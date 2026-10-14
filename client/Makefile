.PHONY: build app run release test coverage clean version bump-patch bump-minor bump-major tag

CONFIG := debug
ifeq ($(firstword $(MAKECMDGOALS)),release)
CONFIG := release
endif

# Version comes from ../VERSION (see ../scripts/version.sh). The build "number"
# (shown in parentheses in About Papertalk) is the short commit hash the app was
# built from, so any build can be traced to its exact source; override with BUILD_NUMBER=...
VERSION := $(shell ../scripts/version.sh)
BUILD_NUMBER ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
RELEASE_ZIP := dist/Papertalk-$(VERSION).zip

# Compile the executable (config-aware so `make release` builds the release binary)
build:
	swift build -c $(CONFIG)

# Build a runnable .app bundle (dist/Papertalk.app).
# Debug by default; `make release` builds the release binary instead.
app: build
	APP="dist/Papertalk.app"; \
	rm -rf "$$APP"; \
	mkdir -p "$$APP/Contents/MacOS" "$$APP/Contents/Resources"; \
	cp ".build/${CONFIG}/Papertalk" "$$APP/Contents/MacOS/Papertalk"; \
	cp Sources/Papertalk/Info.plist "$$APP/Contents/Info.plist"; \
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$$APP/Contents/Info.plist"; \
	plutil -replace CFBundleVersion -string "$(BUILD_NUMBER)" "$$APP/Contents/Info.plist"; \
	if [ -f ../shared/icon.icns ]; then \
		cp ../shared/icon.icns "$$APP/Contents/Resources/Papertalk.icns"; \
		plutil -replace CFBundleIconFile -string Papertalk "$$APP/Contents/Info.plist"; \
	fi; \
	codesign --force --sign - "$$APP" >/dev/null 2>&1 || true; \
	echo "Built $$APP (version $(VERSION), build $(BUILD_NUMBER))"

# Build and launch the app. A copy that's already running is quit first:
# `open` would otherwise just bring the old build to the front.
run: app
	@if pgrep -x Papertalk >/dev/null; then \
		echo "Quitting the running Papertalk…"; \
		osascript -e 'tell application id "dev.papertalk.desktop" to quit' >/dev/null 2>&1 || true; \
		for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Papertalk >/dev/null || break; sleep 0.5; done; \
	fi
	open dist/Papertalk.app

# Build a release-optimized .app bundle and zip it into dist/Papertalk-<version>.zip
release: app
	rm -f dist/Papertalk-*.zip
	ditto -c -k --keepParent dist/Papertalk.app $(RELEASE_ZIP)
	@echo "Bundled $(RELEASE_ZIP)"

# Run the PapertalkTests mock test suite (no network, no keychain).
# The suite is XCTest only; skip Swift Testing's empty second run.
test:
	swift test --disable-swift-testing

# Tests with code coverage → ../coverage/ (report.txt, lcov.info, summary.md, badge.svg)
coverage:
	../scripts/coverage.sh

clean:
	swift package clean
	rm -rf dist

# --- Versioning (see ../scripts/version.sh) ---
version:
	@echo $(VERSION)

bump-patch bump-minor bump-major:
	@../scripts/version.sh bump $(subst bump-,,$@)

# Tag the current commit as v<VERSION>. Pushing the tag runs the release workflow.
tag:
	@git diff --quiet && git diff --cached --quiet || { echo "Commit or stash your changes first."; exit 1; }
	@git rev-parse "v$(VERSION)" >/dev/null 2>&1 && { echo "Tag v$(VERSION) already exists: bump the version first."; exit 1; } || true
	git tag -a "v$(VERSION)" -m "Papertalk $(VERSION)"
	@echo "Created v$(VERSION). Publish it with: git push origin v$(VERSION)"