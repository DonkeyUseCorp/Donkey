import SwiftUI

@main
struct Donkey: App {
    @NSApplicationDelegateAdaptor(DonkeyAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            LocalRuntimeSettingsView()
        }
    }
}

private struct LocalRuntimeSettingsView: View {
    @State private var permissionSetupController: MacPermissionSetupWindowController?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Permissions")
                    .font(.headline)
                Text("Reopen setup for Accessibility, screenshot, and microphone access.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Permissions Setup") {
                    let controller = MacPermissionSetupWindowController()
                    permissionSetupController = controller
                    controller.completed = {
                        permissionSetupController = nil
                    }
                    controller.showSetup()
                }
            }
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
    }
}
