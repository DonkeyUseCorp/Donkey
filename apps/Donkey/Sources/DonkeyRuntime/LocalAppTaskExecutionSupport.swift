import Foundation

/// Terminal status of a user-query harness run, surfaced on `UserQueryCommandHandlingResult`.
public enum LocalAppTaskLiveRunStatus: String, Equatable, Sendable {
    case completed
    case needsUserReview
    case unsupportedCommand
    case needsConfirmation
    case appUnavailable
    case failedSafe
}
