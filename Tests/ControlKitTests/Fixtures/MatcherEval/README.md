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

## How the browser names were prepared

1. `SELECT DISTINCT name` from each profile's `autofill` table, opened read-only with
   `file:…?immutable=1&mode=ro`. `Login Data` was never opened.
2. Opaque names dropped: bare numbers, UUIDs, hex hashes, React/Ember/Angular ids,
   `question_<n>` and friends. One of each kind is kept as a representative negative.
3. Identifying tokens scrubbed: the LinkedIn member URN inside profile-editor field names,
   random per-form ids, and long numbers became `<id>` / `<n>`.
4. Near-duplicates (`otp-code-1…4`, `workExperience-N-…`) collapsed to one representative.

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

Found a wrong label? Fix it here and rerun `make eval`. The snapshot re-scores
automatically, so the fix can't make a regression look like an improvement.
