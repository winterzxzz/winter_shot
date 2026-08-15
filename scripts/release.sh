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

# Styled .dmg with an Applications shortcut: rendered background, volume
# icon, and a Finder icon layout written into the volume's .DS_Store. The
# osascript step prompts once per machine for Automation permission over
# Finder.
VOLUME_NAME="WinterShot"
DMG_PATH="$STAGE/WinterShot-${TAG}.dmg"
RW_DMG="$STAGE/WinterShot-rw.dmg"

mkdir "$STAGE/dmg"
cp -R "$APP" "$STAGE/dmg/"
ln -s /Applications "$STAGE/dmg/Applications"
mkdir "$STAGE/dmg/.background"
swift scripts/render-dmg-background.swift "$STAGE/dmg/.background/background.png"
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/dmg/.VolumeIcon.icns"
# Pre-seed .fseventsd with no_log so fseventsd writes no event store into the
# mounted image — without this an .fseventsd folder ships inside the DMG and
# shows up for anyone browsing with hidden files visible.
mkdir "$STAGE/dmg/.fseventsd"
touch "$STAGE/dmg/.fseventsd/no_log"

hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGE/dmg" -ov -format UDRW \
  "$RW_DMG"

# A stale mounted volume makes the fresh image mount as "WinterShot 1" and
# the Finder styling hits the wrong disk — eject leftovers first, then take
# the mount point hdiutil actually reports.
MOUNT_POINT="/Volumes/$VOLUME_NAME"
if [ -d "$MOUNT_POINT" ]; then
  hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
fi
MOUNT_POINT="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen \
  | awk -F'\t' '/\/Volumes\//{print $NF; exit}')"
if [ "$MOUNT_POINT" != "/Volumes/$VOLUME_NAME" ]; then
  echo "error: image mounted at '$MOUNT_POINT' instead of /Volumes/$VOLUME_NAME" >&2
  hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  exit 1
fi
SetFile -a C "$MOUNT_POINT" 2>/dev/null || true

osascript <<OSA
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set pathbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 548}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 100
    set text size of viewOptions to 12
    set background picture of viewOptions to file ".background:background.png"
    set position of item "WinterShot.app" of container window to {165, 192}
    set position of item "Applications" of container window to {495, 192}
    -- Park the helper entries far below the window so they stay out of
    -- sight even when the user browses with hidden files visible. Finder
    -- only lists them when hidden files are shown, hence the try blocks.
    try
      set position of item ".background" of container window to {165, 700}
    end try
    try
      set position of item ".fseventsd" of container window to {330, 700}
    end try
    try
      set position of item ".VolumeIcon.icns" of container window to {495, 700}
    end try
    update without registering applications
    delay 1
    -- Re-assert the bounds after the update so the final size is what
    -- Finder writes into .DS_Store on close.
    set the bounds of container window to {200, 120, 860, 548}
    delay 1
    close
  end tell
end tell
OSA

sync
# Mark the helper entries Finder-invisible on the volume itself, and drop
# any Finder/Spotlight droppings picked up while the image was mounted.
chflags hidden \
  "$MOUNT_POINT/.background" \
  "$MOUNT_POINT/.fseventsd" \
  "$MOUNT_POINT/.VolumeIcon.icns" 2>/dev/null || true
rm -rf "$MOUNT_POINT/.Trashes" "$MOUNT_POINT/.TemporaryItems" 2>/dev/null || true
hdiutil detach "$MOUNT_POINT" >/dev/null
hdiutil convert "$RW_DMG" -format UDZO -o "$DMG_PATH" >/dev/null
rm -f "$RW_DMG"

# .zip fallback
ditto -c -k --keepParent "$APP" "$STAGE/WinterShot-${TAG}.zip"

echo "==> Publishing $TAG"
gh release create "$TAG" \
  "$STAGE/WinterShot-${TAG}.dmg" \
  "$STAGE/WinterShot-${TAG}.zip" \
  --title "WinterShot ${TAG}" \
  --generate-notes

echo "==> Done: $(gh release view "$TAG" --json url -q .url)"
