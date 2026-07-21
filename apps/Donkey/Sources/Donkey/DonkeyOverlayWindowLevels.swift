import AppKit

enum DonkeyOverlayWindowLevel {
    static let debugInspection = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
    static let userQuery: NSWindow.Level = .statusBar
    /// The screen-recording region/window picker: a full-screen dim + selection, floating at the
    /// status-bar tier so it paints over app windows while arming a recording.
    static let regionSelection: NSWindow.Level = .statusBar
    /// The recording control bar, one tier above the picker so its buttons stay visible and clickable
    /// over the dim while a region or window is being chosen.
    static let recordingControlBar = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
}
