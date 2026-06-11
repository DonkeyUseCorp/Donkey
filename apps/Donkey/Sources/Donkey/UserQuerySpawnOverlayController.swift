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
    private var dismissedSpawnIDs: Set<String> = []
    private var windowResolver = MacWindowResolver()
    private var localOutsideClickMonitor: Any?
    private var globalOutsideClickMonitor: Any?
    private var localMouseMoveMonitor: Any?
    private var globalMouseMoveMonitor: Any?

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

        let allSpawnIDs = Set(spawnStates.map(\.id))
        dismissedSpawnIDs.formIntersection(allSpawnIDs)
        let visibleSpawnStates = spawnStates.filter {
            $0.phase != .notchCue && !dismissedSpawnIDs.contains($0.id)
        }
        guard !visibleSpawnStates.isEmpty else {
            if spawnStates.isEmpty {
                pendingGuideRequestsBySpawnID = [:]
            }
            fadeAndCloseAll()
            return
        }

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
        removeMouseMoveMonitoring()
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
        dismissedSpawnIDs = []
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

        // Swallow guides for a pointer the user dismissed so the fallback
        // overlay does not resurrect it.
        guard !dismissedSpawnIDs.contains(spawnID) else { return true }

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

    /// Clears a user dismissal so the next update re-creates the pointer
    /// surface, emerging from the notch again.
    func restoreSpawn(id spawnID: String) {
        dismissedSpawnIDs.remove(spawnID)
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

        // A user-dragged cursor keeps its spot through model updates; only an
        // explicit new guide step moves it again.
        let effectiveDestination = surface.isUserPositioned ? surface.destination : destination
        let shouldRetarget = !surface.viewModel.freezesMovement &&
            distance(from: surface.destination, to: effectiveDestination) > 1

        surface.viewModel.update(
            state: spawnState,
            destination: effectiveDestination,
            screenSize: screen.frame.size
        )

        if shouldRetarget {
            animateSurfaceTravel(
                surface,
                to: effectiveDestination,
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
        surface.viewModel.dismissed = { [weak self] spawnID in
            guard let self else { return }

            self.dismissedSpawnIDs.insert(spawnID)
            self.fadeAndRemove(id: spawnID)
        }
        surface.viewModel.cursorDragged = { [weak self, weak surface] globalPoint in
            guard let self,
                  let surface else {
                return
            }

            self.moveSurfaceCursor(surface, toGlobalPoint: globalPoint)
        }
    }

    /// Repositions a holding cursor under the user's drag. The global AppKit
    /// mouse point (bottom-left origin) is converted to the overlay's
    /// top-left-origin screen-local space before being applied.
    private func moveSurfaceCursor(
        _ surface: UserQuerySpawnSurface,
        toGlobalPoint globalPoint: CGPoint
    ) {
        let screenFrame = surface.screen.frame
        let localPoint = UserQuerySpawnGeometry.clampedPoint(
            CGPoint(
                x: globalPoint.x - screenFrame.minX,
                y: screenFrame.maxY - globalPoint.y
            ),
            in: screenFrame.size
        )
        surface.travelWorkItem?.cancel()
        surface.isTraveling = false
        surface.isUserPositioned = true
        surface.destination = localPoint
        surface.viewModel.setPosition(localPoint)
        layoutSurface(
            surface,
            on: surface.screen,
            animated: false
        )
    }

    private func animateSurfaceTravel(
        _ surface: UserQuerySpawnSurface,
        to destination: CGPoint,
        on screen: NSScreen,
        preRotateDuration: TimeInterval = 0,
        travelDuration: TimeInterval = UserQuerySpawnOverlayViewModel.travelDuration
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

        let startTravel = DispatchWorkItem { [weak surface] in
            guard let surface else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = travelDuration
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0.05, 0.3, 1)
                surface.panel.animator().setFrame(destinationGlobalFrame, display: true)
            }
        }
        if preRotateDuration > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + preRotateDuration, execute: startTravel)
        } else {
            startTravel.perform()
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
            deadline: .now() + preRotateDuration + travelDuration + 0.03,
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
            delay += step.preRotateDuration + step.travelDuration + step.holdDuration
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
            screenSize: screen.frame.size,
            preRotateDuration: step.preRotateDuration,
            travelDuration: step.travelDuration
        )
        // The view model refuses to move while the user drags the cursor or
        // edits the label; moving the panel anyway would tear the two apart.
        guard !surface.viewModel.freezesMovement else { return }

        surface.isUserPositioned = false
        animateSurfaceTravel(
            surface,
            to: destination,
            on: screen,
            preRotateDuration: step.preRotateDuration,
            travelDuration: step.travelDuration
        )
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
        defer { updateMouseMoveMonitoring() }

        // A drag in progress must keep receiving events even when the pointer
        // briefly outruns the panel frame; going click-through would kill it.
        if surface.viewModel.isCursorDragging {
            surface.panel.ignoresMouseEvents = false
            return
        }

        let hitTestFrame = surface.viewModel.localHitTestFrame
        guard !hitTestFrame.isNull, !hitTestFrame.isEmpty else {
            surface.panel.ignoresMouseEvents = true
            return
        }

        let mouseLocation = overlayLocalPoint(
            for: NSEvent.mouseLocation,
            in: surface
        )
        surface.panel.ignoresMouseEvents = !hitTestFrame.contains(mouseLocation)
    }

    /// Converts a global screen point into the overlay's top-left-origin local
    /// space. `convertPoint(fromScreen:)` alone is not enough: it returns
    /// bottom-left-origin window coordinates, and comparing those against the
    /// flipped `localHitTestFrame` mirrors the interactive region vertically.
    private func overlayLocalPoint(
        for screenPoint: CGPoint,
        in surface: UserQuerySpawnSurface
    ) -> CGPoint {
        let windowPoint = surface.panel.convertPoint(fromScreen: screenPoint)
        return CGPoint(
            x: windowPoint.x,
            y: surface.panel.frame.height - windowPoint.y
        )
    }

    /// `ignoresMouseEvents` is only as fresh as its last evaluation, which
    /// otherwise happens on model updates and layout changes. Without a
    /// movement monitor, mousing over a quiet holding pointer leaves its panel
    /// click-through, so hover and drags never start.
    private func updateMouseMoveMonitoring() {
        guard surfacesByID.values.contains(where: {
            !$0.viewModel.localHitTestFrame.isNull
        }) else {
            removeMouseMoveMonitoring()
            return
        }

        installMouseMoveMonitoringIfNeeded()
    }

    private func installMouseMoveMonitoringIfNeeded() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved]
        if localMouseMoveMonitor == nil {
            localMouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.refreshMouseEventPassthroughForAllSurfaces()
                }
                return event
            }
        }
        if globalMouseMoveMonitor == nil {
            globalMouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshMouseEventPassthroughForAllSurfaces()
                }
            }
        }
    }

    private func removeMouseMoveMonitoring() {
        if let localMouseMoveMonitor {
            NSEvent.removeMonitor(localMouseMoveMonitor)
            self.localMouseMoveMonitor = nil
        }
        if let globalMouseMoveMonitor {
            NSEvent.removeMonitor(globalMouseMoveMonitor)
            self.globalMouseMoveMonitor = nil
        }
    }

    private func refreshMouseEventPassthroughForAllSurfaces() {
        for surface in surfacesByID.values {
            updateMouseEventPassthrough(for: surface)
        }
        updateMouseMoveMonitoring()
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
        // Already fading out — restarting would keep postponing the close on
        // every model update, leaving an invisible panel that swallows clicks.
        guard surface.removalWorkItem == nil else { return }

        surface.travelWorkItem?.cancel()
        surface.panel.ignoresMouseEvents = true
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

        let localPoint = overlayLocalPoint(for: screenPoint, in: surface)
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
    var isUserPositioned = false
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

    /// The first click on an inactive panel must reach the SwiftUI gestures
    /// directly; without this it only focuses the panel and the user has to
    /// click again to drag or dismiss.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hitTestRegionProvider,
           !hitTestRegionProvider().contains(where: { $0.contains(point) }) {
            return nil
        }

        return super.hitTest(point)
    }
}
