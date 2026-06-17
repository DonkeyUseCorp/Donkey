@preconcurrency import ApplicationServices
import AppKit
import DonkeyContracts
import Foundation

public enum LocalAppControlKind: String, Codable, Equatable, Sendable {
    case button
    case textField
    case searchField
    case checkbox
    case link
    case menuItem
    case listItem
    case group
    case unknown
}

public struct LocalAppDiscoveredControl: Codable, Equatable, Sendable {
    public var id: String
    public var kind: LocalAppControlKind
    public var role: String?
    public var label: String
    public var valueSummary: String?
    public var frame: WindowTargetBounds?
    public var isEnabled: Bool
    public var actions: [String]
    public var metadata: [String: String]

    public init(
        id: String,
        kind: LocalAppControlKind,
        role: String? = nil,
        label: String,
        valueSummary: String? = nil,
        frame: WindowTargetBounds? = nil,
        isEnabled: Bool = true,
        actions: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.role = role
        self.label = label
        self.valueSummary = valueSummary
        self.frame = frame
        self.isEnabled = isEnabled
        self.actions = actions
        self.metadata = metadata
    }
}

public struct LocalAppAccessibilityControlIndex: Codable, Equatable, Sendable {
    public var controls: [LocalAppDiscoveredControl]
    public var visibleText: String
    public var metadata: [String: String]

    public init(
        controls: [LocalAppDiscoveredControl],
        visibleText: String,
        metadata: [String: String] = [:]
    ) {
        self.controls = controls
        self.visibleText = visibleText
        self.metadata = metadata
    }

    public func firstControl(
        matching controlID: String,
        acceptedKinds: Set<LocalAppControlKind> = []
    ) -> LocalAppDiscoveredControl? {
        let normalizedID = LocalAppTextNormalizer.normalizedPhrase(controlID)
        return controls.first { control in
            let normalizedLabel = LocalAppTextNormalizer.normalizedPhrase(control.label)
            let normalizedMetadataID = control.metadata["controlID"]
                .map(LocalAppTextNormalizer.normalizedPhrase)
            let kindMatches = acceptedKinds.isEmpty || acceptedKinds.contains(control.kind)
            return kindMatches
                && (
                    normalizedLabel == normalizedID
                        || normalizedMetadataID == normalizedID
                        || LocalAppTextNormalizer.normalizedPhrase(control.id) == normalizedID
                )
        }
    }
}

public struct LocalAppAccessibilityControlDiscovery: Sendable {
    public init() {}

    public func discover(in snapshot: MacAccessibilitySnapshot) -> LocalAppAccessibilityControlIndex {
        var controls: [LocalAppDiscoveredControl] = []
        var visibleText: [String] = []
        visit(snapshot.root, controls: &controls, visibleText: &visibleText)
        return LocalAppAccessibilityControlIndex(
            controls: controls,
            visibleText: visibleText.joined(separator: " "),
            metadata: [
                "observer": "local-app-accessibility-control-discovery",
                "target.windowID": String(snapshot.target.windowID),
                "target.processID": String(snapshot.target.processID),
                "target.appName": snapshot.target.appName ?? "",
                "target.bundleIdentifier": snapshot.target.bundleIdentifier ?? "",
                "controlCount": String(controls.count),
                "treeTruncated": String(snapshot.isTreeTruncated)
            ].merging(
                LocalAppObservationGeometry.targetBoundsMetadata(snapshot.target.bounds)
            ) { current, _ in current }
        )
    }

    func visibleText(for node: MacAccessibilitySnapshotNode) -> String? {
        bestLabel(for: node)
    }

    func control(for node: MacAccessibilitySnapshotNode) -> LocalAppDiscoveredControl? {
        let kind = controlKind(for: node)
        let controlLabel = labelForControl(node, kind: kind)
        guard kind != .unknown, let controlLabel else {
            return nil
        }

        return LocalAppDiscoveredControl(
            id: node.nodeID,
            kind: kind,
            role: node.role,
            label: controlLabel,
            valueSummary: node.valueSummary,
            frame: node.frame,
            isEnabled: node.isEnabled ?? true,
            actions: node.actions,
            metadata: [
                "accessibility.nodeID": node.nodeID,
                "controlKind": kind.rawValue,
                "controlID": inferredControlID(label: controlLabel, kind: kind)
            ]
        )
    }

    public func observedFormFields(in snapshot: MacAccessibilitySnapshot) -> [LocalDocumentFormField] {
        discover(in: snapshot).controls
            .filter { [.textField, .searchField, .checkbox].contains($0.kind) }
            .map { control in
                LocalDocumentFormField(
                    id: control.id,
                    label: control.label,
                    isRequired: control.metadata["required"] == "true",
                    currentValue: control.valueSummary,
                    metadata: control.metadata.merging([
                        "controlKind": control.kind.rawValue,
                        "accessibility.role": control.role ?? "",
                        "accessibility.actions": control.actions.joined(separator: ",")
                    ]) { current, _ in current }
                )
            }
    }

    private func visit(
        _ node: MacAccessibilitySnapshotNode,
        controls: inout [LocalAppDiscoveredControl],
        visibleText: inout [String]
    ) {
        let label = bestLabel(for: node)
        if let label {
            visibleText.append(label)
        }

        if let control = control(for: node) {
            controls.append(control)
        }

        for child in node.children {
            visit(child, controls: &controls, visibleText: &visibleText)
        }
    }

    private func bestLabel(for node: MacAccessibilitySnapshotNode) -> String? {
        [node.label, node.title, node.valueSummary]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private func labelForControl(
        _ node: MacAccessibilitySnapshotNode,
        kind: LocalAppControlKind
    ) -> String? {
        if let label = bestLabel(for: node) {
            return label
        }
        if kind == .listItem || kind == .group {
            return descendantText(for: node) ?? "list item"
        }
        return nil
    }

    private func descendantText(for node: MacAccessibilitySnapshotNode) -> String? {
        var labels: [String] = []
        collectDescendantLabels(node, labels: &labels)
        let joined = labels
            .prefix(6)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private func collectDescendantLabels(
        _ node: MacAccessibilitySnapshotNode,
        labels: inout [String]
    ) {
        for child in node.children {
            if let label = bestLabel(for: child) {
                labels.append(label)
            }
            collectDescendantLabels(child, labels: &labels)
        }
    }

    private func controlKind(for node: MacAccessibilitySnapshotNode) -> LocalAppControlKind {
        let role = node.role ?? ""
        if role == "AXButton" { return .button }
        if role == "AXMenuButton" { return .button }
        if role == "AXCheckBox" { return .checkbox }
        if role == "AXRadioButton" { return .checkbox }
        if role == "AXLink" { return .link }
        if role == "AXMenuItem" { return .menuItem }
        if role == "AXRow" || role == "AXOutlineRow" { return .listItem }
        if role == "AXCell",
           node.frame?.hasPositiveArea == true,
           descendantText(for: node) != nil {
            return .listItem
        }
        if role == "AXGroup",
           node.frame?.hasPositiveArea == true,
           descendantText(for: node) != nil {
            return .group
        }
        if (role == "AXStaticText" || role == "AXImage"),
           node.frame?.hasPositiveArea == true,
           bestLabel(for: node) != nil {
            return .group
        }
        if role == "AXSearchField" { return .searchField }
        if role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" {
            return .textField
        }
        if role == "AXGroup" { return .group }
        if node.actions.contains("AXPress") { return .button }
        return .unknown
    }

    private func inferredControlID(label: String, kind: LocalAppControlKind) -> String {
        let normalized = LocalAppTextNormalizer.normalizedPhrase(label)
        if kind == .searchField {
            return "search"
        }
        return normalized.replacingOccurrences(of: " ", with: "-")
    }
}

public struct MacAccessibilityActionEngineInputBackend: ActionEngineInputBackend {
    public var actionTimeoutNanoseconds: UInt64

    public init(actionTimeoutNanoseconds: UInt64 = 200_000_000) {
        self.actionTimeoutNanoseconds = actionTimeoutNanoseconds
    }

    public func execute(_ command: ActionEngineCommand) async -> ActionEngineInputBackendResult {
        do {
            return try await MacAccessibilityTimeout.run(
                timeoutNanoseconds: actionTimeoutNanoseconds
            ) {
                executeSynchronously(command)
            }
        } catch MacAccessibilityTimeoutError.timedOut {
            return result(command, executed: false, reason: "accessibilityTimedOut")
        } catch {
            return result(command, executed: false, reason: String(describing: error))
        }
    }

    private func executeSynchronously(_ command: ActionEngineCommand) -> ActionEngineInputBackendResult {
        guard AXIsProcessTrusted() else {
            return result(command, executed: false, reason: "accessibilityNotTrusted")
        }
        guard let nodeID = command.metadata["accessibility.nodeID"],
              let action = command.metadata["accessibility.action"]
        else {
            return result(command, executed: false, reason: "missingAccessibilityTarget")
        }
        guard let bundleIdentifier = command.metadata["bundleIdentifier"],
              let application = frontmostApplication(),
              application.bundleIdentifier == bundleIdentifier
        else {
            return result(command, executed: false, reason: "targetAppNotFrontmost")
        }

        // Prefer the live handle captured at observe time: it stays bound to the same logical control
        // even if the tree reordered, so we act on what we observed rather than whatever now sits at the
        // old node index. Fall back to the positional re-walk, and surface a distinct "stale" reason when
        // neither resolves so the planner re-observes instead of retrying a vanished node.
        let element: AXUIElement
        if let cached = cachedElement(processID: application.processIdentifier, nodeID: nodeID),
           isAlive(cached) {
            element = cached
        } else if let walked = resolveElement(
            nodeID: nodeID,
            application: AXUIElementCreateApplication(application.processIdentifier)
        ) {
            element = walked
        } else {
            return result(command, executed: false, reason: "accessibilityNodeStale")
        }

        if action == "AXSetValue" {
            guard let value = command.metadata["accessibility.value"] ?? command.key else {
                return result(command, executed: false, reason: "missingAccessibilityValue")
            }
            let error = AXUIElementSetAttributeValue(
                element,
                kAXValueAttribute as CFString,
                value as CFTypeRef
            )
            return result(command, executed: error == .success, reason: String(describing: error))
        }

        guard let performAction = Self.performAction(for: action) else {
            return result(command, executed: false, reason: "unsupportedAccessibilityAction")
        }
        // Re-check at dispatch that the live element still advertises this action and is enabled; the
        // observe-time action list can go stale. On a miss the caller falls back to a coordinate click.
        guard advertises(element, action: action), isEnabled(element) else {
            return result(command, executed: false, reason: "accessibilityActionNotAdvertised")
        }
        let error = AXUIElementPerformAction(element, performAction)
        return result(command, executed: error == .success, reason: String(describing: error))
    }

    /// The live handle observed for `nodeID`, read on the main actor (the cache is MainActor-confined and
    /// `AXUIElement` is not Sendable). Mirrors `frontmostApplication()`'s main-thread hop.
    private func cachedElement(processID: pid_t, nodeID: String) -> AXUIElement? {
        let lookup = {
            MainActor.assumeIsolated {
                MacAccessibilityElementHandleCache.shared.handle(processID: processID, nodeID: nodeID)
            }
        }
        return Thread.isMainThread ? lookup() : DispatchQueue.main.sync(execute: lookup)
    }

    /// Whether the AX handle still points at a live control — a cheap attribute read fails once the
    /// element is destroyed, which is exactly when a cached handle must be discarded.
    private func isAlive(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success
    }

    private func advertises(_ element: AXUIElement, action: String) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let actions = names as? [String]
        else {
            return false
        }
        return actions.contains(action)
    }

    /// Treats a missing `AXEnabled` attribute as enabled: many container/menu elements never expose it,
    /// and only an explicit `false` should block the action.
    private func isEnabled(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value) == .success else {
            return true
        }
        return (value as? Bool) ?? true
    }

    /// Maps a supported perform-style action name to its AX constant. `AXSetValue` is handled separately
    /// because it sets an attribute rather than performing an action.
    private static func performAction(for action: String) -> CFString? {
        switch action {
        case "AXPress": return kAXPressAction as CFString
        case "AXShowMenu": return kAXShowMenuAction as CFString
        // No SDK constant ships for the open action, but apps (e.g. Finder) advertise the "AXOpen"
        // string; AX matches on the name, so the literal is exactly what a constant would resolve to.
        case "AXOpen": return "AXOpen" as CFString
        case "AXPick": return kAXPickAction as CFString
        case "AXConfirm": return kAXConfirmAction as CFString
        case "AXCancel": return kAXCancelAction as CFString
        default: return nil
        }
    }

    private func frontmostApplication() -> FrontmostAccessibilityApplication? {
        Thread.isMainThread
            ? FrontmostAccessibilityApplication.current()
            : DispatchQueue.main.sync { FrontmostAccessibilityApplication.current() }
    }

    private func resolveElement(nodeID: String, application: AXUIElement) -> AXUIElement? {
        let indexes = nodeID
            .split(separator: ".")
            .dropFirst()
            .compactMap { Int($0).map { $0 - 1 } }
        let roots = windows(from: application)
        let root = roots.first ?? application
        return indexes.reduce(Optional(root)) { element, index in
            guard let element else { return nil }
            let children = children(from: element)
            guard children.indices.contains(index) else { return nil }
            return children[index]
        }
    }

    private func windows(from appElement: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private func children(from element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private func result(
        _ command: ActionEngineCommand,
        executed: Bool,
        reason: String
    ) -> ActionEngineInputBackendResult {
        ActionEngineInputBackendResult(
            executed: executed,
            completedAt: command.issuedAt,
            metadata: [
                "liveInputBackend": "mac-accessibility",
                "inputMode": "accessibilityElement",
                "elementClick": String(command.kind == .tap),
                "controlID": command.metadata["controlID"] ?? "",
                "accessibility.result": reason
            ]
        )
    }
}

private struct FrontmostAccessibilityApplication: Sendable {
    var processIdentifier: pid_t
    var bundleIdentifier: String?

    static func current() -> FrontmostAccessibilityApplication? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        return FrontmostAccessibilityApplication(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier
        )
    }
}
