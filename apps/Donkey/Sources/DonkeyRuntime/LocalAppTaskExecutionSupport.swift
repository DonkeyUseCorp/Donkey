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
    public var initialActionPlan: LocalAppEvidenceBackedActionPlan?
    public var finalActionPlan: LocalAppEvidenceBackedActionPlan?
    public var observation: LocalAppTaskObservation?
    public var actionTraces: [ActionEngineCommandTrace]
    public var workflowProgress: LocalAppTaskWorkflowProgress
    public var metadata: [String: String]

    public init(
        command: String,
        traceID: String,
        status: LocalAppTaskLiveRunStatus,
        resolution: LocalAppTaskCatalogResolution,
        initialActionPlan: LocalAppEvidenceBackedActionPlan? = nil,
        finalActionPlan: LocalAppEvidenceBackedActionPlan? = nil,
        observation: LocalAppTaskObservation? = nil,
        actionTraces: [ActionEngineCommandTrace] = [],
        workflowProgress: LocalAppTaskWorkflowProgress = LocalAppTaskWorkflowProgress(),
        metadata: [String: String] = [:]
    ) {
        self.command = command
        self.traceID = traceID
        self.status = status
        self.resolution = resolution
        self.initialActionPlan = initialActionPlan
        self.finalActionPlan = finalActionPlan
        self.observation = observation
        self.actionTraces = actionTraces
        self.workflowProgress = workflowProgress
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

    @MainActor
    func observe(
        definition: LocalAppTaskDefinition,
        onPartialObservation: @escaping @Sendable (LocalAppTaskObservation) async -> Void
    ) async -> LocalAppTaskObservation
}

public extension LocalAppTaskAppControlling {
    @MainActor
    func observe(
        definition: LocalAppTaskDefinition,
        onPartialObservation: @escaping @Sendable (LocalAppTaskObservation) async -> Void
    ) async -> LocalAppTaskObservation {
        await observe(definition: definition)
    }
}

public enum LocalAppTaskActionEngines {
    public static func keyboardOrAutomation(for definition: LocalAppTaskDefinition) -> ActionEngineGuardrail {
        return ActionEngineGuardrail(
            configuration: ActionEngineConfiguration(liveInputEnabled: true),
            focusGuard: MacLocalAppFocusGuard(
                targetID: LocalAppTaskAdapter(definition: definition).targetID,
                bundleIdentifier: definition.targetApp.bundleIdentifier
            ),
            inputBackend: MacKeyboardActionEngineInputBackend()
        )
    }

    public static func accessibility(for definition: LocalAppTaskDefinition) -> ActionEngineGuardrail {
        ActionEngineGuardrail(
            configuration: ActionEngineConfiguration(liveInputEnabled: true),
            focusGuard: MacLocalAppFocusGuard(
                targetID: LocalAppTaskAdapter(definition: definition).targetID,
                bundleIdentifier: definition.targetApp.bundleIdentifier
            ),
            inputBackend: MacAccessibilityActionEngineInputBackend()
        )
    }

    public static func appleScriptAutomation(for definition: LocalAppTaskDefinition) -> ActionEngineGuardrail {
        ActionEngineGuardrail(
            configuration: ActionEngineConfiguration(liveInputEnabled: true),
            focusGuard: AlwaysSafeActionEngineFocusGuard(),
            inputBackend: MacAppleScriptActionEngineInputBackend()
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
    public var uiUnderstandingRunner: any LocalUIUnderstandingRunning

    public init(
        uiUnderstandingRunner: any LocalUIUnderstandingRunning = ProcessBackedLocalUIUnderstandingAdapter()
    ) {
        self.uiUnderstandingRunner = uiUnderstandingRunner
    }

    @MainActor
    public func launchOrFocus(
        definition: LocalAppTaskDefinition,
        availability: LocalAppAvailability
    ) async -> LocalAppTaskObservation {
        if let itemURL = availability.appURL,
           let itemKind = availability.metadata["itemKind"],
           itemKind != "application" {
            let opened = await openLocalItem(at: itemURL)
            if let bundleIdentifier = definition.targetApp.bundleIdentifier {
                await waitForFrontmostApplication(
                    LocalAppTarget(
                        appName: definition.targetApp.appName,
                        bundleIdentifier: bundleIdentifier,
                        titleContains: definition.targetApp.titleContains
                    )
                )
            }
            let isFocused = definition.targetApp.bundleIdentifier == nil
                || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == definition.targetApp.bundleIdentifier
            return LocalAppTaskObservation(
                appIsRunning: opened,
                appIsFocused: opened && isFocused,
                availableControls: [:],
                visibleText: ["appName": definition.targetApp.appName],
                confidence: opened ? 0.72 : 0.2,
                metadata: [
                    "observer": "mac-local-app-controller",
                    "openedLocalItem": String(opened),
                    "localItem.kind": itemKind,
                    "localItem.path": itemURL.path,
                    "defaultApplication": availability.metadata["defaultApplication"] ?? ""
                ]
            )
        }

        if let appURL = availability.appURL {
            await openApplication(at: appURL)
        } else if let runningApplication = runningApplication(for: definition.targetApp) {
            runningApplication.activate(options: [.activateAllWindows])
        }

        await waitForFrontmostApplication(definition.targetApp)
        return await observe(definition: definition)
    }

    @MainActor
    public func observe(definition: LocalAppTaskDefinition) async -> LocalAppTaskObservation {
        await observe(definition: definition, onPartialObservation: { _ in })
    }

    @MainActor
    public func observe(
        definition: LocalAppTaskDefinition,
        onPartialObservation: @escaping @Sendable (LocalAppTaskObservation) async -> Void
    ) async -> LocalAppTaskObservation {
        let runningApplication = runningApplication(for: definition.targetApp)
        let isFocused = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == definition.targetApp.bundleIdentifier
        let verificationKey = definition.metadata["verificationTextKey"]
            ?? definition.verificationEntityName
            ?? "visibleText"
        let accessibilityIndex = accessibilityControlIndex(for: definition, runningApplication: runningApplication)
        let visibleText = accessibilityIndex?.visibleText ?? accessibilityVisibleText(for: runningApplication)
        var controls: [String: Bool] = Dictionary(
            uniqueKeysWithValues: definition.workflowSteps.compactMap { step in
                guard step.role == .focusControl,
                      let controlID = step.metadata["controlID"]
                else {
                    return nil
                }
                let discovered = accessibilityIndex?.firstControl(matching: controlID) != nil
                return (controlID, discovered)
            }
        )

        var textValues: [String: String] = [:]
        if let visibleText {
            textValues["visibleText"] = visibleText
            textValues[verificationKey] = visibleText
        }

        var accessibilityMetadata = [
            "observer": "mac-local-app-controller",
            "accessibilityTrusted": String(AXIsProcessTrusted()),
            "accessibilityControlDiscovery": String(accessibilityIndex != nil),
            "accessibilityControlCount": accessibilityIndex?.metadata["controlCount"] ?? "0"
        ].merging(accessibilityIndex?.metadata ?? [:]) { current, _ in current }
        for step in definition.workflowSteps {
            guard let controlID = step.metadata["controlID"],
                  let control = accessibilityIndex?.firstControl(matching: controlID)
            else {
                continue
            }
            let frame = control.frame.map {
                HotLoopRect(
                    x: $0.x,
                    y: $0.y,
                    width: $0.width,
                    height: $0.height,
                    space: .screen
                )
            }
            accessibilityMetadata.merge(
                LocalAppObservationGeometry.controlMetadata(
                    controlID: controlID,
                    frame: frame,
                    source: .accessibility,
                    label: control.label,
                    kind: control.kind,
                    confidence: 0.86,
                    extra: control.metadata
                )
            ) { current, _ in current }
        }

        let accessibilityObservation = LocalAppTaskObservation(
            appIsRunning: runningApplication != nil,
            appIsFocused: isFocused,
            availableControls: controls,
            visibleText: textValues,
            confidence: accessibilityIndex == nil ? (visibleText == nil ? 0.4 : 0.75) : 0.86,
            metadata: accessibilityMetadata
        )

        guard shouldIncludeScreenshotUnderstanding(
            definition: definition,
            accessibilityObservation: accessibilityObservation,
            verificationKey: verificationKey
        ) else {
            return accessibilityObservation
        }

        guard let screenshotObservation = await screenshotUnderstandingObservation(
            definition: definition,
            runningApplication: runningApplication,
            isFocused: isFocused,
            verificationKey: verificationKey,
            accessibilityObservation: accessibilityObservation,
            onPartialObservation: onPartialObservation
        ) else {
            var metadata = accessibilityObservation.metadata
            metadata["screenshotUnderstanding.status"] = "unavailable"
            return LocalAppTaskObservation(
                appIsRunning: accessibilityObservation.appIsRunning,
                appIsFocused: accessibilityObservation.appIsFocused,
                availableControls: accessibilityObservation.availableControls,
                visibleText: accessibilityObservation.visibleText,
                confidence: accessibilityObservation.confidence,
                metadata: metadata
            )
        }

        controls.merge(screenshotObservation.availableControls) { current, new in current || new }
        return LocalAppTaskObservation(
            appIsRunning: accessibilityObservation.appIsRunning || screenshotObservation.appIsRunning,
            appIsFocused: accessibilityObservation.appIsFocused || screenshotObservation.appIsFocused,
            availableControls: controls,
            visibleText: accessibilityObservation.visibleText.merging(
                screenshotObservation.visibleText
            ) { current, _ in current },
            confidence: max(accessibilityObservation.confidence, screenshotObservation.confidence),
            metadata: accessibilityObservation.metadata.merging(
                screenshotObservation.metadata
            ) { current, _ in current }
        )
    }

    private func shouldIncludeScreenshotUnderstanding(
        definition: LocalAppTaskDefinition,
        accessibilityObservation: LocalAppTaskObservation,
        verificationKey: String
    ) -> Bool {
        LocalAppTaskObservationFallbackPolicy.shouldUseScreenshotUnderstanding(
            definition: definition,
            accessibilityObservation: accessibilityObservation,
            verificationKey: verificationKey
        )
    }

    @MainActor
    private func screenshotUnderstandingObservation(
        definition: LocalAppTaskDefinition,
        runningApplication: NSRunningApplication?,
        isFocused: Bool,
        verificationKey: String,
        accessibilityObservation: LocalAppTaskObservation,
        onPartialObservation: @escaping @Sendable (LocalAppTaskObservation) async -> Void
    ) async -> LocalAppTaskObservation? {
        guard runningApplication != nil,
              let target = try? MacWindowResolver().selectTarget(),
              target.bundleIdentifier == definition.targetApp.bundleIdentifier,
              target.safetyAssessment.status == .allowed
        else {
            return nil
        }

        let screenshot: CapturedWindowScreenshot
        do {
            screenshot = try await ScreenCaptureKitWindowScreenshotCapturer().capture(target: target)
        } catch {
            return nil
        }

        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("donkey-ui-understanding-\(UUID().uuidString).png")
        do {
            try screenshot.pngData.write(to: imageURL, options: .atomic)
        } catch {
            return nil
        }
        defer {
            try? FileManager.default.removeItem(at: imageURL)
        }

        let request = LocalUIUnderstandingRequest(
            traceID: "local-ui-understanding-\(UUID().uuidString)",
            targetID: LocalAppTaskAdapter(definition: definition).targetID,
            appIsRunning: true,
            appIsFocused: isFocused,
            imageFileURL: imageURL,
            cropBounds: HotLoopRect(
                x: 0,
                y: 0,
                width: Double(screenshot.imageWidth),
                height: Double(screenshot.imageHeight),
                space: .window
            ),
            pixelSize: HotLoopSize(
                width: Double(screenshot.imageWidth),
                height: Double(screenshot.imageHeight),
                space: .window
            ),
            metadata: [
                "observer": "mac-local-app-controller",
                "observation.source": "screenshot",
                "verificationTextKey": verificationKey,
                "screenshot.scope": "targetWindow",
                "screenshot.desktopCaptureAllowed": "false",
                "target.windowID": String(target.windowID),
                "capture.method": screenshot.captureMethod.rawValue
            ].merging(LocalAppObservationGeometry.targetBoundsMetadata(target.bounds)) { current, _ in current }
        )

        do {
            var finalObservation: LocalAppTaskObservation?
            for try await event in uiUnderstandingRunner.understandStream(request) {
                switch event {
                case .partial(let result):
                    await onPartialObservation(
                        Self.fusedObservation(
                            accessibilityObservation: accessibilityObservation,
                            screenshotObservation: result.observation(for: request)
                        )
                    )
                case .final(let result):
                    finalObservation = result.observation(for: request)
                }
            }
            return finalObservation
        } catch {
            return nil
        }
    }

    private static func fusedObservation(
        accessibilityObservation: LocalAppTaskObservation,
        screenshotObservation: LocalAppTaskObservation
    ) -> LocalAppTaskObservation {
        let controls = accessibilityObservation.availableControls.merging(
            screenshotObservation.availableControls
        ) { current, new in current || new }
        return LocalAppTaskObservation(
            appIsRunning: accessibilityObservation.appIsRunning || screenshotObservation.appIsRunning,
            appIsFocused: accessibilityObservation.appIsFocused || screenshotObservation.appIsFocused,
            availableControls: controls,
            visibleText: accessibilityObservation.visibleText.merging(
                screenshotObservation.visibleText
            ) { current, _ in current },
            confidence: max(accessibilityObservation.confidence, screenshotObservation.confidence),
            metadata: accessibilityObservation.metadata.merging(
                screenshotObservation.metadata
            ) { current, _ in current }
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
    private func openLocalItem(at url: URL) async -> Bool {
        NSWorkspace.shared.open(url)
    }

    @MainActor
    private func waitForFrontmostApplication(_ target: LocalAppTarget) async {
        let bundleIdentifier = target.bundleIdentifier
        for _ in 0..<16 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier {
                return
            }
            try? await Task.sleep(nanoseconds: 125_000_000)
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
