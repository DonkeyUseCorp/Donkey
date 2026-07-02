@preconcurrency import ApplicationServices
import CoreGraphics
import DonkeyContracts
import Foundation
import OSLog

/// Low-level keyboard input via CGEvent. Real input — gate behind explicit permission/guards.
///
/// Each entry point takes an optional `target`: with none (the default) the event posts to the HID tap
/// and lands on the frontmost app, exactly as before; with a background `InputTarget` it is delivered to
/// that process WITHOUT moving the cursor or stealing focus — via the SkyLight bridge when available,
/// else the public per-process post.
public enum MacKeyboardInput {
    /// Types arbitrary text by posting per-character unicode key events.
    public static func type(_ text: String, target: InputTarget? = nil) {
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
            post(down, to: target)
            post(up, to: target)
        }
    }

    /// Posts a Return keypress (virtual key 36).
    public static func pressReturn(target: InputTarget? = nil) {
        pressKey("return", target: target)
    }

    /// Posts a single named key (return, escape, tab, arrows, letters, …), optionally chorded with
    /// modifiers (e.g. Cmd+C). Unknown unmodified names that look like a single character are typed
    /// as text rather than silently firing the wrong key; truly unknown multi-char names fall back
    /// to Return so a "submit"-style intent still does something sane.
    public static func pressKey(_ name: String, modifiers: [String] = [], target: InputTarget? = nil) {
        let normalized = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let flags = eventFlags(for: modifiers)
        guard let keyCode = virtualKeyCode(for: normalized) else {
            if normalized.count == 1, flags.isEmpty {
                type(name, target: target)
            } else {
                postKey(36, flags: flags, target: target) // unknown key name → Return
            }
            return
        }
        postKey(keyCode, flags: flags, target: target)
    }

    /// Delivers a built keyboard event: to the HID tap (frontmost) when `target` is nil, otherwise to the
    /// target process cursor-neutrally — SkyLight bridge first (adds the macOS-14 auth envelope), then the
    /// public per-process post. Never the HID tap for a background target, which would warp the cursor.
    private static func post(_ event: CGEvent, to target: InputTarget?) {
        guard let target else {
            event.post(tap: .cghidEventTap)
            return
        }
        if SkyLightEventPost.shared.postKey(event, toPid: target.processID) { return }
        event.postToPid(target.processID)
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

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = [], target: InputTarget? = nil) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        if !flags.isEmpty {
            down.flags = flags
            up.flags = flags
        }
        post(down, to: target)
        post(up, to: target)
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
///
/// Each entry point takes an optional `target`: with none (the default) events post to the HID tap and
/// the real cursor moves to the point, exactly as before; with a background `InputTarget` the leading
/// cursor move is skipped and events are delivered to that process cursor-neutrally — via the SkyLight
/// bridge (which stamps a window-local hit-test point) when available, else the public per-process post.
public enum MacPointerInput {
    public enum Button: String, Sendable {
        case left
        case right
        case center
    }

    /// Moves the pointer to a screen point without clicking (foreground: warps the real cursor;
    /// background: a pid-routed move that never warps the user's cursor). Mirrors the leading move the
    /// click/scroll/drag helpers perform, exposed on its own for a hover/move action.
    @discardableResult
    public static func move(to point: CGPoint, target: InputTarget? = nil) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        guard let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            return false
        }
        post(event, screenPoint: point, to: target)
        return true
    }

    @discardableResult
    public static func moveAndClick(at point: CGPoint, button: Button = .left, clickCount: Int = 1, target: InputTarget? = nil) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        // Foreground moves the real cursor to the point first; background delivery is pid-routed and
        // never warps the cursor, so the move is skipped.
        if target == nil {
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        let mouseButton: CGMouseButton
        let downType: CGEventType
        let upType: CGEventType
        switch button {
        case .left:
            mouseButton = .left; downType = .leftMouseDown; upType = .leftMouseUp
        case .right:
            mouseButton = .right; downType = .rightMouseDown; upType = .rightMouseUp
        case .center:
            mouseButton = .center; downType = .otherMouseDown; upType = .otherMouseUp
        }
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
            post(down, screenPoint: point, to: target)
            post(up, screenPoint: point, to: target)
        }
        return true
    }

    /// Scrolls by line deltas at a screen point (positive y scrolls up, positive x scrolls left,
    /// matching CGEvent wheel conventions). Moves the pointer there first (foreground only) so the
    /// scroll lands on the intended view.
    @discardableResult
    public static func scroll(at point: CGPoint, deltaX: Int = 0, deltaY: Int = 0, target: InputTarget? = nil) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        if target == nil {
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
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
        post(event, screenPoint: point, to: target)
        return true
    }

    /// Drags from one screen point to another: press, interpolated dragged moves so drop targets
    /// see continuous motion, then release at the destination.
    @discardableResult
    public static func drag(from start: CGPoint, to end: CGPoint, steps: Int = 16, target: InputTarget? = nil) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        if target == nil {
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left) else {
            return false
        }
        post(down, screenPoint: start, to: target)
        usleep(40_000)
        let stepCount = max(steps, 2)
        for step in 1...stepCount {
            let fraction = Double(step) / Double(stepCount)
            let point = CGPoint(
                x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction
            )
            if let dragged = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) {
                post(dragged, screenPoint: point, to: target)
            }
            usleep(8_000)
        }
        guard let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) else {
            return false
        }
        usleep(40_000)
        post(up, screenPoint: end, to: target)
        return true
    }

    /// Delivers a built mouse event: to the HID tap (frontmost, real cursor) when `target` is nil,
    /// otherwise to the target process cursor-neutrally — SkyLight bridge first (stamping the window-local
    /// hit-test point derived from the target's bounds), then the public per-process post. Never the HID
    /// tap for a background target, which would warp the user's cursor to the point.
    private static func post(_ event: CGEvent, screenPoint: CGPoint, to target: InputTarget?) {
        guard let target else {
            event.post(tap: .cghidEventTap)
            return
        }
        let windowLocalPoint = CGPoint(
            x: screenPoint.x - target.bounds.x,
            y: screenPoint.y - target.bounds.y
        )
        if SkyLightEventPost.shared.postMouse(
            event,
            toPid: target.processID,
            windowID: target.windowID,
            windowLocalPoint: windowLocalPoint
        ) { return }
        event.postToPid(target.processID)
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

    /// The AX window whose on-screen position matches `bounds` — so a scroll acts on the window the run is
    /// actually reading when an app has several windows open at once (a sidebar list AND a detail window).
    /// Falls back to the primary window when nothing lines up.
    private static func window(of app: AXUIElement, matching bounds: WindowTargetBounds) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return primaryWindow(of: app) }
        for window in windows {
            var posValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
                  let posValue else { continue }
            var position = CGPoint.zero
            AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
            if abs(position.x - bounds.x) < 4, abs(position.y - bounds.y) < 4 { return window }
        }
        return primaryWindow(of: app)
    }

    /// The target window's scrollable CONTENT pane, or nil when it has none. A window can hold several
    /// scroll areas (a chat's transcript AND its one-line compose box AND a sidebar), so keep only the ones
    /// we can actually drive — those that implement the page-scroll action, or expose a settable vertical
    /// scroll bar (the fallback for AppKit apps like KakaoTalk whose scroll views don't implement the
    /// action) — then pick the one with the most readable text. That is the transcript/feed, not the
    /// compose field or a thin sidebar.
    private static func pageScrollArea(processID: pid_t, windowBounds: WindowTargetBounds) -> AXUIElement? {
        let app = AXUIElementCreateApplication(processID)
        guard let window = window(of: app, matching: windowBounds) else { return nil }
        let scrollable = descendants(of: window, role: kAXScrollAreaRole as String, limit: 30).filter { area in
            advertisesPageScroll(area) || verticalScrollBar(of: area) != nil
        }
        return scrollable.max { scrollAreaTextLineCount($0) < scrollAreaTextLineCount($1) }
    }

    private static func advertisesPageScroll(_ area: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(area, &names) == .success, let list = names as? [String] else { return false }
        return list.contains("AXScrollUpByPage") && list.contains("AXScrollDownByPage")
    }

    /// The scroll area's vertical scroll bar, whose `AXValue` (0 = top … 1 = bottom) is settable even when
    /// the scroll area's own page-scroll action isn't implemented. Prefers the bar explicitly marked
    /// vertical, else the only bar present.
    private static func verticalScrollBar(of area: AXUIElement) -> AXUIElement? {
        let bars = children(area).filter { axString($0, kAXRoleAttribute as CFString) == (kAXScrollBarRole as String) }
        return bars.first { axString($0, kAXOrientationAttribute as CFString) == (kAXVerticalOrientationValue as String) } ?? bars.first
    }

    /// The target window's page-scrollable Accessibility scroll area, resolved ONCE so a scroll loop can
    /// act on the same handle every pass instead of re-walking the whole tree each time. Nil when the
    /// window exposes none — the caller then falls back to a synthetic wheel event. Whether this is
    /// non-nil is also the deciding fact for whether a background read can stay off the foreground.
    public static func pageScrollAreaHandle(processID: pid_t, windowBounds: WindowTargetBounds) -> AXUIElement? {
        pageScrollArea(processID: processID, windowBounds: windowBounds)
    }

    /// Scrolls a resolved scroll area one page, staying fully in the background (no frontmost requirement,
    /// no cursor). Prefers the native `AXScrollUpByPage`/`AXScrollDownByPage` action where the scroll view
    /// implements it; otherwise steps the vertical scroll bar's value (0 = top … 1 = bottom) by a fraction
    /// of the range so consecutive reads overlap. Many AppKit apps (KakaoTalk) advertise the page-scroll
    /// action but don't implement it — it returns an error — yet accept a scroll-bar value set. Returns
    /// false when it can't move (no scroll bar, or already at the edge with nothing more to load), which
    /// ends the harvest loop.
    public static func performPageScroll(_ area: AXUIElement, up: Bool) -> Bool {
        if AXUIElementPerformAction(area, (up ? "AXScrollUpByPage" : "AXScrollDownByPage") as CFString) == .success {
            return true
        }
        guard let bar = verticalScrollBar(of: area) else { return false }
        var current: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar, kAXValueAttribute as CFString, &current) == .success,
              let value = (current as? NSNumber)?.doubleValue else { return false }
        let next = up ? max(0, value - 0.2) : min(1, value + 0.2)
        guard abs(next - value) > 0.0005 else { return false }
        return AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, next as CFNumber) == .success
    }

    /// The scroll area's on-screen text in reading order (top-to-bottom, then left-to-right). Collects
    /// static text (timestamps, sender names), TEXT AREAS (where chat apps like KakaoTalk put the actual
    /// message body — NOT static text), and link titles, so a transcript reads as real content rather than
    /// just its chrome. Walks the content pane directly and deeply, so a message nested far below the
    /// window root isn't cut the way the shallow whole-window snapshot is.
    public static func scrollAreaTextLines(_ area: AXUIElement) -> [String] {
        struct Positioned { var y: Double; var x: Double; var text: String }
        var collected: [Positioned] = []
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth <= 22, collected.count <= 4000 else { return }
            for child in children(element) {
                let role = axString(child, kAXRoleAttribute as CFString) ?? ""
                let text: String?
                if role == (kAXStaticTextRole as String) || role == (kAXTextAreaRole as String) || role == (kAXTextFieldRole as String) {
                    text = axString(child, kAXValueAttribute as CFString)
                } else if role == "AXLink" {
                    text = axString(child, kAXTitleAttribute as CFString) ?? axString(child, kAXValueAttribute as CFString)
                } else {
                    text = nil
                }
                if let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                    let frame = elementFrame(child)
                    collected.append(Positioned(y: frame?.y ?? 0, x: frame?.x ?? 0, text: trimmed))
                }
                walk(child, depth: depth + 1)
            }
        }
        walk(area, depth: 0)
        return collected
            .sorted { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }
            .map(\.text)
    }

    /// The count of distinct content lines the scroll area exposes — the signal for whether the content it
    /// scrolls is AX-readable (a native list, a chat whose bubbles are text areas) or drawn outside the
    /// tree (a canvas), which decides AX vs. vision reading. Counts the same text roles `scrollAreaTextLines`
    /// reads, so a transcript whose bodies are text areas isn't mistaken for empty.
    public static func scrollAreaTextLineCount(_ area: AXUIElement) -> Int {
        Set(scrollAreaTextLines(area)).count
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
