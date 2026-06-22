import DonkeyContracts
import Foundation

public enum HarnessConversationEventRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
    case system
    case tool
    case lifecycle
    case summary
}

public struct HarnessConversation: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var status: HarnessAgentStatus
    public var activeAgentIDs: [String]
    public var createdAt: Date
    public var updatedAt: Date
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        title: String,
        status: HarnessAgentStatus = .running,
        activeAgentIDs: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.activeAgentIDs = activeAgentIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }
}

public struct HarnessConversationEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var conversationID: String
    public var agentID: String?
    public var role: HarnessConversationEventRole
    public var text: String
    public var sequence: Int
    public var isPinned: Bool
    public var createdAt: Date
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        conversationID: String,
        agentID: String? = nil,
        role: HarnessConversationEventRole,
        text: String,
        sequence: Int,
        isPinned: Bool = false,
        createdAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.conversationID = conversationID
        self.agentID = agentID
        self.role = role
        self.text = text
        self.sequence = sequence
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.metadata = metadata
    }
}

public struct HarnessConversationAsset: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var conversationID: String
    public var agentID: String?
    public var eventID: String?
    public var displayName: String
    public var contentType: String
    public var urlString: String
    public var byteCount: Int64?
    public var createdAt: Date
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        conversationID: String,
        agentID: String? = nil,
        eventID: String? = nil,
        displayName: String,
        contentType: String,
        urlString: String,
        byteCount: Int64? = nil,
        createdAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.conversationID = conversationID
        self.agentID = agentID
        self.eventID = eventID
        self.displayName = displayName
        self.contentType = contentType
        self.urlString = urlString
        self.byteCount = byteCount
        self.createdAt = createdAt
        self.metadata = metadata
    }
}

public struct HarnessCompactionSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var conversationID: String
    public var agentIDs: [String]
    public var eventIDs: [String]
    public var assetIDs: [String]
    public var promptCharacterCount: Int
    public var records: [AppHarnessContextCompactionRecord]
    public var createdAt: Date
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        conversationID: String,
        agentIDs: [String],
        eventIDs: [String],
        assetIDs: [String],
        promptCharacterCount: Int,
        records: [AppHarnessContextCompactionRecord],
        createdAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.conversationID = conversationID
        self.agentIDs = agentIDs
        self.eventIDs = eventIDs
        self.assetIDs = assetIDs
        self.promptCharacterCount = promptCharacterCount
        self.records = records
        self.createdAt = createdAt
        self.metadata = metadata
    }
}

public protocol HarnessConversationStoring: Sendable {
    func upsertConversation(_ conversation: HarnessConversation) async
    func conversation(id: String) async -> HarnessConversation?
    func recentConversations(limit: Int) async -> [HarnessConversation]
    func appendEvent(_ event: HarnessConversationEvent) async
    func events(conversationID: String) async -> [HarnessConversationEvent]
    func appendAsset(_ asset: HarnessConversationAsset) async
    func assets(conversationID: String) async -> [HarnessConversationAsset]
    func upsertAgentSnapshot(_ agent: HarnessAgentState) async
    func agentSnapshot(id: String) async -> HarnessAgentState?
    func agentSnapshots(conversationID: String) async -> [HarnessAgentState]
    func activeAgentSnapshots() async -> [HarnessAgentState]
    func appendAgentEvent(_ event: HarnessAgentEvent) async
    func agentEvents(agentID: String) async -> [HarnessAgentEvent]
    func appendCompactionSnapshot(_ snapshot: HarnessCompactionSnapshot) async
    func compactionSnapshots(conversationID: String, limit: Int) async -> [HarnessCompactionSnapshot]
}

public actor InMemoryHarnessConversationStore: HarnessConversationStoring {
    private var conversationsByID: [String: HarnessConversation] = [:]
    private var eventsByConversationID: [String: [HarnessConversationEvent]] = [:]
    private var assetsByConversationID: [String: [HarnessConversationAsset]] = [:]
    private var agentSnapshotsByID: [String: HarnessAgentState] = [:]
    private var agentEventsByAgentID: [String: [HarnessAgentEvent]] = [:]
    private var compactionSnapshotsByConversationID: [String: [HarnessCompactionSnapshot]] = [:]

    public init() {}

    public func upsertConversation(_ conversation: HarnessConversation) {
        conversationsByID[conversation.id] = conversation
    }

    public func conversation(id: String) -> HarnessConversation? {
        conversationsByID[id]
    }

    public func recentConversations(limit: Int) -> [HarnessConversation] {
        conversationsByID.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(max(0, limit))
            .map { $0 }
    }

    public func appendEvent(_ event: HarnessConversationEvent) {
        var events = eventsByConversationID[event.conversationID] ?? []
        if let existingIndex = events.firstIndex(where: { $0.id == event.id }) {
            events[existingIndex] = event
        } else {
            events.append(event)
        }
        events.sort {
            if $0.sequence == $1.sequence {
                return $0.createdAt < $1.createdAt
            }
            return $0.sequence < $1.sequence
        }
        eventsByConversationID[event.conversationID] = events
    }

    public func events(conversationID: String) -> [HarnessConversationEvent] {
        eventsByConversationID[conversationID] ?? []
    }

    public func appendAsset(_ asset: HarnessConversationAsset) {
        var assets = assetsByConversationID[asset.conversationID] ?? []
        if let existingIndex = assets.firstIndex(where: { $0.id == asset.id }) {
            assets[existingIndex] = asset
        } else {
            assets.append(asset)
        }
        assets.sort { $0.createdAt < $1.createdAt }
        assetsByConversationID[asset.conversationID] = assets
    }

    public func assets(conversationID: String) -> [HarnessConversationAsset] {
        assetsByConversationID[conversationID] ?? []
    }

    public func upsertAgentSnapshot(_ agent: HarnessAgentState) {
        agentSnapshotsByID[agent.id] = agent
        updateActiveAgentIDs(for: agent)
    }

    public func agentSnapshot(id: String) -> HarnessAgentState? {
        agentSnapshotsByID[id]
    }

    public func agentSnapshots(conversationID: String) -> [HarnessAgentState] {
        agentSnapshotsByID.values
            .filter { $0.conversationID == conversationID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func activeAgentSnapshots() -> [HarnessAgentState] {
        agentSnapshotsByID.values
            .filter(Self.isActiveAgent)
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func appendAgentEvent(_ event: HarnessAgentEvent) {
        var events = agentEventsByAgentID[event.agentID] ?? []
        if let existingIndex = events.firstIndex(where: { $0.id == event.id }) {
            events[existingIndex] = event
        } else {
            events.append(event)
        }
        events.sort { $0.createdAt < $1.createdAt }
        agentEventsByAgentID[event.agentID] = events
    }

    public func agentEvents(agentID: String) -> [HarnessAgentEvent] {
        agentEventsByAgentID[agentID] ?? []
    }

    public func appendCompactionSnapshot(_ snapshot: HarnessCompactionSnapshot) {
        var snapshots = compactionSnapshotsByConversationID[snapshot.conversationID] ?? []
        if let existingIndex = snapshots.firstIndex(where: { $0.id == snapshot.id }) {
            snapshots[existingIndex] = snapshot
        } else {
            snapshots.append(snapshot)
        }
        snapshots.sort { $0.createdAt < $1.createdAt }
        compactionSnapshotsByConversationID[snapshot.conversationID] = snapshots
    }

    public func compactionSnapshots(conversationID: String, limit: Int) -> [HarnessCompactionSnapshot] {
        compactionSnapshotsByConversationID[conversationID]?
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(max(0, limit))
            .map { $0 } ?? []
    }

    private static func isActiveAgent(_ agent: HarnessAgentState) -> Bool {
        [.running, .paused, .waitingForUser, .waitingForPermission, .interrupted, .resuming, .timedOut].contains(agent.status)
    }

    private func updateActiveAgentIDs(for agent: HarnessAgentState) {
        guard var conversation = conversationsByID[agent.conversationID] else { return }

        var activeAgentIDs = Set(conversation.activeAgentIDs)
        if Self.isActiveAgent(agent) {
            activeAgentIDs.insert(agent.id)
            conversation.status = .running
        } else {
            activeAgentIDs.remove(agent.id)
            if activeAgentIDs.isEmpty {
                conversation.status = agent.status
            }
        }
        conversation.activeAgentIDs = activeAgentIDs.sorted()
        conversation.updatedAt = agent.updatedAt
        conversationsByID[conversation.id] = conversation
    }
}

public actor FileHarnessConversationStore: HarnessConversationStoring {
    private let storeURL: URL
    private var snapshot: HarnessConversationStoreSnapshot

    public init(storeURL: URL? = nil) {
        let resolvedStoreURL = storeURL ?? FileHarnessConversationStore.defaultStoreURL()
        self.storeURL = resolvedStoreURL
        self.snapshot = FileHarnessConversationStore.loadSnapshot(from: resolvedStoreURL)
    }

    public static func defaultStoreURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Donkey", isDirectory: true)
            .appendingPathComponent("HarnessStore", isDirectory: true)
            .appendingPathComponent("conversations.json")
    }

    public func upsertConversation(_ conversation: HarnessConversation) {
        snapshot.conversationsByID[conversation.id] = conversation
        save()
    }

    public func conversation(id: String) -> HarnessConversation? {
        snapshot.conversationsByID[id]
    }

    public func recentConversations(limit: Int) -> [HarnessConversation] {
        snapshot.conversationsByID.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(max(0, limit))
            .map { $0 }
    }

    public func appendEvent(_ event: HarnessConversationEvent) {
        var events = snapshot.eventsByConversationID[event.conversationID] ?? []
        if let existingIndex = events.firstIndex(where: { $0.id == event.id }) {
            events[existingIndex] = event
        } else {
            events.append(event)
        }
        events.sort {
            if $0.sequence == $1.sequence {
                return $0.createdAt < $1.createdAt
            }
            return $0.sequence < $1.sequence
        }
        snapshot.eventsByConversationID[event.conversationID] = events
        save()
    }

    public func events(conversationID: String) -> [HarnessConversationEvent] {
        snapshot.eventsByConversationID[conversationID] ?? []
    }

    public func appendAsset(_ asset: HarnessConversationAsset) {
        var assets = snapshot.assetsByConversationID[asset.conversationID] ?? []
        if let existingIndex = assets.firstIndex(where: { $0.id == asset.id }) {
            assets[existingIndex] = asset
        } else {
            assets.append(asset)
        }
        assets.sort { $0.createdAt < $1.createdAt }
        snapshot.assetsByConversationID[asset.conversationID] = assets
        save()
    }

    public func assets(conversationID: String) -> [HarnessConversationAsset] {
        snapshot.assetsByConversationID[conversationID] ?? []
    }

    public func upsertAgentSnapshot(_ agent: HarnessAgentState) {
        snapshot.agentSnapshotsByID[agent.id] = agent
        updateActiveAgentIDs(for: agent)
        save()
    }

    public func agentSnapshot(id: String) -> HarnessAgentState? {
        snapshot.agentSnapshotsByID[id]
    }

    public func agentSnapshots(conversationID: String) -> [HarnessAgentState] {
        snapshot.agentSnapshotsByID.values
            .filter { $0.conversationID == conversationID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func activeAgentSnapshots() -> [HarnessAgentState] {
        snapshot.agentSnapshotsByID.values
            .filter(Self.isActiveAgent)
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func appendAgentEvent(_ event: HarnessAgentEvent) {
        var events = snapshot.agentEventsByAgentID[event.agentID] ?? []
        if let existingIndex = events.firstIndex(where: { $0.id == event.id }) {
            events[existingIndex] = event
        } else {
            events.append(event)
        }
        events.sort { $0.createdAt < $1.createdAt }
        snapshot.agentEventsByAgentID[event.agentID] = events
        save()
    }

    public func agentEvents(agentID: String) -> [HarnessAgentEvent] {
        snapshot.agentEventsByAgentID[agentID] ?? []
    }

    public func appendCompactionSnapshot(_ snapshot: HarnessCompactionSnapshot) {
        var snapshots = self.snapshot.compactionSnapshotsByConversationID[snapshot.conversationID] ?? []
        if let existingIndex = snapshots.firstIndex(where: { $0.id == snapshot.id }) {
            snapshots[existingIndex] = snapshot
        } else {
            snapshots.append(snapshot)
        }
        snapshots.sort { $0.createdAt < $1.createdAt }
        self.snapshot.compactionSnapshotsByConversationID[snapshot.conversationID] = snapshots
        save()
    }

    public func compactionSnapshots(conversationID: String, limit: Int) -> [HarnessCompactionSnapshot] {
        snapshot.compactionSnapshotsByConversationID[conversationID]?
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(max(0, limit))
            .map { $0 } ?? []
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            return
        }
    }

    private static func loadSnapshot(from url: URL) -> HarnessConversationStoreSnapshot {
        guard let data = try? Data(contentsOf: url) else {
            return HarnessConversationStoreSnapshot()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(HarnessConversationStoreSnapshot.self, from: data)) ?? HarnessConversationStoreSnapshot()
    }

    private static func isActiveAgent(_ agent: HarnessAgentState) -> Bool {
        [.running, .paused, .waitingForUser, .waitingForPermission, .interrupted, .resuming, .timedOut].contains(agent.status)
    }

    private func updateActiveAgentIDs(for agent: HarnessAgentState) {
        guard var conversation = snapshot.conversationsByID[agent.conversationID] else { return }

        var activeAgentIDs = Set(conversation.activeAgentIDs)
        if Self.isActiveAgent(agent) {
            activeAgentIDs.insert(agent.id)
            conversation.status = .running
        } else {
            activeAgentIDs.remove(agent.id)
            if activeAgentIDs.isEmpty {
                conversation.status = agent.status
            }
        }
        conversation.activeAgentIDs = activeAgentIDs.sorted()
        conversation.updatedAt = agent.updatedAt
        snapshot.conversationsByID[conversation.id] = conversation
    }
}

private struct HarnessConversationStoreSnapshot: Codable {
    var conversationsByID: [String: HarnessConversation] = [:]
    var eventsByConversationID: [String: [HarnessConversationEvent]] = [:]
    var assetsByConversationID: [String: [HarnessConversationAsset]] = [:]
    var agentSnapshotsByID: [String: HarnessAgentState] = [:]
    var agentEventsByAgentID: [String: [HarnessAgentEvent]] = [:]
    var compactionSnapshotsByConversationID: [String: [HarnessCompactionSnapshot]] = [:]
}

public struct HarnessCompactionPolicy: Codable, Equatable, Sendable {
    public var maxEvents: Int
    public var maxPinnedEvents: Int
    public var maxToolEvents: Int
    public var maxAssets: Int
    public var maxEventCharacters: Int
    public var maxPromptCharacters: Int
    public var preserveWaitingState: Bool
    /// When the rendered rolling context grows past this, fold the older turns into a fresh summary
    /// event. Kept below `maxPromptCharacters` so compaction happens before blunt truncation would bite.
    public var summaryTriggerCharacters: Int
    /// Minimum new events between two summary events, so the loop does not re-summarize every step once
    /// it is hovering near the trigger.
    public var minEventsBetweenSummaries: Int

    public init(
        maxEvents: Int = 12,
        maxPinnedEvents: Int = 6,
        maxToolEvents: Int = 4,
        maxAssets: Int = 6,
        maxEventCharacters: Int = 1_000,
        maxPromptCharacters: Int = 8_000,
        preserveWaitingState: Bool = true,
        summaryTriggerCharacters: Int = 6_000,
        minEventsBetweenSummaries: Int = 6
    ) {
        self.maxEvents = max(0, maxEvents)
        self.maxPinnedEvents = max(0, maxPinnedEvents)
        self.maxToolEvents = max(0, maxToolEvents)
        self.maxAssets = max(0, maxAssets)
        self.maxEventCharacters = max(1, maxEventCharacters)
        self.maxPromptCharacters = max(1, maxPromptCharacters)
        self.preserveWaitingState = preserveWaitingState
        self.summaryTriggerCharacters = max(1, summaryTriggerCharacters)
        self.minEventsBetweenSummaries = max(1, minEventsBetweenSummaries)
    }
}

public struct HarnessCompactedConversationContext: Codable, Equatable, Sendable {
    public var conversation: HarnessConversation
    public var currentTurn: AppHarnessTurn?
    public var events: [HarnessConversationEvent]
    public var assets: [HarnessConversationAsset]
    public var activeAgents: [HarnessAgentState]
    public var promptText: String
    public var compactionRecords: [AppHarnessContextCompactionRecord]
    public var metadata: [String: String]

    public init(
        conversation: HarnessConversation,
        currentTurn: AppHarnessTurn? = nil,
        events: [HarnessConversationEvent],
        assets: [HarnessConversationAsset],
        activeAgents: [HarnessAgentState],
        promptText: String,
        compactionRecords: [AppHarnessContextCompactionRecord],
        metadata: [String: String] = [:]
    ) {
        self.conversation = conversation
        self.currentTurn = currentTurn
        self.events = events
        self.assets = assets
        self.activeAgents = activeAgents
        self.promptText = promptText
        self.compactionRecords = compactionRecords
        self.metadata = metadata
    }
}

public struct HarnessConversationCompactor: Sendable {
    public var policy: HarnessCompactionPolicy

    public init(policy: HarnessCompactionPolicy = HarnessCompactionPolicy()) {
        self.policy = policy
    }

    public func compact(
        conversation: HarnessConversation,
        currentTurn: AppHarnessTurn? = nil,
        events: [HarnessConversationEvent],
        assets: [HarnessConversationAsset],
        activeAgents: [HarnessAgentState]
    ) -> HarnessCompactedConversationContext {
        var records: [AppHarnessContextCompactionRecord] = []
        let selectedEvents = compactEvents(events, records: &records)
        let selectedAssets = Array(assets.sorted { $0.createdAt > $1.createdAt }.prefix(policy.maxAssets))
            .sorted { $0.createdAt < $1.createdAt }
        records.append(
            AppHarnessContextCompactionRecord(
                itemKind: .asset,
                originalCount: assets.count,
                includedCount: selectedAssets.count,
                droppedCount: max(0, assets.count - selectedAssets.count)
            )
        )

        let selectedAgents = compactAgents(activeAgents, records: &records)
        let unboundedPrompt = promptText(
            conversation: conversation,
            currentTurn: currentTurn,
            events: selectedEvents,
            assets: selectedAssets,
            activeAgents: selectedAgents
        )
        let boundedPrompt = bounded(unboundedPrompt, maxCharacters: policy.maxPromptCharacters)
        records.append(
            AppHarnessContextCompactionRecord(
                itemKind: .currentTurn,
                originalCount: unboundedPrompt.count,
                includedCount: boundedPrompt.count,
                truncatedCount: unboundedPrompt.count > boundedPrompt.count ? 1 : 0,
                metadata: ["unit": "characters"]
            )
        )

        return HarnessCompactedConversationContext(
            conversation: conversation,
            currentTurn: currentTurn,
            events: selectedEvents,
            assets: selectedAssets,
            activeAgents: selectedAgents,
            promptText: boundedPrompt,
            compactionRecords: records,
            metadata: [
                "conversationStore": "generic-harness",
                "compactor": "smart-priority-v1",
                "promptTruncated": String(unboundedPrompt.count > boundedPrompt.count),
                "eventCount": String(selectedEvents.count),
                "assetCount": String(selectedAssets.count),
                "activeTaskCount": String(selectedAgents.count)
            ]
        )
    }

    private func compactEvents(
        _ events: [HarnessConversationEvent],
        records: inout [AppHarnessContextCompactionRecord]
    ) -> [HarnessConversationEvent] {
        let sorted = events.sorted {
            if $0.sequence == $1.sequence {
                return $0.createdAt < $1.createdAt
            }
            return $0.sequence < $1.sequence
        }
        let pinned = sorted.filter(\.isPinned).suffix(policy.maxPinnedEvents)
        let summaries = sorted.filter { $0.role == .summary }.suffix(2)
        let toolEvents = sorted.filter { $0.role == .tool }.suffix(policy.maxToolEvents)
        let recent = sorted.suffix(policy.maxEvents)
        let selectedIDs = Set((pinned + summaries + toolEvents + recent).map(\.id))
        let selected = sorted
            .filter { selectedIDs.contains($0.id) }
            .map { event in
                var event = event
                event.text = bounded(event.text, maxCharacters: policy.maxEventCharacters)
                return event
            }
        records.append(
            AppHarnessContextCompactionRecord(
                itemKind: .recentEvent,
                originalCount: events.count,
                includedCount: selected.count,
                droppedCount: max(0, events.count - selected.count),
                truncatedCount: selected.filter { selectedEvent in
                    events.first(where: { $0.id == selectedEvent.id })?.text.count ?? 0 > selectedEvent.text.count
                }.count,
                metadata: [
                    "strategy": "pinned+summary+tool+recent",
                    "maxEvents": String(policy.maxEvents),
                    "maxPinnedEvents": String(policy.maxPinnedEvents),
                    "maxToolEvents": String(policy.maxToolEvents)
                ]
            )
        )
        return selected
    }

    private func compactAgents(
        _ tasks: [HarnessAgentState],
        records: inout [AppHarnessContextCompactionRecord]
    ) -> [HarnessAgentState] {
        let selected = tasks.filter { agent in
            guard policy.preserveWaitingState else { return true }
            return [.running, .paused, .waitingForUser, .waitingForPermission, .interrupted, .resuming, .timedOut].contains(agent.status)
        }
        records.append(
            AppHarnessContextCompactionRecord(
                itemKind: .targetState,
                originalCount: tasks.count,
                includedCount: selected.count,
                droppedCount: max(0, tasks.count - selected.count),
                metadata: ["strategy": "preserveActiveAndWaitingTasks"]
            )
        )
        return selected
    }

    private func promptText(
        conversation: HarnessConversation,
        currentTurn: AppHarnessTurn?,
        events: [HarnessConversationEvent],
        assets: [HarnessConversationAsset],
        activeAgents: [HarnessAgentState]
    ) -> String {
        var lines: [String] = [
            "Conversation: \(conversation.title)",
            "Conversation status: \(conversation.status.rawValue)"
        ]
        if let currentTurn {
            lines.append("Current turn: \(currentTurn.text)")
        }
        if !activeAgents.isEmpty {
            lines.append("Active agents:")
            for agent in activeAgents {
                lines.append("- \(agent.id) status=\(agent.status.rawValue) goal=\(agent.goal)")
                if let continuation = agent.pendingContinuation {
                    lines.append("  pending=\(continuation.stage.rawValue) reason=\(continuation.reason)")
                    if let question = continuation.question {
                        lines.append("  question=\(question)")
                    }
                    if !continuation.missingPermissions.isEmpty {
                        lines.append("  missingPermissions=\(continuation.missingPermissions.map(\.rawValue).joined(separator: ","))")
                    }
                }
            }
        }
        if !events.isEmpty {
            lines.append("Conversation events:")
            for event in events {
                lines.append("- [\(event.sequence)] \(event.role.rawValue): \(event.text)")
            }
        }
        if !assets.isEmpty {
            lines.append("Assets:")
            for asset in assets {
                lines.append("- \(asset.displayName) \(asset.contentType) \(asset.urlString)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func bounded(_ value: String, maxCharacters: Int) -> String {
        guard value.count > maxCharacters else { return value }
        return String(value.prefix(maxCharacters))
    }
}
