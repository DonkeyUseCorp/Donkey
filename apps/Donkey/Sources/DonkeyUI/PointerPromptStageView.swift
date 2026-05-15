import AppKit
import DonkeyContracts
import SwiftUI

public struct PointerPromptStageView: View {
    private let state: PointerPromptState
    @Binding private var messageText: String
    private let inputTextHeight: CGFloat
    private let placement: PointerPromptPlacement
    private weak var intentSink: (any PointerPromptIntentSink)?

    public init(
        state: PointerPromptState,
        messageText: Binding<String>,
        inputTextHeight: CGFloat = PointerPromptLayout.composerInputTextMinimumHeight,
        placement: PointerPromptPlacement = .bottomRight,
        intentSink: any PointerPromptIntentSink
    ) {
        self.state = state
        self._messageText = messageText
        self.inputTextHeight = inputTextHeight
        self.placement = placement
        self.intentSink = intentSink
    }

    public var body: some View {
        promptContent
            .padding(.horizontal, PointerPromptLayout.stageHorizontalPadding)
            .padding(.vertical, PointerPromptLayout.stageVerticalPadding)
            .background(Color.clear)
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var promptContent: some View {
        if placement.placesContentOnLeft {
            HStack(alignment: .top, spacing: PointerPromptLayout.pointerComposerSpacing) {
                activeComposer
                pointer
            }
        } else {
            HStack(alignment: .top, spacing: PointerPromptLayout.pointerComposerSpacing) {
                pointer
                activeComposer
            }
        }
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
            voiceInput: {
                intentSink?.handle(.voiceInputRequested)
            },
            dismiss: {
                intentSink?.handle(.dismissed)
            },
            submit: {
                intentSink?.handle(.messageSubmitted(text: messageText))
            },
            inputTextHeightChanged: { height in
                intentSink?.handle(.inputTextHeightChanged(height))
            }
        )
        .frame(
            width: PointerPromptLayout.composerWidth,
            height: PointerPromptLayout.composerHeight(inputTextHeight: inputTextHeight)
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
    let state: PointerPromptState
    @Binding var messageText: String
    let inputTextHeight: CGFloat
    let voiceInput: @MainActor () -> Void
    let dismiss: @MainActor () -> Void
    let submit: @MainActor () -> Void
    let inputTextHeightChanged: @MainActor (CGFloat) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 12) {
                ComposerMultilineTextInput(
                    text: $messageText,
                    placeholder: state.promptText,
                    isActive: state.isActive,
                    textHeightChanged: inputTextHeightChanged,
                    submit: submit
                )
                    .frame(maxWidth: .infinity)
                    .frame(height: inputTextHeight)

                ComposerVoiceButton(action: voiceInput)
            }
            .frame(height: PointerPromptLayout.composerInputHeight(inputTextHeight: inputTextHeight))
            .padding(.leading, PointerPromptLayout.composerInputLeadingContentPadding)
            .padding(.trailing, PointerPromptLayout.composerInputTrailingContentPadding)
            .background {
                Capsule(style: .continuous)
                    .fill(Color(red: 0.13, green: 0.13, blue: 0.13))
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.07), lineWidth: 1)
                    }
            }
            .padding(.horizontal, PointerPromptLayout.composerInputHorizontalPadding)
            .padding(.top, PointerPromptLayout.composerTitlebarHeight)
            .padding(.bottom, PointerPromptLayout.composerBottomPadding)

            ComposerCloseControl(close: dismiss)
                .offset(
                    x: PointerPromptLayout.closeButtonInset,
                    y: PointerPromptLayout.closeButtonInset
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: PointerPromptLayout.composerCornerRadius, style: .continuous)
                .fill(Color(red: 0.08, green: 0.085, blue: 0.085))
        }
        .overlay {
            RoundedRectangle(cornerRadius: PointerPromptLayout.composerCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        }
        .shadow(
            color: Color.black.opacity(state.isActive ? 0.16 : 0.08),
            radius: state.isActive ? 14 : 8,
            x: 0,
            y: state.isActive ? 6 : 3
        )
        .controlSize(.regular)
    }
}

private struct ComposerMultilineTextInput: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isActive: Bool
    let textHeightChanged: @MainActor (CGFloat) -> Void
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
        textView.font = .systemFont(ofSize: 16)
        textView.textColor = .white
        textView.insertionPointColor = .white
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

        if textView.string != text {
            textView.string = text
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
        var parent: ComposerMultilineTextInput

        init(parent: ComposerMultilineTextInput) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ComposerTextView else { return }

            parent.text = textView.string
            textView.needsDisplay = true
            reportTextHeight(for: textView)
        }

        func updateTextContainerWidth(
            for textView: NSTextView,
            in scrollView: NSScrollView
        ) {
            let width = max(1, scrollView.contentView.bounds.width)
            let height = max(
                PointerPromptLayout.composerInputTextMinimumHeight,
                scrollView.contentView.bounds.height
            )
            textView.textContainer?.containerSize = CGSize(
                width: width,
                height: .greatestFiniteMagnitude
            )
            textView.frame = CGRect(
                x: 0,
                y: 0,
                width: width,
                height: height
            )
        }

        func reportTextHeight(for textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                return
            }

            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let measuredHeight = ceil(max(
                PointerPromptLayout.composerInputTextMinimumHeight,
                usedRect.height
            ))
            parent.textHeightChanged(measuredHeight)
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
            .font: font ?? NSFont.systemFont(ofSize: 16)
        ]
        (placeholder as NSString).draw(at: .zero, withAttributes: attributes)
    }
}

private struct ComposerCloseControl: View {
    let close: @MainActor () -> Void

    var body: some View {
        ComposerTrafficLight(
            color: Color.white.opacity(0.34),
            hoverColor: Color(nsColor: .systemRed),
            accessibilityLabel: "Close prompt",
            action: close
        )
    }
}

private struct ComposerTrafficLight: View {
    let color: Color
    var hoverColor: Color?
    var accessibilityLabel: String?
    var action: (@MainActor () -> Void)?
    @State private var isHovered = false

    @ViewBuilder
    var body: some View {
        if let action {
            Button(action: action) {
                trafficLight
            }
            .buttonStyle(.plain)
            .frame(
                width: PointerPromptLayout.closeButtonSize,
                height: PointerPromptLayout.closeButtonSize
            )
            .contentShape(Circle())
            .onHover { isHovered = $0 }
            .accessibilityLabel(accessibilityLabel ?? "Window control")
        } else {
            trafficLight
                .accessibilityHidden(true)
        }
    }

    private var trafficLight: some View {
        ZStack {
            Circle()
                .fill(isHovered ? hoverColor ?? color : color)
                .overlay {
                    Circle()
                        .stroke(Color.black.opacity(0.18), lineWidth: 0.5)
                }

            if action != nil {
                Image(systemName: "xmark")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.58))
                    .opacity(isHovered ? 1 : 0)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .frame(
            width: PointerPromptLayout.closeButtonSize,
            height: PointerPromptLayout.closeButtonSize
        )
    }
}

private struct ComposerVoiceButton: View {
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "waveform")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.black)
                .frame(
                    width: PointerPromptLayout.composerInputVoiceButtonSize,
                    height: PointerPromptLayout.composerInputVoiceButtonSize
                )
                .background {
                    Circle()
                        .fill(Color.white)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Voice input")
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
