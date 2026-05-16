@preconcurrency import ApplicationServices
import CoreGraphics
import DonkeyContracts
import Foundation

public enum MacAccessibilitySnapshotCaptureError: Error, Equatable, Sendable {
    case missingPreparedRun(runID: String)
    case unsafeTarget(
        windowID: UInt32,
        status: WindowTargetSafetyStatus
    )
    case captureFailed(windowID: UInt32, reason: String)
}

public struct MacAccessibilitySnapshotCaptureResult: Equatable, Sendable {
    public var target: MacWindowTargetCandidate
    public var artifact: RunArtifactRecord
    public var snapshot: MacAccessibilitySnapshot

    public init(
        target: MacWindowTargetCandidate,
        artifact: RunArtifactRecord,
        snapshot: MacAccessibilitySnapshot
    ) {
        self.target = target
        self.artifact = artifact
        self.snapshot = snapshot
    }
}

public struct MacAccessibilityPermissionDeniedResult: Equatable, Sendable {
    public var target: MacWindowTargetCandidate
    public var eventRecord: RunTraceEventRecord

    public init(
        target: MacWindowTargetCandidate,
        eventRecord: RunTraceEventRecord
    ) {
        self.target = target
        self.eventRecord = eventRecord
    }
}

public enum MacAccessibilitySnapshotCaptureOutcome: Equatable, Sendable {
    case captured(MacAccessibilitySnapshotCaptureResult)
    case permissionDenied(MacAccessibilityPermissionDeniedResult)
}

protocol MacAccessibilitySnapshotCapturing {
    func trustStatus() -> MacAccessibilityTrustStatus
    func captureTree(
        target: MacWindowTargetCandidate,
        limits: MacAccessibilitySnapshotLimits
    ) throws -> MacAccessibilitySnapshotTree
}

public final class MacAccessibilitySnapshotCaptureService {
    private let artifactStore: LocalRunArtifactStore
    private let windowResolver: MacWindowResolver
    private let capturer: any MacAccessibilitySnapshotCapturing

    public convenience init(artifactStore: LocalRunArtifactStore) {
        self.init(
            artifactStore: artifactStore,
            windowResolver: MacWindowResolver(),
            capturer: ApplicationServicesMacAccessibilitySnapshotCapturer()
        )
    }

    init(
        artifactStore: LocalRunArtifactStore,
        windowResolver: MacWindowResolver,
        capturer: any MacAccessibilitySnapshotCapturing
    ) {
        self.artifactStore = artifactStore
        self.windowResolver = windowResolver
        self.capturer = capturer
    }

    public func captureSnapshot(
        runID: String,
        selection: MacWindowSelectionRequest = MacWindowSelectionRequest(),
        limits: MacAccessibilitySnapshotLimits = .default,
        artifactID: String = "accessibility-\(UUID().uuidString)"
    ) async throws -> MacAccessibilitySnapshotCaptureOutcome {
        let summary: RunTraceSummary
        do {
            summary = try await artifactStore.summary(runID: runID)
        } catch LocalRunArtifactStoreError.missingSummary {
            throw MacAccessibilitySnapshotCaptureError.missingPreparedRun(runID: runID)
        }

        let target = try windowResolver.selectTarget(selection)
        guard target.safetyAssessment.status == .allowed else {
            throw MacAccessibilitySnapshotCaptureError.unsafeTarget(
                windowID: target.windowID,
                status: target.safetyAssessment.status
            )
        }

        guard capturer.trustStatus() == .trusted else {
            let eventRecord = try await artifactStore.appendEvent(
                permissionDeniedEvent(
                    summary: summary,
                    target: target
                ),
                runID: runID
            )

            return .permissionDenied(
                MacAccessibilityPermissionDeniedResult(
                    target: target,
                    eventRecord: eventRecord
                )
            )
        }

        let tree: MacAccessibilitySnapshotTree
        do {
            tree = try capturer.captureTree(
                target: target,
                limits: limits
            )
        } catch let error as MacAccessibilitySnapshotCaptureError {
            throw error
        } catch {
            throw MacAccessibilitySnapshotCaptureError.captureFailed(
                windowID: target.windowID,
                reason: String(describing: error)
            )
        }

        let snapshot = MacAccessibilitySnapshot(
            target: target,
            limits: limits,
            root: tree.root,
            totalNodeCount: tree.totalNodeCount,
            isTreeTruncated: tree.isTreeTruncated
        )
        let snapshotData = try Self.encoder().encode(snapshot)
        let reservedPath = try await artifactStore.reserveArtifactPath(
            runID: runID,
            artifactID: artifactID,
            kind: .accessibilitySnapshot,
            fileExtension: "json"
        )
        try snapshotData.write(to: reservedPath.fileURL, options: .atomic)

        let artifact = try await artifactStore.recordArtifact(
            runID: runID,
            artifactID: reservedPath.artifactID,
            kind: .accessibilitySnapshot,
            relativePath: reservedPath.relativePath,
            contentType: "application/json",
            byteCount: Int64(snapshotData.count),
            metadata: metadata(
                runID: runID,
                traceID: summary.traceID,
                target: target,
                snapshot: snapshot
            )
        )

        return .captured(
            MacAccessibilitySnapshotCaptureResult(
                target: target,
                artifact: artifact,
                snapshot: snapshot
            )
        )
    }

    private func permissionDeniedEvent(
        summary: RunTraceSummary,
        target: MacWindowTargetCandidate
    ) -> RunEvent {
        let reason = "Accessibility permission is not granted"
        var metadata = targetMetadata(
            runID: summary.runID,
            traceID: summary.traceID,
            target: target
        )
        metadata["accessibility.trustStatus"] = MacAccessibilityTrustStatus.notTrusted.rawValue

        return RunEvent(
            sequence: summary.eventCount + 1,
            stream: .tool,
            summary: reason,
            payload: .tool(
                ToolRunEvent(
                    capability: .accessibility,
                    decision: .deny(reason: reason),
                    toolName: "mac-accessibility-snapshot"
                )
            ),
            traceID: summary.traceID,
            metadata: metadata
        )
    }

    private func metadata(
        runID: String,
        traceID: String,
        target: MacWindowTargetCandidate,
        snapshot: MacAccessibilitySnapshot
    ) -> [String: String] {
        var values = targetMetadata(
            runID: runID,
            traceID: traceID,
            target: target
        )
        values["accessibility.trustStatus"] = MacAccessibilityTrustStatus.trusted.rawValue
        values["accessibility.nodeCount"] = String(snapshot.totalNodeCount)
        values["accessibility.isTreeTruncated"] = String(snapshot.isTreeTruncated)
        values["accessibility.limits.maxDepth"] = String(snapshot.limits.maxDepth)
        values["accessibility.limits.maxChildrenPerNode"] = String(snapshot.limits.maxChildrenPerNode)
        values["accessibility.limits.maxTotalNodes"] = String(snapshot.limits.maxTotalNodes)
        values["accessibility.limits.maxTextLength"] = String(snapshot.limits.maxTextLength)
        return values
    }

    private func targetMetadata(
        runID: String,
        traceID: String,
        target: MacWindowTargetCandidate
    ) -> [String: String] {
        var values = [
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
            "target.safety.reasons": target.safetyAssessment.reasons.map(\.rawValue).joined(separator: ",")
        ]

        if let appName = target.appName {
            values["target.appName"] = appName
        }

        if let bundleIdentifier = target.bundleIdentifier {
            values["target.bundleIdentifier"] = bundleIdentifier
        }

        if let title = target.title {
            values["target.title"] = title
        }

        return values
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private final class ApplicationServicesMacAccessibilitySnapshotCapturer: MacAccessibilitySnapshotCapturing {
    func trustStatus() -> MacAccessibilityTrustStatus {
        AXIsProcessTrusted() ? .trusted : .notTrusted
    }

    func captureTree(
        target: MacWindowTargetCandidate,
        limits: MacAccessibilitySnapshotLimits
    ) throws -> MacAccessibilitySnapshotTree {
        let application = AXUIElementCreateApplication(target.processID)
        let rootElement = resolveWindowElement(
            for: target,
            in: application
        ) ?? application
        var remainingNodeCount = limits.maxTotalNodes
        var isTreeTruncated = false
        let rawRoot = readRawNode(
            rootElement,
            depth: 0,
            limits: limits,
            remainingNodeCount: &remainingNodeCount,
            isTreeTruncated: &isTreeTruncated
        ) ?? RawMacAccessibilitySnapshotNode(
            role: "AXUnknown",
            title: target.title,
            frame: target.bounds
        )

        var tree = MacAccessibilitySnapshotTreeBuilder.build(
            root: rawRoot,
            limits: limits
        )
        tree.isTreeTruncated = tree.isTreeTruncated || isTreeTruncated
        return tree
    }

    private func resolveWindowElement(
        for target: MacWindowTargetCandidate,
        in application: AXUIElement
    ) -> AXUIElement? {
        if let focusedWindow = elementAttribute(
            kAXFocusedWindowAttribute as CFString,
            from: application
        ), matches(focusedWindow, target: target) {
            return focusedWindow
        }

        let windows = elementArrayAttribute(
            kAXWindowsAttribute as CFString,
            from: application,
            limit: 100
        )
        if let match = windows.first(where: { matches($0, target: target) }) {
            return match
        }

        return windows.first
    }

    private func readRawNode(
        _ element: AXUIElement,
        depth: Int,
        limits: MacAccessibilitySnapshotLimits,
        remainingNodeCount: inout Int,
        isTreeTruncated: inout Bool
    ) -> RawMacAccessibilitySnapshotNode? {
        guard remainingNodeCount > 0 else {
            isTreeTruncated = true
            return nil
        }

        remainingNodeCount -= 1
        let children = childNodes(
            for: element,
            depth: depth,
            limits: limits,
            remainingNodeCount: &remainingNodeCount,
            isTreeTruncated: &isTreeTruncated
        )

        return RawMacAccessibilitySnapshotNode(
            role: stringAttribute(kAXRoleAttribute as CFString, from: element),
            title: stringAttribute(kAXTitleAttribute as CFString, from: element),
            label: stringAttribute(kAXDescriptionAttribute as CFString, from: element),
            valueSummary: valueSummaryAttribute(kAXValueAttribute as CFString, from: element),
            frame: frame(from: element),
            isEnabled: boolAttribute(kAXEnabledAttribute as CFString, from: element),
            isFocused: boolAttribute(kAXFocusedAttribute as CFString, from: element),
            actions: actionNames(from: element),
            children: children
        )
    }

    private func childNodes(
        for element: AXUIElement,
        depth: Int,
        limits: MacAccessibilitySnapshotLimits,
        remainingNodeCount: inout Int,
        isTreeTruncated: inout Bool
    ) -> [RawMacAccessibilitySnapshotNode] {
        let childCount = elementArrayCount(
            kAXChildrenAttribute as CFString,
            from: element
        )
        guard depth < limits.maxDepth else {
            if childCount > 0 {
                isTreeTruncated = true
            }
            return []
        }

        if childCount > limits.maxChildrenPerNode {
            isTreeTruncated = true
        }
        let rawChildren = elementArrayAttribute(
            kAXChildrenAttribute as CFString,
            from: element,
            limit: min(childCount, limits.maxChildrenPerNode)
        )

        return rawChildren
            .compactMap { child in
                readRawNode(
                    child,
                    depth: depth + 1,
                    limits: limits,
                    remainingNodeCount: &remainingNodeCount,
                    isTreeTruncated: &isTreeTruncated
                )
            }
    }

    private func matches(
        _ element: AXUIElement,
        target: MacWindowTargetCandidate
    ) -> Bool {
        if let targetTitle = normalized(target.title),
           normalized(stringAttribute(kAXTitleAttribute as CFString, from: element)) == targetTitle {
            return true
        }

        guard let frame = frame(from: element) else {
            return false
        }

        return abs(frame.x - target.bounds.x) <= 2
            && abs(frame.y - target.bounds.y) <= 2
            && abs(frame.width - target.bounds.width) <= 2
            && abs(frame.height - target.bounds.height) <= 2
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }

        return trimmed
    }

    private func stringAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> String? {
        guard let value = copyAttribute(attribute, from: element) else {
            return nil
        }

        if let string = value as? String {
            return string
        }

        if let number = value as? NSNumber {
            return number.stringValue
        }

        return nil
    }

    private func valueSummaryAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> String? {
        guard let value = copyAttribute(attribute, from: element) else {
            return nil
        }

        if let string = value as? String {
            return string
        }

        if let number = value as? NSNumber {
            return number.stringValue
        }

        return String(describing: value)
    }

    private func boolAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> Bool? {
        guard let value = copyAttribute(attribute, from: element) else {
            return nil
        }

        if let bool = value as? Bool {
            return bool
        }

        return (value as? NSNumber)?.boolValue
    }

    private func elementArrayCount(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> Int {
        var count: CFIndex = 0
        if AXUIElementGetAttributeValueCount(element, attribute, &count) == .success {
            return max(0, count)
        }

        guard let value = copyAttribute(attribute, from: element) else {
            return 0
        }

        return (value as? [AXUIElement])?.count ?? 0
    }

    private func elementAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> AXUIElement? {
        guard let value = copyAttribute(attribute, from: element),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private func elementArrayAttribute(
        _ attribute: CFString,
        from element: AXUIElement,
        limit: Int
    ) -> [AXUIElement] {
        guard limit > 0 else {
            return []
        }

        var values: CFArray?
        if AXUIElementCopyAttributeValues(
            element,
            attribute,
            0,
            limit,
            &values
        ) == .success,
           let elements = values as? [AXUIElement] {
            return elements
        }

        guard let value = copyAttribute(attribute, from: element) else {
            return []
        }

        return Array((value as? [AXUIElement] ?? []).prefix(limit))
    }

    private func actionNames(from element: AXUIElement) -> [String] {
        var value: CFArray?
        guard AXUIElementCopyActionNames(element, &value) == .success,
              let actions = value as? [String]
        else {
            return []
        }

        return actions
    }

    private func frame(from element: AXUIElement) -> WindowTargetBounds? {
        guard let position = pointAttribute(
            kAXPositionAttribute as CFString,
            from: element
        ),
            let size = sizeAttribute(
                kAXSizeAttribute as CFString,
                from: element
            )
        else {
            return nil
        }

        return WindowTargetBounds(
            x: position.x,
            y: position.y,
            width: size.width,
            height: size.height
        )
    }

    private func pointAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> CGPoint? {
        guard let value = copyAttribute(attribute, from: element),
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }

        return point
    }

    private func sizeAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> CGSize? {
        guard let value = copyAttribute(attribute, from: element),
              CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }

        return size
    }

    private func copyAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }

        return value
    }
}
