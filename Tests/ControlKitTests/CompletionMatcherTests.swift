import XCTest
@testable import ControlKit

final class CompletionMatcherTests: XCTestCase {
    private func complete(_ typed: String, _ value: String) -> String? {
        guard let end = CompletionMatcher.matchEnd(of: typed, in: value) else { return nil }
        let index = value.index(value.startIndex, offsetBy: end)
        return String(value[index...])
    }

    func testLiteralPrefixStillMatches() {
        XCTAssertEqual(complete("noel", "noeljsason@gmail.com"), "jsason@gmail.com")
        XCTAssertEqual(complete("https", "https://github.com/NoelSason"), "://github.com/NoelSason")
    }

    func testTypingTheHostSkipsTheScheme() {
        // The case that started this: nobody types "https://" to reach GitHub.
        XCTAssertEqual(complete("githu", "https://github.com/NoelSason"), "b.com/NoelSason")
        XCTAssertEqual(complete("github.com", "https://github.com/NoelSason"), "/NoelSason")
    }

    func testTypingAPathSegmentMatches() {
        XCTAssertEqual(complete("NoelS", "https://github.com/NoelSason"), "ason")
    }

    func testTypingTheMailHostMatches() {
        XCTAssertEqual(complete("gmail", "noeljsason@gmail.com"), ".com")
    }

    func testMatchesAreCaseInsensitive() {
        XCTAssertEqual(complete("NOELS", "https://github.com/NoelSason"), "ason")
        XCTAssertEqual(complete("githu", "https://GitHub.com/NoelSason"), "b.com/NoelSason")
    }

    func testMatchMustStartAtATokenBoundary() {
        // "ithub" sits mid-token; completing from there would be a coincidence,
        // not an intention.
        XCTAssertNil(CompletionMatcher.matchEnd(of: "ithub", in: "https://github.com/NoelSason"))
        XCTAssertNil(CompletionMatcher.matchEnd(of: "ason", in: "https://github.com/NoelSason"))
    }

    func testNoMatchWhenTypedTextIsAbsent() {
        XCTAssertNil(CompletionMatcher.matchEnd(of: "gitlab", in: "https://github.com/NoelSason"))
    }

    func testFullyTypedValueOffersNothing() {
        XCTAssertNil(CompletionMatcher.matchEnd(of: "noel@x.com", in: "noel@x.com"))
    }

    func testEmptyInputOffersNothing() {
        XCTAssertNil(CompletionMatcher.matchEnd(of: "", in: "anything"))
    }

    func testEarliestBoundaryWins() {
        // "com" appears twice; the first is the one the user is most likely on.
        XCTAssertEqual(complete("com", "https://com.example.com/x"), ".example.com/x")
    }
}
