import XCTest
@testable import ControlKit

/// Drives the Jev layer against recorded payloads — no network.
final class JevDecodingTests: XCTestCase {
    private let candidates = [
        VaultSchema.field(for: "given_name")!,
        VaultSchema.field(for: "preferred_name")!,
        VaultSchema.field(for: "family_name")!,
        VaultSchema.field(for: "card_number")!,
    ]

    private func answers(_ json: String) throws -> [String: JevAnswer] {
        try JevClient.parse(Data(json.utf8))
    }

    // MARK: Envelope

    func testSuccessfulEnvelopeYieldsTypedAnswers() throws {
        let parsed = try answers("""
        {"code":0,"message":"ok","data":{"answers":{
          "field":{"choice":"preferred_name","confidence":0.91,
                   "probabilities":{"preferred_name":0.91,"given_name":0.07,"family_name":0.02}},
          "is_sensitive":{"noul":0.02}
        }}}
        """)

        XCTAssertEqual(parsed["field"]?.choice, "preferred_name")
        XCTAssertEqual(parsed["field"]?.confidence, 0.91)
        XCTAssertEqual(parsed["is_sensitive"]?.noul, 0.02)
    }

    func testNonZeroCodeThrows() {
        XCTAssertThrowsError(try answers(#"{"code":401,"message":"invalid key","data":null}"#)) { error in
            guard case let JevError.api(code, message) = error else {
                return XCTFail("expected JevError.api, got \(error)")
            }
            XCTAssertEqual(code, 401)
            XCTAssertEqual(message, "invalid key")
        }
    }

    func testMalformedBodyThrowsDecoding() {
        XCTAssertThrowsError(try answers("not json")) { error in
            guard case JevError.decoding = error else {
                return XCTFail("expected JevError.decoding, got \(error)")
            }
        }
    }

    // MARK: Result mapping

    func testConfidentAnswerMapsToTheChosenKey() throws {
        let result = JevMatcher.result(
            from: try answers("""
            {"code":0,"message":"ok","data":{"answers":{
              "field":{"choice":"preferred_name","confidence":0.91,
                       "probabilities":{"preferred_name":0.91,"given_name":0.07}},
              "is_sensitive":{"noul":0.01}
            }}}
            """),
            candidates: candidates
        )

        XCTAssertEqual(result?.key, "preferred_name")
        XCTAssertEqual(result?.source, .jev)
        XCTAssertFalse(result?.looksSensitive ?? true)
        XCTAssertGreaterThanOrEqual(result?.confidence ?? 0, MatchThresholds.autoInsert)
        XCTAssertFalse(result?.alternatives.contains { $0.key == "preferred_name" } ?? true,
                       "the chosen key should not repeat in the alternatives")
    }

    func testNoMatchZeroesConfidenceButKeepsTheRanking() throws {
        let result = JevMatcher.result(
            from: try answers("""
            {"code":0,"message":"ok","data":{"answers":{
              "field":{"choice":"no_match","confidence":0.44,
                       "probabilities":{"given_name":0.30,"family_name":0.14}},
              "is_sensitive":{"noul":0.02}
            }}}
            """),
            candidates: candidates
        )

        XCTAssertEqual(result?.confidence, 0)
        XCTAssertLessThan(result?.confidence ?? 1, MatchThresholds.confirm, "must fall through to the picker")
        XCTAssertEqual(result?.key, "given_name", "ranking is still useful for ordering the picker")
    }

    func testSensitivityIsIndependentOfTheChoice() throws {
        let result = JevMatcher.result(
            from: try answers("""
            {"code":0,"message":"ok","data":{"answers":{
              "field":{"choice":"card_number","confidence":0.97,"probabilities":{"card_number":0.97}},
              "is_sensitive":{"noul":0.96}
            }}}
            """),
            candidates: candidates
        )

        XCTAssertTrue(result?.looksSensitive ?? false)
    }

    func testAnswersNamingAnUnknownKeyAreRejected() throws {
        // Guards against a model answer that isn't one of the options we offered.
        let result = JevMatcher.result(
            from: try answers("""
            {"code":0,"message":"ok","data":{"answers":{
              "field":{"choice":"passport_number","confidence":0.99,
                       "probabilities":{"passport_number":0.99,"given_name":0.01}},
              "is_sensitive":{"noul":0.9}
            }}}
            """),
            candidates: candidates
        )

        XCTAssertNotEqual(result?.key, "passport_number")
        XCTAssertEqual(result?.confidence, 0)
    }

    // MARK: Request construction — the privacy boundary

    func testRequestCarriesNoVaultValues() throws {
        let context = FieldContext(
            appName: "Google Chrome",
            bundleID: "com.google.Chrome",
            domain: "apply.example.edu",
            role: "AXTextField",
            label: "Preferred first name",
            nearbyText: ["Personal information"],
            isEmpty: true
        )

        let body = try JSONEncoder().encode(
            JevRequest(
                model: JevClient.defaultModel,
                state: JevMatcher.state(for: context),
                questions: JevMatcher.questions(for: candidates)
            )
        )
        let json = String(decoding: body, as: UTF8.self)

        // Only key names and their descriptions may appear.
        XCTAssertTrue(json.contains("preferred_name"))
        XCTAssertTrue(json.contains("no_match"))
        XCTAssertTrue(json.contains("Preferred first name"))
        XCTAssertTrue(json.contains("apply.example.edu"))
        XCTAssertLessThanOrEqual(body.count, JevClient.maxBodyBytes)
    }

    func testCandidateListIsCappedAndSeededByTheLocalRanking() {
        let context = FieldContext(appName: "Safari", bundleID: "com.apple.Safari", label: "Institution you attend")
        let selected = JevMatcher.candidates(
            from: VaultSchema.builtIn,
            localRanking: [ScoredKey(key: "university", score: 0.4)],
            context: context
        )

        XCTAssertLessThanOrEqual(selected.count, JevMatcher.maxCandidates)
        XCTAssertEqual(selected.first?.key, "university")
    }

    func testNearbyTextIsTruncatedBeforeItCanBlowTheBodyCap() {
        let context = FieldContext(
            appName: "Safari",
            bundleID: "com.apple.Safari",
            label: "City",
            nearbyText: Array(repeating: String(repeating: "x", count: 5000), count: 40)
        )

        guard case let .array(nearby)? = JevMatcher.state(for: context)["nearby_text"] else {
            return XCTFail("expected nearby_text array")
        }
        XCTAssertLessThanOrEqual(nearby.count, JevMatcher.maxNearbyText)
        for case let .string(text) in nearby {
            XCTAssertLessThanOrEqual(text.count, JevMatcher.maxNearbyTextLength)
        }
    }
}
