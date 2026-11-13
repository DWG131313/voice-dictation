import Foundation
import XCTest

/// Sparkle's settings in `App/Info.plist`, which XcodeGen writes from
/// `project.yml` (Task 26). Sparkle reads them as the app starts: a wrong one
/// shows an alert at every launch, or lets the app go online by itself.
final class UpdaterSettingsTests: XCTestCase {
    private static let infoPlist = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // VoiceDictationUITests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // the package
        .appendingPathComponent("App/Info.plist")

    /// No background network activity (Global Constraints). Sparkle 2.10.1
    /// asks about automatic checks at the second launch unless
    /// `SUEnableAutomaticChecks` is set, and while it is false schedules no
    /// check at all (`SPUUpdater.m`: `startUpdateCycle`,
    /// `scheduleNextUpdateCheckFiringImmediately:usingCurrentDate:`).
    func testUpdatesAreCheckedOnlyWhenDannyAsks() throws {
        let info = try info()
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, false)
        XCTAssertNotEqual(info["SUAutomaticallyUpdate"] as? Bool, true)
    }

    /// Sparkle will not start, and alerts at every launch, unless
    /// `SUPublicEDKey` decodes as 32 bytes of base64, the way `NSData` decodes
    /// it (`SUSignatures.m`; `SPUUpdater.m`,
    /// `checkIfConfiguredProperlyAndRequireFeedURL:…`). So until Danny makes
    /// the real key, the placeholder is shaped like one.
    func testSparkleCanStartWithThePublicKey() throws {
        let key = try XCTUnwrap(info()["SUPublicEDKey"] as? String)
        let decoded = try XCTUnwrap(NSData(base64Encoded: key.trimmingCharacters(in: .whitespacesAndNewlines)),
                                    "\(key) is not base64")
        XCTAssertEqual(decoded.length, 32)
    }

    /// "Check for Updates…" needs a feed, over HTTPS: the app makes no
    /// exception to App Transport Security.
    func testTheFeedIsAnHTTPSURL() throws {
        let feed = try XCTUnwrap(info()["SUFeedURL"] as? String)
        XCTAssertEqual(URL(string: feed)?.scheme, "https", feed)
    }

    private func info() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.infoPlist)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }
}
