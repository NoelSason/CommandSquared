import XCTest
@testable import ControlKit

/// Which text around a field belongs to it. Modelled on section 3 of
/// `QA/test-form.html` in both shapes browsers produce.
final class NearbyTextPolicyTests: XCTestCase {
    typealias Node = NearbyTextPolicy.Node

    // MARK: Brave / Chrome: wrapper divs pruned, every label a flat sibling

    /// The section's children as Chromium exposes them, with `target` at the
    /// input being filled and every other input a bare `.control` whose label
    /// the reader could read.
    private func flatSection(target: String) -> [Node] {
        let items: [(label: String?, input: String?)] = [
            ("3 · Address scoping", nil),
            ("Permanent address", nil),
            ("Street address", "h1"), ("Apt, suite, unit", "h2"), ("City", "h3"), ("ZIP", "h4"),
            ("Current campus address", nil),
            ("Street address", "c1"), ("City", "c2"), ("ZIP", "c3"),
            ("No heading at all", nil),
            ("City", "u1"),
        ]
        var nodes: [Node] = [.heading("3 · Address scoping")]
        for item in items.dropFirst() {
            if let label = item.label { nodes.append(.text(label)) }
            if let input = item.input { nodes.append(input == target ? .target : .control(label: item.label)) }
        }
        return nodes
    }

    private func flat(_ target: String, label: String) -> NearbyTextPolicy.Context {
        NearbyTextPolicy.context(levels: [flatSection(target: target)], own: [label])
    }

    func testAnotherFieldsLabelIsNeverNearbyText() {
        // The shipped bug: "Date of birth" read "What name do you go by?" from
        // a field above it and filled the preferred name.
        let context = flat("c2", label: "City")
        XCTAssertFalse(context.nearby.contains("Street address"), "c1's label")
        XCTAssertFalse(context.nearby.contains("ZIP"), "c3's label")
        XCTAssertFalse(context.nearby.contains("Apt, suite, unit"), "h2's label")
    }

    func testTheNearestHeadingIsTheSections() {
        XCTAssertEqual(flat("h3", label: "City").heading, "Permanent address")
        XCTAssertEqual(flat("c1", label: "Street address").heading, "Current campus address")
        XCTAssertEqual(flat("c2", label: "City").heading, "Current campus address")
        XCTAssertEqual(flat("u1", label: "City").heading, "No heading at all")
    }

    func testNearbyTextIsNearestFirst() {
        let context = flat("c1", label: "Street address")
        XCTAssertEqual(context.nearby.first, "Current campus address")
        XCTAssertLessThan(
            context.nearby.firstIndex(of: "Current campus address")!,
            context.nearby.firstIndex(of: "Permanent address")!
        )
    }

    func testTheFieldsOwnLabelIsNotRepeated() {
        XCTAssertFalse(flat("u1", label: "City").nearby.contains("City"))
    }

    // MARK: Safari: each label and input wrapped in its own group

    func testNestedTreesGiveTheSameHeading() {
        // c2 sits in `.field` inside `.row` inside the section.
        let field: [Node] = [.text("City"), .target]
        let row: [Node] = [.target, .group]
        let section: [Node] = [
            .heading("3 · Address scoping"), .text("Permanent address"), .group, .group, .group,
            .text("Current campus address"), .group, .target, .text("No heading at all"), .group,
        ]
        let context = NearbyTextPolicy.context(levels: [field, row, section], own: ["City"])
        XCTAssertEqual(context.heading, "Current campus address",
                       "a heading right before a group is still a heading — the group carries its own label")
        XCTAssertFalse(context.nearby.contains("City"))
    }

    // MARK: Edges

    func testAHeadingElementIsNeverMistakenForALabel() {
        // An <h3> directly above an unlabelled input is still section structure.
        let nodes: [Node] = [.heading("Billing address"), .control(label: nil), .text("City"), .target]
        XCTAssertEqual(NearbyTextPolicy.context(levels: [nodes], own: ["City"]).heading, "Billing address")
    }

    func testHelpTextUnderTheFieldIsKeptButTheNextLabelIsNot() {
        let nodes: [Node] = [.text("Email"), .target, .text("We'll never share it."), .text("Phone"), .control(label: "Phone")]
        let context = NearbyTextPolicy.context(levels: [nodes], own: ["Email"])
        XCTAssertEqual(context.nearby, ["We'll never share it."])
    }

    func testTheLimitHolds() {
        let nodes: [Node] = (0 ..< 20).map { .text("Line \($0)") } + [.target]
        XCTAssertEqual(NearbyTextPolicy.context(levels: [nodes], own: [], limit: 8).nearby.count, 8)
    }

    // MARK: Labels that arrive in pieces

    func testALabelInPiecesIsDroppedWhole() {
        // `<label>Wrapping label, no <code>for</code> attribute <input></label>`
        // and `Email <span>*</span>` both reach the reader as several texts.
        let nodes: [Node] = [
            .heading("4 · How the label is attached"),
            .text("Wrapping label, no"), .text("for"), .text("attribute"),
            .control(label: "Wrapping label, no for attribute"),
            .text("Email"), .text("*"), .control(label: "Email *"),
            .text("Textarea — your website"), .target,
        ]
        let context = NearbyTextPolicy.context(levels: [nodes], own: ["Textarea — your website"])
        XCTAssertEqual(context.nearby, ["4 · How the label is attached"])
        XCTAssertEqual(context.heading, "4 · How the label is attached")
    }

    func testAnUnreadableLabelClaimsOnlyTheTextRightAboveIt() {
        let nodes: [Node] = [.text("Shipping address"), .text("Street"), .control(label: nil), .text("City"), .target]
        let context = NearbyTextPolicy.context(levels: [nodes], own: ["City"])
        XCTAssertEqual(context.heading, "Shipping address")
        XCTAssertFalse(context.nearby.contains("Street"))
    }

    func testTheFieldsOwnLabelInPiecesIsNotItsHeading() {
        let nodes: [Node] = [.text("Billing address"), .text("City"), .text("*"), .target]
        let context = NearbyTextPolicy.context(levels: [nodes], own: ["City *"])
        XCTAssertEqual(context.heading, "Billing address")
    }
}
