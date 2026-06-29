// Shared building blocks for the onboarding slide mocks — live SwiftUI re-creations
// rendered inside slide artwork regions in place of static screenshots. The
// "screen edge" is the dark top bezel of a Mac display; the collapsed notch drops
// out of its centre and a simulated pointer drives it. The cursor glyph, the
// grow-from-notch surface shape, the accent palette, and the elapsed-time format
// are copied verbatim from the real notch UI (`UserQueryNotchStatusView`) so the
// tour matches the running app.
//
// Every mock (`OnboardingNotchMock`, `OnboardingSignInMock`, `OnboardingInputMock`)
// is built from the pieces here.

import SwiftUI

// MARK: - Screen top edge

/// The top edge of a Mac screen — the line the notch component drops out of. A
/// 1px full-width white hairline whose opacity tapers to nothing at both ends so
/// the edge reads as solid across the centre and dissolves into the slide at the
/// sides. The collapsed component anchors to this line's horizontal centre.
struct OnboardingScreenEdge: View {
    /// Colour of the edge at its solid mid-point. The ends always fade to fully
    /// transparent regardless of this colour.
    var color: Color = .white
    /// Edge thickness in points.
    var thickness: CGFloat = 1

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: color.opacity(0), location: 0.0),
                        .init(color: color, location: 0.48),
                        .init(color: color.opacity(0), location: 0.98)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: thickness)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Live elapsed clock

/// A ticking elapsed-time label, formatted exactly like the real notch
/// ("45m 13s" / "1h 45m 13s"). Counts up from `appearedAt - offset`, so a task
/// shown mid-run starts at its offset rather than zero.
struct OnboardingElapsedClock: View {
    let appearedAt: Date
    let offset: TimeInterval
    let font: Font
    let color: Color

    var body: some View {
        TimelineView(.periodic(from: appearedAt, by: 1)) { context in
            Text(Self.elapsedDescription(seconds: context.date.timeIntervalSince(appearedAt) + offset))
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// Formats elapsed seconds as "45m 13s" (or "1h 45m 13s"), dropping leading
    /// zero units — copied from `UserQueryNotchStatusView.elapsedDescription`.
    static func elapsedDescription(seconds totalSeconds: Double) -> String {
        let clamped = max(0, Int(totalSeconds))
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let seconds = clamped % 60

        var parts: [String] = []
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 { parts.append("\(minutes)m") }
        parts.append("\(seconds)s")
        return parts.joined(separator: " ")
    }
}

// MARK: - Accent palette (copied from UserQueryNotchStatusView)

let onboardingAccentPalette: [Color] = [
    Color(red: 0.114, green: 0.62, blue: 0.46),
    Color(red: 0.94, green: 0.62, blue: 0.15),
    Color(red: 0.83, green: 0.33, blue: 0.49),
    Color(red: 0.22, green: 0.54, blue: 0.87),
    Color(red: 0.5, green: 0.47, blue: 0.87),
    Color(red: 0.88, green: 0.35, blue: 0.28),
    Color(red: 0.24, green: 0.69, blue: 0.71),
    Color(red: 0.66, green: 0.34, blue: 0.79)
]

func onboardingAccent(_ index: Int) -> Color {
    let count = onboardingAccentPalette.count
    return onboardingAccentPalette[((index % count) + count) % count]
}

// MARK: - Ported glyphs and shapes

/// The donkey cursor glyph, geometry ported verbatim from `DonkeyCursorMark`
/// (100×100 viewBox). Filled + outlined when active; a hollow gray silhouette
/// when idle/finished. Tip points up-right at rotation 0.
struct OnboardingCursorMark: View {
    var color: Color
    var silhouette: Bool = false

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width, proxy.size.height) / 100
            let path = Self.cursorPath(scale: scale)
            if silhouette {
                path.stroke(
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
        .accessibilityHidden(true)
    }

    private static func cursorPath(scale: CGFloat) -> Path {
        Path { path in
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }
            path.move(to: point(83.086, 5.6406))
            path.addLine(to: point(10.453, 34.6836))
            path.addCurve(to: point(11.1327, 51.0276), control1: point(2.8514, 37.7227), control2: point(3.3085, 48.6326))
            path.addLine(to: point(35.6947, 58.5471))
            path.addCurve(to: point(41.4486, 64.301), control1: point(38.4486, 59.3909), control2: point(40.6049, 61.5471))
            path.addLine(to: point(48.9681, 88.863))
            path.addCurve(to: point(65.3121, 89.5427), control1: point(51.3665, 96.6911), control2: point(62.2731, 97.1442))
            path.addLine(to: point(94.3551, 16.9097))
            path.addCurve(to: point(83.0821, 5.6367), control1: point(97.1871, 9.8316), control2: point(90.1598, 2.8077))
            path.closeSubpath()
        }
    }
}

/// The notch silhouette as an animatable clip — square top, rounded bottom —
/// pinned to the top centre of the rect it fills, so animating width/height/
/// cornerRadius grows the opening from the closed notch outward. Ported from
/// `GrowingNotchShape`.
struct OnboardingNotchShape: Shape {
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

// MARK: - Shared timing helper

/// Sleeps for `seconds`, returning false if the task was cancelled (slide left).
func onboardingSleep(_ seconds: Double) async -> Bool {
    do {
        try await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    } catch {
        return false
    }
}
