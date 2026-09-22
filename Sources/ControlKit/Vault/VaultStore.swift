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

    private let fileURL: URL
    /// Non-sensitive values, held in memory after the first read. Building the
    /// picker touches every fillable field, and a Keychain read is an XPC round
    /// trip — doing ~30 of them synchronously is felt. Sensitive values are never
    /// cached: each read must go through Touch ID.
    private var valueCache: [String: String] = [:]

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        fields = Self.loadFields(from: self.fileURL) ?? VaultSchema.builtIn
        refreshFilledKeys()
        prefetch()
    }

    /// Warms the cache so the first fill of a session is as quick as the rest.
    private func prefetch() {
        for field in fields where !field.sensitive && !field.isDerived && filledKeys.contains(field.key) {
            if let value = try? Keychain.get(field.key) {
                valueCache[field.key] = value
            }
        }
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
            if trimmed.isEmpty {
                try Keychain.delete(key)
                filledKeys.remove(key)
                valueCache.removeValue(forKey: key)
            } else {
                try Keychain.set(trimmed, for: key, sensitive: field.sensitive)
                filledKeys.insert(key)
                if !field.sensitive { valueCache[key] = trimmed }
            }
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
                if let cached = valueCache[part] { return cached }
                return try Keychain.get(part)
            }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return resolved.isEmpty ? nil : resolved.joined(separator: " ")
        }
        if !field.sensitive, let cached = valueCache[key] { return cached }

        let value = try Keychain.get(key, prompt: field.sensitive ? authenticationPrompt : nil)
        if !field.sensitive, let value { valueCache[key] = value }
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
            filledKeys = try Keychain.storedAccounts()
            unreadableKeys = []
            lastError = nil
        } catch {
            filledKeys = []
            lastError = error.localizedDescription
        }
    }

    // MARK: Persistence

    private func persistFields() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(fields).write(to: fileURL, options: .atomic)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Merges the on-disk schema with the built-in catalog so that new built-in
    /// fields shipped in an update appear for existing users.
    private static func loadFields(from url: URL) -> [VaultField]? {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([VaultField].self, from: data)
        else { return nil }

        var merged = VaultSchema.builtIn
        let builtInKeys = Set(merged.map(\.key))
        merged.append(contentsOf: stored.filter { !builtInKeys.contains($0.key) })
        return merged
    }
}
