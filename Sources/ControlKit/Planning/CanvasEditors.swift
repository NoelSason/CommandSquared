import Foundation

/// Editors that draw their own text instead of using real text fields.
///
/// Google Docs, Figma and friends paint glyphs onto a canvas and keep only a
/// tiny hidden input alive for keyboard handling. Nothing Control does can reach
/// that text — not because of a bug, but because there is no text field there to
/// read. Several of them expose a real accessibility tree only when their own
/// screen-reader mode is switched on.
///
/// Failing with "no text field is focused" would be technically true and totally
/// useless. If we know the app, we can say what to do about it.
public enum CanvasEditors {
    public struct Advice: Sendable, Equatable {
        public let product: String
        public let instruction: String
    }

    static let byDomain: [String: Advice] = [
        "docs.google.com": Advice(
            product: "Google Docs",
            instruction: "Turn on screen reader support in Docs: Tools → Accessibility → Turn on screen reader support."
        ),
        "sheets.google.com": Advice(
            product: "Google Sheets",
            instruction: "Turn on screen reader support in Sheets: Tools → Accessibility → Turn on screen reader support."
        ),
        "slides.google.com": Advice(
            product: "Google Slides",
            instruction: "Turn on screen reader support in Slides: Tools → Accessibility → Turn on screen reader support."
        ),
        "figma.com": Advice(
            product: "Figma",
            instruction: "Figma draws its own text, so Control can't read or fill it."
        ),
        "overleaf.com": Advice(
            product: "Overleaf",
            instruction: "Overleaf's editor draws its own text, so Control can't read or fill it."
        ),
    ]

    static let byBundleID: [String: Advice] = [
        "com.figma.Desktop": Advice(
            product: "Figma",
            instruction: "Figma draws its own text, so Control can't read or fill it."
        ),
    ]

    /// Advice for a place Control is known to be unable to reach, if this is one.
    public static func advice(bundleID: String, domain: String?) -> Advice? {
        if let advice = byBundleID[bundleID] { return advice }
        guard let domain = domain?.lowercased() else { return nil }
        for (host, advice) in byDomain where domain == host || domain.hasSuffix("." + host) {
            return advice
        }
        return nil
    }
}
