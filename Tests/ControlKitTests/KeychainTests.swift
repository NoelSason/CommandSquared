import LocalAuthentication
import XCTest
@testable import ControlKit

/// Round-trips against the real Keychain under a throwaway service name.
///
/// These exist because the bug they cover — `storedAccounts()` returning an empty
/// set forever — was invisible from the outside: writes succeeded, single reads
/// succeeded, and only the "which keys have values" query silently failed, which
/// made the whole vault look empty to the matcher.
final class KeychainTests: XCTestCase {
    private let service = "com.noelsason.Control.tests"

    override func setUp() async throws {
        try Keychain.deleteAll(service: service)
    }

    override func tearDown() async throws {
        try Keychain.deleteAll(service: service)
    }

    func testValueRoundTrips() throws {
        try Keychain.set("Noel", for: "given_name", sensitive: false, service: service)
        XCTAssertEqual(try Keychain.get("given_name", service: service), "Noel")
    }

    func testStoredAccountsSeesEverythingThatWasWritten() throws {
        let written = ["given_name", "family_name", "email_school"]
        for account in written {
            try Keychain.set("x", for: account, sensitive: false, service: service)
        }

        let found = try Keychain.storedAccounts(service: service)
        XCTAssertEqual(found, Set(written),
                       "storedAccounts drives fillableFields — an empty result makes the whole vault invisible")
    }

    func testStoredAccountsIsEmptyOnlyWhenNothingIsStored() throws {
        XCTAssertTrue(try Keychain.storedAccounts(service: service).isEmpty)
        try Keychain.set("x", for: "given_name", sensitive: false, service: service)
        XCTAssertFalse(try Keychain.storedAccounts(service: service).isEmpty)
    }

    func testOverwritingAnExistingAccountReplacesIt() throws {
        try Keychain.set("first", for: "given_name", sensitive: false, service: service)
        try Keychain.set("second", for: "given_name", sensitive: false, service: service)

        XCTAssertEqual(try Keychain.get("given_name", service: service), "second")
        XCTAssertEqual(try Keychain.storedAccounts(service: service), ["given_name"],
                       "a rewrite must not leave a duplicate behind")
    }

    func testDeleteRemovesTheAccount() throws {
        try Keychain.set("x", for: "given_name", sensitive: false, service: service)
        try Keychain.delete("given_name", service: service)

        XCTAssertNil(try Keychain.get("given_name", service: service))
        XCTAssertTrue(try Keychain.storedAccounts(service: service).isEmpty)
    }

    func testDeleteAllClearsEverything() throws {
        for account in ["a", "b", "c"] {
            try Keychain.set("x", for: account, sensitive: false, service: service)
        }
        try Keychain.deleteAll(service: service)
        XCTAssertTrue(try Keychain.storedAccounts(service: service).isEmpty)
    }

    func testMissingAccountReadsAsNilRatherThanThrowing() throws {
        XCTAssertNil(try Keychain.get("never_written", service: service))
    }

    /// "Couldn't save Known Traveler Number: Keychain error -34018." A Developer
    /// ID build without a provisioning profile can't use macOS's own Touch ID
    /// lock, and neither can this test runner. Sensitive values must still
    /// save, and must still ask before they're read.
    func testSensitiveValuesSaveWithoutTheKeychainEntitlement() throws {
        try Keychain.set("TT0000000", for: "known_traveler_number", sensitive: true, service: service)
        XCTAssertTrue(try Keychain.storedAccounts(service: service).contains("known_traveler_number"))

        let real = Keychain.authenticate
        defer { Keychain.authenticate = real }

        var asked: [String] = []
        Keychain.authenticate = { reason in
            asked.append(reason)
            return LAContext()
        }
        XCTAssertEqual(try Keychain.get("known_traveler_number", prompt: "fill your known traveler number", service: service),
                       "TT0000000")
        XCTAssertEqual(asked, ["fill your known traveler number"], "a sensitive read asks first")

        Keychain.authenticate = { _ in throw KeychainError.notAuthenticated("Cancelled.") }
        XCTAssertThrowsError(try Keychain.get("known_traveler_number", prompt: "fill your known traveler number", service: service)) {
            XCTAssertEqual($0.localizedDescription, "Cancelled.")
        }
    }

    func testUnicodeSurvivesTheRoundTrip() throws {
        try Keychain.set("Noël — 世界 🙂", for: "given_name", sensitive: false, service: service)
        XCTAssertEqual(try Keychain.get("given_name", service: service), "Noël — 世界 🙂")
    }
}
