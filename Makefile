# Always the Xcode toolchain (xcodebuild / xcrun), never a bare `swift` from PATH.
# The app's Xcode project is generated from App/project.yml into App/Stages.xcodeproj; the repo
# root holds only Package.swift, so `xcodebuild` there sees the package (and its tests).
DERIVED := build/DerivedData
APP := $(DERIVED)/Build/Products/Debug/Stages.app
# Local self-signed identity (README → Signing). Keeps TCC grants stable across rebuilds.
IDENTITY := Stages Local Signing

.PHONY: project app run install test clean
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

test:
	xcodebuild test -scheme Stages-Package -destination 'platform=macOS,arch=arm64' -quiet

clean:
	rm -rf build App/Stages.xcodeproj
