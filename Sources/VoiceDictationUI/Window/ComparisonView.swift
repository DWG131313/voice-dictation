import SwiftData
import SwiftUI
import VoiceDictationLib

/// Under the transcript when it has other versions (mockup D's "same audio,
/// two models"): its main text and each alternate side by side, two at a
/// time and scrolling sideways beyond that. Each column is headed by its
/// model and its seconds on the clip, the words that differ are underlined,
/// never tinted (Prism), as `BenchReport.diffWords` finds them, and each
/// alternate has "Use this one".
struct ComparisonView: View {
    let library: LibraryModel
    let transcript: Transcript
    let models: [ModelDescriptor]

    /// A column's text grows to this height (about six lines), then scrolls,
    /// so the panel leaves the transcript room in a 600-point window.
    static let textMaxHeight: CGFloat = 120

    /// One word of a column, and whether it differs.
    struct MarkedWord: Equatable {
        let word: String
        let isMarked: Bool
    }

    /// One version of the transcript's text.
    struct Column: Identifiable {
        enum Kind: Hashable {
            case main
            case alternate(PersistentIdentifier)
        }

        let kind: Kind
        /// The model's name; for a hand edit, the model whose text was edited.
        let title: String
        /// What it is, beside the name: "In use" for the main text,
        /// "Original" for the dictation's own text set aside, "Before" for
        /// another former main text, "Edited" for Danny's edit; nil for a
        /// re-transcription.
        let tag: String?
        /// The model's seconds on the clip, "0.9s"; "—" when not known.
        let seconds: String
        let words: [MarkedWord]

        var id: Kind { kind }

        /// The alternate "Use this one" makes the main text; nil for the main text.
        var alternateID: PersistentIdentifier? {
            guard case .alternate(let id) = kind else { return nil }
            return id
        }
    }

    var body: some View {
        let columns = Self.columns(transcript, mainText: library.shownText(transcript), models: models)
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Same audio, \(columns.count) versions")
                .font(Theme.Font.ui(11, medium: true))
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundStyle(Theme.Color.textMuted)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Theme.Space.md) {
                    ForEach(columns) { column in
                        ColumnView(column: column) { use(column) }
                            .containerRelativeFrame(.horizontal, count: 2, spacing: Theme.Space.md)
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
        .padding(Theme.Space.md)
        .background(Theme.Color.bgElevated)
        .overlay(Rectangle().strokeBorder(Theme.Color.hairline, lineWidth: 1))
    }

    /// "Use this one": the column's alternate as the transcript holds it now,
    /// since a promote deletes the alternate it promotes (Task 11).
    private func use(_ column: Column) {
        guard let id = column.alternateID,
              let alternate = transcript.alternates.first(where: { $0.persistentModelID == id }) else { return }
        library.promote(alternate, in: transcript)
    }

    // MARK: - What the columns say

    /// The columns for `t`: its main text (as shown, an edit being typed
    /// included), then its alternates, newest first. The main text's words
    /// are marked where any alternate differs; an alternate's, where it
    /// differs from the main text. None without alternates.
    static func columns(_ t: Transcript, mainText: String, models: [ModelDescriptor]) -> [Column] {
        let alternates = t.alternates.sorted { $0.date > $1.date }
        guard !alternates.isEmpty else { return [] }
        let main = Column(kind: .main, title: LibraryModel.modelName(t.modelKey, in: models), tag: "In use",
                          seconds: LibraryModel.tenths(t.transcribeSeconds),
                          words: marks(mainText, against: alternates.map(\.text)))
        return [main] + alternates.map { alternate in
            let isEdit = alternate.modelKey == AlternateResult.editedModelKey
            let model = isEdit ? alternate.editedFromModelKey ?? t.rawModelKey : alternate.modelKey
            return Column(kind: .alternate(alternate.persistentModelID), title: LibraryModel.modelName(model, in: models),
                          tag: tag(for: alternate, in: t), seconds: LibraryModel.tenths(alternate.seconds),
                          words: alternateMarks(alternate.text, main: mainText))
        }
    }

    /// An alternate's label: a former main text says which, so it stands
    /// apart from a re-transcription by the same model.
    private static func tag(for alternate: AlternateResult, in t: Transcript) -> String? {
        if alternate.modelKey == AlternateResult.editedModelKey { return "Edited" }
        guard alternate.wasMain else { return nil }
        let isOwn = alternate.modelKey == t.rawModelKey
            && (alternate.text == t.rawText || alternate.text == t.cleanedText)
        return isOwn ? "Original" : "Before"
    }

    /// The words of `text`, each marked where `diffWords` finds it differs
    /// from at least one of `others`. A text holding `**` of its own is left
    /// unmarked, as the markers could not be told apart from it.
    static func marks(_ text: String, against others: [String]) -> [MarkedWord] {
        let plain = unmarked(text)
        guard !text.contains("**"), !others.contains(where: { $0.contains("**") }) else { return plain }
        var isMarked = Array(repeating: false, count: plain.count)
        for other in others {
            let words = markedWords(BenchReport.diffWords(text, other).0)
            guard words.count == plain.count else { return plain }
            for (index, word) in words.enumerated() where word.isMarked { isMarked[index] = true }
        }
        return zip(plain, isMarked).map { MarkedWord(word: $0.word, isMarked: $1) }
    }

    /// An alternate's words, marked where they differ from the main text.
    private static func alternateMarks(_ alternate: String, main: String) -> [MarkedWord] {
        guard !alternate.contains("**"), !main.contains("**") else { return unmarked(alternate) }
        return markedWords(BenchReport.diffWords(main, alternate).1)
    }

    /// Reads `BenchReport.diffWords`'s output: its words, those inside a
    /// `**` run marked.
    static func markedWords(_ marked: String) -> [MarkedWord] {
        var words: [MarkedWord] = []
        var inRun = false
        for token in marked.split(separator: " ") {
            var word = Substring(token)
            let opens = word.hasPrefix("**")
            if opens { word = word.dropFirst(2) }
            let closes = word.hasSuffix("**")
            if closes { word = word.dropLast(2) }
            words.append(MarkedWord(word: String(word), isMarked: inRun || opens))
            if opens { inRun = true }
            if closes { inRun = false }
        }
        return words
    }

    private static func unmarked(_ text: String) -> [MarkedWord] {
        text.split(whereSeparator: \.isWhitespace).map { MarkedWord(word: String($0), isMarked: false) }
    }

    /// The words as one text, the marked ones underlined, with the space
    /// between two marked words, so a changed phrase reads as one line.
    static func attributed(_ words: [MarkedWord]) -> AttributedString {
        var text = AttributedString()
        for (index, word) in words.enumerated() {
            if index > 0 {
                var space = AttributedString(" ")
                if word.isMarked, words[index - 1].isMarked { underline(&space) }
                text += space
            }
            var piece = AttributedString(word.word)
            if word.isMarked { underline(&piece) }
            text += piece
        }
        return text
    }

    private static func underline(_ text: inout AttributedString) {
        text[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] = .single
    }
}

/// One column: the model, its tag and seconds, the text with its changed
/// words underlined (scrolling past `textMaxHeight`), and "Use this one"
/// under an alternate.
private struct ColumnView: View {
    let column: ComparisonView.Column
    let use: () -> Void
    /// The text's own height, so a short text takes no more room than it needs.
    @State private var textHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                Text(column.title)
                    .font(Theme.Font.ui(12, medium: true))
                    .foregroundStyle(Theme.Color.text)
                    .lineLimit(1)
                if let tag = column.tag {
                    Text(tag)
                        .font(Theme.Font.ui(12))
                        .foregroundStyle(Theme.Color.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Space.sm)
                Text(column.seconds)
                    .font(Theme.Font.mono(12))
                    .foregroundStyle(Theme.Color.textMuted)
            }
            .accessibilityElement(children: .combine)
            ScrollView(.vertical) {
                Text(ComparisonView.attributed(column.words))
                    .font(Theme.Font.ui(13))
                    .foregroundStyle(Theme.Color.text)
                    .lineSpacing(Theme.Space.xs)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
            }
            .frame(height: min(max(textHeight, 1), ComparisonView.textMaxHeight))
            if column.alternateID != nil {
                Button("Use this one", action: use)
                    .prismSecondaryButton()
                    .accessibilityLabel("Use this one: \(column.title)\(column.tag.map { ", \($0)" } ?? "")")
            }
        }
    }
}
