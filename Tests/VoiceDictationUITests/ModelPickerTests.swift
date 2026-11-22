import XCTest
import VoiceDictationLib
@testable import VoiceDictationUI

/// What both model pickers list (the sidebar's and the menu bar's): the speed
/// ladder, then Apple's two, then a model in use that is on neither; each with
/// ✓ or ↓ and a line that says what it trades (spec 2026-11-22).
final class ModelPickerTests: XCTestCase {
    private let tiny = ModelID(engine: .whisperCpp, name: "tiny.en")
    private let small = ModelID(engine: .whisperCpp, name: "small.en")
    private let kitTiny = ModelID(engine: .whisperKit, name: "tiny.en")
    private let kitBase = ModelID(engine: .whisperKit, name: "base.en")
    private let kitSmall = ModelID(engine: .whisperKit, name: "small.en")
    private let kitLarge = ModelID(engine: .whisperKit, name: "large-v3-turbo")

    private func d(_ id: ModelID, _ name: String, _ state: ModelDescriptor.State = .ready) -> ModelDescriptor {
        ModelDescriptor(id: id, displayName: name, detail: "", state: state)
    }

    /// All nine, in the order the app's engines list them.
    private func all(_ states: [ModelID: ModelDescriptor.State] = [:]) -> [ModelDescriptor] {
        [d(tiny, "Fastest", states[tiny] ?? .ready),
         d(.whisperCppBase, "Fast", states[.whisperCppBase] ?? .ready),
         d(small, "Slow", states[small] ?? .ready),
         d(.appleSpeech, "Apple Speech", states[.appleSpeech] ?? .ready),
         d(.appleDictation, "Apple Dictation", states[.appleDictation] ?? .ready),
         d(kitTiny, "WhisperKit tiny", states[kitTiny] ?? .ready),
         d(kitBase, "WhisperKit base", states[kitBase] ?? .ready),
         d(kitSmall, "WhisperKit small", states[kitSmall] ?? .ready),
         d(kitLarge, "Slowest", states[kitLarge] ?? .ready)]
    }

    private func entry(_ id: ModelID, in sections: [[ModelPicker.Entry]]) -> ModelPicker.Entry? {
        sections.joined().first { $0.id == id }
    }

    func testTheLadderComesFirstThenApple() {
        let sections = ModelPicker.sections(all(), selected: .whisperCppBase)
        XCTAssertEqual(sections.map { $0.map(\.name) },
                       [["Fastest", "Fast", "Slow", "Slowest"], ["Apple Speech", "Apple Dictation"]])
        XCTAssertEqual(sections.map { $0.map(\.line) },
                       [["more mistakes", "in use", "fewer mistakes", "fewest mistakes"],
                        ["built into macOS", "built into macOS"]])
        XCTAssertEqual(sections.joined().filter(\.isInUse).map(\.id), [.whisperCppBase])
    }

    func testMarksAndLinesFollowEachState() {
        let sections = ModelPicker.sections(all([small: .notDownloaded, kitLarge: .downloading(0.4),
                                                 .appleDictation: .unavailable("Not supported on this Mac")]),
                                            selected: .whisperCppBase)

        let fastest = entry(tiny, in: sections)
        XCTAssertEqual(fastest?.mark, .downloaded)
        XCTAssertEqual(fastest?.line, "more mistakes")
        XCTAssertEqual(fastest?.isEnabled, true)

        let slow = entry(small, in: sections)
        XCTAssertEqual(slow?.mark, .notDownloaded)
        XCTAssertEqual(slow?.line, "fewer mistakes")
        XCTAssertEqual(slow?.isEnabled, true, "one click downloads it, then switches to it")

        let slowest = entry(kitLarge, in: sections)
        XCTAssertEqual(slowest?.mark, .notDownloaded)
        XCTAssertEqual(slowest?.line, "downloading 40%")
        XCTAssertEqual(slowest?.isEnabled, false, "a model mid-download can't be chosen again")

        let dictation = entry(.appleDictation, in: sections)
        XCTAssertNil(dictation?.mark)
        XCTAssertEqual(dictation?.line, "Not supported on this Mac")
        XCTAssertEqual(dictation?.isEnabled, false)
    }

    func testTheMarksHaveTheirIcons() {
        XCTAssertEqual(ModelPicker.Mark.downloaded.systemImage, "checkmark")
        XCTAssertEqual(ModelPicker.Mark.notDownloaded.systemImage, "arrow.down.circle")
    }

    /// A state line wins over "in use" while it lasts (spec call 10).
    func testAPreparingModelInUseSaysPreparing() {
        let sections = ModelPicker.sections(all([kitLarge: .preparing]), selected: kitLarge)
        let slowest = entry(kitLarge, in: sections)
        XCTAssertEqual(slowest?.mark, .downloaded)
        XCTAssertEqual(slowest?.line, "preparing")
        XCTAssertEqual(slowest?.isEnabled, true)
        XCTAssertEqual(slowest?.isInUse, true)
    }

    /// macOS manages Apple's models, but their files can still be missing.
    func testAnAppleModelNotYetInstalledOffersItsDownload() {
        let sections = ModelPicker.sections(all([.appleSpeech: .notDownloaded]), selected: .whisperCppBase)
        let speech = entry(.appleSpeech, in: sections)
        XCTAssertEqual(speech?.mark, .notDownloaded)
        XCTAssertEqual(speech?.line, "built into macOS")
        XCTAssertEqual(speech?.isEnabled, true)
    }

    /// A model chosen before the ladder existed is never hidden.
    func testAModelOffTheLadderInUseIsListedLast() {
        let sections = ModelPicker.sections(all(), selected: kitBase)
        XCTAssertEqual(sections.count, 3)
        XCTAssertEqual(sections.last?.map(\.name), ["WhisperKit base"])
        XCTAssertEqual(sections.last?.first?.line, "in use")
        XCTAssertEqual(sections.last?.first?.isInUse, true)
        XCTAssertEqual(sections.first?.map(\.line), ["more mistakes", "the default", "fewer mistakes", "fewest mistakes"])
    }

    func testOffLadderModelsAreHiddenWhenNotInUse() {
        let names = ModelPicker.sections(all(), selected: .whisperCppBase).joined().map(\.name)
        XCTAssertFalse(names.contains { $0.hasPrefix("WhisperKit") })
    }

    /// Only what the engines list shows; an empty group is dropped.
    func testOnlyListedModelsShow() {
        let sections = ModelPicker.sections([d(.whisperCppBase, "Fast"), d(.appleSpeech, "Apple Speech")],
                                            selected: .appleSpeech)
        XCTAssertEqual(sections.map { $0.map(\.name) }, [["Fast"], ["Apple Speech"]])
        XCTAssertTrue(ModelPicker.sections([], selected: .whisperCppBase).isEmpty)
    }

    func testTheClosedBoxNamesTheModelInUse() {
        XCTAssertEqual(ModelPicker.title(all(), selected: .whisperCppBase), "Fast")
        XCTAssertEqual(ModelPicker.title(all(), selected: kitBase), "WhisperKit base")
        // Before the models are first listed, and with nothing chosen.
        XCTAssertEqual(ModelPicker.title([], selected: .whisperCppBase), "Model")
        XCTAssertEqual(ModelPicker.title(all(), selected: nil), "Model")
    }
}
