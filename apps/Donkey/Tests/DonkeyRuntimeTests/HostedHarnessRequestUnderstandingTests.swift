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

    @Test
    func decodesAnApplessActionSurface() async {
        // "show the fifa standings in a nice image": an artifact task the planner produces with
        // generative/web tools. The decoded `.appless` surface is what lets the caller run it without an
        // app and without demanding a frontmost window.
        let result = await understanding(forResponseJSON: #"""
        {"turnKind":"act","restatedGoal":"Generate an image of the FIFA standings.","targetAppName":"","actionSurface":"appless","needsClarification":false}
        """#)
        #expect(result?.turnKind == .act)
        #expect(result?.actionSurface == .appless)
    }

    @Test
    func decodesSuggestedFolderName() async {
        let result = await understanding(forResponseJSON: #"""
        {"turnKind":"act","restatedGoal":"Fill out f1120 pdf.","needsClarification":false,"suggestedFolderName":"Fill out f1120 Cozy"}
        """#)
        #expect(result?.suggestedFolderName == "Fill out f1120 Cozy")
    }

    @Test
    func aMissingActionSurfaceDefaultsToGuiApp() async {
        // An older model or partial output omits the field; the conservative default is the GUI path, so a
        // turn that really does drive an app is never accidentally treated as app-less.
        let result = await understanding(forResponseJSON: #"""
        {"turnKind":"act","restatedGoal":"Make every slide title bold.","targetAppName":"Keynote","needsClarification":false}
        """#)
        #expect(result?.actionSurface == .guiApp)
    }

    @Test
    func understandingSurvivesAJSONRoundTripForResumeReuse() {
        // A resume reuses the first run's understanding by decoding what it persisted, instead of
        // re-deriving it (which drifted goal/params/skills mid-task). Every field a resume depends on must
        // survive the round trip exactly.
        let original = HarnessRequestUnderstanding(
            turnKind: .act,
            restatedGoal: "Fill out the f1120.pdf form using the data from 1120data.txt.",
            targetAppName: "",
            actionSurface: .appless,
            parameters: ["pdf_path": "f1120.pdf", "data_path": "1120data.txt"],
            successCriteria: "The PDF is filled.",
            plan: ["read the data", "list the form's fields", "map and compute", "write", "verify"],
            needsClarification: false,
            executionPreference: .background,
            relevantSkillIDs: ["pdf", "data"],
            suggestedFolderName: "Fill out f1120 Cozy"
        )

        let decoded = HarnessRequestUnderstanding.decode(original.encodedJSON())

        #expect(decoded == original)
        #expect(decoded?.suggestedFolderName == "Fill out f1120 Cozy")
        // The exact failure the reuse prevents: a resume that recomputed re-typed `pdf_path` as `pdf_form`.
        #expect(decoded?.parameters["pdf_path"] == "f1120.pdf")
        #expect(decoded?.parameters["pdf_form"] == nil)
    }

    @Test
    func decodeReturnsNilForMissingOrGarbledPersistedUnderstanding() {
        // A task with no persisted understanding (older task, or it was unavailable first time) or a
        // corrupt value must fall back to recomputing, never crash.
        #expect(HarnessRequestUnderstanding.decode(nil) == nil)
        #expect(HarnessRequestUnderstanding.decode("") == nil)
        #expect(HarnessRequestUnderstanding.decode("{not json") == nil)
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
