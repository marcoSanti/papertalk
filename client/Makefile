.PHONY: build run app clean

# Compile the executable
build:
	swift build

# Build a runnable .app bundle (dist/Papertalk.app)
app:
	./make-app.sh

# Build and launch the app
run: app
	open dist/Papertalk.app

clean:
	swift package clean
	rm -rf dist