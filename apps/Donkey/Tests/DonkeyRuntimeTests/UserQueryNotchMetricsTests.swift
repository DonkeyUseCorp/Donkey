import CoreGraphics
import DonkeyContracts
import Testing

@Suite
struct UserQueryNotchMetricsTests {
    @Test
    func noVoidLayoutKeepsCommandComposerBelowTopRow() {
        let metrics = UserQueryNotchMetrics(
            voidWidth: 0,
            voidHeight: 0,
            expandedContentHeight: UserQueryNotchMetrics.expandedTaskContentHeight,
            isExpanded: true,
            isHostExpanded: true,
            screenWidth: UserQueryNotchMetrics.defaultScreenWidth
        )
        let layout = metrics.layout

        #expect(layout.canRenderTextInTopRow)
        #expect(layout.shouldRenderExpandedTopRowVoidMarker)
        #expect(
            layout.expandedCommandOnlyTopPadding ==
                UserQueryNotchLayout.expandedCommandOnlyTopPaddingBelowPhysicalVoid
        )
        #expect(layout.expandedContentFrame.minY == UserQueryNotchMetrics.fallbackVoidHeight)
        #expect(layout.expandedContentFrame.height == UserQueryNotchMetrics.expandedTaskContentHeight)
        #expect(
            layout.expandedSurfaceFrame.height ==
                UserQueryNotchMetrics.expandedTaskContentHeight +
                UserQueryNotchMetrics.fallbackVoidHeight
        )
    }

    @Test
    func physicalVoidLayoutKeepsTextBelowTopRow() {
        let metrics = UserQueryNotchMetrics(
            voidWidth: UserQueryNotchMetrics.fallbackVoidWidth,
            voidHeight: UserQueryNotchMetrics.fallbackVoidHeight,
            expandedContentHeight: UserQueryNotchMetrics.expandedTaskContentHeight,
            isExpanded: true,
            isHostExpanded: true,
            screenWidth: UserQueryNotchMetrics.defaultScreenWidth
        )
        let layout = metrics.layout

        #expect(!layout.canRenderTextInTopRow)
        #expect(layout.shouldRenderExpandedTopRowVoidMarker)
        #expect(
            layout.expandedCommandOnlyTopPadding ==
                UserQueryNotchLayout.expandedCommandOnlyTopPaddingBelowPhysicalVoid
        )
        #expect(layout.expandedContentFrame.minY == UserQueryNotchMetrics.fallbackVoidHeight)
        #expect(layout.expandedContentFrame.height == UserQueryNotchMetrics.expandedTaskContentHeight)
        #expect(
            layout.expandedSurfaceFrame.height ==
                UserQueryNotchMetrics.expandedTaskContentHeight +
                UserQueryNotchMetrics.fallbackVoidHeight
        )
    }

    @Test
    func noVoidCollapsedRowGrowsForWrappedSecondLine() {
        func collapsedHeight(extra: CGFloat) -> CGFloat {
            UserQueryNotchMetrics(
                voidWidth: 0,
                voidHeight: 0,
                expandedContentHeight: UserQueryNotchMetrics.expandedTaskContentHeight,
                isExpanded: false,
                isHostExpanded: false,
                screenWidth: UserQueryNotchMetrics.defaultScreenWidth,
                collapsedTopRowExtraHeight: extra
            ).layout.collapsedSurfaceFrame.height
        }

        // The inline headline's second line adds exactly its line-height to the collapsed pill.
        #expect(collapsedHeight(extra: 15) == collapsedHeight(extra: 0) + 15)
    }

    @Test
    func physicalVoidCollapsedRowIgnoresTopRowExtraHeight() {
        // A real notch routes the second line into the chin band, so the inline top-row growth never
        // applies — the collapsed pill stays the single-row height regardless of the value passed.
        func collapsedHeight(extra: CGFloat) -> CGFloat {
            UserQueryNotchMetrics(
                voidWidth: UserQueryNotchMetrics.fallbackVoidWidth,
                voidHeight: UserQueryNotchMetrics.fallbackVoidHeight,
                expandedContentHeight: UserQueryNotchMetrics.expandedTaskContentHeight,
                isExpanded: false,
                isHostExpanded: false,
                screenWidth: UserQueryNotchMetrics.defaultScreenWidth,
                collapsedTopRowExtraHeight: extra
            ).layout.collapsedSurfaceFrame.height
        }

        #expect(collapsedHeight(extra: 15) == collapsedHeight(extra: 0))
    }
}
