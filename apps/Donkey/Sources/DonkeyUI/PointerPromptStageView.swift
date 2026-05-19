import AppKit
import DonkeyContracts
import SwiftUI

public struct PointerPromptStageView: View {
    private static let rendersAgentPointer = false

    private let state: PointerPromptState
    @Binding private var messageText: String
    private let inputTextHeight: CGFloat
    private let isInputExpanded: Bool
    private let placement: PointerPromptPlacement
    private weak var intentSink: (any PointerPromptIntentSink)?

    public init(
        state: PointerPromptState,
        messageText: Binding<String>,
        inputTextHeight: CGFloat = PointerPromptLayout.composerInputTextMinimumHeight,
        isInputExpanded: Bool = false,
        placement: PointerPromptPlacement = .bottomRight,
        intentSink: any PointerPromptIntentSink
    ) {
        self.state = state
        self._messageText = messageText
        self.inputTextHeight = inputTextHeight
        self.isInputExpanded = isInputExpanded
        self.placement = placement
        self.intentSink = intentSink
    }

    public var body: some View {
        activeComposer
            .padding(.horizontal, PointerPromptLayout.stageHorizontalPadding)
            .padding(.vertical, PointerPromptLayout.stageVerticalPadding)
            .background(Color.clear)
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var pointerSlot: some View {
        if Self.rendersAgentPointer {
            pointer
        } else {
            hiddenPointerSlot
        }
    }

    private var hiddenPointerSlot: some View {
        Color.clear
            .frame(
                width: PointerPromptLayout.pointerSlotSize.width,
                height: PointerPromptLayout.pointerSlotSize.height
            )
            .accessibilityHidden(true)
    }

    private var pointer: some View {
        AgentPointerView(
            placement: placement,
            theme: state.theme,
            isActive: state.isActive
        )
        .frame(
            width: PointerPromptLayout.pointerSlotSize.width,
            height: PointerPromptLayout.pointerSlotSize.height
        )
    }

    private var composer: some View {
        PointerPromptComposer(
            state: state,
            messageText: $messageText,
            inputTextHeight: inputTextHeight,
            isInputExpanded: isInputExpanded,
            submit: {
                intentSink?.handle(.messageSubmitted(text: messageText))
            },
            inputTextHeightChanged: { height in
                intentSink?.handle(.inputTextHeightChanged(height))
            },
            inputExpansionChanged: { isExpanded in
                intentSink?.handle(.inputExpansionChanged(isExpanded))
            }
        )
        .frame(
            width: PointerPromptLayout.composerWidth,
            height: PointerPromptLayout.composerHeight(
                inputTextHeight: inputTextHeight,
                isExpanded: isInputExpanded
            )
        )
    }

    private var activeComposer: some View {
        composer
            .opacity(state.isActive ? 1 : 0)
            .allowsHitTesting(state.isActive)
            .accessibilityHidden(!state.isActive)
    }
}

private struct PointerPromptComposer: View {
    private static let rendersToolbarControls = false

    let state: PointerPromptState
    @Binding var messageText: String
    let inputTextHeight: CGFloat
    let isInputExpanded: Bool
    let submit: @MainActor () -> Void
    let inputTextHeightChanged: @MainActor (CGFloat) -> Void
    let inputExpansionChanged: @MainActor (Bool) -> Void

    var body: some View {
        promptSurface
        .frame(
            width: PointerPromptLayout.composerInputSurfaceWidth,
            height: PointerPromptLayout.composerInputHeight(
                inputTextHeight: inputTextHeight,
                isExpanded: isExpanded
            ),
            alignment: .topLeading
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var promptSurface: some View {
        if isExpanded {
            expandedPromptSurface
        } else {
            promptCapsule
        }
    }

    private var promptCapsule: some View {
        HStack(spacing: PointerPromptLayout.composerTextWaveformSpacing) {
            textInput
                .frame(width: PointerPromptLayout.composerWrappingTextWidth)

            VoiceWaveformView(levels: state.voiceWaveformLevels)
                .frame(
                    width: PointerPromptLayout.composerWaveformSize.width,
                    height: PointerPromptLayout.composerWaveformSize.height
                )
        }
        .padding(.leading, PointerPromptLayout.composerInputLeadingContentPadding)
        .padding(.trailing, PointerPromptLayout.composerInputTrailingContentPadding)
        .frame(
            width: PointerPromptLayout.composerInputSurfaceWidth,
            height: PointerPromptLayout.composerInputHeight(
                inputTextHeight: inputTextHeight,
                isExpanded: isExpanded
            )
        )
        .background {
            Capsule(style: .continuous)
                .fill(Color.black)
        }
        .overlay {
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.34), lineWidth: 1)
        }
        .shadow(
            color: Color.black.opacity(state.isActive ? 0.2 : 0.08),
            radius: state.isActive ? 12 : 6,
            x: 0,
            y: state.isActive ? 5 : 2
        )
        .accessibilityElement(children: .contain)
    }

    private var expandedPromptSurface: some View {
        VStack(spacing: 0) {
            textInput
                .frame(width: PointerPromptLayout.composerExpandedTextWidth)
                .padding(.top, PointerPromptLayout.composerExpandedTextTopPadding)
                .padding(.horizontal, PointerPromptLayout.composerExpandedTextHorizontalPadding)
                .frame(
                    width: PointerPromptLayout.composerInputSurfaceWidth,
                    height: expandedTextAreaHeight,
                    alignment: .top
                )

            promptToolbar
        }
        .frame(
            width: PointerPromptLayout.composerInputSurfaceWidth,
            height: PointerPromptLayout.composerInputHeight(
                inputTextHeight: inputTextHeight,
                isExpanded: isExpanded
            )
        )
        .background {
            RoundedRectangle(
                cornerRadius: PointerPromptLayout.composerCornerRadius,
                style: .continuous
            )
            .fill(Color.black)
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: PointerPromptLayout.composerCornerRadius,
                style: .continuous
            )
            .stroke(Color.white.opacity(0.28), lineWidth: 1)
        }
        .shadow(
            color: Color.black.opacity(state.isActive ? 0.2 : 0.08),
            radius: state.isActive ? 12 : 6,
            x: 0,
            y: state.isActive ? 5 : 2
        )
        .accessibilityElement(children: .contain)
    }

    private var promptToolbar: some View {
        HStack {
            if Self.rendersToolbarControls {
                toolbarControls
            }

            Spacer(minLength: 0)

            VoiceWaveformView(levels: state.voiceWaveformLevels)
                .frame(
                    width: PointerPromptLayout.composerWaveformSize.width,
                    height: PointerPromptLayout.composerWaveformSize.height
                )
        }
        .padding(.horizontal, PointerPromptLayout.composerExpandedTextHorizontalPadding)
        .frame(
            width: PointerPromptLayout.composerInputSurfaceWidth,
            height: PointerPromptLayout.composerExpandedToolbarHeight
        )
    }

    private var toolbarControls: some View {
        HStack(spacing: 12) {
            toolbarIcon(systemName: "plus")

            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 15, weight: .medium))

                Text("Default permissions")
                    .font(.system(size: 14, weight: .medium))

                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Color.white.opacity(0.6))
        }
    }

    private func toolbarIcon(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(Color.white.opacity(0.62))
            .frame(width: 24, height: 24)
    }

    private var textInput: some View {
        ComposerMultilineTextInput(
            text: $messageText,
            placeholder: state.promptText,
            isActive: state.isActive,
            textHeightChanged: inputTextHeightChanged,
            expansionChanged: inputExpansionChanged,
            submit: submit
        )
        .frame(maxWidth: .infinity)
        .frame(height: inputTextHeight)
    }

    private var expandedSurfaceHeight: CGFloat {
        PointerPromptLayout.composerInputHeight(inputTextHeight: inputTextHeight, isExpanded: true)
    }

    private var expandedTextAreaHeight: CGFloat {
        max(
            inputTextHeight + PointerPromptLayout.composerExpandedTextTopPadding,
            expandedSurfaceHeight - PointerPromptLayout.composerExpandedToolbarHeight
        )
    }

    private var isExpanded: Bool {
        isInputExpanded || messageText.contains("\n")
    }
}

private struct VoiceWaveformView: View {
    let levels: [Double]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(displayLevels.enumerated()), id: \.offset) { _, level in
                Capsule(style: .continuous)
                    .fill(Color.white)
                    .frame(
                        width: 4,
                        height: barHeight(for: level)
                    )
            }
        }
        .animation(.linear(duration: 0.08), value: displayLevels)
    }

    private var displayLevels: [Double] {
        let clampedLevels = levels.map { min(max($0, 0), 1) }
        guard clampedLevels.count >= 7 else {
            return PointerPromptState.defaultVoiceWaveformLevels
        }

        return Array(clampedLevels.suffix(7))
    }

    private func barHeight(for level: Double) -> CGFloat {
        5 + CGFloat(level) * 24
    }
}

private struct ComposerMultilineTextInput: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isActive: Bool
    let textHeightChanged: @MainActor (CGFloat) -> Void
    let expansionChanged: @MainActor (Bool) -> Void
    let submit: @MainActor () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.shouldFocusWhenAttached = isActive
        textView.placeholder = placeholder
        textView.submit = {
            Task { @MainActor in
                submit()
            }
        }
        textView.string = text
        textView.insertionPointColor = .white
        ComposerTextStyle.apply(to: textView)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = CGSize(
            width: 0,
            height: PointerPromptLayout.composerInputTextMinimumHeight
        )
        textView.maxSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = CGSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )
        scrollView.documentView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? ComposerTextView else { return }

        textView.shouldFocusWhenAttached = isActive
        textView.placeholder = placeholder
        textView.submit = {
            Task { @MainActor in
                submit()
            }
        }
        ComposerTextStyle.apply(to: textView)

        if textView.string != text {
            textView.string = text
            ComposerTextStyle.apply(to: textView)
            textView.needsDisplay = true
        }

        DispatchQueue.main.async {
            context.coordinator.updateTextContainerWidth(for: textView, in: scrollView)
            context.coordinator.reportTextHeight(for: textView)
            context.coordinator.reportExpansionState(for: textView)

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
        var parent: ComposerMultilineTextInput

        init(parent: ComposerMultilineTextInput) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ComposerTextView else { return }

            parent.text = textView.string
            textView.needsDisplay = true
            reportTextHeight(for: textView)
            reportExpansionState(for: textView)
            textView.scrollRangeToVisible(textView.selectedRange())
        }

        func updateTextContainerWidth(
            for textView: NSTextView,
            in scrollView: NSScrollView
        ) {
            let width = max(1, scrollView.contentView.bounds.width)
            let visibleHeight = max(
                PointerPromptLayout.composerInputTextMinimumHeight,
                scrollView.contentView.bounds.height
            )
            textView.textContainer?.containerSize = CGSize(
                width: width,
                height: .greatestFiniteMagnitude
            )

            let documentHeight = max(visibleHeight, measuredTextHeight(for: textView))
            textView.frame = CGRect(
                x: 0,
                y: 0,
                width: width,
                height: documentHeight
            )
        }

        func reportTextHeight(for textView: NSTextView) {
            let measuredHeight = measuredTextHeight(for: textView)
            let documentHeight = max(textView.frame.height, measuredHeight)
            if abs(textView.frame.height - documentHeight) > 0.5 {
                textView.setFrameSize(CGSize(width: textView.frame.width, height: documentHeight))
            }

            parent.textHeightChanged(measuredHeight)
        }

        func reportExpansionState(for textView: NSTextView) {
            let wrappedHeight = measuredTextHeight(
                for: textView.string,
                width: PointerPromptLayout.composerWrappingTextWidth
            )
            let shouldExpand = PointerPromptLayout.isComposerInputExpanded(
                inputTextHeight: wrappedHeight
            )
            parent.expansionChanged(shouldExpand)
        }

        private func measuredTextHeight(for textView: NSTextView) -> CGFloat {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                return PointerPromptLayout.composerInputTextMinimumHeight
            }

            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            return ceil(max(
                PointerPromptLayout.composerInputTextMinimumHeight,
                usedRect.height
            ))
        }

        private func measuredTextHeight(for string: String, width: CGFloat) -> CGFloat {
            guard !string.isEmpty else {
                return PointerPromptLayout.composerInputTextMinimumHeight
            }

            let textStorage = NSTextStorage(
                string: string,
                attributes: ComposerTextStyle.attributes(color: .white, font: ComposerTextStyle.font)
            )
            let layoutManager = NSLayoutManager()
            let textContainer = NSTextContainer(
                containerSize: CGSize(width: width, height: .greatestFiniteMagnitude)
            )
            textContainer.lineFragmentPadding = 0
            textContainer.widthTracksTextView = false
            textContainer.heightTracksTextView = false
            layoutManager.addTextContainer(textContainer)
            textStorage.addLayoutManager(layoutManager)
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)

            return ceil(max(
                PointerPromptLayout.composerInputTextMinimumHeight,
                usedRect.height
            ))
        }
    }
}

private final class ComposerTextView: NSTextView {
    var placeholder = ""
    var submit: (() -> Void)?
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

        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let shouldInsertNewline = event.modifierFlags.contains(.shift)

        if isReturn, !shouldInsertNewline {
            submit?()
            return
        }

        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard string.isEmpty, !placeholder.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.58),
            .font: font ?? ComposerTextStyle.font,
            .ligature: 0
        ]
        (placeholder as NSString).draw(at: .zero, withAttributes: attributes)
    }
}

@MainActor
private enum ComposerTextStyle {
    static var font: NSFont {
        NSFont.systemFont(ofSize: 16, weight: .light)
    }

    static func apply(to textView: NSTextView) {
        let textAttributes = attributes(color: .white, font: font)
        textView.font = font
        textView.textColor = .white
        textView.typingAttributes = textAttributes

        let textRange = NSRange(location: 0, length: textView.string.utf16.count)
        guard textRange.length > 0 else { return }

        textView.textStorage?.setAttributes(textAttributes, range: textRange)
    }

    static func attributes(
        color: NSColor,
        font: NSFont
    ) -> [NSAttributedString.Key: Any] {
        [
            .foregroundColor: color,
            .font: font,
            .ligature: 0
        ]
    }
}

private struct AgentPointerView: View {
    let placement: PointerPromptPlacement
    let theme: PointerPromptTheme
    let isActive: Bool

    var body: some View {
        ZStack(alignment: shapeAlignment) {
            if isActive {
                Ellipse()
                    .fill(Color(promptColor: theme.activeShadow))
                    .frame(width: 17, height: 5)
                    .blur(radius: 2)
                    .offset(y: 11)
            }

            AgentPointerShape()
                .fill(Color(promptColor: theme.pointerFill))
                .overlay {
                    AgentPointerShape()
                        .stroke(
                            Color(promptColor: theme.accent),
                            style: StrokeStyle(
                                lineWidth: PointerPromptLayout.pointerStrokeWidth,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                }
                .shadow(
                    color: Color(promptColor: theme.accent).opacity(isActive ? 0.12 : 0),
                    radius: isActive ? 3 : 0,
                    x: 0,
                    y: isActive ? 2 : 0
                )
                .frame(
                    width: PointerPromptLayout.pointerVisualSize.width,
                    height: PointerPromptLayout.pointerVisualSize.height
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: shapeAlignment)
        .accessibilityHidden(true)
    }

    private var shapeAlignment: Alignment {
        Alignment(
            horizontal: placement.placesContentOnLeft ? .leading : .trailing,
            vertical: .top
        )
    }
}

private struct AgentPointerShape: Shape {
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
            x: (100 - x) / 100 * width,
            y: y / 100 * height
        )
    }
}

private extension Color {
    init(promptColor: PointerPromptColor) {
        self.init(
            red: promptColor.red,
            green: promptColor.green,
            blue: promptColor.blue,
            opacity: promptColor.alpha
        )
    }
}
