import Foundation

/// Pulls one string field's value out of a JSON object *as it streams in*. Feed it the growing buffer on
/// each delta; it returns only the newly-available, fully-decoded characters of that field's value. This is
/// what lets a reply embedded in a streamed JSON understanding type into the UI live without ever forwarding
/// raw JSON — or a half-finished `\u` escape — to the screen: the consumer only ever sees decoded reply text.
///
/// It locks onto the field the first time the `"key":"` opener appears, decodes standard JSON string escapes,
/// and stops at the closing quote. Bytes for other fields (and the model's structured decision) stream past
/// untouched.
struct StreamingJSONStringField {
    let key: String
    /// Index (in the char array) of the first content character after the value's opening quote, once found.
    private var valueStart: Int?
    /// How many decoded characters have already been returned, so each call yields only the new suffix.
    private var emittedCount = 0
    private var finished = false

    init(key: String) { self.key = key }

    /// Feed the full accumulated buffer; returns the newly-decoded characters of the field's value (empty
    /// when nothing new is available yet, the field hasn't appeared, or the value has ended).
    mutating func consume(_ buffer: String) -> String {
        guard !finished else { return "" }
        let chars = Array(buffer)
        guard let start = valueStart ?? Self.locateValueStart(of: key, in: chars) else { return "" }
        valueStart = start

        var decoded: [Character] = []
        var index = start
        decodeLoop: while index < chars.count {
            let character = chars[index]
            if character == "\\" {
                guard index + 1 < chars.count else { break decodeLoop } // incomplete escape — wait for more
                switch chars[index + 1] {
                case "\"": decoded.append("\""); index += 2
                case "\\": decoded.append("\\"); index += 2
                case "/": decoded.append("/"); index += 2
                case "n": decoded.append("\n"); index += 2
                case "t": decoded.append("\t"); index += 2
                case "r": decoded.append("\r"); index += 2
                case "b": decoded.append("\u{08}"); index += 2
                case "f": decoded.append("\u{0C}"); index += 2
                case "u":
                    guard index + 5 < chars.count else { break decodeLoop } // incomplete \uXXXX — wait
                    if let code = UInt32(String(chars[(index + 2)...(index + 5)]), radix: 16),
                       let scalar = Unicode.Scalar(code) {
                        decoded.append(Character(scalar))
                    }
                    index += 6
                default: decoded.append(chars[index + 1]); index += 2
                }
            } else if character == "\"" {
                finished = true
                break decodeLoop
            } else {
                decoded.append(character)
                index += 1
            }
        }

        guard decoded.count > emittedCount else { return "" }
        let newPart = String(decoded[emittedCount...])
        emittedCount = decoded.count
        return newPart
    }

    /// Find `"key"`, the following `:`, and the opening `"` of its value; return the index just past that
    /// quote, or nil if the value hasn't started streaming yet.
    private static func locateValueStart(of key: String, in chars: [Character]) -> Int? {
        let needle = Array("\"\(key)\"")
        guard let keyStart = firstIndex(of: needle, in: chars) else { return nil }
        var index = keyStart + needle.count
        while index < chars.count, chars[index] != ":" { index += 1 }
        guard index < chars.count else { return nil }
        index += 1 // past the colon
        while index < chars.count, chars[index] != "\"" {
            guard chars[index].isWhitespace else { return nil } // value isn't a string (or not yet here)
            index += 1
        }
        guard index < chars.count, chars[index] == "\"" else { return nil }
        return index + 1
    }

    private static func firstIndex(of needle: [Character], in haystack: [Character]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            var matched = true
            for offset in 0..<needle.count where haystack[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return start }
        }
        return nil
    }
}
