import CoreGraphics
import Foundation

/// Refuses to fill things the user cannot see.
///
/// Hidden-field harvesting is a real, measured attack on autofill: a form carries
/// invisible inputs alongside the visible ones, the filler populates them, and
/// they are submitted without the user ever knowing they existed. Control is
/// structurally immune to the usual multi-field version because it fills exactly
/// the one field you are focused in — but a page can still move focus to an input
/// positioned off-screen or sized to nothing.
///
/// The rule: if it has a frame, that frame has to be somewhere a person could
/// have seen and clicked.
///
/// Known gap: a full-size input made invisible with `opacity: 0` (on itself or
/// an ancestor) passes. The Accessibility API reports frames, not opacity or
/// paint, so there is nothing here to check. The single-field fill still needs
/// the user to have focused it, and whole-form fill shows every value before
/// writing anything.
public enum FieldVisibility {
    /// Smaller than this in either direction is not a field anyone clicked into.
    /// Hidden inputs are typically 0×0 or 1×1.
    public static let minimumSide: CGFloat = 4

    public enum Verdict: Sendable, Equatable {
        case visible
        /// No frame reported. Common in native controls; not evidence of anything.
        case unknown
        case tooSmall
        case offScreen
    }

    public static func verdict(frame: CGRect?, screens: [CGRect]) -> Verdict {
        guard let frame else { return .unknown }

        if frame.width < minimumSide || frame.height < minimumSide { return .tooSmall }
        // A frame wholly outside every screen was positioned somewhere no one
        // could have clicked.
        guard screens.contains(where: { $0.intersects(frame) }) else { return .offScreen }
        return .visible
    }

    /// `unknown` is allowed through: plenty of legitimate native controls decline
    /// to report a frame, and refusing those would break filling in real apps to
    /// defend against a web attack. Anything that *does* report a frame has to
    /// justify it.
    public static func isFillable(frame: CGRect?, screens: [CGRect]) -> Bool {
        switch verdict(frame: frame, screens: screens) {
        case .visible, .unknown: true
        case .tooSmall, .offScreen: false
        }
    }
}

/// Knows when a focused text field belongs to the browser rather than the page.
///
/// A browser's address bar, find bar, and search box are all ordinary text
/// fields, and Control will happily type your street address into one. The
/// structural tell is that page content lives under an `AXWebArea` and browser
/// chrome does not.
public enum BrowserChrome {
    static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "org.chromium.Chromium",
    ]

    public static func isBrowser(bundleID: String) -> Bool {
        browserBundleIDs.contains(bundleID)
    }

    /// True when this is a browser field that sits outside any web content.
    public static func isChrome(bundleID: String, insideWebArea: Bool) -> Bool {
        isBrowser(bundleID: bundleID) && !insideWebArea
    }
}
