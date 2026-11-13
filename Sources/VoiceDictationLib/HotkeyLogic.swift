import Carbon.HIToolbox
import CoreGraphics
import Foundation
import IOKit.hidsystem

/// The key held to dictate (Task 23). Globe is the default; the right-hand
/// Option and Command keys suit a keyboard whose Globe key does something
/// else, and leave the left-hand ones free for shortcuts.
public enum HotkeyChoice: String, Codable, CaseIterable, Sendable {
    case globe, rightOption, rightCommand

    /// How the window and the logs name the key.
    public var displayName: String {
        switch self {
        case .globe: return "Globe"
        case .rightOption: return "Right Option"
        case .rightCommand: return "Right Command"
        }
    }

    /// The modifier flag the key puts on every event while it is down
    /// (CGEventTypes.h): Fn for Globe, Option or Command for a right-hand key.
    var modifierFlag: CGEventFlags {
        switch self {
        case .globe: return .maskSecondaryFn
        case .rightOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        }
    }

    /// What a `flagsChanged` event says about this key: whether it is now
    /// down, or nil when the event is about another key.
    ///
    /// Globe is read as before Task 23, from the Fn flag of every modifier
    /// change: Globe+Shift reports Globe down again, which changes nothing.
    /// A right-hand key is read only from its own key's events (Events.h:
    /// `kVK_RightOption` is 61, `kVK_RightCommand` 54), by the
    /// device-dependent bit IOLLEvent.h gives that side
    /// (`NX_DEVICERALTKEYMASK`, `NX_DEVICERCMDKEYMASK`). So the left-hand key
    /// (58, 55), which sets the same Option or Command flag, does nothing,
    /// and letting go of the right-hand one ends the dictation even while the
    /// left one is still down.
    func isDown(flagsChangedKeyCode keyCode: Int64, flags: CGEventFlags) -> Bool? {
        switch self {
        case .globe: break
        case .rightOption: guard keyCode == Int64(kVK_RightOption) else { return nil }
        case .rightCommand: guard keyCode == Int64(kVK_RightCommand) else { return nil }
        }
        return isDown(in: flags)
    }

    /// Whether this key is down in `flags`, an event's or the live state's
    /// (`ModifierKeyStrategy.liveFlags`): Fn for Globe, the right-hand key's
    /// own device bit otherwise, so the left-hand key down is this one up.
    func isDown(in flags: CGEventFlags) -> Bool {
        switch self {
        case .globe: return flags.contains(.maskSecondaryFn)
        case .rightOption: return flags.rawValue & UInt64(NX_DEVICERALTKEYMASK) != 0
        case .rightCommand: return flags.rawValue & UInt64(NX_DEVICERCMDKEYMASK) != 0
        }
    }
}

/// What a press or release of the hotkey does to the dictation.
public enum HotkeyAction: Equatable {
    /// Nothing: a down while the key is already down, a release after a
    /// cancel, the release of the press that stopped a hands-free recording
    /// or of the second tap that locked one, or any press or release while
    /// hands-free is locked but the one that stops it.
    case none
    /// A recording starts.
    case start
    /// The recording stops and is transcribed: a hold let go, or a double
    /// tap while hands-free is locked, at its second press.
    case stop
    /// The press was a tap with hands-free on, maybe the first of a double
    /// tap: its recording is thrown away.
    case discardTap
}

/// The hotkey's presses and releases, turned into what they do to the
/// dictation (Task 23), kept apart from the event tap so the rules can be
/// tested.
///
/// Hands-free off, every press records and its release stops, as before: a
/// quick tap makes a recording too short to keep, which the recorder's
/// 0.5 s rule throws away. Hands-free on, a hold dictates the same way. A
/// tap, a press let go within `tapMaximum`, is no dictation: its recording
/// is thrown away (`.discardTap`). A second tap that goes down within
/// `doubleTapWindow` of the first one's release locks instead: its recording
/// carries on after it is let go.
///
/// While locked (Danny's change, finding 9), a single press does nothing,
/// however long, and the recording goes on. A double tap stops it: a tap,
/// then a second press going down within `doubleTapWindow` of that tap's
/// release. The stop comes at that second press, whose release does
/// nothing, and the next quick tap is a first tap again. The tap that locked
/// is no first tap toward stopping: only taps made while locked count. This
/// holds whether hands-free is on or not, so a lock outlives the setting.
public struct TapTracker {
    public static let doubleTapWindow: TimeInterval = 0.35, tapMaximum: TimeInterval = 0.25

    /// Where the hotkey stands for the dictation.
    enum Hold: Equatable {
        /// Up, or down for the press that stopped a hands-free recording, for
        /// a dictation a key has cancelled, or for a press the tap missed.
        case none
        /// Down for the dictation its press started.
        case held
        /// A hands-free recording running until a double tap stops it. The
        /// key may be down, for a press that does nothing.
        case locked
    }

    /// Read at each release. The event tap sets it from the preference at
    /// each press and release, so a change takes effect at once.
    public var handsFreeEnabled: Bool
    /// Whether the key is down, as last reported.
    private var isDown = false
    /// When the press under way went down, while it holds the dictation it
    /// started.
    private var heldSince: TimeInterval?
    private var isLocked = false
    /// When the press under way went down, while locked: let go within
    /// `tapMaximum`, it is a tap, maybe the first of the double tap that
    /// stops the lock.
    private var lockedPressSince: TimeInterval?
    /// When the last tap was let go, while a second one could still lock,
    /// or, while locked, stop.
    private var lastTapEnd: TimeInterval?

    public init(handsFreeEnabled: Bool = false) {
        self.handsFreeEnabled = handsFreeEnabled
    }

    var hold: Hold {
        if isLocked { return .locked }
        return heldSince == nil ? .none : .held
    }

    /// The key went down at `time`, in seconds on a steady clock. A down
    /// while it is already down changes nothing.
    public mutating func down(at time: TimeInterval) -> HotkeyAction {
        guard !isDown else { return .none }
        isDown = true
        guard isLocked else {
            heldSince = time
            return .start
        }
        if let lastTapEnd, time - lastTapEnd <= Self.doubleTapWindow {
            // A double tap's second press: the lock ends, and this press's
            // release does nothing.
            isLocked = false
            self.lastTapEnd = nil
            return .stop
        }
        lockedPressSince = time
        return .none
    }

    /// The key went up at `time`. An up while it is up changes nothing.
    public mutating func up(at time: TimeInterval) -> HotkeyAction {
        guard isDown else { return .none }
        isDown = false
        if isLocked {
            // A press while locked does nothing. A tap may be the first of
            // the double tap that stops the lock; a longer press is none.
            let wasATap = lockedPressSince.map { time - $0 <= Self.tapMaximum } ?? false
            lastTapEnd = wasATap ? time : nil
            lockedPressSince = nil
            return .none
        }
        guard let start = heldSince else { return .none }
        heldSince = nil
        guard handsFreeEnabled, time - start <= Self.tapMaximum else {
            lastTapEnd = nil
            return .stop
        }
        if let lastTapEnd, start - lastTapEnd <= Self.doubleTapWindow {
            self.lastTapEnd = nil
            isLocked = true
            return .none
        }
        lastTapEnd = time
        return .discardTap
    }

    /// The dictation the hotkey held or locked is over: a key cancelled the
    /// hold, Escape cancelled everything, or the hands-free recording ended
    /// by itself. The key's release, or its next press, starts from nothing.
    mutating func cancel() {
        heldSince = nil
        isLocked = false
        lockedPressSince = nil
        lastTapEnd = nil
    }

    /// The tap missed events, re-enabled after macOS turned it off or
    /// rebuilt by the health check, and `down` is where the key is now, read
    /// from the live modifier state. A held dictation whose key is still down
    /// carries on; one whose release was missed stops now, and a late release
    /// does nothing. A hands-free lock carries on either way, since a press
    /// while locked does nothing. A press or release that went by unseen
    /// makes no tap: a press under way then, of unknown length, is no first
    /// tap. A press missed while nothing was under way starts nothing, and
    /// its release does nothing.
    mutating func catchUp(keyIsDown down: Bool) -> HotkeyAction {
        if down != isDown {
            lockedPressSince = nil
            lastTapEnd = nil
        }
        isDown = down
        guard hold == .held, !down else { return .none }
        heldSince = nil
        return .stop
    }

    /// Forgets every press, for an event tap taken down for good (listening
    /// stops, or another hotkey's tap replaces it): no release will be seen.
    /// Returns `.stop` when a dictation was held or locked, to end it as if
    /// the key had been let go; a release that does arrive afterwards
    /// changes nothing.
    mutating func reset() -> HotkeyAction {
        let wasDictating = hold != .none
        cancel()
        isDown = false
        return wasDictating ? .stop : .none
    }
}

/// How the event tap answers a key-down, or a mouse-down: what it does to
/// the dictation, and whether the event goes on to the app in front.
public enum KeyAction: Equatable, Sendable {
    /// Nothing happens and the event goes through untouched. That is any key
    /// or click while the hotkey is up and the app is not working; any key
    /// but a plain Escape, and any click, while hands-free is locked; Escape
    /// with Command, Control or Option (⌘⎋ and the like are other apps'
    /// shortcuts) while the hotkey is not held; Control-Option-V with its
    /// shortcut off; and the app's own Cmd+V, tagged `PasteEngine.eventTag`
    /// (a dictation's paste, or Paste last's), whatever the hotkey, the hold
    /// or the state.
    case none
    /// Another key, or a click, while the hotkey is held for a dictation:
    /// the hotkey was used as a modifier (Globe+Right Arrow is End, Right
    /// Command+click opens a link in a new tab), so this hold's dictation is
    /// cancelled with `cancelHold()`, which never reaches an earlier one, and
    /// the event goes through.
    case cancelHoldAndPass
    /// A plain Escape, with neither Command, Control nor Option (the held
    /// hotkey's own does not count), while the app is working (recording,
    /// transcribing or cleaning up), whether the hotkey is held, locked or
    /// up: everything is cancelled with `cancel()`, and Escape is swallowed.
    case cancelAllAndConsume
    /// Control-Option-V with its shortcut on: the key is swallowed, and the
    /// last transcript pastes (`pasteLast()`) once Control and Option are
    /// let go, or after `PasteLastWait.cap` at most (Ruling T23-1).
    case pasteLastAndConsume
    /// A key repeat of either of the two above, the key held down: swallowed,
    /// and nothing more happens. A held Escape cancels once, and a held
    /// Control-Option-V pastes once.
    case consume

    /// Whether the key is swallowed rather than going on to the app.
    var consumes: Bool {
        switch self {
        case .none, .cancelHoldAndPass: return false
        case .cancelAllAndConsume, .pasteLastAndConsume, .consume: return true
        }
    }
}

/// Paste last's shortcut, waiting for its keys to be let go (Ruling T23-1).
/// Control-Option-V is pressed with Control and Option down. Pasting then
/// would post the paste's Cmd+V while they still are, and an app that reads
/// the live modifier state would see them with it. So the tap swallows the V
/// and holds the request here until a modifier change shows neither Control
/// nor Option down. V's own key-up is too early: people let go of V before
/// the modifiers. Kept down, the paste goes anyway after `cap`. One paste per
/// wait: V pressed again before letting go still pastes once.
struct PasteLastWait {
    /// How long a paste waits at most, in seconds.
    static let cap: TimeInterval = 1

    /// The request waiting, by number; nil when none waits.
    private var waiting: Int?
    /// Requests made so far, which number the next one.
    private var requests = 0

    /// Control-Option-V: a paste now waits. Returns its number, for the
    /// timer that ends the wait at `cap`.
    mutating func request() -> Int {
        requests += 1
        waiting = requests
        return requests
    }

    /// A modifier change, to `flags`: whether the paste waiting goes now,
    /// with neither Control nor Option down.
    mutating func modifiersChanged(to flags: CGEventFlags) -> Bool {
        guard waiting != nil, flags.isDisjoint(with: [.maskControl, .maskAlternate]) else { return false }
        waiting = nil
        return true
    }

    /// The timer of request `number` ran out: whether that paste still
    /// waits, and so goes now, Control or Option still down.
    mutating func capReached(for number: Int) -> Bool {
        guard waiting == number else { return false }
        waiting = nil
        return true
    }

    /// The tap is taken down: the paste waiting is dropped.
    mutating func cancel() {
        waiting = nil
    }
}

// MARK: - The rules

/// The event tap's rules, kept here apart from the tap (`HotkeyManager.swift`)
/// so each is a pure static function, tested without a tap.
extension ModifierKeyStrategy {
    /// How the tap answers a modifier change: nothing unless it is about the
    /// chosen key (`HotkeyChoice.isDown`), then the tracker's answer. A
    /// hands-free recording that ended by itself (five minutes, an input
    /// change, a failure) leaves no lock: the press after it dictates,
    /// rather than counting toward a double tap that would stop a recording
    /// that is already over.
    static func action(forFlagsChanged keyCode: Int64, flags: CGEventFlags, at time: TimeInterval, choice: HotkeyChoice,
                       tracker: inout TapTracker, handsFree: Bool = false, state: DictationState) -> HotkeyAction {
        guard let isDown = choice.isDown(flagsChangedKeyCode: keyCode, flags: flags) else { return .none }
        tracker.handsFreeEnabled = handsFree
        guard isDown else { return tracker.up(at: time) }
        if tracker.hold == .locked, !isRecording(state) { tracker.cancel() }
        return tracker.down(at: time)
    }

    /// How the tap catches up after missing events: re-enabled after macOS
    /// turned it off, or rebuilt by the health check. `flags` is the live
    /// modifier state (`liveFlags`), and the chosen key's place in it decides
    /// (`TapTracker.catchUp`): a held dictation whose release was missed
    /// stops, and one whose key is still down carries on.
    static func action(forLiveFlags flags: CGEventFlags, choice: HotkeyChoice, tracker: inout TapTracker) -> HotkeyAction {
        tracker.catchUp(keyIsDown: choice.isDown(in: flags))
    }

    /// The modifier keys as they are now, from the HID system's two readings
    /// (CGEventSource.h): `flagsState`, its current flags
    /// (`CGEventSourceFlagsState`), and `keyState`, whether one key is down
    /// by its code (`CGEventSourceKeyState`). The header promises the flags
    /// only as "the current flags", and CGEventTypes.h names only the
    /// device-independent bits (the rest "reserved"), so a right-hand key's
    /// own device bit may be missing. Its key state, by code (61, 54), tells
    /// it from the left-hand key without that bit, and adds the bit. Either
    /// reading is enough; with neither, the key reads as up, and a held
    /// dictation stops rather than running on.
    static func liveFlags(flagsState: CGEventFlags, keyState: (CGKeyCode) -> Bool) -> CGEventFlags {
        var flags = flagsState
        if keyState(CGKeyCode(kVK_RightOption)) { flags.insert(CGEventFlags(rawValue: UInt64(NX_DEVICERALTKEYMASK))) }
        if keyState(CGKeyCode(kVK_RightCommand)) { flags.insert(CGEventFlags(rawValue: UInt64(NX_DEVICERCMDKEYMASK))) }
        return flags
    }

    /// How long before the tap handles an event its timestamp may lie and
    /// still be trusted, in seconds. macOS turns off a tap that stops
    /// answering (CGEvent.h, `CGEventTapEnable`), so a tap never holds an
    /// event this long, and a stamp this old is on another clock.
    static let eventTimeLimit: TimeInterval = 10

    /// When an event happened, in seconds on `systemUptime`'s clock, from its
    /// own timestamp, as the tap times presses: so a press the tap handles
    /// late, the main thread stalled, still counts for as long as it was held.
    /// CGEventTypes.h gives the stamp as "roughly, nanoseconds since
    /// startup", and AppKit reads it the same way (`NSEvent(cgEvent:)` makes
    /// 1e9 one second). Nil when the stamp cannot be trusted: none (0, as on
    /// an event made and never posted), after `now`, or more than
    /// `eventTimeLimit` before it, as a stamp on another clock would be.
    static func eventTime(stampedAt timestamp: CGEventTimestamp, handledAt now: TimeInterval) -> TimeInterval? {
        let time = TimeInterval(timestamp) / 1_000_000_000
        guard timestamp > 0, time <= now, now - time <= eventTimeLimit else { return nil }
        return time
    }

    /// How the tap answers a key-down, given the hotkey chosen, where it
    /// stands and what the app is doing: Task 9's decision, extended with the
    /// state. In order: the app's own Cmd+V goes through untouched; a plain
    /// Escape cancels everything while the app works, and is swallowed only
    /// then; any key while the hotkey is held cancels that hold,
    /// Control-Option-V and ⌘⎋ included; Control-Option-V with its shortcut
    /// on pastes the last transcript. A key repeat never cancels or pastes
    /// again.
    ///
    /// A plain Escape has neither Command, Control nor Option: ⌘⎋, ⌃⎋ and
    /// ⌥⎋ are other apps' shortcuts, and go through. While the hotkey is
    /// held, its own modifier is on the event (Right Command's Command), so
    /// that one does not count.
    static func action(forKeyDown keyCode: Int64, flags: CGEventFlags = [], isRepeat: Bool = false,
                       sourceUserData: Int64 = 0, choice: HotkeyChoice = .globe, hold: TapTracker.Hold,
                       state: DictationState, pasteLastShortcut: Bool = false) -> KeyAction {
        guard sourceUserData != PasteEngine.eventTag else { return .none }
        if keyCode == Int64(kVK_Escape), isWorking(state), isPlain(flags, besides: hold == .held ? choice.modifierFlag : []) {
            return isRepeat ? .consume : .cancelAllAndConsume
        }
        if hold == .held { return .cancelHoldAndPass }
        if pasteLastShortcut, keyCode == Int64(kVK_ANSI_V), isControlOption(flags) {
            return isRepeat ? .consume : .pasteLastAndConsume
        }
        return .none
    }

    /// The same, applied to `tracker`: a cancel ends the hotkey's hold or
    /// its hands-free lock, so the key's release, or its next press, starts
    /// from nothing.
    static func action(forKeyDown keyCode: Int64, flags: CGEventFlags = [], isRepeat: Bool = false,
                       sourceUserData: Int64 = 0, choice: HotkeyChoice = .globe, tracker: inout TapTracker,
                       state: DictationState, pasteLastShortcut: Bool = false) -> KeyAction {
        let answer = Self.action(forKeyDown: keyCode, flags: flags, isRepeat: isRepeat, sourceUserData: sourceUserData,
                                 choice: choice, hold: tracker.hold, state: state, pasteLastShortcut: pasteLastShortcut)
        switch answer {
        case .cancelHoldAndPass, .cancelAllAndConsume: tracker.cancel()
        case .none, .pasteLastAndConsume, .consume: break
        }
        return answer
    }

    /// How the tap answers a mouse button going down, whichever button: it
    /// always goes through. A click while the hotkey is held is the hotkey
    /// used as a modifier (Right Command+click opens a link in a new tab,
    /// Right Option+click is another app's own), so it cancels this hold's
    /// dictation with `cancelHold()`, as a key would: the key, held past the
    /// recorder's 0.5 s for a click, would otherwise record, and paste into
    /// the app clicked. While hands-free is locked the key is up, and a click
    /// cancels nothing. A click tagged as the app's own changes nothing,
    /// though the app posts none.
    static func action(forMouseDownWithUserData sourceUserData: Int64, hold: TapTracker.Hold) -> KeyAction {
        guard sourceUserData != PasteEngine.eventTag else { return .none }
        return hold == .held ? .cancelHoldAndPass : .none
    }

    /// The same, applied to `tracker`: a cancel ends the hold, so the key's
    /// release does nothing.
    static func action(forMouseDownWithUserData sourceUserData: Int64, tracker: inout TapTracker) -> KeyAction {
        let answer = Self.action(forMouseDownWithUserData: sourceUserData, hold: tracker.hold)
        if answer == .cancelHoldAndPass { tracker.cancel() }
        return answer
    }

    /// Escape cancels: something is being recorded, transcribed or cleaned up.
    private static func isWorking(_ state: DictationState) -> Bool {
        switch state {
        case .recording, .transcribing, .cleaning: return true
        case .idle, .preparingModel, .needsPermission, .error: return false
        }
    }

    private static func isRecording(_ state: DictationState) -> Bool {
        if case .recording = state { return true }
        return false
    }

    /// Neither Command, Control nor Option, other than `held`, the held
    /// hotkey's own; Shift, Caps Lock and Fn do not count.
    private static func isPlain(_ flags: CGEventFlags, besides held: CGEventFlags) -> Bool {
        flags.subtracting(held).isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate])
    }

    /// Control and Option without Command or Shift; Caps Lock and Fn do not
    /// matter.
    private static func isControlOption(_ flags: CGEventFlags) -> Bool {
        flags.contains([.maskControl, .maskAlternate]) && flags.isDisjoint(with: [.maskCommand, .maskShift])
    }
}
