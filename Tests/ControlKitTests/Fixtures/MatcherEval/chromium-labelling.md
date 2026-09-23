# How the Chromium cases were labelled

This is the record for `chromium.json`, `chromium-repro.json` and `chromium-i18n.json`. The
fixture README covers how the cases were extracted. This file covers who decided each `expect`,
what they could see, and every label changed afterwards.

## Counts

| | real sites (`chromium`) | repro | i18n |
|---|---|---|---|
| text-entry fields in the corpus | 1,410 | 645 | 428 |
| unique cases after dedupe | 1,252 | 409 | 290 |
| skipped as unknowable | 1 | 21 | 0 |
| **cases in the fixture** | **1,251** | **388** | **290** |
| of which `expect: []` | 402 | 160 | 85 |
| with a DOM id (run again as `+id`) | 1,020 | 249 | 268 |

All but 98 of the 3,274 `.out` lines tie to a page control. The 98 that don't are duplicates:
the `.out` files for ebay and dickblick list the same form two or three times.

## Blind labelling

1. **Sheets.** One per form, with fields in page order. Each row carries:
   - the visible label, placeholder, title, `name`, DOM id and `maxlength`;
   - the nearest heading;
   - neighbouring non-text controls as context rows.

   Chromium's type and section columns and the `autocomplete` attribute were stripped.
2. **Labellers.** Six labellers took about 325 fields each. They were given only a labelling
   guide (the rules in the README) and their own sheets, and told not to open the raw
   pages, Chromium's output or Control's code.
3. **Consistency pass.** This read only the cases and labels. It found 71 groups where
   identical visible text was labelled differently, 44 of them after setting aside pure
   billing/shipping scope splits. Page context explains every one:
   - split phone boxes;
   - billing blocks named `Bill*`;
   - guardian, tribute and alternate-pickup fields;
   - a gift card's security code;
   - a noisy inferred label overridden by an unambiguous field name.

   No label changed.

**Two leaks, and what was done about them:**
- *Debug text in two pages.* `117_cc_checkout_macys.com` and `140_checkout_nike.com` were
  saved with Chrome's autofill-prediction overlay on. Their `title` attributes read
  "overall type: NAME_FIRST server type: …", which is Chromium's answer in the page text.
  - 14 cases showed it to a labeller.
  - The extractor now drops those titles; an inferred label keeps only the real label text
    quoted inside the debug text.
  - The 14 labels were re-reviewed against the cleaned text, and all 14 stand.
- *A directory listing.* One labeller's `ls` showed other batches' label file names. No
  contents were read, and nothing from Chromium was involved.

**Alignment fix, made after labelling.** A few fields had been tied to the wrong control:
- a nameless checkbox the `.out` doesn't list shifted every later nameless field in
  `109_checkout_m_nordstroms.com`;
- repeated names in 018, 153 and 155 were swapped, because the `.out` lists fields form by
  form rather than in document order.

Alignment now matches repeated names by label similarity and runs an order-preserving
alignment over nameless controls. Afterwards, the one remaining label mismatch across 1,547
comparable fields is the same field seen two ways ("Enter a location" / "Where").

Each blind label was carried to its field by content. Four fields that no labeller had seen
were labelled by the reviewer from the page text:
- `018 lastName` (shipping) → `family_name`
- `030 zipCode`, a store-finder box beside the site search → `[]`
- `109 r033`, the order-confirmation email → `email_personal`
- `109 r034`, the order phone → `phone_mobile`

## Agreement with Chromium's types (diagnostic only)

For the comparison, Chromium types map onto Control keys like this:
- Address types compare by component, ignoring scope.
- `EMAIL_ADDRESS` accepts either email.
- Whole-number phone types map to `phone_mobile`. Phone parts, split expiry, `UNKNOWN_TYPE`
  and the ignored types map to `[]`.

| | blind | after review |
|---|---|---|
| chromium | 91.7% (1,147 / 1,251) | 91.8% |
| chromium-repro | 88.9% (345 / 388) | 89.4% |
| chromium-i18n | 94.1% (273 / 290) | 94.1% |

The 160 disagreements that remain, by cause:

| count | cause |
|---|---|
| 43 | Chromium says `UNKNOWN_TYPE`, but a key fits (a single DOB box, "Other State/Province", a sign-in email, fields on the i18n and repro pages) |
| 38 | billing address line 2 or billing country: the field wants them, but those keys don't exist, so `[]` |
| 33 | a box with no key: a whole-address box, county, building name, city of birth, nationality, a hotel address, a decoy, a saved-address nickname |
| 27 | someone else's data: a guardian, a tribute honoree, a gift recipient, an alternate pickup person, share/invite boxes, wish-list search |
| 7 | an alternate phone on a form that also has a primary phone |
| 6 | one part of a split phone that Chromium typed as the whole number |
| 6 | other: ZIP-prefix typing, a middle-name box labelled "Additional info", Turkish "Şehir", German PLZ/Ort |

## Review

Every disagreement was reviewed, and so was a seeded random 10% of agreements (177 cases,
`random.Random(2026)`). Review could move a label toward Chromium or away from it.

| case | was | now | direction | reason |
|---|---|---|---|---|
| `chromium-repro.137_bug_555010.cardName` | `full_name` | `card_name`, `full_name` | toward | `name=cardName` in the payment-method block: the cardholder's name, which is also the full name |
| `chromium-repro.079_crbug_52198.idCardNumber` | `student_id` | `[]` | toward | asks for a UT Austin ID card number; the user's student ID is Berkeley's |
| `chromium.029_checkout_kohls.com.bill_phone` | `[]` | `phone_mobile` | toward | `<label for=bill_phone>Contact Phone:</label>` on a text input: the whole number, not a part |
| `chromium.029_checkout_kohls.com.ship_phone` | `[]` | `phone_mobile` | toward | same, shipping block |

Four changes in total, all toward Chromium. None of the 177 sampled agreements changed.

## `autocomplete` cross-check

The `autocomplete` attribute is what the site itself declared, so it is independent of
Chromium's parser. 72 labelled cases carry a meaningful token: 17 real-site, 51 repro, 4 i18n.
None of them are in the adversarial `014`/`015` pages; those fields are either skipped or their
tokens are invalid.

**1 of 72 disagrees (1.4%):** `151_ticketmaster.com mobile_phone`, "Alternate Phone",
`autocomplete="billing tel"`. The label says `[]` under the alternate-phone rule, because the
form has a primary phone.

The first run of this cross-check reported 6 disagreements. Five came from the comparison
script, which mapped `cc-given-name`/`cc-family-name` to `[]` instead of to the user's own
names. No label changed because of them.
