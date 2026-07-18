#!/usr/bin/env bash

# Everything runs inside the dev shell: the flake pins every toolchain
# (rust + cross targets, swiftc, ffmpeg, the android sdk). Running
# against anything else is an error, not something to paper over — and
# a shell entered before the flake last changed is just as much a
# bystander toolchain, so the marker carries the fingerprint of
# flake.nix+flake.lock the shell was actually built from.
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
# Usage: tools/ios/run-sim.sh [rust|swift|rust-swiftui|all]
#
# rust         - the kaya example app (UIKit backend)
# swift        - Swift over the C ABI function floor (UIKit backend)
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

make_bundle() {
    local name="$1" bundle_id="$2" executable_path="$3"
    local app="$BUNDLES/$name.app"
    rm -rf "$app"
    mkdir -p "$app"
    sed -e "s/@EXECUTABLE@/$name/" \
        -e "s/@BUNDLE_ID@/$bundle_id/" \
        -e "s/@NAME@/$name/" \
        tools/ios/Info.plist.in > "$app/Info.plist"
    cp "$executable_path" "$app/$name"
    echo "$app"
}

# A pool of dedicated simulators (kaya-sim-0..N-1, KAYA_IOS_SIMS wide)
# runs the legs in parallel. Devices are created on first use from the
# newest iPhone device type + iOS runtime, stay booted across runs
# (second and later boots ride shared caches, ~15s), and never touch
# the user's own simulators.
POOL="${KAYA_IOS_SIMS:-2}"
UDIDS=()
boot_pool() {
    local dtype runtime i udid
    dtype=$(xcrun simctl list devicetypes | grep -E "iPhone [0-9]+ Pro \(" \
        | tail -1 | grep -oE 'com.apple.CoreSimulator.SimDeviceType[^)]*')
    runtime=$(xcrun simctl list runtimes | grep -m1 -oE 'com.apple.CoreSimulator.SimRuntime.iOS[0-9-]+')
    [ -n "$dtype" ] && [ -n "$runtime" ] \
        || { echo "no iPhone device type / iOS runtime; install one in Xcode" >&2; exit 1; }
    i=0
    while [ "$i" -lt "$POOL" ]; do
        udid=$(xcrun simctl list devices | grep -m1 "kaya-sim-$i (" \
            | grep -oE '[0-9A-F-]{36}' || true)
        if [ -z "$udid" ]; then
            udid=$(xcrun simctl create "kaya-sim-$i" "$dtype" "$runtime")
        fi
        xcrun simctl boot "$udid" 2>/dev/null || true
        UDIDS+=("$udid")
        i=$((i + 1))
    done
    for udid in "${UDIDS[@]}"; do
        # Bounded: bootstatus blocks forever on a wedged device.
        timeout 180 xcrun simctl bootstatus "$udid" -b >/dev/null \
            || { echo "simulator $udid did not boot within 180s" >&2; exit 1; }
    done
}

# Recording mode (KAYA_RECORD=1): the simulator is its own isolated
# surface and shows one app at a time, so ONE suite-long recording
# contains every leg in sequence — per-leg start/stop is not just
# unnecessary, it wedges (the device-side session of a stopped
# recording lingers, and later recorders fail with "Host recording is
# already in progress"). Each leg notes its launch anchor; extraction
# happens after the recorder stops, one lead per leg.
rec_suite_start() {
    [ -n "${KAYA_RECORD:-}" ] || return 0
    command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null \
        || { echo "recording mode needs ffmpeg/ffprobe — run inside nix develop"; exit 1; }
    "$ROOT/tools/harness-extract.sh" --selftest || exit 1
    REC_ROOT="$ROOT/target/recordings/ios"
    mkdir -p "$REC_ROOT"
    # One suite-long recording PER SIMULATOR (concurrent sessions on
    # different udids coexist; same-device sessions are what wedge).
    REC_PIDS=()
    T_MARKS=()
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
    # recordVideo's own clock is unrecoverable from either end: it
    # starts capturing at an unknown moment after launch AND drops its
    # buffered tail when stopped. So plant a fiducial per device: flip
    # the UI appearance dark and stamp the wall time when the flip is
    # actually VISIBLE — the ui command returns seconds before the
    # render lands on a busy, freshly booted simulator, and stamping
    # the command time skews every still by that latency. The
    # screenshot poll pins the stamp to the render within ~300ms.
    sleep 1
    i=0
    local luma
    for udid in "${UDIDS[@]}"; do
        xcrun simctl ui "$udid" appearance dark
        for _ in $(seq 1 25); do
            xcrun simctl io "$udid" screenshot "$REC_ROOT/.flip-probe.png" >/dev/null 2>&1 || true
            luma=$(ffprobe -v quiet -f lavfi "movie=$REC_ROOT/.flip-probe.png,signalstats" \
                -show_entries frame_tags=lavfi.signalstats.YAVG -of csv=p=0 2>/dev/null \
                | awk -F. 'NR==1{print $1}')
            if [ -n "$luma" ] && [ "$luma" -lt 100 ]; then
                break
            fi
            sleep 0.2
        done
        T_MARKS[i]=$(date +%s%3N)
        echo "${T_MARKS[$i]}" >"$REC_ROOT/t_mark-$i"
        i=$((i + 1))
    done
    for udid in "${UDIDS[@]}"; do
        xcrun simctl ui "$udid" appearance light
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
    # Locate each device's appearance-flip fiducial: the first big
    # scene change (everything before it is the static home screen),
    # sanity-checked against the second (the flip back, ~1s later).
    # awk takes what it needs but reads the whole stream: head -1
    # would SIGPIPE ffprobe, which set -o pipefail turns fatal.
    local ANCHORS=()
    local t_flip
    i=0
    while [ "$i" -lt "${#UDIDS[@]}" ]; do
        # The fiducial is the first scene change that is DARK (the
        # appearance flip, YAVG ~76): a freshly booted simulator's
        # home screen churns with boot and install animations, all
        # bright (~157), and "first change" alone picks those up.
        t_flip=$(ffprobe -v quiet -f lavfi \
            "movie=$REC_ROOT/suite-$i.mov,select=gt(scene\,0.3),signalstats" \
            -show_entries frame=pts_time:frame_tags=lavfi.signalstats.YAVG \
            -of csv=p=0 2>/dev/null \
            | awk -F, '$2 + 0 < 100 {printf "%d", $1 * 1000; exit}')
        [ -n "$t_flip" ] || { echo "recording: no dark fiducial in suite-$i.mov"; return 1; }
        ANCHORS[i]=$(( ${T_MARKS[$i]} - t_flip ))
        echo "${ANCHORS[$i]}" >"$REC_ROOT/anchor-$i"
        i=$((i + 1))
    done
    # Each leg extracts from the film of the simulator it ran on.
    local dir failed=0 slot
    local pids=()
    for dir in "$REC_ROOT"/*/; do
        [ -f "$dir/leg.log" ] || continue
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
        cat "$dir/extract.log"
        [ ! -e "$dir/extract-failed" ] || failed=1
    done
    [ "$failed" = 0 ] || { echo "recording: extraction failures above"; return 1; }
}

rec_start() {
    [ -n "${KAYA_RECORD:-}" ] || return 0
    REC_DIR="$ROOT/target/recordings/ios/$1"
    mkdir -p "$REC_DIR"
    # Which simulator's film covers this leg.
    echo "${2:-0}" >"$REC_DIR/sim"
}

rec_finish() {
    [ -n "${KAYA_RECORD:-}" ] || return 0
    # The transcript's own epoch line anchors the leg inside its
    # simulator's recording; nothing to measure here.
    printf '%s\n' "$1" >"$REC_DIR/leg.log"
}

run_bundle_on() {
    local udid="$1" slot="$2" app="$3" bundle_id="$4" name="$5" script="${6:-1}"
    xcrun simctl install "$udid" "$app"
    rec_start "$name" "$slot"
    local out
    out=$(SIMCTL_CHILD_KAYA_SELFTEST="$script" timeout 120 \
        xcrun simctl launch --console-pty "$udid" "$bundle_id" 2>&1) || true
    printf '%s\n' "$out"
    rec_finish "$out"
    xcrun simctl io "$udid" screenshot "$ROOT/target/ios-shot-$name.png" >/dev/null 2>&1 || true
    grep -q "KAYA_SELFTEST: OK" <<<"$out"
}

# Rust entrypoint + SwiftUI backend legs: install the bundle (with the
# embedded dylib) on the claimed simulator and launch with the scene
# script from the environment.
run_swiftui_on() {
    local udid="$1" slot="$2" app="$3" bundle_id="$4" name="$5" selftest="$6" scene="$7"
    xcrun simctl install "$udid" "$app"
    local container
    container=$(xcrun simctl get_app_container "$udid" "$bundle_id" app)
    rec_start "$name" "$slot"
    local out
    out=$(SIMCTL_CHILD_KAYA_SELFTEST="$selftest" \
        SIMCTL_CHILD_KAYA_SELFTEST_SCRIPT="$(grep -v '^#' "$ROOT/tools/scenes/$scene.steps")" \
        SIMCTL_CHILD_KAYA_BACKEND=swiftui \
        SIMCTL_CHILD_KAYA_SWIFTUI_LIB="$container/libkaya_swiftui.dylib" \
        timeout 120 xcrun simctl launch --console-pty "$udid" "$bundle_id" 2>&1) || true
    printf '%s\n' "$out"
    rec_finish "$out"
    xcrun simctl io "$udid" screenshot "$ROOT/target/ios-shot-$name.png" >/dev/null 2>&1 || true
    grep -q "KAYA_SELFTEST: OK" <<<"$out"
}

# Legs run in a pool as wide as the simulator pool: each claims a
# device, runs against it, and reports through a verdict file; drain()
# prints in submission order and is the barrier between flavor blocks
# (their builds overwrite shared scratch files a queued leg reads).
LEGS_DIR="$(mktemp -d)"
trap 'rm -rf "$LEGS_DIR"' EXIT
leg_names=()
leg_pids=()

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

queue_leg() { # fn name args...
    local fn="$1" name="$2"
    shift 2
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
        local verdict=FAIL
        if "$fn" "${UDIDS[$slot]}" "$slot" "$@"; then
            verdict=PASS
        fi
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

drain() {
    if [ ${#leg_pids[@]} -gt 0 ]; then
        wait "${leg_pids[@]}" 2>/dev/null || true
    fi
    leg_pids=()
    local name verdict
    for name in "${leg_names[@]}"; do
        verdict=$(cat "$LEGS_DIR/$name.verdict" 2>/dev/null || echo FAIL)
        echo "== $name =="
        cat "$LEGS_DIR/$name.log" 2>/dev/null
        [ "$verdict" = PASS ] || status=1
        echo "$name: $verdict"
    done
    leg_names=()
}

status=0
KAYA_T0=$SECONDS
timing() {
    echo "TIMING $1 $((SECONDS - KAYA_T0))s"
    KAYA_T0=$SECONDS
}
boot_pool
rec_suite_start
timing boot

SDKROOT_SIM=$(xcrun -sdk iphonesimulator --show-sdk-path)

if [ "$SUITE" = rust ] || [ "$SUITE" = all ]; then
    SDKROOT="$SDKROOT_SIM" cargo build --target aarch64-apple-ios-sim \
        --example milestone2 --example entry --example gallery --example todos --example reorder --example feed
    timing build-rust
    APP=$(make_bundle milestone2 dev.kaya.milestone2 "$TARGET_DIR/examples/milestone2")
    queue_leg run_bundle_on rust "$APP" dev.kaya.milestone2 rust
    APP=$(make_bundle entry dev.kaya.entry "$TARGET_DIR/examples/entry")
    queue_leg run_bundle_on entry-rust "$APP" dev.kaya.entry entry-rust entry
    APP=$(make_bundle gallery dev.kaya.gallery "$TARGET_DIR/examples/gallery")
    queue_leg run_bundle_on gallery-rust "$APP" dev.kaya.gallery gallery-rust gallery
    APP=$(make_bundle todos dev.kaya.todos "$TARGET_DIR/examples/todos")
    queue_leg run_bundle_on todos-rust "$APP" dev.kaya.todos todos-rust todos
    APP=$(make_bundle reorder dev.kaya.reorder "$TARGET_DIR/examples/reorder")
    queue_leg run_bundle_on reorder-rust "$APP" dev.kaya.reorder reorder-rust reorder
    APP=$(make_bundle feed dev.kaya.feed "$TARGET_DIR/examples/feed")
    queue_leg run_bundle_on feed-rust "$APP" dev.kaya.feed feed-rust feed
    drain
    timing legs-rust
fi

if [ "$SUITE" = swift ] || [ "$SUITE" = all ]; then
    SDKROOT="$SDKROOT_SIM" cargo build --target aarch64-apple-ios-sim --lib
    mkdir -p "$BUNDLES"
    # With more than one input file, swiftc only allows top-level code in
    # a file named main.swift; the example is that file.
    cp guests/swift/milestone2.swift "$BUNDLES/main.swift"
    xcrun -sdk iphonesimulator swiftc \
        -target "arm64-apple-ios$IOS_MIN-simulator" \
        -import-objc-header crates/kaya/include/kaya.h \
        bindings/swift/KayaWire.swift bindings/swift/KayaApp.swift bindings/swift/KayaRecords.swift bindings/swift/KayaSums.swift "$BUNDLES/main.swift" \
        -L "$TARGET_DIR" -lkaya \
        -framework UIKit -framework Foundation -framework CoreFoundation \
        -framework CoreGraphics -framework QuartzCore \
        -o "$BUNDLES/milestone2swift-bin"
    APP=$(make_bundle milestone2swift dev.kaya.milestone2swift "$BUNDLES/milestone2swift-bin")
    queue_leg run_bundle_on swift "$APP" dev.kaya.milestone2swift swift

    cp guests/swift/entry.swift "$BUNDLES/main.swift"
    xcrun -sdk iphonesimulator swiftc \
        -target "arm64-apple-ios$IOS_MIN-simulator" \
        -import-objc-header crates/kaya/include/kaya.h \
        bindings/swift/KayaWire.swift bindings/swift/KayaApp.swift bindings/swift/KayaRecords.swift bindings/swift/KayaSums.swift "$BUNDLES/main.swift" \
        -L "$TARGET_DIR" -lkaya \
        -framework UIKit -framework Foundation -framework CoreFoundation \
        -framework CoreGraphics -framework QuartzCore \
        -o "$BUNDLES/entryswift-bin"
    APP=$(make_bundle entryswift dev.kaya.entryswift "$BUNDLES/entryswift-bin")
    queue_leg run_bundle_on entry-swift "$APP" dev.kaya.entryswift entry-swift entry

    cp guests/swift/gallery.swift "$BUNDLES/main.swift"
    xcrun -sdk iphonesimulator swiftc \
        -target "arm64-apple-ios$IOS_MIN-simulator" \
        -import-objc-header crates/kaya/include/kaya.h \
        bindings/swift/KayaWire.swift bindings/swift/KayaApp.swift bindings/swift/KayaRecords.swift bindings/swift/KayaSums.swift "$BUNDLES/main.swift" \
        -L "$TARGET_DIR" -lkaya \
        -framework UIKit -framework Foundation -framework CoreFoundation \
        -framework CoreGraphics -framework QuartzCore \
        -o "$BUNDLES/galleryswift-bin"
    APP=$(make_bundle galleryswift dev.kaya.galleryswift "$BUNDLES/galleryswift-bin")
    queue_leg run_bundle_on gallery-swift "$APP" dev.kaya.galleryswift gallery-swift gallery

    cp guests/swift/todos.swift "$BUNDLES/main.swift"
    xcrun -sdk iphonesimulator swiftc \
        -target "arm64-apple-ios$IOS_MIN-simulator" \
        -import-objc-header crates/kaya/include/kaya.h \
        bindings/swift/KayaWire.swift bindings/swift/KayaApp.swift bindings/swift/KayaRecords.swift bindings/swift/KayaSums.swift "$BUNDLES/main.swift" \
        -L "$TARGET_DIR" -lkaya \
        -framework UIKit -framework Foundation -framework CoreFoundation \
        -framework CoreGraphics -framework QuartzCore \
        -o "$BUNDLES/todosswift-bin"
    APP=$(make_bundle todosswift dev.kaya.todosswift "$BUNDLES/todosswift-bin")
    queue_leg run_bundle_on todos-swift "$APP" dev.kaya.todosswift todos-swift todos

    cp guests/swift/reorder.swift "$BUNDLES/main.swift"
    xcrun -sdk iphonesimulator swiftc \
        -target "arm64-apple-ios$IOS_MIN-simulator" \
        -import-objc-header crates/kaya/include/kaya.h \
        bindings/swift/KayaWire.swift bindings/swift/KayaApp.swift bindings/swift/KayaRecords.swift bindings/swift/KayaSums.swift "$BUNDLES/main.swift" \
        -L "$TARGET_DIR" -lkaya \
        -framework UIKit -framework Foundation -framework CoreFoundation \
        -framework CoreGraphics -framework QuartzCore \
        -o "$BUNDLES/reorderswift-bin"
    APP=$(make_bundle reorderswift dev.kaya.reorderswift "$BUNDLES/reorderswift-bin")
    queue_leg run_bundle_on reorder-swift "$APP" dev.kaya.reorderswift reorder-swift reorder

    cp guests/swift/feed.swift "$BUNDLES/main.swift"
    xcrun -sdk iphonesimulator swiftc \
        -target "arm64-apple-ios$IOS_MIN-simulator" \
        -import-objc-header crates/kaya/include/kaya.h \
        bindings/swift/KayaWire.swift bindings/swift/KayaApp.swift bindings/swift/KayaRecords.swift bindings/swift/KayaSums.swift "$BUNDLES/main.swift" \
        -L "$TARGET_DIR" -lkaya \
        -framework UIKit -framework Foundation -framework CoreFoundation \
        -framework CoreGraphics -framework QuartzCore \
        -o "$BUNDLES/feedswift-bin"
    APP=$(make_bundle feedswift dev.kaya.feedswift "$BUNDLES/feedswift-bin")
    queue_leg run_bundle_on feed-swift "$APP" dev.kaya.feedswift feed-swift feed
    drain
    timing swift-build+legs
fi

if [ "$SUITE" = rust-swiftui ] || [ "$SUITE" = all ]; then
    # Rust entrypoint + SwiftUI backend: the bundle executable is the Rust
    # example's main; KAYA_BACKEND=swiftui makes kaya::run dlopen the
    # SwiftUI dylib embedded in the bundle.
    SDKROOT="$SDKROOT_SIM" cargo build --target aarch64-apple-ios-sim --example milestone2
    mkdir -p "$BUNDLES"
    xcrun -sdk iphonesimulator swiftc \
        -emit-library \
        -target "arm64-apple-ios17.0-simulator" \
        -import-objc-header crates/kaya/include/kaya.h \
        swift/KayaSwiftUI.swift swift/KayaSwiftUIEntry.swift \
        -framework UIKit -framework Foundation \
        -o "$BUNDLES/libkaya_swiftui_ios.dylib"
    APP=$(make_bundle milestone2rs-swiftui dev.kaya.rustswiftui "$TARGET_DIR/examples/milestone2")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on rust-swiftui "$APP" dev.kaya.rustswiftui rust-swiftui 1 milestone2

    # The entry scene against the SwiftUI backend, same embedded dylib.
    SDKROOT="$SDKROOT_SIM" cargo build --target aarch64-apple-ios-sim --example entry
    APP=$(make_bundle entryrs-swiftui dev.kaya.entryswiftui "$TARGET_DIR/examples/entry")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on entry-swiftui "$APP" dev.kaya.entryswiftui entry-swiftui entry entry

    # The todos scene against the SwiftUI backend, same embedded dylib.
    SDKROOT="$SDKROOT_SIM" cargo build --target aarch64-apple-ios-sim --example todos
    APP=$(make_bundle todosrs-swiftui dev.kaya.todosswiftui "$TARGET_DIR/examples/todos")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on todos-swiftui "$APP" dev.kaya.todosswiftui todos-swiftui todos todos

    # The gallery scene against the SwiftUI backend, same embedded dylib.
    SDKROOT="$SDKROOT_SIM" cargo build --target aarch64-apple-ios-sim --example gallery
    APP=$(make_bundle galleryrs-swiftui dev.kaya.galleryswiftui "$TARGET_DIR/examples/gallery")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on gallery-swiftui "$APP" dev.kaya.galleryswiftui gallery-swiftui gallery gallery

    # The reorder scene against the SwiftUI backend, same embedded dylib.
    SDKROOT="$SDKROOT_SIM" cargo build --target aarch64-apple-ios-sim --example reorder
    APP=$(make_bundle reorderrs-swiftui dev.kaya.reorderswiftui "$TARGET_DIR/examples/reorder")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on reorder-swiftui "$APP" dev.kaya.reorderswiftui reorder-swiftui reorder reorder

    # The feed scene against the SwiftUI backend, same embedded dylib.
    SDKROOT="$SDKROOT_SIM" cargo build --target aarch64-apple-ios-sim --example feed
    APP=$(make_bundle feedrs-swiftui dev.kaya.feedswiftui "$TARGET_DIR/examples/feed")
    cp "$BUNDLES/libkaya_swiftui_ios.dylib" "$APP/libkaya_swiftui.dylib"
    queue_leg run_swiftui_on feed-swiftui "$APP" dev.kaya.feedswiftui feed-swiftui feed feed
    drain
    timing swiftui-build+legs
fi

rec_suite_stop || status=1
timing stills-extraction
exit "$status"
