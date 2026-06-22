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
    private var loginWindowController: DonkeyLoginWindowController?
    private var permissionSetupController: MacPermissionSetupWindowController?
    private var manualPermissionSetupController: MacPermissionSetupWindowController?
    private var overlayController: UserQueryOverlayController?
    private var uiUnderstandingCoordinator: UIUnderstandingCoordinator?
    private var frontmostVisionWarmCache: FrontmostVisionWarmCache?
    /// Mirrors the auth coordinator's session phase into the overlay's `needsLogin`, so the notch
    /// flips to/from the login call-to-action as the session is established or expires.
    private var authStateCancellable: AnyCancellable?

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

        // Kick off the first-run download of the bundled CLI tools (ffmpeg/yt-dlp/...) in the background,
        // so a later media task runs them by bare name instead of hunting for Homebrew. Non-blocking and a
        // no-op once the current version is installed or when nothing is published yet.
        Task.detached(priority: .utility) {
            await BundledToolsInstaller.shared.installIfNeeded()
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

        // First install (never signed in) opens the welcome/sign-in window. A returning user whose
        // session has expired skips the window: the notch comes up in login mode (driven by the auth
        // phase observer) and carries them back through sign-in inline.
        if authCoordinator.isAuthenticated || authCoordinator.hasEverSignedIn {
            startAuthenticatedAppSurfaces()
        } else {
            showLoginWindow()
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
        frontmostVisionWarmCache?.stop()
        uiUnderstandingCoordinator?.stop()
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
        // the overlay or opening the window, so running tasks stay put and re-auth happens inline.
        model.sessionExpired = { [weak self] in
            self?.authCoordinator?.signOut()
        }
        if let authCoordinator {
            model.updateNeedsLogin(!authCoordinator.isAuthenticated)
            authStateCancellable = authCoordinator.$phase
                .sink { [weak self, weak model] phase in
                    model?.updateNeedsLogin(!phase.isSignedIn)
                    self?.applySessionState(isSignedIn: phase.isSignedIn, model: model)
                }
        }

        // A locally-stored session can already be expired server-side, which otherwise only surfaces on
        // the first query's 401. Probe the backend on launch so the notch shows login right away.
        validateStoredSession(model: model)

        // Warm the on-device speech model in the background so the first voice command
        // isn't blocked behind a model download.
        AppleSpeechVoiceTranscriptionRuntime.prewarm()
        let controller = UserQueryOverlayController(model: model)
        overlayController = controller
        controller.show()

        // Run as a regular app so Donkey keeps a Dock icon and its menu bar (including Sign Out)
        // while the overlay surfaces are live, instead of receding into an accessory agent.
        NSApp.setActivationPolicy(.regular)

        // The UI-understanding engine (AX + AI parse + per-window cache + background warming) runs in
        // every build and feeds the agent. Only the visual overlay is gated: debug builds inject the
        // AppKit overlay renderer (shown when the dev-overlay config turns it on), while production
        // parses headlessly through a no-op renderer.
        #if DONKEY_DEBUG_OVERLAY
        let uiUnderstandingCoordinator = UIUnderstandingCoordinator(
            overlayController: DebugUIInspectionOverlayController(),
            rendersOverlay: true
        )
        #else
        let uiUnderstandingCoordinator = UIUnderstandingCoordinator(
            rendersOverlay: false
        )
        #endif
        self.uiUnderstandingCoordinator = uiUnderstandingCoordinator

        // Keep ParsedVisionStore warm: watch the frontmost window and re-parse on big changes, so a
        // typed vision command reuses a fresh parse instead of paying for one inline. No-ops when the
        // vision backend isn't configured.
        let frontmostVisionWarmCache = FrontmostVisionWarmCache.fromEnvironment()
        self.frontmostVisionWarmCache = frontmostVisionWarmCache

        // Start the always-on backend loops only while signed in; the phase observer above suspends and
        // resumes them as the session changes (an expired session must not keep them issuing 401s).
        applySessionState(isSignedIn: authCoordinator?.isAuthenticated == true, model: model)
    }

    /// Drive the process-wide session gate and the always-on backend loops from the auth phase. Signed
    /// out: close the gate (every backend call short-circuits to `.authenticationRequired` with no
    /// network round trip) and fully suspend the warm cache, UI-understanding engine, and Live session,
    /// so a logged-out app stops issuing guaranteed-401 requests. Signed in: reopen the gate and restart
    /// them. Idempotent — `start()`/`stop()` on each loop are safe to call repeatedly.
    private func applySessionState(isSignedIn: Bool, model: UserQueryOverlayModel?) {
        BackendSessionGate.shared.update(isAuthenticated: isSignedIn)
        if isSignedIn {
            uiUnderstandingCoordinator?.start()
            frontmostVisionWarmCache?.start()
            model?.resumeLiveSession()
        } else {
            uiUnderstandingCoordinator?.stop()
            frontmostVisionWarmCache?.stop()
            model?.suspendLiveSession()
        }
    }

    /// Confirms a locally-stored session is still valid server-side. Fires one cheap, auth-gated GET
    /// (`/api/inference/models/`); a 401 routes through the model's session-expiry handling (sign out →
    /// notch login) via the inference client's auth-expiry callback. Network or other errors are
    /// ignored so a transient hiccup never signs the user out. Runs off the launch path.
    private func validateStoredSession(model: UserQueryOverlayModel) {
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

    // MARK: - Sign out

    @objc private func signOutMenuAction(_ sender: Any?) {
        signOut()
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
        authCoordinator?.signOut()
        teardownAuthenticatedSurfaces()
        showLoginWindow()
    }

    /// Tears down the live overlay/runtime surfaces so a later sign-in can rebuild them cleanly.
    /// `startAuthenticatedAppSurfaces()` guards on these being nil, so they must be reset here.
    private func teardownAuthenticatedSurfaces() {
        authStateCancellable = nil
        frontmostVisionWarmCache?.stop()
        frontmostVisionWarmCache = nil
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
