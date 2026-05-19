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
    private let hoverChanged: @MainActor (Bool) -> Void
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
        hoverChanged: @escaping @MainActor (Bool) -> Void,
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
        self.hoverChanged = hoverChanged
        self.commandRequested = commandRequested
        self.updateRequested = updateRequested
    }

    public var body: some View {
        ZStack(alignment: .top) {
            collapsedWindow
                .opacity(isExpanded ? 0 : 1)

            expandedWindow
                .offset(y: isExpanded ? 0 : -expandedSurfaceHeight)
                .animation(.smooth(duration: 0.24), value: isExpanded)
        }
        .frame(width: surfaceWidth, height: surfaceHeight, alignment: .top)
        .clipped()
        .onHover { isHovering in
            Task { @MainActor in
                hoverChanged(isHovering)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var collapsedWindow: some View {
        if isResting {
            restingCollapsedWindow
        } else {
            regularCollapsedWindow
        }
    }

    private var regularCollapsedWindow: some View {
        ZStack(alignment: .top) {
            notchSurface(height: collapsedSurfaceHeight, cornerRadius: collapsedCornerRadius)

            physicalNotchDebugOutline

            collapsedContent
                .offset(y: max(0, layout.voidHeight))
        }
        .frame(width: surfaceWidth, height: collapsedSurfaceHeight, alignment: .top)
    }

    private var restingCollapsedWindow: some View {
        ZStack(alignment: .top) {
            physicalNotchDebugOutline

            restingCollapsedSurface
                .offset(x: restingSurfaceOffsetX, y: 0)
        }
        .frame(width: surfaceWidth, height: collapsedSurfaceHeight, alignment: .top)
    }

    private var restingCollapsedSurface: some View {
        ZStack(alignment: .leading) {
            notchSurface(
                width: restingSurfaceWidth,
                height: restingVisibleHeight,
                cornerRadius: restingCornerRadius
            )

            TaskArrowMark(color: accentColor)
                .frame(width: 13, height: 13)
                .padding(.leading, 10)
        }
        .frame(width: restingSurfaceWidth, height: restingVisibleHeight, alignment: .leading)
    }

    private var expandedWindow: some View {
        ZStack(alignment: .top) {
            notchSurface(height: expandedSurfaceHeight, cornerRadius: expandedCornerRadius)

            physicalNotchDebugOutline

            expandedContent
                .offset(y: max(0, layout.voidHeight))
        }
        .frame(width: surfaceWidth, height: expandedSurfaceHeight, alignment: .top)
    }

    private func notchSurface(
        width: CGFloat? = nil,
        height: CGFloat,
        cornerRadius: CGFloat
    ) -> some View {
        notchSurfaceShape(cornerRadius: cornerRadius)
            .fill(Color.black)
            .overlay {
                notchSurfaceShape(cornerRadius: cornerRadius)
                    .stroke(
                        notchDebugColor,
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
            }
            .frame(width: width ?? surfaceWidth, height: height, alignment: .top)
    }

    private var physicalNotchDebugOutline: some View {
        Rectangle()
            .stroke(
                Color.cyan.opacity(0.85),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )
            .frame(width: max(1, layout.voidWidth), height: max(1, layout.voidHeight))
            .opacity(layout.voidWidth > 0 && layout.voidHeight > 0 ? 1 : 0)
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

    private var notchDebugColor: Color {
        Color(red: 1.0, green: 0.14, blue: 0.58).opacity(0.92)
    }

    private var collapsedSurfaceHeight: CGFloat {
        layout.voidHeight + layout.collapsedVisibleHeight
    }

    private var expandedSurfaceHeight: CGFloat {
        layout.voidHeight + layout.expandedVisibleHeight
    }

    private var collapsedCornerRadius: CGFloat {
        13
    }

    private var expandedCornerRadius: CGFloat {
        28
    }

    private var restingVisibleHeight: CGFloat {
        layout.voidHeight > 0 ? layout.voidHeight : layout.collapsedVisibleHeight
    }

    private var restingCornerRadius: CGFloat {
        9
    }

    private var restingArrowAllowance: CGFloat {
        34
    }

    private var restingSurfaceWidth: CGFloat {
        max(restingArrowAllowance, layout.voidWidth + restingArrowAllowance * 2)
    }

    private var restingSurfaceOffsetX: CGFloat {
        0
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
            width: surfaceWidth,
            height: layout.collapsedVisibleHeight,
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
            width: surfaceWidth,
            height: layout.expandedVisibleHeight,
            alignment: .top
        )
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
        .accessibilityHidden(true)
    }
}
