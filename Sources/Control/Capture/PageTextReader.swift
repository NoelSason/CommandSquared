import AppKit
import ApplicationServices
import ControlKit
import Foundation

/// A short excerpt of the page a question sits on — on an application, usually
/// the description of the role — so a draft can speak to it.
///
/// Static text only. Nothing inside a form control or an editable region is
/// read, so no value the user typed and nothing Control filled is ever part of
/// it: those are exactly the things that must not leave with a draft request.
@MainActor
enum PageTextReader {
    /// A job description's substance fits comfortably; the rest is footer.
    static let maxCharacters = 4000
    /// Every Accessibility read is a round trip to the browser. These bound the
    /// wait before the draft request can go.
    static let maxReads = 1500
    static let timeLimit: Duration = .milliseconds(350)

    /// Never descended into: controls whose contents are the user's.
    private static let controlRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
        kAXPopUpButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXMenuButtonRole,
        kAXSliderRole, kAXIncrementorRole, kAXMenuRole, kAXMenuBarRole,
    ]

    static func excerpt(around element: AXUIElement) -> String? {
        guard let webArea = webArea(containing: element) else { return nil }
        let deadline = ContinuousClock.now.advanced(by: timeLimit)

        var texts: [String] = []
        var length = 0
        var reads = 0
        // Depth first, in reading order: children go on reversed.
        var stack = [webArea]
        while let node = stack.popLast(), reads < maxReads, length < maxCharacters, ContinuousClock.now < deadline {
            reads += 1
            let role = AX.string(node, kAXRoleAttribute)
            if let role, controlRoles.contains(role) { continue }

            if role == kAXStaticTextRole {
                reads += 1
                // Text inside a rich-text editor is the user's writing.
                guard AX.element(node, "AXEditableAncestor") == nil,
                      let text = AX.string(node, kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty
                else { continue }
                texts.append(text)
                length += text.count + 1
                continue
            }
            stack.append(contentsOf: AX.elements(node, kAXChildrenAttribute).reversed())
        }

        let joined = texts.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        Log.capture.debug("Read \(joined.count) characters of page text in \(reads) reads.")
        return joined.isEmpty ? nil : String(joined.prefix(maxCharacters))
    }

    private static func webArea(containing element: AXUIElement, levels: Int = 24) -> AXUIElement? {
        var current = element
        for _ in 0 ..< levels {
            if AX.string(current, kAXRoleAttribute) == "AXWebArea" { return current }
            guard let parent = AX.element(current, kAXParentAttribute) else { return nil }
            current = parent
        }
        return nil
    }
}
