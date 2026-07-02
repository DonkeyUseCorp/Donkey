import DonkeyContracts
import Testing

/// Locks the `user.choose` form contract: a form is undecodable — and the tool dead-ends on
/// `invalidInput` — if a `toggle` field (which carries no `options`) forces the whole form to fail.
@Suite
struct HarnessChoiceFormDecodeTests {
    /// The exact shape the video skill emits: a segmented `tier`, an option-less `audio` toggle, and
    /// more segmented fields. A toggle omitting `options` must still decode.
    private let videoForm = """
    {"title":"Video Generation Options","submitLabel":"Generate","fields":[\
    {"id":"tier","label":"Speed & Quality","control":"segmented","options":[\
    {"id":"fast","label":"Fast","detail":"Quicker, lower cost"},\
    {"id":"standard","label":"Standard","detail":"Balanced"},\
    {"id":"high","label":"High","detail":"Best quality, slower"}],"selected":"standard"},\
    {"id":"audio","label":"Audio","control":"toggle","on":true},\
    {"id":"length","label":"Length (seconds)","control":"segmented","options":[\
    {"id":"4","label":"4s"},{"id":"6","label":"6s"},{"id":"8","label":"8s"}],"selected":"8"},\
    {"id":"aspect","label":"Aspect Ratio","control":"segmented","options":[\
    {"id":"16:9","label":"16:9 (Landscape)"},{"id":"9:16","label":"9:16 (Portrait)"}],"selected":"16:9"}]}
    """

    @Test
    func decodesFormContainingAnOptionlessToggle() throws {
        let form = try #require(HarnessChoiceForm.decode(fromJSON: videoForm))
        #expect(form.fields.count == 4)

        let toggle = try #require(form.fields.first { $0.control == .toggle })
        #expect(toggle.id == "audio")
        #expect(toggle.options.isEmpty)
        #expect(toggle.defaultValue == "true")
    }

    @Test
    func guessedDefaultsRoundTripToTheSelectionResponse() throws {
        let form = try #require(HarnessChoiceForm.decode(fromJSON: videoForm))
        let response = form.encodeSelectionResponse(form.defaultSelection)
        #expect(response == "Selected options: tier=standard, audio=true, length=8, aspect=16:9")
    }

    /// A bare toggle with only `id`/`label`/`control` must decode — the minimum a toggle can be.
    @Test
    func decodesAMinimalToggleForm() throws {
        let json = #"{"title":"T","fields":[{"id":"go","label":"Go","control":"toggle"}]}"#
        let form = try #require(HarnessChoiceForm.decode(fromJSON: json))
        #expect(form.fields.count == 1)
        #expect(form.fields[0].options.isEmpty)
        #expect(form.fields[0].defaultValue == "false")
    }

    /// The one hard requirement is a non-empty `fields` array; `title`/`submitLabel` are optional and
    /// default when the planner omits them.
    @Test
    func decodesWithOnlyFields() throws {
        let json = #"{"fields":[{"id":"go","label":"Go","control":"toggle"}]}"#
        let form = try #require(HarnessChoiceForm.decode(fromJSON: json))
        #expect(form.title.isEmpty)
        #expect(form.submitLabel == "Continue")
        #expect(form.fields.count == 1)
    }

    @Test
    func rejectsAFormWithNoFields() {
        #expect(HarnessChoiceForm.decode(fromJSON: #"{"title":"T","fields":[]}"#) == nil)
        #expect(HarnessChoiceForm.decode(fromJSON: #"{"title":"T"}"#) == nil)
    }
}
