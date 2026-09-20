.PHONY: gen build run test kit-test uiux-test ssh-test mobile-build \
	mobile-device mobile-install mobile-share clean

# HerdrMobile / HerdrSSH are arm64-only (libssh2 + OpenSSL xcframeworks).
# Keep code signing on so Simulator Keychain (device SSH key) works; unsigned
# builds log errSecMissingEntitlement (-34018) on every launch.
MOBILE_BUILD = xcodebuild -project HerdrM.xcodeproj -scheme HerdrMobile \
	-configuration Debug \
	-destination 'platform=iOS Simulator,name=iPhone 17,arch=arm64' \
	-derivedDataPath build-ios build \
	-skipPackagePluginValidation \
	ARCHS=arm64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=x86_64

MOBILE_DEVICE_DERIVED = build-ios-device
MOBILE_DEVICE_APP = $(MOBILE_DEVICE_DERIVED)/Build/Products/Debug-iphoneos/HerdrMobile.app
MOBILE_DEVICE_BUILD = xcodebuild -project HerdrM.xcodeproj -scheme HerdrMobile \
	-configuration Debug \
	-destination 'generic/platform=iOS' \
	-derivedDataPath $(MOBILE_DEVICE_DERIVED) build \
	-skipPackagePluginValidation \
	ARCHS=arm64 ONLY_ACTIVE_ARCH=YES

INSTALLER ?= remote-installer
INSTALLER_EXPIRE ?= 1h
INSTALLER_MAX_DOWNLOADS ?= 5
INSTALLER_PROVIDER ?= cloudflare

SSH_TEST = cd Packages/HerdrSSH && xcodebuild test \
	-scheme HerdrSSH \
	-destination 'platform=iOS Simulator,name=iPhone 17,arch=arm64' \
	-derivedDataPath ../../build/HerdrSSHDerivedData \
	-collect-test-diagnostics never \
	-parallel-testing-enabled NO

CODE_SIGN_IDENTITY ?= -

gen:
	xcodegen generate

build: gen
	xcodebuild -project HerdrM.xcodeproj -scheme HerdrM -configuration Debug -derivedDataPath build build CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" CODE_SIGN_STYLE=Manual -skipPackagePluginValidation | tail -5

# `open` only activates an already-running app, so a rebuilt binary would never
# be exercised. Quit the previous Debug instance first (the /Applications copy is untouched).
run: build
	pkill -f 'build/Build/Products/Debug/herdrm.app/Contents/MacOS/herdrm' || true
	sleep 1
	open build/Build/Products/Debug/herdrm.app

# HerdrM UI/UX tests (HerdrMTests, hosted in the app): sidebar behavior through the real SidebarView.
UIUX_TEST = xcodebuild test \
	-project HerdrM.xcodeproj \
	-scheme HerdrM \
	-configuration Debug \
	-derivedDataPath build \
	-destination 'platform=macOS,arch=arm64' \
	CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
	-skipPackagePluginValidation

uiux-test: gen
	$(UIUX_TEST)

kit-test:
	cd Packages/HerdrKit && swift test

# HerdrSSH Swift Testing on iOS Simulator (Session-driver e2e skips without a live sshd fixture).
ssh-test:
	$(SSH_TEST)

# Compile gate for HerdrMobile + HerdrSSH.
mobile-build: gen
	$(MOBILE_BUILD)

# Signed iphoneos .app for a real phone (Automatic signing / team in project.yml).
mobile-device: gen
	$(MOBILE_DEVICE_BUILD)

# Share an already-built device .app. Foreground: Ctrl-C closes the tunnel.
mobile-share:
	@test -d "$(MOBILE_DEVICE_APP)" || { \
		echo "missing $(MOBILE_DEVICE_APP) — run make mobile-device first"; \
		exit 1; \
	}
	$(INSTALLER) share "$(MOBILE_DEVICE_APP)" \
		--expire-after $(INSTALLER_EXPIRE) \
		--max-downloads $(INSTALLER_MAX_DOWNLOADS) \
		--provider $(INSTALLER_PROVIDER)

# Rebuild the device app, then OTA-share it (Safari install page + QR).
mobile-install: mobile-device
	$(INSTALLER) share "$(MOBILE_DEVICE_APP)" \
		--expire-after $(INSTALLER_EXPIRE) \
		--max-downloads $(INSTALLER_MAX_DOWNLOADS) \
		--provider $(INSTALLER_PROVIDER)

test: kit-test

clean:
	rm -rf build build-ios build-ios-device build/HerdrSSHDerivedData HerdrM.xcodeproj \
		Packages/HerdrKit/.build Packages/HerdrSSH/.build
