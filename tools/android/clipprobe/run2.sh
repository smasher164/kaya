#!/usr/bin/env bash

# ClipProbe, second campaign (2026-08-03) — the cells the Compose arm
# and the helper APK turn on, each measured before a line of arm code:
#
#  P1 background SEED via broadcast (writes are not focus-gated).
#  P2 background READ without the IME trick — expect denied/null.
#  P3 the DEFAULT-IME exemption: `ime enable/set` this package, read
#     again from the same unfocused receiver — expect content. This
#     cell decides the helper APK's whole shape.
#  P4 the five-representation clip, BUILT BY HAND (description lists
#     every mime; text+html inline; custom/image bytes via provider
#     URIs) — read back per kind through the paste-grant mechanics.
#  P5 grant REVOCATION: the URI captured in P4, re-opened after the
#     clip changes — expect refused.
#  P6 the ungrantable-URI trap: getPrimaryClip is documented nowhere
#     to CLEAR THE CLIPBOARD when a grant fails — provoke and confirm.
#  P7 the EMULATOR-HOST BRIDGE: EmulatorClipboardMonitor pushes guest
#     clips to the HOST clipboard over vsock. If live, an android
#     clipboard leg can clobber the mac lane mid-validate-all. Measure
#     both directions.
#  P8 a broadcast to a STOPPED package (post-force-stop) is silently
#     dropped (FLAG_EXCLUDE_STOPPED_PACKAGES); measure, and measure
#     whether am's --include-stopped-packages overrides it.
#
# Throwaway; nothing in the validation ladder calls this. Results on
# stdout — the receivers answer through ORDERED broadcast result data,
# which `am broadcast` prints directly (no logcat race).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SERIAL="${1:-emulator-5558}"
PKG=dev.kaya.clipprobe
OUT="$ROOT/target/android-clipprobe"
A() { adb -s "$SERIAL" "$@"; }
seed() { A shell am broadcast -a dev.kaya.clipprobe.SEED -n "$PKG/.SeedReceiver" "$@" | grep -E "data=|Broadcast"; }
read_clip() { A shell am broadcast -a dev.kaya.clipprobe.READ -n "$PKG/.ReadReceiver" "$@" | grep -E "data=|Broadcast"; }

cd "$HERE"
gradle --console=plain -q :app:assembleDebug
mkdir -p "$OUT"

A shell am force-stop "$PKG" >/dev/null 2>&1 || true
A uninstall "$PKG" >/dev/null 2>&1 || true
A install -r app/build/outputs/apk/debug/app-debug.apk >/dev/null

echo "== P8a: broadcast to the NEVER-STARTED package (stopped state) =="
seed --es kind text --es payload "p8-stopped"
echo "== P8b: same, with --include-stopped-packages =="
A shell am broadcast -a dev.kaya.clipprobe.SEED -n "$PKG/.SeedReceiver" \
    --include-stopped-packages --es kind text --es payload "p8-included" | grep -E "data=|Broadcast"

# Un-stop the package properly for the rest of the campaign.
A shell am start -W -n "$PKG/.ProbeActivity" >/dev/null
sleep 2
# The guest-shaped state: something ELSE holds the foreground.
A shell am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null
sleep 1

echo "== P1: background seed (no focus anywhere near this package) =="
seed --es kind text --es payload "p1-background-seed"

echo "== P2: background read, NOT the default IME yet =="
read_clip --es kind text

echo "== P3: ime enable + set, then the same background read =="
A shell ime enable "$PKG/.ProbeIme" 2>&1 | tr -d '\r'
A shell ime set "$PKG/.ProbeIme" 2>&1 | tr -d '\r'
sleep 1
read_clip --es kind text

echo "== P4: the five-representation clip, read back per kind =="
seed --es kind fiverep
read_clip --es kind dump
read_clip --es kind text
read_clip --es kind html
CUSTOM_LINE="$(read_clip --es kind custom | tr -d '\r')"
echo "$CUSTOM_LINE"
read_clip --es kind image
A exec-out screencap -p > "$OUT/after-fiverep.png" 2>/dev/null \
    && echo "== screenshot after the suppressed-overlay copy: $OUT/after-fiverep.png =="

echo "== P5: the P4 custom URI, re-opened after the clip changes =="
CUSTOM_URI="$(printf '%s' "$CUSTOM_LINE" | grep -oE 'content://[^ ]+' | head -1)"
seed --es kind text --es payload "p5-clip-changed"
read_clip --es kind reopen --es uri "$CUSTOM_URI"

echo "== P6: the ungrantable URI, then what is left of the clipboard =="
seed --es kind ungrantable
read_clip --es kind dump
read_clip --es kind text

echo "== P7: the emulator-host bridge, both directions =="
seed --es kind text --es payload "kaya-bridge-guest-to-host"
sleep 1
echo "host pbpaste after guest seed: >>>$(pbpaste 2>/dev/null | head -c 80)<<<"
printf 'kaya-bridge-host-to-guest' | pbcopy
sleep 1
read_clip --es kind text
# Leave the host clipboard clean of probe strings.
printf '' | pbcopy

echo "== restore: default IME back to normal =="
A shell ime reset 2>&1 | tr -d '\r'
A shell am force-stop "$PKG" >/dev/null 2>&1 || true
echo "PROBEDONE"
