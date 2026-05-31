import CoreGraphics
import DonkeyContracts
import Foundation

/// Low-level keyboard input via CGEvent. Real input — gate behind explicit permission/guards.
public enum MacKeyboardInput {
    /// Types arbitrary text by posting per-character unicode key events.
    public static func type(_ text: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        // Post one event per Character, using its full UTF-16 representation. Characters outside the
        // Basic Multilingual Plane (emoji, CJK extensions, …) encode as a surrogate pair, so we send
        // both code units together in a single event rather than truncating to one UniChar — which
        // would silently drop the character.
        for character in text {
            var units = Array(character.utf16)
            guard !units.isEmpty,
                  let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    /// Posts a Return keypress (virtual key 36).
    public static func pressReturn() {
        pressKey("return")
    }

    /// Posts a single named key (return, escape, tab, arrows, …). Unknown names that look like a
    /// single character are typed as text rather than silently firing the wrong key; truly unknown
    /// multi-char names fall back to Return so a "submit"-style intent still does something sane.
    public static func pressKey(_ name: String) {
        let normalized = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let keyCode = virtualKeyCode(for: normalized) else {
            if normalized.count == 1 {
                type(name)
            } else {
                postKey(36) // unknown key name → Return
            }
            return
        }
        postKey(keyCode)
    }

    private static func postKey(_ keyCode: CGKeyCode) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func virtualKeyCode(for name: String) -> CGKeyCode? {
        switch name {
        case "return", "enter", "\n", "": return 36
        case "tab", "\t": return 48
        case "space", "spacebar", " ": return 49
        case "escape", "esc": return 53
        case "delete", "backspace": return 51
        case "forwarddelete", "fwddelete": return 117
        case "left", "leftarrow": return 123
        case "right", "rightarrow": return 124
        case "down", "downarrow": return 125
        case "up", "uparrow": return 126
        case "home": return 115
        case "end": return 119
        case "pageup": return 116
        case "pagedown": return 121
        default: return nil
        }
    }
}

/// Low-level pointer input via CGEvent (move + left click at a screen point). Real input — callers
/// must gate this behind explicit permission/guards.
public enum MacPointerInput {
    @discardableResult
    public static func moveAndClick(at point: CGPoint) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        else {
            return false
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

/// Acts on an app by grounding a control in its accessibility tree and clicking it with the real
/// pointer. This is the accessibility/UI execution path the strategy router falls back to for
/// Electron / non-scriptable apps (and on AppleScript failure).
///
/// Safety: it performs real input only when `liveInputEnabled` is true AND the target window is
/// frontmost (focus guard). Otherwise it grounds the control and reports what it *would* do without
/// moving the pointer, so callers can preview / drive the overlay without acting.
@MainActor
public enum AccessibilityActionExecutor {
    public struct Outcome: Sendable {
        public var clicked: Bool
        public var reason: String
        public var screenPoint: CGPoint?
        public var resolvedAppName: String?
        public var controlID: String?

        public init(
            clicked: Bool,
            reason: String,
            screenPoint: CGPoint? = nil,
            resolvedAppName: String? = nil,
            controlID: String? = nil
        ) {
            self.clicked = clicked
            self.reason = reason
            self.screenPoint = screenPoint
            self.resolvedAppName = resolvedAppName
            self.controlID = controlID
        }
    }

    public static func clickControl(
        appName: String?,
        bundleIdentifier: String?,
        targetQuery: String,
        liveInputEnabled: Bool,
        windowResolver: MacWindowResolver = MacWindowResolver(),
        click: (CGPoint) -> Bool = MacPointerInput.moveAndClick
    ) -> Outcome {
        guard let observation = AccessibilityObserver.observe(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            resolver: windowResolver
        ) else {
            return Outcome(clicked: false, reason: "accessibilityObservationUnavailable")
        }
        guard let control = AccessibilityCursorPathBuilder.resolve(targetQuery, in: observation.controls),
              let frame = control.frame,
              frame.hasPositiveArea
        else {
            return Outcome(clicked: false, reason: "controlNotFound", resolvedAppName: observation.target.appName)
        }

        let point = clickPoint(for: frame)
        // Focus guard: only drive real input into the frontmost window.
        guard observation.target.isFrontmost else {
            return Outcome(clicked: false, reason: "targetNotFrontmost", screenPoint: point, resolvedAppName: observation.target.appName, controlID: control.id)
        }
        guard liveInputEnabled else {
            return Outcome(clicked: false, reason: "liveInputDisabled", screenPoint: point, resolvedAppName: observation.target.appName, controlID: control.id)
        }
        let didClick = click(point)
        return Outcome(
            clicked: didClick,
            reason: didClick ? "ok" : "inputFailed",
            screenPoint: point,
            resolvedAppName: observation.target.appName,
            controlID: control.id
        )
    }

    /// Center of a screen-space control frame (top-left origin global coordinates, as CGEvent uses).
    nonisolated static func clickPoint(for frame: WindowTargetBounds) -> CGPoint {
        CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
    }
}
