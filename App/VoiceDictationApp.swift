import AppKit
import SwiftUI
import VoiceDictationLib
import VoiceDictationUI

/// The app's scenes. Everything they show and do is in the package:
/// `AppModel`, built and started by `AppLifecycle`, and the views.
@main
struct VoiceDictationApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle

    /// Held for the life of the process: holding it is what keeps others out.
    private static let instanceGuard = SingleInstanceGuard()

    init() {
        // Refuse to start if another instance already holds the lock. This is
        // what stops multiple menu bar icons stacking up when macOS launches
        // the app from more than one place at login, or when a dev build and
        // an installed copy are both opened.
        guard Self.instanceGuard.tryAcquire() else {
            FileHandle.standardError.write(
                Data("VoiceDictation is already running; exiting duplicate instance.\n".utf8)
            )
            exit(0)
        }
        // Before anything reads a preference: the bare binary of old kept
        // them in another domain.
        PreferencesMigrator.migrateIfNeeded(fromDomain: PreferencesMigrator.legacyDomain, to: .standard)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: lifecycle.model)
        } label: {
            MenuBarLabel(pipeline: lifecycle.model.pipeline)
        }
        .menuBarExtraStyle(.menu)

        // Opened from the menu only, never at launch and never restored at
        // the next one, so starting the app takes focus from nothing.
        Window("VoiceDictation", id: AppModel.mainWindowID) {
            // Task 18 puts the transcript library here.
            Text("Your transcripts will appear here.")
                .frame(minWidth: 480, minHeight: 320)
                .onAppear { lifecycle.mainWindowDidOpen() }
                .onDisappear { lifecycle.mainWindowDidClose() }
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            // Task 24 puts the settings here.
            SettingsPlaceholder()
        }
        // Like the window, never brought back at the next launch.
        .restorationBehavior(.disabled)
    }
}

/// Stands in until Task 24. D1 needs the one switch to record comparison clips.
private struct SettingsPlaceholder: View {
    @State private var keepComparison = PreferencesManager.shared.keepComparisonRecordings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings will appear here.")
            Toggle("Keep recordings for comparison", isOn: $keepComparison)
                .onChange(of: keepComparison) { _, newValue in
                    PreferencesManager.shared.keepComparisonRecordings = newValue
                }
        }
        .padding(40)
    }
}
