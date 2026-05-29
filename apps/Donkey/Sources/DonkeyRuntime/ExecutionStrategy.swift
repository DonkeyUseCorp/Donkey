import AppKit
import Foundation

/// Whether an app can be driven via AppleScript, or must be driven through accessibility/UI.
public enum AppScriptability: String, Equatable, Sendable, Codable {
    case scriptable
    case notScriptable
    case unknown
}

/// Authoritative, app-derived signals used to classify scriptability. Kept as plain values so the
/// classification logic is pure and unit-testable independently of any live bundle lookup.
public struct AppScriptabilityFacts: Equatable, Sendable {
    public var bundleIdentifier: String?
    /// `Info.plist` `NSAppleScriptEnabled` (or presence of an `OSAScriptingDefinition` sdef). nil = unknown.
    public var appleScriptEnabled: Bool?
    /// The app ships the Electron framework (Chromium) — no useful AppleScript dictionary.
    public var isElectron: Bool

    public init(bundleIdentifier: String? = nil, appleScriptEnabled: Bool? = nil, isElectron: Bool = false) {
        self.bundleIdentifier = bundleIdentifier
        self.appleScriptEnabled = appleScriptEnabled
        self.isElectron = isElectron
    }
}

/// Pure classification of app scriptability from bundle-derived facts. No per-app allowlists: an
/// app is scriptable iff it ships a scripting dictionary, and non-scriptable if it is Electron or
/// declares no dictionary. This generalizes to any third-party app without maintaining a list.
public enum AppScriptabilityClassifier {
    public static func classify(_ facts: AppScriptabilityFacts) -> AppScriptability {
        if facts.isElectron { return .notScriptable }
        switch facts.appleScriptEnabled {
        case .some(true): return .scriptable
        case .some(false): return .notScriptable
        case .none: return .unknown
        }
    }
}

/// How the harness will act on the target app.
public enum ExecutionStrategy: String, Equatable, Sendable {
    /// Scriptable app — drive via AppleScript (skill scripts / dynamic AppleScript).
    case appleScript
    /// Non-scriptable app (Electron) or AppleScript failed — drive via accessibility + UI input.
    case accessibilityUI
}

/// Chooses the execution strategy so the harness figures it out by itself:
/// AppleScript for scriptable apps, accessibility/UI for Electron and non-scriptable apps, and an
/// automatic fallback to accessibility/UI whenever an AppleScript attempt actually fails.
public enum ExecutionStrategySelector {
    public static func strategy(
        scriptability: AppScriptability,
        appleScriptAttempted: Bool = false,
        appleScriptSucceeded: Bool? = nil
    ) -> ExecutionStrategy {
        // An AppleScript attempt that failed/blocked always falls back to the accessibility path.
        if appleScriptAttempted, appleScriptSucceeded == false {
            return .accessibilityUI
        }
        switch scriptability {
        case .notScriptable:
            return .accessibilityUI
        case .scriptable, .unknown:
            // Unknown apps: try AppleScript first; the runtime-failure rule above handles fallback.
            return .appleScript
        }
    }
}

/// Live probe that derives scriptability facts from the installed app bundle.
public struct MacAppScriptabilityProbe: Sendable {
    public init() {}

    public func facts(bundleIdentifier: String?, appName: String? = nil) -> AppScriptabilityFacts {
        guard let url = bundleURL(bundleIdentifier: bundleIdentifier, appName: appName) else {
            return AppScriptabilityFacts(bundleIdentifier: bundleIdentifier)
        }
        let info = Bundle(url: url)?.infoDictionary
        // An app declares AppleScript support via NSAppleScriptEnabled, an OSAScriptingDefinition,
        // or by shipping an .sdef dictionary. Having read the bundle, the absence of all three is a
        // definite "not scriptable" (not unknown).
        let appleScriptEnabled: Bool
        if let flag = info?["NSAppleScriptEnabled"] as? Bool {
            appleScriptEnabled = flag
        } else if let flag = info?["NSAppleScriptEnabled"] as? String {
            appleScriptEnabled = (flag as NSString).boolValue
        } else if info?["OSAScriptingDefinition"] != nil {
            appleScriptEnabled = true
        } else {
            appleScriptEnabled = hasScriptingDefinition(in: url)
        }
        let electronFramework = url
            .appendingPathComponent("Contents/Frameworks/Electron Framework.framework", isDirectory: true)
        let isElectron = FileManager.default.fileExists(atPath: electronFramework.path)
        return AppScriptabilityFacts(
            bundleIdentifier: bundleIdentifier ?? (info?["CFBundleIdentifier"] as? String),
            appleScriptEnabled: appleScriptEnabled,
            isElectron: isElectron
        )
    }

    private func hasScriptingDefinition(in bundleURL: URL) -> Bool {
        let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: resources.path) else {
            return false
        }
        return items.contains { $0.lowercased().hasSuffix(".sdef") }
    }

    public func scriptability(bundleIdentifier: String?, appName: String? = nil) -> AppScriptability {
        AppScriptabilityClassifier.classify(facts(bundleIdentifier: bundleIdentifier, appName: appName))
    }

    private func bundleURL(bundleIdentifier: String?, appName _: String?) -> URL? {
        // Resolve by bundle identifier (reliable); name-only resolution is intentionally not used.
        guard let bundleIdentifier else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
}
