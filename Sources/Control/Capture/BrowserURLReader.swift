import AppKit
import ApplicationServices
import Foundation

/// Finds the page domain behind a focused web input.
///
/// Host only, deliberately. A full URL routinely carries session tokens and
/// application state in its query string, and none of that has any business
/// going into a matching request.
@MainActor
enum BrowserURLReader {
    private static let webAreaRole = "AXWebArea"
    private static let urlAttribute = "AXURL"

    /// Whether the element sits under page content at all. A browser field that
    /// does not is the address bar, the find bar, or a dialog — never a form.
    static func isInsideWebArea(_ element: AXUIElement, levels: Int = 16) -> Bool {
        var current = element
        for _ in 0 ..< levels {
            if AX.string(current, kAXRoleAttribute) == webAreaRole { return true }
            guard let parent = AX.element(current, kAXParentAttribute) else { return false }
            current = parent
        }
        return false
    }

    static func domain(for element: AXUIElement, app: NSRunningApplication) -> String? {
        if let fromWebArea = walkToWebArea(from: element) { return host(fromWebArea) }

        // Safari and some others expose the document URL on the window instead.
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        if let window = AX.element(appElement, kAXFocusedWindowAttribute),
           let document = AX.string(window, kAXDocumentAttribute) {
            return host(document)
        }
        return nil
    }

    private static func walkToWebArea(from element: AXUIElement, levels: Int = 16) -> String? {
        var current = element
        for _ in 0 ..< levels {
            if AX.string(current, kAXRoleAttribute) == webAreaRole {
                return AX.string(current, urlAttribute)
            }
            guard let parent = AX.element(current, kAXParentAttribute) else { return nil }
            current = parent
        }
        return nil
    }

    private static func host(_ urlString: String) -> String? {
        guard let host = URLComponents(string: urlString)?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
