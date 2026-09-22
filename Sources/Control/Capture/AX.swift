import ControlKit
import ApplicationServices
import AppKit
import Foundation

/// Small typed wrapper over the Accessibility C API.
///
/// Everything here stays on the main actor: `AXUIElement` is a CFType with no
/// Sendable guarantees, and the AX API expects to be driven from the main thread.
/// Only `FieldContext` — which is Sendable — leaves this layer.
@MainActor
enum AX {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system "grant Accessibility access" prompt if not yet trusted.
    @discardableResult
    static func requestTrust() -> Bool {
        // The SDK exposes `kAXTrustedCheckOptionPrompt` as a global `var`, which
        // Swift 6 rejects as shared mutable state. The key's value is stable.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copy(element, attribute) else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }

    /// Reads a value attribute without trimming or nil-ing on empty — the caller
    /// needs to distinguish "" from "unreadable".
    static func rawValue(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard let value = copy(element, attribute) as? [AnyObject] else { return [] }
        return value.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            return (item as! AXUIElement)
        }
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
    }

    @discardableResult
    static func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }

    static func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        copyWithError(element, attribute).value
    }

    static func copyWithError(_ element: AXUIElement, _ attribute: String) -> (value: AnyObject?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (error == .success ? value : nil, error)
    }

    static func attributeNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    static func same(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFEqual(lhs, rhs)
    }

    /// Chrome and Electron expose a stub accessibility tree until an assistive
    /// client asks for the real one. `AXEnhancedUserInterface` would also do it
    /// but has known side effects on window management, so only the narrower
    /// `AXManualAccessibility` is set here.
    private static var enabledApps = Set<pid_t>()

    /// Returns true when this call is what turned it on, so the caller knows to
    /// give the app a moment to build its tree before reading from it.
    ///
    /// The pid is only remembered once a set actually succeeds. Caching it on a
    /// failed attempt would mean never trying again for the lifetime of the app.
    @discardableResult
    static func enableManualAccessibility(for pid: pid_t) -> Bool {
        guard !enabledApps.contains(pid) else { return false }

        let app = AXUIElementCreateApplication(pid)
        let manual = set(app, "AXManualAccessibility", kCFBooleanTrue)
        // Chromium answers to AXManualAccessibility; some Electron builds only
        // wake up for AXEnhancedUserInterface. That one has known side effects on
        // window management, so it is a fallback, never the first move.
        let enhanced = manual ? false : set(app, "AXEnhancedUserInterface", kCFBooleanTrue)

        Log.capture.debug("Waking accessibility for pid \(pid): manual=\(manual) enhanced=\(enhanced)")

        guard manual || enhanced else { return false }
        enabledApps.insert(pid)
        return true
    }
}

extension AX {
    /// The element's on-screen rectangle, converted from Accessibility's
    /// top-left-origin global space into Cocoa's bottom-left-origin space.
    static func frame(_ element: AXUIElement) -> NSRect? {
        guard let positionValue = copy(element, kAXPositionAttribute),
              let sizeValue = copy(element, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }

        // AX measures y downward from the top of the primary screen.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? size.height
        return NSRect(
            x: point.x,
            y: primaryHeight - point.y - size.height,
            width: size.width,
            height: size.height
        )
    }
}
