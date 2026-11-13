import SwiftUI
import VoiceDictationLib

/// The left column, from mockup D: the "Transcripts" and "Setup" groups,
/// each section with its count in DM Mono, and at the bottom the model
/// dictation uses and how to dictate. The section showing is in the text
/// colour, the others muted; nothing is filled.
struct Sidebar: View {
    let library: LibraryModel
    /// As `AppModel` last listed them.
    let models: [ModelDescriptor]
    let selectedModel: ModelID?
    /// The key that dictates, and whether a double tap locks it, as saved.
    let hotkey: HotkeyChoice
    let doubleTap: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            group("Transcripts", LibraryModel.Section.transcripts)
            group("Setup", LibraryModel.Section.setup)
            Spacer(minLength: Theme.Space.md)
            footer
        }
        .padding(.top, Theme.Space.sm)
        .padding(.bottom, Theme.Space.md)
        .padding(.horizontal, Theme.Space.sm + Theme.Space.xs)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func group(_ title: String, _ sections: [LibraryModel.Section]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Theme.Font.ui(11, medium: true))
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundStyle(Theme.Color.textMuted)
                .padding(.top, Theme.Space.md)
                .padding(.bottom, Theme.Space.sm)
                .padding(.horizontal, Theme.Space.sm)
                .accessibilityAddTraits(.isHeader)
            ForEach(sections) { section in
                item(section)
            }
        }
    }

    private func item(_ section: LibraryModel.Section) -> some View {
        let isShowing = library.section == section
        let count = library.count(of: section, models: models)
        return Button {
            library.section = section
        } label: {
            HStack(spacing: Theme.Space.sm) {
                Text(section.title)
                    .font(Theme.Font.ui(14))
                    .foregroundStyle(isShowing ? Theme.Color.text : Theme.Color.textMuted)
                Spacer(minLength: Theme.Space.sm)
                if let count {
                    Text("\(count)")
                        .font(Theme.Font.mono(12))
                        .foregroundStyle(Theme.Color.textMuted)
                }
            }
            .padding(.vertical, Theme.Space.sm)
            .padding(.horizontal, Theme.Space.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityValue(count.map(String.init) ?? "")
        .accessibilityAddTraits(isShowing ? .isSelected : [])
    }

    /// The model dictation uses (once the models are listed) and how to
    /// dictate with the chosen key.
    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if let selectedModel {
                Text(LibraryModel.modelName(selectedModel.storageKey, in: models))
                    .font(Theme.Font.ui(12, medium: true))
                    .foregroundStyle(Theme.Color.text)
            }
            Text(Self.hotkeyReminder(for: hotkey, doubleTap: doubleTap))
                .font(Theme.Font.ui(12))
                .foregroundStyle(Theme.Color.textMuted)
        }
        .padding(Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Hairline() }
        .accessibilityElement(children: .combine)
    }

    /// "Hold Right Option to dictate", or with double-tap dictation on
    /// (`doubleTap`) "Hold or double-tap Right Option to dictate": a double
    /// tap locks a recording, and another stops it. Danny's wording: the
    /// window names the feature by the double tap only.
    static func hotkeyReminder(for hotkey: HotkeyChoice, doubleTap: Bool) -> String {
        "Hold \(doubleTap ? "or double-tap " : "")\(hotkey.displayName) to dictate"
    }
}
