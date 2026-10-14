.PHONY: build app run release clean

CONFIG := debug
ifeq ($(firstword $(MAKECMDGOALS)),release)
CONFIG := release
endif

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
	if [ -f ../shared/icon.icns ]; then \
		cp ../shared/icon.icns "$$APP/Contents/Resources/Papertalk.icns"; \
		plutil -replace CFBundleIconFile -string Papertalk "$$APP/Contents/Info.plist"; \
	fi; \
	codesign --force --sign - "$$APP" >/dev/null 2>&1 || true; \
	echo "Built $$APP"

# Build and launch the app
run: app
	open dist/Papertalk.app

# Build a release-optimized .app bundle and zip it into dist/Papertalk.app.zip
release: app
	ditto -c -k --keepParent dist/Papertalk.app dist/Papertalk.app.zip
	@echo "Bundled dist/Papertalk.app.zip"

clean:
	swift package clean
	rm -rf dist

CONFIG := debug
ifeq ($(firstword $(MAKECMDGOALS)),release)
CONFIG := release
endif