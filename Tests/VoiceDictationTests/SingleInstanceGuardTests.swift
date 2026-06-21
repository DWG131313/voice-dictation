import XCTest
@testable import VoiceDictationLib

final class SingleInstanceGuardTests: XCTestCase {
    var lockURL: URL!

    override func setUp() {
        lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vd-test-lock-\(UUID().uuidString).lock")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: lockURL)
    }

    func testFirstInstanceAcquiresLock() {
        let primary = SingleInstanceGuard(lockURL: lockURL)
        XCTAssertTrue(primary.tryAcquire())
        _ = primary // keep alive
    }

    func testSecondInstanceIsRejectedWhileFirstHolds() {
        let primary = SingleInstanceGuard(lockURL: lockURL)
        XCTAssertTrue(primary.tryAcquire())

        let secondary = SingleInstanceGuard(lockURL: lockURL)
        XCTAssertFalse(
            secondary.tryAcquire(),
            "A second instance must not acquire the lock while the first holds it"
        )

        _ = primary // ensure the first lock is still held during the assertion
    }

    func testLockIsReleasedWhenGuardDeallocated() {
        do {
            let primary = SingleInstanceGuard(lockURL: lockURL)
            XCTAssertTrue(primary.tryAcquire())
        } // primary deinits here, releasing the lock

        let secondary = SingleInstanceGuard(lockURL: lockURL)
        XCTAssertTrue(
            secondary.tryAcquire(),
            "The lock should be free again once the first guard is deallocated"
        )
        _ = secondary
    }
}
