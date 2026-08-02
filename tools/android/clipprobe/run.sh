#!/usr/bin/env bash

# Build, install and run the clipboard probe on one emulator.
# Usage: tools/android/clipprobe/run.sh [serial]
#
# NOT A LANE and never to become one. It answers what Android charges
# for a clipboard read, and what it puts ON SCREEN when one happens,
# before the Compose clipboard arm is written. See ProbeActivity's
# header for the questions and docs/clipboard-plan.md §0e for what they
# decided.
#
# WHY AN APK AT ALL: the host cannot reach this clipboard. There is no
# `cmd clipboard`, `service call clipboard <n>` needs a transaction
# number that shifts per API level, and Android 10+ gives an unfocused
# reader nothing — which the shell always is.
#
# THE RESET MATTERS, same as pickerprobe: logcat keeps the previous
# run's lines, so an empty run would read as a successful one.
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

# SEEDED BY ANOTHER APP, which is Q4 and the only way to ask it: the
# host has no path to this clipboard, so a second process has to put
# something there. The Settings app is not scriptable for that, so the
# probe is launched TWICE — the first run leaves its own content
# behind, and the second run reads it as a foreign clip written by a
# process that is already gone.
echo "== run 1: writes and leaves content behind =="
adb -s "$SERIAL" shell am start -W -n "$PKG/.ProbeActivity" >/dev/null
sleep 11
adb -s "$SERIAL" shell am force-stop "$PKG"

echo "== run 2: reads what run 1 left, then loses focus =="
adb -s "$SERIAL" logcat -c
adb -s "$SERIAL" shell am start -W -n "$PKG/.ProbeActivity" --es seed "from-run-1" >/dev/null
sleep 4
# Q3: what is on screen right after a copy?
adb -s "$SERIAL" exec-out screencap -p > "$OUT/after-copy.png" 2>/dev/null \
    && echo "== screenshot after copy: $OUT/after-copy.png =="
# Q2: take focus away, so the read at +7s happens unfocused.
adb -s "$SERIAL" shell am start -a android.intent.action.MAIN \
    -c android.intent.category.HOME >/dev/null
sleep 6
adb -s "$SERIAL" logcat -d -s kayaprobe:*
adb -s "$SERIAL" shell am force-stop "$PKG" >/dev/null 2>&1 || true
