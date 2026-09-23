import XCTest
@testable import ControlKit

/// The Jev key's move out of the vault's Keychain service, against the real
/// Keychain under throwaway service names.
@MainActor
final class JevKeyStorageTests: XCTestCase {
    private let settings = "com.noelsason.Control.tests.settings"
    private let legacy = "com.noelsason.Control.tests.vault"
    private let account = "jev_api_key"
    private var suiteName = ""
    private var preferences: Preferences!

    override func setUp() async throws {
        try Keychain.deleteAll(service: settings)
        try Keychain.deleteAll(service: legacy)
        suiteName = "control-tests-\(UUID().uuidString)"
        preferences = Preferences(defaults: UserDefaults(suiteName: suiteName)!,
                                  settingsService: settings, legacyKeyService: legacy)
    }

    override func tearDown() async throws {
        try Keychain.deleteAll(service: settings)
        try Keychain.deleteAll(service: legacy)
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func testAKeyFromAnOlderBuildMovesOutOfTheVault() throws {
        try Keychain.set("key-123", for: account, sensitive: false, service: legacy)
        preferences.migrateJevKeyIfNeeded()
        XCTAssertEqual(try Keychain.get(account, service: settings), "key-123")
        XCTAssertNil(try Keychain.get(account, service: legacy),
                     "left behind, it counts as a saved detail and dies with 'Clear and start over'")
    }

    func testTheKeyStillWorksBeforeItHasMoved() throws {
        try Keychain.set("key-123", for: account, sensitive: false, service: legacy)
        XCTAssertEqual(preferences.jevAPIKey, "key-123")
        XCTAssertTrue(preferences.hasJevKey)
    }

    func testANewerKeyWinsOverALeftover() throws {
        try Keychain.set("new", for: account, sensitive: false, service: settings)
        try Keychain.set("old", for: account, sensitive: false, service: legacy)
        preferences.migrateJevKeyIfNeeded()
        XCTAssertEqual(try Keychain.get(account, service: settings), "new")
        XCTAssertNil(try Keychain.get(account, service: legacy))
    }

    func testSavingAKeyClearsTheOldPlace() throws {
        try Keychain.set("old", for: account, sensitive: false, service: legacy)
        preferences.jevAPIKey = "new"
        XCTAssertEqual(preferences.jevAPIKey, "new")
        XCTAssertNil(try Keychain.get(account, service: legacy))
        XCTAssertNil(preferences.jevKeyError)
    }

    func testNothingToMoveIsNotAnError() throws {
        preferences.migrateJevKeyIfNeeded()
        XCTAssertEqual(preferences.jevAPIKey, "")
        XCTAssertFalse(preferences.hasJevKey)
        XCTAssertNil(preferences.jevKeyError)
    }
}
