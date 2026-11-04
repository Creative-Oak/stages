# Always the Xcode toolchain (xcodebuild / xcrun), never a bare `swift` from PATH.
# The app's Xcode project is generated from App/project.yml into App/Stages.xcodeproj; the repo
# root holds only Package.swift, so `xcodebuild` there sees the package (and its tests).
DERIVED := build/DerivedData
APP := $(DERIVED)/Build/Products/Debug/Stages.app
# Local self-signed identity (README → Signing). Keeps TCC grants stable across rebuilds.
IDENTITY := Stages Local Signing

.PHONY: project app run install release test clean icon
INSTALLED := $(HOME)/Applications/Stages.app

project:
	cd App && xcodegen generate --quiet

app: project
	xcodebuild -project App/Stages.xcodeproj -scheme Stages -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath $(DERIVED) -quiet build
	@# If Xcode fell back to ad-hoc, re-sign so the designated requirement stays certificate-based.
	@codesign -d -r- $(APP) 2>&1 | grep -q "certificate root" || \
	  codesign --force --deep --timestamp=none --sign "$(IDENTITY)" $(APP)
	@codesign -d -r- $(APP) 2>&1 | grep "designated"

run: app
	-pkill -x Stages; while pgrep -x Stages >/dev/null; do sleep 0.1; done; sleep 0.5
	open $(APP)

# Copy the app to ~/Applications (no admin needed) and run it from there. Grants follow the
# signing certificate, not the path, so they carry over. "Open at login" points here.
install: app
	-pkill -x Stages; while pgrep -x Stages >/dev/null; do sleep 0.1; done; sleep 0.5
	mkdir -p $(HOME)/Applications
	rm -rf $(INSTALLED)
	ditto $(APP) $(INSTALLED)
	open $(INSTALLED)

# Distribution build: Developer ID signing, hardened runtime, notarization, stapling.
# Needs a "Developer ID Application" certificate in the keychain and a notarytool profile:
#   xcrun notarytool store-credentials stages-notary --apple-id <you> --team-id <TEAM> --password <app-specific>
# Usage: make release TEAM_ID=ABCDE12345
TEAM_ID ?=
NOTARY_PROFILE ?= stages-notary
RELEASE_DIR := build/release
release: project
	@test -n "$(TEAM_ID)" || { echo "Set TEAM_ID (your Apple Developer team ID): make release TEAM_ID=…"; exit 1; }
	@security find-identity -v -p codesigning | grep -q "Developer ID Application" || \
	  { echo "No 'Developer ID Application' certificate in the keychain (Xcode → Settings → Accounts → Manage Certificates)."; exit 1; }
	rm -rf $(RELEASE_DIR) && mkdir -p $(RELEASE_DIR)
	xcodebuild -project App/Stages.xcodeproj -scheme Stages -configuration Release -destination 'generic/platform=macOS' \
	  -archivePath $(RELEASE_DIR)/Stages.xcarchive DEVELOPMENT_TEAM=$(TEAM_ID) CODE_SIGN_STYLE=Manual -quiet archive
	ditto $(RELEASE_DIR)/Stages.xcarchive/Products/Applications/Stages.app $(RELEASE_DIR)/Stages.app
	codesign --verify --deep --strict --verbose=2 $(RELEASE_DIR)/Stages.app
	ditto -c -k --keepParent $(RELEASE_DIR)/Stages.app $(RELEASE_DIR)/Stages-notarize.zip
	xcrun notarytool submit $(RELEASE_DIR)/Stages-notarize.zip --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(RELEASE_DIR)/Stages.app
	spctl --assess --type execute --verbose $(RELEASE_DIR)/Stages.app
	ditto -c -k --keepParent $(RELEASE_DIR)/Stages.app $(RELEASE_DIR)/Stages.zip
	@echo "Notarized: $(RELEASE_DIR)/Stages.zip"

# Regenerate the app icon (App/Stages/Assets.xcassets) from tools/make-app-icon.swift.
icon:
	xcrun swift tools/make-app-icon.swift

test:
	xcodebuild test -scheme Stages-Package -destination 'platform=macOS,arch=arm64' -quiet

clean:
	rm -rf build App/Stages.xcodeproj
