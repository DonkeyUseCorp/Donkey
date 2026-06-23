import Foundation

extension HarnessPermission {
    /// A short user-facing name for capabilities backed by a macOS permission the user grants, or nil
    /// for internal capabilities the user never sees in a prompt. The macOS mapping itself lives in
    /// `HarnessSystemPermissionBridge`; this is only the wording the notch shows.
    public var systemAccessName: String? {
        switch self {
        case .screenCapture:
            return "Screen Recording"
        case .accessibility, .input:
            return "Accessibility"
        case .conversation, .memory, .appLookup, .appControl,
             .verification, .lifecycle, .userPrompt, .skillLookup:
            return nil
        }
    }

    /// The notch banner text for a tool stopped on missing permissions, naming the macOS access the
    /// user needs to grant. Falls back to a generic line when nothing maps to a nameable permission.
    public static func permissionRequestSummary(for permissions: [HarnessPermission]) -> String {
        let names = permissions.compactMap(\.systemAccessName).reduce(into: [String]()) { unique, name in
            if !unique.contains(name) { unique.append(name) }
        }
        guard !names.isEmpty else { return "Donkey needs your permission to continue." }
        return "Donkey needs \(ListFormatter.localizedString(byJoining: names)) access to continue."
    }
}
