import AppKit
import SwiftUI

/// The Welcome window: the steps left before dictation works, each with its
/// state in words and the one button that does it. Prism, as the other
/// windows: the title in Jost, the rest in Work Sans, the state words in DM
/// Mono, hairline-separated rows and square buttons. Its scene puts it on
/// black and keeps it dark, light mode or not (`VoiceDictationApp`).
public struct OnboardingView: View {
    private let model: AppModel
    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        let onboarding = model.onboarding
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("Welcome to VoiceDictation")
                    .font(Theme.Font.title())
                    .foregroundStyle(Theme.Color.text)
                    .accessibilityAddTraits(.isHeader)
                Text(onboarding.summary)
                    .font(Theme.Font.ui(14))
                    .foregroundStyle(Theme.Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, Theme.Space.md)
            ForEach(onboarding.steps) { step in
                row(step, onboarding: onboarding)
            }
        }
        .padding(.horizontal, Theme.Space.lg + Theme.Space.xs)
        .padding(.vertical, Theme.Space.lg)
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

    /// One step: its state word, its title and what to do, its button, and a
    /// hairline under it.
    private func row(_ step: OnboardingModel.Step, onboarding: OnboardingModel) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
                Text(Self.stateWord(step.state))
                    .font(Theme.Font.mono(12))
                    .foregroundStyle(step.state == .done ? Theme.Color.textMuted : Theme.Color.text)
                    .frame(width: 84, alignment: .leading)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(step.title)
                        .font(Theme.Font.ui(14, medium: true))
                        .foregroundStyle(Theme.Color.text)
                    Text(step.detail)
                        .font(Theme.Font.ui(12))
                        .foregroundStyle(Theme.Color.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.md)
                if let title = step.actionTitle {
                    Button(title) {
                        if step.id == .speechModel {
                            Task { await onboarding.downloadSelectedModel() }
                        } else {
                            onboarding.open(step.id)
                        }
                    }
                    .prismSecondaryButton()
                }
            }
            .padding(.vertical, Theme.Space.md)
            Hairline()
        }
        .accessibilityElement(children: .contain)
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

/// Opens the Welcome window, or the main window, when the app asks for it:
/// at launch, or when the app is opened again. Attached to
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
            .onChange(of: model.mainWindowRequests) { _, _ in openIfAsked() }
    }

    /// Welcome when a setup step is left; the main window when Danny opened
    /// the app, at launch or again while it runs.
    private func openIfAsked() {
        if model.takeWelcomeRequest() {
            NSApp.activate()
            openWindow(id: AppModel.welcomeWindowID)
        }
        if model.takeMainWindowRequest() {
            NSApp.activate()
            openWindow(id: AppModel.mainWindowID)
        }
    }
}
