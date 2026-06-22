import DonkeyContracts
import Foundation

public enum LocalUIUnderstandingError: Error, Equatable, Sendable {
    case unavailable(String)
    case invalidOutput(String)
}

public struct LocalUIUnderstandingRequest: Equatable, Sendable {
    public var traceID: String
    public var targetID: String
    public var appIsRunning: Bool
    public var appIsFocused: Bool
    public var imageFileURL: URL?
    public var artifactURL: URL?
    public var cropBounds: HotLoopRect?
    public var pixelSize: HotLoopSize?
    public var metadata: [String: String]

    public init(
        traceID: String,
        targetID: String,
        appIsRunning: Bool = true,
        appIsFocused: Bool = true,
        imageFileURL: URL? = nil,
        artifactURL: URL? = nil,
        cropBounds: HotLoopRect? = nil,
        pixelSize: HotLoopSize? = nil,
        metadata: [String: String] = [:]
    ) {
        self.traceID = traceID
        self.targetID = targetID
        self.appIsRunning = appIsRunning
        self.appIsFocused = appIsFocused
        self.imageFileURL = imageFileURL
        self.artifactURL = artifactURL
        self.cropBounds = cropBounds
        self.pixelSize = pixelSize
        self.metadata = metadata
    }
}

public struct LocalUIUnderstandingControl: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var kind: LocalAppControlKind
    public var frame: HotLoopRect?
    public var confidence: Double
    public var metadata: [String: String]

    public init(
        id: String,
        label: String,
        kind: LocalAppControlKind,
        frame: HotLoopRect? = nil,
        confidence: Double,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.frame = frame
        self.confidence = min(max(confidence, 0), 1)
        self.metadata = metadata
    }
}

public struct LocalUIUnderstandingResult: Codable, Equatable, Sendable {
    public var visibleText: [String: String]
    public var controls: [LocalUIUnderstandingControl]
    public var formFields: [LocalDocumentFormField]
    public var confidence: Double
    public var metadata: [String: String]

    public init(
        visibleText: [String: String] = [:],
        controls: [LocalUIUnderstandingControl] = [],
        formFields: [LocalDocumentFormField] = [],
        confidence: Double,
        metadata: [String: String] = [:]
    ) {
        self.visibleText = visibleText
        self.controls = controls
        self.formFields = formFields
        self.confidence = min(max(confidence, 0), 1)
        self.metadata = metadata
    }

    public func observation(for request: LocalUIUnderstandingRequest) -> LocalAppTaskObservation {
        let controlsAllowDirectInput = controls.contains {
            $0.metadata["directInputActionsAllowed"] == "true"
                || $0.metadata["localUIElement.actionEligibility"] == "guardedAction"
        }
        var observationMetadata = request.metadata.merging(metadata) { _, new in new }
        observationMetadata.merge([
            "observer": "local-ui-understanding",
            "traceID": request.traceID,
            "targetID": request.targetID,
            "controlCount": String(controls.count),
            "formFieldCount": String(formFields.count)
        ]) { current, _ in current }
        observationMetadata["directInputActionsAllowed"] = String(controlsAllowDirectInput)
        if let cropBounds = request.cropBounds {
            observationMetadata.merge(
                LocalAppObservationGeometry.cropBoundsMetadata(cropBounds)
            ) { current, _ in current }
        }
        if let pixelSize = request.pixelSize {
            observationMetadata.merge(
                LocalAppObservationGeometry.pixelSizeMetadata(pixelSize)
            ) { current, _ in current }
        }
        for control in controls {
            let controlID = control.metadata["controlID"] ?? control.id
            observationMetadata.merge(
                LocalAppObservationGeometry.controlMetadata(
                    controlID: controlID,
                    frame: control.frame,
                    source: .localUIUnderstanding,
                    label: control.label,
                    kind: control.kind,
                    confidence: control.confidence,
                    extra: control.metadata
                )
            ) { current, _ in current }
        }

        let availableControls = controls.reduce(into: [String: Bool]()) { result, control in
            result[control.id] = true
            if let controlID = control.metadata["controlID"],
               !controlID.isEmpty {
                result[controlID] = true
            }
        }

        return LocalAppTaskObservation(
            appIsRunning: request.appIsRunning,
            appIsFocused: request.appIsFocused,
            availableControls: availableControls,
            visibleText: visibleText,
            confidence: confidence,
            metadata: observationMetadata
        )
    }
}

public enum LocalUIUnderstandingStreamEvent: Equatable, Sendable {
    case partial(LocalUIUnderstandingResult)
    case final(LocalUIUnderstandingResult)
}

public protocol LocalUIUnderstandingRunning: Sendable {
    func understand(_ request: LocalUIUnderstandingRequest) async throws -> LocalUIUnderstandingResult
}

public extension LocalUIUnderstandingRunning {
    func understandStream(
        _ request: LocalUIUnderstandingRequest
    ) -> AsyncThrowingStream<LocalUIUnderstandingStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try await understand(request)
                    continuation.yield(.final(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

