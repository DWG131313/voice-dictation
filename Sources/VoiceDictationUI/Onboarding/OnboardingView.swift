import AppKit
import SwiftUI

/// The Welcome window: the steps left before dictation works, each with its
/// state in words and the one button that does it.
public struct OnboardingView: View {
    private let model: AppModel
    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        let onboarding = model.onboarding
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to VoiceDictation").font(.title2.weight(.semibold))
                Text(onboarding.isComplete
                     ? "You are all set. Hold 🌐 anywhere to dictate."
                     : "A few things to set up before you can hold 🌐 and talk.")
                    .foregroundStyle(.secondary)
            }
            ForEach(onboarding.steps) { step in
                row(step, onboarding: onboarding)
                Divider()
            }
        }
        .padding(28)
        .frame(width: 520)
        .onAppear {
            onboarding.refresh()
            Task { await model.refreshModels() }
        }
        // Cheap: re-reads the permissions and the Globe key setting while open.
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in onboarding.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Back from System Settings.
            onboarding.refresh()
            Task { await model.refreshModels() }
        }
    }

    private func row(_ step: OnboardingModel.Step, onboarding: OnboardingModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Self.stateWord(step.state))
                .font(.caption.weight(.semibold))
                .frame(width: 84, alignment: .leading)
                .foregroundStyle(step.state == .done ? .secondary : .primary)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title).font(.headline)
                Text(step.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let title = step.actionTitle {
                Button(title) {
                    if step.id == .speechModel {
                        Task { await onboarding.downloadSelectedModel() }
                    } else {
                        onboarding.open(step.id)
                    }
                }
            }
        }
    }

    /// Status is words, never colour.
    static func stateWord(_ state: OnboardingModel.Step.State) -> String {
        switch state {
        case .done: return "Done"
        case .needed: return "To do"
        case .unavailable: return "Unavailable"
        }
    }
}

/// Opens the Welcome window when the app asks for it at launch. Attached to
/// the menu bar icon, the one view that exists at launch and has the
/// `openWindow` action.
public struct OpenWelcomeAtLaunch: ViewModifier {
    private let model: AppModel
    @Environment(\.openWindow) private var openWindow

    public init(model: AppModel) {
        self.model = model
    }

    public func body(content: Content) -> some View {
        content
            .onAppear { openIfAsked() }
            .onChange(of: model.welcomeRequests) { _, _ in openIfAsked() }
    }

    private func openIfAsked() {
        guard model.welcomeRequests > 0 else { return }
        NSApp.activate()
        openWindow(id: AppModel.welcomeWindowID)
    }
}
