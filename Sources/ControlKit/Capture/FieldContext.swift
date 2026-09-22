import CryptoKit
import Foundation

/// Everything Control knows about the text field the user is focused in.
///
/// This is the only thing that ever leaves the device (and only its non-value
/// parts — see `JevMatcher`). It deliberately does not carry the field's
/// contents: `isEmpty` records whether there is text, never what the text is.
public struct FieldContext: Sendable, Equatable, Codable {
    /// Human-readable name of the frontmost app, e.g. "Google Chrome".
    public var appName: String
    /// Bundle identifier of the frontmost app, e.g. "com.google.Chrome".
    public var bundleID: String
    /// Host only, never the full URL — query strings routinely carry tokens.
    public var domain: String?
    /// Accessibility role, e.g. "AXTextField".
    public var role: String?
    /// Accessibility subrole. `AXSecureTextField` here means "never touch this".
    public var subrole: String?
    /// The associated label. Highest-signal field by a wide margin.
    public var label: String?
    public var placeholder: String?
    public var helpText: String?
    /// Static text found near the field — section headings like "Mailing address"
    /// that disambiguate an otherwise meaningless label such as "Line 1".
    public var nearbyText: [String]
    /// Whether the field already has content. Never the content itself.
    public var isEmpty: Bool

    public init(
        appName: String,
        bundleID: String,
        domain: String? = nil,
        role: String? = nil,
        subrole: String? = nil,
        label: String? = nil,
        placeholder: String? = nil,
        helpText: String? = nil,
        nearbyText: [String] = [],
        isEmpty: Bool = true
    ) {
        self.appName = appName
        self.bundleID = bundleID
        self.domain = domain
        self.role = role
        self.subrole = subrole
        self.label = label
        self.placeholder = placeholder
        self.helpText = helpText
        self.nearbyText = nearbyText
        self.isEmpty = isEmpty
    }
}

public extension FieldContext {
    /// macOS reports password fields with this subrole. Hard stop.
    static let secureTextFieldSubrole = "AXSecureTextField"

    var isSecureField: Bool {
        subrole == Self.secureTextFieldSubrole
    }

    /// True when capture found nothing usable to match on. Worth surfacing to the
    /// user as "I couldn't read this field" rather than guessing from the app name.
    var hasNoDescriptiveText: Bool {
        descriptiveParts.isEmpty
    }

    /// The label-ish strings, most specific first, with blanks dropped.
    var descriptiveParts: [String] {
        [label, placeholder, helpText]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Lowercased, punctuation-collapsed haystack used by `LocalMatcher`.
    ///
    /// Nearby text is included but ordered last so that rules which scan the
    /// string left-to-right still favour the field's own label.
    var searchText: String {
        (descriptiveParts + nearbyText).map(Self.normalize).joined(separator: " | ")
    }

    /// Just the field's own label/placeholder/help, without ambient page text.
    var ownSearchText: String {
        descriptiveParts.map(Self.normalize).joined(separator: " | ")
    }

    /// Stable identity for the cache: same field on the same page/app maps to the
    /// same key across launches. Deliberately excludes `isEmpty`, which changes as
    /// the user types, and `nearbyText`, which shifts as pages re-render.
    var signature: String {
        let parts = [
            bundleID,
            domain ?? "",
            Self.normalize(label ?? ""),
            Self.normalize(placeholder ?? ""),
            role ?? "",
        ]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercase, strip punctuation to spaces, collapse runs of whitespace.
    /// "E-mail address *" and "email   address" both become "email address".
    static func normalize(_ raw: String) -> String {
        let lowered = raw.lowercased()
        var out = ""
        out.reserveCapacity(lowered.count)
        var lastWasSpace = true
        for scalar in lowered.unicodeScalars {
            let isWordish = CharacterSet.alphanumerics.contains(scalar)
            if isWordish {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
