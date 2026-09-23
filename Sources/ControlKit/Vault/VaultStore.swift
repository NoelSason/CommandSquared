import Foundation
import Observation

/// The vault: field definitions on disk, values in the Keychain.
///
/// The split matters. `vault.json` is a schema — key names, labels, categories,
/// format hints — and is not secret. Every actual value lives in the Keychain,
/// one generic-password item per key, and sensitive ones sit behind Touch ID.
@MainActor
@Observable
public final class VaultStore {
    public private(set) var fields: [VaultField]
    /// Keys that currently hold a value. Derived from an attribute-only Keychain
    /// query, so populating this never triggers an authentication prompt.
    public private(set) var filledKeys: Set<String> = []
    public private(set) var lastError: String?
    /// Keys that hold a value this build cannot open — typically written by a
    /// build with a different code signature. Filled in lazily as rows are read,
    /// rather than by probing every key up front, since probing can raise a
    /// system dialog per item.
    public private(set) var unreadableKeys: Set<String> = []

    /// Which set of values is in play. Switching it changes what fills, without
    /// moving or copying anything — a profile is an overlay, not a copy.
    public var activeProfileID: String = VaultProfile.defaultID {
        didSet {
            guard oldValue != activeProfileID else { return }
            refreshFilledKeys()
            prefetch()
        }
    }

    /// Every account the Keychain holds, across all profiles.
    private var storedAccounts: Set<String> = []

    private let fileURL: URL
    /// Non-sensitive values, held in memory after the first read. Building the
    /// picker touches every fillable field, and a Keychain read is an XPC round
    /// trip — doing ~30 of them synchronously is felt. Sensitive values are never
    /// cached: each read must go through Touch ID.
    private var valueCache: [String: String] = [:]

    /// Set when `vault.json` could not be read and could not be moved aside
    /// either. Saving would then overwrite the only copy of the user's custom
    /// fields, so it is refused instead.
    private var schemaIsReadOnly = false

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        switch Self.loadFields(from: self.fileURL) {
        case .fresh:
            fields = VaultSchema.builtIn
        case let .loaded(loaded):
            fields = loaded
        case let .unreadable(keptAs):
            fields = VaultSchema.builtIn
            if let keptAs {
                lastError = "Your custom fields couldn't be read, so Control started with the built-in ones. "
                    + "The original was kept as \(keptAs.lastPathComponent) in Control's folder."
            } else {
                schemaIsReadOnly = true
                lastError = "Your custom fields couldn't be read. Control won't save field changes until "
                    + "vault.json in Control's folder is fixed or removed, so nothing in it is lost."
            }
        }
        refreshFilledKeys()
        prefetch()
    }

    /// Warms the cache so the first fill of a session is as quick as the rest.
    private func prefetch() {
        for field in fields where !field.sensitive && !field.isDerived && filledKeys.contains(field.key) {
            guard let account = account(providing: field.key) else { continue }
            // Warming only: a value that fails here is read again, with its
            // error reported, when it is actually needed.
            if let value = try? Keychain.get(account) {
                valueCache[account] = value
            }
        }
    }

    // MARK: Profiles

    /// The account that actually holds this key: the active profile's, or the
    /// default profile's if the active one does not override it.
    public func account(providing key: String) -> String? {
        ProfileKey.lookupOrder(profile: activeProfileID, key: key)
            .first { storedAccounts.contains($0) }
    }

    /// Which profile a value is coming from, for keys that resolve at all.
    /// Shown in the picker when it is not the active one, because inheriting a
    /// value silently is fine until it is wrong.
    public func profile(providing key: String) -> String? {
        account(providing: key).map { ProfileKey.parse($0).profile }
    }

    public func isOverridden(_ key: String, in profile: String) -> Bool {
        storedAccounts.contains(ProfileKey.account(profile: profile, key: key))
    }

    /// Keys this profile defines itself, as opposed to inheriting.
    public func overriddenKeys(in profile: String) -> Set<String> {
        Set(storedAccounts.map(ProfileKey.parse).filter { $0.profile == profile }.map(\.key))
    }

    public static var defaultFileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Control", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("vault.json")
    }

    // MARK: Schema

    public func field(for key: String) -> VaultField? {
        fields.first { $0.key == key }
    }

    public func fields(in category: VaultCategory) -> [VaultField] {
        fields.filter { $0.category == category }
    }

    public func addCustomField(_ field: VaultField) {
        guard self.field(for: field.key) == nil else { return }
        var custom = field
        custom.isBuiltIn = false
        fields.append(custom)
        persistFields()
    }

    public func renameCustomField(key: String, to label: String) {
        guard let index = fields.firstIndex(where: { $0.key == key }), !fields[index].isBuiltIn else { return }
        fields[index].label = label
        persistFields()
    }

    public func removeCustomField(key: String) {
        guard let existing = field(for: key), !existing.isBuiltIn else { return }
        fields.removeAll { $0.key == key }
        clearValue(for: key)
        persistFields()
    }

    /// What happened when we tried to read a field back.
    ///
    /// `unreadable` is the state that matters: the value is in the Keychain but
    /// this build cannot open it, which happens when the item was written by a
    /// build with a different code signature. Without this the settings window
    /// shows an empty box and looks like nothing ever saved.
    public enum ReadState: Sendable, Equatable {
        case empty
        case value(String)
        case unreadable(String)
    }

    public func readState(for key: String) -> ReadState {
        guard let field = field(for: key) else { return .empty }
        do {
            guard let stored = try storedValue(for: key), !stored.isEmpty else {
                unreadableKeys.remove(key)
                return .empty
            }
            unreadableKeys.remove(key)
            return .value(stored)
        } catch {
            Log.app.error("Could not read \(field.key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            unreadableKeys.insert(key)
            return .unreadable(error.localizedDescription)
        }
    }

    /// Wipes every stored value. Used to clear items orphaned by a signing change.
    public func resetAllValues() {
        do {
            try Keychain.deleteAll()
            storedAccounts = []
            filledKeys = []
            unreadableKeys = []
            valueCache = [:]
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Values

    public func setValue(_ value: String, for key: String) {
        guard let field = field(for: key) else { return }
        guard !field.isDerived else { return }  // derived values are computed, not stored
        do {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let account = ProfileKey.account(profile: activeProfileID, key: key)
            if trimmed.isEmpty {
                try Keychain.delete(account)
                storedAccounts.remove(account)
                valueCache.removeValue(forKey: account)
            } else {
                try Keychain.set(trimmed, for: account, sensitive: field.sensitive)
                storedAccounts.insert(account)
                if !field.sensitive { valueCache[account] = trimmed }
            }
            recomputeFilledKeys()
            lastError = nil
        } catch {
            lastError = "Couldn't save \(field.label): \(error.localizedDescription)"
            Log.app.error("Keychain write failed for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    public func clearValue(for key: String) {
        setValue("", for: key)
    }

    /// Reads a value straight out of the Keychain.
    ///
    /// For a sensitive field this is the call that raises the Touch ID prompt, so
    /// it must only ever run after the user has confirmed the fill — never
    /// speculatively while ranking candidates.
    public func storedValue(for key: String, authenticationPrompt: String? = nil) throws -> String? {
        guard let field = field(for: key) else { return nil }
        if let parts = field.derivedFrom {
            let resolved = try parts.compactMap { part -> String? in
                guard let account = account(providing: part) else { return nil }
                if let cached = valueCache[account] { return cached }
                return try Keychain.get(account)
            }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return resolved.isEmpty ? nil : resolved.joined(separator: " ")
        }
        guard let account = account(providing: key) else { return nil }
        if !field.sensitive, let cached = valueCache[account] { return cached }

        let value = try Keychain.get(account, prompt: field.sensitive ? authenticationPrompt : nil)
        if !field.sensitive, let value { valueCache[account] = value }
        return value
    }

    /// The final string to insert: stored value, reshaped for the target field.
    public func resolvedValue(
        for key: String,
        context: FieldContext,
        authenticationPrompt: String? = nil
    ) throws -> String? {
        guard let field = field(for: key) else { return nil }
        guard let raw = try storedValue(for: key, authenticationPrompt: authenticationPrompt) else { return nil }
        return ValueFormatter.format(raw, kind: field.kind, context: context)
    }

    // MARK: Candidates

    /// Fields the matcher is allowed to propose: only ones that actually hold a
    /// value. An empty field must never be offered, or Jev will confidently pick
    /// a key that resolves to nothing and the fill silently no-ops.
    /// Built from the user's own values, so an ambiguous label like "Berkeley
    /// email" can be resolved without a hard-coded list of institutions.
    public var matchHints: MatchHints {
        // Hints only sharpen a guess; without them the matcher still works.
        MatchHints(
            university: try? storedValue(for: "university"),
            schoolEmail: try? storedValue(for: "email_school")
        )
    }

    /// What the matcher is allowed to guess from: everything with a value,
    /// minus snippets. Snippets are chosen deliberately, never inferred.
    public var matchableFields: [VaultField] {
        fillableFields.filter { !$0.isSnippet }
    }

    public var fillableFields: [VaultField] {
        fields.filter { field in
            if let parts = field.derivedFrom {
                return parts.contains { filledKeys.contains($0) }
            }
            return filledKeys.contains(field.key)
        }
    }

    public func refreshFilledKeys() {
        do {
            storedAccounts = try Keychain.storedAccounts()
            unreadableKeys = []
            lastError = nil
        } catch {
            storedAccounts = []
            lastError = error.localizedDescription
        }
        recomputeFilledKeys()
    }

    /// What resolves under the active profile: its own overrides, plus anything
    /// inherited from the default.
    private func recomputeFilledKeys() {
        var keys = Set<String>()
        for account in storedAccounts {
            let parsed = ProfileKey.parse(account)
            if parsed.profile == activeProfileID || parsed.profile == VaultProfile.defaultID {
                keys.insert(parsed.key)
            }
        }
        // Only the vault's own fields count as saved details. Anything else in
        // the service — the Jev key, before it moved out — is not one of them.
        filledKeys = keys.intersection(fields.map(\.key))
    }

    // MARK: Persistence

    private func persistFields() {
        guard !schemaIsReadOnly else {
            lastError = "Field changes aren't being saved: vault.json in Control's folder couldn't be read."
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(fields).write(to: fileURL, options: .atomic)
        } catch {
            lastError = error.localizedDescription
        }
    }

    enum LoadedFields: Equatable {
        /// No file yet: a fresh install.
        case fresh
        /// The built-in catalog plus the user's custom fields.
        case loaded([VaultField])
        /// A file that wouldn't decode, moved to `keptAs` — or left in place,
        /// when even the move failed.
        case unreadable(keptAs: URL?)
    }

    /// Merges the on-disk schema with the built-in catalog so that new built-in
    /// fields shipped in an update appear for existing users.
    ///
    /// A file that won't decode is somebody's custom fields, not an absence of
    /// them. It used to be treated as a fresh install, and the next save wrote
    /// the built-in catalog over it.
    static func loadFields(from url: URL) -> LoadedFields {
        guard FileManager.default.fileExists(atPath: url.path) else { return .fresh }
        do {
            let stored = try JSONDecoder().decode([VaultField].self, from: Data(contentsOf: url))
            var merged = VaultSchema.builtIn
            let builtInKeys = Set(merged.map(\.key))
            merged.append(contentsOf: stored.filter { !builtInKeys.contains($0.key) })
            return .loaded(merged)
        } catch {
            Log.app.error("vault.json could not be read: \(error.localizedDescription, privacy: .public)")
            return .unreadable(keptAs: moveAside(url))
        }
    }

    /// Renames an unreadable file out of the way, so it survives the next save.
    static func moveAside(_ url: URL) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let aside = url.appendingPathExtension("corrupt-\(stamp)")
        do {
            try FileManager.default.moveItem(at: url, to: aside)
            return aside
        } catch {
            Log.app.error("Could not move \(url.lastPathComponent, privacy: .public) aside: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
