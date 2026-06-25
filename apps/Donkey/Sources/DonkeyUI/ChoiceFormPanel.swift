import DonkeyContracts
import SwiftUI

/// The inline options form (the agent's generative UI) rendered ON a waiting conversation row — a small
/// stack of fields (segmented choices, dropdowns, toggles) the user adjusts and submits. It owns the
/// in-progress selection (seeded from the form's guessed defaults, so one tap submits) and hands the
/// final choices back through `onSubmit`.
///
/// It styles FLAT — underlined text choices, plain menus, a bare switch — deliberately no boxed "cards",
/// to sit cleanly within the conversation row rather than stacking a panel inside a panel. It is
/// form-agnostic: it switches only on `field.control`, never a field id, so the same view serves video
/// options today and any future caller. Add a control kind by adding a branch in `controlView`.
struct ChoiceFormPanel: View {
    let form: HarnessChoiceForm
    let accent: Color
    let onSubmit: @MainActor ([String: String]) -> Void

    @State private var selection: [String: String]

    init(form: HarnessChoiceForm, accent: Color, onSubmit: @escaping @MainActor ([String: String]) -> Void) {
        self.form = form
        self.accent = accent
        self.onSubmit = onSubmit
        _selection = State(initialValue: form.defaultSelection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let subtitle = form.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.5))
            }

            ForEach(form.fields) { field in
                fieldView(field)
            }

            submitButton
                .padding(.top, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func fieldView(_ field: HarnessChoiceForm.Field) -> some View {
        // A toggle reads best with its label on the same line; selects get a label above the choices.
        if field.control == .toggle {
            HStack(spacing: 8) {
                fieldLabel(field)
                Spacer(minLength: 8)
                toggleControl(field)
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel(field)
                controlView(field)
            }
        }
    }

    private func fieldLabel(_ field: HarnessChoiceForm.Field) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(field.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.82))
            if let help = field.help, !help.isEmpty {
                Text(help)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
        }
    }

    @ViewBuilder
    private func controlView(_ field: HarnessChoiceForm.Field) -> some View {
        switch field.control {
        case .segmented:
            segmentedControl(field)
        case .dropdown:
            dropdownControl(field)
        case .toggle:
            toggleControl(field)
        }
    }

    // MARK: - Segmented (flat, underlined text choices — no cards)

    private func segmentedControl(_ field: HarnessChoiceForm.Field) -> some View {
        let current = selection[field.id] ?? field.defaultValue
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 16) {
                ForEach(field.options) { option in
                    let isOn = current == option.id
                    Button {
                        selection[field.id] = option.id
                    } label: {
                        Text(option.label)
                            .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                            .foregroundStyle(isOn ? accent : Color.white.opacity(0.5))
                            .padding(.bottom, 3)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(isOn ? accent : Color.clear)
                                    .frame(height: 1.5)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            // The chosen option's elaboration, shown once below the row rather than crowding each choice.
            if let detail = field.options.first(where: { $0.id == current })?.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
        }
    }

    // MARK: - Dropdown (plain menu — no box)

    private func dropdownControl(_ field: HarnessChoiceForm.Field) -> some View {
        let currentID = selection[field.id] ?? field.defaultValue
        let currentLabel = field.options.first { $0.id == currentID }?.label ?? "Choose"
        return Menu {
            ForEach(field.options) { option in
                Button(option.label) { selection[field.id] = option.id }
            }
        } label: {
            HStack(spacing: 5) {
                Text(currentLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(accent)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.8))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Toggle (bare switch)

    private func toggleControl(_ field: HarnessChoiceForm.Field) -> some View {
        let isOn = Binding<Bool>(
            get: { (selection[field.id] ?? field.defaultValue) == "true" },
            set: { selection[field.id] = $0 ? "true" : "false" }
        )
        return Toggle(isOn: isOn) { EmptyView() }
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(accent)
            .scaleEffect(0.85, anchor: .trailing)
    }

    // MARK: - Submit

    private var submitButton: some View {
        Button {
            onSubmit(selection)
        } label: {
            Text(form.submitLabel.isEmpty ? "Continue" : form.submitLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.85))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Capsule(style: .continuous).fill(accent))
        }
        .buttonStyle(.plain)
    }
}
