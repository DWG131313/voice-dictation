import SwiftUI
import VoiceDictationLib

/// The main window, from mockup D: the sections, the transcripts and the
/// selected transcript, in columns 220, 340 and the rest wide, on black and
/// dark only (Prism). ⌘F puts the cursor in the search field; the list
/// starts with the keyboard focus, so ↑ and ↓ move through it at once.
public struct MainWindow: View {
    /// Where the keyboard focus is.
    enum Focus: Hashable {
        case search, list
    }

    static let sidebarWidth: CGFloat = 220
    static let listWidth: CGFloat = 340
    static let minimumWidth: CGFloat = 1000
    static let minimumHeight: CGFloat = 600

    private let model: AppModel
    @FocusState private var focus: Focus?

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        let library = model.library
        HStack(spacing: 0) {
            Sidebar(library: library, models: model.models, selectedModel: model.selectedModel)
                .frame(width: Self.sidebarWidth)
            column
            if library.section.scope != nil {
                TranscriptList(library: library, focus: $focus)
                    .frame(width: Self.listWidth)
                column
                TranscriptDetail(library: library, models: model.models)
            } else {
                SetupPlaceholder(section: library.section)
            }
        }
        .frame(minWidth: Self.minimumWidth, maxWidth: .infinity, minHeight: Self.minimumHeight, maxHeight: .infinity)
        // Black up to the window's top edge, under the hidden title bar.
        .background(Theme.Color.bg.ignoresSafeArea())
        .foregroundStyle(Theme.Color.text)
        .background { findShortcut }
        .defaultFocus($focus, .list)
        .preferredColorScheme(.dark)
        .onAppear { library.windowOpened() }
        .onDisappear { library.windowClosed() }
    }

    /// The hairline between two columns, up to the window's top edge.
    private var column: some View {
        Hairline(.vertical)
            .ignoresSafeArea(edges: .top)
    }

    /// ⌘F: an invisible button holds the shortcut, as SwiftUI shortcuts
    /// belong to controls.
    private var findShortcut: some View {
        Button("Find") {
            focus = .search
        }
        .keyboardShortcut("f", modifiers: .command)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Models, Vocabulary and Settings until Tasks 20, 22 and 24 fill them.
private struct SetupPlaceholder: View {
    let section: LibraryModel.Section

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(section.title)
                .font(Theme.Font.title())
                .foregroundStyle(Theme.Color.text)
                .accessibilityAddTraits(.isHeader)
            Text("\(section.title) will appear here.")
                .font(Theme.Font.ui(14))
                .foregroundStyle(Theme.Color.textMuted)
        }
        .padding(.horizontal, Theme.Space.lg + Theme.Space.xs)
        .padding(.vertical, Theme.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
