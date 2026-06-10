import AppKit
import Foundation

/// Focus recovery for guarded input: when the target app lost frontmost status between observe and
/// act (the user glanced elsewhere, a notification stole focus), attempt ONE activation of the app
/// the task is already driving and wait briefly for the window server to comply, instead of denying
/// the input outright. Never activates any app other than the given target.
@MainActor
public enum TargetFocusRecovery {
    /// True when the target process is frontmost, after at most one recovery activation.
    public static func ensureFrontmost(processID: pid_t) async -> Bool {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == processID { return true }
        guard let app = NSRunningApplication(processIdentifier: processID) else { return false }
        app.activate()
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == processID { return true }
        }
        return false
    }

    /// Name of whatever is in front right now, so a focus failure can tell the planner what is
    /// blocking (e.g. a system dialog or another app) instead of failing opaquely.
    public static func frontmostAppName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "another app"
    }
}
