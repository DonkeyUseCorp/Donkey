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
    public var cornerRadius: CGFloat
    public var collapsedSurfaceFrame: CGRect
    public var expandedSurfaceFrame: CGRect
    public var expandedContentFrame: CGRect
    public var collapsedCornerRadius: CGFloat
    public var expandedCornerRadius: CGFloat
    public var canRenderTextInTopRow: Bool
    /// Height of the chin band that hangs below the collapsed notch row while a task streams
    /// (0 when there is nothing to stream). The notch row itself stays `collapsedVisibleHeight`.
    public var chinHeight: CGFloat

    public init(
        voidWidth: CGFloat,
        voidHeight: CGFloat,
        collapsedVisibleHeight: CGFloat,
        expandedVisibleHeight: CGFloat,
        contentHorizontalInset: CGFloat,
        visibleHeight: CGFloat,
        cornerRadius: CGFloat,
        collapsedSurfaceFrame: CGRect,
        expandedSurfaceFrame: CGRect,
        expandedContentFrame: CGRect,
        collapsedCornerRadius: CGFloat,
        expandedCornerRadius: CGFloat,
        canRenderTextInTopRow: Bool,
        chinHeight: CGFloat = 0
    ) {
        self.voidWidth = voidWidth
        self.voidHeight = voidHeight
        self.collapsedVisibleHeight = collapsedVisibleHeight
        self.expandedVisibleHeight = expandedVisibleHeight
        self.contentHorizontalInset = contentHorizontalInset
        self.visibleHeight = visibleHeight
        self.cornerRadius = cornerRadius
        self.collapsedSurfaceFrame = collapsedSurfaceFrame
        self.expandedSurfaceFrame = expandedSurfaceFrame
        self.expandedContentFrame = expandedContentFrame
        self.collapsedCornerRadius = collapsedCornerRadius
        self.expandedCornerRadius = expandedCornerRadius
        self.canRenderTextInTopRow = canRenderTextInTopRow
        self.chinHeight = chinHeight
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
    /// Gap between rendering the collapsed baseline inside the expanded host and flipping
    /// `isExpanded` to spring the surface open. The collapsed render must fully commit first —
    /// otherwise the two passes coalesce and the notch snaps open instead of springing. One frame
    /// was too tight once the collapsed surface grew heavier content (pointer cluster + chin), whose
    /// SwiftUI render lands a frame late, so give the baseline a few frames to settle.
    public static let openHostPreparationDelay: TimeInterval = 0.08
    public static let closeAnimationDuration: TimeInterval = 0.22

    public var voidWidth: CGFloat
    public var voidHeight: CGFloat
    public var expandedContentHeight: CGFloat
    public var isExpanded: Bool
    public var isHostExpanded: Bool
    public var screenWidth: CGFloat
    /// Chin band below the collapsed notch row while a task streams (0 otherwise).
    public var chinHeight: CGFloat

    public init(
        voidWidth: CGFloat,
        voidHeight: CGFloat,
        expandedContentHeight: CGFloat,
        isExpanded: Bool,
        isHostExpanded: Bool,
        screenWidth: CGFloat,
        chinHeight: CGFloat = 0
    ) {
        self.voidWidth = voidWidth
        self.voidHeight = voidHeight
        self.expandedContentHeight = expandedContentHeight
        self.isExpanded = isExpanded
        self.isHostExpanded = isHostExpanded
        self.screenWidth = screenWidth
        self.chinHeight = chinHeight
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
            cornerRadius: isExpanded ? Self.expandedCornerRadius : Self.collapsedCornerRadius,
            collapsedSurfaceFrame: collapsedSurfaceFrame,
            expandedSurfaceFrame: expandedSurfaceFrame,
            expandedContentFrame: expandedContentFrame,
            collapsedCornerRadius: Self.collapsedCornerRadius,
            expandedCornerRadius: Self.expandedCornerRadius,
            canRenderTextInTopRow: canRenderTextInTopRow,
            chinHeight: effectiveChinHeight
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
            height: collapsedVisibleHeight + effectiveChinHeight
        )
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
