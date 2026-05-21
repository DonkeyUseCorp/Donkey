import DonkeyContracts
import Foundation

public enum AIModelProvider: String, Codable, Equatable, Sendable {
    case openAI
    case ollama
    case localRuntime
}

public enum AIModelRole: String, Codable, Equatable, Sendable {
    case taskIntent
    case voiceTranscription
    case plannerHint
    case traceSummary
    case recovery
}

public enum AIModelCapability: String, Codable, Equatable, Hashable, Sendable {
    case textInput
    case audioInput
    case structuredOutputs
    case imageInput
}

public enum AIModelEvalStatus: String, Codable, Equatable, Sendable {
    case candidate
    case passing
    case failing
    case disabled
}

public struct AIModelRegistryEntry: Codable, Equatable, Sendable {
    public var id: String
    public var role: AIModelRole
    public var provider: AIModelProvider
    public var modelID: String
    public var endpoint: URL
    public var capabilities: Set<AIModelCapability>
    public var timeoutMS: Int
    public var promptVersion: String
    public var evalStatus: AIModelEvalStatus
    public var docsURL: URL
    public var rollbackID: String?
    public var metadata: [String: String]

    public init(
        id: String,
        role: AIModelRole,
        provider: AIModelProvider,
        modelID: String,
        endpoint: URL,
        capabilities: Set<AIModelCapability>,
        timeoutMS: Int,
        promptVersion: String,
        evalStatus: AIModelEvalStatus,
        docsURL: URL,
        rollbackID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.role = role
        self.provider = provider
        self.modelID = modelID
        self.endpoint = endpoint
        self.capabilities = capabilities
        self.timeoutMS = timeoutMS
        self.promptVersion = promptVersion
        self.evalStatus = evalStatus
        self.docsURL = docsURL
        self.rollbackID = rollbackID
        self.metadata = metadata
    }
}

public struct AIModelRegistry: Codable, Equatable, Sendable {
    public var entries: [AIModelRegistryEntry]

    public init(entries: [AIModelRegistryEntry]) {
        self.entries = entries
    }

    public static let defaultOpenAIPlanner = AIModelRegistry(
        entries: [
            AIModelRegistryEntry(
                id: "openai-planner-hint-default",
                role: .plannerHint,
                provider: .openAI,
                modelID: "gpt-5.2",
                endpoint: URL(string: "https://api.openai.com/v1/responses")!,
                capabilities: [.textInput, .structuredOutputs],
                timeoutMS: 20_000,
                promptVersion: "planner-hint-v1",
                evalStatus: .candidate,
                docsURL: URL(string: "https://platform.openai.com/docs/api-reference/responses/create")!,
                rollbackID: nil,
                metadata: [
                    "lastVerifiedAt": "2026-05-16",
                    "docsSource": "official OpenAI Responses API and models docs"
                ]
            )
        ]
    )

    public static let defaultHybridPlanner = AIModelRegistry(
        entries: [
            AIModelRegistryEntry(
                id: "local-runtime-task-intent-qwen3",
                role: .taskIntent,
                provider: .localRuntime,
                modelID: "qwen3:8b",
                endpoint: URL(string: "local://qwen3-8b/task-intent")!,
                capabilities: [.textInput, .structuredOutputs],
                timeoutMS: 20_000,
                promptVersion: "task-intent-v1",
                evalStatus: .candidate,
                docsURL: URL(string: "https://ollama.com/library/qwen3")!,
                rollbackID: nil,
                metadata: [
                    "local": "true",
                    "runtime": "donkey-local-llm-sidecar",
                    "sidecarEnvironmentVariable": "DONKEY_LOCAL_LLM_RUNNER"
                ]
            ),
            AIModelRegistryEntry(
                id: "ollama-task-intent-local",
                role: .taskIntent,
                provider: .ollama,
                modelID: "qwen3:8b",
                endpoint: URL(string: "http://127.0.0.1:11434/api/generate")!,
                capabilities: [.textInput, .structuredOutputs],
                timeoutMS: 20_000,
                promptVersion: "task-intent-v1",
                evalStatus: .candidate,
                docsURL: URL(string: "https://docs.ollama.com/api")!,
                rollbackID: nil,
                metadata: [
                    "local": "true",
                    "docsSource": "official Ollama API docs"
                ]
            ),
            AIModelRegistryEntry(
                id: "local-voice-transcription-parakeet-tdt-0.6b-v3",
                role: .voiceTranscription,
                provider: .localRuntime,
                modelID: "nvidia/parakeet-tdt-0.6b-v3",
                endpoint: URL(string: "local://nvidia/parakeet-tdt-0.6b-v3")!,
                capabilities: [.audioInput],
                timeoutMS: 2_000,
                promptVersion: "voice-transcription-v1",
                evalStatus: .candidate,
                docsURL: URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3")!,
                rollbackID: nil,
                metadata: [
                    "local": "true",
                    "runtime": "nvidia-nemo",
                    "language": "25 languages with automatic detection",
                    "inputFormat": "16kHz mono wav or flac",
                    "parameters": "600M",
                    "features": "punctuation,capitalization,wordTimestamps,segmentTimestamps",
                    "license": "CC-BY-4.0",
                    "selectedReason": "current Parakeet TDT 0.6B default for local ASR with punctuation, timestamps, and multilingual support",
                    "lastVerifiedAt": "2026-05-17",
                    "docsSource": "official NVIDIA Hugging Face model card",
                    "fallbackPolicy": "none"
                ]
            ),
            AIModelRegistryEntry(
                id: "ollama-planner-hint-local",
                role: .plannerHint,
                provider: .ollama,
                modelID: "qwen3:8b",
                endpoint: URL(string: "http://127.0.0.1:11434/api/generate")!,
                capabilities: [.textInput, .structuredOutputs],
                timeoutMS: 8_000,
                promptVersion: "planner-hint-v1",
                evalStatus: .candidate,
                docsURL: URL(string: "https://docs.ollama.com/api")!,
                rollbackID: nil,
                metadata: [
                    "local": "true",
                    "docsSource": "official Ollama API docs"
                ]
            ),
            AIModelRegistryEntry(
                id: "openai-planner-hint-default",
                role: .plannerHint,
                provider: .openAI,
                modelID: "gpt-5.2",
                endpoint: URL(string: "https://api.openai.com/v1/responses")!,
                capabilities: [.textInput, .structuredOutputs],
                timeoutMS: 8_000,
                promptVersion: "planner-hint-v1",
                evalStatus: .candidate,
                docsURL: URL(string: "https://platform.openai.com/docs/api-reference/responses/create")!,
                rollbackID: nil,
                metadata: [
                    "lastVerifiedAt": "2026-05-16",
                    "docsSource": "official OpenAI Responses API and models docs"
                ]
            )
        ]
    )
}

public enum AIModelJobType: String, Codable, Equatable, Sendable {
    case taskIntent
    case voiceTranscription
    case plannerHint
    case traceSummary
    case recovery
}

public enum AIModelRisk: String, Codable, Equatable, Sendable {
    case low
    case medium
    case high
}

public enum AIModelPrivacyMode: String, Codable, Equatable, Sendable {
    case standard
    case privacySensitive
}

public enum AIModelLatencyTolerance: String, Codable, Equatable, Sendable {
    case interactive
    case background
}

public struct AIModelRouteRequest: Codable, Equatable, Sendable {
    public var jobType: AIModelJobType
    public var risk: AIModelRisk
    public var privacyMode: AIModelPrivacyMode
    public var latencyTolerance: AIModelLatencyTolerance
    public var failedModelEntryIDs: Set<String>
    public var requiredCapabilities: Set<AIModelCapability>
    public var allowedProviders: Set<AIModelProvider>?

    public init(
        jobType: AIModelJobType,
        risk: AIModelRisk = .low,
        privacyMode: AIModelPrivacyMode = .privacySensitive,
        latencyTolerance: AIModelLatencyTolerance = .interactive,
        failedModelEntryIDs: Set<String> = [],
        requiredCapabilities: Set<AIModelCapability> = [.structuredOutputs],
        allowedProviders: Set<AIModelProvider>? = nil
    ) {
        self.jobType = jobType
        self.risk = risk
        self.privacyMode = privacyMode
        self.latencyTolerance = latencyTolerance
        self.failedModelEntryIDs = failedModelEntryIDs
        self.requiredCapabilities = requiredCapabilities
        self.allowedProviders = allowedProviders
    }

    public func limitingProviders(_ providers: Set<AIModelProvider>) -> AIModelRouteRequest {
        AIModelRouteRequest(
            jobType: jobType,
            risk: risk,
            privacyMode: privacyMode,
            latencyTolerance: latencyTolerance,
            failedModelEntryIDs: failedModelEntryIDs,
            requiredCapabilities: requiredCapabilities,
            allowedProviders: allowedProviders.map { $0.intersection(providers) } ?? providers
        )
    }
}

public enum AIModelRouteError: Error, Equatable, Sendable {
    case noMatchingModel
}

public struct AIModelRouter: Sendable {
    public var registry: AIModelRegistry

    public init(registry: AIModelRegistry = .defaultOpenAIPlanner) {
        self.registry = registry
    }

    public func route(
        _ request: AIModelRouteRequest
    ) throws -> AIModelRegistryEntry {
        let role = role(for: request.jobType)
        let candidates = registry.entries
            .filter { entry in
                entry.role == role
                    && entry.evalStatus != .disabled
                    && !request.failedModelEntryIDs.contains(entry.id)
                    && request.requiredCapabilities.isSubset(of: entry.capabilities)
                    && (request.allowedProviders?.contains(entry.provider) ?? true)
                    && allowsRisk(request.risk, entry: entry)
            }
            .sorted { lhs, rhs in
                score(lhs, request: request) > score(rhs, request: request)
            }

        guard let selected = candidates.first else {
            throw AIModelRouteError.noMatchingModel
        }

        return selected
    }

    private func role(for jobType: AIModelJobType) -> AIModelRole {
        switch jobType {
        case .taskIntent:
            return .taskIntent
        case .voiceTranscription:
            return .voiceTranscription
        case .plannerHint:
            return .plannerHint
        case .traceSummary:
            return .traceSummary
        case .recovery:
            return .recovery
        }
    }

    private func allowsRisk(_ risk: AIModelRisk, entry: AIModelRegistryEntry) -> Bool {
        if risk == .high {
            return entry.evalStatus == .passing
        }

        return true
    }

    private func score(
        _ entry: AIModelRegistryEntry,
        request: AIModelRouteRequest
    ) -> Int {
        var value = 0
        if entry.evalStatus == .passing { value += 10 }
        if request.latencyTolerance == .interactive { value -= entry.timeoutMS / 1_000 }
        if request.privacyMode == .privacySensitive {
            switch entry.provider {
            case .localRuntime:
                value += 4
            case .ollama:
                value += 4
            case .openAI:
                value -= 1
            }
        }
        return value
    }
}
