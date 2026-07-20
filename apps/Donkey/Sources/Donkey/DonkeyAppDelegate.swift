import AppKit
import Carbon.HIToolbox
import Combine
import Darwin
import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation
import SwiftUI

@MainActor
final class DonkeyAppDelegate: NSObject, NSApplicationDelegate {
    private var authCoordinator: DonkeyAuthCoordinator?
    private var onboardingWindowController: OnboardingWindowController?
    private var permissionSetupController: MacPermissionSetupWindowController?
    /// The menu bar surface: the status item whose menu carries Go to App / Log in / Log out.
    private var statusItemController: DonkeyStatusItemController?
    /// Sparkle, running windowless. A background check that finds an update surfaces the status
    /// menu's "Install Update" item; choosing it downloads, installs, and relaunches silently.
    private var updateChecker: (any DonkeyUpdateChecking)?
    private var uiUnderstandingCoordinator: UIUnderstandingCoordinator?
    /// Mirrors the auth coordinator's session phase into the process-wide session gate and the
    /// session heartbeat for the whole run; the status menu reads the phase directly when it opens.
    private var authStateCancellable: AnyCancellable?
    /// Periodically reconciles the app's session against the server, so a sign-out performed on the website
    /// (or another device) takes effect here without a relaunch. A periodic tick plus an app-reactivation
    /// observer fire a cheap auth-gated probe; a 401 routes through the usual session-expiry handling. Both
    /// run only while signed in and are torn down on sign-out.
    private var sessionHeartbeatTimer: Timer?
    private var sessionHeartbeatActiveObserver: NSObjectProtocol?
    /// Runs the Donkey Cut engine (the local server behind cut.donkeyuse.com) for the app's
    /// lifetime. Cut is free and standalone, so this starts regardless of sign-in state.
    private var cutEngineSupervisor: DonkeyCutEngineSupervisor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ManualCaptureDebugLaunchHandler.shouldHandle(arguments: CommandLine.arguments) {
            NSApp.setActivationPolicy(.accessory)
            Task {
                let exitCode = await ManualCaptureDebugLaunchHandler().run(
                    arguments: CommandLine.arguments
                )
                Darwin.exit(exitCode)
            }
            return
        }

        let authCoordinator = DonkeyAuthCoordinator()
        self.authCoordinator = authCoordinator
        // Seed the process-wide session gate before any surface is built, so every backend consumer
        // sees the real auth state on its first tick instead of the optimistic default. The phase
        // observer keeps it current from here on.
        BackendSessionGate.shared.update(isAuthenticated: authCoordinator.isAuthenticated)
        authCoordinator.authenticationCompleted = { [weak self] _ in
            // Sign-in may have happened on the onboarding card's sign-in slide; close it. `close()`
            // clears the retain via onDismiss, and this is a no-op when the card isn't showing
            // (e.g. sign-in from the status menu).
            self?.onboardingWindowController?.close()
        }
        registerAuthCallbackHandler()
        installMainMenu()
        installStatusItem(authCoordinator: authCoordinator)
        startUpdateChecker()

        let cutEngineSupervisor = DonkeyCutEngineSupervisor()
        self.cutEngineSupervisor = cutEngineSupervisor
        cutEngineSupervisor.start()

        // The UI-understanding engine exists only to draw the developer debug overlay; the agent does
        // not read from it. It parses the screen solely to render that overlay, so it is built only in
        // debug-overlay builds and never in production.
        #if DONKEY_DEBUG_OVERLAY
        uiUnderstandingCoordinator = UIUnderstandingCoordinator(
            overlayController: DebugUIInspectionOverlayController(),
            rendersOverlay: true
        )
        #endif

        // Drive the session gate, heartbeat, and debug overlay engine from the auth phase for the
        // whole run. `$phase` replays the current value on subscription, so this also applies the
        // launch state.
        authStateCancellable = authCoordinator.$phase
            .sink { [weak self] phase in
                self?.applySessionState(isSignedIn: phase.isSignedIn)
            }

        // First install (never signed in) opens the onboarding card on its sign-in landing. A
        // returning user signs in from the status menu instead.
        if !authCoordinator.isAuthenticated && !authCoordinator.hasEverSignedIn {
            presentOnboardingCard(entry: .signIn)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleAuthCallbackURL(url)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // The donkey:// sign-in callback can be serviced by a different app instance than this one
        // (LaunchServices cold-launching a second copy of this bundle id, which shares this
        // UserDefaults domain). That copy persists the session and exits, leaving this instance's
        // in-memory phase signed-out and the status menu stuck on "Log in". Clicking "Open Donkey"
        // activates us, so reconciling from the durable session here flips the phase — and the menu —
        // without a relaunch. A no-op when already signed in or when no session is on disk.
        authCoordinator?.reconcileWithPersistedSession()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if authCoordinator?.isAuthenticated != true {
            presentOnboardingCard(entry: .signIn)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        uiUnderstandingCoordinator?.stop()
        cutEngineSupervisor?.stop()
    }

    /// Where to open the onboarding card.
    private enum OnboardingEntry {
        /// Land on the sign-in slide: signed-out app-open, reopen, or post-sign-out.
        case signIn
        /// Open on the feature tour: the "Show Onboarding" menu replay.
        case tour
    }

    /// Presents the onboarding card — the single surface for both the walkthrough and login. When signed
    /// out, slide 0 is the Google sign-in landing with an Explore link into the feature tour, and the card
    /// stays up until sign-in completes (the `authenticationCompleted` handler closes it). When signed in,
    /// it's the feature tour ending in Done. `entry` chooses the opening slide.
    private func presentOnboardingCard(entry: OnboardingEntry) {
        guard let authCoordinator else { return }
        NSApp.setActivationPolicy(.regular)

        // Only one onboarding card is ever on screen: if one is already up, close it before showing the
        // next so a reopen or menu replay replaces the current card rather than stacking another behind it.
        // `close()` fires the old card's onDismiss synchronously (clearing this reference), so the fresh
        // controller assigned next isn't clobbered.
        onboardingWindowController?.close()

        let controller = OnboardingWindowController()
        onboardingWindowController = controller

        let isSignedIn = authCoordinator.isAuthenticated
        // Reopening the sign-in surface means the user is back to try again: clear any stalled attempt
        // (e.g. they dismissed the card on "Continue with Google", then closed the browser) so the button
        // is enabled and ready rather than stuck disabled on `.waitingForCallback`.
        if !isSignedIn {
            authCoordinator.resetSignInIfStalled()
        }
        let pages = OnboardingTour.pages(isSignedIn: isSignedIn)

        // Signed-out pages are [sign-in, features...]. `.signIn` opens on the landing (0); `.tour` skips
        // to the first feature (1). Signed-in pages are features only, always opened at 0.
        let initialPageIndex: Int
        if isSignedIn {
            initialPageIndex = 0
        } else {
            switch entry {
            case .signIn: initialPageIndex = 0
            case .tour: initialPageIndex = min(1, pages.count - 1)
            }
        }

        controller.present(
            pages: pages,
            initialPageIndex: initialPageIndex,
            continueButtonTitle: "Continue",
            finishButtonTitle: "Done",
            onDismiss: { [weak self] in self?.onboardingWindowController = nil },
            signInFooter: isSignedIn ? nil : { [weak self, authCoordinator] in
                AnyView(OnboardingGoogleSignInFooter(
                    authCoordinator: authCoordinator,
                    onContinue: { self?.onboardingWindowController?.close() }
                ))
            }
        )
    }

    // MARK: - Status item

    private func installStatusItem(authCoordinator: DonkeyAuthCoordinator) {
        statusItemController = DonkeyStatusItemController(
            isSignedIn: { [weak authCoordinator] in
                authCoordinator?.isAuthenticated == true
            },
            logIn: { [weak authCoordinator] in
                authCoordinator?.beginGoogleSignIn()
            },
            logOut: { [weak self] in
                self?.signOut()
            },
            checkForUpdates: { [weak self] in
                self?.updateChecker?.checkForUpdatesInBackground()
            },
            installUpdate: { [weak self] in
                self?.updateChecker?.installAvailableUpdate()
            }
        )
    }

    // MARK: - Updates

    private func startUpdateChecker() {
        let updateChecker = SparkleUpdateController()
        self.updateChecker = updateChecker
        updateChecker.updateStateChanged = { [weak self] state in
            self?.statusItemController?.updateState = state
        }
        updateChecker.start()
    }

    /// Drive the process-wide session gate, the debug overlay engine, and the session heartbeat from
    /// the auth phase. Signed out: close the gate (every backend call short-circuits to
    /// `.authenticationRequired` with no network round trip) and suspend the overlay engine, so a
    /// logged-out app stops issuing guaranteed-401 requests. Signed in: reopen the gate and restart
    /// them. Idempotent — `start()`/`stop()` are safe to call repeatedly, and the coordinator is nil
    /// outside debug-overlay builds.
    private func applySessionState(isSignedIn: Bool) {
        BackendSessionGate.shared.update(isAuthenticated: isSignedIn)
        if isSignedIn {
            uiUnderstandingCoordinator?.start()
            startSessionHeartbeat()
        } else {
            uiUnderstandingCoordinator?.stop()
            stopSessionHeartbeat()
        }
    }

    // MARK: - Session heartbeat

    /// Starts the session heartbeat: a periodic tick plus an app-reactivation observer, each firing a cheap
    /// session-validity probe, plus one immediate probe. Idempotent — a no-op while already running, so the
    /// auth-phase observer can call it freely. Torn down by `stopSessionHeartbeat` on sign-out.
    private func startSessionHeartbeat() {
        guard sessionHeartbeatTimer == nil else { return }

        sessionHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.probeSessionValidity()
            }
        }
        sessionHeartbeatActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.probeSessionValidity()
            }
        }

        // A locally-stored session can already be dead server-side; probe right away so the status menu
        // shows "Log in" immediately instead of only on the first real query's 401.
        probeSessionValidity()
    }

    private func stopSessionHeartbeat() {
        sessionHeartbeatTimer?.invalidate()
        sessionHeartbeatTimer = nil
        if let sessionHeartbeatActiveObserver {
            NotificationCenter.default.removeObserver(sessionHeartbeatActiveObserver)
            self.sessionHeartbeatActiveObserver = nil
        }
    }

    /// Confirms the session is still valid server-side. Fires one cheap, auth-gated GET
    /// (`/api/inference/models/`); a 401 clears the dead local session — the server already revoked it,
    /// so this is local cleanup only — which flips the status menu to "Log in" via the phase observer.
    /// Network or other errors are ignored so a transient hiccup never signs the user out.
    private func probeSessionValidity() {
        guard authCoordinator?.isAuthenticated == true,
              let configuration = try? DonkeyBackendInferenceConfiguration.fromEnvironment()
        else { return }

        let backend = DonkeyBackendInferenceClient(
            configuration: configuration,
            onAuthenticationRequired: { [weak self] in
                Task { @MainActor in
                    self?.authCoordinator?.signOut(revokingRemoteSessions: false)
                }
            }
        )
        Task {
            _ = try? await backend.listModels()
        }
    }

    // MARK: - Sign out

    @objc private func signOutMenuAction(_ sender: Any?) {
        signOut()
    }

    @objc private func showOnboardingMenuAction(_ sender: Any?) {
        presentOnboardingCard(entry: .tour)
    }

    // MARK: - Permissions setup

    /// Opens the Accessibility / screenshot / microphone permission walkthrough on demand.
    @objc private func permissionsSetupMenuAction(_ sender: Any?) {
        let controller = MacPermissionSetupWindowController()
        permissionSetupController = controller
        controller.completed = { [weak self] in
            self?.permissionSetupController = nil
        }
        controller.showSetup()
    }

    private func signOut() {
        // User-initiated: revoke every session for this user so the website (and any other device) signs
        // out too. The phase observer tears down the session-bound machinery, and the status menu flips
        // to "Log in" the next time it opens.
        authCoordinator?.signOut(revokingRemoteSessions: true)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(signOutMenuAction) {
            return authCoordinator?.isAuthenticated == true
        }
        return true
    }

    // MARK: - Menu

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(
            withTitle: "About \(Self.appDisplayName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())

        let showOnboardingItem = NSMenuItem(
            title: "Show Onboarding",
            action: #selector(showOnboardingMenuAction(_:)),
            keyEquivalent: ""
        )
        showOnboardingItem.target = self
        appMenu.addItem(showOnboardingItem)

        let permissionsSetupItem = NSMenuItem(
            title: "Permissions Setup",
            action: #selector(permissionsSetupMenuAction(_:)),
            keyEquivalent: ""
        )
        permissionsSetupItem.target = self
        appMenu.addItem(permissionsSetupItem)

        let signOutItem = NSMenuItem(
            title: "Sign Out",
            action: #selector(signOutMenuAction(_:)),
            keyEquivalent: ""
        )
        signOutItem.target = self
        appMenu.addItem(signOutItem)

        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit \(Self.appDisplayName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )

        NSApp.mainMenu = mainMenu
    }

    private static var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
    }

    private func registerAuthCallbackHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc
    private func handleGetURLEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else {
            return
        }

        handleAuthCallbackURL(url)
    }

    private func handleAuthCallbackURL(_ url: URL) {
        guard authCoordinator?.handleCallbackURL(url) == true else {
            return
        }

        NSApp.activate(ignoringOtherApps: true)
    }
}
