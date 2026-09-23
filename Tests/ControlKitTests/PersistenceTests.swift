import XCTest
@testable import ControlKit

/// Files that fail to load must be kept, not overwritten. These used to be
/// swallowed: an unreadable `vault.json` looked like a fresh install, and the
/// next save wrote the built-in catalog over the user's custom fields.
@MainActor
final class PersistenceTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("control-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func contents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    func testAMissingVaultFileIsAFreshInstall() {
        XCTAssertEqual(VaultStore.loadFields(from: directory.appendingPathComponent("vault.json")), .fresh)
    }

    func testCustomFieldsLoadAlongsideTheBuiltInOnes() throws {
        let url = directory.appendingPathComponent("vault.json")
        let custom = VaultField(key: "custom_shoe_size", label: "Shoe size", category: .identity,
                                detail: "Shoe size.", isBuiltIn: false)
        try JSONEncoder().encode([custom]).write(to: url)

        guard case let .loaded(fields) = VaultStore.loadFields(from: url) else { return XCTFail("should load") }
        XCTAssertTrue(fields.contains(custom))
        XCTAssertEqual(fields.count, VaultSchema.builtIn.count + 1)
    }

    func testAnUnreadableVaultFileIsKeptAside() throws {
        let url = directory.appendingPathComponent("vault.json")
        try Data("{ not json".utf8).write(to: url)

        guard case let .unreadable(keptAs) = VaultStore.loadFields(from: url), let keptAs else {
            return XCTFail("should be moved aside")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the next save must not land on it")
        XCTAssertEqual(try String(contentsOf: keptAs, encoding: .utf8), "{ not json", "kept byte for byte")
    }

    func testAnUnreadableCacheIsKeptAside() throws {
        let url = directory.appendingPathComponent("match-cache.json")
        try Data("garbage".utf8).write(to: url)

        let cache = MatchCache(fileURL: url)
        XCTAssertTrue(cache.entries.isEmpty)
        let names = try contents()
        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(names[0].hasPrefix("match-cache.json.corrupt-"), "got \(names)")
    }
}
