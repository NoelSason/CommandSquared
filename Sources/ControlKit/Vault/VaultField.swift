import Foundation

public enum VaultCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case identity
    case contact
    case education
    case address
    case professional
    case payment

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .identity: "Identity"
        case .contact: "Contact"
        case .education: "Education"
        case .address: "Addresses"
        case .professional: "Professional"
        case .payment: "Payment"
        }
    }
}

/// How a value should be reshaped on the way into a field. Drives `ValueFormatter`.
public enum ValueKind: String, Codable, Sendable {
    case text
    case email
    case phone
    case url
    case date
    case monthYear
    case postalCode
    case number
    case cardNumber
}

/// One addressable thing Control knows about you.
///
/// `key` is the stable identifier used by the matcher, the cache, and the Keychain.
/// `detail` is what gets sent to Jev as the option's description, so it is written
/// for a model deciding "is *this* what the field is asking for?" — not as UI copy.
public struct VaultField: Sendable, Codable, Hashable, Identifiable {
    public var key: String
    public var label: String
    public var category: VaultCategory
    public var kind: ValueKind
    public var sensitive: Bool
    public var detail: String
    /// Non-nil for values assembled from other fields, e.g. `full_name`.
    public var derivedFrom: [String]?
    /// Built-in fields cannot be deleted, only cleared.
    public var isBuiltIn: Bool

    public var id: String { key }

    public init(
        key: String,
        label: String,
        category: VaultCategory,
        kind: ValueKind = .text,
        sensitive: Bool = false,
        detail: String,
        derivedFrom: [String]? = nil,
        isBuiltIn: Bool = true
    ) {
        self.key = key
        self.label = label
        self.category = category
        self.kind = kind
        self.sensitive = sensitive
        self.detail = detail
        self.derivedFrom = derivedFrom
        self.isBuiltIn = isBuiltIn
    }

    public var isDerived: Bool { derivedFrom?.isEmpty == false }
}
