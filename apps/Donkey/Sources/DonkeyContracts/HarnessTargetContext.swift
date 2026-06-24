import Foundation

/// The app a computer-use run is currently driving — shared, and mutable mid-run.
///
/// A run is no longer bound to one app for its whole life. The see/act providers (AX, vision, pointer)
/// all hold ONE of these and read it at call time, so when an observe step retargets it (the planner
/// passed `app:` to look at a different app), every later act/scroll/keystroke follows to the new app.
/// That is the structural form of "the model routes per step, like computer use": observation picks the
/// app, and because the planner always observes the surface it is about to act on, the current target is
/// the right one by construction.
///
/// A reference type so the three providers share a single instance; `@MainActor` because every read and
/// retarget happens on the main actor, where the providers and window resolution already live.
@MainActor
public final class HarnessTargetContext {
    /// The current target app's display name. Empty means no app is targeted yet — an app-less run that
    /// has not acquired one. The planner acquires an app by passing `app:` to an observe/capture tool.
    public private(set) var appName: String
    /// The current target's bundle id, when known. Pins observation/action to the exact app even if two
    /// apps share a display name.
    public private(set) var bundleIdentifier: String?

    public init(appName: String, bundleIdentifier: String?) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
    }

    /// A stable per-app cache key (bundle id when present, else the name), used by the vision parse store.
    public var appKey: String {
        if let bundleIdentifier, !bundleIdentifier.isEmpty { return bundleIdentifier }
        return appName
    }

    /// True when no app is targeted — an app-less run before it has acquired one. Observe/capture report
    /// this cleanly instead of resolving an empty name.
    public var isEmpty: Bool {
        appName.isEmpty && (bundleIdentifier?.isEmpty ?? true)
    }

    /// Point the run at a different app. Called by an observe/capture step that named an `app:` to look at,
    /// so subsequent actions resolve, focus, and route input to that app rather than the run's first one.
    public func retarget(appName: String, bundleIdentifier: String?) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
    }
}
