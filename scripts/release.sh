#!/bin/bash
# Cut a WinterShot release: build, package as .dmg + .zip, publish on GitHub.
#
# Usage: scripts/release.sh 0.2.0
# Prereqs: xcodegen, xcodebuild, gh (authenticated). Run from the repo root.
# Remember to bump CFBundleShortVersionString in project.yml to match first.

set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version, e.g. 0.2.0>}"
TAG="v${VERSION}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

PLIST_VERSION=$(grep 'CFBundleShortVersionString' project.yml | sed 's/.*"\(.*\)"/\1/')
if [ "$PLIST_VERSION" != "$VERSION" ]; then
  echo "error: project.yml CFBundleShortVersionString is $PLIST_VERSION, expected $VERSION" >&2
  exit 1
fi

echo "==> Building Release"
xcodegen generate
xcodebuild -project WinterShot.xcodeproj -scheme WinterShot -configuration Release build | tail -1

APP=$(ls -d "$HOME/Library/Developer/Xcode/DerivedData"/WinterShot-*/Build/Products/Release/WinterShot.app | head -1)
echo "==> Packaging $APP"

# .dmg with an Applications shortcut
mkdir "$STAGE/dmg"
cp -R "$APP" "$STAGE/dmg/"
ln -s /Applications "$STAGE/dmg/Applications"
hdiutil create -volname "WinterShot" -srcfolder "$STAGE/dmg" -ov -format UDZO \
  "$STAGE/WinterShot-${TAG}.dmg"

# .zip fallback
ditto -c -k --keepParent "$APP" "$STAGE/WinterShot-${TAG}.zip"

echo "==> Publishing $TAG"
gh release create "$TAG" \
  "$STAGE/WinterShot-${TAG}.dmg" \
  "$STAGE/WinterShot-${TAG}.zip" \
  --title "WinterShot ${TAG}" \
  --generate-notes

echo "==> Done: $(gh release view "$TAG" --json url -q .url)"
