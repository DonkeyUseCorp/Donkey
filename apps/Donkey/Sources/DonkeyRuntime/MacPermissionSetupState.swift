import Foundation

public enum MacPermissionKind: String, CaseIterable, Codable, Equatable, Hashable, Identifiable, Sendable {
    case accessibility
    case screenRecording
    case microphone

    public var id: String {
        rawValue
    }

    public static let coreSetup: [MacPermissionKind] = [
        .accessibility,
        .screenRecording,
        .microphone
    ]

    public var title: String {
        switch self {
        case .accessibility:
            return "Accessibility"
        case .screenRecording:
            return "Screenshots"
        case .microphone:
            return "Microphone"
        }
    }

    public var reason: String {
        switch self {
        case .accessibility:
            return "Lets Donkey read app controls and perform approved UI actions."
        case .screenRecording:
            return "Lets Donkey capture bounded screenshots of the target window when app structure is missing."
        case .microphone:
            return "Lets you use voice input when you choose voice mode."
        }
    }

    public var detail: String {
        switch self {
        case .accessibility:
            return "Used only after a user-requested local-app workflow passes Donkey's safety checks."
        case .screenRecording:
            return "macOS calls this Screen & System Audio Recording; Donkey captures screenshots with audio disabled."
        case .microphone:
            return "Donkey does not record continuously."
        }
    }
}

public enum MacPermissionAuthorizationStatus: String, Codable, Equatable, Sendable {
    case granted
    case notDetermined
    case denied
}

public enum MacPermissionRowAction: String, Codable, Equatable, Sendable {
    case enable
    case ready
    case openSystemSettings
}

public struct MacPermissionRowState: Codable, Equatable, Identifiable, Sendable {
    public var kind: MacPermissionKind
    public var status: MacPermissionAuthorizationStatus
    public var action: MacPermissionRowAction

    public var id: MacPermissionKind {
        kind
    }

    public init(
        kind: MacPermissionKind,
        status: MacPermissionAuthorizationStatus,
        action: MacPermissionRowAction
    ) {
        self.kind = kind
        self.status = status
        self.action = action
    }
}

public struct MacPermissionSetupStateResolver: Sendable {
    public var requestedKinds: Set<MacPermissionKind>

    public init(requestedKinds: Set<MacPermissionKind> = []) {
        self.requestedKinds = requestedKinds
    }

    public func rows(
        statuses: [MacPermissionKind: MacPermissionAuthorizationStatus],
        requiredKinds: [MacPermissionKind] = MacPermissionKind.coreSetup
    ) -> [MacPermissionRowState] {
        requiredKinds.map { kind in
            row(
                kind: kind,
                status: statuses[kind] ?? .notDetermined
            )
        }
    }

    public func row(
        kind: MacPermissionKind,
        status: MacPermissionAuthorizationStatus
    ) -> MacPermissionRowState {
        let action: MacPermissionRowAction
        switch status {
        case .granted:
            action = .ready
        case .notDetermined:
            action = .enable
        case .denied:
            action = .openSystemSettings
        }

        return MacPermissionRowState(
            kind: kind,
            status: status,
            action: action
        )
    }

    public func allRequiredPermissionsGranted(
        statuses: [MacPermissionKind: MacPermissionAuthorizationStatus],
        requiredKinds: [MacPermissionKind] = MacPermissionKind.coreSetup
    ) -> Bool {
        requiredKinds.allSatisfy { statuses[$0] == .granted }
    }
}
