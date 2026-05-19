import CoreGraphics

public struct PointerPromptNotchLayout: Equatable, Sendable {
    public var voidWidth: CGFloat
    public var voidHeight: CGFloat
    public var collapsedVisibleHeight: CGFloat
    public var expandedVisibleHeight: CGFloat
    public var contentHorizontalInset: CGFloat
    public var visibleHeight: CGFloat
    public var cornerRadius: CGFloat

    public init(
        voidWidth: CGFloat,
        voidHeight: CGFloat,
        collapsedVisibleHeight: CGFloat,
        expandedVisibleHeight: CGFloat,
        contentHorizontalInset: CGFloat,
        visibleHeight: CGFloat,
        cornerRadius: CGFloat
    ) {
        self.voidWidth = voidWidth
        self.voidHeight = voidHeight
        self.collapsedVisibleHeight = collapsedVisibleHeight
        self.expandedVisibleHeight = expandedVisibleHeight
        self.contentHorizontalInset = contentHorizontalInset
        self.visibleHeight = visibleHeight
        self.cornerRadius = cornerRadius
    }
}
