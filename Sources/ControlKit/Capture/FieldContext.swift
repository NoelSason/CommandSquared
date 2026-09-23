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
    /// The HTML field name (`firstNameInput`, `billing_address.zip`), when known.
    /// Today only the browser importer has one; capture reads what the
    /// Accessibility API exposes, which is the label.
    public var fieldName: String?

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
        isEmpty: Bool = true,
        fieldName: String? = nil
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
        self.fieldName = fieldName
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

    /// The label-ish strings, most specific first, with blanks dropped. A field
    /// name counts too, once split into words: `firstNameInput` is a label by
    /// another name.
    var descriptiveParts: [String] {
        [label, placeholder, helpText, fieldName.map(Self.splitCamelCase)]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: Text for Chromium's patterns

    /// Label, placeholder and help text for `ChromiumPatterns`: lowercased, one
    /// string per attribute, **punctuation kept**.
    ///
    /// This is a different representation from `searchText` on purpose, and
    /// getting it wrong would look like it works while quietly failing:
    ///
    /// 1. The patterns were written and tested upstream against raw text, by the
    ///    same regex engine (ICU) that `NSRegularExpression` uses. `e.?mail`,
    ///    `(?<!\.)zip`, `address[_-]?line`, `m\.i\.` and `c-v-v` all encode
    ///    something about punctuation. `normalize()` turns punctuation into
    ///    spaces, so on normalised text they either stop matching or match what
    ///    they were written to exclude. Rewriting them for normalised text would
    ///    be translation with no oracle to check it against.
    /// 2. Anchors are per attribute. `^name`, `first$` and `^mm$` describe one
    ///    label, not `searchText`'s `label | placeholder | nearby` join.
    /// 3. `normalize()` is load-bearing for Control's own phrase rules, so it
    ///    stays exactly as it is and they keep using it.
    var patternLabelParts: [String] {
        [label, placeholder, helpText].compactMap { $0 }.map(Self.lowercasedCollapsingWhitespace).filter { !$0.isEmpty }
    }

    /// The field name for `ChromiumPatterns`, twice: as written (`fname`) and
    /// split at camel-case humps (`billing city`). Patterns must begin a word,
    /// so the split form finds `city` in `billingCity`, and the raw form keeps
    /// `fname` whole.
    var patternNameParts: [String] {
        guard let fieldName else { return [] }
        let forms = [fieldName, Self.splitCamelCase(fieldName)].map(Self.lowercasedCollapsingWhitespace)
        return forms[0] == forms[1] ? [forms[0]] : forms
    }

    /// Nearby text for `ChromiumPatterns`, one string per item.
    var patternNearbyParts: [String] {
        nearbyText.map(Self.lowercasedCollapsingWhitespace).filter { !$0.isEmpty }
    }

    static func lowercasedCollapsingWhitespace(_ raw: String) -> String {
        raw.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `firstNameInput` → `first Name Input`. Runs of capitals stay together, so
    /// `billingZIP` becomes `billing ZIP`, not `billing Z I P`.
    static func splitCamelCase(_ name: String) -> String {
        var spaced = ""
        var previous: Character?
        for character in name {
            if let previous, character.isUppercase, previous.isLowercase || previous.isNumber {
                spaced.append(" ")
            }
            spaced.append(character)
            previous = character
        }
        return spaced
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
