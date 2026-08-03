#!/usr/bin/env bash

# ClipHelper campaign — the CROSS-PACKAGE cells the second clipprobe
# run could not measure (its reader owned the provider, and
# same-package access needs no grant, so the grant/revocation/clear
# traps were vacuously green):
#
#  C1 helper reads while NOT the default IME — expect null (control).
#  C2 helper as default IME reads a probe-seeded text — expect content.
#  C3 probe seeds its five-representation clip; the HELPER reads the
#     custom and image bytes across packages — THE PASTE-GRANT CELL
#     (ClipboardService grants the reading package at getPrimaryClip).
#  C4 the C3 URI, re-opened by the helper AFTER the clip changes —
#     the revocation is real only cross-package.
#  C5 the ungrantable URI, read cross-package — the documented-nowhere
#     clear-the-clipboard trap, provoked for real this time.
#  C6 the reverse direction: helper SEEDS image bytes through ITS
#     provider; the probe package (granted the IME role for the cell)
#     reads them across packages and decodes 4x4.
#
# Throwaway; results on stdout via ordered-broadcast result data.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SERIAL="${1:-emulator-5558}"
HELPER=dev.kaya.cliphelper
PROBE=dev.kaya.clipprobe
A() { adb -s "$SERIAL" "$@"; }
probe_seed() { A shell am broadcast -a dev.kaya.clipprobe.SEED -n "$PROBE/.SeedReceiver" "$@" | grep -E "data="; }
helper_read() { A shell am broadcast -a dev.kaya.cliphelper.READ -n "$HELPER/.ReadReceiver" "$@" | grep -E "data="; }
helper_seed() { A shell am broadcast -a dev.kaya.cliphelper.SEED -n "$HELPER/.SeedReceiver" "$@" | grep -E "data="; }
probe_read() { A shell am broadcast -a dev.kaya.clipprobe.READ -n "$PROBE/.ReadReceiver" "$@" | grep -E "data="; }

cd "$HERE"
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
CUSTOM_URI="$(printf '%s' "$CUSTOM_LINE" | grep -oE 'content://[^ "]+' | head -1)"
probe_seed --es kind text --es payload "c4-clip-changed"
helper_read --es kind reopen --es uri "content://dev.kaya.clipprobe/custom"

echo "== C5: the ungrantable URI, cross-package (the clear trap) =="
probe_seed --es kind ungrantable
helper_read --es kind dump
helper_read --es kind text

echo "== C6: helper seeds image; probe reads cross-package =="
# The pixel rides base64 from the host — the same courier the guest
# will use app-to-app. 77 bytes:
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
