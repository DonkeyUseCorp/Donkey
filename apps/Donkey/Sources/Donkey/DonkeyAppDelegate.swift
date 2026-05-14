import AppKit

@MainActor
final class DonkeyAppDelegate: NSObject, NSApplicationDelegate {
    private var overlayController: PointerPromptOverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = PointerPromptOverlayModel()
        let controller = PointerPromptOverlayController(model: model)
        overlayController = controller
        controller.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlayController?.stop()
    }
}
