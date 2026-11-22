import SwiftUI
import VoiceDictationLib

/// The panel a click on the tab opens: the newest transcript with text,
/// wherever it went, with Copy and Open; "Nothing dictated yet." and Open
/// before there is one. 248 pt wide on `bg-elevated`, a hairline border,
/// square, no colour (DESIGN.md `mini-panel`).
struct MiniPanelView: View {
    static let width: CGFloat = 248
    /// How long Copy reads "Copied".
    static let copiedSeconds: TimeInterval = 2

    let transcript: Transcript?
    /// For the header's time, as the rows say it.
    let now: Date
    let copy: () -> Void
    let open: () -> Void
    @State private var showsCopied = false
    @State private var copiedEnds: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            if let transcript {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                    Text(Self.header(transcript))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text(LibraryModel.whenString(transcript.date, now: now))
                        .fixedSize()
                }
                .font(Theme.Font.mono(12))
                .foregroundStyle(Theme.Color.textMuted)
                Text(transcript.text)
                    .font(Theme.Font.ui(14))
                    .foregroundStyle(Theme.Color.text)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.sm) {
                    copyButton
                    openButton
                }
            } else {
                Text("Nothing dictated yet.")
                    .font(Theme.Font.ui(14))
                    .foregroundStyle(Theme.Color.textMuted)
                openButton
            }
        }
        .padding(Theme.Space.md)
        .frame(width: Self.width, alignment: .leading)
        .background(Theme.Color.bgElevated)
        .overlay(Rectangle().strokeBorder(Theme.Color.hairline, lineWidth: 1))
    }

    /// "Terminal · Voice Dictation": the app, then the folder, as the
    /// group headings name them; the app alone with no folder recorded.
    static func header(_ t: Transcript) -> String {
        let title = TranscriptGroups.title(of: Place(t))
        guard let app = title.app else { return title.name }
        return "\(app) · \(title.name)"
    }

    private var copyButton: some View {
        Button {
            copy()
            showCopied()
        } label: {
            HStack(spacing: Theme.Space.xs) {
                if showsCopied { ClipboardMark() }
                Text(showsCopied ? "Copied" : "Copy")
            }
            .compactSecondaryButton()
        }
        .buttonStyle(.plain)
    }

    private var openButton: some View {
        Button(action: open) {
            Text("Open")
                .compactSecondaryButton()
        }
        .buttonStyle(.plain)
    }

    /// "Copied" for `copiedSeconds`; another Copy meanwhile starts them again.
    private func showCopied() {
        showsCopied = true
        copiedEnds?.cancel()
        copiedEnds = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.copiedSeconds))
            guard !Task.isCancelled else { return }
            showsCopied = false
        }
    }
}

private extension View {
    /// The secondary button at the panel's size: 4 by 10 pt inside its 1 pt
    /// white outline, all of it clickable.
    func compactSecondaryButton() -> some View {
        font(Theme.Font.ui(14, medium: true))
            .foregroundStyle(Color.white)
            .padding(.vertical, Theme.Space.xs)
            .padding(.horizontal, 10)
            .overlay(Rectangle().strokeBorder(Color.white, lineWidth: 1))
            .contentShape(Rectangle())
    }
}
