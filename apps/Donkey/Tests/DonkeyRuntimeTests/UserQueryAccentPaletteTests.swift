import DonkeyContracts
import Testing

@Suite
struct UserQueryAccentPaletteTests {
    @Test
    func paletteCyclesThroughSupportedAccentList() {
        var currentIndex: Int?

        let sequence = (0..<10).map { _ in
            let nextIndex = currentIndex.map(UserQueryAccentPalette.index(after:))
                ?? UserQueryAccentPalette.firstIndex
            currentIndex = nextIndex
            return nextIndex
        }

        #expect(sequence == [0, 1, 2, 3, 4, 5, 6, 7, 0, 1])
    }

    @Test
    func paletteContinuesAfterKnownAccent() {
        #expect(UserQueryAccentPalette.index(after: 1) == 2)
        #expect(UserQueryAccentPalette.index(after: 7) == 0)
    }

    @Test
    func paletteNormalizesOutOfRangeIndexes() {
        #expect(UserQueryAccentPalette.normalizedIndex(-1) == 7)
        #expect(UserQueryAccentPalette.normalizedIndex(8) == 0)
        #expect(UserQueryAccentPalette.index(after: 7) == 0)
    }
}
