import Foundation

/// Reshapes a stored value to match what the target field appears to want.
///
/// The stored value is always the canonical form (E.164 phone, ISO date, bare
/// digits for a card). Everything here is a presentation decision made from the
/// field's own placeholder and label — a placeholder is the site telling you its
/// expected format, so mimic it when there is one and fall back to the most
/// common convention when there isn't.
public enum ValueFormatter {
    public static func format(_ value: String, kind: ValueKind, context: FieldContext) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        switch kind {
        case .text, .email, .number, .postalCode:
            return trimmed
        case .phone:
            return formatPhone(trimmed, context: context)
        case .date:
            return formatDate(trimmed, context: context)
        case .monthYear:
            return formatMonthYear(trimmed, context: context)
        case .cardNumber:
            return formatCardNumber(trimmed, context: context)
        case .url:
            return formatURL(trimmed, context: context)
        }
    }

    // MARK: Phone

    /// Canonical storage is E.164 ("+16615239570").
    static func formatPhone(_ value: String, context: FieldContext) -> String {
        let digits = value.digitsOnly
        let hint = context.ownSearchText + " " + (context.placeholder ?? "")

        // The field is explicitly asking for an international number.
        if value.hasPrefix("+"), hint.contains("country code") || hint.contains("international") {
            return value
        }

        // US 10-digit core, dropping a leading country code if present.
        let core = digits.count == 11 && digits.hasPrefix("1") ? String(digits.dropFirst()) : digits
        guard core.count == 10 else { return value }

        let area = core.prefix(3)
        let exchange = core.dropFirst(3).prefix(3)
        let line = core.suffix(4)

        if let placeholder = context.placeholder, placeholder.contains(where: \.isNumber) || placeholder.contains("_") {
            if placeholder.contains("(") { return "(\(area)) \(exchange)-\(line)" }
            if placeholder.contains("-") { return "\(area)-\(exchange)-\(line)" }
            if placeholder.contains(".") { return "\(area).\(exchange).\(line)" }
            if !placeholder.contains(" ") { return core }
        }

        if hint.contains("digits only") || hint.contains("no dashes") { return core }
        return "(\(area)) \(exchange)-\(line)"
    }

    // MARK: Dates

    /// Canonical storage is ISO 8601 ("2006-03-14").
    static func formatDate(_ value: String, context: FieldContext) -> String {
        guard let components = isoComponents(value) else { return value }
        let (year, month, day) = components
        let pad = { (n: Int) in String(format: "%02d", n) }
        let hint = (context.placeholder ?? "") + " " + context.ownSearchText

        if hint.lowercased().contains("dd/mm") { return "\(pad(day))/\(pad(month))/\(year)" }
        if hint.lowercased().contains("yyyy-mm") { return value }
        if hint.contains("-") && !hint.contains("/") { return "\(pad(month))-\(pad(day))-\(year)" }
        return "\(pad(month))/\(pad(day))/\(year)"
    }

    /// Canonical storage is "MM/YYYY".
    static func formatMonthYear(_ value: String, context: FieldContext) -> String {
        let digits = value.digitsOnly
        guard digits.count >= 4 else { return value }

        let month = String(digits.prefix(2))
        let year = String(digits.dropFirst(2))
        let shortYear = String(year.suffix(2))
        let hint = (context.placeholder ?? "") + " " + context.ownSearchText

        if hint.contains("YYYY") || hint.lowercased().contains("yyyy") { return "\(month)/\(year)" }
        if hint.contains("/") || hint.lowercased().contains("mm") { return "\(month)/\(shortYear)" }
        return "\(month)\(shortYear)"
    }

    // MARK: Card

    /// Canonical storage is bare digits. Most checkout fields reformat as you type,
    /// so bare digits is the safer default and grouping is opt-in via the placeholder.
    static func formatCardNumber(_ value: String, context: FieldContext) -> String {
        let digits = value.digitsOnly
        guard let placeholder = context.placeholder, placeholder.contains(" ") else { return digits }
        return stride(from: 0, to: digits.count, by: 4)
            .map { offset -> String in
                let start = digits.index(digits.startIndex, offsetBy: offset)
                let end = digits.index(start, offsetBy: min(4, digits.count - offset))
                return String(digits[start ..< end])
            }
            .joined(separator: " ")
    }

    // MARK: URLs

    /// A field labelled "GitHub username" wants `noelsason`, not the profile URL.
    static func formatURL(_ value: String, context: FieldContext) -> String {
        let hint = context.ownSearchText
        let wantsHandle = ["username", "handle", "user name", "screen name", "id"]
            .contains { hint.contains($0) }
        guard wantsHandle else { return value }

        let stripped = value
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "www.", with: "")
        let segments = stripped.split(separator: "/").map(String.init)
        guard segments.count > 1, let last = segments.last, !last.isEmpty else { return value }
        return last
    }

    // MARK: Helpers

    private static func isoComponents(_ value: String) -> (year: Int, month: Int, day: Int)? {
        let parts = value.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        return (year, month, day)
    }
}

extension String {
    var digitsOnly: String { filter(\.isNumber) }
}
