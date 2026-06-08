import Foundation

public enum LocalModelWorkKind: String, Codable, Equatable, Sendable {
    case taskIntent
    case plannerHint
    case memoryProposal
    case replayEvaluation
}

public enum LocalModelWorkPriority: Int, Codable, Comparable, Sendable {
    case userInteractive = 0
    case plannerHint = 10
    case memory = 20
    case replay = 30

    public static func < (lhs: LocalModelWorkPriority, rhs: LocalModelWorkPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct LocalModelWorkContext: Sendable {
    public var id: String
    public var kind: LocalModelWorkKind
    public var priority: LocalModelWorkPriority
    public var metadata: [String: String]
    private var cancellationStatus: @Sendable () async -> Bool

    public init(
        id: String,
        kind: LocalModelWorkKind,
        priority: LocalModelWorkPriority,
        metadata: [String: String] = [:],
        cancellationStatus: @escaping @Sendable () async -> Bool
    ) {
        self.id = id
        self.kind = kind
        self.priority = priority
        self.metadata = metadata
        self.cancellationStatus = cancellationStatus
    }

    public func isCancelled() async -> Bool {
        await cancellationStatus()
    }
}

public struct LocalModelPriorityWorkerSnapshot: Equatable, Sendable {
    public var currentWorkID: String?
    public var currentPriority: LocalModelWorkPriority?
    public var queuedCount: Int
    public var cancelledWorkIDs: Set<String>

    public init(
        currentWorkID: String?,
        currentPriority: LocalModelWorkPriority?,
        queuedCount: Int,
        cancelledWorkIDs: Set<String>
    ) {
        self.currentWorkID = currentWorkID
        self.currentPriority = currentPriority
        self.queuedCount = queuedCount
        self.cancelledWorkIDs = cancelledWorkIDs
    }
}

public actor LocalModelPriorityWorker {
    private struct WorkTicket: Equatable, Sendable {
        var id: String
        var kind: LocalModelWorkKind
        var priority: LocalModelWorkPriority
        var sequence: Int
        var metadata: [String: String]
    }

    private var queue: [WorkTicket] = []
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var current: WorkTicket?
    private var cancelledWorkIDs: Set<String> = []
    private var nextSequence = 0

    public init() {}

    public func submit<T: Sendable>(
        kind: LocalModelWorkKind,
        priority: LocalModelWorkPriority,
        metadata: [String: String] = [:],
        operation: @escaping @Sendable (LocalModelWorkContext) async -> T
    ) async -> T {
        let ticket = enqueue(kind: kind, priority: priority, metadata: metadata)
        await waitUntilReady(ticket)
        let context = LocalModelWorkContext(
            id: ticket.id,
            kind: kind,
            priority: priority,
            metadata: metadata,
            cancellationStatus: { [weak self] in
                guard let self else { return true }
                return await self.isCancelled(workID: ticket.id)
            }
        )
        let result = await operation(context)
        finish(ticket)
        return result
    }

    public func submit<T: Sendable>(
        kind: LocalModelWorkKind,
        priority: LocalModelWorkPriority,
        metadata: [String: String] = [:],
        operation: @escaping @Sendable () async -> T
    ) async -> T {
        await submit(
            kind: kind,
            priority: priority,
            metadata: metadata
        ) { _ in
            await operation()
        }
    }

    public func cancelCurrent() {
        guard let current else { return }
        cancelledWorkIDs.insert(current.id)
    }

    public func snapshot() -> LocalModelPriorityWorkerSnapshot {
        LocalModelPriorityWorkerSnapshot(
            currentWorkID: current?.id,
            currentPriority: current?.priority,
            queuedCount: queue.count,
            cancelledWorkIDs: cancelledWorkIDs
        )
    }

    public func isCancelled(workID: String) -> Bool {
        cancelledWorkIDs.contains(workID)
    }

    private func enqueue(
        kind: LocalModelWorkKind,
        priority: LocalModelWorkPriority,
        metadata: [String: String]
    ) -> WorkTicket {
        nextSequence += 1
        let ticket = WorkTicket(
            id: "\(kind.rawValue)-\(UUID().uuidString)",
            kind: kind,
            priority: priority,
            sequence: nextSequence,
            metadata: metadata
        )
        queue.append(ticket)
        queue.sort { lhs, rhs in
            if lhs.priority == rhs.priority {
                return lhs.sequence < rhs.sequence
            }
            return lhs.priority < rhs.priority
        }

        if let current, priority < current.priority {
            cancelledWorkIDs.insert(current.id)
        }

        return ticket
    }

    private func waitUntilReady(_ ticket: WorkTicket) async {
        await withCheckedContinuation { continuation in
            waiters[ticket.id] = continuation
            startNextIfIdle()
        }
    }

    private func finish(_ ticket: WorkTicket) {
        if current?.id == ticket.id {
            current = nil
        } else {
            queue.removeAll { $0.id == ticket.id }
        }
        cancelledWorkIDs.remove(ticket.id)
        startNextIfIdle()
    }

    private func startNextIfIdle() {
        guard current == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        current = next
        let continuation = waiters.removeValue(forKey: next.id)
        continuation?.resume()
    }
}
