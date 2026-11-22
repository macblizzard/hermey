#!/usr/bin/env bash
# Build both unsigned artifacts on a Mac, exactly as the `apps` CI job does.
#
#   Tools/release/build_on_mac.sh 0.1.497 497
#
# Why this exists: GitHub's hosted macOS runners are the scarce resource — a job can sit in the queue
# and be cancelled without ever starting, which stops a release dead even when the code is fine. A Mac
# we control builds the same tree with the same commands, and `publish_github.sh` already accepts
# artifact paths, so the release path does not change.
#
# Requires: Xcode with the macOS 26 SDK (`glassEffect`), and xcodegen (installed here if missing).
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION="${1:?usage: build_on_mac.sh <version> <build>   e.g. 0.1.497 497}"
BUILD="${2:?usage: build_on_mac.sh <version> <build>}"

command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate

echo "== macOS app =="
# Universal, explicitly. With nothing pinning the architecture, a build on Apple silicon resolved to
# the active arch alone and shipped 0.1.575 as arm64-only (half the size, and an Intel Mac cannot run
# it), while earlier builds happened to come out fat. `ARCHS_STANDARD` is Xcode's default but is not
# reliable when a concrete `-destination` is given, so both settings are stated.
xcodebuild -skipPackagePluginValidation -project HermesApps.xcodeproj -scheme HermesMac -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/dd \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" build

APP="build/dd/Build/Products/Release/Hermey.app"
test -d "$APP" || { echo "no app at $APP"; exit 1; }
# A thin binary is a broken artifact, not a smaller download: say so here rather than in a bug report.
ARCHS_FOUND=$(lipo -archs "$APP/Contents/MacOS/Hermey")
case "$ARCHS_FOUND" in
  *arm64*x86_64*|*x86_64*arm64*) : ;;
  *) echo "refusing to package: $APP is $ARCHS_FOUND, expected arm64 and x86_64"; exit 1 ;;
esac
# Ad-hoc signature: an unsigned arm64 binary does not just look untrusted, the kernel refuses to
# execute it and macOS calls the app damaged — which `xattr` cannot repair.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

mkdir -p dist dist/dmg-root
rm -rf dist/dmg-root/*
cp -R "$APP" dist/dmg-root/Hermey.app
ln -s /Applications dist/dmg-root/Applications
hdiutil create -volname "Hermey" -srcfolder dist/dmg-root \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "dist/Hermey-macOS-$VERSION.dmg"
rm -rf dist/dmg-root
hdiutil verify "dist/Hermey-macOS-$VERSION.dmg"

echo "== iOS app =="
xcodebuild -skipPackagePluginValidation -project HermesApps.xcodeproj -scheme HermesMobile -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/HermesMobile.xcarchive \
  -derivedDataPath build/ipa-dd \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" PROVISIONING_PROFILE_SPECIFIER="" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" archive

IOS_APP=$(find build/HermesMobile.xcarchive/Products/Applications -maxdepth 1 -name '*.app' | head -n 1)
test -n "$IOS_APP" || { echo "no .app in the archive"; exit 1; }
rm -rf Payload && mkdir -p Payload
cp -R "$IOS_APP" Payload/
codesign --force --deep --sign - "Payload/$(basename "$IOS_APP")" || echo "ad-hoc signing skipped"

# Zip from the repository root, NOT from `dist` with `../Payload`. Zipping a path that climbs out of the
# working directory stores every entry as `../Payload/Hermey.app/…`, so the archive has no
# `Payload/*.app/Info.plist` at its root: `sync_store.py --check` refuses it, and any strict extractor
# would find nothing to install. Sideloaders happened to tolerate the `../`, which is exactly why this
# shipped for ten builds without being noticed (found 2026-11-17 by the CI check on main).
rm -f "dist/Hermey-$VERSION-b$BUILD.ipa"
zip -qry "dist/Hermey-$VERSION-b$BUILD.ipa" Payload

echo
echo "artifacts:"
ls -la "dist/Hermey-macOS-$VERSION.dmg" "dist/Hermey-$VERSION-b$BUILD.ipa"
echo
echo "publish with:"
# publish_github.sh takes a CI *run id* and downloads that run's artifacts; handed local paths
# it treats them as a run id and dies on a 404 (api.github.com/.../runs/dist/Hermey-*.ipa/...).
# Artifacts built here are published with the publisher itself, which takes paths. Printed as one
# line on purpose: a backslash continuation in a hint is the kind of thing that breaks on paste.
echo "  python3 Tools/release/publish_altstore.py --ipa dist/Hermey-$VERSION-b$BUILD.ipa --mac-dmg dist/Hermey-macOS-$VERSION.dmg --repo macblizzard/hermey --downloads-repo macblizzard/hermey-downloads"
echo "  (publish_github.sh is only for runner builds: it takes a run id, not paths)"
