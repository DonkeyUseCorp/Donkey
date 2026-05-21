import DonkeyContracts
@testable import DonkeyRuntime
import Foundation
import Testing

@Suite
struct AgentMemoryStoreTests {
    @Test
    func storeRecordsResolvedAndMissingLookupsAsSearchableMemory() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteAgentMemoryStore(baseDirectory: root, cleanupLegacyStores: false)

        store.record(
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
        store.record(
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

        let figmaResult = try #require(try store.search(query: AgentMemoryQuery(
            text: "open figma",
            scope: .global,
            kinds: [.localItem],
            budget: AgentMemoryRetrievalBudget(maxRecords: 3, minRelevance: 0)
        )).first)
        #expect(figmaResult.record.value == "Figma")
        #expect(figmaResult.record.kind == .localItem)

        let missingSnippet = try #require(store.contextSnippets(for: "launch ghost tool").first)
        #expect(missingSnippet.contains("agent_memory:"))
        #expect(missingSnippet.contains("status=missing"))
        #expect(missingSnippet.contains("Ghost Tool"))
    }

    @Test
    func storePrewarmsFilesFromConfiguredDirectories() throws {
        let fileRoot = temporaryDirectory()
        let storeRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: fileRoot)
            try? FileManager.default.removeItem(at: storeRoot)
        }
        try FileManager.default.createDirectory(at: fileRoot, withIntermediateDirectories: true)
        let fileURL = fileRoot.appendingPathComponent("Roadmap Notes.md")
        try "next steps".write(to: fileURL, atomically: true, encoding: .utf8)

        let store = try SQLiteAgentMemoryStore(baseDirectory: storeRoot, cleanupLegacyStores: false)
        store.prewarmDefaultLocalItems(
            options: AgentMemoryPrewarmOptions(
                applicationRoots: [],
                fileRoots: [fileRoot],
                maxItemsPerRoot: 10
            )
        )

        let result = try #require(try store.search(query: AgentMemoryQuery(
            text: "attach roadmap notes",
            scope: .global,
            kinds: [.localItem],
            budget: AgentMemoryRetrievalBudget(maxRecords: 3, minRelevance: 0)
        )).first)
        #expect(result.record.value == "Roadmap Notes.md")
        #expect(result.record.metadata["agentMemory.local.kind"] == "file")
        #expect(result.record.metadata["agentMemory.local.path"] == fileURL.path)
        #expect(result.record.metadata["agentMemory.local.source"] == "prewarm")
    }

    @Test
    func storePrewarmsTaskDefinitionsAsSearchableCapabilities() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteAgentMemoryStore(baseDirectory: root, cleanupLegacyStores: false)

        store.prewarmTaskDefinitions(BuiltInLocalAppTaskDefinitions.benchmarkFixtures)

        let result = try #require(try store.search(query: AgentMemoryQuery(
            text: "media playback",
            scope: .global,
            kinds: [.taskDefinition],
            budget: AgentMemoryRetrievalBudget(maxRecords: 4, minRelevance: 0)
        )).first)
        #expect(result.record.kind == .taskDefinition)
        #expect(result.record.metadata["taskType"] == "media_playback")
        #expect(result.record.metadata["appleScript.action"] == "music.playMediaQuery")
        #expect(store.taskDefinitions().contains { $0.taskType == "media_playback" })
        #expect(store.cachedAvailability(named: "media playback", preferredKind: nil) == nil)
    }

    @Test
    func storeCombinesFTSAndVectorRetrievalWithPromptBudget() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteAgentMemoryStore(baseDirectory: root, cleanupLegacyStores: false)

        try store.upsert(targetRecord(id: "weather", value: "Weather app search accepts city names."))
        try store.upsert(targetRecord(id: "music", value: "Music app can play an artist from the search field."))

        let results = try store.search(query: AgentMemoryQuery(
            text: "city weather search",
            targetID: "target-1",
            scope: .target,
            kinds: [.targetFact],
            budget: AgentMemoryRetrievalBudget(maxRecords: 1, maxPromptCharacters: 100, minRelevance: 0)
        ))

        #expect(results.map(\.record.id) == ["weather"])
        #expect(results.first?.lexicalScore ?? 0 > 0)
        #expect(results.first?.vectorScore ?? 0 > 0)
    }

    @Test
    func storeFiltersExpiredRecordsAndExportsJSONL() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteAgentMemoryStore(baseDirectory: root, cleanupLegacyStores: false)

        try store.upsert(targetRecord(id: "expired", value: "old fact", expiresAt: timestamp(5)))
        try store.upsert(targetRecord(id: "live", value: "fresh fact", expiresAt: timestamp(1_000)))

        let records = try store.records(
            scope: .target,
            kinds: [.targetFact],
            targetID: "target-1",
            now: timestamp(20)
        )
        #expect(records.map(\.id) == ["live"])

        let exportURL = root.appendingPathComponent("export/memory.jsonl")
        try store.exportJSONL(to: exportURL)
        let text = try String(contentsOf: exportURL, encoding: .utf8)
        #expect(text.contains("\"id\":\"expired\""))
        #expect(text.contains("\"id\":\"live\""))
    }

    @Test
    func storeDeletesLegacyJSONLDirectoriesWhenConfigured() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyDonkey = root.appendingPathComponent("Donkey", isDirectory: true)
        let legacyCache = legacyDonkey.appendingPathComponent("LocalItemResolutionCache", isDirectory: true)
        let legacyTarget = legacyDonkey.appendingPathComponent("TargetMemory", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyCache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyTarget, withIntermediateDirectories: true)

        _ = try SQLiteAgentMemoryStore(
            baseDirectory: root.appendingPathComponent("AgentMemory", isDirectory: true),
            cleanupLegacyStores: true,
            legacyDonkeyDirectory: legacyDonkey
        )

        #expect(!FileManager.default.fileExists(atPath: legacyCache.path))
        #expect(!FileManager.default.fileExists(atPath: legacyTarget.path))
    }

    private func targetRecord(
        id: String,
        value: String,
        expiresAt: RunTraceTimestamp? = nil
    ) -> AgentMemoryRecord {
        AgentMemoryRecord(
            id: id,
            scope: .target,
            kind: .targetFact,
            targetID: "target-1",
            value: value,
            createdAt: timestamp(10),
            expiresAt: expiresAt,
            durable: expiresAt == nil,
            source: AgentMemorySource(traceID: "trace-1", summary: "test"),
            metadata: ["source": "unit"]
        )
    }

    private func timestamp(_ milliseconds: UInt64) -> RunTraceTimestamp {
        RunTraceTimestamp(
            wallClock: Date(timeIntervalSince1970: Double(milliseconds) / 1_000),
            monotonicUptimeNanoseconds: milliseconds * 1_000_000
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "DonkeyAgentMemoryTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
