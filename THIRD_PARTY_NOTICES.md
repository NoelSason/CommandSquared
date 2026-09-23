# Third-party notices

## Chromium autofill patterns

`Sources/ControlKit/Match/ChromiumPatterns.swift` contains field-type patterns derived from
Chromium's `components/autofill/core/browser/form_parsing/resources/legacy_regex_patterns.json`
at commit `7c4a2eb3203b43eb1c934ac6181c6790c84d69bd`. Only English patterns were taken, and
only a subset. The source file lists what was changed.

```
Copyright 2015 The Chromium Authors

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

   * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
   * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.
   * Neither the name of Google LLC nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

A binary distribution must reproduce this notice. The app's acknowledgements carry it
(added with the release work).

## Chromium autofill heuristics test data

`Tests/ControlKitTests/Fixtures/MatcherEval/chromium.json`, `chromium-repro.json` and
`chromium-i18n.json` contain field labels, placeholders, titles, nearby text and element ids
extracted from Chromium's `components/test/data/autofill/heuristics/input/*.html` at commit
`7c4a2eb3203b43eb1c934ac6181c6790c84d69bd`. The pages themselves are not included; the
expected keys are Control's own labels, not Chromium's. Same BSD-3-Clause license and
copyright notice as above. Test data only: nothing from it ships in the app.
