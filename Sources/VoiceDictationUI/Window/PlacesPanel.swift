import SwiftUI
import VoiceDictationLib

/// The Projects & apps panel (DESIGN.md `places-panel`): 240 pt wide, laid
/// over the list against the sidebar's right edge, on `bg-elevated` with
/// hairline sides. Every place that has transcripts, with its count; the
/// folders of an app nested under it. Choosing a line shows that place.
struct PlacesPanel: View {
    static let width: CGFloat = 240

    let library: LibraryModel

    var body: some View {
        let entries = library.placeEntries
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Projects & apps")
                    .font(Theme.Font.ui(11, medium: true))
                    .tracking(0.9)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Color.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Theme.Space.sm)
                Text("esc")
                    .font(Theme.Font.mono(12))
                    .foregroundStyle(Theme.Color.textMuted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.top, Theme.Space.md)
            .padding(.bottom, Theme.Space.sm)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        let opensFolders = !entry.isNested && index + 1 < entries.count && entries[index + 1].isNested
                        line(entry, opensFolders: opensFolders)
                    }
                }
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Color.bgElevated.ignoresSafeArea(edges: .top))
        .overlay(alignment: .leading) { Hairline(.vertical).ignoresSafeArea(edges: .top) }
        .overlay(alignment: .trailing) { Hairline(.vertical).ignoresSafeArea(edges: .top) }
    }

    private func line(_ entry: LibraryModel.PlaceEntry, opensFolders: Bool) -> some View {
        Button {
            library.show(entry.filter)
        } label: {
            HStack(spacing: Theme.Space.sm) {
                Text(opensFolders ? "▾ \(entry.title)" : entry.title)
                    .font(Theme.Font.ui(14))
                    .foregroundStyle(entry.isNested ? Theme.Color.textMuted : Theme.Color.text)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.sm)
                Text("\(entry.count)")
                    .font(Theme.Font.mono(12))
                    .foregroundStyle(Theme.Color.textMuted)
            }
            .padding(.vertical, Theme.Space.sm)
            .padding(.leading, Theme.Space.md + (entry.isNested ? Theme.Space.md : 0))
            .padding(.trailing, Theme.Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.title)
        .accessibilityValue("\(entry.count)")
    }
}
