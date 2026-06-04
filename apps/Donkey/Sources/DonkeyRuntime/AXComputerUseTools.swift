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
                summary: "Click one control returned by ax.observe.",
                inputSchema: ["elementID": "Element ID from the latest ax.observe."],
                requiredPermissions: [.input],
                safetyClass: .guardedInput,
                requiredContext: ["frontmost target", "observed control"],
                verificationHints: ["re-observe to confirm the click changed state"]
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
        guard isFrontmost(target) else {
            return result(context, status: .failed, summary: "\(appName) is not frontmost.", reason: "targetNotFrontmost")
        }
        let label = element.label.isEmpty ? elementID : element.label

        // Prefer a native Accessibility press (AXPress): it activates the control directly, so it works
        // even when a coordinate click would miss (partially obscured, scrolled, zero-size hit area).
        // Falls back to a guarded coordinate click on the element's frame center when AX press isn't
        // available (no bundle id, control doesn't support AXPress) or doesn't land.
        if let bundleIdentifier, !bundleIdentifier.isEmpty, element.actions.contains("AXPress"),
           await axPress(nodeID: element.id, bundleIdentifier: bundleIdentifier) {
            return clickSucceeded(context, elementID: elementID, label: label, strategy: "ax-press", point: nil)
        }
        MacPointerInput.moveAndClick(at: center)
        return clickSucceeded(context, elementID: elementID, label: label, strategy: "coordinate", point: center)
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

    nonisolated static func screenCenter(from metadata: [String: String]) -> CGPoint? {
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

    private func isFrontmost(_ target: MacWindowTargetCandidate) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid_t(target.processID)
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
