import AppKit

enum DonkeyOverlayWindowLevel {
    static let debugInspection = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
    static let userQuery: NSWindow.Level = .statusBar
}
