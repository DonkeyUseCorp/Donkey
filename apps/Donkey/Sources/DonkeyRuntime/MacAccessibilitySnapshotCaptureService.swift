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
    case accessibilityNotTrusted(windowID: UInt32)
    case captureTimedOut(windowID: UInt32, timeoutNanoseconds: UInt64)
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

protocol MacAccessibilitySnapshotCapturing: Sendable {
    func trustStatus() -> MacAccessibilityTrustStatus
    func captureTree(
        target: MacWindowTargetCandidate,
        limits: MacAccessibilitySnapshotLimits
    ) throws -> MacAccessibilitySnapshotTree
}

protocol MacAccessibilitySnapshotProgressCapturing: MacAccessibilitySnapshotCapturing {
    func captureTree(
        target: MacWindowTargetCandidate,
        limits: MacAccessibilitySnapshotLimits,
        onNode: (MacAccessibilitySnapshotNode) -> Void
    ) throws -> MacAccessibilitySnapshotTree
}

public final class MacAccessibilitySnapshotCaptureService {
    private let artifactStore: LocalRunArtifactStore
    private let windowResolver: MacWindowResolver
    private let capturer: any MacAccessibilitySnapshotCapturing
    private let captureTimeoutNanoseconds: UInt64

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
        capturer: any MacAccessibilitySnapshotCapturing,
        captureTimeoutNanoseconds: UInt64 = 250_000_000
    ) {
        self.artifactStore = artifactStore
        self.windowResolver = windowResolver
        self.capturer = capturer
        self.captureTimeoutNanoseconds = captureTimeoutNanoseconds
    }

    public func captureSnapshot(
        runID: String,
        selection: MacWindowSelectionRequest = MacWindowSelectionRequest(),
        limits: MacAccessibilitySnapshotLimits = .default,
        artifactID: String = "accessibility-\(UUID().uuidString)",
        recordsPermissionDeniedEvent: Bool = true
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
            guard recordsPermissionDeniedEvent else {
                throw MacAccessibilitySnapshotCaptureError.accessibilityNotTrusted(
                    windowID: target.windowID
                )
            }

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
            tree = try await captureTreeWithTimeout(target: target, limits: limits)
        } catch let error as MacAccessibilitySnapshotCaptureError {
            throw error
        } catch MacAccessibilityTimeoutError.timedOut(let timeoutNanoseconds) {
            throw MacAccessibilitySnapshotCaptureError.captureTimedOut(
                windowID: target.windowID,
                timeoutNanoseconds: timeoutNanoseconds
            )
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
        if let dialogAssessment = MacAccessibilityNativeDialogDetector().safetyAssessment(for: snapshot) {
            throw MacAccessibilitySnapshotCaptureError.unsafeTarget(
                windowID: target.windowID,
                status: dialogAssessment.status
            )
        }
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

    private func captureTreeWithTimeout(
        target: MacWindowTargetCandidate,
        limits: MacAccessibilitySnapshotLimits
    ) async throws -> MacAccessibilitySnapshotTree {
        let capturer = capturer
        let captureTimeoutNanoseconds = captureTimeoutNanoseconds
        return try await MacAccessibilityTimeout.run(
            timeoutNanoseconds: captureTimeoutNanoseconds
        ) {
            try capturer.captureTree(target: target, limits: limits)
        }
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

public struct MacAccessibilityNativeDialogDetector: Sendable {
    public init() {}

    public func safetyAssessment(
        for snapshot: MacAccessibilitySnapshot
    ) -> WindowTargetSafetyAssessment? {
        guard dialogTexts(in: snapshot.root).first != nil else {
            return nil
        }

        return WindowTargetSafetyAssessment(
            status: .blocked,
            reasons: [.systemSurface],
            summary: "Native macOS dialog detected in Accessibility tree"
        )
    }

    private func dialogTexts(in node: MacAccessibilitySnapshotNode) -> [String] {
        let ownText = [node.role, node.title, node.label, node.valueSummary]
            .compactMap { $0 }
            .joined(separator: " ")
        let descendantText = node.children.flatMap(dialogTexts(in:)).joined(separator: " ")
        let combined = [ownText, descendantText]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if isDialogRole(node.role) {
            return [combined]
        }

        return node.children.flatMap(dialogTexts(in:))
    }

    private func isDialogRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return role == "AXSheet"
            || role == "AXDialog"
            || role == "AXSystemDialog"
            || role == "AXPopover"
    }

}

final class ApplicationServicesMacAccessibilitySnapshotCapturer: MacAccessibilitySnapshotProgressCapturing {
    private let maximumTraversalNanoseconds: UInt64

    init(maximumTraversalNanoseconds: UInt64 = 200_000_000) {
        self.maximumTraversalNanoseconds = maximumTraversalNanoseconds
    }

    func trustStatus() -> MacAccessibilityTrustStatus {
        AXIsProcessTrusted() ? .trusted : .notTrusted
    }

    func captureTree(
        target: MacWindowTargetCandidate,
        limits: MacAccessibilitySnapshotLimits
    ) throws -> MacAccessibilitySnapshotTree {
        try captureTree(target: target, limits: limits, onNode: { _ in })
    }

    func captureTree(
        target: MacWindowTargetCandidate,
        limits: MacAccessibilitySnapshotLimits,
        onNode: (MacAccessibilitySnapshotNode) -> Void
    ) throws -> MacAccessibilitySnapshotTree {
        try captureTree(target: target, limits: limits, onNode: onNode, onLiveElement: { _, _ in })
    }

    /// Like `captureTree(target:limits:onNode:)`, but also hands each visited node's live `AXUIElement`
    /// (paired with its nodeID) to `onLiveElement` so a caller can retain handles for later, identity-
    /// stable action resolution. Not part of the capture protocol — only the concrete capturer and the
    /// observe path use it, so the overlay/inspection callers and their test fakes are untouched.
    func captureTree(
        target: MacWindowTargetCandidate,
        limits: MacAccessibilitySnapshotLimits,
        onNode: (MacAccessibilitySnapshotNode) -> Void,
        onLiveElement: (String, AXUIElement) -> Void
    ) throws -> MacAccessibilitySnapshotTree {
        let application = AXUIElementCreateApplication(target.processID)
        let deadlineUptime = ProcessInfo.processInfo.systemUptime
            + Double(maximumTraversalNanoseconds) / 1_000_000_000
        let rootElement = resolveWindowElement(
            for: target,
            in: application
        ) ?? application
        var remainingNodeCount = limits.maxTotalNodes
        var isTreeTruncated = false
        let rawRoot = readRawNode(
            rootElement,
            depth: 0,
            path: "ax-1",
            limits: limits,
            deadlineUptime: deadlineUptime,
            remainingNodeCount: &remainingNodeCount,
            isTreeTruncated: &isTreeTruncated,
            onNode: onNode,
            onLiveElement: onLiveElement
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
        let windows = elementArrayAttribute(
            kAXWindowsAttribute as CFString,
            from: application,
            limit: 100
        )

        // A modal popup — a separate dialog window or a modal panel — blocks its parent window, so
        // while one is open it is the surface the planner needs to see and act on (its buttons and
        // input fields). This is app-agnostic: confirmation prompts, save/print dialogs, and login
        // sheets are routine RPA surfaces, and a plain window-by-target lookup would miss them
        // because they don't match the resolved main window. (Sheets attach as children of their
        // parent window and already appear under it; this catches the separate-window case.)
        if let modal = windows.first(where: { isModalPopup($0) }) {
            return modal
        }

        if let focusedWindow = elementAttribute(
            kAXFocusedWindowAttribute as CFString,
            from: application
        ), matches(focusedWindow, target: target) {
            return focusedWindow
        }

        if let match = windows.first(where: { matches($0, target: target) }) {
            return match
        }

        return windows.first
    }

    /// A window that traps interaction until dismissed: a dialog/system-dialog subrole, or any
    /// window flagged `AXModal`. Used so the observation surfaces popups over the main window.
    private func isModalPopup(_ element: AXUIElement) -> Bool {
        let subrole = stringAttribute(kAXSubroleAttribute as CFString, from: element)
        if subrole == (kAXDialogSubrole as String) || subrole == (kAXSystemDialogSubrole as String) {
            return true
        }
        return boolAttribute(kAXModalAttribute as CFString, from: element) == true
    }

    private func readRawNode(
        _ element: AXUIElement,
        depth: Int,
        path: String,
        limits: MacAccessibilitySnapshotLimits,
        deadlineUptime: TimeInterval,
        remainingNodeCount: inout Int,
        isTreeTruncated: inout Bool,
        onNode: (MacAccessibilitySnapshotNode) -> Void,
        onLiveElement: (String, AXUIElement) -> Void
    ) -> RawMacAccessibilitySnapshotNode? {
        guard !hasTimedOut(deadlineUptime) else {
            isTreeTruncated = true
            return nil
        }

        guard remainingNodeCount > 0 else {
            isTreeTruncated = true
            return nil
        }

        remainingNodeCount -= 1
        let role = stringAttribute(kAXRoleAttribute as CFString, from: element)
        let title = stringAttribute(kAXTitleAttribute as CFString, from: element)
        let label = stringAttribute(kAXDescriptionAttribute as CFString, from: element)
        let valueSummary = valueSummaryAttribute(kAXValueAttribute as CFString, from: element)
        let frame = frame(from: element)
        let isEnabled = boolAttribute(kAXEnabledAttribute as CFString, from: element)
        let isFocused = boolAttribute(kAXFocusedAttribute as CFString, from: element)
        let actions = actionNames(from: element)

        onNode(
            MacAccessibilitySnapshotNode(
                nodeID: path,
                role: Self.summarizeText(role, limit: limits.maxTextLength),
                title: Self.summarizeText(title, limit: limits.maxTextLength),
                label: Self.summarizeText(label, limit: limits.maxTextLength),
                valueSummary: Self.summarizeText(valueSummary, limit: limits.maxTextLength),
                frame: frame,
                isEnabled: isEnabled,
                isFocused: isFocused,
                actions: actions.compactMap {
                    Self.summarizeText($0, limit: limits.maxTextLength)
                }
            )
        )
        onLiveElement(path, element)

        let children = childNodes(
            for: element,
            depth: depth,
            path: path,
            limits: limits,
            deadlineUptime: deadlineUptime,
            remainingNodeCount: &remainingNodeCount,
            isTreeTruncated: &isTreeTruncated,
            onNode: onNode,
            onLiveElement: onLiveElement
        )

        return RawMacAccessibilitySnapshotNode(
            role: role,
            title: title,
            label: label,
            valueSummary: valueSummary,
            frame: frame,
            isEnabled: isEnabled,
            isFocused: isFocused,
            actions: actions,
            children: children
        )
    }

    private func childNodes(
        for element: AXUIElement,
        depth: Int,
        path: String,
        limits: MacAccessibilitySnapshotLimits,
        deadlineUptime: TimeInterval,
        remainingNodeCount: inout Int,
        isTreeTruncated: inout Bool,
        onNode: (MacAccessibilitySnapshotNode) -> Void,
        onLiveElement: (String, AXUIElement) -> Void
    ) -> [RawMacAccessibilitySnapshotNode] {
        guard !hasTimedOut(deadlineUptime) else {
            isTreeTruncated = true
            return []
        }

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
            .enumerated()
            .compactMap { index, child in
                readRawNode(
                    child,
                    depth: depth + 1,
                    path: "\(path).\(index + 1)",
                    limits: limits,
                    deadlineUptime: deadlineUptime,
                    remainingNodeCount: &remainingNodeCount,
                    isTreeTruncated: &isTreeTruncated,
                    onNode: onNode,
                    onLiveElement: onLiveElement
                )
            }
    }

    private static func summarizeText(
        _ value: String?,
        limit: Int
    ) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }

        guard trimmed.count <= limit else {
            return "[redacted length=\(trimmed.count)]"
        }

        return trimmed
    }

    private func hasTimedOut(_ deadlineUptime: TimeInterval) -> Bool {
        ProcessInfo.processInfo.systemUptime >= deadlineUptime
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

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
