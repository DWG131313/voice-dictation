import Observation
import XCTest
@testable import VoiceDictationLib
@testable import VoiceDictationUI

/// Task 24's Settings: the preferences behind it, and the model
/// `SettingsView` reads in the main window and in the Settings scene (⌘,).
/// Built from fakes and memory: no microphone, no event tap, no login item,
/// no Finder, and nothing written to the real preferences.
final class SettingsModelTests: XCTestCase {
    private let defaults = MemoryPreferenceStore()
    private lazy var preferences = PreferencesManager(defaults: defaults)
    private let system = FakeSettingsSystem()
    private let recorder = FakeRecorder()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("vd-settings-\(UUID().uuidString)", isDirectory: true)
    private let builtIn = AudioInputDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Air Microphone")
    private let yeti = AudioInputDevice(uid: "AppleUSBAudioEngine:Blue:Yeti:1", name: "Yeti Stereo Microphone")
    /// What the model asked for, through the closures `AppModel` gives it.
    private var chosenMicrophones: [String?] = []
    private var hotkeyChanges = 0

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - Preferences

    /// The two new settings: start and stop sounds are on until switched
    /// off, and the microphone follows the system default until one is
    /// chosen. Choosing the system default again forgets the UID.
    func testSoundsAndMicrophonePreferencesDefaultAndAreKept() {
        XCTAssertTrue(preferences.soundsEnabled)
        XCTAssertNil(preferences.inputDeviceUID)

        preferences.soundsEnabled = false
        preferences.inputDeviceUID = "AppleUSBAudioEngine:Blue:Yeti:1"

        let again = PreferencesManager(defaults: defaults)
        XCTAssertFalse(again.soundsEnabled)
        XCTAssertEqual(again.inputDeviceUID, "AppleUSBAudioEngine:Blue:Yeti:1")
        // The names `defaults write com.danny.VoiceDictation` uses.
        XCTAssertEqual(defaults.object(forKey: "soundsEnabled") as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: "inputDeviceUID"), "AppleUSBAudioEngine:Blue:Yeti:1")

        again.inputDeviceUID = nil
        XCTAssertNil(defaults.object(forKey: "inputDeviceUID"))
        XCTAssertNil(PreferencesManager(defaults: defaults).inputDeviceUID)
    }

    /// `PreferencesManager` is observable: a view that reads a setting is
    /// drawn again when it changes, wherever the change was made. The
    /// Settings scene and the window's section show the same settings, and
    /// the sidebar's footer follows the hotkey.
    func testEverySettingIsObservable() {
        let changes: [(String, () -> Void, () -> Void)] = [
            ("hotkey", { _ = self.preferences.hotkey }, { self.preferences.hotkey = .rightOption }),
            ("doubleTapEnabled", { _ = self.preferences.doubleTapEnabled }, { self.preferences.doubleTapEnabled = true }),
            ("pasteLastHotkeyEnabled", { _ = self.preferences.pasteLastHotkeyEnabled },
             { self.preferences.pasteLastHotkeyEnabled = true }),
            ("cleanupEnabled", { _ = self.preferences.cleanupEnabled }, { self.preferences.cleanupEnabled = false }),
            ("keptRecordings", { _ = self.preferences.keptRecordings }, { self.preferences.keptRecordings = 10 }),
            ("inputDeviceUID", { _ = self.preferences.inputDeviceUID }, { self.preferences.inputDeviceUID = "mic" }),
            ("soundsEnabled", { _ = self.preferences.soundsEnabled }, { self.preferences.soundsEnabled = false }),
            ("launchAtLogin", { _ = self.preferences.launchAtLogin }, { self.preferences.launchAtLogin = true }),
            ("selectedModelID", { _ = self.preferences.selectedModelID },
             { self.preferences.selectedModelID = .appleDictation }),
        ]
        for (name, read, write) in changes {
            XCTAssertTrue(notifies(reading: read, writing: write), "\(name) changed unseen")
        }
    }

    // MARK: - Hotkey and double tap

    /// Choosing another hotkey while the app listens replaces the event
    /// tap's strategy at once with one for the new key (Task 23's
    /// `HotkeyManager.start`, which stops the old one first). The fake
    /// manager starts no strategy, so no tap is made. The same key again
    /// restarts nothing.
    @MainActor
    func testHotkeyChangeRestartsTap() {
        let hotkeys = FakeHotkeys()
        let model = makeAppModel(hotkeys: hotkeys)
        model.permissionStatusChanged(accessibility: true, microphone: true)
        XCTAssertEqual(hotkeys.startedChoices, [.globe], "listening for Globe")

        model.settings.hotkey = .rightOption

        XCTAssertEqual(preferences.hotkey, .rightOption)
        XCTAssertEqual(hotkeys.startedChoices, [.globe, .rightOption], "the tap restarts with the new key")
        model.settings.hotkey = .rightOption
        XCTAssertEqual(hotkeys.started.count, 2, "the same key again restarts nothing")
    }

    /// Not listening yet (no Accessibility), there is no tap to restart: the
    /// key is saved, and the tap starts with it once listening starts.
    @MainActor
    func testAHotkeyChosenBeforeListeningIsTheOneListenedFor() {
        let hotkeys = FakeHotkeys()
        var granted = false
        let model = makeAppModel(hotkeys: hotkeys, accessibility: { granted })

        model.settings.hotkey = .rightCommand
        XCTAssertTrue(hotkeys.started.isEmpty)

        granted = true
        model.permissionStatusChanged(accessibility: true, microphone: true)
        XCTAssertEqual(hotkeys.startedChoices, [.rightCommand])
    }

    /// "Double-tap to dictate" is off until switched on, and its explanation
    /// names the hotkey chosen, as the sidebar's footer does. No word in
    /// Settings says "hands-free" (Danny, 2026-11-12).
    @MainActor
    func testDoubleTapRowNamesTheHotkey() {
        let settings = makeSettings()
        XCTAssertFalse(settings.doubleTapEnabled)
        XCTAssertEqual(settings.doubleTapNote,
                       "Double-tap Globe to start, double-tap again to stop. Holding works as always.")

        settings.doubleTapEnabled = true
        settings.hotkey = .rightOption

        XCTAssertTrue(preferences.doubleTapEnabled)
        XCTAssertEqual(settings.doubleTapNote,
                       "Double-tap Right Option to start, double-tap again to stop. Holding works as always.")
        XCTAssertEqual(hotkeyChanges, 1)
        let words = HotkeyChoice.allCases.map(SettingsModel.doubleTapNote(for:)) + SettingsModel.Row.allCases.map(\.title)
            + [SettingsModel.keptRecordingsNote, SettingsModel.pasteLastNote, SettingsModel.openAtLoginUnavailable,
               SettingsModel.systemDefaultMicrophone]
        for text in words {
            XCTAssertFalse(text.lowercased().contains("hands"), text)
        }
    }

    /// The rows, in the brief's order.
    func testTheRowsAreInOrder() {
        XCTAssertEqual(SettingsModel.Row.allCases.map(\.title), [
            "Hotkey", "Double-tap to dictate", "Paste last transcript shortcut", "Clean up transcripts",
            "Recordings to keep", "Microphone", "Start and stop sounds", "Open at login", "Data", "Show welcome guide",
        ])
    }

    // MARK: - Clean up transcripts

    /// While Apple Intelligence cannot run, the row is off and cannot be
    /// switched on, with the reason beneath it in words. The saved choice is
    /// kept: when Apple Intelligence is back, cleanup is on again.
    @MainActor
    func testCleanupRowDisabledWithReasonWhenUnavailable() {
        preferences.cleanupEnabled = true
        system.cleanup = .unavailable("Apple Intelligence is turned off in System Settings")
        let settings = makeSettings()
        settings.refresh()

        XCTAssertEqual(settings.cleanupRow, SettingsModel.ToggleRow(
            isOn: false, isEnabled: false, note: "Apple Intelligence is turned off in System Settings"))
        XCTAssertTrue(preferences.cleanupEnabled, "the saved choice stays")

        system.cleanup = .available
        settings.refresh()
        XCTAssertEqual(settings.cleanupRow, SettingsModel.ToggleRow(isOn: true, isEnabled: true, note: nil))
        settings.cleanupEnabled = false
        XCTAssertEqual(settings.cleanupRow, SettingsModel.ToggleRow(isOn: false, isEnabled: true, note: nil))
        XCTAssertFalse(preferences.cleanupEnabled)
    }

    // MARK: - Recordings to keep

    /// Lowering "Recordings to keep" prunes at once, with no dictation
    /// needed. Ruling T12-1 still holds: pinned and failed transcripts keep
    /// their recordings and do not count, even at 0.
    @MainActor
    func testLoweringKeptRecordingsPrunesImmediately() throws {
        let archive = AudioArchive(directory: directory.appendingPathComponent("audio", isDirectory: true))
        preferences.keptRecordings = 3
        let preferences = preferences
        let store = TranscriptStore(directory: directory, inMemory: true, audio: archive,
                                    keptRecordings: { preferences.keptRecordings })
        let base = Date(timeIntervalSince1970: 1_762_900_000)
        let oldest = try XCTUnwrap(store.add(outcome("Oldest.", at: base)))
        let pinned = try XCTUnwrap(store.add(outcome("Pinned.", at: base.addingTimeInterval(60))))
        store.setPinned(pinned, true)
        let failed = try XCTUnwrap(store.add(outcome("", at: base.addingTimeInterval(120), status: .failed)))
        let older = try XCTUnwrap(store.add(outcome("Older.", at: base.addingTimeInterval(180))))
        let newest = try XCTUnwrap(store.add(outcome("Newest.", at: base.addingTimeInterval(240))))
        XCTAssertEqual(archive.fileNames().count, 5, "three ordinary recordings, a pinned and a failed one")
        let settings = makeSettings(store: store)

        settings.keptRecordings = 1

        XCTAssertEqual(preferences.keptRecordings, 1)
        XCTAssertNotNil(newest.audioFileName, "the newest ordinary recording stays")
        XCTAssertNil(older.audioFileName, "pruned at once")
        XCTAssertNil(oldest.audioFileName, "pruned at once")
        XCTAssertNotNil(pinned.audioFileName, "a pinned transcript keeps its recording")
        XCTAssertNotNil(failed.audioFileName, "a failed dictation keeps its recording")
        XCTAssertEqual(Set(archive.fileNames()), Set([newest, pinned, failed].compactMap(\.audioFileName)))

        settings.keptRecordings = 0

        XCTAssertNil(newest.audioFileName, "0 turns off replay and re-transcription")
        XCTAssertNotNil(pinned.audioFileName)
        XCTAssertNotNil(failed.audioFileName, "failed dictations keep theirs")
        XCTAssertEqual(archive.fileNames().count, 2)
        XCTAssertEqual(store.search("", scope: .all).count, 5, "only recordings go; every transcript stays")
    }

    /// The stepper runs from 0 to 500 in tens; a value from outside, such as
    /// one written with `defaults write`, is brought back inside on the
    /// next change.
    @MainActor
    func testKeptRecordingsStayWithinTheStepper() {
        let settings = makeSettings()
        XCTAssertEqual(settings.keptRecordings, 50)
        XCTAssertEqual(SettingsModel.keptRecordingsRange, 0...500)
        XCTAssertEqual(SettingsModel.keptRecordingsStep, 10)

        settings.keptRecordings = 600
        XCTAssertEqual(preferences.keptRecordings, 500)
        settings.keptRecordings = -10
        XCTAssertEqual(preferences.keptRecordings, 0)
    }

    /// − and + go to the next ten down or up, so a number that is not a
    /// multiple of ten (2, from a `defaults write`) lands on one, and they
    /// stop at the ends.
    func testTheStepperGoesToTheNextTen() {
        XCTAssertEqual(SettingsModel.keptRecordings(after: 50, up: true), 60)
        XCTAssertEqual(SettingsModel.keptRecordings(after: 50, up: false), 40)
        XCTAssertEqual(SettingsModel.keptRecordings(after: 25, up: true), 30)
        XCTAssertEqual(SettingsModel.keptRecordings(after: 25, up: false), 20)
        XCTAssertEqual(SettingsModel.keptRecordings(after: 2, up: false), 0)
        XCTAssertEqual(SettingsModel.keptRecordings(after: 2, up: true), 10)
        XCTAssertEqual(SettingsModel.keptRecordings(after: 0, up: false), 0)
        XCTAssertEqual(SettingsModel.keptRecordings(after: 500, up: true), 500)
        XCTAssertEqual(SettingsModel.keptRecordings(after: 750, up: false), 500, "from outside the range, back inside")
    }

    // MARK: - Microphone

    /// A saved microphone that is no longer connected: the row shows
    /// "System default", and the choice is kept, and once the microphone is
    /// back (the device list changes), the row shows it again.
    @MainActor
    func testMissingMicrophoneFallsBackToDefault() {
        preferences.inputDeviceUID = yeti.uid
        system.microphones = [builtIn]
        let settings = makeSettings()
        settings.viewAppeared()

        XCTAssertNil(settings.microphone)
        XCTAssertEqual(settings.microphoneName, "System default")
        XCTAssertEqual(preferences.inputDeviceUID, yeti.uid, "kept for when it is back")

        system.microphones = [builtIn, yeti]
        system.microphonesChanged()

        XCTAssertEqual(settings.microphones, [builtIn, yeti])
        XCTAssertEqual(settings.microphone, yeti.uid)
        XCTAssertEqual(settings.microphoneName, "Yeti Stereo Microphone")
    }

    /// Choosing a microphone saves it and moves the recorder to it, which
    /// prepares again on it; choosing "System default" forgets it.
    @MainActor
    func testChoosingAMicrophoneMovesTheRecorder() {
        system.microphones = [builtIn, yeti]
        let model = makeAppModel()
        model.settings.refresh()

        model.settings.microphone = yeti.uid

        XCTAssertEqual(preferences.inputDeviceUID, yeti.uid)
        XCTAssertEqual(recorder.inputDeviceUID, yeti.uid)
        XCTAssertEqual(model.settings.microphoneName, "Yeti Stereo Microphone")

        model.settings.microphone = nil

        XCTAssertNil(preferences.inputDeviceUID)
        XCTAssertNil(recorder.inputDeviceUID)
        XCTAssertEqual(model.settings.microphoneName, "System default")
    }

    /// The device list is watched once, however often Settings appears:
    /// a Core Audio listener cannot be taken back (Task 4).
    @MainActor
    func testMicrophonesAreWatchedOnce() {
        let settings = makeSettings()
        settings.viewAppeared()
        settings.viewAppeared()
        XCTAssertEqual(system.observers, 1)
    }

    // MARK: - Open at login

    /// A dev build (anything under `.build`) cannot register a login item,
    /// so the row is off and disabled with the old menu's explanation, and
    /// switching it does nothing.
    @MainActor
    func testOpenAtLoginIsOffAndDisabledInADevBuild() {
        preferences.launchAtLogin = true
        system.canOpenAtLogin = false
        let settings = makeSettings()

        XCTAssertEqual(settings.openAtLoginRow, SettingsModel.ToggleRow(
            isOn: false, isEnabled: false, note: "Install app to enable"))
        settings.openAtLogin = false
        XCTAssertTrue(system.loginItemCalls.isEmpty)
        XCTAssertTrue(preferences.launchAtLogin, "unchanged")
    }

    /// An installed app registers or unregisters the login item as the
    /// switch is turned, and keeps the choice.
    @MainActor
    func testOpenAtLoginFollowsTheSwitchInAnInstalledApp() {
        system.canOpenAtLogin = true
        let settings = makeSettings()
        XCTAssertEqual(settings.openAtLoginRow, SettingsModel.ToggleRow(isOn: false, isEnabled: true, note: nil))

        settings.openAtLogin = true

        XCTAssertEqual(system.loginItemCalls, [true])
        XCTAssertTrue(preferences.launchAtLogin)
        XCTAssertEqual(settings.openAtLoginRow, SettingsModel.ToggleRow(isOn: true, isEnabled: true, note: nil))
    }

    // MARK: - Data

    /// The data folder's total size is measured off the main thread, then
    /// shown; until then the row says it is measuring.
    @MainActor
    func testTheDataFolderIsMeasuredOffTheMainThread() async {
        system.size.bytes = 1_500_000
        let settings = makeSettings()
        XCTAssertNil(settings.dataSize)
        XCTAssertEqual(settings.dataSizeText, "Measuring…")

        await settings.measureData()

        XCTAssertEqual(system.size.folders, [directory])
        XCTAssertEqual(system.size.onMainThread, [false])
        XCTAssertEqual(settings.dataSize, 1_500_000)
        XCTAssertEqual(settings.dataSizeText, ByteCountFormatter.string(fromByteCount: 1_500_000, countStyle: .file))
    }

    /// The size counts every file in the folder and the folders inside it,
    /// at least their bytes (blocks on disk round each one up).
    func testFolderSizeCountsEveryFileInside() throws {
        let audio = directory.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try Data(count: 10_000).write(to: directory.appendingPathComponent("transcripts.store"))
        try Data(count: 30_000).write(to: audio.appendingPathComponent("a.m4a"))

        let size = SettingsModel.size(of: directory)

        XCTAssertGreaterThanOrEqual(size, 40_000)
        XCTAssertLessThan(size, 200_000)
        XCTAssertEqual(SettingsModel.size(of: directory.appendingPathComponent("missing")), 0)
    }

    /// "Reveal in Finder" selects the data folder in the Finder, and the row
    /// names the folder with `~`, never a home folder's full path.
    @MainActor
    func testRevealShowsTheDataFolder() {
        let settings = makeSettings()

        settings.revealData()

        XCTAssertEqual(system.revealed, [directory])
        XCTAssertEqual(SettingsModel.displayPath(of: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoiceDictation", isDirectory: true)),
                       "~/Library/Application Support/VoiceDictation")
    }

    // MARK: - Helpers

    @MainActor
    private func makeSettings(store: TranscriptStore? = nil) -> SettingsModel {
        SettingsModel(preferences: preferences, store: store ?? TranscriptStore(directory: directory, inMemory: true),
                      dataDirectory: directory, system: system.system,
                      chooseMicrophone: { [weak self] uid in self?.chosenMicrophones.append(uid) },
                      hotkeyChanged: { [weak self] in self?.hotkeyChanges += 1 })
    }

    /// The app's model, as `AppModelTests` makes it, with the fake hotkey
    /// manager (no event tap) and `accessibility` in place of the real check.
    @MainActor
    private func makeAppModel(hotkeys: FakeHotkeys = FakeHotkeys(),
                              accessibility: @escaping () -> Bool = { true }) -> AppModel {
        AppModel(service: TranscriptionService(engines: [FakeEngine(kind: .appleSpeech)], selected: .appleSpeech),
                 recorder: recorder, paster: FakePaster(),
                 store: TranscriptStore(directory: directory, inMemory: true),
                 preferences: preferences, hotkeys: hotkeys, settingsSystem: system.system,
                 accessibilityGranted: accessibility, dataDirectory: directory,
                 onboardingSystem: .fake(), pasteAgain: FakeApps().system)
    }

    private func outcome(_ text: String, at date: Date,
                         status: DictationOutcome.Status = .pasted) -> DictationOutcome {
        DictationOutcome(date: date, clip: AudioClip(samples: [Float](repeating: 0.2, count: 1_600)),
                         rawText: text, text: text, model: .appleSpeech, transcribeSeconds: 0.2,
                         appName: "TextEdit", status: status,
                         failure: status == .failed ? "Apple Speech language files are not installed" : nil)
    }

    /// Whether writing changes something `read` read, as SwiftUI would see it.
    private func notifies(reading read: () -> Void, writing write: () -> Void) -> Bool {
        let flag = Flag()
        withObservationTracking(read) { flag.set() }
        write()
        return flag.isSet
    }

    /// A flag the observation's change handler can set from any thread.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}
