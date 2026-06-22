import ApplicationServices
import AVFoundation
import CoreGraphics
import CoreServices
import Foundation

/// A macOS system (TCC) permission Donkey may need while running a task.
public enum SystemPermission: Equatable, Sendable {
    case screenRecording
    case microphone
    case accessibility
    /// Apple Events to a target app (Automation). `nil` target means System Events.
    case automation(targetBundleID: String?)
}

public enum SystemPermissionStatus: String, Sendable {
    case granted
    case notDetermined
    case denied
}

/// The single place that checks and requests macOS TCC permissions. Everything else preflights
/// through `status(_:)` (which never prompts) and only calls `request(_:)` after the user has
/// approved the in-notch pre-gate — so the system dialog never appears without the user's go-ahead.
public enum SystemPermissionCoordinator {
    /// A short user-facing label for the pre-gate banner.
    public static func displayName(_ permission: SystemPermission) -> String {
        switch permission {
        case .screenRecording:
            return "Screen Recording"
        case .microphone:
            return "Microphone"
        case .accessibility:
            return "Accessibility"
        case .automation(let bundleID):
            if let bundleID, !bundleID.isEmpty {
                return "Automation (\(bundleID))"
            }
            return "Automation"
        }
    }

    /// Whether the permission is already granted — never prompts.
    public static func status(_ permission: SystemPermission) -> SystemPermissionStatus {
        switch permission {
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            case .denied, .restricted: return .denied
            @unknown default: return .notDetermined
            }
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined
        case .automation(let bundleID):
            return automationStatus(targetBundleID: bundleID, askIfNeeded: false)
        }
    }

    public static func isGranted(_ permission: SystemPermission) -> Bool {
        status(permission) == .granted
    }

    /// Runs a System Events AppleScript ONLY when Automation consent is already granted — it never
    /// prompts. For internal niceties (e.g. un-minimizing a window before a screenshot) that must
    /// not raise a bare system dialog mid-task. The user's actual AppleScript tasks gate in the notch.
    @discardableResult
    public static func runSystemEventsScriptIfGranted(_ source: String) -> Bool {
        guard isGranted(.automation(targetBundleID: "com.apple.systemevents")) else { return false }
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }

    /// Triggers the macOS permission dialog (or the grant, for automation) and reports whether it
    /// ended up granted. Call only after the user approved the pre-gate.
    @discardableResult
    public static func request(_ permission: SystemPermission) async -> Bool {
        switch permission {
        case .screenRecording:
            return CGRequestScreenCaptureAccess()
        case .microphone:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .accessibility:
            // String value of kAXTrustedCheckOptionPrompt (the global is concurrency-unsafe to touch).
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        case .automation(let bundleID):
            return automationStatus(targetBundleID: bundleID, askIfNeeded: true) == .granted
        }
    }

    // Apple Events / Automation consent for a specific target app.
    private static func automationStatus(targetBundleID: String?, askIfNeeded: Bool) -> SystemPermissionStatus {
        let bundleID = (targetBundleID?.isEmpty == false ? targetBundleID! : "com.apple.systemevents")
        guard let data = bundleID.data(using: .utf8) else { return .notDetermined }

        var addressDesc = AEAddressDesc()
        let createStatus: OSStatus = data.withUnsafeBytes { raw in
            OSStatus(AECreateDesc(typeApplicationBundleID, raw.baseAddress, data.count, &addressDesc))
        }
        guard createStatus == noErr else { return .notDetermined }
        defer { AEDisposeDesc(&addressDesc) }

        let result = AEDeterminePermissionToAutomateTarget(&addressDesc, typeWildCard, typeWildCard, askIfNeeded)
        switch result {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .notDetermined
        default:
            // procNotFound (target not running) and other transient errors aren't a denial.
            return .notDetermined
        }
    }
}
