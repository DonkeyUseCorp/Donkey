import CoreGraphics
import Foundation

public enum PointerPromptSpawnPhase: String, Codable, Equatable, Sendable {
    case notchCue
    case traveling
    case holding
    case fading
}

public struct PointerPromptSpawnTargetHint: Codable, Equatable, Sendable {
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

public struct PointerPromptSpawnState: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var taskID: String?
    public var commandText: String
    public var label: String
    public var accentIndex: Int
    public var phase: PointerPromptSpawnPhase
    public var notchCueAngleDegrees: Double
    public var targetHint: PointerPromptSpawnTargetHint?
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        taskID: String? = nil,
        commandText: String,
        label: String,
        accentIndex: Int,
        phase: PointerPromptSpawnPhase = .notchCue,
        notchCueAngleDegrees: Double = PointerPromptSpawnGeometry.defaultExitAngleDegrees,
        targetHint: PointerPromptSpawnTargetHint? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.commandText = commandText
        self.label = label
        self.accentIndex = accentIndex
        self.phase = phase
        self.notchCueAngleDegrees = notchCueAngleDegrees
        self.targetHint = targetHint
        self.updatedAt = updatedAt
    }
}

public struct PointerPromptSpawnProgressUpdate: Equatable, Sendable {
    public var label: String?
    public var targetHint: PointerPromptSpawnTargetHint?
    public var phase: PointerPromptSpawnPhase?

    public init(
        label: String? = nil,
        targetHint: PointerPromptSpawnTargetHint? = nil,
        phase: PointerPromptSpawnPhase? = nil
    ) {
        self.label = label
        self.targetHint = targetHint
        self.phase = phase
    }
}

public enum PointerPromptSpawnLifecycle {
    public static func keepsVisibleResult(
        for threadStatus: PointerPromptTaskStatus
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
             .failed:
            true
        case .completed:
            false
        }
    }

}

public enum PointerPromptSpawnGeometry {
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
