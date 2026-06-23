import CoreGraphics
import Foundation

public struct UserQueryNotchLayout: Equatable, Sendable {
    public static let expandedCommandOnlyTopPaddingBelowPhysicalVoid: CGFloat = 16

    public var voidWidth: CGFloat
    public var voidHeight: CGFloat
    public var collapsedVisibleHeight: CGFloat
    public var expandedVisibleHeight: CGFloat
    public var contentHorizontalInset: CGFloat
    public var visibleHeight: CGFloat
    public var collapsedSurfaceFrame: CGRect
    public var expandedSurfaceFrame: CGRect
    public var expandedContentFrame: CGRect
    public var collapsedCornerRadius: CGFloat
    public var expandedCornerRadius: CGFloat
    public var canRenderTextInTopRow: Bool
    /// Height of the chin band that hangs below the collapsed notch row while a task streams
    /// (0 when there is nothing to stream). The notch row itself stays `collapsedVisibleHeight`.
    public var chinHeight: CGFloat
    /// Logged out: render the login call-to-action instead of the task surface.
    public var needsLogin: Bool

    public init(
        voidWidth: CGFloat,
        voidHeight: CGFloat,
        collapsedVisibleHeight: CGFloat,
        expandedVisibleHeight: CGFloat,
        contentHorizontalInset: CGFloat,
        visibleHeight: CGFloat,
        collapsedSurfaceFrame: CGRect,
        expandedSurfaceFrame: CGRect,
        expandedContentFrame: CGRect,
        collapsedCornerRadius: CGFloat,
        expandedCornerRadius: CGFloat,
        canRenderTextInTopRow: Bool,
        chinHeight: CGFloat = 0,
        needsLogin: Bool = false
    ) {
        self.voidWidth = voidWidth
        self.voidHeight = voidHeight
        self.collapsedVisibleHeight = collapsedVisibleHeight
        self.expandedVisibleHeight = expandedVisibleHeight
        self.contentHorizontalInset = contentHorizontalInset
        self.visibleHeight = visibleHeight
        self.collapsedSurfaceFrame = collapsedSurfaceFrame
        self.expandedSurfaceFrame = expandedSurfaceFrame
        self.expandedContentFrame = expandedContentFrame
        self.collapsedCornerRadius = collapsedCornerRadius
        self.expandedCornerRadius = expandedCornerRadius
        self.canRenderTextInTopRow = canRenderTextInTopRow
        self.chinHeight = chinHeight
        self.needsLogin = needsLogin
    }

    public var shouldRenderExpandedTopRowVoidMarker: Bool {
        true
    }

    public var expandedCommandOnlyTopPadding: CGFloat {
        Self.expandedCommandOnlyTopPaddingBelowPhysicalVoid
    }
}

public struct UserQueryNotchMetrics: Equatable, Sendable {
    public static let fallbackVoidWidth: CGFloat = 180
    public static let fallbackVoidHeight: CGFloat = 32
    public static let maximumInferredVoidWidth: CGFloat = 220
    public static let defaultScreenWidth: CGFloat = 1512
    public static let minimumPhysicalVoidHeight: CGFloat = 30
    public static let expandedTaskContentHeight: CGFloat = 280
    public static let inputHorizontalMargin: CGFloat = 14
    public static let compactCommandContentVerticalPadding: CGFloat = 30
    /// How long the open host window lingers after the surface starts collapsing, before it snaps to
    /// the notch size. Timed just past the surface close animation (0.22s) so the host always stays
    /// large enough to contain the still-shrinking surface, then closes once it has reached the notch.
    public static let closeAnimationDuration: TimeInterval = 0.26

    public var voidWidth: CGFloat
    public var voidHeight: CGFloat
    public var expandedContentHeight: CGFloat
    public var isExpanded: Bool
    public var isHostExpanded: Bool
    public var screenWidth: CGFloat
    /// Chin band below the collapsed notch row while a task streams (0 otherwise).
    public var chinHeight: CGFloat
    /// Extra height for a wrapped second line of the no-notch collapsed headline. A real notch routes the
    /// line into a chin band (`chinHeight`); a no-notch display renders it inline in the top row, so when
    /// it wraps the pill grows by this instead. 0 on a real notch, and 0 when the line fits one row.
    public var collapsedTopRowExtraHeight: CGFloat
    /// Logged out: render the login call-to-action instead of the task surface. Collapsed shows just
    /// the "Login to use Donkey" line; expanding reveals a wide, short bar with the Login button.
    public var needsLogin: Bool

    /// Height of the short collapsed login band that seats the "Login to use Donkey" line below the
    /// void on a real notch. No-notch displays render the line inline in the top row.
    public static let loginCollapsedBandHeight: CGFloat = 22

    /// Expanded login content height: a short bar holding the label + Login button, not the full task
    /// panel. The expanded surface adds the void top inset on top of this.
    public static let loginExpandedContentHeight: CGFloat = 52

    public init(
        voidWidth: CGFloat,
        voidHeight: CGFloat,
        expandedContentHeight: CGFloat,
        isExpanded: Bool,
        isHostExpanded: Bool,
        screenWidth: CGFloat,
        chinHeight: CGFloat = 0,
        collapsedTopRowExtraHeight: CGFloat = 0,
        needsLogin: Bool = false
    ) {
        self.voidWidth = voidWidth
        self.voidHeight = voidHeight
        self.expandedContentHeight = expandedContentHeight
        self.isExpanded = isExpanded
        self.isHostExpanded = isHostExpanded
        self.screenWidth = screenWidth
        self.chinHeight = chinHeight
        self.collapsedTopRowExtraHeight = collapsedTopRowExtraHeight
        self.needsLogin = needsLogin
    }

    public var surfaceSize: CGSize {
        surfaceFrame.size
    }

    public var hostCornerRadius: CGFloat {
        isHostExpanded ? Self.expandedCornerRadius : Self.collapsedCornerRadius
    }

    public var visibleSurfaceFrameInPanel: CGRect {
        frameInPanel(for: visibleSurfaceFrame)
    }

    public var hoverFramesInPanel: [CGRect] {
        let tolerance: CGFloat = 2
        return [visibleSurfaceFrameInPanel.insetBy(dx: -tolerance, dy: -tolerance)]
    }

    public var layout: UserQueryNotchLayout {
        UserQueryNotchLayout(
            voidWidth: voidWidth,
            voidHeight: voidHeight,
            collapsedVisibleHeight: collapsedVisibleHeight,
            expandedVisibleHeight: expandedVisibleHeight,
            contentHorizontalInset: 14,
            visibleHeight: visibleHeight,
            collapsedSurfaceFrame: collapsedSurfaceFrame,
            expandedSurfaceFrame: expandedSurfaceFrame,
            expandedContentFrame: expandedContentFrame,
            collapsedCornerRadius: Self.collapsedCornerRadius,
            expandedCornerRadius: Self.expandedCornerRadius,
            canRenderTextInTopRow: canRenderTextInTopRow,
            chinHeight: effectiveChinHeight,
            needsLogin: needsLogin
        )
    }

    /// Only the real notch (with a void) grows a chin; no-notch displays show the
    /// streaming line inline in the collapsed row instead.
    private var effectiveChinHeight: CGFloat {
        canRenderTextInTopRow ? 0 : chinHeight
    }

    private var visibleHeight: CGFloat {
        visibleSurfaceFrame.height
    }

    private func frameInPanel(for frame: CGRect) -> CGRect {
        CGRect(
            x: (surfaceSize.width - frame.width) / 2,
            y: surfaceSize.height - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    private var surfaceFrame: CGRect {
        isHostExpanded ? expandedSurfaceFrame : collapsedSurfaceFrame
    }

    private var visibleSurfaceFrame: CGRect {
        isExpanded ? expandedSurfaceFrame : collapsedSurfaceFrame
    }

    private var expandedSurfaceFrame: CGRect {
        CGRect(
            x: 0,
            y: 0,
            width: Self.expandedContentDesignFrame.width,
            height: expandedSurfaceHeight
        )
    }

    private var collapsedSurfaceFrame: CGRect {
        CGRect(
            x: 0,
            y: 0,
            width: collapsedSurfaceWidth,
            height: collapsedVisibleHeight + collapsedExtraHeight
        )
    }

    /// The band below the collapsed notch row: the login call-to-action when logged out (real notch
    /// only — no-notch displays render it inline), the streaming chin on a real notch, or — on a no-notch
    /// display — the room for a wrapped second line of the inline headline.
    private var collapsedExtraHeight: CGFloat {
        guard needsLogin else {
            return canRenderTextInTopRow ? collapsedTopRowExtraHeight : effectiveChinHeight
        }
        return canRenderTextInTopRow ? 0 : Self.loginCollapsedBandHeight
    }

    private var expandedContentFrame: CGRect {
        CGRect(
            x: Self.expandedContentDesignFrame.minX,
            y: expandedContentTopInset,
            width: Self.expandedContentDesignFrame.width,
            height: expandedContentFrameHeight
        )
    }

    private var collapsedSurfaceWidth: CGFloat {
        // Logged out keeps the normal collapsed width — the bar just reads "Login to use Donkey".
        min(
            Self.expandedContentDesignFrame.width,
            max(
                Self.minimumCollapsedSurfaceFrame.width,
                Self.commonCollapsedSurfaceFrame.width,
                voidWidth + Self.collapsedSideLaneWidth * 2
            )
        )
    }

    private var collapsedVisibleHeight: CGFloat {
        max(Self.minimumCollapsedSurfaceFrame.height, Self.commonCollapsedSurfaceFrame.height, voidHeight)
    }

    private var expandedVisibleHeight: CGFloat {
        expandedSurfaceHeight
    }

    private var expandedContentTopInset: CGFloat {
        expandedSurfaceTopInset
    }

    private var expandedContentFrameHeight: CGFloat {
        expandedContentHeight
    }

    private var expandedSurfaceHeight: CGFloat {
        expandedContentHeight + expandedSurfaceTopInset
    }

    private var expandedSurfaceTopInset: CGFloat {
        guard !canRenderTextInTopRow else {
            return Self.commonCollapsedSurfaceFrame.height
        }

        return min(max(0, voidHeight), Self.maximumExpandedContentTopInset)
    }

    private var canRenderTextInTopRow: Bool {
        voidWidth <= 0 && voidHeight <= 0
    }

    private static let minimumCollapsedSurfaceFrame = CGRect(x: 0, y: 0, width: 110, height: 28)
    private static let commonCollapsedSurfaceFrame = CGRect(
        x: 0,
        y: 0,
        width: Self.fallbackVoidWidth + Self.collapsedSideLaneWidth * 2,
        height: Self.fallbackVoidHeight
    )
    private static let expandedContentDesignFrame = CGRect(
        x: 0,
        y: 0,
        width: UserQueryLayout.composerInputSurfaceWidth + Self.inputHorizontalMargin * 2,
        height: 280
    )
    private static let collapsedSideLaneWidth: CGFloat = 34
    private static let collapsedCornerRadius: CGFloat = 14
    // Prototype spec: the expanded notch window and its input box both use a 14px radius.
    private static let expandedCornerRadius: CGFloat = 14
    private static let maximumExpandedContentTopInset: CGFloat = 44
}
