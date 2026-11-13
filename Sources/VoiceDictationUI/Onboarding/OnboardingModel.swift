import AppKit
import Observation
import VoiceDictationLib

/// What the Welcome window asks of the system. The app passes `live`; tests
/// pass fakes, so no permission is requested, no System Settings pane opens
/// and `com.apple.HIToolbox` is never read.
struct OnboardingSystem {
    var microphoneGranted: () -> Bool
    /// True until the user has answered the system's microphone question.
    var microphoneUndetermined: () -> Bool
    var requestMicrophone: () -> Void
    var accessibilityGranted: () -> Bool
    /// Shows the system's question, which also lists the app in System Settings.
    var requestAccessibility: () -> Void
    /// `AppleFnUsageType` from `com.apple.HIToolbox`; nil when never set.
    var globeKeyUsageType: () -> Int?
    var openURL: (URL) -> Void
    /// Checks the permissions again (they otherwise poll every 5 s).
    var refreshPermissions: () -> Void

    @MainActor
    static func live(permissions: PermissionManager) -> OnboardingSystem {
        OnboardingSystem(
            microphoneGranted: { permissions.isMicrophoneGranted },
            microphoneUndetermined: { permissions.isMicrophoneUndetermined },
            requestMicrophone: { permissions.requestMicrophone() },
            accessibilityGranted: { permissions.isAccessibilityGranted },
            requestAccessibility: { permissions.requestAccessibility() },
            globeKeyUsageType: { PermissionManager.globeKeyUsageType() },
            openURL: { NSWorkspace.shared.open($0) },
            refreshPermissions: { permissions.checkPermissions() }
        )
    }
}

/// The Welcome window's checklist: what is left to set up before dictation
/// works, in the order to do it. It replaces the alerts the app used to show.
/// Use from the main thread.
@MainActor @Observable
public final class OnboardingModel {
    public struct Step: Identifiable, Equatable {
        public enum ID: CaseIterable, Sendable { case microphone, accessibility, globeKey, speechModel, tryIt }
        public enum State: Equatable { case done, needed, unavailable(String) }

        public let id: ID
        public let title: String
        public let state: State
        /// What to do, or what is happening.
        public let detail: String
        /// The button, when there is one to press.
        public let actionTitle: String?
    }

    /// System Settings panes. The extension ids and the `Privacy_…` anchors
    /// were read from the installed System Settings: the ids in the Info.plist
    /// of `SecurityPrivacyExtension.appex` and `KeyboardSettings.appex`, the
    /// anchors in the first's `PrivacySecurity.searchTerms`.
    enum Pane {
        static let microphone = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone")!
        static let accessibility = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!
        static let keyboard = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
    }

    /// Read again by `refresh()`; the other steps read live state, which the
    /// views track.
    private var globeKeyUsage: Int?   // nil, as macOS saves it for Do Nothing, until `refresh()`
    /// While the speech model downloads: how far, 0 to 1.
    private var downloadProgress: Double?
    private var downloadFailure: String?

    @ObservationIgnored private let system: OnboardingSystem
    @ObservationIgnored private let service: TranscriptionService
    @ObservationIgnored private let models: () -> [ModelDescriptor]
    @ObservationIgnored private let selected: () -> ModelID?
    @ObservationIgnored private let refreshModels: () async -> Void
    @ObservationIgnored private let preferences: PreferencesManager

    /// True once a dictation has pasted. Kept, so the window does not return
    /// at every launch.
    private var triedIt: Bool

    init(system: OnboardingSystem, service: TranscriptionService, models: @escaping () -> [ModelDescriptor],
         selected: @escaping () -> ModelID?, refreshModels: @escaping () async -> Void,
         preferences: PreferencesManager) {
        self.system = system
        self.service = service
        self.models = models
        self.selected = selected
        self.refreshModels = refreshModels
        self.preferences = preferences
        self.triedIt = preferences.onboardingTriedIt
    }

    // MARK: - Steps

    /// The steps that apply, in order. The Globe key step applies only while
    /// the hotkey is Globe (ruling P7): a right-hand key needs nothing changed
    /// in Keyboard settings.
    public var steps: [Step] { Step.ID.allCases.filter(applies).map(step) }

    public var isComplete: Bool { steps.allSatisfy { $0.state == .done } }

    /// The line under the window's title, naming the hotkey chosen.
    public var summary: String {
        let key = hotkeyName
        return isComplete ? "You are all set. Hold \(key) anywhere to dictate."
            : "A few things to set up before you can hold \(key) and talk."
    }

    /// The hotkey as the steps name it: "Globe", "Right Option"…
    private var hotkeyName: String { preferences.hotkey.displayName }

    func state(of id: Step.ID) -> Step.State { step(id).state }

    private func applies(_ id: Step.ID) -> Bool {
        id != .globeKey || preferences.hotkey == .globe
    }

    func step(_ id: Step.ID) -> Step {
        switch id {
        case .microphone:
            return system.microphoneGranted()
                ? Step(id: id, title: "Microphone", state: .done, detail: "VoiceDictation can hear you.", actionTitle: nil)
                : Step(id: id, title: "Microphone", state: .needed,
                       detail: "VoiceDictation needs the microphone to hear you.",
                       actionTitle: system.microphoneUndetermined() ? "Allow Microphone" : "Open Microphone Settings")
        case .accessibility:
            return system.accessibilityGranted()
                ? Step(id: id, title: "Accessibility", state: .done, detail: "VoiceDictation can paste for you.", actionTitle: nil)
                : Step(id: id, title: "Accessibility", state: .needed,
                       detail: "Needed to watch for the \(hotkeyName) key and paste. Switch VoiceDictation on in the list.",
                       actionTitle: "Open Accessibility Settings")
        case .globeKey:
            let usage = globeKeyUsage
            return usage == nil || usage == 0
                ? Step(id: id, title: "Globe key", state: .done, detail: "Pressing 🌐 does nothing else.", actionTitle: nil)
                : Step(id: id, title: "Globe key", state: .needed,
                       detail: "In Keyboard settings, set “Press 🌐 key to” to “Do Nothing”.",
                       actionTitle: "Open Keyboard Settings")
        case .speechModel:
            return speechModelStep()
        case .tryIt:
            return triedIt
                ? Step(id: id, title: "Try it", state: .done, detail: "Your first dictation pasted.", actionTitle: nil)
                : Step(id: id, title: "Try it", state: .needed,
                       detail: "Click into any text field, hold \(hotkeyName), say a sentence and let go.", actionTitle: nil)
        }
    }

    /// The step for the model dictation uses (ruling T14-1), not Apple
    /// Speech's alone. A new app often sees Apple's files as not downloaded
    /// though they are on the Mac; its Download then finishes at once.
    private func speechModelStep() -> Step {
        let title = "Speech model"
        guard let selected = selected(), let model = models().first(where: { $0.id == selected }) else {
            return Step(id: .speechModel, title: title, state: .needed, detail: "Checking the speech model…", actionTitle: nil)
        }
        if let progress = downloadProgress {
            return Step(id: .speechModel, title: title, state: .needed,
                        detail: "Downloading… \(Int((progress * 100).rounded()))%", actionTitle: nil)
        }
        switch model.state {
        case .ready:
            return Step(id: .speechModel, title: title, state: .done, detail: "\(model.displayName) is ready.", actionTitle: nil)
        case .notDownloaded:
            return Step(id: .speechModel, title: title, state: .needed,
                        detail: downloadFailure ?? "\(model.displayName) needs its files before it can listen.",
                        actionTitle: "Download \(model.displayName)")
        case .downloading(let progress):
            return Step(id: .speechModel, title: title, state: .needed,
                        detail: "Downloading… \(Int((progress * 100).rounded()))%", actionTitle: nil)
        case .preparing:
            return Step(id: .speechModel, title: title, state: .needed, detail: "Preparing…", actionTitle: nil)
        case .unavailable(let reason):
            return Step(id: .speechModel, title: title, state: .unavailable(reason), detail: reason, actionTitle: nil)
        }
    }

    // MARK: - Doing

    /// Re-reads what the system can change while the window is open, such as
    /// coming back from System Settings.
    func refresh() {
        system.refreshPermissions()
        globeKeyUsage = system.globeKeyUsageType()
    }

    /// Does the step's one action: asks, or opens the right System Settings pane.
    func open(_ id: Step.ID) {
        switch id {
        case .microphone:
            if system.microphoneUndetermined() {
                system.requestMicrophone()
            } else {
                system.openURL(Pane.microphone)
            }
        case .accessibility:
            system.requestAccessibility()
            system.openURL(Pane.accessibility)
        case .globeKey:
            system.openURL(Pane.keyboard)
        case .speechModel, .tryIt:
            break
        }
    }

    /// Downloads the model dictation uses, then lists the models again.
    func downloadSelectedModel() async {
        guard let id = selected(), downloadProgress == nil else { return }
        downloadFailure = nil
        downloadProgress = 0
        do {
            try await service.download(id) { [weak self] progress in
                Task { @MainActor in
                    if self?.downloadProgress != nil { self?.downloadProgress = progress }
                }
            }
        } catch {
            downloadFailure = "The download failed: \(error.localizedDescription)"
        }
        downloadProgress = nil
        await refreshModels()
    }

    /// The first dictation that pastes completes the last step.
    func recordOutcome(_ outcome: DictationOutcome) {
        guard outcome.status == .pasted, !triedIt else { return }
        triedIt = true
        preferences.onboardingTriedIt = true
    }

    /// Whether the Welcome window opens at launch: on the first run, and
    /// whenever a step is left.
    /// A speech model still preparing is the normal state at launch, so it
    /// does not count as a step left.
    func shouldShowAtLaunch(firstLaunch: Bool) -> Bool {
        let preparing = selected().flatMap { id in models().first { $0.id == id } }?.state == .preparing
        return firstLaunch || steps.contains { $0.state != .done && !($0.id == .speechModel && preparing) }
    }
}
