# Control — build tasks
#
# DerivedData deliberately lives OUTSIDE this directory. macOS stamps every file
# written under ~/Desktop with a `com.apple.provenance` extended attribute, and
# codesign refuses to sign a bundle carrying one:
#
#     Control.app: resource fork, Finder information, or similar detritus not allowed
#
# So the path below is fixed and reused on every run — never a fresh /tmp dir.

DERIVED_DATA := $(HOME)/Library/Developer/ControlDerivedData
PROJECT      := Control.xcodeproj
SCHEME       := Control
APP          := $(DERIVED_DATA)/Build/Products/Debug/Control.app

XCB := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED_DATA)

.PHONY: all generate build test eval eval-accept run stop clean logs form install

all: build

## Regenerate Control.xcodeproj from project.yml
generate:
	xcodegen generate

build: generate
	$(XCB) -configuration Debug build

test: generate
	$(XCB) -configuration Debug test

## Matcher accuracy: run the fixture eval and print its report. Fails if any case
## the accepted snapshot got right is now wrong. See Tests/ControlKitTests/MatcherEvalTests.swift.
EVAL_TEST := -only-testing:ControlKitTests/MatcherEvalTests
EVAL_REPORT := sed -n '/=== MATCHER EVAL/,/=== END/p; / error: /p; /\*\* TEST/p'

eval: generate
	@set -o pipefail; $(XCB) -configuration Debug test $(EVAL_TEST) 2>&1 | $(EVAL_REPORT)

## Accept the current predictions as the new snapshot. Review the diff before committing.
eval-accept: generate
	@set -o pipefail; TEST_RUNNER_CONTROL_EVAL_ACCEPT=1 $(XCB) -configuration Debug test $(EVAL_TEST) 2>&1 | $(EVAL_REPORT)

## Build and launch. Control is menu-bar only — look for the insert-text icon.
run: build stop
	open "$(APP)"

stop:
	-@pkill -x Control 2>/dev/null || true

## Install to /Applications and run from there.
##
## Needed for anything TCC-related: System Settings' permission pickers cannot
## navigate into ~/Library, so an app sitting in DerivedData can never be added
## to Full Disk Access by hand. A stable, reachable location also keeps the
## Accessibility grant and Login Item registration pointing at one thing.
##
## Sensitive values (cards, the traveler number) get macOS's own Touch ID lock only
## when the app carries a keychain entitlement, and that needs a Developer ID
## provisioning profile for com.noelsason.Control. Put the profile at $(PROFILE) and
## install embeds it and signs with the keychain entitlements. Without it, the app
## signs as before and Control asks for Touch ID itself (see Keychain.swift). Never
## sign with the keychain entitlements without the profile: the app won't launch.
PROFILE := $(HOME)/Library/Developer/Control/Control.provisionprofile
PLAIN_ENTITLEMENTS := Sources/Control/Resources/Control.entitlements
KEYCHAIN_ENTITLEMENTS := Sources/Control/Resources/Control-Keychain.entitlements

install: build stop
	@rm -rf "/Applications/Control.app"
	@cp -R "$(APP)" "/Applications/Control.app"
	@xattr -cr "/Applications/Control.app" 2>/dev/null || true
	@if [ -f "$(PROFILE)" ]; then \
		cp "$(PROFILE)" "/Applications/Control.app/Contents/embedded.provisionprofile"; \
		xattr -c "/Applications/Control.app/Contents/embedded.provisionprofile" 2>/dev/null || true; \
		entitlements="$(KEYCHAIN_ENTITLEMENTS)"; \
		echo "Signing with the keychain entitlement (profile found at $(PROFILE))"; \
	else \
		entitlements="$(PLAIN_ENTITLEMENTS)"; \
	fi; \
	codesign --force --sign "Developer ID Application" --options runtime \
		--entitlements "$$entitlements" "/Applications/Control.app" 2>/dev/null || \
		codesign --force --sign - "/Applications/Control.app"
	@echo "Installed to /Applications/Control.app"
	@open "/Applications/Control.app"

## Serve the manual QA form and open it. Served over http rather than file://
## so the page has a real host for domain extraction and cache keying.
form:
	@echo "Serving QA/test-form.html at http://127.0.0.1:8787/test-form.html (ctrl-C to stop)"
	@open "http://127.0.0.1:8787/test-form.html" &
	@python3 -m http.server 8787 --bind 127.0.0.1 --directory QA

## Stream Control's own log output.
logs:
	/usr/bin/log stream --predicate 'subsystem == "com.noelsason.Control"' --level info

clean:
	rm -rf "$(DERIVED_DATA)"
	rm -rf $(PROJECT)
