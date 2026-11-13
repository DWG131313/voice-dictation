import XCTest
@testable import VoiceDictationLib

/// The rewrite guard (Task 21): cleanup may delete fillers and stammers and
/// change case and punctuation, and nothing else. The cases are the brief's,
/// word for word, and the rest of the 28 in the controller's reference
/// (`guard_reference.py`), which agrees with every answer here.
final class CleanupGuardTests: XCTestCase {
    // MARK: - Accepted

    func testAcceptsFillersAndPunctuation() {
        XCTAssertTrue(CleanupGuard.accepts(raw: "um so i think we should uh ship it",
                                           cleaned: "I think we should ship it."))
    }

    func testAcceptsCaseAndPunctuationOnly() {
        XCTAssertTrue(CleanupGuard.accepts(raw: "set up tailscale on the mac mini",
                                           cleaned: "Set up Tailscale on the Mac mini."))
    }

    func testAcceptsStammers() {
        XCTAssertTrue(CleanupGuard.accepts(raw: "the the build is is broken", cleaned: "The build is broken."))
        XCTAssertTrue(CleanupGuard.accepts(raw: "i i think so", cleaned: "I think so."))
    }

    func testAcceptsApostrophesHyphensAndASplitSentence() {
        XCTAssertTrue(CleanupGuard.accepts(raw: "i don't know, it's e-mail", cleaned: "I don't know. It's email."))
    }

    /// A filler set off by commas.
    func testAcceptsAFillerSetOffByCommas() {
        XCTAssertTrue(CleanupGuard.accepts(raw: "it was, like, really big and loud",
                                           cleaned: "It was really big and loud."))
        XCTAssertTrue(CleanupGuard.accepts(raw: "so, um, we ship the new build on friday, right?",
                                           cleaned: "We ship the new build on Friday."))
    }

    /// A whole filler phrase, set off.
    func testAcceptsAWholeFillerPhraseSetOff() {
        XCTAssertTrue(CleanupGuard.accepts(raw: "you know, i think it works", cleaned: "I think it works."))
    }

    /// Engine output that is already punctuated.
    func testAcceptsPunctuatedEngineOutput() {
        XCTAssertTrue(CleanupGuard.accepts(raw: "So, I think we should, uh, ship it.",
                                           cleaned: "I think we should ship it."))
    }

    /// A stammer across a disfluency.
    func testAcceptsAStammerAcrossADisfluency() {
        XCTAssertTrue(CleanupGuard.accepts(raw: "the uh the build is broken", cleaned: "The build is broken."))
    }

    /// The sample `testRealCleanerOnSample` gives the on-device model: "so"
    /// may go with the "um" beside it, or stay.
    func testAcceptsTheSampleSentence() {
        let raw = "um so the quick brown fox uh jumps over the lazy dog"
        XCTAssertTrue(CleanupGuard.accepts(raw: raw, cleaned: "The quick brown fox jumps over the lazy dog."))
        XCTAssertTrue(CleanupGuard.accepts(raw: raw, cleaned: "So the quick brown fox jumps over the lazy dog."))
    }

    // MARK: - Rejected

    func testRejectsAnAddedWord() {
        XCTAssertFalse(CleanupGuard.accepts(raw: "ship it friday", cleaned: "Ship it on Friday."))
    }

    func testRejectsAChangedWord() {
        XCTAssertFalse(CleanupGuard.accepts(raw: "we should ship it", cleaned: "We must ship it."))
    }

    func testRejectsReorderedWords() {
        XCTAssertFalse(CleanupGuard.accepts(raw: "call sam then email pat", cleaned: "Email Pat, then call Sam."))
    }

    func testRejectsADroppedWordThatIsNoFiller() {
        XCTAssertFalse(CleanupGuard.accepts(raw: "delete the old branch", cleaned: "Delete the branch."))
        // "of" is a filler only inside "kind of" and "sort of".
        XCTAssertFalse(CleanupGuard.accepts(raw: "a cup of coffee please", cleaned: "A cup coffee please."))
    }

    /// Nothing left, or an explanation instead of the text.
    func testRejectsAnEmptyResultAndAnExplanation() {
        XCTAssertFalse(CleanupGuard.accepts(raw: "um", cleaned: ""))
        for raw in ["set it up", "um so i think we should uh ship it", "here is the cleaned text"] {
            XCTAssertFalse(CleanupGuard.accepts(raw: raw, cleaned: "Here is the cleaned text: \(raw)"), raw)
        }
    }

    /// Reformatting is out of scope.
    func testRejectsReformatting() {
        XCTAssertFalse(CleanupGuard.accepts(raw: "twenty five dollars", cleaned: "$25."))
    }

    /// A filler word that is not set off.
    func testRejectsAFillerWordThatIsNotSetOff() {
        XCTAssertFalse(CleanupGuard.accepts(raw: "turn right at the light", cleaned: "Turn at the light."))
    }

    /// Single words of a filler phrase.
    func testRejectsSingleWordsOfAFillerPhrase() {
        XCTAssertFalse(CleanupGuard.accepts(raw: "i didn't say you were wrong", cleaned: "Didn't say were wrong."))
    }

    /// A filler phrase that is not set off.
    func testRejectsAFillerPhraseThatIsNotSetOff() {
        XCTAssertFalse(CleanupGuard.accepts(raw: "do you know the answer", cleaned: "Do the answer?"))
        XCTAssertFalse(CleanupGuard.accepts(raw: "what kind of car is it", cleaned: "What car is it?"))
        XCTAssertFalse(CleanupGuard.accepts(raw: "I mean what I say", cleaned: "What I say."))
    }

    /// Every copy of a repeat deleted.
    func testRejectsDeletingEveryCopyOfARepeat() {
        XCTAssertFalse(CleanupGuard.accepts(raw: "turn right right now", cleaned: "Turn now."))
    }

    /// A full stop is not a pause mark.
    func testRejectsAFillerAfterAFullStop() {
        XCTAssertFalse(CleanupGuard.accepts(raw: "Turn right. Then left at the light.",
                                            cleaned: "Turn. Then left at the light."))
    }

    /// A false start stays in (Danny, 2026-11-11).
    func testRejectsRemovingAFalseStart() {
        XCTAssertFalse(CleanupGuard.accepts(raw: "i went to the, i drove to the store", cleaned: "I drove to the store."))
    }

    /// Rule 5: at most 40% of the raw words may go, fillers or not.
    func testRejectsDeletingMoreThanFortyPercent() {
        XCTAssertFalse(CleanupGuard.accepts(raw: "um uh so, yes", cleaned: "Yes."), "3 of 4 deleted")
        XCTAssertTrue(CleanupGuard.accepts(raw: "um, uh, ship it now", cleaned: "Ship it now."), "2 of 5 is 40%")
    }

    // MARK: - Tokens

    func testTokensMarkPauses() {
        let tokens = CleanupGuard.tokens("so, um — it's e-mail")

        XCTAssertEqual(tokens.map(\.word), ["so", "um", "its", "email"])
        XCTAssertEqual(tokens.map(\.pauseBefore), [false, true, true, false])
        XCTAssertEqual(tokens.map(\.pauseAfter), [true, true, false, false])
    }

    /// An en dash and both ellipses are pause marks, a full stop is not, and
    /// a mark before the first word or after the last is no pause. Curly
    /// apostrophes go, like straight ones.
    func testTokensPauseMarksAtTheEdges() {
        let tokens = CleanupGuard.tokens("…Well – I’m ok... right. Fine…")

        XCTAssertEqual(tokens.map(\.word), ["well", "im", "ok", "right", "fine"])
        XCTAssertEqual(tokens.map(\.pauseBefore), [false, true, false, true, false])
        XCTAssertEqual(tokens.map(\.pauseAfter), [true, false, true, false, false])
        XCTAssertEqual(CleanupGuard.tokens(""), [])
        XCTAssertEqual(CleanupGuard.tokens(" , … "), [])
    }
}
