import DonkeyHarness
import Foundation

/// Maps Donkey Command Layer tool descriptors to Gemini Live function
/// declarations so the always-on session can call them directly.
public enum CommandLayerFunctionDeclarations {
    /// Function declarations for every Command Layer tool.
    public static func declarations() -> [[String: Any]] {
        declarations(from: DonkeyCommandLayer.descriptors)
    }

    public static func declarations(from descriptors: [HarnessToolDescriptor]) -> [[String: Any]] {
        descriptors.map(declaration(from:))
    }

    static func declaration(from descriptor: HarnessToolDescriptor) -> [String: Any] {
        var properties: [String: Any] = [:]
        var required: [String] = []
        let optional = Set(descriptor.optionalInputKeys)
        for (name, description) in descriptor.inputSchema {
            properties[name] = ["type": "string", "description": description]
            // Requiredness comes from the structured descriptor, not prose.
            if !optional.contains(name) {
                required.append(name)
            }
        }
        var parameters: [String: Any] = [
            "type": "object",
            "properties": properties
        ]
        if !required.isEmpty {
            parameters["required"] = required.sorted()
        }
        return [
            "name": descriptor.name,
            "description": descriptor.summary,
            "parameters": parameters
        ]
    }
}
