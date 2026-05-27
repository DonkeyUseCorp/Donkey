import Foundation

public enum UserQueryActivationModifier: String, Equatable, Sendable {
    case command
}

public struct UserQueryActivationShortcut: Equatable, Sendable {
    public var modifier: UserQueryActivationModifier
    public var tapCount: Int
    public var maximumTapDuration: TimeInterval
    public var maximumTapInterval: TimeInterval
    public var holdToVoiceInputDuration: TimeInterval?

    public init(
        modifier: UserQueryActivationModifier,
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

    public static let doubleCommand = UserQueryActivationShortcut(
        modifier: .command,
        tapCount: 2,
        maximumTapDuration: 0.45,
        maximumTapInterval: 0.45,
        holdToVoiceInputDuration: 0.28
    )
}
