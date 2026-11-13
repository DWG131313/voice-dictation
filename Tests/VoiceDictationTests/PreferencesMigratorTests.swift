import XCTest
@testable import VoiceDictationLib

/// The one-time copy of the bare binary's preferences (the `VoiceDictation`
/// domain) into the app bundle's. Each test hands the old domain's keys in
/// as a dictionary and keeps the new ones in memory (Ruling T13-1): no
/// `UserDefaults` suite, which would leave a file in `~/Library/Preferences`.
final class PreferencesMigratorTests: XCTestCase {
    private let target = MemoryPreferenceStore()

    func testCopiesOnce() {
        let legacy: [String: Any] = [
            "selectedModel": "small.en",
            "historyEnabled": false,
            "maxHistoryItems": 40,
            "launchAtLogin": true,
            "hasLaunchedBefore": true,
        ]

        let copied = PreferencesMigrator.migrateIfNeeded(legacy: legacy, to: target)

        XCTAssertEqual(Set(copied), Set(legacy.keys))
        XCTAssertEqual(target.string(forKey: "selectedModel"), "small.en")
        XCTAssertEqual(target.object(forKey: "historyEnabled") as? Bool, false)
        XCTAssertEqual(target.integer(forKey: "maxHistoryItems"), 40)
        XCTAssertTrue(target.bool(forKey: "launchAtLogin"))
        XCTAssertTrue(target.bool(forKey: "hasLaunchedBefore"))
        XCTAssertTrue(target.bool(forKey: "didMigrateLegacyDefaults"))

        // A later launch copies nothing, not even a key that is new in the
        // old domain since.
        XCTAssertEqual(PreferencesMigrator.migrateIfNeeded(legacy: ["keptRecordings": 5], to: target), [])
        XCTAssertNil(target.object(forKey: "keptRecordings"))
    }

    func testDoesNotOverwriteExisting() {
        target.set("tiny.en", forKey: "selectedModel")
        target.set(true, forKey: "historyEnabled")

        let copied = PreferencesMigrator.migrateIfNeeded(
            legacy: ["selectedModel": "small.en", "historyEnabled": false, "hasLaunchedBefore": true], to: target)

        XCTAssertEqual(copied, ["hasLaunchedBefore"])
        XCTAssertEqual(target.string(forKey: "selectedModel"), "tiny.en")
        XCTAssertEqual(target.object(forKey: "historyEnabled") as? Bool, true)
        XCTAssertTrue(target.bool(forKey: "hasLaunchedBefore"))
    }

    /// With no old domain there is nothing to copy, and nothing is marked
    /// done, so an old domain that turns up later is still copied once.
    func testNoLegacyDomainIsANoOp() {
        XCTAssertEqual(PreferencesMigrator.migrateIfNeeded(legacy: nil, to: target), [])
        XCTAssertNil(target.object(forKey: "didMigrateLegacyDefaults"))

        XCTAssertEqual(PreferencesMigrator.migrateIfNeeded(legacy: ["hasLaunchedBefore": true], to: target),
                       ["hasLaunchedBefore"])
        XCTAssertTrue(target.bool(forKey: "hasLaunchedBefore"))
    }

    /// Every key of the old domain is copied, not only the five above
    /// (Ruling P6): a setting such as the kept recordings carries over. So
    /// does one no version reads any more, such as Task 2's comparison
    /// switch, which Task 24 removed; it is harmless.
    func testCopiesKeysBeyondTheFive() {
        let copied = PreferencesMigrator.migrateIfNeeded(
            legacy: ["keepComparisonRecordings": true, "keptRecordings": 20,
                     "selectedModelID": "whisperKit/openai_whisper-base.en", "didImportLegacyHistory": true],
            to: target)

        XCTAssertEqual(Set(copied), ["keepComparisonRecordings", "keptRecordings", "selectedModelID",
                                     "didImportLegacyHistory"])
        let preferences = PreferencesManager(defaults: target)
        XCTAssertTrue(target.bool(forKey: "keepComparisonRecordings"))
        XCTAssertEqual(preferences.keptRecordings, 20)
        XCTAssertEqual(preferences.selectedModelID, ModelID(engine: .whisperKit, name: "openai_whisper-base.en"))
        XCTAssertTrue(target.bool(forKey: "didImportLegacyHistory"))
    }
}
