#!/usr/bin/env bash
# The menus scene runs every one of this runner's flavors: the swift
# guest (IOS_SWIFT_SCENES), the go guest (IOS_GO_SCENES) and the rust
# example (rust-swiftui).

# The split scene is desktop-only BY DESIGN and deliberately not a leg
# here: it drives resize_window, and a phone or tablet host does not
# command its own window size (the system owns surfaces; DESIGN.md,
# Windows). Its phone-safe sibling `listdetail` covers this backend
# instead — the bare invariant, on a phone AND on the iPad, which is
# where the split arm is observable at all.
# The panels scene is desktop-only BY DESIGN and deliberately not a
# leg here: create_window is capability-rejected on this host (no
# KAYA_CAP_AUX_WINDOWS — the system owns surfaces; DESIGN.md,
# Presentation contexts).
# Dev-shell guard; the marker is the flake fingerprint (CLAUDE.md).
kaya_flake="$(cd "$(dirname "$0")/../.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# Build, install, and self-test the milestone scene in the iOS Simulator.
# Usage: tools/ios/run-sim.sh [swift|go|rust-swiftui|all]
#
# rust         - the kaya example app (UIKit backend)
# swift        - Swift over the C ABI function floor (UIKit backend)
# go           - Go over the same function floor, cross-built with
#                GOOS=ios and owning the process main thread
# rust-swiftui - the Rust example with the SwiftUI backend selected at
#                runtime (dylib embedded in the bundle)
#
# Requires full Xcode (simctl, the iOS SDK, and a downloaded simulator
# runtime); simulator builds are unsigned, so no developer account is
# involved. The Rust leg is the kaya example app; the Swift leg validates
# the C ABI's function floor, importing kaya.h directly.
set -euo pipefail

ROOT_FOR_CHECK="$(cd "$(dirname "$0")/../.." && pwd)"
# Compile the ios target and typecheck the Swift guest before the
# simulator is involved.
"$ROOT_FOR_CHECK/tools/check-targets.sh" ios || exit 1
"$ROOT_FOR_CHECK/tools/swift-typecheck.sh" || exit 1

SUITE="${1:-all}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# The active developer dir may still be the Command Line Tools (simctl and
# the iOS SDK live only in Xcode); point at Xcode without needing sudo.
# Handles versioned installs (Xcode-26.6.0.app, the xcodes convention).
if ! xcrun simctl help >/dev/null 2>&1; then
    for app in /Applications/Xcode.app /Applications/Xcode-*.app; do
        if [ -d "$app/Contents/Developer" ]; then
            export DEVELOPER_DIR="$app/Contents/Developer"
            break
        fi
    done
fi
TARGET_DIR="$ROOT/target/aarch64-apple-ios-sim/debug"
BUNDLES="$ROOT/target/ios-bundles"
IOS_MIN="16.0"

cd "$ROOT"

# The swift and rust-swiftui suites compile against kaya.h and the
# generated Swift bindings; fail loudly if either has drifted from the
# Rust source.
tools/gen-header.sh --check
tools/gen-bindings.sh --check

# The host-side picker driver, built ONCE per run and before any leg, so
# a break in it fails at the top rather than inside one leg's watcher,
# where the symptom would be a scene timing out with no reason.
SIMDRIVE=$(tools/ios/simdrive/build.sh)
# The lane's foreign clipboard reader, built once for the same reason.
# It is a separate binary rather than a verb of simdrive because it runs
# INSIDE the simulator, under `simctl spawn`, against the same UIKit the
# guest sees (tools/ios/clipctl/main.swift).
CLIPCTL=$(tools/ios/clipctl/build.sh)

# THE DECLARED APP IDENTITY, READ ONCE, FROM THE ONE PLACE IT IS WRITTEN
# (docs/app-identity-plan.md ruling 4). THE VALUES COME OUT OF THE
# DECLARATION, never retyped: retyping either one here is the second
# reader ruling 4 exists to prevent, and check-app-identity C6 holds
# this file to it.
KAYA_IDENTITY_MANIFEST="$ROOT/guests/assets/identity.toml"
IDENTITY_DECL="$(python3 - "$KAYA_IDENTITY_MANIFEST" <<'PY'
import pathlib
import sys
import tomllib

man = pathlib.Path(sys.argv[1])
if not man.is_file():
    sys.exit(f"run-sim: {man} is missing — the app identity is declared there "
             f"and this lane's bundles read their icon and display name from "
             f"it (docs/app-identity-plan.md ruling 4)")
decl = tomllib.loads(man.read_text(encoding="utf-8"))
icon, name = decl.get("icon"), decl.get("name")
for key, value in (("icon", icon), ("name", name)):
    if not isinstance(value, str) or not value.strip():
        sys.exit(f"run-sim: {man} declares no `{key}`, so the bundles this lane "
                 f"assembles would carry half an identity")
print(icon)
print(name)
PY
)"
identity_decl_rc=$?
if [ "$identity_decl_rc" -ne 0 ] || [ -z "$IDENTITY_DECL" ]; then
    echo "run-sim: could not read the app identity from $KAYA_IDENTITY_MANIFEST" >&2
    exit 1
fi
ICON_REL="$(printf '%s\n' "$IDENTITY_DECL" | head -1)"
IDENTITY_NAME="$(printf '%s\n' "$IDENTITY_DECL" | tail -1)"
ICON_SRC="$ROOT/$ICON_REL"
ICON_IN_BUNDLE="$(basename "$ICON_REL")"
if [ ! -f "$ICON_SRC" ]; then
    echo "run-sim: the declared app mark $ICON_REL is missing from this tree" >&2
    exit 1
fi

# THE ASSET ROOT, INTO EVERY BUNDLE. This is the one lane where staging
# and PACKAGING are the same act: an iOS app resolves its resources out
# of its own bundle (docs/assets-plan.md A4's iOS row and A5.3).
#
# NO KAYA_ASSET_DIR HERE, AND THAT IS THE POINT: the core asks
# `Bundle.main` for its resource directory before it falls back to
# anything (crates/kaya/src/assets.rs, route 2). If the bundle copy
# stops happening the guest does not read a stale file — it gets the
# core's miss sentence naming the bundle it looked in.
#
# THE WHOLE ROOT, not the files a scene happens to want (A5.1).
ASSET_SRC="$ROOT/guests/assets"
if [ ! -d "$ASSET_SRC" ]; then
    echo "run-sim: the asset root $ASSET_SRC is missing — every bundle this" >&2
    echo "  lane assembles carries it, and a guest calling asset() would get" >&2
    echo "  the core's miss sentence on every leg" >&2
    exit 1
fi

make_bundle() {
    # A fourth argument, ANY non-empty value, puts the declared identity
    # into this bundle. OPT-IN AND NOT GLOBAL: `expect_app_icon` reads
    # THIS artifact and holds it equal to what the guest declared over
    # the wire, so a bundle carrying an identity its guest never declared
    # would let the read report one for an app with no declaration.
    local name="$1" bundle_id="$2" executable_path="$3" identity="${4:-}"
    local app="$BUNDLES/$name.app"
    rm -rf "$app"
    mkdir -p "$app"
    local icon_keys=""
    if [ -n "$identity" ]; then
        cp "$ICON_SRC" "$app/$ICON_IN_BUNDLE" || return 1
        icon_keys="$ICON_IN_BUNDLE"
    fi
    KAYA_NAME="$name" KAYA_BUNDLE_ID="$bundle_id" \
        KAYA_ICON_KEYS="$icon_keys" KAYA_DISPLAY_NAME="$IDENTITY_NAME" python3 -c '
import os, sys
tpl = open("tools/ios/Info.plist.in").read()
icon = os.environ["KAYA_ICON_KEYS"]
# The icon file name carries its extension in the bundle and NOT in
# CFBundleIconFiles: iOS matches the entry against the bundle root by
# base name, which is what lets one entry stand for the @2x/@3x family
# an asset catalog would emit. The interpreter resolves it the same way.
block = "" if not icon else """<key>CFBundleDisplayName</key>
    <string>{name}</string>
    <key>CFBundleIcons</key>
    <dict>
        <key>CFBundlePrimaryIcon</key>
        <dict>
            <key>CFBundleIconFiles</key>
            <array>
                <string>{base}</string>
            </array>
        </dict>
    </dict>""".format(name=os.environ["KAYA_DISPLAY_NAME"],
                      base=icon.rsplit(".", 1)[0])
sys.stdout.write(tpl.replace("@EXECUTABLE@", os.environ["KAYA_NAME"])
                    .replace("@BUNDLE_ID@", os.environ["KAYA_BUNDLE_ID"])
                    .replace("@NAME@", os.environ["KAYA_NAME"])
                    .replace("@IDENTITY@", block))' > "$app/Info.plist"
    # `cp -R <dir>/. <dst>/` rather than `cp -R <dir> <dst>` so the
    # ROOT'S CONTENTS land at assets/ whether or not the destination
    # exists — the two spellings differ only on a second run, which is
    # the run that would have nested assets/assets/.
    mkdir -p "$app/assets"
    cp -R "$ASSET_SRC/." "$app/assets/" || return 1
    # What arrived is what was sent, by hash. The bundle assembly is a
    # local copy and cannot half-land the way a push over adb can — but
    # it CAN copy a stale tree if the destination was not cleared, and
    # this is the only place that would notice.
    python3 - "$ASSET_SRC" "$app/assets" "$name" <<'PY' || return 1
import hashlib
import pathlib
import sys

src, dst, leg = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
digest = lambda f: hashlib.sha256(f.read_bytes()).hexdigest()
here = {f.relative_to(src).as_posix(): digest(f) for f in sorted(src.rglob("*")) if f.is_file()}
there = {f.relative_to(dst).as_posix(): digest(f) for f in sorted(dst.rglob("*")) if f.is_file()}
if not here:
    sys.exit(f"run-sim: the tree's asset root is empty, so the {leg} bundle's "
             "copy would agree with anything")
bad = [f"  {n}: " + ("never arrived" if n not in there
                     else f"is {there[n][:12]}, the tree has {h[:12]}")
       for n, h in sorted(here.items()) if there.get(n) != h]
bad += [f"  {n}: is in the bundle and not in the tree" for n in sorted(set(there) - set(here))]
if bad:
    print(f"run-sim: the {leg} bundle's asset root does not match the tree:",
          file=sys.stderr)
    print("\n".join(bad), file=sys.stderr)
    sys.exit(1)
PY
    cp "$executable_path" "$app/$name"
    echo "$app"
}

# A pool of dedicated simulators (kaya-sim-0..N-1, KAYA_IOS_SIMS wide)
# runs the legs in parallel. Devices are created on first use, stay
# booted across runs, and never touch the user's own simulators.
POOL="${KAYA_IOS_SIMS:-3}"
UDIDS=()
# One iPad alongside the phone pool, for one reason: the phone pool is
# ALWAYS a compact horizontal size class, so nothing else in this lane
# observes the regular-width lowering. Form-factor coverage, not
# device-matrix breadth.
PAD_UDID=""

# Resolve a pool device by name, RECREATING it if its type has drifted.
# Reuse-by-name alone is a trap: a device created under a different
# selector or Xcode keeps its old type forever, so the pool silently
# goes heterogeneous and which screen a leg gets varies run to run. For
# the iPad it is worse than flaky — a stale kaya-sim-pad of the wrong
# type makes the form-factor gate VACUOUS while still reporting PASS.
device_of() { # name dtype runtime -> udid
    local name="$1" dtype="$2" runtime="$3" udid have
    udid=$(xcrun simctl list devices | grep -m1 "$name (" \
        | grep -oE '[0-9A-F-]{36}' || true)
    if [ -n "$udid" ]; then
        have=$(xcrun simctl list devices -j | python3 -c "
import json, sys
for devs in json.load(sys.stdin)['devices'].values():
    for x in devs:
        if x.get('udid') == '$udid':
            print(x.get('deviceTypeIdentifier', ''))
")
        if [ "$have" != "$dtype" ]; then
            echo "recreating $name: type drifted ($have != $dtype)" >&2
            xcrun simctl delete "$udid" >/dev/null 2>&1 || true
            udid=""
        fi
    fi
    [ -n "$udid" ] || udid=$(xcrun simctl create "$name" "$dtype" "$runtime")
    printf '%s\n' "$udid"
}

boot_pool() {
    local dtype pad_dtype runtime i udid
    # simctl lists device types NEWEST FIRST, so `head -1` is the newest
    # and `tail -1` is the oldest. The phone selector below says
    # "newest" and takes the tail, which resolves to an iPhone 11 Pro —
    # a real (pre-existing) mismatch between its comment and its
    # behavior. Left alone deliberately: changing the phone changes the
    # screen size every geometry expectation in this lane was frozen
    # against, so it wants its own slice with a full iOS re-validation.
    # Do not copy the tail idiom.
    dtype=$(xcrun simctl list devicetypes | grep -E "iPhone [0-9]+ Pro \(" \
        | tail -1 | grep -oE 'com.apple.CoreSimulator.SimDeviceType[^)]*')
    # Large iPad Pro: unambiguously a regular width in full screen. The
    # trailing `\(com` keeps the "(16GB)" memory variants out.
    pad_dtype=$(xcrun simctl list devicetypes \
        | grep -E "iPad Pro [0-9]+-inch \(M[0-9]+\) \(com" \
        | head -1 | grep -oE 'com.apple.CoreSimulator.SimDeviceType[^)]*')
    runtime=$(xcrun simctl list runtimes | grep -m1 -oE 'com.apple.CoreSimulator.SimRuntime.iOS[0-9-]+')
    [ -n "$dtype" ] && [ -n "$runtime" ] \
        || { echo "no iPhone device type / iOS runtime; install one in Xcode" >&2; exit 1; }
    [ -n "$pad_dtype" ] \
        || { echo "no M-series iPad Pro device type; install one in Xcode" >&2; exit 1; }
    i=0
    while [ "$i" -lt "$POOL" ]; do
        udid=$(device_of "kaya-sim-$i" "$dtype" "$runtime")
        xcrun simctl boot "$udid" 2>/dev/null || true
        UDIDS+=("$udid")
        i=$((i + 1))
    done
    PAD_UDID=$(device_of "kaya-sim-pad" "$pad_dtype" "$runtime")
    xcrun simctl boot "$PAD_UDID" 2>/dev/null || true
    for udid in "${UDIDS[@]}" "$PAD_UDID"; do
        # Bounded: bootstatus blocks forever on a wedged device.
        timeout 180 xcrun simctl bootstatus "$udid" -b >/dev/null \
            || { echo "simulator $udid did not boot within 180s" >&2; exit 1; }
    done
}

# Recording mode (KAYA_RECORD=1): ONE suite-long recording contains
# every leg in sequence. Per-leg start/stop WEDGES — the device-side
# session of a stopped recording lingers and later recorders fail with
# "Host recording is already in progress". Each leg notes its launch
# anchor; extraction happens after the recorder stops.
rec_suite_start() {
    [ -n "${KAYA_RECORD:-}" ] || return 0
    command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null \
        || { echo "recording mode needs ffmpeg/ffprobe — run inside nix develop"; exit 1; }
    "$ROOT/tools/harness-extract.sh" --selftest || exit 1
    REC_ROOT="$ROOT/target/recordings/ios"
    mkdir -p "$REC_ROOT"
    # Extraction sweeps this root, so a leg directory left by an EARLIER
    # run would be extracted against TODAY's film and fail "anchor
    # implausible" forever. A STAMP rather than a wipe, because
    # `run-sim.sh swift` must not delete the rust-swiftui suite's films:
    # this run's legs carry its id and extraction ignores everything
    # else. Directories with no stamp can never be matched to a film.
    REC_RUN="$$-$(date +%s)"
    local stale
    for stale in "$REC_ROOT"/*/; do
        [ -d "$stale" ] || continue
        [ -f "$stale/run" ] || rm -rf "$stale"
    done
    # One suite-long recording PER SIMULATOR (concurrent sessions on
    # different udids coexist; same-device sessions are what wedge).
    REC_PIDS=()
    T_MARKS=()
    L_MARKS=()
    local i udid
    i=0
    for udid in "${UDIDS[@]}"; do
        xcrun simctl io "$udid" recordVideo --codec h264 --force \
            "$REC_ROOT/suite-$i.mov" >"$REC_ROOT/rec-$i.log" 2>&1 &
        REC_PIDS+=($!)
        i=$((i + 1))
    done
    # A lingering host-side session (a previously killed recorder)
    # blocks future recordings; fail fast with the remedy instead of
    # producing an empty video and dead stills.
    sleep 2
    i=0
    local wedged=0
    for udid in "${UDIDS[@]}"; do
        if grep -q "already in progress" "$REC_ROOT/rec-$i.log" 2>/dev/null; then
            wedged=1
        fi
        i=$((i + 1))
    done
    if [ "$wedged" = 1 ] && [ "${KAYA_REC_RETRY:-0}" = 0 ]; then
        # A killed prior run orphans host-side recording sessions; the
        # remedy is known and mechanical, so apply it: reset the
        # simulator service, reboot the pool, try once more.
        echo "recording: stale simctl sessions; resetting CoreSimulatorService and retrying"
        local pid
        for pid in "${REC_PIDS[@]}"; do
            pkill -INT -P "$pid" 2>/dev/null || true
            kill -9 "$pid" 2>/dev/null || true
        done
        killall -9 com.apple.CoreSimulator.CoreSimulatorService 2>/dev/null || true
        sleep 3
        UDIDS=()
        boot_pool
        KAYA_REC_RETRY=1 rec_suite_start
        return
    elif [ "$wedged" = 1 ]; then
        echo "recording: sessions still wedged after a service reset; giving up"
        exit 1
    fi
    # simctl announces capture in its own log ("Recording started") and
    # nothing else can — the output file stays ZERO bytes until
    # finalize. Flipping the fiducial before the announcement films
    # neither edge, and the run dies at extraction after every leg
    # passed. Wait for it, bounded.
    i=0
    local tries
    for udid in "${UDIDS[@]}"; do
        tries=0
        until grep -q "Recording started" "$REC_ROOT/rec-$i.log" 2>/dev/null; do
            tries=$((tries + 1))
            if [ "$tries" -gt 75 ]; then
                echo "recording: recorder $i never announced 'Recording started'" >&2
                exit 1
            fi
            sleep 0.4
        done
        i=$((i + 1))
    done
    # recordVideo's own clock is unrecoverable from either end: it
    # starts capturing at an unknown moment after launch AND drops its
    # buffered tail when stopped. So plant a fiducial per device: flip
    # the UI appearance dark and stamp the wall time when the flip is
    # actually VISIBLE — the ui command returns seconds before the
    # render lands, and a stamp is only ever written for an OBSERVED
    # render.
    #
    # The flip is an EDGE, never an absolute level: the home screen
    # accumulates one bright placeholder icon per installed bundle, and
    # their tiles held the dark appearance at YAVG ~107, so an absolute
    # <100 test concluded the flip "never rendered" while staring
    # straight at it. Measured flip delta there: 68; threshold 25.
    #
    # The pool's appearance is whatever the previous run left behind, and
    # a drop edge cannot fire from a dark base. Normalize to light first;
    # this pre-flip is never stamped.
    for udid in "${UDIDS[@]}"; do
        xcrun simctl ui "$udid" appearance light
    done
    sleep 2
    i=0
    local luma seen base
    for udid in "${UDIDS[@]}"; do
        xcrun simctl io "$udid" screenshot "$REC_ROOT/.flip-probe.png" >/dev/null 2>&1 || true
        base=$(ffprobe -v quiet -f lavfi "movie=$REC_ROOT/.flip-probe.png,signalstats" \
            -show_entries frame_tags=lavfi.signalstats.YAVG -of csv=p=0 2>/dev/null \
            | head -1 | cut -d. -f1)
        [ -n "$base" ] || base=175
        xcrun simctl ui "$udid" appearance dark
        seen=0
        for _ in $(seq 1 50); do
            xcrun simctl io "$udid" screenshot "$REC_ROOT/.flip-probe.png" >/dev/null 2>&1 || true
            luma=$(ffprobe -v quiet -f lavfi "movie=$REC_ROOT/.flip-probe.png,signalstats" \
                -show_entries frame_tags=lavfi.signalstats.YAVG -of csv=p=0 2>/dev/null \
                | head -1 | cut -d. -f1)
            if [ -n "$luma" ] && [ "$luma" -le $((base - 25)) ]; then
                seen=1
                break
            fi
            sleep 0.2
        done
        if [ "$seen" = 0 ]; then
            echo "recording: dark fiducial never rendered on device $i (base $base, last ${luma:-none})" >&2
            exit 1
        fi
        T_MARKS[i]=$(date +%s%3N)
        echo "${T_MARKS[$i]}" >"$REC_ROOT/t_mark-$i"
        i=$((i + 1))
    done
    # The flip BACK is a second fiducial, stamped the same way: a
    # recorder that attaches mid-flip produces a film that OPENS dark, so
    # the dark EDGE is not in it at all. With both edges stamped,
    # extraction anchors on whichever edge the film contains.
    i=0
    for udid in "${UDIDS[@]}"; do
        xcrun simctl io "$udid" screenshot "$REC_ROOT/.flip-probe.png" >/dev/null 2>&1 || true
        base=$(ffprobe -v quiet -f lavfi "movie=$REC_ROOT/.flip-probe.png,signalstats" \
            -show_entries frame_tags=lavfi.signalstats.YAVG -of csv=p=0 2>/dev/null \
            | head -1 | cut -d. -f1)
        [ -n "$base" ] || base=107
        xcrun simctl ui "$udid" appearance light
        seen=0
        for _ in $(seq 1 50); do
            xcrun simctl io "$udid" screenshot "$REC_ROOT/.flip-probe.png" >/dev/null 2>&1 || true
            luma=$(ffprobe -v quiet -f lavfi "movie=$REC_ROOT/.flip-probe.png,signalstats" \
                -show_entries frame_tags=lavfi.signalstats.YAVG -of csv=p=0 2>/dev/null \
                | head -1 | cut -d. -f1)
            if [ -n "$luma" ] && [ "$luma" -ge $((base + 25)) ]; then
                seen=1
                break
            fi
            sleep 0.2
        done
        if [ "$seen" = 0 ]; then
            echo "recording: light fiducial never rendered on device $i (base $base, last ${luma:-none})" >&2
            exit 1
        fi
        L_MARKS[i]=$(date +%s%3N)
        echo "${L_MARKS[$i]}" >"$REC_ROOT/l_mark-$i"
        i=$((i + 1))
    done
    sleep 1
    rm -f "$REC_ROOT/.flip-probe.png"
}

rec_suite_stop() {
    [ -n "${KAYA_RECORD:-}" ] || return 0
    # simctl itself must receive the SIGINT to finalize each file, and
    # the xcrun wrapper does not forward signals — hit the children
    # first, then the wrapper, bounded.
    local pid i
    for pid in "${REC_PIDS[@]}"; do
        pkill -INT -P "$pid" 2>/dev/null || true
        kill -INT "$pid" 2>/dev/null || true
    done
    for pid in "${REC_PIDS[@]}"; do
        for _ in $(seq 1 40); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.5
        done
        wait "$pid" 2>/dev/null || true
    done
    # Locate each device's appearance-flip fiducial. Both edges were
    # stamped when they became VISIBLE, and both are EDGES, not levels:
    # the home screen's icon load moves the absolute luma of "dark" run
    # to run (107 measured, over any fixed threshold, while the flip's
    # drop stayed a clean 68). Anchor on whichever edge the film
    # contains. Boot and install churn is bright-to-bright and crosses
    # neither threshold.
    # The reader takes what it needs but DRAINS the whole stream: head -1
    # would SIGPIPE ffprobe, which set -o pipefail turns fatal.
    local ANCHORS=()
    local t_flip
    i=0
    while [ "$i" -lt "${#UDIDS[@]}" ]; do
        t_flip=$(ffprobe -v quiet -f lavfi \
            "movie=$REC_ROOT/suite-$i.mov,select=gt(scene\,0.3),signalstats" \
            -show_entries frame=pts_time:frame_tags=lavfi.signalstats.YAVG \
            -of csv=p=0 2>/dev/null \
            | KAYA_DIR=down python3 -c '
import os, sys
# The first frame whose average luma steps by 25 in the wanted
# direction; its presentation time in ms is the fiducial edge.
down = os.environ["KAYA_DIR"] == "down"
prev = None
for line in sys.stdin:
    parts = line.strip().split(",")
    if len(parts) < 2:
        continue
    try:
        pts, luma = float(parts[0]), float(parts[1])
    except ValueError:
        continue
    if prev is not None and ((luma <= prev - 25) if down else (luma >= prev + 25)):
        print(int(pts * 1000))
        break
    prev = luma')
        if [ -n "$t_flip" ]; then
            ANCHORS[i]=$(( ${T_MARKS[$i]} - t_flip ))
        else
            t_flip=$(ffprobe -v quiet -f lavfi \
                "movie=$REC_ROOT/suite-$i.mov,select=gt(scene\,0.3),signalstats" \
                -show_entries frame=pts_time:frame_tags=lavfi.signalstats.YAVG \
                -of csv=p=0 2>/dev/null \
            | KAYA_DIR=up python3 -c '
import os, sys
# The first frame whose average luma steps by 25 in the wanted
# direction; its presentation time in ms is the fiducial edge.
down = os.environ["KAYA_DIR"] == "down"
prev = None
for line in sys.stdin:
    parts = line.strip().split(",")
    if len(parts) < 2:
        continue
    try:
        pts, luma = float(parts[0]), float(parts[1])
    except ValueError:
        continue
    if prev is not None and ((luma <= prev - 25) if down else (luma >= prev + 25)):
        print(int(pts * 1000))
        break
    prev = luma')
            [ -n "$t_flip" ] || { echo "recording: no fiducial edge in suite-$i.mov"; return 1; }
            ANCHORS[i]=$(( ${L_MARKS[$i]} - t_flip ))
        fi
        echo "${ANCHORS[$i]}" >"$REC_ROOT/anchor-$i"
        i=$((i + 1))
    done
    # Each leg extracts from the film of the simulator it ran on.
    local dir failed=0 slot
    local pids=()
    for dir in "$REC_ROOT"/*/; do
        [ -f "$dir/leg.log" ] || continue
        [ "$(cat "$dir/run" 2>/dev/null)" = "$REC_RUN" ] || continue
        slot=$(cat "$dir/sim" 2>/dev/null || echo 0)
        (
            "$ROOT/tools/harness-extract.sh" "$REC_ROOT/suite-$slot.mov" \
                "$dir/leg.log" "${ANCHORS[$slot]}" "$dir/steps" \
                >"$dir/extract.log" 2>&1 \
                || : >"$dir/extract-failed"
        ) &
        pids+=($!)
    done
    [ ${#pids[@]} -eq 0 ] || wait "${pids[@]}" 2>/dev/null || true
    for dir in "$REC_ROOT"/*/; do
        [ -f "$dir/extract.log" ] || continue
        [ "$(cat "$dir/run" 2>/dev/null)" = "$REC_RUN" ] || continue
        cat "$dir/extract.log"
        [ ! -e "$dir/extract-failed" ] || failed=1
    done
    [ "$failed" = 0 ] || { echo "recording: extraction failures above"; return 1; }
}

rec_start() {
    [ -n "${KAYA_RECORD:-}" ] || return 0
    REC_DIR="$ROOT/target/recordings/ios/$1"
    mkdir -p "$REC_DIR"
    # Which simulator's film covers this leg, and which run recorded
    # it (extraction takes only this run's legs — see rec_suite_start).
    echo "${2:-0}" >"$REC_DIR/sim"
    printf '%s\n' "$REC_RUN" >"$REC_DIR/run"
}

rec_finish() {
    [ -n "${KAYA_RECORD:-}" ] || return 0
    # The transcript's own epoch line anchors the leg inside its
    # simulator's recording; nothing to measure here.
    printf '%s\n' "$1" >"$REC_DIR/leg.log"
}

# THE CLIPBOARD SCENE'S FOREIGN SIDE, ON THE HOST. iOS has no child
# processes, so the interpreter cannot run the foreign tools the mac arm
# runs, and an app reading its own writes cannot fail for the reason the
# scene exists. The seed and the foreign read are answered here, over
# the same two files the picker verbs use, payloads base64'd because the
# request line is word-split below.
#
# Every rule below was measured (docs/clipboard-plan.md §8):
#   - BOTH DIRECTIONS ARE A SPAWNED PROCESS, not a tool
#     (tools/ios/clipctl). `simctl pbpaste` reads a union clip as empty
#     and `pbsync <device> host` drops app-defined types; `simctl
#     pbcopy` is text-only and `pbsync host <device>` exits rc=0 while
#     delivery is still in flight (§8 finding 6), besides transiting the
#     ONE macOS pasteboard this lane must never touch.
#   - `simctl` writes its "unhandled Platform key" warnings to STDERR,
#     so every capture here drops it.

# base64 in and out, in python3 — the repo's rule for text processing,
# and the spelling that cannot line-wrap a long payload into several
# tokens.
clip_decode() { # b64 -> bytes on stdout
    python3 -c 'import base64, sys
sys.stdout.buffer.write(base64.b64decode(sys.argv[1]))' "$1"
}

clip_encode() { # bytes on stdin -> one base64 token on stdout
    python3 -c 'import base64, sys
sys.stdout.write(base64.b64encode(sys.stdin.buffer.read()).decode())'
}

# The process that HOSTS the paste alert, resolved per call and cached
# per device: the alert is SpringBoard's, and SpringBoard's own tree is
# the one place it is ALWAYS readable — the hit-test route goes blind
# exactly when the alert was raised by the foreground app's own blocked
# read.
clip_sb_pid() { # udid -> pid (0 when unresolved, which press tolerates)
    local udid="$1" pid
    local cache="$LEGS_DIR/sb-pid-$udid"
    if [ -f "$cache" ]; then
        cat "$cache"
        return 0
    fi
    pid=$(xcrun simctl spawn "$udid" launchctl list 2>/dev/null \
        | grep -F "com.apple.SpringBoard" | head -1 | cut -f1)
    echo "${pid:-0}" | tee "$cache"
}

# Answer the per-clip paste prompt, or report that there was none — an
# own-content read never raises one, so "none" is an answer.
#
# The press verb searches the hit-test overlay AND SpringBoard's tree
# each try, refuses to tap a button whose frame is still animating, and
# FAILS when nothing carries the label, which is this function's "no
# alert" signal. Pressed again until that failure, because the alert
# leaving the screen is the only proof a tap landed.
clip_press() { # udid -> pressed | none
    local udid="$1" sb i did=0
    sb=$(clip_sb_pid "$udid")
    for i in 1 2 3 4 5 6; do
        if ! timeout 60 "$SIMDRIVE" "$udid" "$sb" press Allow Paste >/dev/null 2>&1; then
            if [ "$did" = 1 ]; then
                echo pressed
            else
                echo none
            fi
            return 0
        fi
        did=1
    done
    echo "the paste alert is still up after 6 presses" >&2
    return 1
}

# Put content on the device clipboard FROM OUTSIDE the guest: a
# spawned writer on the DEVICE, one item, replacing the board. `kind`
# is a bare token; the payload rides base64 and is the literal content
# for text/html, or an ALREADY-EXPANDED absolute path for image/files.
#
# THE HOST PASTEBOARD IS NOT IN THIS PATH, deliberately: `pbsync host
# <device>` exits rc=0 while DELIVERY IS STILL IN FLIGHT, so the guest's
# read snapshots the board mid-replacement and answers empty
# (docs/clipboard-plan.md §8 finding 6). The spawned write is
# synchronous and visible to other processes before the spawn exits, and
# it keeps the ONE macOS pasteboard out of a lane that runs beside
# validate-mac's clipboard legs. check-steps' iOS clause pins the
# absence.
#
# Custom formats are not seedable, here as everywhere: no stock tool
# writes an app-defined type, and a helper kaya wrote would be foreign
# in name only.
clip_seed() { # udid kind b64 -> ok
    local udid="$1" kind="$2" payload path
    case "$kind" in
        text | html)
            payload="$3"
            ;;
        image)
            # The watcher reads the container file (a real host path)
            # and hands clipctl the BYTES: the write must not depend on
            # the spawned process's own sandbox seeing the path.
            path=$(clip_decode "$3")
            if [ ! -f "$path" ]; then
                echo "the image seed's file is missing: $path" >&2
                return 1
            fi
            payload=$(clip_encode <"$path")
            ;;
        files)
            # The PATH itself is the payload: the container path is the
            # same string on the host and inside the simulator, and the
            # file-url item must carry the url, not the bytes.
            path=$(clip_decode "$3")
            if [ ! -f "$path" ]; then
                echo "the files seed's file is missing: $path" >&2
                return 1
            fi
            payload="$3"
            ;;
        *)
            echo "clipboard_seed cannot write $kind from outside the app" >&2
            return 1
            ;;
    esac
    # THE WRITER IS HELD ALIVE: the pasteboard daemon serves item DATA
    # by fetching it from the setter, and a writer that exits at once
    # intermittently leaves a reader empty (measured 1-in-5 solo for the
    # png; §8 finding 6). Each seed kills the previous holder.
    local holder_file="$LEGS_DIR/seed-holder-$udid"
    local seed_log="$LEGS_DIR/seed-$udid.out"
    if [ -f "$holder_file" ]; then
        kill "$(cat "$holder_file")" 2>/dev/null || true
        rm -f "$holder_file"
    fi
    : >"$seed_log"
    timeout 600 xcrun simctl spawn "$udid" "$CLIPCTL" write "$kind" "$payload" hold \
        >"$seed_log" 2>/dev/null &
    echo "$!" >"$holder_file"
    # The W line is the writer saying the board is written; the hold
    # begins after it. No line inside the bound is a failed write.
    local waited=0
    while ! grep -q "^W types=" "$seed_log"; do
        waited=$((waited + 1))
        if [ "$waited" -gt 100 ]; then
            echo "the spawned $kind seed never reported its write on $udid" >&2
            return 1
        fi
        sleep 0.1
    done
    echo ok
}

# Read the device clipboard back FROM OUTSIDE the guest, in one
# representation, and answer what expect_clipboard compares: the content
# for text/html/custom, WxH for an image, newline-joined basenames for
# files, empty when the board does not carry the kind.
clip_read() { # udid b64-kind -> b64 answer
    local udid="$1" kind log png b64 tries=0
    kind=$(clip_decode "$2")
    if [ -z "$kind" ]; then
        echo "clip_read needs a kind" >&2
        return 1
    fi
    # Named for the DEVICE: a leg holds its simulator for its whole
    # duration, so this cannot collide with another leg's read.
    log="$LEGS_DIR/clipread-$udid.out"
    # THE READ RUNS IN THE BACKGROUND because it does not return until
    # the prompt is answered, and the thing that answers it is the press
    # below — a foreground read would deadlock against its own remedy.
    timeout 25 xcrun simctl spawn "$udid" "$CLIPCTL" read "$kind" >"$log" 2>/dev/null &
    local reader=$!
    # 0.3s between press rounds, not 1s (2026-08-20): the reader
    # returns the moment the Allow lands, so the sleep's only job is
    # pacing the next press attempt — at 1s every prompted read paid
    # most of a second of pure wait after the press had already
    # worked, across three ~75s whale legs.
    while kill -0 "$reader" 2>/dev/null && [ "$tries" -lt 20 ]; do
        clip_press "$udid" >/dev/null || true
        tries=$((tries + 1))
        sleep 0.3
    done
    wait "$reader" 2>/dev/null || true
    if ! grep -q "^S " "$log"; then
        echo "the spawned reader answered nothing at all: $(head -3 "$log")" >&2
        return 1
    fi
    # THE MISSING LINE IS THE DIAGNOSIS. A kind the board does not carry
    # still prints an EMPTY `S b64=`; no line at all means the read never
    # returned, which is an unanswered prompt and not an empty
    # clipboard.
    if ! grep -q "^S b64=" "$log"; then
        echo "the $kind read never returned after $tries presses — the paste prompt" \
            "went unanswered; the board offered $(grep "^S types=" "$log")" >&2
        return 1
    fi
    b64=$(grep -m1 "^S b64=" "$log" | cut -d= -f2-)
    case "$kind" in
        image)
            # TWO OF APPLE'S TOOLS, the mac arm's own answer: the bytes
            # are written out and `sips` reports the DECODED SIZE. WxH
            # rather than a byte count, because every host re-encodes
            # freely and one picture would count differently per lane.
            if [ -z "$b64" ]; then
                return 0
            fi
            png="$LEGS_DIR/clipread-$udid.png"
            clip_decode "$b64" >"$png"
            sips -g pixelWidth -g pixelHeight "$png" 2>/dev/null | python3 -c 'import re, sys
size = dict(re.findall(r"^\s+(pixelWidth|pixelHeight):\s*(\d+)", sys.stdin.read(), re.M))
sys.stdout.write(size["pixelWidth"] + "x" + size["pixelHeight"] if len(size) == 2 else "")' \
                | clip_encode
            ;;
        files)
            # BASENAMES, never paths: the expected string is compared
            # byte for byte across lanes whose containers are at
            # different paths.
            clip_decode "$b64" | python3 -c 'import os, sys, urllib.parse
names = [os.path.basename(urllib.parse.unquote(urllib.parse.urlparse(line).path.rstrip("/")))
         for line in sys.stdin.read().splitlines() if line]
sys.stdout.write("\n".join(names))' | clip_encode
            ;;
        *)
            # text, html and any custom id ARE their own answer, so the
            # reader's base64 rides through untouched — one fewer decode
            # to be byte-exact about.
            printf '%s' "$b64"
            ;;
    esac
}

# THE DEVICE PASTEBOARD IS NOT ALWAYS THE DEVICE'S. Simulator.app's
# Edit > Automatically Sync Pasteboard is ON BY DEFAULT
# (`PasteboardAutomaticSync` in com.apple.iphonesimulator) and RELAYS
# the macOS pasteboard into and out of every booted simulator —
# measured 2026-08-03: a host `pbcopy` replaced a booted device's clip
# in 260ms, and two booted devices ground each other's clips down to one
# shared board. §8 finding 5's "strictly per-device" holds only while
# that app is not running.
#
# So MEASURE IT, before any leg, on the two devices this lane booted. A
# pref read would not do: a running Simulator.app ignores a `defaults
# write` (measured), so the pref can say NO while the relay is live. Two
# devices, two different clips, each keeping its own — types only, which
# is prompt-free at every stage (§8 finding 2). And no host pasteboard:
# this lane must never write the board the mac lane is using.
clip_relay_check() { # udid_a udid_b -> 0 when the boards are separate
    local a="$1" b="$2" i seen_a seen_b shared
    timeout 60 xcrun simctl spawn "$a" "$CLIPCTL" write html \
        "$(printf '%s' '<b>kaya relay check</b>' | clip_encode)" >/dev/null 2>&1
    timeout 60 xcrun simctl spawn "$b" "$CLIPCTL" write text \
        "$(printf '%s' 'kaya relay check' | clip_encode)" >/dev/null 2>&1
    # The relay is FAST (260ms), so a look a second later is decisive;
    # three is slack for a loaded machine. Device A wrote first, so
    # last-writer-wins leaves A carrying B's text: A LOSING html and B
    # GAINING it are two independent tells of a shared board.
    for i in 1 2 3; do
        sleep 1
        seen_a=$(timeout 60 xcrun simctl spawn "$a" "$CLIPCTL" 2>/dev/null | grep -m1 '^S types=')
        seen_b=$(timeout 60 xcrun simctl spawn "$b" "$CLIPCTL" 2>/dev/null | grep -m1 '^S types=')
        if [ -z "$seen_a" ] || [ -z "$seen_b" ]; then
            # A device that did not answer is not a verdict either way.
            continue
        fi
        shared=0
        case "$seen_a" in
            *public.html*) ;;
            *) shared=1 ;;
        esac
        case "$seen_b" in
            *public.html*) shared=1 ;;
        esac
        if [ "$shared" = 0 ]; then
            continue
        fi
        echo "the simulator clipboards are NOT separate boards:" >&2
        echo "  $a offers $seen_a" >&2
        echo "  $b offers $seen_b" >&2
        echo "Simulator.app is relaying the macOS pasteboard into every booted" >&2
        echo "simulator (Edit > Automatically Sync Pasteboard, on by default)." >&2
        echo "The clipboard legs cannot run against a board the mac lane" >&2
        echo "rewrites throughout the matrix. Quit Simulator.app — this lane" >&2
        echo "boots its devices headless with simctl and never needs it — or" >&2
        echo "turn that menu item off, or run" >&2
        echo "  defaults write com.apple.iphonesimulator PasteboardAutomaticSync -bool NO" >&2
        echo "and RELAUNCH it: a running Simulator.app reads that pref only at" >&2
        echo "launch. Then re-run." >&2
        return 1
    done
    if [ -z "$seen_a" ] || [ -z "$seen_b" ]; then
        echo "the relay check could not read a clipboard on $a / $b" >&2
        return 1
    fi
    return 0
}

# THE FIRST PICKER A DEVICE SHOWS AFTER A BOOT OPENS IN THE WRONG
# DIRECTORY (docs/traps.md), and this is the warm-up in front of that.
# The app's reveal races DocumentManager's own default-location
# strategy, whose `getSaveLocation` answer is the app's container root,
# and whichever lands LAST wins. Measured 2026-08-03 over ten leg runs:
#
#   device state          getSaveLocation   reveal   outcome
#   first picker on boot        708ms        381ms   the ROOT, every time
#   any picker after that       160ms        297ms   the asked-for directory
#
# It is neither the harness nor the guest — `file_choose` then refuses a
# row that is genuinely not there — and it is NOT Simulator.app: a cold
# device fails identically with the app running, a warm one passes
# headless.
#
# So WARM THE STACK before any leg with the system's own Files app, the
# same DocumentManager and file provider the picker uses. The device
# says when it is done: `com.apple.FileProvider` carries no pid until
# something on that boot has used the document stack.
doc_daemon_pid() { # udid -> the file provider daemon's pid, empty when down
    xcrun simctl spawn "$1" launchctl list 2>/dev/null | python3 -c '
import sys
for line in sys.stdin:
    parts = line.rstrip("\n").split("\t")
    if len(parts) >= 3 and parts[2] == "com.apple.FileProvider" and parts[0].isdigit():
        sys.stdout.write(parts[0])
        break
'
}

picker_warm() { # udid -> 0 when this device can aim a picker
    local udid="$1" i
    if [ -n "$(doc_daemon_pid "$udid")" ]; then
        return 0
    fi
    if ! timeout 60 xcrun simctl launch "$udid" com.apple.DocumentsApp >/dev/null 2>&1; then
        echo "the stock Files app would not launch on $udid — this lane warms the" >&2
        echo "document stack with it so the filedialog scene's first picker opens" >&2
        echo "where it was aimed (docs/traps.md). Check the runtime has" >&2
        echo "com.apple.DocumentsApp: xcrun simctl listapps $udid" >&2
        return 1
    fi
    for i in $(seq 1 80); do
        if [ -n "$(doc_daemon_pid "$udid")" ]; then
            break
        fi
        sleep 0.25
    done
    if [ -z "$(doc_daemon_pid "$udid")" ]; then
        echo "the file provider daemon never came up on $udid after launching Files" >&2
        return 1
    fi
    # The daemon answering is the edge; the local-storage tree fills in
    # behind it and nothing on the host can watch that. Measured: the
    # resolution the picker waits on drops 708ms -> 294ms across this
    # pause, which is what puts the reveal back in front of it.
    sleep 3
    timeout 60 xcrun simctl terminate "$udid" com.apple.DocumentsApp >/dev/null 2>&1 || true
    return 0
}

# The clipboard verbs, dispatched off the request line's first token.
clip_verb() { # udid verb args...
    local udid="$1" verb="$2"
    case "$verb" in
        clip_seed) clip_seed "$udid" "${3:-}" "${4:-}" ;;
        clip_read) clip_read "$udid" "${3:-}" ;;
        clip_press) clip_press "$udid" ;;
        *)
            echo "unknown clipboard verb $verb" >&2
            return 1
            ;;
    esac
}

# Answer the guest's simdrive requests for the life of one leg.
#
# The protocol is two files: the guest writes `kaya-simdrive-request`
# holding one verb, this writes `kaya-simdrive-response` whose FIRST
# LINE is ok/err and whose TRAILING NEWLINE IS THE COMMIT, written last,
# so a guest reading mid-write keeps waiting rather than acting on half
# an answer.
#
# The app's pid is resolved per request rather than once: simdrive needs
# it to tell the picker's process from the app's, and the app is
# launched after this starts. The clipboard verbs need no pid.
simdrive_watch() { # udid bundle_id documents_dir
    local udid="$1" bundle_id="$2" dir="$3"
    local request="$dir/kaya-simdrive-request" response="$dir/kaya-simdrive-response"
    mkdir -p "$dir"
    rm -f "$request" "$response"
    while :; do
        if [ -f "$request" ]; then
            local verb
            verb=$(cat "$request" 2>/dev/null)
            rm -f "$request"
            # CAPTURED WITH `|| rc=$?`, NOT `rc=$?` ON THE NEXT LINE:
            # under `set -e` a failing command substitution kills the
            # watcher before the next line runs, which made the err
            # branch below unreachable.
            local pid body rc=0
            case "$verb" in
                clip_*)
                    # shellcheck disable=SC2086
                    body=$(clip_verb "$udid" $verb 2>&1) || rc=$?
                    ;;
                *)
                    pid=$(xcrun simctl spawn "$udid" launchctl list 2>/dev/null \
                        | grep -F "$bundle_id" | head -1 | cut -f1)
                    # shellcheck disable=SC2086
                    body=$("$SIMDRIVE" "$udid" "${pid:-0}" $verb 2>&1) || rc=$?
                    ;;
            esac
            # Written aside and RENAMED: rename is atomic, so the
            # guest either sees no response or a whole one. Polling a
            # file being written is exactly how a harness reads half an
            # answer and acts on it.
            if [ "$rc" -eq 0 ]; then
                printf 'ok\n%s\n' "$body" >"$response.part"
            else
                printf 'err\n%s\n' "$body" >"$response.part"
            fi
            mv -f "$response.part" "$response"
        fi
        sleep 0.05
    done
}

# DROP ONE STEP, not a suffix — the cut's sibling, for a step out of
# reach on this host while everything AFTER it is expressible. Exactly
# one `identity` step reads the declared NAME off an AUXILIARY window,
# and this host has none (the core rejects create_window by capability
# and the guest asks rather than testing the platform), while the icon
# reads and the live-widget round trip below it are expressible.
#
# THE SAME TWO GUARDS THE CUT CARRIES: a drop that matches no step is
# STALE, and the `keep` verbs name the assertions the drop may not take
# with it. A green leg still SAYS what it declined.
#
# NAMED BY VERB AND TARGET, never by the whole line: the line carries
# the declared NAME, and retyping a declared value in a runner is the
# second source of truth guests/assets/identity.toml exists to prevent.
scene_script_drop() { # scene verb target keep-verb...
    python3 - "$ROOT/tools/scenes/$1.steps" "$2" "$3" "${@:4}" <<'PY'
import pathlib
import sys

path, verb, target = sys.argv[1], sys.argv[2], sys.argv[3]
keeps = sys.argv[4:]
if not keeps:
    sys.exit(f"run-sim: dropping `{verb} {target}` from {path} with no `keep` "
             f"verb — say which assertions this drop may not take with it, or "
             f"the leg can be trimmed until it asserts nothing")
lines = [" ".join(line.split()) for line in pathlib.Path(path).read_text().splitlines()
         if line.strip() and not line.lstrip().startswith("#")]
hits = [i for i, line in enumerate(lines) if line.split()[:2] == [verb, target]]
if len(hits) != 1:
    sys.exit(f"run-sim: {path} has {len(hits)} `{verb} {target}` steps and this "
             f"lane drops exactly one — the scene was reshaped and nobody "
             f"re-read what the phone can express. Fix the leg, do not widen "
             f"the drop.")
kept = lines[:hits[0]] + lines[hits[0] + 1:]


def asserted(seq, v):
    """The distinct `v` steps in seq, whitespace-normalized."""
    return {line for line in seq if line.split()[:1] == [v]}


for v in keeps:
    whole, survived = asserted(lines, v), asserted(kept, v)
    if not survived:
        sys.exit(f"run-sim: dropping `{verb} {target}` from {path} leaves no "
                 f"`{v}` step at all — the leg would pass without asserting the "
                 f"thing it exists for")
    if survived != whole:
        sys.exit(f"run-sim: dropping `{verb} {target}` from {path} takes "
                 f"{sorted(whole - survived)} — the drop may not take an "
                 f"assertion of `{v}` with it")
print(f"run-sim: NOT RUN on this host (no auxiliary windows): {lines[hits[0]]}",
      file=sys.stderr)
print("\n".join(kept))
PY
}

# Rust entrypoint + SwiftUI backend legs: install the bundle (with the
# embedded dylib) on the claimed simulator and launch with the scene
# script from the environment.
run_swiftui_on() {
    local udid="$1" slot="$2" app="$3" bundle_id="$4" name="$5" selftest="$6" scene="$7"
    # Optional 8th argument: extra steps appended to the shared scene
    # for THIS leg only. The scene file stays byte-frozen and shared
    # verbatim; this is how a leg asserts something only true on its own
    # device (the iPad's form factor).
    local extra="${8:-}"
    # Optional 9th/10th arguments: THE PHONE-EXPRESSIBLE PREFIX — the cut
    # VERB this host cannot express, and the verb whose assertions the
    # cut may not take with it.
    #
    # This runner declines WHOLE scenes for the same reason and says so
    # at the top of the file: `split` drives resize_window and a phone
    # does not command its own window size, `panels` drives create_window
    # and this host rejects it by capability. `dirty` is desktop-only in
    # its TAIL alone — its last six steps hang off a chrome close, and on
    # iOS the whole close grammar is inside `#if os(macOS)`. An
    # all-or-nothing carve-out would leave D4's iOS arm asserted by
    # nobody, and a phone-safe sibling scene would mint a cross-lane
    # obligation mid-fan-out (check-steps' wired()). This keeps the
    # shared file byte-frozen, and the steps this lane did not run are
    # PRINTED.
    #
    # THE TWO WAYS THIS COULD GO QUIET, BOTH REFUSED BELOW: the cut verb
    # leaving the scene (the cut is then stale), and the cut swallowing
    # the very assertion the leg exists for. The second is not
    # hypothetical — cut this scene one step earlier, at `click
    # button#0`, and the prefix asserts `dirty false` and never
    # `dirty true`.
    local cut="${9:-}" keep="${10:-}"
    # The 11th and 12th: THE ONE STEP THIS HOST CANNOT EXPRESS while
    # everything after it can (scene_script_drop above). Mutually
    # exclusive with the cut, and the same `keep` guard holds it.
    local drop_verb="${11:-}" drop_target="${12:-}"
    if [ -n "$cut" ] && [ -n "$drop_verb" ]; then
        echo "run-sim: $name asks for both a cut at \`$cut\` and a drop of" \
            "\`$drop_verb $drop_target\` — pick one" >&2
        return 1
    fi
    xcrun simctl install "$udid" "$app"
    local container
    container=$(xcrun simctl get_app_container "$udid" "$bundle_id" app)
    rec_start "$name" "$slot"
    local script
    if [ -n "$cut" ]; then
        script=$(python3 - "$ROOT/tools/scenes/$scene.steps" "$cut" "$keep" <<'PY'
import pathlib
import sys

path, cut, keep = sys.argv[1], sys.argv[2], sys.argv[3]
# A CUT WITHOUT A `keep` IS AN UNGUARDED CUT: naming what the cut may
# not take is the price of cutting at all. A LIST, because one scene's
# tail can be below more than one thing the leg exists to assert.
keeps = keep.split()
if not keeps:
    sys.exit(f"run-sim: cutting {path} at `{cut}` with no `keep` verb — say "
             f"which assertions this cut may not take with it, or the leg "
             f"can be trimmed until it asserts nothing")
lines = [line for line in pathlib.Path(path).read_text().splitlines()
         if not line.lstrip().startswith("#")]
verbs = [(line.split() or [""])[0] for line in lines]
if cut not in verbs:
    sys.exit(f"run-sim: {path} has no `{cut}` step, so this lane's cut is "
             f"stale — the scene was reshaped and nobody re-read what the "
             f"phone can express. Fix the leg, do not widen the cut.")
at = verbs.index(cut)
prefix, dropped = lines[:at], lines[at:]


def asserted(seq, verb):
    """The distinct `verb` steps in seq, whitespace-normalized."""
    return {" ".join(line.split()) for line in seq
            if (line.split() or [""])[0] == verb}


for verb in keeps:
    whole, kept = asserted(lines, verb), asserted(prefix, verb)
    if not kept:
        sys.exit(f"run-sim: cutting {path} at `{cut}` leaves no `{verb}` step "
                 f"at all — the leg would pass without asserting the thing it "
                 f"exists for")
    if kept != whole:
        sys.exit(f"run-sim: cutting {path} at `{cut}` drops "
                 f"{sorted(whole - kept)} — the cut may not take an assertion "
                 f"of `{verb}` with it")
print("\n".join(f"run-sim: NOT RUN on this host (after `{cut}`): {line}"
                for line in dropped if line.strip()), file=sys.stderr)
print("\n".join(prefix))
PY
        ) || return 1
    elif [ -n "$drop_verb" ]; then
        script=$(scene_script_drop "$scene" "$drop_verb" "$drop_target" $keep) \
            || return 1
    else
        script=$(grep -v '^#' "$ROOT/tools/scenes/$scene.steps")
    fi
    [ -n "$extra" ] && script="$script
$extra"
    # THE HARNESS'S EYES AND HANDS OUTSIDE THIS APP, for two different
    # reasons. iOS's document picker is a remote view controller whose UI
    # belongs to another process and publishes nothing in-process, so its
    # verbs are answered on the HOST by tools/ios/simdrive. The
    # clipboard's foreign seed and read cannot run in-process at all, so
    # they are answered there too. Both meet the guest through files in
    # the app's own data container (docs/traps.md). STARTED PER LEG AND
    # KILLED WITH IT — a watcher outliving its leg would answer the NEXT
    # one's requests against a dead app.
    #
    # `editor` joins the picker half: it opens BOTH pickers, so it needs
    # the same eyes and hands the save leg does, typing verbs included.
    local watcher_pid=""
    if [ "$scene" = filedialog ] || [ "$scene" = clipboard ] || [ "$scene" = save ] \
        || [ "$scene" = editor ]; then
        local data_container
        data_container=$(xcrun simctl get_app_container "$udid" "$bundle_id" data)
        simdrive_watch "$udid" "$bundle_id" "$data_container/Documents" &
        watcher_pid=$!
    fi
    # NO MARK IS STAGED FOR THE GUEST: the identity guest names the mark
    # as an asset and the core resolves it out of THIS BUNDLE'S OWN
    # Resources, which `make_bundle` filled with the whole asset root
    # (docs/assets-plan.md).
    #
    # THE TWO INDEPENDENT COPIES SURVIVE THAT: the bytes the guest
    # declares come from the asset-root copy, and `expect_app_icon`
    # decodes `Resources/$ICON_IN_BUNDLE`, the icon-keys copy make_bundle
    # writes from the manifest. Two files, two steps, held equal by the
    # interpreter — ruling 4's byte-equality check, running where the
    # lane can watch it.
    local out
    out=$(env SIMCTL_CHILD_KAYA_SELFTEST="$selftest" \
        SIMCTL_CHILD_KAYA_SELFTEST_SCRIPT="$script" \
        SIMCTL_CHILD_KAYA_SWIFTUI_LIB="$container/libkaya_swiftui.dylib" \
        timeout 120 xcrun simctl launch --console-pty "$udid" "$bundle_id" 2>&1) || true
    if [ -n "$watcher_pid" ]; then
        kill "$watcher_pid" 2>/dev/null || true
        wait "$watcher_pid" 2>/dev/null || true
    fi
    # The last seed's held writer dies with the leg (clip_seed's
    # holder discipline; the next leg's own copy replaces the board).
    if [ -f "$LEGS_DIR/seed-holder-$udid" ]; then
        kill "$(cat "$LEGS_DIR/seed-holder-$udid")" 2>/dev/null || true
        rm -f "$LEGS_DIR/seed-holder-$udid"
    fi
    printf '%s\n' "$out"
    rec_finish "$out"
    # (NO PER-LEG SCREENSHOT: `--console-pty` returns only when the
    # guest EXITS, so any capture on this line is strictly after
    # teardown and photographs the home screen. `KAYA_RECORD=1` is the
    # visual record — a still at EVERY step, anchored to the harness
    # transcript rather than to a guessed delay.)
    grep -q "KAYA_SELFTEST: OK" <<<"$out"
}

# Legs run in a pool as wide as the simulator pool: each claims a
# device, runs against it, and reports through a verdict file; drain()
# prints in submission order and is the barrier between flavor blocks
# (their builds overwrite shared scratch files a queued leg reads).
LEGS_DIR="$(mktemp -d)"
trap 'rm -rf "$LEGS_DIR" "${PREP_DIR:-}"' EXIT
leg_names=()
leg_pids=()
# The iPad's legs are tracked apart from the phone pool's. If they rode
# leg_pids, a running pad leg would count against the phone pool's
# saturation gate below, throttling the pool it does not use and
# eventually tripping its wedge watchdog.
pad_pids=()

# Count live leg subshells only: recorders and emulators are
# background jobs of this same shell, and a jobs-based gate counts
# them too — with enough of them it deadlocks the queue outright.
running_legs() {
    local n=0 p
    for p in "${leg_pids[@]}"; do
        kill -0 "$p" 2>/dev/null && n=$((n + 1))
    done
    echo "$n"
}

# Join the backgrounded device preparation (the relay check and the
# picker warms — see boot below) before ANY leg claims a device. Inside
# the queue functions rather than at each phase's head so no future
# phase can forget it; idempotent, so forty calls cost one join.
prep_join() {
    [ -n "${PREP_JOINED:-}" ] && return 0
    PREP_JOINED=1
    if [ ${#PREP_PIDS[@]} -gt 0 ]; then
        wait "${PREP_PIDS[@]}" 2>/dev/null || true
    fi
    local f rc
    for f in "$PREP_DIR"/*.rc; do
        rc=$(cat "$f" 2>/dev/null || echo missing)
        if [ "$rc" != 0 ]; then
            echo "run-sim: device preparation failed ($(basename "$f") rc=$rc)" >&2
            return 1
        fi
    done
}

queue_leg() { # fn name args...
    local fn="$1" name="$2"
    shift 2
    prep_join || exit 1
    leg_names+=("$name")
    (
        local slot='' i
        while [ -z "$slot" ]; do
            i=0
            while [ "$i" -lt "${#UDIDS[@]}" ]; do
                if mkdir "$LEGS_DIR/.dev-$i" 2>/dev/null; then
                    slot=$i
                    break
                fi
                i=$((i + 1))
            done
            [ -n "$slot" ] || sleep 0.2
        done
        # Per-leg wall time rides the verdict (the bottleneck-hunt
        # instrumentation, uniform across runners).
        local t0=$SECONDS
        local verdict=FAIL
        if "$fn" "${UDIDS[$slot]}" "$slot" "$@"; then
            verdict=PASS
        fi
        echo $((SECONDS - t0)) >"$LEGS_DIR/$name.secs"
        rmdir "$LEGS_DIR/.dev-$slot" 2>/dev/null
        echo "$verdict" >"$LEGS_DIR/$name.verdict"
    ) >"$LEGS_DIR/$name.log" 2>&1 &
    leg_pids+=($!)
    # Watchdog: a wedged pool must die loudly in minutes, not
    # silently absorb tens of them (the deadlock class this gate once
    # had). No slot freeing for 3 minutes is never legitimate — legs
    # are bounded far tighter.
    local spins=0
    while [ "$(running_legs)" -ge "${#UDIDS[@]}" ]; do
        spins=$((spins + 1))
        if [ "$spins" -gt 900 ]; then
            echo "pool wedged: $(running_legs) legs running, none finishing; queued=${#leg_names[@]}" >&2
            exit 1
        fi
        sleep 0.2
    done
}

# The iPad leg: same verdict/timing protocol as queue_leg, bound to the
# one pad device instead of the phone pool. Recording is suppressed
# because the fiducial scheme indexes films by phone-pool slot and the
# pad has none — the pad leg is a state gate, not a visual record.
queue_pad_leg() { # fn name args...
    local fn="$1" name="$2"
    shift 2
    prep_join || exit 1
    leg_names+=("$name")
    (
        unset KAYA_RECORD
        while ! mkdir "$LEGS_DIR/.dev-pad" 2>/dev/null; do sleep 0.2; done
        local t0=$SECONDS
        local verdict=FAIL
        if "$fn" "$PAD_UDID" pad "$@"; then
            verdict=PASS
        fi
        echo $((SECONDS - t0)) >"$LEGS_DIR/$name.secs"
        rmdir "$LEGS_DIR/.dev-pad" 2>/dev/null
        echo "$verdict" >"$LEGS_DIR/$name.verdict"
    ) >"$LEGS_DIR/$name.log" 2>&1 &
    pad_pids+=($!)
}

drain() {
    if [ ${#leg_pids[@]} -gt 0 ] || [ ${#pad_pids[@]} -gt 0 ]; then
        wait "${leg_pids[@]}" "${pad_pids[@]}" 2>/dev/null || true
    fi
    leg_pids=()
    pad_pids=()
    local name verdict
    for name in "${leg_names[@]}"; do
        verdict=$(cat "$LEGS_DIR/$name.verdict" 2>/dev/null || echo FAIL)
        echo "== $name =="
        cat "$LEGS_DIR/$name.log" 2>/dev/null
        [ "$verdict" = PASS ] || status=1
        echo "$name: $verdict ($(cat "$LEGS_DIR/$name.secs" 2>/dev/null || echo '?')s)"
    done
    leg_names=()
}

status=0
KAYA_T0=$SECONDS
timing() {
    echo "TIMING $1 $((SECONDS - KAYA_T0))s"
    KAYA_T0=$SECONDS
}
# The guests must know they are being filmed: the harness holds its
# window briefly after the last step when recording (see record_linger
# in harness.rs), and a simulator child only sees SIMCTL_CHILD_-prefixed
# variables.
if [ -n "${KAYA_RECORD:-}" ]; then
    export SIMCTL_CHILD_KAYA_RECORD=1
fi
boot_pool
# BEFORE ANY LEG, and on every run: are these devices' clipboards their
# own (clip_relay_check), and has each phone burned the first-picker
# ignores-its-directory boot quirk (picker_warm)? BACKGROUNDED here and
# JOINED IN queue_leg (prep_join) since 2026-08-20: both need only
# booted devices, the build phase that follows needs no devices, and
# serially they sat ~15s on the lane's critical path. A preparation
# failure still fails the lane before any leg runs — just at the first
# queue instead of five seconds in.
PREP_DIR="$(mktemp -d)"
PREP_PIDS=()
(
    clip_relay_check "${UDIDS[0]}" "$PAD_UDID"
    prep_rc=$?
    echo "$prep_rc" >"$PREP_DIR/relay.rc"
) &
PREP_PIDS+=($!)
for udid in "${UDIDS[@]}"; do
    (
        picker_warm "$udid"
        prep_rc=$?
        echo "$prep_rc" >"$PREP_DIR/warm-$udid.rc"
    ) &
    PREP_PIDS+=($!)
done
rec_suite_start
timing boot

SDKROOT_SIM=$(xcrun -sdk iphonesimulator --show-sdk-path)

# Clean slate: bundles are derived artifacts with no history worth
# keeping, and a stale main.swift once put the LAYOUT guest inside the
# milestone2 bundle (same class as the stale-stills trap; the leg
# failed only because the scripts happened to differ).
rm -rf "$BUNDLES"

# The one iOS backend is the SwiftUI interpreter: every bundle embeds
# its dylib, whatever language the guest is written in. Always built
# fresh — a stale interpreter under a new guest is the stale-artifact
# class.
build_swiftui_dylib() {
    mkdir -p "$BUNDLES"
    # Same marker contract as the mac dylib
    # (tools/swiftui/build-dylib.sh), generated here rather than shared
    # so this lane does not depend on the mac lane having run.
    local marker="$BUNDLES/KayaBuildId.swift"
    cat >"$marker" <<EOF
// Generated by tools/ios/run-sim.sh. Do not edit, do not commit.
public let kayaSwiftUIBuildIdMarker = "kaya-build-id:$("$ROOT/tools/build-id.sh" swiftui)"
EOF
    xcrun -sdk iphonesimulator swiftc \
        -emit-library \
        -target "arm64-apple-ios17.0-simulator" \
        -import-objc-header crates/kaya/include/kaya.h \
        -pch-output-dir "$BUNDLES/.pch" \
        swift/KayaSwiftUI.swift swift/KayaSwiftUIEntry.swift "$marker" \
        -framework UIKit -framework Foundation \
        -o "$BUNDLES/libkaya_swiftui_ios.dylib" || return 1
    "$ROOT/tools/build-id.sh" --verify --component swiftui \
        "$BUNDLES/libkaya_swiftui_ios.dylib"
}

if [ "$SUITE" = swift ] || [ "$SUITE" = all ]; then
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --lib
    # Every app bundle below links this archive; verify it once,
    # here, rather than trusting the copies downstream.
    "$ROOT/tools/build-id.sh" --verify \
        target/aarch64-apple-ios-sim/debug/libkaya.a || exit 1
    build_swiftui_dylib
    # With more than one input file, swiftc only allows top-level code
    # in a file named main.swift — each scene stages its own. The
    # per-scene compiles are INDEPENDENT so they pool; legs queue only
    # after every binary exists. The list is explicit: window/panels are
    # desktop-only by design and must not ride $SCENES here.
    # Entries are `scene` or `scene:guest` — the guest defaults to the
    # scene's own name, and names a different one where two scenes
    # share an app. `listdetail:split` is the only such pair today: a
    # scene selects a SCRIPT, never an app, and the split guest is the
    # app both list-detail scenes drive. (`split` itself stays out —
    # it drives resize_window, which this host rejects by design.)
    IOS_SWIFT_SCENES="milestone2 stall entry gallery todos reorder feed grow align layout confirm nav listdetail:split scroll progress select radio grid textarea sections menus commands a11y a11yrows clipboard background undo ranges dirty filedialog save styling toolbar identity assets table"
    # Machine-read by check-steps' wired(), which replaced a bare-name
    # grep that comments and unrelated code satisfied: a scene is wired
    # here IF AND ONLY IF it is in a list above, declared desktop-only,
    # or ledgered below. window/panels drive aux windows and panel
    # chrome no phone has; split drives resize_window, rejected above.
    # shellcheck disable=SC2034  # read by check-steps' wired(), not by this script
    IOS_DESKTOP_ONLY_SCENES="window panels split panes"
    # Scenes whose GUEST cannot run here YET — sequencing, not design:
    # the portfolio dashboard is Python by design
    # (docs/portfolio-plan.md), and CPython reaches this platform with
    # the packaging milestone (official upstream support exists,
    # PEP 730). The legs wire when it lands.
    # shellcheck disable=SC2034  # read by check-steps' wired(), not by this script
    IOS_UNWIRED_SCENES="portfolio"
    # NOT NARROWER any more, except by design: editor runs from the Go
    # suite alone (the plan chose Go so a binding's awkward corners
    # would show; there is no rust or swift editor guest). Everything
    # else in the roster runs from ALL THREE suites — undo, ranges,
    # dirty, filedialog and save graduated into the lists 2026-08-19
    # (plain legs but dirty, which carries the documented chrome-close
    # cut; the simdrive watcher engages per-verb inside run_swiftui_on,
    # so the picker scenes needed no leg-specific plumbing).
    swift_pids=()
    swift_names=()
    for entry in $IOS_SWIFT_SCENES; do
        (
            guest="${entry%%:*}"
            src="${entry##*:}"
            stage="$BUNDLES/.stage-$guest"
            mkdir -p "$stage"
            cp "guests/swift/$src.swift" "$stage/main.swift"
            companions=()
            if [ -f "guests/swift/$src+Kaya.swift" ]; then
                companions=("guests/swift/$src+Kaya.swift")
            fi
            xcrun -sdk iphonesimulator swiftc \
                -target "arm64-apple-ios$IOS_MIN-simulator" \
                -import-objc-header crates/kaya/include/kaya.h \
                -pch-output-dir "$BUNDLES/.pch" \
                bindings/swift/KayaWire.swift bindings/swift/KayaApp.swift \
                bindings/swift/KayaRecords.swift bindings/swift/KayaSums.swift \
                "${companions[@]}" "$stage/main.swift" \
                "$TARGET_DIR/libkaya.a" \
                -framework UIKit -framework Foundation -framework CoreFoundation \
                -framework CoreGraphics -framework QuartzCore \
                -o "$BUNDLES/${guest}swift-bin" >"$stage/build.log" 2>&1
        ) &
        swift_pids+=($!)
        swift_names+=("${entry%%:*}")
    done
    swift_status=0
    i=0
    for pid in "${swift_pids[@]}"; do
        if ! wait "$pid"; then
            echo "swift guest build FAILED: ${swift_names[$i]}" >&2
            cat "$BUNDLES/.stage-${swift_names[$i]}/build.log" >&2
            swift_status=1
        fi
        i=$((i + 1))
    done
    rm -rf "$BUNDLES"/.stage-*
    [ "$swift_status" = 0 ] || exit 1
    # AND EACH BINARY MUST CARRY THE MARKER ITSELF, the Go arm's test one
    # suite down: the id lives in libkaya.a, so it is in this executable
    # only if the archive really was linked in. Write `-L"$TARGET_DIR"
    # -lkaya` here instead and ld64 prefers the .dylib beside it — the
    # bundle then names an absolute build-machine path to a library
    # outside itself, runs anyway because the Simulator shares the host
    # filesystem, and tells nobody.
    for entry in $IOS_SWIFT_SCENES; do
        "$ROOT/tools/build-id.sh" --verify "$BUNDLES/${entry%%:*}swift-bin" || exit 1
    done
    for entry in $IOS_SWIFT_SCENES; do
        guest="${entry%%:*}"
        # THE DECLARED IDENTITY GOES INTO ONE BUNDLE, the one whose guest
        # declares an identity — make_bundle's fourth argument, and the
        # reason it is opt-in is written there.
        ident=""
        if [ "$guest" = identity ]; then ident=identity; fi
        APP=$(make_bundle "${guest}swift" "dev.kaya.${guest}swift" "$BUNDLES/${guest}swift-bin" "$ident")
        cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
        if [ "$guest" = milestone2 ]; then
            queue_leg run_swiftui_on swift "$APP" dev.kaya.milestone2swift swift 1 milestone2
        elif [ "$guest" = identity ]; then
            # ONE STEP IS NOT RUN HERE and the leg prints it:
            # `expect_title window#1` reads the declared NAME off an
            # auxiliary window and this host has none. THE NAME IS STILL
            # DECLARED AND STILL READ here, off the bundle's own
            # CFBundleDisplayName (docs/app-identity-plan.md ruling 3).
            # The keep guard names `expect_app_icon`, so the drop may not
            # take either icon read with it.
            queue_leg run_swiftui_on "$guest-swift" "$APP" "dev.kaya.${guest}swift" \
                "$guest-swift" "$guest" "$guest" "" "" expect_app_icon \
                expect_title "window#1"
        elif [ "$guest" = sections ]; then
            # THE PHONE-EXPRESSIBLE PREFIX (the dirty-cut shape): the
            # sections tail opens an aux window this host rejects by
            # capability, so the leg runs everything above the click
            # that opens it — and the keep guard holds the section
            # asserts above the cut.
            queue_leg run_swiftui_on "$guest-swift" "$APP" "dev.kaya.${guest}swift" "$guest-swift" "$guest" "$guest" "" expect_windows "expect_section expect_section_symbol"
        elif [ "$guest" = dirty ]; then
            # The cut this mechanism was designed around: dirty's last
            # six steps hang off a chrome close and iOS's close grammar
            # is macOS-only; the prefix is D4's iOS arm.
            queue_leg run_swiftui_on "$guest-swift" "$APP" "dev.kaya.${guest}swift" "$guest-swift" "$guest" "$guest" "" close_window expect_dirty
        else
            queue_leg run_swiftui_on "$guest-swift" "$APP" "dev.kaya.${guest}swift" "$guest-swift" "$guest" "$guest"
        fi
    done
    # UNDER `all` THE PHASES INTERLEAVE (2026-08-20): the pool is three
    # devices and the whale legs — clipboard at ~75s each — live one
    # per app family, so draining here queued the whales BEHIND each
    # other and the serialization was the whole matrix's bound. Each
    # family's build still finishes before its legs queue; the next
    # family's build overlaps the pool's work; one drain at the end
    # collects every verdict. A single-suite run and recording mode
    # keep the old serial shape (a film wants its legs in order).
    if [ "$SUITE" = all ] && [ -z "${KAYA_RECORD:-}" ]; then
        timing swift-built+queued
    else
        drain
        timing swift-build+legs
    fi
fi

# The Go guest suite: the same C ABI floor the swift suite reaches. Go
# owns `main` (`-buildmode=exe`), pins it to thread 0 with
# runtime.LockOSThread in the guest's init, and hands that thread to
# kaya_run (guests/go/cmd/main_desktop.go — `!android` reaches iOS,
# which is the point of that tag). No gomobile: `go build` reaches
# ios/arm64 directly (docs/go-mobile-plan.md D1). The binding needed
# only its #cgo lines, because GOOS=ios also satisfies the `darwin` tag
# and was silently answering with the macOS link.
#
# THE SCENE LIST IS THE SWIFT SUITE'S, ENTRY FOR ENTRY: same bundle,
# same embedded interpreter, same transport, same verdict grep, so the
# two are comparable leg for leg — which is how uniform semantics gets
# checked at all (invariant 1).
#
# NOT WIDER: filedialog, ranges, undo and dirty run here from the rust
# example only, and window/panels/split are desktop-only by design. A Go
# leg on any of those would be a sweep, not this depth slice.
#
# AND `editor` IS THE ONE DIVERGENCE: it is a Go app with no Swift guest
# to mirror (docs/editor-plan.md). It rides its own leg block rather
# than $IOS_GO_SCENES because it needs two things the loop cannot pass —
# the simdrive watcher and the phone-expressible cut.
#
# NOT NARROWER, and nothing enforces this: check-steps' wired() keys on
# scene x runner and never on language, so a Go suite that stalled at
# six scenes would leave every gate green. Any future divergence has to
# be written down right here.
if [ "$SUITE" = go ] || [ "$SUITE" = all ]; then
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --lib
    # Every bundle below links this archive; verify it once, here, rather
    # than trusting the copies downstream — the swift suite's rule.
    "$ROOT/tools/build-id.sh" --verify \
        target/aarch64-apple-ios-sim/debug/libkaya.a || exit 1
    build_swiftui_dylib
    # cgo needs a cross compiler. bindings/go/runtime.go's #cgo ios line
    # carries the archive and frameworks; this carries the triple and
    # sysroot. Both ride CC rather than CGO_CFLAGS/CGO_LDFLAGS, because
    # cgo uses CC to LINK as well as compile and -isysroot needs both.
    IOS_GO_CC="$(xcrun -sdk iphonesimulator -f clang) -target arm64-apple-ios$IOS_MIN-simulator -isysroot $SDKROOT_SIM"
    IOS_GO_SCENES="milestone2 stall entry gallery todos reorder feed grow align layout confirm nav listdetail scroll progress select radio grid textarea sections menus commands a11y a11yrows clipboard background undo ranges dirty filedialog save styling toolbar identity assets table"
    # ONE CROSS-BUILD FOR THE WHOLE SUITE. guests/go/cmd is the guest
    # tree's only main package: it imports every scene library and picks
    # one from KAYA_SELFTEST. The bundles still differ — one per scene,
    # each with its own bundle id, because a leg is launched by bundle id
    # — but they all carry a copy of this executable.
    CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC="$IOS_GO_CC" \
        go build -o "$BUNDLES/go-bin" dev.kaya/guests/go/cmd || exit 1
    # AND THE BINARY MUST CARRY THE MARKER ITSELF, this lane's cheapest
    # test that the bundles are SELF-CONTAINED: the id lives in
    # libkaya.a, so it is in this executable only if the archive really
    # was linked in. Point the #cgo line back at `-L… -lkaya` and ld64
    # prefers the .dylib in the same directory — the guest then names an
    # absolute build-machine path to a library outside its bundle, runs
    # anyway because the Simulator shares the host filesystem, and tells
    # nobody.
    "$ROOT/tools/build-id.sh" --verify "$BUNDLES/go-bin" || exit 1
    for guest in $IOS_GO_SCENES; do
        ident=""
        if [ "$guest" = identity ]; then ident=identity; fi
        APP=$(make_bundle "${guest}go" "dev.kaya.${guest}go" "$BUNDLES/go-bin" "$ident")
        cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
        if [ "$guest" = milestone2 ]; then
            queue_leg run_swiftui_on go "$APP" dev.kaya.milestone2go go 1 milestone2
        elif [ "$guest" = identity ]; then
            # The swift leg's drop, verbatim and for its reasons.
            queue_leg run_swiftui_on "$guest-go" "$APP" "dev.kaya.${guest}go" \
                "$guest-go" "$guest" "$guest" "" "" expect_app_icon \
                expect_title "window#1"
        elif [ "$guest" = sections ]; then
            # The same phone-expressible prefix as the swift leg above.
            queue_leg run_swiftui_on "$guest-go" "$APP" "dev.kaya.${guest}go" "$guest-go" "$guest" "$guest" "" expect_windows "expect_section expect_section_symbol"
        elif [ "$guest" = dirty ]; then
            # The swift leg's cut, verbatim and for its reasons.
            queue_leg run_swiftui_on "$guest-go" "$APP" "dev.kaya.${guest}go" "$guest-go" "$guest" "$guest" "" close_window expect_dirty
        else
            queue_leg run_swiftui_on "$guest-go" "$APP" "dev.kaya.${guest}go" "$guest-go" "$guest" "$guest"
        fi
    done
    # THE TEXT EDITOR — kaya's forcing artifact (docs/editor-plan.md),
    # the only script on this lane that drives an APP rather than a
    # feature.
    #
    # OFF THE LOOP ABOVE, for two things the loop cannot pass: the
    # simdrive watcher (this scene opens BOTH pickers) and THE
    # PHONE-EXPRESSIBLE CUT, because the scene's last stretch hangs off a
    # CHROME CLOSE and iOS has none — which is why the whole close
    # grammar in the interpreter sits inside `#if os(macOS)`. The guard
    # in run_swiftui_on holds the cut honest both ways: a verb the scene
    # no longer has is a stale cut, and the cut may not take an
    # `expect_dirty` with it.
    #
    # WHAT THE CUT DOES TAKE: the two unsaved-work refusals and the
    # closing `expect_ax`. The first door (File>New) is inside the
    # prefix, so the alert composition is still exercised; what this lane
    # does not run is the SECOND door, the window's own.
    APP=$(make_bundle editorgo dev.kaya.editorgo "$BUNDLES/go-bin")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on editor-go "$APP" dev.kaya.editorgo editor-go editor editor \
        '' close_window expect_dirty
    # The swift phase's interleave rule, verbatim.
    if [ "$SUITE" = all ] && [ -z "${KAYA_RECORD:-}" ]; then
        timing go-built+queued
    else
        drain
        timing go-build+legs
    fi
fi

if [ "$SUITE" = rust-swiftui ] || [ "$SUITE" = all ]; then
    # Rust entrypoint + SwiftUI backend: the bundle executable is the Rust
    # example's main; kaya::run unconditionally dlopens the
    # SwiftUI dylib embedded in the bundle.
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example milestone2
    build_swiftui_dylib
    APP=$(make_bundle milestone2rs-swiftui dev.kaya.rustswiftui "$TARGET_DIR/examples/milestone2")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on rust-swiftui "$APP" dev.kaya.rustswiftui rust-swiftui 1 milestone2

    # The entry scene against the SwiftUI backend, same embedded dylib.
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example entry
    APP=$(make_bundle entryrs-swiftui dev.kaya.entryswiftui "$TARGET_DIR/examples/entry")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on entry-swiftui "$APP" dev.kaya.entryswiftui entry-swiftui entry entry

    # The todos scene against the SwiftUI backend, same embedded dylib.
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example todos
    APP=$(make_bundle todosrs-swiftui dev.kaya.todosswiftui "$TARGET_DIR/examples/todos")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on todos-swiftui "$APP" dev.kaya.todosswiftui todos-swiftui todos todos

    # The gallery scene against the SwiftUI backend, same embedded dylib.
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example gallery
    APP=$(make_bundle galleryrs-swiftui dev.kaya.galleryswiftui "$TARGET_DIR/examples/gallery")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on gallery-swiftui "$APP" dev.kaya.galleryswiftui gallery-swiftui gallery gallery

    # The reorder scene against the SwiftUI backend, same embedded dylib.
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example reorder
    APP=$(make_bundle reorderrs-swiftui dev.kaya.reorderswiftui "$TARGET_DIR/examples/reorder")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on reorder-swiftui "$APP" dev.kaya.reorderswiftui reorder-swiftui reorder reorder

    # The feed scene against the SwiftUI backend, same embedded dylib.
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example feed
    APP=$(make_bundle feedrs-swiftui dev.kaya.feedswiftui "$TARGET_DIR/examples/feed")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on feed-swiftui "$APP" dev.kaya.feedswiftui feed-swiftui feed feed

    # The layout contract on the SwiftUI interpreter, mirroring the
    # UIKit suite above: grow asserted as shares, layout observed.
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example grow
    APP=$(make_bundle growrs-swiftui dev.kaya.growswiftui "$TARGET_DIR/examples/grow")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on grow-swiftui "$APP" dev.kaya.growswiftui grow-swiftui grow grow

    # The align scene: the cross-axis contract (center + baseline).
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example align
    APP=$(make_bundle alignrs-swiftui dev.kaya.alignswiftui "$TARGET_DIR/examples/align")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on align-swiftui "$APP" dev.kaya.alignswiftui align-swiftui align align

    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example layout
    APP=$(make_bundle layoutrs-swiftui dev.kaya.layoutswiftui "$TARGET_DIR/examples/layout")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on layout-swiftui "$APP" dev.kaya.layoutswiftui layout-swiftui layout layout

    # The stall diagnostic (crates/kaya/src/stall.rs). The watchdog is
    # CORE-SIDE, so this host needs no arm of its own.
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example stall
    APP=$(make_bundle stallrs-swiftui dev.kaya.stallswiftui "$TARGET_DIR/examples/stall")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on stall-swiftui "$APP" dev.kaya.stallswiftui stall-swiftui stall stall

    # The confirm scene: alerts are phone-native (see the swift leg).
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example confirm
    APP=$(make_bundle confirmrs-swiftui dev.kaya.confirmswiftui "$TARGET_DIR/examples/confirm")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on confirm-swiftui "$APP" dev.kaya.confirmswiftui confirm-swiftui confirm confirm

    # The nav scene (see the swift leg): the serial stack, phone-native.
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example nav
    APP=$(make_bundle navrs-swiftui dev.kaya.navswiftui "$TARGET_DIR/examples/nav")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on nav-swiftui "$APP" dev.kaya.navswiftui nav-swiftui nav nav

    # The scroll scene (see the swift leg).
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example scroll
    APP=$(make_bundle scrollrs-swiftui dev.kaya.scrollswiftui "$TARGET_DIR/examples/scroll")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on scroll-swiftui "$APP" dev.kaya.scrollswiftui scroll-swiftui scroll scroll

    # The filedialog scene. THE ONE LEG WITH EYES ON THE HOST: iOS's
    # picker is a remote view controller, so expect_file_dialog and
    # file_choose are answered by tools/ios/simdrive over the container
    # bridge rather than in-process (docs/traps.md).
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example filedialog
    APP=$(make_bundle filedialogrs-swiftui dev.kaya.filedialogswiftui "$TARGET_DIR/examples/filedialog")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on filedialog-swiftui "$APP" dev.kaya.filedialogswiftui \
        filedialog-swiftui filedialog filedialog

    # The save scene: the ROUND TRIP an editor walks (docs/save-plan.md
    # D5). iOS's save dialog is
    # `UIDocumentPickerViewController(forExporting:)`, another remote
    # view controller, and simdrive has four verbs for it
    # (savestate/savename/savepress/savecancel). `savepress` exists
    # rather than reusing `press` because `press Save` FALSELY SUCCEEDS
    # on this sheet: it matches the static text "Save as" by
    # containment, reports a press, and the sheet stays up.
    #
    # THE PLATFORM ANSWERS WITH A DOCUMENT THAT EXISTS here, unlike the
    # three desktops — the export copies a ZERO-BYTE file the backend
    # stages for the name — so this leg watches D1's "opening a
    # destination yields an empty file" on the side the core does NOT
    # create.
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example save
    APP=$(make_bundle savers-swiftui dev.kaya.saveswiftui "$TARGET_DIR/examples/save")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on save-swiftui "$APP" dev.kaya.saveswiftui \
        save-swiftui save save

    # The clipboard scene. THE SECOND LEG WITH HELP FROM THE HOST: iOS
    # cannot spawn a child process, so the foreign seed and read are
    # answered by run_swiftui_on's watcher over the container bridge
    # (docs/clipboard-plan.md §8). NO DRAIN BRACKET, unlike every desktop
    # lane: the simulator pasteboard is strictly PER-DEVICE, so the slot
    # queue_leg holds IS this lane's clipboard exclusion.
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example clipboard
    APP=$(make_bundle clipboardrs-swiftui dev.kaya.clipboardswiftui "$TARGET_DIR/examples/clipboard")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on clipboard-swiftui "$APP" dev.kaya.clipboardswiftui \
        clipboard-swiftui clipboard clipboard

    # The a11y scene: every widget kind's role and name read back out of
    # UIKit's OWN accessibility tree. iOS is the one platform where that
    # read is IN-PROCESS — unlike macOS, where the server side returns
    # nil and only the AXUIElement client API sees the real thing.
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example a11y
    APP=$(make_bundle a11yrs-swiftui dev.kaya.a11yswiftui "$TARGET_DIR/examples/a11y")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on a11y-swiftui "$APP" dev.kaya.a11yswiftui a11y-swiftui a11y a11y

    # The stamped-accessibility scene (docs/tpl-props-plan.md P3): the
    # a11y scene's sibling, split out because a For's column shifts
    # ordinal container targets per language. swift and go ride the
    # rosters above; this bundle is the rust leg.
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example a11yrows
    APP=$(make_bundle a11yrowsrs-swiftui dev.kaya.a11yrowsswiftui "$TARGET_DIR/examples/a11yrows")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on a11yrows-swiftui "$APP" dev.kaya.a11yrowsswiftui a11yrows-swiftui a11yrows a11yrows

    # The styling scene (docs/styling-plan.md slice 1): brand + roles +
    # inset. The swift and go legs ride the scene lists above.
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example styling
    APP=$(make_bundle stylingrs-swiftui dev.kaya.stylingswiftui "$TARGET_DIR/examples/styling")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on styling-swiftui "$APP" dev.kaya.stylingswiftui styling-swiftui styling styling

    # The text-ranges scene: HIGHLIGHT a set, SELECT one, REVEAL one,
    # plus the two things that make those three a contract — a user's
    # keystroke DROPS a declared set (D2), and a select_range arriving
    # mid-composition is REFUSED (D4).
    #
    # THE OFFSETS ARE THIS LANE'S UNIT TEST: the scene's document opens
    # with a CJK word, so every match sits SIX BYTES further along than
    # in UTF-16, the unit this backend counts. The assertions carry the
    # covered TEXT beside the offsets, because the core converts bytes to
    # UTF-16 to lower a range and this backend converts back to read one
    # — offsets alone would let two symmetric mistakes cancel.
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example ranges
    APP=$(make_bundle rangesrs-swiftui dev.kaya.rangesswiftui "$TARGET_DIR/examples/ranges")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on ranges-swiftui "$APP" dev.kaya.rangesswiftui ranges-swiftui ranges ranges

    # The progress scene (see the swift leg).
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example progress
    APP=$(make_bundle progressrs-swiftui dev.kaya.progressswiftui "$TARGET_DIR/examples/progress")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on progress-swiftui "$APP" dev.kaya.progressswiftui progress-swiftui progress progress

    # The menus scene: the phone half of the command vocabulary —
    # promoted primaries as trailing bar actions, the rest in the More
    # menu, the shortcut through the interpreter's one dispatch table,
    # long-press context menus, and the late rebuild's promotion
    # recompute.
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example menus
    APP=$(make_bundle menusrs-swiftui dev.kaya.menusswiftui "$TARGET_DIR/examples/menus")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on menus-swiftui "$APP" dev.kaya.menusswiftui menus-swiftui menus menus
    # The same bundle and the same scene on the iPad. The phone leg
    # above proves the compact lowering; this is the only thing in any
    # lane that observes the REGULAR one, where the iPadOS 26 menu-bar
    # defect lived.
    # The assertion guards two regressions at once: a bundle that loses
    # UIDeviceFamily=2 runs in iPhone COMPATIBILITY mode and reports
    # compact/overflow, and a regular arm that stops selecting the menu
    # bar reports regular/overflow.
    queue_pad_leg run_swiftui_on menus-swiftui-pad "$APP" dev.kaya.menusswiftui \
        menus-swiftui-pad menus menus 'expect_menu_presentation "regular/bar"'

    # The toolbar scene (docs/chrome-plan.md C2): the `primary` bit
    # ASSERTED in the bar — the promoted set really among the buttons
    # UIKit built, in catalog preorder, the More menu beside them, and
    # one button's glyph and enablement read off the element.
    #
    # PHONE ONLY, and that is the lowering rather than an omission: a
    # regular-width window promotes nothing at all (the catalog goes to
    # the system menu bar, KayaMenuFormFactorChrome), so there is no
    # promoted bar on the iPad for expect_toolbar to read.
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example toolbar
    APP=$(make_bundle toolbarrs-swiftui dev.kaya.toolbarswiftui "$TARGET_DIR/examples/toolbar")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on toolbar-swiftui "$APP" dev.kaya.toolbarswiftui toolbar-swiftui toolbar toolbar

    # The identity scene (docs/app-identity-plan.md). THE ONLY LEG ON
    # THIS LANE THAT ASSERTS ON THE BUNDLE IT WAS BUILT INTO, and that is
    # the platform: iOS has NO runtime route to the Home Screen icon
    # (the SDK's whole surface is supportsAlternateIcons,
    # setAlternateIconName and alternateIconName, typed BOOL and
    # NSString), so the artifact an iOS app's identity lives in is its
    # bundle.
    #
    # `expect_app_icon` decodes the icon inside THIS app's bundle with
    # UIKit's decoder and samples its four quadrant centres, as the mac
    # leg samples AppKit's Dock copy and the Windows leg the HICON behind
    # WM_GETICON — one frozen string, three artifacts. It cannot pass
    # vacuously: no identity over the wire, no icon keys, a named file
    # the bundle lacks, and an icon differing from the declared bytes
    # each go RED naming which.
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example identity
    APP=$(make_bundle identityrs-swiftui dev.kaya.identityswiftui "$TARGET_DIR/examples/identity" identity)
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on identity-swiftui "$APP" dev.kaya.identityswiftui \
        identity-swiftui identity identity "" "" expect_app_icon \
        expect_title "window#1"

    # The assets conformance scene (docs/assets-plan.md). THIS LANE'S
    # ASSET DELIVERY IS THE SHIPPED MECHANISM: make_bundle copies the
    # asset root into Resources exactly as a real iOS app packages one,
    # no KAYA_ASSET_DIR is set anywhere here, and the core asks
    # `Bundle.main` (crates/kaya/src/assets.rs, route 2). So the scene's
    # frozen census is an assertion about the BUNDLE and fails if the
    # copy staged one file instead of the root.
    #
    # It is also the only asset observation this lane can make:
    # `expect_typeface` is depth-stubbed here, which is why the
    # conformance scene reads an IMAGE instead.
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example assets
    APP=$(make_bundle assetsrs-swiftui dev.kaya.assetsswiftui "$TARGET_DIR/examples/assets")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on assets-swiftui "$APP" dev.kaya.assetsswiftui assets-swiftui assets assets

    # The listdetail scene: list-detail's bare invariant, the only form
    # of it this host can run — the `split` scene drives resize_window,
    # and a phone or tablet does not command its own window size
    # (DESIGN.md, Windows).
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example split
    APP=$(make_bundle listdetailrs-swiftui dev.kaya.listdetailswiftui "$TARGET_DIR/examples/split")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on listdetail-swiftui "$APP" dev.kaya.listdetailswiftui \
        listdetail-swiftui listdetail listdetail
    # The same bundle and scene on the iPad, and the reason this scene
    # exists: the phone above is ALWAYS compact, so its invariant is
    # vacuous there. This device is regular, so the invariant bites —
    # with the detail pushed, one pane on screen is a failure. The extra
    # step appends the literal the shared file may not carry, which turns
    # "did not violate the invariant" into "the split arm ran".
    queue_pad_leg run_swiftui_on listdetail-swiftui-pad "$APP" dev.kaya.listdetailswiftui \
        listdetail-swiftui-pad listdetail listdetail 'expect_split "regular/split"'

    # The table scene (docs/tables-plan.md): column headers and
    # click-to-sort on the For vocabulary. The phone is compact, so this
    # leg runs kaya's own header over KayaTableLayout — decision 5's
    # revision, where a native Table would collapse to a first-column
    # list and hide the declared columns.
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example table
    APP=$(make_bundle tablers-swiftui dev.kaya.tableswiftui "$TARGET_DIR/examples/table")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on table-swiftui "$APP" dev.kaya.tableswiftui table-swiftui table table
    # The same bundle and scene on the iPad — THE ONLY LEG IN ANY LANE
    # THAT RUNS UIKit's NATIVE Table (regular width, and the runtime is
    # over TableColumnForEach's iOS 17.4 floor). NO EXTRA STEP, unlike
    # the two pad legs above, and that is decision 5's revision showing
    # through: with the size class gone from every table observable, the
    # bytes a native tier presents and the bytes a synthesized tier
    # presents are IDENTICAL BY DESIGN, so no assertion this leg could
    # append would name the tier it ran. What it buys is that the native
    # path executes at all. THE ROUTING is held off-device now by
    # tools/check-table-tier.sh, so a change to it owes nobody the hand
    # perturbation. WHAT THIS LEG STILL CANNOT SAY is the device's own
    # word: that the pad reports .regular here and the phone .compact
    # above (measured by hand, both ways, 2026-08-21).
    queue_pad_leg run_swiftui_on table-swiftui-pad "$APP" dev.kaya.tableswiftui \
        table-swiftui-pad table table

    # The commands scene, the DEPTH slice (rust only until the sweep):
    # the chords run through the interpreter's one dispatch table, and
    # the `settings` role is inert here — iOS has no application menu to
    # move it into, so the item stays where the app declared it.
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example commands
    APP=$(make_bundle commandsrs-swiftui dev.kaya.commandsswiftui "$TARGET_DIR/examples/commands")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on commands-swiftui "$APP" dev.kaya.commandsswiftui commands-swiftui \
        commands commands

    # The undo scene (rust only until the sweep): ONE history walked
    # newest-first over two tiers — the field's own _UITextUndoManager
    # and the core's ledger — through the Edit>Undo role. The one leg in
    # any lane that types with REAL text input rather than set_text,
    # because a programmatic write clears the very history the first tier
    # is made of (D7). On this platform the input path is UIKeyInput's
    # insertText, iOS having no way to post a key event in process
    # (docs/undo-plan.md §1.3).
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example undo
    APP=$(make_bundle undors-swiftui dev.kaya.undoswiftui "$TARGET_DIR/examples/undo")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on undo-swiftui "$APP" dev.kaya.undoswiftui undo-swiftui undo undo

    # The dirty scene, the DEPTH slice's mobile arm (rust only until the
    # sweep). THE PROP APPLIES HERE AND LOWERS TO NOTHING, the one
    # stated exception in this design (docs/dirty-plan.md D4): a phone
    # has no window chrome to carry an unsaved-work mark. This leg is
    # what keeps "empty" from meaning "absent" — expect_dirty reads the
    # APPLIED PROP back through the interpreter (D5's iOS row) and fails
    # the moment the prop stops arriving.
    #
    # The cut is the chrome close; `expect_dirty` is named as the
    # assertion the cut may not take with it.
    SDKROOT="$SDKROOT_SIM" cargo build --locked --target aarch64-apple-ios-sim --example dirty
    APP=$(make_bundle dirtyrs-swiftui dev.kaya.dirtyswiftui "$TARGET_DIR/examples/dirty")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on dirty-swiftui "$APP" dev.kaya.dirtyswiftui dirty-swiftui \
        dirty dirty '' close_window expect_dirty
    if [ "$SUITE" = all ] && [ -z "${KAYA_RECORD:-}" ]; then
        timing swiftui-built+queued
    else
        drain
        timing swiftui-build+legs
    fi
fi

# The interleaved pool's one collection point (empty arrays no-op for
# the serial shapes, which drained inside their phases).
drain
if [ "$SUITE" = all ] && [ -z "${KAYA_RECORD:-}" ]; then
    timing all-legs-drained
fi

rec_suite_stop || status=1
timing stills-extraction
exit "$status"
