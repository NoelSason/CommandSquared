import XCTest
@testable import ControlKit

/// The local matcher's accuracy as a number, and a ratchet on it.
///
/// Every matcher bug that reached the user was a fix for one label that quietly
/// broke others, found by hand afterwards. This runs every labelled case in
/// `Fixtures/MatcherEval/` through `LocalMatcher`, prints a report, and fails if
/// any case that the accepted snapshot got right is now wrong.
///
/// The snapshot stores *predictions*, not verdicts. Correcting a label re-scores
/// the snapshot too, so before/after comparisons stay fair; adding a hard case
/// lowers the headline number without failing anything. Only a regression on an
/// existing case fails.
///
///     make eval          # print the report
///     make eval-accept   # accept current predictions as the new snapshot
final class MatcherEvalTests: XCTestCase {

    // MARK: Fixture shape

    struct Case: Decodable {
        enum Input: String, Decodable {
            /// Text as the Accessibility API reports it at fill time.
            case label
            /// An HTML field name, as the browser importer sees it.
            case fieldName
        }

        let id: String
        let input: Input
        let label: String?
        let placeholder: String?
        let help: String?
        let nearby: [String]?
        /// Every acceptable key. Empty means the field must match nothing.
        let expect: [String]
        let note: String?
        /// The fixture file the case came from.
        var source = ""

        private enum CodingKeys: String, CodingKey {
            case id, input, label, placeholder, help, nearby, expect, note
        }
    }

    struct Prediction: Codable, Equatable {
        let key: String?
        let score: Double
    }

    struct Snapshot: Codable {
        var cases: [String: Prediction]
    }

    enum Outcome: String {
        case correct, wrong, missed
    }

    struct Result {
        let testCase: Case
        let prediction: Prediction
        let outcome: Outcome
        let holdout: Bool

        /// Wrong and confident enough to fill without asking — a silent bad fill.
        var harmful: Bool {
            outcome == .wrong && prediction.score >= MatchThresholds.autoInsert
        }
    }

    // MARK: Running a case

    private static let matcher = LocalMatcher()

    /// The hints a Berkeley student's vault produces. Only label cases get them;
    /// the importer runs without hints, so field-name cases do too.
    private static let hints = MatchHints(
        university: "University of California, Berkeley",
        schoolEmail: "student@berkeley.edu"
    )

    /// Every built-in key holds a value, so nothing is hidden by an empty vault.
    private static let fillable = Set(VaultSchema.builtIn.filter { !$0.isSnippet }.map(\.key))

    static func context(for testCase: Case) -> FieldContext {
        switch testCase.input {
        case .label:
            FieldContext(
                appName: "Safari",
                bundleID: "com.apple.Safari",
                domain: "example.com",
                role: "AXTextField",
                label: testCase.label,
                placeholder: testCase.placeholder,
                helpText: testCase.help,
                nearbyText: testCase.nearby ?? []
            )
        case .fieldName:
            VaultImporter.context(forFieldName: testCase.label ?? "")
        }
    }

    static func hints(for testCase: Case) -> MatchHints {
        testCase.input == .label ? hints : MatchHints()
    }

    /// The top candidate, if it clears the lowest bar at which Control proposes
    /// anything at all. Below that the picker opens with no preselection, which
    /// is a miss, not a guess.
    static func predict(_ testCase: Case) -> Prediction {
        let top = matcher.match(context(for: testCase), fillable: fillable, hints: hints(for: testCase)).first
        guard let top, top.score >= MatchThresholds.confirm else {
            return Prediction(key: nil, score: top?.score ?? 0)
        }
        return Prediction(key: top.key, score: top.score)
    }

    static func outcome(of prediction: Prediction, for testCase: Case) -> Outcome {
        guard let key = prediction.key else {
            return testCase.expect.isEmpty ? .correct : .missed
        }
        return testCase.expect.contains(key) ? .correct : .wrong
    }

    /// About a quarter of cases, chosen by a stable hash of the id. The report
    /// gives only totals for these, so rules cannot be tuned against them case
    /// by case. (`hashValue` is seeded per process, hence FNV-1a.)
    static func isHoldout(_ id: String) -> Bool {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash % 4 == 0
    }

    // MARK: The test

    func testMatcherAccuracy() throws {
        let cases = try Self.loadCases()
        try checkFixtures(cases)

        let results = cases.map { testCase in
            let prediction = Self.predict(testCase)
            return Result(
                testCase: testCase,
                prediction: prediction,
                outcome: Self.outcome(of: prediction, for: testCase),
                holdout: Self.isHoldout(testCase.id)
            )
        }

        let snapshot = try? Self.loadSnapshot()
        print(Self.report(results, snapshot: snapshot))

        if ProcessInfo.processInfo.environment["CONTROL_EVAL_ACCEPT"] == "1" {
            try Self.writeSnapshot(results)
            return
        }

        guard let snapshot else {
            XCTFail("No accepted snapshot yet. Run `make eval-accept` to record one.")
            return
        }

        // A case the snapshot got right must still be right.
        var regressed: [String] = []
        var harmfulBefore = 0
        var harmfulNow = 0
        for result in results {
            guard let before = snapshot.cases[result.testCase.id] else { continue }
            let beforeOutcome = Self.outcome(of: before, for: result.testCase)
            if beforeOutcome == .correct, result.outcome != .correct {
                regressed.append("\(result.testCase.id): \(Self.describe(before)) → \(Self.describe(result.prediction))")
            }
            if beforeOutcome == .wrong, before.score >= MatchThresholds.autoInsert { harmfulBefore += 1 }
            if result.harmful { harmfulNow += 1 }
        }

        XCTAssertTrue(
            regressed.isEmpty,
            "\(regressed.count) case(s) the snapshot got right are now wrong:\n  " + regressed.joined(separator: "\n  ")
        )
        XCTAssertLessThanOrEqual(
            harmfulNow, harmfulBefore,
            "Silent wrong fills went from \(harmfulBefore) to \(harmfulNow)."
        )
    }

    /// Every input on the hand-test page is either a case or deliberately not one.
    func testEveryHandTestFieldHasACase() throws {
        let cases = try Self.loadCases()
        let formIDs = Set(cases.filter { $0.source == "form" }.map { String($0.id.dropFirst("form.".count)) })

        let html = try String(contentsOf: Self.repoRoot.appendingPathComponent("QA/test-form.html"), encoding: .utf8)
        let tags = try NSRegularExpression(pattern: #"<(?:input|textarea)\b[^>]*>|<div\b[^>]*contenteditable[^>]*>"#)
        let idAttribute = try NSRegularExpression(pattern: #"\bid="([^"]+)""#)

        for match in tags.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            let tag = String(html[Range(match.range, in: html)!])
            guard let idMatch = idAttribute.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else {
                XCTFail("Give this hand-test field an id so it can have an eval case: \(tag)")
                continue
            }
            let id = String(tag[Range(idMatch.range(at: 1), in: tag)!])
            guard Self.excludedFormFields[id] == nil else { continue }
            XCTAssertTrue(formIDs.contains(id), "QA/test-form.html has #\(id) but form.json has no form.\(id) case")
        }
    }

    /// Fields refused before matching ever runs. The matcher has no say in them,
    /// so they are covered where the refusal lives, not here.
    private static let excludedFormFields = [
        "pw": "secure field — FieldContext.isSecureField",
        "pw2": "secure field — FieldContext.isSecureField",
        "hidden-zero": "hidden field — FieldVisibilityTests",
        "hidden-offscreen": "hidden field — FieldVisibilityTests",
        "hidden-tiny": "hidden field — FieldVisibilityTests",
    ]

    private func checkFixtures(_ cases: [Case]) throws {
        var seen = Set<String>()
        let known = Self.fillable
        for testCase in cases {
            XCTAssertTrue(seen.insert(testCase.id).inserted, "duplicate case id \(testCase.id)")
            for key in testCase.expect {
                XCTAssertTrue(known.contains(key), "\(testCase.id) expects unknown key \(key)")
            }
            let text = [testCase.label, testCase.placeholder, testCase.help].compactMap { $0 }
            XCTAssertFalse(text.isEmpty, "\(testCase.id) has nothing to match on")
        }
    }

    // MARK: Report

    static func report(_ results: [Result], snapshot: Snapshot?) -> String {
        var lines = ["=== MATCHER EVAL ==="]

        func summary(_ name: String, _ subset: [Result]) -> String {
            let count = subset.count
            let correct = subset.filter { $0.outcome == .correct }.count
            let wrong = subset.filter { $0.outcome == .wrong }.count
            let missed = subset.filter { $0.outcome == .missed }.count
            let harmful = subset.filter(\.harmful).count
            return name.padding(toLength: 13, withPad: " ", startingAt: 0)
                + pad(count, 5) + pad(correct, 9) + pad(wrong, 7) + pad(missed, 8) + pad(harmful, 9)
                + "   " + percent(correct, count)
        }

        lines.append("")
        lines.append("source         cases  correct  wrong  missed  harmful   accuracy")
        lines.append(summary("all", results))
        for source in sources {
            let subset = results.filter { $0.testCase.source == source }
            if !subset.isEmpty { lines.append(summary(source, subset)) }
        }
        lines.append(summary("dev", results.filter { !$0.holdout }))
        lines.append(summary("holdout", results.filter(\.holdout)))
        lines.append("harmful = wrong and confident enough to fill without asking")

        let positives = results.filter { !$0.testCase.expect.isEmpty && $0.outcome == .correct }
        let silent = positives.filter { $0.prediction.score >= MatchThresholds.autoInsert }.count
        lines.append("of \(positives.count) correct answers, \(silent) fill without asking (\(percent(silent, positives.count)))")

        // Confusion pairs, dev only.
        var pairs: [String: Int] = [:]
        for result in results where !result.holdout && result.outcome != .correct {
            let expected = result.testCase.expect.first.map {
                result.testCase.expect.count > 1 ? "\($0)+" : $0
            } ?? "nothing"
            pairs["\(expected) → \(result.prediction.key ?? "nothing")", default: 0] += 1
        }
        if !pairs.isEmpty {
            lines.append("")
            lines.append("top confusions (dev, expected → got)")
            for (pair, count) in pairs.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }).prefix(20) {
                lines.append("  \(pad(count, 4))  \(pair)")
            }
        }

        if let snapshot {
            lines.append("")
            lines.append(comparison(results, snapshot: snapshot))
        }

        // Every dev failure, with what fired, grouped by source.
        let failures = results.filter { !$0.holdout && $0.outcome != .correct }
        if !failures.isEmpty {
            lines.append("")
            lines.append("dev failures (\(failures.count))")
            for result in failures.sorted(by: { ($0.testCase.source, $0.testCase.id) < ($1.testCase.source, $1.testCase.id) }) {
                let expected = result.testCase.expect.isEmpty ? "nothing" : result.testCase.expect.joined(separator: "|")
                lines.append("  [\(result.outcome.rawValue)] \(result.testCase.id)")
                lines.append("      want \(expected), got \(describe(result.prediction))")
                for evidence in trace(result.testCase).prefix(4) {
                    lines.append("      · \(evidence.key) \(String(format: "%.2f", evidence.score)) — \(evidence.reason)")
                }
            }
        }

        lines.append("=== END ===")
        return lines.joined(separator: "\n")
    }

    private static func comparison(_ results: [Result], snapshot: Snapshot) -> String {
        var shared = 0
        var correctBefore = 0
        var correctNow = 0
        var fixed = 0
        var regressed: [String] = []
        var added = 0
        for result in results {
            guard let before = snapshot.cases[result.testCase.id] else {
                added += 1
                continue
            }
            shared += 1
            let beforeCorrect = outcome(of: before, for: result.testCase) == .correct
            let nowCorrect = result.outcome == .correct
            if beforeCorrect { correctBefore += 1 }
            if nowCorrect { correctNow += 1 }
            if !beforeCorrect, nowCorrect { fixed += 1 }
            if beforeCorrect, !nowCorrect {
                let split = result.holdout ? " [holdout — don't tune on it]" : ""
                regressed.append("  \(result.testCase.id): \(describe(before)) → \(describe(result.prediction))\(split)")
            }
        }
        var line = "vs snapshot: \(percent(correctBefore, shared)) → \(percent(correctNow, shared)) on \(shared) shared cases"
            + " · fixed \(fixed) · regressed \(regressed.count)"
        if added > 0 { line += " · \(added) new case(s) not in the snapshot" }
        // Regressions are listed even for holdout cases: each one fails the test,
        // so each one has to be findable.
        return ([line] + regressed.sorted()).joined(separator: "\n")
    }

    private static func trace(_ testCase: Case) -> [LocalMatcher.Evidence] {
        matcher.trace(context(for: testCase), fillable: fillable, hints: hints(for: testCase))
            .sorted { $0.score > $1.score }
    }

    private static func describe(_ prediction: Prediction) -> String {
        guard let key = prediction.key else { return "nothing" }
        return "\(key) (\(String(format: "%.2f", prediction.score)))"
    }

    private static func pad(_ number: Int, _ width: Int) -> String {
        let text = String(number)
        return String(repeating: " ", count: max(0, width - text.count)) + text
    }

    private static func percent(_ part: Int, _ whole: Int) -> String {
        guard whole > 0 else { return "—" }
        return String(format: "%.1f%%", 100 * Double(part) / Double(whole))
    }

    // MARK: Files

    /// Fixtures are read from the source tree rather than the test bundle, so
    /// that the snapshot can be written back to the same place it is read from.
    private static let fixtureDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/MatcherEval")

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let snapshotURL = fixtureDirectory.appendingPathComponent("snapshot.json")

    /// One fixture file per source, reported separately. `handwritten` is kept
    /// apart because it was written by the same hand that tunes the rules.
    private static let sources = ["form", "regression", "handwritten", "browser"]

    static func loadCases() throws -> [Case] {
        let decoder = JSONDecoder()
        return try sources.flatMap { source in
            let url = fixtureDirectory.appendingPathComponent("\(source).json")
            return try decoder.decode([Case].self, from: Data(contentsOf: url)).map { testCase in
                var testCase = testCase
                testCase.source = source
                return testCase
            }
        }
    }

    private static func loadSnapshot() throws -> Snapshot {
        try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: snapshotURL))
    }

    private static func writeSnapshot(_ results: [Result]) throws {
        var cases: [String: Prediction] = [:]
        for result in results {
            // Three decimals: enough to see a score move, few enough to keep
            // the diff about keys rather than floating-point noise.
            let score = (result.prediction.score * 1000).rounded() / 1000
            cases[result.testCase.id] = Prediction(key: result.prediction.key, score: score)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(Snapshot(cases: cases)).write(to: snapshotURL, options: .atomic)
        print("Accepted snapshot of \(cases.count) cases → \(snapshotURL.path)")
    }
}
