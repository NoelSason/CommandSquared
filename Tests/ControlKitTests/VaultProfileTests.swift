import XCTest
@testable import ControlKit

final class VaultProfileTests: XCTestCase {

    func testDefaultProfileKeepsBareAccountNames() {
        // Values written before profiles existed are default-profile values.
        // Reading both shapes avoids a migration that could half-fail.
        XCTAssertEqual(ProfileKey.account(profile: "default", key: "email_personal"), "email_personal")
    }

    func testOtherProfilesArePrefixed() {
        XCTAssertEqual(ProfileKey.account(profile: "school", key: "email_personal"), "school/email_personal")
    }

    func testParsingRoundTrips() {
        let parsed = ProfileKey.parse("school/email_personal")
        XCTAssertEqual(parsed.profile, "school")
        XCTAssertEqual(parsed.key, "email_personal")
    }

    func testABareAccountParsesAsDefault() {
        let parsed = ProfileKey.parse("email_personal")
        XCTAssertEqual(parsed.profile, "default")
        XCTAssertEqual(parsed.key, "email_personal")
    }

    func testKeysContainingSlashesSplitOnlyOnce() {
        let parsed = ProfileKey.parse("work/some/odd_key")
        XCTAssertEqual(parsed.profile, "work")
        XCTAssertEqual(parsed.key, "some/odd_key")
    }

    func testLookupFallsBackToTheDefaultProfile() {
        // The whole point: "School" overrides your email and inherits your name.
        XCTAssertEqual(
            ProfileKey.lookupOrder(profile: "school", key: "family_name"),
            ["school/family_name", "family_name"]
        )
    }

    func testTheDefaultProfileHasNothingToFallBackTo() {
        XCTAssertEqual(ProfileKey.lookupOrder(profile: "default", key: "family_name"), ["family_name"])
    }

    func testTheDefaultProfileCannotBeMistakenForAnother() {
        XCTAssertTrue(VaultProfile.builtIn.first { $0.id == "default" }!.isDefault)
        XCTAssertFalse(VaultProfile.builtIn.first { $0.id == "school" }!.isDefault)
    }
}

@MainActor
final class ProfileByDomainTests: XCTestCase {
    private var preferences: Preferences!

    override func setUp() async throws {
        // A throwaway suite per test: these write to UserDefaults for real.
        let defaults = UserDefaults(suiteName: "control.tests.\(UUID().uuidString)")!
        preferences = Preferences(defaults: defaults)
    }

    private func context(domain: String?) -> FieldContext {
        FieldContext(appName: "Brave", bundleID: "com.brave.Browser", domain: domain, label: "Email")
    }

    func testASiteWithNoHistoryHasNoProfile() {
        XCTAssertNil(preferences.profile(for: context(domain: "example.com")))
    }

    func testAChoiceIsRememberedForTheSite() {
        preferences.rememberProfile("school", for: context(domain: "berkeley.edu"))
        XCTAssertEqual(preferences.profile(for: context(domain: "berkeley.edu")), "school")
    }

    func testSubdomainsInheritTheChoice() {
        // Picking "School" on berkeley.edu should hold on portal.berkeley.edu —
        // a university is one place as far as the user is concerned.
        preferences.rememberProfile("school", for: context(domain: "berkeley.edu"))
        XCTAssertEqual(preferences.profile(for: context(domain: "portal.berkeley.edu")), "school")
    }

    func testAnExactMatchBeatsASuffixMatch() {
        preferences.rememberProfile("school", for: context(domain: "berkeley.edu"))
        preferences.rememberProfile("work", for: context(domain: "jobs.berkeley.edu"))
        XCTAssertEqual(preferences.profile(for: context(domain: "jobs.berkeley.edu")), "work")
    }

    func testAChoiceCanBeForgotten() {
        preferences.rememberProfile("school", for: context(domain: "berkeley.edu"))
        preferences.forgetProfile(for: "berkeley.edu")
        XCTAssertNil(preferences.profile(for: context(domain: "berkeley.edu")))
    }

    func testANativeAppWithNoDomainIsNotRemembered() {
        preferences.rememberProfile("school", for: context(domain: nil))
        XCTAssertTrue(preferences.profileByDomain.isEmpty)
    }
}
