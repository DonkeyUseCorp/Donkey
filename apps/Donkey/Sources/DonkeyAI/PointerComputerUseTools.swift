import AppKit
import CoreGraphics
import DonkeyContracts
import DonkeyHarness
import DonkeyRuntime
import Foundation

/// Pointer computer-use tools that act on elements from EITHER observation source — scroll a view
/// and drag one element onto another. They resolve an element's screen point from whatever geometry
/// the observation stashed (`ax.frame.*` screen points, or `vision.bbox.*` capture pixels mapped
/// through the window's current bounds), so the planner scrolls and drags the same elements it sees,
/// regardless of how it saw them.
///
/// Safety mirrors the click tools: every action re-checks the target is frontmost at the instant of
/// input, and acts only on observed, action-eligible elements.
@MainActor
public final class PointerComputerUseToolProvider {
    public enum ToolName {
        public static let scroll = "mouse.scroll"
        public static let drag = "mouse.drag"
    }

    /// The app this run is currently driving — shared with the AX/vision providers and mutable when an
    /// observe step retargets it. Read per call so a scroll/drag follows to the app the planner last
    /// observed; the pointer tools never retarget themselves (they act on whatever was just observed).
    private let target: HarnessTargetContext
    private var appName: String { target.appName }
    private var bundleIdentifier: String? { target.bundleIdentifier }
    private let executionPreference: ExecutionPreference

    public init(
        target: HarnessTargetContext,
        executionPreference: ExecutionPreference = .foreground
    ) {
        self.target = target
        self.executionPreference = executionPreference
    }

    public static var descriptors: [HarnessToolDescriptor] {
        [
            HarnessToolDescriptor(
                name: ToolName.scroll,
                pluginID: "core.computer-use.pointer",
                summary: "Scroll the frontmost window — to reach list items, page content, or controls that are below or above what was observed. Scrolls at an observed element when elementID is given, else at the window center.",
                inputSchema: [
                    "direction": "\"up\", \"down\", \"left\", or \"right\" — down reveals content further below.",
                    "amount": "How many lines to scroll (default 5). Use a larger number to move a full page.",
                    "elementID": "Observed element to scroll at, when a specific pane must receive the scroll."
                ],
                optionalInputKeys: ["amount", "elementID"],
                requiredPermissions: [.input],
                safetyClass: .guardedInput,
                requiredContext: ["frontmost target"],
                verificationHints: ["re-observe to confirm new content scrolled into view"]
            ),
            HarnessToolDescriptor(
                name: ToolName.drag,
                pluginID: "core.computer-use.pointer",
                summary: "Drag one observed element onto another (reorder items, move files, adjust sliders by dragging the knob to a target).",
                inputSchema: [
                    "fromElementID": "Observed element to pick up.",
                    "toElementID": "Observed element to drop it on."
                ],
                requiredPermissions: [.input],
                safetyClass: .guardedInput,
                requiredContext: ["frontmost target", "observed elements"],
                verificationHints: ["re-observe to confirm the drop landed"]
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
        case ToolName.scroll: return await scroll(context)
        case ToolName.drag: return await drag(context)
        default:
            return result(context, status: .unknownTool, summary: "Unknown pointer tool.", reason: "unknownPointerTool")
        }
    }

    private func scroll(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        let direction = context.call.input["direction"]?.lowercased() ?? ""
        guard ["up", "down", "left", "right"].contains(direction) else {
            return result(context, status: .invalidInput, summary: "mouse.scroll requires direction up, down, left, or right.", reason: "invalidDirection")
        }
        guard let routing = await resolveRouting() else {
            return notFrontmost(context)
        }
        let target = routing.target
        let point: CGPoint
        if let elementID = context.call.input["elementID"], !elementID.isEmpty {
            guard let element = context.worldModel.elements.first(where: { $0.id == elementID }),
                  let resolved = Self.screenPoint(for: element, window: target.bounds) else {
                return result(context, status: .failed, summary: "Element \(elementID) has no resolvable position.", reason: "elementNotFound")
            }
            point = resolved
        } else {
            point = CGPoint(
                x: target.bounds.x + target.bounds.width / 2,
                y: target.bounds.y + target.bounds.height / 2
            )
        }
        let amount = max(1, min(context.call.input["amount"].flatMap(Int.init) ?? 5, 50))
        // Unknown direction falls back to "right", preserving the prior default branch. The sign
        // convention itself lives once in VisionComputerActionExecutor so the two scroll paths agree.
        let scrollDirection = VisionComputerAction.ScrollDirection(rawValue: direction) ?? .right
        let (deltaX, deltaY) = VisionComputerActionExecutor.scrollLineDeltas(direction: scrollDirection, lines: amount)
        MacPointerInput.scroll(at: point, deltaX: deltaX, deltaY: deltaY, target: routing.inputTarget)
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .succeeded,
            summary: "Scrolled \(direction) \(amount) line(s).",
            observations: HarnessObservationDelta(facts: ["lastAcceptedTool": context.call.name]),
            metadata: ["direction": direction, "amount": String(amount)]
        )
    }

    private func drag(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        guard let fromID = context.call.input["fromElementID"], !fromID.isEmpty,
              let toID = context.call.input["toElementID"], !toID.isEmpty else {
            return result(context, status: .invalidInput, summary: "mouse.drag requires fromElementID and toElementID.", reason: "missingElementIDs")
        }
        guard let routing = await resolveRouting() else {
            return notFrontmost(context)
        }
        let target = routing.target
        guard let fromElement = context.worldModel.elements.first(where: { $0.id == fromID }),
              let start = Self.screenPoint(for: fromElement, window: target.bounds) else {
            return result(context, status: .failed, summary: "Element \(fromID) has no resolvable position.", reason: "fromElementNotFound")
        }
        guard let toElement = context.worldModel.elements.first(where: { $0.id == toID }),
              let end = Self.screenPoint(for: toElement, window: target.bounds) else {
            return result(context, status: .failed, summary: "Element \(toID) has no resolvable position.", reason: "toElementNotFound")
        }
        MacPointerInput.drag(from: start, to: end, target: routing.inputTarget)
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .succeeded,
            summary: "Dragged \(fromElement.label.isEmpty ? fromID : fromElement.label) onto \(toElement.label.isEmpty ? toID : toElement.label).",
            observations: HarnessObservationDelta(facts: ["lastAcceptedTool": context.call.name]),
            metadata: [
                "fromElementID": fromID,
                "toElementID": toID,
                "fromPoint": "\(Int(start.x)),\(Int(start.y))",
                "toPoint": "\(Int(end.x)),\(Int(end.y))"
            ]
        )
    }

    // MARK: - Geometry

    /// Resolves an element's current screen point from whichever geometry its observation stashed.
    nonisolated static func screenPoint(for element: HarnessWorldElement, window: WindowTargetBounds) -> CGPoint? {
        if let axCenter = AXComputerUseToolProvider.screenCenter(from: element.metadata) {
            return axCenter
        }
        guard let geometry = VisionComputerUseToolProvider.geometry(from: element.metadata) else {
            return nil
        }
        let normalized = VisionComputerUseToolProvider.normalizedCenter(
            bbox: geometry.bbox,
            imageWidth: geometry.imageWidth,
            imageHeight: geometry.imageHeight
        )
        // A screen/desktop-scope element carries the display rect it was detected in; map through that,
        // matching vision.click. Falling back to the window rect would misplace a click/scroll/drag on
        // anything detected outside the front window (a modal, a menu, another monitor).
        return VisionComputerActionExecutor.screenPoint(
            VisionComputerAction.Point(x: normalized.x, y: normalized.y),
            window: geometry.region ?? window
        )
    }

    // MARK: - Helpers

    /// Resolves the target window and decides how to deliver input. On a background turn over a safe
    /// surface it returns a pinned target for cursor-neutral pid-routed delivery (no app raise);
    /// otherwise it brings the target frontmost (one recovery activation, never any other app) and
    /// returns a nil input target for the HID path. Returns nil only when a required activation failed.
    private func resolveRouting() async -> (target: MacWindowTargetCandidate, inputTarget: InputTarget?)? {
        guard let target = AccessibilityObserver.resolveTarget(appName: appName, bundleIdentifier: bundleIdentifier) else {
            return nil
        }
        switch TargetActionGuard.resolve(candidate: target, preference: executionPreference, lane: .pidEventPost) {
        case .background(let inputTarget):
            return (target, inputTarget)
        case .foreground:
            guard await TargetFocusRecovery.ensureFrontmost(processID: pid_t(target.processID)) else {
                return nil
            }
            return (target, nil)
        }
    }

    private func notFrontmost(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        result(
            context,
            status: .failed,
            summary: "\(appName) is not frontmost; \(TargetFocusRecovery.frontmostAppName()) is in front and refocusing failed.",
            reason: "targetNotFrontmost"
        )
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
