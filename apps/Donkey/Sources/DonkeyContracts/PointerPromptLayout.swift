import CoreGraphics

public enum PointerPromptLayout {
    public static let contentWidth: CGFloat = 448
    public static let contentExtraHeight: CGFloat = 4
    public static let stageHorizontalPadding: CGFloat = 8
    public static let stageVerticalPadding: CGFloat = 10
    public static let pointerSlotSize = CGSize(width: 58, height: 68)
    public static let pointerVisualSize = CGSize(width: 24, height: 24)
    public static let pointerTipUnitPoint = CGPoint(x: 0.16914, y: 0.05641)
    public static let pointerStrokeWidth: CGFloat = 1.6
    public static let pointerDistanceFromCursor: CGFloat = 48
    public static let pointerDiagonalComponent = pointerDistanceFromCursor / CGFloat(2).squareRoot()
    public static let pointerComposerSpacing: CGFloat = 16
    public static let composerWidth: CGFloat = 350
    public static let composerCornerRadius: CGFloat = 12
    public static let composerDragBorderThickness: CGFloat = 14
    public static let composerTitlebarHeight: CGFloat = 48
    public static let composerBottomPadding: CGFloat = 16
    public static let composerInputHorizontalPadding: CGFloat = 16
    public static let composerInputLeadingContentPadding: CGFloat = 20
    public static let composerInputTrailingContentPadding: CGFloat = 8
    public static let composerInputMinimumHeight: CGFloat = 46.4
    public static let composerInputTextMinimumHeight: CGFloat = 19.2
    public static let composerInputTextVerticalPadding: CGFloat = 13.6
    public static let composerInputVoiceButtonSize: CGFloat = 33.6
    public static let closeButtonSize: CGFloat = 12
    public static let closeButtonInset: CGFloat = 16
    public static let closeControlWidth = closeButtonSize

    public static let contentSize = contentSize(inputTextHeight: composerInputTextMinimumHeight)
    public static let composerSize = CGSize(
        width: composerWidth,
        height: composerHeight(inputTextHeight: composerInputTextMinimumHeight)
    )

    public static func composerInputHeight(inputTextHeight: CGFloat) -> CGFloat {
        max(
            composerInputMinimumHeight,
            inputTextHeight + composerInputTextVerticalPadding * 2
        )
    }

    public static func composerHeight(inputTextHeight: CGFloat) -> CGFloat {
        composerTitlebarHeight +
            composerInputHeight(inputTextHeight: inputTextHeight) +
            composerBottomPadding
    }

    public static func contentSize(inputTextHeight: CGFloat) -> CGSize {
        CGSize(
            width: contentWidth,
            height: stageVerticalPadding * 2 +
                composerHeight(inputTextHeight: inputTextHeight) +
                contentExtraHeight
        )
    }
}
