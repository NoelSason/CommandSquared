import XCTest
@testable import ControlKit

@MainActor
final class MatchCacheTests: XCTestCase {
    private var fileURL: URL!
    private var cache: MatchCache!

    override func setUp() async throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("control-cache-\(UUID().uuidString).json")
        cache = MatchCache(fileURL: fileURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private let context = FieldContext(
        appName: "Safari",
        bundleID: "com.apple.Safari",
        domain: "example.com",
        role: "AXTextField",
        label: "Email"
    )

    func testRecordAndLookupRoundTrip() {
        cache.record("email_school", for: context, source: .jev, userConfirmed: false)
        XCTAssertEqual(cache.entry(for: context)?.key, "email_school")
    }

    func testAUserCorrectionSurvivesALaterModelAnswer() {
        cache.record("email_school", for: context, source: .manual, userConfirmed: true)
        cache.record("email_personal", for: context, source: .jev, userConfirmed: false)

        XCTAssertEqual(cache.entry(for: context)?.key, "email_school",
                       "a Jev answer must not overwrite what the user chose")
    }

    func testAUserCorrectionCanBeChangedByTheUser() {
        cache.record("email_school", for: context, source: .manual, userConfirmed: true)
        cache.record("email_personal", for: context, source: .manual, userConfirmed: true)
        XCTAssertEqual(cache.entry(for: context)?.key, "email_personal")
    }

    func testPruningDropsEntriesPointingAtDeletedFields() {
        cache.record("custom_thing", for: context, source: .manual, userConfirmed: true)
        cache.prune(validKeys: Set(VaultSchema.builtIn.map(\.key)))
        XCTAssertNil(cache.entry(for: context))
    }

    func testEntriesPersistAcrossInstances() {
        cache.record("email_school", for: context, source: .manual, userConfirmed: true)
        let reloaded = MatchCache(fileURL: fileURL)
        XCTAssertEqual(reloaded.entry(for: context)?.key, "email_school")
        XCTAssertTrue(reloaded.entry(for: context)?.userConfirmed ?? false)
    }

    func testDifferentSitesDoNotShareAnEntry() {
        var other = context
        other.domain = "other.com"
        cache.record("email_school", for: context, source: .manual, userConfirmed: true)
        XCTAssertNil(cache.entry(for: other))
    }

    // MARK: Only what the rules don't know is remembered

    func testAPlainLocalFillIsNotRemembered() {
        // Shipped behaviour: every fill was cached and the cache is consulted
        // before the rules, so one wrong local guess replayed on every visit.
        cache.record("preferred_name", for: context, source: .local, userConfirmed: false)
        XCTAssertNil(cache.entry(for: context))
    }

    func testReplayingACorrectionDoesNotDemoteIt() {
        // Cycling to a different candidate is a correction, and is remembered.
        cache.record("email_school", for: context, source: .manual, userConfirmed: false)
        // The next fill replays it from the cache; that must not overwrite it.
        cache.record("email_school", for: context, source: .cache, userConfirmed: false)
        XCTAssertEqual(cache.entry(for: context)?.source, .manual)
    }

    func testEchoEntriesFromOlderBuildsAreIgnored() throws {
        let echo = MatchCache.Entry(key: "home_city", learnedAt: Date(), source: .cache,
                                    userConfirmed: false, label: "City", appName: "Brave Browser")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([context.signature: echo]).write(to: fileURL)

        let reloaded = MatchCache(fileURL: fileURL)
        XCTAssertNil(reloaded.entry(for: context))
        XCTAssertTrue(reloaded.entries.isEmpty)
    }
}
