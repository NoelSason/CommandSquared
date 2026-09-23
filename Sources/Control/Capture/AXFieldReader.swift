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
            return .failure(unreachableEditorReason(for: app) ?? .noFocusedField)
        }

        return read(focused, app: app)
    }

    /// Everything Control can learn about one element, focused or not. Whole-form
    /// fill reads every field on a page through here.
    static func read(_ focused: AXUIElement, app: NSRunningApplication) -> Result<FocusedField, BlockReason> {
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

        let bundleID = app.bundleIdentifier ?? "unknown"
        let insideWebArea = BrowserURLReader.isInsideWebArea(focused)

        // The browser's own address bar is an ordinary text field, and typing a
        // street address into it helps nobody.
        if BrowserChrome.isChrome(bundleID: bundleID, insideWebArea: insideWebArea) {
            return .failure(.browserChrome)
        }

        // Something the user could not have seen has no business being filled.
        guard FieldVisibility.isFillable(
            frame: AX.frame(focused),
            screens: NSScreen.screens.map(\.frame)
        ) else {
            Log.capture.error("Refused a field that is not visible in \(app.localizedName ?? "?", privacy: .public).")
            return .failure(.hiddenField)
        }

        let label = label(for: focused)
        let placeholder = AX.string(focused, kAXPlaceholderValueAttribute)
        let helpText = AX.string(focused, kAXHelpAttribute)
        let ambient = ambientContext(around: focused, own: [label, placeholder, helpText].compactMap { $0 })

        let context = FieldContext(
            appName: app.localizedName ?? "Unknown",
            bundleID: bundleID,
            domain: BrowserURLReader.domain(for: focused, app: app),
            role: role,
            subrole: subrole,
            label: label,
            placeholder: placeholder,
            helpText: helpText,
            nearbyText: ambient.nearby,
            isEmpty: (AX.rawValue(focused, kAXValueAttribute) ?? "").isEmpty,
            heading: ambient.heading
        )

        return .success(FocusedField(element: focused, context: context, app: app))
    }

    /// Some editors paint their own text and expose nothing to read. Saying so,
    /// with the fix where one exists, beats "no text field is focused".
    private static func unreachableEditorReason(for app: NSRunningApplication) -> BlockReason? {
        let bundleID = app.bundleIdentifier ?? ""
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let domain = AX.element(appElement, kAXFocusedWindowAttribute)
            .flatMap { AX.string($0, kAXDocumentAttribute) }
            .flatMap { URLComponents(string: $0)?.host?.lowercased() }

        guard let advice = CanvasEditors.advice(bundleID: bundleID, domain: domain) else { return nil }
        return .canvasEditor(product: advice.product, instruction: advice.instruction)
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

    private typealias Node = NearbyTextPolicy.Node

    /// Static text around the field — section headings like "Mailing address"
    /// that turn a meaningless "Line 1" into something matchable.
    ///
    /// This only describes the tree; `NearbyTextPolicy` decides what belongs to
    /// this field. Chromium prunes wrapper divs, so a section can arrive as one
    /// flat list of labels and inputs: the window around the field matters, and
    /// the first few children of a big section say nothing about a field near
    /// its end.
    private static func ambientContext(
        around element: AXUIElement,
        own: [String],
        levels: Int = 3
    ) -> NearbyTextPolicy.Context {
        var budget = 160  // hard ceiling: every AX read is an IPC round trip
        var nodeLevels: [[Node]] = []
        var current = element

        for _ in 0 ..< levels {
            guard budget > 0, let parent = AX.element(current, kAXParentAttribute) else { break }
            budget -= 1

            let children = AX.elements(parent, kAXChildrenAttribute)
            guard let index = children.firstIndex(where: { AX.same($0, current) }) else { break }

            var nodes: [Node] = []
            for position in max(0, index - 16) ..< min(children.count, index + 5) {
                guard budget > 0 else { break }
                if position == index {
                    nodes.append(.target)
                    continue
                }
                switch summarize(children[position], depth: 2, budget: &budget) {
                case let .control(label): nodes.append(.control(label: label))
                case .group: nodes.append(.group)
                case let .texts(texts): nodes.append(contentsOf: texts)
                }
            }
            nodeLevels.append(nodes)
            current = parent
        }

        return NearbyTextPolicy.context(levels: nodeLevels, own: own)
    }

    private enum Summary {
        /// A form control itself, with its label when it has a readable one.
        case control(label: String?)
        /// Something holding a control somewhere inside.
        case group
        /// Only text, in reading order.
        case texts([Node])
    }

    private static let controlRoles: Set<String> = ["AXButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton"]

    private static func summarize(_ element: AXUIElement, depth: Int, budget: inout Int) -> Summary {
        guard budget > 0 else { return .texts([]) }
        budget -= 1

        let role = AX.string(element, kAXRoleAttribute)
        if let role, editableRoles.contains(role) {
            // The policy drops exactly this label's text from the neighbours,
            // and nothing else — so a subhead right above it survives.
            budget -= 3
            return .control(label: label(for: element))
        }
        if let role, controlRoles.contains(role) { return .control(label: nil) }

        if role == kAXStaticTextRole || role == "AXHeading" {
            let isHeading = role == "AXHeading"
            if let text = AX.string(element, kAXValueAttribute) ?? AX.string(element, kAXTitleAttribute) {
                guard text.count <= 120 else { return .texts([]) }
                return .texts([isHeading ? .heading(text) : .text(text)])
            }
            // Some browsers put a heading's words in a static-text child.
            guard isHeading, depth > 0,
                  case let .texts(inner) = summarize(AX.elements(element, kAXChildrenAttribute), depth: depth - 1, budget: &budget)
            else { return .texts([]) }
            return .texts(inner.map { $0.text.map(Node.heading) ?? $0 })
        }

        guard depth > 0 else { return .texts([]) }
        return summarize(AX.elements(element, kAXChildrenAttribute), depth: depth - 1, budget: &budget)
    }

    private static func summarize(_ children: [AXUIElement], depth: Int, budget: inout Int) -> Summary {
        var nodes: [Node] = []
        for child in children.prefix(8) {
            guard budget > 0 else { break }
            switch summarize(child, depth: depth, budget: &budget) {
            case .control, .group: return .group
            case let .texts(texts): nodes.append(contentsOf: texts)
            }
        }
        return .texts(nodes)
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
