import DonkeyContracts
@testable import DonkeyRuntime
import Foundation
import Testing

@Suite
struct LocalItemResolutionCacheTests {
    @Test
    func cacheRecordsResolvedAndMissingLookupsAsSearchableMemory() throws {
        let cacheURL = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        let cache = LocalItemResolutionCache(storeURL: cacheURL)

        cache.record(
            availability: LocalAppAvailability(
                target: LocalAppTarget(
                    appName: "Figma",
                    bundleIdentifier: "com.figma.Desktop",
                    titleContains: "Figma",
                    metadata: [
                        "localItem.kind": "application",
                        "localItem.path": "/Applications/Figma.app"
                    ]
                ),
                isInstalled: true,
                appURL: URL(fileURLWithPath: "/Applications/Figma.app"),
                metadata: [
                    "provider": "test",
                    "itemKind": "application",
                    "itemURL": "/Applications/Figma.app",
                    "bundleIdentifier": "com.figma.Desktop",
                    "match": "exact"
                ]
            ),
            query: "figma",
            source: "unit"
        )
        cache.record(
            availability: LocalAppAvailability(
                target: LocalAppTarget(appName: "Ghost Tool"),
                isInstalled: false,
                metadata: [
                    "provider": "test",
                    "reason": "localItemUnavailable",
                    "requestedItemName": "ghost tool"
                ]
            ),
            query: "ghost tool",
            source: "unit-missing"
        )

        let figmaResult = try #require(cache.search(query: "open figma").first)
        #expect(figmaResult.entry.displayName == "Figma")
        #expect(figmaResult.entry.isAvailable)

        let missingSnippet = try #require(cache.contextSnippets(for: "launch ghost tool").first)
        #expect(missingSnippet.contains("local_resolution_cache:"))
        #expect(missingSnippet.contains("status=missing"))
        #expect(missingSnippet.contains("Ghost Tool"))
    }

    @Test
    func cachePrewarmsFilesFromConfiguredDirectories() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("donkey-cache-test-\(UUID().uuidString)", isDirectory: true)
        let cacheURL = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileURL = rootURL.appendingPathComponent("Roadmap Notes.md")
        try "next steps".write(to: fileURL, atomically: true, encoding: .utf8)

        let cache = LocalItemResolutionCache(storeURL: cacheURL)
        cache.prewarmDefaultLocalItems(
            options: LocalItemResolutionCachePrewarmOptions(
                applicationRoots: [],
                fileRoots: [rootURL],
                maxItemsPerRoot: 10
            )
        )

        let result = try #require(cache.search(query: "attach roadmap notes").first)
        #expect(result.entry.displayName == "Roadmap Notes.md")
        #expect(result.entry.kind == "file")
        #expect(result.entry.path == fileURL.path)
        #expect(result.entry.source == "prewarm")
    }

    @Test
    func cachePrewarmsTaskDefinitionsAsSearchableCapabilities() throws {
        let cacheURL = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
        let cache = LocalItemResolutionCache(storeURL: cacheURL)

        cache.prewarmTaskDefinitions(BuiltInLocalAppTaskDefinitions.benchmarkFixtures)

        let result = try #require(cache.search(query: "media playback", limit: 4).first { result in
            result.entry.kind == "taskDefinition"
        })
        #expect(result.entry.displayName == "media playback")
        #expect(result.entry.metadata["taskType"] == "media_playback")
        #expect(result.entry.metadata["appleScript.action"] == "music.playMediaQuery")
        #expect(cache.taskDefinitions().contains { $0.taskType == "media_playback" })
        #expect(cache.cachedAvailability(named: "media playback", preferredKind: nil) == nil)
    }

    private func temporaryCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("donkey-resolution-cache-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("cache.jsonl")
    }
}
