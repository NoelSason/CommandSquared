import Foundation
import LocalAuthentication
import Security

public enum KeychainError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)
    case malformedData

    public var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "Keychain error \(status): \(message)"
        case .malformedData:
            return "Keychain item was not valid UTF-8."
        }
    }
}

/// Thin wrapper over the macOS Keychain for vault values.
///
/// Two storage classes:
///   - ordinary entries are plain generic-password items, readable while unlocked;
///   - `sensitive` entries carry a `SecAccessControl` with `.userPresence`, so macOS
///     itself demands Touch ID (or the login password) at read time. No crypto of
///     our own anywhere.
///
/// macOS has two keychains and Control has to cope with both. The modern
/// data-protection keychain is preferred, but items written by an earlier build —
/// or by a build without the entitlement for it — live in the legacy login
/// keychain. Every operation therefore tries the modern one and falls back,
/// including on "not found", which is what an item sitting in the other keychain
/// looks like.
public enum Keychain {
    public static let service = "com.noelsason.Control.vault"

    // MARK: Write

    public static func set(
        _ value: String,
        for account: String,
        sensitive: Bool,
        service: String = Keychain.service
    ) throws {
        let attributes = addAttributes(value, account, sensitive, service)
        do {
            try eitherKeychain(attributes) { SecItemAdd($0 as CFDictionary, nil) }
        } catch KeychainError.unexpectedStatus(errSecDuplicateItem) {
            // Something is already stored under this account. It may have been
            // written by a build with a different code signature, which cannot be
            // updated in place — only removed and rewritten.
            try? delete(account, service: service)
            try eitherKeychain(attributes) { SecItemAdd($0 as CFDictionary, nil) }
        }
    }

    private static func addAttributes(
        _ value: String,
        _ account: String,
        _ sensitive: Bool,
        _ service: String
    ) -> [CFString: Any] {
        var attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: Data(value.utf8),
        ]

        var error: Unmanaged<CFError>?
        if sensitive, let control = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &error
        ) {
            attributes[kSecAttrAccessControl] = control
        } else {
            attributes[kSecAttrAccessible] = sensitive
                ? kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                : kSecAttrAccessibleWhenUnlocked
        }
        return attributes
    }

    // MARK: Read

    /// Reads a value. For a `sensitive` entry this is what raises the Touch ID
    /// prompt — so never call it speculatively, only once the user has confirmed.
    public static func get(
        _ account: String,
        prompt: String? = nil,
        service: String = Keychain.service
    ) throws -> String? {
        var attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        if let prompt {
            let context = LAContext()
            context.localizedReason = prompt
            attributes[kSecUseAuthenticationContext] = context
        }

        var item: CFTypeRef?
        do {
            try eitherKeychain(attributes) { SecItemCopyMatching($0 as CFDictionary, &item) }
        } catch KeychainError.unexpectedStatus(errSecItemNotFound) {
            return nil
        }

        guard let data = item as? Data else { return nil }
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.malformedData
        }
        return string
    }

    /// Which accounts hold a value, *without* reading any of them.
    ///
    /// Attribute-only queries do not trip `.userPresence`, so this is safe to run
    /// on every launch. Both keychains are queried and the results unioned —
    /// checking only one silently hides everything written by an older build.
    public static func storedAccounts(service: String = Keychain.service) throws -> Set<String> {
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]

        var accounts = Set<String>()
        for modern in [true, false] {
            var query = attributes
            if modern { query[kSecUseDataProtectionKeychain] = true }

            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { continue }

            // Security returns a CFArray of CFDictionary. Swift bridges those keys
            // to `String`, NOT `CFString` — casting to [[CFString: Any]] compiles
            // and silently yields nil, which is how this went unnoticed.
            guard let entries = item as? [[String: Any]] else { continue }
            for entry in entries {
                if let account = entry[kSecAttrAccount as String] as? String {
                    accounts.insert(account)
                }
            }
        }
        return accounts
    }

    // MARK: Delete

    public static func delete(_ account: String, service: String = Keychain.service) throws {
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        // Delete from both keychains: the item may be in either, or in both.
        for modern in [true, false] {
            var query = attributes
            if modern { query[kSecUseDataProtectionKeychain] = true }
            _ = SecItemDelete(query as CFDictionary)
        }
    }

    /// Removes every value Control has stored, in both keychains. The escape hatch
    /// for items orphaned by a change of code signature, which the current build
    /// can neither read nor overwrite.
    public static func deleteAll(service: String = Keychain.service) throws {
        // Enumerate and delete one at a time. A single service-wide SecItemDelete
        // does not reliably clear every match across both keychains, and a
        // half-finished wipe is worse than none — the leftovers are exactly the
        // unreadable items this is meant to get rid of.
        for account in (try? storedAccounts(service: service)) ?? [] {
            try? delete(account, service: service)
        }

        // Sweep for anything the enumeration could not see.
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        for modern in [true, false] {
            var query = attributes
            if modern { query[kSecUseDataProtectionKeychain] = true }
            _ = SecItemDelete(query as CFDictionary)
        }
    }

    // MARK: Keychain selection

    /// Runs against the data-protection keychain, falling back to the legacy one.
    ///
    /// `errSecItemNotFound` is part of the fallback set on purpose: an item living
    /// in the legacy keychain looks exactly like a missing item to a modern query,
    /// and treating that as final is what makes older entries disappear.
    /// Which keychain answered last time. Once one of them is known to hold
    /// Control's items, try it first — otherwise every single read pays for a
    /// failed round trip to the other one before finding anything.
    private nonisolated(unsafe) static var preferModern = true

    private static func eitherKeychain(
        _ attributes: [CFString: Any],
        _ operation: ([CFString: Any]) -> OSStatus
    ) throws {
        var modern = attributes
        modern[kSecUseDataProtectionKeychain] = true
        let legacy = attributes

        let first = preferModern ? modern : legacy
        let second = preferModern ? legacy : modern

        let status = operation(first)
        if status == errSecSuccess { return }

        let retryable: Set<OSStatus> = [errSecMissingEntitlement, errSecParam, errSecItemNotFound]
        guard retryable.contains(status) else {
            throw KeychainError.unexpectedStatus(status)
        }

        let secondStatus = operation(second)
        guard secondStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(secondStatus)
        }
        preferModern.toggle()
    }
}
