public enum PointerPromptPlacement: Equatable, Sendable {
    case bottomRight
    case bottomLeft
    case topLeft
    case topRight

    public var placesContentOnLeft: Bool {
        switch self {
        case .bottomLeft, .topLeft:
            true
        case .bottomRight, .topRight:
            false
        }
    }

    public var placesContentAbovePointer: Bool {
        switch self {
        case .topLeft, .topRight:
            true
        case .bottomLeft, .bottomRight:
            false
        }
    }
}
