import Cocoa
import Carbon.HIToolbox

public class PasteEngine: Pasting {
    private let pasteboard: NSPasteboard
    private let isTrusted: () -> Bool
    /// Delay before restoring clipboard. Slow apps (Electron) read the
    /// pasteboard a beat after receiving Cmd+V; restore too early and they
    /// paste the old contents.
    private let clipboardRestoreDelay: TimeInterval

    public convenience init() {
        self.init(pasteboard: .general, isTrusted: { AXIsProcessTrusted() }, restoreDelay: 0.5)
    }

    /// Tests pass a pasteboard of their own and say whether Accessibility
    /// access is granted.
    init(pasteboard: NSPasteboard, isTrusted: @escaping () -> Bool, restoreDelay: TimeInterval) {
        self.pasteboard = pasteboard
        self.isTrusted = isTrusted
        self.clipboardRestoreDelay = restoreDelay
    }

    public var frontmostAppName: String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    /// Pastes `text` into the frontmost app with Cmd+V, then puts back what
    /// was on the clipboard. Without Accessibility access macOS ignores the
    /// Cmd+V, so the text is left on the clipboard for the user to paste, and
    /// this returns false.
    public func paste(text: String) -> Bool {
        let pasteboard = self.pasteboard

        // 1. Snapshot everything on the clipboard — images, files, rich text —
        //    not just the plain string, so nothing the user copied is lost.
        let snapshot = Self.snapshot(of: pasteboard)

        // 2. Set transcribed text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        // 3. Simulate Cmd+V. If it cannot be sent, the text stays where the
        //    user can paste it.
        guard isTrusted() else {
            Log.info("[PASTE] Accessibility not granted — text left on the clipboard")
            return false
        }
        guard simulatePaste() else { return false }

        // 4. Restore clipboard after delay — unless the user has already
        //    copied something new in the meantime, which must win.
        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) {
            guard pasteboard.changeCount == ourChangeCount else { return }
            Self.restore(snapshot, to: pasteboard)
        }
        return true
    }

    // MARK: - Clipboard snapshot

    public struct Snapshot {
        public var items: [[NSPasteboard.PasteboardType: Data]]
    }

    public static func snapshot(of pasteboard: NSPasteboard) -> Snapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item -> [NSPasteboard.PasteboardType: Data] in
            var contents: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    contents[type] = data
                }
            }
            return contents
        }
        return Snapshot(items: items)
    }

    public static func restore(_ snapshot: Snapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = snapshot.items.compactMap { contents in
            guard !contents.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in contents {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    /// Sends Cmd+V; false if the events could not be made.
    private func simulatePaste() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down: Cmd + V
        guard let cmdVDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: true),
              let cmdVUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: false) else {
            Log.info("[PASTE] Failed to create Cmd+V events — text left on the clipboard")
            return false
        }

        cmdVDown.flags = .maskCommand
        cmdVUp.flags = .maskCommand

        cmdVDown.post(tap: .cghidEventTap)
        cmdVUp.post(tap: .cghidEventTap)
        return true
    }
}
