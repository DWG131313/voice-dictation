import AppKit
import Combine
import Observation
import Sparkle
import SwiftUI
import VoiceDictationLib
import VoiceDictationUI

/// The app's scenes. Everything they show and do is in the package:
/// `AppModel`, built and started by `AppLifecycle`, and the views. The one
/// exception is Sparkle, which only this target links: `SparkleUpdates`
/// stands behind the menu's "Check for Updates…".
@main
struct VoiceDictationApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle

    /// Held for the life of the process: holding it is what keeps others out.
    private static let instanceGuard = SingleInstanceGuard()

    private let updates: SparkleUpdates

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
        // After the lock, so a copy turned away above starts no updater.
        updates = SparkleUpdates()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: lifecycle.model, updates: updates)
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

        // ⌘, and the menu's "Settings…": the same view as the window's
        // Settings section (Task 24), black and dark only, as the window is.
        Settings {
            SettingsView(model: lifecycle.model)
                .frame(width: 560, height: 680)
                .background(Theme.Color.bg)
                .foregroundStyle(Theme.Color.text)
                .preferredColorScheme(.dark)
                .onAppear { lifecycle.windowDidOpen(AppModel.settingsWindowID) }
                .onDisappear { lifecycle.windowDidClose(AppModel.settingsWindowID) }
        }
        // Like the window, never brought back at the next launch.
        .restorationBehavior(.disabled)
    }
}

/// Sparkle behind "Check for Updates…" (Task 26), built as Sparkle's SwiftUI
/// setup builds it. `SUEnableAutomaticChecks` is false in Info.plist, so
/// starting the updater neither asks about automatic checks nor schedules
/// one: the app goes online for updates only when Danny chooses the item.
@MainActor @Observable
final class SparkleUpdates: UpdateChecking {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private(set) var canCheckForUpdates = false
    @ObservationIgnored private var canCheckObservation: AnyCancellable?

    init() {
        // Key-value observable (SPUUpdater.h); false while a check is under way.
        canCheckObservation = controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] canCheck in self?.canCheckForUpdates = canCheck }
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
