import DonkeyContracts
import Foundation

public struct LocalAppTaskIntentParser: Sendable {
    public var taskDefinitions: [LocalAppTaskDefinition]

    public init(taskDefinitions: [LocalAppTaskDefinition]) {
        self.taskDefinitions = taskDefinitions
    }

    public func parse(_: String) -> TaskIntent? {
        nil
    }

    public static func normalizedPhrase(_ value: String) -> String {
        let folded = value.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars)
            .split(separator: " ")
            .joined(separator: " ")
            .lowercased()
    }
}
