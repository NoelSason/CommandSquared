import Foundation
import Observation

/// Remembers which vault key a given field resolved to, so the same field on the
/// same site never costs a second Jev call — and so a correction sticks.
///
/// Keyed on `FieldContext.signature`, which covers app, domain, label, placeholder
/// and role, but deliberately not the field's contents or surrounding page text.
@MainActor
@Observable
public final class MatchCache {
    public struct Entry: Codable, Sendable, Equatable {
        public var key: String
        public var learnedAt: Date
        public var source: MatchSource
        /// True when the user picked this themselves. Protected from being
        /// overwritten by a later Jev answer.
        public var userConfirmed: Bool
        /// Kept for the cache inspector in settings, so a wrong entry is findable.
        public var label: String?
        public var appName: String?
    }

    public private(set) var entries: [String: Entry] = [:]
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        load()
    }

    public static var defaultFileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Control", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("match-cache.json")
    }

    // MARK: Lookup

    public func entry(for context: FieldContext) -> Entry? {
        entries[context.signature]
    }

    // MARK: Record

    public func record(
        _ key: String,
        for context: FieldContext,
        source: MatchSource,
        userConfirmed: Bool
    ) {
        let signature = context.signature

        // A user's own pick outranks anything the model says later.
        if let existing = entries[signature], existing.userConfirmed, !userConfirmed {
            return
        }

        entries[signature] = Entry(
            key: key,
            learnedAt: Date(),
            source: source,
            userConfirmed: userConfirmed,
            label: context.label ?? context.placeholder,
            appName: context.appName
        )
        save()
    }

    /// Drops any keys that no longer exist in the vault — otherwise deleting a
    /// custom field leaves cache entries pointing at nothing.
    public func prune(validKeys: Set<String>) {
        let before = entries.count
        entries = entries.filter { validKeys.contains($0.value.key) }
        if entries.count != before { save() }
    }

    public func forget(signature: String) {
        entries.removeValue(forKey: signature)
        save()
    }

    public func reset() {
        entries = [:]
        save()
    }

    // MARK: Persistence

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([String: Entry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(entries).write(to: fileURL, options: .atomic)
    }
}
