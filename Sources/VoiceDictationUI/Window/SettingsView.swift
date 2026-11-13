import AppKit
import SwiftUI
import VoiceDictationLib

/// Settings (Task 24): one view for the main window's Settings section and
/// for the Settings scene (⌘,), both reading the app's `SettingsModel`, so
/// they always agree. Prism rows: the label, and any line beneath it, on the
/// left, the control on the right, and a hairline under each. The controls
/// are drawn here, square and black and white: the system's switch and pop-up
/// button would bring the accent colour, and the spectrum is the only colour
/// on a screen.
public struct SettingsView: View {
    private let model: AppModel
    @Environment(\.openWindow) private var openWindow

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        @Bindable var settings = model.settings
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings")
                    .font(Theme.Font.title())
                    .foregroundStyle(Theme.Color.text)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, Theme.Space.md)
                ForEach(SettingsModel.Row.allCases) { row in
                    self.row(row, settings: settings)
                }
            }
            .padding(.horizontal, Theme.Space.lg + Theme.Space.xs)
            .padding(.vertical, Theme.Space.lg)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { settings.viewAppeared() }
        // Back from System Settings (Apple Intelligence switched on, say).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refresh()
        }
    }

    @ViewBuilder
    private func row(_ row: SettingsModel.Row, settings: SettingsModel) -> some View {
        @Bindable var settings = settings
        switch row {
        case .hotkey:
            line(row) {
                PrismMenu(title: row.title, selection: $settings.hotkey, current: settings.hotkey.displayName,
                          options: HotkeyChoice.allCases.map { PrismMenu.Option(value: $0, name: $0.displayName) })
            }
        case .doubleTap:
            line(row, note: settings.doubleTapNote) {
                PrismSwitch(title: row.title, isOn: $settings.doubleTapEnabled)
            }
        case .pasteLastShortcut:
            line(row, note: SettingsModel.pasteLastNote) {
                PrismSwitch(title: row.title, isOn: $settings.pasteLastHotkeyEnabled)
            }
        case .cleanup:
            let cleanup = settings.cleanupRow
            line(row, note: cleanup.note) {
                PrismSwitch(title: row.title, isOn: Binding(get: { cleanup.isOn }, set: { settings.cleanupEnabled = $0 }),
                            isEnabled: cleanup.isEnabled)
            }
        case .keptRecordings:
            line(row, note: SettingsModel.keptRecordingsNote) {
                PrismStepper(title: row.title, value: settings.keptRecordings,
                             range: SettingsModel.keptRecordingsRange) { up in
                    settings.keptRecordings = SettingsModel.keptRecordings(after: settings.keptRecordings, up: up)
                }
            }
        case .microphone:
            line(row) {
                PrismMenu(title: row.title, selection: $settings.microphone, current: settings.microphoneName,
                          options: [PrismMenu.Option(value: nil, name: SettingsModel.systemDefaultMicrophone)]
                              + settings.microphones.map { PrismMenu.Option(value: $0.uid, name: $0.name) })
            }
        case .sounds:
            line(row) {
                PrismSwitch(title: row.title, isOn: $settings.soundsEnabled)
            }
        case .openAtLogin:
            let login = settings.openAtLoginRow
            line(row, note: login.note) {
                PrismSwitch(title: row.title, isOn: $settings.openAtLogin, isEnabled: login.isEnabled)
            }
        case .data:
            line(row, note: settings.dataPath) {
                HStack(spacing: Theme.Space.md) {
                    Text(settings.dataSizeText)
                        .font(Theme.Font.mono(12))
                        .foregroundStyle(Theme.Color.textMuted)
                    Button("Reveal in Finder") { settings.revealData() }
                        .prismSecondaryButton()
                }
            }
        case .welcomeGuide:
            Button(row.title) {
                // A menu bar app is not active when Settings is used from the
                // menu, so the window would open behind the app in front.
                NSApp.activate()
                openWindow(id: AppModel.welcomeWindowID)
            }
            .prismSecondaryButton()
            .padding(.top, Theme.Space.lg)
        }
    }

    /// One row: its label, the line beneath it if any, and its control.
    private func line<Control: View>(_ row: SettingsModel.Row, note: String? = nil,
                                     @ViewBuilder control: () -> Control) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Theme.Space.md) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(row.title)
                        .font(Theme.Font.ui(14, medium: true))
                        .foregroundStyle(Theme.Color.text)
                    if let note {
                        Text(note)
                            .font(Theme.Font.ui(12))
                            .foregroundStyle(Theme.Color.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Theme.Space.md)
                control()
            }
            .padding(.vertical, Theme.Space.md)
            Hairline()
        }
        .accessibilityElement(children: .contain)
    }
}

/// Prism's switch: square, black and white, never the accent colour. On is a
/// white bar with its black square at the right; off, a black bar outlined
/// in grey with its grey square at the left. A switch that cannot be changed
/// is faded, and says why in its row.
private struct PrismSwitch: View {
    let title: String
    @Binding var isOn: Bool
    var isEnabled = true

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Rectangle()
                    .fill(isOn ? Theme.Color.text : Theme.Color.bg)
                Rectangle()
                    .strokeBorder(isOn ? Theme.Color.text : Theme.Color.textMuted, lineWidth: 1)
                Rectangle()
                    .fill(isOn ? Theme.Color.bg : Theme.Color.textMuted)
                    .frame(width: 12, height: 12)
                    .padding(Theme.Space.xs)
            }
            .frame(width: 36, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// Prism's pop-up: the choice in a square box with a hairline border and a
/// muted chevron. The list is the system's menu, with a checkmark at the
/// choice.
private struct PrismMenu<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let name: String

        var id: Value { value }
    }

    let title: String
    @Binding var selection: Value
    /// The choice's name, shown in the box.
    let current: String
    let options: [Option]

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options) { option in
                    Text(option.name).tag(option.value)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: Theme.Space.sm) {
                Text(current)
                    .font(Theme.Font.ui(13))
                    .foregroundStyle(Theme.Color.text)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(Theme.Font.ui(10, medium: true))
                    .foregroundStyle(Theme.Color.textMuted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Theme.Space.sm + Theme.Space.xs)
            .padding(.vertical, Theme.Space.sm)
            .background(Theme.Color.bgElevated)
            .overlay(Rectangle().strokeBorder(Theme.Color.hairline, lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(current)
    }
}

/// Prism's stepper: − and + in square boxes either side of the number, in DM
/// Mono. Each press goes to the next ten (`SettingsModel.keptRecordings`);
/// an end that cannot be passed is faded.
private struct PrismStepper: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    /// A press: up, or down.
    let step: (Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            button("−", up: false, isEnabled: value > range.lowerBound)
            Text("\(value)")
                .font(Theme.Font.mono(13))
                .foregroundStyle(Theme.Color.text)
                .frame(minWidth: 48)
            button("+", up: true, isEnabled: value < range.upperBound)
        }
        .overlay(Rectangle().strokeBorder(Theme.Color.hairline, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(true)
            case .decrement: step(false)
            @unknown default: break
            }
        }
    }

    private func button(_ label: String, up: Bool, isEnabled: Bool) -> some View {
        Button {
            step(up)
        } label: {
            Text(label)
                .font(Theme.Font.ui(14, medium: true))
                .foregroundStyle(Theme.Color.text)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}
