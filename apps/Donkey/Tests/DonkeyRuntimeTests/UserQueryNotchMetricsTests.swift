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
            expandedContentHeight: UserQueryNotchMetrics.expandedConversationContentHeight,
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
        #expect(layout.expandedContentFrame.height == UserQueryNotchMetrics.expandedConversationContentHeight)
        #expect(
            layout.expandedSurfaceFrame.height ==
                UserQueryNotchMetrics.expandedConversationContentHeight +
                UserQueryNotchMetrics.fallbackVoidHeight
        )
    }

    @Test
    func physicalVoidLayoutKeepsTextBelowTopRow() {
        let metrics = UserQueryNotchMetrics(
            voidWidth: UserQueryNotchMetrics.fallbackVoidWidth,
            voidHeight: UserQueryNotchMetrics.fallbackVoidHeight,
            expandedContentHeight: UserQueryNotchMetrics.expandedConversationContentHeight,
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
        #expect(layout.expandedContentFrame.height == UserQueryNotchMetrics.expandedConversationContentHeight)
        #expect(
            layout.expandedSurfaceFrame.height ==
                UserQueryNotchMetrics.expandedConversationContentHeight +
                UserQueryNotchMetrics.fallbackVoidHeight
        )
    }

    @Test
    func noVoidCollapsedRowGrowsForWrappedSecondLine() {
        func collapsedHeight(extra: CGFloat) -> CGFloat {
            UserQueryNotchMetrics(
                voidWidth: 0,
                voidHeight: 0,
                expandedContentHeight: UserQueryNotchMetrics.expandedConversationContentHeight,
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
    func collapsedRealNotchSeatsVoidOffCenterForTheClock() {
        let metrics = UserQueryNotchMetrics(
            voidWidth: UserQueryNotchMetrics.fallbackVoidWidth,
            voidHeight: UserQueryNotchMetrics.fallbackVoidHeight,
            expandedContentHeight: UserQueryNotchMetrics.expandedConversationContentHeight,
            isExpanded: false,
            isHostExpanded: false,
            screenWidth: UserQueryNotchMetrics.defaultScreenWidth
        )
        let layout = metrics.layout
        let leading = layout.collapsedVoidLeadingInset
        let trailing = layout.collapsedSurfaceFrame.width - leading - metrics.voidWidth

        // The trailing lane (the live clock's room) is the wider of the two, so the void seats left of
        // the surface center — and the window positions by the void center, not the surface center.
        #expect(trailing > leading)
        #expect(metrics.surfaceVoidCenterX == leading + metrics.voidWidth / 2)
        #expect(metrics.surfaceVoidCenterX < metrics.surfaceSize.width / 2)
    }

    @Test
    func expandedAndNoVoidSurfacesPositionByTheirCenter() {
        // Expanded host: the void sits mid-surface, so it positions by the surface center (no offset).
        let expanded = UserQueryNotchMetrics(
            voidWidth: UserQueryNotchMetrics.fallbackVoidWidth,
            voidHeight: UserQueryNotchMetrics.fallbackVoidHeight,
            expandedContentHeight: UserQueryNotchMetrics.expandedConversationContentHeight,
            isExpanded: true,
            isHostExpanded: true,
            screenWidth: UserQueryNotchMetrics.defaultScreenWidth
        )
        #expect(expanded.surfaceVoidCenterX == expanded.surfaceSize.width / 2)

        // No-notch collapsed pill: nothing to seat, so it stays centered too.
        let noVoid = UserQueryNotchMetrics(
            voidWidth: 0,
            voidHeight: 0,
            expandedContentHeight: UserQueryNotchMetrics.expandedConversationContentHeight,
            isExpanded: false,
            isHostExpanded: false,
            screenWidth: UserQueryNotchMetrics.defaultScreenWidth
        )
        #expect(noVoid.surfaceVoidCenterX == noVoid.surfaceSize.width / 2)
    }

    @Test
    func physicalVoidCollapsedRowIgnoresTopRowExtraHeight() {
        // A real notch routes the second line into the chin band, so the inline top-row growth never
        // applies — the collapsed pill stays the single-row height regardless of the value passed.
        func collapsedHeight(extra: CGFloat) -> CGFloat {
            UserQueryNotchMetrics(
                voidWidth: UserQueryNotchMetrics.fallbackVoidWidth,
                voidHeight: UserQueryNotchMetrics.fallbackVoidHeight,
                expandedContentHeight: UserQueryNotchMetrics.expandedConversationContentHeight,
                isExpanded: false,
                isHostExpanded: false,
                screenWidth: UserQueryNotchMetrics.defaultScreenWidth,
                collapsedTopRowExtraHeight: extra
            ).layout.collapsedSurfaceFrame.height
        }

        #expect(collapsedHeight(extra: 15) == collapsedHeight(extra: 0))
    }
}
