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
xcodebuild -project HermesApps.xcodeproj -scheme HermesMac -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/dd \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" build

APP="build/dd/Build/Products/Release/Hermey.app"
test -d "$APP" || { echo "no app at $APP"; exit 1; }
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
xcodebuild -project HermesApps.xcodeproj -scheme HermesMobile -configuration Release \
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

cd dist
rm -f "Hermey-$VERSION-b$BUILD.ipa"
zip -qry "Hermey-$VERSION-b$BUILD.ipa" ../Payload
cd ..

echo
echo "artifacts:"
ls -la "dist/Hermey-macOS-$VERSION.dmg" "dist/Hermey-$VERSION-b$BUILD.ipa"
echo
echo "publish with:"
echo "  publish_hermey_from_local.sh dist/Hermey-$VERSION-b$BUILD.ipa dist/Hermey-macOS-$VERSION.dmg"
