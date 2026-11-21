import SwiftUI
import VoiceDictationLib

/// A day's heading in the list: its title in upper case, its count in DM
/// Mono, and Delete at the right. On `bg-elevated` with a hairline below
/// (DESIGN.md `day-heading`). Tapping it folds the day.
struct DayHeading: View {
    let library: LibraryModel
    let day: DayGroup
    let now: Date

    var body: some View {
        let title = TranscriptGroups.dayTitle(day.day, now: now)
        let isFolded = library.isFolded(day.id)
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Button {
                library.toggleFold(day.id)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                    Text(title)
                        .font(Theme.Font.ui(11, medium: true))
                        .tracking(0.9)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.Color.text)
                    Text("\(day.transcripts.count)")
                        .font(Theme.Font.mono(12))
                        .foregroundStyle(Theme.Color.textMuted)
                    Spacer(minLength: Theme.Space.sm)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(day.transcripts.count)")
            .accessibilityValue(isFolded ? "Folded" : "Open")
            .accessibilityHint("Folds or opens the day")
            .accessibilityAddTraits(.isHeader)
            DeleteHeadingButton(label: "Delete \(title)", hasDeletable: !library.deletable(day.transcripts).isEmpty) {
                library.askToDelete(day: day)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.md)
        .padding(.bottom, Theme.Space.sm)
        .background(Theme.Color.bgElevated)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

/// A group's heading under a day: a fold chevron, the folder or app, the
/// app and count in DM Mono ("Terminal · 4", or just "24"), and Delete at
/// the right (DESIGN.md `group-heading`). Tapping it folds the group.
struct GroupHeading: View {
    let library: LibraryModel
    let group: PlaceGroup
    /// The day it sits under, which the Delete's words name.
    let day: DayGroup

    var body: some View {
        let title = TranscriptGroups.title(of: group.place)
        let count = group.transcripts.count
        let detail = title.app.map { "\($0) · \(count)" } ?? "\(count)"
        let isFolded = library.isFolded(group.id)
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Button {
                library.toggleFold(group.id)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                    Text(isFolded ? "▸" : "▾")
                        .font(Theme.Font.mono(10))
                        .foregroundStyle(Theme.Color.textMuted)
                        .frame(width: 10)
                    Text(title.name)
                        .font(Theme.Font.ui(13, medium: true))
                        .foregroundStyle(Theme.Color.text)
                        .lineLimit(1)
                    Text(detail)
                        .font(Theme.Font.mono(12))
                        .foregroundStyle(Theme.Color.textMuted)
                        .lineLimit(1)
                    Spacer(minLength: Theme.Space.sm)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title.name), \(detail.replacingOccurrences(of: " · ", with: ", "))")
            .accessibilityValue(isFolded ? "Folded" : "Open")
            .accessibilityHint("Folds or opens the group")
            .accessibilityAddTraits(.isHeader)
            DeleteHeadingButton(label: "Delete \(title.name)",
                                hasDeletable: !library.deletable(group.transcripts).isEmpty) {
                library.askToDelete(group: group, on: day)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.sm)
        .padding(.bottom, Theme.Space.sm)
    }

}

/// Delete at a heading's right: Work Sans 12, muted, in the text colour
/// under the pointer. Absent when nothing under the heading can go. It is
/// its own button, so it does not fold the heading.
struct DeleteHeadingButton: View {
    let label: String
    let hasDeletable: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        if hasDeletable {
            Button(action: action) {
                Text("Delete")
                    .font(Theme.Font.ui(12))
                    .foregroundStyle(isHovering ? Theme.Color.text : Theme.Color.textMuted)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .accessibilityLabel(label)
        }
    }
}
