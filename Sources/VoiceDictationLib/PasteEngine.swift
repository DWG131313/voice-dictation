import Cocoa
import Carbon.HIToolbox

public class PasteEngine: Pasting {
    private let pasteboard: NSPasteboard
    private let isTrusted: () -> Bool
    /// Delay before restoring clipboard. Slow apps (Electron) read the
    /// pasteboard a beat after receiving Cmd+V; restore too early and they
    /// paste the old contents.
    private let clipboardRestoreDelay: TimeInterval
    /// Posts Cmd+V to the app in front; false if it could not.
    private let postPaste: () -> Bool
    /// The put-back still waiting: what the clipboard held before the
    /// paste, and the change count the paste left. A paste made while one
    /// waits, with the clipboard still as that paste left it, puts back the
    /// same snapshot, not the earlier paste's text (code review, 2026-11-20).
    private var pendingRestore: (snapshot: Snapshot, changeCount: Int)?
    /// Counts the pastes, so only the latest one's put-back runs.
    private var pasteCount = 0

    public convenience init() {
        self.init(pasteboard: .general, isTrusted: { AXIsProcessTrusted() }, restoreDelay: 0.5,
                  postPaste: PasteEngine.postCmdV)
    }

    /// Tests pass a pasteboard of their own, say whether Accessibility
    /// access is granted, and stand in for the keystroke, so nothing is
    /// ever posted to the app in front.
    init(pasteboard: NSPasteboard, isTrusted: @escaping () -> Bool, restoreDelay: TimeInterval,
         postPaste: @escaping () -> Bool = { false }) {
        self.pasteboard = pasteboard
        self.isTrusted = isTrusted
        self.clipboardRestoreDelay = restoreDelay
        self.postPaste = postPaste
    }

    public var frontmostAppName: String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    /// How long one Accessibility call to the front app may wait, in seconds.
    /// These calls run on the main thread, where the hotkey's event tap runs
    /// too; a hung app must not hold it for the default 6 s. Set per element.
    public static let accessibilityMessagingTimeout: Float = 0.25
    private var accessibilityMessagingTimeout: Float { Self.accessibilityMessagingTimeout }

    /// The folder the front window is open on, as a project name. Needs
    /// Accessibility; nil without it. Reads only the window's `AXDocument`.
    public var frontmostFolder: String? {
        guard isTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, accessibilityMessagingTimeout)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let windowElement = window as! AXUIElement
        // A window's element does not take its app's timeout.
        AXUIElementSetMessagingTimeout(windowElement, accessibilityMessagingTimeout)
        var document: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement, kAXDocumentAttribute as CFString,
                                            &document) == .success else { return nil }
        return Self.projectName(fromDocument: document as? String,
                                home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// The project a window's `AXDocument` names: the last component of a
    /// file URL that is a folder. Nil for a document, the home folder, the
    /// root or anything that is not a file URL.
    static func projectName(fromDocument document: String?, home: URL) -> String? {
        guard let document, let url = URL(string: document), url.isFileURL, url.hasDirectoryPath else { return nil }
        func trimmed(_ path: String) -> String {
            var path = path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }
        let path = trimmed(url.path)
        guard path != "/", path != trimmed(home.path) else { return nil }
        let name = url.lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    /// Pastes `text` into the frontmost app with Cmd+V, then puts back what
    /// was on the clipboard. Without Accessibility access macOS ignores the
    /// Cmd+V, so the text is left on the clipboard for the user to paste, and
    /// this returns false.
    public func paste(text: String) -> Bool {
        let pasteboard = self.pasteboard

        // 1. Snapshot everything on the clipboard — images, files, rich text —
        //    not just the plain string, so nothing the user copied is lost.
        //    While an earlier paste's put-back waits and its text is still
        //    there, that put-back's snapshot is the one to keep.
        let snapshot: Snapshot
        if let pending = pendingRestore, pending.changeCount == pasteboard.changeCount {
            snapshot = pending.snapshot
        } else {
            snapshot = Self.snapshot(of: pasteboard)
        }

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
        guard postPaste() else { return false }

        // 4. Restore clipboard after delay — unless the user has already
        //    copied something new in the meantime, which must win, or a later
        //    paste has taken over the put-back.
        pasteCount += 1
        let thisPaste = pasteCount
        pendingRestore = (snapshot, ourChangeCount)
        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) { [weak self] in
            guard let self, self.pasteCount == thisPaste else { return }
            self.pendingRestore = nil
            guard pasteboard.changeCount == ourChangeCount else { return }
            Self.restore(snapshot, to: pasteboard)
        }
        return true
    }

    /// Puts `text` on the clipboard and leaves it there: no Cmd+V, and
    /// nothing is put back afterwards.
    public func copy(text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// The change count of the pasteboard `paste` and `copy` write.
    public var clipboardChangeCount: Int {
        pasteboard.changeCount
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

    // MARK: - Cmd+V

    /// What the app puts in the `.eventSourceUserData` of the Cmd+V it posts
    /// ("VDPASTE" in ASCII). The hotkey's event tap sees that keystroke too,
    /// and this is how it tells the app's own paste from a key the user pressed.
    static let eventTag: Int64 = 0x56_44_50_41_53_54_45

    /// The Cmd+V key-down and key-up `paste` posts, each tagged with
    /// `eventTag`. Nil if they could not be made.
    static func pasteKeystrokes() -> (down: CGEvent, up: CGEvent)? {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let cmdVDown = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: true),
              let cmdVUp = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: false) else {
            return nil
        }
        for event in [cmdVDown, cmdVUp] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: eventTag)
        }
        return (cmdVDown, cmdVUp)
    }

    /// Sends Cmd+V; false if the events could not be made.
    static func postCmdV() -> Bool {
        guard let keystrokes = Self.pasteKeystrokes() else {
            Log.info("[PASTE] Failed to create Cmd+V events — text left on the clipboard")
            return false
        }
        keystrokes.down.post(tap: .cghidEventTap)
        keystrokes.up.post(tap: .cghidEventTap)
        return true
    }
}
