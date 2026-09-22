import Foundation
import Observation

/// User-facing settings. Everything here is non-secret; the Jev API key is the one
/// exception and lives in the Keychain, reachable through `jevAPIKey`.
@MainActor
@Observable
public final class Preferences {
    private enum Key {
        static let triggerMode = "triggerMode"
        static let activeProfile = "activeProfile"
        static let profileByDomain = "profileByDomain"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let deniedBundleIDs = "deniedBundleIDs"
        static let deniedDomains = "deniedDomains"
        static let jevEnabled = "jevEnabled"
        static let inlineSuggestions = "inlineSuggestions"
        static let autoInsertEnabled = "autoInsertEnabled"
        static let confirmedCategories = "confirmedCategories"
    }

    /// Keychain account for the API key. Not part of the vault service, so a
    /// vault wipe does not take the key with it.
    private static let apiKeyAccount = "jev_api_key"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.triggerMode: TriggerMode.doubleCommand.rawValue,
            Key.hotKeyCode: 9,               // V
            Key.hotKeyModifiers: 1_310_720,  // NSEvent .control | .command
            Key.jevEnabled: true,
            Key.inlineSuggestions: true,
            Key.autoInsertEnabled: true,
            Key.confirmedCategories: [VaultCategory.payment.rawValue],
        ])
    }

    // MARK: Profiles

    public var activeProfileID: String {
        get { defaults.string(forKey: Key.activeProfile) ?? VaultProfile.defaultID }
        set { defaults.set(newValue, forKey: Key.activeProfile) }
    }

    /// Which profile a site last used. Learned rather than configured — the same
    /// bet the match cache makes, and for the same reason: nobody is going to
    /// maintain a per-site list by hand, but everybody will pick the right one
    /// once when it matters.
    public var profileByDomain: [String: String] {
        get { defaults.dictionary(forKey: Key.profileByDomain) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Key.profileByDomain) }
    }

    public func profile(for context: FieldContext) -> String? {
        guard let domain = context.domain?.lowercased() else { return nil }
        let learned = profileByDomain
        if let exact = learned[domain] { return exact }
        // A profile chosen on one part of a university's site applies across it.
        return learned.first { domain.hasSuffix("." + $0.key) }?.value
    }

    public func rememberProfile(_ profileID: String, for context: FieldContext) {
        guard let domain = context.domain?.lowercased() else { return }
        var learned = profileByDomain
        learned[domain] = profileID
        profileByDomain = learned
    }

    public func forgetProfile(for domain: String) {
        var learned = profileByDomain
        learned.removeValue(forKey: domain)
        profileByDomain = learned
    }

    // MARK: Trigger

    public var triggerMode: TriggerMode {
        get { TriggerMode(rawValue: defaults.string(forKey: Key.triggerMode) ?? "") ?? .doubleCommand }
        set { defaults.set(newValue.rawValue, forKey: Key.triggerMode) }
    }

    // MARK: Hotkey

    public var hotKeyCode: Int {
        get { defaults.integer(forKey: Key.hotKeyCode) }
        set { defaults.set(newValue, forKey: Key.hotKeyCode) }
    }

    public var hotKeyModifiers: Int {
        get { defaults.integer(forKey: Key.hotKeyModifiers) }
        set { defaults.set(newValue, forKey: Key.hotKeyModifiers) }
    }

    // MARK: Behaviour

    /// When false, every match is confirmed in the HUD before it lands.
    public var autoInsertEnabled: Bool {
        get { defaults.bool(forKey: Key.autoInsertEnabled) }
        set { defaults.set(newValue, forKey: Key.autoInsertEnabled) }
    }

    /// Complete a field as you type, before the trigger is ever pressed.
    public var inlineSuggestionsEnabled: Bool {
        get { defaults.bool(forKey: Key.inlineSuggestions) }
        set { defaults.set(newValue, forKey: Key.inlineSuggestions) }
    }

    /// When false, matching stops at the local rules and never reaches the network.
    public var jevEnabled: Bool {
        get { defaults.bool(forKey: Key.jevEnabled) }
        set { defaults.set(newValue, forKey: Key.jevEnabled) }
    }

    /// Categories that always require confirmation no matter how confident the match.
    public var confirmedCategories: Set<VaultCategory> {
        get {
            let raw = defaults.stringArray(forKey: Key.confirmedCategories) ?? []
            return Set(raw.compactMap(VaultCategory.init(rawValue:)))
        }
        set { defaults.set(newValue.map(\.rawValue).sorted(), forKey: Key.confirmedCategories) }
    }

    // MARK: Denylist

    public var deniedBundleIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.deniedBundleIDs) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Key.deniedBundleIDs) }
    }

    public var deniedDomains: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.deniedDomains) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Key.deniedDomains) }
    }

    public func isDenied(_ context: FieldContext) -> Bool {
        if deniedBundleIDs.contains(context.bundleID) { return true }
        guard let domain = context.domain?.lowercased() else { return false }
        return deniedDomains.contains { denied in
            domain == denied || domain.hasSuffix("." + denied)
        }
    }

    // MARK: Jev API key

    /// Non-nil when the last attempt to store a key failed. Swallowing this is
    /// how a key silently fails to save and everything downstream looks broken
    /// for reasons that have nothing to do with it.
    public private(set) var jevKeyError: String?

    public var jevAPIKey: String {
        get { (try? Keychain.get(Self.apiKeyAccount)) .flatMap { $0 } ?? "" }
        set {
            do {
                if newValue.isEmpty {
                    try Keychain.delete(Self.apiKeyAccount)
                } else {
                    try Keychain.set(newValue, for: Self.apiKeyAccount, sensitive: false)
                }
                jevKeyError = nil
            } catch {
                jevKeyError = error.localizedDescription
                Log.app.error("Could not store the Jev key: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public var hasJevKey: Bool {
        (try? Keychain.storedAccounts().contains(Self.apiKeyAccount)) ?? false
    }
}
