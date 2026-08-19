#!/usr/bin/env bash

# Build, install and run the clipboard probe on one emulator.
# Usage: tools/android/clipprobe/run.sh [serial]
# A probe, not a lane. Questions in ProbeActivity; answers in
# docs/clipboard-plan.md §0e and docs/traps.md.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SERIAL="${1:-emulator-5558}"
PKG=dev.kaya.clipprobe
OUT="$ROOT/target/android-clipprobe"

cd "$HERE"
gradle --console=plain -q :app:assembleDebug
mkdir -p "$OUT"

adb -s "$SERIAL" shell am force-stop "$PKG" >/dev/null 2>&1 || true
adb -s "$SERIAL" uninstall "$PKG" >/dev/null 2>&1 || true
adb -s "$SERIAL" install -r app/build/outputs/apk/debug/app-debug.apk >/dev/null
adb -s "$SERIAL" logcat -c

# Two runs: nothing else on the device can seed this clipboard (Q4).
echo "== run 1: writes and leaves content behind =="
adb -s "$SERIAL" shell am start -W -n "$PKG/.ProbeActivity" >/dev/null
sleep 11
adb -s "$SERIAL" shell am force-stop "$PKG"

echo "== run 2: reads what run 1 left, then loses focus =="
adb -s "$SERIAL" logcat -c
adb -s "$SERIAL" shell am start -W -n "$PKG/.ProbeActivity" --es seed "from-run-1" >/dev/null
sleep 4
adb -s "$SERIAL" exec-out screencap -p > "$OUT/after-copy.png" 2>/dev/null \
    && echo "== screenshot after copy: $OUT/after-copy.png =="
# Q2: focus away, so the read at +7s happens unfocused.
adb -s "$SERIAL" shell am start -a android.intent.action.MAIN \
    -c android.intent.category.HOME >/dev/null
sleep 6
adb -s "$SERIAL" logcat -d -s kayaprobe:*
adb -s "$SERIAL" shell am force-stop "$PKG" >/dev/null 2>&1 || true
