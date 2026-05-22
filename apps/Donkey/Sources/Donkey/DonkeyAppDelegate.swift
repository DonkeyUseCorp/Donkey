import AppKit
import Carbon.HIToolbox
import Darwin
import Foundation

@MainActor
final class DonkeyAppDelegate: NSObject, NSApplicationDelegate {
    private var authCoordinator: DonkeyAuthCoordinator?
    private var loginWindowController: DonkeyLoginWindowController?
    private var overlayController: PointerPromptOverlayController?
    private var runtimeOnboardingController: LocalRuntimeOnboardingWindowController?

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
        guard overlayController == nil else { return }

        loginWindowController?.close()
        loginWindowController = nil
        NSApp.setActivationPolicy(.accessory)

        let model = PointerPromptOverlayModel()
        let controller = PointerPromptOverlayController(model: model)
        overlayController = controller
        controller.show()

        let runtimeOnboardingController = LocalRuntimeOnboardingWindowController()
        self.runtimeOnboardingController = runtimeOnboardingController
        runtimeOnboardingController.showIfSetupNeeded()
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
