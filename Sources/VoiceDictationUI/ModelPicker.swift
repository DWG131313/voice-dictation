import SwiftUI
import VoiceDictationLib

/// What both model pickers list, the sidebar's and the menu bar's Model
/// submenu (spec 2026-11-22): the speed ladder, then Apple's two, then the
/// model in use if it is on neither. Each model has ✓ when it is on the Mac,
/// ↓ when it is not, and a line that says what it trades, or what it is doing.
enum ModelPicker {
    enum Mark: Equatable {
        case downloaded, notDownloaded

        var systemImage: String {
            switch self {
            case .downloaded: "checkmark"
            case .notDownloaded: "arrow.down.circle"
            }
        }
    }

    struct Entry: Identifiable {
        let descriptor: ModelDescriptor
        let name: String
        let line: String
        let mark: Mark?
        let isEnabled: Bool
        let isInUse: Bool

        var id: ModelID { descriptor.id }
    }

    /// Fastest, Fast, Slow, Slowest: whisper.cpp for the three sizes it has,
    /// WhisperKit for the largest, which only it has.
    static let ladder: [ModelID] = [
        ModelID(engine: .whisperCpp, name: "tiny.en"),
        .whisperCppBase,
        ModelID(engine: .whisperCpp, name: "small.en"),
        ModelID(engine: .whisperKit, name: "large-v3-turbo"),
    ]

    static let apple: [ModelID] = [.appleSpeech, .appleDictation]

    /// What each listed model trades. A model off the ladder is listed only
    /// while it is in use, so its line is "in use".
    private static let usualLines: [ModelID: String] = [
        ladder[0]: "more mistakes",
        ladder[1]: "the default",
        ladder[2]: "fewer mistakes",
        ladder[3]: "fewest mistakes",
        .appleSpeech: "built into macOS",
        .appleDictation: "built into macOS",
    ]

    /// The ladder's listed models in ladder order, then Apple's, then the
    /// model in use if it is in neither. Empty groups are dropped.
    static func sections(_ models: [ModelDescriptor], selected: ModelID?) -> [[Entry]] {
        func group(_ ids: [ModelID]) -> [Entry] {
            ids.compactMap { id in models.first { $0.id == id } }.map { entry($0, selected: selected) }
        }
        var sections = [group(ladder), group(apple)]
        if let selected, !ladder.contains(selected), !apple.contains(selected),
           let inUse = models.first(where: { $0.id == selected }) {
            sections.append([entry(inUse, selected: selected)])
        }
        return sections.filter { !$0.isEmpty }
    }

    /// The closed picker: the model in use, or "Model" before one is chosen
    /// or listed.
    static func title(_ models: [ModelDescriptor], selected: ModelID?) -> String {
        guard let selected, let inUse = models.first(where: { $0.id == selected }) else { return "Model" }
        return inUse.displayName
    }

    /// A state line (downloading, preparing, unavailable) wins over "in use"
    /// while it lasts (spec call 10).
    private static func entry(_ model: ModelDescriptor, selected: ModelID?) -> Entry {
        let isInUse = model.id == selected
        let usual = usualLines[model.id] ?? "in use"
        let mark: Mark?
        let line: String
        let isEnabled: Bool
        switch model.state {
        case .ready:
            (mark, line, isEnabled) = (.downloaded, isInUse ? "in use" : usual, true)
        case .preparing:
            (mark, line, isEnabled) = (.downloaded, "preparing", true)
        case .notDownloaded:
            (mark, line, isEnabled) = (.notDownloaded, usual, true)
        case .downloading(let progress):
            (mark, line, isEnabled) = (.notDownloaded, "downloading \(Int(progress * 100))%", false)
        case .unavailable(let reason):
            (mark, line, isEnabled) = (nil, reason, false)
        }
        return Entry(descriptor: model, name: model.displayName, line: line, mark: mark,
                     isEnabled: isEnabled, isInUse: isInUse)
    }
}

/// The pickers' rows, in the system's menu: one section per group, each model
/// its mark, its name and, under it as the item's subtitle, its line. Choosing a model not on the
/// Mac downloads it and then switches to it (`AppModel.choose`). No download
/// sizes here: they are on the Models page.
struct ModelPickerItems: View {
    let sections: [[ModelPicker.Entry]]
    let choose: (ModelDescriptor) -> Void

    var body: some View {
        ForEach(sections.indices, id: \.self) { index in
            Section {
                ForEach(sections[index]) { entry in
                    Button {
                        choose(entry.descriptor)
                    } label: {
                        // The Text after the Label becomes the menu item's
                        // subtitle; a second Text inside the Label is dropped
                        // (ModelPickerViewTests).
                        Label {
                            Text(entry.name)
                        } icon: {
                            if let mark = entry.mark {
                                Image(systemName: mark.systemImage)
                            }
                        }
                        Text(entry.line)
                    }
                    .disabled(!entry.isEnabled)
                }
            }
        }
    }
}
