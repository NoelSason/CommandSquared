import Foundation

/// Expands `{placeholders}` in a piece of text.
///
/// Two things use this. Snippets are stored templates — "Hi, I'm {full_name},
/// reachable at {email_school}" — and selection substitution runs the same
/// expansion over whatever text you have highlighted, so you can type a rough
/// draft with gaps and fill them in one keystroke.
///
/// Unknown placeholders are left exactly as written. Silently deleting something
/// it did not understand would be the worst possible failure for text the user is
/// about to send.
public enum TemplateEngine {
    /// What a template needs from the outside world, so expansion stays pure and
    /// testable — no clock, no pasteboard, no Keychain in here.
    public struct Environment: Sendable {
        public var now: Date
        public var calendar: Calendar
        public var locale: Locale
        public var clipboard: String?
        /// Resolves a vault key to its value. Returns nil for unknown or empty.
        public var value: @Sendable (String) -> String?

        public init(
            now: Date = Date(),
            calendar: Calendar = .current,
            locale: Locale = .current,
            clipboard: String? = nil,
            value: @escaping @Sendable (String) -> String? = { _ in nil }
        ) {
            self.now = now
            self.calendar = calendar
            self.locale = locale
            self.clipboard = clipboard
            self.value = value
        }
    }

    public struct Result: Sendable, Equatable {
        public var text: String
        /// Where the caret should land, if the template said so with `{cursor}`,
        /// in UTF-16 code units from the start of `text` — the unit the
        /// Accessibility API's text ranges count in. Counting `Character`s put
        /// the caret in the wrong place after an emoji or a `\r\n`.
        public var cursorOffset: Int?
        /// Placeholders that could not be resolved, left in place in `text`.
        public var unresolved: [String]

        public var isFullyResolved: Bool { unresolved.isEmpty }
    }

    /// True when the text contains anything worth expanding. Used to decide
    /// whether a selection is a template at all.
    public static func containsPlaceholder(_ text: String) -> Bool {
        guard let open = text.firstIndex(of: "{") else { return false }
        return text[open...].contains("}")
    }

    public static func expand(_ template: String, in environment: Environment) -> Result {
        var output = ""
        var unresolved: [String] = []
        var cursorOffset: Int?
        var remainder = Substring(template)

        while let open = remainder.firstIndex(of: "{") {
            guard let close = remainder[open...].firstIndex(of: "}") else { break }

            output += remainder[remainder.startIndex ..< open]
            let token = String(remainder[remainder.index(after: open) ..< close])
            remainder = remainder[remainder.index(after: close)...]

            if token == "cursor" {
                cursorOffset = output.utf16.count
                continue
            }
            if let resolved = resolve(token, in: environment) {
                output += resolved
            } else {
                unresolved.append(token)
                output += "{\(token)}"
            }
        }

        output += remainder
        return Result(text: output, cursorOffset: cursorOffset, unresolved: unresolved)
    }

    // MARK: Token resolution

    static func resolve(_ token: String, in environment: Environment) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if trimmed == "clipboard" { return environment.clipboard }

        let parts = parse(trimmed)
        switch parts.head {
        case "date": return date(parts, in: environment, includeTime: false)
        case "time": return date(parts, in: environment, includeTime: true)
        default: return environment.value(trimmed)
        }
    }

    /// A token is `head` then an optional `±shift` then an optional `:format`,
    /// and the two are independent — `{date+1d:HH:mm}` asks for tomorrow at this
    /// hour, which needs both.
    static func parse(_ token: String) -> (head: String, shift: String?, format: String?) {
        var rest = Substring(token)

        var format: String?
        if let colon = rest.firstIndex(of: ":") {
            format = String(rest[rest.index(after: colon)...])
            rest = rest[..<colon]
        }

        var shift: String?
        if let sign = rest.firstIndex(where: { $0 == "+" || $0 == "-" }) {
            shift = String(rest[sign...])
            rest = rest[..<sign]
        }

        return (String(rest).lowercased(), shift, format)
    }

    static func date(
        _ parts: (head: String, shift: String?, format: String?),
        in environment: Environment,
        includeTime: Bool
    ) -> String? {
        var moment = environment.now
        let format = parts.format

        if let expression = parts.shift {
            guard let shifted = shift(moment, by: expression, in: environment) else { return nil }
            moment = shifted
        }

        let formatter = DateFormatter()
        formatter.locale = environment.locale
        formatter.calendar = environment.calendar
        formatter.timeZone = environment.calendar.timeZone

        if let format {
            formatter.dateFormat = format
        } else if includeTime {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        } else {
            formatter.dateFormat = "MM/dd/yyyy"
        }
        return formatter.string(from: moment)
    }

    /// `+7d`, `-1mo`, `+2w`, `+1y`. Calendar arithmetic, not multiplication —
    /// adding a month to 31 January has to land in February, and adding a day
    /// across a clock change has to stay the same hour.
    static func shift(_ date: Date, by expression: String, in environment: Environment) -> Date? {
        var amount = ""
        var unit = ""
        for character in expression {
            if character == "+" { continue }
            if character == "-" { amount.append(character); continue }
            if character.isNumber { amount.append(character) } else { unit.append(character) }
        }
        guard let magnitude = Int(amount) else { return nil }

        let component: Calendar.Component
        switch unit.lowercased() {
        case "d", "day", "days": component = .day
        case "w", "wk", "week", "weeks": component = .weekOfYear
        case "mo", "month", "months": component = .month
        case "y", "yr", "year", "years": component = .year
        case "h", "hr", "hour", "hours": component = .hour
        case "min", "mins", "minute", "minutes": component = .minute
        default: return nil
        }

        return environment.calendar.date(byAdding: component, value: magnitude, to: date)
    }
}
