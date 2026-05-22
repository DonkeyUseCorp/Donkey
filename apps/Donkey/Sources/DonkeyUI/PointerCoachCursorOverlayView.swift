import DonkeyContracts
import SwiftUI

@MainActor
public final class PointerCoachCursorOverlayViewModel: ObservableObject {
    public let request: PointerCoachCursorGuideRequest
    public private(set) var screenSize: CGSize
    @Published public private(set) var viewportOrigin: CGPoint = .zero
    @Published public private(set) var viewportSize: CGSize = .zero
    @Published public private(set) var startedAt = Date()
    @Published public private(set) var now = Date()

    public init(
        request: PointerCoachCursorGuideRequest,
        screenSize: CGSize
    ) {
        self.request = request
        self.screenSize = screenSize
    }

    public var animationFrame: CoachCursorAnimationFrame {
        animationFrame(size: screenSize)
    }

    public var visualFrame: CGRect {
        visualFrame(for: animationFrame)
    }

    public func start(at date: Date = Date()) {
        startedAt = date
        now = date
    }

    public func update(now: Date, screenSize: CGSize? = nil) {
        self.now = now
        if let screenSize {
            self.screenSize = screenSize
        }
    }

    public func updateViewport(origin: CGPoint, size: CGSize) {
        viewportOrigin = origin
        viewportSize = size
    }

    public func renderPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x - viewportOrigin.x,
            y: point.y - viewportOrigin.y
        )
    }

    public func labelPosition(for cursorPosition: CGPoint) -> CGPoint {
        let prefersLeft = cursorPosition.x > screenSize.width - 340
        let prefersAbove = cursorPosition.y > screenSize.height - 120
        return CGPoint(
            x: cursorPosition.x + (prefersLeft ? -156 : 156),
            y: cursorPosition.y + (prefersAbove ? -54 : 54)
        )
    }

    private func visualFrame(for frame: CoachCursorAnimationFrame) -> CGRect {
        var bounds = CGRect(
            x: frame.position.x - 30,
            y: frame.position.y - 30,
            width: 60,
            height: 60
        )
        if !frame.visibleLabel.isEmpty {
            let labelCenter = labelPosition(for: frame.position)
            bounds = bounds.union(CGRect(
                x: labelCenter.x - 160,
                y: labelCenter.y - 42,
                width: 320,
                height: 84
            ))
        }
        return bounds.insetBy(dx: -8, dy: -8)
    }

    private func animationFrame(size: CGSize) -> CoachCursorAnimationFrame {
        let sample = AgentVisualizationCursorPathSampler.sample(
            request: request,
            elapsed: now.timeIntervalSince(startedAt),
            screenSize: size
        )
        return CoachCursorAnimationFrame(
            position: sample.position,
            angle: sample.angle,
            visibleLabel: sample.visibleLabel,
            isHolding: sample.isHolding,
            haloScale: sample.haloScale,
            haloOpacity: sample.haloOpacity,
            labelOpacity: sample.labelOpacity
        )
    }
}

public struct PointerCoachCursorOverlayView: View {
    @ObservedObject private var viewModel: PointerCoachCursorOverlayViewModel

    public init(viewModel: PointerCoachCursorOverlayViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        let frame = viewModel.animationFrame

        ZStack(alignment: .topLeading) {
            if frame.isHolding {
                Circle()
                    .stroke(Color.white.opacity(0.55), lineWidth: 1.5)
                    .frame(width: 36, height: 36)
                    .scaleEffect(frame.haloScale)
                    .opacity(frame.haloOpacity)
                    .position(viewModel.renderPoint(frame.position))
            }

            cursor(angle: frame.angle)
                .position(viewModel.renderPoint(frame.position))

            if !frame.visibleLabel.isEmpty {
                label(text: frame.visibleLabel, accent: frame.accent)
                    .position(viewModel.renderPoint(viewModel.labelPosition(for: frame.position)))
                    .opacity(frame.labelOpacity)
            }
        }
    }

    private func cursor(angle: Double) -> some View {
        PointerCoachCursorShape()
            .fill(Color.white)
            .overlay {
                PointerCoachCursorShape()
                    .stroke(Color(red: 0.34, green: 0.95, blue: 1.0), lineWidth: 1.4)
            }
            .shadow(color: Color.black.opacity(0.28), radius: 3, x: 0, y: 2)
            .frame(width: 26, height: 26)
            .rotationEffect(.degrees(angle + 50))
    }

    private func label(text: String, accent: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: 280, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(accent)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.32), radius: 8, x: 0, y: 4)
    }

}

public struct CoachCursorAnimationFrame {
    var position: CGPoint
    var angle: Double
    var visibleLabel: String
    var isHolding: Bool
    var haloScale: Double = 1
    var haloOpacity: Double = 0.35
    var labelOpacity: Double = 0
    var accent: Color = Color(red: 0.34, green: 0.28, blue: 0.95)
}

private struct PointerCoachCursorShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        path.move(to: svgPoint(x: 83.086, y: 5.6406, width: w, height: h))
        path.addLine(to: svgPoint(x: 10.453, y: 34.6836, width: w, height: h))
        path.addCurve(
            to: svgPoint(x: 11.13269, y: 51.0276, width: w, height: h),
            control1: svgPoint(x: 2.8514, y: 37.7227, width: w, height: h),
            control2: svgPoint(x: 3.3085, y: 48.6326, width: w, height: h)
        )
        path.addLine(to: svgPoint(x: 35.69469, y: 58.5471, width: w, height: h))
        path.addCurve(
            to: svgPoint(x: 41.44859, y: 64.301, width: w, height: h),
            control1: svgPoint(x: 38.44859, y: 59.39085, width: w, height: h),
            control2: svgPoint(x: 40.60489, y: 61.5471, width: w, height: h)
        )
        path.addLine(to: svgPoint(x: 48.96809, y: 88.863, width: w, height: h))
        path.addCurve(
            to: svgPoint(x: 65.31209, y: 89.54269, width: w, height: h),
            control1: svgPoint(x: 51.36649, y: 96.6911, width: w, height: h),
            control2: svgPoint(x: 62.27309, y: 97.1442, width: w, height: h)
        )
        path.addLine(to: svgPoint(x: 94.35509, y: 16.90969, width: w, height: h))
        path.addCurve(
            to: svgPoint(x: 83.08209, y: 5.63669, width: w, height: h),
            control1: svgPoint(x: 97.18709, y: 9.83159, width: w, height: h),
            control2: svgPoint(x: 90.15979, y: 2.80769, width: w, height: h)
        )
        path.closeSubpath()

        return path
    }

    private func svgPoint(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGPoint {
        CGPoint(
            x: (100 - x) / 100 * width,
            y: y / 100 * height
        )
    }
}
