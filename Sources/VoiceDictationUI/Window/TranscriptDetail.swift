import AppKit
import SwiftUI
import VoiceDictationLib

/// The right column, from mockup D: the selected transcript's title (app and
/// time, the screen's one Jost title), its status word, four facts (five for
/// a cleaned one), the Raw / Cleaned switch when cleanup changed the text,
/// its text, which Danny can edit, the actions under it, and the comparison
/// when it has other versions. Empty while nothing is selected.
struct TranscriptDetail: View {
    let library: LibraryModel
    /// As `AppModel.models` lists them, to name the transcript's model and
    /// offer the others for re-transcription.
    let models: [ModelDescriptor]

    /// The transcript text's size and line height (mockup D: 16 pt, 1.65).
    static let textSize: CGFloat = 16
    static let lineHeight: CGFloat = 1.65
    /// The text keeps room for about three lines, however much the
    /// comparison below it takes.
    static let minimumTextHeight: CGFloat = 80

    var body: some View {
        if let transcript = library.selectedTranscript {
            content(transcript)
        } else {
            // Holds the column's width, so the others stay where they are.
            Spacer(minLength: 0)
        }
    }

    private func content(_ t: Transcript) -> some View {
        let shown = LibraryModel.displayText(t)
        let offersSwitch = LibraryModel.offersRawCleanedSwitch(t)
        return VStack(alignment: .leading, spacing: 0) {
            header(t)
            facts(t)
            // The text's only frame: no border around it.
            Hairline()
            if offersSwitch {
                VersionSwitch(library: library, transcript: t)
                    .padding(.top, Theme.Space.md)
            }
            Group {
                if shown.isReason {
                    // A failed dictation has no text: why it failed, muted.
                    Text(shown.text)
                        .font(Theme.Font.ui(Self.textSize))
                        .foregroundStyle(Theme.Color.textMuted)
                } else {
                    TranscriptText(transcript: t, text: library.shownText(t),
                                   isMainText: library.showsMainText(t), library: library)
                }
            }
            .padding(.top, offersSwitch ? Theme.Space.sm : Theme.Space.md)
            .frame(maxWidth: .infinity, minHeight: Self.minimumTextHeight, maxHeight: .infinity, alignment: .topLeading)
            DetailActions(library: library, transcript: t, models: models)
                .padding(.top, Theme.Space.md)
            if !t.alternates.isEmpty {
                ComparisonView(library: library, transcript: t, models: models)
                    .padding(.top, Theme.Space.lg)
            }
        }
        .padding(.horizontal, Theme.Space.lg + Theme.Space.xs)
        .padding(.vertical, Theme.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog("Delete this pinned transcript?", isPresented: deletionAsked(t), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { library.delete(t, confirmed: true) }
            Button("Cancel", role: .cancel) { library.cancelDeletion() }
        } message: {
            Text("Its recording and its other versions are deleted with it.")
        }
    }

    /// Whether Danny is being asked to confirm deleting `t`, a pinned transcript.
    private func deletionAsked(_ t: Transcript) -> Binding<Bool> {
        Binding(get: { library.deletionToConfirm == t.id },
                set: { if !$0 { library.cancelDeletion() } })
    }

    /// The title, and the status in a word on the right.
    private func header(_ t: Transcript) -> some View {
        let status = LibraryModel.statusWord(t)
        return HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
            Text(LibraryModel.title(t, now: Date()))
                .font(Theme.Font.title())
                .tracking(1)
                .foregroundStyle(Theme.Color.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
                // The title gives the day and time as a row says them; this the full date.
                .help(t.date.formatted(date: .complete, time: .shortened))
            Spacer(minLength: Theme.Space.md)
            Text(status)
                .font(Theme.Font.mono(11))
                .foregroundStyle(Theme.Color.textMuted)
                .accessibilityLabel("Status: \(status)")
        }
    }

    /// Length, Transcribed in, Model and Words, and Cleaned in for a cleaned
    /// transcript: muted labels over DM Mono values.
    private func facts(_ t: Transcript) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.lg) {
            ForEach(LibraryModel.facts(t, models: models), id: \.label) { fact in
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(fact.label)
                        .font(Theme.Font.ui(12))
                        .foregroundStyle(Theme.Color.textMuted)
                    Text(fact.value)
                        .font(Theme.Font.mono(13))
                        .foregroundStyle(Theme.Color.text)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, Theme.Space.md)
    }
}

/// The Raw / Cleaned switch above a cleaned transcript's text (Task 21): two
/// words, the side showing in the text colour and the other muted, with
/// nothing filled, as the sidebar marks the section showing. Raw shows the
/// text as dictated; Cleaned, the cleanup or what Danny made of it. The side
/// the main text is on shows it to edit; the other side, to read and copy.
private struct VersionSwitch: View {
    let library: LibraryModel
    let transcript: Transcript

    var body: some View {
        let showing = library.versionShowing(transcript)
        HStack(spacing: Theme.Space.xs) {
            side("Raw", .raw, showing: showing)
            Text("/")
                .font(Theme.Font.ui(12, medium: true))
                .foregroundStyle(Theme.Color.textMuted)
                .accessibilityHidden(true)
            side("Cleaned", .cleaned, showing: showing)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Version shown")
    }

    private func side(_ title: String, _ version: LibraryModel.TextVersion,
                      showing: LibraryModel.TextVersion) -> some View {
        let isShowing = version == showing
        return Button {
            library.show(version, of: transcript)
        } label: {
            Text(title)
                .font(Theme.Font.ui(12, medium: true))
                .foregroundStyle(isShowing ? Theme.Color.text : Theme.Color.textMuted)
                .padding(.vertical, Theme.Space.xs)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(version == .raw ? "Show the text as dictated" : "Show the cleaned-up text")
        .accessibilityAddTraits(isShowing ? .isSelected : [])
    }
}

/// The actions under the text, from mockup D with Delete added: Copy, Paste
/// again, Play audio, Re-transcribe with…, Pin and Delete, then Revert to raw
/// for an edit or a cleanup, and Use cleaned for a cleanup that came late.
/// They wrap onto another line in a narrow column. Under them, in muted
/// words: why Play and Re-transcribe are unavailable, what is being
/// re-transcribed, and what the last action has to say.
private struct DetailActions: View {
    let library: LibraryModel
    let transcript: Transcript
    let models: [ModelDescriptor]

    var body: some View {
        let t = transcript
        let hasText = !t.text.isEmpty
        let audioGone = LibraryModel.audioUnavailableReason(t)
        let choices = LibraryModel.retranscribeChoices(t, models: models)
        let running = library.retranscribing
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            FlowLayout(spacing: Theme.Space.sm) {
                Button("Copy") { library.copy(t) }
                    .prismPrimaryButton()
                    .unavailable(!hasText)
                Button("Paste again") { Task { await library.pasteAgain(t) } }
                    .prismSecondaryButton()
                    .unavailable(!hasText)
                Button(library.isPlaying(t) ? "Stop" : "Play audio") { library.togglePlay(t) }
                    .prismSecondaryButton()
                    .unavailable(audioGone != nil)
                Menu {
                    ForEach(choices) { model in
                        Button(model.displayName) { Task { await library.retranscribe(t, with: model.id) } }
                            .disabled(running.contains(model.id))
                    }
                } label: {
                    Text("Re-transcribe with…")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .prismSecondaryButton()
                .unavailable(choices.isEmpty)
                .help(choices.isEmpty ? audioGone ?? "No other model is ready" : "Transcribe the recording again")
                .accessibilityLabel("Re-transcribe with…")
                Button(t.pinned ? "Unpin" : "Pin") { library.togglePin(t) }
                    .prismSecondaryButton()
                Button("Delete") { library.delete(t) }
                    .prismSecondaryButton()
                if LibraryModel.offersRevertToRaw(t) {
                    Button("Revert to raw") { library.revertToRaw(t) }
                        .prismSecondaryButton()
                }
                if LibraryModel.offersUseCleaned(t) {
                    Button("Use cleaned") { library.useCleaned(t) }
                        .prismSecondaryButton()
                }
            }
            ForEach(notes(audioGone: audioGone, running: running), id: \.self) { note in
                Text(note)
                    .font(Theme.Font.ui(12))
                    .foregroundStyle(Theme.Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The muted lines under the actions.
    private func notes(audioGone: String?, running: Set<ModelID>) -> [String] {
        var notes: [String] = []
        if let audioGone { notes.append(audioGone) }
        if !running.isEmpty {
            let names = running.map { LibraryModel.modelName($0.storageKey, in: models) }.sorted()
            notes.append("Re-transcribing with \(ListFormatter.localizedString(byJoining: names))…")
        }
        if let message = library.message(for: transcript) { notes.append(message) }
        return notes
    }
}

private extension View {
    /// An action that cannot be used now: disabled and dimmed as a whole,
    /// outline included, with no colour.
    func unavailable(_ isUnavailable: Bool) -> some View {
        disabled(isUnavailable)
            .opacity(isUnavailable ? 0.4 : 1)
    }
}

/// Lays its views out left to right, starting a new line when the next one
/// would not fit, as mockup D's actions wrap.
private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let lines = Self.lines(of: sizes, width: proposal.width ?? .infinity, spacing: spacing)
        let height = lines.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: proposal.width ?? lines.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var index = 0
        var y = bounds.minY
        for line in Self.lines(of: sizes, width: bounds.width, spacing: spacing) {
            var x = bounds.minX
            for _ in 0..<line.count {
                let size = sizes[index]
                // Centred on the line, as the primary and secondary buttons differ a little in height.
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
                index += 1
            }
            y += line.height + spacing
        }
    }

    /// The views each line holds, and the line's width and height.
    private static func lines(of sizes: [CGSize], width: CGFloat,
                              spacing: CGFloat) -> [(count: Int, width: CGFloat, height: CGFloat)] {
        var lines: [(count: Int, width: CGFloat, height: CGFloat)] = []
        for size in sizes {
            if let last = lines.last, last.width + spacing + size.width <= width {
                lines[lines.count - 1] = (last.count + 1, last.width + spacing + size.width, max(last.height, size.height))
            } else {
                lines.append((1, size.width, size.height))
            }
        }
        return lines
    }
}

/// `TranscriptTextView` in a scroll view of its own, for SwiftUI: the
/// transcript's text, which Danny can edit. Each change goes to
/// `LibraryModel.edit`, which saves it shortly after typing stops; the edit
/// ends at once when the text view stops being edited. It reports its text
/// selection to the library, so ⌘C in the list copies the selected words too
/// (Ruling T18-3). The other side of the Raw / Cleaned switch shows here to
/// read and copy only.
struct TranscriptText: NSViewRepresentable {
    let transcript: Transcript
    /// What it shows: the edit being typed, or else the main text, or the
    /// other version the Raw / Cleaned switch is turned to.
    let text: String
    /// True for the main text, the one Danny can edit.
    let isMainText: Bool
    let library: LibraryModel

    func makeCoordinator() -> Coordinator {
        Coordinator(library: library)
    }

    /// The text view: editable, in Prism's face (Work Sans 16, lines 1.65
    /// apart), with no border, no spelling marks (the spectrum is the only
    /// colour on the screen) and ⌘Z.
    static func makeTextView() -> TranscriptTextView {
        let textView = TranscriptTextView(frame: .zero)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        // What new text is typed in, also once every character is gone.
        textView.font = Theme.Font.uiFace(TranscriptDetail.textSize) as NSFont
        textView.textColor = NSColor(Theme.Color.text)
        textView.defaultParagraphStyle = TranscriptTextView.paragraphStyle
        textView.typingAttributes = TranscriptTextView.textAttributes
        // Apple's recipe for a text view that wraps to its scroll view's width.
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Transcript text")
        return textView
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = Self.makeTextView()
        textView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }

    /// Puts the text in when another transcript, or the other side of the
    /// Raw / Cleaned switch, is shown, or when the text changed other than by
    /// typing (an empty edit restored, Use this one, Revert to raw). While
    /// Danny types, the text is already what he typed.
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.library = library
        coordinator.transcript = transcript
        guard let textView = scrollView.documentView as? TranscriptTextView else { return }
        textView.isEditable = isMainText
        let isAnotherText = coordinator.shown != transcript.id || coordinator.showsMainText != isMainText
        guard isAnotherText || textView.string != text else { return }
        coordinator.shown = transcript.id
        coordinator.showsMainText = isMainText
        textView.show(text, fromTheTop: isAnotherText)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var library: LibraryModel
        /// The transcript whose text the view holds.
        var transcript: Transcript?
        var shown: Transcript.ID?
        /// Whether the view holds the main text, or the other version.
        var showsMainText = true

        init(library: LibraryModel) {
            self.library = library
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            library.textSelection = textView.selectedRange()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, let transcript else { return }
            library.edit(transcript, text: textView.string)
        }

        func textDidEndEditing(_ notification: Notification) {
            library.commitEdit()
        }
    }
}

/// The transcript's text, editable. ⌘C copies the selected words as plain
/// text, or the whole transcript when none are selected, so Copy works with
/// nothing selected and never takes the place of a selection (Ruling T18-3).
final class TranscriptTextView: NSTextView {
    /// Where ⌘C puts the text; tests pass their own.
    var pasteboard: NSPasteboard = .general

    /// Work Sans 16 lines, 1.65 apart.
    static var paragraphStyle: NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = TranscriptDetail.textSize * TranscriptDetail.lineHeight
        paragraph.maximumLineHeight = TranscriptDetail.textSize * TranscriptDetail.lineHeight
        return paragraph
    }

    /// Work Sans 16 in the text colour, 1.65 lines apart.
    static var textAttributes: [NSAttributedString.Key: Any] {
        [
            .font: Theme.Font.uiFace(TranscriptDetail.textSize) as NSFont,
            .foregroundColor: NSColor(Theme.Color.text),
            .paragraphStyle: paragraphStyle,
        ]
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        usePrismSelection()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        usePrismSelection()
    }

    /// Prism has no accent colour: selected words read black on the text
    /// white, not on the system's blue.
    private func usePrismSelection() {
        selectedTextAttributes = [
            .backgroundColor: NSColor(Theme.Color.text),
            .foregroundColor: NSColor(Theme.Color.bg),
        ]
        insertionPointColor = NSColor(Theme.Color.text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Shows `text` in place of what is there: from the top for another
    /// transcript, otherwise with the caret at the end. ⌘Z undoes typing in
    /// the text it was typed in only, so its undo starts afresh.
    func show(_ text: String, fromTheTop: Bool) {
        breakUndoCoalescing()
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: Self.textAttributes))
        undoManager?.removeAllActions()
        setSelectedRange(NSRange(location: fromTheTop ? 0 : (text as NSString).length, length: 0))
        if fromTheTop { scroll(.zero) }
    }

    /// What ⌘C copies now; nil when there is no text.
    private var textToCopy: String? {
        LibraryModel.textToCopy(string, selectedRange: selectedRange())
    }

    override func copy(_ sender: Any?) {
        guard let text = textToCopy else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(NSText.copy(_:)) { return textToCopy != nil }
        return super.validateMenuItem(menuItem)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.copy(_:)) { return textToCopy != nil }
        return super.validateUserInterfaceItem(item)
    }
}
