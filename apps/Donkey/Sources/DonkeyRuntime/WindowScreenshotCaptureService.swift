import CoreGraphics
import DonkeyContracts
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

public enum WindowScreenshotCaptureMethod: String, Codable, Equatable, Sendable {
    case screenCaptureKitDesktopIndependentWindow
    case boundsCrop
}

public enum WindowScreenshotOverlapStatus: String, Codable, Equatable, Sendable {
    case notRequired
    case clear
    case occluded
}

public enum WindowScreenshotCaptureError: Error, Equatable, Sendable {
    case missingPreparedRun(runID: String)
    case unsafeTarget(
        windowID: UInt32,
        status: WindowTargetSafetyStatus
    )
    case occludedTarget(
        windowID: UInt32,
        occludingWindowID: UInt32
    )
    case screenRecordingPermissionDenied
    case targetWindowUnavailable(windowID: UInt32)
    case captureFailed(windowID: UInt32, reason: String)
    case pngEncodingFailed(windowID: UInt32)
}

public struct WindowScreenshotCaptureResult: Equatable, Sendable {
    public var target: MacWindowTargetCandidate
    public var artifact: RunArtifactRecord
    public var imageWidth: Int
    public var imageHeight: Int
    public var captureMethod: WindowScreenshotCaptureMethod
    public var overlapStatus: WindowScreenshotOverlapStatus

    public init(
        target: MacWindowTargetCandidate,
        artifact: RunArtifactRecord,
        imageWidth: Int,
        imageHeight: Int,
        captureMethod: WindowScreenshotCaptureMethod,
        overlapStatus: WindowScreenshotOverlapStatus
    ) {
        self.target = target
        self.artifact = artifact
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.captureMethod = captureMethod
        self.overlapStatus = overlapStatus
    }
}

public struct CapturedWindowScreenshot: Equatable, Sendable {
    public var pngData: Data
    public var imageWidth: Int
    public var imageHeight: Int
    public var captureMethod: WindowScreenshotCaptureMethod
    public var coordinateSpace: String

    public init(
        pngData: Data,
        imageWidth: Int,
        imageHeight: Int,
        captureMethod: WindowScreenshotCaptureMethod,
        coordinateSpace: String
    ) {
        self.pngData = pngData
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.captureMethod = captureMethod
        self.coordinateSpace = coordinateSpace
    }
}

protocol WindowScreenshotCapturing {
    var captureMethod: WindowScreenshotCaptureMethod { get }
    var requiresOverlapFreeTarget: Bool { get }

    func capture(
        target: MacWindowTargetCandidate
    ) async throws -> CapturedWindowScreenshot
}

public protocol ScreenRecordingPermissionChecking: Sendable {
    func hasScreenRecordingAccess() -> Bool
}

public struct CoreGraphicsScreenRecordingPermissionChecker: ScreenRecordingPermissionChecking {
    public init() {}

    public func hasScreenRecordingAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }
}

public final class WindowScreenshotCaptureService {
    private let artifactStore: LocalRunArtifactStore
    private let windowResolver: MacWindowResolver
    private let capturer: any WindowScreenshotCapturing

    public convenience init(artifactStore: LocalRunArtifactStore) {
        self.init(
            artifactStore: artifactStore,
            windowResolver: MacWindowResolver(),
            capturer: ScreenCaptureKitWindowScreenshotCapturer()
        )
    }

    init(
        artifactStore: LocalRunArtifactStore,
        windowResolver: MacWindowResolver,
        capturer: any WindowScreenshotCapturing
    ) {
        self.artifactStore = artifactStore
        self.windowResolver = windowResolver
        self.capturer = capturer
    }

    public func captureScreenshot(
        runID: String,
        selection: MacWindowSelectionRequest = MacWindowSelectionRequest(),
        artifactID: String = "screenshot-\(UUID().uuidString)"
    ) async throws -> WindowScreenshotCaptureResult {
        let summary: RunTraceSummary
        do {
            summary = try await artifactStore.summary(runID: runID)
        } catch LocalRunArtifactStoreError.missingSummary {
            throw WindowScreenshotCaptureError.missingPreparedRun(runID: runID)
        }

        let candidates = windowResolver.enumerateCandidates()
        let target = try selectTarget(selection, from: candidates)
        guard target.safetyAssessment.status == .allowed else {
            throw WindowScreenshotCaptureError.unsafeTarget(
                windowID: target.windowID,
                status: target.safetyAssessment.status
            )
        }

        let overlapStatus = try validateOverlap(
            for: target,
            in: candidates
        )

        let screenshot: CapturedWindowScreenshot
        do {
            screenshot = try await capturer.capture(target: target)
        } catch let error as WindowScreenshotCaptureError {
            throw error
        } catch {
            throw WindowScreenshotCaptureError.captureFailed(
                windowID: target.windowID,
                reason: String(describing: error)
            )
        }

        let reservedPath = try await artifactStore.reserveArtifactPath(
            runID: runID,
            artifactID: artifactID,
            kind: .screenshot,
            fileExtension: "png"
        )
        try screenshot.pngData.write(to: reservedPath.fileURL, options: .atomic)

        let artifact = try await artifactStore.recordArtifact(
            runID: runID,
            artifactID: reservedPath.artifactID,
            kind: .screenshot,
            relativePath: reservedPath.relativePath,
            contentType: "image/png",
            byteCount: Int64(screenshot.pngData.count),
            metadata: metadata(
                runID: runID,
                traceID: summary.traceID,
                target: target,
                screenshot: screenshot,
                overlapStatus: overlapStatus
            )
        )

        return WindowScreenshotCaptureResult(
            target: target,
            artifact: artifact,
            imageWidth: screenshot.imageWidth,
            imageHeight: screenshot.imageHeight,
            captureMethod: screenshot.captureMethod,
            overlapStatus: overlapStatus
        )
    }

    private func selectTarget(
        _ selection: MacWindowSelectionRequest,
        from candidates: [MacWindowTargetCandidate]
    ) throws -> MacWindowTargetCandidate {
        guard !candidates.isEmpty else {
            throw MacWindowResolverError.noVisibleWindows
        }

        if let windowID = selection.windowID {
            guard let target = candidates.first(where: { $0.windowID == windowID }) else {
                throw MacWindowResolverError.windowNotFound(windowID: windowID)
            }

            return target
        }

        if let focused = candidates.first(where: \.isFocused) {
            return focused
        }

        if let frontmost = candidates.first(where: \.isFrontmost) {
            return frontmost
        }

        throw MacWindowResolverError.noFocusedWindow
    }

    private func validateOverlap(
        for target: MacWindowTargetCandidate,
        in candidates: [MacWindowTargetCandidate]
    ) throws -> WindowScreenshotOverlapStatus {
        guard capturer.requiresOverlapFreeTarget else {
            return .notRequired
        }

        guard let targetIndex = candidates.firstIndex(where: { $0.windowID == target.windowID }) else {
            return .clear
        }

        if let occludingWindow = candidates[..<targetIndex].first(where: { candidate in
            candidate.windowID != target.windowID
                && candidate.isVisible
                && candidate.isOnScreen
                && candidate.bounds.intersects(target.bounds)
        }) {
            throw WindowScreenshotCaptureError.occludedTarget(
                windowID: target.windowID,
                occludingWindowID: occludingWindow.windowID
            )
        }

        return .clear
    }

    private func metadata(
        runID: String,
        traceID: String,
        target: MacWindowTargetCandidate,
        screenshot: CapturedWindowScreenshot,
        overlapStatus: WindowScreenshotOverlapStatus
    ) -> [String: String] {
        var metadata = [
            "runID": runID,
            "traceID": traceID,
            "target.windowID": String(target.windowID),
            "target.processID": String(target.processID),
            "target.bounds.x": String(target.bounds.x),
            "target.bounds.y": String(target.bounds.y),
            "target.bounds.width": String(target.bounds.width),
            "target.bounds.height": String(target.bounds.height),
            "target.isVisible": String(target.isVisible),
            "target.isOnScreen": String(target.isOnScreen),
            "target.isFrontmost": String(target.isFrontmost),
            "target.isFocused": String(target.isFocused),
            "target.isIPhoneMirroring": String(target.isIPhoneMirroring),
            "target.safety.status": target.safetyAssessment.status.rawValue,
            "target.safety.reasons": target.safetyAssessment.reasons.map(\.rawValue).joined(separator: ","),
            "capture.method": screenshot.captureMethod.rawValue,
            "capture.coordinateSpace": screenshot.coordinateSpace,
            "capture.imageWidth": String(screenshot.imageWidth),
            "capture.imageHeight": String(screenshot.imageHeight),
            "capture.overlapStatus": overlapStatus.rawValue
        ]

        if let appName = target.appName {
            metadata["target.appName"] = appName
        }

        if let bundleIdentifier = target.bundleIdentifier {
            metadata["target.bundleIdentifier"] = bundleIdentifier
        }

        if let title = target.title {
            metadata["target.title"] = title
        }

        return metadata
    }
}

public final class ScreenCaptureKitWindowScreenshotCapturer: WindowScreenshotCapturing, @unchecked Sendable {
    private let permissionChecker: any ScreenRecordingPermissionChecking

    public init(permissionChecker: any ScreenRecordingPermissionChecking = CoreGraphicsScreenRecordingPermissionChecker()) {
        self.permissionChecker = permissionChecker
    }

    public var captureMethod: WindowScreenshotCaptureMethod {
        .screenCaptureKitDesktopIndependentWindow
    }

    public var requiresOverlapFreeTarget: Bool {
        false
    }

    public func capture(
        target: MacWindowTargetCandidate
    ) async throws -> CapturedWindowScreenshot {
        guard permissionChecker.hasScreenRecordingAccess() else {
            throw WindowScreenshotCaptureError.screenRecordingPermissionDenied
        }

        let content = try await SCShareableContent.current
        guard let window = content.windows.first(where: { $0.windowID == target.windowID }) else {
            throw WindowScreenshotCaptureError.targetWindowUnavailable(windowID: target.windowID)
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let contentInfo = SCShareableContent.info(for: filter)
        let scale = CGFloat(contentInfo.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(ceil(contentInfo.contentRect.width * scale)))
        configuration.height = max(1, Int(ceil(contentInfo.contentRect.height * scale)))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        let pngData = try Self.pngData(
            for: image,
            windowID: target.windowID
        )

        return CapturedWindowScreenshot(
            pngData: pngData,
            imageWidth: image.width,
            imageHeight: image.height,
            captureMethod: .screenCaptureKitDesktopIndependentWindow,
            coordinateSpace: "screenCaptureKit.contentRect.points"
        )
    }

    private static func pngData(
        for image: CGImage,
        windowID: UInt32
    ) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw WindowScreenshotCaptureError.pngEncodingFailed(windowID: windowID)
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw WindowScreenshotCaptureError.pngEncodingFailed(windowID: windowID)
        }

        return data as Data
    }
}

private extension WindowTargetBounds {
    func intersects(_ other: WindowTargetBounds) -> Bool {
        let maxX = x + width
        let maxY = y + height
        let otherMaxX = other.x + other.width
        let otherMaxY = other.y + other.height

        return x < otherMaxX
            && maxX > other.x
            && y < otherMaxY
            && maxY > other.y
    }
}
