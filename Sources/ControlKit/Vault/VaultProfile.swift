import Foundation

/// A named set of values that overrides the default one.
///
/// The thing this exists to fix is the most-complained-about limitation in
/// 1Password's own forums: people keep four email addresses in one identity and
/// can only autofill the first, and the official workaround is to duplicate the
/// whole identity per address. Duplication is the wrong shape — your name does
/// not change when your email does.
///
/// So a profile is **sparse**. "School" overrides the email and the address and
/// inherits everything else. Nothing is copied, and changing your surname changes
/// it everywhere at once.
public struct VaultProfile: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    /// Symbol shown in the menu bar and picker.
    public var symbol: String

    public init(id: String, name: String, symbol: String) {
        self.id = id
        self.name = name
        self.symbol = symbol
    }

    /// Every profile falls back to this one, which is why it cannot be deleted.
    public static let defaultID = "default"

    public var isDefault: Bool { id == Self.defaultID }

    public static let builtIn: [VaultProfile] = [
        VaultProfile(id: defaultID, name: "Personal", symbol: "person"),
        VaultProfile(id: "school", name: "School", symbol: "graduationcap"),
        VaultProfile(id: "work", name: "Work", symbol: "briefcase"),
    ]
}

/// Maps a (profile, field) pair onto a single Keychain account name.
///
/// The default profile deliberately keeps its bare key. Accounts written before
/// profiles existed are all default-profile values, and rewriting them on upgrade
/// would mean a migration that could half-fail and leave a vault in two shapes.
/// Reading handles both forms instead, which cannot half-fail.
public enum ProfileKey {
    public static let separator: Character = "/"

    public static func account(profile: String, key: String) -> String {
        profile == VaultProfile.defaultID ? key : "\(profile)\(separator)\(key)"
    }

    /// Splits an account back into its parts. A bare account is a default one.
    public static func parse(_ account: String) -> (profile: String, key: String) {
        guard let slash = account.firstIndex(of: separator) else {
            return (VaultProfile.defaultID, account)
        }
        return (String(account[..<slash]), String(account[account.index(after: slash)...]))
    }

    /// Where to look for a value, in order: the active profile, then the default.
    public static func lookupOrder(profile: String, key: String) -> [String] {
        guard profile != VaultProfile.defaultID else { return [key] }
        return [account(profile: profile, key: key), key]
    }
}
