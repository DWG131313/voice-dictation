import AppKit
import SwiftUI
import VoiceDictationLib

/// The right column, from mockup D: the selected transcript's title (app and
/// time, the screen's one Jost title), its status word, four facts, and its
/// text, which can be selected. Empty while nothing is selected.
struct TranscriptDetail: View {
    let library: LibraryModel
    /// As `AppModel.models` lists them, to name the transcript's model.
    let models: [ModelDescriptor]

    /// The transcript text's size and line height (mockup D: 16 pt, 1.65).
    static let textSize: CGFloat = 16
    static let lineHeight: CGFloat = 1.65

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
        return VStack(alignment: .leading, spacing: 0) {
            header(t)
            facts(t)
            if shown.isReason {
                // A failed dictation has no text: why it failed, muted.
                Text(shown.text)
                    .font(Theme.Font.ui(Self.textSize))
                    .foregroundStyle(Theme.Color.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                TranscriptText(id: t.id, text: shown.text, library: library)
            }
        }
        .padding(.horizontal, Theme.Space.lg + Theme.Space.xs)
        .padding(.vertical, Theme.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                // The row says only "Yesterday" or "Nov 3"; this gives the day and time.
                .help(t.date.formatted(date: .complete, time: .shortened))
            Spacer(minLength: Theme.Space.md)
            Text(status)
                .font(Theme.Font.mono(11))
                .foregroundStyle(Theme.Color.textMuted)
                .accessibilityLabel("Status: \(status)")
        }
    }

    /// Length, Transcribed in, Model and Words: muted labels over DM Mono values.
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

/// `TranscriptTextView` in a scroll view of its own, for SwiftUI. It reports
/// its text selection to the library, so ⌘C in the list copies the selected
/// words too (Ruling T18-3).
struct TranscriptText: NSViewRepresentable {
    /// Whose text it is: showing another transcript clears the selection and
    /// scrolls to the top, even when the words are the same.
    let id: Transcript.ID
    let text: String
    let library: LibraryModel

    func makeCoordinator() -> Coordinator {
        Coordinator(library: library)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = TranscriptTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        // Apple's recipe for a text view that wraps to its scroll view's width.
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Transcript text")
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

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.library = library
        guard let textView = scrollView.documentView as? TranscriptTextView,
              context.coordinator.shown != id || textView.string != text else { return }
        context.coordinator.shown = id
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: Self.attributes))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scroll(.zero)
    }

    /// Work Sans 16 in the text colour, 1.65 lines apart.
    private static var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = TranscriptDetail.textSize * TranscriptDetail.lineHeight
        paragraph.maximumLineHeight = TranscriptDetail.textSize * TranscriptDetail.lineHeight
        return [
            .font: Theme.Font.uiFace(TranscriptDetail.textSize) as NSFont,
            .foregroundColor: NSColor(Theme.Color.text),
            .paragraphStyle: paragraph,
        ]
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var library: LibraryModel
        /// The transcript whose text the view holds.
        var shown: Transcript.ID?

        init(library: LibraryModel) {
            self.library = library
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            library.textSelection = textView.selectedRange()
        }
    }
}

/// The transcript's text: selectable, not editable (Task 19 makes it
/// editable). ⌘C copies the selected words as plain text, or the whole
/// transcript when none are selected, so Copy works with nothing selected
/// and never takes the place of a selection (Ruling T18-3).
final class TranscriptTextView: NSTextView {
    /// Where ⌘C puts the text; tests pass their own.
    var pasteboard: NSPasteboard = .general

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
