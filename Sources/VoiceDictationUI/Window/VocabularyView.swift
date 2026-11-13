import SwiftUI
import VoiceDictationLib

/// The Vocabulary section: Danny's words and his replacement rules, two
/// plain lists with add, remove and inline editing. Every change is saved
/// at once. Apple Speech ignores the words, so for it a replacement rule is
/// what gets a name right; the explanation says so.
struct VocabularyView: View {
    let store: VocabularyStore

    @State private var newWord = ""
    @State private var newFrom = ""
    @State private var newTo = ""

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Vocabulary")
                    .font(Theme.Font.title())
                    .foregroundStyle(Theme.Color.text)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, Theme.Space.md)

                heading("Words")
                note("Words the app should recognise. Apple Dictation and the Whisper models use them as a hint; "
                     + "Apple Speech ignores them, so for it add a replacement below.")
                ForEach($store.wordRows) { $row in
                    editableRow {
                        field("Word", text: $row.text)
                    } remove: {
                        store.removeWord(id: row.id)
                        store.save()
                    }
                }
                addRow(button: "Add word", canAdd: !newWord.trimmingCharacters(in: .whitespaces).isEmpty) {
                    field("New word", text: $newWord, onSubmit: addWord)
                } add: {
                    addWord()
                }

                heading("Replacements")
                    .padding(.top, Theme.Space.xl)
                note("Always replace this with that. Whole words, any capitals; the longest match wins.")
                ForEach($store.ruleRows) { $row in
                    editableRow {
                        field("When I say", text: $row.from)
                        Text("→").foregroundStyle(Theme.Color.textMuted)
                        field("Write", text: $row.to)
                    } remove: {
                        store.removeRule(id: row.id)
                        store.save()
                    }
                }
                addRow(button: "Add replacement", canAdd: !newFrom.trimmingCharacters(in: .whitespaces).isEmpty) {
                    field("When I say", text: $newFrom, onSubmit: addReplacement)
                    Text("→").foregroundStyle(Theme.Color.textMuted)
                    field("Write", text: $newTo, onSubmit: addReplacement)
                } add: {
                    addReplacement()
                }
            }
            .padding(.horizontal, Theme.Space.lg + Theme.Space.xs)
            .padding(.vertical, Theme.Space.lg)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onChange(of: store.words) { store.save() }
        .onChange(of: store.replacements) { store.save() }
    }

    private func addWord() {
        if store.addWord(newWord) { store.save() }
        newWord = ""
    }

    private func addReplacement() {
        let from = newFrom.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty else { return }
        store.addReplacement(from: from, to: newTo)
        store.save()
        newFrom = ""
        newTo = ""
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(Theme.Font.ui(11, medium: true))
            .tracking(0.9)
            .textCase(.uppercase)
            .foregroundStyle(Theme.Color.textMuted)
            .padding(.bottom, Theme.Space.xs)
            .accessibilityAddTraits(.isHeader)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.ui(13))
            .foregroundStyle(Theme.Color.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, Theme.Space.sm)
    }

    private func editableRow<Content: View>(@ViewBuilder _ content: () -> Content,
                                            remove: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.md) {
                content()
                Button("Remove", action: remove)
                    .prismSecondaryButton()
            }
            .padding(.vertical, Theme.Space.sm)
            Hairline()
        }
    }

    private func addRow<Content: View>(button: String, canAdd: Bool, @ViewBuilder _ content: () -> Content,
                                       add: @escaping () -> Void) -> some View {
        HStack(spacing: Theme.Space.md) {
            content()
            Button(button, action: add)
                .prismPrimaryButton()
                .disabled(!canAdd)
                .opacity(canAdd ? 1 : 0.4)
        }
        .padding(.top, Theme.Space.md)
    }

    /// Prism's field, as the search field: square, raised black, hairline border.
    private func field(_ label: String, text: Binding<String>, onSubmit: @escaping () -> Void = {}) -> some View {
        TextField(label, text: text, prompt: Text(label).foregroundStyle(Theme.Color.textMuted))
            .textFieldStyle(.plain)
            .font(Theme.Font.ui(13))
            .foregroundStyle(Theme.Color.text)
            .tint(Theme.Color.text)
            .onSubmit(onSubmit)
            .accessibilityLabel(label)
            .padding(.horizontal, Theme.Space.sm + Theme.Space.xs)
            .padding(.vertical, Theme.Space.sm)
            .background(Theme.Color.bgElevated)
            .overlay(Rectangle().strokeBorder(Theme.Color.hairline, lineWidth: 1))
    }
}
