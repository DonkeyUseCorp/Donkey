import DonkeyContracts
import Foundation

public struct AppHarnessContextPacketLimits: Equatable, Sendable {
    public var maxRecentEvents: Int
    public var maxAssets: Int
    public var maxEventTextCharacters: Int
    public var maxAssetNameCharacters: Int
    public var maxMemoryItems: Int
    public var maxMemoryTextCharacters: Int
    public var maxPromptCharacters: Int

    public init(
        maxRecentEvents: Int = 8,
        maxAssets: Int = 8,
        maxEventTextCharacters: Int = 360,
        maxAssetNameCharacters: Int = 120,
        maxMemoryItems: Int = 4,
        maxMemoryTextCharacters: Int = 360,
        maxPromptCharacters: Int = 3_200
    ) {
        self.maxRecentEvents = max(0, maxRecentEvents)
        self.maxAssets = max(0, maxAssets)
        self.maxEventTextCharacters = max(40, maxEventTextCharacters)
        self.maxAssetNameCharacters = max(24, maxAssetNameCharacters)
        self.maxMemoryItems = max(0, maxMemoryItems)
        self.maxMemoryTextCharacters = max(40, maxMemoryTextCharacters)
        self.maxPromptCharacters = max(240, maxPromptCharacters)
    }
}

public struct AppHarnessTurnRequest: Equatable, Sendable {
    public var turn: AppHarnessTurn
    public var recentEvents: [PointerPromptTaskEvent]
    public var assets: [PointerPromptTaskAsset]
    public var targetState: [String: String]
    public var memory: [String]
    public var policy: [String: String]

    public init(
        turn: AppHarnessTurn,
        recentEvents: [PointerPromptTaskEvent] = [],
        assets: [PointerPromptTaskAsset] = [],
        targetState: [String: String] = [:],
        memory: [String] = [],
        policy: [String: String] = [:]
    ) {
        self.turn = turn
        self.recentEvents = recentEvents
        self.assets = assets
        self.targetState = targetState
        self.memory = memory
        self.policy = policy
    }
}

public struct AppHarnessRoutingOutcome: Equatable, Sendable {
    public var decision: AppHarnessDecision
    public var assistantResponse: String?
    public var missingDetail: String?
    public var resolution: LocalAppTaskCatalogResolution?
    public var metadata: [String: String]

    public init(
        decision: AppHarnessDecision,
        assistantResponse: String? = nil,
        missingDetail: String? = nil,
        resolution: LocalAppTaskCatalogResolution? = nil,
        metadata: [String: String] = [:]
    ) {
        self.decision = decision
        self.assistantResponse = assistantResponse
        self.missingDetail = missingDetail
        self.resolution = resolution
        self.metadata = metadata
    }
}

public struct AppHarnessRoutingResult: Equatable, Sendable {
    public var contextPacket: AppHarnessContextPacket
    public var outcome: AppHarnessRoutingOutcome

    public init(contextPacket: AppHarnessContextPacket, outcome: AppHarnessRoutingOutcome) {
        self.contextPacket = contextPacket
        self.outcome = outcome
    }
}

public struct AppHarnessContextPacketBuilder: Sendable {
    public var limits: AppHarnessContextPacketLimits

    public init(limits: AppHarnessContextPacketLimits = AppHarnessContextPacketLimits()) {
        self.limits = limits
    }

    public func build(
        request: AppHarnessTurnRequest,
        catalog: LocalAppTaskCatalog,
        traceID: String
    ) -> AppHarnessContextPacket {
        var redactionCount = 0
        var compactionRecords: [AppHarnessContextCompactionRecord] = []
        var turn = request.turn
        let redactedTurn = Self.redacted(turn.text)
        redactionCount += redactedTurn.count
        let boundedTurn = Self.bounded(redactedTurn.text, maxLength: limits.maxPromptCharacters)
        turn.text = boundedTurn.text
        compactionRecords.append(
            AppHarnessContextCompactionRecord(
                itemKind: .currentTurn,
                originalCount: request.turn.text.isEmpty ? 0 : 1,
                includedCount: turn.text.isEmpty ? 0 : 1,
                truncatedCount: boundedTurn.wasTruncated ? 1 : 0,
                metadata: ["traceID": traceID]
            )
        )

        let preparedEvents = request.recentEvents.map { event -> PreparedHarnessContextEvent in
            let redacted = Self.redacted(event.text)
            redactionCount += redacted.count
            let bounded = Self.bounded(redacted.text, maxLength: limits.maxEventTextCharacters)
            return PreparedHarnessContextEvent(
                event: AppHarnessContextEvent(
                    role: event.role,
                    text: bounded.text,
                    sequence: event.sequence
                ),
                sourceID: event.id,
                isTransientCorrection: Self.isTransientCorrection(event),
                wasTruncated: bounded.wasTruncated
            )
        }
        let eventCompaction = Self.compactEvents(
            preparedEvents,
            limit: limits.maxRecentEvents
        )
        let events = eventCompaction.events
        compactionRecords.append(contentsOf: eventCompaction.records)

        let assets = request.assets
            .suffix(limits.maxAssets)
            .map { asset -> AppHarnessContextAsset in
                let boundedName = Self.bounded(asset.displayName, maxLength: limits.maxAssetNameCharacters)
                return AppHarnessContextAsset(
                    displayName: boundedName.text,
                    contentType: asset.contentType,
                    byteCount: asset.byteCount
                )
            }
        compactionRecords.append(
            AppHarnessContextCompactionRecord(
                itemKind: .asset,
                originalCount: request.assets.count,
                includedCount: assets.count,
                droppedCount: max(0, request.assets.count - assets.count),
                truncatedCount: request.assets.suffix(limits.maxAssets).filter {
                    $0.displayName.count > limits.maxAssetNameCharacters
                }.count
            )
        )

        let memory = request.memory
            .prefix(limits.maxMemoryItems)
            .map { item -> String in
                let redacted = Self.redacted(item)
                redactionCount += redacted.count
                return Self.bounded(redacted.text, maxLength: limits.maxMemoryTextCharacters).text
            }
        compactionRecords.append(
            AppHarnessContextCompactionRecord(
                itemKind: .memory,
                originalCount: request.memory.count,
                includedCount: memory.count,
                droppedCount: max(0, request.memory.count - memory.count),
                truncatedCount: request.memory.prefix(limits.maxMemoryItems).filter {
                    Self.redacted($0).text.count > limits.maxMemoryTextCharacters
                }.count
            )
        )

        let runtimeCapabilities = catalog.taskDefinitions
            .map { "\($0.taskType):\($0.targetApp.appName)" }
            .sorted()
        compactionRecords.append(
            AppHarnessContextCompactionRecord(
                itemKind: .runtimeCapability,
                originalCount: catalog.taskDefinitions.count,
                includedCount: runtimeCapabilities.count
            )
        )
        compactionRecords.append(
            AppHarnessContextCompactionRecord(
                itemKind: .targetState,
                originalCount: request.targetState.count,
                includedCount: request.targetState.count
            )
        )
        compactionRecords.append(
            AppHarnessContextCompactionRecord(
                itemKind: .policy,
                originalCount: request.policy.count,
                includedCount: request.policy.count
            )
        )

        let promptBounds = Self.bounded(
            Self.promptText(
                turn: turn,
                events: events,
                assets: assets,
                runtimeCapabilities: runtimeCapabilities,
                targetState: request.targetState,
                memory: memory,
                policy: request.policy
            ),
            maxLength: limits.maxPromptCharacters
        )
        let promptText = promptBounds.text

        return AppHarnessContextPacket(
            traceID: traceID,
            currentTurn: turn,
            recentEvents: events,
            assets: assets,
            runtimeCapabilities: runtimeCapabilities,
            targetState: request.targetState,
            memory: memory,
            policy: request.policy,
            promptText: promptText,
            redactionCount: redactionCount,
            compactionRecords: compactionRecords,
            metadata: [
                "bounds.maxRecentEvents": String(limits.maxRecentEvents),
                "bounds.maxAssets": String(limits.maxAssets),
                "bounds.maxPromptCharacters": String(limits.maxPromptCharacters),
                "compaction.recordCount": String(compactionRecords.count),
                "compaction.promptTruncated": String(promptBounds.wasTruncated),
                "events.originalCount": String(request.recentEvents.count),
                "events.droppedCount": String(eventCompaction.droppedCount),
                "events.droppedTransientCorrectionCount": String(eventCompaction.droppedTransientCorrectionCount),
                "events.includedCount": String(events.count),
                "assets.includedCount": String(assets.count),
                "memory.includedCount": String(memory.count),
                "prompt.characterCount": String(promptText.count)
            ]
        )
    }

    private static func promptText(
        turn: AppHarnessTurn,
        events: [AppHarnessContextEvent],
        assets: [AppHarnessContextAsset],
        runtimeCapabilities: [String],
        targetState: [String: String],
        memory: [String],
        policy: [String: String]
    ) -> String {
        var sections = [
            "Trace: \(turn.id)",
            "Turn source: \(turn.source.rawValue)",
            "Current turn: \(turn.text)"
        ]
        if !events.isEmpty {
            sections.append("Recent thread:\n" + events.map { "\($0.role.rawValue): \($0.text)" }.joined(separator: "\n"))
        }
        if !assets.isEmpty {
            sections.append("Assets: " + assets.map { "\($0.displayName) (\($0.contentType))" }.joined(separator: ", "))
        }
        if !runtimeCapabilities.isEmpty {
            sections.append("Runtime capabilities: " + runtimeCapabilities.joined(separator: ", "))
        }
        if !targetState.isEmpty {
            sections.append("Target state: " + keyValueText(targetState))
        }
        if !memory.isEmpty {
            sections.append("Memory:\n" + memory.joined(separator: "\n"))
        }
        if !policy.isEmpty {
            sections.append("Policy: " + keyValueText(policy))
        }
        return sections.joined(separator: "\n\n")
    }

    private static func keyValueText(_ values: [String: String]) -> String {
        values
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
    }

    private static func redacted(_ text: String) -> (text: String, count: Int) {
        var redacted = text
        var count = 0
        let replacements = [
            #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#: "[redacted-email]",
            #"\b(?:\d[ -]*?){13,16}\b"#: "[redacted-number]",
            #"(?i)(password|token|api[_ -]?key)\s*[:=]\s*\S+"#: "$1=[redacted-secret]"
        ]
        for (pattern, replacement) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
            count += regex.numberOfMatches(in: redacted, range: range)
            redacted = regex.stringByReplacingMatches(
                in: redacted,
                options: [],
                range: range,
                withTemplate: replacement
            )
        }
        return (redacted, count)
    }

    private static func bounded(_ text: String, maxLength: Int) -> (text: String, wasTruncated: Bool) {
        guard text.count > maxLength else { return (text, false) }

        let endIndex = text.index(text.startIndex, offsetBy: maxLength)
        return (String(text[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "...", true)
    }

    private static func compactEvents(
        _ preparedEvents: [PreparedHarnessContextEvent],
        limit: Int
    ) -> HarnessEventCompactionResult {
        guard limit > 0 else {
            let transientCount = preparedEvents.filter(\.isTransientCorrection).count
            return HarnessEventCompactionResult(
                events: [],
                records: [
                    AppHarnessContextCompactionRecord(
                        itemKind: .recentEvent,
                        originalCount: preparedEvents.count,
                        includedCount: 0,
                        droppedCount: preparedEvents.count,
                        truncatedCount: 0
                    ),
                    AppHarnessContextCompactionRecord(
                        itemKind: .transientCorrection,
                        originalCount: transientCount,
                        includedCount: 0,
                        droppedCount: transientCount,
                        truncatedCount: 0
                    )
                ],
                droppedCount: preparedEvents.count,
                droppedTransientCorrectionCount: transientCount
            )
        }

        let selected: [PreparedHarnessContextEvent]
        if preparedEvents.count <= limit {
            selected = preparedEvents
        } else {
            let nonTransient = preparedEvents.filter { !$0.isTransientCorrection }
            var chosen = Array(nonTransient.suffix(limit))
            if chosen.count < limit {
                let chosenIDs = Set(chosen.map(\.sourceID))
                let fill = preparedEvents
                    .filter { $0.isTransientCorrection && !chosenIDs.contains($0.sourceID) }
                    .suffix(limit - chosen.count)
                chosen.append(contentsOf: fill)
            }
            selected = chosen.sorted { lhs, rhs in
                if lhs.event.sequence == rhs.event.sequence {
                    return lhs.sourceID < rhs.sourceID
                }
                return lhs.event.sequence < rhs.event.sequence
            }
        }

        let selectedIDs = Set(selected.map(\.sourceID))
        let dropped = preparedEvents.filter { !selectedIDs.contains($0.sourceID) }
        let transientOriginal = preparedEvents.filter(\.isTransientCorrection).count
        let transientIncluded = selected.filter(\.isTransientCorrection).count
        let transientDropped = dropped.filter(\.isTransientCorrection).count
        let recentTruncated = selected.filter { !$0.isTransientCorrection && $0.wasTruncated }.count
        let transientTruncated = selected.filter { $0.isTransientCorrection && $0.wasTruncated }.count

        return HarnessEventCompactionResult(
            events: selected.map(\.event),
            records: [
                AppHarnessContextCompactionRecord(
                    itemKind: .recentEvent,
                    originalCount: preparedEvents.count,
                    includedCount: selected.count,
                    droppedCount: dropped.count,
                    truncatedCount: recentTruncated,
                    metadata: ["strategy": "dropTransientCorrectionsFirst"]
                ),
                AppHarnessContextCompactionRecord(
                    itemKind: .transientCorrection,
                    originalCount: transientOriginal,
                    includedCount: transientIncluded,
                    droppedCount: transientDropped,
                    truncatedCount: transientTruncated,
                    metadata: ["strategy": "dropBeforeDurableEvents"]
                )
            ],
            droppedCount: dropped.count,
            droppedTransientCorrectionCount: transientDropped
        )
    }

    private static func isTransientCorrection(_: PointerPromptTaskEvent) -> Bool {
        false
    }
}

private struct PreparedHarnessContextEvent: Equatable, Sendable {
    var event: AppHarnessContextEvent
    var sourceID: String
    var isTransientCorrection: Bool
    var wasTruncated: Bool
}

private struct HarnessEventCompactionResult: Equatable, Sendable {
    var events: [AppHarnessContextEvent]
    var records: [AppHarnessContextCompactionRecord]
    var droppedCount: Int
    var droppedTransientCorrectionCount: Int
}

public struct AppHarnessTurnRouter: Sendable {
    public var catalog: LocalAppTaskCatalog
    public var contextBuilder: AppHarnessContextPacketBuilder
    public var turnClassifier: AppHarnessTurnClassifier

    public init(
        catalog: LocalAppTaskCatalog,
        contextBuilder: AppHarnessContextPacketBuilder = AppHarnessContextPacketBuilder(),
        turnClassifier: AppHarnessTurnClassifier = AppHarnessTurnClassifier()
    ) {
        self.catalog = catalog
        self.contextBuilder = contextBuilder
        self.turnClassifier = turnClassifier
    }

    public func route(
        request: AppHarnessTurnRequest,
        traceID: String
    ) -> AppHarnessRoutingResult {
        let packet = contextBuilder.build(
            request: request,
            catalog: catalog,
            traceID: traceID
        )
        let trimmedText = request.turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return AppHarnessRoutingResult(
                contextPacket: packet,
                outcome: AppHarnessRoutingOutcome(
                    decision: AppHarnessDecision(
                        kind: .noOp,
                        traceID: traceID,
                        metadata: ["router": "emptyTurn"]
                    ),
                    metadata: ["router": "emptyTurn"]
                )
            )
        }

        let modelIntentResolution = LocalAppTaskCatalogResolution(
            status: .unsupportedCommand,
            metadata: ["reason": "modelIntentRequired"]
        )

        let classification = turnClassifier.classify(
            text: trimmedText,
            request: request,
            catalog: catalog
        )

        if request.turn.isFollowUp && classification.kind == .unknown {
            return AppHarnessRoutingResult(
                contextPacket: packet,
                outcome: AppHarnessRoutingOutcome(
                    decision: decision(
                        kind: .runLocalTask,
                        traceID: traceID,
                        resolution: modelIntentResolution,
                        metadata: ["router": "followUpActionContext"]
                    ),
                    resolution: modelIntentResolution,
                    metadata: ["router": "followUpActionContext"]
                )
            )
        }

        if classification.kind == .answer,
           let response = classification.response {
            return AppHarnessRoutingResult(
                contextPacket: packet,
                outcome: AppHarnessRoutingOutcome(
                    decision: decision(
                        kind: .respond,
                        traceID: traceID,
                        message: response,
                        metadata: ["router": classification.router]
                    ),
                    assistantResponse: response,
                    metadata: ["router": classification.router].merging(classification.metadata) { current, _ in current }
                )
            )
        }

        return AppHarnessRoutingResult(
            contextPacket: packet,
            outcome: AppHarnessRoutingOutcome(
                decision: decision(
                    kind: .runLocalTask,
                    traceID: traceID,
                    resolution: modelIntentResolution,
                    metadata: ["router": "modelIntent"]
                ),
                resolution: modelIntentResolution,
                metadata: ["router": "modelIntent"].merging(classification.metadata) { current, _ in current }
            )
        )
    }

    private func decision(
        kind: AppHarnessDecisionKind,
        traceID: String,
        message: String? = nil,
        missingDetail: String? = nil,
        resolution: LocalAppTaskCatalogResolution? = nil,
        metadata: [String: String] = [:]
    ) -> AppHarnessDecision {
        AppHarnessDecision(
            kind: kind,
            message: message,
            missingDetail: missingDetail,
            taskIntentID: resolution?.intent?.intentID,
            traceID: traceID,
            metadata: metadata.merging([
                "structuredDecision": "true",
                "resolution.status": resolution?.status.rawValue ?? "none"
            ]) { current, _ in current }
        )
    }

    private func clarificationPrompt(
        for missingDetail: String,
        resolution: LocalAppTaskCatalogResolution
    ) -> String {
        let readableDetail = missingDetail
            .split(separator: "_")
            .joined(separator: " ")
        if let definition = resolution.definition {
            let taskTitle = Self.displayTitle(for: definition)
            return "What \(readableDetail) should I use for \(taskTitle)?"
        }
        return "What \(readableDetail) should I use?"
    }

    private static func displayTitle(for definition: LocalAppTaskDefinition) -> String {
        if let displayTitle = definition.metadata["displayTitle"], !displayTitle.isEmpty {
            return displayTitle
        }
        return definition.taskType
            .split(separator: "_")
            .joined(separator: " ")
    }
}
