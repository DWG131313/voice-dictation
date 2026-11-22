import SwiftUI
import VoiceDictationLib

/// The left column, from mockup D: the "Transcripts" and "Setup" groups,
/// each section with its count in DM Mono, and at the bottom one row: the
/// model picker and the Mini View switch (spec 2026-11-22). The section
/// showing is in the text colour, the others muted; nothing is filled.
struct Sidebar: View {
    let library: LibraryModel
    /// As `AppModel` last listed them.
    let models: [ModelDescriptor]
    let selectedModel: ModelID?
    /// The saved setting the menu bar's Mini View toggle also changes.
    @Binding var miniViewEnabled: Bool
    /// `AppModel.choose`: a model not on the Mac downloads, then is used.
    let choose: (ModelDescriptor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            group("Transcripts", LibraryModel.Section.transcripts, includesPlaces: true)
            group("Setup", LibraryModel.Section.setup)
            Spacer(minLength: Theme.Space.md)
            footer
        }
        .padding(.top, Theme.Space.sm)
        .padding(.bottom, Theme.Space.md)
        .padding(.horizontal, Theme.Space.sm + Theme.Space.xs)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func group(_ title: String, _ sections: [LibraryModel.Section],
                       includesPlaces: Bool = false) -> some View {
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
            if includesPlaces { placesItem }
        }
    }

    /// "Projects & apps ›": toggles the panel beside the sidebar. It is in
    /// the text colour while a place shows, with its name under it in DM
    /// Mono; choosing the place, in the panel, is what shows it.
    private var placesItem: some View {
        let isShowing = library.section == .places
        return Button {
            library.isPlacesPanelOpen.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(LibraryModel.Section.places.title)
                        .font(Theme.Font.ui(14))
                        .foregroundStyle(isShowing || library.isPlacesPanelOpen ? Theme.Color.text : Theme.Color.textMuted)
                    if isShowing, let placeTitle = library.placeTitle {
                        Text(placeTitle)
                            .font(Theme.Font.mono(11))
                            .foregroundStyle(Theme.Color.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Theme.Space.sm)
                Text("›")
                    .font(Theme.Font.mono(12))
                    .foregroundStyle(Theme.Color.textMuted)
            }
            .padding(.vertical, Theme.Space.sm)
            .padding(.horizontal, Theme.Space.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LibraryModel.Section.places.title)
        .accessibilityValue(library.placeTitle ?? "")
        .accessibilityHint(library.isPlacesPanelOpen ? "Closes the list of projects and apps" : "Opens the list of projects and apps")
        .accessibilityAddTraits(isShowing ? .isSelected : [])
    }

    private func item(_ section: LibraryModel.Section) -> some View {
        let isShowing = library.section == section
        let count = library.count(of: section, models: models)
        return Button {
            library.isPlacesPanelOpen = false
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

    /// One row under a hairline: on the left the model in use, which opens
    /// the same list as the menu bar's Model submenu (`ModelPicker`); on the
    /// right "Mini View" and Prism's switch. The name gives way first: a long
    /// one ends in "…" (spec call 6), the switch never squeezes.
    private var footer: some View {
        let title = ModelPicker.title(models, selected: selectedModel)
        return HStack(spacing: Theme.Space.sm) {
            Menu {
                if models.isEmpty {
                    Text("Loading models…")
                }
                ModelPickerItems(sections: ModelPicker.sections(models, selected: selectedModel), choose: choose)
            } label: {
                HStack(spacing: Theme.Space.xs) {
                    Text(title)
                        .font(Theme.Font.ui(12, medium: true))
                        .foregroundStyle(Theme.Color.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(Theme.Font.ui(9, medium: true))
                        .foregroundStyle(Theme.Color.textMuted)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("Model")
            .accessibilityValue(title)
            Spacer(minLength: Theme.Space.sm)
            HStack(spacing: Theme.Space.sm) {
                Text("Mini View")
                    .font(Theme.Font.ui(12))
                    .foregroundStyle(Theme.Color.textMuted)
                    .accessibilityHidden(true)
                PrismSwitch(title: "Mini View", isOn: $miniViewEnabled)
            }
            .fixedSize()
            .layoutPriority(1)
        }
        .padding(Theme.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Hairline() }
    }
}
