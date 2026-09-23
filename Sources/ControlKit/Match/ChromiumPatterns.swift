// Field-type patterns derived from Chromium's autofill heuristics.
//
// Source: components/autofill/core/browser/form_parsing/resources/legacy_regex_patterns.json
// https://github.com/chromium/chromium/blob/7c4a2eb3203b43eb1c934ac6181c6790c84d69bd/components/autofill/core/browser/form_parsing/resources/legacy_regex_patterns.json
// Commit 7c4a2eb3203b43eb1c934ac6181c6790c84d69bd (2026-08-11).
//
// Changes from the original:
// - English patterns only, and only the types that map to a Control key or veto
//   one (see `ChromiumPatterns.omitted` for what was left out and why).
// - ADDRESS_LINE_2's name pattern drops its `street` alternative. Chromium relies
//   on field order to tell the second "street" field from the first; Control sees
//   one field at a time.
// - At match time every pattern must begin at a word start (see `LocalMatcher`),
//   and scores are rescaled into Control's 0–1 range.
//
// Copyright 2015 The Chromium Authors
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google LLC nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import Foundation

/// A field type, named as Chromium names it.
enum ChromiumFieldType: String, Sendable, CaseIterable {
    // Types that fill a Control key.
    case firstName = "FIRST_NAME"
    case middleName = "MIDDLE_NAME"
    case middleInitial = "MIDDLE_INITIAL"
    case lastName = "LAST_NAME"
    case fullName = "FULL_NAME"
    case nameGeneric = "NAME_GENERIC"
    case email = "EMAIL_ADDRESS"
    case addressLine1 = "ADDRESS_LINE_1"
    case addressLine2 = "ADDRESS_LINE_2"
    case apartmentNumber = "ADDRESS_HOME_APT_NUM"
    case city = "CITY"
    case state = "STATE"
    case zip = "ZIP_CODE"
    case country = "COUNTRY"
    case phone = "PHONE"
    case company = "COMPANY_NAME"
    case nameOnCard = "NAME_ON_CARD"
    case cardNumber = "CREDIT_CARD_NUMBER"
    case cardVerificationCode = "CREDIT_CARD_VERIFICATION_CODE"
    case cardExpiry = "CREDIT_CARD_EXP_DATE"
    case cardExpiryTwoDigitYear = "CREDIT_CARD_EXP_DATE_2_DIGIT_YEAR"
    case cardExpiryFourDigitYear = "CREDIT_CARD_EXP_DATE_4_DIGIT_YEAR"

    // Types Chromium recognises so that it can *decline* to fill them. Control
    // uses them the same way: as vetoes.
    case nameIgnored = "NAME_IGNORED"
    case honorificPrefix = "HONORIFIC_PREFIX"
    case addressNameIgnored = "ADDRESS_NAME_IGNORED"
    case addressLookup = "ADDRESS_LOOKUP"
    case attentionIgnored = "ATTENTION_IGNORED"
    case searchTerm = "SEARCH_TERM"
    case oneTimeCode = "ONE_TIME_CODE"
    case promoCode = "MERCHANT_PROMO_CODE"
    case price = "PRICE"
    case numericQuantity = "NUMERIC_QUANTITY"
    case iban = "IBAN_VALUE"
    case passport = "PASSPORT"
    case giftCard = "GIFT_CARD"
    case debitGiftCard = "DEBIT_GIFT_CARD"
    case loyaltyMembership = "LOYALTY_MEMBERSHIP_ID"
}

/// One entry of Chromium's pattern file, copied verbatim.
struct ChromiumPattern: Sendable {
    let type: ChromiumFieldType
    /// ICU regular expression, matched case-insensitively.
    let positive: String
    /// A match here cancels a positive match on the same text.
    let negative: String?
    /// Chromium's `positive_score`. Rescaled by `LocalMatcher`.
    let score: Double
    /// `match_field_attributes` is `[LABEL]` only: Chromium never runs this
    /// pattern against an HTML field name.
    let labelOnly: Bool

    init(_ type: ChromiumFieldType, _ positive: String, negative: String? = nil, score: Double, labelOnly: Bool = false) {
        self.type = type
        self.positive = positive
        self.negative = negative
        self.score = score
        self.labelOnly = labelOnly
    }
}

enum ChromiumPatterns {
    static let english: [ChromiumPattern] = [
        // Names
        ChromiumPattern(.firstName, ##"first.*name|initials|fname|first$|given.*name"##, score: 0.9),
        ChromiumPattern(.middleName, ##"middle.*name|mname|middle$"##, score: 0.9),
        ChromiumPattern(.middleInitial, ##"middle.*initial|m\.i\.|mi$|\bmi\b"##, score: 0.9),
        ChromiumPattern(.lastName, ##"last.*name|lname|surname|last$|secondname|family.*name"##, negative: ##"surname\d"##, score: 0.9),
        ChromiumPattern(.fullName, ##"^name|full.?name|your.?name|customer.?name|bill.?name|ship.?name|name.*first.*last|firstandlastname|contact.?(name|person)|receiver"##, score: 0.9),
        ChromiumPattern(.nameGeneric, ##"^name"##, score: 0.9),

        // Contact
        ChromiumPattern(.email, ##"e.?mail"##, score: 1.4),
        ChromiumPattern(.phone, ##"phone|mobile|contact.?number"##, score: 1.2),
        ChromiumPattern(.company, ##"company|business|organization|organisation"##, score: 1.1),

        // Address
        ChromiumPattern(.addressLine1, ##"^address$|address[_-]?line(one)?|address1|addr1|street|(?:shipping|billing)address$|house.?name"##, score: 1.1),
        ChromiumPattern(.addressLine1, ##"(^\W*address)|(address\W*$)|(?:shipping|billing|mailing|pick.?up|drop.?off|delivery|sender|postal|recipient|home|work|office|school|business|mail)[\s\-]+address|address\s+(of|for|to|from)|street.*(house|building|apartment|floor)|(house|building|apartment|floor).*street"##, score: 1.1, labelOnly: true),
        // Upstream: address[_-]?line(2|two)|address2|addr2|street|suite|unit
        ChromiumPattern(.addressLine2, ##"address[_-]?line(2|two)|address2|addr2|suite|unit"##, score: 1.1),
        ChromiumPattern(.apartmentNumber, ##"apartment"##, score: 1.1),
        ChromiumPattern(.city, ##"(?<!(?:pa|ri|li|di|ni|lo))city|town|suburb"##, score: 1.1),
        ChromiumPattern(.state, ##"(?<!(united|hist|history).?)state|region|province|county|principality"##, score: 1.1),
        ChromiumPattern(.zip, ##"(?<!\.)zip|postal|post.*code|pcode|pin.?code"##, score: 1.1),
        ChromiumPattern(.country, ##"country|countries"##, score: 1.1),

        // Payment
        ChromiumPattern(.nameOnCard, ##"card.?(?:holder|owner)|name.*on.*card|(?:card|cc).?name|cc.?full.?name"##, score: 1.0),
        ChromiumPattern(.cardNumber, ##"(?:card|cc|acct).?(?:number|#|no|num|field(?!s)|pan)|0000 ?0000 ?0000 ?0000|1234 ?1234 ?1234 ?1234|^xxxx ?xxxx ?xxxx ?xxxx$"##, score: 1.0),
        ChromiumPattern(.cardVerificationCode, ##"verification|card.?identification|security.?code|card.?code|security.?value|security.?number|card.?pin|c-v-v|(?:cvn|cvv|cvc|csc|cvd|ccv)|\bcid\b|cccid"##, score: 1.0),
        ChromiumPattern(.cardExpiry, ##"expir|exp.*date|^expfield$"##, score: 1.0),
        ChromiumPattern(.cardExpiryTwoDigitYear, ##"(?:exp.*date[^y\n\r]*|mm\s*[-/]?\s*)(?:yy(?!y)|aa(?!a)|jj(?!j))"##, score: 1.0),
        ChromiumPattern(.cardExpiryFourDigitYear, ##"(?:exp.*date[^y\n\r]*|mm\s*[-/]?\s*)(?:yyyy(?!y)|aaaa(?!a)|jjjj(?!j))"##, score: 1.0),

        // Vetoes
        ChromiumPattern(.nameIgnored, ##"user.?name|user.?id|nickname|maiden name|title|prefix|suffix|mail"##, score: 0.9),
        ChromiumPattern(.honorificPrefix, ##"^title:?$|salutation"##, negative: ##"salutation and given name"##, score: 0.9),
        ChromiumPattern(.addressNameIgnored, ##"(?:address|location).*(?:nickname|label|type)"##, negative: ##"e.?mail|re.?type|typed"##, score: 1.1),
        ChromiumPattern(.addressLookup, ##"lookup"##, score: 1.1),
        ChromiumPattern(.attentionIgnored, ##"attention|attn"##, score: 1.1),
        ChromiumPattern(.searchTerm, ##"^q$|search|query|qry"##, score: 0.8),
        ChromiumPattern(.oneTimeCode, ##"otp|verification.code|2fa|six.digit"##, score: 1.1),
        ChromiumPattern(.promoCode, ##"(promo(tion|tional)?|gift|discount|coupon)[-_. ]*code"##, score: 0.85),
        ChromiumPattern(.price, ##"\bprice\b|\brate\b|\bcost\b"##, score: 0.95),
        ChromiumPattern(.numericQuantity, ##"size|height|quantity|length|amount"##, score: 0.95),
        ChromiumPattern(.iban, ##"(\biban(\b|_)|international bank account number)"##, score: 0.975),
        ChromiumPattern(.passport, ##"document.*number|passport"##, score: 1.2),
        ChromiumPattern(.giftCard, ##"gift.?(card|cert)"##, score: 1.0),
        ChromiumPattern(.debitGiftCard, ##"(?:visa|mastercard|discover|amex|american express).*gift.?card"##, score: 1.0),
        ChromiumPattern(.loyaltyMembership, ##"loyalty.*(?:num|card)|frequent[\s-]*flyer|(?:member|membership|traveler|flyer).*(?:number|no)"##, score: 1.1),
    ]

    /// English types in the upstream file that are deliberately not ported.
    static let omitted: [String: String] = [
        // Chromium parses a form top to bottom and uses the previous field to
        // decide these. Control sees one field at a time, so on their own they
        // would misfire: `address|line` would make every "Address" line 2.
        "ADDRESS_LINE_2 (label pattern)": "order-dependent",
        "ADDRESS_LINE_EXTRA": "order-dependent",
        "NAME_ON_CARD_CONTEXTUAL": "order-dependent (only after a card number)",
        "CREDIT_CARD_EXP_MONTH, CREDIT_CARD_EXP_YEAR and their split variants": "order-dependent; Control stores one expiry",
        "PHONE_AREA_CODE, PHONE_PREFIX, PHONE_SUFFIX, PHONE_EXTENSION, PHONE_COUNTRY_CODE and separators": "order-dependent parts of a split number",
        "DAY": "order-dependent part of a split date",
        // No Control key, or specific to other countries' address formats.
        "ADDRESS_HOME_HOUSE_NUMBER, ADDRESS_HOME_STREET_NAME, ADDRESS_HOME_DEPENDENT_LOCALITY": "no Control key",
        "IN_DEPENDENT_LOCALITY, IN_STREET_LOCATION, LANDMARK, BETWEEN_STREETS*, OVERFLOW_AND_LANDMARK": "regional",
        "COUNTRY_LOCATION": "\"Location\" means a city on most English forms",
        "REGION_IGNORED": "only meaningful alongside a separate state field",
        "ALTERNATIVE_FAMILY_NAME, ALTERNATIVE_FULL_NAME, ALTERNATIVE_GIVEN_NAME": "phonetic names",
        "FLIGHT, TRAVEL_ORIGIN, TRAVEL_DESTINATION, DEBIT_CARD, AUGMENTED_PHONE_COUNTRY_CODE": "no Control key",
    ]
}
