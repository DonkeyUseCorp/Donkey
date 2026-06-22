import DonkeyContracts
import Foundation

public struct AppHarnessTurnRequest: Equatable, Sendable {
    public var turn: AppHarnessTurn
    public var recentEvents: [UserQueryConversationEvent]
    public var assets: [UserQueryConversationAsset]
    public var targetState: [String: String]
    public var memory: [String]
    public var policy: [String: String]

    public init(
        turn: AppHarnessTurn,
        recentEvents: [UserQueryConversationEvent] = [],
        assets: [UserQueryConversationAsset] = [],
        targetState: [String: String] = [:],
        memory: [String] = [],
        policy: [String: String] = [:]
    ) {
        self.turn = turn
        self.recentEvents = recentEvents
        self.assets = assets
        self.targetState = targetState
        self.memory = memory
        self.policy = policy
    }
}
