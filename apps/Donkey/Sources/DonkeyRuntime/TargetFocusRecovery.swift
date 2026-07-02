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

    /// The pid of the app in front right now, captured just before a background action that could steal
    /// focus (a `shell_exec` running `osascript … activate`, an `open -a`) so it can be handed back after.
    public static func frontmostProcessID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// Put the user's app back in front when a background action pulled another app forward. A background
    /// turn promises no focus steal, but a shell command can raise an app as a side effect outside the
    /// input guard; snapshotting the frontmost pid before the command and restoring it here makes that
    /// steal impossible to leave standing. No-op when nothing moved (still frontmost), when the snapshot
    /// app has since quit, or when it is Donkey itself — a background run never forces Donkey forward.
    public static func restoreFrontmost(to processID: pid_t) {
        guard processID != ProcessInfo.processInfo.processIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != processID,
              let app = NSRunningApplication(processIdentifier: processID) else {
            return
        }
        app.activate()
    }

    /// Run a mouse/keyboard gesture with the target briefly brought to the front, then hand focus back.
    ///
    /// This exists because a synthetic mouse click or scroll only lands on the ACTIVE app — macOS drops it
    /// for a backgrounded window no matter how it is posted (verified against a real app: pid-post, PSN-post,
    /// and the raw event-record post all leave a backgrounded window untouched; only the frontmost app moves).
    /// So a gesture on a background turn cannot be delivered invisibly; the honest path is to activate the
    /// target for the moment of the gesture and restore the user's app after. `body` runs the gesture on the
    /// real event tap while the target is front; `settle` lets the app process the last events before focus
    /// leaves. Reads (Accessibility, screenshot OCR) never take this path — only gestures that click or scroll.
    ///
    /// Returns `nil` WITHOUT running `body` when the target could not be brought to the front, so a caller
    /// never reports a gesture as done when it never landed. Pass `restore: false` on a foreground turn to
    /// leave the target up (the user is meant to watch it).
    public static func withForeground<T>(
        processID: pid_t,
        restore: Bool,
        settle: UInt64 = 180_000_000,
        _ body: () async -> T
    ) async -> T? {
        let previous = restore ? frontmostProcessID() : nil
        guard await ensureFrontmost(processID: processID) else { return nil }
        let out = await body()
        if restore {
            try? await Task.sleep(nanoseconds: settle)
            if let previous, previous != processID { restoreFrontmost(to: previous) }
        }
        return out
    }
}
