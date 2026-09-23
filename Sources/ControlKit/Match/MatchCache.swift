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

        /// Whether this entry knows something the rules don't.
        ///
        /// A pick, a cycle landing or a hand correction does, and so does a Jev
        /// answer, since asking again costs a network call. A plain local fill
        /// does not: it is only an echo of what the rules said at the time, and
        /// replaying it ahead of the rules freezes a wrong guess in place — the
        /// campus fields on the hand-test page kept getting the home address
        /// that way — and hides every rule fix made since.
        public var isAuthoritative: Bool {
            userConfirmed || source == .manual || source == .jev
        }
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
        entries[context.signature].flatMap { $0.isAuthoritative ? $0 : nil }
    }

    // MARK: Record

    public func record(
        _ key: String,
        for context: FieldContext,
        source: MatchSource,
        userConfirmed: Bool
    ) {
        let signature = context.signature

        // Echoes of the rules — and replays of an entry already here — teach
        // nothing, and recording a replay as `.cache` would demote the
        // correction it came from.
        guard userConfirmed || source == .manual || source == .jev else { return }

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
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let decoded = try decoder.decode([String: Entry].self, from: Data(contentsOf: fileURL))
            // Echo entries written by older builds are dropped rather than kept
            // inert, so the inspector in settings lists only what is actually used.
            entries = decoded.filter { $0.value.isAuthoritative }
        } catch {
            // The file holds the user's corrections. Starting empty is fine;
            // overwriting it on the next save is not, so it is kept aside.
            Log.match.error("Match cache could not be read: \(error.localizedDescription, privacy: .public)")
            _ = VaultStore.moveAside(fileURL)
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            // Not fatal — fills still work, they just aren't remembered — but a
            // correction that silently fails to stick looks exactly like a bug.
            Log.match.error("Match cache could not be saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
