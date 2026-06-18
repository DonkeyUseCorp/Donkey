import DonkeyContracts
import DonkeyRuntime
import Foundation

public enum DonkeyBackendInferenceClientError: Error, Equatable, Sendable {
    case missingConfiguration(String)
    case invalidResponse
    case invalidURL(String)
    case httpStatus(Int, String)
    case missingDownloadPayload(String)
    case invalidBase64(String)
}

public struct DonkeyBackendInferenceConfiguration: Equatable, Sendable {
    public var baseURL: URL
    public var clientID: String
    public var devAuthBypass: Bool
    public static let baseURLConfigurationDescription = "DONKEY_WEB_BASE_URL"

    public init(baseURL: URL, clientID: String, devAuthBypass: Bool = false) {
        self.baseURL = baseURL
        self.clientID = clientID
        self.devAuthBypass = devAuthBypass
    }

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) throws -> DonkeyBackendInferenceConfiguration {
        let baseURLString = configuredBaseURLString(
            environment: environment,
            bundle: bundle
        )
        guard let baseURLString,
              let baseURL = URL(string: baseURLString) else {
            throw DonkeyBackendInferenceClientError.missingConfiguration(
                baseURLConfigurationDescription
            )
        }

        return DonkeyBackendInferenceConfiguration(
            baseURL: baseURL,
            clientID: environment["DONKEY_CLIENT_ID"] ?? stableClientID(),
            devAuthBypass: boolEnvironmentValue(environment["DONKEY_DEV_AUTH_BYPASS"])
        )
    }

    private static func configuredBaseURLString(
        environment: [String: String],
        bundle: Bundle
    ) -> String? {
        trimmed(environment["DONKEY_WEB_BASE_URL"])
            ?? configuredBundleValue("DonkeyWebBaseURL", bundle: bundle)
    }

    private static func configuredBundleValue(
        _ key: String,
        bundle: Bundle
    ) -> String? {
        let bundleValue = bundle.object(forInfoDictionaryKey: key) as? String
        return trimmed(bundleValue)
    }

    private static func trimmed(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue?.isEmpty == false ? trimmedValue : nil
    }

    private static func boolEnvironmentValue(_ value: String?) -> Bool {
        switch trimmed(value)?.lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private static func stableClientID() -> String {
        let key = "DonkeyBackendInferenceClientID"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }

        let created = "donkey-\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(created, forKey: key)
        return created
    }
}

public struct DonkeyBackendInferenceClient: @unchecked Sendable {
    public var configuration: DonkeyBackendInferenceConfiguration
    public var httpClient: any AIHTTPClient
    public var fileManager: FileManager

    public init(
        configuration: DonkeyBackendInferenceConfiguration,
        httpClient: any AIHTTPClient = URLSessionAIHTTPClient(),
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.httpClient = httpClient
        self.fileManager = fileManager
    }

    public func listModels(
        outputModalities: [RemoteInferenceModality] = [.text]
    ) async throws -> RemoteInferenceModelList {
        var request = makeRequest(path: "/api/inference/models/")
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(
                name: "output_modalities",
                value: outputModalities.map(\.rawValue).joined(separator: ",")
            )
        ]
        if let url = components?.url {
            request.url = url
        }
        let data = try await send(request)
        return try JSONDecoder().decode(RemoteInferenceModelList.self, from: data)
    }

    /// Mint a short-lived Gemini Live (Vertex AI) connection: an OAuth access
    /// token plus the websocket endpoint and fully-qualified model path. The
    /// long-lived service-account credential stays on the backend.
    public func mintLiveConnection() async throws -> RemoteLiveConnection {
        var request = makeRequest(path: "/api/inference/live-token/")
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        let data = try await send(request)
        return try JSONDecoder().decode(RemoteLiveConnection.self, from: data)
    }

    public func completeChat(
        _ completionRequest: RemoteInferenceChatCompletionRequest
    ) async throws -> RemoteInferenceJSONValue {
        var request = makeRequest(path: "/api/inference/chat/completions/")
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(completionRequest)
        let data = try await send(request)
        return try JSONDecoder().decode(RemoteInferenceJSONValue.self, from: data)
    }

    public func createResponse(
        _ responseRequest: RemoteInferenceResponseCreateRequest
    ) async throws -> RemoteInferenceJSONValue {
        var request = makeRequest(path: "/api/inference/responses/")
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(responseRequest)
        let data = try await send(request)
        return try JSONDecoder().decode(RemoteInferenceJSONValue.self, from: data)
    }

    /// Web search via the backend's Google Search grounding (service-account credentials stay on the
    /// server; no key in the app). Returns a grounded summary and the source pages it used.
    public func searchWeb(query: String) async throws -> RemoteWebSearchResult {
        var request = makeRequest(path: "/api/web/search/")
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(["query": query])
        let data = try await send(request)
        return try JSONDecoder().decode(RemoteWebSearchResult.self, from: data)
    }

    /// Read a web page through the backend's reader (SSRF-guarded, fetch + cleanup run server-side).
    /// Returns just the main content as clean markdown — nav/ads/boilerplate stripped — plus the title.
    public func fetchWeb(url: String) async throws -> RemoteWebFetchResult {
        var request = makeRequest(path: "/api/web/fetch/")
        request.httpMethod = "POST"
        // The backend caps its own fetch at 20s; give the round trip a little headroom over that.
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(["url": url])
        let data = try await send(request)
        return try JSONDecoder().decode(RemoteWebFetchResult.self, from: data)
    }

    /// Start a Browser Use Cloud agent task through the backend. Returns immediately with our task id;
    /// poll `pollBrowserRun` for status and result. The backend owns the API key and credit charge.
    /// Run an agentic browser task and wait for its result. The backend runs it to completion
    /// (it polls Browser Use server-side) and charges credits there, so this is a single blocking
    /// call — no client-side polling. Structured output, when requested, comes back as a JSON string.
    public func runBrowserTask(
        task: String,
        startURL: String?,
        structuredOutputSchemaJSON: String?
    ) async throws -> RemoteBrowserRunStatus {
        var request = makeRequest(path: "/api/browser/run/")
        request.httpMethod = "POST"
        // The backend runs the task to completion before responding; allow a long round trip.
        request.timeoutInterval = 300
        var body: [String: Any] = ["task": task]
        if let startURL { body["startUrl"] = startURL }
        if let schema = structuredOutputSchemaJSON,
           let schemaData = schema.data(using: .utf8),
           let schemaObject = try? JSONSerialization.jsonObject(with: schemaData) {
            body["structuredOutputSchema"] = schemaObject
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await send(request)
        return try JSONDecoder().decode(RemoteBrowserRunStatus.self, from: data)
    }

    public func parseScreenshot(
        _ understandingRequest: LocalUIUnderstandingRequest,
        imageData: Data? = nil,
        contentType: String = "image/png"
    ) async throws -> LocalUIUnderstandingResult {
        let request = try makeScreenshotParseRequest(
            understandingRequest,
            imageData: imageData,
            contentType: contentType,
            stream: false
        )
        let data = try await send(request)
        return try JSONDecoder().decode(LocalUIUnderstandingResult.self, from: data)
    }

    public func parseScreenshotStream(
        _ understandingRequest: LocalUIUnderstandingRequest,
        imageData: Data? = nil,
        contentType: String = "image/png",
        onPartialResult: @escaping @MainActor @Sendable (LocalUIUnderstandingResult) -> Void
    ) async throws -> LocalUIUnderstandingResult {
        var request = try makeScreenshotParseRequest(
            understandingRequest,
            imageData: imageData,
            contentType: contentType,
            stream: true
        )
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let (lines, response) = try await httpClient.streamLines(request)
        var responseBodyLines: [String] = []
        guard (200..<300).contains(response.statusCode) else {
            for try await line in lines {
                responseBodyLines.append(line)
            }
            throw DonkeyBackendInferenceClientError.httpStatus(
                response.statusCode,
                responseBodyLines.joined(separator: "\n")
            )
        }

        let decoder = JSONDecoder()
        var finalResult: LocalUIUnderstandingResult?
        var eventName: String?
        var eventID: String?
        var dataLines: [String] = []

        func flushEvent() async throws {
            guard !dataLines.isEmpty else {
                eventName = nil
                eventID = nil
                return
            }

            let event = RemoteInferenceServerSentEvent(
                event: eventName,
                data: dataLines.joined(separator: "\n"),
                id: eventID
            )
            eventName = nil
            eventID = nil
            dataLines.removeAll()

            switch event.event {
            case "partial":
                let result = try Self.decodeLocalUIUnderstandingResult(
                    from: event.data,
                    decoder: decoder
                )
                await onPartialResult(result)
            case "final":
                finalResult = try Self.decodeLocalUIUnderstandingResult(
                    from: event.data,
                    decoder: decoder
                )
            case "error":
                if let result = try? Self.decodeLocalUIUnderstandingResult(
                    from: event.data,
                    decoder: decoder
                ) {
                    finalResult = result
                    return
                }
                let error = (try? decoder.decode(RemoteScreenshotParseStreamError.self, from: Data(event.data.utf8)))
                if let recovered = error?.message,
                   let result = try? Self.decodeLocalUIUnderstandingResult(
                       from: recovered,
                       decoder: decoder
                   ) {
                    finalResult = result
                    return
                }
                throw DonkeyBackendInferenceClientError.httpStatus(
                    response.statusCode,
                    error?.message ?? event.data
                )
            default:
                break
            }
        }

        for try await line in lines {
            if line.isEmpty {
                try await flushEvent()
            } else if line.hasPrefix("event:") {
                eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("id:") {
                eventID = String(line.dropFirst("id:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces))
            }
        }
        try await flushEvent()

        guard let finalResult else {
            throw DonkeyBackendInferenceClientError.invalidResponse
        }
        return finalResult
    }

    /// Parse a screenshot with the hosted vision endpoint (RunPod OmniParser V2).
    /// Single-shot only — the route does not stream. Returns elements with pixel
    /// boxes relative to the uploaded image, origin top-left.
    public func parseScreenshotVision(
        imageData: Data,
        options: RemoteVisionParseOptions? = nil
    ) async throws -> RemoteVisionParseResponse {
        var request = makeRequest(path: "/api/vision")
        request.httpMethod = "POST"
        // OmniParser on a cold/slow RunPod worker can take ~60s, which sits right
        // on URLSession's default 60s request timeout. Give the parse room to land
        // so a slow-but-successful response isn't killed at the boundary.
        request.timeoutInterval = 180
        request.httpBody = try JSONEncoder().encode(
            RemoteVisionParseRequest(
                image: imageData.base64EncodedString(),
                returnElements: true,
                options: options
            )
        )
        let data = try await send(request)
        return try JSONDecoder().decode(RemoteVisionParseResponse.self, from: data)
    }

    private static func decodeLocalUIUnderstandingResult(
        from text: String,
        decoder: JSONDecoder
    ) throws -> LocalUIUnderstandingResult {
        var lastError: Error?
        for candidate in jsonObjectCandidates(in: text).reversed() {
            do {
                return try decoder.decode(LocalUIUnderstandingResult.self, from: Data(candidate.utf8))
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }
        throw DonkeyBackendInferenceClientError.invalidResponse
    }

    public func makeStreamingChatRequest(
        _ completionRequest: RemoteInferenceChatCompletionRequest
    ) throws -> URLRequest {
        var request = makeRequest(path: "/api/inference/chat/completions/")
        request.httpMethod = "POST"
        var body = completionRequest
        body.stream = true
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    public func createAssetGeneration(
        _ assetRequest: RemoteInferenceAssetGenerationRequest
    ) async throws -> RemoteInferenceGenerationRecord {
        var request = makeRequest(path: "/api/inference/assets/")
        request.httpMethod = "POST"
        var body = assetRequest
        if body.generationId == nil {
            body.generationId = "generation-\(UUID().uuidString.lowercased())"
        }
        request.httpBody = try JSONEncoder().encode(body)
        let data = try await send(request)
        return try JSONDecoder().decode(RemoteInferenceGenerationRecord.self, from: data)
    }

    public func refreshAssetGeneration(
        _ record: RemoteInferenceGenerationRecord
    ) async throws -> RemoteInferenceGenerationRecord {
        var request = makeRequest(path: "/api/inference/assets/refresh/")
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(record)
        let data = try await send(request)
        return try JSONDecoder().decode(RemoteInferenceGenerationRecord.self, from: data)
    }

    public func downloadCompletedOutputs(
        for record: RemoteInferenceGenerationRecord,
        downloadsDirectory: URL? = nil
    ) async throws -> [RemoteInferenceDownloadedAsset] {
        guard record.status == .completed else {
            return []
        }

        let directory = try generationDownloadDirectory(
            generationID: record.id,
            downloadsDirectory: downloadsDirectory
        )
        var usedFilenames = Set<String>()
        var downloads: [RemoteInferenceDownloadedAsset] = []

        for output in record.outputs {
            let payload = try await downloadPayload(for: output)
            let filename = uniqueFilename(
                preferred: output.filename ?? defaultFilename(for: output),
                used: &usedFilenames
            )
            let fileURL = directory.appendingPathComponent(filename, isDirectory: false)
            try payload.data.write(to: fileURL, options: [.atomic])
            downloads.append(
                RemoteInferenceDownloadedAsset(
                    outputID: output.id,
                    fileURL: fileURL,
                    contentType: output.contentType ?? payload.contentType,
                    byteCount: Int64(payload.data.count)
                )
            )
        }

        return downloads
    }

    public static func decodeServerSentEvents(_ data: Data) -> [RemoteInferenceServerSentEvent] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .components(separatedBy: "\n\n")
            .compactMap { block -> RemoteInferenceServerSentEvent? in
                var event: String?
                var id: String?
                var dataLines: [String] = []
                for line in block.components(separatedBy: .newlines) {
                    if line.hasPrefix("event:") {
                        event = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("id:") {
                        id = String(line.dropFirst("id:".count)).trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("data:") {
                        dataLines.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces))
                    }
                }
                guard !dataLines.isEmpty else { return nil }
                return RemoteInferenceServerSentEvent(event: event, data: dataLines.joined(separator: "\n"), id: id)
            }
    }

    private static func jsonObjectCandidates(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = trimmed.isEmpty ? [] : [trimmed]
        var objectStart: String.Index?
        var depth = 0
        var isInsideString = false
        var isEscaped = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else if character == "\"" {
                isInsideString = true
            } else if character == "{" {
                if depth == 0 {
                    objectStart = index
                }
                depth += 1
            } else if character == "}", depth > 0 {
                depth -= 1
                if depth == 0, let start = objectStart {
                    let objectEnd = text.index(after: index)
                    candidates.append(String(text[start..<objectEnd]))
                    objectStart = nil
                }
            }

            index = text.index(after: index)
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    public func makeRequest(path: String) -> URLRequest {
        let url = backendURL(path: path)
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = true
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.clientID, forHTTPHeaderField: "x-donkey-client-id")
        if configuration.devAuthBypass {
            request.setValue("1", forHTTPHeaderField: "x-donkey-dev-auth-bypass")
        }
        return request
    }

    private func makeScreenshotParseRequest(
        _ understandingRequest: LocalUIUnderstandingRequest,
        imageData: Data?,
        contentType: String,
        stream: Bool
    ) throws -> URLRequest {
        guard let imageData = try imageData ?? understandingRequest.imageFileURL.map({ try Data(contentsOf: $0) }) else {
            throw DonkeyBackendInferenceClientError.missingDownloadPayload("screenshot")
        }

        var request = makeRequest(path: "/api/inference/screenshots/parse/")
        request.httpMethod = "POST"
        var metadata = understandingRequest.metadata
        metadata["screenshot.scope"] = metadata["screenshot.scope"] ?? "targetWindow"
        metadata["screenshot.desktopCaptureAllowed"] = "false"
        request.httpBody = try JSONEncoder().encode(
            RemoteScreenshotParseRequest(
                imageBase64: imageData.base64EncodedString(),
                contentType: contentType,
                pixelSize: understandingRequest.pixelSize ?? HotLoopSize(
                    width: 1,
                    height: 1,
                    space: .window
                ),
                traceID: understandingRequest.traceID,
                targetID: understandingRequest.targetID,
                cropBounds: understandingRequest.cropBounds,
                metadata: metadata,
                stream: stream
            )
        )
        return request
    }


    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await httpClient.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw DonkeyBackendInferenceClientError.httpStatus(response.statusCode, message)
        }
        return data
    }

    private func downloadPayload(for output: RemoteInferenceOutputRef) async throws -> (data: Data, contentType: String) {
        if let encoded = output.dataBase64 {
            guard let data = Data(base64Encoded: encoded) else {
                throw DonkeyBackendInferenceClientError.invalidBase64(output.id)
            }
            return (data, output.contentType ?? "application/octet-stream")
        }

        guard let urlString = output.url else {
            throw DonkeyBackendInferenceClientError.missingDownloadPayload(output.id)
        }
        if urlString.hasPrefix("data:") {
            return try dataURLPayload(urlString, outputID: output.id)
        }

        let url = try absoluteURL(for: urlString)
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = true
        let (data, response) = try await httpClient.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw DonkeyBackendInferenceClientError.httpStatus(response.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return (data, response.value(forHTTPHeaderField: "Content-Type") ?? output.contentType ?? "application/octet-stream")
    }

    private func dataURLPayload(_ value: String, outputID: String) throws -> (data: Data, contentType: String) {
        guard let comma = value.firstIndex(of: ",") else {
            throw DonkeyBackendInferenceClientError.invalidBase64(outputID)
        }

        let metadata = String(value[value.startIndex..<comma])
        let payload = String(value[value.index(after: comma)...])
        let contentType = metadata
            .dropFirst("data:".count)
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init) ?? "application/octet-stream"

        if metadata.contains(";base64") {
            guard let data = Data(base64Encoded: payload) else {
                throw DonkeyBackendInferenceClientError.invalidBase64(outputID)
            }
            return (data, contentType)
        }

        guard let decoded = payload.removingPercentEncoding,
              let data = decoded.data(using: .utf8)
        else {
            throw DonkeyBackendInferenceClientError.invalidBase64(outputID)
        }
        return (data, contentType)
    }

    private func absoluteURL(for value: String) throws -> URL {
        if let url = URL(string: value), url.scheme != nil {
            return url
        }
        guard let url = URL(string: value, relativeTo: configuration.baseURL)?.absoluteURL else {
            throw DonkeyBackendInferenceClientError.invalidURL(value)
        }
        return url
    }

    private func backendURL(path: String) -> URL {
        let base = configuration.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: "\(base)\(normalizedPath)")!
    }

    private func generationDownloadDirectory(
        generationID: String,
        downloadsDirectory: URL?
    ) throws -> URL {
        let baseDirectory = downloadsDirectory
            ?? fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let directory = baseDirectory
            .appendingPathComponent("Donkey", isDirectory: true)
            .appendingPathComponent(sanitizedFilename(generationID), isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func defaultFilename(for output: RemoteInferenceOutputRef) -> String {
        let ext: String
        switch output.kind {
        case .image:
            ext = "png"
        case .video:
            ext = "mp4"
        case .audio, .music:
            ext = "mp3"
        case .text:
            ext = "txt"
        }
        return "\(output.id).\(ext)"
    }

    private func uniqueFilename(preferred: String, used: inout Set<String>) -> String {
        let sanitized = sanitizedFilename(preferred)
        guard used.contains(sanitized) else {
            used.insert(sanitized)
            return sanitized
        }

        let url = URL(fileURLWithPath: sanitized)
        let base = url.deletingPathExtension().lastPathComponent
        let pathExtension = url.pathExtension
        var index = 2
        while true {
            let candidate = pathExtension.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(pathExtension)"
            if !used.contains(candidate) {
                used.insert(candidate)
                return candidate
            }
            index += 1
        }
    }

    private func sanitizedFilename(_ value: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\?%*:|\"<>")
        let cleaned = value
            .components(separatedBy: disallowed)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "asset" : String(cleaned.prefix(160))
    }
}

private struct RemoteScreenshotParseRequest: Encodable {
    var imageBase64: String
    var contentType: String
    var pixelSize: HotLoopSize
    var traceID: String
    var targetID: String
    var cropBounds: HotLoopRect?
    var metadata: [String: String]
    var stream: Bool
}

private struct RemoteScreenshotParseStreamError: Decodable {
    var error: String?
    var message: String
    var details: RemoteInferenceJSONValue?
}
