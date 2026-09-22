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
}
