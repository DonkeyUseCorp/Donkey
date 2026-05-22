import AppKit
import DonkeyContracts
import DonkeyRuntime
import DonkeyUI
import QuartzCore
import SwiftUI

@MainActor
final class PointerPromptSpawnOverlayController {
    private var surfacesByID: [String: PointerPromptSpawnSurface] = [:]
    private var viewModelsByID: [String: PointerPromptSpawnOverlayViewModel] = [:]
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
        spawnStates: [PointerPromptSpawnState],
        selectedSpawnID: String?,
        screen: NSScreen?,
        notchMetrics: PointerPromptNotchMetrics
    ) {
        guard let screen else { return }

        let visibleSpawnStates = spawnStates.filter { $0.phase != .notchCue }
        guard !visibleSpawnStates.isEmpty else {
            fadeAndCloseAll()
            return
        }

        let visibleIDs = Set(visibleSpawnStates.map(\.id))
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
            surface.viewModel.fadeOut()
            surface.panel.close()
        }
        surfacesByID = [:]
        viewModelsByID = [:]
    }

    private func updateSurface(
        for spawnState: PointerPromptSpawnState,
        selectedSpawnID: String?,
        screen: NSScreen,
        notchMetrics: PointerPromptNotchMetrics
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
        for spawnState: PointerPromptSpawnState,
        selectedSpawnID: String?,
        destination: CGPoint,
        screen: NSScreen
    ) {
        let viewModel = PointerPromptSpawnOverlayViewModel()
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

        let initialLocalFrame = viewModel.cursorOnlyVisualFrame(at: origin)
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
    }

    private func updateExistingSurface(
        _ surface: PointerPromptSpawnSurface,
        spawnState: PointerPromptSpawnState,
        selectedSpawnID: String?,
        destination: CGPoint,
        screen: NSScreen
    ) {
        surface.screen = screen
        surface.viewModel.setSelected(spawnState.id == selectedSpawnID)
        let shouldRetarget = !surface.viewModel.freezesMovement &&
            distance(from: surface.destination, to: destination) > 1

        surface.viewModel.update(
            state: spawnState,
            destination: destination,
            screenSize: screen.frame.size
        )

        if spawnState.phase == .fading {
            fadeAndRemove(id: spawnState.id)
            return
        }

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
        viewModel: PointerPromptSpawnOverlayViewModel,
        localFrame: CGRect,
        screen: NSScreen
    ) -> PointerPromptSpawnSurface {
        let globalFrame = panelFrame(
            for: localFrame,
            on: screen
        )
        let hostingView = PointerPromptSpawnHostingView(
            rootView: PointerPromptSpawnOverlayView(viewModel: viewModel)
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

        let panel = PointerPromptSpawnPanel(
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
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary
        ]
        panel.setFrame(globalFrame, display: true)
        panel.orderFrontRegardless()

        return PointerPromptSpawnSurface(
            id: id,
            viewModel: viewModel,
            panel: panel,
            hostingView: hostingView,
            screen: screen,
            destination: viewModel.destination
        )
    }

    private func configureCallbacks(for surface: PointerPromptSpawnSurface) {
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
        _ surface: PointerPromptSpawnSurface,
        to destination: CGPoint,
        on screen: NSScreen
    ) {
        surface.travelWorkItem?.cancel()
        surface.screen = screen
        surface.destination = destination
        surface.isTraveling = true

        let currentLocalFrame = surface.viewModel.cursorOnlyVisualFrame(
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

        let destinationLocalFrame = surface.viewModel.cursorOnlyVisualFrame(
            at: destination
        )
        let destinationGlobalFrame = panelFrame(
            for: destinationLocalFrame,
            on: screen
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = PointerPromptSpawnOverlayViewModel.travelDuration
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
            deadline: .now() + PointerPromptSpawnOverlayViewModel.travelDuration + 0.03,
            execute: workItem
        )
        updateMouseEventPassthrough(for: surface)
    }

    private func layoutSurface(
        _ surface: PointerPromptSpawnSurface,
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
        to surface: PointerPromptSpawnSurface,
        on screen: NSScreen
    ) {
        surface.viewModel.updateViewport(
            origin: localFrame.origin,
            size: localFrame.size
        )
        surface.hostingView.frame = CGRect(origin: .zero, size: localFrame.size)
        surface.screen = screen
    }

    private func updateMouseEventPassthrough(for surface: PointerPromptSpawnSurface) {
        let hitTestFrame = surface.viewModel.localHitTestFrame
        guard !hitTestFrame.isNull, !hitTestFrame.isEmpty else {
            surface.panel.ignoresMouseEvents = true
            return
        }

        let mouseLocation = surface.panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        surface.panel.ignoresMouseEvents = !hitTestFrame.contains(mouseLocation)
    }

    func cueState(
        for spawnState: PointerPromptSpawnState?,
        screen: NSScreen?,
        notchMetrics: PointerPromptNotchMetrics
    ) -> PointerPromptSpawnState? {
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
        spawnState.notchCueAngleDegrees = PointerPromptSpawnGeometry.angleDegrees(
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
        inInteractiveRegionOf surface: PointerPromptSpawnSurface
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
        for hint: PointerPromptSpawnTargetHint?,
        screen: NSScreen,
        notchMetrics: PointerPromptNotchMetrics
    ) -> CGPoint {
        let screenSize = screen.frame.size
        let fallback = PointerPromptSpawnGeometry.fallbackPoint(
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

    private func resolvedWindowTarget(for hint: PointerPromptSpawnTargetHint) -> MacWindowTargetCandidate? {
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
        hint: PointerPromptSpawnTargetHint
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
        return PointerPromptSpawnGeometry.clampedPoint(
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

private final class PointerPromptSpawnSurface {
    let id: String
    let viewModel: PointerPromptSpawnOverlayViewModel
    let panel: PointerPromptSpawnPanel
    let hostingView: PointerPromptSpawnHostingView<PointerPromptSpawnOverlayView>
    var screen: NSScreen
    var destination: CGPoint
    var isTraveling = false
    var travelWorkItem: DispatchWorkItem?
    var removalWorkItem: DispatchWorkItem?

    init(
        id: String,
        viewModel: PointerPromptSpawnOverlayViewModel,
        panel: PointerPromptSpawnPanel,
        hostingView: PointerPromptSpawnHostingView<PointerPromptSpawnOverlayView>,
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

private final class PointerPromptSpawnPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

private final class PointerPromptSpawnHostingView<Content: View>: NSHostingView<Content> {
    var hitTestRegionProvider: (() -> [CGRect])?

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hitTestRegionProvider,
           !hitTestRegionProvider().contains(where: { $0.contains(point) }) {
            return nil
        }

        return super.hitTest(point)
    }
}
