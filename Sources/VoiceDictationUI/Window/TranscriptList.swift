import AppKit
import SwiftUI
import VoiceDictationLib

/// The middle column, from mockup D: the search field, a notice when the
/// history was moved aside (Ruling T18-1), and the transcripts, newest
/// first. With the list focused, ↑ and ↓ move the selection and ⌘C copies
/// the selected transcript, or the words selected in it (Ruling T18-3).
struct TranscriptList: View {
    let library: LibraryModel
    let focus: FocusState<MainWindow.Focus?>.Binding

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if let notice = library.notice {
                Text(notice)
                    .font(Theme.Font.ui(12))
                    .foregroundStyle(Theme.Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.md)
                    .background(Theme.Color.bgElevated)
                    .overlay(alignment: .top) { Hairline() }
                    .overlay(alignment: .bottom) { Hairline() }
            }
            rows
        }
    }

    /// Prism's field: square corners, the raised black, a hairline border.
    private var searchField: some View {
        @Bindable var library = library
        return TextField("Search transcripts", text: $library.query,
                         prompt: Text("Search transcripts").foregroundStyle(Theme.Color.textMuted))
            .textFieldStyle(.plain)
            .font(Theme.Font.ui(13))
            .foregroundStyle(Theme.Color.text)
            .focused(focus, equals: .search)
            .accessibilityLabel("Search transcripts")
            .padding(.horizontal, Theme.Space.sm + Theme.Space.xs)
            .padding(.vertical, Theme.Space.sm)
            .background(Theme.Color.bgElevated)
            .overlay(Rectangle().strokeBorder(Theme.Color.hairline, lineWidth: 1))
            .padding(Theme.Space.md)
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let message = library.emptyMessage {
                        Text(message)
                            .font(Theme.Font.ui(14))
                            .foregroundStyle(Theme.Color.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Space.md)
                    } else {
                        let now = Date()
                        ForEach(library.rows) { transcript in
                            TranscriptRow(transcript: transcript, isSelected: transcript.id == library.selection,
                                          now: now) {
                                library.selection = transcript.id
                                focus.wrappedValue = .list
                            }
                            .id(transcript.id)
                        }
                    }
                }
            }
            // Clicking the list focuses it; its selection, not a ring, shows where you are.
            .focusable(interactions: .edit)
            .focused(focus, equals: .list)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) {
                library.moveSelection(by: -1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                library.moveSelection(by: 1)
                return .handled
            }
            // Nil (Copy disabled) when the selected transcript has no text.
            .onCopyCommand(perform: library.copyCommandText == nil ? nil : {
                guard let text = library.copyCommandText else { return [] }
                return [NSItemProvider(object: text as NSString)]
            })
            .onChange(of: library.selection) { _, selection in
                if let selection { proxy.scrollTo(selection) }
            }
            .accessibilityLabel("Transcripts")
        }
    }
}

/// One transcript in the list: the app and `time · length` on one muted
/// DM Mono line, then two lines of its text. A hairline below it; the
/// selected row has the spectrum underline instead, and no fill.
struct TranscriptRow: View {
    let transcript: Transcript
    let isSelected: Bool
    let now: Date
    let select: () -> Void

    var body: some View {
        let meta = LibraryModel.rowMeta(transcript, now: now)
        let shown = LibraryModel.displayText(transcript)
        Button(action: select) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                    Text(meta.app)
                        .lineLimit(1)
                    Spacer(minLength: Theme.Space.sm)
                    Text(meta.when)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .font(Theme.Font.mono(12))
                .foregroundStyle(Theme.Color.textMuted)
                Text(shown.text)
                    .font(Theme.Font.ui(14))
                    .foregroundStyle(shown.isReason ? Theme.Color.textMuted : Theme.Color.text)
                    .lineLimit(2)
                    .lineSpacing(Theme.Space.xs)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Theme.Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if isSelected {
                SpectrumUnderline()
            } else {
                Hairline()
            }
        }
        .accessibilityLabel("\(meta.app), \(meta.when.replacingOccurrences(of: " · ", with: ", ")). \(shown.text)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
