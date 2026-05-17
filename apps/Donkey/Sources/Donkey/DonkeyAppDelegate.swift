import AppKit
import Darwin

@MainActor
final class DonkeyAppDelegate: NSObject, NSApplicationDelegate {
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

        NSApp.setActivationPolicy(.accessory)

        let model = PointerPromptOverlayModel()
        let controller = PointerPromptOverlayController(model: model)
        overlayController = controller
        controller.show()

        let runtimeOnboardingController = LocalRuntimeOnboardingWindowController()
        self.runtimeOnboardingController = runtimeOnboardingController
        runtimeOnboardingController.showIfSetupNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlayController?.stop()
    }
}
