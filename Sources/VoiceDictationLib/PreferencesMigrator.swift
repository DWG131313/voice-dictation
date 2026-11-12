import Foundation

/// Carries the old app's preferences over to the app bundle, once.
///
/// Before Task 13 the app ran as a bare binary, so its preferences are in the
/// `VoiceDictation` defaults domain. The app bundle keeps its own in
/// `com.danny.VoiceDictation`. On the bundle's first launch every key of the
/// old domain that the new one does not have yet is copied across, not only
/// the plan's five (Ruling P6), so a setting such as "Keep recordings for
/// comparison" or the history import's done flag carries over too. A key
/// already set in the new domain is never overwritten. The old domain is
/// left as it was.
public enum PreferencesMigrator {
    /// The bare binary's defaults domain.
    public static let legacyDomain = "VoiceDictation"
    /// Set in the new domain once the copy is done, so it happens only once.
    static let doneKey = "didMigrateLegacyDefaults"

    /// Copies the keys of the defaults domain named `legacyDomain` that
    /// `defaults` does not have into `defaults`, unless that was done before.
    /// Returns the keys copied.
    ///
    /// It takes the old domain's name rather than a `UserDefaults` for it:
    /// the old keys are read with `persistentDomain(forName:)`, which returns
    /// that domain's own keys only. `UserDefaults(suiteName:)` would also
    /// return the global domain's keys, and copy system-wide settings into
    /// the app's domain (Ruling T13-1).
    @discardableResult
    public static func migrateIfNeeded(fromDomain legacyDomain: String, to defaults: UserDefaults) -> [String] {
        migrateIfNeeded(legacy: defaults.persistentDomain(forName: legacyDomain), to: defaults)
    }

    /// `legacy` is the old domain's keys, nil when there is no such domain.
    /// With nothing to copy nothing is marked done, so an old domain that
    /// appears later is still copied once. Tests pass a dictionary and
    /// preferences kept in memory.
    @discardableResult
    static func migrateIfNeeded(legacy: [String: Any]?, to target: PreferenceStore) -> [String] {
        guard !target.bool(forKey: doneKey), let legacy, !legacy.isEmpty else { return [] }
        let copied = legacy.keys.sorted().filter { target.object(forKey: $0) == nil }
        for key in copied {
            target.set(legacy[key], forKey: key)
        }
        target.set(true, forKey: doneKey)
        Log.info("[PREFS] Copied \(copied.count) of \(legacy.count) setting(s) from the old app's preferences: "
                 + copied.joined(separator: ", "))
        return copied
    }
}
