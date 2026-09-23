import Foundation
import Observation

/// User-facing settings. Everything here is non-secret; the Jev API key is the one
/// exception and lives in the Keychain under its own service, reachable through
/// `jevAPIKey`.
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
        static let onboardingCompleted = "onboardingCompleted"
    }

    /// Keychain account for the API key.
    private static let apiKeyAccount = "jev_api_key"

    /// Where the Jev key lives: its own service, stored on this Mac only.
    ///
    /// Builds before this one kept it under the vault's service, despite a
    /// comment saying otherwise. That counted it as a saved detail, let "Clear
    /// and start over" delete it, and would have synced it along with the vault.
    public static let settingsService = "com.noelsason.Control.settings"

    private let defaults: UserDefaults
    private let settingsService: String
    /// Where older builds put the key. Read as a fallback until it has moved.
    private let legacyKeyService: String

    public init(
        defaults: UserDefaults = .standard,
        settingsService: String = Preferences.settingsService,
        legacyKeyService: String = Keychain.service
    ) {
        self.defaults = defaults
        self.settingsService = settingsService
        self.legacyKeyService = legacyKeyService
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

    // MARK: Setup

    /// Set once first-run setup has been finished or closed. Setup stays
    /// reachable from the menu either way.
    public var onboardingCompleted: Bool {
        get { defaults.bool(forKey: Key.onboardingCompleted) }
        set { defaults.set(newValue, forKey: Key.onboardingCompleted) }
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

    /// The key, from its own place first and from where older builds kept it
    /// second, so it keeps working whether or not it has moved yet.
    ///
    /// A read that *fails* — as opposed to finding nothing — used to become ""
    /// and silently switch Jev off. It now says why.
    public var jevAPIKey: String {
        get {
            do {
                if let key = try Keychain.get(Self.apiKeyAccount, service: settingsService) { return key }
                return try Keychain.get(Self.apiKeyAccount, service: legacyKeyService) ?? ""
            } catch {
                jevKeyError = "Couldn't read the Jev key: \(error.localizedDescription)"
                Log.app.error("Could not read the Jev key: \(error.localizedDescription, privacy: .public)")
                return ""
            }
        }
        set {
            do {
                if newValue.isEmpty {
                    try Keychain.delete(Self.apiKeyAccount, service: settingsService)
                } else {
                    try Keychain.set(newValue, for: Self.apiKeyAccount, sensitive: false, deviceOnly: true,
                                     service: settingsService)
                }
                // Whatever an older build left behind is superseded either way.
                try Keychain.delete(Self.apiKeyAccount, service: legacyKeyService)
                jevKeyError = nil
            } catch {
                jevKeyError = error.localizedDescription
                Log.app.error("Could not store the Jev key: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Read by the settings view on every redraw, so it only looks — a failure
    /// to look shows as "not set", and the next real read reports the error.
    public var hasJevKey: Bool {
        let here = (try? Keychain.storedAccounts(service: settingsService)) ?? []
        let legacy = (try? Keychain.storedAccounts(service: legacyKeyService)) ?? []
        return here.contains(Self.apiKeyAccount) || legacy.contains(Self.apiKeyAccount)
    }

    /// Moves a key stored by an older build into its own service: copy, read
    /// back, and only then delete the old one. A failure at any step leaves the
    /// key where it was, still working, and is retried on the next launch.
    public func migrateJevKeyIfNeeded() {
        do {
            guard let legacy = try Keychain.get(Self.apiKeyAccount, service: legacyKeyService) else { return }
            if try Keychain.get(Self.apiKeyAccount, service: settingsService) == nil {
                try Keychain.set(legacy, for: Self.apiKeyAccount, sensitive: false, deviceOnly: true,
                                 service: settingsService)
                guard try Keychain.get(Self.apiKeyAccount, service: settingsService) == legacy else {
                    Log.app.error("The Jev key did not read back after moving; leaving the original in place.")
                    return
                }
            }
            try Keychain.delete(Self.apiKeyAccount, service: legacyKeyService)
            Log.app.info("Moved the Jev key to its own keychain service.")
        } catch {
            Log.app.error("Could not move the Jev key: \(error.localizedDescription, privacy: .public)")
        }
    }
}
