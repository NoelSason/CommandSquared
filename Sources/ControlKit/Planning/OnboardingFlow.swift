import Foundation

/// Which step of first-run setup to show, decided from what is already true.
///
/// First run used to be the settings window with an orange banner: correct, and
/// no help at all in knowing what to do first. The steps are the three things
/// that have to be true for Control to be any use — it can read fields, it
/// knows something about you, and you've seen it work — and each one is
/// skipped the moment it's already done.
public enum OnboardingFlow {
    public enum Step: Int, CaseIterable, Sendable {
        case access, details, tryIt, done
    }

    public struct State: Sendable, Equatable {
        public var accessGranted: Bool
        public var savedDetails: Int
        public var detailsSkipped: Bool
        public var practiced: Bool
        public var practiceSkipped: Bool

        public init(
            accessGranted: Bool,
            savedDetails: Int,
            detailsSkipped: Bool = false,
            practiced: Bool = false,
            practiceSkipped: Bool = false
        ) {
            self.accessGranted = accessGranted
            self.savedDetails = savedDetails
            self.detailsSkipped = detailsSkipped
            self.practiced = practiced
            self.practiceSkipped = practiceSkipped
        }
    }

    public static func step(for state: State) -> Step {
        // Nothing else works without access, so it comes first and can't be skipped.
        if !state.accessGranted { return .access }
        if state.savedDetails == 0, !state.detailsSkipped { return .details }
        // Practising needs something to fill with.
        if state.savedDetails > 0, !state.practiced, !state.practiceSkipped { return .tryIt }
        return .done
    }

    /// Whether setup opens by itself at launch. Someone who was already set up
    /// before setup existed — access granted, details saved — is not sent
    /// through it.
    public static func showsAtLaunch(completed: Bool, accessGranted: Bool, savedDetails: Int) -> Bool {
        !completed && !(accessGranted && savedDetails > 0)
    }

    /// The question the practice box asks: the first of these the user has a
    /// value for, so the demonstration fills something real.
    public static func practiceLabel(filled: Set<String>) -> String? {
        let questions: [(key: String, label: String)] = [
            ("email_personal", "Email address"),
            ("given_name", "First name"),
            ("phone_mobile", "Phone number"),
            ("university", "University"),
            ("family_name", "Last name"),
        ]
        return questions.first { filled.contains($0.key) }?.label
    }
}
