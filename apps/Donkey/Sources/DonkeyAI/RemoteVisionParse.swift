import Foundation

// Wire models for the hosted vision endpoint (POST /api/vision), which
// fronts the RunPod OmniParser V2 worker. Coordinates in the response are pixels
// relative to the uploaded image, origin top-left. See the contract in
// site/src/lib/inference/vision/schema.ts.

public struct RemoteVisionParseOptions: Codable, Equatable, Sendable {
    public var boxThreshold: Double?
    public var iouThreshold: Double?

    public init(boxThreshold: Double? = nil, iouThreshold: Double? = nil) {
        self.boxThreshold = boxThreshold
        self.iouThreshold = iouThreshold
    }
}

struct RemoteVisionParseRequest: Encodable {
    var image: String
    var returnElements: Bool
    var options: RemoteVisionParseOptions?
}

public struct RemoteVisionParseResponse: Decodable, Equatable, Sendable {
    public struct ImageSize: Decodable, Equatable, Sendable {
        public var width: Double
        public var height: Double
    }

    public struct Box: Decodable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
    }

    public struct Point: Decodable, Equatable, Sendable {
        public var x: Double
        public var y: Double
    }

    public struct Element: Decodable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var kind: String
        public var interactive: Bool
        public var box: Box
        public var point: Point
        public var confidence: Double
    }

    public var image: ImageSize
    public var elements: [Element]

    public init(image: ImageSize, elements: [Element]) {
        self.image = image
        self.elements = elements
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.image = try container.decode(ImageSize.self, forKey: .image)
        self.elements = try container.decodeIfPresent([Element].self, forKey: .elements) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case image
        case elements
    }
}
