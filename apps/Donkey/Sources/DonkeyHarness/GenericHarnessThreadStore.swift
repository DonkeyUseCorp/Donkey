import DonkeyContracts
import Foundation

public enum HarnessThreadEventRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
    case system
    case tool
    case lifecycle
    case summary
}

public struct HarnessThread: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var status: HarnessTaskStatus
    public var activeTaskIDs: [String]
    public var createdAt: Date
    public var updatedAt: Date
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        title: String,
        status: HarnessTaskStatus = .running,
        activeTaskIDs: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.activeTaskIDs = activeTaskIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }
}

public struct HarnessThreadEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var threadID: String
    public var taskID: String?
    public var role: HarnessThreadEventRole
    public var text: String
    public var sequence: Int
    public var isPinned: Bool
    public var createdAt: Date
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        threadID: String,
        taskID: String? = nil,
        role: HarnessThreadEventRole,
        text: String,
        sequence: Int,
        isPinned: Bool = false,
        createdAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.threadID = threadID
        self.taskID = taskID
        self.role = role
        self.text = text
        self.sequence = sequence
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.metadata = metadata
    }
}

public struct HarnessThreadAsset: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var threadID: String
    public var taskID: String?
    public var eventID: String?
    public var displayName: String
    public var contentType: String
    public var urlString: String
    public var byteCount: Int64?
    public var createdAt: Date
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        threadID: String,
        taskID: String? = nil,
        eventID: String? = nil,
        displayName: String,
        contentType: String,
        urlString: String,
        byteCount: Int64? = nil,
        createdAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.threadID = threadID
        self.taskID = taskID
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
    public var threadID: String
    public var taskIDs: [String]
    public var eventIDs: [String]
    public var assetIDs: [String]
    public var promptCharacterCount: Int
    public var records: [AppHarnessContextCompactionRecord]
    public var createdAt: Date
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        threadID: String,
        taskIDs: [String],
        eventIDs: [String],
        assetIDs: [String],
        promptCharacterCount: Int,
        records: [AppHarnessContextCompactionRecord],
        createdAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.threadID = threadID
        self.taskIDs = taskIDs
        self.eventIDs = eventIDs
        self.assetIDs = assetIDs
        self.promptCharacterCount = promptCharacterCount
        self.records = records
        self.createdAt = createdAt
        self.metadata = metadata
    }
}

public protocol HarnessThreadStoring: Sendable {
    func upsertThread(_ thread: HarnessThread) async
    func thread(id: String) async -> HarnessThread?
    func recentThreads(limit: Int) async -> [HarnessThread]
    func appendEvent(_ event: HarnessThreadEvent) async
    func events(threadID: String) async -> [HarnessThreadEvent]
    func appendAsset(_ asset: HarnessThreadAsset) async
    func assets(threadID: String) async -> [HarnessThreadAsset]
    func upsertTaskSnapshot(_ task: HarnessTaskState) async
    func taskSnapshot(id: String) async -> HarnessTaskState?
    func taskSnapshots(threadID: String) async -> [HarnessTaskState]
    func activeTaskSnapshots() async -> [HarnessTaskState]
    func appendTaskEvent(_ event: HarnessTaskEvent) async
    func taskEvents(taskID: String) async -> [HarnessTaskEvent]
    func appendCompactionSnapshot(_ snapshot: HarnessCompactionSnapshot) async
    func compactionSnapshots(threadID: String, limit: Int) async -> [HarnessCompactionSnapshot]
}

public actor InMemoryHarnessThreadStore: HarnessThreadStoring {
    private var threadsByID: [String: HarnessThread] = [:]
    private var eventsByThreadID: [String: [HarnessThreadEvent]] = [:]
    private var assetsByThreadID: [String: [HarnessThreadAsset]] = [:]
    private var taskSnapshotsByID: [String: HarnessTaskState] = [:]
    private var taskEventsByTaskID: [String: [HarnessTaskEvent]] = [:]
    private var compactionSnapshotsByThreadID: [String: [HarnessCompactionSnapshot]] = [:]

    public init() {}

    public func upsertThread(_ thread: HarnessThread) {
        threadsByID[thread.id] = thread
    }

    public func thread(id: String) -> HarnessThread? {
        threadsByID[id]
    }

    public func recentThreads(limit: Int) -> [HarnessThread] {
        threadsByID.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(max(0, limit))
            .map { $0 }
    }

    public func appendEvent(_ event: HarnessThreadEvent) {
        var events = eventsByThreadID[event.threadID] ?? []
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
        eventsByThreadID[event.threadID] = events
    }

    public func events(threadID: String) -> [HarnessThreadEvent] {
        eventsByThreadID[threadID] ?? []
    }

    public func appendAsset(_ asset: HarnessThreadAsset) {
        var assets = assetsByThreadID[asset.threadID] ?? []
        if let existingIndex = assets.firstIndex(where: { $0.id == asset.id }) {
            assets[existingIndex] = asset
        } else {
            assets.append(asset)
        }
        assets.sort { $0.createdAt < $1.createdAt }
        assetsByThreadID[asset.threadID] = assets
    }

    public func assets(threadID: String) -> [HarnessThreadAsset] {
        assetsByThreadID[threadID] ?? []
    }

    public func upsertTaskSnapshot(_ task: HarnessTaskState) {
        taskSnapshotsByID[task.id] = task
        updateActiveTaskIDs(for: task)
    }

    public func taskSnapshot(id: String) -> HarnessTaskState? {
        taskSnapshotsByID[id]
    }

    public func taskSnapshots(threadID: String) -> [HarnessTaskState] {
        taskSnapshotsByID.values
            .filter { $0.threadID == threadID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func activeTaskSnapshots() -> [HarnessTaskState] {
        taskSnapshotsByID.values
            .filter(Self.isActiveTask)
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func appendTaskEvent(_ event: HarnessTaskEvent) {
        var events = taskEventsByTaskID[event.taskID] ?? []
        if let existingIndex = events.firstIndex(where: { $0.id == event.id }) {
            events[existingIndex] = event
        } else {
            events.append(event)
        }
        events.sort { $0.createdAt < $1.createdAt }
        taskEventsByTaskID[event.taskID] = events
    }

    public func taskEvents(taskID: String) -> [HarnessTaskEvent] {
        taskEventsByTaskID[taskID] ?? []
    }

    public func appendCompactionSnapshot(_ snapshot: HarnessCompactionSnapshot) {
        var snapshots = compactionSnapshotsByThreadID[snapshot.threadID] ?? []
        if let existingIndex = snapshots.firstIndex(where: { $0.id == snapshot.id }) {
            snapshots[existingIndex] = snapshot
        } else {
            snapshots.append(snapshot)
        }
        snapshots.sort { $0.createdAt < $1.createdAt }
        compactionSnapshotsByThreadID[snapshot.threadID] = snapshots
    }

    public func compactionSnapshots(threadID: String, limit: Int) -> [HarnessCompactionSnapshot] {
        compactionSnapshotsByThreadID[threadID]?
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(max(0, limit))
            .map { $0 } ?? []
    }

    private static func isActiveTask(_ task: HarnessTaskState) -> Bool {
        [.running, .paused, .waitingForUser, .waitingForPermission, .interrupted, .resuming, .timedOut].contains(task.status)
    }

    private func updateActiveTaskIDs(for task: HarnessTaskState) {
        guard var thread = threadsByID[task.threadID] else { return }

        var activeTaskIDs = Set(thread.activeTaskIDs)
        if Self.isActiveTask(task) {
            activeTaskIDs.insert(task.id)
            thread.status = .running
        } else {
            activeTaskIDs.remove(task.id)
            if activeTaskIDs.isEmpty {
                thread.status = task.status
            }
        }
        thread.activeTaskIDs = activeTaskIDs.sorted()
        thread.updatedAt = task.updatedAt
        threadsByID[thread.id] = thread
    }
}

public actor FileHarnessThreadStore: HarnessThreadStoring {
    private let storeURL: URL
    private var snapshot: HarnessThreadStoreSnapshot

    public init(storeURL: URL? = nil) {
        let resolvedStoreURL = storeURL ?? FileHarnessThreadStore.defaultStoreURL()
        self.storeURL = resolvedStoreURL
        self.snapshot = FileHarnessThreadStore.loadSnapshot(from: resolvedStoreURL)
    }

    public static func defaultStoreURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Donkey", isDirectory: true)
            .appendingPathComponent("HarnessStore", isDirectory: true)
            .appendingPathComponent("store.json")
    }

    public func upsertThread(_ thread: HarnessThread) {
        snapshot.threadsByID[thread.id] = thread
        save()
    }

    public func thread(id: String) -> HarnessThread? {
        snapshot.threadsByID[id]
    }

    public func recentThreads(limit: Int) -> [HarnessThread] {
        snapshot.threadsByID.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(max(0, limit))
            .map { $0 }
    }

    public func appendEvent(_ event: HarnessThreadEvent) {
        var events = snapshot.eventsByThreadID[event.threadID] ?? []
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
        snapshot.eventsByThreadID[event.threadID] = events
        save()
    }

    public func events(threadID: String) -> [HarnessThreadEvent] {
        snapshot.eventsByThreadID[threadID] ?? []
    }

    public func appendAsset(_ asset: HarnessThreadAsset) {
        var assets = snapshot.assetsByThreadID[asset.threadID] ?? []
        if let existingIndex = assets.firstIndex(where: { $0.id == asset.id }) {
            assets[existingIndex] = asset
        } else {
            assets.append(asset)
        }
        assets.sort { $0.createdAt < $1.createdAt }
        snapshot.assetsByThreadID[asset.threadID] = assets
        save()
    }

    public func assets(threadID: String) -> [HarnessThreadAsset] {
        snapshot.assetsByThreadID[threadID] ?? []
    }

    public func upsertTaskSnapshot(_ task: HarnessTaskState) {
        snapshot.taskSnapshotsByID[task.id] = task
        updateActiveTaskIDs(for: task)
        save()
    }

    public func taskSnapshot(id: String) -> HarnessTaskState? {
        snapshot.taskSnapshotsByID[id]
    }

    public func taskSnapshots(threadID: String) -> [HarnessTaskState] {
        snapshot.taskSnapshotsByID.values
            .filter { $0.threadID == threadID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func activeTaskSnapshots() -> [HarnessTaskState] {
        snapshot.taskSnapshotsByID.values
            .filter(Self.isActiveTask)
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func appendTaskEvent(_ event: HarnessTaskEvent) {
        var events = snapshot.taskEventsByTaskID[event.taskID] ?? []
        if let existingIndex = events.firstIndex(where: { $0.id == event.id }) {
            events[existingIndex] = event
        } else {
            events.append(event)
        }
        events.sort { $0.createdAt < $1.createdAt }
        snapshot.taskEventsByTaskID[event.taskID] = events
        save()
    }

    public func taskEvents(taskID: String) -> [HarnessTaskEvent] {
        snapshot.taskEventsByTaskID[taskID] ?? []
    }

    public func appendCompactionSnapshot(_ snapshot: HarnessCompactionSnapshot) {
        var snapshots = self.snapshot.compactionSnapshotsByThreadID[snapshot.threadID] ?? []
        if let existingIndex = snapshots.firstIndex(where: { $0.id == snapshot.id }) {
            snapshots[existingIndex] = snapshot
        } else {
            snapshots.append(snapshot)
        }
        snapshots.sort { $0.createdAt < $1.createdAt }
        self.snapshot.compactionSnapshotsByThreadID[snapshot.threadID] = snapshots
        save()
    }

    public func compactionSnapshots(threadID: String, limit: Int) -> [HarnessCompactionSnapshot] {
        snapshot.compactionSnapshotsByThreadID[threadID]?
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

    private static func loadSnapshot(from url: URL) -> HarnessThreadStoreSnapshot {
        guard let data = try? Data(contentsOf: url) else {
            return HarnessThreadStoreSnapshot()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(HarnessThreadStoreSnapshot.self, from: data)) ?? HarnessThreadStoreSnapshot()
    }

    private static func isActiveTask(_ task: HarnessTaskState) -> Bool {
        [.running, .paused, .waitingForUser, .waitingForPermission, .interrupted, .resuming, .timedOut].contains(task.status)
    }

    private func updateActiveTaskIDs(for task: HarnessTaskState) {
        guard var thread = snapshot.threadsByID[task.threadID] else { return }

        var activeTaskIDs = Set(thread.activeTaskIDs)
        if Self.isActiveTask(task) {
            activeTaskIDs.insert(task.id)
            thread.status = .running
        } else {
            activeTaskIDs.remove(task.id)
            if activeTaskIDs.isEmpty {
                thread.status = task.status
            }
        }
        thread.activeTaskIDs = activeTaskIDs.sorted()
        thread.updatedAt = task.updatedAt
        snapshot.threadsByID[thread.id] = thread
    }
}

private struct HarnessThreadStoreSnapshot: Codable {
    var threadsByID: [String: HarnessThread] = [:]
    var eventsByThreadID: [String: [HarnessThreadEvent]] = [:]
    var assetsByThreadID: [String: [HarnessThreadAsset]] = [:]
    var taskSnapshotsByID: [String: HarnessTaskState] = [:]
    var taskEventsByTaskID: [String: [HarnessTaskEvent]] = [:]
    var compactionSnapshotsByThreadID: [String: [HarnessCompactionSnapshot]] = [:]
}

public struct HarnessCompactionPolicy: Codable, Equatable, Sendable {
    public var maxEvents: Int
    public var maxPinnedEvents: Int
    public var maxToolEvents: Int
    public var maxAssets: Int
    public var maxEventCharacters: Int
    public var maxPromptCharacters: Int
    public var preserveWaitingState: Bool

    public init(
        maxEvents: Int = 12,
        maxPinnedEvents: Int = 6,
        maxToolEvents: Int = 4,
        maxAssets: Int = 6,
        maxEventCharacters: Int = 1_000,
        maxPromptCharacters: Int = 8_000,
        preserveWaitingState: Bool = true
    ) {
        self.maxEvents = max(0, maxEvents)
        self.maxPinnedEvents = max(0, maxPinnedEvents)
        self.maxToolEvents = max(0, maxToolEvents)
        self.maxAssets = max(0, maxAssets)
        self.maxEventCharacters = max(1, maxEventCharacters)
        self.maxPromptCharacters = max(1, maxPromptCharacters)
        self.preserveWaitingState = preserveWaitingState
    }
}

public struct HarnessCompactedThreadContext: Codable, Equatable, Sendable {
    public var thread: HarnessThread
    public var currentTurn: AppHarnessTurn?
    public var events: [HarnessThreadEvent]
    public var assets: [HarnessThreadAsset]
    public var activeTasks: [HarnessTaskState]
    public var promptText: String
    public var compactionRecords: [AppHarnessContextCompactionRecord]
    public var metadata: [String: String]

    public init(
        thread: HarnessThread,
        currentTurn: AppHarnessTurn? = nil,
        events: [HarnessThreadEvent],
        assets: [HarnessThreadAsset],
        activeTasks: [HarnessTaskState],
        promptText: String,
        compactionRecords: [AppHarnessContextCompactionRecord],
        metadata: [String: String] = [:]
    ) {
        self.thread = thread
        self.currentTurn = currentTurn
        self.events = events
        self.assets = assets
        self.activeTasks = activeTasks
        self.promptText = promptText
        self.compactionRecords = compactionRecords
        self.metadata = metadata
    }
}

public struct HarnessThreadCompactor: Sendable {
    public var policy: HarnessCompactionPolicy

    public init(policy: HarnessCompactionPolicy = HarnessCompactionPolicy()) {
        self.policy = policy
    }

    public func compact(
        thread: HarnessThread,
        currentTurn: AppHarnessTurn? = nil,
        events: [HarnessThreadEvent],
        assets: [HarnessThreadAsset],
        activeTasks: [HarnessTaskState]
    ) -> HarnessCompactedThreadContext {
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

        let selectedTasks = compactTasks(activeTasks, records: &records)
        let unboundedPrompt = promptText(
            thread: thread,
            currentTurn: currentTurn,
            events: selectedEvents,
            assets: selectedAssets,
            activeTasks: selectedTasks
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

        return HarnessCompactedThreadContext(
            thread: thread,
            currentTurn: currentTurn,
            events: selectedEvents,
            assets: selectedAssets,
            activeTasks: selectedTasks,
            promptText: boundedPrompt,
            compactionRecords: records,
            metadata: [
                "threadStore": "generic-harness",
                "compactor": "smart-priority-v1",
                "promptTruncated": String(unboundedPrompt.count > boundedPrompt.count),
                "eventCount": String(selectedEvents.count),
                "assetCount": String(selectedAssets.count),
                "activeTaskCount": String(selectedTasks.count)
            ]
        )
    }

    private func compactEvents(
        _ events: [HarnessThreadEvent],
        records: inout [AppHarnessContextCompactionRecord]
    ) -> [HarnessThreadEvent] {
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

    private func compactTasks(
        _ tasks: [HarnessTaskState],
        records: inout [AppHarnessContextCompactionRecord]
    ) -> [HarnessTaskState] {
        let selected = tasks.filter { task in
            guard policy.preserveWaitingState else { return true }
            return [.running, .paused, .waitingForUser, .waitingForPermission, .interrupted, .resuming, .timedOut].contains(task.status)
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
        thread: HarnessThread,
        currentTurn: AppHarnessTurn?,
        events: [HarnessThreadEvent],
        assets: [HarnessThreadAsset],
        activeTasks: [HarnessTaskState]
    ) -> String {
        var lines: [String] = [
            "Thread: \(thread.title)",
            "Thread status: \(thread.status.rawValue)"
        ]
        if let currentTurn {
            lines.append("Current turn: \(currentTurn.text)")
        }
        if !activeTasks.isEmpty {
            lines.append("Active tasks:")
            for task in activeTasks {
                lines.append("- \(task.id) status=\(task.status.rawValue) goal=\(task.goal)")
                if let continuation = task.pendingContinuation {
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
            lines.append("Thread events:")
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
