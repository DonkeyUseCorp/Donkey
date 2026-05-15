import CoreGraphics
import Foundation

public struct PointerPromptState: Equatable, Sendable {
    public var promptText: String
    public var isPrimaryActionEnabled: Bool
    public var leadingSignalLevel: SignalLevel
    public var isActive: Bool
    public var theme: PointerPromptTheme

    public init(
        promptText: String,
        isPrimaryActionEnabled: Bool = true,
        leadingSignalLevel: SignalLevel = .idle,
        isActive: Bool = false,
        theme: PointerPromptTheme = .defaultBlue
    ) {
        self.promptText = promptText
        self.isPrimaryActionEnabled = isPrimaryActionEnabled
        self.leadingSignalLevel = leadingSignalLevel
        self.isActive = isActive
        self.theme = theme
    }

    public static let productionDefault = PointerPromptState(
        promptText: "Make this so",
        leadingSignalLevel: .ready,
        isActive: true
    )
}

public struct PointerPromptTheme: Equatable, Sendable {
    public var accent: PointerPromptColor
    public var fill: PointerPromptColor
    public var pointerFill: PointerPromptColor
    public var activeShadow: PointerPromptColor

    public init(
        accent: PointerPromptColor,
        fill: PointerPromptColor,
        pointerFill: PointerPromptColor,
        activeShadow: PointerPromptColor
    ) {
        self.accent = accent
        self.fill = fill
        self.pointerFill = pointerFill
        self.activeShadow = activeShadow
    }

    public static let defaultBlue = PointerPromptTheme(
        accent: PointerPromptColor(
            red: 13.0 / 255.0,
            green: 108.0 / 255.0,
            blue: 216.0 / 255.0,
            alpha: 1
        ),
        fill: PointerPromptColor(red: 0.88, green: 0.94, blue: 1.0, alpha: 1),
        pointerFill: .white,
        activeShadow: PointerPromptColor(red: 0.0, green: 0.14, blue: 0.32, alpha: 0.26)
    )

    public static func fromConfig(_ config: PointerPromptThemeConfig) -> PointerPromptTheme? {
        guard let accent = PointerPromptColor(cssString: config.accent) else {
            return nil
        }

        let baseTheme = PointerPromptTheme.accent(accent)
        return PointerPromptTheme(
            accent: accent,
            fill: PointerPromptColor(cssString: config.fill) ?? baseTheme.fill,
            pointerFill: PointerPromptColor(cssString: config.pointerFill) ?? baseTheme.pointerFill,
            activeShadow: PointerPromptColor(cssString: config.activeShadow) ?? baseTheme.activeShadow
        )
    }

    public static func accent(_ accent: PointerPromptColor) -> PointerPromptTheme {
        PointerPromptTheme(
            accent: accent,
            fill: accent.mixed(with: .white, accentWeight: 0.13, alpha: 1),
            pointerFill: accent.mixed(with: .white, accentWeight: 0.24, alpha: 1),
            activeShadow: PointerPromptColor(
                red: accent.red,
                green: accent.green,
                blue: accent.blue,
                alpha: 0.26
            )
        )
    }
}

public struct PointerPromptThemeConfig: Codable, Equatable, Sendable {
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

public struct PointerPromptColor: Equatable, Sendable {
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

    public static let white = PointerPromptColor(red: 1, green: 1, blue: 1, alpha: 1)

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
        with other: PointerPromptColor,
        accentWeight: Double,
        alpha: Double
    ) -> PointerPromptColor {
        let baseWeight = 1 - accentWeight
        return PointerPromptColor(
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

public enum PointerPromptIntent: Equatable, Sendable {
    case addContextRequested
    case voiceInputRequested
    case primaryActionRequested(promptText: String)
    case messageSubmitted(text: String)
    case inputTextHeightChanged(CGFloat)
    case dismissed
}

@MainActor
public protocol PointerPromptIntentSink: AnyObject {
    func handle(_ intent: PointerPromptIntent)
}

@MainActor
public final class NoopPointerPromptIntentSink: PointerPromptIntentSink {
    public init() {}

    public func handle(_ intent: PointerPromptIntent) {}
}
