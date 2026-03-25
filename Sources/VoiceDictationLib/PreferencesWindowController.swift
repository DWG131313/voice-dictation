import Cocoa

public protocol PreferencesWindowDelegate: AnyObject {
    func preferencesDidChangeModel(to modelId: String)
}

public class PreferencesWindowController: NSWindowController {
    public weak var preferencesDelegate: PreferencesWindowDelegate?

    private var modelPopup: NSPopUpButton!
    private var historyToggle: NSButton!
    private var modelStatusLabels: [String: NSTextField] = [:]
    private var modelManager: ModelManager?

    public convenience init(modelManager: ModelManager?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoiceDictation Preferences"
        window.center()
        window.isReleasedWhenClosed = false

        self.init(window: window)
        self.modelManager = modelManager
        setupUI()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let padding: CGFloat = 20
        var y: CGFloat = 240

        // Model section header
        let modelHeader = NSTextField(labelWithString: "Whisper Model")
        modelHeader.font = .boldSystemFont(ofSize: 13)
        modelHeader.frame = NSRect(x: padding, y: y, width: 360, height: 20)
        contentView.addSubview(modelHeader)
        y -= 30

        // Model popup
        modelPopup = NSPopUpButton(frame: NSRect(x: padding, y: y, width: 250, height: 25))
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged(_:))

        let currentModelId = PreferencesManager.shared.selectedModelId
        for model in PreferencesManager.WhisperModel.available {
            modelPopup.addItem(withTitle: model.displayName)
            modelPopup.lastItem?.representedObject = model.id as NSString

            if model.id == currentModelId {
                modelPopup.selectItem(withTitle: model.displayName)
            }
        }
        contentView.addSubview(modelPopup)
        y -= 25

        // Model descriptions
        for model in PreferencesManager.WhisperModel.available {
            let isDownloaded = modelManager?.isModelDownloaded(model) ?? false
            let status = isDownloaded ? "Downloaded" : "Not downloaded"
            let label = NSTextField(labelWithString: "\(model.id): \(model.sizeDescription) — \(status)")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: padding + 5, y: y, width: 360, height: 16)
            contentView.addSubview(label)
            modelStatusLabels[model.id] = label
            y -= 18
        }

        y -= 15

        // History section header
        let historyHeader = NSTextField(labelWithString: "Transcription History")
        historyHeader.font = .boldSystemFont(ofSize: 13)
        historyHeader.frame = NSRect(x: padding, y: y, width: 360, height: 20)
        contentView.addSubview(historyHeader)
        y -= 30

        // History toggle
        historyToggle = NSButton(checkboxWithTitle: "Keep transcription history", target: self, action: #selector(historyToggled(_:)))
        historyToggle.frame = NSRect(x: padding, y: y, width: 300, height: 20)
        historyToggle.state = PreferencesManager.shared.historyEnabled ? .on : .off
        contentView.addSubview(historyToggle)
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        guard let modelId = sender.selectedItem?.representedObject as? NSString else { return }
        preferencesDelegate?.preferencesDidChangeModel(to: modelId as String)
    }

    @objc private func historyToggled(_ sender: NSButton) {
        PreferencesManager.shared.historyEnabled = sender.state == .on
    }
}
