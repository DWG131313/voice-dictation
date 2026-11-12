import XCTest
@testable import VoiceDictationLib

final class CoreTypesTests: XCTestCase {
    func testStorageKeyRoundTrip() {
        let id = ModelID(engine: .whisperKit, name: "large-v3-turbo")
        XCTAssertEqual(id.storageKey, "whisperKit/large-v3-turbo")
        XCTAssertEqual(ModelID(storageKey: "whisperKit/large-v3-turbo"), id)
    }

    func testStorageKeyRejectsGarbage() {
        XCTAssertNil(ModelID(storageKey: "nope"))
    }

    func testClipDurationAndPeak() {
        var samples = [Float](repeating: 0, count: 16_000)
        samples[100] = 0.5
        let clip = AudioClip(samples: samples)
        XCTAssertEqual(clip.duration, 1.0, accuracy: 0.0001)
        XCTAssertEqual(clip.peak, 0.5, accuracy: 0.0001)
    }
}
