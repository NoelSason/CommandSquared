# Matcher eval fixtures

Labelled cases for `MatcherEvalTests`, which runs every case through `LocalMatcher`,
prints an accuracy report, and fails if a case that `snapshot.json` got right is now
wrong.

```sh
make eval          # report + ratchet
make eval-accept   # accept current predictions as the new snapshot (review the diff)
```

## Files

| File | What it holds |
|---|---|
| `form.json` | One case per input on `QA/test-form.html` (`form.<inputId>`). A test fails if an input has no case. Nearby text is simulated from `AXFieldReader`'s walk: the field's own `<label>`, then the section heading and every subhead in the section, then the page title. |
| `regression.json` | Every label→key assertion in `LocalMatcherTests`, `MatchHintsTests` and `VaultImporterTests`. |
| `handwritten.json` | Labels in the style of Greenhouse, Lever, Workday, Google Forms, checkout and university forms. Written before the Chromium port and then frozen. Reported separately because the same person wrote the rules. |
| `browser.json` | Real HTML field names from the Brave and Chrome form history (`Web Data` → `autofill`). Names only; values were never read. |
| `chromium.json` | Text fields from the real-site forms in Chromium's autofill heuristics corpus (checkout, register and other named sites), as capture would see them. Labelled blind; see below. |
| `chromium-repro.json` | The same corpus's synthetic and minimal pages: `bug`/`crbug` repros and hand-built test forms. In the headline, reported separately. |
| `chromium-i18n.json` | The corpus's non-English pages. **Not in the headline**: the matcher is English-only by design, and this measures what that costs. |
| `chromium-labelling.md` | How the Chromium cases were labelled and reviewed: agreement with Chromium's own types, the `autocomplete` cross-check, and every label changed in review. |
| `snapshot.json` | Last accepted prediction per case id. Predictions, not verdicts, so fixing a label re-scores the baseline too. |

## Case shape

```json
{ "id": "browser.billing_city", "input": "fieldName", "label": "billing_city",
  "placeholder": null, "help": null, "nearby": [], "expect": ["billing_city"], "note": "…" }
```

- `input: "label"` is text as the Accessibility API reports it at fill time. It runs
  with a Berkeley student's `MatchHints`.
- `input: "fieldName"` goes through `VaultImporter.context(forFieldName:)`, exactly as an
  import would, with no hints.
- `expect` lists every acceptable key. An empty list means the field must match nothing.
- A prediction is the top key scoring at or above `MatchThresholds.confirm`. *Harmful*
  means wrong and at or above `autoInsert`: a silent wrong fill.
- About a quarter of cases are a holdout split (by FNV-1a of the id). The report gives
  totals for them, never per-case detail.
- `fieldName` (optional, label cases only) is the field's DOM `id`, which is what
  `AXDOMIdentifier` exposes. Capture reads it in Chrome and Safari as
  `FieldContext.domIdentifier`, which the matcher treats as weak, nearby-strength evidence
  and never sends to Jev. Native apps and other browsers have no id, so a case with one
  runs twice: label-only (the headline) and `+id`, which passes the id as capture does.
  The `+id` run has its own snapshot entry (`<id>+id`) and shares its case's holdout split.

## How the browser names were prepared

1. `SELECT DISTINCT name` from each profile's `autofill` table, opened read-only with
   `file:…?immutable=1&mode=ro`. `Login Data` was never opened.
2. Opaque names dropped: bare numbers, UUIDs, hex hashes, React/Ember/Angular ids,
   `question_<n>` and friends. One of each kind is kept as a representative negative.
3. Identifying tokens scrubbed: the LinkedIn member URN inside profile-editor field names,
   random per-form ids, and long numbers became `<id>` / `<n>`.
4. Near-duplicates (`otp-code-1…4`, `workExperience-N-…`) collapsed to one representative.

## How the Chromium corpus was prepared

Source: `components/test/data/autofill/heuristics/` at Chromium commit
`7c4a2eb3203b43eb1c934ac6181c6790c84d69bd`: 184 `input/*.html` pages and their
`output/*.out` files. The HTML was downloaded to a scratch directory and never committed;
only the tuples below are.

1. Each `.out` line was tied to its HTML control by name (or id) and occurrence. The 98
   lines that don't tie are repeat listings of the same form in two files (ebay, dickblick).
2. Only text-entry controls are kept: `input` of type text, email, tel, url, search, number
   or an unknown type (browsers render those as text), and `textarea`.
3. Each case simulates what capture sees:
   - `label`: aria-labelledby, then aria-label, then `<label for>`, then a wrapping
     `<label>`, then `title`.
   - `placeholder`, and `help` (the `title` when it isn't the label).
   - `heading`: when the field has no markup label, the text Chromium inferred for it
     from the page (a table cell, preceding text). That is what `NearbyTextPolicy`
     returns as the heading of a label-less field. Otherwise the nearest preceding
     h1–h6, legend, caption, or short header- or title-classed text.
   - `nearby`: that inferred text, then the section heading.
   - `fieldName`: the DOM `id`. The `name` attribute is kept in `note` only.

   About half the real-site fields have no markup label, so their words reach the
   matcher only as nearby text. That's deliberate: it is what Control sees on those
   pages today.
4. Deduplicated on (visible label text, field name, placeholder), keeping the first
   occurrence, with real sites first. Fields with no text at all and no id were dropped.
5. Groups:
   - `chromium-i18n`: every `*_i18n_*` page except the two English ones, plus 098,
     152, 154, 155, 159, 167, 169 and 175–179.
   - `chromium-repro`: `bug`/`crbug`, `autocomplete_attribute_*`, `misc_phones`,
     `address2lines`, `credit_card_ignore_birthday_fields`, `namesurname`, `cc_forms*`,
     `otp`, `002_i18n_en` and `166_i18n_en_honorific_prefix`.
   - Everything else is `chromium`.

**The circularity trap.** The `.out` types are Chromium's own parser output, saved as
regression goldens, and `LocalMatcher` runs Chromium's patterns. Scoring against those
types would reward agreeing with Chromium, mistakes included. So the `expect` keys are
Control's own labels:
- Labelled **blind**: the type, section and `autocomplete` columns were stripped from the
  labelling sheets.
- Labelled from the field's text, names and neighbouring fields, by the rules below.
- Only then compared with Chromium's types, as a diagnostic.
- Review covered every disagreement and a seeded random 10% of agreements, so review
  could move labels either way. Every change is logged in `chromium-labelling.md`.

## Labelling rules

Browser names were labelled **from the name alone, before any matcher output was seen.**

- `expect` is the vault key whose value belongs in the field.
- It is `[]` when no vault key fits. That includes:
  - one part of a split value: `phonePart2`, `birthDate-month`, `ccmonth`
  - someone else's details: a second passenger, a guest, an emergency contact
  - login, config and product fields: `username`, `SMTP_SENDER_NAME`, `project-name`
- A field for "you" in a role counts as the user: the first traveller, the CEO on a
  founder application, the candidate on a job application.
- An address component with no scope accepts every scope (home, campus, billing).
- A bare email field name accepts both addresses. Label cases follow the test form
  instead: a bare "Email address" wants the personal one.
- Genuinely unknowable names (`cname`, `link`, `co-email`) were left out rather than
  guessed.

Added for the Chromium cases:
- Scope follows the page. Shipping, mailing and contact addresses are unscoped. A billing
  section accepts only `billing_*`, and billing line 2 and billing country are `[]`, because
  those keys don't exist.
- A bare email is `email_personal`, including confirm and re-enter boxes and a sign-in
  email. A work email is `[]`.
- The user's phone, however it's described (home, day, evening, cell), is `phone_mobile`.
  Work phone, fax and split phone boxes are `[]`. An "alternate" phone is `[]` when the
  form also has a primary one.
- Card expiry in one box is `card_exp`; a separate month box and year box are each `[]`.
- These are all `[]`:
  - account handles and site nicknames;
  - security questions, PINs, captchas and codes;
  - gift recipients and "tell a friend";
  - address line 3, county, a separate house number or street name, a whole-address box,
    a company address.

Found a wrong label? Fix it here and rerun `make eval`. The snapshot re-scores
automatically, so the fix can't make a regression look like an improvement.
