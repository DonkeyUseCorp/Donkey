import DonkeyContracts
import Foundation
import SwiftUI
import UniformTypeIdentifiers

public struct UserQueryNotchStatusView: View {
    @State private var renderedSpawnCue: UserQuerySpawnState?
    @State private var spawnCueIsExiting = false

    private let state: UserQueryState
    private let updateState: UserQueryUpdateState
    private let layout: UserQueryNotchLayout
    private let surfaceWidth: CGFloat
    private let surfaceHeight: CGFloat
    private let isExpanded: Bool
    private let isCurrentTaskPaused: Bool
    @Binding private var commandText: String
    private let commandInputTextHeight: CGFloat
    private let isCommandInputExpanded: Bool
    private let tasks: [UserQueryNotchTask]
    private let accentIndex: Int
    private let spawnState: UserQuerySpawnState?
    private let commandSubmitted: @MainActor (String) -> Void
    private let commandInputTextHeightChanged: @MainActor (CGFloat) -> Void
    private let commandInputExpansionChanged: @MainActor (Bool) -> Void
    private let assetsDropped: @MainActor ([UserQueryTaskAssetDraft]) -> Void
    private let pauseRequested: @MainActor (String) -> Void
    private let resumeRequested: @MainActor (String) -> Void
    private let approvePermissionRequested: @MainActor (String) -> Void
    private let updateRequested: @MainActor () -> Void

    public init(
        state: UserQueryState,
        updateState: UserQueryUpdateState,
        layout: UserQueryNotchLayout,
        surfaceWidth: CGFloat,
        surfaceHeight: CGFloat,
        isExpanded: Bool,
        isCurrentTaskPaused: Bool,
        commandText: Binding<String>,
        commandInputTextHeight: CGFloat,
        isCommandInputExpanded: Bool,
        tasks: [UserQueryNotchTask] = [],
        accentIndex: Int,
        spawnState: UserQuerySpawnState? = nil,
        commandSubmitted: @escaping @MainActor (String) -> Void,
        commandInputTextHeightChanged: @escaping @MainActor (CGFloat) -> Void,
        commandInputExpansionChanged: @escaping @MainActor (Bool) -> Void,
        assetsDropped: @escaping @MainActor ([UserQueryTaskAssetDraft]) -> Void,
        pauseRequested: @escaping @MainActor (String) -> Void,
        resumeRequested: @escaping @MainActor (String) -> Void,
        approvePermissionRequested: @escaping @MainActor (String) -> Void,
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
        self.tasks = tasks
        self.accentIndex = accentIndex
        self.spawnState = spawnState
        self.commandSubmitted = commandSubmitted
        self.commandInputTextHeightChanged = commandInputTextHeightChanged
        self.commandInputExpansionChanged = commandInputExpansionChanged
        self.assetsDropped = assetsDropped
        self.pauseRequested = pauseRequested
        self.resumeRequested = resumeRequested
        self.approvePermissionRequested = approvePermissionRequested
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

            if let renderedSpawnCue {
                spawnCueArrow(renderedSpawnCue)
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
        .contentShape(Rectangle())
        .onDrop(
            of: [UTType.fileURL],
            isTargeted: nil,
            perform: handleDroppedFileProviders
        )
        .onAppear(perform: updateRenderedSpawnCue)
        .onChange(of: spawnCueIdentity) {
            updateRenderedSpawnCue()
        }
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
        Group {
            if layout.canRenderTextInTopRow {
                fullWidthCollapsedContent
            } else {
                voidAwareCollapsedContent
            }
        }
    }

    private var fullWidthCollapsedContent: some View {
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

    private var voidAwareCollapsedContent: some View {
        ZStack {
            TaskArrowMark(color: accentColor)
                .frame(width: 13, height: 13)
                .position(x: collapsedLeadingLaneCenterX, y: layout.collapsedVisibleHeight / 2)

            if let compactTopRowStatusText {
                Text(compactTopRowStatusText)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: collapsedSideLaneWidth, height: layout.collapsedVisibleHeight)
                    .position(x: collapsedTrailingLaneCenterX, y: layout.collapsedVisibleHeight / 2)
            }
        }
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
    }

    private var expandedTaskContent: some View {
        VStack(spacing: 0) {
            if updateState.headerButtonTitle != nil {
                expandedUpdateHeader
            }

            VStack(spacing: Self.taskListCommandSpacing) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        if tasks.isEmpty {
                            currentTaskRow
                        } else {
                            ForEach(tasks) { task in
                                taskRow(task)
                            }
                        }
                    }
                    .padding(.top, 10)
                }

                commandRow
            }
            .padding(.horizontal, Self.contentInset)
            .padding(.bottom, Self.contentInset)
        }
    }

    private var expandedCommandOnlyContent: some View {
        VStack(spacing: 0) {
            if updateState.headerButtonTitle != nil {
                expandedUpdateHeader
            }

            commandRow
                .padding(.top, expandedCommandOnlyTopPadding)
        }
        .padding(.horizontal, Self.contentInset)
        .padding(.bottom, Self.contentInset)
    }

    private var expandedNotchArrow: some View {
        TaskArrowMark(color: accentColor)
            .frame(width: 15, height: 15)
            .position(x: expandedNotchArrowX, y: expandedNotchArrowY)
    }

    private func spawnCueArrow(_ cue: UserQuerySpawnState) -> some View {
        let exitOffset = spawnCueExitOffset(for: cue.notchCueAngleDegrees)

        return TaskArrowMark(
            color: accentColor(for: cue.accentIndex),
            rotationDegrees: spawnCueIsExiting ? cue.notchCueAngleDegrees : -45
        )
        .frame(width: 15, height: 15)
        .position(x: spawnCueArrowX, y: spawnCueArrowY)
        .offset(
            x: spawnCueIsExiting ? exitOffset.width : 0,
            y: spawnCueIsExiting ? exitOffset.height : 0
        )
        .opacity(spawnCueIsExiting ? 0 : 1)
        .animation(.easeInOut(duration: 0.16), value: spawnCueIsExiting)
        .accessibilityHidden(true)
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

    private var spawnCueArrowX: CGFloat {
        layout.canRenderTextInTopRow
            ? max(16, layout.contentHorizontalInset + 6)
            : collapsedLeadingLaneCenterX
    }

    private var spawnCueArrowY: CGFloat {
        max(14, layout.collapsedVisibleHeight / 2)
    }

    private var spawnCueIdentity: String? {
        guard let spawnState,
              spawnState.phase == .notchCue else {
            return nil
        }

        return spawnState.id
    }

    private func updateRenderedSpawnCue() {
        guard let spawnState,
              spawnState.phase == .notchCue else {
            return
        }

        guard renderedSpawnCue?.id != spawnState.id else { return }

        renderedSpawnCue = spawnState
        spawnCueIsExiting = false
        let cueID = spawnState.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard renderedSpawnCue?.id == cueID else { return }

            spawnCueIsExiting = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            guard renderedSpawnCue?.id == cueID else { return }

            renderedSpawnCue = nil
            spawnCueIsExiting = false
        }
    }

    private func spawnCueExitOffset(for angleDegrees: Double) -> CGSize {
        let radians = angleDegrees * .pi / 180
        let distance: CGFloat = 28
        return CGSize(
            width: cos(radians) * distance,
            height: sin(radians) * distance
        )
    }

    private var expandedCommandOnlyTopPadding: CGFloat {
        layout.expandedCommandOnlyTopPadding
    }

    private var collapsedSideLaneWidth: CGFloat {
        max(0, (animatingSurfaceWidth - layout.voidWidth) / 2)
    }

    private var collapsedLeadingLaneCenterX: CGFloat {
        collapsedSideLaneWidth / 2
    }

    private var collapsedTrailingLaneCenterX: CGFloat {
        animatingSurfaceWidth - collapsedSideLaneWidth / 2
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

            if isWorking {
                activityBars(color: accentColor)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func taskRow(_ task: UserQueryNotchTask) -> some View {
        HStack(spacing: 12) {
            TaskArrowMark(color: accentColor(for: task.accentIndex))
                .frame(width: 14, height: 14)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(1)

                Text(taskStatusDescription(task))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.42))
                    .lineLimit(1)
            }

            Spacer()

            if task.status == .running || task.status == .paused || task.status == .waitingForPermission || task.status == .interrupted {
                activeTaskControls(for: task)
            } else {
                taskStatusAccessory(task)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var commandRow: some View {
        UserQueryComposer(
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

    private func handleDroppedFileProviders(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        let group = DispatchGroup()
        let collector = DroppedAssetCollector()
        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                guard let url = DroppedAssetUtilities.fileURL(from: item),
                      let draft = DroppedAssetUtilities.assetDraft(for: url) else {
                    return
                }

                collector.append(draft)
            }
        }
        group.notify(queue: .main) {
            let drafts = collector.values()
            guard !drafts.isEmpty else { return }

            Task { @MainActor in
                assetsDropped(drafts)
            }
        }
        return true
    }

    private var commandInputState: UserQueryState {
        UserQueryState(
            promptText: UserQueryCopy.defaultPromptPlaceholder,
            isPrimaryActionEnabled: true,
            leadingSignalLevel: .ready,
            isActive: isExpanded,
            theme: state.theme,
            voiceWaveformLevels: state.voiceWaveformLevels,
            isVoiceInputActive: false
        )
    }

    @ViewBuilder
    private func activeTaskControls(for task: UserQueryNotchTask) -> some View {
        switch task.status {
        case .waitingForPermission:
            statusControlButton(
                systemName: "checkmark.shield",
                label: "Approve Permission",
                isEnabled: true,
                action: {
                    approvePermissionRequested(task.id)
                }
            )
        case .interrupted:
            statusControlButton(
                systemName: "arrow.triangle.2.circlepath",
                label: "Resume Changed Task",
                isEnabled: true,
                action: {
                    resumeRequested(task.id)
                }
            )
        default:
            HStack(spacing: 6) {
                statusControlButton(
                    systemName: "play.fill",
                    label: "Resume",
                    isEnabled: task.status == .paused,
                    action: {
                        resumeRequested(task.id)
                    }
                )

                statusControlButton(
                    systemName: "pause.fill",
                    label: "Pause",
                    isEnabled: task.status == .running,
                    action: {
                        pauseRequested(task.id)
                    }
                )
            }
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

    @ViewBuilder
    private func taskStatusAccessory(_ task: UserQueryNotchTask) -> some View {
        switch task.status {
        case .chatting:
            Image(systemName: "text.bubble")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(accentColor(for: task.accentIndex))
                .frame(width: 18, height: 18)
        case .running:
            activityBars(color: accentColor(for: task.accentIndex))
        case .paused:
            Image(systemName: "pause.fill")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.5))
                .frame(width: 18, height: 18)
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(accentColor(for: task.accentIndex))
                .frame(width: 18, height: 18)
        case .waitingForClarification:
            Image(systemName: "questionmark")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.62))
                .frame(width: 18, height: 18)
        case .waitingForPermission:
            Image(systemName: "lock.shield")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.62))
                .frame(width: 18, height: 18)
        case .waitingForReview:
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.62))
                .frame(width: 18, height: 18)
        case .interrupted:
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.62))
                .frame(width: 18, height: 18)
        case .needsAttention:
            Image(systemName: "exclamationmark")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.62))
                .frame(width: 18, height: 18)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.55))
                .frame(width: 18, height: 18)
        }
    }

    private var taskTitle: String {
        if let primaryTask {
            return primaryTask.title
        }

        if let taskDisplayText {
            return taskDisplayText
        }

        switch state.leadingSignalLevel {
        case .idle:
            return "Idle"
        case .ready:
            return "Ready"
        case .thinking:
            return "Working"
        }
    }

    private var statusDescription: String {
        if let primaryTask {
            return taskStatusDescription(primaryTask)
        }

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

    private var compactTopRowStatusText: String? {
        if let primaryTask {
            switch primaryTask.status {
            case .chatting:
                return nil
            case .running:
                return "Run"
            case .paused:
                return "Hld"
            case .completed:
                return "Done"
            case .waitingForClarification:
                return "Ask"
            case .waitingForPermission:
                return "Perm"
            case .waitingForReview:
                return "Rev"
            case .interrupted:
                return "Chg"
            case .needsAttention:
                return "Ask"
            case .failed:
                return "Fail"
            }
        }

        if isCurrentTaskPaused {
            return "Hld"
        }

        switch state.leadingSignalLevel {
        case .idle:
            return "Idle"
        case .ready:
            return "Rdy"
        case .thinking:
            return "Run"
        }
    }

    private var isWorking: Bool {
        primaryTask?.status == .running || state.leadingSignalLevel == .thinking
    }

    private var isActiveTask: Bool {
        isWorking || isCurrentTaskPaused || primaryTask?.status == .paused
    }

    private var hasTaskDisplayText: Bool {
        !tasks.isEmpty || taskDisplayText != nil
    }

    private var taskDisplayText: String? {
        let text = UserQueryCopy.normalizedDisplayText(state.promptText)
        guard UserQueryCopy.isTaskDisplayText(text) else {
            return nil
        }

        return text
    }

    private var isResting: Bool {
        state.leadingSignalLevel == .idle && !hasTaskDisplayText
    }

    private var accentColor: Color {
        accentColor(for: primaryTask?.accentIndex ?? accentIndex)
    }

    private var primaryTask: UserQueryNotchTask? {
        tasks.first
    }

    private func isPrimaryTask(_ task: UserQueryNotchTask) -> Bool {
        task.id == primaryTask?.id
    }

    private func taskStatusDescription(_ task: UserQueryNotchTask) -> String {
        switch task.status {
        case .chatting:
            return task.detail.isEmpty ? "Conversation" : task.detail
        case .running:
            return task.detail.isEmpty ? "Running" : task.detail
        case .paused:
            return "Paused"
        case .completed:
            return task.detail.isEmpty ? "Done" : task.detail
        case .waitingForClarification:
            return task.detail.isEmpty ? "Waiting for detail" : task.detail
        case .waitingForPermission:
            return task.detail.isEmpty ? "Waiting for approval" : task.detail
        case .waitingForReview:
            return task.detail.isEmpty ? "Waiting for review" : task.detail
        case .interrupted:
            return task.detail.isEmpty ? "Changed course" : task.detail
        case .needsAttention:
            return task.detail.isEmpty ? "Needs attention" : task.detail
        case .failed:
            return task.detail.isEmpty ? "Stopped" : task.detail
        }
    }

    private func accentColor(for index: Int) -> Color {
        Self.accentColors[UserQueryAccentPalette.normalizedIndex(index)]
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
    private static let contentInset: CGFloat = 14
    private static let taskListCommandSpacing: CGFloat = 8
}

private struct TaskArrowMark: View {
    var color: Color
    var rotationDegrees: Double = -45

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
        .rotationEffect(.degrees(rotationDegrees))
        .accessibilityHidden(true)
    }
}

private final class DroppedAssetCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var drafts: [UserQueryTaskAssetDraft] = []

    func append(_ draft: UserQueryTaskAssetDraft) {
        lock.lock()
        drafts.append(draft)
        lock.unlock()
    }

    func values() -> [UserQueryTaskAssetDraft] {
        lock.lock()
        let snapshot = drafts
        lock.unlock()
        return snapshot
    }
}

private enum DroppedAssetUtilities {
    static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }

        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }

        if let string = item as? String {
            return URL(string: string)
        }

        if let string = item as? NSString {
            return URL(string: string as String)
        }

        return nil
    }

    static func assetDraft(for url: URL) -> UserQueryTaskAssetDraft? {
        guard url.isFileURL else { return nil }

        let contentType = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredMIMEType)
            ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.int64Value
        return UserQueryTaskAssetDraft(
            displayName: url.lastPathComponent,
            contentType: contentType,
            urlString: url.absoluteString,
            byteCount: byteCount
        )
    }
}
