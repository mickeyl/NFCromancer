prefix ?= $(HOME)/.local
INSTALL_DIR = $(prefix)/bin
NOTARY_PROFILE ?=

# Mock app (the single provider: mock + ACR122U passthrough)
MOCK_CODESIGN_MATCH ?= Developer ID Application
MOCK_SIGN_IDENTITY := $(shell security find-identity -v -p codesigning | awk -F'"' '/$(MOCK_CODESIGN_MATCH)/ {print $$2; exit}')
MOCK_CODESIGN_FLAGS ?= --options runtime --timestamp
MOCK_SRCS = $(shell find Sources/NFCromancer-Mock \( -name '*.swift' -o -name '*.m' -o -name '*.h' \) -not -path '*/.build/*' 2>/dev/null)
MOCK_PLIST = Sources/NFCromancer-Mock/Resources/Info.plist
MOCK_ENTITLEMENTS = Sources/NFCromancer-Mock/Resources/entitlements.plist
MOCK_ICON = Sources/NFCromancer-Mock/Resources/NFCromancer.icns
MOCK_BUNDLE = NFCromancer-Mock.app
MOCK_BIN = $(MOCK_BUNDLE)/Contents/MacOS/NFCromancer-Mock
MOCK_BIN_NAME = NFCromancer-Mock
INSTALLED_MOCK_APP = $(INSTALL_DIR)/$(MOCK_BUNDLE)
MOCK_DIST_ZIP = NFCromancer-Mock.zip

# Monotonic build number derived from commit count; falls back to the
# value already in the source Info.plist when the tree is not a git
# checkout (e.g. Homebrew unpacks a tarball).
BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null)

.DEFAULT_GOAL := help

.PHONY: help install uninstall clean \
        mock mock-debug mock-dev mock-relaunch mock-install mock-run mock-stop mock-status mock-log mock-assess mock-notarize mock-clean

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "Mock app (virtual NFC tags + ACR122U passthrough):"
	@echo "  mock        Build the mock menubar app (release)"
	@echo "  mock-debug  Build with debug symbols"
	@echo "  mock-dev    Stop, debug-build, and run in foreground"
	@echo "  mock-relaunch  Quick debug rebuild and background relaunch"
	@echo "  mock-run    Install and start the mock app"
	@echo "  mock-stop   Stop the running mock app"
	@echo "  mock-status Show whether the mock app is running"
	@echo "  mock-log    Tail system log output from the mock app"
	@echo "  mock-assess Verify signing and Gatekeeper assessment"
	@echo "  mock-notarize Notarize the mock app (requires NOTARY_PROFILE)"
	@echo "  mock-clean  Remove mock build artifacts"
	@echo ""
	@echo "General:"
	@echo "  install     Build and install the mock app to \$$(prefix)/bin  [$(prefix)]"
	@echo "  uninstall   Remove installed files from \$$(prefix)/bin"
	@echo "  clean       Remove all build artifacts"
	@echo ""
	@echo "Variables:"
	@echo "  MOCK_CODESIGN_MATCH  Signing identity  [$(MOCK_CODESIGN_MATCH)]"
	@echo "  NOTARY_PROFILE  notarytool profile    [$(NOTARY_PROFILE)]"

install: mock-install

mock-install: mock
	mkdir -p $(INSTALL_DIR)
	rm -rf $(INSTALLED_MOCK_APP)
	cp -R $(MOCK_BUNDLE) $(INSTALL_DIR)/
	@xattr -cr $(INSTALLED_MOCK_APP) 2>/dev/null || true

uninstall:
	rm -rf $(INSTALLED_MOCK_APP)
	@echo "Uninstalled from $(INSTALL_DIR)"

# ---- Mock App ----

SWIFTPM_FLAGS ?= --disable-sandbox

mock: $(MOCK_BIN)

mock-debug:
	@mkdir -p $(MOCK_BUNDLE)/Contents/MacOS $(MOCK_BUNDLE)/Contents/Resources
	@cp $(MOCK_PLIST) $(MOCK_BUNDLE)/Contents/Info.plist
	@if [ -n "$(BUILD_NUMBER)" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" $(MOCK_BUNDLE)/Contents/Info.plist; fi
	@cd Sources/NFCromancer-Mock && swift build $(SWIFTPM_FLAGS) 2>&1 | tail -3
	@cp $$(cd Sources/NFCromancer-Mock && swift build $(SWIFTPM_FLAGS) --show-bin-path)/$(MOCK_BIN_NAME) $(MOCK_BIN)
	@cp $(MOCK_ICON) $(MOCK_BUNDLE)/Contents/Resources/NFCromancer.icns
	@codesign --force --sign - --entitlements $(MOCK_ENTITLEMENTS) $(MOCK_BUNDLE) >/dev/null
	@xattr -cr $(MOCK_BUNDLE) 2>/dev/null || true

mock-relaunch: mock-debug
	@pkill -f "$(MOCK_BIN_NAME).app/Contents/MacOS" 2>/dev/null && sleep 0.5 || true
	@open "$(MOCK_BUNDLE)"
	@echo "Mock app relaunched (debug build)"

mock-dev: mock-debug
	@pkill -f "$(MOCK_BIN_NAME).app/Contents/MacOS" 2>/dev/null && sleep 0.5 || true
	@echo "Starting in foreground… (^C to stop)"
	$(MOCK_BIN)

$(MOCK_BIN): $(MOCK_SRCS) $(MOCK_PLIST) $(MOCK_ENTITLEMENTS) $(MOCK_ICON)
	mkdir -p $(MOCK_BUNDLE)/Contents/MacOS $(MOCK_BUNDLE)/Contents/Resources
	cp $(MOCK_PLIST) $(MOCK_BUNDLE)/Contents/Info.plist
	@if [ -n "$(BUILD_NUMBER)" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" $(MOCK_BUNDLE)/Contents/Info.plist; fi
	cd Sources/NFCromancer-Mock && swift build $(SWIFTPM_FLAGS) -c release
	cp $$(cd Sources/NFCromancer-Mock && swift build $(SWIFTPM_FLAGS) -c release --show-bin-path)/$(MOCK_BIN_NAME) $(MOCK_BIN)
	cp $(MOCK_ICON) $(MOCK_BUNDLE)/Contents/Resources/NFCromancer.icns
	@if [ -z "$(MOCK_SIGN_IDENTITY)" ]; then \
		echo "WARNING: No codesigning identity matching '$(MOCK_CODESIGN_MATCH)' found in your keychain."; \
		echo "Signing the mock app ad hoc. Gatekeeper will reject quarantined or distributed copies."; \
		codesign --force --sign - --entitlements $(MOCK_ENTITLEMENTS) $(MOCK_BUNDLE); \
	else \
		echo "Codesigning mock app with: $(MOCK_SIGN_IDENTITY)"; \
		codesign --force --sign "$(MOCK_SIGN_IDENTITY)" $(MOCK_CODESIGN_FLAGS) --entitlements $(MOCK_ENTITLEMENTS) $(MOCK_BUNDLE); \
	fi
	@xattr -cr $(MOCK_BUNDLE) 2>/dev/null || true

mock-run: mock-install
	@if ! pgrep -f $(MOCK_BIN_NAME) > /dev/null 2>&1; then \
		open "$(INSTALLED_MOCK_APP)"; \
		echo "NFCromancer-Mock started"; \
	else \
		echo "NFCromancer-Mock already running"; \
	fi

mock-stop:
	@pid=$$(pgrep -f "$(MOCK_BIN_NAME).app/Contents/MacOS" 2>/dev/null); \
	if [ -n "$$pid" ]; then \
		kill "$$pid"; \
		echo "NFCromancer-Mock stopped (was PID $$pid)"; \
	else \
		echo "NFCromancer-Mock is not running"; \
	fi

mock-status:
	@pid=$$(pgrep -f "$(MOCK_BIN_NAME).app/Contents/MacOS" 2>/dev/null); \
	if [ -n "$$pid" ]; then \
		echo "NFCromancer-Mock is running (PID $$pid)"; \
	else \
		echo "NFCromancer-Mock is not running"; \
	fi

mock-log:
	@echo "Tailing logs for NFCromancer-Mock… (^C to stop)"
	@log stream --predicate 'process == "$(MOCK_BIN_NAME)"' --style compact

mock-assess: mock
	codesign --verify --deep --strict --verbose=4 $(MOCK_BUNDLE)
	spctl -a -vvv -t exec $(MOCK_BUNDLE)

mock-notarize:
	@if [ -z "$(NOTARY_PROFILE)" ]; then \
		echo "ERROR: Set NOTARY_PROFILE to a notarytool keychain profile."; \
		exit 1; \
	fi
	$(MAKE) mock-clean
	$(MAKE) mock
	rm -f $(MOCK_DIST_ZIP)
	ditto -c -k --keepParent --sequesterRsrc --zlibCompressionLevel 9 $(MOCK_BUNDLE) $(MOCK_DIST_ZIP)
	xcrun notarytool submit $(MOCK_DIST_ZIP) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(MOCK_BUNDLE)
	$(MAKE) mock-assess

mock-clean:
	rm -rf $(MOCK_BUNDLE) $(MOCK_DIST_ZIP)

# ---- General ----

clean: mock-clean
