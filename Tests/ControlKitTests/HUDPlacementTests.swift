import XCTest
@testable import ControlKit

final class HUDPlacementTests: XCTestCase {
    /// Primary at the origin, a taller display to its right — the arrangement
    /// that broke in practice.
    private let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let right = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
    private var screens: [CGRect] { [primary, right] }

    private func screen(for anchor: CGRect?, mouse: CGPoint = .zero) -> CGRect {
        HUDPlacement.screen(for: anchor, screens: screens, mouse: mouse, fallback: primary)
    }

    // MARK: Which display

    func testAFieldOnTheSecondDisplayStaysThere() {
        let anchor = CGRect(x: 2000, y: 600, width: 300, height: 24)
        XCTAssertEqual(screen(for: anchor), right)
    }

    func testAFieldOnThePrimaryStaysThere() {
        XCTAssertEqual(screen(for: CGRect(x: 100, y: 400, width: 300, height: 24)), primary)
    }

    func testAFieldStraddlingTwoDisplaysGoesWhereMostOfItIs() {
        // A corner-containment test picks whichever corner it happens to check.
        let mostlyRight = CGRect(x: 1462, y: 600, width: 300, height: 24)
        XCTAssertEqual(screen(for: mostlyRight), right)

        let mostlyLeft = CGRect(x: 1262, y: 600, width: 300, height: 24)
        XCTAssertEqual(screen(for: mostlyLeft), primary)
    }

    func testAFieldOffEveryDisplayGoesToTheNearestOne() {
        let offToTheRight = CGRect(x: 5000, y: 600, width: 300, height: 24)
        XCTAssertEqual(screen(for: offToTheRight), right)
    }

    func testWithNoAnchorThePointerDecides() {
        // Toasts that report a refusal have no field to point at, and were
        // always landing on the main display regardless of where the user was.
        XCTAssertEqual(screen(for: nil, mouse: CGPoint(x: 2400, y: 700)), right)
        XCTAssertEqual(screen(for: nil, mouse: CGPoint(x: 400, y: 300)), primary)
    }

    func testWithNoAnchorAndNoPointerItFallsBack() {
        XCTAssertEqual(screen(for: nil, mouse: CGPoint(x: -9999, y: -9999)), primary)
    }

    // MARK: Where on that display

    private let size = CGSize(width: 340, height: 120)

    func testAboveSitsAboveTheField() {
        let anchor = CGRect(x: 100, y: 400, width: 300, height: 24)
        let origin = HUDPlacement.origin(anchor: anchor, size: size, visible: primary, anchoring: .above)
        XCTAssertGreaterThan(origin.y, anchor.maxY)
        XCTAssertEqual(origin.x, anchor.minX)
    }

    func testBelowSitsBelowTheField() {
        let anchor = CGRect(x: 100, y: 400, width: 300, height: 24)
        let origin = HUDPlacement.origin(anchor: anchor, size: size, visible: primary, anchoring: .below)
        XCTAssertLessThan(origin.y + size.height, anchor.minY)
    }

    func testItFlipsRatherThanCoveringTheField() {
        // A field near the top has no room above it; clamping would put the panel
        // on top of the thing it refers to.
        let nearTop = CGRect(x: 100, y: 950, width: 300, height: 24)
        let origin = HUDPlacement.origin(anchor: nearTop, size: size, visible: primary, anchoring: .above)
        XCTAssertLessThan(origin.y + size.height, nearTop.minY + HUDPlacement.gap + 1)
    }

    func testItIsPulledBackFromTheRightEdge() {
        let nearRight = CGRect(x: 1400, y: 400, width: 100, height: 24)
        let origin = HUDPlacement.origin(anchor: nearRight, size: size, visible: primary, anchoring: .above)
        XCTAssertLessThanOrEqual(origin.x + size.width, primary.maxX)
    }

    func testItStaysWithinADisplayWithNegativeOrigin() {
        // The right-hand display starts at y = -200; a panel must not be clamped
        // using the primary's coordinates.
        let anchor = CGRect(x: 2000, y: -150, width: 300, height: 24)
        let origin = HUDPlacement.origin(anchor: anchor, size: size, visible: right, anchoring: .below)
        XCTAssertGreaterThanOrEqual(origin.y, right.minY)
        XCTAssertLessThanOrEqual(origin.y + size.height, right.maxY)
    }

    func testWithNoAnchorItCentresOnTheChosenDisplay() {
        let origin = HUDPlacement.origin(anchor: nil, size: size, visible: right, anchoring: .above)
        XCTAssertEqual(origin.x, right.midX - size.width / 2)
        XCTAssertEqual(origin.y, right.midY - size.height / 2)
    }
}
