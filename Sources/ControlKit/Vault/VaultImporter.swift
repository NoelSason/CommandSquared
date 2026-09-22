import Foundation

public enum ImportSource: String, Sendable, Codable, CaseIterable {
    case contacts
    case vCard
    case browser

    public var title: String {
        switch self {
        case .contacts: "Contacts"
        case .vCard: "vCard file"
        case .browser: "Browser autofill"
        }
    }
}

/// One proposed value, before the user has agreed to it.
public struct ImportedValue: Sendable, Equatable, Identifiable {
    public let key: String
    public let value: String
    public let source: ImportSource
    /// Where it came from in the source — an HTML field name, a vCard property.
    /// Shown in the review list, because seeing `project-name` next to
    /// "Full name" is what makes a bad row obvious at a glance.
    public let origin: String
    public let confidence: Double

    public var id: String { "\(source.rawValue)|\(key)|\(value)" }

    /// Ticked by default only when the mapping is not in doubt.
    public var isConfident: Bool { confidence >= 0.85 }

    public init(key: String, value: String, source: ImportSource, origin: String, confidence: Double) {
        self.key = key
        self.value = value
        self.source = source
        self.origin = origin
        self.confidence = confidence
    }
}

public struct BrowserAutofillRow: Sendable, Equatable {
    public let fieldName: String
    public let value: String
    public let useCount: Int

    public init(fieldName: String, value: String, useCount: Int) {
        self.fieldName = fieldName
        self.value = value
        self.useCount = useCount
    }
}

/// Turns things you already have into vault entries.
///
/// Typing forty fields by hand is the worst part of first run. All the parsing
/// here is pure — the app supplies rows and text, this decides what they mean —
/// so the mapping is testable without a browser or a Contacts permission prompt.
public enum VaultImporter {
    /// Browser field names are labels by another name, so they go through the
    /// same matcher that decides what to fill. Nothing bespoke, and it improves
    /// whenever the matcher does.
    public static let minimumConfidence = MatchThresholds.autoInsert

    // MARK: Browser autofill

    public static func fromBrowserAutofill(_ rows: [BrowserAutofillRow]) -> [ImportedValue] {
        let matcher = LocalMatcher()
        let allKeys = Set(VaultSchema.builtIn.filter { !$0.isDerived && !$0.sensitive }.map(\.key))

        var best: [String: ImportedValue] = [:]
        var bestUse: [String: Int] = [:]

        for row in rows {
            let trimmed = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 200 else { continue }

            let context = FieldContext(
                appName: "Browser",
                bundleID: "import",
                label: humanize(row.fieldName)
            )
            guard let top = matcher.match(context, fillable: allKeys).first,
                  top.score >= minimumConfidence
            else { continue }

            // The same key turns up under many field names. Keep whichever value
            // the browser filled most often — that is the one actually in use.
            if let existing = bestUse[top.key], existing >= row.useCount { continue }
            bestUse[top.key] = row.useCount
            best[top.key] = ImportedValue(
                key: top.key,
                value: trimmed,
                source: .browser,
                origin: row.fieldName,
                confidence: top.score
            )
        }

        return best.values.sorted { ($0.confidence, $0.key) > ($1.confidence, $1.key) }
    }

    /// `firstNameInput` and `first_name` are both "first name" to a human, and the
    /// matcher only understands the human form.
    public static func humanize(_ fieldName: String) -> String {
        var spaced = ""
        var previous: Character?
        for character in fieldName {
            // Split camelCase, but not runs of capitals like "ZIP".
            if let previous, character.isUppercase, previous.isLowercase || previous.isNumber {
                spaced.append(" ")
            }
            spaced.append(character)
            previous = character
        }
        return FieldContext.normalize(spaced)
    }

    // MARK: vCard

    /// Parses the subset of vCard that describes a person. Handles folded lines
    /// and escaped separators; ignores photos, notes, and everything else.
    public static func parseVCard(_ text: String, source: ImportSource = .vCard) -> [ImportedValue] {
        var values: [String: ImportedValue] = [:]

        func offer(_ key: String, _ value: String, _ origin: String, _ confidence: Double = 1.0) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, values[key] == nil else { return }
            values[key] = ImportedValue(key: key, value: trimmed, source: source,
                                        origin: origin, confidence: confidence)
        }

        for line in unfold(text) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let head = String(line[line.startIndex ..< colon]).uppercased()
            let body = unescape(String(line[line.index(after: colon)...]))
            let name = head.split(separator: ";").first.map(String.init) ?? head
            let parameters = head.uppercased()

            switch name {
            case "N":
                // Family;Given;Additional;Prefix;Suffix
                let parts = splitComponents(body)
                if parts.count > 0 { offer("family_name", parts[0], "N") }
                if parts.count > 1 { offer("given_name", parts[1], "N") }
                if parts.count > 2 { offer("middle_name", parts[2], "N") }

            case "NICKNAME":
                offer("preferred_name", body.split(separator: ",").first.map(String.init) ?? body, "NICKNAME")

            case "EMAIL":
                // A .edu address is a school address; Control keeps those apart
                // and nothing in vCard does.
                let key = body.lowercased().hasSuffix(".edu") ? "email_school" : "email_personal"
                offer(key, body, "EMAIL", 0.9)

            case "TEL":
                guard parameters.contains("CELL") || parameters.contains("MOBILE") || values["phone_mobile"] == nil
                else { break }
                offer("phone_mobile", body, "TEL", 0.9)

            case "ADR":
                // ;;street;city;region;postcode;country
                let parts = splitComponents(body)
                let prefix = parameters.contains("WORK") ? "campus" : "home"
                if parts.count > 2 { offer("\(prefix)_street_1", parts[2], "ADR") }
                if parts.count > 3 { offer("\(prefix)_city", parts[3], "ADR") }
                if parts.count > 4 { offer("\(prefix)_state", parts[4], "ADR") }
                if parts.count > 5 { offer("\(prefix)_postal", parts[5], "ADR") }
                if parts.count > 6, prefix == "home" { offer("home_country", parts[6], "ADR") }

            case "ORG":
                offer("current_org", splitComponents(body).first ?? body, "ORG", 0.85)

            case "TITLE":
                offer("current_title", body, "TITLE", 0.85)

            case "BDAY":
                offer("date_of_birth", isoDate(body), "BDAY")

            case "URL":
                let host = body.lowercased()
                if host.contains("github.com") {
                    offer("github_url", body, "URL")
                } else if host.contains("linkedin.com") {
                    offer("linkedin_url", body, "URL")
                } else {
                    offer("website_url", body, "URL", 0.8)
                }

            default:
                break
            }
        }

        return values.values.sorted { ($0.confidence, $0.key) > ($1.confidence, $1.key) }
    }

    // MARK: vCard plumbing

    /// A vCard line may continue on the next line, marked by leading whitespace.
    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else if !raw.isEmpty {
                lines.append(String(raw))
            }
        }
        return lines
    }

    /// Splits on unescaped semicolons.
    static func splitComponents(_ value: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var escaped = false
        for character in value {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == ";" {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// vCard dates come as `20060101` or `2006-01-01`; the vault stores ISO.
    static func isoDate(_ value: String) -> String {
        let digits = value.filter(\.isNumber)
        guard digits.count == 8 else { return value }
        let year = digits.prefix(4)
        let month = digits.dropFirst(4).prefix(2)
        let day = digits.suffix(2)
        return "\(year)-\(month)-\(day)"
    }

    // MARK: Merging

    /// Later sources fill gaps but never overwrite an earlier, more trusted one.
    public static func merge(_ groups: [[ImportedValue]]) -> [ImportedValue] {
        var seen = Set<String>()
        var merged: [ImportedValue] = []
        for group in groups {
            for value in group where seen.insert(value.key).inserted {
                merged.append(value)
            }
        }
        return merged.sorted { ($0.confidence, $0.key) > ($1.confidence, $1.key) }
    }
}
