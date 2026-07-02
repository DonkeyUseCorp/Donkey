import AppKit
import CoreGraphics
import DonkeyContracts
import DonkeyHarness
import Foundation

/// Accessibility computer-use tools registered into a `HarnessToolRegistry`: a "see" tool that reads
/// the frontmost app's Accessibility tree into the world model, and an "act" tool that clicks one of
/// those elements. These are the AX counterparts to the vision tools — the harness planner chooses
/// between AX (fast, structured, native apps) and vision (any pixels) per step.
///
/// Acting clicks the AX element's reported screen frame center, guarded so the target must be
/// frontmost at the instant of the click (mirrors the vision/`VisionActionDriver` safety rule).
@MainActor
public final class AXComputerUseToolProvider {
    public enum ToolName {
        public static let observe = "ax.observe"
        public static let click = "ax.click"
        public static let selectAndPress = "ax.select_and_press"
        public static let harvest = "content.harvest"
    }

    /// Lines to advance per harvest scroll pass. Deliberately smaller than a viewport so consecutive
    /// reads overlap — de-duplication drops the overlap, and nothing between two views is skipped.
    private static let harvestScrollLines = 8

    /// A first Accessibility read yielding fewer distinct text lines than this means the app draws its
    /// content outside the AX tree (a chat transcript's bubbles, a custom-drawn list). When a vision reader
    /// is available, harvest switches to reading the pixels instead of returning chrome.
    private static let harvestAXProductiveThreshold = 8

    /// Cap on scroll passes when harvest reads through vision. Each pass is a screenshot + hosted parse
    /// (seconds, rate-limited), so the vision path is bounded tighter than the cheap AX path.
    private static let harvestMaxVisionScrolls = 6

    /// The app this run is currently driving — shared with the vision/pointer providers and mutable when
    /// an observe step retargets it. Read per call (via the computed accessors below) so action always
    /// resolves against the app the planner last looked at, not one app pinned for the whole run.
    private let target: HarnessTargetContext
    private var appName: String { target.appName }
    private var bundleIdentifier: String? { target.bundleIdentifier }
    private let executionPreference: ExecutionPreference
    private let actionBackend: ActionEngineInputBackend
    /// Reads the current target window's visible text through vision (screenshot + parse), for
    /// `content.harvest` to fall back on when the Accessibility tree is too thin to hold the content.
    /// Injected by the run so this module needn't depend on the vision stack; nil leaves harvest AX-only.
    private let visionTextReader: (@MainActor () async -> [String])?

    public init(
        target: HarnessTargetContext,
        executionPreference: ExecutionPreference = .foreground,
        actionBackend: ActionEngineInputBackend = MacAccessibilityActionEngineInputBackend(),
        visionTextReader: (@MainActor () async -> [String])? = nil
    ) {
        self.target = target
        self.executionPreference = executionPreference
        self.actionBackend = actionBackend
        self.visionTextReader = visionTextReader
    }

    /// The semantic AX action to attempt for a click gesture, or nil to take the coordinate path. Gated
    /// on the control advertising the action so we never claim a press that the control can't perform.
    /// Right-click maps to the context-menu action and double-click to open; single left-click keeps the
    /// existing press. Triple-clicks and unadvertised gestures fall through to coordinates.
    nonisolated static func semanticAction(
        button: MacPointerInput.Button,
        clicks: Int,
        advertised: Set<String>
    ) -> String? {
        switch (button, clicks) {
        case (.right, _): return advertised.contains("AXShowMenu") ? "AXShowMenu" : nil
        case (.left, 2): return advertised.contains("AXOpen") ? "AXOpen" : nil
        case (.left, 1): return advertised.contains("AXPress") ? "AXPress" : nil
        default: return nil
        }
    }

    public static var descriptors: [HarnessToolDescriptor] {
        [
            HarnessToolDescriptor(
                name: ToolName.observe,
                pluginID: "core.computer-use.ax",
                summary: "Read the target app's Accessibility tree and return its actionable controls. Fast and structured; prefer this for native apps. Pass app=\"<App Name>\" to observe a specific app and make it the active target for the actions that follow; omit it to observe the current target. Pass window=\"<title text>\" when the app has more than one window open (a chat app's contact list AND a conversation window) to pin the one whose title matches — every later act/scroll/read then resolves that window, not whichever is frontmost.",
                inputSchema: [
                    "app": "Optional app name to observe and switch the run's active target to; omit to use the current target.",
                    "window": "Optional window title (or a distinctive part of it, e.g. a person's name) to pin a specific window when the app has several open; sticks to the target for the following steps."
                ],
                optionalInputKeys: ["app", "window"],
                outputSchema: ["elements": "Accessibility control IDs, labels, roles, and click eligibility."],
                requiredPermissions: [.accessibility],
                safetyClass: .readOnly,
                verificationHints: ["fresh observation reflects the current control state"],
                // A screen read reflects live state that changes on its own, so the run's read cache must
                // never serve a prior observation — re-observing is the whole point of calling it again.
                metadata: [HarnessToolDescriptor.volatileResultMetadataKey: "true"]
            ),
            HarnessToolDescriptor(
                name: ToolName.click,
                pluginID: "core.computer-use.ax",
                summary: "Click one control returned by ax.observe. Supports right-click (context menus) and double/triple click.",
                inputSchema: [
                    "elementID": "Element ID from the latest ax.observe.",
                    "button": "\"left\" (default) or \"right\" for a context menu.",
                    "clicks": "1 (default), 2 (double-click), or 3 (triple-click)."
                ],
                optionalInputKeys: ["button", "clicks"],
                requiredPermissions: [.input],
                safetyClass: .guardedInput,
                requiredContext: ["frontmost target", "observed control"],
                verificationHints: ["re-observe to confirm the click changed state"]
            ),
            HarnessToolDescriptor(
                name: ToolName.selectAndPress,
                pluginID: "core.computer-use.ax",
                summary: "Select a named list/sidebar/table row and press a key on it — ATOMICALLY in one call, so the keypress lands while the row still holds selection and keyboard focus. Doing this as separate observe/click/press steps loses that focus and the key hits nothing. Use it for keyboard-driven row actions in any app: delete a row (key=delete), open it (key=return), or move a file to Trash (key=delete, modifiers=command). Pass confirm=<button title> to also press a confirmation dialog's button that appears afterward (e.g. confirm=Delete). Find the exact row text with ax.observe first if unsure. Re-observe after to verify the effect.",
                inputSchema: [
                    "label": "Exact visible text of the list/sidebar/table row to act on.",
                    "key": "Key to press once the row is selected (e.g. delete, return).",
                    "modifiers": "Optional modifier for the key (e.g. command).",
                    "confirm": "Optional title of a confirmation-dialog button to press afterward (e.g. Delete, OK)."
                ],
                optionalInputKeys: ["modifiers", "confirm"],
                requiredPermissions: [.input],
                safetyClass: .guardedInput,
                requiredContext: ["frontmost target"],
                verificationHints: ["re-observe to confirm the row is gone / the action took effect"]
            ),
            HarnessToolDescriptor(
                name: ToolName.harvest,
                pluginID: "core.computer-use.ax",
                summary: "Read content that spans MORE than one screen — a chat transcript, a long feed, a scrolling list — in a single call. It reads the visible on-screen text (the Accessibility text, or the pixels via OCR when the app draws its own content that isn't in the Accessibility tree) and scrolls, over and over, collecting the distinct lines it sees, so you don't loop observe/scroll/observe yourself (each of which costs a planning step). It scrolls through the app's own scroll view where it can, so the read stays in the background. Use direction=up for older history (a chat backlog above the newest message), down for later content. Returns the gathered text; read it directly.",
                inputSchema: [
                    "direction": "\"up\" to gather older/earlier content (e.g. chat history above the newest message), or \"down\" for later content. Default \"up\".",
                    "maxItems": "Stop once this many distinct text lines are collected (default 60). Ask for a little more than you need and pick from the result.",
                    "maxScrolls": "Cap on scroll passes before returning what was gathered so far (default 20).",
                    "window": "Optional window title (or a distinctive part of it, e.g. a person's name) to read when the app has more than one window open — a chat's conversation window vs. its contact list. Without it the read uses whatever window the run last pinned, else the app's first.",
                    "elementID": "Observed element to scroll at (the scrolling pane), when a specific region must receive the scroll; omit for the window center."
                ],
                optionalInputKeys: ["direction", "maxItems", "maxScrolls", "window", "elementID"],
                outputSchema: ["text": "The distinct text lines gathered across the scroll; most-recent first when direction=up."],
                requiredPermissions: [.accessibility, .input],
                safetyClass: .guardedInput,
                requiredContext: ["a resolved target window"],
                verificationHints: ["the returned text is the gathered content; read it directly rather than re-scrolling"],
                // A scrolling read reflects live state and moves the view, so the run's read cache must
                // never serve a prior harvest — re-harvesting is the whole point of calling it again.
                metadata: [HarnessToolDescriptor.volatileResultMetadataKey: "true"]
            )
        ]
    }

    public func makeTools() -> [HarnessTool] {
        Self.descriptors.map { descriptor in
            HarnessTool(descriptor: descriptor) { context in
                await self.execute(context)
            }
        }
    }

    private func execute(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        switch context.call.name {
        case ToolName.observe: return observe(context)
        case ToolName.click: return await click(context)
        case ToolName.selectAndPress: return await selectAndPress(context)
        case ToolName.harvest: return await harvest(context)
        default:
            return result(context, status: .unknownTool, summary: "Unknown AX tool.", reason: "unknownAXTool")
        }
    }

    private func observe(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        // The planner can name an app to look at; that becomes the active target for the actions that
        // follow. This is what unbinds the run from one app — observe X, act on X; observe Y, act on Y.
        // It can also name a specific window (a conversation, a document) so a multi-window app resolves
        // the right one; that pin sticks to the target for the later act/scroll steps.
        if let requested = trimmed(context.call.input["app"]) {
            retarget(to: requested, window: trimmed(context.call.input["window"]))
        }
        guard !target.isEmpty else {
            return result(context, status: .failed, summary: "No active app to observe. Pass app=\"<App Name>\" to target one, or open the app first.", reason: "noActiveTarget")
        }
        guard let observation = AccessibilityObserver.observe(appName: appName, bundleIdentifier: bundleIdentifier, windowTitleHint: target.windowTitleHint) else {
            let windowNote = target.windowTitleHint.map { " No window titled \"\($0)\" is open — open that chat/document first." } ?? ""
            return result(context, status: .failed, summary: "Accessibility is unavailable for \(appName).\(windowNote)", reason: "axUnavailable")
        }
        let worldElements = observation.controls.compactMap { Self.worldElement(from: $0) }
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .succeeded,
            summary: "Observed \(worldElements.count) Accessibility control(s) in \(appName).",
            observations: HarnessObservationDelta(
                focusedApp: observation.target.appName,
                focusedWindowTitle: observation.target.title,
                elements: worldElements,
                facts: [
                    "ax.observe.controlCount": String(worldElements.count),
                    "lastAcceptedTool": context.call.name
                ]
            ),
            metadata: ["elementCount": String(worldElements.count), "source": "accessibility"]
        )
    }

    private func click(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        guard let elementID = trimmed(context.call.input["elementID"]) else {
            return result(context, status: .invalidInput, summary: "ax.click requires an elementID.", reason: "missingElementID")
        }
        guard let element = context.worldModel.elements.first(where: { $0.id == elementID }) else {
            return result(context, status: .failed, summary: "Control \(elementID) is not in the latest observation.", reason: "elementNotFound")
        }
        // A location on screen is the only hard requirement for a click: a coordinate click lands on the
        // control's frame regardless of what the Accessibility tree reports about it. `isActionEligible`
        // (the control's AX enabled bit) gates only the SEMANTIC AX action below — it must not veto the
        // click, because apps that draw their own controls (chat rows, custom lists) report
        // an unreliable enabled bit, and returning "cannot be clicked" there dead-ends the planner into
        // escalating to a focus-stealing shell fallback.
        guard let center = Self.screenCenter(from: element.metadata) else {
            return result(context, status: .failed, summary: "Control \(elementID) has no on-screen location to click; re-observe, or use vision.click.", reason: "elementNotOnScreen")
        }
        guard let target = AccessibilityObserver.resolveTarget(appName: appName, bundleIdentifier: bundleIdentifier, windowTitleHint: target.windowTitleHint) else {
            return result(context, status: .failed, summary: noWindowSummary, reason: "noWindowForApp")
        }
        let label = element.label.isEmpty ? elementID : element.label
        let button: MacPointerInput.Button = context.call.input["button"] == "right" ? .right : .left
        let clicks = context.call.input["clicks"].flatMap(Int.init) ?? 1
        let advertised = Set(element.actions)

        // Background Accessibility action first: AXUIElementPerformAction is a focus-neutral cross-process
        // RPC, so when the turn asked for background work, the surface is safe, and the control advertises
        // a semantic action, we act without raising the app or moving the cursor. Anything the background
        // lane can't drive (no advertised action, an unsafe surface, or a foreground turn) falls through to
        // the foreground path below, which is always available.
        if element.isActionEligible,
           case .background(let inputTarget) = TargetActionGuard.resolve(
            candidate: target,
            preference: executionPreference,
            lane: .axAction
        ),
           let bundleIdentifier, !bundleIdentifier.isEmpty,
           let action = Self.semanticAction(button: button, clicks: clicks, advertised: advertised),
           await axPerform(nodeID: element.id, action: action, bundleIdentifier: bundleIdentifier, background: inputTarget) {
            return clickSucceeded(
                context,
                elementID: elementID,
                label: label,
                strategy: "ax-" + action.dropFirst(2).lowercased() + "-background",
                point: nil
            )
        }

        // COORDINATE fallback on a background turn: the control advertises no semantic action, reports
        // itself disabled, or its AX action didn't land (an opaque or custom-drawn row). A coordinate click
        // only lands on the ACTIVE app — a click posted to a backgrounded window is dropped (verified) — so
        // briefly bring the target to the front, click on the real event tap, and hand focus back. The
        // truly-background AX-action path above handled controls that expose a semantic action; this is the
        // honest fallback for the rest. If the target can't be fronted, fall through and report the blocker.
        if case .background = TargetActionGuard.resolve(
            candidate: target,
            preference: executionPreference,
            lane: .pidEventPost
        ) {
            let clicked = await TargetFocusRecovery.withForeground(processID: pid_t(target.processID), restore: true) { () -> Bool in
                MacPointerInput.moveAndClick(at: center, button: button, clickCount: clicks, target: nil)
                return true
            }
            if clicked == true {
                return clickSucceeded(context, elementID: elementID, label: label, strategy: "coordinate-focus-restore", point: center)
            }
        }

        // Foreground path (unchanged behavior): activate the target, then prefer a native Accessibility
        // action — it works even when a coordinate click would miss (partially obscured, scrolled,
        // zero-size hit area) — and fall back to a guarded coordinate click on the frame center when no
        // semantic action applies, there's no bundle id, or the AX action doesn't land.
        guard await TargetFocusRecovery.ensureFrontmost(processID: pid_t(target.processID)) else {
            return result(
                context,
                status: .failed,
                summary: "\(appName) is not frontmost; \(TargetFocusRecovery.frontmostAppName()) is in front and refocusing failed.",
                reason: "targetNotFrontmost"
            )
        }
        if element.isActionEligible,
           let bundleIdentifier, !bundleIdentifier.isEmpty,
           let action = Self.semanticAction(button: button, clicks: clicks, advertised: advertised),
           await axPerform(nodeID: element.id, action: action, bundleIdentifier: bundleIdentifier, background: nil) {
            return clickSucceeded(
                context,
                elementID: elementID,
                label: label,
                strategy: "ax-" + action.dropFirst(2).lowercased(),
                point: nil
            )
        }
        MacPointerInput.moveAndClick(at: center, button: button, clickCount: clicks)
        return clickSucceeded(context, elementID: elementID, label: label, strategy: "coordinate", point: center)
    }

    /// Atomically selects a named list/sidebar/table row and presses a key on it (optionally confirming
    /// a dialog) — the general, app-agnostic version of "delete the selected row". Splitting select and
    /// keypress across separate planner steps loses the row's keyboard focus (the app re-activates, the
    /// overlay takes key focus), so the key lands nowhere; doing both here, with no step gap, mirrors a
    /// real user. Works for any app's list UI (playlists, notes, mail, files); grids/collections aren't
    /// row-based and aren't covered.
    private func selectAndPress(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        guard let label = trimmed(context.call.input["label"]) else {
            return result(context, status: .invalidInput, summary: "ax.select_and_press requires the row's `label`.", reason: "missingLabel")
        }
        guard let key = trimmed(context.call.input["key"]) else {
            return result(context, status: .invalidInput, summary: "ax.select_and_press requires a `key` to press.", reason: "missingKey")
        }
        guard let target = AccessibilityObserver.resolveTarget(appName: appName, bundleIdentifier: bundleIdentifier, windowTitleHint: target.windowTitleHint) else {
            return result(context, status: .failed, summary: noWindowSummary, reason: "noWindowForApp")
        }
        let pid = pid_t(target.processID)
        // Select the row + focus its container via Accessibility (cross-process, no front needed) first;
        // that part is a reliable background RPC.
        guard let frame = AccessibilityActionExecutor.selectListRow(processID: pid, label: label) else {
            return result(
                context,
                status: .failed,
                summary: "No row labeled \"\(label)\" in a list/sidebar/table of \(appName). Re-observe; it may be offscreen, still syncing, or named differently.",
                reason: "rowNotFound"
            )
        }
        let clickPoint = AccessibilityActionExecutor.clickPoint(for: frame)
        let modifiers = trimmed(context.call.input["modifiers"]).map { [$0] } ?? []
        let confirm = trimmed(context.call.input["confirm"])
        let chord = modifiers.first.map { "\($0)+\(key)" } ?? key
        // The click that latches selection and the keypress only land on the ACTIVE app, so run them with
        // the target briefly fronted, then hand focus back on a background turn. The click is harmless when
        // the row is already selected; it latches key focus if the AX select didn't take, and the keypress
        // rides the same window while the row still holds focus.
        let outcome = await TargetFocusRecovery.withForeground(
            processID: pid,
            restore: executionPreference == .background
        ) { () async -> (confirmStuck: Bool, confirmed: Bool) in
            _ = MacPointerInput.moveAndClick(at: clickPoint, target: nil)
            try? await Task.sleep(nanoseconds: 350_000_000)
            MacKeyboardInput.pressKey(key, modifiers: modifiers, target: nil)
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let confirm else { return (false, false) }
            AccessibilityActionExecutor.pressModalButton(processID: pid, title: confirm)
            try? await Task.sleep(nanoseconds: 800_000_000)
            let stuck = AccessibilityActionExecutor.hasModalPopup(processID: pid)
            return (stuck, !stuck)
        }
        guard let outcome else {
            return result(
                context,
                status: .failed,
                summary: "\(appName) could not be brought to the front to act on \"\(label)\"; \(TargetFocusRecovery.frontmostAppName()) is in front.",
                reason: "targetNotFrontmost"
            )
        }
        if outcome.confirmStuck {
            return result(
                context,
                status: .failed,
                summary: "Pressed \(chord) on \"\(label)\" but the confirmation dialog is still open.",
                reason: "confirmDialogStuck"
            )
        }
        if outcome.confirmed {
            return result(
                context,
                status: .succeeded,
                summary: "Selected \"\(label)\", pressed \(chord), and confirmed the \"\(confirm ?? "")\" dialog.",
                reason: "actedAndConfirmed"
            )
        }
        return result(
            context,
            status: .succeeded,
            summary: "Selected \"\(label)\" and pressed \(chord).",
            reason: "acted"
        )
    }

    /// Reads content that spans more than one screen in a single call by alternating an Accessibility read
    /// with a scroll, collecting the distinct text lines it sees. This collapses what would otherwise be
    /// many observe/scroll planning steps — each a full model round-trip — into one tool call: the scroll
    /// and re-read happen locally, and only the assembled text goes back to the planner. Consecutive views
    /// overlap (the scroll advances less than a viewport) so de-duplication drops the overlap without
    /// skipping anything between two reads. Stops at `maxItems`, at `maxScrolls`, or when two passes in a
    /// row surface nothing new (the end of the content).
    private func harvest(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        guard !target.isEmpty else {
            return result(context, status: .failed, summary: "No active app to read. Observe an app first (ax.observe app=\"<App Name>\") or open it.", reason: "noActiveTarget")
        }
        let direction = trimmed(context.call.input["direction"])?.lowercased() ?? "up"
        guard direction == "up" || direction == "down" else {
            return result(context, status: .invalidInput, summary: "content.harvest direction must be \"up\" or \"down\".", reason: "invalidDirection")
        }
        let maxItems = max(1, min(context.call.input["maxItems"].flatMap(Int.init) ?? 60, 500))
        let maxScrolls = max(1, min(context.call.input["maxScrolls"].flatMap(Int.init) ?? 20, 40))
        // Capture the pinned window title once, before the local `target` below shadows the shared context,
        // so the probe/loop reads resolve the same window the whole harvest. An explicit window= on this
        // call pins it directly (and sticks to the target for later steps), so a harvest is self-contained
        // even without a preceding observe; otherwise inherit whatever window the run last pinned.
        let windowTitleHint: String?
        if let requestedWindow = trimmed(context.call.input["window"]) {
            target.retarget(appName: appName, bundleIdentifier: bundleIdentifier, windowTitleHint: requestedWindow)
            windowTitleHint = requestedWindow
        } else {
            windowTitleHint = target.windowTitleHint
        }

        guard let target = AccessibilityObserver.resolveTarget(appName: appName, bundleIdentifier: bundleIdentifier, windowTitleHint: windowTitleHint) else {
            return result(context, status: .failed, summary: noWindowSummary, reason: "noWindowForApp")
        }
        let scrollPoint = harvestScrollPoint(context: context, windowBounds: target.bounds)
        // CGEvent sign convention, shared with mouse.scroll: +y scrolls up, -y scrolls down.
        let deltaY = direction == "up" ? Self.harvestScrollLines : -Self.harvestScrollLines

        // Resolve the scrollable content pane ONCE. The Accessibility page-scroll action on this handle is a
        // cross-process RPC — it scrolls whether or not the app is frontmost and moves no cursor — so a read
        // through it stays fully in the background. Most AppKit lists expose such an area even when the
        // content itself is drawn outside the AX tree (a chat transcript's bubbles). When the window has
        // none, scrolling falls back to a synthetic wheel event, which a backgrounded window drops, so that
        // path briefly fronts the target and restores focus after.
        let scrollArea = AccessibilityActionExecutor.pageScrollAreaHandle(processID: pid_t(target.processID), windowBounds: target.bounds)
        let useAXScroll = scrollArea != nil

        // Choose the READ path from the CONTENT pane, not the whole window: measure the AX text inside the
        // scroll area we will actually read, so a chrome-heavy sidebar or header can't mask a content pane
        // that is drawn outside the tree. When there's a scroll area we read it directly, so the shallow
        // whole-window probe is only needed as the no-scroll-area fallback (and to prove AX is available).
        let probeControls = scrollArea == nil
            ? AccessibilityObserver.observe(appName: appName, bundleIdentifier: bundleIdentifier, windowTitleHint: windowTitleHint)?.controls
            : nil
        let probeLines = probeControls.map(Self.harvestLines(from:)) ?? []
        let contentLineCount = scrollArea.map(AccessibilityActionExecutor.scrollAreaTextLineCount) ?? probeLines.count
        let useVision = contentLineCount < Self.harvestAXProductiveThreshold && visionTextReader != nil
        if !useVision, scrollArea == nil, probeControls == nil {
            return result(context, status: .failed, summary: "Accessibility is unavailable for \(appName) and no vision reader is available. Try vision.capture.", reason: "axUnavailable")
        }
        let cap = useVision ? min(maxScrolls, Self.harvestMaxVisionScrolls) : maxScrolls
        let settle: UInt64 = useVision ? 700_000_000 : 400_000_000

        let scrollUp = direction == "up"
        let scrollStep: () -> Bool = {
            if let scrollArea {
                return AccessibilityActionExecutor.performPageScroll(scrollArea, up: scrollUp)
            }
            return MacPointerInput.scroll(at: scrollPoint, deltaX: 0, deltaY: deltaY, target: nil)
        }

        let visionReader = visionTextReader
        let harvestAppName = appName
        let harvestBundleID = bundleIdentifier
        let harvestWindowHint = windowTitleHint
        // When the content pane is an AX scroll area, read its text DIRECTLY (static text + message-body
        // text areas + links), in reading order — this is what gets a chat transcript's bubbles, which the
        // shallow whole-window snapshot misses. Present newest-first for an "up" harvest so the most-recent
        // lines survive the `maxItems` cap. Falls back to the whole-window observe when there's no scroll
        // area, and to vision only when the content isn't in the tree at all.
        let directReader: (() -> [String])? = scrollArea.map { area in
            {
                let lines = AccessibilityActionExecutor.scrollAreaTextLines(area)
                return scrollUp ? lines.reversed() : lines
            }
        }
        // The whole-window observe read was already paid for by the probe above; seed the loop with it so
        // that fallback path doesn't observe the same unchanged view twice. The direct-reader and vision
        // paths read their own first pass.
        let seedLines: [String]? = (useVision || directReader != nil) ? nil : probeLines
        let runLoop: () async -> (lines: [String], scrolls: Int) = {
            var orderedLines: [String] = []
            var seen = Set<String>()
            var scrolls = 0
            var emptyPasses = 0
            var pending = seedLines
            while true {
                let passLines: [String]
                if let seeded = pending {
                    passLines = seeded
                    pending = nil
                } else if useVision {
                    passLines = await visionReader?() ?? []
                } else if let directReader {
                    passLines = directReader()
                } else {
                    passLines = AccessibilityObserver.observe(appName: harvestAppName, bundleIdentifier: harvestBundleID, windowTitleHint: harvestWindowHint)
                        .map { Self.harvestLines(from: $0.controls) } ?? []
                }
                let before = orderedLines.count
                for text in passLines where !seen.contains(text) {
                    seen.insert(text)
                    orderedLines.append(text)
                }
                let added = orderedLines.count - before
                if orderedLines.count >= maxItems { break }
                if scrolls >= cap { break }
                // Two consecutive passes with nothing new means the scroll reached the end of the content.
                if added == 0 {
                    emptyPasses += 1
                    if emptyPasses >= 2 { break }
                } else {
                    emptyPasses = 0
                }
                guard scrollStep() else { break }
                scrolls += 1
                // Let the app render the newly revealed rows before the next read.
                try? await Task.sleep(nanoseconds: settle)
            }
            return (Array(orderedLines.prefix(maxItems)), scrolls)
        }

        // The AX-scroll path needs no focus borrow — it runs fully in the background. The synthetic
        // fallback borrows the foreground for the read and restores focus after on a background turn; it
        // returns nil only when the target could not be fronted.
        let harvested: (lines: [String], scrolls: Int)?
        if useAXScroll {
            harvested = await runLoop()
        } else {
            harvested = await TargetFocusRecovery.withForeground(
                processID: pid_t(target.processID),
                restore: executionPreference == .background,
                runLoop
            )
        }
        guard let harvested else {
            return result(
                context,
                status: .failed,
                summary: "\(appName) could not be brought to the front to read; \(TargetFocusRecovery.frontmostAppName()) is in front and refocusing failed.",
                reason: "targetNotFrontmost"
            )
        }
        let collected = harvested.lines
        let scrolls = harvested.scrolls
        let via = useVision ? " via vision" : ""
        guard !collected.isEmpty else {
            return result(
                context,
                status: .succeeded,
                summary: "Harvested no readable text from \(appName)\(via) over \(scrolls) scroll(s). The content may be images or off-screen — try vision.capture scope=screen, or the view may be empty.",
                reason: "harvestEmpty"
            )
        }
        let order = direction == "up" ? "most-recent first" : "in scroll order"
        let body = collected.joined(separator: "\n")
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .succeeded,
            summary: "Harvested \(collected.count) distinct line(s) from \(appName)\(via) over \(scrolls) scroll(s), \(order):\n\(body)",
            observations: HarnessObservationDelta(facts: [
                "lastAcceptedTool": context.call.name,
                "content.harvest.lineCount": String(collected.count)
            ]),
            metadata: ["direction": direction, "scrolls": String(scrolls), "lineCount": String(collected.count), "source": useVision ? "vision" : "accessibility"]
        )
    }

    /// The distinct-ready text lines a single Accessibility read contributes to a harvest: each control's
    /// label and value, trimmed and non-empty. The harvest loop de-duplicates across passes.
    private static func harvestLines(from controls: [LocalAppDiscoveredControl]) -> [String] {
        var lines: [String] = []
        for control in controls {
            for candidate in [control.label, control.valueSummary ?? ""] {
                let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lines.append(text) }
            }
        }
        return lines
    }

    /// The screen point a harvest scroll acts at: the observed scrolling pane when `elementID` names one,
    /// otherwise the target window's center. Mirrors mouse.scroll's targeting.
    private func harvestScrollPoint(context: HarnessToolExecutionContext, windowBounds: WindowTargetBounds) -> CGPoint {
        if let elementID = trimmed(context.call.input["elementID"]),
           let element = context.worldModel.elements.first(where: { $0.id == elementID }),
           let center = Self.screenCenter(from: element.metadata) {
            return center
        }
        return CGPoint(
            x: windowBounds.x + windowBounds.width / 2,
            y: windowBounds.y + windowBounds.height / 2
        )
    }

    /// Performs an AX `action` (e.g. `AXPress`, `AXShowMenu`, `AXOpen`) on the control identified by
    /// `nodeID` via the action backend. Foreground (`background: nil`) re-checks that `bundleIdentifier`
    /// is the frontmost app before acting; passing a pinned `background` target instead routes the RPC to
    /// that process id with no frontmost requirement. Either way the backend re-checks the live control
    /// still advertises the action. Returns whether the action landed.
    private func axPerform(
        nodeID: String,
        action: String,
        bundleIdentifier: String,
        background: InputTarget?
    ) async -> Bool {
        var metadata = [
            "accessibility.nodeID": nodeID,
            "accessibility.action": action,
            "bundleIdentifier": bundleIdentifier,
            "controlID": nodeID
        ]
        if let background {
            metadata["accessibility.executionMode"] = "background"
            metadata["accessibility.processID"] = String(background.processID)
        }
        let command = ActionEngineCommand(
            id: UUID().uuidString,
            traceID: "ax-click",
            targetID: nodeID,
            kind: .tap,
            issuedAt: RunTraceTimestamp(
                wallClock: Date(),
                monotonicUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            ),
            metadata: metadata
        )
        let outcome = await actionBackend.execute(command)
        return outcome.executed
    }

    private func clickSucceeded(
        _ context: HarnessToolExecutionContext,
        elementID: String,
        label: String,
        strategy: String,
        point: CGPoint?
    ) -> HarnessToolResult {
        var metadata = ["elementID": elementID, "label": label, "inputStrategy": strategy]
        if let point { metadata["screenPoint"] = "\(Int(point.x)),\(Int(point.y))" }
        let viaAccessibility = strategy.hasPrefix("ax-")
        let inBackground = strategy.hasSuffix("-background")
        let summary: String
        if viaAccessibility {
            summary = inBackground
                ? "Pressed \(label) via Accessibility in the background."
                : "Pressed \(label) via Accessibility."
        } else {
            summary = "Clicked \(label)."
        }
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .succeeded,
            summary: summary,
            observations: HarnessObservationDelta(facts: ["lastAcceptedTool": context.call.name]),
            metadata: metadata
        )
    }

    // MARK: - Control ⇄ world-model mapping

    /// Maps an Accessibility control into a world-model element, stashing its screen frame so a later
    /// `ax.click` can click the frame center. Returns nil for controls without a usable frame.
    nonisolated static func worldElement(from control: LocalAppDiscoveredControl) -> HarnessWorldElement? {
        guard let frame = control.frame, frame.width > 0, frame.height > 0 else { return nil }
        return HarnessWorldElement(
            id: control.id,
            label: control.label,
            role: control.role ?? control.kind.rawValue,
            isActionEligible: control.isEnabled,
            actions: control.actions.isEmpty ? ["click"] : control.actions,
            metadata: [
                "ax.frame.x": String(frame.x),
                "ax.frame.y": String(frame.y),
                "ax.frame.width": String(frame.width),
                "ax.frame.height": String(frame.height),
                "ax.kind": control.kind.rawValue,
                "ax.value": control.valueSummary ?? ""
            ]
        )
    }

    public nonisolated static func screenCenter(from metadata: [String: String]) -> CGPoint? {
        guard let x = metadata["ax.frame.x"].flatMap(Double.init),
              let y = metadata["ax.frame.y"].flatMap(Double.init),
              let width = metadata["ax.frame.width"].flatMap(Double.init),
              let height = metadata["ax.frame.height"].flatMap(Double.init),
              width > 0, height > 0 else {
            return nil
        }
        return CGPoint(x: x + width / 2, y: y + height / 2)
    }

    // MARK: - Helpers

    /// Switch the run's active target to `requestedApp`. Resolves it to a running window's exact identity
    /// when it's already open; otherwise pins it by name so a re-observe after the planner launches it
    /// resolves cleanly (this observe then reports "no window" rather than acting on the wrong app).
    private func retarget(to requestedApp: String, window: String? = nil) {
        if let resolved = AccessibilityObserver.resolveTarget(appName: requestedApp, bundleIdentifier: nil) {
            target.retarget(appName: resolved.appName ?? requestedApp, bundleIdentifier: resolved.bundleIdentifier, windowTitleHint: window)
        } else {
            target.retarget(appName: requestedApp, bundleIdentifier: nil, windowTitleHint: window)
        }
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// The failure line when no target window resolves. When a specific window was pinned but isn't open,
    /// say so and point the planner at opening it, rather than the generic "no window" that reads as the
    /// whole app being gone.
    private var noWindowSummary: String {
        if let hint = target.windowTitleHint, !hint.isEmpty {
            return "No window titled \"\(hint)\" in \(appName). Open that chat/document first (e.g. double-click it in the list), then retry."
        }
        return "No window for \(appName)."
    }

    private func result(
        _ context: HarnessToolExecutionContext,
        status: HarnessToolResultStatus,
        summary: String,
        reason: String
    ) -> HarnessToolResult {
        HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: status,
            summary: summary,
            metadata: ["reason": reason]
        )
    }
}
