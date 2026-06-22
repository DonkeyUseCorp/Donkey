import CoreGraphics
import Foundation

public enum UserQueryCopy {
    public static let defaultPromptPlaceholder = "What can donkey do for you?"
    private static let transientComposerPlaceholders: Set<String> = [
        "Listening...",
        "No voice captured",
        "Transcribing...",
        "Voice unavailable"
    ]

    public static func normalizedDisplayText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    public static func composerPlaceholder(for text: String) -> String {
        let normalizedText = normalizedDisplayText(text)
        guard transientComposerPlaceholders.contains(normalizedText) else {
            return defaultPromptPlaceholder
        }

        return normalizedText
    }

    public static func isTaskDisplayText(_ text: String) -> Bool {
        let normalizedText = normalizedDisplayText(text)
        return !normalizedText.isEmpty &&
            normalizedText != defaultPromptPlaceholder
    }
}

public struct UserQueryState: Equatable, Sendable {
    public static let defaultVoiceWaveformLevels: [Double] = [
        0.12,
        0.2,
        0.34,
        0.5,
        0.34,
        0.2,
        0.12
    ]

    public var promptText: String
    public var isPrimaryActionEnabled: Bool
    public var leadingSignalLevel: SignalLevel
    public var isActive: Bool
    public var theme: UserQueryTheme
    public var voiceWaveformLevels: [Double]
    public var isVoiceInputActive: Bool

    public init(
        promptText: String,
        isPrimaryActionEnabled: Bool = true,
        leadingSignalLevel: SignalLevel = .idle,
        isActive: Bool = false,
        theme: UserQueryTheme = .defaultBlue,
        voiceWaveformLevels: [Double] = UserQueryState.defaultVoiceWaveformLevels,
        isVoiceInputActive: Bool = false
    ) {
        self.promptText = promptText
        self.isPrimaryActionEnabled = isPrimaryActionEnabled
        self.leadingSignalLevel = leadingSignalLevel
        self.isActive = isActive
        self.theme = theme
        self.voiceWaveformLevels = voiceWaveformLevels
        self.isVoiceInputActive = isVoiceInputActive
    }

    public static let productionDefault = UserQueryState(
        promptText: UserQueryCopy.defaultPromptPlaceholder,
        leadingSignalLevel: .ready,
        isActive: true
    )
}

public struct UserQueryTheme: Equatable, Sendable {
    public var accent: UserQueryColor
    public var fill: UserQueryColor
    public var pointerFill: UserQueryColor
    public var activeShadow: UserQueryColor

    public init(
        accent: UserQueryColor,
        fill: UserQueryColor,
        pointerFill: UserQueryColor,
        activeShadow: UserQueryColor
    ) {
        self.accent = accent
        self.fill = fill
        self.pointerFill = pointerFill
        self.activeShadow = activeShadow
    }

    public static let defaultBlue = UserQueryTheme(
        accent: UserQueryColor(
            red: 13.0 / 255.0,
            green: 108.0 / 255.0,
            blue: 216.0 / 255.0,
            alpha: 1
        ),
        fill: UserQueryColor(red: 0.88, green: 0.94, blue: 1.0, alpha: 1),
        pointerFill: .white,
        activeShadow: UserQueryColor(red: 0.0, green: 0.14, blue: 0.32, alpha: 0.26)
    )

    public static func fromConfig(_ config: UserQueryThemeConfig) -> UserQueryTheme? {
        guard let accent = UserQueryColor(cssString: config.accent) else {
            return nil
        }

        let baseTheme = UserQueryTheme.accent(accent)
        return UserQueryTheme(
            accent: accent,
            fill: UserQueryColor(cssString: config.fill) ?? baseTheme.fill,
            pointerFill: UserQueryColor(cssString: config.pointerFill) ?? baseTheme.pointerFill,
            activeShadow: UserQueryColor(cssString: config.activeShadow) ?? baseTheme.activeShadow
        )
    }

    public static func accent(_ accent: UserQueryColor) -> UserQueryTheme {
        UserQueryTheme(
            accent: accent,
            fill: accent.mixed(with: .white, accentWeight: 0.13, alpha: 1),
            pointerFill: accent.mixed(with: .white, accentWeight: 0.24, alpha: 1),
            activeShadow: UserQueryColor(
                red: accent.red,
                green: accent.green,
                blue: accent.blue,
                alpha: 0.26
            )
        )
    }
}

public struct UserQueryThemeConfig: Codable, Equatable, Sendable {
    public var accent: String
    public var fill: String?
    public var pointerFill: String?
    public var activeShadow: String?

    public init(
        accent: String,
        fill: String? = nil,
        pointerFill: String? = nil,
        activeShadow: String? = nil
    ) {
        self.accent = accent
        self.fill = fill
        self.pointerFill = pointerFill
        self.activeShadow = activeShadow
    }
}

public struct UserQueryColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let white = UserQueryColor(red: 1, green: 1, blue: 1, alpha: 1)

    public init?(cssString: String?) {
        guard let cssString else { return nil }

        let trimmed = cssString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("rgba("), trimmed.hasSuffix(")") {
            let rawValues = trimmed
                .dropFirst(5)
                .dropLast()
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            guard rawValues.count == 4,
                  let red = Double(rawValues[0]),
                  let green = Double(rawValues[1]),
                  let blue = Double(rawValues[2]),
                  let alpha = Double(rawValues[3]) else {
                return nil
            }

            self.init(
                red: red / 255.0,
                green: green / 255.0,
                blue: blue / 255.0,
                alpha: alpha
            )
            return
        }

        let hex = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = Int(hex, radix: 16) else {
            return nil
        }

        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0,
            alpha: 1
        )
    }

    public func mixed(
        with other: UserQueryColor,
        accentWeight: Double,
        alpha: Double
    ) -> UserQueryColor {
        let baseWeight = 1 - accentWeight
        return UserQueryColor(
            red: red * accentWeight + other.red * baseWeight,
            green: green * accentWeight + other.green * baseWeight,
            blue: blue * accentWeight + other.blue * baseWeight,
            alpha: alpha
        )
    }
}

public enum SignalLevel: String, Equatable, Sendable {
    case idle
    case ready
    case thinking
}

/// Well-known keys on a task's `metadata`. Shared so the harness side that writes them and the notch
/// UI that reads them never drift on a raw string literal.
public enum UserQueryConversationMetadataKey {
    /// Set to "true" on a task that failed because the account is out of credits. The notch shows a
    /// "Reload credits" CTA banner for such a task.
    public static let creditReloadRequired = "credits.reloadRequired"
}

public enum UserQueryIntent: Equatable, Sendable {
    case addContextRequested
    case voiceInputRequested
    case primaryActionRequested(promptText: String)
    case messageSubmitted(text: String)
    case inputTextHeightChanged(CGFloat)
    case inputExpansionChanged(Bool)
    case dismissed
}

@MainActor
public protocol UserQueryIntentSink: AnyObject {
    func handle(_ intent: UserQueryIntent)
}

@MainActor
public final class NoopUserQueryIntentSink: UserQueryIntentSink {
    public init() {}

    public func handle(_ intent: UserQueryIntent) {}
}

public struct PointerCoachCursorGuideRequest: Equatable, Sendable {
    public var id: String
    public var title: String
    public var origin: CGPoint
    public var steps: [PointerCoachCursorGuideStep]
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        title: String,
        origin: CGPoint = CGPoint(x: 0.5, y: 0.14),
        steps: [PointerCoachCursorGuideStep],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.origin = origin
        self.steps = steps
        self.metadata = metadata
    }
}

public struct PointerCoachCursorGuideStep: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var target: CGPoint
    public var preRotateDuration: TimeInterval
    public var travelDuration: TimeInterval
    public var holdDuration: TimeInterval
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        label: String,
        target: CGPoint,
        preRotateDuration: TimeInterval = 0.12,
        travelDuration: TimeInterval = 0.9,
        holdDuration: TimeInterval = 1.8,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.label = label
        self.target = target
        self.preRotateDuration = min(max(preRotateDuration, 0), 0.6)
        self.travelDuration = max(0.1, travelDuration)
        self.holdDuration = max(0.4, holdDuration)
        self.metadata = metadata
    }
}
