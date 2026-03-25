import Cocoa
import Carbon.HIToolbox

public class PasteEngine {
    /// Delay before restoring clipboard. Increase if paste doesn't work in slow apps (Electron).
    private let clipboardRestoreDelay: TimeInterval = 0.3

    public init() {}

    public func paste(text: String) {
        let pasteboard = NSPasteboard.general

        // 1. Save current clipboard (string only for v1)
        let previousString = pasteboard.string(forType: .string)

        // 2. Set transcribed text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 3. Simulate Cmd+V
        simulatePaste()

        // 4. Restore clipboard after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) {
            pasteboard.clearContents()
            if let previous = previousString {
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down: Cmd + V
        guard let cmdVDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: true),
              let cmdVUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: false) else {
            return
        }

        cmdVDown.flags = .maskCommand
        cmdVUp.flags = .maskCommand

        cmdVDown.post(tap: .cghidEventTap)
        cmdVUp.post(tap: .cghidEventTap)
    }
}
