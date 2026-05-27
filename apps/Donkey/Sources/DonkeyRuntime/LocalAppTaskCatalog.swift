import AppKit
import DonkeyContracts
import Foundation

public struct LocalAppAvailability: Equatable, Sendable {
    public var target: LocalAppTarget
    public var isInstalled: Bool
    public var appURL: URL?
    public var metadata: [String: String]

    public init(
        target: LocalAppTarget,
        isInstalled: Bool,
        appURL: URL? = nil,
        metadata: [String: String] = [:]
    ) {
        self.target = target
        self.isInstalled = isInstalled
        self.appURL = appURL
        self.metadata = metadata
    }
}

public protocol LocalAppAvailabilityProviding: Sendable {
    func availability(for target: LocalAppTarget) -> LocalAppAvailability
    func availability(namedApp appName: String) -> LocalAppAvailability
    func availability(namedLocalItem itemName: String) -> LocalAppAvailability
    func appFinderCatalogEntries() -> [LocalAppFinderCatalogEntry]
}

public extension LocalAppAvailabilityProviding {
    func appFinderCatalogEntries() -> [LocalAppFinderCatalogEntry] {
        []
    }
}

public struct MacLocalAppAvailabilityProvider: LocalAppAvailabilityProviding {
    public init() {}

    public func appFinderCatalogEntries() -> [LocalAppFinderCatalogEntry] {
        let store = LocalAppFinderProfileStore.defaultStore
        let snapshotEntries = store.resolvedCatalogEntries()
        if !snapshotEntries.isEmpty {
            return snapshotEntries.map { entry in
                store.entry(
                    appName: entry.appName,
                    bundleIdentifier: entry.bundleIdentifier,
                    path: entry.metadata["localItem.path"]
                )
            }
        }
        return Self.cachedInstalledApplicationCatalogEntries
    }

    public func availability(for target: LocalAppTarget) -> LocalAppAvailability {
        guard let bundleIdentifier = target.bundleIdentifier else {
            return availability(namedApp: target.appName)
        }

        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        if appURL == nil,
           let cachedAvailability = SQLiteAgentMemoryStore.shared?.cachedAvailability(
            named: target.appName,
            preferredKind: .application
           ) {
            return cachedAvailability
        }

        let availability = LocalAppAvailability(
            target: target,
            isInstalled: appURL != nil,
            appURL: appURL,
            metadata: [
                "bundleIdentifier": bundleIdentifier,
                "provider": "mac-nsworkspace"
            ]
        )
        SQLiteAgentMemoryStore.shared?.record(
            availability: availability,
            query: target.appName,
            source: "bundleLookup"
        )
        return availability
    }

    public func availability(namedApp appName: String) -> LocalAppAvailability {
        availability(namedLocalItem: appName, preferredKind: .application)
    }

    public func availability(namedLocalItem itemName: String) -> LocalAppAvailability {
        availability(namedLocalItem: itemName, preferredKind: nil)
    }

    private func availability(
        namedLocalItem itemName: String,
        preferredKind: LocalItemKind?
    ) -> LocalAppAvailability {
        let requestedName = LocalAppLookup.cleanedLookupName(itemName)
        guard !requestedName.isEmpty else {
            return LocalAppAvailability(
                target: LocalAppTarget(appName: itemName),
                isInstalled: false,
                metadata: [
                    "provider": "mac-local-item-lookup",
                    "reason": "missingLookupName"
                ]
            )
        }

        if let cachedAvailability = SQLiteAgentMemoryStore.shared?.cachedAvailability(
            named: requestedName,
            preferredKind: preferredKind
        ) {
            return cachedAvailability
        }

        if preferredKind == .application,
           let runningApplication = Self.runningApplication(named: requestedName) {
            let appName = runningApplication.localizedName ?? requestedName
            let availability = LocalAppAvailability(
                target: LocalAppTarget(
                    appName: appName,
                    bundleIdentifier: runningApplication.bundleIdentifier,
                    titleContains: appName
                ),
                isInstalled: true,
                appURL: runningApplication.bundleURL,
                metadata: [
                    "provider": "mac-local-item-lookup",
                    "requestedItemName": requestedName,
                    "bundleIdentifier": runningApplication.bundleIdentifier ?? "",
                    "itemKind": LocalItemKind.application.rawValue,
                    "itemURL": runningApplication.bundleURL?.path ?? "",
                    "match": "runningApplication"
                ]
            )
            SQLiteAgentMemoryStore.shared?.record(
                availability: availability,
                query: requestedName,
                source: "runningApplication"
            )
            return availability
        }

        guard let match = Self.localItem(named: requestedName, preferredKind: preferredKind) else {
            let availability = LocalAppAvailability(
                target: LocalAppTarget(appName: LocalAppLookup.titleCased(requestedName)),
                isInstalled: false,
                metadata: [
                    "provider": "mac-local-item-lookup",
                    "reason": "localItemUnavailable",
                    "requestedItemName": requestedName
                ]
            )
            SQLiteAgentMemoryStore.shared?.record(
                availability: availability,
                query: requestedName,
                source: "missingLookup"
            )
            return availability
        }

        let defaultApplication = Self.defaultApplication(for: match)
        let availability = LocalAppAvailability(
            target: LocalAppTarget(
                appName: match.displayName,
                bundleIdentifier: match.bundleIdentifier ?? defaultApplication?.bundleIdentifier,
                titleContains: match.displayName,
                metadata: [
                    "localItem.kind": match.kind.rawValue,
                    "localItem.path": match.url.path,
                    "localItem.defaultApplication": defaultApplication?.displayName ?? ""
                ]
            ),
            isInstalled: true,
            appURL: match.url,
            metadata: [
                "provider": match.provider,
                "requestedItemName": requestedName,
                "bundleIdentifier": match.bundleIdentifier ?? defaultApplication?.bundleIdentifier ?? "",
                "itemKind": match.kind.rawValue,
                "itemURL": match.url.path,
                "defaultApplication": defaultApplication?.displayName ?? "",
                "match": match.matchKind
            ]
        )
        SQLiteAgentMemoryStore.shared?.record(
            availability: availability,
            query: requestedName,
            source: match.provider
        )
        return availability
    }

    private static func runningApplication(named appName: String) -> NSRunningApplication? {
        let normalizedName = LocalAppLookup.normalized(appName)
        return NSWorkspace.shared.runningApplications.first { application in
            guard let localizedName = application.localizedName else { return false }
            return LocalAppLookup.nameMatches(
                candidate: localizedName,
                requested: normalizedName
            ) != nil
        }
    }

    private static func localItem(
        named itemName: String,
        preferredKind: LocalItemKind?
    ) -> LocalItemMatch? {
        let normalizedName = LocalAppLookup.normalized(itemName)
        let matches = spotlightItems(named: itemName, requested: normalizedName, preferredKind: preferredKind)
            + fallbackFileSystemItems(named: normalizedName, preferredKind: preferredKind)
        return matches
            .sorted(by: LocalItemMatch.isBetterMatch)
            .first
    }

    public static func installedApplications() -> [LocalApplicationCatalogCandidate] {
        let urls = spotlightApplicationURLs() + fallbackApplicationURLs()
        var applicationsByID: [String: LocalApplicationCatalogCandidate] = [:]
        for url in urls {
            guard LocalItemKind(url: url) == .application else { continue }
            let bundle = Bundle(url: url)
            let appName = displayName(for: url, kind: .application)
            let bundleIdentifier = bundle?.bundleIdentifier
            let candidate = LocalApplicationCatalogCandidate(
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                path: url.path,
                metadata: [
                    "localItem.kind": LocalItemKind.application.rawValue,
                    "localItem.path": url.path
                ]
            )
            applicationsByID[candidate.catalogID] = candidate
        }

        return applicationsByID.values.sorted {
            if $0.appName == $1.appName {
                return $0.catalogID < $1.catalogID
            }
            return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
    }

    private static func installedApplicationCatalogEntries() -> [LocalAppFinderCatalogEntry] {
        cachedInstalledApplications
            .map { LocalAppFinderProfileStore.defaultStore.entry(for: $0) }
            .sorted {
                if $0.appName == $1.appName {
                    return $0.appID < $1.appID
                }
                return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
            }
    }

    private static let cachedInstalledApplications = installedApplications()

    private static var cachedInstalledApplicationCatalogEntries: [LocalAppFinderCatalogEntry] {
        installedApplicationCatalogEntries()
    }

    private static func spotlightApplicationURLs() -> [URL] {
        let query = #"kMDItemContentTypeTree == "com.apple.application-bundle""#
        guard let output = runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/mdfind"),
            arguments: [query],
            timeoutSeconds: 1.5
        ) else {
            return []
        }

        return output
            .split(whereSeparator: \.isNewline)
            .prefix(300)
            .map { URL(fileURLWithPath: String($0)) }
    }

    private static func fallbackApplicationURLs() -> [URL] {
        var urls: [URL] = []
        for rootURL in applicationSearchRoots() {
            guard let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let itemURL as URL in enumerator {
                guard itemURL.pathExtension == "app" else { continue }
                urls.append(itemURL)
                if urls.count >= 300 { return urls }
            }
        }
        return urls
    }

    private static func spotlightItems(
        named itemName: String,
        requested normalizedName: String,
        preferredKind: LocalItemKind?
    ) -> [LocalItemMatch] {
        let escapedName = itemName.replacingOccurrences(of: "\"", with: "\\\"")
        var query = #"kMDItemDisplayName == "*\#(escapedName)*"cd || kMDItemFSName == "*\#(escapedName)*"cd"#
        if preferredKind == .application {
            query = "(\(query)) && kMDItemContentTypeTree == \"com.apple.application-bundle\""
        }

        guard let output = runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/mdfind"),
            arguments: [query],
            timeoutSeconds: 1.5
        ) else {
            return []
        }

        return output
            .split(whereSeparator: \.isNewline)
            .prefix(100)
            .compactMap { line in
                localItemMatch(
                    url: URL(fileURLWithPath: String(line)),
                    requested: normalizedName,
                    provider: "mdfind",
                    preferredKind: preferredKind
                )
            }
    }

    private static func fallbackFileSystemItems(
        named normalizedName: String,
        preferredKind: LocalItemKind?
    ) -> [LocalItemMatch] {
        var matches: [LocalItemMatch] = []
        for rootURL in fallbackSearchRoots() {
            guard let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .contentTypeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let itemURL as URL in enumerator {
                guard let match = localItemMatch(
                    url: itemURL,
                    requested: normalizedName,
                    provider: "filesystem",
                    preferredKind: preferredKind
                ) else {
                    continue
                }
                matches.append(match)
                if matches.count >= 100 { return matches }
            }
        }

        return matches
    }

    private static func localItemMatch(
        url: URL,
        requested normalizedName: String,
        provider: String,
        preferredKind: LocalItemKind?
    ) -> LocalItemMatch? {
        let kind = LocalItemKind(url: url)
        if let preferredKind, kind != preferredKind {
            return nil
        }

        let displayName = displayName(for: url, kind: kind)
        guard let nameMatch = LocalAppLookup.nameMatches(
            candidate: displayName,
            requested: normalizedName
        ) ?? LocalAppLookup.nameMatches(
            candidate: url.deletingPathExtension().lastPathComponent,
            requested: normalizedName
        ) else {
            return nil
        }

        let bundle = kind == .application ? Bundle(url: url) : nil
        return LocalItemMatch(
            url: url,
            displayName: displayName,
            kind: kind,
            bundleIdentifier: bundle?.bundleIdentifier,
            score: nameMatch.score + kind.scoreBias(preferredKind: preferredKind),
            matchKind: nameMatch.kind,
            provider: provider
        )
    }

    private static func defaultApplication(for match: LocalItemMatch) -> LocalItemDefaultApplication? {
        guard match.kind != .application,
              let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: match.url)
        else {
            return nil
        }

        let bundle = Bundle(url: applicationURL)
        let displayName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? applicationURL.deletingPathExtension().lastPathComponent
        return LocalItemDefaultApplication(
            displayName: displayName,
            bundleIdentifier: bundle?.bundleIdentifier
        )
    }

    private static func displayName(for url: URL, kind: LocalItemKind) -> String {
        if kind == .application,
           let bundle = Bundle(url: url) {
            return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
        }

        return url.lastPathComponent
    }

    private static func fallbackSearchRoots() -> [URL] {
        let homeApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            homeApplications,
            homeDirectory.appendingPathComponent("Desktop", isDirectory: true),
            homeDirectory.appendingPathComponent("Documents", isDirectory: true),
            homeDirectory.appendingPathComponent("Downloads", isDirectory: true)
        ]
    }

    private static func applicationSearchRoots() -> [URL] {
        let homeApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            homeApplications
        ]
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) -> String? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        if process.isRunning {
            process.terminate()
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}

public struct StaticLocalAppAvailabilityProvider: LocalAppAvailabilityProviding {
    public var installedBundleIdentifiers: Set<String>
    public var installedApplicationNames: [String: String]
    public var installedLocalItemNames: [String: String]

    public init(
        installedBundleIdentifiers: Set<String>,
        installedApplicationNames: [String: String] = [:],
        installedLocalItemNames: [String: String] = [:]
    ) {
        self.installedBundleIdentifiers = installedBundleIdentifiers
        self.installedApplicationNames = installedApplicationNames
        self.installedLocalItemNames = installedLocalItemNames
    }

    public func appFinderCatalogEntries() -> [LocalAppFinderCatalogEntry] {
        var entriesByID: [String: LocalAppFinderCatalogEntry] = [:]
        for (appName, bundleIdentifier) in installedApplicationNames {
            let entry = LocalAppFinderCatalogBuilder.entry(
                appName: appName,
                bundleIdentifier: bundleIdentifier
            )
            entriesByID[entry.appID] = entry
        }
        for bundleIdentifier in installedBundleIdentifiers {
            let appName = installedApplicationNames.first { $0.value == bundleIdentifier }?.key
                ?? LocalAppFinderCatalogBuilder.inferredAppName(from: bundleIdentifier)
            let entry = LocalAppFinderCatalogBuilder.entry(
                appName: appName,
                bundleIdentifier: bundleIdentifier
            )
            entriesByID[entry.appID] = entry
        }

        return entriesByID.values.sorted {
            if $0.appName == $1.appName {
                return $0.appID < $1.appID
            }
            return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
    }

    public func availability(for target: LocalAppTarget) -> LocalAppAvailability {
        let bundleIdentifier = target.bundleIdentifier ?? ""
        guard !bundleIdentifier.isEmpty else {
            return availability(namedApp: target.appName)
        }

        return LocalAppAvailability(
            target: target,
            isInstalled: installedBundleIdentifiers.contains(bundleIdentifier),
            metadata: [
                "bundleIdentifier": bundleIdentifier,
                "provider": "static"
            ]
        )
    }

    public func availability(namedApp appName: String) -> LocalAppAvailability {
        availability(namedLocalItem: appName, preferredKind: .application)
    }

    public func availability(namedLocalItem itemName: String) -> LocalAppAvailability {
        availability(namedLocalItem: itemName, preferredKind: nil)
    }

    private func availability(
        namedLocalItem itemName: String,
        preferredKind: LocalItemKind?
    ) -> LocalAppAvailability {
        let requestedName = LocalAppLookup.cleanedLookupName(itemName)
        let normalizedRequestedName = LocalAppLookup.normalized(requestedName)
        if let match = installedApplicationNames.first(where: { item in
            LocalAppLookup.normalized(item.key) == normalizedRequestedName
        }), preferredKind == nil || preferredKind == .application {
            let bundleIdentifier = match.value
            return LocalAppAvailability(
                target: LocalAppTarget(
                    appName: match.key,
                    bundleIdentifier: bundleIdentifier,
                    titleContains: match.key,
                    metadata: [
                        "localItem.kind": LocalItemKind.application.rawValue
                    ]
                ),
                isInstalled: installedBundleIdentifiers.contains(bundleIdentifier),
                metadata: [
                    "bundleIdentifier": bundleIdentifier,
                    "provider": "static",
                    "requestedItemName": requestedName,
                    "itemKind": LocalItemKind.application.rawValue
                ]
            )
        }

        if let bundleIdentifier = installedBundleIdentifiers.first(where: { bundleIdentifier in
            LocalAppLookup.normalized(Self.inferredAppName(from: bundleIdentifier)) == normalizedRequestedName
        }), preferredKind == nil || preferredKind == .application {
            let appName = Self.inferredAppName(from: bundleIdentifier)
            return LocalAppAvailability(
                target: LocalAppTarget(
                    appName: appName,
                    bundleIdentifier: bundleIdentifier,
                    titleContains: appName,
                    metadata: [
                        "localItem.kind": LocalItemKind.application.rawValue
                    ]
                ),
                isInstalled: true,
                metadata: [
                    "bundleIdentifier": bundleIdentifier,
                    "provider": "static",
                    "requestedItemName": requestedName,
                    "itemKind": LocalItemKind.application.rawValue
                ]
            )
        }

        if let match = installedLocalItemNames.first(where: { item in
            LocalAppLookup.nameMatches(
                candidate: item.key,
                requested: normalizedRequestedName
            ) != nil || LocalAppLookup.nameMatches(
                candidate: URL(fileURLWithPath: item.key).deletingPathExtension().lastPathComponent,
                requested: normalizedRequestedName
            ) != nil
        }), preferredKind == nil || preferredKind?.rawValue == match.value {
            let itemKind = match.value
            return LocalAppAvailability(
                target: LocalAppTarget(
                    appName: match.key,
                    titleContains: match.key,
                    metadata: [
                        "localItem.kind": itemKind
                    ]
                ),
                isInstalled: true,
                metadata: [
                    "provider": "static",
                    "requestedItemName": requestedName,
                    "itemKind": itemKind
                ]
            )
        }

        return LocalAppAvailability(
            target: LocalAppTarget(appName: LocalAppLookup.titleCased(requestedName)),
            isInstalled: false,
            metadata: [
                "provider": "static",
                "reason": "localItemUnavailable",
                "requestedItemName": requestedName
            ]
        )
    }

    private static func inferredAppName(from bundleIdentifier: String) -> String {
        LocalAppFinderProfileStore.defaultStore.inferredAppName(from: bundleIdentifier)
    }
}

private struct LocalItemMatch: Equatable {
    var url: URL
    var displayName: String
    var kind: LocalItemKind
    var bundleIdentifier: String?
    var score: Int
    var matchKind: String
    var provider: String

    static func isBetterMatch(lhs: LocalItemMatch, rhs: LocalItemMatch) -> Bool {
        if lhs.score == rhs.score {
            if lhs.displayName.count == rhs.displayName.count {
                return lhs.url.path.count < rhs.url.path.count
            }
            return lhs.displayName.count < rhs.displayName.count
        }
        return lhs.score < rhs.score
    }
}

private struct LocalItemDefaultApplication: Equatable {
    var displayName: String
    var bundleIdentifier: String?
}

enum LocalItemKind: String, Equatable, Hashable {
    case application
    case folder
    case file
    case other

    init(url: URL) {
        if url.pathExtension == "app" {
            self = .application
            return
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            self = .folder
            return
        }

        self = url.pathExtension.isEmpty ? .other : .file
    }

    func scoreBias(preferredKind: LocalItemKind?) -> Int {
        if self == preferredKind {
            return -10
        }

        switch self {
        case .application:
            return 0
        case .folder:
            return 8
        case .file:
            return 12
        case .other:
            return 20
        }
    }
}

enum LocalAppLookup {
    static func cleanedLookupName(_ value: String) -> String {
        normalized(value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalized(_ value: String) -> String {
        LocalAppTextNormalizer.normalizedPhrase(value)
    }

    static func titleCased(_ value: String) -> String {
        normalized(value)
            .split(separator: " ")
            .map { word in word.prefix(1).uppercased() + word.dropFirst() }
            .joined(separator: " ")
    }

    static func nameMatches(
        candidate: String,
        requested normalizedRequestedName: String
    ) -> (score: Int, kind: String)? {
        let normalizedCandidate = normalized(candidate)
        if normalizedCandidate == normalizedRequestedName {
            return (0, "exact")
        }
        if normalizedCandidate.hasSuffix(" \(normalizedRequestedName)") {
            return (1, "suffix")
        }
        if normalizedCandidate.contains(" \(normalizedRequestedName) ") {
            return (2, "contains")
        }
        return nil
    }
}

private enum LocalAppFinderCatalogBuilder {
    static func entry(
        appName: String,
        bundleIdentifier: String?,
        path: String? = nil
    ) -> LocalAppFinderCatalogEntry {
        LocalAppFinderProfileStore.defaultStore.entry(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            path: path
        )
    }

    static func inferredAppName(from bundleIdentifier: String) -> String {
        LocalAppFinderProfileStore.defaultStore.inferredAppName(from: bundleIdentifier)
    }
}

public enum LocalAppTaskCatalogResolutionStatus: String, Equatable, Sendable {
    case resolved
    case needsConfirmation
    case unsupportedCommand
    case appUnavailable
}

public struct LocalAppTaskCatalogResolution: Equatable, Sendable {
    public var status: LocalAppTaskCatalogResolutionStatus
    public var intent: TaskIntent?
    public var definition: LocalAppTaskDefinition?
    public var availability: LocalAppAvailability?
    public var metadata: [String: String]

    public init(
        status: LocalAppTaskCatalogResolutionStatus,
        intent: TaskIntent? = nil,
        definition: LocalAppTaskDefinition? = nil,
        availability: LocalAppAvailability? = nil,
        metadata: [String: String] = [:]
    ) {
        self.status = status
        self.intent = intent
        self.definition = definition
        self.availability = availability
        self.metadata = metadata
    }
}

public struct LocalAppTaskCatalog: Sendable {
    public var taskDefinitions: [LocalAppTaskDefinition]
    public var availabilityProvider: any LocalAppAvailabilityProviding

    public init(
        taskDefinitions: [LocalAppTaskDefinition],
        availabilityProvider: any LocalAppAvailabilityProviding = MacLocalAppAvailabilityProvider()
    ) {
        self.taskDefinitions = taskDefinitions
        self.availabilityProvider = availabilityProvider
    }

    public func resolve(command _: String) -> LocalAppTaskCatalogResolution {
        LocalAppTaskCatalogResolution(
            status: .unsupportedCommand,
            metadata: ["reason": "modelIntentRequired"]
        )
    }

    public func resolve(intent: TaskIntent) -> LocalAppTaskCatalogResolution {
        if intent.confidence < Self.minimumModelIntentConfidence {
            var metadata = [
                "reason": "lowConfidenceIntent",
                "taskType": intent.taskType,
                "targetApp": intent.targetApp.appName,
                "intentConfidence": String(intent.confidence)
            ]
            for key in [
                "responseMode",
                "assistantResponse",
                "missingEntity",
                "notActionableReason"
            ] {
                if let value = intent.metadata[key], !value.isEmpty {
                    metadata[key] = value
                }
            }
            return LocalAppTaskCatalogResolution(
                status: .needsConfirmation,
                intent: intent,
                metadata: metadata
            )
        }

        if intent.taskType == Self.genericAppOpenTaskType {
            return resolveGenericAppOpen(intent: intent)
        }
        if intent.taskType == Self.genericLocalAppInteractionTaskType {
            return resolveGenericLocalAppInteraction(intent: intent)
        }

        guard let definition = taskDefinitions.first(where: { supports(intent: intent, definition: $0) }) else {
            return LocalAppTaskCatalogResolution(
                status: .unsupportedCommand,
                intent: intent,
                metadata: ["reason": "parsedIntentDefinitionMissing"]
            )
        }

        if intent.needsConfirmation {
            return LocalAppTaskCatalogResolution(
                status: .needsConfirmation,
                intent: intent,
                definition: definition,
                metadata: ["reason": intent.metadata["missingEntity"] ?? "needsConfirmation"]
            )
        }

        let availability = availabilityProvider.availability(for: definition.targetApp)
        guard availability.isInstalled else {
            return LocalAppTaskCatalogResolution(
                status: .appUnavailable,
                intent: intent,
                definition: definition,
                availability: availability,
                metadata: ["reason": "targetAppUnavailable"]
            )
        }

        return LocalAppTaskCatalogResolution(
            status: .resolved,
            intent: intent,
            definition: definition,
            availability: availability,
            metadata: [
                "taskType": definition.taskType,
                "targetApp": definition.targetApp.appName
            ]
        )
    }

    public func adapter(for definition: LocalAppTaskDefinition) -> LocalAppTaskAdapter {
        LocalAppTaskAdapter(definition: definition)
    }

    public func appFinderCatalogEntries() -> [LocalAppFinderCatalogEntry] {
        availabilityProvider.appFinderCatalogEntries()
    }

    private func supports(
        intent: TaskIntent,
        definition: LocalAppTaskDefinition
    ) -> Bool {
        intent.taskType == definition.taskType
            && intent.targetApp.appName == definition.targetApp.appName
            && intent.targetApp.bundleIdentifier == definition.targetApp.bundleIdentifier
    }

    private func resolveGenericAppOpen(intent: TaskIntent) -> LocalAppTaskCatalogResolution {
        let requestedAppName = intent.metadata["requestedItemName"]
            ?? intent.entities["appName"]
            ?? intent.targetApp.appName
        let cleanedRequestedAppName = LocalAppLookup.cleanedLookupName(requestedAppName)
        guard !cleanedRequestedAppName.isEmpty,
              cleanedRequestedAppName != LocalAppLookup.cleanedLookupName(Self.genericLocalItemTarget.appName)
        else {
            return LocalAppTaskCatalogResolution(
                status: .needsConfirmation,
                intent: intent,
                definition: Self.genericAppOpenDefinition(target: Self.genericLocalItemTarget),
                metadata: [
                    "reason": "appName",
                    "taskType": Self.genericAppOpenTaskType
                ]
            )
        }
        let availability = availabilityProvider.availability(namedLocalItem: cleanedRequestedAppName)
        let target = availability.target
        let definition = Self.genericAppOpenDefinition(target: target)
        var resolvedIntent = intent
        resolvedIntent.targetApp = target
        resolvedIntent.normalizedEntities["appName"] = target.appName
        resolvedIntent.metadata["bundleIdentifier"] = target.bundleIdentifier ?? ""
        resolvedIntent.metadata["targetApp"] = target.appName
        resolvedIntent.metadata["requestedItemName"] = cleanedRequestedAppName

        guard availability.isInstalled else {
            return LocalAppTaskCatalogResolution(
                status: .appUnavailable,
                intent: resolvedIntent,
                definition: definition,
                availability: availability,
                metadata: [
                    "reason": "targetAppUnavailable",
                    "taskType": definition.taskType,
                    "targetApp": target.appName,
                    "requestedItemName": cleanedRequestedAppName,
                    "lookupProvider": availability.metadata["provider"] ?? "",
                    "itemKind": availability.metadata["itemKind"] ?? target.metadata["localItem.kind"] ?? ""
                ]
            )
        }

        return LocalAppTaskCatalogResolution(
            status: .resolved,
            intent: resolvedIntent,
            definition: definition,
            availability: availability,
            metadata: [
                "taskType": definition.taskType,
                "targetApp": target.appName,
                "requestedItemName": cleanedRequestedAppName,
                "lookupProvider": availability.metadata["provider"] ?? "",
                "itemKind": availability.metadata["itemKind"] ?? target.metadata["localItem.kind"] ?? ""
            ]
        )
    }

    private func resolveGenericLocalAppInteraction(intent: TaskIntent) -> LocalAppTaskCatalogResolution {
        let requestedAppName = intent.metadata["requestedItemName"]
            ?? intent.normalizedEntities["appName"]
            ?? intent.entities["appName"]
            ?? intent.targetApp.appName
        let cleanedRequestedAppName = LocalAppLookup.cleanedLookupName(requestedAppName)
        guard !cleanedRequestedAppName.isEmpty,
              cleanedRequestedAppName != LocalAppLookup.cleanedLookupName(Self.genericLocalAppInteractionTarget.appName)
        else {
            return LocalAppTaskCatalogResolution(
                status: .needsConfirmation,
                intent: intent,
                definition: Self.genericLocalAppInteractionDefinition,
                metadata: [
                    "reason": "appName",
                    "taskType": Self.genericLocalAppInteractionTaskType
                ]
            )
        }

        guard let plan = intent.actionPlan else {
            return LocalAppTaskCatalogResolution(
                status: .needsConfirmation,
                intent: intent,
                definition: Self.genericLocalAppInteractionDefinition,
                metadata: [
                    "reason": "missingActionPlan",
                    "taskType": Self.genericLocalAppInteractionTaskType,
                    "targetApp": cleanedRequestedAppName
                ]
            )
        }
        guard plan.isExecutable else {
            return LocalAppTaskCatalogResolution(
                status: .needsConfirmation,
                intent: intent,
                definition: Self.genericLocalAppInteractionDefinition,
                metadata: [
                    "reason": "invalidActionPlan",
                    "taskType": Self.genericLocalAppInteractionTaskType,
                    "targetApp": cleanedRequestedAppName,
                    "plan.tools": plan.tools.map(\.rawValue).joined(separator: ",")
                ]
            )
        }

        let inputEntity = plan.inputEntity
        if plan.requiresTextInput,
           Self.entityValue(named: inputEntity, in: intent).isEmpty {
            return LocalAppTaskCatalogResolution(
                status: .needsConfirmation,
                intent: intent,
                definition: Self.genericLocalAppInteractionDefinition,
                metadata: [
                    "reason": inputEntity,
                    "taskType": Self.genericLocalAppInteractionTaskType,
                    "targetApp": cleanedRequestedAppName
                ]
            )
        }

        let availability = availabilityProvider.availability(namedApp: cleanedRequestedAppName)
        let target = availability.target
        let definition = Self.genericLocalAppInteractionDefinition(
            target: target,
            plan: plan
        )
        var resolvedIntent = intent
        resolvedIntent.targetApp = target
        resolvedIntent.normalizedEntities["appName"] = target.appName
        resolvedIntent.metadata["bundleIdentifier"] = target.bundleIdentifier ?? ""
        resolvedIntent.metadata["targetApp"] = target.appName
        resolvedIntent.metadata["requestedItemName"] = cleanedRequestedAppName

        guard availability.isInstalled else {
            return LocalAppTaskCatalogResolution(
                status: .appUnavailable,
                intent: resolvedIntent,
                definition: definition,
                availability: availability,
                metadata: [
                    "reason": "targetAppUnavailable",
                    "taskType": definition.taskType,
                    "targetApp": target.appName,
                    "requestedItemName": cleanedRequestedAppName,
                    "lookupProvider": availability.metadata["provider"] ?? "",
                    "itemKind": availability.metadata["itemKind"] ?? target.metadata["localItem.kind"] ?? ""
                ]
            )
        }

        return LocalAppTaskCatalogResolution(
            status: .resolved,
            intent: resolvedIntent,
            definition: definition,
            availability: availability,
            metadata: [
                "taskType": definition.taskType,
                "targetApp": target.appName,
                "requestedItemName": cleanedRequestedAppName,
                "lookupProvider": availability.metadata["provider"] ?? "",
                "itemKind": availability.metadata["itemKind"] ?? target.metadata["localItem.kind"] ?? "",
                "plan.tools": plan.tools.map(\.rawValue).joined(separator: ",")
            ]
        )
    }

    public static var genericLocalItemOpenDefinition: LocalAppTaskDefinition {
        genericAppOpenDefinition(target: genericLocalItemTarget)
    }

    public static var genericLocalAppInteractionDefinition: LocalAppTaskDefinition {
        genericLocalAppInteractionDefinition(
            target: genericLocalAppInteractionTarget,
            plan: .defaultSearchSubmitPlan
        )
    }

    public static func genericAppOpenDefinition(target: LocalAppTarget) -> LocalAppTaskDefinition {
        return LocalAppTaskDefinition(
            taskType: genericAppOpenTaskType,
            targetApp: target,
            triggerTerms: [],
            entityRules: [
                LocalAppTaskEntityRule(
                    name: "appName",
                    required: true,
                    metadata: [
                        "dynamicLookupEntity": "true",
                        "description": "Requested local app, file, or folder name selected by the model"
                    ]
                )
            ],
            workflowSteps: BuiltInLocalAppTaskDefinitions.commonWorkflowPrefix + [
                LocalAppTaskWorkflowStepDefinition(
                    id: "verify-opened-app",
                    role: .verifyResult,
                    summary: "Verify the target app is visible or focused"
                )
            ],
            observationStrategies: [.accessibility, .windowMetadata],
            verificationEntityName: "appName",
            metadata: [
                "catalogEntry": "generic-app-open",
                "displayTitle": "open local item",
                "taskLabelTemplate": "Open {appName}",
                "verificationTextKey": "appName",
                "domain": "app",
                "dynamicTarget": target.metadata["dynamicTarget"] ?? "false",
                "localItem.kind": target.metadata["localItem.kind"] ?? "",
                "localItem.path": target.metadata["localItem.path"] ?? ""
            ]
        )
    }

    public static func genericLocalAppInteractionDefinition(
        target: LocalAppTarget,
        plan: LocalAppActionPlan
    ) -> LocalAppTaskDefinition {
        let inputEntity = plan.inputEntity
        var metadata: [String: String] = [
            "catalogEntry": "generic-local-app-interaction",
            "displayTitle": "local app interaction",
            "taskLabelTemplate": "Use {appName}",
            "verificationTextKey": inputEntity,
            "domain": "app",
            "dynamicTarget": target.metadata["dynamicTarget"] ?? "false",
            "modelPlanned": "true",
            "plan.tools": plan.tools.map(\.rawValue).joined(separator: ","),
            "plan.verificationTools": plan.verificationTools.map(\.rawValue).joined(separator: ","),
            "plan.inputEntity": inputEntity,
            "plan.allowedTools": LocalAppActionPlanTool.allCases.map(\.rawValue).joined(separator: ","),
            "plan.setTextInputContract": "inputEntityValueIsExactTextToEnter"
        ]
        metadata["verificationMode"] = plan.requiresVisibleTextVerification
            ? "visibleText"
            : "commandAttempted"

        return LocalAppTaskDefinition(
            taskType: genericLocalAppInteractionTaskType,
            targetApp: target,
            triggerTerms: [],
            entityRules: [
                LocalAppTaskEntityRule(
                    name: "appName",
                    required: true,
                    metadata: [
                        "dynamicLookupEntity": "true",
                        "description": "Requested local app selected by the model"
                    ]
                ),
                LocalAppTaskEntityRule(
                    name: "goal",
                    required: true,
                    metadata: ["description": "Short model-selected action goal"]
                ),
                LocalAppTaskEntityRule(
                    name: "query",
                    required: false,
                    metadata: ["description": "Text to enter when the model plan includes set_text"]
                )
            ],
            workflowSteps: Self.workflowSteps(for: plan),
            observationStrategies: [.accessibility, .windowMetadata, .screenshotForLocalModel],
            verificationEntityName: inputEntity,
            metadata: metadata
        )
    }

    private static func workflowSteps(
        for plan: LocalAppActionPlan
    ) -> [LocalAppTaskWorkflowStepDefinition] {
        var steps = BuiltInLocalAppTaskDefinitions.commonWorkflowPrefix
        var submitIndex = 1
        let inputEntity = plan.inputEntity
        for tool in plan.tools {
            switch tool {
            case .openOrFocusApp, .observeApp:
                continue
            case .newDocument:
                steps.append(LocalAppTaskWorkflowStepDefinition(
                    id: "model-plan-new-document",
                    role: .submit,
                    summary: "Create a new document or note",
                    metadata: [
                        "key": "Command+N",
                        "plan.tool": tool.rawValue
                    ]
                ))
            case .focusSearch, .focusAddressBar, .focusTextEntry:
                var metadata = [
                    "controlID": plan.controlID,
                    "plan.tool": tool.rawValue
                ]
                if !plan.focusKey.isEmpty {
                    metadata["key"] = plan.focusKey
                }
                steps.append(LocalAppTaskWorkflowStepDefinition(
                    id: "model-plan-\(Self.toolSlug(tool.rawValue))",
                    role: .focusControl,
                    summary: "Focus the model-selected input control",
                    metadata: metadata
                ))
            case .setText:
                steps.append(LocalAppTaskWorkflowStepDefinition(
                    id: "model-plan-set-text",
                    role: .enterText,
                    summary: "Enter the model-selected text entity",
                    metadata: [
                        "controlID": plan.controlID,
                        "entityName": inputEntity,
                        "plan.tool": tool.rawValue
                    ]
                ))
            case .clickTarget:
                steps.append(LocalAppTaskWorkflowStepDefinition(
                    id: "model-plan-click-target-\(submitIndex)",
                    role: .submit,
                    summary: "Click the model-selected visual or Accessibility target",
                    metadata: [
                        "controlID": plan.controlID,
                        "plan.tool": tool.rawValue
                    ]
                ))
                submitIndex += 1
            case .pressReturn:
                steps.append(LocalAppTaskWorkflowStepDefinition(
                    id: "model-plan-press-return-\(submitIndex)",
                    role: .submit,
                    summary: "Submit the model-planned action",
                    metadata: [
                        "key": "Return",
                        "plan.tool": tool.rawValue
                    ]
                ))
                submitIndex += 1
            case .verifyCommand, .verifyVisibleText:
                steps.append(LocalAppTaskWorkflowStepDefinition(
                    id: "model-plan-\(Self.toolSlug(tool.rawValue))",
                    role: .verifyResult,
                    summary: "Verify the model-planned action",
                    metadata: ["plan.tool": tool.rawValue]
                ))
            }
        }
        if steps.contains(where: { $0.role == .verifyResult }) == false {
            steps.append(LocalAppTaskWorkflowStepDefinition(
                id: "model-plan-verify",
                role: .verifyResult,
                summary: "Verify the model-planned action"
            ))
        }
        return steps
    }

    private static func toolSlug(_ value: String) -> String {
        value
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: "-")
            .lowercased()
    }

    private static func entityValue(named entityName: String, in intent: TaskIntent) -> String {
        (intent.normalizedEntities[entityName] ?? intent.entities[entityName] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func slug(_ value: String) -> String {
        LocalAppTextNormalizer.normalizedPhrase(value)
            .split(separator: " ")
            .joined(separator: "-")
    }

    private static let genericAppOpenTaskType = "app_open"
    private static let genericLocalAppInteractionTaskType = "local_app_interaction"
    private static let minimumModelIntentConfidence = 0.55
    private static var genericLocalItemTarget: LocalAppTarget {
        LocalAppTarget(
            appName: "Local Item",
            titleContains: nil,
            metadata: [
                "dynamicTarget": "true",
                "localItem.kind": "dynamic"
            ]
        )
    }
    private static var genericLocalAppInteractionTarget: LocalAppTarget {
        LocalAppTarget(
            appName: "Local App",
            titleContains: nil,
            metadata: [
                "dynamicTarget": "true",
                "localItem.kind": LocalItemKind.application.rawValue
            ]
        )
    }
}

public enum BuiltInLocalAppTaskDefinitions {
    public static var commonWorkflowPrefix: [LocalAppTaskWorkflowStepDefinition] {
        [
            LocalAppTaskWorkflowStepDefinition(
                id: "parse-intent",
                role: .parseIntent,
                summary: "Parse the local app task intent"
            ),
            LocalAppTaskWorkflowStepDefinition(
                id: "launch-or-focus",
                role: .launchOrFocusApp,
                summary: "Launch or focus the target app"
            ),
            LocalAppTaskWorkflowStepDefinition(
                id: "observe-app",
                role: .observeApp,
                summary: "Observe the target app state",
                metadata: ["strategyOrder": "accessibility,windowMetadata,screenshotForLocalModel"]
            )
        ]
    }

    public static var documentFormFill: LocalAppTaskDefinition {
        LocalAppTaskDefinition(
            taskType: "document_form_fill",
            targetApp: LocalAppTarget(
                appName: "Preview",
                bundleIdentifier: "com.apple.Preview",
                titleContains: nil
            ),
            triggerTerms: [],
            entityRules: [
                LocalAppTaskEntityRule(
                    name: "document",
                    metadata: ["contextRole": "documentTarget"]
                ),
                LocalAppTaskEntityRule(
                    name: "dataSource",
                    metadata: ["contextRole": "structuredInputData"]
                )
            ],
            workflowSteps: commonWorkflowPrefix + [
                LocalAppTaskWorkflowStepDefinition(
                    id: "observe-form-fields",
                    role: .custom,
                    summary: "Discover fillable fields from Accessibility or bounded local UI understanding",
                    metadata: [
                        "requiresStructuredDataMapping": "true",
                        "preferredObservation": "accessibility,localModel"
                    ]
                ),
                LocalAppTaskWorkflowStepDefinition(
                    id: "map-data-to-fields",
                    role: .custom,
                    summary: "Map provided data to detected document fields",
                    metadata: [
                        "requiresUserData": "true",
                        "outputMustBeReviewed": "true"
                    ]
                ),
                LocalAppTaskWorkflowStepDefinition(
                    id: "verify-filled-document",
                    role: .verifyResult,
                    summary: "Verify all required fields have a proposed value"
                )
            ],
            observationStrategies: [.accessibility, .screenshotForLocalModel],
            verificationEntityName: "document",
            metadata: [
                "catalogEntry": "built-in-document-form-fill",
                "displayTitle": "document form fill",
                "taskLabelTemplate": "Fill {document}",
                "domain": "document",
                "requiresDocumentContext": "true",
                "requiresStructuredData": "true",
                "guardedLiveDefault": "reviewOnly",
                "screenshotFallback": "missingVerificationOrControls",
                "visualFallback": "localModel",
                "ocrFallbackDefault": "false"
            ]
        )
    }
}
