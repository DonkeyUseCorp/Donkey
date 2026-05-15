import Foundation

public enum PointerPromptActivationModifier: String, Equatable, Sendable {
    case command
}

public struct PointerPromptActivationShortcut: Equatable, Sendable {
    public var modifier: PointerPromptActivationModifier
    public var tapCount: Int
    public var maximumTapDuration: TimeInterval
    public var maximumTapInterval: TimeInterval
    public var holdToVoiceInputDuration: TimeInterval?

    public init(
        modifier: PointerPromptActivationModifier,
        tapCount: Int,
        maximumTapDuration: TimeInterval,
        maximumTapInterval: TimeInterval,
        holdToVoiceInputDuration: TimeInterval? = nil
    ) {
        self.modifier = modifier
        self.tapCount = max(1, tapCount)
        self.maximumTapDuration = max(0, maximumTapDuration)
        self.maximumTapInterval = max(0, maximumTapInterval)
        self.holdToVoiceInputDuration = holdToVoiceInputDuration.map { max(0, $0) }
    }

    public static let doubleCommand = PointerPromptActivationShortcut(
        modifier: .command,
        tapCount: 2,
        maximumTapDuration: 0.45,
        maximumTapInterval: 0.45,
        holdToVoiceInputDuration: 0.28
    )
}
