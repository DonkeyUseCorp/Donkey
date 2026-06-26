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
            screenWidth: UserQueryNotchMetrics.defaultScreenWidth,
            collapsedTrailingSlot: .clock
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
    func collapsedRealNotchIsSymmetricWhenClockIsIdle() {
        let metrics = UserQueryNotchMetrics(
            voidWidth: UserQueryNotchMetrics.fallbackVoidWidth,
            voidHeight: UserQueryNotchMetrics.fallbackVoidHeight,
            expandedContentHeight: UserQueryNotchMetrics.expandedConversationContentHeight,
            isExpanded: false,
            isHostExpanded: false,
            screenWidth: UserQueryNotchMetrics.defaultScreenWidth,
            collapsedTrailingSlot: .empty
        )
        let layout = metrics.layout
        let leading = layout.collapsedVoidLeadingInset
        let trailing = layout.collapsedSurfaceFrame.width - leading - metrics.voidWidth

        // With nothing in the gutter, the trailing lane sits at its original size (34), matching the
        // leading lane (34) — so the lanes are symmetric and the void is centered.
        #expect(trailing == leading)
        #expect(leading == UserQueryNotchMetrics.collapsedOriginalLaneWidth)
        #expect(trailing == UserQueryNotchMetrics.collapsedOriginalLaneWidth)
        #expect(metrics.surfaceVoidCenterX == leading + metrics.voidWidth / 2)
        #expect(metrics.surfaceVoidCenterX == metrics.surfaceSize.width / 2)
    }

    @Test
    func collapsedTrailingLaneCollapsesForAGlyphAndExpandsOnlyForTheClock() {
        func laneWidths(_ slot: CollapsedTrailingSlot) -> (leading: CGFloat, trailing: CGFloat) {
            let metrics = UserQueryNotchMetrics(
                voidWidth: UserQueryNotchMetrics.fallbackVoidWidth,
                voidHeight: UserQueryNotchMetrics.fallbackVoidHeight,
                expandedContentHeight: UserQueryNotchMetrics.expandedConversationContentHeight,
                isExpanded: false,
                isHostExpanded: false,
                screenWidth: UserQueryNotchMetrics.defaultScreenWidth,
                collapsedTrailingSlot: slot
            )
            let layout = metrics.layout
            let leading = layout.collapsedVoidLeadingInset
            return (leading, layout.collapsedSurfaceFrame.width - leading - metrics.voidWidth)
        }

        // The bug this fixes: a conversation waiting on the user (or a failure, or an available update) shows
        // a glyph, not the clock, so the trailing lane must collapse back to the original width — only the
        // live clock widens it. So the notch no longer jitters its void on a running → waiting transition.
        for glyphSlot: CollapsedTrailingSlot in [.attentionGlyph, .errorGlyph, .updateIcon, .empty] {
            #expect(laneWidths(glyphSlot).trailing == UserQueryNotchMetrics.collapsedOriginalLaneWidth)
        }
        #expect(laneWidths(.clock).trailing == UserQueryNotchMetrics.collapsedClockLaneWidth)
    }

    @Test
    func collapsedLeadingLaneExpandsForAPointerClusterAndCollapsesBack() {
        func leadingLane(pointerCount: Int) -> CGFloat {
            UserQueryNotchMetrics(
                voidWidth: UserQueryNotchMetrics.fallbackVoidWidth,
                voidHeight: UserQueryNotchMetrics.fallbackVoidHeight,
                expandedContentHeight: UserQueryNotchMetrics.expandedConversationContentHeight,
                isExpanded: false,
                isHostExpanded: false,
                screenWidth: UserQueryNotchMetrics.defaultScreenWidth,
                collapsedLeadingPointerCount: pointerCount
            ).layout.collapsedVoidLeadingInset
        }

        // One or no pointer keeps the leading lane at its original width; the lane only ever grows to fit
        // the cascade, never shrinks below the original, and the width tracks the same cluster geometry the
        // view renders (so it can't clip the pointers it draws).
        #expect(leadingLane(pointerCount: 0) == UserQueryNotchMetrics.collapsedOriginalLaneWidth)
        #expect(leadingLane(pointerCount: 1) == UserQueryNotchMetrics.collapsedOriginalLaneWidth)
        #expect(leadingLane(pointerCount: 3) >= UserQueryNotchMetrics.collapsedOriginalLaneWidth)
        #expect(
            leadingLane(pointerCount: 3) >=
                UserQueryNotchMetrics.collapsedPointerClusterWidth(3)
        )
    }

    @Test
    func collapsedTrailingSlotMatchesTheNotchGutterPrecedence() {
        // A surfaced failure wins the gutter over everything else.
        #expect(
            UserQueryNotchMetrics.collapsedTrailingSlot(
                primaryStatus: .running, hasSurfacedError: true, isUpdateActionable: true
            ) == .errorGlyph
        )
        // Otherwise the primary conversation's status drives it: running → clock, waiting → attention glyph.
        #expect(
            UserQueryNotchMetrics.collapsedTrailingSlot(
                primaryStatus: .running, hasSurfacedError: false, isUpdateActionable: false
            ) == .clock
        )
        for waiting: UserQueryConversationStatus in [.waitingForClarification, .waitingForReview, .waitingForPermission] {
            #expect(
                UserQueryNotchMetrics.collapsedTrailingSlot(
                    primaryStatus: waiting, hasSurfacedError: false, isUpdateActionable: false
                ) == .attentionGlyph
            )
        }
        // A terminal/benign status leaves the gutter empty even when a conversation is primary.
        #expect(
            UserQueryNotchMetrics.collapsedTrailingSlot(
                primaryStatus: .completed, hasSurfacedError: false, isUpdateActionable: true
            ) == .empty
        )
        // The update icon shows only when no conversation is primary.
        #expect(
            UserQueryNotchMetrics.collapsedTrailingSlot(
                primaryStatus: nil, hasSurfacedError: false, isUpdateActionable: true
            ) == .updateIcon
        )
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
