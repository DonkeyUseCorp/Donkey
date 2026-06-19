import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation
import Testing

@Suite
struct DonkeyBackendInferenceClientTests {
    @Test
    func streamingChatRequestUsesBackendHeadersAndFlattensParameters() throws {
        let client = DonkeyBackendInferenceClient(
            configuration: configuration(),
            httpClient: FixtureHTTPClient(data: Data("{}".utf8), statusCode: 200)
        )
        let request = try client.makeStreamingChatRequest(
            RemoteInferenceChatCompletionRequest(
                model: "router/large",
                messages: [
                    RemoteInferenceChatMessage(role: "user", content: .string("hello"))
                ],
                parameters: [
                    "temperature": .number(0.2)
                ]
            )
        )

        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.httpShouldHandleCookies == true)
        #expect(request.value(forHTTPHeaderField: "x-donkey-client-id") == "client-1")
        #expect(request.url?.path == "/api/inference/chat/completions/")

        let object = try #require(request.httpBodyJSONObject)
        #expect(object["stream"] as? Bool == true)
        #expect(object["temperature"] as? Double == 0.2)
        #expect(object["model"] as? String == "router/large")
    }

    @Test
    func streamChatParsesSSEDeltasAndReturnsAccumulatedText() async throws {
        // OpenAI-style SSE: a role-only opener (no content) is skipped, content chunks accumulate, and
        // the [DONE] sentinel ends the stream. The default streamLines splits the buffered body by line.
        let sse = """
        data: {"choices":[{"delta":{"role":"assistant"}}]}

        data: {"choices":[{"delta":{"content":"Now "}}]}

        data: {"choices":[{"delta":{"content":"playing."}}]}

        data: [DONE]

        """
        let client = DonkeyBackendInferenceClient(
            configuration: configuration(),
            httpClient: FixtureHTTPClient(data: Data(sse.utf8), statusCode: 200)
        )
        let collector = StreamDeltaCollector()
        let full = try await client.streamChat(
            RemoteInferenceChatCompletionRequest(
                messages: [RemoteInferenceChatMessage(role: "user", content: .string("hi"))]
            ),
            onDelta: { delta in collector.append(delta) }
        )

        #expect(full == "Now playing.")
        #expect(collector.values() == ["Now ", "playing."])
    }

    @Test
    func createResponseUsesBackendProxyAndStoreFalse() async throws {
        let httpClient = FixtureHTTPClient(
            data: Data(#"{"output_text":"{\"taskType\":\"none\"}"}"#.utf8),
            statusCode: 200
        )
        let client = DonkeyBackendInferenceClient(
            configuration: configuration(),
            httpClient: httpClient
        )

        _ = try await client.createResponse(
            RemoteInferenceResponseCreateRequest(
                input: .string("hello"),
                store: false,
                metadata: ["source_trace_id": "trace-1"]
            )
        )

        let request = try #require(httpClient.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "x-donkey-client-id") == "client-1")
        #expect(request.value(forHTTPHeaderField: "x-donkey-dev-auth-bypass") == nil)
        #expect(request.url?.path == "/api/inference/responses/")

        let object = try #require(request.httpBodyJSONObject)
        #expect(object["model"] == nil)
        #expect(object["store"] as? Bool == false)
        #expect(object["stream"] as? Bool == false)
    }

    @Test
    func backendRequestsSendDevAuthBypassHeaderWhenConfigured() {
        let client = DonkeyBackendInferenceClient(
            configuration: DonkeyBackendInferenceConfiguration(
                baseURL: URL(string: "https://donkey.example")!,
                clientID: "client-1",
                devAuthBypass: true
            ),
            httpClient: FixtureHTTPClient(data: Data("{}".utf8), statusCode: 200)
        )

        let request = client.makeRequest(path: "/api/inference/responses/")

        #expect(request.value(forHTTPHeaderField: "x-donkey-client-id") == "client-1")
        #expect(request.value(forHTTPHeaderField: "x-donkey-dev-auth-bypass") == "1")
    }

    @Test
    func createResponseSendsDebugUIInspectionToolWithoutProviderCredentials() async throws {
        let httpClient = FixtureHTTPClient(
            data: Data(#"{"output_text":"{\"elements\":[]}"}"#.utf8),
            statusCode: 200
        )
        let client = DonkeyBackendInferenceClient(
            configuration: configuration(),
            httpClient: httpClient
        )

        _ = try await client.createResponse(
            RemoteInferenceResponseCreateRequest(
                donkeyProvider: "openai",
                input: .string("inspect"),
                tools: [
                    RemoteInferenceComputerUseTool(type: .debugUIInspection).jsonObject
                ],
                metadata: ["source": "debug-ui-inspection-overlay"]
            )
        )

        let request = try #require(httpClient.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "x-donkey-client-id") == "client-1")

        let object = try #require(request.httpBodyJSONObject)
        #expect(object["donkeyProvider"] as? String == "openai")
        #expect(object["store"] as? Bool == false)
        let tools = try #require(object["tools"] as? [[String: Any]])
        #expect(tools.first?["type"] as? String == "donkey_debug_ui_inspection")
    }

    @Test
    func parseScreenshotUsesBackendProxyAndDecodesLocalUIUnderstandingResult() async throws {
        let response = LocalUIUnderstandingResult(
            visibleText: ["visibleText": "Search"],
            controls: [
                LocalUIUnderstandingControl(
                    id: "search",
                    label: "Search",
                    kind: .searchField,
                    frame: HotLoopRect(x: 10, y: 20, width: 100, height: 30, space: .window),
                    confidence: 0.84,
                    metadata: ["controlID": "search"]
                )
            ],
            confidence: 0.84,
            metadata: ["runtime.backend": "gemini-screenshot-parser"]
        )
        let httpClient = FixtureHTTPClient(
            data: try JSONEncoder().encode(response),
            statusCode: 200
        )
        let client = DonkeyBackendInferenceClient(
            configuration: configuration(),
            httpClient: httpClient
        )

        let result = try await client.parseScreenshot(
            LocalUIUnderstandingRequest(
                traceID: "trace-1",
                targetID: "target-1",
                imageFileURL: nil,
                cropBounds: HotLoopRect(x: 0, y: 0, width: 200, height: 100, space: .window),
                pixelSize: HotLoopSize(width: 200, height: 100, space: .window),
                metadata: ["source": "test"]
            ),
            imageData: Data("png".utf8)
        )

        #expect(result.controls.first?.id == "search")
        let request = try #require(httpClient.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "x-donkey-client-id") == "client-1")
        #expect(request.url?.path == "/api/inference/screenshots/parse/")

        let object = try #require(request.httpBodyJSONObject)
        #expect(object["imageBase64"] as? String == Data("png".utf8).base64EncodedString())
        #expect(object["contentType"] as? String == "image/png")
        #expect(object["traceID"] as? String == "trace-1")
        #expect(object["targetID"] as? String == "target-1")
        #expect(object["stream"] as? Bool == false)
        let pixelSize = try #require(object["pixelSize"] as? [String: Any])
        #expect(pixelSize["width"] as? Double == 200)
        #expect(pixelSize["height"] as? Double == 100)
        let metadata = try #require(object["metadata"] as? [String: Any])
        #expect(metadata["screenshot.scope"] as? String == "targetWindow")
        #expect(metadata["screenshot.desktopCaptureAllowed"] as? String == "false")
    }

    @Test
    @MainActor
    func parseScreenshotStreamUsesSSEAndEmitsPartialBeforeFinal() async throws {
        let partial = LocalUIUnderstandingResult(
            controls: [
                LocalUIUnderstandingControl(
                    id: "partial-play",
                    label: "Play",
                    kind: .button,
                    frame: HotLoopRect(x: 10, y: 20, width: 80, height: 40, space: .window),
                    confidence: 0.7
                )
            ],
            confidence: 0.7,
            metadata: ["screenshotParser.stream": "partial"]
        )
        let final = LocalUIUnderstandingResult(
            controls: [
                LocalUIUnderstandingControl(
                    id: "partial-play",
                    label: "Play",
                    kind: .button,
                    frame: HotLoopRect(x: 10, y: 20, width: 80, height: 40, space: .window),
                    confidence: 0.7
                ),
                LocalUIUnderstandingControl(
                    id: "final-shuffle",
                    label: "Shuffle",
                    kind: .button,
                    frame: HotLoopRect(x: 100, y: 20, width: 90, height: 40, space: .window),
                    confidence: 0.8
                )
            ],
            confidence: 0.8,
            metadata: ["screenshotParser.stream": "final"]
        )
        let encoder = JSONEncoder()
        let responseText = [
            "event: partial",
            "data: \(String(data: try encoder.encode(partial), encoding: .utf8)!)",
            "",
            "event: final",
            "data: \(String(data: try encoder.encode(final), encoding: .utf8)!)",
            "",
        ].joined(separator: "\n")
        let httpClient = FixtureHTTPClient(
            data: Data(responseText.utf8),
            statusCode: 200,
            headerFields: ["Content-Type": "text/event-stream"]
        )
        let client = DonkeyBackendInferenceClient(
            configuration: configuration(),
            httpClient: httpClient
        )

        var partials: [LocalUIUnderstandingResult] = []
        let result = try await client.parseScreenshotStream(
            LocalUIUnderstandingRequest(
                traceID: "trace-stream",
                targetID: "target-stream",
                pixelSize: HotLoopSize(width: 200, height: 100, space: .window)
            ),
            imageData: Data("png".utf8)
        ) { partial in
            partials.append(partial)
        }

        #expect(partials.map(\.controls.count) == [1])
        #expect(partials.first?.controls.first?.id == "partial-play")
        #expect(result.controls.map(\.id) == ["partial-play", "final-shuffle"])
        let request = try #require(httpClient.requests.first)
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        let object = try #require(request.httpBodyJSONObject)
        #expect(object["stream"] as? Bool == true)
    }

    @Test
    @MainActor
    func parseScreenshotStreamToleratesConcatenatedJSONDataLines() async throws {
        let stalePartial = LocalUIUnderstandingResult(
            controls: [
                LocalUIUnderstandingControl(
                    id: "stale-play",
                    label: "Play",
                    kind: .button,
                    confidence: 0.4
                )
            ],
            confidence: 0.4,
            metadata: ["screenshotParser.stream": "partial"]
        )
        let latestPartial = LocalUIUnderstandingResult(
            controls: [
                LocalUIUnderstandingControl(
                    id: "latest-play",
                    label: "Play",
                    kind: .button,
                    confidence: 0.8
                )
            ],
            confidence: 0.8,
            metadata: ["screenshotParser.stream": "partial"]
        )
        let final = LocalUIUnderstandingResult(
            controls: [
                LocalUIUnderstandingControl(
                    id: "final-result",
                    label: "Search Result",
                    kind: .listItem,
                    confidence: 0.9
                )
            ],
            confidence: 0.9,
            metadata: ["screenshotParser.stream": "final"]
        )
        let encoder = JSONEncoder()
        let responseText = [
            "event: partial",
            "data: \(String(data: try encoder.encode(stalePartial), encoding: .utf8)!)",
            "data: \(String(data: try encoder.encode(latestPartial), encoding: .utf8)!)",
            "",
            "event: final",
            "data: \(String(data: try encoder.encode(stalePartial), encoding: .utf8)!)",
            "data: \(String(data: try encoder.encode(final), encoding: .utf8)!)",
            "",
        ].joined(separator: "\n")
        let httpClient = FixtureHTTPClient(
            data: Data(responseText.utf8),
            statusCode: 200,
            headerFields: ["Content-Type": "text/event-stream"]
        )
        let client = DonkeyBackendInferenceClient(
            configuration: configuration(),
            httpClient: httpClient
        )

        var partials: [LocalUIUnderstandingResult] = []
        let result = try await client.parseScreenshotStream(
            LocalUIUnderstandingRequest(
                traceID: "trace-concat",
                targetID: "target-concat",
                pixelSize: HotLoopSize(width: 200, height: 100, space: .window)
            ),
            imageData: Data("png".utf8)
        ) { partial in
            partials.append(partial)
        }

        #expect(partials.map(\.controls.first?.id) == ["latest-play"])
        #expect(result.controls.map(\.id) == ["final-result"])
    }

    @Test
    @MainActor
    func parseScreenshotStreamRecoversResultFromErrorEventPayload() async throws {
        let stalePartial = LocalUIUnderstandingResult(
            controls: [
                LocalUIUnderstandingControl(
                    id: "stale-close",
                    label: "Close",
                    kind: .button,
                    confidence: 0.5
                )
            ],
            confidence: 0.5,
            metadata: ["screenshotParser.stream": "partial"]
        )
        let final = LocalUIUnderstandingResult(
            controls: [
                LocalUIUnderstandingControl(
                    id: "final-close",
                    label: "Close",
                    kind: .button,
                    confidence: 0.9
                )
            ],
            confidence: 0.9,
            metadata: ["screenshotParser.stream": "final"]
        )
        let encoder = JSONEncoder()
        let concatenatedResults = [
            String(data: try encoder.encode(stalePartial), encoding: .utf8)!,
            String(data: try encoder.encode(final), encoding: .utf8)!
        ].joined(separator: "\n")
        let errorPayloadData = try JSONSerialization.data(
            withJSONObject: [
                "error": "invalid_provider_output",
                "message": concatenatedResults
            ]
        )
        let errorPayload = try #require(String(data: errorPayloadData, encoding: .utf8))
        let responseText = [
            "event: error",
            "data: \(errorPayload)",
            "",
        ].joined(separator: "\n")
        let httpClient = FixtureHTTPClient(
            data: Data(responseText.utf8),
            statusCode: 200,
            headerFields: ["Content-Type": "text/event-stream"]
        )
        let client = DonkeyBackendInferenceClient(
            configuration: configuration(),
            httpClient: httpClient
        )

        let result = try await client.parseScreenshotStream(
            LocalUIUnderstandingRequest(
                traceID: "trace-error-recovery",
                targetID: "target-error-recovery",
                pixelSize: HotLoopSize(width: 200, height: 100, space: .window)
            ),
            imageData: Data("png".utf8)
        ) { _ in }

        #expect(result.controls.map(\.id) == ["final-close"])
    }

    @Test
    func screenshotParseOverlayMapperConvertsWindowPixelsToScreenOverlayCoordinates() throws {
        let result = LocalUIUnderstandingResult(
            controls: [
                LocalUIUnderstandingControl(
                    id: "review",
                    label: "Review",
                    kind: .button,
                    frame: HotLoopRect(x: 100, y: 50, width: 200, height: 100, space: .window),
                    confidence: 0.91,
                    metadata: ["controlID": "review"]
                )
            ],
            confidence: 0.91,
            metadata: ["parserProvider": "gemini-flash"]
        )
        let target = MacWindowTargetCandidate(
            windowID: 42,
            processID: 100,
            appName: "Codex",
            bundleIdentifier: "com.openai.codex",
            title: "Add screenshot parsing endpoint",
            bounds: WindowTargetBounds(x: 100, y: 200, width: 500, height: 300),
            isVisible: true,
            isOnScreen: true,
            isFrontmost: true,
            isFocused: true,
            isIPhoneMirroring: false,
            safetyAssessment: WindowTargetSafetyAssessment(
                status: .allowed,
                summary: "allowed"
            )
        )

        let frame = ScreenshotParseDebugUIOverlayMapper.frame(
            from: result,
            target: target,
            capturePixelSize: HotLoopSize(width: 1_000, height: 600, space: .window),
            screenFrame: WindowTargetBounds(x: 0, y: 0, width: 1_000, height: 800),
            minConfidence: 0.25
        )

        let element = try #require(frame.elements.first)
        #expect(element.id == "ai-42-review")
        #expect(element.type == .button)
        #expect(element.bbox == DebugUIBoundingBox(x: 150, y: 225, width: 100, height: 50))
        #expect(element.metadata["directInputActionsAllowed"] == "true")
        #expect(element.metadata["localUIElement.actionEligibility"] == "guardedAction")
        #expect(element.metadata["target.windowID"] == "42")
        #expect(element.metadata["debugOverlay.localBounds.x"] == "50.0")
        #expect(element.metadata["debugOverlay.localBounds.y"] == "25.0")
        #expect(element.metadata["debugOverlay.localBounds.width"] == "100.0")
        #expect(element.metadata["debugOverlay.localBounds.height"] == "50.0")
    }

    @Test
    func screenshotParseOverlayMapperUsesCompressedImagePixelSpace() throws {
        let result = LocalUIUnderstandingResult(
            controls: [
                LocalUIUnderstandingControl(
                    id: "compressed-review",
                    label: "Review",
                    kind: .button,
                    frame: HotLoopRect(x: 448, y: 320, width: 112, height: 64, space: .window),
                    confidence: 0.91
                )
            ],
            confidence: 0.91
        )
        let target = MacWindowTargetCandidate(
            windowID: 43,
            processID: 100,
            appName: "Codex",
            bundleIdentifier: "com.openai.codex",
            title: "Add screenshot parsing endpoint",
            bounds: WindowTargetBounds(x: 1_440, y: 120, width: 756, height: 540),
            isVisible: true,
            isOnScreen: true,
            isFrontmost: true,
            isFocused: true,
            isIPhoneMirroring: false,
            safetyAssessment: WindowTargetSafetyAssessment(
                status: .allowed,
                summary: "allowed"
            )
        )

        let frame = ScreenshotParseDebugUIOverlayMapper.frame(
            from: result,
            target: target,
            capturePixelSize: HotLoopSize(width: 896, height: 640, space: .window),
            screenFrame: WindowTargetBounds(x: 1_440, y: 0, width: 1_440, height: 900),
            minConfidence: 0.25
        )

        let bbox = try #require(frame.elements.first?.bbox)
        #expect(abs(bbox.x - 378) < 0.0001)
        #expect(abs(bbox.y - 390) < 0.0001)
        #expect(abs(bbox.width - 94.5) < 0.0001)
        #expect(abs(bbox.height - 54) < 0.0001)
    }

    @Test
    func debugUIFusionKeepsAccessibilityGeometryAndAddsAIGaps() throws {
        let accessibilityFrame = DebugUIInspectionFrame(
            elements: [
                DebugUIElement(
                    id: "ax-review",
                    type: .button,
                    label: "Review",
                    bbox: DebugUIBoundingBox(x: 100, y: 100, width: 80, height: 30),
                    confidence: 1,
                    metadata: ["localUIElement.sources": "accessibility"]
                ),
                DebugUIElement(
                    id: "ax-window",
                    type: .draggable,
                    label: "Window",
                    bbox: DebugUIBoundingBox(x: 0, y: 0, width: 500, height: 400),
                    confidence: 1,
                    metadata: ["localUIElement.sources": "accessibility"]
                )
            ]
        )
        let aiFrame = DebugUIInspectionFrame(
            elements: [
                DebugUIElement(
                    id: "ai-review",
                    type: .button,
                    label: "Review",
                    bbox: DebugUIBoundingBox(x: 105, y: 105, width: 60, height: 20),
                    confidence: 0.95,
                    metadata: ["localUIElement.sources": "remote-screenshot-parser"]
                ),
                DebugUIElement(
                    id: "ai-voice",
                    type: .toolbarIcon,
                    label: "Voice",
                    bbox: DebugUIBoundingBox(x: 220, y: 100, width: 40, height: 30),
                    confidence: 0.9,
                    metadata: ["localUIElement.sources": "remote-screenshot-parser"]
                )
            ]
        )

        let fused = DebugUIInspectionFrameFusion.fused(
            accessibilityFrame: accessibilityFrame,
            aiFrame: aiFrame
        )
        let ids = fused.elements.map(\.id)

        #expect(ids.contains("ax-review"))
        #expect(ids.contains("ax-window"))
        #expect(!ids.contains("ai-review"))
        #expect(ids.contains("ai-voice"))
        let aiElement = try #require(fused.elements.first { $0.id == "ai-voice" })
        #expect(aiElement.metadata["debugUIFusion.source"] == "ai")
        #expect(aiElement.metadata["directInputActionsAllowed"] == "true")
        #expect(aiElement.metadata["localUIElement.actionEligibility"] == "guardedAction")
    }

    @Test
    func debugUIFusionDoesNotLetLargeAccessibilityContainersHideAIControls() throws {
        let accessibilityFrame = DebugUIInspectionFrame(
            elements: [
                DebugUIElement(
                    id: "ax-sidebar-group",
                    type: .listItem,
                    label: "Sidebar",
                    bbox: DebugUIBoundingBox(x: 0, y: 0, width: 260, height: 700),
                    confidence: 0.8,
                    metadata: ["localUIElement.sources": "accessibility"]
                )
            ]
        )
        let aiFrame = DebugUIInspectionFrame(
            elements: [
                DebugUIElement(
                    id: "ai-small-icon",
                    type: .toolbarIcon,
                    label: "Search",
                    bbox: DebugUIBoundingBox(x: 18, y: 84, width: 28, height: 28),
                    confidence: 0.88,
                    metadata: ["localUIElement.sources": "remote-screenshot-parser"]
                )
            ]
        )

        let fused = DebugUIInspectionFrameFusion.fused(
            accessibilityFrame: accessibilityFrame,
            aiFrame: aiFrame
        )

        #expect(fused.elements.map(\.id).contains("ai-small-icon"))
    }

    @Test
    func configurationUsesWebBaseEnvironmentURL() throws {
        let configuration = try DonkeyBackendInferenceConfiguration.fromEnvironment([
            "DONKEY_WEB_BASE_URL": "https://web.donkey.example",
            "DONKEY_BACKEND_URL": "https://api.donkey.example",
            "BETTER_AUTH_URL": "https://auth.donkey.example",
            "DONKEY_CLIENT_ID": "client-env"
        ])

        #expect(configuration.baseURL.absoluteString == "https://web.donkey.example")
        #expect(configuration.clientID == "client-env")
        #expect(configuration.devAuthBypass == false)
    }

    @Test
    func configurationReadsDevAuthBypassEnvironment() throws {
        let configuration = try DonkeyBackendInferenceConfiguration.fromEnvironment([
            "DONKEY_WEB_BASE_URL": "https://web.donkey.example",
            "DONKEY_CLIENT_ID": "client-env",
            "DONKEY_DEV_AUTH_BYPASS": "1",
        ])

        #expect(configuration.baseURL.absoluteString == "https://web.donkey.example")
        #expect(configuration.clientID == "client-env")
        #expect(configuration.devAuthBypass == true)
    }

    @Test
    func configurationUsesBundledWebBaseURL() throws {
        let fixture = try temporaryBundle(info: [
            "DonkeyWebBaseURL": "https://bundle.donkey.example"
        ])
        defer {
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        let configuration = try DonkeyBackendInferenceConfiguration.fromEnvironment(
            ["DONKEY_CLIENT_ID": "client-env"],
            bundle: fixture.bundle
        )

        #expect(configuration.baseURL.absoluteString == "https://bundle.donkey.example")
        #expect(configuration.clientID == "client-env")
    }

    @Test
    func configurationDoesNotUseBackendEnvironmentURLAsBaseURL() {
        #expect(throws: DonkeyBackendInferenceClientError.missingConfiguration("DONKEY_WEB_BASE_URL")) {
            _ = try DonkeyBackendInferenceConfiguration.fromEnvironment([
                "DONKEY_BACKEND_URL": "https://api.donkey.example",
                "BETTER_AUTH_URL": "https://auth.donkey.example",
                "DONKEY_CLIENT_ID": "client-env"
            ])
        }
    }

    @Test
    func configurationDoesNotUseBundledBackendURLAsBaseURL() throws {
        let fixture = try temporaryBundle(info: [
            "DonkeyBackendURL": "https://bundle-api.donkey.example"
        ])
        defer {
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        #expect(throws: DonkeyBackendInferenceClientError.missingConfiguration("DONKEY_WEB_BASE_URL")) {
            _ = try DonkeyBackendInferenceConfiguration.fromEnvironment(
                ["DONKEY_CLIENT_ID": "client-env"],
                bundle: fixture.bundle
            )
        }
    }

    @Test
    func configurationEnvironmentWebBaseURLOverridesBundledWebBaseURL() throws {
        let fixture = try temporaryBundle(info: [
            "DonkeyWebBaseURL": "https://bundle.donkey.example"
        ])
        defer {
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        let configuration = try DonkeyBackendInferenceConfiguration.fromEnvironment(
            [
                "DONKEY_WEB_BASE_URL": "https://web.donkey.example",
                "DONKEY_CLIENT_ID": "client-env"
            ],
            bundle: fixture.bundle
        )

        #expect(configuration.baseURL.absoluteString == "https://web.donkey.example")
        #expect(configuration.clientID == "client-env")
    }

    @Test
    func invalidEnvironmentWebBaseURLDoesNotUseBundledWebBaseURL() throws {
        let fixture = try temporaryBundle(info: [
            "DonkeyWebBaseURL": "https://bundle.donkey.example"
        ])
        defer {
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        #expect(throws: DonkeyBackendInferenceClientError.missingConfiguration("DONKEY_WEB_BASE_URL")) {
            _ = try DonkeyBackendInferenceConfiguration.fromEnvironment(
                [
                    "DONKEY_WEB_BASE_URL": "not a url",
                    "DONKEY_CLIENT_ID": "client-env"
                ],
                bundle: fixture.bundle
            )
        }
    }

    @Test
    func decodesServerSentEvents() {
        let data = Data(
            """
            id: one
            event: message
            data: {"delta":"hi"}

            data: [DONE]

            """.utf8
        )

        let events = DonkeyBackendInferenceClient.decodeServerSentEvents(data)

        #expect(events.count == 2)
        #expect(events.first?.id == "one")
        #expect(events.first?.event == "message")
        #expect(events.first?.data == #"{"delta":"hi"}"#)
        #expect(events.last?.data == "[DONE]")
    }

    @Test
    func createAssetGenerationSendsLocalGenerationID() async throws {
        let response = generationRecord(outputs: [])
        let httpClient = FixtureHTTPClient(
            data: try JSONEncoder().encode(response),
            statusCode: 201
        )
        let client = DonkeyBackendInferenceClient(
            configuration: configuration(),
            httpClient: httpClient
        )

        let record = try await client.createAssetGeneration(
            RemoteInferenceAssetGenerationRequest(
                kind: .image,
                model: "image-model",
                prompt: "make an icon"
            )
        )

        let object = try #require(httpClient.requests.first?.httpBodyJSONObject)
        let generationID = try #require(object["generationId"] as? String)
        #expect(generationID.hasPrefix("generation-"))
        #expect(record.id == response.id)
    }

    @Test
    func downloadsInlineOutputsIntoGenerationDirectory() async throws {
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("donkey-inference-tests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: baseDirectory)
        }

        let client = DonkeyBackendInferenceClient(
            configuration: configuration(),
            httpClient: FixtureHTTPClient(data: Data(), statusCode: 200)
        )
        let record = generationRecord(
            outputs: [
                RemoteInferenceOutputRef(
                    id: "audio-1",
                    kind: .audio,
                    dataBase64: Data("first".utf8).base64EncodedString(),
                    contentType: "audio/mpeg",
                    filename: "bad/name.mp3"
                ),
                RemoteInferenceOutputRef(
                    id: "audio-2",
                    kind: .audio,
                    dataBase64: Data("second".utf8).base64EncodedString(),
                    contentType: "audio/mpeg",
                    filename: "bad/name.mp3"
                )
            ]
        )

        let downloads = try await client.downloadCompletedOutputs(
            for: record,
            downloadsDirectory: baseDirectory
        )

        #expect(downloads.map { $0.fileURL.lastPathComponent } == ["bad-name.mp3", "bad-name-2.mp3"])
        #expect(try String(contentsOf: downloads[0].fileURL, encoding: .utf8) == "first")
        #expect(try String(contentsOf: downloads[1].fileURL, encoding: .utf8) == "second")
        #expect(downloads[0].fileURL.path.contains("/Donkey/generation-1/"))
        #expect(downloads[0].userQueryAssetDraft().source == .agentReturned)
    }

    @Test
    func remoteOutputDownloadsDoNotUseDonkeyClientHeaders() async throws {
        let httpClient = FixtureHTTPClient(
            data: Data("downloaded".utf8),
            statusCode: 200,
            headerFields: ["Content-Type": "video/mp4"]
        )
        let client = DonkeyBackendInferenceClient(
            configuration: configuration(),
            httpClient: httpClient
        )
        let record = generationRecord(
            outputs: [
                RemoteInferenceOutputRef(
                    id: "video-1",
                    kind: .video,
                    url: "https://cdn.example/video.mp4",
                    contentType: "video/mp4",
                    filename: "video.mp4"
                )
            ]
        )
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("donkey-inference-tests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: baseDirectory)
        }

        let downloads = try await client.downloadCompletedOutputs(
            for: record,
            downloadsDirectory: baseDirectory
        )

        #expect(downloads.first?.contentType == "video/mp4")
        #expect(httpClient.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(httpClient.requests.first?.httpShouldHandleCookies == true)
        #expect(httpClient.requests.first?.value(forHTTPHeaderField: "x-donkey-client-id") == nil)
    }

    @Test
    func downloadsDataURLOutputsLocally() async throws {
        let client = DonkeyBackendInferenceClient(
            configuration: configuration(),
            httpClient: FixtureHTTPClient(data: Data(), statusCode: 200)
        )
        let record = generationRecord(
            outputs: [
                RemoteInferenceOutputRef(
                    id: "image-1",
                    kind: .image,
                    url: "data:image/png;base64,\(Data("png".utf8).base64EncodedString())",
                    filename: "image.png"
                )
            ]
        )
        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("donkey-inference-tests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: baseDirectory)
        }

        let downloads = try await client.downloadCompletedOutputs(
            for: record,
            downloadsDirectory: baseDirectory
        )

        #expect(try String(contentsOf: downloads[0].fileURL, encoding: .utf8) == "png")
        #expect(downloads[0].contentType == "image/png")
    }

    @Test
    func signedOutSessionShortCircuitsRequestsWithoutHittingTheNetwork() async {
        // While signed out the client must refuse every request locally — no network round trip — so the
        // always-on loops stop spraying guaranteed-401 calls. It returns the same typed error a real 401
        // would, instantly. A local gate instance keeps this independent of the parallel test run.
        let gate = BackendSessionGate()
        gate.update(isAuthenticated: false)

        let httpClient = FixtureHTTPClient(data: Data("{}".utf8), statusCode: 200)
        let client = DonkeyBackendInferenceClient(
            configuration: configuration(),
            httpClient: httpClient,
            sessionGate: gate
        )

        await #expect(throws: DonkeyBackendInferenceClientError.authenticationRequired) {
            _ = try await client.createResponse(
                RemoteInferenceResponseCreateRequest(model: "router/large", input: .string("hi"))
            )
        }
        // Never reached the transport.
        #expect(httpClient.requests.isEmpty)
    }

    @Test
    func devAuthBypassIgnoresTheSignedOutGate() async throws {
        // The dev-auth bypass is always treated as authenticated, so the gate never blocks it.
        let gate = BackendSessionGate()
        gate.update(isAuthenticated: false)

        let httpClient = FixtureHTTPClient(data: Data("{}".utf8), statusCode: 200)
        let client = DonkeyBackendInferenceClient(
            configuration: DonkeyBackendInferenceConfiguration(
                baseURL: URL(string: "https://donkey.example")!,
                clientID: "client-1",
                devAuthBypass: true
            ),
            httpClient: httpClient,
            sessionGate: gate
        )

        _ = try await client.createResponse(
            RemoteInferenceResponseCreateRequest(model: "router/large", input: .string("hi"))
        )
        #expect(httpClient.requests.count == 1)
    }

    private func configuration() -> DonkeyBackendInferenceConfiguration {
        DonkeyBackendInferenceConfiguration(
            baseURL: URL(string: "https://donkey.example")!,
            clientID: "client-1"
        )
    }

    private func temporaryBundle(info: [String: String]) throws -> (bundle: Bundle, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("donkey-bundle-tests-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = directory.appendingPathComponent("DonkeyTest.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        var plist: [String: Any] = [
            "CFBundleIdentifier": "com.donkeyuse.tests.\(UUID().uuidString)",
            "CFBundlePackageType": "BNDL"
        ]
        for (key, value) in info {
            plist[key] = value
        }

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: bundleURL.appendingPathComponent("Info.plist"))

        return (
            bundle: try #require(Bundle(url: bundleURL)),
            directory: directory
        )
    }

    private func generationRecord(
        outputs: [RemoteInferenceOutputRef]
    ) -> RemoteInferenceGenerationRecord {
        RemoteInferenceGenerationRecord(
            id: "generation-1",
            kind: .music,
            status: .completed,
            provider: "provider-data",
            model: "asset-model",
            providerJobId: nil,
            providerGenerationId: nil,
            providerPollingUrl: nil,
            outputs: outputs,
            usage: nil,
            error: nil,
            metadata: [:]
        )
    }
}

private final class StreamDeltaCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [String] = []

    func append(_ delta: String) {
        lock.lock()
        deltas.append(delta)
        lock.unlock()
    }

    func values() -> [String] {
        lock.lock()
        let snapshot = deltas
        lock.unlock()
        return snapshot
    }
}

private final class FixtureHTTPClient: AIHTTPClient, @unchecked Sendable {
    var data: Data
    var statusCode: Int
    var headerFields: [String: String]
    var requests: [URLRequest] = []

    init(data: Data, statusCode: Int, headerFields: [String: String] = [:]) {
        self.data = data
        self.statusCode = statusCode
        self.headerFields = headerFields
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (
            data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headerFields
            )!
        )
    }
}

private struct StaticUIUnderstandingRunner: LocalUIUnderstandingRunning {
    var result: LocalUIUnderstandingResult

    func understand(_ request: LocalUIUnderstandingRequest) async throws -> LocalUIUnderstandingResult {
        result
    }
}

private extension URLRequest {
    var httpBodyJSONObject: [String: Any]? {
        guard let httpBody,
              let object = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any]
        else {
            return nil
        }

        return object
    }
}
