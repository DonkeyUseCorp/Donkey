import DonkeyContracts
import SwiftUI

public struct PointerPromptNotchStatusView: View {
    private let state: PointerPromptState
    private let updateState: PointerPromptUpdateState
    private let layout: PointerPromptNotchLayout
    private let surfaceWidth: CGFloat
    private let surfaceHeight: CGFloat
    private let isExpanded: Bool
    private let accentIndex: Int
    private let commandRequested: @MainActor () -> Void
    private let updateRequested: @MainActor () -> Void

    public init(
        state: PointerPromptState,
        updateState: PointerPromptUpdateState,
        layout: PointerPromptNotchLayout,
        surfaceWidth: CGFloat,
        surfaceHeight: CGFloat,
        isExpanded: Bool,
        accentIndex: Int,
        commandRequested: @escaping @MainActor () -> Void,
        updateRequested: @escaping @MainActor () -> Void
    ) {
        self.state = state
        self.updateState = updateState
        self.layout = layout
        self.surfaceWidth = surfaceWidth
        self.surfaceHeight = surfaceHeight
        self.isExpanded = isExpanded
        self.accentIndex = accentIndex
        self.commandRequested = commandRequested
        self.updateRequested = updateRequested
    }

    public var body: some View {
        GeometryReader { proxy in
            animatedNotchSurface
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
        VStack(spacing: 0) {
            expandedHeader

            currentTaskRow
                .padding(.horizontal, 14)
                .padding(.top, 10)

            Spacer(minLength: 8)

            commandRow
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
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

    private var expandedHeader: some View {
        HStack(spacing: 10) {
            TaskArrowMark(color: accentColor)
                .frame(width: 15, height: 15)

            Text("Current task")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.92))

            Text(statusLabel)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.42))

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

            Button(action: commandRequested) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .regular))
                    Text("new")
                        .font(.system(size: 13, weight: .regular))
                }
                .foregroundStyle(Color.white.opacity(0.46))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .frame(height: 40)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var currentTaskRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(accentColor)
                .frame(width: 7, height: 7)

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

            if isWorking {
                activityBars(color: accentColor)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var commandRow: some View {
        Button(action: commandRequested) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.42))

                Text("Type a task...")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.42))

                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(Color.white.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
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
        switch state.leadingSignalLevel {
        case .idle:
            let text = state.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty || text == "Make this so" ? "Resting" : text
        case .ready:
            let text = state.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "Ready" : text
        case .thinking:
            let text = state.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "Working" : text
        }
    }

    private var statusLabel: String {
        switch state.leadingSignalLevel {
        case .idle:
            return "resting"
        case .ready:
            return "ready"
        case .thinking:
            return "working"
        }
    }

    private var statusDescription: String {
        switch state.leadingSignalLevel {
        case .idle:
            return "Waiting for a task"
        case .ready:
            return "Ready for the next task"
        case .thinking:
            return "Classifying and running"
        }
    }

    private var isWorking: Bool {
        state.leadingSignalLevel == .thinking
    }

    private var isResting: Bool {
        state.leadingSignalLevel == .idle && taskTitle == "Resting"
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
