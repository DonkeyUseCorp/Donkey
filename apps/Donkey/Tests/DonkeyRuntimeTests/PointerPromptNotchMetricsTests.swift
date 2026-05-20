import CoreGraphics
import DonkeyContracts
import Testing

@Suite
struct PointerPromptNotchMetricsTests {
    @Test
    func noVoidLayoutKeepsCommandComposerBelowTopRow() {
        let metrics = PointerPromptNotchMetrics(
            voidWidth: 0,
            voidHeight: 0,
            expandedContentHeight: PointerPromptNotchMetrics.expandedTaskContentHeight,
            isExpanded: true,
            isHostExpanded: true,
            screenWidth: PointerPromptNotchMetrics.defaultScreenWidth
        )
        let layout = metrics.layout

        #expect(layout.canRenderTextInTopRow)
        #expect(layout.shouldRenderExpandedTopRowVoidMarker)
        #expect(
            layout.expandedCommandOnlyTopPadding ==
                PointerPromptNotchMetrics.fallbackVoidHeight +
                PointerPromptNotchLayout.expandedCommandOnlyTopPaddingBelowPhysicalVoid
        )
        #expect(layout.expandedContentFrame.minY == 0)
        #expect(layout.expandedContentFrame.height == layout.expandedSurfaceFrame.height)
        #expect(layout.expandedSurfaceFrame.height > PointerPromptNotchMetrics.expandedTaskContentHeight)
    }

    @Test
    func physicalVoidLayoutKeepsTextBelowTopRow() {
        let metrics = PointerPromptNotchMetrics(
            voidWidth: PointerPromptNotchMetrics.fallbackVoidWidth,
            voidHeight: PointerPromptNotchMetrics.fallbackVoidHeight,
            expandedContentHeight: PointerPromptNotchMetrics.expandedTaskContentHeight,
            isExpanded: true,
            isHostExpanded: true,
            screenWidth: PointerPromptNotchMetrics.defaultScreenWidth
        )
        let layout = metrics.layout

        #expect(!layout.canRenderTextInTopRow)
        #expect(layout.shouldRenderExpandedTopRowVoidMarker)
        #expect(
            layout.expandedCommandOnlyTopPadding ==
                PointerPromptNotchMetrics.fallbackVoidHeight +
                PointerPromptNotchLayout.expandedCommandOnlyTopPaddingBelowPhysicalVoid
        )
        #expect(layout.expandedContentFrame.minY == PointerPromptNotchMetrics.fallbackVoidHeight)
        #expect(layout.expandedContentFrame.height == PointerPromptNotchMetrics.expandedTaskContentHeight)
        #expect(
            layout.expandedSurfaceFrame.height ==
                PointerPromptNotchMetrics.expandedTaskContentHeight +
                PointerPromptNotchMetrics.fallbackVoidHeight
        )
    }
}
