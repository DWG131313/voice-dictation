import AppKit
import Observation
import SwiftUI
import VoiceDictationLib

/// What "Check for Updates…" needs (Task 26). Sparkle provides it in the app
/// target, the only one that links Sparkle, so the menu and its tests do not.
/// The menu reads `canCheckForUpdates` as it draws, so a conforming class is
/// `@Observable` and the item follows it.
@MainActor
public protocol UpdateChecking: AnyObject, Observable {
    /// False while a check is under way: Sparkle's `canCheckForUpdates`.
    var canCheckForUpdates: Bool { get }
    /// Checks now and shows what it finds: the app's only update check.
    func checkForUpdates()
}

/// The menu bar menu: what the app is doing, the window, Mini View, Paste
/// Last Transcript, the model dictation uses, Settings, Check for Updates…
/// and Quit.
public struct MenuBarContent: View {
    private let model: AppModel
    private let updates: any UpdateChecking
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    public init(model: AppModel, updates: any UpdateChecking) {
        self.model = model
        self.updates = updates
    }

    public var body: some View {
        if case .needsPermission = model.pipeline.state {
            // A way to the permissions even if the Welcome window never
            // opened at launch.
            Button(Self.statusLine(for: model.pipeline.state)) {
                NSApp.activate()
                openWindow(id: AppModel.welcomeWindowID)
            }
        } else {
            Text(Self.statusLine(for: model.pipeline.state))
        }
        Divider()
        Button("Open VoiceDictation") {
            // A menu bar app is not active when its menu is used, so the
            // window would open behind the app in front.
            NSApp.activate()
            openWindow(id: AppModel.mainWindowID)
        }
        // The tab on the edge of the window in front; saved, off by default.
        Toggle("Mini View", isOn: Binding(
            get: { model.miniViewEnabled },
            set: { model.miniViewEnabled = $0 }
        ))
        // The store's latest transcript with text (Ruling P4); off until one
        // is kept. Control-Option-V does the same when its shortcut is on.
        Button("Paste Last Transcript") {
            model.pipeline.pasteLast()
        }
        .disabled(!model.pipeline.canPasteLast)
        Divider()
        modelMenu
        Divider()
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        updatesItem
        Divider()
        Button("Quit") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// The models, one group per engine with no heading, the default's
    /// first, and the one dictation uses checked. `AppModel` lists them
    /// again whenever a menu opens.
    private var modelMenu: some View {
        Menu(Self.modelMenuTitle(models: model.models, selected: model.selectedModel)) {
            if model.models.isEmpty {
                Text("Loading models…")
            }
            ForEach(Self.modelSections(model.models)) { section in
                Section { modelItems(section.models) }
            }
        }
    }

    /// Sparkle checks only from here: its automatic checks are off.
    private var updatesItem: some View {
        let entry = Self.updatesEntry(updates)
        return Button(entry.title, action: entry.action)
            .disabled(!entry.isEnabled)
    }

    /// A toggle draws the checkmark. Choosing the checked model goes through
    /// `choose` too: that is how "Download Apple Speech" works for the model
    /// already in use.
    private func modelItems(_ models: [ModelDescriptor]) -> some View {
        ForEach(models) { descriptor in
            let entry = Self.menuEntry(for: descriptor)
            Toggle(entry.title, isOn: Binding(
                get: { descriptor.id == model.selectedModel },
                set: { _ in Task { await model.choose(descriptor) } }
            ))
            .disabled(!entry.isEnabled)
            .help(descriptor.detail)
        }
    }

    // MARK: - What the menu says

    /// The status line: what the app is doing, in words.
    static func statusLine(for state: DictationState) -> String {
        switch state {
        case .idle: return "Status: Ready"
        case .recording: return "Status: Recording..."
        case .transcribing: return "Status: Transcribing..."
        case .cleaning: return "Status: Cleaning up..."
        case .preparingModel(let name): return "Status: Preparing \(name)..."
        case .error(let message): return "Error: \(message)"
        case .needsPermission(let permission): return "Permission needed: \(permission)"
        }
    }

    /// "Model: " and the model dictation uses; just "Model" until the models
    /// are first listed.
    static func modelMenuTitle(models: [ModelDescriptor], selected: ModelID?) -> String {
        guard let selected else { return "Model" }
        let name = models.first { $0.id == selected }?.displayName ?? selected.storageKey
        return "Model: \(name)"
    }

    /// One engine's models in the Model submenu.
    struct ModelSection: Identifiable {
        let engine: EngineKind
        var models: [ModelDescriptor]

        var id: EngineKind { engine }
    }

    /// The models grouped by engine, in the order they are listed, which is
    /// the order of `AppModel.engines()`.
    static func modelSections(_ models: [ModelDescriptor]) -> [ModelSection] {
        var sections: [ModelSection] = []
        for model in models {
            if let index = sections.firstIndex(where: { $0.engine == model.id.engine }) {
                sections[index].models.append(model)
            } else {
                sections.append(ModelSection(engine: model.id.engine, models: [model]))
            }
        }
        return sections
    }

    /// "Check for Updates…", greyed out while Sparkle is already checking;
    /// choosing it asks Sparkle to check now.
    static func updatesEntry(_ updates: any UpdateChecking)
        -> (title: String, isEnabled: Bool, action: @MainActor () -> Void) {
        ("Check for Updates…", updates.canCheckForUpdates, { updates.checkForUpdates() })
    }

    /// How a model reads in the Model submenu, and whether choosing it does
    /// anything. A model that is not on the Mac offers its download, which
    /// then selects it.
    static func menuEntry(for model: ModelDescriptor) -> (title: String, isEnabled: Bool) {
        switch model.state {
        case .ready:
            return (model.displayName, true)
        case .notDownloaded:
            return ("Download \(model.displayName)", true)
        case .preparing:
            return ("\(model.displayName) — preparing", true)
        case .downloading(let progress):
            return ("\(model.displayName) — downloading \(Int(progress * 100))%", false)
        case .unavailable(let reason):
            return ("\(model.displayName) — \(reason)", false)
        }
    }
}

/// The menu bar icon: today's symbols, drawn as a template image that the
/// system colours. Status is the menu's words, never colour (Prism).
public struct MenuBarLabel: View {
    private let pipeline: DictationPipeline

    public init(pipeline: DictationPipeline) {
        self.pipeline = pipeline
    }

    public var body: some View {
        let state = pipeline.state
        Image(systemName: Self.symbolName(for: state))
            .accessibilityLabel(Self.accessibilityLabel(for: state))
    }

    /// The SF Symbol for `state`. One this macOS lacks would leave no icon
    /// at all, so it falls back to the plain mic.
    static func symbolName(for state: DictationState,
                           exists: (String) -> Bool = { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil })
        -> String {
        let name: String
        switch state {
        case .idle, .recording: name = "mic.fill"
        case .transcribing, .cleaning: name = "waveform"
        case .preparingModel: name = "arrow.down.circle"
        case .error: name = "mic.slash.fill"
        case .needsPermission: name = "exclamationmark.triangle.fill"
        }
        guard !exists(name) else { return name }
        Log.info("[STATUS] SF Symbol '\(name)' unavailable — falling back to mic.fill")
        return "mic.fill"
    }

    static func accessibilityLabel(for state: DictationState) -> String {
        switch state {
        case .idle: return "VoiceDictation — Ready"
        case .recording: return "VoiceDictation — Recording"
        case .transcribing: return "VoiceDictation — Transcribing"
        case .cleaning: return "VoiceDictation — Cleaning up"
        case .preparingModel: return "VoiceDictation — Preparing a model"
        case .error: return "VoiceDictation — Error"
        case .needsPermission: return "VoiceDictation — Permission Needed"
        }
    }
}
