import Foundation

/// Decides which text around a field describes *it* — as opposed to the fields
/// next to it.
///
/// The reader walks up from the field a few levels and, at each level, hands
/// over the parent's children in reading order. The hard part is that browsers
/// don't agree on shape. Safari keeps a `<div class="field">` around each label
/// and input, so another field's label sits inside a group that also holds a
/// control and is easy to skip. Chrome and Brave prune those divs, so every
/// label in a section ends up a flat sibling of every input — and the old rule,
/// "skip subtrees that contain a field", had nothing to skip. "Date of birth"
/// then read "What name do you go by?" from a field above it, and filled the
/// preferred name.
///
/// Two rules cover both shapes:
///
/// - Text right above a bare control is that control's label and is dropped
///   (`labelText(in:targetLabel:)` has the details: pieces, hints, subheads).
/// - The nearest other text above the field is its section heading. Address
///   scope ("Campus" vs "Permanent") comes from that one heading, not from
///   whichever scope word appears anywhere nearby.
public enum NearbyTextPolicy {
    public enum Node: Sendable, Equatable {
        /// Static text, in reading order.
        case text(String)
        /// A heading element.
        case heading(String)
        /// A form control on its own. Text right before it is its label; `label`
        /// is that label when the reader could read it.
        case control(label: String?)
        /// A container holding a control. It carries its own label inside, so
        /// text right before it is a heading, not a label.
        case group
        /// The field being filled, or the container on the path to it.
        case target
    }

    public struct Context: Sendable, Equatable {
        /// Descriptive text, nearest first. Never another field's label.
        public var nearby: [String]
        /// The nearest section text above the field that isn't a label.
        public var heading: String?

        public init(nearby: [String], heading: String?) {
            self.nearby = nearby
            self.heading = heading
        }
    }

    /// How much text after the field is kept, at the field's own level. A line
    /// of help under an input is common; beyond that it is usually the next
    /// section starting.
    static let followingLimit = 2

    /// - Parameters:
    ///   - levels: `levels[0]` is the field's parent's children, `levels[1]`
    ///     the grandparent's, and so on. Each level holds exactly one `.target`.
    ///   - own: the field's own label, placeholder and help, which are already
    ///     in the context and are not repeated here.
    public static func context(levels: [[Node]], own: [String], limit: Int = 8) -> Context {
        let ownText = Set(own.map(key))
        var nearby: [String] = []
        var seen = Set<String>()
        var heading: String?

        func add(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !ownText.contains(key(trimmed)), nearby.count < limit,
                  seen.insert(key(trimmed)).inserted
            else { return }
            nearby.append(trimmed)
        }

        for (depth, nodes) in levels.enumerated() {
            guard let target = nodes.firstIndex(of: .target) else { continue }
            // At the field itself, the text above it is its own label, which is
            // already in the context. Higher up, the target is a container that
            // holds its label inside, so the text above it is section text.
            let claimed = labelText(in: nodes, targetLabel: depth == 0 ? own.joined(separator: " ") : nil)

            // Above the field, nearest first.
            for index in stride(from: target - 1, through: 0, by: -1) {
                guard !claimed.contains(index), let text = nodes[index].text else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if heading == nil, !key(trimmed).isEmpty, !ownText.contains(key(trimmed)) {
                    heading = trimmed
                }
                add(text)
            }

            // Help text directly under the field, before the next label starts.
            guard depth == 0 else { continue }
            var kept = 0
            var index = target + 1
            while index < nodes.count, kept < followingLimit, !claimed.contains(index), let text = nodes[index].text {
                add(text)
                kept += 1
                index += 1
            }
        }

        return Context(nearby: nearby, heading: heading)
    }

    private static func key(_ text: String) -> String {
        FieldContext.normalize(text)
    }

    /// Indices of text that is some control's label, and so not context.
    ///
    /// A control claims the run of plain text right above it back to the
    /// farthest piece that belongs to its label. That covers a label in pieces
    /// ("Email", "*"), a hint between a label and its input (Google Forms puts
    /// every question's description there), and still leaves a subhead right
    /// above a label alone, because the subhead isn't part of it. When a label
    /// couldn't be read, only the one text right above the control is taken.
    static func labelText(in nodes: [Node], targetLabel: String?) -> Set<Int> {
        var claimed = Set<Int>()
        for (index, node) in nodes.enumerated() {
            let label: String?
            switch node {
            case let .control(known): label = known
            case .target:
                guard let targetLabel else { continue }
                label = targetLabel
            case .text, .heading, .group: continue
            }

            var run: [Int] = []
            var above = index - 1
            while above >= 0, case .text = nodes[above] {
                run.append(above)
                above -= 1
            }
            guard !run.isEmpty else { continue }

            guard let label else {
                claimed.insert(run[0])
                continue
            }
            let words = " " + key(label) + " "
            if let farthest = run.lastIndex(where: { position in
                guard let piece = nodes[position].text.map(key) else { return false }
                return piece.isEmpty || words.contains(" " + piece + " ")
            }) {
                claimed.formUnion(run[...farthest])
            }
        }
        return claimed
    }
}

public extension NearbyTextPolicy.Node {
    /// The words of a text or heading node.
    var text: String? {
        switch self {
        case let .text(text), let .heading(text): text
        case .control, .group, .target: nil
        }
    }
}
