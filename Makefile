APP_NAME     := iMessageWidget
BUILD_DIR    := .build/release
APP_BUNDLE   := $(APP_NAME).app
BUNDLE_BIN   := $(APP_BUNDLE)/Contents/MacOS
BUNDLE_RES   := $(APP_BUNDLE)/Contents/Resources

# Use Xcode's Swift toolchain, not Command Line Tools
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer

.PHONY: build bundle sign run install clean

build:
	swift build -c release 2>&1

bundle: build
	mkdir -p "$(BUNDLE_BIN)"
	mkdir -p "$(BUNDLE_RES)"
	cp "$(BUILD_DIR)/$(APP_NAME)" "$(BUNDLE_BIN)/$(APP_NAME)"
	cp Resources/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"

sign: bundle
	codesign --force --deep --sign - "$(APP_BUNDLE)"

run: sign
	pkill -x "$(APP_NAME)" 2>/dev/null || true
	open "$(APP_BUNDLE)"

install: sign
	rm -rf "/Applications/$(APP_BUNDLE)"
	cp -r "$(APP_BUNDLE)" /Applications/
	open "/Applications/$(APP_BUNDLE)"

clean:
	rm -rf .build "$(APP_BUNDLE)"
