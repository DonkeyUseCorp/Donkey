import CoreGraphics
import Foundation

/// What the collapsed notch's trailing (right) lane shows. One source of truth for the gutter: the
/// layout sizes the lane from this — only the live clock needs the widened lane; a glyph or the update
/// icon fits the original width; nothing collapses it back — and the view renders the matching content
/// by switching on the very same value, so the lane width and what sits in it can never drift.
public enum CollapsedTrailingSlot: String, Equatable, Sendable {
    /// Nothing in the gutter — the lane collapses to its original width.
    case empty
    /// The waiting-on-user attention mark (clarification, review, or permission). Fits the original width.
    case attentionGlyph
    /// A surfaced failure's red warning mark. Fits the original width.
    case errorGlyph
    /// An available app update. Fits the original width.
    case updateIcon
    /// The live elapsed timer ("Nh Nm Ns") — the only gutter content that needs the widened lane.
    case clock

    /// Only the live clock needs the wide lane; every glyph/icon and the empty lane keep the original width.
    public var needsWideLane: Bool { self == .clock }
}

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
    /// Distance from the collapsed surface's left edge to the void's left edge — the leading lane width.
    /// The trailing lane (the remainder past the void) is wider so the live clock fits beside the camera,
    /// which seats the void off-center; the host is positioned to keep it on the physical camera anyway.
    public var collapsedVoidLeadingInset: CGFloat
    /// Height of the chin band that hangs below the collapsed notch row while a task streams
    /// (0 when there is nothing to stream). The notch row itself stays `collapsedVisibleHeight`.
    public var chinHeight: CGFloat
    /// Logged out: render the login call-to-action instead of the task surface.
    public var needsLogin: Bool
    /// What the collapsed trailing lane shows. The view renders its gutter by switching on this, the
    /// same value that sized the lane — so the content and the width it sits in are one decision.
    public var collapsedTrailingSlot: CollapsedTrailingSlot

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
        collapsedVoidLeadingInset: CGFloat = 0,
        chinHeight: CGFloat = 0,
        needsLogin: Bool = false,
        collapsedTrailingSlot: CollapsedTrailingSlot = .empty
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
        self.collapsedVoidLeadingInset = collapsedVoidLeadingInset
        self.chinHeight = chinHeight
        self.needsLogin = needsLogin
        self.collapsedTrailingSlot = collapsedTrailingSlot
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
    public static let expandedConversationContentHeight: CGFloat = 280
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
    /// What the collapsed trailing lane shows. The lane expands only for the live clock and collapses
    /// back to the original width for a glyph, the update icon, or nothing — so the width tracks the
    /// content. Built with `collapsedTrailingSlot(primaryStatus:hasSurfacedError:isUpdateActionable:)`
    /// from the same conversation state the notch view renders.
    public var collapsedTrailingSlot: CollapsedTrailingSlot
    /// How many pointers the collapsed leading lane holds (the surfaced-conversation cluster). The lane
    /// widens to fit a multi-pointer cluster and collapses back to the original width for one or none,
    /// so both side lanes are sized by their content rather than a fixed literal.
    public var collapsedLeadingPointerCount: Int

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
        needsLogin: Bool = false,
        collapsedTrailingSlot: CollapsedTrailingSlot = .empty,
        collapsedLeadingPointerCount: Int = 0
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
        self.collapsedTrailingSlot = collapsedTrailingSlot
        self.collapsedLeadingPointerCount = collapsedLeadingPointerCount
    }

    /// Classify what the collapsed trailing lane shows, matching the notch view's gutter exactly so the
    /// lane width (sized from this) and the rendered content (the view's `collapsedRightSlot`) stay one
    /// decision. A surfaced failure wins first; then the primary conversation's status — running shows
    /// the clock, a waiting-on-user state shows the attention mark, anything else is empty; an app
    /// update shows only when no conversation is primary.
    public static func collapsedTrailingSlot(
        primaryStatus: UserQueryConversationStatus?,
        hasSurfacedError: Bool,
        isUpdateActionable: Bool
    ) -> CollapsedTrailingSlot {
        if hasSurfacedError { return .errorGlyph }
        if let primaryStatus {
            switch primaryStatus {
            case .waitingForClarification, .waitingForReview, .waitingForPermission:
                return .attentionGlyph
            case .running:
                return .clock
            case .chatting, .paused, .completed, .interrupted, .needsAttention, .failed, .timedOut:
                return .empty
            }
        }
        if isUpdateActionable { return .updateIcon }
        return .empty
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
            collapsedVoidLeadingInset: collapsedVoidLeadingInset,
            chinHeight: effectiveChinHeight,
            needsLogin: needsLogin,
            collapsedTrailingSlot: collapsedTrailingSlot
        )
    }

    /// X of the void's center within the surface currently being positioned. The collapsed real-notch
    /// surface seats the void off-center (a wider trailing lane gives the live clock room), so the host
    /// window is placed by this — not the surface center — to keep the void pinned to the physical
    /// camera. The expanded panel and the no-notch pill stay centered, where the void already sits
    /// mid-surface (or there is none).
    public var surfaceVoidCenterX: CGFloat {
        guard !isHostExpanded, voidWidth > 0 else { return surfaceSize.width / 2 }
        return collapsedVoidLeadingInset + voidWidth / 2
    }

    /// Distance from the collapsed surface's left edge to the void's left edge (the leading lane width).
    /// Derived from the actual collapsed width so any min/max clamp is split between the lanes in the
    /// nominal ratio, keeping the void's seat stable.
    private var collapsedVoidLeadingInset: CGFloat {
        let laneTotal = max(0, collapsedSurfaceWidth - voidWidth)
        return laneTotal * (collapsedLeadingLaneWidth / collapsedSideLaneTotal)
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
                commonCollapsedSurfaceFrame.width,
                voidWidth + collapsedSideLaneTotal
            )
        )
    }

    private var collapsedVisibleHeight: CGFloat {
        max(Self.minimumCollapsedSurfaceFrame.height, commonCollapsedSurfaceFrame.height, voidHeight)
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
            return commonCollapsedSurfaceFrame.height
        }

        return min(max(0, voidHeight), Self.maximumExpandedContentTopInset)
    }

    private var canRenderTextInTopRow: Bool {
        voidWidth <= 0 && voidHeight <= 0
    }

    private static let minimumCollapsedSurfaceFrame = CGRect(x: 0, y: 0, width: 110, height: 28)
    private var commonCollapsedSurfaceFrame: CGRect {
        CGRect(
            x: 0,
            y: 0,
            width: Self.fallbackVoidWidth + collapsedSideLaneTotal,
            height: Self.fallbackVoidHeight
        )
    }
    private static let expandedContentDesignFrame = CGRect(
        x: 0,
        y: 0,
        width: UserQueryLayout.composerInputSurfaceWidth + Self.inputHorizontalMargin * 2,
        height: 280
    )
    /// The collapsed surface's side lanes flank the void, and each is sized by what it holds. The
    /// original (unused) lane width is `collapsedOriginalLaneWidth`; a lane expands past it only for
    /// content that needs the room — the trailing lane for the live clock, the leading lane for a
    /// multi-pointer cluster — and collapses back when that content is gone. When both sit at the
    /// original width the void is centered; an expanded lane seats it off-center (see
    /// `surfaceVoidCenterX`), which the host positioning compensates for.
    public static let collapsedOriginalLaneWidth: CGFloat = 34
    /// The trailing lane width while the live elapsed clock ("Nh Nm Ns") shows beside the camera.
    public static let collapsedClockLaneWidth: CGFloat = 64
    /// Pointer-cluster geometry, shared with the notch view's `pointerCluster` so the leading lane is
    /// sized to the exact cascade it renders: a base pointer plus a fixed step per extra pointer, capped.
    public static let collapsedPointerSize: CGFloat = 14
    public static let collapsedPointerStepX: CGFloat = 8
    public static let collapsedMaxClusterPointers: Int = 3

    /// Width of the rendered pointer cascade for `pointerCount` surfaced conversations (capped at the
    /// cluster max). One or none is a single pointer; each extra pointer adds one cascade step.
    public static func collapsedPointerClusterWidth(_ pointerCount: Int) -> CGFloat {
        let visible = max(1, min(pointerCount, collapsedMaxClusterPointers))
        return collapsedPointerSize + collapsedPointerStepX * CGFloat(visible - 1)
    }

    private var collapsedLeadingLaneWidth: CGFloat {
        max(Self.collapsedOriginalLaneWidth, Self.collapsedPointerClusterWidth(collapsedLeadingPointerCount))
    }
    private var collapsedTrailingLaneWidth: CGFloat {
        collapsedTrailingSlot.needsWideLane ? Self.collapsedClockLaneWidth : Self.collapsedOriginalLaneWidth
    }
    private var collapsedSideLaneTotal: CGFloat { collapsedLeadingLaneWidth + collapsedTrailingLaneWidth }
    private static let collapsedCornerRadius: CGFloat = 14
    // Prototype spec: the expanded notch window and its input box both use a 14px radius.
    private static let expandedCornerRadius: CGFloat = 14
    private static let maximumExpandedContentTopInset: CGFloat = 44
}
