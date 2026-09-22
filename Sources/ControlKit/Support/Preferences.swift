import Foundation
import Observation

/// User-facing settings. Everything here is non-secret; the Jev API key is the one
/// exception and lives in the Keychain, reachable through `jevAPIKey`.
@MainActor
@Observable
public final class Preferences {
    private enum Key {
        static let triggerMode = "triggerMode"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let deniedBundleIDs = "deniedBundleIDs"
        static let deniedDomains = "deniedDomains"
        static let jevEnabled = "jevEnabled"
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
            Key.autoInsertEnabled: true,
            Key.confirmedCategories: [VaultCategory.payment.rawValue],
        ])
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

    public var jevAPIKey: String {
        get { (try? Keychain.get(Self.apiKeyAccount)) .flatMap { $0 } ?? "" }
        set {
            if newValue.isEmpty {
                try? Keychain.delete(Self.apiKeyAccount)
            } else {
                try? Keychain.set(newValue, for: Self.apiKeyAccount, sensitive: false)
            }
        }
    }

    public var hasJevKey: Bool {
        (try? Keychain.storedAccounts().contains(Self.apiKeyAccount)) ?? false
    }
}
