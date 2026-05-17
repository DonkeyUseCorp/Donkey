@preconcurrency import ApplicationServices
import AppKit
import DonkeyContracts
import Foundation

public enum LocalAppTaskLiveRunStatus: String, Equatable, Sendable {
    case completed
    case needsUserReview
    case unsupportedCommand
    case needsConfirmation
    case appUnavailable
    case failedSafe
}

public struct LocalAppTaskLiveRunResult: Equatable, Sendable {
    public var command: String
    public var traceID: String
    public var status: LocalAppTaskLiveRunStatus
    public var resolution: LocalAppTaskCatalogResolution
    public var initialPlan: LocalAppTaskDryRunPlan?
    public var finalPlan: LocalAppTaskDryRunPlan?
    public var observation: LocalAppTaskObservation?
    public var documentFormFillPlan: DocumentFormFillPlan?
    public var actionTraces: [ActionEngineCommandTrace]
    public var metadata: [String: String]

    public init(
        command: String,
        traceID: String,
        status: LocalAppTaskLiveRunStatus,
        resolution: LocalAppTaskCatalogResolution,
        initialPlan: LocalAppTaskDryRunPlan? = nil,
        finalPlan: LocalAppTaskDryRunPlan? = nil,
        observation: LocalAppTaskObservation? = nil,
        documentFormFillPlan: DocumentFormFillPlan? = nil,
        actionTraces: [ActionEngineCommandTrace] = [],
        metadata: [String: String] = [:]
    ) {
        self.command = command
        self.traceID = traceID
        self.status = status
        self.resolution = resolution
        self.initialPlan = initialPlan
        self.finalPlan = finalPlan
        self.observation = observation
        self.documentFormFillPlan = documentFormFillPlan
        self.actionTraces = actionTraces
        self.metadata = metadata
    }
}

public protocol LocalAppTaskAppControlling: Sendable {
    @MainActor
    func launchOrFocus(
        definition: LocalAppTaskDefinition,
        availability: LocalAppAvailability
    ) async -> LocalAppTaskObservation

    @MainActor
    func observe(definition: LocalAppTaskDefinition) async -> LocalAppTaskObservation
}

public struct LocalAppTaskLiveRunner: Sendable {
    public typealias ActionEngineFactory = @Sendable (LocalAppTaskDefinition) -> ActionEngineGuardrail

    public var catalog: LocalAppTaskCatalog
    public var appController: any LocalAppTaskAppControlling
    public var contextProvider: any LocalAppTaskContextProviding
    public var documentFormFillPlanner: DocumentFormFillPlanner
    public var actionEngineFactory: ActionEngineFactory
    public var permissionPolicy: ToolCallPolicy

    public init(
        catalog: LocalAppTaskCatalog = .defaultLocal(),
        appController: any LocalAppTaskAppControlling = MacLocalAppTaskController(),
        contextProvider: any LocalAppTaskContextProviding = MacLocalAppTaskContextProvider(),
        documentFormFillPlanner: DocumentFormFillPlanner = DocumentFormFillPlanner(),
        actionEngineFactory: @escaping ActionEngineFactory = Self.defaultActionEngine(for:),
        permissionPolicy: ToolCallPolicy = ToolCallPolicy(deniedCapabilities: [])
    ) {
        self.catalog = catalog
        self.appController = appController
        self.contextProvider = contextProvider
        self.documentFormFillPlanner = documentFormFillPlanner
        self.actionEngineFactory = actionEngineFactory
        self.permissionPolicy = permissionPolicy
    }

    public func run(
        command: String,
        traceID: String = "local-app-task-\(UUID().uuidString)"
    ) async -> LocalAppTaskLiveRunResult {
        await run(
            command: command,
            traceID: traceID,
            resolution: catalog.resolve(command: command),
            metadata: ["intentParser": "deterministic"]
        )
    }

    public func run(
        command: String,
        traceID: String,
        resolution: LocalAppTaskCatalogResolution,
        metadata: [String: String] = [:]
    ) async -> LocalAppTaskLiveRunResult {
        guard resolution.status == .resolved else {
            return unresolvedResult(
                command: command,
                traceID: traceID,
                resolution: resolution,
                metadata: metadata
            )
        }

        guard let definition = resolution.definition,
              var intent = resolution.intent,
              let availability = resolution.availability
        else {
            return LocalAppTaskLiveRunResult(
                command: command,
                traceID: traceID,
                status: .failedSafe,
                resolution: resolution,
                metadata: metadata.merging(["reason": "incompleteResolution"]) { current, _ in current }
            )
        }

        intent.metadata["traceID"] = traceID
        let adapter = catalog.adapter(for: definition)
        if definition.metadata["guardedLiveDefault"] == "reviewOnly" {
            let context = await contextProvider.snapshot()
            let documentPlan = documentFormFillPlanner.plan(
                intent: intent,
                definition: definition,
                context: context
            )
            let observation = LocalAppTaskObservation(
                appIsRunning: context.focusedBundleIdentifier == definition.targetApp.bundleIdentifier,
                appIsFocused: context.focusedBundleIdentifier == definition.targetApp.bundleIdentifier,
                availableControls: [:],
                visibleText: [
                    "document": context.focusedWindowTitle
                        ?? intent.normalizedEntities["document"]
                        ?? "current document"
                ],
                confidence: context.focusedWindowTitle == nil ? 0.4 : 0.72,
                metadata: [
                    "observer": "local-app-task-context",
                    "documentFormFillPlan.status": documentPlan.status.rawValue
                ]
            )
            let initialPlan = adapter.dryRunPlan(for: intent, observation: observation)
            return LocalAppTaskLiveRunResult(
                command: command,
                traceID: traceID,
                status: .needsUserReview,
                resolution: resolution,
                initialPlan: initialPlan,
                finalPlan: initialPlan,
                observation: observation,
                documentFormFillPlan: documentPlan,
                metadata: metadata.merging([
                    "reason": "reviewOnlyTask",
                    "documentFormFillPlan.status": documentPlan.status.rawValue,
                    "documentFormFillPlan.proposalCount": String(documentPlan.proposals.count)
                ]) { current, _ in current }
            )
        }

        let launchObservation = await appController.launchOrFocus(
            definition: definition,
            availability: availability
        )
        let initialPlan = adapter.dryRunPlan(for: intent, observation: launchObservation)
        guard initialPlan.canAttemptGuardedLive else {
            return LocalAppTaskLiveRunResult(
                command: command,
                traceID: traceID,
                status: status(for: initialPlan.terminalState),
                resolution: resolution,
                initialPlan: initialPlan,
                observation: launchObservation,
                metadata: metadata.merging(["reason": "dryRunPlanBlocked"]) { current, _ in current }
            )
        }

        var actionTraces: [ActionEngineCommandTrace] = []
        let accessibilityCommands = await accessibilityCommandTemplates(
            intent: intent,
            definition: definition
        )
        if !accessibilityCommands.isEmpty {
            let accessibilityEngine = Self.accessibilityActionEngine(for: definition)
            for (index, actionCommand) in accessibilityCommands.enumerated() {
                let spacedCommand = actionCommand.withIssuedAt(Self.now(advancedByMilliseconds: Double(index) * 60))
                let trace = await accessibilityEngine.handle(
                    spacedCommand,
                    permissionPolicy: permissionPolicy
                )
                actionTraces.append(trace)
                guard trace.executed || trace.decision == .projectedDryRun else {
                    break
                }
            }
        }

        let engine = actionEngineFactory(definition)
        let accessibilityHandledStepIDs: Set<String> = Set(actionTraces.compactMap { trace -> String? in
            guard trace.executed || trace.decision == ActionEngineCommandDecision.projectedDryRun else { return nil }
            return trace.command.metadata["workflowStepID"]
        })
        let commands = adapter.guardedKeyboardCommandTemplates(
            for: intent,
            issuedAt: Self.now()
        ).filter { command in
            guard let workflowStepID = command.metadata["workflowStepID"] else { return true }
            return !accessibilityHandledStepIDs.contains(workflowStepID)
        }

        for (index, actionCommand) in commands.enumerated() {
            let spacedCommand = actionCommand.withIssuedAt(Self.now(advancedByMilliseconds: Double(index) * 40))
            let trace = await engine.handle(
                spacedCommand,
                permissionPolicy: permissionPolicy
            )
            actionTraces.append(trace)

            guard trace.executed || trace.decision == ActionEngineCommandDecision.projectedDryRun else {
                let finalObservation = await appController.observe(definition: definition)
                let finalPlan = adapter.dryRunPlan(for: intent, observation: finalObservation)
                return LocalAppTaskLiveRunResult(
                    command: command,
                    traceID: traceID,
                    status: .failedSafe,
                    resolution: resolution,
                    initialPlan: initialPlan,
                    finalPlan: finalPlan,
                    observation: finalObservation,
                    actionTraces: actionTraces,
                    metadata: metadata.merging(["reason": "actionDenied"]) { current, _ in current }
                )
            }
        }

        try? await Task.sleep(nanoseconds: 700_000_000)
        let finalObservation = await appController.observe(definition: definition)
        let finalPlan = adapter.dryRunPlan(for: intent, observation: finalObservation)
        return LocalAppTaskLiveRunResult(
            command: command,
            traceID: traceID,
            status: status(for: finalPlan.terminalState),
            resolution: resolution,
            initialPlan: initialPlan,
            finalPlan: finalPlan,
            observation: finalObservation,
            actionTraces: actionTraces,
            metadata: metadata.merging([
                "executedCommandCount": String(actionTraces.filter(\.executed).count),
                "projectedCommandCount": String(actionTraces.filter { $0.decision == .projectedDryRun }.count)
            ]) { current, _ in current }
        )
    }

    public static func defaultActionEngine(for definition: LocalAppTaskDefinition) -> ActionEngineGuardrail {
        ActionEngineGuardrail(
            configuration: ActionEngineConfiguration(liveInputEnabled: true),
            focusGuard: MacLocalAppFocusGuard(
                targetID: LocalAppTaskAdapter(definition: definition).targetID,
                bundleIdentifier: definition.targetApp.bundleIdentifier
            ),
            inputBackend: MacKeyboardActionEngineInputBackend()
        )
    }

    public static func accessibilityActionEngine(for definition: LocalAppTaskDefinition) -> ActionEngineGuardrail {
        ActionEngineGuardrail(
            configuration: ActionEngineConfiguration(liveInputEnabled: true),
            focusGuard: MacLocalAppFocusGuard(
                targetID: LocalAppTaskAdapter(definition: definition).targetID,
                bundleIdentifier: definition.targetApp.bundleIdentifier
            ),
            inputBackend: MacAccessibilityActionEngineInputBackend()
        )
    }

    private func unresolvedResult(
        command: String,
        traceID: String,
        resolution: LocalAppTaskCatalogResolution,
        metadata: [String: String]
    ) -> LocalAppTaskLiveRunResult {
        let status: LocalAppTaskLiveRunStatus
        switch resolution.status {
        case .resolved:
            status = .failedSafe
        case .needsConfirmation:
            status = .needsConfirmation
        case .unsupportedCommand:
            status = .unsupportedCommand
        case .appUnavailable:
            status = .appUnavailable
        }

        return LocalAppTaskLiveRunResult(
            command: command,
            traceID: traceID,
            status: status,
            resolution: resolution,
            metadata: metadata
        )
    }

    @MainActor
    private func accessibilityCommandTemplates(
        intent: TaskIntent,
        definition: LocalAppTaskDefinition
    ) -> [ActionEngineCommand] {
        guard AXIsProcessTrusted(),
              let target = try? MacWindowResolver().selectTarget(),
              target.bundleIdentifier == definition.targetApp.bundleIdentifier
        else {
            return []
        }

        let limits = MacAccessibilitySnapshotLimits(maxDepth: 6, maxChildrenPerNode: 80, maxTotalNodes: 500)
        guard let tree = try? ApplicationServicesMacAccessibilitySnapshotCapturer().captureTree(
            target: target,
            limits: limits
        ) else {
            return []
        }
        let snapshot = MacAccessibilitySnapshot(
            target: target,
            limits: limits,
            root: tree.root,
            totalNodeCount: tree.totalNodeCount,
            isTreeTruncated: tree.isTreeTruncated
        )
        let index = LocalAppAccessibilityControlDiscovery().discover(in: snapshot)
        return LocalAppAccessibilityActionPlanner().commands(
            for: intent,
            definition: definition,
            index: index,
            issuedAt: Self.now()
        )
    }

    private func status(for terminalState: LocalAppTaskTerminalState) -> LocalAppTaskLiveRunStatus {
        switch terminalState {
        case .completed:
            return .completed
        case .needsUserReview:
            return .needsUserReview
        case .failedSafe, .timedOut:
            return .failedSafe
        }
    }

    private static func now(advancedByMilliseconds milliseconds: Double = 0) -> RunTraceTimestamp {
        let now = ProcessInfo.processInfo.systemUptime
        return RunTraceTimestamp(
            wallClock: Date().addingTimeInterval(milliseconds / 1_000),
            monotonicUptimeNanoseconds: UInt64((now * 1_000_000_000) + (milliseconds * 1_000_000))
        )
    }
}

public struct MacLocalAppFocusGuard: ActionEngineFocusGuard {
    public var targetID: String
    public var bundleIdentifier: String?

    public init(targetID: String, bundleIdentifier: String?) {
        self.targetID = targetID
        self.bundleIdentifier = bundleIdentifier
    }

    public func targetIsSafeForInput(targetID: String) async -> Bool {
        guard targetID == self.targetID,
              let bundleIdentifier
        else {
            return false
        }

        return await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier
        }
    }
}

public struct MacLocalAppTaskController: LocalAppTaskAppControlling {
    public init() {}

    @MainActor
    public func launchOrFocus(
        definition: LocalAppTaskDefinition,
        availability: LocalAppAvailability
    ) async -> LocalAppTaskObservation {
        if let runningApplication = runningApplication(for: definition.targetApp) {
            runningApplication.activate(options: [.activateAllWindows])
        } else if let appURL = availability.appURL {
            await openApplication(at: appURL)
        }

        try? await Task.sleep(nanoseconds: 350_000_000)
        return await observe(definition: definition)
    }

    @MainActor
    public func observe(definition: LocalAppTaskDefinition) async -> LocalAppTaskObservation {
        let runningApplication = runningApplication(for: definition.targetApp)
        let isFocused = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == definition.targetApp.bundleIdentifier
        let accessibilityIndex = accessibilityControlIndex(for: definition, runningApplication: runningApplication)
        let visibleText = accessibilityIndex?.visibleText ?? accessibilityVisibleText(for: runningApplication)
        let verificationKey = definition.metadata["verificationTextKey"]
            ?? definition.verificationEntityName
            ?? "visibleText"
        let controls: [String: Bool] = Dictionary(
            uniqueKeysWithValues: definition.workflowSteps.compactMap { step in
                guard step.role == .focusControl,
                      let controlID = step.metadata["controlID"]
                else {
                    return nil
                }
                let discovered = accessibilityIndex?.firstControl(matching: controlID) != nil
                return (controlID, discovered || step.metadata["key"] != nil || visibleText != nil)
            }
        )

        var textValues: [String: String] = [:]
        if let visibleText {
            textValues["visibleText"] = visibleText
            textValues[verificationKey] = visibleText
        }

        return LocalAppTaskObservation(
            appIsRunning: runningApplication != nil,
            appIsFocused: isFocused,
            availableControls: controls,
            visibleText: textValues,
            confidence: accessibilityIndex == nil ? (visibleText == nil ? 0.4 : 0.75) : 0.86,
            metadata: [
                "observer": "mac-local-app-controller",
                "accessibilityTrusted": String(AXIsProcessTrusted()),
                "accessibilityControlDiscovery": String(accessibilityIndex != nil),
                "accessibilityControlCount": accessibilityIndex?.metadata["controlCount"] ?? "0"
            ]
        )
    }

    @MainActor
    private func accessibilityControlIndex(
        for definition: LocalAppTaskDefinition,
        runningApplication: NSRunningApplication?
    ) -> LocalAppAccessibilityControlIndex? {
        guard AXIsProcessTrusted(),
              runningApplication != nil,
              let target = try? MacWindowResolver().selectTarget(),
              target.bundleIdentifier == definition.targetApp.bundleIdentifier
        else {
            return nil
        }

        let limits = MacAccessibilitySnapshotLimits(maxDepth: 6, maxChildrenPerNode: 80, maxTotalNodes: 500)
        guard let tree = try? ApplicationServicesMacAccessibilitySnapshotCapturer().captureTree(
            target: target,
            limits: limits
        ) else {
            return nil
        }
        let snapshot = MacAccessibilitySnapshot(
            target: target,
            limits: limits,
            root: tree.root,
            totalNodeCount: tree.totalNodeCount,
            isTreeTruncated: tree.isTreeTruncated
        )
        return LocalAppAccessibilityControlDiscovery().discover(in: snapshot)
    }

    @MainActor
    private func runningApplication(for target: LocalAppTarget) -> NSRunningApplication? {
        guard let bundleIdentifier = target.bundleIdentifier else { return nil }
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first
    }

    @MainActor
    private func openApplication(at url: URL) async {
        await withCheckedContinuation { continuation in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(
                at: url,
                configuration: configuration
            ) { _, _ in
                continuation.resume()
            }
        }
    }

    @MainActor
    private func accessibilityVisibleText(for application: NSRunningApplication?) -> String? {
        guard AXIsProcessTrusted(),
              let processIdentifier = application?.processIdentifier
        else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(processIdentifier)
        let elements = windows(from: appElement)
        let roots = elements.isEmpty ? [appElement] : elements
        let values = roots.flatMap { textValues(from: $0, depth: 0, remaining: 160) }
        let joined = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    @MainActor
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

    @MainActor
    private func textValues(
        from element: AXUIElement,
        depth: Int,
        remaining: Int
    ) -> [String] {
        guard depth <= 8, remaining > 0 else { return [] }

        var values: [String] = []
        for attribute in [
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXValueAttribute,
            kAXHelpAttribute
        ] {
            if let text = stringAttribute(attribute as CFString, from: element) {
                values.append(text)
            }
        }

        let children = children(from: element)
        let nextRemaining = max(0, remaining - values.count)
        for child in children.prefix(nextRemaining) {
            values.append(contentsOf: textValues(
                from: child,
                depth: depth + 1,
                remaining: max(0, nextRemaining - values.count)
            ))
            if values.count >= remaining {
                break
            }
        }

        return values
    }

    @MainActor
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

    @MainActor
    private func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value
        else {
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
}

private extension ActionEngineCommand {
    var commandName: String {
        metadata["taskType"] ?? id
    }

    func withIssuedAt(_ issuedAt: RunTraceTimestamp) -> ActionEngineCommand {
        ActionEngineCommand(
            id: id,
            traceID: traceID,
            targetID: targetID,
            stateID: stateID,
            actionID: actionID,
            kind: kind,
            issuedAt: issuedAt,
            targetBounds: targetBounds,
            key: key,
            holdDurationMS: holdDurationMS,
            metadata: metadata
        )
    }
}
