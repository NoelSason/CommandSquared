import AppKit
import PDFKit
import UniformTypeIdentifiers

/// The plain text of a document the user picks — a resume, a bio, notes — for
/// the "About you" box. Read on this Mac; nothing is uploaded.
enum DocumentText {
    /// What the picker offers. Word and RTF go through `NSAttributedString`,
    /// which reads both natively.
    static let types: [UTType] = [
        .pdf, .plainText, .rtf, .rtfd, .html,
        UTType("org.openxmlformats.wordprocessingml.document"),
        UTType("com.microsoft.word.doc"),
        UTType(filenameExtension: "md"),
    ].compactMap { $0 }

    /// A resume is a few thousand characters; this is a guard against a book.
    static let maxLength = 40_000

    static func read(_ url: URL) -> String? {
        let raw: String?
        if url.pathExtension.lowercased() == "pdf" {
            raw = PDFDocument(url: url)?.string
        } else if let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
            raw = attributed.string
        } else {
            raw = try? String(contentsOf: url, encoding: .utf8)
        }
        guard let raw else { return nil }
        let tidied = tidy(raw)
        return tidied.isEmpty ? nil : String(tidied.prefix(maxLength))
    }

    /// PDFs come out with ragged spacing: trailing spaces, runs of blank
    /// lines, and non-breaking spaces. None of it carries meaning here.
    static func tidy(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
