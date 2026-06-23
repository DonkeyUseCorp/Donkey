import DonkeyHarness
import Foundation

/// Bridges the harness's capability permissions (`HarnessPermission`) to the macOS TCC permissions
/// (`SystemPermission`) that actually back them. The harness is platform-agnostic and only reasons
/// about capabilities; this is the single place that says which of those need a real macOS grant and
/// that turns the user's notch approval into a system request.
public enum HarnessSystemPermissionBridge {
    /// The macOS permission a harness capability requires, or nil for capabilities that are purely
    /// internal (conversation, lookups, lifecycle) and never touch TCC.
    public static func systemPermission(for permission: HarnessPermission) -> SystemPermission? {
        switch permission {
        case .screenCapture:
            return .screenRecording
        case .accessibility, .input:
            return .accessibility
        case .conversation, .memory, .appLookup, .appControl,
             .verification, .lifecycle, .userPrompt, .skillLookup:
            return nil
        }
    }

    /// Narrows a desired capability set to what's actually available now: internal capabilities pass
    /// through untouched, and a TCC-backed one is kept only when macOS currently grants it. A
    /// capability that drops out trips the registry's permission gate the first time a tool needs it,
    /// which is what surfaces the in-notch request — so onboarding can be skipped and the permission
    /// asked for in the conversation instead of being assumed.
    public static func granting(_ desired: Set<HarnessPermission>) -> Set<HarnessPermission> {
        desired.filter { permission in
            guard let system = systemPermission(for: permission) else { return true }
            return SystemPermissionCoordinator.isGranted(system)
        }
    }

    /// Requests a macOS permission after the user approved the notch gate, and reports whether it
    /// ended up granted. Microphone and Automation resolve synchronously. Accessibility flips live
    /// once the user toggles the Settings pane this opens, so a short poll catches it without a second
    /// Approve. Screen Recording can need an app relaunch — the poll then times out and the caller
    /// keeps the gate open rather than resuming into the same denial.
    public static func grantBlocking(_ permission: SystemPermission) async -> Bool {
        if SystemPermissionCoordinator.isGranted(permission) { return true }
        if await SystemPermissionCoordinator.request(permission) { return true }
        for _ in 0..<16 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if SystemPermissionCoordinator.isGranted(permission) { return true }
        }
        return false
    }
}
