import DonkeyAI
import DonkeyContracts
import Foundation
import Testing

/// The two-tier split lives or dies on this one decoded field: `turnKind` is what routes a turn to the
/// no-tools responder versus the action loop. These tests pin the wire decode so a greeting classified
/// `converse` never silently falls through to the action path (the "hi → curl wttr.in" failure).
@Suite
@MainActor
struct HostedHarnessRequestUnderstandingTests {
    private func understanding(forResponseJSON json: String) async -> HarnessRequestUnderstanding? {
        // The backend wraps the model's text under `output_text`; the boundary pulls the JSON object out
        // of it and decodes the typed understanding.
        let envelope = try! JSONSerialization.data(withJSONObject: ["output_text": json])
        let backend = DonkeyBackendInferenceClient(
            configuration: DonkeyBackendInferenceConfiguration(
                baseURL: URL(string: "https://donkey.example")!,
                clientID: "client-1"
            ),
            httpClient: SingleResponseHTTPClient(data: envelope, statusCode: 200)
        )
        return await HostedHarnessRequestUnderstanding(backend: backend)
            .understand(command: "hi", frontmostAppName: "Finder")
    }

    @Test
    func classifiesAGreetingAsConverse() async {
        let result = await understanding(forResponseJSON: #"""
        {"turnKind":"converse","restatedGoal":"The user said hi.","needsClarification":false}
        """#)
        #expect(result?.turnKind == .converse)
        #expect(result?.needsClarification == false)
    }

    @Test
    func classifiesADoableRequestAsAct() async {
        let result = await understanding(forResponseJSON: #"""
        {"turnKind":"act","restatedGoal":"Lower the system volume.","targetAppName":"","needsClarification":false}
        """#)
        #expect(result?.turnKind == .act)
    }

    @Test
    func anUnknownOrMissingTurnKindDegradesToAct() async {
        // A reply missing the field (older model, partial output) must NOT accidentally route to the
        // responder — the conservative default is the action path, matching the nil-understanding degrade.
        let result = await understanding(forResponseJSON: #"""
        {"restatedGoal":"Open Safari.","needsClarification":false}
        """#)
        #expect(result?.turnKind == .act)
    }
}

private final class SingleResponseHTTPClient: AIHTTPClient, @unchecked Sendable {
    let data: Data
    let statusCode: Int

    init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: [:])!)
    }
}
