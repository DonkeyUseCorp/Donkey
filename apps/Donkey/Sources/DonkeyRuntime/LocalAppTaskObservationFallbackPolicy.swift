import DonkeyContracts
import Foundation

public enum LocalAppTaskObservationFallbackPolicy {
    public static func shouldUseScreenshotUnderstanding(
        definition: LocalAppTaskDefinition,
        accessibilityObservation: LocalAppTaskObservation,
        verificationKey: String
    ) -> Bool {
        guard definition.observationStrategies.contains(.screenshotForLocalModel) else {
            return false
        }

        switch screenshotFallbackMode(for: definition) {
        case .never:
            return false
        case .always:
            return true
        case .missingVerificationText:
            return accessibilityObservation.visibleText[verificationKey]?.isEmpty != false
        case .missingControls:
            return missingRequiredControls(
                definition: definition,
                accessibilityObservation: accessibilityObservation
            )
        case .missingVerificationOrControls:
            break
        }

        if accessibilityObservation.visibleText[verificationKey]?.isEmpty == false {
            return false
        }

        return missingRequiredControls(
            definition: definition,
            accessibilityObservation: accessibilityObservation
        ) || accessibilityObservation.visibleText.isEmpty
    }

    static func screenshotFallbackMode(
        for definition: LocalAppTaskDefinition
    ) -> LocalAppTaskScreenshotFallbackMode {
        switch definition.metadata["screenshotFallback"] {
        case "never":
            return .never
        case "always":
            return .always
        case "missingVerificationText":
            return .missingVerificationText
        case "missingControls":
            return .missingControls
        default:
            return .missingVerificationOrControls
        }
    }

    private static func missingRequiredControls(
        definition: LocalAppTaskDefinition,
        accessibilityObservation: LocalAppTaskObservation
    ) -> Bool {
        definition.workflowSteps.contains { step in
            guard step.role == .focusControl,
                  let controlID = step.metadata["controlID"]
            else {
                return false
            }

            return accessibilityObservation.availableControls[controlID] != true
        }
    }
}

enum LocalAppTaskScreenshotFallbackMode: String, Equatable, Sendable {
    case never
    case always
    case missingVerificationText
    case missingControls
    case missingVerificationOrControls
}
