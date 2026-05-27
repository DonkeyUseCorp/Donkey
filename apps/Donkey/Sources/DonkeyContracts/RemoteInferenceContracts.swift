import Foundation

public enum RemoteInferenceModality: String, Codable, Equatable, Sendable {
    case text
    case image
    case video
    case audio
    case music
}

public enum RemoteInferenceAssetKind: String, Codable, Equatable, Sendable {
    case image
    case video
    case music
}

public enum RemoteInferenceGenerationStatus: String, Codable, Equatable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
    case cancelled
}

public enum RemoteInferenceJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: RemoteInferenceJSONValue])
    case array([RemoteInferenceJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RemoteInferenceJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: RemoteInferenceJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public typealias RemoteInferenceJSONObject = [String: RemoteInferenceJSONValue]

public enum RemoteInferenceComputerUseToolType: String, Codable, Equatable, Sendable {
    case geminiBrowserInteraction = "donkey_gemini_browser_interaction"
    case openAIMacDesktopInteraction = "donkey_openai_mac_desktop_interaction"
    case debugUIInspection = "donkey_debug_ui_inspection"
}

public struct RemoteInferenceComputerUseTool: Codable, Equatable, Sendable {
    public var type: RemoteInferenceComputerUseToolType
    public var excludedPredefinedFunctions: [String]
    public var metadata: [String: String]

    public init(
        type: RemoteInferenceComputerUseToolType,
        excludedPredefinedFunctions: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.type = type
        self.excludedPredefinedFunctions = excludedPredefinedFunctions
        self.metadata = metadata
    }

    public var jsonObject: RemoteInferenceJSONObject {
        var object: RemoteInferenceJSONObject = [
            "type": .string(type.rawValue)
        ]
        if !excludedPredefinedFunctions.isEmpty {
            object["excludedPredefinedFunctions"] = .array(
                excludedPredefinedFunctions.map(RemoteInferenceJSONValue.string)
            )
        }
        if !metadata.isEmpty {
            object["metadata"] = .object(metadata.mapValues(RemoteInferenceJSONValue.string))
        }
        return object
    }
}

public struct RemoteInferenceChatMessage: Codable, Equatable, Sendable {
    public var role: String
    public var content: RemoteInferenceJSONValue

    public init(role: String, content: RemoteInferenceJSONValue) {
        self.role = role
        self.content = content
    }
}

public struct RemoteInferenceChatCompletionRequest: Codable, Equatable, Sendable {
    public var model: String?
    public var models: [String]
    public var messages: [RemoteInferenceChatMessage]
    public var stream: Bool
    public var modalities: [RemoteInferenceModality]
    public var provider: RemoteInferenceJSONObject?
    public var metadata: [String: String]
    public var parameters: RemoteInferenceJSONObject

    public init(
        model: String? = nil,
        models: [String] = [],
        messages: [RemoteInferenceChatMessage],
        stream: Bool = false,
        modalities: [RemoteInferenceModality] = [.text],
        provider: RemoteInferenceJSONObject? = nil,
        metadata: [String: String] = [:],
        parameters: RemoteInferenceJSONObject = [:]
    ) {
        self.model = model
        self.models = models
        self.messages = messages
        self.stream = stream
        self.modalities = modalities
        self.provider = provider
        self.metadata = metadata
        self.parameters = parameters
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encodeIfPresent(model, forKey: DynamicCodingKey("model"))
        if !models.isEmpty {
            try container.encode(models, forKey: DynamicCodingKey("models"))
        }
        try container.encode(messages, forKey: DynamicCodingKey("messages"))
        try container.encode(stream, forKey: DynamicCodingKey("stream"))
        try container.encode(modalities.map(\.rawValue), forKey: DynamicCodingKey("modalities"))
        try container.encodeIfPresent(provider, forKey: DynamicCodingKey("provider"))
        if !metadata.isEmpty {
            try container.encode(metadata, forKey: DynamicCodingKey("metadata"))
        }
        for (key, value) in parameters {
            try container.encode(value, forKey: DynamicCodingKey(key))
        }
    }
}

public struct RemoteInferenceResponseCreateRequest: Codable, Equatable, Sendable {
    public var donkeyProvider: String?
    public var model: String?
    public var input: RemoteInferenceJSONValue
    public var store: Bool
    public var text: RemoteInferenceJSONObject?
    public var tools: [RemoteInferenceJSONObject]
    public var include: [String]
    public var metadata: [String: String]
    public var parameters: RemoteInferenceJSONObject

    public init(
        donkeyProvider: String? = nil,
        model: String? = nil,
        input: RemoteInferenceJSONValue,
        store: Bool = false,
        text: RemoteInferenceJSONObject? = nil,
        tools: [RemoteInferenceJSONObject] = [],
        include: [String] = [],
        metadata: [String: String] = [:],
        parameters: RemoteInferenceJSONObject = [:]
    ) {
        self.donkeyProvider = donkeyProvider
        self.model = model
        self.input = input
        self.store = store
        self.text = text
        self.tools = tools
        self.include = include
        self.metadata = metadata
        self.parameters = parameters
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encodeIfPresent(donkeyProvider, forKey: DynamicCodingKey("donkeyProvider"))
        try container.encodeIfPresent(model, forKey: DynamicCodingKey("model"))
        try container.encode(input, forKey: DynamicCodingKey("input"))
        try container.encode(store, forKey: DynamicCodingKey("store"))
        try container.encode(false, forKey: DynamicCodingKey("stream"))
        try container.encodeIfPresent(text, forKey: DynamicCodingKey("text"))
        if !tools.isEmpty {
            try container.encode(tools, forKey: DynamicCodingKey("tools"))
        }
        if !include.isEmpty {
            try container.encode(include, forKey: DynamicCodingKey("include"))
        }
        if !metadata.isEmpty {
            try container.encode(metadata, forKey: DynamicCodingKey("metadata"))
        }
        for (key, value) in parameters {
            try container.encode(value, forKey: DynamicCodingKey(key))
        }
    }
}

public struct RemoteInferenceAssetGenerationRequest: Codable, Equatable, Sendable {
    public var generationId: String?
    public var kind: RemoteInferenceAssetKind
    public var provider: String?
    public var model: String
    public var prompt: String
    public var inputs: RemoteInferenceJSONObject
    public var parameters: RemoteInferenceJSONObject
    public var metadata: [String: String]

    public init(
        generationId: String? = nil,
        kind: RemoteInferenceAssetKind,
        provider: String? = nil,
        model: String,
        prompt: String,
        inputs: RemoteInferenceJSONObject = [:],
        parameters: RemoteInferenceJSONObject = [:],
        metadata: [String: String] = [:]
    ) {
        self.generationId = generationId
        self.kind = kind
        self.provider = provider
        self.model = model
        self.prompt = prompt
        self.inputs = inputs
        self.parameters = parameters
        self.metadata = metadata
    }
}

public struct RemoteInferenceOutputRef: Codable, Equatable, Sendable {
    public var id: String
    public var kind: RemoteInferenceModality
    public var url: String?
    public var dataBase64: String?
    public var contentType: String?
    public var filename: String?
    public var byteCount: Int64?
    public var metadata: RemoteInferenceJSONObject?

    public init(
        id: String,
        kind: RemoteInferenceModality,
        url: String? = nil,
        dataBase64: String? = nil,
        contentType: String? = nil,
        filename: String? = nil,
        byteCount: Int64? = nil,
        metadata: RemoteInferenceJSONObject? = nil
    ) {
        self.id = id
        self.kind = kind
        self.url = url
        self.dataBase64 = dataBase64
        self.contentType = contentType
        self.filename = filename
        self.byteCount = byteCount
        self.metadata = metadata
    }
}

public struct RemoteInferenceGenerationRecord: Codable, Equatable, Sendable {
    public var id: String
    public var kind: RemoteInferenceAssetKind
    public var status: RemoteInferenceGenerationStatus
    public var provider: String
    public var model: String
    public var providerJobId: String?
    public var providerGenerationId: String?
    public var providerPollingUrl: String?
    public var outputs: [RemoteInferenceOutputRef]
    public var usage: RemoteInferenceJSONValue?
    public var error: RemoteInferenceJSONValue?
    public var metadata: RemoteInferenceJSONObject

    public init(
        id: String,
        kind: RemoteInferenceAssetKind,
        status: RemoteInferenceGenerationStatus,
        provider: String,
        model: String,
        providerJobId: String? = nil,
        providerGenerationId: String? = nil,
        providerPollingUrl: String? = nil,
        outputs: [RemoteInferenceOutputRef],
        usage: RemoteInferenceJSONValue? = nil,
        error: RemoteInferenceJSONValue? = nil,
        metadata: RemoteInferenceJSONObject = [:]
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.provider = provider
        self.model = model
        self.providerJobId = providerJobId
        self.providerGenerationId = providerGenerationId
        self.providerPollingUrl = providerPollingUrl
        self.outputs = outputs
        self.usage = usage
        self.error = error
        self.metadata = metadata
    }
}

public struct RemoteInferenceModel: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var provider: String
    public var inputModalities: [RemoteInferenceModality]
    public var outputModalities: [RemoteInferenceModality]
    public var contextLength: Int?
    public var pricing: RemoteInferenceJSONValue?
    public var metadata: RemoteInferenceJSONObject

    public init(
        id: String,
        name: String,
        provider: String,
        inputModalities: [RemoteInferenceModality],
        outputModalities: [RemoteInferenceModality],
        contextLength: Int? = nil,
        pricing: RemoteInferenceJSONValue? = nil,
        metadata: RemoteInferenceJSONObject = [:]
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.inputModalities = inputModalities
        self.outputModalities = outputModalities
        self.contextLength = contextLength
        self.pricing = pricing
        self.metadata = metadata
    }
}

public struct RemoteInferenceModelList: Codable, Equatable, Sendable {
    public var data: [RemoteInferenceModel]

    public init(data: [RemoteInferenceModel]) {
        self.data = data
    }
}

public struct RemoteInferenceDownloadedAsset: Codable, Equatable, Sendable {
    public var outputID: String
    public var fileURL: URL
    public var contentType: String
    public var byteCount: Int64

    public init(outputID: String, fileURL: URL, contentType: String, byteCount: Int64) {
        self.outputID = outputID
        self.fileURL = fileURL
        self.contentType = contentType
        self.byteCount = byteCount
    }

    public func userQueryAssetDraft(displayName: String? = nil) -> UserQueryTaskAssetDraft {
        UserQueryTaskAssetDraft(
            source: .agentReturned,
            displayName: displayName ?? fileURL.lastPathComponent,
            contentType: contentType,
            urlString: fileURL.absoluteString,
            byteCount: byteCount
        )
    }
}

public struct RemoteInferenceServerSentEvent: Equatable, Sendable {
    public var event: String?
    public var data: String
    public var id: String?

    public init(event: String? = nil, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
