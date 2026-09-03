#!/usr/bin/env bash

# Dev-shell guard; the marker is the flake fingerprint (CLAUDE.md).
kaya_flake="$(cd "$(dirname "$0")/../../.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi

# ClipProbe II, the campaign the iOS clipboard arm is written from
# (main2.swift has the cell list).
#
#   run2.sh [a|b|c|s|all] [udid]
#
#  A  the app writes the union clip, is TERMINATED, pbsync device->host,
#     the host reads every kind back.
#  B  the host seeds each kind, the app's recv mode lists types WITHOUT
#     touching data.
#  C  the paste prompt, photographed and driven through simdrive.
#  S  a simctl-spawned reader against the app's union clip.
#
# Throwaway; nothing in the validation ladder calls this. Results on
# stdout plus screenshots in target/ios-clipprobe2/.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
cd "$ROOT" || exit 1

# shellcheck source=tools/lib/swift-toolchain.sh
. "$ROOT/tools/lib/swift-toolchain.sh"
kaya_resolve_swiftc || exit 1
[ -n "${SWIFT_DEVELOPER_DIR:-}" ] && export DEVELOPER_DIR="$SWIFT_DEVELOPER_DIR"
xcrun simctl help >/dev/null 2>&1 || {
    echo "run2.sh: no full Xcode (simctl missing)" >&2
    exit 1
}

CAMPAIGN="${1:-all}"
UDID="${2:-}"
if [ -z "$UDID" ]; then
    UDID=$(xcrun simctl list devices 2>/dev/null | grep -m1 "kaya-sim-0 (" \
        | grep -oE '[0-9A-F-]{36}') || true
fi
[ -n "$UDID" ] || {
    echo "run2.sh: no kaya-sim-0; run tools/ios/run-sim.py once" >&2
    exit 1
}
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

OUT="$ROOT/target/ios-clipprobe2"
APP="$OUT/ClipProbe2.app"
BUNDLE=dev.kaya.clipprobe2
rm -rf "$APP"
mkdir -p "$APP"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
env -u SDKROOT "$SWIFTC" \
    -target arm64-apple-ios17.0-simulator \
    -sdk "$SDK" \
    -o "$APP/ClipProbe2" \
    "$HERE/main2.swift" || exit 1

cat >"$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ClipProbe2</string>
    <key>CFBundleIdentifier</key><string>dev.kaya.clipprobe2</string>
    <key>CFBundleName</key><string>ClipProbe2</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSRequiresIPhoneOS</key><true/>
    <key>UIFileSharingEnabled</key><true/>
    <key>LSSupportsOpeningDocumentsInPlace</key><true/>
    <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
    <key>UILaunchScreen</key><dict/>
</dict>
</plist>
PLIST

xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP" || exit 1

# hold=1 leaves the app running (campaign C drives it while it lives).
launch_mode() {
    local mode="$1" log="$2" hold="${3:-0}"
    SIMCTL_CHILD_KAYA_CLIPPROBE_MODE="$mode" \
        xcrun simctl launch --console-pty "$UDID" "$BUNDLE" >"$log" 2>&1 &
    LAUNCH_PID=$!
    if [ "$hold" = 0 ]; then
        sleep 8
        kill "$LAUNCH_PID" 2>/dev/null || true
        xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
    fi
}

# pbsync in either direction, BOUNDED: a promised secondary type makes
# it hang past delivery (measured: rc=124 while the content had long
# arrived), so the exit status is noise — the caller polls for arrival.
pbsync_bounded() {
    timeout 30 xcrun simctl pbsync "$1" "$2" >/dev/null 2>&1 || true
}

host_pb_types() {
    osascript -e 'clipboard info' 2>/dev/null
}

if [ "$CAMPAIGN" = a ] || [ "$CAMPAIGN" = all ]; then
    echo "== A: app writes the union clip, host reads it back =="
    launch_mode write "$OUT/write.log"
    echo "-- app-side (W cells):"
    grep PROBE "$OUT/write.log" | grep -v NSLog || cat "$OUT/write.log"
    echo "-- app TERMINATED; pbsync device->host…"
    : | pbcopy   # a clean host slate, so arrival is unambiguous
    pbsync_bounded "$UDID" host
    for _ in $(seq 1 20); do
        if pbpaste 2>/dev/null | grep -q "kaya clip"; then break; fi
        sleep 0.5
    done
    echo "-- host clipboard info:"
    host_pb_types
    echo "-- host pbpaste (plain): [$(pbpaste 2>/dev/null)]"
    echo "-- host pbpaste -Prefer public.html: [$(pbpaste -Prefer public.html 2>/dev/null)]"
    echo "-- host pbpaste -Prefer dev.kaya/note: [$(pbpaste -Prefer dev.kaya/note 2>/dev/null)]"
    SCRATCH="$OUT/sync.png"
    rm -f "$SCRATCH"
    osascript \
        -e "set f to open for access POSIX file \"$SCRATCH\" with write permission" \
        -e "set eof f to 0" \
        -e "write (the clipboard as «class PNGf») to f" \
        -e "close access f" 2>/dev/null
    if [ -f "$SCRATCH" ]; then
        echo "-- host png: $(sips -g pixelWidth -g pixelHeight "$SCRATCH" 2>/dev/null | grep pixel | tr '\n' ' ')"
    else
        echo "-- host png: none crossed"
    fi
    echo "-- host file-url: [$(osascript -e 'POSIX path of (the clipboard as «class furl»)' 2>/dev/null)]"
fi

if [ "$CAMPAIGN" = b ] || [ "$CAMPAIGN" = all ]; then
    echo "== B: host seeds each kind, app lists types without data =="
    CONTAINER=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data 2>/dev/null)
    printf 'seeded bytes' >"$CONTAINER/Documents/seeded.txt" 2>/dev/null || true

    seed_and_recv() {
        local label="$1"
        pbsync_bounded host "$UDID"
        launch_mode recv "$OUT/recv-$label.log"
        echo "-- after seeding $label:"
        grep "PROBE R" "$OUT/recv-$label.log" || cat "$OUT/recv-$label.log"
    }

    printf 'plain text seed' | pbcopy
    seed_and_recv text

    HEXHTML=$(printf '<b>seeded</b> html' | xxd -p | tr -d '\n' | tr '[:lower:]' '[:upper:]')
    osascript -e "set the clipboard to «data HTML${HEXHTML}»" 2>/dev/null
    seed_and_recv html

    PNGPATH="$OUT/seed.png"
    python3 - "$PNGPATH" <<'EOF'
import sys, struct, zlib
sig = b'\x89PNG\r\n\x1a\n'
def chunk(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', 4, 4, 8, 2, 0, 0, 0))
raw = b''.join(b'\x00' + b'\xff\x00\x00' * 4 for _ in range(4))
idat = chunk(b'IDAT', zlib.compress(raw))
open(sys.argv[1], 'wb').write(sig + ihdr + idat + chunk(b'IEND', b''))
EOF
    osascript -e "set the clipboard to (read (POSIX file \"$PNGPATH\") as «class PNGf»)" 2>/dev/null
    seed_and_recv image

    osascript -e "set the clipboard to POSIX file \"$CONTAINER/Documents/seeded.txt\"" 2>/dev/null
    seed_and_recv files
fi

if [ "$CAMPAIGN" = c ] || [ "$CAMPAIGN" = all ]; then
    echo "== C: the prompt, driven =="
    SIMDRIVE=$(tools/ios/simdrive/build.sh) || exit 1
    printf 'first-foreign' | xcrun simctl pbcopy "$UDID"
    launch_mode read "$OUT/read.log" 1
    # The pid, for simdrive: last field of "bundle: pid" in the log.
    sleep 3
    APP_PID=$(grep -oE '[0-9]+$' <(grep "$BUNDLE" "$OUT/read.log" | head -1) || echo 0)
    echo "-- app pid: ${APP_PID:-unknown}"
    xcrun simctl io "$UDID" screenshot "$OUT/alert-up.png" >/dev/null 2>&1
    echo "-- simdrive describe (is the alert an overlay?):"
    "$SIMDRIVE" "$UDID" "${APP_PID:-0}" describe 2>&1 | head -25
    echo "-- simdrive press Allow Paste:"
    "$SIMDRIVE" "$UDID" "${APP_PID:-0}" press Allow Paste 2>&1
    sleep 3
    xcrun simctl io "$UDID" screenshot "$OUT/after-allow.png" >/dev/null 2>&1
    echo "-- re-seeding (P3)…"
    printf 'second-foreign' | xcrun simctl pbcopy "$UDID"
    sleep 6
    xcrun simctl io "$UDID" screenshot "$OUT/after-reseed.png" >/dev/null 2>&1
    echo "-- app-side (P cells):"
    grep PROBE "$OUT/read.log" | grep -v heartbeat || cat "$OUT/read.log"
    echo "-- heartbeats seen: $(grep -c heartbeat "$OUT/read.log")"
    kill "$LAUNCH_PID" 2>/dev/null || true
    xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
fi

if [ "$CAMPAIGN" = s ] || [ "$CAMPAIGN" = all ]; then
    echo "== S: a simctl-spawned reader against the app's union clip =="
    env -u SDKROOT "$SWIFTC" \
        -target arm64-apple-ios17.0-simulator \
        -sdk "$SDK" \
        -o "$OUT/spawnread" \
        "$HERE/spawnread.swift" || exit 1
    launch_mode write "$OUT/write-s.log"
    echo "-- app wrote the union clip and was TERMINATED; spawning the reader…"
    for kind in "" text html image files dev.kaya/note; do
        echo "-- spawn read ${kind:-types-only}:"
        timeout 20 xcrun simctl spawn "$UDID" "$OUT/spawnread" $kind 2>&1 \
            | grep -v "unhandled Platform" | grep "^S " \
            || echo "   (no answer within 20s — treated as gated or unsupported)"
    done
fi

echo "== done; screenshots in $OUT =="
