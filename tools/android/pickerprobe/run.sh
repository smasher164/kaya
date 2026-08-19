#!/usr/bin/env bash

# Build, install and run the picker probe on one emulator.
# Usage: tools/android/pickerprobe/run.sh [serial]
#
# NOT A LANE and never to become one: it installs an app with an
# accessibility service. Findings: docs/traps.md, "What DocumentsUI
# publishes".
#
# THE RESET IS THE WHOLE POINT of having a script. Three ways a rerun
# silently measures the LAST run instead of this one:
#   - the picker is still up, so `am start` on the probe's component just
#     brings that task forward and onCreate never runs again;
#   - force-stop kills the accessibility service with the process, and
#     the setting still NAMES it, so `dumpsys` must confirm it rebound;
#   - logcat keeps the previous run's lines, so an empty run reads as a
#     successful one.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SERIAL="${1:-emulator-5554}"
PKG=dev.kaya.pickerprobe
SVC="$PKG/$PKG.ProbeA11y"

(cd "$HERE" && gradle --console=plain -q :app:assembleDebug)

adb -s "$SERIAL" install -r "$HERE/app/build/outputs/apk/debug/app-debug.apk" >/dev/null

adb -s "$SERIAL" logcat -c

# The picker is MODAL, so each variant needs the FULL reset above
# (docs/traps.md:2404).
for variant in basic multi filter cancel; do
    # Both tasks: the probe's, and the picker it may have left standing.
    adb -s "$SERIAL" shell am force-stop "$PKG"
    adb -s "$SERIAL" shell am force-stop com.google.android.documentsui
    adb -s "$SERIAL" shell am force-stop com.android.documentsui 2>/dev/null || true

    # AFTER the force-stop: the service lives in the app's process, so
    # the force-stop killed it and the setting still naming it proves
    # nothing.
    adb -s "$SERIAL" shell settings put secure \
        enabled_accessibility_services "$SVC" >/dev/null
    adb -s "$SERIAL" shell settings put secure accessibility_enabled 1 >/dev/null
    bound=0
    for _ in $(seq 1 20); do
        if adb -s "$SERIAL" shell dumpsys accessibility 2>/dev/null | grep -q ProbeA11y; then
            bound=1
            break
        fi
        sleep 0.5
    done
    if [ "$bound" -ne 1 ]; then
        echo "run.sh: the probe's accessibility service never bound ($variant)" >&2
        exit 1
    fi

    # NO -S: it force-stops the package first, killing the service just
    # confirmed bound (docs/traps.md:2415).
    adb -s "$SERIAL" shell am start -W -n "$PKG/.ProbeActivity" \
        --es variant "$variant" >/dev/null
    sleep 12
done
adb -s "$SERIAL" logcat -d -s "kayaprobe:*"

adb -s "$SERIAL" shell am force-stop com.google.android.documentsui
adb -s "$SERIAL" shell am force-stop "$PKG"
