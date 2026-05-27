@testable import DonkeyRuntime
import DonkeyContracts
import CoreGraphics
import Foundation
import Testing

@Suite
struct MacKeyboardActionEngineInputBackendTests {
    @Test
    func textEntryUsesPasteboardBackedPasteCommand() async {
        let recorder = KeyboardCommandRecorder()
        let backend = MacKeyboardActionEngineInputBackend(
            keyCommandPoster: { command in
                recorder.append(command)
                return true
            },
            textEntryExecutor: { text, postKeyCommand in
                let pasted = postKeyCommand("Command+V")
                return MacKeyboardTextEntryExecution(
                    executed: pasted,
                    inputMode: "pasteboardText",
                    metadata: [
                        "textEntry.method": "pasteboard",
                        "textEntry.shortcut": "Command+V",
                        "textEntry.characterCount": String(text.count)
                    ]
                )
            }
        )

        let result = await backend.execute(command(
            key: "Sample Result",
            metadata: ["inputRole": "textEntry"]
        ))

        #expect(result.executed == true)
        #expect(result.metadata["inputMode"] == "pasteboardText")
        #expect(result.metadata["textEntry.method"] == "pasteboard")
        #expect(result.metadata["textEntry.shortcut"] == "Command+V")
        #expect(result.metadata["textEntry.characterCount"] == "13")
        #expect(recorder.commands() == ["Command+V"])
    }

    @Test
    func ordinaryKeyCommandsDoNotUseTextEntryPastePath() async {
        let recorder = KeyboardCommandRecorder()
        let backend = MacKeyboardActionEngineInputBackend(
            keyCommandPoster: { command in
                recorder.append(command)
                return true
            },
            textEntryExecutor: { _, _ in
                MacKeyboardTextEntryExecution(
                    executed: false,
                    inputMode: "pasteboardText",
                    metadata: ["reason": "unexpectedTextEntry"]
                )
            }
        )

        let result = await backend.execute(command(key: "Command+F"))

        #expect(result.executed == true)
        #expect(result.metadata["inputMode"] == "keyCommand")
        #expect(result.metadata["reason"] == nil)
        #expect(recorder.commands() == ["Command+F"])
    }

    @Test
    func tapCommandsClickCenterOfScreenTargetBounds() async {
        let recorder = MouseClickRecorder()
        let backend = MacKeyboardActionEngineInputBackend(
            keyCommandPoster: { _ in false },
            mouseClickPoster: { point in
                recorder.append(point)
                return true
            },
            textEntryExecutor: { _, _ in
                MacKeyboardTextEntryExecution(executed: false, inputMode: "pasteboardText")
            }
        )

        let result = await backend.execute(ActionEngineCommand(
            id: "tap-visual-send",
            traceID: "trace-coordinate-click",
            targetID: "local-app-task-test",
            kind: .tap,
            issuedAt: RunTraceTimestamp(
                wallClock: Date(timeIntervalSince1970: 0),
                monotonicUptimeNanoseconds: 0
            ),
            targetBounds: HotLoopRect(x: 100, y: 200, width: 80, height: 40, space: .screen),
            metadata: ["controlID": "send", "visualFallback": "aiOrObservedBounds"]
        ))

        #expect(result.executed == true)
        #expect(result.metadata["inputMode"] == "coordinateClick")
        #expect(result.metadata["elementClick"] == "true")
        #expect(result.metadata["controlID"] == "send")
        #expect(recorder.points() == [CGPoint(x: 140, y: 220)])
    }

    private func command(
        key: String,
        metadata: [String: String] = [:]
    ) -> ActionEngineCommand {
        ActionEngineCommand(
            id: "keyboard-\(key)",
            traceID: "trace-keyboard",
            targetID: "local-app-task-test",
            kind: .key,
            issuedAt: RunTraceTimestamp(
                wallClock: Date(timeIntervalSince1970: 0),
                monotonicUptimeNanoseconds: 0
            ),
            key: key,
            metadata: metadata
        )
    }
}

private final class KeyboardCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCommands: [String] = []

    func append(_ command: String) {
        lock.lock()
        recordedCommands.append(command)
        lock.unlock()
    }

    func commands() -> [String] {
        lock.lock()
        let commands = recordedCommands
        lock.unlock()
        return commands
    }
}

private final class MouseClickRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPoints: [CGPoint] = []

    func append(_ point: CGPoint) {
        lock.lock()
        recordedPoints.append(point)
        lock.unlock()
    }

    func points() -> [CGPoint] {
        lock.lock()
        let points = recordedPoints
        lock.unlock()
        return points
    }
}
