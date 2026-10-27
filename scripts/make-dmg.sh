#!/bin/bash
# Builds Clipnpaste.app and packs it into dist/Clipnpaste.dmg, the file people download: a disk
# image named Clipnpaste holding the app and a shortcut to Applications to drag it onto.
#   ./scripts/make-dmg.sh                                         build, then pack
#   APP=some/Clipnpaste.app DMG=out.dmg ./scripts/make-dmg.sh     pack an app that is already built
# The build runs at low priority and never installs or touches the copy in ~/Applications.
# Sign with your own certificate through CLIPNPASTE_SIGN_ID, as for build.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${APP:-}" ]; then
  INSTALL=0 nice -n 15 ./scripts/build.sh
  APP=build/Clipnpaste.app
fi
DMG="${DMG:-dist/Clipnpaste.dmg}"
[ -f "$APP/Contents/Info.plist" ] || { echo "No app at $APP" >&2; exit 1; }
codesign --verify --strict "$APP"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/Clipnpaste"
ditto "$APP" "$STAGE/Clipnpaste/Clipnpaste.app"
ln -s /Applications "$STAGE/Clipnpaste/Applications"
# The icon of the mounted disk.
if [ -f "$APP/Contents/Resources/AppIcon.icns" ] && command -v SetFile >/dev/null; then
  cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/Clipnpaste/.VolumeIcon.icns"
  SetFile -a C "$STAGE/Clipnpaste"
fi

mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"
hdiutil create -volname Clipnpaste -srcfolder "$STAGE/Clipnpaste" -fs HFS+ -format UDZO -imagekey zlib-level=9 -quiet "$DMG"
hdiutil verify -quiet "$DMG"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "Made $DMG: Clipnpaste $VERSION, $(du -h "$DMG" | cut -f1 | tr -d ' ')"
