import SwiftUI
import VoiceDictationLib

/// The Models section: every speech model with its state, its size on disk
/// and the buttons that fit. Downloading never changes the model in use;
/// only "Use for dictation" does. A refusal or a failure is a short line on
/// the model's own row, never an alert.
struct ModelsView: View {
    let model: AppModel

    /// What a row's button does.
    enum Action: Equatable {
        case download, cancel, delete, use, inUse
    }

    /// One engine's models, in the order the engine lists them.
    struct Group: Identifiable {
        let engine: EngineKind
        var models: [ModelDescriptor]

        var id: EngineKind { engine }
        /// The old whisper-cli models sit under a muted label; removed in Task 27A.
        var title: String? { engine == .whisperCLI ? "Previous engine" : nil }
    }

    /// Apple's models first, then WhisperKit (the engine lists it smallest
    /// to largest), then whisper.cpp, then the previous engine.
    static func sections(_ models: [ModelDescriptor]) -> [Group] {
        [EngineKind.appleSpeech, .whisperKit, .whisperCpp, .whisperCLI].compactMap { engine in
            let ofEngine = models.filter { $0.id.engine == engine }
            return ofEngine.isEmpty ? nil : Group(engine: engine, models: ofEngine)
        }
    }

    /// The buttons a model's state calls for. The Apple models have no
    /// Delete (macOS manages their files); the one in use cannot be deleted.
    /// Cancel is offered only for a download this app can cancel.
    static func actions(for model: ModelDescriptor, selected: ModelID?, cancellable: Bool) -> [Action] {
        switch model.state {
        case .ready:
            let isSelected = model.id == selected
            var actions: [Action] = [isSelected ? .inUse : .use]
            if model.id.engine != .appleSpeech, !isSelected { actions.append(.delete) }
            return actions
        case .notDownloaded: return [.download]
        case .downloading: return cancellable ? [.cancel] : []
        case .preparing, .unavailable: return []
        }
    }

    static func stateWord(_ state: ModelDescriptor.State) -> String {
        switch state {
        case .ready: "Ready"
        case .notDownloaded: "Not downloaded"
        case .downloading(let fraction): "Downloading \(Int(fraction * 100))%"
        case .preparing: "Preparing"
        case .unavailable(let reason): "Unavailable: \(reason)"
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Models")
                    .font(Theme.Font.title())
                    .foregroundStyle(Theme.Color.text)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, Theme.Space.md)
                if model.models.isEmpty {
                    Text("Listing the models…")
                        .font(Theme.Font.ui(14))
                        .foregroundStyle(Theme.Color.textMuted)
                }
                ForEach(Self.sections(model.models)) { group in
                    if let title = group.title {
                        Text(title)
                            .font(Theme.Font.ui(11, medium: true))
                            .tracking(0.9)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.Color.textMuted)
                            .padding(.top, Theme.Space.lg)
                            .padding(.bottom, Theme.Space.sm)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(group.models) { descriptor in
                        row(descriptor)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.lg + Theme.Space.xs)
            .padding(.vertical, Theme.Space.lg)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func row(_ descriptor: ModelDescriptor) -> some View {
        let actions = Self.actions(for: descriptor, selected: model.selectedModel,
                                   cancellable: model.downloadProgress[descriptor.id] != nil)
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(descriptor.displayName)
                        .font(Theme.Font.ui(14, medium: true))
                        .foregroundStyle(Theme.Color.text)
                    if !descriptor.detail.isEmpty {
                        Text(descriptor.detail)
                            .font(Theme.Font.ui(12))
                            .foregroundStyle(Theme.Color.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: Theme.Space.sm) {
                        Text(Self.stateWord(descriptor.state))
                            .font(Theme.Font.ui(12, medium: true))
                            .foregroundStyle(Theme.Color.text)
                        if let bytes = descriptor.bytesOnDisk {
                            Text(Self.size(bytes))
                                .font(Theme.Font.mono(12))
                                .foregroundStyle(Theme.Color.textMuted)
                        }
                    }
                    if let note = model.modelMessages[descriptor.id] {
                        Text(note)
                            .font(Theme.Font.ui(12))
                            .foregroundStyle(Theme.Color.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Theme.Space.md)
                HStack(spacing: Theme.Space.sm) {
                    ForEach(actions, id: \.self) { action in
                        button(action, for: descriptor)
                    }
                }
            }
            .padding(.vertical, Theme.Space.md)
            Hairline()
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func button(_ action: Action, for descriptor: ModelDescriptor) -> some View {
        switch action {
        case .download:
            Button("Download") { Task { await model.download(descriptor.id) } }
                .prismSecondaryButton()
        case .cancel:
            Button("Cancel") { model.cancelDownload(descriptor.id) }
                .prismSecondaryButton()
        case .delete:
            Button("Delete") { Task { await model.deleteModel(descriptor.id) } }
                .prismSecondaryButton()
        case .use:
            Button("Use for dictation") { Task { await model.use(descriptor) } }
                .prismPrimaryButton()
        case .inUse:
            Button("In use") {}
                .prismSecondaryButton()
                .disabled(true)
        }
    }
}
