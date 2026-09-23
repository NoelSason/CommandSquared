import Foundation

/// The built-in catalog of field keys.
///
/// Design rule: store granular atoms and compose upward. `full_name` is derived
/// from its parts rather than stored, because splitting a stored full name at
/// fill time gets middle names, suffixes, and two-word surnames wrong.
public enum VaultSchema {
    public static let builtIn: [VaultField] = identity + contact + education + addresses + professional + payment

    public static func field(for key: String) -> VaultField? {
        builtIn.first { $0.key == key }
    }

    // MARK: Identity

    static let identity: [VaultField] = [
        VaultField(key: "given_name", label: "First name", category: .identity,
                   detail: "The user's legal first name / given name."),
        VaultField(key: "middle_name", label: "Middle name", category: .identity,
                   detail: "The user's middle name or middle initial."),
        VaultField(key: "family_name", label: "Last name", category: .identity,
                   detail: "The user's last name / family name / surname."),
        VaultField(key: "preferred_name", label: "Preferred name", category: .identity,
                   detail: "The first name the user actually goes by day to day, which may differ from their legal first name."),
        VaultField(key: "full_name", label: "Full name", category: .identity,
                   detail: "The user's complete name, first and last together, as written on official documents.",
                   // Middle name is deliberately excluded: most "Full name" fields want the
                   // two-part form, and forms that want the middle name ask for it separately.
                   derivedFrom: ["given_name", "family_name"]),
        VaultField(key: "pronouns", label: "Pronouns", category: .identity,
                   detail: "The user's pronouns, e.g. they/them."),
        VaultField(key: "date_of_birth", label: "Date of birth", category: .identity, kind: .date,
                   detail: "The user's date of birth."),
        // A government-issued id, so it gets the same care as a card: Touch ID
        // to read, confirmed before every fill, never synced or imported.
        VaultField(key: "known_traveler_number", label: "Known Traveler Number", category: .identity, sensitive: true,
                   detail: "The user's Known Traveler Number (KTN) for TSA PreCheck: the PASSID from Global Entry, NEXUS or SENTRI, or the number TSA PreCheck issued. Not a frequent-flyer, loyalty, or redress number."),
    ]

    // MARK: Contact

    static let contact: [VaultField] = [
        VaultField(key: "email_personal", label: "Personal email", category: .contact, kind: .email,
                   detail: "The user's personal email address, used for anything not tied to their university."),
        VaultField(key: "email_school", label: "School email", category: .contact, kind: .email,
                   detail: "The user's university-issued email address, used for academic and campus systems."),
        VaultField(key: "phone_mobile", label: "Mobile phone", category: .contact, kind: .phone,
                   detail: "The user's mobile phone number."),
    ]

    // MARK: Education

    static let education: [VaultField] = [
        VaultField(key: "university", label: "University", category: .education,
                   detail: "The name of the college or university the user attends."),
        VaultField(key: "major_primary", label: "Major", category: .education,
                   detail: "The user's primary declared major or field of study."),
        VaultField(key: "major_secondary", label: "Second major", category: .education,
                   detail: "The user's second major, when a form asks for an additional or double major."),
        VaultField(key: "degree_type", label: "Degree type", category: .education,
                   detail: "The kind of degree being pursued, e.g. B.A., B.S."),
        VaultField(key: "grad_year", label: "Graduation year", category: .education, kind: .number,
                   detail: "The year the user expects to graduate."),
        VaultField(key: "class_standing", label: "Class standing", category: .education,
                   detail: "The user's year in school, e.g. Junior."),
        VaultField(key: "student_id", label: "Student ID", category: .education,
                   detail: "The user's university student identification number."),
        VaultField(key: "gpa", label: "GPA", category: .education, kind: .number,
                   detail: "The user's grade point average."),
    ]

    // MARK: Addresses

    static let addresses: [VaultField] = [
        VaultField(key: "home_street_1", label: "Home street", category: .address,
                   detail: "First line of the user's permanent home address: number and street."),
        VaultField(key: "home_street_2", label: "Home street line 2", category: .address,
                   detail: "Second line of the user's permanent home address: apartment, suite, or unit."),
        VaultField(key: "home_city", label: "Home city", category: .address,
                   detail: "City of the user's permanent home address."),
        VaultField(key: "home_state", label: "Home state", category: .address,
                   detail: "State or province of the user's permanent home address."),
        VaultField(key: "home_postal", label: "Home ZIP", category: .address, kind: .postalCode,
                   detail: "ZIP or postal code of the user's permanent home address."),
        VaultField(key: "home_country", label: "Home country", category: .address,
                   detail: "Country of the user's permanent home address."),
        VaultField(key: "campus_street_1", label: "Campus street", category: .address,
                   detail: "First line of the user's current school-year or campus address."),
        VaultField(key: "campus_street_2", label: "Campus street line 2", category: .address,
                   detail: "Second line of the user's campus address: apartment, suite, or unit."),
        VaultField(key: "campus_city", label: "Campus city", category: .address,
                   detail: "City of the user's current campus address."),
        VaultField(key: "campus_state", label: "Campus state", category: .address,
                   detail: "State or province of the user's current campus address."),
        VaultField(key: "campus_postal", label: "Campus ZIP", category: .address, kind: .postalCode,
                   detail: "ZIP or postal code of the user's current campus address."),
    ]

    // MARK: Professional

    static let professional: [VaultField] = [
        VaultField(key: "github_url", label: "GitHub", category: .professional, kind: .url,
                   detail: "The user's GitHub profile URL or username."),
        VaultField(key: "linkedin_url", label: "LinkedIn", category: .professional, kind: .url,
                   detail: "The user's LinkedIn profile URL."),
        VaultField(key: "website_url", label: "Website", category: .professional, kind: .url,
                   detail: "The user's personal website or portfolio URL."),
        VaultField(key: "current_title", label: "Current title", category: .professional,
                   detail: "The user's current job or role title."),
        VaultField(key: "current_org", label: "Current organization", category: .professional,
                   detail: "The organization or employer the user currently works for."),
    ]

    // MARK: Payment — every entry sensitive, so every fill is confirmed + Touch ID gated

    static let payment: [VaultField] = [
        VaultField(key: "card_name", label: "Name on card", category: .payment, sensitive: true,
                   detail: "The cardholder name printed on the user's payment card."),
        VaultField(key: "card_number", label: "Card number", category: .payment, kind: .cardNumber, sensitive: true,
                   detail: "The user's payment card number."),
        VaultField(key: "card_exp", label: "Card expiry", category: .payment, kind: .monthYear, sensitive: true,
                   detail: "The expiration date of the user's payment card."),
        VaultField(key: "card_cvv", label: "Card CVV", category: .payment, kind: .number, sensitive: true,
                   detail: "The security code (CVV / CVC) on the back of the user's payment card."),
        VaultField(key: "billing_street_1", label: "Billing street", category: .payment, sensitive: true,
                   detail: "First line of the billing address attached to the user's payment card."),
        VaultField(key: "billing_city", label: "Billing city", category: .payment, sensitive: true,
                   detail: "City of the billing address attached to the user's payment card."),
        VaultField(key: "billing_state", label: "Billing state", category: .payment, sensitive: true,
                   detail: "State of the billing address attached to the user's payment card."),
        VaultField(key: "billing_postal", label: "Billing ZIP", category: .payment, kind: .postalCode, sensitive: true,
                   detail: "ZIP or postal code of the billing address attached to the user's payment card."),
    ]
}
