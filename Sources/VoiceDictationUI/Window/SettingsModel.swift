import AppKit
import Observation
import VoiceDictationLib

/// The Settings section (Task 24): each row's value, and what changing it
/// sets off. `SettingsView` shows it in the main window's Settings section
/// and in the Settings scene (⌘,), so the two always agree. The values live
/// in `PreferencesManager`, which is observable; this adds the rest: another
/// hotkey restarts the event tap, fewer kept recordings prune at once, the
/// recorder moves to the chosen microphone, and the login item follows its
/// switch. Use from the main thread.
@MainActor @Observable
final class SettingsModel {
    /// The rows, in the order Settings shows them.
    enum Row: CaseIterable, Identifiable {
        case hotkey, doubleTap, pasteLastShortcut, cleanup, keptRecordings, microphone, sounds, openAtLogin, data,
             welcomeGuide

        var id: Self { self }

        /// The row's label; for the last, its button.
        var title: String {
            switch self {
            case .hotkey: "Hotkey"
            case .doubleTap: "Double-tap to dictate"
            case .pasteLastShortcut: "Paste last transcript shortcut"
            case .cleanup: "Clean up transcripts"
            case .keptRecordings: "Recordings to keep"
            case .microphone: "Microphone"
            case .sounds: "Start and stop sounds"
            case .openAtLogin: "Open at login"
            case .data: "Data"
            case .welcomeGuide: "Show welcome guide"
            }
        }
    }

    /// What a switch shows: whether it is on, whether it can be changed, and
    /// the line beneath it, if any.
    struct ToggleRow: Equatable {
        var isOn: Bool
        var isEnabled: Bool
        var note: String?
    }

    /// What Settings asks of the Mac, as closures, so tests stand in for
    /// each; `live()` is the app's.
    struct System {
        /// Whether on-device cleanup can run, and if not, why.
        var cleanupAvailability: () -> CleanerAvailability
        /// The microphones connected now.
        var microphones: () -> [AudioInputDevice]
        /// Calls back on the main queue whenever a microphone comes or goes,
        /// for the life of the app.
        var observeMicrophones: (@escaping @MainActor () -> Void) -> Void
        /// Whether this copy may register a login item: an installed app only.
        var canOpenAtLogin: () -> Bool
        /// Registers or unregisters the login item; false when that failed.
        var setOpenAtLogin: (Bool) -> Bool
        /// Shows a folder in the Finder.
        var reveal: (URL) -> Void
        /// A folder's size on disk, in bytes; called off the main thread.
        var folderSize: @Sendable (URL) -> Int64

        static func live() -> System {
            System(
                cleanupAvailability: { FoundationModelCleaner.availability },
                microphones: { AudioDevices.inputDevices() },
                observeMicrophones: { AudioDevices.observeDevices($0) },
                canOpenAtLogin: { LoginItemManager.isRunningFromAppBundle() },
                setOpenAtLogin: { LoginItemManager.shared.setEnabled($0) },
                // Selects the folder in a Finder window (NSWorkspace.h).
                reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
                folderSize: { SettingsModel.size(of: $0) })
        }
    }

    /// "Recordings to keep" runs from 0 to 500, ten at a time.
    nonisolated static let keptRecordingsRange = 0...500
    nonisolated static let keptRecordingsStep = 10
    /// The line under "Recordings to keep".
    static let keptRecordingsNote = "Recordings older than a week are removed, except pinned and failed dictations'; transcripts always stay. 0 turns off replay and re-transcription."
    /// The line under "Paste last transcript shortcut": which keys it is.
    static let pasteLastNote = "Control-Option-V pastes your latest transcript."
    /// The microphone row's name for the system's default input.
    static let systemDefaultMicrophone = "System default"
    /// Why "Open at login" is off in a dev build: the old menu's words.
    static let openAtLoginUnavailable = "Install app to enable"

    @ObservationIgnored private let preferences: PreferencesManager
    @ObservationIgnored private let store: TranscriptStore
    @ObservationIgnored private let system: System
    /// Moves the recorder to a microphone; nil is the system default.
    @ObservationIgnored private let chooseMicrophone: (String?) -> Void
    /// Tells the app the hotkey changed, so the event tap restarts.
    @ObservationIgnored private let hotkeyChanged: () -> Void
    /// `~/Library/Application Support/VoiceDictation/`: the transcripts, the
    /// kept recordings, the vocabulary and the downloaded models.
    let dataDirectory: URL

    /// The microphones connected, as last read.
    private(set) var microphones: [AudioInputDevice] = []
    /// Whether cleanup can run, as last read.
    private(set) var cleanupAvailability = CleanerAvailability.available
    /// The data folder's size in bytes, once measured.
    private(set) var dataSize: Int64?
    /// Counts measurements, so one that finishes late shows nothing.
    @ObservationIgnored private var sizeMeasurements = 0
    @ObservationIgnored private var isWatchingMicrophones = false

    init(preferences: PreferencesManager, store: TranscriptStore, dataDirectory: URL, system: System,
         chooseMicrophone: @escaping (String?) -> Void, hotkeyChanged: @escaping () -> Void) {
        self.preferences = preferences
        self.store = store
        self.dataDirectory = dataDirectory
        self.system = system
        self.chooseMicrophone = chooseMicrophone
        self.hotkeyChanged = hotkeyChanged
    }

    // MARK: - Reading what changes outside the app

    /// Reads again whether cleanup can run and which microphones are
    /// connected: when Settings appears, and when the app becomes active
    /// (back from System Settings, say).
    func refresh() {
        cleanupAvailability = system.cleanupAvailability()
        microphones = system.microphones()
    }

    /// Settings appeared: reads what may have changed, starts watching the
    /// microphones (once, for the life of the app: a Core Audio listener
    /// cannot be taken back), and measures the data folder.
    func viewAppeared() {
        refresh()
        if !isWatchingMicrophones {
            isWatchingMicrophones = true
            system.observeMicrophones { [weak self] in
                guard let self else { return }
                microphones = system.microphones()
            }
        }
        Task { await measureData() }
    }

    // MARK: - Hotkey

    /// The key held to dictate. Another key saves it and tells the app,
    /// which restarts the event tap with it.
    var hotkey: HotkeyChoice {
        get { preferences.hotkey }
        set {
            guard newValue != preferences.hotkey else { return }
            preferences.hotkey = newValue
            hotkeyChanged()
        }
    }

    /// "Double-tap to dictate", off until switched on. The event tap reads
    /// it at each press.
    var doubleTapEnabled: Bool {
        get { preferences.doubleTapEnabled }
        set { preferences.doubleTapEnabled = newValue }
    }

    /// The line under "Double-tap to dictate", naming the key chosen.
    var doubleTapNote: String { Self.doubleTapNote(for: hotkey) }

    nonisolated static func doubleTapNote(for hotkey: HotkeyChoice) -> String {
        "Double-tap \(hotkey.displayName) to start, double-tap again to stop. Holding works as always."
    }

    /// Control-Option-V pastes the latest transcript, off until switched on.
    var pasteLastHotkeyEnabled: Bool {
        get { preferences.pasteLastHotkeyEnabled }
        set { preferences.pasteLastHotkeyEnabled = newValue }
    }

    // MARK: - Clean up transcripts

    /// The saved choice; the switch shows `cleanupRow`.
    var cleanupEnabled: Bool {
        get { preferences.cleanupEnabled }
        set { preferences.cleanupEnabled = newValue }
    }

    /// While cleanup cannot run, the switch is off and disabled with the
    /// reason beneath; the saved choice stays for when it can.
    var cleanupRow: ToggleRow {
        switch cleanupAvailability {
        case .available: ToggleRow(isOn: preferences.cleanupEnabled, isEnabled: true, note: nil)
        case .unavailable(let reason): ToggleRow(isOn: false, isEnabled: false, note: reason)
        }
    }

    // MARK: - Recordings to keep

    /// How many recordings are kept for replay and re-transcription, kept
    /// within `keptRecordingsRange`. A lower number prunes at once, with no
    /// dictation needed: the newest that many ordinary recordings stay, and
    /// pinned and failed transcripts keep theirs (Ruling T12-1). The data
    /// folder is measured again, as its size changed.
    var keptRecordings: Int {
        get { preferences.keptRecordings }
        set {
            let kept = min(max(newValue, Self.keptRecordingsRange.lowerBound), Self.keptRecordingsRange.upperBound)
            guard kept != preferences.keptRecordings else { return }
            preferences.keptRecordings = kept
            store.prune(keeping: kept)
            Task { await measureData() }
        }
    }

    /// Where − and + take "Recordings to keep": the next multiple of
    /// `keptRecordingsStep` down or up, within `keptRecordingsRange`.
    nonisolated static func keptRecordings(after value: Int, up: Bool) -> Int {
        let step = keptRecordingsStep
        let next = up ? (value / step + 1) * step : ((value + step - 1) / step - 1) * step
        return min(max(next, keptRecordingsRange.lowerBound), keptRecordingsRange.upperBound)
    }

    // MARK: - Microphone

    /// The microphone row's choice, by UID: the saved one while it is
    /// connected; nil, the system default, otherwise. Choosing one saves it
    /// and moves the recorder to it.
    var microphone: String? {
        get { Self.selection(saved: preferences.inputDeviceUID, connected: microphones) }
        set {
            preferences.inputDeviceUID = newValue
            chooseMicrophone(newValue)
        }
    }

    /// A saved microphone that is not connected shows as the system default,
    /// which the recorder then uses; the saved UID stays for when it is back.
    nonisolated static func selection(saved: String?, connected: [AudioInputDevice]) -> String? {
        guard let saved, connected.contains(where: { $0.uid == saved }) else { return nil }
        return saved
    }

    /// The name of the microphone the row shows.
    var microphoneName: String {
        microphones.first { $0.uid == microphone }?.name ?? Self.systemDefaultMicrophone
    }

    // MARK: - Sounds and login

    /// "Start and stop sounds", on until switched off; the recorder reads it
    /// at each start and stop.
    var soundsEnabled: Bool {
        get { preferences.soundsEnabled }
        set { preferences.soundsEnabled = newValue }
    }

    /// "Open at login": a dev build cannot register a login item, so there
    /// the switch is off and disabled with the reason beneath.
    var openAtLoginRow: ToggleRow {
        guard system.canOpenAtLogin() else {
            return ToggleRow(isOn: false, isEnabled: false, note: Self.openAtLoginUnavailable)
        }
        return ToggleRow(isOn: preferences.launchAtLogin, isEnabled: true, note: nil)
    }

    /// Saves the choice and registers or unregisters the login item; a dev
    /// build changes nothing.
    var openAtLogin: Bool {
        get { openAtLoginRow.isOn }
        set {
            guard system.canOpenAtLogin(), newValue != preferences.launchAtLogin else { return }
            preferences.launchAtLogin = newValue
            if !system.setOpenAtLogin(newValue) {
                Log.info("[SETTINGS] Could not turn open at login \(newValue ? "on" : "off")")
            }
        }
    }

    // MARK: - Data

    /// The data folder, with `~` for the home folder.
    var dataPath: String { Self.displayPath(of: dataDirectory) }

    nonisolated static func displayPath(of url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// The data folder's total size, or that it is being measured.
    var dataSizeText: String {
        dataSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Measuring…"
    }

    /// "Reveal in Finder": the data folder, selected in a Finder window.
    func revealData() {
        system.reveal(dataDirectory)
    }

    /// Measures the data folder off the main thread, then shows its size. A
    /// measurement started later wins over one still running.
    func measureData() async {
        sizeMeasurements += 1
        let measurement = sizeMeasurements
        let folder = dataDirectory
        let size = system.folderSize
        let bytes = await Task.detached(priority: .utility) { size(folder) }.value
        guard measurement == sizeMeasurements else { return }
        dataSize = bytes
    }

    /// Bytes the folder and everything in it take on disk, counted as the
    /// Models section counts a model (`totalFileAllocatedSize`). Slow for a
    /// big folder, so it is called off the main thread.
    nonisolated static func size(of folder: URL) -> Int64 {
        let key = URLResourceKey.totalFileAllocatedSizeKey
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [key])?.allObjects as? [URL] ?? []
        return files.reduce(0) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [key]))?.totalFileAllocatedSize ?? 0)
        }
    }
}
