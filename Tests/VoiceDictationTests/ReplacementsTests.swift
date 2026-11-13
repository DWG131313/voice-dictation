import XCTest
@testable import VoiceDictationLib

/// Task 22: `Replacements.apply`, a pure function.
final class ReplacementsTests: XCTestCase {
    private func apply(_ rules: [(String, String)], to text: String) -> String {
        Replacements.apply(rules.map { Replacement(from: $0.0, to: $0.1) }, to: text)
    }

    func testCaseInsensitiveMatchInsertsReplacementAsWritten() {
        XCTAssertEqual(apply([("gv seventy", "GV70")], to: "my GV Seventy is here"), "my GV70 is here")
        XCTAssertEqual(apply([("tail scale", "Tailscale")], to: "TAIL SCALE and tail scale"), "Tailscale and Tailscale")
    }

    func testOnlyWholeWordsMatch() {
        XCTAssertEqual(apply([("cat", "dog")], to: "the category of a cat, cat."), "the category of a dog, dog.")
        XCTAssertEqual(apply([("cat", "dog")], to: "scatter"), "scatter")
    }

    func testLongestFromWinsOverShorter() {
        let rules = [("mac", "Mac"), ("mac mini", "Mac mini")]
        XCTAssertEqual(apply(rules, to: "my mac mini and a mac"), "my Mac mini and a Mac")
        XCTAssertEqual(apply(rules.reversed(), to: "my mac mini and a mac"), "my Mac mini and a Mac")
    }

    func testNoReplacementIsReplacedAgain() {
        XCTAssertEqual(apply([("a", "b"), ("b", "c")], to: "a"), "b")
        XCTAssertEqual(apply([("a", "b"), ("b", "c")], to: "a b"), "b c")
    }

    func testEmptyFromIsIgnored() {
        XCTAssertEqual(apply([("", "x"), ("  ", "y")], to: "hello there"), "hello there")
    }

    func testReplacementTextIsLiteral() {
        XCTAssertEqual(apply([("price", "$1 \\0 $0")], to: "the price"), "the $1 \\0 $0")
    }

    func testFromIsLiteralNotARegularExpression() {
        XCTAssertEqual(apply([("c.t", "x")], to: "cat c.t"), "cat x")
        XCTAssertEqual(apply([("c++", "C plus plus")], to: "I like c++ a lot"), "I like C plus plus a lot")
    }

    func testPhraseMatchesAcrossAnyWhitespace() {
        XCTAssertEqual(apply([("gv seventy", "GV70")], to: "my gv  seventy"), "my GV70")
    }

    func testPunctuationNextToAMatchIsKept() {
        XCTAssertEqual(apply([("gv seventy", "GV70")], to: "Is it a GV seventy? Yes, gv seventy."), "Is it a GV70? Yes, GV70.")
    }

    func testReplacementCanBeEmpty() {
        XCTAssertEqual(apply([("um", "")], to: "so um yes"), "so  yes")
    }

    func testNoRulesLeavesTextAlone() {
        XCTAssertEqual(apply([], to: "unchanged text"), "unchanged text")
    }

    func testFirstOfTwoRulesWithTheSameFromWins() {
        XCTAssertEqual(apply([("Foo", "one"), ("foo", "two")], to: "foo"), "one")
    }
}
