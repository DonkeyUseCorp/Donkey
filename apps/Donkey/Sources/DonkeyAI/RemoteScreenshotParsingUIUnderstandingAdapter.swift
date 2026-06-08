import CryptoKit
import DonkeyContracts
import DonkeyRuntime
import Foundation

public actor RemoteScreenshotParsingThrottle {
    private struct Entry {
        var fingerprint: String
        var timestamp: Date
    }

    private var entries: [String: Entry] = [:]
    private let minimumInterval: TimeInterval

    public init(minimumInterval: TimeInterval = 8) {
        self.minimumInterval = max(0, minimumInterval)
    }

    public func shouldAllow(
        targetID: String,
        imageFingerprint: String,
        now: Date = Date()
    ) -> Bool {
        if let existing = entries[targetID] {
            if existing.fingerprint == imageFingerprint {
                return false
            }
            if now.timeIntervalSince(existing.timestamp) < minimumInterval {
                return false
            }
        }

        entries[targetID] = Entry(fingerprint: imageFingerprint, timestamp: now)
        return true
    }
}

public struct RemoteScreenshotParsingLocalUIUnderstandingAdapter: LocalUIUnderstandingRunning {
    public var client: DonkeyBackendInferenceClient

    public init(client: DonkeyBackendInferenceClient) {
        self.client = client
    }

    public func understand(_ request: LocalUIUnderstandingRequest) async throws -> LocalUIUnderstandingResult {
        try await client.parseScreenshot(request)
    }

    public func understandStream(
        _ request: LocalUIUnderstandingRequest
    ) -> AsyncThrowingStream<LocalUIUnderstandingStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let final = try await client.parseScreenshotStream(request) { partial in
                        continuation.yield(.partial(partial))
                    }
                    continuation.yield(.final(final))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func understand(
        _ request: LocalUIUnderstandingRequest,
        imageData: Data
    ) async throws -> LocalUIUnderstandingResult {
        try await client.parseScreenshot(request, imageData: imageData)
    }

    func understandStream(
        _ request: LocalUIUnderstandingRequest,
        imageData: Data
    ) -> AsyncThrowingStream<LocalUIUnderstandingStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let final = try await client.parseScreenshotStream(
                        request,
                        imageData: imageData
                    ) { partial in
                        continuation.yield(.partial(partial))
                    }
                    continuation.yield(.final(final))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

public struct RemoteFallbackLocalUIUnderstandingAdapter: LocalUIUnderstandingRunning {
    public var primary: any LocalUIUnderstandingRunning
    public var remote: RemoteScreenshotParsingLocalUIUnderstandingAdapter
    public var throttle: RemoteScreenshotParsingThrottle
    public var minimumPrimaryConfidence: Double

    public init(
        primary: any LocalUIUnderstandingRunning = ProcessBackedLocalUIUnderstandingAdapter(),
        remote: RemoteScreenshotParsingLocalUIUnderstandingAdapter,
        throttle: RemoteScreenshotParsingThrottle = RemoteScreenshotParsingThrottle(),
        minimumPrimaryConfidence: Double = 0.75
    ) {
        self.primary = primary
        self.remote = remote
        self.throttle = throttle
        self.minimumPrimaryConfidence = min(max(minimumPrimaryConfidence, 0), 1)
    }

    public func understand(_ request: LocalUIUnderstandingRequest) async throws -> LocalUIUnderstandingResult {
        let primaryResult = try? await primary.understand(request)
        if let primaryResult, primaryEvidenceIsGood(primaryResult) {
            return primaryResult
        }

        guard let imageFileURL = request.imageFileURL else {
            if let primaryResult {
                return primaryResult
            }
            throw LocalUIUnderstandingError.unavailable("missingImagePath")
        }

        let imageData: Data
        do {
            imageData = try Data(contentsOf: imageFileURL)
        } catch {
            if let primaryResult {
                return primaryResult
            }
            throw LocalUIUnderstandingError.unavailable("missingImageData")
        }

        let fingerprint = Self.fingerprint(for: imageData)
        let allowed = await throttle.shouldAllow(
            targetID: request.targetID,
            imageFingerprint: fingerprint
        )
        guard allowed else {
            if let primaryResult {
                return annotatedPrimaryResult(primaryResult, status: "throttled")
            }
            throw LocalUIUnderstandingError.unavailable("remoteScreenshotParsingThrottled")
        }

        do {
            var remoteResult = try await remote.understand(request, imageData: imageData)
            remoteResult.metadata = remoteResult.metadata.merging([
                "remoteScreenshotParsing.status": "used",
                "remoteScreenshotParsing.fingerprint": fingerprint
            ]) { current, _ in current }
            return bestResult(primary: primaryResult, remote: remoteResult)
        } catch {
            if let primaryResult {
                return annotatedPrimaryResult(primaryResult, status: "failed")
            }
            throw error
        }
    }

    public func understandStream(
        _ request: LocalUIUnderstandingRequest
    ) -> AsyncThrowingStream<LocalUIUnderstandingStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await streamUnderstanding(request, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func streamUnderstanding(
        _ request: LocalUIUnderstandingRequest,
        continuation: AsyncThrowingStream<LocalUIUnderstandingStreamEvent, Error>.Continuation
    ) async throws {
        let primaryResult = try? await primary.understand(request)
        if let primaryResult, primaryEvidenceIsGood(primaryResult) {
            continuation.yield(.final(primaryResult))
            continuation.finish()
            return
        }

        guard let imageFileURL = request.imageFileURL else {
            if let primaryResult {
                continuation.yield(.final(primaryResult))
                continuation.finish()
                return
            }
            throw LocalUIUnderstandingError.unavailable("missingImagePath")
        }

        let imageData: Data
        do {
            imageData = try Data(contentsOf: imageFileURL)
        } catch {
            if let primaryResult {
                continuation.yield(.final(primaryResult))
                continuation.finish()
                return
            }
            throw LocalUIUnderstandingError.unavailable("missingImageData")
        }

        let fingerprint = Self.fingerprint(for: imageData)
        let allowed = await throttle.shouldAllow(
            targetID: request.targetID,
            imageFingerprint: fingerprint
        )
        guard allowed else {
            if let primaryResult {
                continuation.yield(.final(annotatedPrimaryResult(primaryResult, status: "throttled")))
                continuation.finish()
                return
            }
            throw LocalUIUnderstandingError.unavailable("remoteScreenshotParsingThrottled")
        }

        do {
            for try await event in remote.understandStream(request, imageData: imageData) {
                switch event {
                case .partial(var partial):
                    partial.metadata = partial.metadata.merging([
                        "remoteScreenshotParsing.status": "streaming",
                        "remoteScreenshotParsing.fingerprint": fingerprint
                    ]) { current, _ in current }
                    continuation.yield(.partial(bestResult(primary: primaryResult, remote: partial)))
                case .final(var final):
                    final.metadata = final.metadata.merging([
                        "remoteScreenshotParsing.status": "used",
                        "remoteScreenshotParsing.fingerprint": fingerprint
                    ]) { current, _ in current }
                    continuation.yield(.final(bestResult(primary: primaryResult, remote: final)))
                }
            }
            continuation.finish()
        } catch {
            if let primaryResult {
                continuation.yield(.final(annotatedPrimaryResult(primaryResult, status: "failed")))
                continuation.finish()
                return
            }
            throw error
        }
    }

    private func primaryEvidenceIsGood(_ result: LocalUIUnderstandingResult) -> Bool {
        result.confidence >= minimumPrimaryConfidence
            && (!result.controls.isEmpty || !result.visibleText.isEmpty || !result.formFields.isEmpty)
    }

    private func bestResult(
        primary: LocalUIUnderstandingResult?,
        remote: LocalUIUnderstandingResult
    ) -> LocalUIUnderstandingResult {
        guard let primary else {
            return remote
        }

        if remote.confidence >= primary.confidence || primary.controls.isEmpty {
            return remote
        }

        return annotatedPrimaryResult(primary, status: "primaryPreferred")
    }

    private func annotatedPrimaryResult(
        _ result: LocalUIUnderstandingResult,
        status: String
    ) -> LocalUIUnderstandingResult {
        LocalUIUnderstandingResult(
            visibleText: result.visibleText,
            controls: result.controls,
            formFields: result.formFields,
            confidence: result.confidence,
            metadata: result.metadata.merging([
                "remoteScreenshotParsing.status": status
            ]) { current, _ in current }
        )
    }

    private static func fingerprint(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
