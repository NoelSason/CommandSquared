# Control

A system-wide smart paste for macOS. Focus any text field, press **⌘⇧Space**, and Control
reads the field's label, works out what it's asking for, and fills it from a local vault.

Matching runs in three tiers, first hit wins:

1. **Cache** — this exact field on this exact site resolved before. Instant, offline, and
   holds your corrections permanently.
2. **Local rules** — `LocalMatcher`'s deterministic table. "Email address", "ZIP",
   "Phone number" and friends never cost a network call.
3. **[Jev](https://www.jevai.org)** — a `choice` question over the candidate keys for
   anything the rules can't settle, gated on the returned `confidence`.

## Privacy boundary

Vault **values never leave the device.** `JevMatcher` is the only type that builds a
request, and it sends:

- the field's label, placeholder, help text, and role
- the app name and the page's *host* (never the full URL — query strings carry tokens)
- nearby static text, capped at 8 entries of 120 characters
- the **names and descriptions** of at most 12 candidate vault keys

Jev answers with a key. The value is looked up locally afterward.
`JevDecodingTests.testRequestCarriesNoVaultValues` pins this.

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
5. Optional: *Matching* → paste a Jev API key from `https://www.jevai.org/agent/keys`.
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
