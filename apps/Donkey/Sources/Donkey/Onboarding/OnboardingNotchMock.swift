// The notch demo: the screen edge with a collapsed component that grows into the
// full conversation panel, driven by a simulated pointer. One view drives four
// slide behaviours (loop, static panel, open-composer, compose-and-run); the
// pointer path and timings are gathered in `OnboardingNotchMockTuning` — the
// single place to tune the staged behaviour. Built on `OnboardingMockKit`.

import SwiftUI

// MARK: - Tuning (the simulation script + layout)

/// Every knob the notch mock exposes: where the edge and pointer sit, the
/// collapsed/expanded surface sizes, and the timing of each staged step. This is
/// the room left to simulate the pointer and timer behaviour — adjust here.
struct OnboardingNotchMockTuning {
    // Layout, as fractions of the artwork region unless noted. The notch drops
    // from the same line as the sign-in slide (`OnboardingSignInMock`), so the
    // tour's notch sits at a consistent height as the user pages forward.
    var edgeYFraction: CGFloat = 0.13
    var edgeWidthFraction: CGFloat = 1.0
    var collapsedWidth: CGFloat = 286
    var collapsedHeight: CGFloat = 38
    var expandedWidth: CGFloat = 392
    /// Expanded height grows with the row count, capped to the region.
    var expandedBaseHeight: CGFloat = 78
    var rowHeight: CGFloat = 80
    var collapsedCorner: CGFloat = 18
    var expandedCorner: CGFloat = 26

    // The animated pointer: a filled, accent-colored donkey cursor.
    var pointerSize: CGFloat = 28
    var pointerAccentIndex: Int = 3
    /// The glyph tip's offset from its frame centre, so a click lands the tip.
    var tipOffset = CGSize(width: 9, height: 12)

    // Pointer rest position (fraction of region) and the hover target offset
    // from the notch centre (points).
    var pointerRestX: CGFloat = 0.77
    var pointerRestY: CGFloat = 0.82
    var pointerHoverDX: CGFloat = 16
    var pointerHoverDY: CGFloat = 30

    // Timings, seconds — the staged loop.
    var runningHold: Double = 1.9      // collapsed + running before the pointer moves in
    var pointerTravel: Double = 0.9    // pointer drift from rest to the notch
    var expandedHold: Double = 2.9     // dwell expanded under the pointer
    var pointerRetreat: Double = 0.6   // pointer drift back to rest on collapse
    var loopGap: Double = 1.1          // settle before the loop repeats
}

// MARK: - Notch mock

/// The staged mock: the screen edge, the collapsed/expanded notch surface that
/// grows from the edge, and a simulated pointer that drifts in to trigger the
/// expansion. Purely decorative — it never takes hit-testing, so the slideshow's
/// own controls stay clickable through it.
/// How the notch mock behaves on a slide.
enum OnboardingNotchMockMode {
    /// Collapse → pointer drifts in → expand → dwell → collapse, on a loop.
    case loop
    /// Static: just the expanded conversation panel, centered, no pointer.
    case expandedPanel
    /// One-shot: pointer flies in, the notch expands and stays open, then the
    /// pointer clicks the composer and the text caret is left blinking.
    case openComposer
    /// One-shot: pointer expands the notch, clicks the composer, types a command,
    /// clicks send, then vanishes while the task runs in the notch.
    case composeAndRun
}

struct OnboardingNotchMock: View {
    let conversations: [OnboardingMockConversation]
    let mode: OnboardingNotchMockMode
    var tuning: OnboardingNotchMockTuning

    private enum Phase { case collapsed, expanded }

    @State private var phase: Phase
    @State private var pointer: CGPoint = .zero
    @State private var pointerVisible = false
    @State private var pressed = false
    @State private var halo = false
    @State private var haloPoint: CGPoint = .zero
    @State private var composerFocused = false
    @State private var composerCaretVisible = false
    /// Text typed into the composer (`.composeAndRun`).
    @State private var composerText = ""
    /// Whether the typed prompt has been sent and is now running in the notch.
    @State private var sentTask = false
    /// When the sent task started, so its clock counts up from the send.
    @State private var sentAt = Date()
    /// Anchors every timer in the scene; reset each time the slide reappears.
    @State private var appearedAt = Date()

    init(
        conversations: [OnboardingMockConversation],
        mode: OnboardingNotchMockMode = .loop,
        tuning: OnboardingNotchMockTuning = OnboardingNotchMockTuning()
    ) {
        self.conversations = conversations
        self.mode = mode
        self.tuning = tuning
        _phase = State(initialValue: mode == .expandedPanel ? .expanded : .collapsed)
    }

    // Surface grow/shrink curves, copied from the real notch (prototype's
    // cubic-bezier(0.2,0.9,0.24,1) open; faster ease-out close).
    private static let surfaceOpen = Animation.timingCurve(0.2, 0.9, 0.24, 1, duration: 0.55)
    private static let surfaceClose = Animation.easeOut(duration: 0.22)
    private static let contentReveal = Animation.easeOut(duration: 0.3).delay(0.12)
    private static let contentHide = Animation.easeOut(duration: 0.1)

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                OnboardingScreenEdge(color: OnboardingPalette.ink.opacity(0.35))
                    .frame(width: size.width * tuning.edgeWidthFraction)
                    .position(x: size.width / 2, y: edgeY(size))

                notchSurface(size: size)

                if mode != .expandedPanel {
                    if halo {
                        Circle()
                            .stroke(onboardingAccent(tuning.pointerAccentIndex).opacity(0.7), lineWidth: 2)
                            .frame(width: 40, height: 40)
                            .position(haloPoint)
                            .transition(.opacity)
                    }

                    OnboardingCursorMark(color: onboardingAccent(tuning.pointerAccentIndex))
                        .frame(width: tuning.pointerSize, height: tuning.pointerSize)
                        .scaleEffect(pressed ? 0.86 : 1, anchor: .topTrailing)
                        .shadow(color: Color.black.opacity(0.28), radius: 3, x: 0, y: 1)
                        .position(pointer)
                        .opacity(pointerVisible ? 1 : 0)
                }
            }
            .frame(width: size.width, height: size.height)
            .task {
                switch mode {
                case .loop: await runLoop(in: size)
                case .expandedPanel: break
                case .openComposer: await runOpenComposer(in: size)
                case .composeAndRun: await runComposeAndRun(in: size)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Surface

    @ViewBuilder
    private func notchSurface(size: CGSize) -> some View {
        let canvasH = expandedHeight(in: size)
        let openW = phase == .expanded ? tuning.expandedWidth : tuning.collapsedWidth
        let openH = phase == .expanded ? canvasH : tuning.collapsedHeight
        let corner = phase == .expanded ? tuning.expandedCorner : tuning.collapsedCorner
        let shape = OnboardingNotchShape(width: openW, height: openH, cornerRadius: corner)

        ZStack(alignment: .top) {
            Color.black

            collapsedContent
                .frame(width: tuning.collapsedWidth, height: tuning.collapsedHeight)
                .frame(maxWidth: .infinity, alignment: .top)
                .opacity(phase == .expanded ? 0 : 1)
                .animation(Self.contentHide, value: phase)

            expandedContent
                .opacity(phase == .expanded ? 1 : 0)
                .animation(phase == .expanded ? Self.contentReveal : Self.contentHide, value: phase)
        }
        .frame(width: tuning.expandedWidth, height: canvasH, alignment: .top)
        .clipShape(shape)
        .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 1))
        .animation(phase == .expanded ? Self.surfaceOpen : Self.surfaceClose, value: phase)
        .position(x: size.width / 2, y: edgeY(size) + canvasH / 2)
    }

    // MARK: Collapsed content (cursor cluster + rotating prompt + clock)

    private var collapsedContent: some View {
        // The chin advances to the next running task every 2.6s, the real notch's
        // rotation; the lit pointer takes the speaking task's accent.
        TimelineView(.periodic(from: appearedAt, by: 2.6)) { context in
            let speaker = rotatingSpeaker(at: context.date)
            HStack(spacing: 7) {
                collapsedPointerCluster(speaker: speaker)
                    .frame(width: clusterWidth, height: 16)

                Text(speaker?.prompt ?? "")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                if let speaker, speaker.isRunning {
                    OnboardingElapsedClock(
                        appearedAt: appearedAt,
                        offset: speaker.elapsedOffset,
                        font: .system(size: 11, weight: .regular).monospacedDigit(),
                        color: Color.white.opacity(0.5)
                    )
                }
            }
            .padding(.horizontal, 13)
        }
    }

    /// The tasks the notch should show right now. In `.composeAndRun` the notch
    /// shows only the settled idle tasks until the typed prompt is sent — so it
    /// never looks empty — then the new running task joins them on top.
    private var effectiveConversations: [OnboardingMockConversation] {
        if mode == .composeAndRun && !sentTask {
            return conversations.filter { !$0.isRunning }
        }
        return conversations
    }

    private var runningConversations: [OnboardingMockConversation] {
        effectiveConversations.filter(\.isRunning)
    }

    private func rotatingSpeaker(at date: Date) -> OnboardingMockConversation? {
        let running = runningConversations
        guard !running.isEmpty else { return effectiveConversations.first }
        let step = Int(date.timeIntervalSince(appearedAt) / 2.6)
        return running[((step % running.count) + running.count) % running.count]
    }

    private var clusterWidth: CGFloat {
        let count = min(runningConversations.count, 3)
        return 14 + 7 * CGFloat(max(0, count - 1))
    }

    @ViewBuilder
    private func collapsedPointerCluster(speaker: OnboardingMockConversation?) -> some View {
        let cluster = Array(runningConversations.prefix(3))
        if cluster.isEmpty {
            OnboardingCursorMark(color: onboardingAccent(0), silhouette: true)
                .frame(width: 14, height: 14)
        } else {
            ZStack(alignment: .topLeading) {
                // Oldest first so the newest pointer lands on top of the cascade.
                ForEach(Array(cluster.reversed().enumerated()), id: \.element.id) { index, convo in
                    OnboardingCursorMark(
                        color: onboardingAccent(convo.accentIndex),
                        silhouette: convo.id != speaker?.id
                    )
                    .frame(width: 14, height: 14)
                    .offset(x: 7 * CGFloat(index), y: 3 * CGFloat(index))
                    .zIndex(convo.id == speaker?.id ? 10 : Double(index))
                }
            }
        }
    }

    // MARK: Expanded content (rows + composer)

    private var expandedContent: some View {
        VStack(spacing: 8) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(effectiveConversations) { expandedRow($0) }
                }
            }

            composer
        }
        .padding(14)
    }

    private func expandedRow(_ convo: OnboardingMockConversation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            OnboardingCursorMark(
                color: onboardingAccent(convo.accentIndex),
                silhouette: !convo.isRunning
            )
            .frame(width: 14, height: 14)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(convo.prompt)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(convo.status)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.42))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if convo.isRunning {
                OnboardingElapsedClock(
                    appearedAt: mode == .composeAndRun ? sentAt : appearedAt,
                    offset: mode == .composeAndRun ? 0 : convo.elapsedOffset,
                    font: .system(size: 11, weight: .regular).monospacedDigit(),
                    color: Color.white.opacity(0.5)
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 9)
            }
        }
    }

    private var composer: some View {
        let hasText = !composerText.isEmpty
        let caretShown = composerFocused && composerCaretVisible
        return HStack(alignment: .bottom, spacing: 8) {
            Group {
                if hasText {
                    // The caret rides at the end of the text and wraps with it, so
                    // the line grows as the command is typed.
                    Text("\(composerText)\(caretShown ? "▏" : "")")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 3) {
                        if composerFocused {
                            RoundedRectangle(cornerRadius: 1, style: .continuous)
                                .fill(Color.white)
                                .frame(width: 2, height: 15)
                                .opacity(composerCaretVisible ? 1 : 0)
                        }
                        Text("What can donkey do for you?")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Image(systemName: "arrow.up")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.black.opacity(hasText ? 0.8 : 0.55))
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(hasText ? 0.95 : 0.7))
                .clipShape(Circle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(minHeight: 40, alignment: .bottom)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.white.opacity(composerFocused ? 0.28 : 0.1), lineWidth: 1)
        )
    }

    // MARK: Geometry

    private func edgeY(_ size: CGSize) -> CGFloat { size.height * tuning.edgeYFraction }

    private func restPoint(_ size: CGSize) -> CGPoint {
        CGPoint(x: size.width * tuning.pointerRestX, y: size.height * tuning.pointerRestY)
    }

    private func hoverPoint(_ size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + tuning.pointerHoverDX, y: edgeY(size) + tuning.pointerHoverDY)
    }

    private func offscreenStart(_ size: CGSize) -> CGPoint {
        CGPoint(x: size.width + 70, y: size.height * 0.9)
    }

    private func expandedHeight(in size: CGSize) -> CGFloat {
        let needed = tuning.expandedBaseHeight
            + CGFloat(effectiveConversations.count) * tuning.rowHeight
            + composerExtraHeight
        // Leave room for the slide's bottom fade and page dots; when the rows
        // don't fit, the panel caps here and the row ScrollView scrolls.
        let maxH = size.height - edgeY(size) - 84
        return min(needed, max(tuning.collapsedHeight, maxH))
    }

    /// Extra panel height for a composer that has wrapped past one line as the
    /// command is typed (≈ one 13pt line per extra row).
    private var composerExtraHeight: CGFloat {
        CGFloat(composerLineCount - 1) * 17
    }

    private var composerLineCount: Int {
        guard !composerText.isEmpty else { return 1 }
        // Text area = panel inset (28) + composer padding (24) + send (22) + gap (8).
        let contentWidth = tuning.expandedWidth - 82
        let perLine = max(8, Int(contentWidth / 7.2))
        let lines = Int(ceil(Double(composerText.count) / Double(perLine)))
        return min(3, max(1, lines))
    }

    /// The composer's centre within the artwork region, used as the click target
    /// in `.openComposer`. The composer sits at the panel's bottom (14pt inset,
    /// 40pt tall → centre 34pt up from the panel's bottom edge).
    private func composerPoint(in size: CGSize) -> CGPoint {
        let canvasH = expandedHeight(in: size)
        let panelCenterY = edgeY(size) + canvasH / 2
        return CGPoint(x: size.width / 2 - tuning.expandedWidth * 0.28, y: panelCenterY + canvasH / 2 - 34)
    }

    /// The composer's send button centre — trailing inside the composer row.
    private func composerSendPoint(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + tuning.expandedWidth / 2 - 37, y: composerPoint(in: size).y)
    }

    // MARK: Simulation

    /// The staged loop: hold collapsed + running, drift the pointer in, expand on
    /// "hover", dwell, then collapse and retreat — repeating for the slide's life.
    @MainActor
    private func runLoop(in size: CGSize) async {
        pointer = restPoint(size)
        pointerVisible = true
        haloPoint = hoverPoint(size)

        while !Task.isCancelled {
            withAnimation(Self.surfaceClose) {
                phase = .collapsed
                halo = false
            }
            if await sleep(tuning.runningHold) == false { return }

            withAnimation(.easeInOut(duration: tuning.pointerTravel)) {
                pointer = hoverPoint(size)
            }
            if await sleep(tuning.pointerTravel) == false { return }

            withAnimation(Self.surfaceOpen) { phase = .expanded }
            withAnimation(.easeOut(duration: 0.25)) { halo = true }
            if await sleep(tuning.expandedHold) == false { return }

            withAnimation(Self.surfaceClose) {
                phase = .collapsed
                halo = false
            }
            withAnimation(.easeInOut(duration: tuning.pointerRetreat)) {
                pointer = restPoint(size)
            }
            if await sleep(tuning.loopGap) == false { return }
        }
    }

    /// One-shot: the pointer flies in from offscreen, the notch expands and stays
    /// open, then the pointer crosses to the composer, clicks it, and the text
    /// caret is left blinking in the focused field.
    @MainActor
    private func runOpenComposer(in size: CGSize) async {
        pointer = offscreenStart(size)
        pointerVisible = true
        haloPoint = hoverPoint(size)

        // Fly in to the notch and expand.
        withAnimation(.easeInOut(duration: tuning.pointerTravel)) { pointer = hoverPoint(size) }
        if await sleep(tuning.pointerTravel) == false { return }
        withAnimation(Self.surfaceOpen) { phase = .expanded }
        withAnimation(.easeOut(duration: 0.25)) { halo = true }
        if await sleep(0.5) == false { return }
        withAnimation(.easeOut(duration: 0.3)) { halo = false }
        if await sleep(0.5) == false { return }

        // Cross to the composer and click it.
        let composer = composerPoint(in: size)
        let target = CGPoint(x: composer.x - tuning.tipOffset.width, y: composer.y + tuning.tipOffset.height)
        haloPoint = composer
        withAnimation(.easeInOut(duration: tuning.pointerTravel)) { pointer = target }
        if await sleep(tuning.pointerTravel) == false { return }
        withAnimation(.easeOut(duration: 0.10)) {
            pressed = true
            halo = true
        }
        if await sleep(0.12) == false { return }
        withAnimation(.easeOut(duration: 0.12)) { pressed = false }
        withAnimation(.easeOut(duration: 0.3)) { halo = false }

        // Leave the composer focused with a blinking caret.
        composerFocused = true
        while !Task.isCancelled {
            composerCaretVisible = true
            if await sleep(0.5) == false { return }
            composerCaretVisible = false
            if await sleep(0.5) == false { return }
        }
    }

    /// One-shot: the pointer expands the notch, clicks the composer, types the
    /// command, clicks send, then vanishes while the prompt runs in the notch.
    @MainActor
    private func runComposeAndRun(in size: CGSize) async {
        pointer = offscreenStart(size)
        pointerVisible = true
        haloPoint = hoverPoint(size)

        // Fly in and expand.
        withAnimation(.easeInOut(duration: tuning.pointerTravel)) { pointer = hoverPoint(size) }
        if await sleep(tuning.pointerTravel) == false { return }
        withAnimation(Self.surfaceOpen) { phase = .expanded }
        withAnimation(.easeOut(duration: 0.25)) { halo = true }
        if await sleep(0.45) == false { return }
        withAnimation(.easeOut(duration: 0.3)) { halo = false }
        if await sleep(0.35) == false { return }

        // Click the composer to focus it.
        let composer = composerPoint(in: size)
        let composerTarget = CGPoint(x: composer.x - tuning.tipOffset.width, y: composer.y + tuning.tipOffset.height)
        haloPoint = composer
        withAnimation(.easeInOut(duration: tuning.pointerTravel)) { pointer = composerTarget }
        if await sleep(tuning.pointerTravel) == false { return }
        withAnimation(.easeOut(duration: 0.10)) {
            pressed = true
            halo = true
        }
        if await sleep(0.12) == false { return }
        withAnimation(.easeOut(duration: 0.12)) { pressed = false }
        withAnimation(.easeOut(duration: 0.3)) { halo = false }
        composerFocused = true
        composerCaretVisible = true
        if await sleep(0.3) == false { return }

        // Type the command into the composer (the running task is the one being composed).
        let command = (conversations.first(where: { $0.isRunning }) ?? conversations.first)?.prompt ?? ""
        for character in command {
            composerText.append(character)
            if await sleep(0.045) == false { return }
        }
        if await sleep(0.45) == false { return }

        // Cross to the send button and click it.
        let sendPoint = composerSendPoint(in: size)
        let sendTarget = CGPoint(x: sendPoint.x - tuning.tipOffset.width, y: sendPoint.y + tuning.tipOffset.height)
        haloPoint = sendPoint
        withAnimation(.easeInOut(duration: tuning.pointerTravel)) { pointer = sendTarget }
        if await sleep(tuning.pointerTravel) == false { return }
        withAnimation(.easeOut(duration: 0.10)) {
            pressed = true
            halo = true
        }
        if await sleep(0.12) == false { return }
        withAnimation(.easeOut(duration: 0.12)) { pressed = false }
        withAnimation(.easeOut(duration: 0.3)) { halo = false }

        // Send: clear the composer and reveal the running task.
        composerText = ""
        composerFocused = false
        sentAt = Date()
        withAnimation(.easeOut(duration: 0.25)) { sentTask = true }

        // The pointer vanishes; the task keeps running in the notch.
        withAnimation(.easeOut(duration: 0.3)) { pointerVisible = false }
    }

    /// Sleeps for `seconds`, returning false if the task was cancelled (slide left).
    private func sleep(_ seconds: Double) async -> Bool {
        do {
            try await Task.sleep(for: .seconds(seconds))
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}
