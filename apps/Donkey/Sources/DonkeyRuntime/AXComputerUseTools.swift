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
    }

    /// The app this run is currently driving — shared with the vision/pointer providers and mutable when
    /// an observe step retargets it. Read per call (via the computed accessors below) so action always
    /// resolves against the app the planner last looked at, not one app pinned for the whole run.
    private let target: HarnessTargetContext
    private var appName: String { target.appName }
    private var bundleIdentifier: String? { target.bundleIdentifier }
    private let executionPreference: ExecutionPreference
    private let actionBackend: ActionEngineInputBackend

    public init(
        target: HarnessTargetContext,
        executionPreference: ExecutionPreference = .foreground,
        actionBackend: ActionEngineInputBackend = MacAccessibilityActionEngineInputBackend()
    ) {
        self.target = target
        self.executionPreference = executionPreference
        self.actionBackend = actionBackend
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
                summary: "Read the target app's Accessibility tree and return its actionable controls. Fast and structured; prefer this for native apps. Pass app=\"<App Name>\" to observe a specific app and make it the active target for the actions that follow; omit it to observe the current target.",
                inputSchema: ["app": "Optional app name to observe and switch the run's active target to; omit to use the current target."],
                optionalInputKeys: ["app"],
                outputSchema: ["elements": "Accessibility control IDs, labels, roles, and click eligibility."],
                requiredPermissions: [.accessibility],
                safetyClass: .readOnly,
                verificationHints: ["fresh observation reflects the current control state"]
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
        default:
            return result(context, status: .unknownTool, summary: "Unknown AX tool.", reason: "unknownAXTool")
        }
    }

    private func observe(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        // The planner can name an app to look at; that becomes the active target for the actions that
        // follow. This is what unbinds the run from one app — observe X, act on X; observe Y, act on Y.
        if let requested = trimmed(context.call.input["app"]) {
            retarget(to: requested)
        }
        guard !target.isEmpty else {
            return result(context, status: .failed, summary: "No active app to observe. Pass app=\"<App Name>\" to target one, or open the app first.", reason: "noActiveTarget")
        }
        guard let observation = AccessibilityObserver.observe(appName: appName, bundleIdentifier: bundleIdentifier) else {
            return result(context, status: .failed, summary: "Accessibility is unavailable for \(appName).", reason: "axUnavailable")
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
        guard element.isActionEligible, let center = Self.screenCenter(from: element.metadata) else {
            return result(context, status: .failed, summary: "Control \(elementID) cannot be clicked.", reason: "elementNotClickable")
        }
        guard let target = AccessibilityObserver.resolveTarget(appName: appName, bundleIdentifier: bundleIdentifier) else {
            return result(context, status: .failed, summary: "No window for \(appName).", reason: "noWindowForApp")
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
        if case .background(let inputTarget) = TargetActionGuard.resolve(
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
        if let bundleIdentifier, !bundleIdentifier.isEmpty,
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
        guard let target = AccessibilityObserver.resolveTarget(appName: appName, bundleIdentifier: bundleIdentifier) else {
            return result(context, status: .failed, summary: "No window for \(appName).", reason: "noWindowForApp")
        }
        let pid = pid_t(target.processID)
        guard await TargetFocusRecovery.ensureFrontmost(processID: pid) else {
            return result(
                context,
                status: .failed,
                summary: "\(appName) is not frontmost; \(TargetFocusRecovery.frontmostAppName()) is in front and refocusing failed.",
                reason: "targetNotFrontmost"
            )
        }
        // Select the row + focus its container via Accessibility (the reliable, deterministic part), then
        // also coordinate-click it: harmless when already selected, and a real click latches selection +
        // key focus if the AX select didn't take.
        guard let frame = AccessibilityActionExecutor.selectListRow(processID: pid, label: label) else {
            return result(
                context,
                status: .failed,
                summary: "No row labeled \"\(label)\" in a list/sidebar/table of \(appName). Re-observe; it may be offscreen, still syncing, or named differently.",
                reason: "rowNotFound"
            )
        }
        _ = MacPointerInput.moveAndClick(at: AccessibilityActionExecutor.clickPoint(for: frame))
        try? await Task.sleep(nanoseconds: 350_000_000)
        let modifiers = trimmed(context.call.input["modifiers"]).map { [$0] } ?? []
        MacKeyboardInput.pressKey(key, modifiers: modifiers)
        try? await Task.sleep(nanoseconds: 800_000_000)

        let chord = modifiers.first.map { "\($0)+\(key)" } ?? key
        if let confirm = trimmed(context.call.input["confirm"]) {
            AccessibilityActionExecutor.pressModalButton(processID: pid, title: confirm)
            try? await Task.sleep(nanoseconds: 800_000_000)
            if AccessibilityActionExecutor.hasModalPopup(processID: pid) {
                return result(
                    context,
                    status: .failed,
                    summary: "Pressed \(chord) on \"\(label)\" but the confirmation dialog is still open.",
                    reason: "confirmDialogStuck"
                )
            }
            return result(
                context,
                status: .succeeded,
                summary: "Selected \"\(label)\", pressed \(chord), and confirmed the \"\(confirm)\" dialog.",
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
    private func retarget(to requestedApp: String) {
        if let resolved = AccessibilityObserver.resolveTarget(appName: requestedApp, bundleIdentifier: nil) {
            target.retarget(appName: resolved.appName ?? requestedApp, bundleIdentifier: resolved.bundleIdentifier)
        } else {
            target.retarget(appName: requestedApp, bundleIdentifier: nil)
        }
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
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
