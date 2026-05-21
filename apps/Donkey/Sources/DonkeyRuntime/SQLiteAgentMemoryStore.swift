import AppKit
import DonkeyContracts
import Foundation
import SQLite3

public enum AgentMemoryStoreError: Error, Equatable, Sendable {
    case openFailed(String)
    case sqliteFailure(String)
    case invalidIdentifier(String)
    case missingRequiredScope
}

public protocol AgentMemoryEmbeddingProviding: Sendable {
    var modelID: String { get }
    var dimensions: Int { get }
    func embedding(for text: String) -> [Float]
}

public struct HashingAgentMemoryEmbeddingProvider: AgentMemoryEmbeddingProviding {
    public let modelID = "local-hashing-agent-memory-embedding-v1"
    public let dimensions: Int

    public init(dimensions: Int = 256) {
        self.dimensions = max(1, dimensions)
    }

    public func embedding(for text: String) -> [Float] {
        var vector = Array(repeating: Float(0), count: dimensions)
        for token in Self.tokens(in: text) {
            let index = Int(Self.fnv1a(token) % UInt64(dimensions))
            vector[index] += 1
        }
        let magnitude = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }

    static func tokens(in text: String) -> [String] {
        text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private static func fnv1a(_ token: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in token.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

public struct AgentMemoryPrewarmOptions: Sendable {
    public var applicationRoots: [URL]
    public var fileRoots: [URL]
    public var maxItemsPerRoot: Int

    public init(
        applicationRoots: [URL],
        fileRoots: [URL],
        maxItemsPerRoot: Int = 600
    ) {
        self.applicationRoots = applicationRoots
        self.fileRoots = fileRoots
        self.maxItemsPerRoot = max(0, maxItemsPerRoot)
    }

    public static func defaults() -> AgentMemoryPrewarmOptions {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        return AgentMemoryPrewarmOptions(
            applicationRoots: [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
                URL(fileURLWithPath: "/System/Applications", isDirectory: true),
                URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
                homeDirectory.appendingPathComponent("Applications", isDirectory: true)
            ],
            fileRoots: [
                homeDirectory.appendingPathComponent("Desktop", isDirectory: true),
                homeDirectory.appendingPathComponent("Documents", isDirectory: true),
                homeDirectory.appendingPathComponent("Downloads", isDirectory: true)
            ]
        )
    }
}

public final class SQLiteAgentMemoryStore: @unchecked Sendable {
    public static let shared: SQLiteAgentMemoryStore? = try? SQLiteAgentMemoryStore()

    private let baseDirectory: URL
    private let storeURL: URL
    private let fileManager: FileManager
    private let embeddingProvider: any AgentMemoryEmbeddingProviding
    private let lock = NSRecursiveLock()
    private var db: OpaquePointer?
    private var isPrewarming = false

    public init(
        baseDirectory: URL? = nil,
        fileManager: FileManager = .default,
        embeddingProvider: any AgentMemoryEmbeddingProviding = HashingAgentMemoryEmbeddingProvider(),
        cleanupLegacyStores: Bool = true,
        legacyDonkeyDirectory: URL? = nil
    ) throws {
        self.fileManager = fileManager
        self.embeddingProvider = embeddingProvider
        let usingDefaultDirectory = baseDirectory == nil
        let resolvedBaseDirectory = try baseDirectory ?? Self.defaultBaseDirectory(fileManager: fileManager)
        self.baseDirectory = resolvedBaseDirectory
        self.storeURL = resolvedBaseDirectory.appendingPathComponent("agent-memory.sqlite", isDirectory: false)

        try fileManager.createDirectory(at: resolvedBaseDirectory, withIntermediateDirectories: true)
        if cleanupLegacyStores && (usingDefaultDirectory || legacyDonkeyDirectory != nil) {
            Self.deleteLegacyStores(fileManager: fileManager, donkeyDirectoryOverride: legacyDonkeyDirectory)
        }

        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw AgentMemoryStoreError.openFailed(Self.message(from: db))
        }

        do {
            try configure()
            try createSchema()
        } catch {
            sqlite3_close(db)
            db = nil
            throw error
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    public static func defaultBaseDirectory(fileManager: FileManager = .default) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return applicationSupport
            .appendingPathComponent("Donkey", isDirectory: true)
            .appendingPathComponent("AgentMemory", isDirectory: true)
    }

    public func upsert(_ record: AgentMemoryRecord) throws {
        let searchText = Self.searchText(for: record)
        let vector = embeddingProvider.embedding(for: searchText)
        var storedRecord = record
        storedRecord.embedding = AgentMemoryEmbeddingMetadata(
            modelID: embeddingProvider.modelID,
            dimensions: vector.count
        )
        let recordJSON = String(decoding: try Self.encoder().encode(storedRecord), as: UTF8.self)

        lock.lock()
        defer { lock.unlock() }
        try transaction {
            let sql = """
            INSERT INTO memory_records (
                id, scope, kind, target_id, run_id, user_id, value,
                created_wall, created_uptime_ns, expires_wall, expires_uptime_ns,
                durable, source_json, metadata_json, confidence, use_count,
                last_used_wall, last_used_uptime_ns, search_text, record_json,
                embedding_model_id, embedding_dimensions, updated_wall
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                scope=excluded.scope,
                kind=excluded.kind,
                target_id=excluded.target_id,
                run_id=excluded.run_id,
                user_id=excluded.user_id,
                value=excluded.value,
                created_wall=excluded.created_wall,
                created_uptime_ns=excluded.created_uptime_ns,
                expires_wall=excluded.expires_wall,
                expires_uptime_ns=excluded.expires_uptime_ns,
                durable=excluded.durable,
                source_json=excluded.source_json,
                metadata_json=excluded.metadata_json,
                confidence=excluded.confidence,
                use_count=max(memory_records.use_count, excluded.use_count),
                last_used_wall=excluded.last_used_wall,
                last_used_uptime_ns=excluded.last_used_uptime_ns,
                search_text=excluded.search_text,
                record_json=excluded.record_json,
                embedding_model_id=excluded.embedding_model_id,
                embedding_dimensions=excluded.embedding_dimensions,
                updated_wall=excluded.updated_wall
            """
            let sourceJSON = String(decoding: try Self.encoder().encode(storedRecord.source), as: UTF8.self)
            let metadataJSON = String(decoding: try Self.encoder().encode(storedRecord.metadata), as: UTF8.self)
            try withStatement(sql) { statement in
                bind(storedRecord.id, to: statement, index: 1)
                bind(storedRecord.scope.rawValue, to: statement, index: 2)
                bind(storedRecord.kind.rawValue, to: statement, index: 3)
                bind(storedRecord.targetID, to: statement, index: 4)
                bind(storedRecord.runID, to: statement, index: 5)
                bind(storedRecord.userID, to: statement, index: 6)
                bind(storedRecord.value, to: statement, index: 7)
                bind(storedRecord.createdAt.wallClock.timeIntervalSince1970, to: statement, index: 8)
                bind(Int64(clamping: storedRecord.createdAt.monotonicUptimeNanoseconds), to: statement, index: 9)
                bind(storedRecord.expiresAt?.wallClock.timeIntervalSince1970, to: statement, index: 10)
                bind(storedRecord.expiresAt.map { Int64(clamping: $0.monotonicUptimeNanoseconds) }, to: statement, index: 11)
                bind(storedRecord.durable ? 1 : 0, to: statement, index: 12)
                bind(sourceJSON, to: statement, index: 13)
                bind(metadataJSON, to: statement, index: 14)
                bind(storedRecord.confidence, to: statement, index: 15)
                bind(Int64(storedRecord.useCount), to: statement, index: 16)
                bind(storedRecord.lastUsedAt?.wallClock.timeIntervalSince1970, to: statement, index: 17)
                bind(storedRecord.lastUsedAt.map { Int64(clamping: $0.monotonicUptimeNanoseconds) }, to: statement, index: 18)
                bind(searchText, to: statement, index: 19)
                bind(recordJSON, to: statement, index: 20)
                bind(embeddingProvider.modelID, to: statement, index: 21)
                bind(Int64(vector.count), to: statement, index: 22)
                bind(Date().timeIntervalSince1970, to: statement, index: 23)
                try stepDone(statement)
            }

            try deleteFTSAndEmbedding(recordID: storedRecord.id)
            try withStatement("INSERT INTO memory_fts(id, search_text, value) VALUES (?, ?, ?)") { statement in
                bind(storedRecord.id, to: statement, index: 1)
                bind(searchText, to: statement, index: 2)
                bind(storedRecord.value, to: statement, index: 3)
                try stepDone(statement)
            }
            try withStatement("INSERT INTO memory_embeddings(record_id, embedding_model_id, dimensions, vector) VALUES (?, ?, ?, ?)") { statement in
                bind(storedRecord.id, to: statement, index: 1)
                bind(embeddingProvider.modelID, to: statement, index: 2)
                bind(Int64(vector.count), to: statement, index: 3)
                bind(Self.vectorData(vector), to: statement, index: 4)
                try stepDone(statement)
            }
        }
    }

    @discardableResult
    public func appendApprovedProposal(
        _ proposal: AgentMemoryWriteProposal,
        decidedAt: RunTraceTimestamp
    ) throws -> AgentMemoryWriteDecision {
        let approval = AgentMemoryApprover.evaluate(proposal, decidedAt: decidedAt)
        guard approval.approved else {
            return AgentMemoryWriteDecision(proposal: proposal, approval: approval, storedRecord: nil)
        }
        try upsert(proposal.record)
        return AgentMemoryWriteDecision(proposal: proposal, approval: approval, storedRecord: proposal.record)
    }

    public func records(
        scope: AgentMemoryScope? = nil,
        kinds: [AgentMemoryKind] = [],
        targetID: String? = nil,
        runID: String? = nil,
        userID: String? = nil,
        now: RunTraceTimestamp? = nil
    ) throws -> [AgentMemoryRecord] {
        let filters = Self.filters(
            scope: scope,
            kinds: kinds,
            targetID: targetID,
            runID: runID,
            userID: userID,
            now: now
        )
        let sql = "SELECT record_json FROM memory_records \(filters.whereClause) ORDER BY created_wall ASC"
        lock.lock()
        defer { lock.unlock() }
        return try withStatement(sql) { statement in
            for (index, value) in filters.values.enumerated() {
                bind(value, to: statement, index: Int32(index + 1))
            }
            var records: [AgentMemoryRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let text = columnString(statement, index: 0),
                      let data = text.data(using: .utf8),
                      let record = try? Self.decoder().decode(AgentMemoryRecord.self, from: data)
                else {
                    continue
                }
                records.append(record)
            }
            return records
        }
    }

    public func search(query: AgentMemoryQuery) throws -> [AgentMemorySearchResult] {
        let normalizedQuery = LocalAppLookup.cleanedLookupName(query.text)
        guard !normalizedQuery.isEmpty, query.budget.maxRecords > 0 else { return [] }

        let now = Self.now()
        let candidates = try records(
            scope: query.scope,
            kinds: query.kinds,
            targetID: query.targetID,
            runID: query.runID,
            userID: query.userID,
            now: now
        )
        guard !candidates.isEmpty else { return [] }

        let ftsScores = (try? ftsScores(for: normalizedQuery)) ?? [:]
        let queryVector = embeddingProvider.embedding(for: normalizedQuery)
        var results: [AgentMemorySearchResult] = []
        results.reserveCapacity(candidates.count)

        for record in candidates {
            let text = Self.searchText(for: record)
            let lexicalScore = ftsScores[record.id] ?? Self.tokenOverlapScore(query: normalizedQuery, searchText: text)
            let vectorScore = Self.cosineSimilarity(queryVector, storedVector(recordID: record.id) ?? embeddingProvider.embedding(for: text))
            let exactScore = Self.exactLocalItemScore(record: record, query: normalizedQuery)
            let recencyScore = Self.recencyScore(record: record, now: now)
            let useScore = min(Double(record.useCount) / 10, 1)
            let availabilityScore = record.kind == .negativeLookup ? -0.2 : 0.05
            let rankScore: Double
            if exactScore > 0 {
                rankScore = 1 + exactScore + lexicalScore * 0.1 + useScore * 0.05
            } else {
                rankScore = lexicalScore * 0.42
                    + vectorScore * 0.34
                    + recencyScore * 0.08
                    + useScore * 0.06
                    + record.confidence * 0.05
                    + availabilityScore
            }
            let relevance = min(max(rankScore, 0), 1)
            guard relevance >= query.budget.minRelevance else { continue }
            results.append(
                AgentMemorySearchResult(
                    record: record,
                    relevance: relevance,
                    embeddingModelID: record.embedding?.modelID ?? embeddingProvider.modelID,
                    lexicalScore: lexicalScore,
                    vectorScore: vectorScore,
                    rankScore: rankScore,
                    metadata: [
                        "retriever": "sqlite-agent-memory",
                        "lexicalScore": Self.format(lexicalScore),
                        "vectorScore": Self.format(vectorScore),
                        "rankScore": Self.format(rankScore)
                    ]
                )
            )
        }

        var promptCharacters = 0
        var bounded: [AgentMemorySearchResult] = []
        for result in results.sorted(by: Self.isBetterResult) {
            guard bounded.count < query.budget.maxRecords else { break }
            let nextCharacters = promptCharacters + result.record.value.count
            guard nextCharacters <= query.budget.maxPromptCharacters else { break }
            promptCharacters = nextCharacters
            bounded.append(result)
        }
        return bounded
    }

    @discardableResult
    public func delete(
        recordID: String? = nil,
        scope: AgentMemoryScope? = nil,
        kind: AgentMemoryKind? = nil,
        targetID: String? = nil,
        runID: String? = nil,
        userID: String? = nil
    ) throws -> Int {
        if let recordID {
            try validateIdentifier(recordID)
        }
        let filters = Self.filters(
            scope: scope,
            kinds: kind.map { [$0] } ?? [],
            targetID: targetID,
            runID: runID,
            userID: userID,
            now: nil,
            recordID: recordID
        )
        let ids = try recordIDs(whereClause: filters.whereClause, values: filters.values)
        guard !ids.isEmpty else { return 0 }

        lock.lock()
        defer { lock.unlock() }
        try transaction {
            for id in ids {
                try deleteFTSAndEmbedding(recordID: id)
                try withStatement("DELETE FROM memory_records WHERE id = ?") { statement in
                    bind(id, to: statement, index: 1)
                    try stepDone(statement)
                }
            }
        }
        return ids.count
    }

    public func exportJSONL(to url: URL) throws {
        let records = try records()
        var data = Data()
        let encoder = Self.encoder()
        for record in records.sorted(by: { $0.id < $1.id }) {
            var line = try encoder.encode(record)
            line.append(0x0A)
            data.append(line)
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func prewarmDefaultLocalItemsInBackground(options: AgentMemoryPrewarmOptions = .defaults()) {
        lock.lock()
        guard !isPrewarming else {
            lock.unlock()
            return
        }
        isPrewarming = true
        lock.unlock()

        Task.detached(priority: .utility) { [self] in
            prewarmDefaultLocalItems(options: options)
            finishPrewarming()
        }
    }

    public func prewarmDefaultLocalItems(options: AgentMemoryPrewarmOptions = .defaults()) {
        guard options.maxItemsPerRoot > 0 else { return }

        let entries = prewarmRecords(
            roots: options.applicationRoots,
            allowedKinds: [.application],
            maxItemsPerRoot: options.maxItemsPerRoot
        ) + prewarmRecords(
            roots: options.fileRoots,
            allowedKinds: [.folder, .file, .other],
            maxItemsPerRoot: options.maxItemsPerRoot
        )
        for entry in entries {
            try? upsert(entry)
        }
    }

    public func prewarmTaskDefinitions(_ definitions: [LocalAppTaskDefinition]) {
        for definition in definitions {
            try? upsert(Self.record(taskDefinition: definition))
        }
    }

    public func taskDefinitions() -> [LocalAppTaskDefinition] {
        (try? records(scope: .global, kinds: [.taskDefinition], now: Self.now()))?
            .compactMap(Self.taskDefinition(from:))
            .sorted { lhs, rhs in
                if lhs.taskType == rhs.taskType {
                    return lhs.targetApp.appName < rhs.targetApp.appName
                }
                return lhs.taskType < rhs.taskType
            } ?? []
    }

    public func record(
        availability: LocalAppAvailability,
        query: String,
        source: String
    ) {
        try? upsert(Self.record(availability: availability, query: query, source: source))
    }

    func cachedAvailability(
        named itemName: String,
        preferredKind: LocalItemKind?
    ) -> LocalAppAvailability? {
        let requestedName = LocalAppLookup.cleanedLookupName(itemName)
        guard !requestedName.isEmpty else { return nil }

        let results = (try? search(query: AgentMemoryQuery(
            text: requestedName,
            scope: .global,
            kinds: [.localItem],
            budget: AgentMemoryRetrievalBudget(maxRecords: 8, maxPromptCharacters: 1_000, minRelevance: 0)
        ))) ?? []

        for result in results {
            let record = result.record
            guard record.metadata[Self.localAvailableKey] == "true" else { continue }
            if let preferredKind,
               record.metadata[Self.localKindKey] != preferredKind.rawValue {
                continue
            }
            let appURL = existingURL(for: record)
            guard appURL != nil || record.metadata[Self.localBundleIdentifierKey]?.isEmpty == false else {
                continue
            }
            markUsed(recordID: record.id)

            var metadata = record.metadata
            metadata["provider"] = "sqlite-agent-memory"
            metadata["cache.id"] = record.id
            metadata["cache.score"] = Self.format(result.rankScore)
            metadata["requestedItemName"] = requestedName
            metadata["itemKind"] = metadata[Self.localKindKey] ?? ""
            metadata["itemURL"] = appURL?.path ?? metadata[Self.localPathKey] ?? ""
            metadata["bundleIdentifier"] = metadata[Self.localBundleIdentifierKey] ?? ""
            metadata["match"] = "agentMemory"

            var targetMetadata = [
                "localItem.kind": metadata[Self.localKindKey] ?? "",
                "localItem.path": appURL?.path ?? metadata[Self.localPathKey] ?? ""
            ]
            if let defaultApplication = metadata["defaultApplication"], !defaultApplication.isEmpty {
                targetMetadata["localItem.defaultApplication"] = defaultApplication
            }

            return LocalAppAvailability(
                target: LocalAppTarget(
                    appName: metadata[Self.localDisplayNameKey] ?? record.value,
                    bundleIdentifier: metadata[Self.localBundleIdentifierKey]?.nilIfEmpty,
                    titleContains: metadata[Self.localDisplayNameKey] ?? record.value,
                    metadata: targetMetadata
                ),
                isInstalled: true,
                appURL: appURL,
                metadata: metadata
            )
        }

        return nil
    }

    public func contextSnippets(for query: String, limit: Int = 4) -> [String] {
        let results = (try? search(query: AgentMemoryQuery(
            text: query,
            scope: .global,
            kinds: [.localItem, .negativeLookup, .taskDefinition],
            budget: AgentMemoryRetrievalBudget(maxRecords: limit, maxPromptCharacters: 1_600, minRelevance: 0.05)
        ))) ?? []

        return results.map { result in
            let record = result.record
            let status = record.kind == .negativeLookup ? "missing" : "available"
            let name = record.metadata[Self.localDisplayNameKey] ?? record.metadata["displayTitle"] ?? record.value
            let kind = record.metadata[Self.localKindKey] ?? record.kind.rawValue
            let path = record.metadata[Self.localPathKey].map { " path=\($0)" } ?? ""
            let bundleIdentifier = record.metadata[Self.localBundleIdentifierKey].map { " bundleIdentifier=\($0)" } ?? ""
            let metadata = Self.snippetMetadata(record.metadata)
            return "agent_memory: query=\"\(record.metadata[Self.localQueryKey] ?? record.value)\" status=\(status) name=\"\(name)\" kind=\(kind)\(path)\(bundleIdentifier) source=\(record.metadata[Self.localSourceKey] ?? record.source.summary) match=\(record.metadata[Self.localMatchKey] ?? "") score=\(Self.format(result.rankScore))\(metadata)"
        }
    }

    private func configure() throws {
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA foreign_keys=ON")
    }

    private func createSchema() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS memory_records (
            id TEXT PRIMARY KEY NOT NULL,
            scope TEXT NOT NULL,
            kind TEXT NOT NULL,
            target_id TEXT,
            run_id TEXT,
            user_id TEXT,
            value TEXT NOT NULL,
            created_wall REAL NOT NULL,
            created_uptime_ns INTEGER NOT NULL,
            expires_wall REAL,
            expires_uptime_ns INTEGER,
            durable INTEGER NOT NULL,
            source_json TEXT NOT NULL,
            metadata_json TEXT NOT NULL,
            confidence REAL NOT NULL,
            use_count INTEGER NOT NULL,
            last_used_wall REAL,
            last_used_uptime_ns INTEGER,
            search_text TEXT NOT NULL,
            record_json TEXT NOT NULL,
            embedding_model_id TEXT,
            embedding_dimensions INTEGER,
            updated_wall REAL NOT NULL
        )
        """)
        try execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts
        USING fts5(id UNINDEXED, search_text, value, tokenize='unicode61')
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS memory_embeddings (
            record_id TEXT PRIMARY KEY NOT NULL,
            embedding_model_id TEXT NOT NULL,
            dimensions INTEGER NOT NULL,
            vector BLOB NOT NULL
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_memory_scope_kind ON memory_records(scope, kind)")
        try execute("CREATE INDEX IF NOT EXISTS idx_memory_target ON memory_records(target_id)")
        try execute("CREATE INDEX IF NOT EXISTS idx_memory_run ON memory_records(run_id)")
        try execute("CREATE INDEX IF NOT EXISTS idx_memory_user ON memory_records(user_id)")
        try execute("PRAGMA user_version = 1")
    }

    private func prewarmRecords(
        roots: [URL],
        allowedKinds: Set<LocalItemKind>,
        maxItemsPerRoot: Int
    ) -> [AgentMemoryRecord] {
        var entries: [AgentMemoryRecord] = []
        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            var rootCount = 0
            for case let itemURL as URL in enumerator {
                let kind = LocalItemKind(url: itemURL)
                guard allowedKinds.contains(kind) else { continue }

                entries.append(Self.record(
                    url: itemURL,
                    query: Self.displayName(for: itemURL, kind: kind),
                    kind: kind,
                    source: "prewarm",
                    match: "prewarm",
                    metadata: [
                        "prewarm.root": root.path,
                        "parentDirectory": itemURL.deletingLastPathComponent().lastPathComponent,
                        "fileExtension": itemURL.pathExtension
                    ]
                ))
                rootCount += 1
                if rootCount >= maxItemsPerRoot { break }
            }
        }
        return entries
    }

    private func markUsed(recordID: String) {
        guard var record = try? record(id: recordID) else { return }
        record.useCount += 1
        record.lastUsedAt = Self.now()
        try? upsert(record)
    }

    private func record(id: String) throws -> AgentMemoryRecord? {
        try records().first { $0.id == id }
    }

    private func existingURL(for record: AgentMemoryRecord) -> URL? {
        if let path = record.metadata[Self.localPathKey], !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        guard let bundleIdentifier = record.metadata[Self.localBundleIdentifierKey], !bundleIdentifier.isEmpty else {
            return nil
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    private func ftsScores(for query: String) throws -> [String: Double] {
        let tokens = Self.tokens(in: query)
        guard !tokens.isEmpty else { return [:] }
        let matchQuery = tokens.map { "\($0)*" }.joined(separator: " OR ")
        let sql = "SELECT id, bm25(memory_fts) FROM memory_fts WHERE memory_fts MATCH ? LIMIT 200"

        lock.lock()
        defer { lock.unlock() }
        return try withStatement(sql) { statement in
            bind(matchQuery, to: statement, index: 1)
            var scores: [String: Double] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = columnString(statement, index: 0) else { continue }
                let bm25 = sqlite3_column_double(statement, 1)
                scores[id] = max(scores[id] ?? 0, 1 / (1 + abs(bm25)))
            }
            return scores
        }
    }

    private func storedVector(recordID: String) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        return try? withStatement("SELECT vector FROM memory_embeddings WHERE record_id = ?") { statement in
            bind(recordID, to: statement, index: 1)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let blob = sqlite3_column_blob(statement, 0)
            else {
                return nil
            }
            let count = Int(sqlite3_column_bytes(statement, 0))
            let data = Data(bytes: blob, count: count)
            return Self.vector(from: data)
        }
    }

    private func recordIDs(whereClause: String, values: [SQLValue]) throws -> [String] {
        let sql = "SELECT id FROM memory_records \(whereClause)"
        lock.lock()
        defer { lock.unlock() }
        return try withStatement(sql) { statement in
            for (index, value) in values.enumerated() {
                bind(value, to: statement, index: Int32(index + 1))
            }
            var ids: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let id = columnString(statement, index: 0) {
                    ids.append(id)
                }
            }
            return ids
        }
    }

    private func deleteFTSAndEmbedding(recordID: String) throws {
        try withStatement("DELETE FROM memory_fts WHERE id = ?") { statement in
            bind(recordID, to: statement, index: 1)
            try stepDone(statement)
        }
        try withStatement("DELETE FROM memory_embeddings WHERE record_id = ?") { statement in
            bind(recordID, to: statement, index: 1)
            try stepDone(statement)
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw AgentMemoryStoreError.sqliteFailure(Self.message(from: db))
        }
    }

    private func transaction(_ block: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try block()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw AgentMemoryStoreError.sqliteFailure(Self.message(from: db))
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AgentMemoryStoreError.sqliteFailure(Self.message(from: db))
        }
    }

    private func bind(_ value: SQLValue, to statement: OpaquePointer, index: Int32) {
        switch value {
        case let .string(value):
            sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        case let .double(value):
            sqlite3_bind_double(statement, index, value)
        case let .int(value):
            sqlite3_bind_int64(statement, index, value)
        case .null:
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(_ value: String?, to statement: OpaquePointer, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bind(_ value: Double?, to statement: OpaquePointer, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value)
    }

    private func bind(_ value: Int64?, to statement: OpaquePointer, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, value)
    }

    private func bind(_ value: Int, to statement: OpaquePointer, index: Int32) {
        sqlite3_bind_int(statement, index, Int32(value))
    }

    private func bind(_ data: Data, to statement: OpaquePointer, index: Int32) {
        _ = data.withUnsafeBytes { rawBuffer in
            sqlite3_bind_blob(statement, index, rawBuffer.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
        }
    }

    private func columnString(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private func validateIdentifier(_ value: String) throws {
        let allowedScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:")
        let isSafe = !value.isEmpty
            && value.count <= 256
            && value != "."
            && value != ".."
            && value.unicodeScalars.allSatisfy { allowedScalars.contains($0) }

        guard isSafe else {
            throw AgentMemoryStoreError.invalidIdentifier(value)
        }
    }

    private func finishPrewarming() {
        lock.lock()
        isPrewarming = false
        lock.unlock()
    }

    private static func filters(
        scope: AgentMemoryScope?,
        kinds: [AgentMemoryKind],
        targetID: String?,
        runID: String?,
        userID: String?,
        now: RunTraceTimestamp?,
        recordID: String? = nil
    ) -> (whereClause: String, values: [SQLValue]) {
        var clauses: [String] = []
        var values: [SQLValue] = []
        if let recordID {
            clauses.append("id = ?")
            values.append(.string(recordID))
        }
        if let scope {
            clauses.append("scope = ?")
            values.append(.string(scope.rawValue))
        }
        if !kinds.isEmpty {
            clauses.append("kind IN (\(Array(repeating: "?", count: kinds.count).joined(separator: ",")))")
            values.append(contentsOf: kinds.map { .string($0.rawValue) })
        }
        if let targetID {
            clauses.append("target_id = ?")
            values.append(.string(targetID))
        }
        if let runID {
            clauses.append("run_id = ?")
            values.append(.string(runID))
        }
        if let userID {
            clauses.append("user_id = ?")
            values.append(.string(userID))
        }
        if let now {
            clauses.append("(expires_wall IS NULL OR expires_wall > ?)")
            values.append(.double(now.wallClock.timeIntervalSince1970))
        }
        guard !clauses.isEmpty else { return ("", []) }
        return ("WHERE " + clauses.joined(separator: " AND "), values)
    }

    private static func record(
        availability: LocalAppAvailability,
        query: String,
        source: String
    ) -> AgentMemoryRecord {
        let kind = availability.metadata["itemKind"]
            ?? availability.target.metadata["localItem.kind"]
            ?? (availability.target.bundleIdentifier == nil ? "unknown" : LocalItemKind.application.rawValue)
        let path = availability.metadata["itemURL"]
            ?? availability.target.metadata["localItem.path"]
            ?? availability.appURL?.path
        let bundleIdentifier = availability.metadata["bundleIdentifier"]
            ?? availability.target.bundleIdentifier
        let displayName = availability.target.appName
        let match = availability.metadata["match"]
            ?? availability.metadata["reason"]
            ?? (availability.isInstalled ? "resolved" : "missing")

        var metadata = availability.metadata
        metadata[localQueryKey] = query
        metadata[localNormalizedQueryKey] = LocalAppLookup.cleanedLookupName(query)
        metadata[localDisplayNameKey] = displayName
        metadata[localNormalizedDisplayNameKey] = LocalAppLookup.normalized(displayName)
        metadata[localKindKey] = kind
        metadata[localPathKey] = path ?? ""
        metadata[localBundleIdentifierKey] = bundleIdentifier ?? ""
        metadata[localAvailableKey] = String(availability.isInstalled)
        metadata[localSourceKey] = source
        metadata[localMatchKey] = match

        return AgentMemoryRecord(
            id: localItemID(
                kind: kind,
                path: path,
                bundleIdentifier: bundleIdentifier,
                displayName: displayName,
                query: query,
                isAvailable: availability.isInstalled
            ),
            scope: .global,
            kind: availability.isInstalled ? .localItem : .negativeLookup,
            value: displayName,
            createdAt: now(),
            expiresAt: availability.isInstalled ? nil : now().adding(seconds: 86_400),
            durable: availability.isInstalled,
            source: AgentMemorySource(summary: source),
            metadata: metadata,
            confidence: availability.isInstalled ? 0.95 : 0.75,
            useCount: 1
        )
    }

    private static func record(
        url: URL,
        query: String,
        kind: LocalItemKind,
        source: String,
        match: String,
        metadata: [String: String]
    ) -> AgentMemoryRecord {
        let displayName = displayName(for: url, kind: kind)
        let bundleIdentifier = kind == .application ? Bundle(url: url)?.bundleIdentifier : nil
        var entryMetadata = metadata
        entryMetadata["itemKind"] = kind.rawValue
        entryMetadata["itemURL"] = url.path
        entryMetadata["bundleIdentifier"] = bundleIdentifier ?? ""
        entryMetadata[localQueryKey] = query
        entryMetadata[localNormalizedQueryKey] = LocalAppLookup.cleanedLookupName(query)
        entryMetadata[localDisplayNameKey] = displayName
        entryMetadata[localNormalizedDisplayNameKey] = LocalAppLookup.normalized(displayName)
        entryMetadata[localKindKey] = kind.rawValue
        entryMetadata[localPathKey] = url.path
        entryMetadata[localBundleIdentifierKey] = bundleIdentifier ?? ""
        entryMetadata[localAvailableKey] = "true"
        entryMetadata[localSourceKey] = source
        entryMetadata[localMatchKey] = match

        return AgentMemoryRecord(
            id: localItemID(
                kind: kind.rawValue,
                path: url.path,
                bundleIdentifier: bundleIdentifier,
                displayName: displayName,
                query: query,
                isAvailable: true
            ),
            scope: .global,
            kind: .localItem,
            value: displayName,
            createdAt: now(),
            durable: true,
            source: AgentMemorySource(summary: source),
            metadata: entryMetadata,
            confidence: 0.9,
            useCount: 1
        )
    }

    private static func record(taskDefinition definition: LocalAppTaskDefinition) -> AgentMemoryRecord {
        let entityText = definition.entityRules.map(\.name).joined(separator: " ")
        let workflowText = definition.workflowSteps
            .flatMap { step in [step.id, step.role.rawValue, step.summary] + step.metadata.flatMap { [$0.key, $0.value] } }
            .joined(separator: " ")
        let displayTitle = displayTitle(for: definition)
        var metadata = definition.metadata
        metadata["taskType"] = definition.taskType
        metadata["targetApp"] = definition.targetApp.appName
        metadata["bundleIdentifier"] = definition.targetApp.bundleIdentifier ?? ""
        metadata["entityNames"] = definition.entityRules.map(\.name).joined(separator: ",")
        metadata["observationStrategies"] = definition.observationStrategies.map(\.rawValue).joined(separator: ",")
        metadata["verificationEntityName"] = definition.verificationEntityName ?? ""
        metadata["displayTitle"] = displayTitle
        metadata["taskText"] = "\(definition.taskType) \(entityText) \(workflowText)"
        metadata["targetAppTitle"] = definition.targetApp.titleContains ?? definition.targetApp.appName
        if let encodedDefinition = encodedTaskDefinition(definition) {
            metadata[taskDefinitionJSONMetadataKey] = encodedDefinition
        }

        return AgentMemoryRecord(
            id: "task-definition:\(definition.taskType)",
            scope: .global,
            kind: .taskDefinition,
            value: displayTitle,
            createdAt: now(),
            durable: true,
            source: AgentMemorySource(summary: "task-definition-prewarm"),
            metadata: metadata,
            confidence: 1,
            useCount: 1
        )
    }

    private static func taskDefinition(from record: AgentMemoryRecord) -> LocalAppTaskDefinition? {
        guard let encodedDefinition = record.metadata[taskDefinitionJSONMetadataKey],
              let data = encodedDefinition.data(using: .utf8)
        else {
            return nil
        }
        return try? JSONDecoder().decode(LocalAppTaskDefinition.self, from: data)
    }

    private static func encodedTaskDefinition(_ definition: LocalAppTaskDefinition) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(definition) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func localItemID(
        kind: String,
        path: String?,
        bundleIdentifier: String?,
        displayName: String,
        query: String,
        isAvailable: Bool
    ) -> String {
        if !isAvailable {
            return "missing:\(LocalAppLookup.cleanedLookupName(query))"
        }
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return "\(kind):bundle:\(bundleIdentifier)"
        }
        if let path, !path.isEmpty {
            return "\(kind):path:\(path)"
        }
        return "\(kind):name:\(LocalAppLookup.normalized(displayName))"
    }

    private static func searchText(for record: AgentMemoryRecord) -> String {
        (
            [
                record.id,
                record.scope.rawValue,
                record.kind.rawValue,
                record.targetID ?? "",
                record.runID ?? "",
                record.userID ?? "",
                record.value,
                record.source.summary
            ] + record.metadata
                .filter { $0.key != taskDefinitionJSONMetadataKey }
                .sorted { $0.key < $1.key }
                .flatMap { [$0.key, $0.value] }
        )
        .filter { !$0.isEmpty }
        .joined(separator: " ")
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

    private static func displayTitle(for definition: LocalAppTaskDefinition) -> String {
        if let displayTitle = definition.metadata["displayTitle"], !displayTitle.isEmpty {
            return displayTitle
        }
        return definition.taskType
            .split(separator: "_")
            .map { word in word.prefix(1).uppercased() + word.dropFirst() }
            .joined(separator: " ")
    }

    private static func exactLocalItemScore(record: AgentMemoryRecord, query: String) -> Double {
        guard [.localItem, .negativeLookup, .taskDefinition].contains(record.kind) else { return 0 }
        let normalizedDisplayName = record.metadata[localNormalizedDisplayNameKey]
            ?? LocalAppLookup.normalized(record.value)
        let normalizedQuery = record.metadata[localNormalizedQueryKey]
            ?? LocalAppLookup.cleanedLookupName(record.value)
        if normalizedDisplayName == query || normalizedQuery == query { return 1 }
        if normalizedDisplayName.hasPrefix(query) { return 0.92 }
        if normalizedDisplayName.contains(" \(query)") || normalizedDisplayName.contains(query) { return 0.84 }
        return 0
    }

    private static func tokenOverlapScore(query: String, searchText: String) -> Double {
        let queryTokens = Set(tokens(in: query))
        guard !queryTokens.isEmpty else { return 0 }
        let searchText = LocalAppLookup.normalized(searchText)
        let matched = queryTokens.filter { searchText.contains($0) }.count
        return Double(matched) / Double(queryTokens.count)
    }

    private static func recencyScore(record: AgentMemoryRecord, now: RunTraceTimestamp) -> Double {
        let age = record.createdAt.wallClock.distance(to: now.wallClock)
        guard age > 0 else { return 1 }
        return max(0, min(1, 1 - age / (60 * 60 * 24 * 30)))
    }

    private static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        let dot = zip(lhs, rhs).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        let lhsMagnitude = sqrt(lhs.reduce(Float(0)) { $0 + $1 * $1 })
        let rhsMagnitude = sqrt(rhs.reduce(Float(0)) { $0 + $1 * $1 })
        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return 0 }
        return Double(dot / (lhsMagnitude * rhsMagnitude))
    }

    private static func isBetterResult(lhs: AgentMemorySearchResult, rhs: AgentMemorySearchResult) -> Bool {
        if lhs.rankScore == rhs.rankScore {
            if lhs.record.useCount == rhs.record.useCount {
                return lhs.record.value.count < rhs.record.value.count
            }
            return lhs.record.useCount > rhs.record.useCount
        }
        return lhs.rankScore > rhs.rankScore
    }

    private static func tokens(in text: String) -> [String] {
        HashingAgentMemoryEmbeddingProvider.tokens(in: text)
    }

    private static func vectorData(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * MemoryLayout<UInt32>.size)
        for value in vector {
            var littleEndian = value.bitPattern.littleEndian
            data.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
        }
        return data
    }

    private static func vector(from data: Data) -> [Float] {
        guard data.count % MemoryLayout<UInt32>.size == 0 else { return [] }
        var vector: [Float] = []
        vector.reserveCapacity(data.count / MemoryLayout<UInt32>.size)
        var offset = 0
        while offset < data.count {
            let bits = data[offset..<(offset + MemoryLayout<UInt32>.size)].reduce(UInt32(0)) { value, byte in
                (value >> 8) | (UInt32(byte) << 24)
            }
            vector.append(Float(bitPattern: UInt32(littleEndian: bits)))
            offset += MemoryLayout<UInt32>.size
        }
        return vector
    }

    private static func snippetMetadata(_ metadata: [String: String]) -> String {
        let allowedKeys = [
            "taskType",
            "targetApp",
            "itemKind",
            "defaultApplication",
            "entityNames",
            "verificationMode",
            "automationBackend",
            "appleScript.action",
            "screenshotFallback"
        ]
        let pairs = allowedKeys.compactMap { key -> String? in
            guard let value = metadata[key], !value.isEmpty else { return nil }
            return "\(key)=\(value)"
        }
        guard !pairs.isEmpty else { return "" }
        return " metadata={\(pairs.joined(separator: ","))}"
    }

    private static func now() -> RunTraceTimestamp {
        RunTraceTimestamp(
            wallClock: Date(),
            monotonicUptimeNanoseconds: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        )
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        JSONDecoder()
    }

    private static func message(from db: OpaquePointer?) -> String {
        guard let db, let message = sqlite3_errmsg(db) else { return "unknown sqlite error" }
        return String(cString: message)
    }

    private static func deleteLegacyStores(fileManager: FileManager, donkeyDirectoryOverride: URL? = nil) {
        let donkeyDirectory: URL
        if let donkeyDirectoryOverride {
            donkeyDirectory = donkeyDirectoryOverride
        } else {
            guard let applicationSupport = try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            ) else {
                return
            }
            donkeyDirectory = applicationSupport.appendingPathComponent("Donkey", isDirectory: true)
        }
        for name in ["LocalItemResolutionCache", "TargetMemory"] {
            let url = donkeyDirectory.appendingPathComponent(name, isDirectory: true)
            try? fileManager.removeItem(at: url)
        }
    }

    private static let localQueryKey = "agentMemory.local.query"
    private static let localNormalizedQueryKey = "agentMemory.local.normalizedQuery"
    private static let localDisplayNameKey = "agentMemory.local.displayName"
    private static let localNormalizedDisplayNameKey = "agentMemory.local.normalizedDisplayName"
    private static let localKindKey = "agentMemory.local.kind"
    private static let localPathKey = "agentMemory.local.path"
    private static let localBundleIdentifierKey = "agentMemory.local.bundleIdentifier"
    private static let localAvailableKey = "agentMemory.local.available"
    private static let localSourceKey = "agentMemory.local.source"
    private static let localMatchKey = "agentMemory.local.match"
    private static let taskDefinitionJSONMetadataKey = "taskDefinitionJSON"
}

private enum SQLValue {
    case string(String)
    case double(Double)
    case int(Int64)
    case null
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension RunTraceTimestamp {
    func adding(seconds: TimeInterval) -> RunTraceTimestamp {
        RunTraceTimestamp(
            wallClock: wallClock.addingTimeInterval(seconds),
            monotonicUptimeNanoseconds: monotonicUptimeNanoseconds + UInt64(seconds * 1_000_000_000)
        )
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
