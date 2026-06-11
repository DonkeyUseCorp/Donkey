import AppKit
import DonkeyContracts
import SwiftUI

@MainActor
public final class UserQuerySpawnOverlayViewModel: ObservableObject {
    public let objectID = UUID().uuidString
    @Published public private(set) var state: UserQuerySpawnState?
    @Published public private(set) var position: CGPoint = .zero
    @Published public private(set) var destination: CGPoint = .zero
    @Published public private(set) var screenSize: CGSize = .zero
    @Published public private(set) var viewportOrigin: CGPoint = .zero
    @Published public private(set) var viewportSize: CGSize = .zero
    @Published public private(set) var opacity: Double = 0
    @Published public private(set) var isHolding = false
    @Published public private(set) var isSelected = false
    @Published public private(set) var cursorAngleDegrees =
        UserQuerySpawnGeometry.defaultExitAngleDegrees
    @Published public private(set) var terminalTailAngleDegrees = 0.0
    @Published public private(set) var isWorking = false
    @Published public private(set) var isCursorDragging = false
    @Published public private(set) var isLabelEditing = false
    @Published public var draftText = ""
    @Published public private(set) var draftTextHeight: CGFloat = UserQuerySpawnOverlayViewModel.inlineEditorMinimumTextHeight

    public var labelLayoutChanged: (() -> Void)?
    public var labelEditingChanged: ((Bool) -> Void)?
    public var followUpSubmitted: ((String, String, String) -> Void)?
    public var selected: ((String) -> Void)?
    public var travelCompleted: (() -> Void)?
    public var dismissed: ((String) -> Void)?
    public var cursorDragged: ((CGPoint) -> Void)?

    private var animationGeneration = 0

    public init() {}

    public var hitTestFrame: CGRect {
        guard state != nil, isHolding else { return .null }

        return contentFrame(at: position, includesLabel: true)
    }

    public var localHitTestFrame: CGRect {
        guard !hitTestFrame.isNull else { return .null }

        return hitTestFrame.offsetBy(dx: -viewportOrigin.x, dy: -viewportOrigin.y)
    }

    public var visualFrame: CGRect {
        guard state != nil else { return .null }

        return panelFrame(at: position, includesLabel: isHolding)
    }

    public var renderPosition: CGPoint {
        CGPoint(
            x: position.x - viewportOrigin.x,
            y: position.y - viewportOrigin.y
        )
    }

    public var localCursorCenter: CGPoint {
        renderPosition
    }

    public var localHaloCenter: CGPoint {
        CGPoint(
            x: localCursorCenter.x,
            y: localCursorCenter.y + Self.collapsedHaloVerticalOffset
        )
    }

    public func localLabelCenter(in screenSize: CGSize) -> CGPoint {
        let offset = labelOffset(in: screenSize)
        return CGPoint(
            x: localCursorCenter.x + offset.width,
            y: localCursorCenter.y + offset.height
        )
    }

    public var isTraveling: Bool {
        state != nil && !isHolding
    }

    public var freezesMovement: Bool {
        isCursorDragging ||
            isLabelEditing ||
            !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isAwaitingResponse: Bool {
        guard let state else { return false }

        return state.phase != .fading &&
            state.label.trimmingCharacters(in: .whitespacesAndNewlines) ==
            state.commandText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var hasScreenSize: Bool {
        screenSize.width > 0 && screenSize.height > 0
    }

    public var hasViewportSize: Bool {
        viewportSize.width > 0 && viewportSize.height > 0
    }

    public var displayLabelContentWidth: CGFloat {
        Self.displayLabelContentSize(
            for: state?.label ?? "",
            maximumWidth: Self.collapsedLabelContentWidth
        ).width
    }

    public func cursorOnlyVisualFrame(at point: CGPoint) -> CGRect {
        CGRect(
            x: point.x - Self.cursorVisualFrameSize.width / 2,
            y: point.y - Self.cursorVisualFrameSize.height / 2,
            width: Self.cursorVisualFrameSize.width,
            height: Self.cursorVisualFrameSize.height
        )
    }

    public func cursorPanelFrame(at point: CGPoint) -> CGRect {
        panelFrame(at: point, includesLabel: false)
    }

    public func updateViewport(origin: CGPoint, size: CGSize) {
        viewportOrigin = origin
        viewportSize = size
    }

    private func contentFrame(
        at point: CGPoint,
        includesLabel: Bool
    ) -> CGRect {
        var frame = cursorOnlyVisualFrame(at: point)
        guard includesLabel else { return frame.insetBy(dx: -Self.contentOverdrawPadding, dy: -Self.contentOverdrawPadding) }

        let labelSize = labelSize()
        frame = frame.union(labelFrame(for: point, labelSize: labelSize))
        return frame.insetBy(dx: -Self.contentOverdrawPadding, dy: -Self.contentOverdrawPadding)
    }

    private func panelFrame(
        at point: CGPoint,
        includesLabel: Bool
    ) -> CGRect {
        var frame = contentFrame(at: point, includesLabel: includesLabel)
        guard includesLabel else { return frame.insetBy(dx: -Self.panelOverdrawPadding, dy: -Self.panelOverdrawPadding) }

        for labelSize in reservedPanelLabelSizes() {
            frame = frame.union(labelFrame(for: point, labelSize: labelSize))
        }
        return frame.insetBy(dx: -Self.panelOverdrawPadding, dy: -Self.panelOverdrawPadding)
    }

    private func labelFrame(
        for point: CGPoint,
        labelSize: CGSize
    ) -> CGRect {
        let offset = labelOffset(for: point, labelSize: labelSize, in: screenSize)
        return CGRect(
            x: point.x + offset.width - labelSize.width / 2,
            y: point.y + offset.height - labelSize.height / 2,
            width: labelSize.width,
            height: labelSize.height
        )
    }

    public var cursorHitTestFrame: CGRect {
        guard state != nil else { return .null }

        return CGRect(
            x: position.x - 22,
            y: position.y - 22,
            width: 44,
            height: 44
        )
    }

    public func labelOffset(in screenSize: CGSize) -> CGSize {
        labelOffset(for: position, labelSize: labelSize(), in: screenSize)
    }

    private func labelOffset(
        for cursorPosition: CGPoint,
        labelSize: CGSize,
        in screenSize: CGSize
    ) -> CGSize {
        let margin = Self.screenMargin
        let preferredOffset = CGSize(width: 0, height: -(labelSize.height / 2 + Self.collapsedLabelBottomGap))
        let rightOffset = CGSize(width: labelSize.width / 2 + 44, height: 0)
        let leftOffset = CGSize(width: -labelSize.width / 2 - 44, height: 0)
        let belowOffset = CGSize(width: 0, height: labelSize.height / 2 + 44)

        if point(cursorPosition, offsetBy: preferredOffset, labelSize: labelSize, fitsIn: screenSize, margin: margin) {
            return preferredOffset
        }
        if point(cursorPosition, offsetBy: leftOffset, labelSize: labelSize, fitsIn: screenSize, margin: margin) {
            return leftOffset
        }
        if point(cursorPosition, offsetBy: rightOffset, labelSize: labelSize, fitsIn: screenSize, margin: margin) {
            return rightOffset
        }
        return clampedOffset(
            belowOffset,
            from: cursorPosition,
            labelSize: labelSize,
            in: screenSize,
            margin: margin
        )
    }

    private func labelSize() -> CGSize {
        if isLabelEditing {
            return Self.inlineEditorLabelSize(for: state?.label ?? "")
        }

        return Self.collapsedLabelSize(for: state?.label ?? "")
    }

    private func reservedPanelLabelSizes() -> [CGSize] {
        let text = state?.label ?? ""
        return [
            Self.collapsedLabelSize(for: text),
            Self.inlineEditorLabelSize(for: text)
        ]
    }

    public func show(
        state: UserQuerySpawnState,
        origin: CGPoint,
        destination: CGPoint,
        screenSize: CGSize,
        preRotateDuration: TimeInterval = 0,
        travelDuration: TimeInterval = UserQuerySpawnOverlayViewModel.travelDuration
    ) {
        animationGeneration += 1
        self.state = state
        self.position = origin
        self.destination = destination
        self.screenSize = screenSize
        self.opacity = 0
        self.isHolding = false
        let travelAngle = UserQuerySpawnGeometry.angleDegrees(
            from: origin,
            to: destination
        )
        self.cursorAngleDegrees = travelAngle
        self.terminalTailAngleDegrees = 0
        self.isWorking = false
        self.viewportOrigin = .zero
        self.viewportSize = .zero
        self.isCursorDragging = false
        self.isLabelEditing = false
        self.draftText = ""
        self.draftTextHeight = Self.inlineEditorMinimumTextHeight
        labelLayoutChanged?()
        labelEditingChanged?(false)

        let generation = animationGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.animationGeneration == generation else { return }

            withAnimation(.easeOut(duration: 0.12)) {
                self.opacity = 1
            }
            self.finishTravelAfterDelay(
                generation: generation,
                finalPosition: destination,
                delay: preRotateDuration + travelDuration
            )
        }
    }

    public func update(
        state: UserQuerySpawnState,
        destination: CGPoint,
        screenSize: CGSize,
        preRotateDuration: TimeInterval = 0,
        travelDuration: TimeInterval = UserQuerySpawnOverlayViewModel.travelDuration
    ) {
        guard self.state?.id == state.id else {
            show(
                state: state,
                origin: position,
                destination: destination,
                screenSize: screenSize,
                preRotateDuration: preRotateDuration,
                travelDuration: travelDuration
            )
            return
        }

        let previousLabel = self.state?.label
        let previousLabelSize = labelSize()
        let previousScreenSize = self.screenSize
        let wasAwaitingResponse = isAwaitingResponse
        self.state = state
        self.screenSize = screenSize
        if isHolding,
           (
            previousLabel != state.label ||
                previousLabelSize != labelSize() ||
                previousScreenSize != screenSize
           ) {
            labelLayoutChanged?()
        }
        guard state.phase != .fading else {
            fadeOut()
            return
        }
        if isHolding,
           wasAwaitingResponse,
           !isAwaitingResponse {
            animationGeneration += 1
            terminalTailAngleDegrees = 0
            withAnimation(.easeOut(duration: 0.12)) {
                isWorking = true
            }
        }

        guard !freezesMovement else { return }
        guard distance(from: self.destination, to: destination) > 1 else { return }

        animationGeneration += 1
        let generation = animationGeneration
        let travelAngle = UserQuerySpawnGeometry.angleDegrees(
            from: position,
            to: destination
        )
        if preRotateDuration > 0 {
            withAnimation(.easeInOut(duration: preRotateDuration)) {
                cursorAngleDegrees = travelAngle
            }
        } else {
            cursorAngleDegrees = travelAngle
        }
        terminalTailAngleDegrees = 0
        self.destination = destination
        self.isHolding = false
        self.isWorking = false
        withAnimation(.easeOut(duration: 0.12)) {
            self.opacity = 1
        }
        finishTravelAfterDelay(
            generation: generation,
            finalPosition: destination,
            delay: preRotateDuration + travelDuration
        )
    }

    public func fadeOut() {
        animationGeneration += 1
        withAnimation(.easeOut(duration: 0.18)) {
            opacity = 0
        }

        let generation = animationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.animationGeneration == generation else { return }

            self.state = nil
            self.isHolding = false
            self.isWorking = false
            self.terminalTailAngleDegrees = 0
            self.isCursorDragging = false
            self.isLabelEditing = false
            self.draftText = ""
            self.draftTextHeight = Self.inlineEditorMinimumTextHeight
            self.viewportOrigin = .zero
            self.viewportSize = .zero
            self.labelLayoutChanged?()
            self.labelEditingChanged?(false)
        }
    }

    public func setSelected(_ isSelected: Bool) {
        guard self.isSelected != isSelected else { return }

        self.isSelected = isSelected
    }

    public func dismiss() {
        guard let state else { return }

        dismissed?(state.id)
    }

    /// Reports a user drag of the cursor at a global AppKit screen point; the
    /// controller owning the panel converts it to overlay coordinates and calls
    /// `setPosition`.
    public func reportCursorDrag(at globalPoint: CGPoint) {
        guard isHolding else { return }

        isCursorDragging = true
        cursorDragged?(globalPoint)
    }

    public func endCursorDrag() {
        isCursorDragging = false
    }

    /// Moves the holding cursor directly to a point (top-left-origin screen-local
    /// coordinates), bypassing travel animation — used while the user drags it.
    public func setPosition(_ point: CGPoint) {
        animationGeneration += 1
        position = point
        destination = point
        isHolding = true
    }

    public func select() {
        guard let state else { return }

        selected?(state.id)
    }

    public func beginInlineInput() {
        guard let state,
              state.taskID != nil,
              !isLabelEditing else {
            select()
            return
        }

        selected?(state.id)
        draftText = ""
        draftTextHeight = Self.inlineEditorMinimumTextHeight
        isLabelEditing = true
        labelLayoutChanged?()
        labelEditingChanged?(true)
    }

    public func cancelInlineInput() {
        guard isLabelEditing || !draftText.isEmpty else { return }

        draftText = ""
        draftTextHeight = Self.inlineEditorMinimumTextHeight
        isLabelEditing = false
        labelLayoutChanged?()
        labelEditingChanged?(false)
    }

    public func closeInlineInputIfIdle() {
        guard isLabelEditing,
              draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        cancelInlineInput()
    }

    public func submitInlineInput() {
        guard let state else { return }

        let trimmedText = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty,
              let taskID = state.taskID else {
            cancelInlineInput()
            return
        }

        draftText = ""
        draftTextHeight = Self.inlineEditorMinimumTextHeight
        isLabelEditing = false
        labelLayoutChanged?()
        labelEditingChanged?(false)
        followUpSubmitted?(state.id, taskID, trimmedText)
    }

    public func updateDraftTextHeight(_ height: CGFloat) {
        let clamped = min(max(height, Self.inlineEditorMinimumTextHeight), Self.inlineEditorMaximumTextHeight)
        guard abs(draftTextHeight - clamped) > 0.5 else { return }

        draftTextHeight = clamped
        labelLayoutChanged?()
    }

    private func finishTravelAfterDelay(
        generation: Int,
        finalPosition: CGPoint,
        delay: TimeInterval = UserQuerySpawnOverlayViewModel.travelDuration
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.animationGeneration == generation else { return }

            self.position = finalPosition
            self.isHolding = true
            self.playTerminalTailAnimation(generation: generation)
            if var state = self.state, state.phase == .traveling || state.phase == .notchCue {
                state.phase = .holding
                state.updatedAt = Date()
                self.state = state
            }
            self.travelCompleted?()
        }
    }

    private func playTerminalTailAnimation(generation: Int) {
        isWorking = false
        terminalTailAngleDegrees = 0

        for frame in Self.terminalTailAnimationFrames {
            DispatchQueue.main.asyncAfter(deadline: .now() + frame.delay) { [weak self] in
                guard let self,
                      self.animationGeneration == generation,
                      self.isHolding else {
                    return
                }

                withAnimation(.easeInOut(duration: Self.terminalTailFrameDuration)) {
                    self.terminalTailAngleDegrees = frame.angleDegrees
                }
            }
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.terminalTailAnimationDuration
        ) { [weak self] in
            guard let self,
                  self.animationGeneration == generation,
                  self.isHolding else {
                return
            }

            withAnimation(.easeOut(duration: 0.12)) {
                self.terminalTailAngleDegrees = 0
            }
            if self.isAwaitingResponse {
                self.playTerminalTailAnimation(generation: generation)
            } else {
                self.isWorking = true
            }
        }
    }

    private func distance(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private func point(
        _ point: CGPoint,
        offsetBy offset: CGSize,
        labelSize: CGSize,
        fitsIn screenSize: CGSize,
        margin: CGFloat
    ) -> Bool {
        let rect = CGRect(
            x: point.x + offset.width - labelSize.width / 2,
            y: point.y + offset.height - labelSize.height / 2,
            width: labelSize.width,
            height: labelSize.height
        )
        return rect.minX >= margin &&
            rect.minY >= margin &&
            rect.maxX <= screenSize.width - margin &&
            rect.maxY <= screenSize.height - margin
    }

    private func clampedOffset(
        _ offset: CGSize,
        from point: CGPoint,
        labelSize: CGSize,
        in screenSize: CGSize,
        margin: CGFloat
    ) -> CGSize {
        guard screenSize.width > 0, screenSize.height > 0 else { return offset }

        let proposedCenter = CGPoint(
            x: point.x + offset.width,
            y: point.y + offset.height
        )
        let minX = margin + labelSize.width / 2
        let maxX = screenSize.width - margin - labelSize.width / 2
        let minY = margin + labelSize.height / 2
        let maxY = screenSize.height - margin - labelSize.height / 2
        let clampedCenter = CGPoint(
            x: Self.clamp(proposedCenter.x, minimum: minX, maximum: maxX, fallback: screenSize.width / 2),
            y: Self.clamp(proposedCenter.y, minimum: minY, maximum: maxY, fallback: screenSize.height / 2)
        )
        return CGSize(
            width: clampedCenter.x - point.x,
            height: clampedCenter.y - point.y
        )
    }

    private static func clamp(
        _ value: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat,
        fallback: CGFloat
    ) -> CGFloat {
        guard minimum <= maximum else { return fallback }

        return min(max(value, minimum), maximum)
    }

    public static let travelDuration: TimeInterval = 0.82
    public static let terminalTailAnimationDuration: TimeInterval = 0.70
    private static let terminalTailFrameDuration: TimeInterval = 0.08
    private static let terminalTailAnimationFrames: [(delay: TimeInterval, angleDegrees: Double)] = [
        (0.0875, -14),
        (0.2625, -7),
        (0.35, 0),
        (0.4375, 14),
        (0.6125, 7),
        (0.70, 0)
    ]
    fileprivate static let cursorVisualFrameSize = CGSize(width: 84, height: 112)
    private static let screenMargin: CGFloat = 20
    private static let contentOverdrawPadding: CGFloat = 10
    private static let panelOverdrawPadding: CGFloat = 28
    fileprivate static let labelHorizontalPadding: CGFloat = 10
    fileprivate static let labelVerticalPadding: CGFloat = 3
    fileprivate static let collapsedLabelContentWidth: CGFloat = 240
    fileprivate static let collapsedLabelMinimumHeight: CGFloat = 48
    fileprivate static let collapsedLabelBottomGap: CGFloat = 22
    fileprivate static let inlineEditorContentWidth: CGFloat = 480
    fileprivate static let inlineEditorInputHeight: CGFloat = 64
    fileprivate static let inlineEditorHorizontalPadding: CGFloat = 16
    fileprivate static let inlineEditorVerticalPadding: CGFloat = 14
    fileprivate static let inlineEditorSpacing: CGFloat = 12
    fileprivate static let labelFontSize: CGFloat = 12
    public static let inlineEditorMinimumTextHeight: CGFloat = 14
    public static let inlineEditorMaximumTextHeight: CGFloat = 44
    fileprivate static let collapsedHaloSize: CGFloat = 40
    fileprivate static let collapsedHaloVerticalOffset: CGFloat = 12
    private static let travelAnimation = Animation.timingCurve(0.45, 0.05, 0.3, 1, duration: travelDuration)

    private static func collapsedLabelSize(for text: String) -> CGSize {
        displayLabelSize(for: text, maximumWidth: collapsedLabelContentWidth)
    }

    private static func displayLabelSize(for text: String, maximumWidth: CGFloat) -> CGSize {
        let contentSize = displayLabelContentSize(for: text, maximumWidth: maximumWidth)
        return CGSize(
            width: contentSize.width + Self.labelHorizontalPadding * 2,
            height: max(collapsedLabelMinimumHeight, contentSize.height + Self.labelVerticalPadding * 2)
        )
    }

    private static func inlineEditorLabelSize(for text: String) -> CGSize {
        CGSize(
            width: inlineEditorContentWidth + inlineEditorHorizontalPadding * 2,
            height: inlineEditorMessageHeight(for: text) +
                inlineEditorSpacing +
                inlineEditorInputHeight +
                inlineEditorVerticalPadding * 2
        )
    }

    private static func inlineEditorMessageHeight(for text: String) -> CGFloat {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return 20 }

        let font = NSFont.systemFont(ofSize: labelFontSize, weight: .medium)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.alignment = .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle
        ]
        let rect = (trimmedText as NSString).boundingRect(
            with: CGSize(
                width: inlineEditorContentWidth,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        return max(ceil(rect.height), ceil(lineHeight))
    }

    fileprivate static func displayLabelContentSize(
        for text: String,
        maximumWidth: CGFloat
    ) -> CGSize {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return CGSize(width: 1, height: 14)
        }

        let font = NSFont.systemFont(ofSize: labelFontSize, weight: .medium)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.alignment = .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle
        ]
        let boundingRect = (trimmedText as NSString).boundingRect(
            with: CGSize(
                width: maximumWidth,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let singleLineWidth = ceil((trimmedText as NSString).size(withAttributes: attributes).width)
        return CGSize(
            width: min(max(ceil(boundingRect.width), min(singleLineWidth, maximumWidth)), maximumWidth),
            height: max(ceil(boundingRect.height), ceil(lineHeight))
        )
    }
}

public struct UserQuerySpawnOverlayView: View {
    @ObservedObject private var viewModel: UserQuerySpawnOverlayViewModel
    @State private var haloPulseActive = false
    @State private var isLabelHovered = false
    @State private var isDismissButtonHovered = false

    public init(viewModel: UserQuerySpawnOverlayViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let state = viewModel.state {
                    spawnSurface(state: state, screenSize: viewModel.hasScreenSize ? viewModel.screenSize : proxy.size)
                        .frame(
                            width: viewModel.hasViewportSize ? viewModel.viewportSize.width : proxy.size.width,
                            height: viewModel.hasViewportSize ? viewModel.viewportSize.height : proxy.size.height,
                            alignment: .topLeading
                        )
                        .opacity(viewModel.opacity)
                }
            }
        }
        .ignoresSafeArea()
    }

    private func spawnSurface(
        state: UserQuerySpawnState,
        screenSize: CGSize
    ) -> some View {
        ZStack(alignment: .topLeading) {
            if viewModel.isWorking {
                Circle()
                    .stroke(accentColor(for: state.accentIndex), lineWidth: 1.5)
                    .frame(
                        width: UserQuerySpawnOverlayViewModel.collapsedHaloSize,
                        height: UserQuerySpawnOverlayViewModel.collapsedHaloSize
                    )
                    .scaleEffect(haloPulseScale)
                    .opacity(haloPulseOpacity)
                    .position(viewModel.localHaloCenter)
                    .animation(
                        .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                        value: haloPulseActive
                    )
                    .onAppear {
                        haloPulseActive = true
                    }
                    .onDisappear {
                        haloPulseActive = false
                    }
            }

            cursor(state: state)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .gesture(cursorDragGesture)
                .position(viewModel.localCursorCenter)

            if viewModel.isHolding {
                stationaryLabel(state: state)
                    .position(viewModel.localLabelCenter(in: screenSize))
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.select()
        }
    }

    private func cursor(state: UserQuerySpawnState) -> some View {
        SpawnPointerShape()
            .fill(accentColor(for: state.accentIndex))
            .overlay {
                SpawnPointerShape()
                    .stroke(Color.white.opacity(0.92), lineWidth: 1.5)
            }
            .shadow(color: Color.black.opacity(0.34), radius: 4, x: 0, y: 2)
            .frame(width: 28, height: 28)
            .rotationEffect(.degrees(cursorAngleDegrees + 50))
            .rotationEffect(.degrees(viewModel.terminalTailAngleDegrees))
            .scaleEffect(viewModel.isWorking ? holdingCursorScale : 1)
            .animation(
                .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                value: haloPulseActive
            )
    }

    private func stationaryLabel(state: UserQuerySpawnState) -> some View {
        Group {
            if viewModel.isLabelEditing {
                inlineLabelEditor(state: state)
            } else {
                displayLabel(state: state)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(accentColor(for: state.accentIndex))
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            viewModel.beginInlineInput()
        }
        .onHover { hovering in
            isLabelHovered = hovering
        }
        .overlay(alignment: .topTrailing) {
            dismissButton
                .offset(x: 6, y: -6)
                .opacity(showsDismissButton ? 1 : 0)
                .allowsHitTesting(showsDismissButton)
                .onHover { hovering in
                    isDismissButtonHovered = hovering
                }
                .animation(.easeOut(duration: 0.12), value: showsDismissButton)
        }
    }

    private var showsDismissButton: Bool {
        isLabelHovered || isDismissButtonHovered
    }

    private var dismissButton: some View {
        Button {
            viewModel.dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background {
                    Circle()
                        .fill(Color.black.opacity(0.45))
                }
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.35), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    /// Lets the user grab the cursor and reposition it; gesture coordinates are
    /// unreliable because the panel follows the cursor, so the real mouse
    /// location is reported instead.
    private var cursorDragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { _ in
                viewModel.reportCursorDrag(at: NSEvent.mouseLocation)
            }
            .onEnded { _ in
                viewModel.endCursorDrag()
            }
    }

    private func displayLabel(state: UserQuerySpawnState) -> some View {
        Text(state.label)
        .font(.system(size: UserQuerySpawnOverlayViewModel.labelFontSize, weight: .medium))
        .foregroundStyle(.white)
        .multilineTextAlignment(.leading)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
        .frame(
            width: viewModel.displayLabelContentWidth,
            alignment: .leading
        )
        .padding(.horizontal, UserQuerySpawnOverlayViewModel.labelHorizontalPadding)
        .padding(.vertical, UserQuerySpawnOverlayViewModel.labelVerticalPadding)
    }

    private func inlineLabelEditor(state: UserQuerySpawnState) -> some View {
        VStack(alignment: .leading, spacing: UserQuerySpawnOverlayViewModel.inlineEditorSpacing) {
            Text(state.label)
                .font(.system(size: UserQuerySpawnOverlayViewModel.labelFontSize, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(
                    width: UserQuerySpawnOverlayViewModel.inlineEditorContentWidth,
                    alignment: .leading
                )

            SpawnLabelInlineTextInput(
                text: $viewModel.draftText,
                isActive: viewModel.isLabelEditing,
                textHeightChanged: viewModel.updateDraftTextHeight,
                submit: viewModel.submitInlineInput,
                cancel: viewModel.cancelInlineInput,
                focusLost: viewModel.closeInlineInputIfIdle
            )
            .frame(
                width: UserQuerySpawnOverlayViewModel.inlineEditorContentWidth - 24,
                height: max(viewModel.draftTextHeight, UserQuerySpawnOverlayViewModel.inlineEditorMinimumTextHeight),
                alignment: .topLeading
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(
                width: UserQuerySpawnOverlayViewModel.inlineEditorContentWidth,
                height: UserQuerySpawnOverlayViewModel.inlineEditorInputHeight,
                alignment: .topLeading
            )
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(inputAccentColor(for: state.accentIndex))
            }
        }
        .frame(
            width: UserQuerySpawnOverlayViewModel.inlineEditorContentWidth,
            alignment: .center
        )
        .padding(.horizontal, UserQuerySpawnOverlayViewModel.inlineEditorHorizontalPadding)
        .padding(.vertical, UserQuerySpawnOverlayViewModel.inlineEditorVerticalPadding)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .animation(.easeOut(duration: 0.12), value: viewModel.isLabelEditing)
    }

    private var cursorAngleDegrees: Double {
        viewModel.cursorAngleDegrees
    }

    private var haloPulseScale: CGFloat {
        haloPulseActive ? 1.15 : 1.0
    }

    private var haloPulseOpacity: Double {
        haloPulseActive ? 0.2 : 0.6
    }

    private var holdingCursorScale: CGFloat {
        haloPulseActive ? 1.08 : 1.0
    }

    private func accentColor(for index: Int) -> Color {
        Self.accentColors[UserQueryAccentPalette.normalizedIndex(index)]
    }

    private func inputAccentColor(for index: Int) -> Color {
        Self.inputAccentColors[UserQueryAccentPalette.normalizedIndex(index)]
    }

    private static let accentColors: [Color] = [
        Color(red: 0.114, green: 0.62, blue: 0.46),
        Color(red: 0.94, green: 0.62, blue: 0.15),
        Color(red: 0.83, green: 0.33, blue: 0.49),
        Color(red: 0.22, green: 0.54, blue: 0.87),
        Color(red: 0.5, green: 0.47, blue: 0.87),
        Color(red: 0.88, green: 0.35, blue: 0.28),
        Color(red: 0.24, green: 0.69, blue: 0.71),
        Color(red: 0.66, green: 0.34, blue: 0.79)
    ]

    private static let inputAccentColors: [Color] = [
        Color(red: 0.69, green: 0.87, blue: 0.81),
        Color(red: 0.98, green: 0.87, blue: 0.70),
        Color(red: 0.94, green: 0.77, blue: 0.82),
        Color(red: 0.73, green: 0.84, blue: 0.95),
        Color(red: 0.83, green: 0.81, blue: 0.95),
        Color(red: 0.96, green: 0.77, blue: 0.75),
        Color(red: 0.73, green: 0.89, blue: 0.90),
        Color(red: 0.88, green: 0.77, blue: 0.93)
    ]
}

private struct SpawnLabelInlineTextInput: NSViewRepresentable {
    @Binding var text: String
    let isActive: Bool
    let textHeightChanged: @MainActor (CGFloat) -> Void
    let submit: @MainActor () -> Void
    let cancel: @MainActor () -> Void
    let focusLost: @MainActor () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = SpawnLabelInlineTextView()
        textView.delegate = context.coordinator
        textView.shouldFocusWhenAttached = isActive
        textView.submit = {
            Task { @MainActor in
                submit()
            }
        }
        textView.cancel = {
            Task { @MainActor in
                cancel()
            }
        }
        textView.focusLost = {
            Task { @MainActor in
                focusLost()
            }
        }
        textView.string = text
        textView.insertionPointColor = NSColor.black.withAlphaComponent(0.72)
        SpawnLabelInlineTextStyle.apply(to: textView)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = CGSize(width: 0, height: UserQuerySpawnOverlayViewModel.inlineEditorMinimumTextHeight)
        textView.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        scrollView.documentView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? SpawnLabelInlineTextView else { return }

        textView.shouldFocusWhenAttached = isActive
        textView.submit = {
            Task { @MainActor in
                submit()
            }
        }
        textView.cancel = {
            Task { @MainActor in
                cancel()
            }
        }
        textView.focusLost = {
            Task { @MainActor in
                focusLost()
            }
        }
        SpawnLabelInlineTextStyle.apply(to: textView)

        if textView.string != text {
            textView.string = text
            SpawnLabelInlineTextStyle.apply(to: textView)
            textView.needsDisplay = true
        }

        DispatchQueue.main.async {
            context.coordinator.updateTextContainerWidth(for: textView, in: scrollView)
            context.coordinator.reportTextHeight(for: textView)

            if isActive, textView.window?.firstResponder !== textView {
                textView.focusIfNeeded()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SpawnLabelInlineTextInput

        init(parent: SpawnLabelInlineTextInput) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? SpawnLabelInlineTextView else { return }

            parent.text = textView.string
            SpawnLabelInlineTextStyle.apply(to: textView)
            textView.needsDisplay = true
            reportTextHeight(for: textView)
            textView.scrollRangeToVisible(textView.selectedRange())
        }

        func updateTextContainerWidth(
            for textView: NSTextView,
            in scrollView: NSScrollView
        ) {
            let width = max(1, scrollView.contentView.bounds.width)
            textView.textContainer?.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
            let documentHeight = max(
                UserQuerySpawnOverlayViewModel.inlineEditorMinimumTextHeight,
                measuredTextHeight(for: textView)
            )
            textView.frame = CGRect(x: 0, y: 0, width: width, height: documentHeight)
        }

        func reportTextHeight(for textView: NSTextView) {
            parent.textHeightChanged(measuredTextHeight(for: textView))
        }

        private func measuredTextHeight(for textView: NSTextView) -> CGFloat {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                return UserQuerySpawnOverlayViewModel.inlineEditorMinimumTextHeight
            }

            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            return ceil(max(
                UserQuerySpawnOverlayViewModel.inlineEditorMinimumTextHeight,
                usedRect.height
            ))
        }
    }
}

private final class SpawnLabelInlineTextView: NSTextView {
    var submit: (() -> Void)?
    var cancel: (() -> Void)?
    var focusLost: (() -> Void)?
    var shouldFocusWhenAttached = false

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfNeeded()
    }

    func focusIfNeeded() {
        guard shouldFocusWhenAttached else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.window?.makeFirstResponder(self)
        }
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign {
            focusLost?()
        }
        return didResign
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let isEscape = event.keyCode == 53
        let shouldInsertNewline = event.modifierFlags.contains(.shift)

        if isEscape {
            cancel?()
            return
        }

        if isReturn, !shouldInsertNewline {
            submit?()
            return
        }

        super.keyDown(with: event)
    }
}

@MainActor
private enum SpawnLabelInlineTextStyle {
    static var font: NSFont {
        NSFont.systemFont(ofSize: UserQuerySpawnOverlayViewModel.labelFontSize, weight: .medium)
    }

    static func apply(to textView: NSTextView) {
        let textAttributes = attributes(color: NSColor.black.withAlphaComponent(0.68), font: font)
        textView.font = font
        textView.textColor = NSColor.black.withAlphaComponent(0.68)
        textView.alignment = .left
        textView.typingAttributes = textAttributes

        let textRange = NSRange(location: 0, length: textView.string.utf16.count)
        guard textRange.length > 0 else { return }

        textView.textStorage?.setAttributes(textAttributes, range: textRange)
    }

    static func attributes(
        color: NSColor,
        font: NSFont
    ) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        paragraphStyle.lineBreakMode = .byWordWrapping
        return [
            .foregroundColor: color,
            .font: font,
            .ligature: 0,
            .paragraphStyle: paragraphStyle
        ]
    }
}

private struct SpawnPointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        path.move(to: svgPoint(x: 83.086, y: 5.6406, width: w, height: h))
        path.addLine(to: svgPoint(x: 10.453, y: 34.6836, width: w, height: h))
        path.addCurve(
            to: svgPoint(x: 11.13269, y: 51.0276, width: w, height: h),
            control1: svgPoint(x: 2.8514, y: 37.7227, width: w, height: h),
            control2: svgPoint(x: 3.3085, y: 48.6326, width: w, height: h)
        )
        path.addLine(to: svgPoint(x: 35.69469, y: 58.5471, width: w, height: h))
        path.addCurve(
            to: svgPoint(x: 41.44859, y: 64.301, width: w, height: h),
            control1: svgPoint(x: 38.44859, y: 59.39085, width: w, height: h),
            control2: svgPoint(x: 40.60489, y: 61.5471, width: w, height: h)
        )
        path.addLine(to: svgPoint(x: 48.96809, y: 88.863, width: w, height: h))
        path.addCurve(
            to: svgPoint(x: 65.31209, y: 89.54269, width: w, height: h),
            control1: svgPoint(x: 51.36649, y: 96.6911, width: w, height: h),
            control2: svgPoint(x: 62.27309, y: 97.1442, width: w, height: h)
        )
        path.addLine(to: svgPoint(x: 94.35509, y: 16.90969, width: w, height: h))
        path.addCurve(
            to: svgPoint(x: 83.08209, y: 5.63669, width: w, height: h),
            control1: svgPoint(x: 97.18709, y: 9.83159, width: w, height: h),
            control2: svgPoint(x: 90.15979, y: 2.80769, width: w, height: h)
        )
        path.closeSubpath()

        return path
    }

    private func svgPoint(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGPoint {
        CGPoint(
            x: x / 100 * width,
            y: y / 100 * height
        )
    }
}
