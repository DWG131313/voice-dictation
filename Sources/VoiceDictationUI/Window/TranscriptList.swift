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
            lengthRow
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
        .confirmationDialog(library.headingDeletionToConfirm?.title ?? "", isPresented: deletionAsked,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { library.confirmHeadingDeletion() }
            Button("Cancel", role: .cancel) { library.cancelHeadingDeletion() }
        } message: {
            Text(library.headingDeletionToConfirm?.message ?? "")
        }
    }

    /// Whether Danny is being asked to confirm deleting a heading's transcripts.
    private var deletionAsked: Binding<Bool> {
        Binding(get: { library.headingDeletionToConfirm != nil },
                set: { if !$0 { library.cancelHeadingDeletion() } })
    }

    /// "LENGTH  Any  <10s  10s–1m  >1m": DM Mono 12, the chosen one in the
    /// text colour with a 1 pt underline, and a hairline below.
    private var lengthRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
            Text("Length")
                .font(Theme.Font.ui(11, medium: true))
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundStyle(Theme.Color.textMuted)
                .accessibilityHidden(true)
            ForEach(LengthFilter.allCases, id: \.self) { option in
                let isChosen = library.length == option
                Button {
                    library.length = option
                } label: {
                    Text(Self.lengthWords(option))
                        .font(Theme.Font.mono(12))
                        .foregroundStyle(isChosen ? Theme.Color.text : Theme.Color.textMuted)
                        .overlay(alignment: .bottom) {
                            if isChosen { Rectangle().fill(Theme.Color.text).frame(height: 1) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Length, \(Self.lengthWords(option))")
                .accessibilityAddTraits(isChosen ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.top, Theme.Space.xs)
        .padding(.bottom, Theme.Space.sm + Theme.Space.xs)
        .overlay(alignment: .bottom) { Hairline() }
    }

    static func lengthWords(_ option: LengthFilter) -> String {
        switch option {
        case .any: "Any"
        case .short: "<10s"
        case .medium: "10s–1m"
        case .long: ">1m"
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
            // The caret and selection follow the tint, not the system accent
            // (Prism: the spectrum is the only colour).
            .tint(Theme.Color.text)
            .focused(focus, equals: .search)
            .accessibilityLabel("Search transcripts")
            .padding(.horizontal, Theme.Space.sm + Theme.Space.xs)
            .padding(.vertical, Theme.Space.sm)
            .background(Theme.Color.bgElevated)
            .overlay(Rectangle().strokeBorder(Theme.Color.hairline, lineWidth: 1))
            .padding(Theme.Space.md)
    }

    @ViewBuilder
    private func rowViews(_ transcripts: [Transcript], now: Date, indent: CGFloat) -> some View {
        ForEach(transcripts) { transcript in
            TranscriptRow(transcript: transcript, isSelected: transcript.id == library.selection,
                          now: now, indent: indent) {
                library.selection = transcript.id
                focus.wrappedValue = .list
            }
            .id(transcript.id)
        }
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
                        let showsGroups = library.showsGroupHeadings
                        ForEach(library.days) { day in
                            DayHeading(library: library, day: day, now: now)
                            if !library.isFolded(day.id) {
                                if showsGroups {
                                    ForEach(day.groups) { group in
                                        GroupHeading(library: library, group: group, day: day)
                                        if !library.isFolded(group.id) {
                                            rowViews(group.transcripts, now: now, indent: TranscriptRow.indent)
                                        }
                                    }
                                } else {
                                    rowViews(day.transcripts, now: now, indent: Theme.Space.md)
                                }
                            }
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
            // The window opens on its selection, wherever it is in the list.
            .onAppear {
                if let selection = library.selection { proxy.scrollTo(selection) }
            }
            .accessibilityLabel("Transcripts")
        }
    }
}

/// One transcript in the list: the time on the left and the length on the
/// right of one muted DM Mono line (the heading above says the day and the
/// place), then two lines of its text, indented under its group heading. A
/// hairline below it; the selected row has the spectrum underline instead,
/// and no fill.
struct TranscriptRow: View {
    let transcript: Transcript
    let isSelected: Bool
    let now: Date
    /// The left padding: 34 pt under a group heading.
    var indent: CGFloat = TranscriptRow.indent
    let select: () -> Void

    static let indent: CGFloat = 34

    var body: some View {
        let meta = LibraryModel.rowMeta(transcript, now: now)
        let times = LibraryModel.rowTimes(transcript)
        let shown = LibraryModel.displayText(transcript)
        Button(action: select) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                    Text(times.time)
                        .lineLimit(1)
                    Spacer(minLength: Theme.Space.sm)
                    if let length = times.length {
                        Text(length)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
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
            .padding(.leading, indent)
            .padding(.trailing, Theme.Space.md)
            .padding(.vertical, Theme.Space.md)
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
