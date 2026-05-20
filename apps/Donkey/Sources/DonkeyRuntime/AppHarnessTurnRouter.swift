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
    public var kind: AppHarnessTurnRouteKind
    public var assistantResponse: String?
    public var missingDetail: String?
    public var resolution: LocalAppTaskCatalogResolution?
    public var metadata: [String: String]

    public init(
        kind: AppHarnessTurnRouteKind,
        assistantResponse: String? = nil,
        missingDetail: String? = nil,
        resolution: LocalAppTaskCatalogResolution? = nil,
        metadata: [String: String] = [:]
    ) {
        self.kind = kind
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
        var turn = request.turn
        let redactedTurn = Self.redacted(turn.text)
        redactionCount += redactedTurn.count
        turn.text = Self.truncated(redactedTurn.text, maxLength: limits.maxPromptCharacters)

        let events = request.recentEvents
            .suffix(limits.maxRecentEvents)
            .map { event in
                let redacted = Self.redacted(event.text)
                redactionCount += redacted.count
                return AppHarnessContextEvent(
                    role: event.role,
                    text: Self.truncated(redacted.text, maxLength: limits.maxEventTextCharacters),
                    sequence: event.sequence
                )
            }

        let assets = request.assets
            .suffix(limits.maxAssets)
            .map { asset in
                AppHarnessContextAsset(
                    displayName: Self.truncated(asset.displayName, maxLength: limits.maxAssetNameCharacters),
                    contentType: asset.contentType,
                    byteCount: asset.byteCount
                )
            }

        let memory = request.memory
            .prefix(limits.maxMemoryItems)
            .map { item -> String in
                let redacted = Self.redacted(item)
                redactionCount += redacted.count
                return Self.truncated(redacted.text, maxLength: limits.maxMemoryTextCharacters)
            }

        let runtimeCapabilities = catalog.taskDefinitions
            .map { "\($0.taskType):\($0.targetApp.appName)" }
            .sorted()
        let promptText = Self.truncated(
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
            metadata: [
                "bounds.maxRecentEvents": String(limits.maxRecentEvents),
                "bounds.maxAssets": String(limits.maxAssets),
                "bounds.maxPromptCharacters": String(limits.maxPromptCharacters),
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

    private static func truncated(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }

        let endIndex = text.index(text.startIndex, offsetBy: maxLength)
        return String(text[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}

public struct AppHarnessTurnRouter: Sendable {
    public var catalog: LocalAppTaskCatalog
    public var contextBuilder: AppHarnessContextPacketBuilder

    public init(
        catalog: LocalAppTaskCatalog,
        contextBuilder: AppHarnessContextPacketBuilder = AppHarnessContextPacketBuilder()
    ) {
        self.catalog = catalog
        self.contextBuilder = contextBuilder
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
                outcome: AppHarnessRoutingOutcome(kind: .noOp)
            )
        }

        let deterministicResolution = catalog.resolve(command: trimmedText)
        switch deterministicResolution.status {
        case .resolved:
            return AppHarnessRoutingResult(
                contextPacket: packet,
                outcome: AppHarnessRoutingOutcome(
                    kind: .actionableIntent,
                    resolution: deterministicResolution,
                    metadata: ["router": "deterministicCatalog"]
                )
            )
        case .needsConfirmation:
            let missingDetail = deterministicResolution.metadata["reason"] ?? "detail"
            return AppHarnessRoutingResult(
                contextPacket: packet,
                outcome: AppHarnessRoutingOutcome(
                    kind: .clarification,
                    assistantResponse: clarificationPrompt(for: missingDetail, resolution: deterministicResolution),
                    missingDetail: missingDetail,
                    resolution: deterministicResolution,
                    metadata: ["router": "deterministicCatalog"]
                )
            )
        case .appUnavailable:
            return AppHarnessRoutingResult(
                contextPacket: packet,
                outcome: AppHarnessRoutingOutcome(
                    kind: .actionableIntent,
                    resolution: deterministicResolution,
                    metadata: ["router": "deterministicCatalog"]
                )
            )
        case .unsupportedCommand:
            break
        }

        if request.turn.isFollowUp && !Self.isConversational(trimmedText) {
            return AppHarnessRoutingResult(
                contextPacket: packet,
                outcome: AppHarnessRoutingOutcome(
                    kind: .actionableIntent,
                    resolution: deterministicResolution,
                    metadata: ["router": "followUpActionContext"]
                )
            )
        }

        if Self.isConversational(trimmedText) {
            return AppHarnessRoutingResult(
                contextPacket: packet,
                outcome: AppHarnessRoutingOutcome(
                    kind: .conversation,
                    assistantResponse: conversationResponse(for: trimmedText),
                    metadata: ["router": "conversationRules"]
                )
            )
        }

        return AppHarnessRoutingResult(
            contextPacket: packet,
            outcome: AppHarnessRoutingOutcome(
                kind: .clarification,
                assistantResponse: "What would you like Donkey to do?",
                missingDetail: "actionable request",
                resolution: deterministicResolution,
                metadata: ["router": "unsupportedClarification"]
            )
        )
    }

    private func conversationResponse(for text: String) -> String {
        let normalized = LocalAppTaskIntentParser.normalizedPhrase(text)
        if normalized.contains("what can") || normalized.contains("help") || normalized.contains("capabil") {
            let examples = catalog.taskDefinitions
                .map { $0.taskType.split(separator: "_").joined(separator: " ") }
                .sorted()
                .joined(separator: ", ")
            return examples.isEmpty
                ? "I can keep a task thread going and ask for details before taking action."
                : "I can keep a task thread going, ask for missing details, and run supported local tasks such as \(examples)."
        }

        return "Hi. Tell me what local app task you want to work on."
    }

    private func clarificationPrompt(
        for missingDetail: String,
        resolution: LocalAppTaskCatalogResolution
    ) -> String {
        switch missingDetail {
        case "city":
            return "Which city should I use?"
        case "query":
            return "What should I play?"
        case "document":
            return "Which document should I use?"
        default:
            if let taskType = resolution.definition?.taskType.split(separator: "_").joined(separator: " ") {
                return "What \(missingDetail) should I use for \(taskType)?"
            }
            return "What \(missingDetail) should I use?"
        }
    }

    private static func isConversational(_ text: String) -> Bool {
        let normalized = LocalAppTaskIntentParser.normalizedPhrase(text)
        let greetings: Set<String> = [
            "hi",
            "hello",
            "hey",
            "good morning",
            "good afternoon",
            "good evening",
            "thanks",
            "thank you"
        ]
        if greetings.contains(normalized) {
            return true
        }

        return normalized.contains("what can you do")
            || normalized.contains("what can donkey do")
            || normalized.contains("help")
            || normalized.contains("capabilities")
            || normalized.contains("how does donkey work")
            || normalized.contains("who are you")
    }
}
