#!/usr/bin/env bash

# ClipHelper campaign — the CROSS-PACKAGE clipboard cells. The
# same-package clipprobe run could not measure them: its reader owned the
# provider, so the grant/revocation/clear traps were vacuously green.
# Results: docs/clipboard-plan.md:1223. THROWAWAY.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SERIAL="${1:-emulator-5558}"
HELPER=dev.kaya.cliphelper
PROBE=dev.kaya.clipprobe
A() { adb -s "$SERIAL" "$@"; }
probe_seed() { A shell am broadcast -a dev.kaya.clipprobe.SEED -n "$PROBE/.SeedReceiver" "$@" | grep -E "data="; }
helper_read() { A shell am broadcast -a dev.kaya.cliphelper.READ -n "$HELPER/.ReadReceiver" "$@" | grep -E "data="; }
helper_seed() { A shell am broadcast -a dev.kaya.cliphelper.SEED -n "$HELPER/.SeedReceiver" "$@" | grep -E "data="; }
probe_read() { A shell am broadcast -a dev.kaya.clipprobe.READ -n "$PROBE/.ReadReceiver" "$@" | grep -E "data="; }

cd "$HERE" || exit 1
gradle --console=plain -q :app:assembleDebug
(cd "$HERE/../clipprobe" && gradle --console=plain -q :app:assembleDebug)

for pkg_apk in "$HELPER:$HERE/app/build/outputs/apk/debug/app-debug.apk" \
    "$PROBE:$HERE/../clipprobe/app/build/outputs/apk/debug/app-debug.apk"; do
    pkg="${pkg_apk%%:*}"
    apk="${pkg_apk#*:}"
    A shell am force-stop "$pkg" >/dev/null 2>&1 || true
    A uninstall "$pkg" >/dev/null 2>&1 || true
    A install -r "$apk" >/dev/null
done
A shell ime reset >/dev/null 2>&1 || true

echo "== C1: helper reads, no IME role =="
probe_seed --es kind text --es payload "c1-seed"
helper_read --es kind text

echo "== C2: helper as default IME =="
A shell ime enable "$HELPER/.HelperIme" >/dev/null
A shell ime set "$HELPER/.HelperIme" >/dev/null
sleep 1
helper_read --es kind text

echo "== C3: cross-package byte reads off the probe's provider =="
probe_seed --es kind fiverep
helper_read --es kind dump
CUSTOM_LINE="$(helper_read --es kind custom | tr -d '\r')"
echo "$CUSTOM_LINE"
helper_read --es kind image

echo "== C4: the C3 URI after the clip changes (cross-package revocation) =="
probe_seed --es kind text --es payload "c4-clip-changed"
helper_read --es kind reopen --es uri "content://dev.kaya.clipprobe/custom"

echo "== C5: the ungrantable URI, cross-package (the clear trap) =="
probe_seed --es kind ungrantable
helper_read --es kind dump
helper_read --es kind text

echo "== C6: helper seeds image; probe reads cross-package =="
# The pixel rides base64 from the host, 77 bytes:
PIXEL_B64="iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAFElEQVR42mP4z8AAR0hMdN5/JAAA0m8X6VG7Iy0AAAAASUVORK5CYII="
helper_seed --es kind image --es b64 "$PIXEL_B64"
A shell ime enable "$PROBE/.ProbeIme" >/dev/null
A shell ime set "$PROBE/.ProbeIme" >/dev/null
sleep 1
probe_read --es kind image

A shell ime reset >/dev/null 2>&1 || true
A shell am force-stop "$HELPER" >/dev/null 2>&1 || true
A shell am force-stop "$PROBE" >/dev/null 2>&1 || true
echo "PROBEDONE"
