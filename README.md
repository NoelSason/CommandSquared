# Control

A system-wide smart paste for macOS. Focus any text field, press **⌘⇧Space**, and Control
reads the field's label, works out what it's asking for, and fills it from a local vault.

Matching runs in three tiers, first hit wins:

1. **Cache** — this exact field on this exact site resolved before. Instant, offline, and
   holds your corrections permanently.
2. **Local rules** — `LocalMatcher`'s deterministic table. "Email address", "ZIP",
   "Phone number" and friends never cost a network call.
3. **[Jev](https://docs.typesafe.ai)** (TypeSafe's model, `api.typesafe.ai/v1/systemone`) — a `choice` question over the candidate keys for
   anything the rules can't settle, gated on the returned `confidence`.

## Local rules

`LocalMatcher` combines two sources of evidence:

- **Chromium's autofill patterns** (`Match/ChromiumPatterns.swift`, BSD-3-Clause, see
  `THIRD_PARTY_NOTICES.md`) decide *what kind* of field this is: a first name, an email,
  a city, a card number. They also recognise fields that must be left alone, such as
  search boxes, one-time codes and promo codes, and those veto every match.
- **Control's own rules** handle what a browser can't: school vs personal email (using
  the user's own institution as a hint), home vs campus vs billing address (from the
  section heading), the education and professional keys Chromium has no type for, and
  snippets, which are never guessed.

The patterns run against **raw, lowercased text, one attribute at a time**, not against
the normalised `searchText` Control's phrase rules use. That's deliberate:

- `normalize()` turns punctuation into spaces, and many patterns depend on punctuation
  (`e.?mail`, `(?<!\.)zip`, `address[_-]?line`, `m\.i\.`). On normalised text they stop
  matching, or match exactly what they were written to exclude.
- Anchors such as `^name` describe one label, not a joined string.
- Rewriting the patterns for normalised text would be translation with nothing to check
  it against.

The full reasoning is on `FieldContext.patternLabelParts`, and `ChromiumPatternTests`
pins it in both directions. Every match must still begin a word, the same rule that
stops "sid" matching inside "residential".

Accuracy is measured, not asserted. `make eval` runs about 850 labelled cases (the
hand-test page, past regressions, and real browser field names) and fails if any case the
accepted snapshot got right is now wrong. See `Tests/ControlKitTests/Fixtures/MatcherEval/`.

## Privacy boundary

Vault **values never leave the device.** `JevMatcher` is the only type that builds a
request, and it sends:

- the field's label, placeholder, help text, and role
- the app name and the page's *host* (never the full URL — query strings carry tokens)
- nearby static text, capped at 8 entries of 120 characters
- the **names and descriptions** of at most 12 candidate vault keys

Jev answers with a key. The value is looked up locally afterward.
`JevDecodingTests.testRequestCarriesNoVaultValues` pins this.

### Long-answer drafts

The one other thing that leaves the Mac, and only once it is set up (Settings → *Long
answers*: a Claude key and some "About you" text). When the trigger lands in an empty,
multi-line field whose label reads as an open question — "Tell us about a project you're
proud of", "Why us?", anything with a word limit — and neither the cache nor the local rules
have a confident answer, `AnswerDrafter` asks Claude (`claude-sonnet-5`, adaptive thinking
at low effort) for a first draft and streams it into the field a few words at a time. Before
every piece Control checks the field still has focus and still holds exactly the draft so far,
and stops if not; pressing the trigger again stops it too. What was written stays. It sends:

- the "About you" text, marked for prompt caching so the next question on the same form is cheap
- the field's label, help text, placeholder and label cell, and nearby text capped as for Jev
- the page's host and window title, which usually names the organisation asking
- up to 4,000 characters of the page's own static text, often the role's description
  (`PageTextReader`); nothing inside a form control or an editable region is read, so no
  typed or filled-in value is ever part of it
- drafts Control wrote for other questions on the same site in the last two hours, so each
  answer tells a different story; kept in memory only

`AnswerDrafter` has no access to the vault. A question only in the placeholder ("What's on
your mind?") never counts, so chat boxes are left alone; see `LongAnswerPolicy`. A draft
costs one to two cents, and settings show a running monthly estimate.

Pressing the trigger again within three minutes, on a box still holding the untouched draft,
clears it and writes a different one, shown the old draft as what to move away from. Tapping
the double-tap modifier three times drafts into any empty box. When a draft is done the toast
gives its word count, and warns when it's over a limit the question states (`LengthLimit`).

### Saved answers

Every answer Control drafts is saved when the user moves on from the box, as they left it:
an edited draft is saved edited (`AnswerWatcher`, `Preferences.saveAnswer`). Before drafting,
`FillController` looks for one to reuse instead:

- the same wording (ignoring case, punctuation and Google Forms' "Required question") is found
  locally, with no network call
- a reworded question goes to Jev as a `choice` over up to 12 earlier questions
  (`AnswerReuse`), and only a pick at 0.75 confidence or above is reused. **Jev sees question
  text only, never an answer**, the same boundary as field matching
- an answer is skipped if it breaks the new box's length limit, would put paragraphs in a
  single-line box, or was already used on the same form

A reused answer goes in at once, and pressing the trigger again replaces it with a fresh
draft. Saved answers live in the Keychain on this Mac, listed and deletable in settings.

### Learning from answers

Off until turned on (Settings → *Long answers* → *Learn from your answers*). `AnswerWatcher`
notices when the user has finished answering a form question: they typed into another
field, clicked away, switched apps, or left the field for 20 seconds. It never writes to a
field. The answer then goes to Claude (`claude-haiku-4-5`) only if every local check passes:

- the field's own label reads as a question (`LongAnswerPolicy`), and it isn't a password field
- the question isn't demographic, legal, salary, health or a security question (`AnswerLearner.shouldConsider`)
- the answer is prose, not a link, a code or a number
- the app or site isn't turned off, and the answer isn't a saved detail or an untouched Control draft

Haiku sees the question, the answer, the host, the "About you" text and the facts already
learned, and replies with up to three short facts or `NONE`. Facts are kept in the Keychain
on this Mac, listed and deletable in settings, and ride along with "About you" in every
draft. A ceiling of 40 calls an hour guards against anything firing in a loop.

Two hard blocks run before matching: a focused element with subrole `AXSecureTextField` is
refused outright, and so is anything on the user's app/domain denylist.

## Layout

| Path | What lives there |
|---|---|
| `Sources/ControlKit` | Vault, matching, Jev. No AppKit, no Accessibility, fully testable. |
| `Sources/Control` | The app: hotkey, AX capture, insertion, UI. |
| `Tests/ControlKitTests` | 39 tests over the logic tier. |

`ControlKit` is a separate framework so `make test` never has to launch the app — which
would register a global hotkey and prompt for Accessibility on every run.

## Build

```sh
make build     # generate the project and build
make test      # run the ControlKit suite
make eval      # matcher accuracy report (make eval-accept records a new snapshot)
make run       # build, relaunch, and open the app
make logs      # stream Control's own os_log output
make clean     # drop DerivedData and the generated project
```

`Control.xcodeproj` is generated from `project.yml` by [xcodegen](https://github.com/yonaskolb/XcodeGen)
and is not checked in.

### Why DerivedData lives outside this directory

macOS stamps a `com.apple.provenance` extended attribute on files written anywhere under
`~/Desktop`, and `codesign` refuses a bundle carrying one:

```
Control.app: resource fork, Finder information, or similar detritus not allowed
```

Clearing the attribute doesn't help — it comes straight back on the next write. So the
Makefile pins DerivedData to `~/Library/Developer/ControlDerivedData`: one fixed path,
reused every run, never a fresh `/tmp` directory.

## First run

1. `make run`.
2. Control is menu-bar only — look for the insert-text icon. No Dock icon by design.
3. Grant **Accessibility** access when asked (System Settings → Privacy & Security →
   Accessibility). Nothing works without it: Control can neither read a label nor type.
4. Menu bar → **Settings…** → *Your details* and fill in what you want available.
5. Optional: *Matching* → paste a TypeSafe API key from `https://console.typesafe.ai/keys`.
   Tiers 1 and 2 work without it.

Accessibility trust is keyed on bundle ID **and** code signature, which is why the Makefile
builds to a fixed path with a stable ad-hoc identity. Move the app or change how it's signed
and macOS will ask again.

## Field Inspector

Menu bar → **Field Inspector…**. While that window is open the hotkey **captures instead of
filling** — it shows the extracted `FieldContext` and the raw AX attribute dump, and inserts
nothing.

This is the tool for the thing that actually varies: accessibility label quality differs a
lot between apps, and a failed fill doesn't tell you whether the label was missing, the role
was wrong, or the insertion bounced. Field values are shown as a character count, never as
text.

## Insertion

`TextInserter` tries four methods in order, verifying against the element's value after each:

1. `kAXSelectedTextAttribute` — insert at the caret.
2. `kAXValueAttribute` — only when the field is empty, since it replaces rather than inserts.
3. Synthesized Unicode keystrokes — works in web and Electron content where AX writes
   silently no-op, and never touches the clipboard.
4. Clipboard + ⌘V, restoring the previous plain-text contents. Lossy, and disabled entirely
   for sensitive fields.

Before any of it, Control waits for the hotkey's modifiers to be released — typing while ⌘⇧
is still physically held turns every synthesized keystroke into a menu shortcut.

## Sensitive fields

Payment entries are stored with a `SecAccessControl` carrying `.userPresence`, so macOS
itself demands Touch ID at read time. They are never read while ranking candidates, only
after the user confirms; they always require confirmation regardless of confidence; the
picker masks their previews; and the clipboard fallback is disabled for them.
