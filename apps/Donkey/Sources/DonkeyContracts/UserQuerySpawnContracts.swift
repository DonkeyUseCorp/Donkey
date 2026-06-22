import CoreGraphics
import Foundation

public enum UserQuerySpawnPhase: String, Codable, Equatable, Sendable {
    case notchCue
    case traveling
    case holding
    case fading
}

public struct UserQuerySpawnTargetHint: Codable, Equatable, Sendable {
    public var appName: String?
    public var bundleIdentifier: String?
    public var titleContains: String?
    public var bounds: WindowTargetBounds?
    public var metadata: [String: String]

    public init(
        appName: String? = nil,
        bundleIdentifier: String? = nil,
        titleContains: String? = nil,
        bounds: WindowTargetBounds? = nil,
        metadata: [String: String] = [:]
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.titleContains = titleContains
        self.bounds = bounds
        self.metadata = metadata
    }
}

public struct UserQuerySpawnState: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var conversationID: String?
    public var commandText: String
    public var label: String
    public var accentIndex: Int
    public var phase: UserQuerySpawnPhase
    public var notchCueAngleDegrees: Double
    public var targetHint: UserQuerySpawnTargetHint?
    public var createdAt: Date
    public var updatedAt: Date
    /// When the spawn's work last came to rest (run finished or is waiting on
    /// the user). Nil while a run is in flight; cleared when work resumes.
    public var finishedAt: Date?

    public init(
        id: String = UUID().uuidString,
        conversationID: String? = nil,
        commandText: String,
        label: String,
        accentIndex: Int,
        phase: UserQuerySpawnPhase = .notchCue,
        notchCueAngleDegrees: Double = UserQuerySpawnGeometry.defaultExitAngleDegrees,
        targetHint: UserQuerySpawnTargetHint? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.commandText = commandText
        self.label = label
        self.accentIndex = accentIndex
        self.phase = phase
        self.notchCueAngleDegrees = notchCueAngleDegrees
        self.targetHint = targetHint
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
    }
}

public struct UserQuerySpawnProgressUpdate: Equatable, Sendable {
    public var label: String?
    public var targetHint: UserQuerySpawnTargetHint?
    public var phase: UserQuerySpawnPhase?
    /// One token-chunk of the assistant's final reply, streamed as it is generated. When set, the
    /// model appends it to the running task's detail (the chin and the open row read that), so the
    /// answer types itself out instead of popping in whole. A normal `label` update replaces the status
    /// line; an `answerDelta` accumulates onto it.
    public var answerDelta: String?

    public init(
        label: String? = nil,
        targetHint: UserQuerySpawnTargetHint? = nil,
        phase: UserQuerySpawnPhase? = nil,
        answerDelta: String? = nil
    ) {
        self.label = label
        self.targetHint = targetHint
        self.phase = phase
        self.answerDelta = answerDelta
    }
}

public enum UserQuerySpawnLifecycle {
    public static func keepsVisibleResult(
        for threadStatus: UserQueryConversationStatus
    ) -> Bool {
        switch threadStatus {
        case .chatting,
             .running,
             .paused,
             .waitingForClarification,
             .waitingForPermission,
             .waitingForReview,
             .interrupted,
             .needsAttention,
             .failed,
             .timedOut:
            true
        case .completed:
            false
        }
    }

}

public enum UserQuerySpawnGeometry {
    public static let defaultExitAngleDegrees: Double = 90
    public static let fallbackVerticalOffset: CGFloat = 250
    public static let minimumScreenInset: CGFloat = 36

    public static func fallbackPoint(
        screenSize: CGSize,
        notchBottomY: CGFloat,
        verticalOffset: CGFloat = fallbackVerticalOffset,
        inset: CGFloat = minimumScreenInset
    ) -> CGPoint {
        clampedPoint(
            CGPoint(x: screenSize.width / 2, y: notchBottomY + verticalOffset),
            in: screenSize,
            inset: inset
        )
    }

    public static func clampedPoint(
        _ point: CGPoint,
        in screenSize: CGSize,
        inset: CGFloat = minimumScreenInset
    ) -> CGPoint {
        let maximumX = max(inset, screenSize.width - inset)
        let maximumY = max(inset, screenSize.height - inset)
        return CGPoint(
            x: min(max(point.x, inset), maximumX),
            y: min(max(point.y, inset), maximumY)
        )
    }

    public static func angleDegrees(from origin: CGPoint, to target: CGPoint) -> Double {
        atan2(target.y - origin.y, target.x - origin.x) * 180 / .pi
    }

    public static func labelTypingIdentity(spawnID: String, label: String) -> String {
        "\(spawnID):\(label)"
    }
}
