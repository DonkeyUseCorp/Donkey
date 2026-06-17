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
    private let dismissRequested: @MainActor (String) -> Void
    private let taskSelected: @MainActor (String) -> Void
    /// (taskID, alwaysAllow). `alwaysAllow` persists a standing rule for the
    /// command signature; it is only offered for non-highRisk shell consent.
    private let approvePermissionRequested: @MainActor (String, Bool) -> Void
    private let denyPermissionRequested: @MainActor (String) -> Void
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
        dismissRequested: @escaping @MainActor (String) -> Void,
        taskSelected: @escaping @MainActor (String) -> Void,
        approvePermissionRequested: @escaping @MainActor (String, Bool) -> Void,
        denyPermissionRequested: @escaping @MainActor (String) -> Void,
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
        self.dismissRequested = dismissRequested
        self.taskSelected = taskSelected
        self.approvePermissionRequested = approvePermissionRequested
        self.denyPermissionRequested = denyPermissionRequested
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
        DonkeyCursorMark(color: accentColor, silhouette: true)
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
            DonkeyCursorMark(color: accentColor, silhouette: !hasRunningTask)
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
        // The chin narrates running tasks one at a time, advancing every couple of seconds;
        // the left arrow takes the color of whichever task is currently speaking.
        TimelineView(.periodic(from: Self.chinRotationAnchor, by: Self.chinRotationInterval)) { context in
            let speaker = rotatingChinTask(at: context.date)
            ZStack {
                DonkeyCursorMark(
                    color: speaker.map { accentColor(for: $0.accentIndex) } ?? accentColor,
                    silhouette: speaker == nil
                )
                .frame(width: 13, height: 13)
                .position(x: collapsedLeadingLaneCenterX, y: layout.collapsedVisibleHeight / 2)

                collapsedRightSlot
                    .frame(width: collapsedSideLaneWidth, height: layout.collapsedVisibleHeight)
                    .position(x: collapsedTrailingLaneCenterX, y: layout.collapsedVisibleHeight / 2)

                if layout.chinHeight > 0, let speaker {
                    Text(speaker.detail.isEmpty ? speaker.title : speaker.detail)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: max(0, animatingSurfaceWidth - 24), alignment: .leading)
                        .position(x: animatingSurfaceWidth / 2, y: layout.collapsedVisibleHeight + layout.chinHeight / 2)
                }
            }
            .frame(
                width: animatingSurfaceWidth,
                height: animatingSurfaceHeight,
                alignment: .center
            )
        }
    }

    /// The running task currently surfaced in the chin. Running tasks (newest first) rotate
    /// round-robin; the clock is anchored to the newest task's start, so a freshly added task
    /// shows first (the view re-renders on the task change) and then yields to the others.
    private func rotatingChinTask(at date: Date) -> UserQueryNotchTask? {
        let running = tasks.filter { $0.status == .running }
        guard !running.isEmpty else { return nil }
        let anchor = running.map(\.createdAt).max() ?? date
        let slot = Int(max(0, date.timeIntervalSince(anchor)) / Self.chinRotationInterval)
        let index = ((slot % running.count) + running.count) % running.count
        return running[index]
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
        DonkeyCursorMark(color: accentColor)
            .frame(width: 15, height: 15)
            .position(x: expandedNotchArrowX, y: expandedNotchArrowY)
    }

    private func spawnCueArrow(_ cue: UserQuerySpawnState) -> some View {
        let exitOffset = spawnCueExitOffset(for: cue.notchCueAngleDegrees)

        return DonkeyCursorMark(
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

    // The right-gutter app action, styled like the prototype: a label + a white pill button.
    private var expandedUpdateHeader: some View {
        HStack(spacing: 8) {
            Spacer()

            if updateState.isActionable {
                Text("Update Available")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.7))

                Button(action: updateRequested) {
                    Text("Restart")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.82))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
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
        HStack(alignment: .top, spacing: 12) {
            DonkeyCursorMark(color: accentColor)
                .frame(width: 14, height: 14)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(taskTitle)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)

                Text(statusDescription)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.42))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if isWorking {
                HStack(spacing: 8) {
                    if let started = primaryTask?.createdAt {
                        elapsedTimer(since: started)
                    }
                    activityBars(color: accentColor)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(minHeight: 48)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            if let taskID = primaryTask?.id {
                taskSelected(taskID)
            }
        }
    }

    /// A count-up elapsed-time label for a running task — the timeline ticks every second on its
    /// own, so a long-running query visibly advances instead of looking stuck.
    private func elapsedTimer(since start: Date) -> some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            Text(Self.elapsedDescription(from: start, to: context.date))
                .font(.system(size: 11, weight: .regular).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.5))
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// Formats elapsed time as "45m 13s" (or "1h 45m 13s"), dropping any leading zero units.
    static func elapsedDescription(from start: Date, to now: Date) -> String {
        let totalSeconds = max(0, Int(now.timeIntervalSince(start)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        var parts: [String] = []
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 { parts.append("\(minutes)m") }
        parts.append("\(seconds)s")
        return parts.joined(separator: " ")
    }

    private func taskRow(_ task: UserQueryNotchTask) -> some View {
        let isPermission = task.status == .waitingForPermission
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                // Colored pointer only while actively running; silhouette once stopped or finished.
                DonkeyCursorMark(color: accentColor(for: task.accentIndex), silhouette: task.status != .running)
                    .frame(width: 14, height: 14)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if !isPermission {
                        Text(taskStatusDescription(task))
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.42))
                            .lineLimit(5)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Reserve room so long text never slides under the pinned controls / time (prototype: pr-[88px]).
                .padding(.trailing, isPermission ? 0 : 88)
            }

            if isPermission {
                permissionBanner(for: task)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 48)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            taskSelected(task.id)
        }
        // Pinned to the full cell, matching the prototype insets: controls at top-8/right-12, elapsed
        // time at bottom-2.5/right-12, so the time stays near the cell bottom as the subtext grows.
        .overlay(alignment: .topTrailing) {
            if !isPermission {
                topRightControls(task)
                    .padding(.top, 8)
                    .padding(.trailing, 12)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !isPermission {
                taskElapsedLabel(task)
                    .padding(.bottom, 10)
                    .padding(.trailing, 12)
            }
        }
    }

    /// Controls pinned to the row's top-right. Like the prototype, every task carries a real control:
    /// running → stop; paused → resume + close; everything else → close, so any task can be deleted.
    @ViewBuilder
    private func topRightControls(_ task: UserQueryNotchTask) -> some View {
        switch task.status {
        case .waitingForPermission:
            // The permission banner carries its own Approve / Deny; the row needs no extra control.
            EmptyView()
        default:
            stateControls(for: task)
        }
    }

    @ViewBuilder
    private func stateControls(for task: UserQueryNotchTask) -> some View {
        switch task.status {
        case .running:
            // Stop = pause (same affordance the prototype uses for a running task).
            NotchControlButton(systemName: "stop.fill", label: "Stop", isEnabled: true) {
                pauseRequested(task.id)
            }
        case .paused, .interrupted:
            HStack(spacing: 6) {
                NotchControlButton(systemName: "play.fill", label: "Resume", isEnabled: true) {
                    resumeRequested(task.id)
                }
                NotchControlButton(systemName: "xmark", label: "Close", isEnabled: true) {
                    dismissRequested(task.id)
                }
            }
        default:
            // Completed, failed, chatting, and the waiting states (e.g. a clarifying question) are all
            // dismissable straight from the row instead of showing a non-actionable status glyph.
            NotchControlButton(systemName: "xmark", label: "Close", isEnabled: true) {
                dismissRequested(task.id)
            }
        }
    }

    /// Live ticking time while running; a frozen total once the task has stopped or finished. Both use
    /// the prototype's row time style (10px, 55% white) so every row's time matches regardless of status.
    @ViewBuilder
    private func taskElapsedLabel(_ task: UserQueryNotchTask) -> some View {
        if task.status == .running {
            TimelineView(.periodic(from: task.createdAt, by: 1)) { context in
                taskElapsedText(Self.elapsedDescription(from: task.createdAt, to: context.date))
            }
        } else {
            taskElapsedText(Self.elapsedDescription(from: task.createdAt, to: task.updatedAt))
        }
    }

    private func taskElapsedText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .regular).monospacedDigit())
            .foregroundStyle(Color.white.opacity(0.55))
            .lineLimit(1)
            .fixedSize()
    }

    /// A permission request banner below the task text: the request reads on the left, Approve / Deny
    /// on the right. The system permission is only requested once the user taps Approve; Deny stops
    /// the task — the harness never reaches the system without the user's go-ahead.
    private func permissionBanner(for task: UserQueryNotchTask) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.7))

            Text(permissionRequestText(task))
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.7))
                .lineLimit(2)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            permissionButton(label: "Approve", prominent: true) {
                approvePermissionRequested(task.id, false)
            }
            permissionButton(label: "Deny", prominent: false) {
                denyPermissionRequested(task.id)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// What the user is actually approving — named by the concrete action, never the word "tools".
    /// Prefers the shell command being requested, falls back to the gate's own reason, and never
    /// surfaces the runtime's internal "stopped" placeholder.
    private func permissionRequestText(_ task: UserQueryNotchTask) -> String {
        if let command = task.metadata["genericHarness.shellConsent.command"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            return "Allow Donkey to run \(command)"
        }

        let detail = task.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty || detail == Self.internalNotExecutablePlaceholder {
            return "Donkey needs your permission to continue"
        }

        return detail
    }

    /// Mirrors the runtime's guard summary so it never leaks into a permission prompt as if it were
    /// the thing being approved.
    private static let internalNotExecutablePlaceholder = "Task is stopped and cannot execute tools."

    private func permissionButton(label: String, prominent: Bool, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(prominent ? Color.black.opacity(0.82) : Color.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.12)))
                .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) permission")
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

    /// The collapsed right gutter: a notification icon when one is needed, the live run time
    /// while working, an update glyph when idle, otherwise empty — mirroring the prototype.
    @ViewBuilder
    private var collapsedRightSlot: some View {
        if let task = primaryTask {
            switch task.status {
            case .waitingForClarification, .needsAttention:
                slotIcon("exclamationmark.bubble")
            case .waitingForPermission:
                slotIcon("exclamationmark.shield")
            case .waitingForReview:
                slotIcon("doc.text.magnifyingglass")
            case .running:
                compactLiveTime(since: task.createdAt)
            case .paused, .interrupted:
                slotText(Self.compactElapsed(from: task.createdAt, to: task.updatedAt))
            case .completed:
                VStack(spacing: 0) {
                    Text("Done").foregroundStyle(Color.white.opacity(0.92))
                    slotText(Self.compactElapsed(from: task.createdAt, to: task.updatedAt))
                }
                .font(.system(size: 9, weight: .regular).monospacedDigit())
            case .failed:
                slotIcon("xmark")
            case .chatting:
                EmptyView()
            }
        } else if updateState.isActionable {
            slotIcon("icloud.and.arrow.down")
        } else {
            EmptyView()
        }
    }

    private func slotIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(Color.white.opacity(0.85))
    }

    private func slotText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .regular).monospacedDigit())
            .foregroundStyle(Color.white.opacity(0.72))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func compactLiveTime(since start: Date) -> some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            slotText(Self.compactElapsed(from: start, to: context.date))
        }
    }

    /// Compact elapsed time for the 34px right slot: seconds, then minutes, then "Xh Ym".
    static func compactElapsed(from start: Date, to now: Date) -> String {
        let totalSeconds = max(0, Int(now.timeIntervalSince(start)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
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

    private var hasRunningTask: Bool {
        tasks.contains { $0.status == .running }
    }

    private func isPrimaryTask(_ task: UserQueryNotchTask) -> Bool {
        task.id == primaryTask?.id
    }

    /// The task's status line, resolved through the centralized activity vocabulary so the notch and
    /// the future conversation view speak the same language.
    private func taskStatusDescription(_ task: UserQueryNotchTask) -> String {
        UserQueryActivity.current(for: task).displayText
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
    /// The chin advances to the next running task every 2.6s, on a clock shared by all tasks.
    private static let chinRotationInterval: TimeInterval = 2.6
    private static let chinRotationAnchor = Date(timeIntervalSinceReferenceDate: 0)
}

/// A round row control (stop / resume / close). Like the prototype's control buttons it brightens its
/// fill on hover (white 12% → 20%), so the X and its siblings highlight under the cursor.
private struct NotchControlButton: View {
    let systemName: String
    let label: String
    var isEnabled: Bool = true
    let action: @MainActor () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(Color.white.opacity(isEnabled ? 0.88 : 0.3))
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(backgroundOpacity))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
        .onHover { hovering in
            isHovering = hovering && isEnabled
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var backgroundOpacity: Double {
        guard isEnabled else { return 0.055 }
        return isHovering ? 0.2 : 0.12
    }
}

/// The donkey cursor glyph. Geometry is ported verbatim from the prototype's
/// `DonkeyCursor` SVG (100x100 viewBox) so the app and landing-page prototype
/// stay visually identical. The cursor's tip points up-right at `rotationDegrees`
/// 0, so resting/list usages need no rotation; only the spawn cue rotates it.
private struct DonkeyCursorMark: View {
    var color: Color
    var rotationDegrees: Double = 0
    /// Silhouette = hollow gray outline (prototype's inactive/idle arrow); otherwise filled + shadowed.
    var silhouette: Bool = false

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width, proxy.size.height) / 100
            let path = Self.cursorPath(scale: scale)
            if silhouette {
                path
                    .stroke(
                        Color.white.opacity(0.5),
                        style: StrokeStyle(lineWidth: 6 * scale, lineJoin: .round)
                    )
            } else {
                path
                    .fill(color)
                    .overlay(
                        path.stroke(
                            Color.white.opacity(0.92),
                            style: StrokeStyle(lineWidth: 5.36 * scale, lineJoin: .round)
                        )
                    )
                    .shadow(color: Color.black.opacity(0.34), radius: 2 * scale, x: 0, y: 2 * scale)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .rotationEffect(.degrees(rotationDegrees))
        .accessibilityHidden(true)
    }

    private static func cursorPath(scale: CGFloat) -> Path {
        Path { path in
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * scale, y: y * scale)
            }

            path.move(to: point(83.086, 5.6406))
            path.addLine(to: point(10.453, 34.6836))
            path.addCurve(
                to: point(11.1327, 51.0276),
                control1: point(2.8514, 37.7227),
                control2: point(3.3085, 48.6326)
            )
            path.addLine(to: point(35.6947, 58.5471))
            path.addCurve(
                to: point(41.4486, 64.301),
                control1: point(38.4486, 59.3909),
                control2: point(40.6049, 61.5471)
            )
            path.addLine(to: point(48.9681, 88.863))
            path.addCurve(
                to: point(65.3121, 89.5427),
                control1: point(51.3665, 96.6911),
                control2: point(62.2731, 97.1442)
            )
            path.addLine(to: point(94.3551, 16.9097))
            path.addCurve(
                to: point(83.0821, 5.6367),
                control1: point(97.1871, 9.8316),
                control2: point(90.1598, 2.8077)
            )
            path.closeSubpath()
        }
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
