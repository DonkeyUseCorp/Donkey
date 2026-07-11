@testable import Donkey
import DonkeyAI
import DonkeyHarness
import Foundation
import Testing

@Suite
struct GeminiLiveTests {
    @Test
    func configurationParsesEnvironment() {
        // Live is always on with audio off and audio-output on; only GEMINI_API_KEY
        // is read from the environment, the rest is fixed in code.
        let config = GeminiLiveConfiguration.fromEnvironment([:])
        #expect(config.enabled)
        #expect(config.audioEnabled == false)
        #expect(config.liveAudioOutput)
        #expect(config.apiKey == nil)
    }

    @Test
    func functionDeclarationsCoverCommandLayerAndInferRequired() {
        let declarations = CommandLayerFunctionDeclarations.declarations()
        #expect(declarations.count == DonkeyCommandLayer.Command.allCases.count)

        let names = Set(declarations.compactMap { $0["name"] as? String })
        for command in DonkeyCommandLayer.Command.allCases {
            #expect(names.contains(command.rawValue))
        }

        // skill_run requires the ids app_skill advertises; the script input is
        // optional (some scripts take none).
        let skillRun = declarations.first { ($0["name"] as? String) == "skill_run" }
        let parameters = skillRun?["parameters"] as? [String: Any]
        let required = parameters?["required"] as? [String] ?? []
        #expect(required.contains("skillID"))
        #expect(required.contains("scriptID"))
        #expect(!required.contains("input"))
    }

    @Test
    func commandNamesAreValidFunctionCallIdentifiers() {
        // Gemini/Vertex Live rejects dots in function names and normalizes them
        // (e.g. `apps.list` → `apps_list`), so a dotted name would never dispatch.
        // Every Command Layer name must be a plain `[A-Za-z_][A-Za-z0-9_]*` id.
        for command in DonkeyCommandLayer.Command.allCases {
            let name = command.rawValue
            #expect(!name.isEmpty)
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
            #expect(
                name.unicodeScalars.allSatisfy(allowed.contains),
                "command name \(name) is not a valid LLM function identifier"
            )
            let first = name.unicodeScalars.first!
            #expect(
                !CharacterSet(charactersIn: "0123456789").contains(first),
                "command name \(name) must not start with a digit"
            )
        }
    }

    @Test
    func developerAPIProviderUsesKeyModelAndAudioOutput() async throws {
        // GEMINI_API_KEY → connect directly to the Developer API with the key in
        // the query string, the hardcoded default model, and AUDIO output.
        let config = GeminiLiveConfiguration.fromEnvironment([
            "GEMINI_API_KEY": "test-key-123"
        ])
        #expect(config.apiKey == "test-key-123")
        #expect(config.model == GeminiLiveConfiguration.defaultModel)

        let connection = try await GeminiLiveConnectionFactory.makeProvider(configuration: config)()
        #expect(connection.bearerToken == nil)
        #expect(connection.audioOutput)
        #expect(connection.model == GeminiLiveConfiguration.defaultModel)
        #expect(connection.url.absoluteString.contains("generativelanguage.googleapis.com"))
        #expect(connection.url.query?.contains("key=test-key-123") == true)
    }

    @Test
    func configDefaultsToLive25AndVision35() {
        // Command Live model defaults to a 2.5 model; the turn-based vision model
        // defaults to the stronger gemini-3.5-flash.
        #expect(GeminiLiveConfiguration.defaultModel.contains("2.5"))
        #expect(GeminiLiveConfiguration.defaultVisionModel == "gemini-3.5-flash")
        let defaults = GeminiLiveConfiguration.fromEnvironment([:])
        #expect(defaults.apiKey == nil)
        #expect(defaults.model == GeminiLiveConfiguration.defaultModel)
        #expect(defaults.visionModel == "gemini-3.5-flash")
    }

    @Test
    @MainActor
    func canonicalToolNameStripsGeminiPrefixes() {
        // Gemini sometimes namespaces tool-call names; dispatch must match the
        // declared name (this regressed vision_control → `default_vision_control`).
        #expect(GeminiLiveVoiceController.canonicalToolName("vision_control") == "vision_control")
        #expect(GeminiLiveVoiceController.canonicalToolName("default_vision_control") == "vision_control")
        #expect(GeminiLiveVoiceController.canonicalToolName("default_api.skill_run") == "skill_run")
        #expect(GeminiLiveVoiceController.canonicalToolName("apps_list") == "apps_list")
    }

    @Test
    func pcm16ResamplesAndPacksLittleEndian() {
        // 48kHz → 16kHz is a 3:1 decimation.
        let samples = Array(repeating: Float(0), count: 480)
        let data = GeminiLivePCM.pcm16Mono16k(from: samples, sourceRate: 48_000)
        // ~160 output samples * 2 bytes each.
        #expect(data.count == 160 * MemoryLayout<Int16>.size)

        // Full-scale sample clamps to Int16.max (0xFF7F little-endian for 32767).
        let loud = GeminiLivePCM.pcm16Mono16k(from: [1.0, 1.0], sourceRate: 16_000)
        #expect(loud.count == 2 * MemoryLayout<Int16>.size)
        #expect(loud[0] == 0xFF)
        #expect(loud[1] == 0x7F)
    }

    @Test
    func parsesToolCallAndSetupCompleteFrames() {
        let setup = Data(#"{"setupComplete":{}}"#.utf8)
        #expect(GeminiLiveProtocol.parseServerEvents(setup) == [.connected])

        let toolCall = Data(#"""
        {"toolCall":{"functionCalls":[{"id":"c1","name":"app.open","args":{"app":"Spotify"}}]}}
        """#.utf8)
        let events = GeminiLiveProtocol.parseServerEvents(toolCall)
        #expect(events == [.toolCalls([
            AIRealtimeToolCall(id: "c1", name: "app.open", arguments: ["app": "Spotify"])
        ])])
    }

    @Test
    func parsesModelTurnTextAndTurnCompletion() {
        // Text-modality answers arrive as modelTurn text parts; they are the
        // model's ANSWER and must surface as textOut, never as a transcript.
        let textFrame = Data(#"""
        {"serverContent":{"modelTurn":{"parts":[{"text":"Your largest file is movie.mkv (4.2 GB)."}]}}}
        """#.utf8)
        #expect(GeminiLiveProtocol.parseServerEvents(textFrame) == [
            .textOut("Your largest file is movie.mkv (4.2 GB).")
        ])

        // turnComplete closes the turn so buffered text can flush; an audio-mode
        // output transcription on the same frame is delivered first.
        let completeFrame = Data(#"""
        {"serverContent":{"turnComplete":true,"outputTranscription":{"text":"Done."}}}
        """#.utf8)
        #expect(GeminiLiveProtocol.parseServerEvents(completeFrame) == [
            .finalTranscript("Done."),
            .turnComplete
        ])

        let bareComplete = Data(#"{"serverContent":{"turnComplete":true}}"#.utf8)
        #expect(GeminiLiveProtocol.parseServerEvents(bareComplete) == [.turnComplete])
    }

    @Test
    @MainActor
    func agentRunDescriptorIsAValidRegisteredEscalation() {
        // The delegation escalation must be a valid LLM function identifier and
        // require the structured goal it hands to the local pipeline.
        let descriptor = GeminiLiveVoiceController.agentRunDescriptor
        #expect(descriptor.name == "agent_run")
        #expect(descriptor.inputSchema.keys.contains("goal"))
        let declarations = CommandLayerFunctionDeclarations.declarations(from: [descriptor])
        let parameters = declarations.first?["parameters"] as? [String: Any]
        let required = parameters?["required"] as? [String] ?? []
        #expect(required.contains("goal"))
    }

    @Test
    func setupMessageDoesNotDoublePrefixVertexModelPath() {
        let vertexModel = "projects/p/locations/global/publishers/google/models/gemini-2.0-flash-live-001"
        let data = GeminiLiveProtocol.setupMessage(
            model: vertexModel,
            systemInstruction: "be fast",
            functionDeclarations: [],
            includeAudioResponse: false,
            resumptionHandle: nil
        )
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let setup = root?["setup"] as? [String: Any]
        #expect((setup?["model"] as? String) == vertexModel)
    }

    @Test
    func decodesBackendLiveConnection() throws {
        let json = Data(#"""
        {"token":"ya29.tok","websocketUrl":"wss://aiplatform.googleapis.com/ws/x",
         "model":"projects/p/locations/global/publishers/google/models/m",
         "expiresAt":"2026-01-01T00:00:00Z","project":"p","location":"global"}
        """#.utf8)
        let connection = try JSONDecoder().decode(RemoteLiveConnection.self, from: json)
        #expect(connection.token == "ya29.tok")
        #expect(connection.websocketUrl == "wss://aiplatform.googleapis.com/ws/x")
        #expect(connection.model.hasSuffix("/models/m"))
    }

    @Test
    func buildsSetupMessageWithToolsAndSessionPolicies() {
        let data = GeminiLiveProtocol.setupMessage(
            model: "gemini-test-live",
            systemInstruction: "be fast",
            functionDeclarations: CommandLayerFunctionDeclarations.declarations(),
            includeAudioResponse: false,
            resumptionHandle: nil
        )
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let setup = root?["setup"] as? [String: Any]
        #expect((setup?["model"] as? String) == "models/gemini-test-live")
        #expect(setup?["contextWindowCompression"] != nil)
        #expect(setup?["sessionResumption"] != nil)
        let tools = setup?["tools"] as? [[String: Any]]
        let declarations = tools?.first?["functionDeclarations"] as? [[String: Any]]
        #expect((declarations?.count ?? 0) == DonkeyCommandLayer.Command.allCases.count)
    }
}
