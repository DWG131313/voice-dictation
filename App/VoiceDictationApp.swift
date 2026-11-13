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
                .modifier(OpenWelcomeAtLaunch(model: lifecycle.model))
        }
        .menuBarExtraStyle(.menu)

        // The transcript library. Opened from the menu only, never at launch
        // and never restored at the next one, so starting the app takes
        // focus from nothing. Black to the top edge, as in mockup D: the
        // title bar is hidden and the traffic lights sit over the sidebar.
        Window("VoiceDictation", id: AppModel.mainWindowID) {
            MainWindow(model: lifecycle.model)
                .onAppear { lifecycle.windowDidOpen(AppModel.mainWindowID) }
                .onDisappear { lifecycle.windowDidClose(AppModel.mainWindowID) }
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 640)

        // The setup steps, shown at launch while any is left; like the main
        // window, never at launch otherwise and never restored.
        Window("Welcome", id: AppModel.welcomeWindowID) {
            OnboardingView(model: lifecycle.model)
                .onAppear { lifecycle.windowDidOpen(AppModel.welcomeWindowID) }
                .onDisappear { lifecycle.windowDidClose(AppModel.welcomeWindowID) }
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .windowResizability(.contentSize)

        Settings {
            // Task 24 puts the settings here.
            SettingsPlaceholder()
                .onAppear { lifecycle.windowDidOpen(AppModel.settingsWindowID) }
                .onDisappear { lifecycle.windowDidClose(AppModel.settingsWindowID) }
        }
        // Like the window, never brought back at the next launch.
        .restorationBehavior(.disabled)
    }
}

/// Stands in until Task 24. D1 needs the one switch to record comparison clips,
/// and the Welcome window is reachable from here.
private struct SettingsPlaceholder: View {
    @State private var keepComparison = PreferencesManager.shared.keepComparisonRecordings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings will appear here.")
            Toggle("Keep recordings for comparison", isOn: $keepComparison)
                .onChange(of: keepComparison) { _, newValue in
                    PreferencesManager.shared.keepComparisonRecordings = newValue
                }
            Button("Show Welcome…") {
                NSApp.activate()
                openWindow(id: AppModel.welcomeWindowID)
            }
        }
        .padding(40)
    }
}
