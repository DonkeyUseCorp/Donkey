import Foundation

/// Bounds an async operation with a wall-clock deadline so one hung provider
/// call can never silently stall a user-facing run.
public enum AIDeadline {
    public struct Exceeded: Error, CustomStringConvertible {
        public let seconds: TimeInterval
        public var description: String { "deadlineExceeded after \(seconds)s" }
    }

    /// Run a throwing operation, throwing `Exceeded` if it outlives `seconds`.
    /// The losing branch is cancelled (URLSession-backed work honors this).
    public static func enforce<T: Sendable>(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Exceeded(seconds: seconds)
            }
            guard let first = try await group.next() else { throw Exceeded(seconds: seconds) }
            group.cancelAll()
            return first
        }
    }

    /// Run a best-effort operation that already degrades through `nil`,
    /// returning `nil` if it outlives `seconds`.
    public static func race<T: Sendable>(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
