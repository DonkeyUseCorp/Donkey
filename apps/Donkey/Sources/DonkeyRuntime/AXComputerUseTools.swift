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

    private let appName: String
    private let bundleIdentifier: String?

    public init(appName: String, bundleIdentifier: String?) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
    }

    public static var descriptors: [HarnessToolDescriptor] {
        [
            HarnessToolDescriptor(
                name: ToolName.observe,
                pluginID: "core.computer-use.ax",
                summary: "Read the frontmost app's Accessibility tree and return its actionable controls. Fast and structured; prefer this for native apps.",
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
        guard await TargetFocusRecovery.ensureFrontmost(processID: pid_t(target.processID)) else {
            return result(
                context,
                status: .failed,
                summary: "\(appName) is not frontmost; \(TargetFocusRecovery.frontmostAppName()) is in front and refocusing failed.",
                reason: "targetNotFrontmost"
            )
        }
        let label = element.label.isEmpty ? elementID : element.label
        let button: MacPointerInput.Button = context.call.input["button"] == "right" ? .right : .left
        let clicks = context.call.input["clicks"].flatMap(Int.init) ?? 1

        // Prefer a native Accessibility press (AXPress): it activates the control directly, so it works
        // even when a coordinate click would miss (partially obscured, scrolled, zero-size hit area).
        // Falls back to a guarded coordinate click on the element's frame center when AX press isn't
        // available (no bundle id, control doesn't support AXPress) or doesn't land. Right-clicks and
        // multi-clicks have no AX action equivalent, so they always take the coordinate path.
        if button == .left, clicks == 1,
           let bundleIdentifier, !bundleIdentifier.isEmpty, element.actions.contains("AXPress"),
           await axPress(nodeID: element.id, bundleIdentifier: bundleIdentifier) {
            return clickSucceeded(context, elementID: elementID, label: label, strategy: "ax-press", point: nil)
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

    /// Performs an `AXPress` on the control identified by `nodeID` via the Accessibility action backend,
    /// which re-checks that `bundleIdentifier` is the frontmost app before acting. Returns whether the
    /// press landed.
    private func axPress(nodeID: String, bundleIdentifier: String) async -> Bool {
        let command = ActionEngineCommand(
            id: UUID().uuidString,
            traceID: "ax-click",
            targetID: nodeID,
            kind: .tap,
            issuedAt: RunTraceTimestamp(
                wallClock: Date(),
                monotonicUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            ),
            metadata: [
                "accessibility.nodeID": nodeID,
                "accessibility.action": "AXPress",
                "bundleIdentifier": bundleIdentifier,
                "controlID": nodeID
            ]
        )
        let outcome = await MacAccessibilityActionEngineInputBackend().execute(command)
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
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .succeeded,
            summary: strategy == "ax-press" ? "Pressed \(label) via Accessibility." : "Clicked \(label).",
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
