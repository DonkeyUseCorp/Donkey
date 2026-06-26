import AppKit
import Carbon.HIToolbox
import Combine
import Darwin
import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation

@MainActor
final class DonkeyAppDelegate: NSObject, NSApplicationDelegate {
    private var authCoordinator: DonkeyAuthCoordinator?
    private var onboardingWindowController: OnboardingWindowController?
    private var loginWindowController: DonkeyLoginWindowController?
    private var permissionSetupController: MacPermissionSetupWindowController?
    private var manualPermissionSetupController: MacPermissionSetupWindowController?
    private var overlayController: UserQueryOverlayController?
    private var uiUnderstandingCoordinator: UIUnderstandingCoordinator?
    /// Mirrors the auth coordinator's session phase into the overlay's `needsLogin`, so the notch
    /// flips to/from the login call-to-action as the session is established or expires.
    private var authStateCancellable: AnyCancellable?
    /// Periodically reconciles the out-of-credits reload CTA against the real balance, so it clears once the
    /// user tops up rather than lingering until relaunch. Paired with an app-reactivation observer for the
    /// common "topped up in the browser, came back" path. Both are torn down on sign-out.
    private var creditReloadPollTimer: Timer?
    private var creditReloadActiveObserver: NSObjectProtocol?
    /// Periodically reconciles the app's session against the server, so a sign-out performed on the website
    /// (or another device) takes effect here without a relaunch. A periodic tick plus an app-reactivation
    /// observer fire a cheap auth-gated probe; a 401 routes through the usual session-expiry handling. Both
    /// run only while signed in and are torn down on sign-out.
    private var sessionHeartbeatTimer: Timer?
    private var sessionHeartbeatActiveObserver: NSObjectProtocol?

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
        // Seed the process-wide session gate before any surface is built, so the warm cache, Live
        // session, and auto-resume all see the real auth state on their first tick instead of the
        // optimistic default. The phase observer keeps it current from here on.
        BackendSessionGate.shared.update(isAuthenticated: authCoordinator.isAuthenticated)
        authCoordinator.authenticationCompleted = { [weak self] _ in
            self?.startAuthenticatedAppSurfaces()
        }
        registerAuthCallbackHandler()
        installMainMenu()

        // First install (never signed in) runs the onboarding walkthrough, which finishes into the
        // sign-in window. A returning user whose session has expired skips both: the notch comes up
        // in login mode (driven by the auth phase observer) and carries them back through sign-in inline.
        if authCoordinator.isAuthenticated || authCoordinator.hasEverSignedIn {
            startAuthenticatedAppSurfaces()
        } else {
            showOnboarding()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleAuthCallbackURL(url)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if authCoordinator?.isAuthenticated != true {
            showLoginWindow()
        } else if let permissionSetupController {
            permissionSetupController.showSetup()
        } else if overlayController == nil {
            startAuthenticatedAppSurfaces()
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
        overlayController?.stop()
        uiUnderstandingCoordinator?.stop()
    }

    /// First-run onboarding: a borderless, draggable card window that walks through what Donkey does.
    /// Whether the user steps through to the final slide or dismisses early, it finishes into sign-in.
    private func showOnboarding() {
        NSApp.setActivationPolicy(.regular)
        let controller = OnboardingWindowController()
        onboardingWindowController = controller
        controller.present(
            pages: OnboardingTour.pages,
            continueButtonTitle: "Continue",
            finishButtonTitle: "Get Started",
            onFinish: { [weak self] in
                self?.finishOnboarding()
            },
            onClose: { [weak self] in
                self?.finishOnboarding()
            }
        )
    }

    private func finishOnboarding() {
        onboardingWindowController = nil
        showLoginWindow()
    }

    private func showLoginWindow() {
        guard let authCoordinator else { return }

        NSApp.setActivationPolicy(.regular)
        if loginWindowController == nil {
            loginWindowController = DonkeyLoginWindowController(authCoordinator: authCoordinator)
        }
        loginWindowController?.showLogin()
    }

    private func startAuthenticatedAppSurfaces() {
        guard overlayController == nil,
              permissionSetupController == nil
        else { return }

        loginWindowController?.close()
        loginWindowController = nil
        NSApp.setActivationPolicy(.regular)

        // The notch overlay renders immediately on launch, so it's always present. When permissions
        // still need granting, the setup window opens alongside the notch rather than gating it.
        startOverlaySurfaces()

        let permissionSetupController = MacPermissionSetupWindowController()
        guard !permissionSetupController.permissionsAreReady else { return }

        self.permissionSetupController = permissionSetupController
        permissionSetupController.completed = { [weak self] in
            self?.permissionSetupController = nil
        }
        permissionSetupController.showSetup()
    }

    private func startOverlaySurfaces() {
        guard overlayController == nil else { return }

        // Voice button transcription: Apple's on-device speech is preferred; Gemini is
        // the automatic fallback when the local path is unavailable or fails.
        let voiceTranscriber = LocalVoiceTranscriptionAdapter(
            runtime: FallbackVoiceTranscriptionRuntime(runtimes: [
                AppleSpeechVoiceTranscriptionRuntime(),
                GeminiVoiceTranscriptionRuntime()
            ])
        )
        let model = UserQueryOverlayModel(voiceTranscriber: voiceTranscriber)

        // The notch Login button starts the real Google sign-in; the auth phase drives whether the
        // notch shows the login call-to-action, so an expired session surfaces here without a window.
        model.loginActionRequested = { [weak self] in
            self?.authCoordinator?.beginGoogleSignIn()
        }
        // A mid-run 401 expired the session: sign out (clears the dead cookie, flips phase to signedOut)
        // so the $phase observer below sets needsLogin — surfacing the notch login WITHOUT tearing down
        // the overlay or opening the window, so running tasks stay put and re-auth happens inline. The
        // server already revoked this session (that's what the 401 means), so this is local cleanup only.
        model.sessionExpired = { [weak self] in
            self?.authCoordinator?.signOut(revokingRemoteSessions: false)
        }
        if let authCoordinator {
            model.updateNeedsLogin(!authCoordinator.isAuthenticated)
            authStateCancellable = authCoordinator.$phase
                .sink { [weak self, weak model] phase in
                    model?.updateNeedsLogin(!phase.isSignedIn)
                    self?.applySessionState(isSignedIn: phase.isSignedIn, model: model)
                }
        }

        // Keep the out-of-credits CTA honest: poll the balance while any task is credit-blocked and clear
        // the CTA the moment a top-up lands, so it doesn't linger until the next relaunch.
        startCreditReloadReconciler(model: model)

        // Warm the on-device speech model in the background so the first voice command
        // isn't blocked behind a model download.
        AppleSpeechVoiceTranscriptionRuntime.prewarm()
        let controller = UserQueryOverlayController(model: model)
        overlayController = controller
        controller.show()

        // Now that the notch surface is live, kick off the first-run download of the bundled CLI tools
        // (ffmpeg/yt-dlp/...). It surfaces as a system-driven conversation the user can watch but not stop,
        // and no-ops once the current version is installed or when nothing is published — so this is cheap
        // to call on every launch and re-sign-in. Tools are only used by agent tasks (which need sign-in),
        // so downloading once the authenticated notch is up — rather than before login — is the right time.
        model.startSystemToolsSetupIfNeeded()

        // Run as a regular app so Donkey keeps a Dock icon and its menu bar (including Sign Out)
        // while the overlay surfaces are live, instead of receding into an accessory agent.
        NSApp.setActivationPolicy(.regular)

        // The UI-understanding engine exists only to draw the developer debug overlay; the agent does
        // not read from it. It parses the screen solely to render that overlay, so it is built only in
        // debug-overlay builds and never in production. The agent's only vision source is the on-demand
        // `vision.capture` tool inside a live run.
        #if DONKEY_DEBUG_OVERLAY
        let uiUnderstandingCoordinator = UIUnderstandingCoordinator(
            overlayController: DebugUIInspectionOverlayController(),
            rendersOverlay: true
        )
        self.uiUnderstandingCoordinator = uiUnderstandingCoordinator
        #endif

        // Start the debug overlay engine (if any) only while signed in; the phase observer above stops
        // and restarts it as the session changes (its parse pass would otherwise 401 while signed out).
        applySessionState(isSignedIn: authCoordinator?.isAuthenticated == true, model: model)
    }

    /// Drive the process-wide session gate, the debug overlay engine, and the Live session from the auth
    /// phase. Signed out: close the gate (every backend call short-circuits to `.authenticationRequired`
    /// with no network round trip) and suspend the overlay engine and Live session, so a logged-out app
    /// stops issuing guaranteed-401 requests. Signed in: reopen the gate and restart them. Idempotent —
    /// `start()`/`stop()` are safe to call repeatedly, and the coordinator is nil outside debug-overlay
    /// builds.
    private func applySessionState(isSignedIn: Bool, model: UserQueryOverlayModel?) {
        BackendSessionGate.shared.update(isAuthenticated: isSignedIn)
        if isSignedIn {
            uiUnderstandingCoordinator?.start()
            model?.resumeLiveSession()
            if let model { startSessionHeartbeat(model: model) }
        } else {
            uiUnderstandingCoordinator?.stop()
            model?.suspendLiveSession()
            stopSessionHeartbeat()
        }
    }

    // MARK: - Session heartbeat

    /// Starts the session heartbeat: a periodic tick plus an app-reactivation observer, each firing a cheap
    /// session-validity probe, plus one immediate probe. Idempotent — a no-op while already running, so the
    /// auth-phase observer can call it freely. Torn down by `stopSessionHeartbeat` on sign-out.
    private func startSessionHeartbeat(model: UserQueryOverlayModel) {
        guard sessionHeartbeatTimer == nil else { return }

        sessionHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self, weak model] _ in
            Task { @MainActor in
                guard let self, let model else { return }
                self.probeSessionValidity(model: model)
            }
        }
        sessionHeartbeatActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak model] _ in
            Task { @MainActor in
                guard let self, let model else { return }
                self.probeSessionValidity(model: model)
            }
        }

        // A locally-stored session can already be dead server-side; probe right away so the notch shows
        // login immediately instead of only on the first real query's 401.
        probeSessionValidity(model: model)
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
    /// (`/api/inference/models/`); a 401 routes through the model's session-expiry handling (sign out →
    /// notch login) via the inference client's auth-expiry callback. Network or other errors are ignored
    /// so a transient hiccup never signs the user out.
    private func probeSessionValidity(model: UserQueryOverlayModel) {
        guard authCoordinator?.isAuthenticated == true,
              let configuration = try? DonkeyBackendInferenceConfiguration.fromEnvironment()
        else { return }

        let backend = DonkeyBackendInferenceClient(
            configuration: configuration,
            onAuthenticationRequired: { [weak model] in
                Task { @MainActor in model?.handleSessionExpired() }
            }
        )
        Task {
            _ = try? await backend.listModels()
        }
    }

    // MARK: - Credit reload reconciliation

    /// Once a task is flagged out-of-credits, nothing in-app retries after the user tops up, so the notch's
    /// reload CTA would linger until relaunch. Reconcile it against the real balance: a periodic tick while any
    /// task carries the flag (and only then — the tick is a free no-op otherwise), plus an app-reactivation
    /// trigger so returning from the billing page in the browser clears the CTA right away.
    private func startCreditReloadReconciler(model: UserQueryOverlayModel) {
        creditReloadPollTimer?.invalidate()
        creditReloadPollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self, weak model] _ in
            Task { @MainActor in
                guard let self, let model else { return }
                self.reconcileCreditReload(model: model)
            }
        }
        if let creditReloadActiveObserver {
            NotificationCenter.default.removeObserver(creditReloadActiveObserver)
        }
        creditReloadActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak model] _ in
            Task { @MainActor in
                guard let self, let model else { return }
                self.reconcileCreditReload(model: model)
            }
        }
    }

    private func stopCreditReloadReconciler() {
        creditReloadPollTimer?.invalidate()
        creditReloadPollTimer = nil
        if let creditReloadActiveObserver {
            NotificationCenter.default.removeObserver(creditReloadActiveObserver)
            self.creditReloadActiveObserver = nil
        }
    }

    /// One reconciliation pass: skip entirely unless a task is credit-blocked and the session is usable, then
    /// fetch the balance and clear the CTA across every flagged task once it goes positive. A 401 routes
    /// through the same session-expiry handling as every other backend call; any other error is ignored so a
    /// transient hiccup leaves the CTA in place for the next pass.
    private func reconcileCreditReload(model: UserQueryOverlayModel) {
        guard model.hasPendingCreditReload,
              BackendSessionGate.shared.isAuthenticated,
              let configuration = try? DonkeyBackendInferenceConfiguration.fromEnvironment()
        else { return }

        let backend = DonkeyBackendInferenceClient(
            configuration: configuration,
            onAuthenticationRequired: { [weak model] in
                Task { @MainActor in model?.handleSessionExpired() }
            }
        )
        Task { @MainActor [weak model] in
            guard let balanceMicros = try? await backend.fetchCreditBalanceMicros(),
                  balanceMicros > 0 else { return }
            model?.clearPendingCreditReload()
        }
    }

    // MARK: - Sign out

    @objc private func signOutMenuAction(_ sender: Any?) {
        signOut()
    }

    @objc private func showOnboardingMenuAction(_ sender: Any?) {
        showOnboardingWalkthrough()
    }

    /// Replays the onboarding walkthrough on demand from the menu. Unlike the first-run path, finishing or
    /// closing it just dismisses the card — it never routes into sign-in.
    private func showOnboardingWalkthrough() {
        NSApp.setActivationPolicy(.regular)
        let controller = OnboardingWindowController()
        onboardingWindowController = controller
        controller.present(
            pages: OnboardingTour.pages,
            finishButtonTitle: "Done",
            onFinish: { [weak self] in self?.onboardingWindowController = nil },
            onClose: { [weak self] in self?.onboardingWindowController = nil }
        )
    }

    // MARK: - Permissions setup

    /// Reopens the Accessibility / screenshot / microphone permission walkthrough on demand. Uses a
    /// dedicated retain so it never collides with the launch-time `permissionSetupController`, which the
    /// startup state machine keys off of.
    @objc private func permissionsSetupMenuAction(_ sender: Any?) {
        let controller = MacPermissionSetupWindowController()
        manualPermissionSetupController = controller
        controller.completed = { [weak self] in
            self?.manualPermissionSetupController = nil
        }
        controller.showSetup()
    }

    private func signOut() {
        // User-initiated: revoke every session for this user so the website (and any other device) signs
        // out too, then tear down local surfaces and surface login.
        authCoordinator?.signOut(revokingRemoteSessions: true)
        teardownAuthenticatedSurfaces()
        showLoginWindow()
    }

    /// Tears down the live overlay/runtime surfaces so a later sign-in can rebuild them cleanly.
    /// `startAuthenticatedAppSurfaces()` guards on these being nil, so they must be reset here.
    private func teardownAuthenticatedSurfaces() {
        authStateCancellable = nil
        stopCreditReloadReconciler()
        stopSessionHeartbeat()
        uiUnderstandingCoordinator?.stop()
        uiUnderstandingCoordinator = nil
        overlayController?.stop()
        overlayController = nil
        permissionSetupController = nil
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

        let showOnboardingItem = NSMenuItem(
            title: "Show Onboarding",
            action: #selector(showOnboardingMenuAction(_:)),
            keyEquivalent: ""
        )
        showOnboardingItem.target = self
        appMenu.addItem(showOnboardingItem)

        let signOutItem = NSMenuItem(
            title: "Sign Out",
            action: #selector(signOutMenuAction(_:)),
            keyEquivalent: ""
        )
        signOutItem.target = self
        appMenu.addItem(signOutItem)

        let permissionsSetupItem = NSMenuItem(
            title: "Permissions Setup…",
            action: #selector(permissionsSetupMenuAction(_:)),
            keyEquivalent: ""
        )
        permissionsSetupItem.target = self
        appMenu.addItem(permissionsSetupItem)

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
