import AppKit
import CoreGraphics
import DonkeyContracts
import Foundation

public struct MacKeyboardActionEngineInputBackend: ActionEngineInputBackend {
    public init() {}

    public func execute(_ command: ActionEngineCommand) async -> ActionEngineInputBackendResult {
        guard command.kind == .key, let key = command.key else {
            return result(
                command: command,
                executed: false,
                metadata: ["liveInputBackend": "mac-keyboard", "reason": "unsupportedCommandKind"]
            )
        }

        let executed: Bool
        let inputMode: String
        if command.metadata["inputRole"] == "textEntry" {
            executed = postText(key)
            inputMode = "unicodeText"
        } else {
            executed = postKeyCommand(key)
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
                "key": key
            ]
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

    private func postText(_ text: String) -> Bool {
        guard !text.isEmpty,
              let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        else {
            return false
        }

        let utf16 = Array(text.utf16)
        utf16.withUnsafeBufferPointer { buffer in
            event.keyboardSetUnicodeString(
                stringLength: utf16.count,
                unicodeString: buffer.baseAddress
            )
        }
        event.post(tap: .cghidEventTap)
        return true
    }

    private func postKeyCommand(_ command: String) -> Bool {
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
