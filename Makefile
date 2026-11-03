# Always the Xcode toolchain (xcodebuild / xcrun), never a bare `swift` from PATH.
# The app's Xcode project is generated from App/project.yml into App/Stages.xcodeproj; the repo
# root holds only Package.swift, so `xcodebuild` there sees the package (and its tests).
DERIVED := build/DerivedData
APP := $(DERIVED)/Build/Products/Debug/Stages.app

.PHONY: project app run test clean

project:
	cd App && xcodegen generate --quiet

app: project
	xcodebuild -project App/Stages.xcodeproj -scheme Stages -configuration Debug -derivedDataPath $(DERIVED) -quiet build

run: app
	-pkill -x Stages && sleep 0.5
	open $(APP)

test:
	xcodebuild test -scheme Stages-Package -destination 'platform=macOS,arch=arm64' -quiet

clean:
	rm -rf build App/Stages.xcodeproj
