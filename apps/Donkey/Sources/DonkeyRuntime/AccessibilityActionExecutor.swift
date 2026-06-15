@preconcurrency import ApplicationServices
import CoreGraphics
import DonkeyContracts
import Foundation
import OSLog

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

    /// Posts a single named key (return, escape, tab, arrows, letters, …), optionally chorded with
    /// modifiers (e.g. Cmd+C). Unknown unmodified names that look like a single character are typed
    /// as text rather than silently firing the wrong key; truly unknown multi-char names fall back
    /// to Return so a "submit"-style intent still does something sane.
    public static func pressKey(_ name: String, modifiers: [String] = []) {
        let normalized = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let flags = eventFlags(for: modifiers)
        guard let keyCode = virtualKeyCode(for: normalized) else {
            if normalized.count == 1, flags.isEmpty {
                type(name)
            } else {
                postKey(36, flags: flags) // unknown key name → Return
            }
            return
        }
        postKey(keyCode, flags: flags)
    }

    /// Maps typed modifier tokens (split on `+`, `,`, or whitespace) to CGEvent flags. Unknown
    /// tokens are ignored rather than guessed.
    static func eventFlags(for modifiers: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        let tokens = modifiers.flatMap {
            $0.lowercased().components(separatedBy: CharacterSet(charactersIn: "+, "))
        }
        for token in tokens {
            switch token.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "command", "cmd", "meta": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option", "opt", "alt": flags.insert(.maskAlternate)
            case "control", "ctrl": flags.insert(.maskControl)
            case "fn", "function": flags.insert(.maskSecondaryFn)
            default: break
            }
        }
        return flags
    }

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        if !flags.isEmpty {
            down.flags = flags
            up.flags = flags
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    static func virtualKeyCode(for name: String) -> CGKeyCode? {
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
        default: return ansiKeyCode(for: name)
        }
    }

    /// ANSI-layout virtual key codes for letters, digits, and common symbols, so modifier chords
    /// like Cmd+C have a concrete key to chord with.
    private static func ansiKeyCode(for name: String) -> CGKeyCode? {
        let codes: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
            "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
            "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
            "m": 46, ".": 47, "`": 50
        ]
        return codes[name]
    }
}

/// Low-level pointer input via CGEvent (move, click variants, scroll, drag at screen points). Real
/// input — callers must gate this behind explicit permission/guards.
public enum MacPointerInput {
    public enum Button: String, Sendable {
        case left
        case right
    }

    @discardableResult
    public static func moveAndClick(at point: CGPoint, button: Button = .left, clickCount: Int = 1) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        let mouseButton: CGMouseButton = button == .right ? .right : .left
        let downType: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        let clicks = min(max(clickCount, 1), 3)
        // Double/triple clicks are one down/up pair per click with an increasing click state, not
        // independent single clicks — apps key multi-click behavior off the event's click state.
        for clickState in 1...clicks {
            guard let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: mouseButton),
                  let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: mouseButton)
            else {
                return false
            }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return true
    }

    /// Scrolls by line deltas at a screen point (positive y scrolls up, positive x scrolls left,
    /// matching CGEvent wheel conventions). Moves the pointer there first so the scroll lands on
    /// the intended view.
    @discardableResult
    public static func scroll(at point: CGPoint, deltaX: Int = 0, deltaY: Int = 0) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .line,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        ) else {
            return false
        }
        event.location = point
        event.post(tap: .cghidEventTap)
        return true
    }

    /// Drags from one screen point to another: press, interpolated dragged moves so drop targets
    /// see continuous motion, then release at the destination.
    @discardableResult
    public static func drag(from start: CGPoint, to end: CGPoint, steps: Int = 16) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left) else {
            return false
        }
        down.post(tap: .cghidEventTap)
        usleep(40_000)
        let stepCount = max(steps, 2)
        for step in 1...stepCount {
            let fraction = Double(step) / Double(stepCount)
            let point = CGPoint(
                x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction
            )
            CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            usleep(8_000)
        }
        guard let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) else {
            return false
        }
        usleep(40_000)
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
        click: (CGPoint) -> Bool = { MacPointerInput.moveAndClick(at: $0) }
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

    // MARK: - Deterministic list-row deletion primitives

    private static let log = Logger(subsystem: "com.donkeyuse.Donkey", category: "ax-delete")

    /// Selects a list/outline/table row whose label matches `label`, and gives its enclosing list
    /// keyboard focus — the deterministic equivalent of a user clicking the row. Returns the row's
    /// screen frame (top-left origin) on success so the caller can also coordinate-click it. This is
    /// what a synthetic coordinate click alone fails to do reliably for AppKit sidebars: the row ends
    /// up genuinely selected AND its container holds key focus, so a following Delete key acts on it.
    public static func selectListRow(processID: pid_t, label: String) -> WindowTargetBounds? {
        let app = AXUIElementCreateApplication(processID)
        guard let window = primaryWindow(of: app) else {
            log.error("selectListRow: no window for pid \(processID)")
            return nil
        }
        guard let list = firstDescendant(of: window, role: kAXOutlineRole as String)
            ?? firstDescendant(of: window, role: kAXTableRole as String)
            ?? firstDescendant(of: window, role: kAXListRole as String) else {
            log.error("selectListRow: no outline/table/list in window")
            return nil
        }
        guard let row = matchingRow(in: list, label: label) else {
            log.error("selectListRow: no row labeled \(label, privacy: .public)")
            return nil
        }
        // Select the row and focus its container — the two halves a real click does.
        AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(list, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let frame = elementFrame(row)
        log.info("selectListRow: selected \(label, privacy: .public) frame=\(String(describing: frame), privacy: .public)")
        return frame
    }

    /// Presses (AXPress) the button titled `title` inside the app's frontmost modal — a separate dialog
    /// window (subrole `AXDialog`/`AXSystemDialog`) or an attached sheet. Music's delete confirmation has
    /// NO default button, so a Return keystroke can't dismiss it; a direct AX press is the reliable
    /// confirm. Matches only inside a modal subtree so a same-named button elsewhere can't be hit.
    @discardableResult
    public static func pressModalButton(processID: pid_t, title: String) -> Bool {
        let app = AXUIElementCreateApplication(processID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        for window in windows {
            if let button = modalButton(in: window, title: title, inModal: false, depth: 0),
               AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
                log.info("pressModalButton: pressed \(title, privacy: .public)")
                return true
            }
        }
        return false
    }

    /// True if the app has a modal popup open (separate `AXDialog`/`AXSystemDialog` window or `AXModal`).
    public static func hasModalPopup(processID: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(processID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        for window in windows {
            let subrole = axString(window, kAXSubroleAttribute as CFString)
            if subrole == (kAXDialogSubrole as String) || subrole == (kAXSystemDialogSubrole as String) {
                return true
            }
            var modal: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXModalAttribute as CFString, &modal) == .success,
               (modal as? Bool) == true { return true }
        }
        return false
    }

    // MARK: - Raw AX helpers

    private static func primaryWindow(of app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        // Prefer the standard window (skip dialogs/panels); fall back to the first window.
        return windows.first { axString($0, kAXSubroleAttribute as CFString) == (kAXStandardWindowSubrole as String) }
            ?? windows.first
    }

    private static func matchingRow(in list: AXUIElement, label: String) -> AXUIElement? {
        for row in descendants(of: list, role: kAXRowRole as String, limit: 400) {
            if rowText(row).contains(label) { return row }
        }
        return nil
    }

    /// All visible text under a row (its static texts / value), joined — so we can match by label.
    private static func rowText(_ row: AXUIElement) -> String {
        var parts: [String] = []
        if let v = axString(row, kAXValueAttribute as CFString) { parts.append(v) }
        if let t = axString(row, kAXTitleAttribute as CFString) { parts.append(t) }
        for text in descendants(of: row, role: kAXStaticTextRole as String, limit: 20) {
            if let v = axString(text, kAXValueAttribute as CFString) { parts.append(v) }
        }
        return parts.joined(separator: " ")
    }

    private static func firstDescendant(of element: AXUIElement, role: String, depth: Int = 0) -> AXUIElement? {
        guard depth < 12 else { return nil }
        for child in children(element) {
            if axString(child, kAXRoleAttribute as CFString) == role { return child }
            if let found = firstDescendant(of: child, role: role, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func descendants(of element: AXUIElement, role: String, limit: Int, depth: Int = 0, found: Int = 0) -> [AXUIElement] {
        guard depth < 14, found < limit else { return [] }
        var result: [AXUIElement] = []
        for child in children(element) {
            if axString(child, kAXRoleAttribute as CFString) == role { result.append(child) }
            if result.count + found >= limit { break }
            result.append(contentsOf: descendants(of: child, role: role, limit: limit, depth: depth + 1, found: found + result.count))
            if result.count + found >= limit { break }
        }
        return result
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let kids = value as? [AXUIElement] else { return [] }
        return kids
    }

    private static func elementFrame(_ element: AXUIElement) -> WindowTargetBounds? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let posValue, let sizeValue,
              CFGetTypeID(posValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        return WindowTargetBounds(x: Double(point.x), y: Double(point.y), width: Double(size.width), height: Double(size.height))
    }

    private static func modalButton(in element: AXUIElement, title: String, inModal: Bool, depth: Int) -> AXUIElement? {
        guard depth < 8 else { return nil }
        let role = axString(element, kAXRoleAttribute as CFString)
        let subrole = axString(element, kAXSubroleAttribute as CFString)
        let nowModal = inModal
            || role == (kAXSheetRole as String)
            || subrole == (kAXDialogSubrole as String)
            || subrole == (kAXSystemDialogSubrole as String)
        if nowModal, role == (kAXButtonRole as String), axString(element, kAXTitleAttribute as CFString) == title {
            return element
        }
        for child in children(element) {
            if let found = modalButton(in: child, title: title, inModal: nowModal, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }
}
