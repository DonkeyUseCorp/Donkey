// The command-field demo: a mock of the Donkey input field that types itself out,
// then a colored donkey pointer flies in from offscreen, clicks send, and
// vanishes — cycling through example commands and accent colors. One variant
// types straight away; the other summons the field with a double-⌘ first. Built
// on `OnboardingMockKit`.

import SwiftUI

// MARK: - Tuning

/// Knobs for the typed-command demo: the field's size and position, the
/// caret-blink and typewriter cadence, and the colored pointer's travel. The
/// room left to tune the typing and pointer behaviour.
struct OnboardingInputMockTuning {
    // The real command composer's geometry (UserQueryLayout): a 576×66 black
    // capsule with a 28pt mic and a 36.8pt send circle pinned trailing, here
    // trimmed 10% narrower for the tour.
    var fieldWidth: CGFloat = 518
    var fieldHeight: CGFloat = 66
    var leadingPadding: CGFloat = 20
    var trailingPadding: CGFloat = 14.6
    var textControlsSpacing: CGFloat = 12
    var controlsSpacing: CGFloat = 16
    var micSize: CGFloat = 28
    var sendDiameter: CGFloat = 36.8
    var fieldCenterYFraction: CGFloat = 0.46

    var pointerSize: CGFloat = 30
    /// Where the glyph's tip sits relative to its frame centre, so the pointer
    /// lands its tip on the send button rather than its body.
    var tipOffset = CGSize(width: 10, height: 13)
    /// Accent index the first cycle uses; each cycle steps to the next colour.
    var firstColorIndex: Int = 3
    var pointerTravel: Double = 0.95

    var blinkOn: Double = 0.5
    var blinkOff: Double = 0.5
    var perCharDelay: Double = 0.05
    var postTypePause: Double = 0.55
    var afterClickHold: Double = 0.25
    var loopGap: Double = 0.7
}

// MARK: - Input mock

/// The sign-in slide's artwork: a mock of the Donkey command field that types
/// itself out, then a colored donkey pointer flies in from offscreen, clicks the
/// send button, and vanishes — cycling through example commands and accent
/// colors. Decorative only; never takes hit-testing.
/// How the input mock opens: type straight away, or summon the field with a
/// double-⌘ first.
enum OnboardingInputMockMode {
    case typeAndSend
    case commandSummon
}

struct OnboardingInputMock: View {
    /// Example commands typed in turn — drawn from the eval fixtures.
    let commands: [String]
    let mode: OnboardingInputMockMode
    var tuning: OnboardingInputMockTuning

    @State private var typed = ""
    @State private var caretVisible = true
    @State private var pointer: CGPoint = .zero
    @State private var pointerVisible = false
    @State private var pointerColor: Color = .blue
    @State private var pressed = false
    @State private var halo = false
    @State private var showField: Bool
    @State private var showKeyHint = false
    @State private var keyPressed = false

    init(
        commands: [String],
        mode: OnboardingInputMockMode = .typeAndSend,
        tuning: OnboardingInputMockTuning = OnboardingInputMockTuning()
    ) {
        self.commands = commands
        self.mode = mode
        self.tuning = tuning
        // The command-summon variant hides the field until the ⌘+⌘ plays.
        _showField = State(initialValue: mode == .typeAndSend)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let send = sendCenter(in: size)
            ZStack(alignment: .topLeading) {
                inputBar(width: fieldWidth(in: size))
                    .scaleEffect(showField ? 1 : 0.96)
                    .opacity(showField ? 1 : 0)
                    .position(fieldCenter(in: size))

                if showKeyHint {
                    commandKeyHint
                        .position(fieldCenter(in: size))
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }

                if halo {
                    Circle()
                        .stroke(pointerColor.opacity(0.7), lineWidth: 2)
                        .frame(width: tuning.sendDiameter + 6, height: tuning.sendDiameter + 6)
                        .scaleEffect(pressed ? 1.3 : 1)
                        .position(send)
                        .transition(.opacity)
                }

                OnboardingCursorMark(color: pointerColor)
                    .frame(width: tuning.pointerSize, height: tuning.pointerSize)
                    .scaleEffect(pressed ? 0.86 : 1, anchor: .topTrailing)
                    .position(pointer)
                    .opacity(pointerVisible ? 1 : 0)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(Rectangle())
            .task {
                switch mode {
                case .typeAndSend: await runInput(in: size)
                case .commandSummon: await runSummon(in: size)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: ⌘+⌘ summon hint

    /// A realistic mechanical ⌘ keycap — a white sculpted top with a soft dark
    /// drop shadow giving it real depth. On a press the cap slides down onto its
    /// shadow, then springs back.
    private var commandKeyHint: some View {
        let face = CGSize(width: 108, height: 104)
        let radius: CGFloat = 20
        // The key's depth: how far the face sits above its shadow.
        let depth = CGSize(width: 6, height: 8)
        // Pressed, the cap travels most of the way down onto its shadow.
        let press = keyPressed
            ? CGSize(width: depth.width - 1, height: depth.height - 2)
            : .zero

        return ZStack(alignment: .topLeading) {
            // Soft, light shadow giving the key just a little depth.
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(OnboardingPalette.ink)
                .frame(width: face.width, height: face.height)
                .offset(x: depth.width, y: depth.height)
                .blur(radius: 5)
                .opacity(keyPressed ? 0.32 : 0.42)

            // Keycap: a softly graded white top with a sculpted inner dish.
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white, Color(white: 0.91)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(Color.black.opacity(0.12), lineWidth: 1)
                    )

                RoundedRectangle(cornerRadius: radius - 7, style: .continuous)
                    .fill(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius - 7, style: .continuous)
                            .stroke(Color.black.opacity(0.05), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.05), radius: 1, x: 0, y: 1)
                    .padding(7)

                VStack(spacing: 4) {
                    Image(systemName: "command")
                        .font(.system(size: 30, weight: .semibold))
                    Text("command")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(0.2)
                }
                .foregroundStyle(OnboardingPalette.ink)
            }
            .frame(width: face.width, height: face.height)
            .offset(x: press.width, y: press.height)
        }
        .frame(width: face.width + depth.width, height: face.height + depth.height, alignment: .topLeading)
    }

    // MARK: Field

    private func inputBar(width: CGFloat) -> some View {
        let hasText = !typed.isEmpty
        return HStack(spacing: tuning.textControlsSpacing) {
            ZStack(alignment: .leading) {
                if !hasText {
                    Text("What can donkey do for you?")
                        .font(.system(size: 16, weight: .light))
                        .foregroundStyle(Color.white.opacity(0.58))
                        .lineLimit(1)
                }
                HStack(alignment: .center, spacing: 1) {
                    Text(typed)
                        .font(.system(size: 16, weight: .light))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 2, height: 20)
                        .opacity(caretVisible ? 1 : 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Trailing controls: the mic icon and the white send circle.
            HStack(spacing: tuning.controlsSpacing) {
                Image(systemName: "mic")
                    .font(.system(size: 24, weight: .ultraLight))
                    .foregroundStyle(Color.white.opacity(hasText ? 0.34 : 0.52))
                    .frame(width: tuning.micSize, height: tuning.micSize)

                ZStack {
                    Circle().fill(Color.white.opacity(hasText ? 0.94 : 0.68))
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(hasText ? 0.78 : 0.42))
                }
                .frame(width: tuning.sendDiameter, height: tuning.sendDiameter)
            }
        }
        .padding(.leading, tuning.leadingPadding)
        .padding(.trailing, tuning.trailingPadding)
        .frame(width: width, height: tuning.fieldHeight)
        .background(Capsule(style: .continuous).fill(Color.black))
        .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.34), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.2), radius: 12, x: 0, y: 5)
    }

    // MARK: Geometry

    private func fieldWidth(in size: CGSize) -> CGFloat {
        min(tuning.fieldWidth, size.width - 48)
    }

    private func fieldCenter(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2, y: size.height * tuning.fieldCenterYFraction)
    }

    private func sendCenter(in size: CGSize) -> CGPoint {
        let center = fieldCenter(in: size)
        let right = center.x + fieldWidth(in: size) / 2
        return CGPoint(x: right - tuning.trailingPadding - tuning.sendDiameter / 2, y: center.y)
    }

    /// The pointer's frame centre that lands its tip on the send button.
    private func pointerTarget(in size: CGSize) -> CGPoint {
        let send = sendCenter(in: size)
        return CGPoint(x: send.x - tuning.tipOffset.width, y: send.y + tuning.tipOffset.height)
    }

    private func offscreenStart(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width + 70, y: size.height * 0.92)
    }

    // MARK: Simulation

    /// One cycle: blink the caret twice, type the command, fly the colored
    /// pointer in from offscreen to the send button and click, then vanish in
    /// place — advancing the command and color, forever.
    @MainActor
    private func runInput(in size: CGSize) async {
        let start = offscreenStart(in: size)
        let send = sendCenter(in: size)
        let target = pointerTarget(in: size)
        var commandIndex = 0
        var colorIndex = tuning.firstColorIndex

        while !Task.isCancelled {
            typed = ""
            pressed = false
            halo = false
            pointerVisible = false
            pointer = start
            pointerColor = onboardingAccent(colorIndex)
            _ = send  // halo/click anchor, captured for clarity

            // Blink the caret twice before typing begins.
            for _ in 0..<2 {
                caretVisible = true
                if await onboardingSleep(tuning.blinkOn) == false { return }
                caretVisible = false
                if await onboardingSleep(tuning.blinkOff) == false { return }
            }
            caretVisible = true

            // Type the command out, character by character.
            for character in commands[commandIndex % commands.count] {
                typed.append(character)
                if await onboardingSleep(tuning.perCharDelay) == false { return }
            }
            if await onboardingSleep(tuning.postTypePause) == false { return }

            // Fly the pointer in from offscreen to the send button.
            pointerVisible = true
            withAnimation(.easeInOut(duration: tuning.pointerTravel)) { pointer = target }
            if await onboardingSleep(tuning.pointerTravel) == false { return }

            // Click: press in with a halo, then release.
            withAnimation(.easeOut(duration: 0.10)) {
                pressed = true
                halo = true
            }
            if await onboardingSleep(0.12) == false { return }
            withAnimation(.easeOut(duration: 0.12)) { pressed = false }
            if await onboardingSleep(tuning.afterClickHold) == false { return }

            // Vanish in place.
            withAnimation(.easeOut(duration: 0.28)) {
                pointerVisible = false
                halo = false
            }
            caretVisible = false
            if await onboardingSleep(tuning.loopGap) == false { return }

            commandIndex += 1
            colorIndex = (colorIndex + 1) % onboardingAccentPalette.count
        }
    }

    /// One cycle for the summon variant: tap ⌘ twice, reveal the field, type the
    /// command, fly the pointer in to send, vanish — advancing command and color.
    @MainActor
    private func runSummon(in size: CGSize) async {
        let start = offscreenStart(in: size)
        let target = pointerTarget(in: size)
        var commandIndex = 0
        var colorIndex = tuning.firstColorIndex

        while !Task.isCancelled {
            typed = ""
            pressed = false
            halo = false
            pointerVisible = false
            caretVisible = false
            pointer = start
            pointerColor = onboardingAccent(colorIndex)
            withAnimation(.easeOut(duration: 0.2)) { showField = false }
            showKeyHint = true
            if await onboardingSleep(0.4) == false { return }

            // Tap ⌘ twice to summon the field.
            for _ in 0..<2 {
                withAnimation(.easeIn(duration: 0.07)) { keyPressed = true }
                if await onboardingSleep(0.12) == false { return }
                withAnimation(.easeOut(duration: 0.12)) { keyPressed = false }
                if await onboardingSleep(0.2) == false { return }
            }
            if await onboardingSleep(0.25) == false { return }

            // Hide the hint and reveal the field.
            withAnimation(.easeOut(duration: 0.2)) { showKeyHint = false }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { showField = true }
            caretVisible = true
            if await onboardingSleep(0.4) == false { return }

            // Type the command out.
            for character in commands[commandIndex % commands.count] {
                typed.append(character)
                if await onboardingSleep(tuning.perCharDelay) == false { return }
            }
            if await onboardingSleep(tuning.postTypePause) == false { return }

            // Fly the pointer in and click send.
            pointerVisible = true
            withAnimation(.easeInOut(duration: tuning.pointerTravel)) { pointer = target }
            if await onboardingSleep(tuning.pointerTravel) == false { return }
            withAnimation(.easeOut(duration: 0.10)) {
                pressed = true
                halo = true
            }
            if await onboardingSleep(0.12) == false { return }
            withAnimation(.easeOut(duration: 0.12)) { pressed = false }
            if await onboardingSleep(tuning.afterClickHold) == false { return }

            // Vanish in place.
            withAnimation(.easeOut(duration: 0.28)) {
                pointerVisible = false
                halo = false
            }
            caretVisible = false
            if await onboardingSleep(tuning.loopGap) == false { return }

            commandIndex += 1
            colorIndex = (colorIndex + 1) % onboardingAccentPalette.count
        }
    }
}
