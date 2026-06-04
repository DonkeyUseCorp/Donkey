import DonkeyContracts
import Foundation

public enum DebugUIInspectionHostedAdapterError: Error, Equatable, Sendable {
    case providerReturnedAction
    case missingOutputText
    case invalidJSON(String)
}

public struct DebugUIInspectionRequest: Equatable, Sendable {
    public var provider: DebugUIInspectionProvider?
    /// Full `data:<contentType>;base64,<…>` URL for the image. Callers prepare this with the shared
    /// `ScreenshotCompression` helper so every hosted-vision request is downscaled + JPEG-encoded the
    /// same way; `pixelSize` must be the size of THIS image (model coordinates map back through it).
    public var imageDataURL: String
    public var pixelSize: HotLoopSize
    public var minConfidence: Double
    public var metadata: [String: String]

    public init(
        provider: DebugUIInspectionProvider? = nil,
        imageDataURL: String,
        pixelSize: HotLoopSize,
        minConfidence: Double = 0.25,
        metadata: [String: String] = [:]
    ) {
        self.provider = provider
        self.imageDataURL = imageDataURL
        self.pixelSize = pixelSize
        self.minConfidence = min(max(minConfidence, 0), 1)
        self.metadata = metadata
    }
}

public protocol DebugUIInspectionAnalyzing: Sendable {
    func inspect(_ request: DebugUIInspectionRequest) async throws -> DebugUIInspectionFrame
}

public struct HostedDebugUIInspectionAnalyzer: DebugUIInspectionAnalyzing {
    public var backend: DonkeyBackendInferenceClient
    public var decoder: JSONDecoder

    public init(
        backend: DonkeyBackendInferenceClient,
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.backend = backend
        self.decoder = decoder
    }

    public func inspect(_ request: DebugUIInspectionRequest) async throws -> DebugUIInspectionFrame {
        let response = try await backend.createResponse(responseRequest(for: request))
        return try DebugUIInspectionResponseDecoder.decode(
            response,
            decoder: decoder,
            screenshotPixelSize: request.pixelSize,
            minConfidence: request.minConfidence
        )
    }

    private func responseRequest(
        for request: DebugUIInspectionRequest
    ) -> RemoteInferenceResponseCreateRequest {
        RemoteInferenceResponseCreateRequest(
            donkeyProvider: request.provider?.rawValue,
            input: .array([
                .object([
                    "role": .string("user"),
                    "content": .array([
                        .object([
                            "type": .string("input_text"),
                            "text": .string(Self.prompt(for: request.pixelSize))
                        ]),
                        .object([
                            "type": .string("input_image"),
                            "image_url": .string(request.imageDataURL),
                            "detail": .string("original")
                        ])
                    ])
                ])
            ]),
            store: false,
            text: Self.responseFormat,
            tools: [
                RemoteInferenceComputerUseTool(
                    type: .debugUIInspection,
                    excludedPredefinedFunctions: Self.excludedActionNames,
                    metadata: [
                        "mode": "read_only",
                        "schema": "debug_ui_inspection_v1"
                    ]
                ).jsonObject
            ],
            metadata: request.metadata.merging([
                "source": "debug-ui-inspection-overlay",
                "prompt_version": "debug-ui-inspection-v1",
                "privacy.store": "false",
                "screenshot.width": String(request.pixelSize.width),
                "screenshot.height": String(request.pixelSize.height)
            ]) { current, _ in current },
            parameters: [
                "reasoning": .object([
                    "effort": .string("low")
                ]),
                "max_output_tokens": .number(8_000)
            ]
        )
    }

    private static func prompt(for pixelSize: HotLoopSize) -> String {
        let width = max(1, Int(pixelSize.width.rounded()))
        let height = max(1, Int(pixelSize.height.rounded()))
        return """
    You are a read-only macOS UI inspection model. Return bounding boxes for visible visual controls that are likely clickable or otherwise user-interactable. Return ONLY valid JSON.

    The attached screenshot coordinate space is exactly \(width) pixels wide by \(height) pixels high.

    Find every visible control candidate a person could click, focus, drag, select, or activate. Include macOS window controls, browser toolbar controls, app sidebars, buttons, links, tabs, menu items, dropdowns, text inputs, search fields, checkboxes, radios, toggles, sliders, toolbar icons, sidebar rows, list rows, clickable cards, draggable handles, resize handles, scrollbars, split panes, canvas interaction regions, floating action buttons, and icon-only controls. Prefer over-detecting likely controls over missing them.

    Do not include static text, decorative graphics, separators, backgrounds, or non-interactable containers unless they are clearly interactive.

    Coordinates must be screenshot pixel coordinates in that \(width)x\(height) coordinate space with origin at top-left. Bounding boxes must tightly fit the clickable region. If you can only report coordinates in a resized internal image coordinate space, set coordinate_space to that image width and height so the client can scale the boxes. If an element is partially obscured, include it with lower confidence. Infer labels for icon-only controls when possible.

    Do not return an empty elements array unless the screenshot is blank or contains no visible UI. For a normal macOS desktop screenshot, return the visible controls you can identify.

    Do not click, type, scroll, drag, navigate, call tools, or propose actions. This is visual inspection only.

    Return exactly:
    {"coordinate_space":{"width":\(width),"height":\(height)},"elements":[{"id":"stable_unique_id","type":"button","label":"Save","description":"Saves current document","bbox":{"x":120,"y":340,"width":88,"height":32},"confidence":0.98,"visual_style":{"overlay_color":"#3B82F6","border_color":"#60A5FA","label_color":"#FFFFFF"}}]}
    """
    }

    private static let excludedActionNames = [
        "click",
        "click_at",
        "double_click",
        "drag",
        "drag_and_drop",
        "go_back",
        "go_forward",
        "hover",
        "hover_at",
        "key_combination",
        "navigate",
        "open_web_browser",
        "scroll",
        "scroll_document",
        "search",
        "type",
        "type_text",
        "type_text_at"
    ]

    private static let responseFormat: RemoteInferenceJSONObject = [
        "verbosity": .string("low"),
        "format": .object([
            "type": .string("json_schema"),
            "name": .string("debug_ui_inspection_v1"),
            "strict": .bool(true),
            "schema": .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "required": .array([
                    .string("coordinate_space"),
                    .string("elements")
                ]),
                "properties": .object([
                    "coordinate_space": .object([
                        "type": .string("object"),
                        "additionalProperties": .bool(false),
                        "required": .array([
                            .string("width"),
                            .string("height")
                        ]),
                        "properties": .object([
                            "width": .object([
                                "type": .string("number"),
                                "minimum": .number(1)
                            ]),
                            "height": .object([
                                "type": .string("number"),
                                "minimum": .number(1)
                            ])
                        ])
                    ]),
                    "elements": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "additionalProperties": .bool(false),
                            "required": .array([
                                .string("id"),
                                .string("type"),
                                .string("label"),
                                .string("description"),
                                .string("bbox"),
                                .string("confidence"),
                                .string("visual_style")
                            ]),
                            "properties": .object([
                                "id": .object(["type": .string("string")]),
                                "type": .object([
                                    "type": .string("string"),
                                    "enum": .array(DebugUIElementType.allCases.map { .string($0.rawValue) })
                                ]),
                                "label": .object(["type": .string("string")]),
                                "description": .object(["type": .string("string")]),
                                "bbox": .object([
                                    "type": .string("object"),
                                    "additionalProperties": .bool(false),
                                    "required": .array([
                                        .string("x"),
                                        .string("y"),
                                        .string("width"),
                                        .string("height")
                                    ]),
                                    "properties": .object([
                                        "x": .object(["type": .string("number")]),
                                        "y": .object(["type": .string("number")]),
                                        "width": .object(["type": .string("number")]),
                                        "height": .object(["type": .string("number")])
                                    ])
                                ]),
                                "confidence": .object([
                                    "type": .string("number"),
                                    "minimum": .number(0),
                                    "maximum": .number(1)
                                ]),
                                "visual_style": .object([
                                    "type": .string("object"),
                                    "additionalProperties": .bool(false),
                                    "required": .array([
                                        .string("overlay_color"),
                                        .string("border_color"),
                                        .string("label_color")
                                    ]),
                                    "properties": .object([
                                        "overlay_color": .object(["type": .string("string")]),
                                        "border_color": .object(["type": .string("string")]),
                                        "label_color": .object(["type": .string("string")])
                                    ])
                                ])
                            ])
                        ])
                    ])
                ])
            ])
        ])
    ]
}

public enum DebugUIInspectionResponseDecoder {
    public static func decode(
        _ response: RemoteInferenceJSONValue,
        decoder: JSONDecoder = JSONDecoder(),
        screenshotPixelSize: HotLoopSize? = nil,
        minConfidence: Double = 0.25
    ) throws -> DebugUIInspectionFrame {
        guard containsActionOutput(response) == false else {
            throw DebugUIInspectionHostedAdapterError.providerReturnedAction
        }

        let frameData: Data
        if let object = response.objectValue,
           object["elements"] != nil {
            frameData = try JSONEncoder().encode(response)
        } else {
            guard let outputText = outputText(from: response),
                  !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw DebugUIInspectionHostedAdapterError.missingOutputText
            }
            // Vision models occasionally wrap the JSON in markdown fences or add trailing prose;
            // extract the JSON object so a stray character doesn't fail the whole inspection.
            frameData = Data(jsonObjectSubstring(outputText).utf8)
        }

        do {
            let rawFrame = try decoder.decode(RawDebugUIInspectionFrame.self, from: frameData)
            return normalizedFrame(rawFrame, screenshotPixelSize: screenshotPixelSize)
                .validated(minConfidence: minConfidence)
        } catch {
            throw DebugUIInspectionHostedAdapterError.invalidJSON(String(describing: error))
        }
    }

    /// Extracts the JSON object from model output that may be fenced or have trailing prose.
    /// Returns the FIRST brace-balanced `{…}` object, scanning past braces that appear inside string
    /// literals — so trailing prose such as `{…valid…} note: see {example}` doesn't get swallowed
    /// into malformed JSON (which the old first-`{`-to-last-`}` heuristic did).
    static func jsonObjectSubstring(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            trimmed = trimmed
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = trimmed.firstIndex(of: "{") else { return trimmed }

        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < trimmed.endIndex {
            let character = trimmed[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(trimmed[start...index])
                    }
                default: break
                }
            }
            index = trimmed.index(after: index)
        }
        // Unbalanced (truncated) output: hand back from the first brace so the decoder surfaces it.
        return String(trimmed[start...])
    }

    public static func containsActionOutput(_ value: RemoteInferenceJSONValue) -> Bool {
        switch value {
        case .string(let text):
            return actionMarkers.contains { text.contains($0) }
        case .number, .bool, .null:
            return false
        case .array(let values):
            return values.contains(where: containsActionOutput)
        case .object(let object):
            if let type = object["type"]?.stringValue,
               actionTypes.contains(type) {
                return true
            }
            if object["functionCall"] != nil ||
                object["function_call"] != nil ||
                object["computer_call"] != nil {
                return true
            }
            return object.values.contains(where: containsActionOutput)
        }
    }

    private static func outputText(from value: RemoteInferenceJSONValue) -> String? {
        guard let object = value.objectValue else {
            return nil
        }

        if let text = object["output_text"]?.stringValue {
            return text
        }

        return object["output"]?.arrayValue?
            .compactMap(messageText)
            .joined(separator: "\n")
    }

    private static func messageText(from value: RemoteInferenceJSONValue) -> String? {
        guard let object = value.objectValue else {
            return nil
        }
        if let text = object["text"]?.stringValue {
            return text
        }
        return object["content"]?.arrayValue?
            .compactMap { content in
                guard let contentObject = content.objectValue else { return nil }
                return contentObject["text"]?.stringValue
            }
            .joined(separator: "\n")
    }

    private static let actionTypes = Set([
        "computer_call",
        "computer_call_output",
        "function_call"
    ])

    private static let actionMarkers = [
        "\"type\":\"computer_call\"",
        "\"type\":\"function_call\"",
        "\"functionCall\"",
        "\"function_call\""
    ]

    private static func normalizedFrame(
        _ frame: RawDebugUIInspectionFrame,
        screenshotPixelSize: HotLoopSize?
    ) -> DebugUIInspectionFrame {
        guard let screenshotPixelSize,
              screenshotPixelSize.width > 0,
              screenshotPixelSize.height > 0,
              let coordinateSpace = frame.coordinateSpace,
              coordinateSpace.width > 0,
              coordinateSpace.height > 0
        else {
            return DebugUIInspectionFrame(elements: frame.elements)
        }

        let scaleX = screenshotPixelSize.width / coordinateSpace.width
        let scaleY = screenshotPixelSize.height / coordinateSpace.height
        return DebugUIInspectionFrame(
            elements: frame.elements.map { element in
                var adjusted = element
                adjusted.bbox = DebugUIBoundingBox(
                    x: adjusted.bbox.x * scaleX,
                    y: adjusted.bbox.y * scaleY,
                    width: adjusted.bbox.width * scaleX,
                    height: adjusted.bbox.height * scaleY
                )
                return adjusted
            }
        )
    }
}

private struct RawDebugUIInspectionFrame: Decodable {
    var coordinateSpace: RawDebugUICoordinateSpace?
    var elements: [DebugUIElement]

    enum CodingKeys: String, CodingKey {
        case coordinateSpace = "coordinate_space"
        case elements
    }
}

private struct RawDebugUICoordinateSpace: Decodable {
    var width: Double
    var height: Double
}
