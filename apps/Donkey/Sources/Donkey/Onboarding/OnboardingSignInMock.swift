// The sign-in slide's artwork: the screen edge with a collapsed notch at the top
// and the command field below. The field types a prompt and the pointer clicks
// send; the sent prompt runs in the collapsed notch (it never expands), cycling
// through the example commands. Built on `OnboardingMockKit`.

import SwiftUI

/// The sign-in slide: the screen edge with a collapsed notch at the top, and the
/// command field below. The field types a prompt and the pointer clicks send;
/// the sent prompt then runs in the collapsed notch (timer ticking) — it never
/// expands. Cycles through the example commands. Decorative only.
struct OnboardingSignInMock: View {
    let commands: [String]

    private let pillWidth: CGFloat = 320
    private let pillHeight: CGFloat = 38
    private let edgeYFraction: CGFloat = 0.13
    private let fieldYFraction: CGFloat = 0.66
    private let fieldHeight: CGFloat = 66
    private let leadingPadding: CGFloat = 20
    private let trailingPadding: CGFloat = 14.6
    private let sendDiameter: CGFloat = 36.8
    private let micSize: CGFloat = 28

    @State private var typed = ""
    @State private var caretVisible = true
    @State private var pointer: CGPoint = .zero
    @State private var pointerVisible = false
    @State private var pointerColor: Color = .blue
    @State private var pressed = false
    @State private var halo = false

    @State private var runningPrompt = ""
    @State private var runningColor: Color = .blue
    @State private var runningSince = Date()
    @State private var hasRunning = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let send = sendCenter(in: size)
            ZStack(alignment: .topLeading) {
                OnboardingScreenEdge(color: OnboardingPalette.ink.opacity(0.35))
                    .frame(width: size.width)
                    .position(x: size.width / 2, y: edgeY(size))

                collapsedNotch
                    .position(x: size.width / 2, y: edgeY(size) + pillHeight / 2)

                field(width: fieldWidth(in: size))
                    .position(fieldCenter(in: size))

                if halo {
                    Circle()
                        .stroke(pointerColor.opacity(0.7), lineWidth: 2)
                        .frame(width: sendDiameter + 6, height: sendDiameter + 6)
                        .scaleEffect(pressed ? 1.3 : 1)
                        .position(send)
                        .transition(.opacity)
                }

                OnboardingCursorMark(color: pointerColor)
                    .frame(width: 30, height: 30)
                    .scaleEffect(pressed ? 0.86 : 1, anchor: .topTrailing)
                    .position(pointer)
                    .opacity(pointerVisible ? 1 : 0)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(Rectangle())
            .task { await run(in: size) }
        }
        .allowsHitTesting(false)
    }

    // MARK: Collapsed notch

    private var collapsedNotch: some View {
        let shape = OnboardingNotchShape(width: pillWidth, height: pillHeight, cornerRadius: 18)
        return ZStack {
            Color.black
            if hasRunning {
                HStack(spacing: 7) {
                    OnboardingCursorMark(color: runningColor)
                        .frame(width: 14, height: 14)
                    Text(runningPrompt)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    OnboardingElapsedClock(
                        appearedAt: runningSince,
                        offset: 0,
                        font: .system(size: 11, weight: .regular).monospacedDigit(),
                        color: Color.white.opacity(0.5)
                    )
                }
                .padding(.horizontal, 13)
            } else {
                HStack {
                    OnboardingCursorMark(color: onboardingAccent(0), silhouette: true)
                        .frame(width: 14, height: 14)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 13)
            }
        }
        .frame(width: pillWidth, height: pillHeight)
        .clipShape(shape)
        .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    // MARK: Field

    private func field(width: CGFloat) -> some View {
        let hasText = !typed.isEmpty
        return HStack(spacing: 12) {
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

            HStack(spacing: 16) {
                Image(systemName: "mic")
                    .font(.system(size: 24, weight: .ultraLight))
                    .foregroundStyle(Color.white.opacity(hasText ? 0.34 : 0.52))
                    .frame(width: micSize, height: micSize)
                ZStack {
                    Circle().fill(Color.white.opacity(hasText ? 0.94 : 0.68))
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(hasText ? 0.78 : 0.42))
                }
                .frame(width: sendDiameter, height: sendDiameter)
            }
        }
        .padding(.leading, leadingPadding)
        .padding(.trailing, trailingPadding)
        .frame(width: width, height: fieldHeight)
        .background(Capsule(style: .continuous).fill(Color.black))
        .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.34), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.2), radius: 12, x: 0, y: 5)
    }

    // MARK: Geometry

    private func edgeY(_ size: CGSize) -> CGFloat { size.height * edgeYFraction }

    private func fieldWidth(in size: CGSize) -> CGFloat { min(518, size.width - 48) }

    private func fieldCenter(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2, y: size.height * fieldYFraction)
    }

    private func sendCenter(in size: CGSize) -> CGPoint {
        let center = fieldCenter(in: size)
        let right = center.x + fieldWidth(in: size) / 2
        return CGPoint(x: right - trailingPadding - sendDiameter / 2, y: center.y)
    }

    // MARK: Simulation

    @MainActor
    private func run(in size: CGSize) async {
        let start = CGPoint(x: size.width + 70, y: size.height * 0.92)
        let send = sendCenter(in: size)
        let target = CGPoint(x: send.x - 10, y: send.y + 13)
        var commandIndex = 0
        var colorIndex = 3

        while !Task.isCancelled {
            typed = ""
            pressed = false
            halo = false
            pointerVisible = false
            pointer = start
            pointerColor = onboardingAccent(colorIndex)

            // Blink the caret once, then start typing the command.
            caretVisible = true
            if await onboardingSleep(0.5) == false { return }
            caretVisible = false
            if await onboardingSleep(0.5) == false { return }
            caretVisible = true

            let command = commands[commandIndex % commands.count]
            for character in command {
                typed.append(character)
                if await onboardingSleep(0.05) == false { return }
            }
            if await onboardingSleep(0.5) == false { return }

            // Fly the pointer in and click send.
            pointerVisible = true
            withAnimation(.easeInOut(duration: 0.95)) { pointer = target }
            if await onboardingSleep(0.95) == false { return }
            withAnimation(.easeOut(duration: 0.10)) {
                pressed = true
                halo = true
            }
            if await onboardingSleep(0.12) == false { return }
            withAnimation(.easeOut(duration: 0.12)) { pressed = false }

            // Send: the prompt moves into the collapsed notch and starts running.
            runningPrompt = command
            runningColor = pointerColor
            runningSince = Date()
            hasRunning = true
            withAnimation(.easeOut(duration: 0.2)) { typed = "" }
            caretVisible = false
            withAnimation(.easeOut(duration: 0.28)) {
                pointerVisible = false
                halo = false
            }

            // Let it run in the notch before the next prompt.
            if await onboardingSleep(2.6) == false { return }

            commandIndex += 1
            colorIndex = (colorIndex + 1) % onboardingAccentPalette.count
        }
    }
}
