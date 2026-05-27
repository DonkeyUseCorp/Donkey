import AppKit
import CoreGraphics
import DonkeyContracts
import Foundation

struct MacKeyboardTextEntryExecution: Equatable, Sendable {
    var executed: Bool
    var inputMode: String
    var metadata: [String: String]

    init(
        executed: Bool,
        inputMode: String,
        metadata: [String: String] = [:]
    ) {
        self.executed = executed
        self.inputMode = inputMode
        self.metadata = metadata
    }
}

public struct MacKeyboardActionEngineInputBackend: ActionEngineInputBackend {
    private let keyCommandPoster: @Sendable (String) -> Bool
    private let mouseClickPoster: @Sendable (CGPoint) -> Bool
    private let textEntryExecutor: @Sendable (
        String,
        @escaping @Sendable (String) -> Bool
    ) async -> MacKeyboardTextEntryExecution

    public init() {
        self.keyCommandPoster = Self.postKeyCommand
        self.mouseClickPoster = Self.postMouseClick
        self.textEntryExecutor = Self.pasteText
    }

    init(
        keyCommandPoster: @escaping @Sendable (String) -> Bool,
        mouseClickPoster: @escaping @Sendable (CGPoint) -> Bool = Self.postMouseClick,
        textEntryExecutor: @escaping @Sendable (
            String,
            @escaping @Sendable (String) -> Bool
        ) async -> MacKeyboardTextEntryExecution
    ) {
        self.keyCommandPoster = keyCommandPoster
        self.mouseClickPoster = mouseClickPoster
        self.textEntryExecutor = textEntryExecutor
    }

    public func execute(_ command: ActionEngineCommand) async -> ActionEngineInputBackendResult {
        if command.kind == .tap {
            return await executeTap(command)
        }

        guard command.kind == .key, let key = command.key else {
            return result(
                command: command,
                executed: false,
                metadata: [
                    "liveInputBackend": "mac-keyboard",
                    "inputMode": "keyboard",
                    "elementClick": "false",
                    "reason": "unsupportedCommandKind"
                ]
            )
        }

        let executed: Bool
        let inputMode: String
        var inputMetadata: [String: String] = [:]
        if command.metadata["inputRole"] == "textEntry" {
            let textResult = await textEntryExecutor(key, keyCommandPoster)
            executed = textResult.executed
            inputMode = textResult.inputMode
            inputMetadata = textResult.metadata
        } else {
            executed = keyCommandPoster(key)
            inputMode = "keyCommand"
        }

        if executed {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }

        return result(
            command: command,
            executed: executed,
            metadata: [
                "liveInputBackend": "mac-keyboard",
                "inputMode": inputMode,
                "elementClick": "false",
                "key": key
            ].merging(inputMetadata) { current, _ in current }
        )
    }

    private func executeTap(_ command: ActionEngineCommand) async -> ActionEngineInputBackendResult {
        guard let point = screenCenter(of: command.targetBounds) else {
            return result(
                command: command,
                executed: false,
                metadata: [
                    "liveInputBackend": "mac-keyboard",
                    "inputMode": "coordinateClick",
                    "elementClick": "true",
                    "reason": "missingScreenTargetBounds"
                ]
            )
        }

        let executed = mouseClickPoster(point)
        if executed {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        return result(
            command: command,
            executed: executed,
            metadata: [
                "liveInputBackend": "mac-keyboard",
                "inputMode": "coordinateClick",
                "elementClick": "true",
                "targetPoint.x": String(Double(point.x)),
                "targetPoint.y": String(Double(point.y)),
                "controlID": command.metadata["controlID"] ?? "",
                "visualFallback": command.metadata["visualFallback"] ?? ""
            ]
        )
    }

    private func screenCenter(of rect: HotLoopRect?) -> CGPoint? {
        guard let rect,
              rect.hasPositiveArea,
              rect.space == .screen
        else {
            return nil
        }
        return CGPoint(
            x: rect.origin.x + rect.size.width / 2,
            y: rect.origin.y + rect.size.height / 2
        )
    }

    private func result(
        command: ActionEngineCommand,
        executed: Bool,
        metadata: [String: String]
    ) -> ActionEngineInputBackendResult {
        ActionEngineInputBackendResult(
            executed: executed,
            completedAt: Self.now(),
            metadata: metadata
        )
    }

    private static func pasteText(
        _ text: String,
        postKeyCommand: @escaping @Sendable (String) -> Bool
    ) async -> MacKeyboardTextEntryExecution {
        guard !text.isEmpty else {
            return MacKeyboardTextEntryExecution(
                executed: false,
                inputMode: "pasteboardText",
                metadata: ["reason": "emptyText"]
            )
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            snapshot.restore(to: pasteboard)
            return MacKeyboardTextEntryExecution(
                executed: false,
                inputMode: "pasteboardText",
                metadata: ["reason": "pasteboardWriteFailed"]
            )
        }
        let textChangeCount = pasteboard.changeCount

        try? await Task.sleep(nanoseconds: 30_000_000)
        let pasted = postKeyCommand("Command+V")
        try? await Task.sleep(nanoseconds: 400_000_000)
        if pasteboard.changeCount == textChangeCount {
            snapshot.restore(to: pasteboard)
        }

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

    private static func postKeyCommand(_ command: String) -> Bool {
        let parts = command
            .split(separator: "+")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let keyName = parts.last,
              let keyCode = Self.keyCode(for: keyName),
              let source = CGEventSource(stateID: .hidSystemState)
        else {
            return false
        }

        let flags = Self.flags(for: Array(parts.dropLast()))
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return false
        }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private static func postMouseClick(at point: CGPoint) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let mouseDown = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: point,
                mouseButton: .left
              ),
              let mouseUp = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
              )
        else {
            return false
        }
        mouseDown.post(tap: .cghidEventTap)
        mouseUp.post(tap: .cghidEventTap)
        return true
    }

    private static func flags(for modifiers: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers.map({ $0.lowercased() }) {
            switch modifier {
            case "command", "cmd", "⌘":
                flags.insert(.maskCommand)
            case "shift", "⇧":
                flags.insert(.maskShift)
            case "option", "alt", "⌥":
                flags.insert(.maskAlternate)
            case "control", "ctrl", "⌃":
                flags.insert(.maskControl)
            default:
                continue
            }
        }
        return flags
    }

    private static func keyCode(for keyName: String) -> CGKeyCode? {
        switch keyName.lowercased() {
        case "return", "enter":
            return 36
        case "tab":
            return 48
        case "escape", "esc":
            return 53
        case "space":
            return 49
        case "a":
            return 0
        case "b":
            return 11
        case "c":
            return 8
        case "d":
            return 2
        case "e":
            return 14
        case "f":
            return 3
        case "g":
            return 5
        case "h":
            return 4
        case "i":
            return 34
        case "j":
            return 38
        case "k":
            return 40
        case "l":
            return 37
        case "m":
            return 46
        case "n":
            return 45
        case "o":
            return 31
        case "p":
            return 35
        case "q":
            return 12
        case "r":
            return 15
        case "s":
            return 1
        case "t":
            return 17
        case "u":
            return 32
        case "v":
            return 9
        case "w":
            return 13
        case "x":
            return 7
        case "y":
            return 16
        case "z":
            return 6
        default:
            return nil
        }
    }

    private static func now() -> RunTraceTimestamp {
        RunTraceTimestamp(
            wallClock: Date(),
            monotonicUptimeNanoseconds: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        )
    }
}

private struct PasteboardSnapshot {
    var items: [Item]

    struct Item {
        var representations: [(type: String, data: Data)]
    }

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        PasteboardSnapshot(
            items: (pasteboard.pasteboardItems ?? []).map { item in
                Item(
                    representations: item.types.compactMap { type in
                        guard let data = item.data(forType: type) else { return nil }
                        return (type.rawValue, data)
                    }
                )
            }
        )
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let pasteboardItems = items.compactMap { item -> NSPasteboardItem? in
            let pasteboardItem = NSPasteboardItem()
            var wroteRepresentation = false
            for representation in item.representations {
                let type = NSPasteboard.PasteboardType(representation.type)
                wroteRepresentation = pasteboardItem.setData(representation.data, forType: type)
                    || wroteRepresentation
            }
            return wroteRepresentation ? pasteboardItem : nil
        }
        if !pasteboardItems.isEmpty {
            pasteboard.writeObjects(pasteboardItems)
        }
    }
}
