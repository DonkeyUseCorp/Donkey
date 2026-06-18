import CoreGraphics

public enum UserQueryLayout {
    public static let contentWidth: CGFloat = 592
    public static let contentExtraHeight: CGFloat = 8
    public static let stageHorizontalPadding: CGFloat = 8
    public static let stageVerticalPadding: CGFloat = 10
    public static let pointerSlotSize = CGSize(width: 58, height: 68)
    public static let pointerVisualSize = CGSize(width: 24, height: 24)
    public static let pointerTipUnitPoint = CGPoint(x: 0.16914, y: 0.05641)
    public static let pointerStrokeWidth: CGFloat = 1.6
    public static let pointerDistanceFromCursor: CGFloat = 48
    public static let pointerDiagonalComponent = pointerDistanceFromCursor / CGFloat(2).squareRoot()
    public static let pointerComposerSpacing: CGFloat = 16
    public static let composerWidth: CGFloat = 576
    public static let composerInputSurfaceWidth: CGFloat = 576
    public static let composerCornerRadius: CGFloat = 22
    public static let composerDragBorderThickness: CGFloat = 14
    public static let composerTitlebarHeight: CGFloat = 0
    public static let composerBottomPadding: CGFloat = 0
    public static let composerInputHorizontalPadding: CGFloat = 16
    public static let composerInputLeadingContentPadding: CGFloat = 20
    public static let composerInputTrailingContentPadding: CGFloat = 14.6
    public static let composerTextWaveformSpacing: CGFloat = 12
    public static let composerWaveformSize = CGSize(width: 54, height: 28)
    public static let composerInputMinimumHeight: CGFloat = 66
    public static let composerInputTextMinimumHeight: CGFloat = 19.2
    public static let composerInputTextMaximumHeight: CGFloat = 134.4
    public static let composerInputTextVerticalPadding: CGFloat = 23.4
    public static let composerInputVoiceButtonSize: CGFloat = 33.6
    public static let composerMicrophoneIconSize: CGFloat = 28
    public static let composerSendButtonSize: CGFloat = 36.8
    public static let composerTrailingControlsSpacing: CGFloat = 16
    public static let composerTrailingControlsWidth: CGFloat =
        composerMicrophoneIconSize + composerTrailingControlsSpacing + composerSendButtonSize
    public static let composerExpandedTextTopPadding: CGFloat = 18
    public static let composerExpandedTextHorizontalPadding: CGFloat = 24
    public static let composerExpandedToolbarHeight: CGFloat = 54
    public static let composerExpandedMinimumHeight: CGFloat = 156

    // The notch follow-up box starts as a single line and grows with its text. Send button sits
    // in the bottom-right corner of the same box (no separate toolbar row), mirroring the prototype.
    public static let followUpComposerCornerRadius: CGFloat = 14
    public static let followUpComposerSendButtonSize: CGFloat = 28
    public static let followUpComposerLeadingPadding: CGFloat = 20
    /// Right inset large enough to keep wrapped text clear of the corner send button.
    public static let followUpComposerTrailingPadding: CGFloat = 44
    public static let followUpComposerVerticalInset: CGFloat = 6
    /// One-line resting height: a compact single-line bar that seats the corner send button (6 + 28 + 6),
    /// matching the thin iMessage-style input.
    public static let followUpComposerMinimumHeight: CGFloat = 40

    public static var followUpComposerTextWidth: CGFloat {
        composerInputSurfaceWidth - followUpComposerLeadingPadding - followUpComposerTrailingPadding
    }

    /// Clamped height of the editable text area inside the follow-up box (one line up to the scroll cap).
    public static func followUpComposerTextAreaHeight(inputTextHeight: CGFloat) -> CGFloat {
        clampedComposerInputTextHeight(inputTextHeight)
    }

    /// Outer follow-up box height: the text area plus vertical insets, never below the one-line resting height.
    public static func followUpComposerHeight(inputTextHeight: CGFloat) -> CGFloat {
        max(
            followUpComposerMinimumHeight,
            followUpComposerTextAreaHeight(inputTextHeight: inputTextHeight) + followUpComposerVerticalInset * 2
        )
    }

    public static let contentSize = contentSize(inputTextHeight: composerInputTextMinimumHeight)
    public static let composerSize = CGSize(
        width: composerWidth,
        height: composerHeight(inputTextHeight: composerInputTextMinimumHeight)
    )

    public static func composerInputHeight(inputTextHeight: CGFloat) -> CGFloat {
        composerInputHeight(
            inputTextHeight: inputTextHeight,
            isExpanded: isComposerInputExpanded(inputTextHeight: inputTextHeight)
        )
    }

    public static func composerInputHeight(
        inputTextHeight: CGFloat,
        isExpanded: Bool
    ) -> CGFloat {
        let inputTextHeight = clampedComposerInputTextHeight(inputTextHeight)

        guard isExpanded else {
            return composerInputMinimumHeight
        }

        let measuredHeight = inputTextHeight +
            composerExpandedTextTopPadding +
            composerExpandedToolbarHeight

        return max(composerExpandedMinimumHeight, measuredHeight)
    }

    public static func isComposerInputExpanded(inputTextHeight: CGFloat) -> Bool {
        inputTextHeight > composerInputTextMinimumHeight + 1
    }

    public static func clampedComposerInputTextHeight(_ inputTextHeight: CGFloat) -> CGFloat {
        min(
            max(composerInputTextMinimumHeight, inputTextHeight),
            composerInputTextMaximumHeight
        )
    }

    public static var composerWrappingTextWidth: CGFloat {
        composerInputSurfaceWidth -
            composerInputLeadingContentPadding -
            composerInputTrailingContentPadding -
            composerTextWaveformSpacing -
            composerTrailingControlsWidth
    }

    public static var composerExpandedTextWidth: CGFloat {
        composerInputSurfaceWidth - composerExpandedTextHorizontalPadding * 2
    }

    public static func singleLineComposerInputHeight(inputTextHeight: CGFloat) -> CGFloat {
        max(
            composerInputMinimumHeight,
            inputTextHeight + composerInputTextVerticalPadding * 2
        )
    }

    public static func composerHeight(inputTextHeight: CGFloat) -> CGFloat {
        composerInputHeight(inputTextHeight: inputTextHeight)
    }

    public static func composerHeight(inputTextHeight: CGFloat, isExpanded: Bool) -> CGFloat {
        composerInputHeight(inputTextHeight: inputTextHeight, isExpanded: isExpanded)
    }

    public static func contentSize(inputTextHeight: CGFloat) -> CGSize {
        contentSize(
            inputTextHeight: inputTextHeight,
            isExpanded: isComposerInputExpanded(inputTextHeight: inputTextHeight)
        )
    }

    public static func contentSize(inputTextHeight: CGFloat, isExpanded: Bool) -> CGSize {
        CGSize(
            width: contentWidth,
            height: stageVerticalPadding * 2 +
                composerHeight(inputTextHeight: inputTextHeight, isExpanded: isExpanded) +
                contentExtraHeight
        )
    }
}
