import Foundation

public enum UserQueryUpdateStatus: String, Equatable, Sendable {
    case notChecked
    case checking
    case upToDate
    case available
    case installing
    case unavailable
    case failed
}

public struct UserQueryUpdateState: Equatable, Sendable {
    public var status: UserQueryUpdateStatus
    public var currentVersion: String
    public var latestVersion: String?
    public var message: String?

    public init(
        status: UserQueryUpdateStatus = .notChecked,
        currentVersion: String,
        latestVersion: String? = nil,
        message: String? = nil
    ) {
        self.status = status
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.message = message
    }

    public var isActionable: Bool {
        status == .available
    }
}
