import DonkeyContracts
import DonkeyRuntime
import Foundation

/// One UI action requested by Gemini's built-in `computer_use` tool, normalized from the model's
/// native function call into a shape the executor can run. The model reports click coordinates in its
/// 0–1000 normalized space (origin top-left); `VisionComputerActionExecutor` maps them onto the
/// target window. The desktop tool emits a small, stable action vocabulary (click variants, move,
/// drag, scroll, type, key chords, wait); browser-only navigation functions are excluded server-side.
public struct VisionComputerAction: Sendable, Equatable {
    public enum ScrollDirection: String, Sendable, Equatable {
        case up, down, left, right
    }

    /// A point in the model's 0–1000 normalized image space (origin top-left).
    public struct Point: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public enum Kind: Sendable, Equatable {
        case click(button: MacPointerInput.Button, count: Int, point: Point)
        case move(point: Point)
        case drag(from: Point, to: Point)
        case scroll(point: Point?, direction: ScrollDirection, magnitude: Double?)
        case type(text: String, point: Point?, pressEnter: Bool, clearFirst: Bool)
        case keys([String])
        case wait(seconds: Double)
        /// The model returned no function call — the goal is finished; `text` is its closing summary.
        case done(text: String)
        /// A predefined function we don't run on the macOS desktop (browser navigation, etc.).
        case unsupported(name: String)
    }

    public var kind: Kind
    /// The model's own one-line `intent` for this action, when supplied.
    public var intent: String

    public init(kind: Kind, intent: String = "") {
        self.kind = kind
        self.intent = intent
    }

    /// A one-line, human-readable description (for traces and smoke-test logs).
    public var summary: String {
        let head: String
        switch kind {
        case let .click(button, count, point):
            head = "\(VisionComputerActionExecutor.clickVerb(button: button, count: count)) (\(Int(point.x)),\(Int(point.y)))"
        case let .move(point):
            head = "move (\(Int(point.x)),\(Int(point.y)))"
        case let .drag(from, to):
            head = "drag (\(Int(from.x)),\(Int(from.y)))→(\(Int(to.x)),\(Int(to.y)))"
        case let .scroll(_, direction, _):
            head = "scroll \(direction.rawValue)"
        case let .type(text, _, pressEnter, _):
            head = "type \"\(text)\"\(pressEnter ? " ⏎" : "")"
        case let .keys(keys):
            head = "keys \(keys.joined(separator: "+"))"
        case let .wait(seconds):
            head = "wait \(seconds)s"
        case .done:
            head = "done"
        case let .unsupported(name):
            head = "unsupported \(name)"
        }
        return intent.isEmpty ? head : "\(head) :: \(intent)"
    }
}

/// Configuration shared by every desktop computer-use tool declaration. The agent never drives a web
/// browser's chrome on the macOS desktop, so the browser-navigation predefined functions are excluded
/// — leaving the GUI actions (click, type, scroll, drag, key chords, …). Defined once so the
/// direct-Vertex planner and the backend desktop tool can't drift.
public enum VisionComputerDesktopTool {
    public static let excludedPredefinedFunctions = [
        "open_web_browser",
        "navigate",
        "go_back",
        "go_forward",
        "search",
    ]
}

/// A raw computer-use function call (name + arguments) pulled from a model response, before it is
/// normalized into a `VisionComputerAction`.
public struct VisionFunctionCall: Sendable, Equatable {
    public var name: String
    public var arguments: RemoteInferenceJSONObject

    public init(name: String, arguments: RemoteInferenceJSONObject) {
        self.name = name
        self.arguments = arguments
    }
}

public extension VisionComputerAction {
    /// Normalizes a raw computer-use function call into a typed action. Tolerant of the two function
    /// naming families Gemini computer use uses across model versions — the streamlined `click` /
    /// `type` / `scroll` set and the older `click_at` / `type_text_at` / `scroll_at` set — and of
    /// snake_case argument variants, so the executor sees one stable shape.
    static func from(call: VisionFunctionCall) -> VisionComputerAction {
        let name = call.name.lowercased()
        let intent = call.string("intent", "reason", "description") ?? ""

        func tagged(_ kind: Kind) -> VisionComputerAction { VisionComputerAction(kind: kind, intent: intent) }
        func clickKind(_ button: MacPointerInput.Button, _ count: Int) -> VisionComputerAction {
            guard let point = call.point() else { return tagged(.unsupported(name: call.name)) }
            return tagged(.click(button: button, count: count, point: point))
        }

        switch name {
        case "click", "click_at", "left_click", "left_click_at", "tap", "tap_at":
            return clickKind(.left, 1)
        case "double_click", "double_click_at", "doubleclick":
            return clickKind(.left, 2)
        case "triple_click", "triple_click_at":
            return clickKind(.left, 3)
        case "right_click", "right_click_at", "context_click":
            return clickKind(.right, 1)
        case "middle_click", "middle_click_at":
            return clickKind(.center, 1)
        case "move", "mouse_move", "move_to", "hover", "hover_at":
            guard let point = call.point() else { return tagged(.unsupported(name: call.name)) }
            return tagged(.move(point: point))
        case "drag", "drag_and_drop", "dragdrop":
            // gemini-3.5-flash uses start_x/start_y/end_x/end_y; the 2.5 model used x/y +
            // destination_x/destination_y — accept both.
            guard let from = call.point(["start_x", "x"], ["start_y", "y"]),
                  let to = call.point(["end_x", "destination_x", "to_x", "x2"], ["end_y", "destination_y", "to_y", "y2"])
            else { return tagged(.unsupported(name: call.name)) }
            return tagged(.drag(from: from, to: to))
        case "scroll", "scroll_at", "scroll_document", "scroll_window":
            let direction = ScrollDirection(rawValue: (call.string("direction") ?? "down").lowercased()) ?? .down
            return tagged(.scroll(
                point: call.point(),
                direction: direction,
                magnitude: call.double(["magnitude_in_pixels", "magnitude", "amount", "distance"])
            ))
        case "type", "type_text", "type_text_at", "input_text", "keyboard_type":
            let point = call.point()
            return tagged(.type(
                text: call.string("text", "value") ?? "",
                point: point,
                pressEnter: call.bool("press_enter", "enter", "submit") ?? false,
                clearFirst: call.bool("clear_before_typing", "clear") ?? (point != nil)
            ))
        case "key_combination", "hotkey", "press_key", "key", "keypress", "key_press":
            return tagged(.keys(call.keyList()))
        case "wait", "wait_5_seconds", "sleep":
            return tagged(.wait(seconds: call.double(["seconds", "duration", "duration_seconds"]) ?? defaultWaitSeconds(for: name)))
        default:
            return tagged(.unsupported(name: call.name))
        }
    }

    private static func defaultWaitSeconds(for name: String) -> Double {
        name == "wait_5_seconds" ? 5 : 1
    }
}

public enum VisionComputerResponseError: Error, CustomStringConvertible {
    /// The response carried neither a function call nor any text — an empty, safety-blocked, or
    /// truncated turn. Surfaced as an error so the driver fails the run instead of reporting the
    /// goal "done" off a model turn that produced nothing.
    case noPlan(rawPreview: String)

    public var description: String {
        switch self {
        case let .noPlan(preview): return "model returned no action and no text: \(preview.prefix(200))"
        }
    }
}

/// Pulls computer-use function calls (and any closing text) out of a model response, handling both
/// transports: the backend's normalized Responses shape (`computer_use.calls[]`, then `output[]`
/// function-call items) and the raw Vertex `generateContent` shape
/// (`candidates[].content.parts[].functionCall`).
public enum VisionComputerResponse {
    /// The single next action for one model turn: the first function call decoded into an action, or
    /// `.done` when the model finished and replied in words. Throws `noPlan` when the turn carried
    /// NEITHER a call nor text, so an empty/blocked/truncated response fails the run rather than being
    /// mistaken for completion. Shared by both planners so the two transports decode identically.
    public static func firstAction(in value: RemoteInferenceJSONValue) throws -> VisionComputerAction {
        if let call = functionCalls(in: value).first {
            return VisionComputerAction.from(call: call)
        }
        let text = outputText(in: value)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VisionComputerResponseError.noPlan(rawPreview: text)
        }
        return VisionComputerAction(kind: .done(text: text))
    }

    public static func functionCalls(in value: RemoteInferenceJSONValue) -> [VisionFunctionCall] {
        guard let object = value.objectValue else { return [] }

        if let calls = object["computer_use"]?.objectValue?["calls"]?.arrayValue {
            let parsed = calls.compactMap(hostedCall(from:))
            if !parsed.isEmpty { return parsed }
        }
        if let output = object["output"]?.arrayValue {
            let parsed = output.compactMap(outputItemCall(from:))
            if !parsed.isEmpty { return parsed }
        }
        if let candidates = object["candidates"]?.arrayValue {
            let parsed = candidates.flatMap(vertexCandidateCalls(from:))
            if !parsed.isEmpty { return parsed }
        }
        return []
    }

    /// The model's plain text — its closing "done" summary when no function call is present, or an
    /// action's narration. Thought-summary parts (Vertex) are excluded.
    public static func outputText(in value: RemoteInferenceJSONValue) -> String {
        guard let object = value.objectValue else { return "" }

        if let text = object["output_text"]?.stringValue, !text.isEmpty {
            return text
        }
        if let parts = object["candidates"]?.arrayValue?.first?
            .objectValue?["content"]?.objectValue?["parts"]?.arrayValue {
            let text = parts.compactMap { part -> String? in
                guard let partObject = part.objectValue, partObject["thought"]?.boolFlag != true else { return nil }
                return partObject["text"]?.stringValue
            }.joined(separator: "\n")
            if !text.isEmpty { return text }
        }
        if let output = object["output"]?.arrayValue {
            let text = output.compactMap { item -> String? in
                guard let itemObject = item.objectValue else { return nil }
                if let direct = itemObject["text"]?.stringValue { return direct }
                return itemObject["content"]?.arrayValue?
                    .compactMap { $0.objectValue?["text"]?.stringValue }
                    .joined()
            }.joined(separator: "\n")
            if !text.isEmpty { return text }
        }
        return ""
    }

    private static func hostedCall(from value: RemoteInferenceJSONValue) -> VisionFunctionCall? {
        guard let object = value.objectValue, let name = object["name"]?.stringValue else { return nil }
        return VisionFunctionCall(name: name, arguments: argumentsObject(object))
    }

    private static func outputItemCall(from value: RemoteInferenceJSONValue) -> VisionFunctionCall? {
        guard let object = value.objectValue,
              object["type"]?.stringValue == "function_call",
              let name = object["name"]?.stringValue
        else { return nil }
        return VisionFunctionCall(name: name, arguments: argumentsObject(object))
    }

    private static func vertexCandidateCalls(from value: RemoteInferenceJSONValue) -> [VisionFunctionCall] {
        guard let parts = value.objectValue?["content"]?.objectValue?["parts"]?.arrayValue else { return [] }
        return parts.compactMap { part -> VisionFunctionCall? in
            guard let call = part.objectValue?["functionCall"]?.objectValue
                ?? part.objectValue?["function_call"]?.objectValue,
                let name = call["name"]?.stringValue
            else { return nil }
            return VisionFunctionCall(name: name, arguments: argumentsObject(call))
        }
    }

    /// Reads the call's arguments whether they arrive under `arguments` (hosted/output) or `args`
    /// (Vertex / raw SDK).
    private static func argumentsObject(_ object: RemoteInferenceJSONObject) -> RemoteInferenceJSONObject {
        object["arguments"]?.objectValue ?? object["args"]?.objectValue ?? [:]
    }
}

/// Shared instruction text for the computer-use loop. Kept in one place so the direct-Vertex planner
/// and the hosted `createResponse` planner send the same framing; the action vocabulary itself comes
/// from the built-in tool, so this only states the goal, the current screen, prior steps, and the
/// discoverable per-app guidance (never a hardcoded app list, never fixed coordinates).
public enum VisionComputerUsePrompt {
    public static func instructions(
        goal: String,
        app: String,
        width: Int,
        height: Int,
        history: [String],
        appGuidance: String?
    ) -> String {
        let historyBlock = history.isEmpty
            ? "This is the first action; nothing has been done yet."
            : "Actions already performed, in order (do NOT repeat one that already worked):\n"
                + history.suffix(10).enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let guidanceBlock: String
        if let appGuidance, !appGuidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guidanceBlock = """


            APP-SPECIFIC OPERATING GUIDE for "\(app)" (follow it — it says where controls are and how to read state; it never gives fixed coordinates, so always read the current screenshot for exact positions):
            \(appGuidance)
            """
        } else {
            guidanceBlock = ""
        }
        return """
        You are operating the macOS app "\(app)" to accomplish a goal. Use the computer tool to act on \
        the screen, one step at a time.
        GOAL: \(goal)
        The attached screenshot is the CURRENT state of the app window (\(width) x \(height) pixels), origin top-left.

        \(historyBlock)\(guidanceBlock)

        Take the SINGLE next action that best progresses toward the goal given only what is visible now. \
        If your last action produced no visible change it missed — re-locate the target and aim at its \
        exact center rather than repeating the same spot. When the goal is fully and verifiably satisfied \
        in the current screenshot, stop and reply with a one-line confirmation instead of calling the tool.
        """
    }
}

private extension VisionFunctionCall {
    func string(_ keys: String...) -> String? {
        for key in keys {
            if let value = arguments[key]?.stringValue, !value.isEmpty { return value }
        }
        return nil
    }

    func double(_ keys: [String]) -> Double? {
        for key in keys {
            if let value = arguments[key]?.doubleNumber { return value }
        }
        return nil
    }

    func bool(_ keys: String...) -> Bool? {
        for key in keys {
            if let value = arguments[key]?.boolFlag { return value }
        }
        return nil
    }

    /// A normalized point from `x`/`y` (or the supplied key aliases). Returns nil if either axis is
    /// missing, so the decoder can reject a coordinate action that carries no target.
    func point(_ xKeys: [String] = ["x"], _ yKeys: [String] = ["y"]) -> VisionComputerAction.Point? {
        guard let x = double(xKeys), let y = double(yKeys) else { return nil }
        return VisionComputerAction.Point(x: x, y: y)
    }

    /// A key chord as an ordered list, from either an array (`keys: ["control","c"]`) or a
    /// `+`-joined string (`keys: "control+c"`), or a single `key`.
    func keyList() -> [String] {
        if let array = arguments["keys"]?.arrayValue {
            return array.compactMap { $0.stringValue }
        }
        if let joined = arguments["keys"]?.stringValue {
            return joined.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let single = arguments["key"]?.stringValue {
            return single.contains("+")
                ? single.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : [single]
        }
        if let array = arguments["key"]?.arrayValue {
            return array.compactMap { $0.stringValue }
        }
        return []
    }
}

private extension RemoteInferenceJSONValue {
    var doubleNumber: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    var boolFlag: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        case .string(let value):
            switch value.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "yes", "on", "1": return true
            case "false", "no", "off", "0": return false
            default: return nil
            }
        default: return nil
        }
    }
}
