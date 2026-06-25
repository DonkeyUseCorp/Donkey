import CoreGraphics
import DonkeyContracts
import DonkeyRuntime
import Foundation

/// Runs one normalized `VisionComputerAction` against the target window with the real pointer and
/// keyboard, returning a short history line. This is the single sink for both computer-use loops (the
/// direct-Vertex Live escalation and the hosted `createResponse` path), so coordinate mapping and the
/// action vocabulary stay identical across them.
///
/// `target` is nil for foreground input (the driver brings the app frontmost and the real cursor
/// moves); a background `InputTarget` routes input to the process without warping the cursor.
@MainActor
public enum VisionComputerActionExecutor {
    @discardableResult
    public static func execute(
        _ action: VisionComputerAction,
        window: WindowTargetBounds,
        target: InputTarget? = nil
    ) async -> String {
        let note = action.intent.isEmpty ? "" : ": \(action.intent)"

        switch action.kind {
        case let .click(button, count, point):
            let screen = screenPoint(point, window: window)
            MacPointerInput.moveAndClick(at: screen, button: button, clickCount: count, target: target)
            return "\(clickLabel(button, count)) (\(label(screen)))\(note)"

        case let .move(point):
            let screen = screenPoint(point, window: window)
            MacPointerInput.move(to: screen, target: target)
            return "moved to (\(label(screen)))\(note)"

        case let .drag(from, to):
            let start = screenPoint(from, window: window)
            let end = screenPoint(to, window: window)
            MacPointerInput.drag(from: start, to: end, target: target)
            return "dragged (\(label(start))) → (\(label(end)))\(note)"

        case let .scroll(point, direction, magnitude):
            let screen = point.map { screenPoint($0, window: window) } ?? windowCenter(window)
            let (deltaX, deltaY) = scrollDeltas(direction: direction, magnitude: magnitude)
            MacPointerInput.scroll(at: screen, deltaX: deltaX, deltaY: deltaY, target: target)
            return "scrolled \(direction.rawValue) (\(label(screen)))\(note)"

        case let .type(text, point, pressEnter, clearFirst):
            if let point {
                MacPointerInput.moveAndClick(at: screenPoint(point, window: window), target: target)
            }
            if clearFirst {
                MacKeyboardInput.pressKey("a", modifiers: ["command"], target: target)
                MacKeyboardInput.pressKey("delete", target: target)
            }
            MacKeyboardInput.type(text, target: target)
            if pressEnter {
                MacKeyboardInput.pressReturn(target: target)
            }
            return "typed \"\(text)\"\(pressEnter ? " ⏎" : "")\(note)"

        case let .keys(keys):
            guard let last = keys.last else {
                // Unrecognized/empty key call: fall back to Return (submit), as the prior loop did when
                // a key action arrived without a name — better than silently doing nothing.
                MacKeyboardInput.pressReturn(target: target)
                return "pressed return (empty key combination)\(note)"
            }
            MacKeyboardInput.pressKey(last, modifiers: Array(keys.dropLast()), target: target)
            return "pressed \(keys.joined(separator: "+"))\(note)"

        case let .wait(seconds):
            let clamped = min(max(seconds, 0), 10)
            try? await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
            return "waited \(formatted(clamped))s\(note)"

        case let .done(text):
            return text.isEmpty ? "done\(note)" : "done: \(text)"

        case let .unsupported(name):
            return "ignored unsupported action \(name)\(note)"
        }
    }

    /// Maps a 0–1000 normalized point onto the target window's screen bounds (top-left origin). This is
    /// independent of the compressed screenshot size, so it stays correct after downscaling. The single
    /// normalized→screen mapping shared by the computer-use loops and the harness AX/vision tools.
    /// `nonisolated` so non-MainActor coordinate math (the pointer tools) can reuse it.
    nonisolated public static func screenPoint(_ point: VisionComputerAction.Point, window: WindowTargetBounds) -> CGPoint {
        let nx = min(max(point.x / normalizedScale, 0), 1)
        let ny = min(max(point.y / normalizedScale, 0), 1)
        return CGPoint(x: window.x + nx * window.width, y: window.y + ny * window.height)
    }

    /// Gemini reports coordinates in a 0–1000 normalized space (origin top-left), independent of the
    /// raw pixel size — so detection coordinates expressed in this scale map cleanly to the window.
    nonisolated public static let normalizedScale = 1_000.0

    private static func windowCenter(_ window: WindowTargetBounds) -> CGPoint {
        CGPoint(x: window.x + window.width / 2, y: window.y + window.height / 2)
    }

    /// Maps a scroll direction to CGEvent line deltas for a given line count. CGEvent convention:
    /// positive y scrolls up, positive x scrolls left. The single home for the direction→sign mapping,
    /// shared with the harness `mouse.scroll` tool so the two scroll paths can't drift in sign.
    nonisolated public static func scrollLineDeltas(
        direction: VisionComputerAction.ScrollDirection,
        lines: Int
    ) -> (Int, Int) {
        switch direction {
        case .up: return (0, lines)
        case .down: return (0, -lines)
        case .left: return (lines, 0)
        case .right: return (-lines, 0)
        }
    }

    /// Converts an optional pixel magnitude into a coarse, clamped wheel-line count. The loop
    /// re-screenshots after each step, so an approximate amount is fine.
    private static func scrollDeltas(
        direction: VisionComputerAction.ScrollDirection,
        magnitude: Double?
    ) -> (Int, Int) {
        let lines = magnitude.map { max(1, min(Int(($0 / 80).rounded()), 20)) } ?? 6
        return scrollLineDeltas(direction: direction, lines: lines)
    }

    /// The base verb for a click variant ("click", "double-click", "right-click", …). The single home
    /// for the button+count → variant decision, so trace, history, and user-facing strings can't drift.
    nonisolated public static func clickVerb(button: MacPointerInput.Button, count: Int) -> String {
        switch button {
        case .right: return "right-click"
        case .center: return "middle-click"
        case .left:
            return count >= 3 ? "triple-click" : count == 2 ? "double-click" : "click"
        }
    }

    private static func clickLabel(_ button: MacPointerInput.Button, _ count: Int) -> String {
        "\(clickVerb(button: button, count: count))ed"
    }

    private static func label(_ point: CGPoint) -> String { "\(Int(point.x)),\(Int(point.y))" }

    private static func formatted(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%.1f", seconds)
    }
}
