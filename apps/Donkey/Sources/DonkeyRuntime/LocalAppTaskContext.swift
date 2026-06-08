import Foundation

public struct LocalDocumentFormField: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var isRequired: Bool
    public var currentValue: String?
    public var metadata: [String: String]

    public init(
        id: String,
        label: String,
        isRequired: Bool = false,
        currentValue: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.label = label
        self.isRequired = isRequired
        self.currentValue = currentValue
        self.metadata = metadata
    }
}
