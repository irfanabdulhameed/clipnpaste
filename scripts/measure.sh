#!/bin/bash
# Speed numbers against the plan's section 7 targets.
#
# Idle cost of the running app (read-only: it only watches with ps, top and footprint, so it is
# safe on the installed copy while you work):
#   ./scripts/measure.sh                 60 s on the installed copy (or the only copy running)
#   ./scripts/measure.sh -s 300          5 minutes, the plan's idle-CPU window
#   ./scripts/measure.sh -p PID          a given process
#
# Motion (open latency, frame pacing, the rise's shape):
#   ./scripts/measure.sh --motion        runs build/Clipnpaste.app's measure scene (demo data, no
#                                        shortcut, no menu bar icon, never the clipboard); it
#                                        quits by itself. Build first: INSTALL=0 ./scripts/build.sh
#   CYCLES=5 ./scripts/measure.sh --motion   fewer open/close cycles (20 by default)
#
# For the installed app's own opens, launch it with --measure and read the log:
#   log stream --predicate 'subsystem == "com.irfanabdulhameed.clipnpaste" && category == "measure"'
set -euo pipefail
cd "$(dirname "$0")/.."

SECS=60
PID=""
MOTION=0
while [ $# -gt 0 ]; do
  case "$1" in
    -s) SECS="$2"; shift ;;
    -p) PID="$2"; shift ;;
    --motion) MOTION=1 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$MOTION" = 1 ]; then
  BIN=build/Clipnpaste.app/Contents/MacOS/Clipnpaste
  [ -x "$BIN" ] || { echo "Build first: INSTALL=0 ./scripts/build.sh" >&2; exit 1; }
  LOG="$(mktemp -t clipnpaste-measure)"
  APP=""
  cleanup() {
    [ -n "$APP" ] && kill "$APP" 2>/dev/null || true
    rm -f "$LOG"
  }
  trap cleanup EXIT
  nice -n 15 "$BIN" --scene measure --measure --measure-cycles "${CYCLES:-20}" >"$LOG" 2>&1 &
  APP=$!
  # It quits by itself when done; two minutes at most.
  for _ in $(seq 1 600); do kill -0 "$APP" 2>/dev/null || break; sleep 0.2; done
  kill "$APP" 2>/dev/null || true
  wait "$APP" 2>/dev/null || true
  APP=""
  grep -E "measure: (SUMMARY|interrupted)" "$LOG" | sed 's/^\[Clipnpaste\] measure: //'
  exit 0
fi

if [ -z "$PID" ]; then
  PID="$(pgrep -f "$HOME/Applications/Clipnpaste.app/Contents/MacOS/Clipnpaste" | head -1 || true)"
  [ -z "$PID" ] && PID="$(pgrep -x Clipnpaste | head -1 || true)"
fi
[ -n "$PID" ] || { echo "Clipnpaste is not running." >&2; exit 1; }

# CPU time used so far, in seconds ("M:SS.ss" or "H:MM:SS.ss").
cpu_seconds() { ps -o time= -p "$PID" | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; print s }'; }
# Idle wake-ups so far (top's default mode counts from launch).
wakeups() { top -l 1 -pid "$PID" -stats pid,idlew | awk -v p="$PID" '$1 == p { print $2 }'; }

echo "Watching $(ps -o comm= -p "$PID") ($PID) for $SECS s; leave the panel closed and the Mac idle…"
C0="$(cpu_seconds)"; W0="$(wakeups)"
sleep "$SECS"
C1="$(cpu_seconds)"; W1="$(wakeups)"
FOOT="$(footprint "$PID" 2>/dev/null | sed -n 's/.*Footprint: \(.*\) (.*/\1/p' | head -1)"

awk -v c0="$C0" -v c1="$C1" -v w0="$W0" -v w1="$W1" -v s="$SECS" -v f="$FOOT" 'BEGIN {
  printf "%-16s%-28s%s\n", "Idle CPU:", sprintf("%.3f%% over %d s", (c1 - c0) / s * 100, s), "target 0.0 to 0.1% over 5 minutes"
  printf "%-16s%-28s%s\n", "Idle wake-ups:", sprintf("%.2f per second", (w1 - w0) / s), "target <= 2/s while you work, <= 1/s after 60 s idle"
  printf "%-16s%-28s%s\n", "Memory:", f " footprint", "target under 50 MB idle with 1,000 clips; under 120 MB with history open"
}'
