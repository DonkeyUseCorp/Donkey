import SwiftUI

@main
struct Donkey: App {
    @NSApplicationDelegateAdaptor(DonkeyAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
