#!/bin/sh
# Developer ID build of Stages, optionally notarized and published as a GitHub release that the
# installed copies pick up through Sparkle.
#
#   tools/release.sh build   VERSION   sign only               → build/release/Stages.app
#   tools/release.sh release VERSION   + notarize, zip, appcast → build/release/{Stages.zip,appcast.xml}
#   tools/release.sh publish VERSION   + tag vVERSION and upload both to a GitHub release
#
# Needs: the "Developer ID Application" certificate in the keychain; for release/publish a
# notarytool profile (`xcrun notarytool store-credentials stages-notary …`) and the Sparkle
# EdDSA key in the keychain (`generate_keys --account stages`, made once; back it up with -x).
# CFBundleVersion is the commit count, so it only goes up; Sparkle compares it.
#
# Error reports: the Sentry DSN comes from App/project.yml (SENTRY_DSN), or from the
# environment to override it. release/publish refuse to ship without one (NO_SENTRY=1 to
# allow). With sentry-cli installed and authenticated (SENTRY_AUTH_TOKEN, an org token from
# creative-oak.sentry.io → Settings → Auth Tokens), dSYMs are uploaded so crashes symbolicate;
# either way they're zipped next to the app and attached to the GitHub release.
# Releases are never marked "pre-release" on GitHub: the feed is releases/latest, which skips them.
set -eu

MODE=${1:?usage: release.sh build|release|publish VERSION}
VERSION=${2:?usage: release.sh build|release|publish VERSION}
TEAM_ID=${TEAM_ID:-493257NQK3}
NOTARY_PROFILE=${NOTARY_PROFILE:-stages-notary}
SPARKLE_ACCOUNT=stages
REPO=Creative-Oak/stages
SENTRY_ORG=${SENTRY_ORG:-creative-oak}
SENTRY_PROJECT=${SENTRY_PROJECT:-stages}
BUNDLE_ID=dk.creativeoak.stages

cd "$(dirname "$0")/.."
OUT=build/release
DERIVED=build/DerivedData
APP=$OUT/Stages.app
BUILD=$(git rev-list --count HEAD)
IDENTITY="Developer ID Application: Creative Oak ApS ($TEAM_ID)"

if [ "$MODE" = publish ]; then
  git diff --quiet HEAD || { echo "Commit first: the release is tagged at HEAD."; exit 1; }
  ! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || { echo "Tag v$VERSION exists."; exit 1; }
fi

(cd App && xcodegen generate --quiet)
rm -rf "$OUT" && mkdir -p "$OUT"
xcodebuild -project App/Stages.xcodeproj -scheme Stages -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
  -archivePath "$OUT/Stages.xcarchive" \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  ${SENTRY_DSN:+SENTRY_DSN="$SENTRY_DSN"} -quiet archive
ditto "$OUT/Stages.xcarchive/Products/Applications/Stages.app" "$APP"

DSN=$(/usr/libexec/PlistBuddy -c "Print :SentryDSN" "$APP/Contents/Info.plist" 2>/dev/null || true)
case "$DSN" in
  https://*) echo "Error reports: DSN built in (opt-in for users)." ;;
  *)
    echo "Warning: no Sentry DSN built in; Settings won't offer error reports."
    if [ "$MODE" != build ] && [ "${NO_SENTRY:-0}" != 1 ]; then
      echo "Set SENTRY_DSN in App/project.yml (or the environment), or NO_SENTRY=1 to ship without."
      exit 1
    fi ;;
esac

# Re-sign Sparkle's helpers inside-out with the hardened runtime (Sparkle's documented recipe),
# then the app. Notarization rejects anything nested that isn't.
sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }
SP=$APP/Contents/Frameworks/Sparkle.framework/Versions/B
sign "$SP/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SP/XPCServices/Downloader.xpc"
sign "$SP/Autoupdate"
sign "$SP/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"
echo "Built Stages $VERSION ($BUILD): $APP"
[ "$MODE" = build ] && exit 0

ditto -c -k --keepParent "$APP" "$OUT/Stages-notarize.zip"
xcrun notarytool submit "$OUT/Stages-notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"
rm "$OUT/Stages-notarize.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Stages.zip"

# appcast.xml: one item, the release itself. The feed URL is releases/latest/download/appcast.xml.
SIG=$("$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" --account "$SPARKLE_ACCOUNT" "$OUT/Stages.zip")
cat > "$OUT/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Stages</title>
    <item>
      <title>Stages $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <link>https://github.com/$REPO/releases/tag/v$VERSION</link>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/Stages.zip" type="application/octet-stream" $SIG/>
    </item>
  </channel>
</rss>
EOF
echo "Notarized: $OUT/Stages.zip, $OUT/appcast.xml"

# dSYMs: zipped beside the app (and kept in build/dsyms, which the next release doesn't wipe),
# and uploaded to Sentry when sentry-cli can.
DSYMS=$OUT/Stages.xcarchive/dSYMs
DSYM_ZIP=Stages-$VERSION-dSYMs.zip
ditto -c -k --keepParent "$DSYMS" "$OUT/$DSYM_ZIP"
mkdir -p build/dsyms && cp "$OUT/$DSYM_ZIP" build/dsyms/
SENTRY_RELEASE="$BUNDLE_ID@$VERSION+$BUILD"   # the SDK's default release name
if command -v sentry-cli >/dev/null 2>&1 && sentry-cli info >/dev/null 2>&1; then
  sentry-cli debug-files upload --org "$SENTRY_ORG" --project "$SENTRY_PROJECT" "$DSYMS"
  sentry-cli releases new --org "$SENTRY_ORG" --project "$SENTRY_PROJECT" "$SENTRY_RELEASE"
  sentry-cli releases set-commits --org "$SENTRY_ORG" --auto "$SENTRY_RELEASE" ||
    echo "Warning: couldn't link commits (connect the GitHub repo in Sentry); the release still works."
  sentry-cli releases finalize --org "$SENTRY_ORG" "$SENTRY_RELEASE"
else
  echo "Warning: sentry-cli missing or not authenticated: dSYMs not uploaded. Later:"
  echo "  sentry-cli debug-files upload --org $SENTRY_ORG --project $SENTRY_PROJECT build/dsyms/$DSYM_ZIP"
fi
[ "$MODE" = release ] && exit 0

git tag "v$VERSION"
git push origin "v$VERSION"
gh release create "v$VERSION" "$OUT/Stages.zip" "$OUT/appcast.xml" "$OUT/$DSYM_ZIP" --repo "$REPO" \
  --title "Stages $VERSION" --generate-notes
echo "Published v$VERSION. Installed copies update within 6 hours (or Settings → Check Now)."
