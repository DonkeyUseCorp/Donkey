import DonkeyAI
import DonkeyHarness
import Foundation
import Testing

@Suite
struct GeminiLiveTests {
    @Test
    func configurationParsesEnvironment() {
        // Live is on by default with no env set; audio off.
        let defaults = GeminiLiveConfiguration.fromEnvironment([:])
        #expect(defaults.enabled)
        #expect(defaults.audioEnabled == false)

        // Explicit opt-out.
        let disabled = GeminiLiveConfiguration.fromEnvironment(["GEMINI_LIVE_ENABLED": "false"])
        #expect(disabled.enabled == false)

        // Optional audio opt-in.
        let withAudio = GeminiLiveConfiguration.fromEnvironment(["GEMINI_LIVE_AUDIO": "true"])
        #expect(withAudio.enabled)
        #expect(withAudio.audioEnabled)
    }

    @Test
    func functionDeclarationsCoverCommandLayerAndInferRequired() {
        let declarations = CommandLayerFunctionDeclarations.declarations()
        #expect(declarations.count == DonkeyCommandLayer.Command.allCases.count)

        let names = Set(declarations.compactMap { $0["name"] as? String })
        for command in DonkeyCommandLayer.Command.allCases {
            #expect(names.contains(command.rawValue))
        }

        // music.play has a required `query` and an optional `app`.
        let music = declarations.first { ($0["name"] as? String) == "music.play" }
        let parameters = music?["parameters"] as? [String: Any]
        let required = parameters?["required"] as? [String] ?? []
        #expect(required.contains("query"))
        #expect(!required.contains("app"))
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
