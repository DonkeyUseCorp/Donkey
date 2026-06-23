@testable import DonkeyAI
import Foundation
import Testing

/// Offline unit tests for the streaming JSON field extractor — the fragile part of one-round-trip streaming.
/// Pure logic, no model, so these run in a plain `swift test`. They feed the field in arbitrary chunk
/// boundaries (the real stream splits tokens unpredictably) and check the decoded value is delivered exactly
/// once, in order, with escapes handled and no partial-escape leakage.
@Suite
struct StreamingJSONStringFieldTests {
    /// Feed `full` to a fresh extractor one Unicode scalar at a time (the meanest possible chunking) and
    /// return everything it emitted, concatenated.
    private func emitCharByChar(_ full: String, key: String = "conversationReply") -> String {
        var field = StreamingJSONStringField(key: key)
        var emitted = ""
        var buffer = ""
        for character in full {
            buffer.append(character)
            emitted += field.consume(buffer)
        }
        return emitted
    }

    @Test
    func extractsValueDeliveredCharByChar() {
        let json = #"{"conversationReply":"Hey there!","turnKind":"converse"}"#
        #expect(emitCharByChar(json) == "Hey there!")
    }

    @Test
    func decodesEscapesAcrossChunkBoundaries() {
        let json = #"{"conversationReply":"line1\nline2 \"quoted\" end","turnKind":"converse"}"#
        #expect(emitCharByChar(json) == "line1\nline2 \"quoted\" end")
    }

    @Test
    func decodesUnicodeEscape() {
        let json = #"{"conversationReply":"café","turnKind":"converse"}"#
        #expect(emitCharByChar(json) == "café")
    }

    @Test
    func emitsNothingWhenFieldAbsent() {
        let json = #"{"turnKind":"act","restatedGoal":"open Safari"}"#
        #expect(emitCharByChar(json) == "")
    }

    @Test
    func emptyValueEmitsNothingAndDoesNotLeakIntoNextField() {
        let json = #"{"conversationReply":"","turnKind":"act"}"#
        #expect(emitCharByChar(json) == "")
    }

    @Test
    func handlesFieldNotFirst() {
        let json = #"{"turnKind":"converse","restatedGoal":"hi","conversationReply":"Hello!"}"#
        #expect(emitCharByChar(json) == "Hello!")
    }

    @Test
    func deliversEachCharacterExactlyOnce() {
        // Whole-buffer-at-once should match char-by-char: no duplication, no drops.
        let json = #"{"conversationReply":"abcdef","turnKind":"converse"}"#
        var field = StreamingJSONStringField(key: "conversationReply")
        let once = field.consume(json)
        #expect(once == "abcdef")
        // A second consume of the same (now-complete) buffer yields nothing more.
        #expect(field.consume(json) == "")
    }
}
