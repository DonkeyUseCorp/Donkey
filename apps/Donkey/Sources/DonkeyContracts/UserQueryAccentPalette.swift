public enum UserQueryAccentPalette {
    public static let supportedIndexes = [0, 1, 2, 3, 4, 5, 6, 7]
    public static let firstIndex = supportedIndexes[0]

    public static func normalizedIndex(_ index: Int) -> Int {
        supportedIndexes[((index % supportedIndexes.count) + supportedIndexes.count) % supportedIndexes.count]
    }

    public static func index(after index: Int) -> Int {
        normalizedIndex(index + 1)
    }
}
