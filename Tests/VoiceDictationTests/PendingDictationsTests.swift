import XCTest
@testable import VoiceDictationLib

final class PendingDictationsTests: XCTestCase {
    private func url(_ n: Int) -> URL { URL(fileURLWithPath: "/tmp/\(n).wav") }
    private func entry(_ n: Int) -> PendingDictation { PendingDictation(timer: StageTimer(), fileURL: url(n)) }

    func testPopsInOrderAndSkipsRemovedEntries() {
        var p = PendingDictations()
        (1...4).forEach { p.append(entry($0)) }
        p.remove(fileURL: url(2))
        XCTAssertEqual(p.popFirst()?.fileURL, url(1))
        XCTAssertEqual(p.popFirst()?.fileURL, url(3))
    }

    func testResetLeavesNothingToMispair() {
        var p = PendingDictations()
        (1...3).forEach { p.append(entry($0)) }
        p.reset()
        p.append(entry(9))
        XCTAssertEqual(p.popFirst()?.fileURL, url(9))
        XCTAssertNil(p.popFirst())
    }

    func testSetStemTargetsMatchingEntry() {
        var p = PendingDictations()
        p.append(entry(1)); p.append(entry(2))
        p.setStem("42", for: url(2))
        XCTAssertNil(p.popFirst()?.comparisonStem)
        XCTAssertEqual(p.popFirst()?.comparisonStem, "42")
    }
}
