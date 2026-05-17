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
    public var actionEngineFactory: ActionEngineFactory
    public var permissionPolicy: ToolCallPolicy

    public init(
        catalog: LocalAppTaskCatalog = LocalAppTaskCatalog(taskDefinitions: BuiltInLocalAppTaskDefinitions.defaults),
        appController: any LocalAppTaskAppControlling = MacLocalAppTaskController(),
        actionEngineFactory: @escaping ActionEngineFactory = Self.defaultActionEngine(for:),
        permissionPolicy: ToolCallPolicy = ToolCallPolicy(deniedCapabilities: [])
    ) {
        self.catalog = catalog
        self.appController = appController
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

        let engine = actionEngineFactory(definition)
        var actionTraces: [ActionEngineCommandTrace] = []
        let commands = adapter.guardedKeyboardCommandTemplates(
            for: intent,
            issuedAt: Self.now()
        )

        for (index, actionCommand) in commands.enumerated() {
            let spacedCommand = actionCommand.withIssuedAt(Self.now(advancedByMilliseconds: Double(index) * 40))
            let trace = await engine.handle(
                spacedCommand,
                permissionPolicy: permissionPolicy
            )
            actionTraces.append(trace)

            guard trace.executed || trace.decision == .projectedDryRun else {
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
        let visibleText = accessibilityVisibleText(for: runningApplication)
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
                return (controlID, step.metadata["key"] != nil || visibleText != nil)
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
            confidence: visibleText == nil ? 0.4 : 0.75,
            metadata: [
                "observer": "mac-local-app-controller",
                "accessibilityTrusted": String(AXIsProcessTrusted())
            ]
        )
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
