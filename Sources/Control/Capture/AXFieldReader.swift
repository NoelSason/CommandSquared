import AppKit
import ApplicationServices
import ControlKit
import Foundation

/// The focused text field plus everything Control could learn about it.
///
/// The `AXUIElement` is held so the same element can be written back to after the
/// match resolves. It is re-verified at insert time, because a match that went out
/// to Jev may return after the user has moved on.
@MainActor
struct FocusedField {
    let element: AXUIElement
    let context: FieldContext
    /// The app that owned focus when the hotkey fired. Kept so the picker can
    /// hand focus back before inserting.
    let app: NSRunningApplication
}

@MainActor
enum AXFieldReader {
    private static let editableRoles: Set<String> = [
        kAXTextFieldRole,
        kAXTextAreaRole,
        kAXComboBoxRole,
        kAXSearchFieldSubrole,
    ]

    static func readFocusedField() async -> Result<FocusedField, BlockReason> {
        guard AX.isTrusted else { return .failure(.noFocusedField) }

        guard let app = NSWorkspace.shared.frontmostApplication else {
            return .failure(.noFocusedField)
        }

        // Chromium and Electron ship a stub accessibility tree until an assistive
        // client asks for the real one, and building it is not instant. Without
        // this pause the very first press in a browser finds nothing.
        if AX.enableManualAccessibility(for: app.processIdentifier) {
            try? await Task.sleep(for: .milliseconds(150))
        }

        guard let focused = await focusedElement(for: app) else {
            Log.capture.debug("No focused element in \(app.localizedName ?? "?", privacy: .public)")
            return .failure(.noFocusedField)
        }

        let role = AX.string(focused, kAXRoleAttribute)
        let subrole = AX.string(focused, kAXSubroleAttribute)

        // Password fields are refused before anything else reads from them.
        if subrole == FieldContext.secureTextFieldSubrole {
            return .success(FocusedField(
                element: focused,
                context: FieldContext(
                    appName: app.localizedName ?? "Unknown",
                    bundleID: app.bundleIdentifier ?? "unknown",
                    role: role,
                    subrole: subrole
                ),
                app: app
            ))
        }

        Log.capture.debug("""
            Focused element in \(app.localizedName ?? "?", privacy: .public): \
            role=\(role ?? "nil", privacy: .public) subrole=\(subrole ?? "nil", privacy: .public)
            """)

        guard isEditable(focused, role: role, subrole: subrole) else {
            return .failure(.notEditable)
        }

        let context = FieldContext(
            appName: app.localizedName ?? "Unknown",
            bundleID: app.bundleIdentifier ?? "unknown",
            domain: BrowserURLReader.domain(for: focused, app: app),
            role: role,
            subrole: subrole,
            label: label(for: focused),
            placeholder: AX.string(focused, kAXPlaceholderValueAttribute),
            helpText: AX.string(focused, kAXHelpAttribute),
            nearbyText: nearbyText(around: focused),
            isEmpty: (AX.rawValue(focused, kAXValueAttribute) ?? "").isEmpty
        )

        return .success(FocusedField(element: focused, context: context, app: app))
    }

    // MARK: Finding focus

    /// The system-wide query is the right one and usually answers. Some apps
    /// only answer the same question asked of their own application element,
    /// so fall back to that before giving up — and retry once, since focus can
    /// still be settling right after a hotkey fires.
    private static func focusedElement(for app: NSRunningApplication) async -> AXUIElement? {
        let pid = app.processIdentifier
        let systemWide = AXUIElementCreateSystemWide()
        let appElement = AXUIElementCreateApplication(pid)

        // Chromium builds its real tree asynchronously after being woken, and a
        // big page takes longer than a single retry allows.
        for attempt in 0 ..< 5 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(100)) }

            let system = AX.copyWithError(systemWide, kAXFocusedUIElementAttribute)
            if let value = system.value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                return (value as! AXUIElement)
            }

            let owned = AX.copyWithError(appElement, kAXFocusedUIElementAttribute)
            if let value = owned.value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                Log.capture.debug("Focus came from the app element, not the system-wide one.")
                return (value as! AXUIElement)
            }

            if attempt == 0 || attempt == 4 {
                Log.capture.error("""
                    Focus lookup attempt \(attempt) failed for \(app.localizedName ?? "?", privacy: .public) \
                    (pid \(pid), \(app.bundleIdentifier ?? "?", privacy: .public)): \
                    system-wide=\(describe(system.error), privacy: .public) \
                    app-element=\(describe(owned.error), privacy: .public) \
                    appRole=\(AX.string(appElement, kAXRoleAttribute) ?? "nil", privacy: .public) \
                    appChildren=\(AX.elements(appElement, kAXChildrenAttribute).count) \
                    trusted=\(AX.isTrusted)
                    """)
            }
        }
        return nil
    }

    /// Turns an AXError into something readable in the log. The distinction that
    /// matters: `apiDisabled` means the permission is not really in effect,
    /// `noValue` means the app genuinely reports nothing focused, and
    /// `cannotComplete` usually means the target app never answered.
    private static func describe(_ error: AXError) -> String {
        switch error {
        case .success: "success"
        case .apiDisabled: "apiDisabled (accessibility not actually enabled for Control)"
        case .noValue: "noValue (app reports nothing focused)"
        case .attributeUnsupported: "attributeUnsupported"
        case .cannotComplete: "cannotComplete (app did not respond)"
        case .notImplemented: "notImplemented (app exposes no accessibility)"
        case .invalidUIElement: "invalidUIElement"
        case .failure: "failure"
        default: "AXError(\(error.rawValue))"
        }
    }

    // MARK: Editability

    private static func isEditable(_ element: AXUIElement, role: String?, subrole: String?) -> Bool {
        if let role, editableRoles.contains(role) { return true }
        if let subrole, editableRoles.contains(subrole) { return true }
        // contenteditable regions and custom controls: trust whether the element
        // says its value can be written.
        return AX.isSettable(element, kAXValueAttribute)
    }

    // MARK: Label

    /// Highest-signal first. `AXTitleUIElement` is what `<label for="…">` becomes
    /// in Safari and Chrome, so it beats every other source when present.
    private static func label(for element: AXUIElement) -> String? {
        if let titleElement = AX.element(element, kAXTitleUIElementAttribute) {
            if let value = AX.string(titleElement, kAXValueAttribute) { return value }
            if let title = AX.string(titleElement, kAXTitleAttribute) { return title }
        }
        if let title = AX.string(element, kAXTitleAttribute) { return title }
        // aria-label lands here in Chrome.
        if let description = AX.string(element, kAXDescriptionAttribute) { return description }
        return nil
    }

    // MARK: Ambient text

    /// Static text from the field's ancestors — section headings like "Mailing
    /// address" that turn a meaningless "Line 1" into something matchable.
    private static func nearbyText(around element: AXUIElement, levels: Int = 3, limit: Int = 8) -> [String] {
        var collected: [String] = []
        var seen = Set<String>()
        var budget = 120  // hard ceiling: every AX read is an IPC round trip
        var current = element

        for _ in 0 ..< levels {
            guard budget > 0, let parent = AX.element(current, kAXParentAttribute) else { break }
            budget -= 1

            for child in AX.elements(parent, kAXChildrenAttribute).prefix(16) {
                guard budget > 0, collected.count < limit else { break }
                guard !AX.same(child, element), !AX.same(child, current) else { continue }

                let subtree = collectSubtree(child, depth: 2, budget: &budget)
                // Anything containing another input belongs to *that* field. Its
                // label and help text are not context for this one — taking them
                // is how "What are you studying?" ends up holding a phone number.
                guard !subtree.containsField else { continue }

                for text in subtree.texts where seen.insert(text).inserted {
                    collected.append(text)
                    if collected.count >= limit { break }
                }
            }

            current = parent
        }

        return collected
    }

    /// Gathers the text in a subtree, and reports whether that subtree also holds
    /// a form control — in which case the caller throws the text away.
    private static func collectSubtree(
        _ element: AXUIElement,
        depth: Int,
        budget: inout Int
    ) -> (texts: [String], containsField: Bool) {
        guard budget > 0 else { return ([], false) }
        budget -= 1

        let role = AX.string(element, kAXRoleAttribute)
        if let role, editableRoles.contains(role) { return ([], true) }
        if role == "AXButton" || role == "AXPopUpButton" || role == "AXCheckBox" {
            return ([], true)
        }

        if role == kAXStaticTextRole || role == "AXHeading" {
            guard let text = AX.string(element, kAXValueAttribute) ?? AX.string(element, kAXTitleAttribute),
                  text.count <= 120
            else { return ([], false) }
            return ([text], false)
        }

        guard depth > 0 else { return ([], false) }

        var texts: [String] = []
        for child in AX.elements(element, kAXChildrenAttribute).prefix(8) {
            guard budget > 0 else { break }
            let sub = collectSubtree(child, depth: depth - 1, budget: &budget)
            if sub.containsField { return ([], true) }
            texts.append(contentsOf: sub.texts)
        }
        return (texts, false)
    }

    // MARK: Debug

    /// Raw attribute dump for the field inspector. Values are shown by length
    /// only — the inspector must not become a way to read what the user typed.
    static func debugDump(_ element: AXUIElement) -> [(String, String)] {
        AX.attributeNames(element).sorted().map { name in
            if name == kAXValueAttribute || name == kAXSelectedTextAttribute {
                let length = (AX.rawValue(element, name) ?? "").count
                return (name, "<\(length) characters>")
            }
            guard let value = AX.copy(element, name) else { return (name, "—") }
            if let string = value as? String { return (name, string) }
            if CFGetTypeID(value) == AXUIElementGetTypeID() {
                let child = value as! AXUIElement
                let role = AX.string(child, kAXRoleAttribute) ?? "element"
                let text = AX.string(child, kAXValueAttribute) ?? AX.string(child, kAXTitleAttribute) ?? ""
                return (name, text.isEmpty ? "<\(role)>" : "<\(role)> \(text)")
            }
            return (name, String(describing: value))
        }
    }
}
