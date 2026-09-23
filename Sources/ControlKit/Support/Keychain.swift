import Foundation
import LocalAuthentication
import Security

public enum KeychainError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)
    case malformedData
    /// Touch ID or the password didn't confirm it's the user, or they cancelled.
    case notAuthenticated(String)

    public var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "Keychain error \(status): \(message)"
        case .malformedData:
            return "Keychain item was not valid UTF-8."
        case let .notAuthenticated(message):
            return message
        }
    }
}

/// Thin wrapper over the macOS Keychain for vault values.
///
/// Two storage classes:
///   - ordinary entries are plain generic-password items, readable while unlocked;
///   - `sensitive` entries are read only after Touch ID (or the login password),
///     and never leave this Mac. When the build has the keychain entitlement they
///     also carry a `SecAccessControl` with `.userPresence`, so macOS itself
///     enforces that. Without it — a Developer ID build with no provisioning
///     profile — macOS refuses any such item (`errSecMissingEntitlement`, in both
///     keychains), so the value goes in the login keychain, this device only, and
///     `get` asks for Touch ID itself before reading it. No crypto of our own
///     anywhere.
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

    /// - Parameter deviceOnly: keep a non-sensitive item on this Mac only. For
    ///   credentials such as the Jev key, which must never leave with the vault.
    public static func set(
        _ value: String,
        for account: String,
        sensitive: Bool,
        deviceOnly: Bool = false,
        service: String = Keychain.service
    ) throws {
        do {
            try add(addAttributes(value, account, sensitive, deviceOnly, service), account: account, service: service)
        } catch KeychainError.unexpectedStatus(errSecMissingEntitlement) where sensitive {
            // No entitlement for macOS's own Touch ID lock. Keep the value on
            // this Mac only; `get` asks for Touch ID before every read.
            try add(addAttributes(value, account, false, true, service), account: account, service: service)
        }
    }

    private static func add(_ attributes: [CFString: Any], account: String, service: String) throws {
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
        _ deviceOnly: Bool,
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
            attributes[kSecAttrAccessible] = sensitive || deviceOnly
                ? kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                : kSecAttrAccessibleWhenUnlocked
        }
        return attributes
    }

    // MARK: Read

    /// Reads a value. With a `prompt` — every read of a `sensitive` entry — this
    /// asks for Touch ID first, so never call it speculatively, only once the
    /// user has confirmed.
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
            // Control asks, rather than leaving it to the item: an item saved
            // without macOS's lock would otherwise read with no prompt at all.
            // The confirmed context goes with the query, so an item that does
            // carry the lock doesn't ask a second time.
            attributes[kSecUseAuthenticationContext] = try authenticate(prompt)
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
        var failures: [OSStatus] = []
        for modern in [true, false] {
            var query = attributes
            if modern { query[kSecUseDataProtectionKeychain] = true }

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            // Nothing stored, or no entitlement for the modern keychain, are
            // ordinary answers. Anything else is a real failure.
            guard status == errSecSuccess else {
                if status != errSecItemNotFound, status != errSecMissingEntitlement { failures.append(status) }
                continue
            }

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
        // If both keychains failed, an empty answer would make the whole vault
        // look empty with no explanation — which is how this went unnoticed.
        // One keychain failing while the other answers is still worth knowing.
        if let failure = failures.first {
            if failures.count == 2 { throw KeychainError.unexpectedStatus(failure) }
            Log.app.error("One keychain could not be listed (status \(failure)); showing what the other holds.")
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

    // MARK: Authentication

    /// Confirms it's the user — Touch ID, or the login password — and returns
    /// the context that proves it. Replaceable so tests can run without a finger.
    nonisolated(unsafe) static var authenticate: (_ reason: String) throws -> LAContext = askForTouchID

    /// Blocks until the user answers. The prompt is macOS's own window and the
    /// answer arrives on a private queue, so waiting here holds nothing up that
    /// the prompt needs — the same wait a `.userPresence` read does inside
    /// `SecItemCopyMatching`.
    static func askForTouchID(_ reason: String) throws -> LAContext {
        let context = LAContext()
        let answer = Answer()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, error in
            answer.ok = ok
            answer.error = error
            answer.done.signal()
        }
        answer.done.wait()
        guard answer.ok else { throw KeychainError.notAuthenticated(message(for: answer.error)) }
        return context
    }

    /// Written on LocalAuthentication's queue before `done` is signalled, read
    /// only after the wait: the semaphore orders every access.
    private final class Answer: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var ok = false
        var error: Error?
    }

    private static func message(for error: Error?) -> String {
        switch (error as? LAError)?.code {
        case .userCancel?, .systemCancel?, .appCancel?: "Cancelled."
        case .authenticationFailed?: "Touch ID didn't recognise you."
        case .biometryLockout?: "Touch ID is locked. Unlock your Mac with your password, then try again."
        case .passcodeNotSet?: "Set a login password on this Mac to protect this."
        default: error?.localizedDescription ?? "Couldn't confirm it's you."
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
