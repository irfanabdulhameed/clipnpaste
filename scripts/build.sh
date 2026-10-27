#!/bin/bash
# Builds Clipnpaste.app into build/ and installs it in ~/Applications.
#   ./scripts/build.sh --run              install, then quit any running copy and relaunch
#   INSTALL=0 ./scripts/build.sh          build only, don't install
#   --scratch-path DIR                    use another build folder (or CLIPNPASTE_SCRATCH=DIR)
#   CLIPNPASTE_SIGN_ID="Name"             signing identity (default "Keylog Dev")
set -euo pipefail
cd "$(dirname "$0")/.."

RUN=0
SCRATCH="${CLIPNPASTE_SCRATCH:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN=1 ;;
    --scratch-path) SCRATCH="$2"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
SCRATCH_ARGS=()
[ -n "$SCRATCH" ] && SCRATCH_ARGS=(--scratch-path "$SCRATCH")

CONFIG="${CONFIG:-release}"
taskpolicy -b swift build -c "$CONFIG" --product Clipnpaste ${SCRATCH_ARGS[@]+"${SCRATCH_ARGS[@]}"}
BIN="$(swift build -c "$CONFIG" --show-bin-path ${SCRATCH_ARGS[@]+"${SCRATCH_ARGS[@]}"})/Clipnpaste"

APP="build/Clipnpaste.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Clipnpaste"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# A stable certificate keeps macOS permissions across rebuilds; ad-hoc loses them.
IDENTITY="${CLIPNPASTE_SIGN_ID:-Keylog Dev}"
IDENTITIES="$(security find-identity -p codesigning 2>/dev/null || true)"
if grep -qF "\"$IDENTITY\"" <<<"$IDENTITIES"; then
  SIGN="$IDENTITY"
else
  SIGN="-"
  echo "WARNING: no \"$IDENTITY\" certificate. Signing ad-hoc, so permissions (Accessibility) will be lost after each rebuild."
fi
strip -S -x "$APP/Contents/MacOS/Clipnpaste"
codesign --force --options runtime --timestamp=none --sign "$SIGN" "$APP"
echo "Built $APP (signed: $SIGN)"

if [ "${INSTALL:-1}" = 1 ]; then
  DEST="$HOME/Applications/Clipnpaste.app"
  if pgrep -x Clipnpaste >/dev/null; then
    pkill -x Clipnpaste || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Clipnpaste >/dev/null || break; sleep 0.3; done
  fi
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  touch "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
  echo "Installed $DEST"
  if [ "$RUN" = 1 ]; then
    open "$DEST"
    echo "Launched $DEST"
  fi
fi
