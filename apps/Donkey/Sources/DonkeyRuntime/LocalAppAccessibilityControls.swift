@preconcurrency import ApplicationServices
import AppKit
import DonkeyContracts
import Foundation

public enum LocalAppControlKind: String, Codable, Equatable, Sendable {
    case button
    case textField
    case searchField
    case checkbox
    case menuItem
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
        let normalizedID = LocalAppTaskIntentParser.normalizedPhrase(controlID)
        return controls.first { control in
            let normalizedLabel = LocalAppTaskIntentParser.normalizedPhrase(control.label)
            let normalizedMetadataID = control.metadata["controlID"]
                .map(LocalAppTaskIntentParser.normalizedPhrase)
            let kindMatches = acceptedKinds.isEmpty || acceptedKinds.contains(control.kind)
            return kindMatches
                && (
                    normalizedLabel == normalizedID
                        || normalizedMetadataID == normalizedID
                        || LocalAppTaskIntentParser.normalizedPhrase(control.id) == normalizedID
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
                "controlCount": String(controls.count),
                "treeTruncated": String(snapshot.isTreeTruncated)
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

        let kind = controlKind(for: node)
        if kind != .unknown, let label {
            controls.append(
                LocalAppDiscoveredControl(
                    id: node.nodeID,
                    kind: kind,
                    role: node.role,
                    label: label,
                    valueSummary: node.valueSummary,
                    frame: node.frame,
                    isEnabled: node.isEnabled ?? true,
                    actions: node.actions,
                    metadata: [
                        "accessibility.nodeID": node.nodeID,
                        "controlID": inferredControlID(label: label, kind: kind)
                    ]
                )
            )
        }

        for child in node.children {
            visit(child, controls: &controls, visibleText: &visibleText)
        }
    }

    private func bestLabel(for node: MacAccessibilitySnapshotNode) -> String? {
        [node.label, node.title, node.valueSummary, node.role]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private func controlKind(for node: MacAccessibilitySnapshotNode) -> LocalAppControlKind {
        let role = node.role ?? ""
        if role == "AXButton" { return .button }
        if role == "AXCheckBox" { return .checkbox }
        if role == "AXMenuItem" { return .menuItem }
        if role == "AXSearchField" { return .searchField }
        if role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" {
            return .textField
        }
        if role == "AXGroup" { return .group }
        if node.actions.contains("AXPress") { return .button }
        return .unknown
    }

    private func inferredControlID(label: String, kind: LocalAppControlKind) -> String {
        let normalized = LocalAppTaskIntentParser.normalizedPhrase(label)
        if kind == .searchField {
            return "search"
        }
        return normalized.replacingOccurrences(of: " ", with: "-")
    }
}

public struct LocalAppAccessibilityActionPlanner: Sendable {
    public init() {}

    public func commands(
        for intent: TaskIntent,
        definition: LocalAppTaskDefinition,
        index: LocalAppAccessibilityControlIndex,
        issuedAt: RunTraceTimestamp
    ) -> [ActionEngineCommand] {
        let adapter = LocalAppTaskAdapter(definition: definition)
        return definition.workflowSteps.compactMap { step in
            switch step.role {
            case .focusControl:
                guard let controlID = step.metadata["controlID"],
                      let control = index.firstControl(
                        matching: controlID,
                        acceptedKinds: [.searchField, .textField, .button]
                      )
                else {
                    return nil
                }
                return command(
                    id: "\(intent.intentID)-ax-\(step.id)",
                    traceID: intent.metadata["traceID"] ?? intent.intentID,
                    targetID: adapter.targetID,
                    issuedAt: issuedAt,
                    kind: .tap,
                    control: control,
                    definition: definition,
                    step: step,
                    metadata: [
                        "accessibility.action": "AXPress",
                        "accessibility.nodeID": control.id,
                        "inputStrategy": "accessibility"
                    ]
                )
            case .enterText:
                let entityName = step.metadata["entityName"] ?? definition.verificationEntityName
                guard let entityName,
                      let text = intent.normalizedEntities[entityName],
                      let control = index.firstControl(
                        matching: step.metadata["controlID"] ?? "search",
                        acceptedKinds: [.searchField, .textField]
                      )
                else {
                    return nil
                }
                return command(
                    id: "\(intent.intentID)-ax-\(step.id)",
                    traceID: intent.metadata["traceID"] ?? intent.intentID,
                    targetID: adapter.targetID,
                    issuedAt: issuedAt,
                    kind: .key,
                    control: control,
                    definition: definition,
                    step: step,
                    metadata: [
                        "accessibility.action": "AXSetValue",
                        "accessibility.nodeID": control.id,
                        "accessibility.value": text,
                        "inputStrategy": "accessibility",
                        "text": text
                    ]
                )
            case .submit:
                return nil
            case .parseIntent, .launchOrFocusApp, .observeApp, .verifyResult, .custom:
                return nil
            }
        }
    }

    public func fillCommands(
        approval: DocumentFormFillApproval,
        definition: LocalAppTaskDefinition,
        issuedAt: RunTraceTimestamp
    ) -> [ActionEngineCommand] {
        let adapter = LocalAppTaskAdapter(definition: definition)
        return approval.approvedProposals.enumerated().map { index, proposal in
            ActionEngineCommand(
                id: "\(approval.id)-fill-\(index)",
                traceID: approval.traceID,
                targetID: adapter.targetID,
                kind: .key,
                issuedAt: Self.timestamp(issuedAt, advancedByMilliseconds: Double(index) * 60),
                key: proposal.proposedValue,
                metadata: [
                    "taskType": definition.taskType,
                    "workflowStepRole": "enterText",
                    "inputStrategy": "accessibility",
                    "accessibility.action": "AXSetValue",
                    "accessibility.nodeID": proposal.fieldID,
                    "accessibility.value": proposal.proposedValue,
                    "documentFormFill.approvalID": approval.id,
                    "documentFormFill.sourceKey": proposal.sourceKey,
                    "documentFormFill.fieldLabel": proposal.fieldLabel
                ]
            )
        }
    }

    private func command(
        id: String,
        traceID: String,
        targetID: String,
        issuedAt: RunTraceTimestamp,
        kind: ActionEngineCommandKind,
        control: LocalAppDiscoveredControl,
        definition: LocalAppTaskDefinition,
        step: LocalAppTaskWorkflowStepDefinition,
        metadata: [String: String]
    ) -> ActionEngineCommand {
        ActionEngineCommand(
            id: id,
            traceID: traceID,
            targetID: targetID,
            kind: kind,
            issuedAt: issuedAt,
            targetBounds: control.frame.map {
                HotLoopRect(
                    x: $0.x,
                    y: $0.y,
                    width: $0.width,
                    height: $0.height,
                    space: .screen
                )
            },
            metadata: step.metadata.merging(metadata) { current, _ in current }
                .merging([
                    "taskType": definition.taskType,
                    "bundleIdentifier": definition.targetApp.bundleIdentifier ?? "",
                    "workflowStepID": step.id,
                    "workflowStepRole": step.role.rawValue
                ]) { current, _ in current }
        )
    }

    private static func timestamp(
        _ timestamp: RunTraceTimestamp,
        advancedByMilliseconds milliseconds: Double
    ) -> RunTraceTimestamp {
        RunTraceTimestamp(
            wallClock: timestamp.wallClock.addingTimeInterval(milliseconds / 1_000),
            monotonicUptimeNanoseconds: timestamp.monotonicUptimeNanoseconds + UInt64(milliseconds * 1_000_000)
        )
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

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let element = resolveElement(nodeID: nodeID, application: appElement) else {
            return result(command, executed: false, reason: "accessibilityNodeNotFound")
        }

        switch action {
        case "AXPress":
            let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
            return result(command, executed: error == .success, reason: String(describing: error))
        case "AXSetValue":
            guard let value = command.metadata["accessibility.value"] ?? command.key else {
                return result(command, executed: false, reason: "missingAccessibilityValue")
            }
            let error = AXUIElementSetAttributeValue(
                element,
                kAXValueAttribute as CFString,
                value as CFTypeRef
            )
            return result(command, executed: error == .success, reason: String(describing: error))
        default:
            return result(command, executed: false, reason: "unsupportedAccessibilityAction")
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
