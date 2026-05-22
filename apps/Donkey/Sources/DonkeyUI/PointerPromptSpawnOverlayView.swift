import AppKit
import DonkeyContracts
import SwiftUI

@MainActor
public final class PointerPromptSpawnOverlayViewModel: ObservableObject {
    public let objectID = UUID().uuidString
    @Published public private(set) var state: PointerPromptSpawnState?
    @Published public private(set) var position: CGPoint = .zero
    @Published public private(set) var destination: CGPoint = .zero
    @Published public private(set) var screenSize: CGSize = .zero
    @Published public private(set) var viewportOrigin: CGPoint = .zero
    @Published public private(set) var viewportSize: CGSize = .zero
    @Published public private(set) var opacity: Double = 0
    @Published public private(set) var isHolding = false
    @Published public private(set) var isSelected = false
    @Published public private(set) var isLabelHovered = false
    @Published public private(set) var isLabelEditing = false
    @Published public var draftText = ""
    @Published public private(set) var draftTextHeight: CGFloat = PointerPromptSpawnOverlayViewModel.inlineEditorMinimumTextHeight

    public var labelLayoutChanged: (() -> Void)?
    public var labelEditingChanged: ((Bool) -> Void)?
    public var followUpSubmitted: ((String, String, String) -> Void)?
    public var selected: ((String) -> Void)?
    public var travelCompleted: (() -> Void)?

    private var animationGeneration = 0

    public init() {}

    public var hitTestFrame: CGRect {
        guard state != nil, isHolding else { return .null }

        return visualFrame(at: position, includesLabel: true)
    }

    public var localHitTestFrame: CGRect {
        guard !hitTestFrame.isNull else { return .null }

        return hitTestFrame.offsetBy(dx: -viewportOrigin.x, dy: -viewportOrigin.y)
    }

    public var visualFrame: CGRect {
        guard state != nil else { return .null }

        return visualFrame(at: position, includesLabel: isHolding)
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
        isLabelEditing || !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var hasScreenSize: Bool {
        screenSize.width > 0 && screenSize.height > 0
    }

    public var hasViewportSize: Bool {
        viewportSize.width > 0 && viewportSize.height > 0
    }

    public func cursorOnlyVisualFrame(at point: CGPoint) -> CGRect {
        CGRect(
            x: point.x - Self.cursorVisualFrameSize.width / 2,
            y: point.y - Self.cursorVisualFrameSize.height / 2,
            width: Self.cursorVisualFrameSize.width,
            height: Self.cursorVisualFrameSize.height
        )
    }

    public func updateViewport(origin: CGPoint, size: CGSize) {
        viewportOrigin = origin
        viewportSize = size
    }

    private func visualFrame(
        at point: CGPoint,
        includesLabel: Bool
    ) -> CGRect {
        var frame = cursorOnlyVisualFrame(at: point)
        guard includesLabel else { return frame }

        let labelSize = labelSize()
        let offset = labelOffset(for: point, in: screenSize)
        let origin = CGPoint(
            x: point.x + offset.width - labelSize.width / 2,
            y: point.y + offset.height - labelSize.height / 2
        )
        frame = frame.union(CGRect(origin: origin, size: labelSize))
        return frame.insetBy(dx: -10, dy: -10)
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
        labelOffset(for: position, in: screenSize)
    }

    private func labelOffset(
        for cursorPosition: CGPoint,
        in screenSize: CGSize
    ) -> CGSize {
        let labelSize = labelSize()
        let margin: CGFloat = 20
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
        return belowOffset
    }

    private func labelSize() -> CGSize {
        if isLabelEditing {
            return Self.inlineEditorLabelSize(for: state?.label ?? "")
        }
        guard isLabelHovered else { return Self.collapsedLabelSize }

        return Self.expandedCollapsedLabelSize(for: state?.label ?? "")
    }

    public func show(
        state: PointerPromptSpawnState,
        origin: CGPoint,
        destination: CGPoint,
        screenSize: CGSize
    ) {
        animationGeneration += 1
        self.state = state
        self.position = origin
        self.destination = destination
        self.screenSize = screenSize
        self.opacity = 0
        self.isHolding = false
        self.viewportOrigin = .zero
        self.viewportSize = .zero
        self.isLabelHovered = false
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
            self.finishTravelAfterDelay(generation: generation, finalPosition: destination)
        }
    }

    public func update(
        state: PointerPromptSpawnState,
        destination: CGPoint,
        screenSize: CGSize
    ) {
        guard self.state?.id == state.id else {
            show(state: state, origin: position, destination: destination, screenSize: screenSize)
            return
        }

        self.state = state
        self.screenSize = screenSize
        guard state.phase != .fading else {
            fadeOut()
            return
        }

        guard !freezesMovement else { return }
        guard distance(from: self.destination, to: destination) > 1 else { return }

        animationGeneration += 1
        let generation = animationGeneration
        self.destination = destination
        self.isHolding = false
        withAnimation(.easeOut(duration: 0.12)) {
            self.opacity = 1
        }
        finishTravelAfterDelay(generation: generation, finalPosition: destination)
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
            self.isLabelHovered = false
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

    public func setLabelHovered(_ isHovered: Bool) {
        guard !isLabelEditing else { return }

        let shouldExpand = isHovered && Self.collapsedLabelNeedsExpansion(state?.label ?? "")
        guard isLabelHovered != shouldExpand else { return }

        isLabelHovered = shouldExpand
        labelLayoutChanged?()
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
        isLabelHovered = false
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

    private func finishTravelAfterDelay(generation: Int, finalPosition: CGPoint) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.travelDuration) { [weak self] in
            guard let self, self.animationGeneration == generation else { return }

            self.position = finalPosition
            self.isHolding = true
            if var state = self.state, state.phase == .traveling || state.phase == .notchCue {
                state.phase = .holding
                state.updatedAt = Date()
                self.state = state
            }
            self.travelCompleted?()
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

    public static let travelDuration: TimeInterval = 0.82
    fileprivate static let cursorVisualFrameSize = CGSize(width: 84, height: 112)
    fileprivate static let labelHorizontalPadding: CGFloat = 10
    fileprivate static let collapsedLabelContentWidth: CGFloat = 240
    fileprivate static let collapsedLabelSize = CGSize(width: 260, height: 48)
    fileprivate static let collapsedLabelBottomGap: CGFloat = 22
    fileprivate static let expandedCollapsedLabelWidth: CGFloat = 480
    fileprivate static let inlineEditorContentWidth: CGFloat = expandedCollapsedLabelWidth
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

    private static func expandedCollapsedLabelSize(for text: String) -> CGSize {
        let characterCount = max(Array(text).count, 1)
        let approximateCharactersPerLine = 44
        let lineCount = max(1, Int(ceil(Double(characterCount) / Double(approximateCharactersPerLine))))
        let height = CGFloat(lineCount) * 14 + 12
        return CGSize(
            width: expandedCollapsedLabelWidth + Self.labelHorizontalPadding * 2,
            height: max(collapsedLabelSize.height, height)
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
        return min(max(ceil(rect.height), lineHeight), ceil(lineHeight * 3))
    }

    private static func collapsedLabelNeedsExpansion(_ text: String) -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return false }

        let font = NSFont.systemFont(ofSize: labelFontSize, weight: .medium)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.alignment = .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle
        ]
        let singleLineWidth = ceil((trimmedText as NSString).size(withAttributes: attributes).width)
        let boundingRect = (trimmedText as NSString).boundingRect(
            with: CGSize(
                width: collapsedLabelContentWidth,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let maximumVisibleHeight = ceil(lineHeight * 2 + 1)

        return singleLineWidth > collapsedLabelContentWidth * 2 ||
            ceil(boundingRect.height) > maximumVisibleHeight
    }
}

public struct PointerPromptSpawnOverlayView: View {
    @ObservedObject private var viewModel: PointerPromptSpawnOverlayViewModel
    @State private var haloPulseActive = false

    public init(viewModel: PointerPromptSpawnOverlayViewModel) {
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
        state: PointerPromptSpawnState,
        screenSize: CGSize
    ) -> some View {
        ZStack(alignment: .topLeading) {
            if viewModel.isHolding {
                Circle()
                    .stroke(accentColor(for: state.accentIndex), lineWidth: 1.5)
                    .frame(
                        width: PointerPromptSpawnOverlayViewModel.collapsedHaloSize,
                        height: PointerPromptSpawnOverlayViewModel.collapsedHaloSize
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

    private func cursor(state: PointerPromptSpawnState) -> some View {
        SpawnPointerShape()
            .fill(accentColor(for: state.accentIndex))
            .overlay {
                SpawnPointerShape()
                    .stroke(Color.white.opacity(0.92), lineWidth: 1.5)
            }
            .shadow(color: Color.black.opacity(0.34), radius: 4, x: 0, y: 2)
            .frame(width: 28, height: 28)
            .rotationEffect(.degrees(cursorAngleDegrees + 50))
            .scaleEffect(viewModel.isHolding ? holdingCursorScale : 1)
            .animation(
                .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                value: haloPulseActive
            )
    }

    private func stationaryLabel(state: PointerPromptSpawnState) -> some View {
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
        .onHover { isHovered in
            viewModel.setLabelHovered(isHovered)
        }
    }

    private func displayLabel(state: PointerPromptSpawnState) -> some View {
        TypewriterText(
            text: state.label,
            identity: PointerPromptSpawnGeometry.labelTypingIdentity(
                spawnID: state.id,
                label: state.label
            )
        )
        .font(.system(size: PointerPromptSpawnOverlayViewModel.labelFontSize, weight: .medium))
        .foregroundStyle(.white)
        .multilineTextAlignment(.leading)
        .lineLimit(viewModel.isLabelHovered ? nil : 2)
        .truncationMode(.tail)
        .frame(
            maxWidth: viewModel.isLabelHovered ? PointerPromptSpawnOverlayViewModel.expandedCollapsedLabelWidth : PointerPromptSpawnOverlayViewModel.collapsedLabelContentWidth,
            alignment: .leading
        )
        .padding(.horizontal, PointerPromptSpawnOverlayViewModel.labelHorizontalPadding)
        .padding(.vertical, 3)
    }

    private func inlineLabelEditor(state: PointerPromptSpawnState) -> some View {
        VStack(alignment: .leading, spacing: PointerPromptSpawnOverlayViewModel.inlineEditorSpacing) {
            Text(state.label)
                .font(.system(size: PointerPromptSpawnOverlayViewModel.labelFontSize, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(
                    width: PointerPromptSpawnOverlayViewModel.inlineEditorContentWidth,
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
                width: PointerPromptSpawnOverlayViewModel.inlineEditorContentWidth - 24,
                height: max(viewModel.draftTextHeight, PointerPromptSpawnOverlayViewModel.inlineEditorMinimumTextHeight),
                alignment: .topLeading
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(
                width: PointerPromptSpawnOverlayViewModel.inlineEditorContentWidth,
                height: PointerPromptSpawnOverlayViewModel.inlineEditorInputHeight,
                alignment: .topLeading
            )
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(inputAccentColor(for: state.accentIndex))
            }
        }
        .frame(
            width: PointerPromptSpawnOverlayViewModel.inlineEditorContentWidth,
            alignment: .center
        )
        .padding(.horizontal, PointerPromptSpawnOverlayViewModel.inlineEditorHorizontalPadding)
        .padding(.vertical, PointerPromptSpawnOverlayViewModel.inlineEditorVerticalPadding)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .animation(.easeOut(duration: 0.12), value: viewModel.isLabelEditing)
    }

    private var cursorAngleDegrees: Double {
        PointerPromptSpawnGeometry.angleDegrees(
            from: viewModel.position,
            to: viewModel.destination
        )
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
        Self.accentColors[((index % Self.accentColors.count) + Self.accentColors.count) % Self.accentColors.count]
    }

    private func inputAccentColor(for index: Int) -> Color {
        Self.inputAccentColors[((index % Self.inputAccentColors.count) + Self.inputAccentColors.count) % Self.inputAccentColors.count]
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

private struct TypewriterText: View {
    let text: String
    let identity: String
    @State private var visibleText = ""
    @State private var generation = UUID()

    var body: some View {
        Text(visibleText)
            .onAppear {
                restart()
            }
            .onChange(of: identity) {
                restart()
            }
    }

    private func restart() {
        let currentGeneration = UUID()
        generation = currentGeneration
        visibleText = ""

        let characters = Array(text)
        guard !characters.isEmpty else { return }

        for index in characters.indices {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.026) {
                guard generation == currentGeneration else { return }

                visibleText = String(characters[...index])
            }
        }
    }
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
        textView.minSize = CGSize(width: 0, height: PointerPromptSpawnOverlayViewModel.inlineEditorMinimumTextHeight)
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
                PointerPromptSpawnOverlayViewModel.inlineEditorMinimumTextHeight,
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
                return PointerPromptSpawnOverlayViewModel.inlineEditorMinimumTextHeight
            }

            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            return ceil(max(
                PointerPromptSpawnOverlayViewModel.inlineEditorMinimumTextHeight,
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
        NSFont.systemFont(ofSize: PointerPromptSpawnOverlayViewModel.labelFontSize, weight: .medium)
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
