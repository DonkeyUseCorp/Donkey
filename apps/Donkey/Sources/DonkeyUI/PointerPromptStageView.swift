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
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .background(Color.clear)
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var promptContent: some View {
        if placement.placesContentOnLeft {
            HStack(alignment: .bottom, spacing: 16) {
                composer
                pointer
            }
        } else {
            HStack(alignment: .bottom, spacing: 16) {
                pointer
                composer
            }
        }
    }

    private var pointer: some View {
        AgentPointerView(
            placement: placement,
            theme: state.theme,
            isActive: state.isActive
        )
        .frame(width: 58, height: 68)
        .offset(y: placement.placesContentAbovePointer ? 20 : -22)
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
            submit: {
                intentSink?.handle(.messageSubmitted(text: messageText))
            }
        )
        .frame(width: 350, height: 142)
    }
}

private struct PointerPromptComposer: View {
    let state: PointerPromptState
    @Binding var messageText: String
    let addContext: @MainActor () -> Void
    let voiceInput: @MainActor () -> Void
    let submit: @MainActor () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 13) {
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
        .padding(.leading, 24)
        .padding(.trailing, 18)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 38, style: .continuous)
                .fill(Color(promptColor: state.theme.fill))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 38, style: .continuous)
                .stroke(Color(promptColor: state.theme.accent), lineWidth: 2.4)
        }
        .shadow(
            color: Color(promptColor: state.theme.accent).opacity(state.isActive ? 0.13 : 0.08),
            radius: state.isActive ? 12 : 8,
            x: 0,
            y: state.isActive ? 5 : 3
        )
        .onAppear(perform: focusIfActive)
        .onChange(of: state.isActive) { _, _ in
            focusIfActive()
        }
    }

    private func focusIfActive() {
        guard state.isActive else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isFocused = true
        }
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
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
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
        ZStack(alignment: .bottom) {
            if isActive {
                Ellipse()
                    .fill(Color(promptColor: theme.activeShadow))
                    .frame(width: 42, height: 13)
                    .blur(radius: 4)
                    .offset(y: 2)
            }

            AgentPointerShape()
                .fill(Color(promptColor: theme.pointerFill))
                .overlay {
                    AgentPointerShape()
                        .stroke(Color(promptColor: theme.accent), lineWidth: 2.3)
                }
                .shadow(
                    color: Color(promptColor: theme.accent).opacity(isActive ? 0.18 : 0.08),
                    radius: isActive ? 8 : 4,
                    x: 0,
                    y: isActive ? 4 : 2
                )
                .frame(width: 48, height: 58)
                .rotationEffect(rotation)
                .scaleEffect(x: placement.placesContentOnLeft ? -1 : 1, y: 1)
                .offset(y: -7)
        }
        .accessibilityHidden(true)
    }

    private var rotation: Angle {
        placement.placesContentAbovePointer ? .degrees(18) : .degrees(-14)
    }
}

private struct AgentPointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        path.move(to: CGPoint(x: w * 0.12, y: h * 0.04))
        path.addLine(to: CGPoint(x: w * 0.86, y: h * 0.55))
        path.addLine(to: CGPoint(x: w * 0.52, y: h * 0.62))
        path.addLine(to: CGPoint(x: w * 0.68, y: h * 0.95))
        path.addLine(to: CGPoint(x: w * 0.49, y: h * 1.0))
        path.addLine(to: CGPoint(x: w * 0.34, y: h * 0.69))
        path.addLine(to: CGPoint(x: w * 0.12, y: h * 0.88))
        path.closeSubpath()

        return path
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
