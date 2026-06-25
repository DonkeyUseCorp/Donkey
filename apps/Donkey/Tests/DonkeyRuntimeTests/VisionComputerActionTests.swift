import DonkeyContracts
import Foundation
import Testing

@testable import DonkeyAI

/// Decoding Gemini computer-use responses into typed `VisionComputerAction`s, across both transports
/// (raw Vertex `candidates[].content.parts[].functionCall` and the backend's normalized
/// `computer_use.calls[]` / `output[]`) and both function-naming families the model uses.
struct VisionComputerActionTests {
    private func decode(_ json: String) -> RemoteInferenceJSONValue {
        try! JSONDecoder().decode(RemoteInferenceJSONValue.self, from: Data(json.utf8))
    }

    private func firstAction(_ json: String) -> VisionComputerAction? {
        guard let call = VisionComputerResponse.functionCalls(in: decode(json)).first else { return nil }
        return VisionComputerAction.from(call: call)
    }

    @Test func vertexClickAtFunctionCall() {
        let action = firstAction("""
        {"candidates":[{"content":{"parts":[
          {"functionCall":{"name":"click_at","args":{"x":500,"y":250,"intent":"tap play"}}}
        ]}}]}
        """)
        guard case let .click(button, count, point) = action?.kind else {
            Issue.record("expected click, got \(String(describing: action?.kind))"); return
        }
        #expect(button == .left)
        #expect(count == 1)
        #expect(point.x == 500 && point.y == 250)
        #expect(action?.intent == "tap play")
    }

    @Test func hostedTypeTextAtFunctionCall() {
        let action = firstAction("""
        {"computer_use":{"registered_tools":["donkey_gemini_mac_desktop_interaction"],"calls":[
          {"name":"type_text_at","arguments":{"x":100,"y":200,"text":"hello","press_enter":true}}
        ]}}
        """)
        guard case let .type(text, point, pressEnter, clearFirst) = action?.kind else {
            Issue.record("expected type, got \(String(describing: action?.kind))"); return
        }
        #expect(text == "hello")
        #expect(point?.x == 100 && point?.y == 200)
        #expect(pressEnter)
        #expect(clearFirst) // type_text_at carries coordinates, so it defaults to clearing the field
    }

    @Test func plainTypeDoesNotClear() {
        let action = firstAction("""
        {"output":[{"type":"function_call","name":"type","arguments":{"text":"hi"}}]}
        """)
        guard case let .type(_, point, _, clearFirst) = action?.kind else {
            Issue.record("expected type"); return
        }
        #expect(point == nil)
        #expect(clearFirst == false) // no focus click → typing into the already-focused field, don't wipe it
    }

    @Test func keyCombinationParsesChord() {
        let action = firstAction("""
        {"computer_use":{"calls":[{"name":"key_combination","arguments":{"keys":"control+c"}}]}}
        """)
        guard case let .keys(keys) = action?.kind else { Issue.record("expected keys"); return }
        #expect(keys == ["control", "c"])
    }

    @Test func scrollDecodesDirectionAndMagnitude() {
        let action = firstAction("""
        {"computer_use":{"calls":[{"name":"scroll","arguments":{"direction":"down","magnitude_in_pixels":800}}]}}
        """)
        guard case let .scroll(point, direction, magnitude) = action?.kind else {
            Issue.record("expected scroll"); return
        }
        #expect(point == nil)
        #expect(direction == .down)
        #expect(magnitude == 800)
    }

    @Test func dragAndDropDecodesStreamlined35Endpoints() {
        // gemini-3.5-flash emits start_x/start_y/end_x/end_y.
        let action = firstAction("""
        {"computer_use":{"calls":[{"name":"drag_and_drop","arguments":{"start_x":10,"start_y":20,"end_x":30,"end_y":40}}]}}
        """)
        guard case let .drag(from, to) = action?.kind else { Issue.record("expected drag"); return }
        #expect(from.x == 10 && from.y == 20)
        #expect(to.x == 30 && to.y == 40)
    }

    @Test func dragAndDropDecodesLegacy25Endpoints() {
        // The 2.5 computer-use model used x/y + destination_x/destination_y.
        let action = firstAction("""
        {"computer_use":{"calls":[{"name":"drag_and_drop","arguments":{"x":10,"y":20,"destination_x":30,"destination_y":40}}]}}
        """)
        guard case let .drag(from, to) = action?.kind else { Issue.record("expected drag"); return }
        #expect(from.x == 10 && from.y == 20)
        #expect(to.x == 30 && to.y == 40)
    }

    @Test func clickVariantsMapToButtonsAndCounts() {
        func kind(_ name: String) -> VisionComputerAction.Kind? {
            firstAction("{\"computer_use\":{\"calls\":[{\"name\":\"\(name)\",\"arguments\":{\"x\":1,\"y\":1}}]}}")?.kind
        }
        guard case .click(.left, 2, _)? = kind("double_click") else { Issue.record("double_click"); return }
        guard case .click(.right, 1, _)? = kind("right_click") else { Issue.record("right_click"); return }
        guard case .click(.center, 1, _)? = kind("middle_click") else { Issue.record("middle_click"); return }
        guard case .move? = kind("hover_at") else { Issue.record("hover_at→move"); return }
    }

    @Test func browserOnlyFunctionsAreUnsupportedOnDesktop() {
        let action = firstAction("""
        {"computer_use":{"calls":[{"name":"navigate","arguments":{"url":"https://example.com"}}]}}
        """)
        guard case .unsupported = action?.kind else { Issue.record("expected unsupported"); return }
    }

    @Test func noFunctionCallMeansDoneWithText() {
        let value = decode("""
        {"candidates":[{"content":{"parts":[{"text":"The song is now playing."}]}}]}
        """)
        #expect(VisionComputerResponse.functionCalls(in: value).isEmpty)
        #expect(VisionComputerResponse.outputText(in: value) == "The song is now playing.")
    }

    @Test func firstActionThrowsOnEmptyResponse() {
        // An empty / safety-blocked / truncated turn (no call, no text) must fail the run, not be
        // mistaken for "done".
        let value = decode("{\"candidates\":[{\"content\":{\"parts\":[]}}]}")
        #expect(throws: VisionComputerResponseError.self) {
            _ = try VisionComputerResponse.firstAction(in: value)
        }
    }

    @Test func firstActionReturnsDoneOnTextOnly() throws {
        let value = decode("{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"The song is playing.\"}]}}]}")
        guard case let .done(text) = try VisionComputerResponse.firstAction(in: value).kind else {
            Issue.record("expected done"); return
        }
        #expect(text == "The song is playing.")
    }

    @Test func firstActionReturnsActionOnCall() throws {
        let value = decode("{\"computer_use\":{\"calls\":[{\"name\":\"click\",\"arguments\":{\"x\":1,\"y\":2}}]}}")
        guard case .click = try VisionComputerResponse.firstAction(in: value).kind else {
            Issue.record("expected click"); return
        }
    }

    @Test func screenPointMapsNormalizedSpaceIntoWindow() {
        let window = WindowTargetBounds(x: 100, y: 50, width: 1000, height: 800)
        let point = VisionComputerActionExecutor.screenPoint(
            VisionComputerAction.Point(x: 500, y: 250), window: window
        )
        #expect(abs(point.x - 600) < 0.001)   // 100 + 0.5 * 1000
        #expect(abs(point.y - 250) < 0.001)   // 50 + 0.3125 * 800 = 50 + 250
    }
}
