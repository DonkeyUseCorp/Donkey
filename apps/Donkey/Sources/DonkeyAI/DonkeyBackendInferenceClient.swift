import DonkeyContracts
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

    public init(baseURL: URL, clientID: String) {
        self.baseURL = baseURL
        self.clientID = clientID
    }

    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DonkeyBackendInferenceConfiguration {
        guard let baseURLString = environment["DONKEY_BACKEND_URL"],
              let baseURL = URL(string: baseURLString) else {
            throw DonkeyBackendInferenceClientError.missingConfiguration("DONKEY_BACKEND_URL")
        }

        return DonkeyBackendInferenceConfiguration(
            baseURL: baseURL,
            clientID: environment["DONKEY_CLIENT_ID"] ?? stableClientID()
        )
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

public struct DonkeyBackendInferenceClient {
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

    public func makeRequest(path: String) -> URLRequest {
        let url = backendURL(path: path)
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = true
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.clientID, forHTTPHeaderField: "x-donkey-client-id")
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
