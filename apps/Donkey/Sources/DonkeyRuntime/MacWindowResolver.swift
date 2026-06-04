@preconcurrency import AppKit
import CoreGraphics
import DonkeyContracts
import Foundation

public enum MacWindowResolverError: Error, Equatable, Sendable {
    case noVisibleWindows
    case noFocusedWindow
    case windowNotFound(windowID: UInt32)
}

struct MacWindowProviderWindow: Equatable, Sendable {
    var windowID: UInt32
    var processID: Int32
    var appName: String?
    var bundleIdentifier: String?
    var title: String?
    var knownApplication: MacKnownApplicationIdentity?
    var bounds: WindowTargetBounds
    var alpha: Double
    var layer: Int
    var isOnScreen: Bool

    init(
        windowID: UInt32,
        processID: Int32,
        appName: String? = nil,
        bundleIdentifier: String? = nil,
        title: String? = nil,
        knownApplication: MacKnownApplicationIdentity? = nil,
        bounds: WindowTargetBounds,
        alpha: Double = 1,
        layer: Int = 0,
        isOnScreen: Bool = true
    ) {
        self.windowID = windowID
        self.processID = processID
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.knownApplication = knownApplication
        self.bounds = bounds
        self.alpha = alpha
        self.layer = layer
        self.isOnScreen = isOnScreen
    }
}

struct MacKnownApplicationIdentity: Equatable, Sendable {
    var processID: Int32
    var bundleIdentifier: String?
    var localizedName: String?
    var executableName: String?

    init(
        processID: Int32,
        bundleIdentifier: String? = nil,
        localizedName: String? = nil,
        executableName: String? = nil
    ) {
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.executableName = executableName
    }
}

protocol MacKnownApplicationIdentityProviding {
    func identitiesByProcessIdentifier() -> [Int32: MacKnownApplicationIdentity]
}

protocol MacWindowMetadataProviding {
    func windows() -> [MacWindowProviderWindow]
    func frontmostProcessIdentifier() -> Int32?
    func focusedWindowIdentifier() -> UInt32?
}

public final class MacWindowResolver: @unchecked Sendable {
    private let provider: any MacWindowMetadataProviding

    public convenience init() {
        self.init(provider: CoreGraphicsMacWindowMetadataProvider())
    }

    init(provider: any MacWindowMetadataProviding) {
        self.provider = provider
    }

    public func enumerateCandidates() -> [MacWindowTargetCandidate] {
        let frontmostProcessID = provider.frontmostProcessIdentifier()
        let focusedWindowID = provider.focusedWindowIdentifier()
        var assignedFocusedFallback = false

        return provider.windows()
            .filter(Self.isVisibleWindow)
            .map { window in
                let isFrontmost = window.processID == frontmostProcessID
                let isFocused: Bool

                if let focusedWindowID {
                    isFocused = window.windowID == focusedWindowID
                } else if isFrontmost && !assignedFocusedFallback {
                    isFocused = true
                    assignedFocusedFallback = true
                } else {
                    isFocused = false
                }

                return MacWindowTargetCandidate(
                    windowID: window.windowID,
                    processID: window.processID,
                    appName: Self.normalizedOptional(window.appName),
                    bundleIdentifier: Self.normalizedOptional(window.bundleIdentifier),
                    title: Self.normalizedOptional(window.title),
                    bounds: window.bounds,
                    isVisible: true,
                    isOnScreen: window.isOnScreen,
                    isFrontmost: isFrontmost,
                    isFocused: isFocused,
                    isIPhoneMirroring: Self.isIPhoneMirroring(window),
                    safetyAssessment: Self.safetyAssessment(for: window)
                )
            }
    }

    public func enumerateCandidateList() -> MacWindowCandidateListSnapshot {
        MacWindowCandidateListSnapshot(candidates: enumerateCandidates())
    }

    /// The user's frontmost real window, skipping Donkey's own process and bundle so the agent never
    /// targets its own overlay. Candidates come back front-to-back, so the first non-Donkey match is
    /// the app the user was last working in. Shared by the harness run and the warm-cache monitor so
    /// the two always agree on which window is "frontmost".
    public func frontmostUserAppTarget() -> MacWindowTargetCandidate? {
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        let ownBundleID = Bundle.main.bundleIdentifier
        return enumerateCandidates().first { candidate in
            if candidate.processID == ownProcessID { return false }
            if let ownBundleID, let candidateBundle = candidate.bundleIdentifier,
               candidateBundle.caseInsensitiveCompare(ownBundleID) == .orderedSame {
                return false
            }
            return true
        }
    }

    public func selectTarget(
        _ request: MacWindowSelectionRequest = MacWindowSelectionRequest()
    ) throws -> MacWindowTargetCandidate {
        let candidates = enumerateCandidates()
        guard !candidates.isEmpty else {
            throw MacWindowResolverError.noVisibleWindows
        }

        if let windowID = request.windowID {
            guard let match = candidates.first(where: { $0.windowID == windowID }) else {
                throw MacWindowResolverError.windowNotFound(windowID: windowID)
            }

            return match
        }

        if let focused = candidates.first(where: \.isFocused) {
            return focused
        }

        if let frontmost = candidates.first(where: \.isFrontmost) {
            return frontmost
        }

        throw MacWindowResolverError.noFocusedWindow
    }

    private static func isVisibleWindow(_ window: MacWindowProviderWindow) -> Bool {
        window.isOnScreen
            && window.alpha > 0
            && window.layer == 0
            && window.bounds.hasPositiveArea
    }

    private static func isIPhoneMirroring(_ window: MacWindowProviderWindow) -> Bool {
        let haystack = searchableText(for: window)
        return haystack.contains("iphone mirroring")
            || haystack.contains("iphone")
                && haystack.contains("mirroring")
            || haystack.contains("screencontinuity")
    }

    private static func safetyAssessment(
        for window: MacWindowProviderWindow
    ) -> WindowTargetSafetyAssessment {
        var reasons: [WindowTargetSafetyReason] = []
        let haystack = searchableText(for: window)

        if haystack.contains("loginwindow")
            || haystack.contains("sign in")
            || haystack.contains("signin")
            || haystack.contains("sign-in")
            || haystack.contains("log in")
            || haystack.contains("unlock")
            || haystack.contains("authentication") {
            reasons.append(.loginSurface)
        }

        if haystack.contains("password")
            || haystack.contains("passcode")
            || haystack.contains("credential")
            || haystack.contains("keychain") {
            reasons.append(.passwordSurface)
        }

        if haystack.contains("payment")
            || haystack.contains("checkout")
            || haystack.contains("billing")
            || haystack.contains("credit card")
            || haystack.contains("card number")
            || haystack.contains("apple pay")
            || haystack.contains("paypal")
            || haystack.contains("purchase") {
            reasons.append(.paymentSurface)
        }

        if haystack.contains("permission")
            || haystack.contains("privacy & security")
            || haystack.contains("screen recording")
            || haystack.contains("accessibility") {
            reasons.append(.permissionSurface)
        }

        if haystack.contains("system settings")
            || haystack.contains("system preferences")
            || haystack.contains("securityagent")
            || haystack.contains("coreautha")
            || haystack.contains("systemuiserver")
            || haystack.contains("installer")
            || haystack.contains("software update") {
            reasons.append(.systemSurface)
        }

        if isUnderDescribed(window) {
            reasons.append(.unknownSurface)
        }

        let uniqueReasons = reasons.uniqued()
        if uniqueReasons.isEmpty {
            return WindowTargetSafetyAssessment(
                status: .allowed,
                summary: "No sensitive surface indicators detected"
            )
        }

        if uniqueReasons == [.unknownSurface] {
            return WindowTargetSafetyAssessment(
                status: .reviewRequired,
                reasons: uniqueReasons,
                summary: "Window metadata is too sparse for automatic capture"
            )
        }

        return WindowTargetSafetyAssessment(
            status: .blocked,
            reasons: uniqueReasons,
            summary: "Sensitive or system surface indicators detected"
        )
    }

    private static func isUnderDescribed(_ window: MacWindowProviderWindow) -> Bool {
        normalizedOptional(window.appName) == nil
            && normalizedOptional(window.bundleIdentifier) == nil
            && normalizedOptional(window.title) == nil
            && normalizedOptional(window.knownApplication?.bundleIdentifier) == nil
            && normalizedOptional(window.knownApplication?.localizedName) == nil
            && normalizedOptional(window.knownApplication?.executableName) == nil
    }

    private static func searchableText(for window: MacWindowProviderWindow) -> String {
        [
            window.appName,
            window.bundleIdentifier,
            window.title,
            window.knownApplication?.bundleIdentifier,
            window.knownApplication?.localizedName,
            window.knownApplication?.executableName
        ]
        .compactMap(normalizedOptional)
        .joined(separator: " ")
        .lowercased()
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }

        return trimmed
    }
}

private struct CoreGraphicsMacWindowMetadataProvider: MacWindowMetadataProviding {
    var applicationIdentityProvider: any MacKnownApplicationIdentityProviding

    init(
        applicationIdentityProvider: any MacKnownApplicationIdentityProviding = NSWorkspaceMacKnownApplicationIdentityProvider()
    ) {
        self.applicationIdentityProvider = applicationIdentityProvider
    }

    func windows() -> [MacWindowProviderWindow] {
        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        let knownApplications = applicationIdentityProvider.identitiesByProcessIdentifier()
        return rawWindows.compactMap { rawWindow in
            guard let windowID = rawWindow.uint32Value(for: kCGWindowNumber),
                  let processID = rawWindow.int32Value(for: kCGWindowOwnerPID),
                  let bounds = rawWindow.boundsValue(for: kCGWindowBounds)
            else {
                return nil
            }

            let knownApplication = knownApplications[processID]

            return MacWindowProviderWindow(
                windowID: windowID,
                processID: processID,
                appName: rawWindow.stringValue(for: kCGWindowOwnerName)
                    ?? knownApplication?.localizedName
                    ?? knownApplication?.executableName,
                bundleIdentifier: knownApplication?.bundleIdentifier,
                title: rawWindow.stringValue(for: kCGWindowName),
                knownApplication: knownApplication,
                bounds: bounds,
                alpha: rawWindow.doubleValue(for: kCGWindowAlpha) ?? 1,
                layer: rawWindow.intValue(for: kCGWindowLayer) ?? 0,
                isOnScreen: rawWindow.boolValue(for: kCGWindowIsOnscreen) ?? true
            )
        }
    }

    func frontmostProcessIdentifier() -> Int32? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func focusedWindowIdentifier() -> UInt32? {
        nil
    }
}

private struct NSWorkspaceMacKnownApplicationIdentityProvider: MacKnownApplicationIdentityProviding {
    func identitiesByProcessIdentifier() -> [Int32: MacKnownApplicationIdentity] {
        var identities: [Int32: MacKnownApplicationIdentity] = [:]
        for application in NSWorkspace.shared.runningApplications {
            let processID = application.processIdentifier
            let executableName = application.executableURL?
                .deletingPathExtension()
                .lastPathComponent
            identities[processID] = MacKnownApplicationIdentity(
                processID: processID,
                bundleIdentifier: application.bundleIdentifier,
                localizedName: application.localizedName,
                executableName: executableName
            )
        }
        return identities
    }
}

private extension Dictionary where Key == String, Value == Any {
    func stringValue(for key: CFString) -> String? {
        self[key as String] as? String
    }

    func boolValue(for key: CFString) -> Bool? {
        if let value = self[key as String] as? Bool {
            return value
        }

        return (self[key as String] as? NSNumber)?.boolValue
    }

    func intValue(for key: CFString) -> Int? {
        (self[key as String] as? NSNumber)?.intValue
    }

    func int32Value(for key: CFString) -> Int32? {
        (self[key as String] as? NSNumber)?.int32Value
    }

    func uint32Value(for key: CFString) -> UInt32? {
        (self[key as String] as? NSNumber)?.uint32Value
    }

    func doubleValue(for key: CFString) -> Double? {
        (self[key as String] as? NSNumber)?.doubleValue
    }

    func boundsValue(for key: CFString) -> WindowTargetBounds? {
        guard let rawBounds = self[key as String] as? [String: Any],
              let x = (rawBounds["X"] as? NSNumber)?.doubleValue,
              let y = (rawBounds["Y"] as? NSNumber)?.doubleValue,
              let width = (rawBounds["Width"] as? NSNumber)?.doubleValue,
              let height = (rawBounds["Height"] as? NSNumber)?.doubleValue
        else {
            return nil
        }

        return WindowTargetBounds(
            x: x,
            y: y,
            width: width,
            height: height
        )
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
