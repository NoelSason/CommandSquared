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

.PHONY: all generate build test run stop clean logs form

all: build

## Regenerate Control.xcodeproj from project.yml
generate:
	xcodegen generate

build: generate
	$(XCB) -configuration Debug build

test: generate
	$(XCB) -configuration Debug test

## Build and launch. Control is menu-bar only — look for the insert-text icon.
run: build stop
	open "$(APP)"

stop:
	-@pkill -x Control 2>/dev/null || true

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
