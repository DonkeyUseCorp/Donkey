import CoreGraphics

public struct PointerPromptNotchLayout: Equatable, Sendable {
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
        expandedCornerRadius: CGFloat
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
    }
}
