import Foundation

/// A generative UI form the agent surfaces to the user mid-turn: a titled set of fields, each a typed
/// control (a segmented button group, a dropdown, or a toggle), every one carrying a default the planner
/// guesses from the request. It is app-agnostic — video generation is the first caller (speed/quality,
/// audio), but any tool can request one to let the user pick before the agent commits.
///
/// The shape is deliberately FLAT so a model can emit it as plain JSON and so the renderer can switch on
/// one string. Extend the vocabulary by adding a `ControlKind` case plus its renderer (notch panel) and
/// its value reading here — the rest of the pipeline (request → wait → render → submit → resume) is
/// untouched. Nothing in the harness core branches on a specific field id, so the same primitive serves
/// any future use case.
public struct HarnessChoiceForm: Codable, Equatable, Sendable {
    /// The kinds of control a field can render. Add a case to grow the vocabulary (e.g. `slider`,
    /// `text`); the decoder, the notch renderer, and `defaultValue(for:)` are the only switches to update.
    public enum ControlKind: String, Codable, Equatable, Sendable {
        case segmented   // a single-select row of buttons — best for 2–4 mutually exclusive choices
        case dropdown    // a single-select menu — best for many choices or to save space
        case toggle      // an on/off switch
    }

    public struct Option: Codable, Equatable, Sendable, Identifiable {
        /// The value returned in the selection when this option is chosen.
        public var id: String
        public var label: String
        /// Optional one-line elaboration shown under the label (e.g. "Quicker, lower cost").
        public var detail: String?

        public init(id: String, label: String, detail: String? = nil) {
            self.id = id
            self.label = label
            self.detail = detail
        }
    }

    public struct Field: Codable, Equatable, Sendable, Identifiable {
        /// Stable key this field's chosen value is returned under in the selection.
        public var id: String
        public var label: String
        /// Optional secondary line under the label.
        public var help: String?
        public var control: ControlKind
        /// Options for `segmented`/`dropdown`; ignored for `toggle`.
        public var options: [Option]
        /// Default selected option id for `segmented`/`dropdown`. Falls back to the first option.
        public var selected: String?
        /// Default state for `toggle`.
        public var on: Bool?

        public init(
            id: String,
            label: String,
            help: String? = nil,
            control: ControlKind,
            options: [Option] = [],
            selected: String? = nil,
            on: Bool? = nil
        ) {
            self.id = id
            self.label = label
            self.help = help
            self.control = control
            self.options = options
            self.selected = selected
            self.on = on
        }

        /// The value this field starts on — the planner's guessed default. Segmented/dropdown resolve to
        /// the declared `selected` if it names a real option, else the first option's id; a toggle to
        /// "true"/"false". Returns nil only for an option-less select (a malformed field).
        public var defaultValue: String? {
            switch control {
            case .segmented, .dropdown:
                if let selected, options.contains(where: { $0.id == selected }) {
                    return selected
                }
                return options.first?.id
            case .toggle:
                return (on ?? false) ? "true" : "false"
            }
        }
    }

    public var title: String
    public var subtitle: String?
    public var submitLabel: String
    public var fields: [Field]

    public init(
        title: String,
        subtitle: String? = nil,
        submitLabel: String = "Continue",
        fields: [Field]
    ) {
        self.title = title
        self.subtitle = subtitle
        self.submitLabel = submitLabel
        self.fields = fields
    }
}

public extension HarnessChoiceForm {
    /// Decodes a form from the JSON a tool (or the planner) produced. Returns nil for malformed JSON or a
    /// form with no fields — the caller then falls back to plain conversation rather than an empty panel.
    static func decode(fromJSON json: String) -> HarnessChoiceForm? {
        guard let data = json.data(using: .utf8),
              let form = try? JSONDecoder().decode(HarnessChoiceForm.self, from: data),
              !form.fields.isEmpty
        else {
            return nil
        }
        return form
    }

    func encodedJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The selection the form starts on — every field at its guessed default. The user submits this as-is
    /// (one tap) or after adjusting controls.
    var defaultSelection: [String: String] {
        var selection: [String: String] = [:]
        for field in fields {
            if let value = field.defaultValue {
                selection[field.id] = value
            }
        }
        return selection
    }

    /// Encodes the user's choices into the single response line the waiting planner reads back (as the
    /// user's clarification answer). Stable `id=value` pairs, ordered by the form's fields, so the planner
    /// maps them onto its next tool call deterministically — never by parsing free text.
    func encodeSelectionResponse(_ selection: [String: String]) -> String {
        let pairs = fields.compactMap { field -> String? in
            guard let value = selection[field.id] ?? field.defaultValue else { return nil }
            return "\(field.id)=\(value)"
        }
        return "Selected options: " + pairs.joined(separator: ", ")
    }
}
