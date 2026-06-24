import DonkeyContracts
import Foundation
import SwiftUI
import UniformTypeIdentifiers

public struct UserQueryNotchStatusView: View {
    @State private var renderedSpawnCue: UserQuerySpawnState?
    @State private var spawnCueIsExiting = false
    /// Drives the grow/shrink animation. The controller flips the `isExpanded` property by swapping the
    /// whole hosting `rootView` — and that swap can land inside the host-resize `CATransaction` (actions
    /// disabled), which swallows a `.animation(value: isExpanded)` and snaps the surface open. Mirroring
    /// the open state into `@State` and flipping it in `.onChange` moves the animation onto SwiftUI's own
    /// fresh transaction, so the surface always interpolates from the committed collapsed notch.
    @State private var surfaceIsOpen = false

    private let state: UserQueryState
    private let updateState: UserQueryUpdateState
    private let layout: UserQueryNotchLayout
    private let surfaceWidth: CGFloat
    private let surfaceHeight: CGFloat
    /// Whether the host window is open. The window opens/closes instantly (no animation); only the
    /// content animates. The collapsed chrome belongs to the closed window, so it tracks this.
    private let isHostExpanded: Bool
    private let isExpanded: Bool
    private let isCurrentConversationPaused: Bool
    @Binding private var commandText: String
    private let commandInputTextHeight: CGFloat
    private let isCommandInputExpanded: Bool
    private let conversations: [UserQueryConversation]
    private let surfacedConversations: [UserQueryConversation]
    /// While the user is replying to a specific conversation (tapped Reply), this is that conversation; the expanded
    /// panel dims every other row so it's clear the next message continues this one thread.
    private let replyTargetConversationID: String?
    /// The row the keyboard arrows currently highlight (distinct from the reply target). It renders a
    /// brighter fill and a ring so the selection reads while the composer keeps text focus.
    private let selectedConversationID: String?
    private let accentIndex: Int
    private let spawnState: UserQuerySpawnState?
    private let commandSubmitted: @MainActor (String) -> Void
    private let commandInputTextHeightChanged: @MainActor (CGFloat) -> Void
    private let commandInputExpansionChanged: @MainActor (Bool) -> Void
    private let assetsDropped: @MainActor ([UserQueryConversationAssetDraft]) -> Void
    private let pauseRequested: @MainActor (String) -> Void
    private let resumeRequested: @MainActor (String) -> Void
    private let dismissRequested: @MainActor (String) -> Void
    private let conversationSelected: @MainActor (String) -> Void
    /// A conversation waiting on the user (a clarification or review) offers Reply; tapping it pins the composer
    /// to that conversation and focuses the input so the user's next message answers it.
    private let replyRequested: @MainActor (String) -> Void
    /// Tapping the notch chrome outside a row, control, or the composer while replying leaves reply mode.
    private let replyModeExited: @MainActor () -> Void
    /// (conversationID, alwaysAllow). `alwaysAllow` persists a standing rule for the
    /// command signature; it is only offered for non-highRisk shell consent.
    private let approvePermissionRequested: @MainActor (String, Bool) -> Void
    private let denyPermissionRequested: @MainActor (String) -> Void
    private let updateRequested: @MainActor () -> Void
    /// Logged out: the notch renders a login call-to-action instead of the conversation surface, and the
    /// Login button fires this to start the real sign-in (handled by the model/controller).
    private let needsLogin: Bool
    private let loginRequested: @MainActor () -> Void
    /// A conversation that failed for lack of credits shows a "Reload credits" CTA in its banner; tapping it
    /// fires this so the app can open the billing page (reuses the permission-banner button styling).
    private let reloadCreditsRequested: @MainActor (String) -> Void

    public init(
        state: UserQueryState,
        updateState: UserQueryUpdateState,
        layout: UserQueryNotchLayout,
        surfaceWidth: CGFloat,
        surfaceHeight: CGFloat,
        isHostExpanded: Bool,
        isExpanded: Bool,
        isCurrentConversationPaused: Bool,
        commandText: Binding<String>,
        commandInputTextHeight: CGFloat,
        isCommandInputExpanded: Bool,
        conversations: [UserQueryConversation] = [],
        surfacedConversations: [UserQueryConversation] = [],
        replyTargetConversationID: String? = nil,
        selectedConversationID: String? = nil,
        accentIndex: Int,
        spawnState: UserQuerySpawnState? = nil,
        commandSubmitted: @escaping @MainActor (String) -> Void,
        commandInputTextHeightChanged: @escaping @MainActor (CGFloat) -> Void,
        commandInputExpansionChanged: @escaping @MainActor (Bool) -> Void,
        assetsDropped: @escaping @MainActor ([UserQueryConversationAssetDraft]) -> Void,
        pauseRequested: @escaping @MainActor (String) -> Void,
        resumeRequested: @escaping @MainActor (String) -> Void,
        dismissRequested: @escaping @MainActor (String) -> Void,
        conversationSelected: @escaping @MainActor (String) -> Void,
        replyRequested: @escaping @MainActor (String) -> Void = { _ in },
        replyModeExited: @escaping @MainActor () -> Void = {},
        approvePermissionRequested: @escaping @MainActor (String, Bool) -> Void,
        denyPermissionRequested: @escaping @MainActor (String) -> Void,
        updateRequested: @escaping @MainActor () -> Void,
        needsLogin: Bool = false,
        loginRequested: @escaping @MainActor () -> Void = {},
        reloadCreditsRequested: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.state = state
        self.updateState = updateState
        self.layout = layout
        self.surfaceWidth = surfaceWidth
        self.surfaceHeight = surfaceHeight
        self.isHostExpanded = isHostExpanded
        self.isExpanded = isExpanded
        self.isCurrentConversationPaused = isCurrentConversationPaused
        _commandText = commandText
        self.commandInputTextHeight = commandInputTextHeight
        self.isCommandInputExpanded = isCommandInputExpanded
        self.conversations = conversations
        self.surfacedConversations = surfacedConversations
        self.replyTargetConversationID = replyTargetConversationID
        self.selectedConversationID = selectedConversationID
        self.accentIndex = accentIndex
        self.spawnState = spawnState
        self.commandSubmitted = commandSubmitted
        self.commandInputTextHeightChanged = commandInputTextHeightChanged
        self.commandInputExpansionChanged = commandInputExpansionChanged
        self.assetsDropped = assetsDropped
        self.pauseRequested = pauseRequested
        self.resumeRequested = resumeRequested
        self.dismissRequested = dismissRequested
        self.conversationSelected = conversationSelected
        self.replyRequested = replyRequested
        self.replyModeExited = replyModeExited
        self.approvePermissionRequested = approvePermissionRequested
        self.denyPermissionRequested = denyPermissionRequested
        self.updateRequested = updateRequested
        self.needsLogin = needsLogin
        self.loginRequested = loginRequested
        self.reloadCreditsRequested = reloadCreditsRequested
    }

    public var body: some View {
        // The notch shape itself grows. There is one fixed content canvas — the black fill plus the
        // collapsed and expanded content, laid out once and pinned to the host's top center — and a
        // single clip shape that animates from the closed-notch size out to full size. The content
        // never moves; the growing notch simply uncovers more of it, downward from the notch and
        // outward from center. The host window opens/closes instantly to give the clip room.
        contentCanvas
            .frame(width: surfaceWidth, height: surfaceHeight, alignment: .top)
            .clipShape(
                GrowingNotchShape(
                    width: animatingSurfaceWidth,
                    height: animatingSurfaceHeight,
                    cornerRadius: animatingSurfaceCornerRadius
                )
            )
            .shadow(
                color: Color.black.opacity(surfaceIsOpen ? 0.5 : 0),
                radius: surfaceIsOpen ? 24 : 0,
                x: 0,
                y: surfaceIsOpen ? 12 : 0
            )
            // The host follows a beat later on close (see closeAnimationDuration), once the clip has
            // finished shrinking back to the notch.
            .animation(surfaceAnimation, value: surfaceIsOpen)
            .onAppear { surfaceIsOpen = isExpanded }
            .onChange(of: isExpanded) { surfaceIsOpen = isExpanded }
            .accessibilityElement(children: .contain)
    }

    private var contentCanvas: some View {
        ZStack(alignment: .top) {
            Color.black

            // While replying, a tap on bare chrome (not a row, control, or the composer — those sit above
            // this layer and take their own taps first) leaves reply mode. Only present while targeted, so
            // it never interferes with normal taps.
            if replyTargetConversationID != nil {
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .contentShape(Rectangle())
                    .onTapGesture { replyModeExited() }
                    .accessibilityHidden(true)
            }

            collapsedContentLayer
                // Keep the off-center void pinned to the camera once the host opens into its wider,
                // centered canvas (jumps in step with the instant host reframe, never slides).
                .offset(x: collapsedChromeVoidShift)
                // The collapsed chrome fades out as the notch grows open and fades back in as it
                // collapses, so it cross-dissolves with the expanded content rather than popping.
                .opacity(surfaceIsOpen ? 0 : 1)
                .animation(Self.collapsedChromeAnimation, value: surfaceIsOpen)

            expandedContent
                .opacity(surfaceIsOpen ? 1 : 0)
                .animation(
                    surfaceIsOpen ? Self.expandedContentAnimation : Self.expandedContentDismissAnimation,
                    value: surfaceIsOpen
                )

            if !hasConversationDisplayText && !needsLogin {
                expandedNotchArrow
                    .opacity(surfaceIsOpen ? 1 : 0)
                    .animation(
                        surfaceIsOpen ? Self.expandedContentAnimation : Self.expandedContentDismissAnimation,
                        value: surfaceIsOpen
                    )
            }

            if let renderedSpawnCue {
                spawnCueArrow(renderedSpawnCue)
            }
        }
        // The canvas is laid out once at the full expanded size and pinned to the top, so every layer
        // holds its final position. The growing clip in `body` reveals more of it; nothing reflows.
        .frame(width: expandedSurfaceWidth, height: expandedSurfaceHeight, alignment: .top)
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
        if needsLogin {
            loginCollapsedContent
        } else if isResting {
            restingCollapsedContent
        } else {
            regularCollapsedContent
        }
    }

    /// Logged out, collapsed: the idle silhouette sits in the leading lane beside the void, and the
    /// notch reads "Login to use Donkey". On a real notch the line sits in the band below the void;
    /// a no-notch display renders the cursor and line inline in the top row. No button until expanded.
    @ViewBuilder
    private var loginCollapsedContent: some View {
        let idleCursor = DonkeyCursorMark(color: accentColor, silhouette: true)
            .frame(width: 14, height: 14)

        if layout.canRenderTextInTopRow {
            HStack(spacing: 7) {
                idleCursor

                Text(Self.loginHeadline)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, max(10, layout.contentHorizontalInset))
            .frame(width: collapsedSurfaceWidth, height: collapsedSurfaceHeight, alignment: .center)
        } else {
            let label = Text(Self.loginHeadline)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)

            ZStack(alignment: .top) {
                idleCursor
                    .position(x: collapsedLeadingLaneCenterX, y: layout.collapsedVisibleHeight / 2)

                VStack(spacing: 0) {
                    Spacer(minLength: 0).frame(height: layout.collapsedVisibleHeight)
                    label.frame(height: UserQueryNotchMetrics.loginCollapsedBandHeight)
                }
            }
            .frame(width: collapsedSurfaceWidth, height: collapsedSurfaceHeight, alignment: .top)
        }
    }

    /// The white Login pill, styled like the prototype's expanded login bar (and the Restart button).
    private func loginButton() -> some View {
        Button(action: loginRequested) {
            Text("Login")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.82))
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Login")
    }

    private static let loginHeadline = "Login to use Donkey"

    private var regularCollapsedContent: some View {
        collapsedContent
            .frame(width: collapsedSurfaceWidth, height: collapsedSurfaceHeight, alignment: .top)
    }

    private var restingCollapsedContent: some View {
        DonkeyCursorMark(color: accentColor, silhouette: true)
            .frame(width: 14, height: 14)
            .padding(.leading, 10)
            .frame(width: collapsedSurfaceWidth, height: collapsedSurfaceHeight, alignment: .leading)
    }

    /// The leading-lane pointer(s). One pointer per surfaced conversation (running plus undismissed
    /// completions), overlapping as a cascading stack, newest on top, capped so the lane never crowds.
    /// Only the pointer for the conversation currently narrating the chin (`speaker`) takes its accent
    /// color; every other pointer renders as a gray silhouette, so the lit arrow always matches the line
    /// on screen. With nothing surfaced it falls back to the idle silhouette.
    @ViewBuilder
    private func pointerCluster(size: CGFloat, speaker: UserQueryConversation?) -> some View {
        let cluster = Array(surfacedConversations.prefix(Self.maxClusterPointers))
        if cluster.isEmpty {
            DonkeyCursorMark(color: accentColor, silhouette: true)
                .frame(width: size, height: size)
        } else {
            // Color the pointer for the speaking conversation; if it isn't in the visible cluster, fall
            // back to the newest pointer so the lane is never all-gray while a conversation is narrating.
            let litID = cluster.first(where: { $0.id == speaker?.id })?.id ?? cluster.first?.id
            let count = cluster.count
            let width = size + Self.clusterStepX * CGFloat(count - 1)
            let height = size + Self.clusterStepY * CGFloat(count - 1)
            ZStack(alignment: .topLeading) {
                // Oldest first so the newest pointer lands on top, furthest along the cascade.
                ForEach(Array(cluster.reversed().enumerated()), id: \.element.id) { index, conversation in
                    DonkeyCursorMark(
                        color: accentColor(for: conversation.accentIndex),
                        silhouette: conversation.id != litID
                    )
                        .frame(width: size, height: size)
                        .offset(x: Self.clusterStepX * CGFloat(index), y: Self.clusterStepY * CGFloat(index))
                        // The lit pointer rides above the gray silhouettes so the colored arrow always
                        // reads clearly, whichever cascade position the speaking conversation sits in.
                        .zIndex(conversation.id == litID ? Double(count) : Double(index))
                }
            }
            .frame(width: width, height: height)
        }
    }

    private var animatingSurfaceWidth: CGFloat {
        animatingSurfaceFrame.width
    }

    private var animatingSurfaceHeight: CGFloat {
        animatingSurfaceFrame.height
    }

    /// The visible black surface. The host window jumps to its expanded size instantly (so there is
    /// always room), and this surface grows from the collapsed notch to the expanded frame inside it,
    /// animated off `isExpanded`. On collapse it shrinks back first, then the host follows.
    private var animatingSurfaceFrame: CGRect {
        surfaceIsOpen ? layout.expandedSurfaceFrame : layout.collapsedSurfaceFrame
    }

    private var animatingSurfaceCornerRadius: CGFloat {
        surfaceIsOpen ? layout.expandedCornerRadius : layout.collapsedCornerRadius
    }

    /// The collapsed surface size, used to lay out the collapsed chrome at a fixed size so it does not
    /// stretch with the growing surface while it cross-dissolves out.
    private var collapsedSurfaceWidth: CGFloat {
        layout.collapsedSurfaceFrame.width
    }

    private var collapsedSurfaceHeight: CGFloat {
        layout.collapsedSurfaceFrame.height
    }

    /// The fully expanded surface size. Every layer is laid out in this fixed canvas so the content
    /// holds its final position while the growing clip window reveals it from the notch outward.
    private var expandedSurfaceWidth: CGFloat {
        layout.expandedSurfaceFrame.width
    }

    private var expandedSurfaceHeight: CGFloat {
        layout.expandedSurfaceFrame.height
    }

    private var collapsedContent: some View {
        // INVARIANT: every notch change must land on BOTH display kinds. `canRenderTextInTopRow` is the
        // no-notch (no camera void) display — it renders inline here; the `else` is the physical-notch
        // (void-aware) layout. A change that touches only one branch is a bug, not a layout choice.
        Group {
            if layout.canRenderTextInTopRow {
                fullWidthCollapsedContent
            } else {
                voidAwareCollapsedContent
            }
        }
    }

    private var fullWidthCollapsedContent: some View {
        // A no-notch display has no camera void to route around, so the line lives inline here rather
        // than in a chin band — but it reads the very same rotating line the chin does (the surfaced
        // conversation's latest line), so both layouts narrate identically. It gets the same one-line
        // budget at rest, growing to a second line (see the controller's `statusCollapsedTopRowExtraHeight`)
        // only while the line it shows is a surfaced one — active or unacknowledged.
        TimelineView(.periodic(from: Self.chinRotationAnchor, by: Self.chinRotationInterval)) { context in
            let speaker = rotatingChinConversation(at: context.date)
            HStack(spacing: 7) {
                pointerCluster(size: 14, speaker: speaker)
                    // While a conversation waits on the user, its pointer stays lit and pulses for attention — the
                    // same cue the expanded row gives — so the blocked thread reads at a glance.
                    .modifier(AttentionPulse(active: isPrimaryWaitingOnUser))

                Text(collapsedTopRowText(speaker: speaker))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(chinLineLimit(speaker: speaker))
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                // The gutter carries the live elapsed clock while a conversation runs, then the waiting-on-user "!"
                // glyph (or the update cloud) — the same indicators a void-aware host raises. The slot shows the
                // full elapsed time (hours, minutes, and seconds), same as the notched layout's widened gutter.
                collapsedRightSlot
            }
            .padding(.horizontal, max(10, layout.contentHorizontalInset))
            .frame(
                width: collapsedSurfaceWidth,
                height: collapsedSurfaceHeight,
                alignment: .center
            )
        }
    }

    /// The line the no-notch collapsed row shows: the rotating surfaced conversation's latest line, identical to
    /// the chin band. Only when nothing is surfaced does it fall back to the headline (e.g. "Thinking",
    /// or a freshly typed prompt that has no conversation line yet).
    private func collapsedTopRowText(speaker: UserQueryConversation?) -> String {
        if let speaker {
            return chinText(for: speaker)
        }
        return collapsedHeadline
    }

    private var voidAwareCollapsedContent: some View {
        // The chin narrates running conversations one at a time, advancing every couple of seconds;
        // the left arrow takes the color of whichever conversation is currently speaking.
        TimelineView(.periodic(from: Self.chinRotationAnchor, by: Self.chinRotationInterval)) { context in
            let speaker = rotatingChinConversation(at: context.date)
            ZStack {
                pointerCluster(size: 14, speaker: speaker)
                    .modifier(AttentionPulse(active: isPrimaryWaitingOnUser))
                    .position(x: collapsedLeadingLaneCenterX, y: layout.collapsedVisibleHeight / 2)

                collapsedRightSlot
                    .frame(width: collapsedTrailingLaneWidth, height: layout.collapsedVisibleHeight)
                    .position(x: collapsedTrailingLaneCenterX, y: layout.collapsedVisibleHeight / 2)

                if layout.chinHeight > 0, let speaker {
                    chinLine(for: speaker)
                        .frame(width: max(0, collapsedSurfaceWidth - 24), alignment: .leading)
                        .position(
                            x: collapsedSurfaceWidth / 2,
                            y: layout.collapsedVisibleHeight + (layout.chinHeight - Self.chinBottomMargin) / 2
                        )
                }
            }
            .frame(
                width: collapsedSurfaceWidth,
                height: collapsedSurfaceHeight,
                alignment: .center
            )
        }
    }

    /// The chin line for a surfaced conversation. While the conversation runs it echoes what the user asked, so the
    /// notch reads back the prompt rather than the planner's per-step narration. Once the agent answers,
    /// the conversation's `detail` carries the reply (set to `result.summary` on completion), so the chin shows
    /// the response. A failure is flagged by the red warning icon in the right rail (see
    /// `collapsedRightSlot`), not inline here.
    private func chinLine(for conversation: UserQueryConversation) -> some View {
        Text(chinText(for: conversation))
            .font(.system(size: Self.chinFontSize, weight: .regular))
            .foregroundStyle(Color.white.opacity(0.72))
            .lineLimit(chinLineLimit(speaker: conversation))
            .truncationMode(.tail)
    }

    private func chinText(for conversation: UserQueryConversation) -> String {
        conversation.chinDisplayText
    }

    /// How many lines the collapsed chin gives the line it is currently narrating. A surfaced conversation
    /// — one that is active or unacknowledged (running, waiting on the user, or a terminal line not yet
    /// dismissed) — gets a second line. An idle line (the most-recent settled conversation shown as the
    /// fallback, or no speaker at all) reads on one, so the resting notch stays a single line. Matches the
    /// two-line budget the controller reserves (`statusChinHeight` / `statusCollapsedTopRowExtraHeight`),
    /// so the band height and the rendered line agree.
    private func chinLineLimit(speaker: UserQueryConversation?) -> Int {
        guard let speaker, surfacedConversations.contains(where: { $0.id == speaker.id }) else { return 1 }
        return 2
    }

    private func rotatingChinConversation(at date: Date) -> UserQueryConversation? {
        Self.collapsedChinConversation(
            conversations: conversations,
            surfaced: surfacedConversations,
            at: date,
            rotationInterval: Self.chinRotationInterval
        )
    }

    /// The one rule for which conversation the collapsed notch narrates. Every collapsed surface — the
    /// chin band, the no-notch top row, and the headline fallback — selects through here, so they can
    /// never disagree, and the priority is locked by `UserQueryCollapsedChinSelectionTests`.
    ///
    /// The invariant this enforces: **while any conversation exists, the notch shows one of them, and it
    /// is always that conversation's live line** (`chinDisplayText`) — never nil-then-fall-back-to-the-
    /// prompt, which was the "still says hi" bug. Priority, highest first:
    ///   1. an unacknowledged failure — holds the chin until the user expands to see it;
    ///   2. a conversation blocked on the user — its `chinDisplayText` is the agent's question, not the prompt;
    ///   3. the running conversations, rotating round-robin anchored to the newest so each narrates in turn;
    ///   4. otherwise the most recent conversation, whatever its state — read from *every* conversation, not just
    ///      the unacknowledged ones, so a finished or already-seen reply keeps showing rather than
    ///      reverting to the opening prompt. `conversations` is newest-first and deduped, so `.first` is current.
    public static func collapsedChinConversation(
        conversations: [UserQueryConversation],
        surfaced: [UserQueryConversation],
        at date: Date,
        rotationInterval: TimeInterval
    ) -> UserQueryConversation? {
        if let errored = surfaced.first(where: { $0.status == .failed }) {
            return errored
        }
        if let waiting = surfaced.first(where: { isWaitingOnUser($0) }) {
            return waiting
        }
        let running = surfaced.filter { $0.status == .running }
        guard !running.isEmpty else {
            return conversations.first
        }
        let anchor = running.map(\.createdAt).max() ?? date
        let slot = Int(max(0, date.timeIntervalSince(anchor)) / rotationInterval)
        let index = ((slot % running.count) + running.count) % running.count
        return running[index]
    }

    private var expandedContent: some View {
        Group {
            if needsLogin {
                loginExpandedContent
            } else if hasConversationDisplayText {
                expandedConversationContent
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

    /// Logged out, expanded: a wide, short bar — the headline on the left, the Login pill on the right
    /// (no conversation list, no command input). Mirrors the prototype's expanded login bar.
    private var loginExpandedContent: some View {
        HStack(spacing: 12) {
            Text(Self.loginHeadline)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.92))

            Spacer(minLength: 8)

            loginButton()
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var expandedConversationContent: some View {
        VStack(spacing: 0) {
            if updateState.headerButtonTitle != nil {
                expandedUpdateHeader
            }

            VStack(spacing: Self.conversationListCommandSpacing) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 8) {
                            if conversations.isEmpty {
                                currentConversationRow
                            } else {
                                ForEach(conversations) { conversation in
                                    // While replying to one conversation, the others dim back (handled inside the
                                    // row so an attention pointer can stay lit) — it's clear which thread
                                    // the next message continues. The dim is instant, not eased: an eased
                                    // reply-dim made an arrowed-to row brighten ~0.16s after it scrolled
                                    // in, reading as "scroll, then select."
                                    conversationRow(conversation)
                                        .id(conversation.id)
                                }
                            }
                        }
                        .padding(.top, 10)
                    }
                    // Keep the keyboard-highlighted row on screen as the arrows walk past the fold.
                    // `anchor: nil` scrolls the minimum to reveal the row (a no-op while it's already
                    // visible) and stays unanimated, so a fast arrow burst can't restart a scroll
                    // animation every frame and stall ("stuck", confirmed by profiling). The scroll
                    // shares the selection's transaction (no defer), so an off-screen row scrolls in
                    // already highlighted instead of lighting up a frame after it arrives.
                    .onChange(of: selectedConversationID) {
                        guard let selectedConversationID else { return }
                        proxy.scrollTo(selectedConversationID)
                    }
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

    /// The leading lane only holds the pointer; the trailing lane is wider so the live clock fits beside
    /// the camera. The void seats off-center between them.
    private var collapsedVoidLeadingInset: CGFloat {
        layout.collapsedVoidLeadingInset
    }

    private var collapsedTrailingLaneWidth: CGFloat {
        max(0, collapsedSurfaceWidth - collapsedVoidLeadingInset - layout.voidWidth)
    }

    private var collapsedVoidCenterX: CGFloat {
        collapsedVoidLeadingInset + layout.voidWidth / 2
    }

    private var collapsedLeadingLaneCenterX: CGFloat {
        collapsedVoidLeadingInset / 2
    }

    private var collapsedTrailingLaneCenterX: CGFloat {
        collapsedSurfaceWidth - collapsedTrailingLaneWidth / 2
    }

    /// While the host is open it sits centered, but the collapsed chrome is still cross-dissolving out of
    /// that wider canvas. Because the collapsed surface seats the void off-center, a re-centered chrome
    /// would slide the void off the camera mid-animation. Shift the chrome by the void's offset from the
    /// surface center while the host is open so the void stays pinned to the camera. The host opens
    /// instantly (no animation) and `isHostExpanded` tracks it, so the shift jumps in step rather than
    /// sliding.
    private var collapsedChromeVoidShift: CGFloat {
        guard isHostExpanded, layout.voidWidth > 0 else { return 0 }
        return collapsedSurfaceWidth / 2 - collapsedVoidCenterX
    }

    private var currentConversationRow: some View {
        HStack(alignment: .top, spacing: 12) {
            DonkeyCursorMark(color: accentColor)
                .frame(width: 14, height: 14)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(conversationTitle)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)

                Text(statusDescription)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.42))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if isWorking, let started = primaryConversation?.createdAt {
                elapsedTimer(since: started)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(minHeight: 48)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            if let conversationID = primaryConversation?.id {
                conversationSelected(conversationID)
            }
        }
    }

    /// A count-up elapsed-time label for a running conversation — the timeline ticks every second on its
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

    /// Trailing room a row's text leaves for the pinned top-right controls, by control set: a lone Close
    /// (or Stop) button, or a Resume + Close pair. Permission rows carry their own banner controls.
    private func controlsReserve(for conversation: UserQueryConversation) -> CGFloat {
        // A system-driven row carries no controls (see `topRightControls`), so its text spans the full row.
        if !conversation.isUserControllable { return 0 }
        if conversation.status == .waitingForPermission { return 0 }
        return rowShowsControlPair(conversation) ? 74 : 44
    }

    /// Whether a row shows a two-button pair (Resume + Close, or Reply + Close) vs a single Close/Stop —
    /// mirrors `stateControls`, so the title/subtext reserve the right trailing room for the controls.
    private func rowShowsControlPair(_ conversation: UserQueryConversation) -> Bool {
        guard conversation.isUserControllable else { return false }
        switch conversation.status {
        case .paused, .interrupted, .timedOut, .waitingForClarification, .waitingForReview:
            return true
        case .needsAttention:
            return !conversation.commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return false
        }
    }

    /// Trailing room the subtext leaves for the bottom-pinned elapsed time at its widest (e.g. "59m 59s").
    private static let conversationTimeColumnReserve: CGFloat = 52

    /// Full opacity normally; while a reply is targeted, every row except the targeted one dims back so
    /// the user sees which thread their next message answers.
    private func rowReplyDimOpacity(for conversation: UserQueryConversation) -> Double {
        guard let replyTargetConversationID else { return 1 }
        return conversation.id == replyTargetConversationID ? 1 : 0.5
    }

    /// A conversation blocked on the user — the attention state. Its pointer stays lit and pulses even when the
    /// row dims for a reply, so every thread still waiting on the user reads at a glance. Broader than
    /// `isAwaitingUserResponse` (which gates the Reply button): a permission request also waits on the
    /// user and pulses for attention, but is answered with Approve / Deny rather than Reply.
    private func isWaitingOnUser(_ conversation: UserQueryConversation) -> Bool {
        Self.isWaitingOnUser(conversation)
    }

    static func isWaitingOnUser(_ conversation: UserQueryConversation) -> Bool {
        conversation.status.isAwaitingUserResponse || conversation.status == .waitingForPermission
    }

    private func conversationRow(_ conversation: UserQueryConversation) -> some View {
        let isPermission = conversation.status == .waitingForPermission
        // The reply dim is applied per-element rather than to the whole row so the pointer of a conversation that
        // itself needs the user can stay lit while everything else recedes.
        let contentDim = rowReplyDimOpacity(for: conversation)
        let isReplyTarget = replyTargetConversationID == conversation.id
        let isSelected = selectedConversationID == conversation.id
        let pointerDim = (isWaitingOnUser(conversation) || isSelected) ? 1 : contentDim
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                // Colored pointer while actively running; silhouette once stopped or finished — but the
                // reply target and the keyboard-highlighted row always show their live accent color, so
                // even a finished thread reads as active again while it is the focus.
                DonkeyCursorMark(
                    color: accentColor(for: conversation.accentIndex),
                    silhouette: !isReplyTarget && !isSelected && conversation.status != .running
                )
                    .frame(width: 14, height: 14)
                    .padding(.top, 1)
                    .opacity(pointerDim)
                    // A conversation waiting on the user gently pulses its pointer to call attention.
                    .modifier(AttentionPulse(active: isWaitingOnUser(conversation)))

                VStack(alignment: .leading, spacing: 4) {
                    Text(conversation.title)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // First line runs all the way to just left of the pinned top-right controls.
                        .padding(.trailing, controlsReserve(for: conversation))

                    if !isPermission {
                        Text(conversationStatusDescription(conversation))
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.42))
                            .lineLimit(Self.conversationSubtextLineLimit)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Subtext runs to just left of the controls, or the bottom-pinned elapsed time.
                            .padding(.trailing, max(controlsReserve(for: conversation), Self.conversationTimeColumnReserve))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(contentDim)
            }

            if isPermission {
                permissionBanner(for: conversation)
                    .opacity(contentDim)
            } else if showsReloadCreditsBanner(conversation) {
                reloadCreditsBanner(for: conversation)
                    .opacity(contentDim)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // The elapsed time is pinned to the cell bottom and the controls to the cell top, so a short
        // single-line row crowds the time right under the close button while a multi-line row spaces
        // them comfortably apart. Floor the row height to a two-line row's height so a one- or two-line
        // row renders at the same height and places the time identically; only genuinely long detail
        // grows past it (and never crowds the time).
        .frame(minHeight: 72)
        // The cell fill recedes with the rest of the content while a reply targets another row; a
        // keyboard-highlighted row instead brightens to full strength so the selection reads clearly.
        .background(Color.white.opacity(isSelected ? 0.16 : 0.07 * contentDim))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        // The highlight snaps rather than fading: the row scrolls into view instantly, so an
        // eased highlight would land ~0.12s later and read as "scroll first, then select."
        // Snapping lands the selection with the scroll, so the row reads as selected first.
        .onTapGesture {
            // A system-driven row (tool setup) isn't repliable — tapping it does nothing.
            guard conversation.isUserControllable else { return }
            // Every user row is repliable. Tapping the active thread again leaves reply mode; tapping any
            // other row pins it and focuses the composer, so the user can just start typing. (A running
            // or permission-gated thread takes the message as a queued follow-up; the rest resume.)
            if isReplyTarget {
                replyModeExited()
            } else {
                replyRequested(conversation.id)
            }
        }
        // Pinned to the full cell, matching the prototype insets: controls at top-8/right-12, elapsed
        // time at bottom-2.5/right-12, so the time stays near the cell bottom as the subtext grows.
        .overlay(alignment: .topTrailing) {
            if !isPermission {
                topRightControls(conversation)
                    .padding(.top, 8)
                    .padding(.trailing, 12)
                    .opacity(contentDim)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !isPermission {
                conversationElapsedLabel(conversation)
                    .padding(.bottom, 10)
                    .padding(.trailing, 12)
                    .opacity(contentDim)
            }
        }
    }

    /// Controls pinned to the row's top-right. Like the prototype, every conversation carries a real control:
    /// running → stop; paused → resume + close; everything else → close, so any conversation can be deleted.
    @ViewBuilder
    private func topRightControls(_ conversation: UserQueryConversation) -> some View {
        if !conversation.isUserControllable {
            // A system-driven row (tool setup) is the app's to run: the user watches it, but it carries no
            // Stop / Resume / Close — it can't be stopped or dismissed by hand.
            EmptyView()
        } else {
            switch conversation.status {
            case .waitingForPermission:
                // The permission banner carries its own Approve / Deny; the row needs no extra control.
                EmptyView()
            default:
                stateControls(for: conversation)
            }
        }
    }

    @ViewBuilder
    private func stateControls(for conversation: UserQueryConversation) -> some View {
        switch conversation.status {
        case .running:
            // Stop = pause (same affordance the prototype uses for a running conversation).
            NotchControlButton(systemName: "stop.fill", label: "Stop", isEnabled: true) {
                pauseRequested(conversation.id)
            }
        case .waitingForClarification, .waitingForReview:
            // The agent is blocked waiting on the user (the white attention glyph). Offer Reply so the
            // user can answer the question (or respond to the review) right from the row, plus Close.
            replyAndCloseControls(for: conversation)
        case .paused, .interrupted, .timedOut:
            // Paused (user), interrupted (changed course), and timed out (hit the step ceiling) all carry a
            // goal and real progress, so they are retryable: offer Resume + Close.
            resumeAndCloseControls(for: conversation)
        case .needsAttention:
            // A run cut short by a relaunch is retryable; but an info-only needsAttention row (e.g. an
            // asset drop) has no goal to resume, so it only gets Close — Resume there would dead-end.
            if conversation.commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                closeControl(for: conversation)
            } else {
                resumeAndCloseControls(for: conversation)
            }
        default:
            // Completed, failed, and chatting only carry Close. A completed thread is still repliable,
            // but by tapping the row (which activates it) rather than a button — see `conversationRow`'s tap.
            closeControl(for: conversation)
        }
    }

    @ViewBuilder
    private func resumeAndCloseControls(for conversation: UserQueryConversation) -> some View {
        HStack(spacing: 6) {
            NotchControlButton(systemName: "play.fill", label: "Resume", isEnabled: true) {
                resumeRequested(conversation.id)
            }
            NotchControlButton(systemName: "xmark", label: "Close", isEnabled: true) {
                dismissRequested(conversation.id)
            }
        }
    }

    /// A conversation waiting on the user gets Reply (answer the clarification / respond to the review) + Close.
    /// Reply pins the composer to this conversation and focuses the input; the user's next message answers it.
    @ViewBuilder
    private func replyAndCloseControls(for conversation: UserQueryConversation) -> some View {
        HStack(spacing: 6) {
            NotchTextButton(label: "Reply", isEnabled: true) {
                replyRequested(conversation.id)
            }
            NotchControlButton(systemName: "xmark", label: "Close", isEnabled: true) {
                dismissRequested(conversation.id)
            }
        }
    }

    private func closeControl(for conversation: UserQueryConversation) -> some View {
        NotchControlButton(systemName: "xmark", label: "Close", isEnabled: true) {
            dismissRequested(conversation.id)
        }
    }

    /// Live ticking time while running; a frozen total once the conversation has stopped or finished. Both use
    /// the prototype's row time style (10px, 55% white) so every row's time matches regardless of status.
    @ViewBuilder
    private func conversationElapsedLabel(_ conversation: UserQueryConversation) -> some View {
        if conversation.status == .running {
            TimelineView(.periodic(from: conversation.createdAt, by: 1)) { context in
                conversationElapsedText(Self.elapsedDescription(from: conversation.createdAt, to: context.date))
            }
        } else {
            conversationElapsedText(Self.elapsedDescription(from: conversation.createdAt, to: conversation.updatedAt))
        }
    }

    private func conversationElapsedText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .regular).monospacedDigit())
            .foregroundStyle(Color.white.opacity(0.55))
            .lineLimit(1)
            .fixedSize()
    }

    /// A permission request banner below the conversation text: the request reads on the left, Approve / Deny
    /// on the right. The system permission is only requested once the user taps Approve; Deny stops
    /// the conversation — the harness never reaches the system without the user's go-ahead.
    private func permissionBanner(for conversation: UserQueryConversation) -> some View {
        HStack(spacing: 8) {
            Text(permissionRequestText(conversation))
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.7))
                .lineLimit(2)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            permissionButton(label: "Approve", prominent: true) {
                approvePermissionRequested(conversation.id, false)
            }
            permissionButton(label: "Deny", prominent: false) {
                denyPermissionRequested(conversation.id)
            }
        }
        // Aligns the prompt under the conversation title (pointer width 14 + the row's 12 spacing) so it reads
        // as part of the row rather than a nested card.
        .padding(.leading, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Whether this conversation failed for lack of credits and should show the reload CTA. Read from the typed
    /// metadata flag the harness sets — never inferred from the narration text.
    private func showsReloadCreditsBanner(_ conversation: UserQueryConversation) -> Bool {
        conversation.metadata[UserQueryConversationMetadataKey.creditReloadRequired] == "true"
    }

    /// A reload CTA on a credit-exhausted conversation. Reuses the permission banner's button styling; tapping
    /// it opens the billing page so the user can top up, then re-run the conversation (Close is still on the row).
    private func reloadCreditsBanner(for conversation: UserQueryConversation) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "creditcard")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.7))

            Text("Add credits to continue")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            permissionButton(label: "Reload", prominent: true) {
                reloadCreditsRequested(conversation.id)
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
    private func permissionRequestText(_ conversation: UserQueryConversation) -> String {
        if let command = conversation.metadata["genericHarness.shellConsent.command"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            return "Allow Donkey to run \(command)"
        }

        let detail = conversation.detail.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// While replying, the composer is outlined in the targeted conversation's accent color so the input visibly
    /// belongs to that thread (matching the row's lit pointer).
    private var replyTargetAccentColor: Color? {
        guard let replyTargetConversationID,
              let conversation = conversations.first(where: { $0.id == replyTargetConversationID }) else {
            return nil
        }
        return accentColor(for: conversation.accentIndex)
    }

    /// The composer's outline color. The keyboard-highlighted row takes precedence — its accent rides on
    /// the input so the selection reads as the next thread the user will reply to — and falls back to the
    /// reply target's accent while one is pinned.
    private var composerAccentColor: Color? {
        if let selectedConversationID,
           let conversation = conversations.first(where: { $0.id == selectedConversationID }) {
            return accentColor(for: conversation.accentIndex)
        }
        return replyTargetAccentColor
    }

    private var commandRow: some View {
        UserQueryComposer(
            state: commandInputState,
            messageText: $commandText,
            inputTextHeight: commandInputTextHeight,
            isInputExpanded: isCommandInputExpanded,
            surfaceFill: Color.white.opacity(0.085),
            borderColor: composerAccentColor,
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

    private var conversationTitle: String {
        Self.conversationTitle(conversations: conversations, state: state)
    }

    /// The notch's headline text. Factored to a static so the controller can measure the exact string the
    /// pill renders when sizing the no-notch collapsed row for a wrapped second line.
    static func conversationTitle(conversations: [UserQueryConversation], state: UserQueryState) -> String {
        if let primary = conversations.first {
            return primary.title
        }

        if let display = conversationDisplayText(state: state) {
            return display
        }

        switch state.leadingSignalLevel {
        case .idle, .ready:
            return "Idle"
        case .thinking:
            return "Thinking"
        }
    }

    /// The collapsed headline. Normally the prompt (`conversationTitle`); but while the primary conversation waits on the
    /// user, the notch reads back the agent's question (carried in `detail`) instead, so the pill shows
    /// what the agent is asking rather than echoing what the user originally typed.
    private var collapsedHeadline: String {
        Self.collapsedHeadline(conversations: conversations, state: state)
    }

    public static func collapsedHeadline(conversations: [UserQueryConversation], state: UserQueryState) -> String {
        // The collapsed notch narrates the conversation's latest line — the same `chinDisplayText` the
        // chin band shows — so once the agent has replied it never reverts to echoing the original prompt
        // title (the "still says hi" bug). `chinDisplayText` already carries the right line in every
        // state: the agent's question while it waits, its reply once done, the prompt only before any
        // line exists. With no conversation at all, fall back to the typed prompt / idle headline.
        if let primary = conversations.first {
            return primary.chinDisplayText
        }
        return conversationTitle(conversations: conversations, state: state)
    }

    /// Whether the surfaced conversation is blocked on the user — drives the collapsed pointer's attention pulse.
    private var isPrimaryWaitingOnUser: Bool {
        guard let primaryConversation else { return false }
        return isWaitingOnUser(primaryConversation)
    }

    private var statusDescription: String {
        if let primaryConversation {
            return conversationStatusDescription(primaryConversation)
        }

        if isCurrentConversationPaused {
            return "Paused"
        }

        switch state.leadingSignalLevel {
        case .idle, .ready:
            return hasConversationDisplayText ? "Needs attention" : "Idle"
        case .thinking:
            return "Thinking"
        }
    }

    /// The collapsed right gutter follows the prototype exactly: it only ever carries an icon or the
    /// live clock — and the icon shows ONLY when a conversation is actively blocked on the user (a question to
    /// answer, a review to give, or a permission to approve), the run time while a conversation runs, or an
    /// update cloud, otherwise nothing. A finished conversation is never labelled here; it keeps surfacing as a
    /// colored pointer + chin line instead. Crucially, a benign `needsAttention` conversation (an interrupted
    /// run restored across launches, an upload, a failed resume) does NOT raise the attention glyph —
    /// it is not waiting on the user, so it stays out of the gutter and surfaces only in the list. The
    /// time only rides alongside the chin (a running conversation always narrates), so the gutter never shows a
    /// lonely clock; every state's full elapsed total lives in the expanded row.
    @ViewBuilder
    private var collapsedRightSlot: some View {
        if surfacedErrorConversation != nil {
            // A surfaced failure (e.g. an auth error) raises the red warning glyph here while its message
            // holds the chin, until the user expands to acknowledge it.
            attentionGlyph(color: Self.chinErrorColor)
        } else if let conversation = primaryConversation {
            switch conversation.status {
            case .waitingForClarification, .waitingForReview:
                // Attention: the agent is blocked waiting for the user to answer or review something.
                attentionGlyph()
            case .waitingForPermission:
                // Waiting on the user, same as a clarification or review — show the attention glyph.
                attentionGlyph()
            case .running:
                fullLiveTime(since: conversation.createdAt)
            case .completed, .paused, .interrupted, .failed, .chatting, .needsAttention, .timedOut:
                // The gutter only ever carries the waiting-on-user icons or the live clock — a completed
                // conversation keeps surfacing as a colored pointer + chin line, and the rest (including a benign
                // needsAttention or a retryable timed-out run) surface in the list without nagging the
                // collapsed gutter.
                EmptyView()
            }
        } else if updateState.isActionable {
            // App update available.
            slotIcon("icloud.and.arrow.down")
        } else {
            EmptyView()
        }
    }

    /// The surfaced failure currently holding the chin, if any — drives the right-rail warning glyph.
    private var surfacedErrorConversation: UserQueryConversation? {
        surfacedConversations.first { $0.status == .failed }
    }

    private func slotIcon(_ systemName: String, color: Color = Color.white.opacity(0.85)) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(color)
    }

    /// The waiting-on-user attention glyph: the prototype's `MessageCircleWarning`. SF Symbols has no
    /// faithful circular message-with-exclamation mark, so it is ported as a path (see
    /// `DonkeyAttentionGlyph`) and rendered at the slot-icon's optical size.
    private func attentionGlyph(color: Color = Color.white.opacity(0.85)) -> some View {
        DonkeyAttentionGlyph(color: color)
            .frame(width: Self.attentionGlyphSize, height: Self.attentionGlyphSize)
    }

    /// Sized to read alongside the 11pt slot text/clock; the Lucide art carries internal padding, so the
    /// frame runs a touch larger than the SF-symbol icons to land at the same optical weight.
    private static let attentionGlyphSize: CGFloat = 13

    private func slotText(_ text: String, opacity: Double = 0.72) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .regular).monospacedDigit())
            .foregroundStyle(Color.white.opacity(opacity))
            .lineLimit(1)
            .fixedSize()
    }

    /// Full elapsed time (hours, minutes, and seconds) for the collapsed right gutter. The gutter's
    /// trailing lane is sized to fit the whole running total beside the camera, so the clock never
    /// collapses to a single unit.
    private func fullLiveTime(since start: Date) -> some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            slotText(Self.elapsedDescription(from: start, to: context.date))
        }
    }

    private var isWorking: Bool {
        primaryConversation?.status == .running || state.leadingSignalLevel == .thinking
    }

    private var hasConversationDisplayText: Bool {
        !conversations.isEmpty || conversationDisplayText != nil
    }

    private var conversationDisplayText: String? {
        Self.conversationDisplayText(state: state)
    }

    static func conversationDisplayText(state: UserQueryState) -> String? {
        let text = UserQueryCopy.normalizedDisplayText(state.promptText)
        guard UserQueryCopy.isConversationDisplayText(text) else {
            return nil
        }

        return text
    }

    private var isResting: Bool {
        (state.leadingSignalLevel == .idle || state.leadingSignalLevel == .ready) && !hasConversationDisplayText
    }

    private var accentColor: Color {
        accentColor(for: primaryConversation?.accentIndex ?? accentIndex)
    }

    private var primaryConversation: UserQueryConversation? {
        conversations.first
    }


    /// The conversation's status line, resolved through the centralized activity vocabulary so the notch and
    /// the future conversation view speak the same language.
    private func conversationStatusDescription(_ conversation: UserQueryConversation) -> String {
        UserQueryActivity.current(for: conversation).displayText
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

    /// The surface curve, chosen per direction: opening springs out (like the prototype's
    /// cubic-bezier(0.2,0.9,0.24,1)); closing eases shut a touch faster. The host window shrink on
    /// close (closeAnimationDuration) is timed to land just after the close curve settles.
    private var surfaceAnimation: Animation {
        surfaceIsOpen ? Self.surfaceOpenAnimation : Self.surfaceCloseAnimation
    }

    // Open grows the surface on the prototype's exact curve (cubic-bezier(0.2,0.9,0.24,1) over 550ms),
    // a decelerating ease with no overshoot. Close eases shut on the faster 220ms curve the prototype's
    // outer clip uses, which is what perceptually drives the collapse; the host shrink
    // (closeAnimationDuration) is timed to land just after it.
    private static let surfaceOpenAnimation = Animation.timingCurve(0.2, 0.9, 0.24, 1, duration: 0.55)
    private static let surfaceCloseAnimation = Animation.easeOut(duration: 0.22)
    /// The collapsed chrome cross-dissolves as the surface grows/collapses (prototype: 150ms).
    private static let collapsedChromeAnimation = Animation.easeOut(duration: 0.15)

    // The content fades in 150ms after the surface starts growing (prototype: `opacity 300ms ease-out
    // 150ms`) so the box opens first and the rows then appear, and out fast on close. These win over
    // the surface curve for the content subtree because they are attached closer to the leaf.
    private static let expandedContentAnimation = Animation.easeOut(duration: 0.3).delay(0.15)
    private static let expandedContentDismissAnimation = Animation.easeOut(duration: 0.1)
    private static let contentInset: CGFloat = 14
    private static let conversationListCommandSpacing: CGFloat = 8
    /// Expanded row subtext is a generous preview, not a data cap: the full line is kept in state and
    /// the row tail-truncates only after five rendered lines.
    private static let conversationSubtextLineLimit = 5
    /// The collapsed leading lane shows at most this many overlapping pointers; extra surfaced conversations
    /// are still listed when the notch is expanded.
    private static let maxClusterPointers = 3
    private static let clusterStepX: CGFloat = 8
    private static let clusterStepY: CGFloat = 3
    /// Chin text metrics, matching the band geometry the controller sizes (10pt on a 12pt line with an
    /// 8pt bottom margin). The text is seated above that bottom margin so it stays constant as the band
    /// grows for a second line.
    private static let chinFontSize: CGFloat = 12
    private static let chinBottomMargin: CGFloat = 8
    /// The failed-chin warning red. Mirrors the prototype's `ERROR_RED` (rgb(255, 69, 58)) exactly — it
    /// is the one place this hue is needed in the app, so it stays a literal rather than a shared token,
    /// kept in sync with conversations.ts by value.
    private static let chinErrorColor = Color(red: 1.0, green: 69.0 / 255.0, blue: 58.0 / 255.0)
    /// The chin advances to the next running conversation every 2.6s, on a clock shared by all conversations.
    private static let chinRotationInterval: TimeInterval = 2.6
    private static let chinRotationAnchor = Date(timeIntervalSinceReferenceDate: 0)
}

/// The notch silhouette as an animatable clip: an `UnevenRoundedRectangle` (square top, rounded
/// bottom) of the given size, pinned to the top center of whatever rect it is asked to fill. Animating
/// `width`/`height`/`cornerRadius` grows or shrinks the opening from the closed notch outward while the
/// content it clips stays fixed underneath, so the notch appears to expand in place rather than the
/// content moving.
private struct GrowingNotchShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(width, AnimatablePair(height, cornerRadius)) }
        set {
            width = newValue.first
            height = newValue.second.first
            cornerRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let clampedWidth = min(max(0, width), rect.width)
        let clampedHeight = min(max(0, height), rect.height)
        let radius = min(cornerRadius, clampedWidth / 2, clampedHeight / 2)
        let opening = CGRect(
            x: (rect.width - clampedWidth) / 2,
            y: 0,
            width: clampedWidth,
            height: clampedHeight
        )
        return UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: 0,
                bottomLeading: radius,
                bottomTrailing: radius,
                topTrailing: 0
            ),
            style: .continuous
        )
        .path(in: opening)
    }
}

/// A round row control (stop / resume / close). Like the prototype's control buttons it brightens its
/// fill on hover (white 12% → 20%), so the X and its siblings highlight under the cursor.
private struct NotchControlButton: View {
    private let icon: AnyView
    private let label: String
    private let isEnabled: Bool
    private let action: @MainActor () -> Void

    @State private var isHovering = false

    /// SF Symbol control (stop / resume / close).
    init(
        systemName: String,
        label: String,
        isEnabled: Bool = true,
        action: @escaping @MainActor () -> Void
    ) {
        self.init(label: label, isEnabled: isEnabled, action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .regular))
        }
    }

    /// Custom-icon control (e.g. the ported lucide Reply glyph). The icon inherits the button's
    /// foreground tint, so a stroked shape reads the same enabled/hover color as an SF Symbol.
    init<Icon: View>(
        label: String,
        isEnabled: Bool = true,
        action: @escaping @MainActor () -> Void,
        @ViewBuilder icon: () -> Icon
    ) {
        self.icon = AnyView(icon())
        self.label = label
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            icon
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

/// A rectangular text control (e.g. Reply). Shares NotchControlButton's enabled/hover tinting, but
/// renders a labeled pill instead of a 24×24 icon circle so the action reads as a word, not a glyph.
private struct NotchTextButton: View {
    let label: String
    let isEnabled: Bool
    let action: @MainActor () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(isEnabled ? 0.88 : 0.3))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Color.white.opacity(backgroundOpacity))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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

/// A gentle, slow pulse (scale + fade) used to call attention to a conversation that is waiting on the user,
/// without the urgency of the running-pointer pulse. Inert until `active`, so non-waiting rows are still.
private struct AttentionPulse: ViewModifier {
    let active: Bool
    @State private var pulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(active && pulsing ? 1.1 : 1.0)
            .opacity(active && pulsing ? 0.7 : 1.0)
            .onAppear { startIfNeeded() }
            .onChange(of: active) { startIfNeeded() }
    }

    private func startIfNeeded() {
        // Reset when inactive so a thread that re-enters a waiting state (e.g. a second clarification)
        // re-arms the pulse instead of being blocked by the stale `pulsing` flag.
        guard active else {
            pulsing = false
            return
        }
        guard !pulsing else { return }
        withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
            pulsing = true
        }
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

/// The waiting-on-user attention mark. Geometry is ported verbatim from the prototype's Notch icon —
/// Lucide `MessageCircleWarning` (24×24 viewBox, stroked at width 1.9, round caps/joins) — so the app
/// and landing-page prototype show the same glyph. The bubble's elliptical arcs are expressed as cubic
/// Béziers; the exclamation is a vertical stroke plus a zero-length round-capped segment for the dot.
private struct DonkeyAttentionGlyph: View {
    var color: Color

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width, proxy.size.height) / 24
            Self.glyphPath(scale: scale)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: 1.9 * scale, lineCap: .round, lineJoin: .round)
                )
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private static func glyphPath(scale: CGFloat) -> Path {
        Path { path in
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * scale, y: y * scale)
            }

            // Speech-bubble outline (Lucide's circle + tail).
            path.move(to: point(2.992, 16.342))
            path.addCurve(to: point(3.086, 17.509), control1: point(3.139, 16.713), control2: point(3.172, 17.119))
            path.addLine(to: point(2.021, 20.799))
            path.addCurve(to: point(2.314, 21.727), control1: point(1.951, 21.138), control2: point(2.062, 21.489))
            path.addCurve(to: point(3.257, 21.967), control1: point(2.565, 21.965), control2: point(2.922, 22.056))
            path.addLine(to: point(6.670, 20.969))
            path.addCurve(to: point(7.769, 21.061), control1: point(7.038, 20.896), control2: point(7.419, 20.928))
            path.addCurve(to: point(20.208, 17.713), control1: point(12.178, 23.120), control2: point(17.428, 21.707))
            path.addCurve(to: point(19.028, 4.886), control1: point(22.987, 13.720), control2: point(22.489, 8.306))
            path.addCurve(to: point(6.187, 3.863), control1: point(15.567, 1.467), control2: point(10.147, 1.035))
            path.addCurve(to: point(2.992, 16.342), control1: point(2.228, 6.692), control2: point(0.880, 11.959))
            path.closeSubpath()

            // Exclamation stroke.
            path.move(to: point(12, 8))
            path.addLine(to: point(12, 12))

            // Exclamation dot: a zero-length segment that the round line cap renders as a dot.
            path.move(to: point(12, 16))
            path.addLine(to: point(12.01, 16))
        }
    }
}

private final class DroppedAssetCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var drafts: [UserQueryConversationAssetDraft] = []

    func append(_ draft: UserQueryConversationAssetDraft) {
        lock.lock()
        drafts.append(draft)
        lock.unlock()
    }

    func values() -> [UserQueryConversationAssetDraft] {
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

    static func assetDraft(for url: URL) -> UserQueryConversationAssetDraft? {
        guard url.isFileURL else { return nil }

        let contentType = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredMIMEType)
            ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.int64Value
        return UserQueryConversationAssetDraft(
            displayName: url.lastPathComponent,
            contentType: contentType,
            urlString: url.absoluteString,
            byteCount: byteCount
        )
    }
}
