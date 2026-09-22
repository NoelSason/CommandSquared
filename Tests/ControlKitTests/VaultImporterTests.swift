import XCTest
@testable import ControlKit

final class VaultImporterTests: XCTestCase {

    // MARK: Field-name humanising

    func testCamelCaseFieldNamesBecomeLabels() {
        XCTAssertEqual(VaultImporter.humanize("firstNameInput"), "first name input")
        XCTAssertEqual(VaultImporter.humanize("lastNameInput"), "last name input")
        XCTAssertEqual(VaultImporter.humanize("emailInput"), "email input")
    }

    func testSeparatorsBecomeSpaces() {
        XCTAssertEqual(VaultImporter.humanize("first_name"), "first name")
        XCTAssertEqual(VaultImporter.humanize("dir-email"), "dir email")
        XCTAssertEqual(VaultImporter.humanize("urls.0.value"), "urls 0 value")
    }

    func testRunsOfCapitalsAreNotSplit() {
        XCTAssertEqual(VaultImporter.humanize("ZIP"), "zip")
        XCTAssertEqual(VaultImporter.humanize("billingZIP"), "billing zip")
    }

    // MARK: Browser autofill

    private func rows(_ pairs: [(String, String, Int)]) -> [BrowserAutofillRow] {
        pairs.map { BrowserAutofillRow(fieldName: $0.0, value: $0.1, useCount: $0.2) }
    }

    func testRecognisableFieldNamesAreImported() {
        let imported = VaultImporter.fromBrowserAutofill(rows([
            ("firstNameInput", "Noel", 7),
            ("lastNameInput", "Sason", 7),
            ("phone", "6615239570", 4),
        ]))

        let byKey = Dictionary(uniqueKeysWithValues: imported.map { ($0.key, $0.value) })
        XCTAssertEqual(byKey["given_name"], "Noel")
        XCTAssertEqual(byKey["family_name"], "Sason")
        XCTAssertEqual(byKey["phone_mobile"], "6615239570")
    }

    func testUnrelatedFieldNamesAreNotImported() {
        // Real rows from a real browser profile. "project-name" and
        // "repository-name-input" must not become the user's full name.
        let imported = VaultImporter.fromBrowserAutofill(rows([
            ("repository-name-input", "control-new", 32),
            ("project-name", "my-side-project", 5),
            ("subdomain", "staging", 9),
            ("Description", "a thing I built", 13),
        ]))

        XCTAssertTrue(imported.isEmpty, "got \(imported.map { "\($0.origin)->\($0.key)" })")
    }

    func testTheMostUsedValueWinsForAKey() {
        let imported = VaultImporter.fromBrowserAutofill(rows([
            ("emailInput", "old@example.com", 2),
            ("email", "noel@example.com", 12),
        ]))

        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.value, "noel@example.com")
    }

    func testEmptyAndAbsurdValuesAreSkipped() {
        let imported = VaultImporter.fromBrowserAutofill(rows([
            ("firstNameInput", "   ", 5),
            ("lastNameInput", String(repeating: "x", count: 500), 5),
        ]))
        XCTAssertTrue(imported.isEmpty)
    }

    func testOriginIsKeptSoABadRowIsObvious() {
        let imported = VaultImporter.fromBrowserAutofill(rows([("firstNameInput", "Noel", 7)]))
        XCTAssertEqual(imported.first?.origin, "firstNameInput")
    }

    // MARK: vCard

    private let card = """
    BEGIN:VCARD
    VERSION:3.0
    N:Sason;Noel;Jubil;;
    FN:Noel Sason
    NICKNAME:Noel
    EMAIL;type=INTERNET;type=HOME:noeljsason@gmail.com
    EMAIL;type=INTERNET;type=WORK:noel_sason@berkeley.edu
    TEL;type=CELL:+16615239570
    ADR;type=HOME:;;27680 N Ridgeline Pl;Valencia;CA;91355;USA
    ORG:Lawrence Berkeley National Laboratory;BBOP
    TITLE:Research Affiliate
    URL:https://github.com/NoelSason
    BDAY:20060101
    END:VCARD
    """

    private func parsed() -> [String: String] {
        Dictionary(uniqueKeysWithValues: VaultImporter.parseVCard(card).map { ($0.key, $0.value) })
    }

    func testNameComponentsAreSplitCorrectly() {
        let values = parsed()
        XCTAssertEqual(values["given_name"], "Noel")
        XCTAssertEqual(values["family_name"], "Sason")
        XCTAssertEqual(values["middle_name"], "Jubil")
        XCTAssertEqual(values["preferred_name"], "Noel")
    }

    func testEduAddressesAreRecognisedAsSchoolEmail() {
        // vCard has no concept of a school address; Control does, and the
        // distinction is one of the things it exists to get right.
        let values = parsed()
        XCTAssertEqual(values["email_personal"], "noeljsason@gmail.com")
        XCTAssertEqual(values["email_school"], "noel_sason@berkeley.edu")
    }

    func testAddressComponentsLandInTheRightSlots() {
        let values = parsed()
        XCTAssertEqual(values["home_street_1"], "27680 N Ridgeline Pl")
        XCTAssertEqual(values["home_city"], "Valencia")
        XCTAssertEqual(values["home_state"], "CA")
        XCTAssertEqual(values["home_postal"], "91355")
    }

    func testWorkAddressesGoToTheCampusSlots() {
        let values = Dictionary(uniqueKeysWithValues: VaultImporter.parseVCard("""
        BEGIN:VCARD
        ADR;type=WORK:;;1752 Shattuck Avenue;Berkeley;CA;94709;USA
        END:VCARD
        """).map { ($0.key, $0.value) })

        XCTAssertEqual(values["campus_street_1"], "1752 Shattuck Avenue")
        XCTAssertEqual(values["campus_city"], "Berkeley")
    }

    func testURLsAreClassifiedByHost() {
        XCTAssertEqual(parsed()["github_url"], "https://github.com/NoelSason")

        let linkedIn = Dictionary(uniqueKeysWithValues: VaultImporter.parseVCard("""
        BEGIN:VCARD
        URL:https://linkedin.com/in/noelsason
        END:VCARD
        """).map { ($0.key, $0.value) })
        XCTAssertEqual(linkedIn["linkedin_url"], "https://linkedin.com/in/noelsason")
    }

    func testCompactDatesBecomeISO() {
        XCTAssertEqual(parsed()["date_of_birth"], "2006-01-01")
    }

    func testOrganisationTakesOnlyTheFirstComponent() {
        XCTAssertEqual(parsed()["current_org"], "Lawrence Berkeley National Laboratory")
    }

    func testFoldedLinesAreRejoined() {
        let folded = """
        BEGIN:VCARD
        ADR;type=HOME:;;27680 N Ridge
         line Pl;Valencia;CA;91355;USA
        END:VCARD
        """
        let values = Dictionary(uniqueKeysWithValues: VaultImporter.parseVCard(folded).map { ($0.key, $0.value) })
        XCTAssertEqual(values["home_street_1"], "27680 N Ridgeline Pl")
    }

    func testEscapedSeparatorsSurvive() {
        let escaped = "BEGIN:VCARD\nORG:Smith\\, Jones and Co\nEND:VCARD"
        let values = Dictionary(uniqueKeysWithValues: VaultImporter.parseVCard(escaped).map { ($0.key, $0.value) })
        XCTAssertEqual(values["current_org"], "Smith, Jones and Co")
    }

    func testGarbageInputProducesNothingRatherThanCrashing() {
        XCTAssertTrue(VaultImporter.parseVCard("").isEmpty)
        XCTAssertTrue(VaultImporter.parseVCard("not a vcard at all").isEmpty)
        XCTAssertTrue(VaultImporter.parseVCard("BEGIN:VCARD\nN\nEND:VCARD").isEmpty)
    }

    // MARK: Merging

    func testEarlierSourcesWinOnConflict() {
        let contacts = [ImportedValue(key: "email_personal", value: "from-contacts@x.com",
                                      source: .contacts, origin: "EMAIL", confidence: 0.9)]
        let browser = [ImportedValue(key: "email_personal", value: "from-browser@x.com",
                                     source: .browser, origin: "email", confidence: 0.72),
                       ImportedValue(key: "home_city", value: "Valencia",
                                     source: .browser, origin: "city", confidence: 0.9)]

        let merged = VaultImporter.merge([contacts, browser])
        let byKey = Dictionary(uniqueKeysWithValues: merged.map { ($0.key, $0.value) })
        XCTAssertEqual(byKey["email_personal"], "from-contacts@x.com")
        XCTAssertEqual(byKey["home_city"], "Valencia", "gaps are still filled")
    }

    func testConfidentRowsArePreTicked() {
        let confident = ImportedValue(key: "given_name", value: "Noel", source: .contacts, origin: "N", confidence: 1.0)
        let doubtful = ImportedValue(key: "full_name", value: "x", source: .browser, origin: "project-name", confidence: 0.58)
        XCTAssertTrue(confident.isConfident)
        XCTAssertFalse(doubtful.isConfident)
    }
}

extension VaultImporterTests {
    /// Real rows from a real Brave profile that used to import as the wrong thing.
    func testQualifiedFieldNamesAreNotMistakenForTheThingTheyQualify() {
        let imported = VaultImporter.fromBrowserAutofill(rows([
            ("sid-country", "United States", 3),
            ("birthDate-month", "01", 4),
            ("birthDate-day", "01", 4),
            ("birthDate-year", "2006", 4),
        ]))

        let keys = Set(imported.map(\.key))
        XCTAssertFalse(keys.contains("student_id"), "sid-country is a country field")
        XCTAssertFalse(keys.contains("date_of_birth"), "a date split across three boxes is not a date")
    }

    func testARealStudentIDFieldStillImports() {
        let imported = VaultImporter.fromBrowserAutofill(rows([("studentId", "3040205977", 5)]))
        XCTAssertEqual(imported.first?.key, "student_id")
    }

    func testARealDateOfBirthFieldStillImports() {
        let imported = VaultImporter.fromBrowserAutofill(rows([("dateOfBirth", "2006-01-01", 5)]))
        XCTAssertEqual(imported.first?.key, "date_of_birth")
    }
}
