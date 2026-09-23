import XCTest
@testable import ControlKit

final class OnboardingFlowTests: XCTestCase {
    typealias State = OnboardingFlow.State

    func testAccessComesFirstAndCannotBeSkipped() {
        let state = State(accessGranted: false, savedDetails: 12, detailsSkipped: true, practiceSkipped: true)
        XCTAssertEqual(OnboardingFlow.step(for: state), .access)
    }

    func testDetailsFollowAccess() {
        XCTAssertEqual(OnboardingFlow.step(for: State(accessGranted: true, savedDetails: 0)), .details)
    }

    func testAStepAlreadyDoneIsSkipped() {
        XCTAssertEqual(OnboardingFlow.step(for: State(accessGranted: true, savedDetails: 5)), .tryIt)
    }

    func testPracticeNeedsSomethingToFillWith() {
        let skippedDetails = State(accessGranted: true, savedDetails: 0, detailsSkipped: true)
        XCTAssertEqual(OnboardingFlow.step(for: skippedDetails), .done)
    }

    func testPractisingFinishes() {
        XCTAssertEqual(OnboardingFlow.step(for: State(accessGranted: true, savedDetails: 5, practiced: true)), .done)
        XCTAssertEqual(OnboardingFlow.step(for: State(accessGranted: true, savedDetails: 5, practiceSkipped: true)), .done)
    }

    func testFirstRunOpensSetup() {
        XCTAssertTrue(OnboardingFlow.showsAtLaunch(completed: false, accessGranted: false, savedDetails: 0))
    }

    func testSomeoneAlreadySetUpIsNotSentThroughIt() {
        XCTAssertFalse(OnboardingFlow.showsAtLaunch(completed: false, accessGranted: true, savedDetails: 20))
    }

    func testFinishedSetupStaysFinished() {
        XCTAssertFalse(OnboardingFlow.showsAtLaunch(completed: true, accessGranted: false, savedDetails: 0))
    }

    func testThePracticeQuestionIsOneTheVaultCanAnswer() {
        XCTAssertEqual(OnboardingFlow.practiceLabel(filled: ["phone_mobile", "given_name"]), "First name")
        XCTAssertEqual(OnboardingFlow.practiceLabel(filled: ["email_personal"]), "Email address")
        XCTAssertNil(OnboardingFlow.practiceLabel(filled: ["gpa"]))
    }
}
