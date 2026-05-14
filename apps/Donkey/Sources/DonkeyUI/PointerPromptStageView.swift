import DonkeyContracts
import SwiftUI

public struct PointerPromptStageView: View {
    private let state: PointerPromptState
    @Binding private var messageText: String
    private let placement: PointerPromptPlacement
    private weak var intentSink: (any PointerPromptIntentSink)?

    public init(
        state: PointerPromptState,
        messageText: Binding<String>,
        placement: PointerPromptPlacement = .bottomRight,
        intentSink: any PointerPromptIntentSink
    ) {
        self.state = state
        self._messageText = messageText
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
            addContext: {
                intentSink?.handle(.addContextRequested)
            },
            voiceInput: {
                intentSink?.handle(.voiceInputRequested)
            },
            dismiss: {
                intentSink?.handle(.dismissed)
            },
            submit: {
                intentSink?.handle(.messageSubmitted(text: messageText))
            }
        )
        .frame(
            width: PointerPromptLayout.composerSize.width,
            height: PointerPromptLayout.composerSize.height
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
    let addContext: @MainActor () -> Void
    let voiceInput: @MainActor () -> Void
    let dismiss: @MainActor () -> Void
    let submit: @MainActor () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 13) {
            HStack(spacing: 12) {
                ComposerCloseButton(action: dismiss)

                TextField(state.promptText, text: $messageText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(promptColor: state.theme.accent))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .focused($isFocused)
                    .onSubmit(submit)
                    .accessibilityLabel("Message for Donkey")
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)

            HStack(spacing: 10) {
                ComposerIconButton(
                    systemName: "plus",
                    label: "Add context",
                    theme: state.theme,
                    action: addContext
                )

                ComposerSignalButton(
                    level: state.leadingSignalLevel,
                    theme: state.theme,
                    action: voiceInput
                )

                Spacer(minLength: 12)

                ComposerIconButton(
                    systemName: "arrow.up",
                    label: "Send message",
                    theme: state.theme,
                    isProminent: true,
                    isDisabled: messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: submit
                )
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 18)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: PointerPromptLayout.composerCornerRadius, style: .continuous)
                .fill(Color(promptColor: state.theme.fill))
        }
        .overlay {
            RoundedRectangle(cornerRadius: PointerPromptLayout.composerCornerRadius, style: .continuous)
                .stroke(Color(promptColor: state.theme.accent), lineWidth: 1.4)
        }
        .shadow(
            color: Color(promptColor: state.theme.accent).opacity(state.isActive ? 0.13 : 0.08),
            radius: state.isActive ? 12 : 8,
            x: 0,
            y: state.isActive ? 5 : 3
        )
        .onAppear(perform: syncFocusWithActiveState)
        .onChange(of: state.isActive) { _, _ in
            syncFocusWithActiveState()
        }
    }

    private func syncFocusWithActiveState() {
        guard state.isActive else {
            isFocused = false
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isFocused = true
        }
    }
}

private struct ComposerCloseButton: View {
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: PointerPromptLayout.closeButtonSize, weight: .regular))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.white, Color.red)
                .frame(
                    width: PointerPromptLayout.closeButtonSize,
                    height: PointerPromptLayout.closeButtonSize
                )
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Close prompt")
    }
}

private struct ComposerIconButton: View {
    let systemName: String
    let label: String
    let theme: PointerPromptTheme
    var isProminent = false
    var isDisabled = false
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: isProminent ? 17 : 16, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .frame(width: 34, height: 34)
                .background {
                    Circle()
                        .fill(backgroundColor)
                }
                .overlay {
                    Circle()
                        .stroke(borderColor, lineWidth: isProminent ? 0 : 1.4)
                }
        }
        .buttonStyle(.borderless)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.38 : 1)
        .accessibilityLabel(label)
    }

    private var foregroundColor: Color {
        isProminent ? Color(promptColor: theme.fill) : Color(promptColor: theme.accent)
    }

    private var backgroundColor: Color {
        isProminent ? Color(promptColor: theme.accent) : Color.white.opacity(0.32)
    }

    private var borderColor: Color {
        Color(promptColor: theme.accent).opacity(0.38)
    }
}

private struct ComposerSignalButton: View {
    let level: SignalLevel
    let theme: PointerPromptTheme
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 5) {
                ForEach(Array(barHeights.enumerated()), id: \.offset) { _, height in
                    Capsule()
                        .fill(Color(promptColor: theme.accent).opacity(level == .idle ? 0.38 : 0.66))
                        .frame(width: 4.5, height: height)
                }
            }
            .frame(width: 44, height: 34)
            .background {
                Capsule()
                    .fill(Color.white.opacity(0.32))
            }
            .overlay {
                Capsule()
                    .stroke(Color(promptColor: theme.accent).opacity(0.28), lineWidth: 1.4)
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Voice input")
    }

    private var barHeights: [CGFloat] {
        switch level {
        case .idle:
            [7, 18, 10]
        case .ready:
            [8, 24, 15]
        case .thinking:
            [17, 26, 21]
        }
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
