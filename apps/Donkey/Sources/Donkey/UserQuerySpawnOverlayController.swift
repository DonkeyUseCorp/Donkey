import AppKit
import DonkeyContracts
import DonkeyRuntime
import DonkeyUI
import QuartzCore
import SwiftUI

@MainActor
final class UserQuerySpawnOverlayController {
    private var surfacesByID: [String: UserQuerySpawnSurface] = [:]
    private var viewModelsByID: [String: UserQuerySpawnOverlayViewModel] = [:]
    private var pendingGuideRequestsBySpawnID: [String: PointerCoachCursorGuideRequest] = [:]
    private var windowResolver = MacWindowResolver()
    private var localOutsideClickMonitor: Any?
    private var globalOutsideClickMonitor: Any?

    var followUpSubmitted: ((String, String, String) -> Void)? {
        didSet {
            for viewModel in viewModelsByID.values {
                viewModel.followUpSubmitted = followUpSubmitted
            }
        }
    }

    var selected: ((String) -> Void)? {
        didSet {
            for viewModel in viewModelsByID.values {
                viewModel.selected = selected
            }
        }
    }

    func update(
        spawnStates: [UserQuerySpawnState],
        selectedSpawnID: String?,
        screen: NSScreen?,
        notchMetrics: UserQueryNotchMetrics
    ) {
        guard let screen else { return }

        let visibleSpawnStates = spawnStates.filter { $0.phase != .notchCue }
        guard !visibleSpawnStates.isEmpty else {
            if spawnStates.isEmpty {
                pendingGuideRequestsBySpawnID = [:]
            }
            fadeAndCloseAll()
            return
        }

        let allSpawnIDs = Set(spawnStates.map(\.id))
        let visibleIDs = Set(visibleSpawnStates.map(\.id))
        pendingGuideRequestsBySpawnID = pendingGuideRequestsBySpawnID.filter { allSpawnIDs.contains($0.key) }
        for spawnState in visibleSpawnStates {
            updateSurface(
                for: spawnState,
                selectedSpawnID: selectedSpawnID,
                screen: screen,
                notchMetrics: notchMetrics
            )
        }

        for staleID in surfacesByID.keys where !visibleIDs.contains(staleID) {
            fadeAndRemove(id: staleID)
        }
    }

    func close() {
        removeOutsideClickMonitoring()
        for surface in surfacesByID.values {
            surface.travelWorkItem?.cancel()
            surface.removalWorkItem?.cancel()
            cancelGuide(for: surface)
            surface.viewModel.fadeOut()
            surface.panel.close()
        }
        surfacesByID = [:]
        viewModelsByID = [:]
        pendingGuideRequestsBySpawnID = [:]
    }

    @discardableResult
    func playGuide(
        request: PointerCoachCursorGuideRequest,
        on spawnID: String?,
        screen: NSScreen?
    ) -> Bool {
        guard let spawnID,
              !request.steps.isEmpty,
              let screen else {
            return false
        }

        guard let surface = surfacesByID[spawnID] else {
            pendingGuideRequestsBySpawnID[spawnID] = request
            return true
        }

        startGuide(
            request: request,
            on: surface,
            screen: screen,
            startDelay: surface.isTraveling ? UserQuerySpawnOverlayViewModel.travelDuration + 0.04 : 0
        )
        return true
    }

    private func updateSurface(
        for spawnState: UserQuerySpawnState,
        selectedSpawnID: String?,
        screen: NSScreen,
        notchMetrics: UserQueryNotchMetrics
    ) {
        let destination = destinationPoint(
            for: spawnState.targetHint,
            screen: screen,
            notchMetrics: notchMetrics
        )

        if let surface = surfacesByID[spawnState.id] {
            updateExistingSurface(
                surface,
                spawnState: spawnState,
                selectedSpawnID: selectedSpawnID,
                destination: destination,
                screen: screen
            )
            return
        }

        createSurface(
            for: spawnState,
            selectedSpawnID: selectedSpawnID,
            destination: destination,
            screen: screen
        )
    }

    private func createSurface(
        for spawnState: UserQuerySpawnState,
        selectedSpawnID: String?,
        destination: CGPoint,
        screen: NSScreen
    ) {
        let viewModel = UserQuerySpawnOverlayViewModel()
        viewModel.followUpSubmitted = followUpSubmitted
        viewModel.selected = selected
        viewModel.setSelected(spawnState.id == selectedSpawnID)

        let origin = spawnOrigin(
            in: screen,
            index: surfacesByID.count
        )
        viewModel.show(
            state: spawnState,
            origin: origin,
            destination: destination,
            screenSize: screen.frame.size
        )

        let initialLocalFrame = viewModel.cursorPanelFrame(at: origin)
        viewModel.updateViewport(
            origin: initialLocalFrame.origin,
            size: initialLocalFrame.size
        )
        let surface = makeSurface(
            id: spawnState.id,
            viewModel: viewModel,
            localFrame: initialLocalFrame,
            screen: screen
        )
        configureCallbacks(for: surface)
        surfacesByID[spawnState.id] = surface
        viewModelsByID[spawnState.id] = viewModel
        animateSurfaceTravel(
            surface,
            to: destination,
            on: screen
        )
        startPendingGuideIfNeeded(
            for: surface,
            screen: screen,
            startDelay: UserQuerySpawnOverlayViewModel.travelDuration + 0.04
        )
    }

    private func updateExistingSurface(
        _ surface: UserQuerySpawnSurface,
        spawnState: UserQuerySpawnState,
        selectedSpawnID: String?,
        destination: CGPoint,
        screen: NSScreen
    ) {
        surface.screen = screen
        surface.viewModel.setSelected(spawnState.id == selectedSpawnID)
        if spawnState.phase == .fading {
            fadeAndRemove(id: spawnState.id)
            return
        }

        if surface.isPlayingGuide {
            updateMouseEventPassthrough(for: surface)
            return
        }
        startPendingGuideIfNeeded(
            for: surface,
            screen: screen,
            startDelay: surface.isTraveling ? UserQuerySpawnOverlayViewModel.travelDuration + 0.04 : 0
        )
        if surface.isPlayingGuide {
            updateMouseEventPassthrough(for: surface)
            return
        }

        let shouldRetarget = !surface.viewModel.freezesMovement &&
            distance(from: surface.destination, to: destination) > 1

        surface.viewModel.update(
            state: spawnState,
            destination: destination,
            screenSize: screen.frame.size
        )

        if shouldRetarget {
            animateSurfaceTravel(
                surface,
                to: destination,
                on: screen
            )
            return
        }

        if surface.isTraveling {
            updateMouseEventPassthrough(for: surface)
            return
        }

        layoutSurface(
            surface,
            on: screen,
            animated: false
        )
    }

    private func makeSurface(
        id: String,
        viewModel: UserQuerySpawnOverlayViewModel,
        localFrame: CGRect,
        screen: NSScreen
    ) -> UserQuerySpawnSurface {
        let globalFrame = panelFrame(
            for: localFrame,
            on: screen
        )
        let hostingView = UserQuerySpawnHostingView(
            rootView: UserQuerySpawnOverlayView(viewModel: viewModel)
        )
        hostingView.frame = CGRect(origin: .zero, size: globalFrame.size)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.hitTestRegionProvider = { [weak viewModel] in
            guard let viewModel else { return [] }

            let frame = viewModel.localHitTestFrame
            return frame.isNull || frame.isEmpty ? [] : [frame]
        }

        let panel = UserQuerySpawnPanel(
            contentRect: globalFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.title = "Donkey Spawn"
        panel.contentView = hostingView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.ignoresMouseEvents = true
        panel.level = DonkeyOverlayWindowLevel.userQuery
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary
        ]
        panel.setFrame(globalFrame, display: true)
        panel.orderFrontRegardless()

        return UserQuerySpawnSurface(
            id: id,
            viewModel: viewModel,
            panel: panel,
            hostingView: hostingView,
            screen: screen,
            destination: viewModel.destination
        )
    }

    private func configureCallbacks(for surface: UserQuerySpawnSurface) {
        surface.viewModel.labelLayoutChanged = { [weak self, weak surface] in
            guard let self,
                  let surface else {
                return
            }

            self.layoutSurface(
                surface,
                on: surface.screen,
                animated: false
            )
        }
        surface.viewModel.labelEditingChanged = { [weak self, weak surface] isEditing in
            guard let self,
                  let surface else {
                return
            }

            self.layoutSurface(
                surface,
                on: surface.screen,
                animated: false
            )
            if isEditing {
                NSApp.activate(ignoringOtherApps: true)
                surface.panel.orderFrontRegardless()
                surface.panel.makeKeyAndOrderFront(nil)
            } else {
                surface.panel.orderFrontRegardless()
            }
            self.updateMouseEventPassthrough(for: surface)
            self.updateOutsideClickMonitoring()
        }
        surface.viewModel.travelCompleted = { [weak self, weak surface] in
            guard let self,
                  let surface else {
                return
            }

            surface.isTraveling = false
            self.layoutSurface(
                surface,
                on: surface.screen,
                animated: false
            )
        }
    }

    private func animateSurfaceTravel(
        _ surface: UserQuerySpawnSurface,
        to destination: CGPoint,
        on screen: NSScreen
    ) {
        surface.travelWorkItem?.cancel()
        surface.screen = screen
        surface.destination = destination
        surface.isTraveling = true

        let currentLocalFrame = surface.viewModel.cursorPanelFrame(
            at: surface.viewModel.position
        )
        applyViewport(
            currentLocalFrame,
            to: surface,
            on: screen
        )
        surface.panel.setFrame(
            panelFrame(for: currentLocalFrame, on: screen),
            display: true
        )

        let destinationLocalFrame = surface.viewModel.cursorPanelFrame(
            at: destination
        )
        let destinationGlobalFrame = panelFrame(
            for: destinationLocalFrame,
            on: screen
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = UserQuerySpawnOverlayViewModel.travelDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0.05, 0.3, 1)
            surface.panel.animator().setFrame(destinationGlobalFrame, display: true)
        }

        let workItem = DispatchWorkItem { [weak self, weak surface] in
            guard let self,
                  let surface,
                  surface.isTraveling else {
                return
            }

            surface.isTraveling = false
            self.layoutSurface(
                surface,
                on: surface.screen,
                animated: false
            )
        }
        surface.travelWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + UserQuerySpawnOverlayViewModel.travelDuration + 0.03,
            execute: workItem
        )
        updateMouseEventPassthrough(for: surface)
    }

    private func startGuide(
        request: PointerCoachCursorGuideRequest,
        on surface: UserQuerySpawnSurface,
        screen: NSScreen,
        startDelay: TimeInterval
    ) {
        cancelGuide(for: surface)
        surface.isPlayingGuide = true

        var delay = startDelay
        for step in request.steps {
            let workItem = DispatchWorkItem { [weak self, weak surface] in
                Task { @MainActor in
                    guard let self,
                          let surface else {
                        return
                    }

                    self.applyGuideStep(
                        step,
                        request: request,
                        to: surface,
                        screen: screen
                    )
                }
            }
            surface.guideWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            delay += UserQuerySpawnOverlayViewModel.travelDuration + step.holdDuration
        }

        let completionWorkItem = DispatchWorkItem { [weak self, weak surface] in
            guard let self,
                  let surface else {
                return
            }

            surface.isPlayingGuide = false
            surface.guideWorkItems = []
            surface.guideCompletionWorkItem = nil
            self.layoutSurface(surface, on: surface.screen, animated: false)
        }
        surface.guideCompletionWorkItem = completionWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.05, execute: completionWorkItem)
    }

    private func applyGuideStep(
        _ step: PointerCoachCursorGuideStep,
        request: PointerCoachCursorGuideRequest,
        to surface: UserQuerySpawnSurface,
        screen: NSScreen
    ) {
        guard var state = surface.viewModel.state else { return }

        state.label = step.label
        state.phase = .traveling
        state.updatedAt = Date()
        state.targetHint = UserQuerySpawnTargetHint(
            metadata: [
                "agentVisualization.planID": request.id,
                "agentVisualization.stepID": step.id,
                "agentVisualization.reusedSpawn": "true"
            ]
        )
        let destination = guideDestination(
            for: step,
            on: screen
        )
        surface.screen = screen
        surface.viewModel.update(
            state: state,
            destination: destination,
            screenSize: screen.frame.size
        )
        animateSurfaceTravel(surface, to: destination, on: screen)
    }

    private func guideDestination(
        for step: PointerCoachCursorGuideStep,
        on screen: NSScreen
    ) -> CGPoint {
        AgentVisualizationCursorPathSampler.point(
            step.target,
            metadata: step.metadata,
            screenFrame: screen.frame
        )
    }

    private func cancelGuide(for surface: UserQuerySpawnSurface) {
        for workItem in surface.guideWorkItems {
            workItem.cancel()
        }
        surface.guideWorkItems = []
        surface.guideCompletionWorkItem?.cancel()
        surface.guideCompletionWorkItem = nil
        surface.isPlayingGuide = false
    }

    private func startPendingGuideIfNeeded(
        for surface: UserQuerySpawnSurface,
        screen: NSScreen,
        startDelay: TimeInterval
    ) {
        guard let request = pendingGuideRequestsBySpawnID.removeValue(forKey: surface.id) else {
            return
        }

        startGuide(
            request: request,
            on: surface,
            screen: screen,
            startDelay: startDelay
        )
    }

    private func layoutSurface(
        _ surface: UserQuerySpawnSurface,
        on screen: NSScreen,
        animated: Bool
    ) {
        guard !surface.viewModel.visualFrame.isNull,
              !surface.viewModel.visualFrame.isEmpty else {
            updateMouseEventPassthrough(for: surface)
            return
        }

        surface.screen = screen
        let localFrame = surface.viewModel.visualFrame
        applyViewport(
            localFrame,
            to: surface,
            on: screen
        )
        let globalFrame = panelFrame(for: localFrame, on: screen)
        if animated {
            surface.panel.animator().setFrame(globalFrame, display: true)
        } else {
            surface.panel.setFrame(globalFrame, display: true)
        }
        updateMouseEventPassthrough(for: surface)
    }

    private func applyViewport(
        _ localFrame: CGRect,
        to surface: UserQuerySpawnSurface,
        on screen: NSScreen
    ) {
        surface.viewModel.updateViewport(
            origin: localFrame.origin,
            size: localFrame.size
        )
        surface.hostingView.frame = CGRect(origin: .zero, size: localFrame.size)
        surface.screen = screen
    }

    private func updateMouseEventPassthrough(for surface: UserQuerySpawnSurface) {
        let hitTestFrame = surface.viewModel.localHitTestFrame
        guard !hitTestFrame.isNull, !hitTestFrame.isEmpty else {
            surface.panel.ignoresMouseEvents = true
            return
        }

        let mouseLocation = surface.panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        surface.panel.ignoresMouseEvents = !hitTestFrame.contains(mouseLocation)
    }

    func cueState(
        for spawnState: UserQuerySpawnState?,
        screen: NSScreen?,
        notchMetrics: UserQueryNotchMetrics
    ) -> UserQuerySpawnState? {
        guard var spawnState,
              spawnState.phase == .notchCue,
              let screen else {
            return spawnState
        }

        let notchBottomY = max(
            notchMetrics.layout.collapsedVisibleHeight,
            notchMetrics.layout.voidHeight
        )
        let origin = CGPoint(x: screen.frame.width / 2, y: notchBottomY)
        let destination = destinationPoint(
            for: spawnState.targetHint,
            screen: screen,
            notchMetrics: notchMetrics
        )
        spawnState.notchCueAngleDegrees = UserQuerySpawnGeometry.angleDegrees(
            from: origin,
            to: destination
        )
        return spawnState
    }

    private func fadeAndCloseAll() {
        for spawnID in Array(surfacesByID.keys) {
            fadeAndRemove(id: spawnID)
        }
    }

    private func fadeAndRemove(id spawnID: String) {
        guard let surface = surfacesByID[spawnID] else { return }

        surface.travelWorkItem?.cancel()
        surface.removalWorkItem?.cancel()
        pendingGuideRequestsBySpawnID[spawnID] = nil
        cancelGuide(for: surface)
        surface.viewModel.fadeOut()
        let workItem = DispatchWorkItem { [weak self, weak surface] in
            guard let self,
                  let surface else {
                return
            }

            surface.panel.close()
            self.surfacesByID[spawnID] = nil
            self.viewModelsByID[spawnID] = nil
        }
        surface.removalWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: workItem)
    }

    private func updateOutsideClickMonitoring() {
        guard viewModelsByID.values.contains(where: \.isLabelEditing) else {
            removeOutsideClickMonitoring()
            return
        }

        installOutsideClickMonitoringIfNeeded()
    }

    private func installOutsideClickMonitoringIfNeeded() {
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown
        ]
        if localOutsideClickMonitor == nil {
            localOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                let screenPoint = NSEvent.mouseLocation
                Task { @MainActor [weak self] in
                    self?.handleOutsideClickCandidate(at: screenPoint)
                }
                return event
            }
        }
        if globalOutsideClickMonitor == nil {
            globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
                let screenPoint = NSEvent.mouseLocation
                Task { @MainActor [weak self] in
                    self?.handleOutsideClickCandidate(at: screenPoint)
                }
            }
        }
    }

    private func removeOutsideClickMonitoring() {
        if let localOutsideClickMonitor {
            NSEvent.removeMonitor(localOutsideClickMonitor)
            self.localOutsideClickMonitor = nil
        }
        if let globalOutsideClickMonitor {
            NSEvent.removeMonitor(globalOutsideClickMonitor)
            self.globalOutsideClickMonitor = nil
        }
    }

    private func handleOutsideClickCandidate(at screenPoint: CGPoint) {
        let activeSurfaces = surfacesByID.values.filter { $0.viewModel.isLabelEditing }
        guard !activeSurfaces.isEmpty else {
            removeOutsideClickMonitoring()
            return
        }

        guard !activeSurfaces.contains(where: { contains(screenPoint, inInteractiveRegionOf: $0) }) else {
            return
        }

        for surface in activeSurfaces {
            surface.viewModel.cancelInlineInput()
        }
        updateOutsideClickMonitoring()
    }

    private func contains(
        _ screenPoint: CGPoint,
        inInteractiveRegionOf surface: UserQuerySpawnSurface
    ) -> Bool {
        guard surface.panel.frame.contains(screenPoint) else { return false }

        let localPoint = surface.panel.convertPoint(fromScreen: screenPoint)
        return surface.viewModel.localHitTestFrame.contains(localPoint)
    }

    private func spawnOrigin(in screen: NSScreen, index: Int) -> CGPoint {
        let stagger = CGFloat((index % 5) - 2) * 18
        return CGPoint(x: screen.frame.width / 2 + stagger, y: -24)
    }

    private func destinationPoint(
        for hint: UserQuerySpawnTargetHint?,
        screen: NSScreen,
        notchMetrics: UserQueryNotchMetrics
    ) -> CGPoint {
        let screenSize = screen.frame.size
        let fallback = UserQuerySpawnGeometry.fallbackPoint(
            screenSize: screenSize,
            notchBottomY: max(
                notchMetrics.layout.collapsedVisibleHeight,
                notchMetrics.layout.voidHeight
            )
        )

        guard let hint else { return fallback }

        if let bounds = hint.bounds {
            return point(for: bounds, on: screen) ?? fallback
        }

        guard let target = resolvedWindowTarget(for: hint) else {
            return fallback
        }

        return point(for: target.bounds, on: screen) ?? fallback
    }

    private func resolvedWindowTarget(for hint: UserQuerySpawnTargetHint) -> MacWindowTargetCandidate? {
        let candidates = windowResolver.enumerateCandidates()
            .filter {
                $0.isVisible &&
                    $0.isOnScreen &&
                    $0.safetyAssessment.status == .allowed &&
                    matches($0, hint: hint)
            }

        return candidates
            .sorted {
                if $0.isFocused != $1.isFocused {
                    return $0.isFocused && !$1.isFocused
                }
                if $0.isFrontmost != $1.isFrontmost {
                    return $0.isFrontmost && !$1.isFrontmost
                }
                return $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height
            }
            .first
    }

    private func matches(
        _ candidate: MacWindowTargetCandidate,
        hint: UserQuerySpawnTargetHint
    ) -> Bool {
        if let bundleIdentifier = hint.bundleIdentifier,
           candidate.bundleIdentifier != bundleIdentifier {
            return false
        }

        if let titleContains = hint.titleContains,
           candidate.title?.localizedCaseInsensitiveContains(titleContains) != true {
            return false
        }

        if hint.bundleIdentifier == nil,
           hint.titleContains == nil,
           let appName = hint.appName,
           candidate.appName?.localizedCaseInsensitiveContains(appName) != true {
            return false
        }

        return true
    }

    private func point(
        for bounds: WindowTargetBounds,
        on screen: NSScreen
    ) -> CGPoint? {
        guard bounds.hasPositiveArea else { return nil }

        let localPoint = CGPoint(
            x: CGFloat(bounds.x) - screen.frame.minX + CGFloat(bounds.width) / 2,
            y: CGFloat(bounds.y) + CGFloat(bounds.height) / 2
        )
        return UserQuerySpawnGeometry.clampedPoint(
            localPoint,
            in: screen.frame.size
        )
    }

    private func panelFrame(
        for localFrame: CGRect,
        on screen: NSScreen
    ) -> CGRect {
        CGRect(
            x: screen.frame.minX + localFrame.minX,
            y: screen.frame.maxY - localFrame.maxY,
            width: localFrame.width,
            height: localFrame.height
        )
    }

    private func distance(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}

private final class UserQuerySpawnSurface {
    let id: String
    let viewModel: UserQuerySpawnOverlayViewModel
    let panel: UserQuerySpawnPanel
    let hostingView: UserQuerySpawnHostingView<UserQuerySpawnOverlayView>
    var screen: NSScreen
    var destination: CGPoint
    var isTraveling = false
    var travelWorkItem: DispatchWorkItem?
    var removalWorkItem: DispatchWorkItem?
    var isPlayingGuide = false
    var guideWorkItems: [DispatchWorkItem] = []
    var guideCompletionWorkItem: DispatchWorkItem?

    init(
        id: String,
        viewModel: UserQuerySpawnOverlayViewModel,
        panel: UserQuerySpawnPanel,
        hostingView: UserQuerySpawnHostingView<UserQuerySpawnOverlayView>,
        screen: NSScreen,
        destination: CGPoint
    ) {
        self.id = id
        self.viewModel = viewModel
        self.panel = panel
        self.hostingView = hostingView
        self.screen = screen
        self.destination = destination
    }
}

private final class UserQuerySpawnPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

private final class UserQuerySpawnHostingView<Content: View>: NSHostingView<Content> {
    var hitTestRegionProvider: (() -> [CGRect])?

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hitTestRegionProvider,
           !hitTestRegionProvider().contains(where: { $0.contains(point) }) {
            return nil
        }

        return super.hitTest(point)
    }
}
