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
        /// The nearest section heading, as `NearbyTextPolicy` finds it.
        let heading: String?
        /// The page's id for the field, which is what `AXDOMIdentifier` reports.
        /// Capture passes it as `FieldContext.domIdentifier`, which only Chrome
        /// and Safari fill in, so the headline leaves it out and the `+id` mode
        /// passes it on.
        let fieldName: String?
        /// Every acceptable key. Empty means the field must match nothing.
        let expect: [String]
        let note: String?
        /// The fixture file the case came from.
        var source = ""
        /// Run with the DOM id passed through, as capture does in Chrome and Safari.
        var withID = false

        /// The snapshot key. The `+id` run of a case is a separate prediction.
        var key: String { withID ? id + "+id" : id }

        /// The headline is what Control sees today, on English forms.
        var inHeadline: Bool { !withID && !MatcherEvalTests.outsideHeadline.contains(source) }

        private enum CodingKeys: String, CodingKey {
            case id, input, label, placeholder, help, nearby, heading, fieldName, expect, note
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
                nearbyText: testCase.nearby ?? [],
                heading: testCase.heading,
                domIdentifier: testCase.withID ? testCase.fieldName : nil
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
    /// by case. (`hashValue` is seeded per process, hence FNV-1a.) Takes the
    /// case id, not the snapshot key, so both runs of a case share a split.
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
            guard let before = snapshot.cases[result.testCase.key] else { continue }
            let beforeOutcome = Self.outcome(of: before, for: result.testCase)
            if beforeOutcome == .correct, result.outcome != .correct {
                regressed.append("\(result.testCase.key): \(Self.describe(before)) → \(Self.describe(result.prediction))")
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
            XCTAssertTrue(seen.insert(testCase.key).inserted, "duplicate case id \(testCase.key)")
            for key in testCase.expect {
                XCTAssertTrue(known.contains(key), "\(testCase.id) expects unknown key \(key)")
            }
            // A field with no label of its own still has a case when the page
            // gives it nearby text or an id: capture meets those too.
            let text = [testCase.label, testCase.placeholder, testCase.help, testCase.heading, testCase.fieldName]
                .compactMap { $0 } + (testCase.nearby ?? [])
            XCTAssertFalse(text.isEmpty, "\(testCase.id) has nothing to match on")
        }
    }

    // MARK: Report

    static func report(_ results: [Result], snapshot: Snapshot?) -> String {
        var lines = ["=== MATCHER EVAL ==="]
        let headline = results.filter(\.testCase.inHeadline)

        func summary(_ name: String, _ subset: [Result]) -> String {
            let count = subset.count
            let correct = subset.filter { $0.outcome == .correct }.count
            let wrong = subset.filter { $0.outcome == .wrong }.count
            let missed = subset.filter { $0.outcome == .missed }.count
            let harmful = subset.filter(\.harmful).count
            let dev = subset.filter { !$0.holdout }
            let holdout = subset.filter(\.holdout)
            return name.padding(toLength: 20, withPad: " ", startingAt: 0)
                + pad(count, 5) + pad(correct, 9) + pad(wrong, 7) + pad(missed, 8) + pad(harmful, 9)
                + "   " + percent(correct, count).padding(toLength: 9, withPad: " ", startingAt: 0)
                + percent(dev.filter { $0.outcome == .correct }.count, dev.count).padding(toLength: 8, withPad: " ", startingAt: 0)
                + percent(holdout.filter { $0.outcome == .correct }.count, holdout.count)
        }

        lines.append("")
        lines.append("source                cases  correct  wrong  missed  harmful   accuracy dev     holdout")
        lines.append(summary("all", headline))
        for source in sources {
            let subset = headline.filter { $0.testCase.source == source }
            if !subset.isEmpty { lines.append(summary(source, subset)) }
        }
        lines.append(summary("dev", headline.filter { !$0.holdout }))
        lines.append(summary("holdout", headline.filter(\.holdout)))

        // Measured, ratcheted, but not what Control sees today on English forms.
        var outside: [String] = []
        for source in sources {
            let labelOnly = results.filter { $0.testCase.source == source && !$0.testCase.withID && !$0.testCase.inHeadline }
            if !labelOnly.isEmpty { outside.append(summary(source, labelOnly)) }
        }
        for source in sources {
            let withID = results.filter { $0.testCase.source == source && $0.testCase.withID }
            if !withID.isEmpty { outside.append(summary("\(source) +id", withID)) }
        }
        if !outside.isEmpty {
            lines.append("not in the headline:")
            lines.append(contentsOf: outside)
        }
        lines.append("harmful = wrong and confident enough to fill without asking")
        lines.append("+id = the same field with its DOM id, as capture reads it in Chrome and Safari")

        let positives = headline.filter { !$0.testCase.expect.isEmpty && $0.outcome == .correct }
        let silent = positives.filter { $0.prediction.score >= MatchThresholds.autoInsert }.count
        lines.append("of \(positives.count) correct answers, \(silent) fill without asking (\(percent(silent, positives.count)))")

        if let line = idComparison(results) {
            lines.append("")
            lines.append(line)
        }

        lines.append("")
        lines.append(calibration(headline))
        lines.append("")
        lines.append(families(headline))

        // Confusion pairs, dev only.
        var pairs: [String: Int] = [:]
        for result in headline where !result.holdout && result.outcome != .correct {
            let expected = result.testCase.expect.first.map {
                result.testCase.expect.count > 1 ? "\($0)+" : $0
            } ?? "nothing"
            pairs["\(expected) → \(result.prediction.key ?? "nothing")", default: 0] += 1
        }
        if !pairs.isEmpty {
            lines.append("")
            lines.append("top confusions (dev, expected → got)")
            for (pair, count) in pairs.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }).prefix(30) {
                lines.append("  \(pad(count, 4))  \(pair)")
            }
        }

        if let snapshot {
            lines.append("")
            lines.append(comparison(results, snapshot: snapshot))
        }

        // Every dev failure, with what fired, grouped by source.
        let failures = headline.filter { !$0.holdout && $0.outcome != .correct }
        if !failures.isEmpty {
            lines.append("")
            lines.append("dev failures (\(failures.count))")
            for result in failures.sorted(by: { ($0.testCase.source, $0.testCase.id) < ($1.testCase.source, $1.testCase.id) }) {
                let expected = result.testCase.expect.isEmpty ? "nothing" : result.testCase.expect.joined(separator: "|")
                lines.append("  [\(result.outcome.rawValue)] \(result.testCase.id)")
                lines.append("      \(describeInput(result.testCase))")
                lines.append("      want \(expected), got \(describe(result.prediction))")
                for evidence in trace(result.testCase).prefix(4) {
                    lines.append("      · \(evidence.key) \(String(format: "%.2f", evidence.score)) — \(evidence.reason)")
                }
            }
        }

        lines.append("=== END ===")
        return lines.joined(separator: "\n")
    }

    /// What reading the field's id would change: the cases it fixes, and the
    /// ones it breaks. The breaks are the risk, so the dev ones are listed.
    private static func idComparison(_ results: [Result]) -> String? {
        let labelOnly = Dictionary(
            results.filter { !$0.testCase.withID && $0.testCase.fieldName != nil }.map { ($0.testCase.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let pairs = results.filter(\.testCase.withID).compactMap { withID in
            labelOnly[withID.testCase.id].map { (labelOnly: $0, withID: withID) }
        }
        guard !pairs.isEmpty else { return nil }

        func counts(_ subset: [(labelOnly: Result, withID: Result)]) -> (fixes: Int, breaks: Int) {
            (subset.filter { $0.labelOnly.outcome != .correct && $0.withID.outcome == .correct }.count,
             subset.filter { $0.labelOnly.outcome == .correct && $0.withID.outcome != .correct }.count)
        }
        let dev = pairs.filter { !$0.withID.holdout }
        let (devFixes, devBreaks) = counts(dev)
        let (holdoutFixes, holdoutBreaks) = counts(pairs.filter(\.withID.holdout))
        var lines = ["+id vs label-only on \(pairs.count) cases with an id: dev fixes \(devFixes) · breaks \(devBreaks)"
            + " · holdout fixes \(holdoutFixes) · breaks \(holdoutBreaks)"]
        let broken = dev.filter { $0.labelOnly.outcome == .correct && $0.withID.outcome != .correct }
        for pair in broken.prefix(15) {
            lines.append("  broken: \(pair.withID.testCase.id) [id \(pair.withID.testCase.fieldName ?? "")]: "
                + "\(describe(pair.labelOnly.prediction)) → \(describe(pair.withID.prediction))")
        }
        return lines.joined(separator: "\n")
    }

    /// How often a prediction at each score is right. Everything at or above
    /// `autoInsert` fills without asking, so a low bucket up there is harm.
    private static func calibration(_ results: [Result]) -> String {
        let edges = [MatchThresholds.confirm, 0.40, MatchThresholds.autoInsert, 0.70, 0.85, 0.90, 0.95]
        var lines = ["calibration (headline predictions by score)", "  score        n  right  wrong  precision"]
        let predicted = results.filter { $0.prediction.key != nil }
        for (index, low) in edges.enumerated() {
            let high = index + 1 < edges.count ? edges[index + 1] : .infinity
            let bucket = predicted.filter { $0.prediction.score >= low && $0.prediction.score < high }
            let right = bucket.filter { $0.outcome == .correct }.count
            let range = String(format: "%.2f", low) + (high.isFinite ? String(format: "–%.2f", high) : "+    ")
            lines.append("  " + range.padding(toLength: 10, withPad: " ", startingAt: 0)
                + pad(bucket.count, 5) + pad(right, 7) + pad(bucket.count - right, 7) + "   " + percent(right, bucket.count))
        }
        return lines.joined(separator: "\n")
    }

    /// Which piece of evidence won each prediction, grouped with the quoted
    /// text elided: `phone_mobile ← Chromium PHONE in …`. A family that is
    /// often wrong is a candidate for asking instead of filling.
    private static func families(_ results: [Result]) -> String {
        struct Tally { var fired = 0, right = 0, wrong = 0, silentWrong = 0 }
        var tallies: [String: Tally] = [:]
        for result in results {
            guard let key = result.prediction.key,
                  let winner = trace(result.testCase).first(where: { $0.key == key })
            else { continue }
            let reason = winner.reason.replacingOccurrences(of: #""[^"]*""#, with: "…", options: .regularExpression)
            var tally = tallies["\(key) ← \(reason)", default: Tally()]
            tally.fired += 1
            if result.outcome == .correct { tally.right += 1 } else { tally.wrong += 1 }
            if result.harmful { tally.silentWrong += 1 }
            tallies["\(key) ← \(reason)"] = tally
        }
        var lines = ["rule families (headline, winning evidence, most wrong first)",
                     "  fired  right  wrong  silent-wrong  precision  family"]
        let sorted = tallies.sorted { ($0.value.wrong, $0.value.fired, $1.key) > ($1.value.wrong, $1.value.fired, $0.key) }
        for (family, tally) in sorted.prefix(25) {
            lines.append("  " + pad(tally.fired, 5) + pad(tally.right, 7) + pad(tally.wrong, 7) + pad(tally.silentWrong, 14)
                + "   " + percent(tally.right, tally.fired).padding(toLength: 9, withPad: " ", startingAt: 0) + "  " + family)
        }
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
            guard let before = snapshot.cases[result.testCase.key] else {
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
                regressed.append("  \(result.testCase.key): \(describe(before)) → \(describe(result.prediction))\(split)")
            }
        }
        var line = "vs snapshot: \(percent(correctBefore, shared)) → \(percent(correctNow, shared)) on \(shared) shared cases"
            + " (every source and mode)"
            + " · fixed \(fixed) · regressed \(regressed.count)"
        if added > 0 { line += " · \(added) new case(s) not in the snapshot" }
        // Regressions are listed even for holdout cases: each one fails the test,
        // so each one has to be findable.
        return ([line] + regressed.sorted()).joined(separator: "\n")
    }

    /// The text a case gives the matcher, for reading a failure without
    /// opening the fixture.
    private static func describeInput(_ testCase: Case) -> String {
        var parts: [String] = []
        if let label = testCase.label { parts.append("label \"\(label)\"") }
        if let placeholder = testCase.placeholder { parts.append("placeholder \"\(placeholder)\"") }
        if let help = testCase.help { parts.append("help \"\(help)\"") }
        if let heading = testCase.heading { parts.append("heading \"\(heading)\"") }
        if let fieldName = testCase.fieldName { parts.append("id \"\(fieldName)\"") }
        return parts.isEmpty ? "(no text)" : parts.joined(separator: " · ")
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
    /// The `chromium*` sources are real forms from Chromium's autofill test
    /// data; see the fixture README for how they were extracted and labelled.
    private static let sources = ["form", "regression", "handwritten", "browser", "chromium", "chromium-repro", "chromium-i18n"]

    /// Measured and ratcheted, but left out of the headline: the matcher is
    /// English-only by design, and this source measures what that costs.
    static let outsideHeadline: Set<String> = ["chromium-i18n"]

    static func loadCases() throws -> [Case] {
        let decoder = JSONDecoder()
        let cases = try sources.flatMap { source in
            let url = fixtureDirectory.appendingPathComponent("\(source).json")
            guard FileManager.default.fileExists(atPath: url.path) else { return [Case]() }
            return try decoder.decode([Case].self, from: Data(contentsOf: url)).map { testCase in
                var testCase = testCase
                testCase.source = source
                return testCase
            }
        }
        // Every case that knows its field's id runs a second time with it.
        let withID = cases.filter { $0.fieldName != nil }.map { testCase in
            var testCase = testCase
            testCase.withID = true
            return testCase
        }
        return cases + withID
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
            cases[result.testCase.key] = Prediction(key: result.prediction.key, score: score)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(Snapshot(cases: cases)).write(to: snapshotURL, options: .atomic)
        print("Accepted snapshot of \(cases.count) cases → \(snapshotURL.path)")
    }
}
