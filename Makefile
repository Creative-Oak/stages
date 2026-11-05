# Always the Xcode toolchain (xcodebuild / xcrun), never a bare `swift` from PATH.
# The app's Xcode project is generated from App/project.yml into App/Stages.xcodeproj; the repo
# root holds only Package.swift, so `xcodebuild` there sees the package (and its tests).
DERIVED := build/DerivedData
APP := $(DERIVED)/Build/Products/Debug/Stages.app
# Local self-signed identity (README → Signing). Keeps TCC grants stable across rebuilds.
IDENTITY := Stages Local Signing

.PHONY: project app run install release publish test clean icon
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

# Developer ID build (tools/release.sh build), copied to ~/Applications (no admin needed) and run
# from there. Same certificate as the published releases, so the grants carry over to updates.
# "Open at login" points here.
install:
	tools/release.sh build $(or $(VERSION),dev-$(shell git rev-parse --short HEAD))
	-pkill -x Stages; while pgrep -x Stages >/dev/null; do sleep 0.1; done; sleep 0.5
	mkdir -p $(HOME)/Applications
	rm -rf $(INSTALLED)
	ditto build/release/Stages.app $(INSTALLED)
	open $(INSTALLED)

# Notarized zip + Sparkle appcast in build/release (tools/release.sh). Usage: make release VERSION=0.2.0
release:
	@test -n "$(VERSION)" || { echo "Set VERSION: make release VERSION=0.2.0"; exit 1; }
	tools/release.sh release $(VERSION)

# The same, then tag vVERSION and publish a GitHub release: installed copies update themselves.
publish:
	@test -n "$(VERSION)" || { echo "Set VERSION: make publish VERSION=0.2.0"; exit 1; }
	tools/release.sh publish $(VERSION)

# Regenerate the app icon (App/Stages/Assets.xcassets) from tools/make-app-icon.swift.
icon:
	xcrun swift tools/make-app-icon.swift

test:
	xcodebuild test -scheme Stages-Package -destination 'platform=macOS,arch=arm64' -quiet

clean:
	rm -rf build App/Stages.xcodeproj
