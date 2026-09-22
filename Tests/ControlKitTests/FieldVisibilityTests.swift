import XCTest
@testable import ControlKit

final class FieldVisibilityTests: XCTestCase {
    private let screens = [CGRect(x: 0, y: 0, width: 1512, height: 982)]

    func testAnOrdinaryFieldIsFillable() {
        let frame = CGRect(x: 100, y: 200, width: 320, height: 28)
        XCTAssertEqual(FieldVisibility.verdict(frame: frame, screens: screens), .visible)
        XCTAssertTrue(FieldVisibility.isFillable(frame: frame, screens: screens))
    }

    func testAZeroSizedInputIsRefused() {
        // The shape of a hidden input planted to harvest an address.
        let frame = CGRect(x: 100, y: 200, width: 0, height: 0)
        XCTAssertEqual(FieldVisibility.verdict(frame: frame, screens: screens), .tooSmall)
        XCTAssertFalse(FieldVisibility.isFillable(frame: frame, screens: screens))
    }

    func testAOnePixelInputIsRefused() {
        let frame = CGRect(x: 10, y: 10, width: 1, height: 1)
        XCTAssertFalse(FieldVisibility.isFillable(frame: frame, screens: screens))
    }

    func testAnInputPositionedOffScreenIsRefused() {
        // The other common trick: full size, parked at -9999.
        let frame = CGRect(x: -9999, y: -9999, width: 300, height: 24)
        XCTAssertEqual(FieldVisibility.verdict(frame: frame, screens: screens), .offScreen)
        XCTAssertFalse(FieldVisibility.isFillable(frame: frame, screens: screens))
    }

    func testAFieldOnASecondScreenIsFine() {
        let twoScreens = screens + [CGRect(x: 1512, y: 0, width: 2560, height: 1440)]
        let frame = CGRect(x: 2000, y: 400, width: 300, height: 24)
        XCTAssertTrue(FieldVisibility.isFillable(frame: frame, screens: twoScreens))
    }

    func testAPartlyScrolledFieldIsStillFillable() {
        let frame = CGRect(x: 100, y: -10, width: 300, height: 24)
        XCTAssertTrue(FieldVisibility.isFillable(frame: frame, screens: screens))
    }

    func testAnUnreportedFrameIsAllowedThrough() {
        // Refusing these would break native apps to defend against a web attack.
        XCTAssertEqual(FieldVisibility.verdict(frame: nil, screens: screens), .unknown)
        XCTAssertTrue(FieldVisibility.isFillable(frame: nil, screens: screens))
    }
}

final class BrowserChromeTests: XCTestCase {
    func testBrowserFieldsOutsideWebContentAreChrome() {
        // The address bar, the find bar, the search box.
        XCTAssertTrue(BrowserChrome.isChrome(bundleID: "com.brave.Browser", insideWebArea: false))
        XCTAssertTrue(BrowserChrome.isChrome(bundleID: "com.apple.Safari", insideWebArea: false))
    }

    func testBrowserFieldsInsideWebContentAreNotChrome() {
        XCTAssertFalse(BrowserChrome.isChrome(bundleID: "com.brave.Browser", insideWebArea: true))
    }

    func testNonBrowserAppsAreNeverChrome() {
        // A native app's field reports no web area and must still be fillable.
        XCTAssertFalse(BrowserChrome.isChrome(bundleID: "com.apple.mail", insideWebArea: false))
        XCTAssertFalse(BrowserChrome.isChrome(bundleID: "com.apple.Notes", insideWebArea: false))
    }
}

final class CanvasEditorsTests: XCTestCase {
    func testGoogleDocsGetsActionableAdvice() {
        let advice = CanvasEditors.advice(bundleID: "com.brave.Browser", domain: "docs.google.com")
        XCTAssertEqual(advice?.product, "Google Docs")
        XCTAssertTrue(advice?.instruction.contains("screen reader support") ?? false)
    }

    func testSubdomainsAreCovered() {
        XCTAssertNotNil(CanvasEditors.advice(bundleID: "com.apple.Safari", domain: "www.docs.google.com"))
    }

    func testAnOrdinaryPageHasNoAdvice() {
        // Only speak up where we actually know something. A generic "this might
        // be a canvas" guess would be noise on every failed capture.
        XCTAssertNil(CanvasEditors.advice(bundleID: "com.brave.Browser", domain: "example.com"))
        XCTAssertNil(CanvasEditors.advice(bundleID: "com.apple.Notes", domain: nil))
    }

    func testDesktopAppsAreMatchedByBundleID() {
        XCTAssertEqual(CanvasEditors.advice(bundleID: "com.figma.Desktop", domain: nil)?.product, "Figma")
    }
}
