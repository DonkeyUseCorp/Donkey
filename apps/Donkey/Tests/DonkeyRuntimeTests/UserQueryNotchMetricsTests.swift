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
}
