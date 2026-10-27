#!/bin/bash
# Runs the swift-testing suite. With only the Command Line Tools, SwiftPM can't find
# Testing.framework by itself, so point it there.
#   --scratch-path DIR (or CLIPNPASTE_SCRATCH=DIR) uses another build folder.
set -euo pipefail
cd "$(dirname "$0")/.."

ARGS=()
[ -n "${CLIPNPASTE_SCRATCH:-}" ] && ARGS=(--scratch-path "$CLIPNPASTE_SCRATCH")

CLT=/Library/Developer/CommandLineTools/Library/Developer
if [ "$(xcode-select -p)" = "/Library/Developer/CommandLineTools" ] && [ -d "$CLT/Frameworks/Testing.framework" ]; then
  exec taskpolicy -b swift test ${ARGS[@]+"${ARGS[@]}"} \
    -Xswiftc -F -Xswiftc "$CLT/Frameworks" \
    -Xlinker -F -Xlinker "$CLT/Frameworks" \
    -Xlinker -rpath -Xlinker "$CLT/Frameworks" \
    -Xlinker -rpath -Xlinker "$CLT/usr/lib" "$@"
fi
exec taskpolicy -b swift test ${ARGS[@]+"${ARGS[@]}"} "$@"
