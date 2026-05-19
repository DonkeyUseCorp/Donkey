import DonkeyContracts
import SwiftUI

public struct PointerPromptNotchStatusView: View {
    private let state: PointerPromptState
    private let updateState: PointerPromptUpdateState
    private let layout: PointerPromptNotchLayout
    private let surfaceWidth: CGFloat
    private let surfaceHeight: CGFloat
    private let isExpanded: Bool
    private let isCurrentTaskPaused: Bool
    @Binding private var commandText: String
    private let commandInputTextHeight: CGFloat
    private let isCommandInputExpanded: Bool
    private let accentIndex: Int
    private let commandSubmitted: @MainActor (String) -> Void
    private let commandInputTextHeightChanged: @MainActor (CGFloat) -> Void
    private let commandInputExpansionChanged: @MainActor (Bool) -> Void
    private let pauseRequested: @MainActor () -> Void
    private let resumeRequested: @MainActor () -> Void
    private let updateRequested: @MainActor () -> Void

    public init(
        state: PointerPromptState,
        updateState: PointerPromptUpdateState,
        layout: PointerPromptNotchLayout,
        surfaceWidth: CGFloat,
        surfaceHeight: CGFloat,
        isExpanded: Bool,
        isCurrentTaskPaused: Bool,
        commandText: Binding<String>,
        commandInputTextHeight: CGFloat,
        isCommandInputExpanded: Bool,
        accentIndex: Int,
        commandSubmitted: @escaping @MainActor (String) -> Void,
        commandInputTextHeightChanged: @escaping @MainActor (CGFloat) -> Void,
        commandInputExpansionChanged: @escaping @MainActor (Bool) -> Void,
        pauseRequested: @escaping @MainActor () -> Void,
        resumeRequested: @escaping @MainActor () -> Void,
        updateRequested: @escaping @MainActor () -> Void
    ) {
        self.state = state
        self.updateState = updateState
        self.layout = layout
        self.surfaceWidth = surfaceWidth
        self.surfaceHeight = surfaceHeight
        self.isExpanded = isExpanded
        self.isCurrentTaskPaused = isCurrentTaskPaused
        _commandText = commandText
        self.commandInputTextHeight = commandInputTextHeight
        self.isCommandInputExpanded = isCommandInputExpanded
        self.accentIndex = accentIndex
        self.commandSubmitted = commandSubmitted
        self.commandInputTextHeightChanged = commandInputTextHeightChanged
        self.commandInputExpansionChanged = commandInputExpansionChanged
        self.pauseRequested = pauseRequested
        self.resumeRequested = resumeRequested
        self.updateRequested = updateRequested
    }

    public var body: some View {
        GeometryReader { proxy in
            animatedNotchSurface
                // Pin the top edge to the host's top center for every spring frame.
                // Alignment-based layout occasionally reused a stale host geometry
                // after quick hover enter/exit, making expansion appear to start
                // from the bottom-right instead of from the physical notch.
                .position(
                    x: proxy.size.width / 2,
                    y: animatingSurfaceHeight / 2
                )
        }
        .frame(width: surfaceWidth, height: surfaceHeight)
        .clipped()
        .accessibilityElement(children: .contain)
    }

    private var animatedNotchSurface: some View {
        ZStack(alignment: .top) {
            Color.black

            collapsedContentLayer
                .opacity(isExpanded ? 0 : 1)
                .animation(Self.restContentAnimation, value: isExpanded)

            expandedContent
                .opacity(isExpanded ? 1 : 0)
                .animation(
                    isExpanded ? Self.expandedContentAnimation : Self.expandedContentDismissAnimation,
                    value: isExpanded
                )

            if !hasTaskDisplayText {
                expandedNotchArrow
                    .opacity(isExpanded ? 1 : 0)
                    .animation(
                        isExpanded ? Self.expandedContentAnimation : Self.expandedContentDismissAnimation,
                        value: isExpanded
                    )
            }
        }
        .frame(width: animatingSurfaceWidth, height: animatingSurfaceHeight, alignment: .top)
        .clipShape(notchSurfaceShape(cornerRadius: animatingSurfaceCornerRadius))
        .shadow(
            color: Color.black.opacity(isExpanded ? 0.5 : 0),
            radius: isExpanded ? 24 : 0,
            x: 0,
            y: isExpanded ? 12 : 0
        )
        .animation(isExpanded ? Self.openEnvelopeAnimation : Self.closeEnvelopeAnimation, value: isExpanded)
    }

    @ViewBuilder
    private var collapsedContentLayer: some View {
        if isResting {
            restingCollapsedContent
        } else {
            regularCollapsedContent
        }
    }

    private var regularCollapsedContent: some View {
        collapsedContent
            .frame(width: animatingSurfaceWidth, height: animatingSurfaceHeight, alignment: .top)
    }

    private var restingCollapsedContent: some View {
        TaskArrowMark(color: accentColor)
            .frame(width: 13, height: 13)
            .padding(.leading, 10)
            .frame(width: animatingSurfaceWidth, height: animatingSurfaceHeight, alignment: .leading)
    }

    private func notchSurfaceShape(cornerRadius: CGFloat) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: 0,
                bottomLeading: cornerRadius,
                bottomTrailing: cornerRadius,
                topTrailing: 0
            ),
            style: .continuous
        )
    }

    private var animatingSurfaceWidth: CGFloat {
        animatingSurfaceFrame.width
    }

    private var animatingSurfaceHeight: CGFloat {
        animatingSurfaceFrame.height
    }

    private var animatingSurfaceFrame: CGRect {
        isExpanded ? layout.expandedSurfaceFrame : layout.collapsedSurfaceFrame
    }

    private var animatingSurfaceCornerRadius: CGFloat {
        isExpanded ? layout.expandedCornerRadius : layout.collapsedCornerRadius
    }

    private var collapsedContent: some View {
        HStack(spacing: 7) {
            TaskArrowMark(color: accentColor)
                .frame(width: 13, height: 13)

            Text(taskTitle)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            if isWorking {
                activityBars(color: accentColor, height: 12)
            }
        }
        .padding(.horizontal, max(10, layout.contentHorizontalInset))
        .frame(
            width: animatingSurfaceWidth,
            height: animatingSurfaceHeight,
            alignment: .center
        )
    }

    private var expandedContent: some View {
        Group {
            if hasTaskDisplayText {
                expandedTaskContent
            } else {
                expandedCommandOnlyContent
            }
        }
        .frame(
            width: layout.expandedContentFrame.width,
            height: layout.expandedContentFrame.height,
            alignment: .top
        )
        .offset(
            x: layout.expandedContentFrame.minX,
            y: layout.expandedContentFrame.minY
        )
        .clipped()
    }

    private var expandedTaskContent: some View {
        VStack(spacing: 0) {
            if updateState.headerButtonTitle != nil {
                expandedUpdateHeader
            }

            ScrollView(.vertical, showsIndicators: false) {
                currentTaskRow
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
            }

            Spacer(minLength: 8)

            commandRow
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
    }

    private var expandedCommandOnlyContent: some View {
        VStack(spacing: 0) {
            if updateState.headerButtonTitle != nil {
                expandedUpdateHeader
            }

            commandRow
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 24)
        }
    }

    private var expandedNotchArrow: some View {
        TaskArrowMark(color: accentColor)
            .frame(width: 15, height: 15)
            .position(x: expandedNotchArrowX, y: expandedNotchArrowY)
    }

    private var expandedUpdateHeader: some View {
        HStack {
            Spacer()

            if let updateTitle = updateState.headerButtonTitle {
                Button(action: updateRequested) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Color(red: 0.94, green: 0.62, blue: 0.15))
                            .frame(width: 7, height: 7)

                        Text(updateTitle)
                            .font(.system(size: 12, weight: .regular))
                    }
                    .foregroundStyle(Color.white.opacity(0.9))
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .background(Color(red: 0.94, green: 0.62, blue: 0.15).opacity(0.22))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 40)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var expandedNotchArrowX: CGFloat {
        24
    }

    private var expandedNotchArrowY: CGFloat {
        max(14, layout.collapsedVisibleHeight / 2)
    }

    private var currentTaskRow: some View {
        HStack(spacing: 12) {
            TaskArrowMark(color: accentColor)
                .frame(width: 14, height: 14)

            VStack(alignment: .leading, spacing: 4) {
                Text(taskTitle)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(1)

                Text(statusDescription)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.42))
            }

            Spacer()

            if isActiveTask {
                activeTaskControls
            } else if isWorking {
                activityBars(color: accentColor)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var commandRow: some View {
        PointerPromptComposer(
            state: commandInputState,
            messageText: $commandText,
            inputTextHeight: commandInputTextHeight,
            isInputExpanded: isCommandInputExpanded,
            surfaceFill: Color.white.opacity(0.085),
            forceExpandedSurface: true,
            toolbarStyle: .followUp,
            sizeProfile: .compact,
            submit: submitCommandText,
            inputTextHeightChanged: commandInputTextHeightChanged,
            inputExpansionChanged: commandInputExpansionChanged
        )
    }

    private func submitCommandText() {
        let text = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        commandText = ""
        commandSubmitted(text)
    }

    private var commandInputState: PointerPromptState {
        PointerPromptState(
            promptText: "Ask for follow-up changes",
            isPrimaryActionEnabled: true,
            leadingSignalLevel: .ready,
            isActive: isExpanded,
            theme: state.theme,
            voiceWaveformLevels: state.voiceWaveformLevels
        )
    }

    private var activeTaskControls: some View {
        HStack(spacing: 6) {
            statusControlButton(
                systemName: "play.fill",
                label: "Resume",
                isEnabled: isCurrentTaskPaused,
                action: resumeRequested
            )

            statusControlButton(
                systemName: "pause.fill",
                label: "Pause",
                isEnabled: !isCurrentTaskPaused,
                action: pauseRequested
            )
        }
    }

    private func statusControlButton(
        systemName: String,
        label: String,
        isEnabled: Bool,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(Color.white.opacity(isEnabled ? 0.88 : 0.3))
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(isEnabled ? 0.12 : 0.055))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }

    private func activityBars(color: Color, height: CGFloat = 18) -> some View {
        HStack(spacing: 3) {
            ForEach([0.44, 0.82, 0.58], id: \.self) { scale in
                Capsule(style: .continuous)
                    .fill(color)
                    .frame(width: 3, height: height * scale)
            }
        }
        .frame(width: 18, height: height)
    }

    private var taskTitle: String {
        if let taskDisplayText {
            return taskDisplayText
        }

        switch state.leadingSignalLevel {
        case .idle:
            return "Resting"
        case .ready:
            return "Ready"
        case .thinking:
            return "Working"
        }
    }

    private var statusDescription: String {
        if isCurrentTaskPaused {
            return "Paused"
        }

        switch state.leadingSignalLevel {
        case .idle:
            return hasTaskDisplayText ? "Needs attention" : "Idle"
        case .ready:
            return "Ready"
        case .thinking:
            return "Running"
        }
    }

    private var isWorking: Bool {
        state.leadingSignalLevel == .thinking
    }

    private var isActiveTask: Bool {
        isWorking || isCurrentTaskPaused
    }

    private var hasTaskDisplayText: Bool {
        taskDisplayText != nil
    }

    private var taskDisplayText: String? {
        let text = state.promptText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !text.isEmpty, text != "Make this so", text != "Resting" else {
            return nil
        }

        return text
    }

    private var isResting: Bool {
        state.leadingSignalLevel == .idle && !hasTaskDisplayText
    }

    private var accentColor: Color {
        Self.accentColors[((accentIndex % Self.accentColors.count) + Self.accentColors.count) % Self.accentColors.count]
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

    private var cornerRadius: CGFloat {
        layout.cornerRadius
    }

    private static let openEnvelopeAnimation = Animation.spring(
        response: 0.55,
        dampingFraction: 0.82,
        blendDuration: 0
    )
    private static let closeEnvelopeAnimation = Animation.easeOut(duration: 0.22)
    private static let restContentAnimation = Animation.easeOut(duration: 0.15)
    private static let expandedContentAnimation = Animation
        .easeOut(duration: 0.3)
        .delay(0.15)
    private static let expandedContentDismissAnimation = Animation.easeOut(duration: 0.1)
}

private struct TaskArrowMark: View {
    var color: Color

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            Path { path in
                path.move(to: CGPoint(x: width * 0.18, y: height * 0.06))
                path.addLine(to: CGPoint(x: width * 0.88, y: height * 0.5))
                path.addLine(to: CGPoint(x: width * 0.18, y: height * 0.94))
                path.addLine(to: CGPoint(x: width * 0.34, y: height * 0.5))
                path.closeSubpath()
            }
            .fill(color)
        }
        .aspectRatio(1, contentMode: .fit)
        .rotationEffect(.degrees(-45))
        .accessibilityHidden(true)
    }
}
