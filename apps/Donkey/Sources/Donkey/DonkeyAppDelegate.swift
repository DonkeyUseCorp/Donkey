import AppKit
import Carbon.HIToolbox
import Darwin
import DonkeyAI
import DonkeyRuntime
import Foundation

@MainActor
final class DonkeyAppDelegate: NSObject, NSApplicationDelegate {
    private var authCoordinator: DonkeyAuthCoordinator?
    private var loginWindowController: DonkeyLoginWindowController?
    private var permissionSetupController: MacPermissionSetupWindowController?
    private var overlayController: UserQueryOverlayController?
    private var uiUnderstandingCoordinator: UIUnderstandingCoordinator?
    private var runtimeOnboardingController: LocalRuntimeOnboardingWindowController?
    private var frontmostVisionWarmCache: FrontmostVisionWarmCache?

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
        authCoordinator.authenticationCompleted = { [weak self] _ in
            self?.startAuthenticatedAppSurfaces()
        }
        registerAuthCallbackHandler()

        if authCoordinator.isAuthenticated {
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

        let permissionSetupController = MacPermissionSetupWindowController()
        if permissionSetupController.permissionsAreReady {
            startOverlaySurfaces()
            return
        }

        self.permissionSetupController = permissionSetupController
        permissionSetupController.completed = { [weak self] in
            self?.permissionSetupController = nil
            self?.startOverlaySurfaces()
        }
        permissionSetupController.showSetup()
    }

    private func startOverlaySurfaces() {
        guard overlayController == nil else { return }

        NSApp.setActivationPolicy(.accessory)

        let model = UserQueryOverlayModel()
        let controller = UserQueryOverlayController(model: model)
        overlayController = controller
        controller.show()

        // The UI-understanding engine (AX + AI parse + per-window cache + background warming) runs in
        // every build. Only the visual overlay is debug-only: debug builds inject the AppKit overlay
        // renderer, while production parses headlessly through a no-op renderer.
        #if DONKEY_DEBUG_OVERLAY
        let uiUnderstandingCoordinator = UIUnderstandingCoordinator(
            overlayController: DebugUIInspectionOverlayController(),
            rendersOverlay: true
        )
        #else
        let uiUnderstandingCoordinator = UIUnderstandingCoordinator(
            rendersOverlay: false,
            defaultConfiguration: DebugUIOverlayConfiguration(enabled: true, activeWindowOnly: true)
        )
        #endif
        self.uiUnderstandingCoordinator = uiUnderstandingCoordinator
        uiUnderstandingCoordinator.start()

        let runtimeOnboardingController = LocalRuntimeOnboardingWindowController()
        self.runtimeOnboardingController = runtimeOnboardingController
        runtimeOnboardingController.showIfSetupNeeded()

        // Keep ParsedVisionStore warm: watch the frontmost window and re-parse on big changes, so a
        // typed vision command reuses a fresh parse instead of paying for one inline. No-ops when the
        // vision backend isn't configured.
        let frontmostVisionWarmCache = FrontmostVisionWarmCache.fromEnvironment()
        self.frontmostVisionWarmCache = frontmostVisionWarmCache
        frontmostVisionWarmCache?.start()
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
