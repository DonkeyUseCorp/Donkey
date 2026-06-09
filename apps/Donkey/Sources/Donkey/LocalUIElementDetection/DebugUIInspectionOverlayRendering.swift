import DonkeyContracts
import DonkeyRuntime

/// Rendering seam for the UI-understanding engine. The engine (parse + per-window cache + warming)
/// runs in every build; only the visual overlay is a debug build concern, so the engine talks to an
/// abstract renderer and the concrete AppKit overlay lives behind `DONKEY_DEBUG_OVERLAY`.
@MainActor
protocol DebugUIInspectionOverlayRendering {
    func render(frame: DebugUIInspectionFrame, snapshot: DebugUIScreenCaptureSnapshot)
    func closeScreens(except activeScreenIDs: Set<UInt32>)
    func setHidden(_ hidden: Bool)
    func close()
}

/// Production renderer: the engine still parses and caches, it just paints nothing.
@MainActor
struct NoopDebugUIInspectionOverlayRenderer: DebugUIInspectionOverlayRendering {
    func render(frame: DebugUIInspectionFrame, snapshot: DebugUIScreenCaptureSnapshot) {}
    func closeScreens(except activeScreenIDs: Set<UInt32>) {}
    func setHidden(_ hidden: Bool) {}
    func close() {}
}
