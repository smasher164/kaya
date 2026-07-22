#!/usr/bin/env bash

# The panels scene is desktop-only BY DESIGN and deliberately not a
# leg here: create_window is capability-rejected on this host (no
# KAYA_CAP_AUX_WINDOWS — the system owns surfaces; DESIGN.md,
# Presentation contexts).
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
# Build, install, and self-test the milestone scene in the Android emulator.
# Usage: tools/android/run-emulator.sh [compose|jvm|all]
#
# rust    - the milestone-0 app logic as a Rust cdylib behind the JNI
#           entry (android.widget backend driven over JNI)
# jvm     - the JVM app itself as the guest: Java app logic over the
#           direct ring tier (Unsafe fenced access on raw addresses)
# compose - the rust app on the Compose interpreter (the one Android
#           backend)
#
# Run inside the dev shell (direnv or `nix develop`); the SDK, emulator,
# NDK, JDK, and Gradle all come from the flake. stdout is invisible to an
# Android app process, so selftest results are read from logcat.
set -euo pipefail

ROOT_FOR_CHECK="$(cd "$(dirname "$0")/../.." && pwd)"
# Compile the android target before anything heavy: a missing match arm
# should fail here, not after the emulator boots.
"$ROOT_FOR_CHECK/tools/check-targets.sh" android || exit 1

SUITE="${1:-all}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# The suites compile the generated Java binding (and the Rust core
# against kaya.h); fail loudly if either has drifted from the source.
tools/gen-header.sh --check
tools/gen-bindings.sh --check

# AVDs live under target/ so nothing leaks into $HOME.
export ANDROID_AVD_HOME="$ROOT/target/avd"
mkdir -p "$ANDROID_AVD_HOME"
AVD=kaya
IMAGE="system-images;android-35;google_apis;arm64-v8a"

if ! avdmanager list avd -c 2>/dev/null | grep -qx "$AVD"; then
    echo "no" | avdmanager create avd -n "$AVD" -k "$IMAGE" >/dev/null
fi

# A pool of emulators (KAYA_ANDROID_EMUS wide) runs the legs in
# parallel. All pool instances share the one AVD READ-ONLY — the
# sharing rule is all-or-nothing, a read-write instance locks every
# sibling out — and read-only instances quickboot from the snapshot in
# ~2-4s. The snapshot itself can only be written by a read-write
# instance, so it is created once here. Pool instances stay warm
# across runs on purpose; nothing kills them at exit.
POOL="${KAYA_ANDROID_EMUS:-2}"
boot_wait() { # serial
    local serial="$1" tries=0
    until adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | grep -q 1; do
        tries=$((tries + 1))
        if [ "$tries" -gt 120 ]; then
            echo "$serial did not boot; emulator log tail:" >&2
            tail -5 "$ROOT/target/emu-${serial#emulator-}.log" >&2 || true
            exit 1
        fi
        sleep 1
    done
}
if [ ! -d "$ANDROID_AVD_HOME/$AVD.avd/snapshots/default_boot" ]; then
    echo "== creating quickboot snapshot (one-time) =="
    emulator -avd "$AVD" -no-window -no-audio -no-boot-anim \
        -gpu swiftshader_indirect -port 5554 >"$ROOT/target/emu-5554.log" 2>&1 &
    boot_wait emulator-5554
    adb -s emulator-5554 emu kill >/dev/null 2>&1 || true
    sleep 5
fi
SERIALS=()
i=0
while [ "$i" -lt "$POOL" ]; do
    port=$((5554 + 2 * i))
    serial="emulator-$port"
    SERIALS+=("$serial")
    if ! adb -s "$serial" get-state 2>/dev/null | grep -q device; then
        emulator -avd "$AVD" -read-only -no-window -no-audio -no-boot-anim \
            -gpu swiftshader_indirect -port "$port" >"$ROOT/target/emu-$port.log" 2>&1 &
    fi
    i=$((i + 1))
done
for serial in "${SERIALS[@]}"; do
    boot_wait "$serial"
done

status=0
KAYA_T0=$SECONDS
timing() {
    echo "TIMING $1 $((SECONDS - KAYA_T0))s"
    KAYA_T0=$SECONDS
}
timing boot

if [ -n "${KAYA_RECORD:-}" ]; then
    command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null \
        || { echo "recording mode needs ffmpeg/ffprobe — run inside nix develop"; exit 1; }
    "$ROOT/tools/harness-extract.sh" --selftest || exit 1
fi

# Legs run in a pool as wide as the device pool: each claims an
# emulator, runs against it with adb -s, and reports through a verdict
# file; drain() prints in submission order and doubles as the barrier
# before the next gradle build rewrites the APK a queued leg would
# install.
LEGS_DIR="$(mktemp -d)"
trap 'rm -rf "$LEGS_DIR"' EXIT
leg_names=()
leg_pids=()

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

run_apk() {
    local name="$1"
    leg_names+=("$name")
    (
        local serial='' slot='' i
        while [ -z "$serial" ]; do
            i=0
            while [ "$i" -lt "${#SERIALS[@]}" ]; do
                if mkdir "$LEGS_DIR/.dev-$i" 2>/dev/null; then
                    serial="${SERIALS[$i]}"
                    slot=$i
                    break
                fi
                i=$((i + 1))
            done
            [ -n "$serial" ] || sleep 0.2
        done
        local verdict=FAIL
        if run_apk_on "$serial" "$@"; then
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
    while [ "$(running_legs)" -ge "${#SERIALS[@]}" ]; do
        spins=$((spins + 1))
        if [ "$spins" -gt 900 ]; then
            echo "pool wedged: $(running_legs) legs running, none finishing; queued=${#leg_names[@]}" >&2
            exit 1
        fi
        sleep 0.2
    done
}

run_apk_on() {
    # Selftest scripts double as scene selectors on Android (one APK
    # hosts every scene); pass the script as a string extra.
    local serial="$1" name="$2" apk="$3" component="$4" script="$5"
    shift 5
    local failed=0
    adb -s "$serial" install -r "$apk" >/dev/null
    adb -s "$serial" shell am force-stop "${component%%:*}" >/dev/null 2>&1 || true
    adb -s "$serial" shell am force-stop "${component%%/*}"
    adb -s "$serial" logcat -c
    # Recording mode (KAYA_RECORD=1): the emulator display is its own
    # isolated surface; screenrecord runs on-device, stopped with
    # SIGINT so the file finalizes, then pulled and mined for stills at
    # the harness transcript's offsets.
    local rec_pid=
    # The guest must know it is being filmed: the harness holds its
    # window briefly after the last step when recording (see
    # record_linger in harness.rs), and the only way in is a KAYA_*
    # extra, which MainActivity maps to an environment variable.
    local rec_extra=()
    if [ -n "${KAYA_RECORD:-}" ]; then
        adb -s "$serial" shell rm -f "/data/local/tmp/kaya-rec.mp4"
        adb -s "$serial" shell screenrecord "/data/local/tmp/kaya-rec.mp4" &
        rec_pid=$!
        rec_extra=(--es KAYA_RECORD 1)
    fi
    adb -s "$serial" shell am start -W -n "$component" --es KAYA_SELFTEST "$script" ${rec_extra[@]+"${rec_extra[@]}"} "$@" >/dev/null
    # The selftest exits the app at ~2.5s; grab the scene while it is
    # still up. logcat then reads the verdict from the buffer even if it
    # was emitted before the watch attached.
    sleep 2
    adb -s "$serial" exec-out screencap -p > "$ROOT/target/android-shot-$name.png" 2>/dev/null || true
    local out
    out=$(timeout 60 adb -s "$serial" logcat -s kaya:* -e 'KAYA_SELFTEST: (OK|FAILED)' -m 1) || true
    printf '%s\n' "$out"
    if [ -n "${KAYA_RECORD:-}" ]; then
        local dir="$ROOT/target/recordings/android/$name"
        mkdir -p "$dir"
        # The recorder's start time is unobservable from the host (it
        # buffers before its first file write), but its END is: the
        # last frame lands when this SIGINT arrives. Anchor = stop
        # time minus video duration.
        local t_kill
        t_kill=$(date +%s%3N)
        adb -s "$serial" shell "kill -2 \$(pidof screenrecord)" 2>/dev/null || true
        wait "$rec_pid" 2>/dev/null
        sleep 1
        adb -s "$serial" pull "/data/local/tmp/kaya-rec.mp4" "$dir/video.mp4" >/dev/null 2>&1 || true
        adb -s "$serial" logcat -d -s kaya:* >"$dir/leg.log" 2>/dev/null || true
        local dur_ms
        dur_ms=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 \
            "$dir/video.mp4" 2>/dev/null | awk '{printf "%d", $1 * 1000}')
        if [ -z "$dur_ms" ]; then
            echo "$name: recording produced no readable video"
            failed=1
        elif ! "$ROOT/tools/harness-extract.sh" "$dir/video.mp4" "$dir/leg.log" \
            "$((t_kill - dur_ms))" "$dir/steps"; then
            failed=1
        fi
    fi
    if ! grep -q "KAYA_SELFTEST: OK" <<<"$out"; then
        # A guest that never printed a verdict crashed before dispatch;
        # the kaya-tag filter above cannot see that, so surface the
        # runtime's own crash log.
        adb -s "$serial" logcat -d -s AndroidRuntime:E | tail -30
        failed=1
    fi
    [ "$failed" = 0 ]
}

# The Kotlin interpreter reads the scene script from the environment
# (via the KAYA_* intent-extra mapping). Intent extras cannot carry
# newlines through the shell, so comments are stripped and lines fold
# into `;` — the grammar's newline stand-in.
scene_script() { grep -v '^#' "$ROOT/tools/scenes/$1.steps" | tr '\n' ';'; }

if [ "$SUITE" = compose ] || [ "$SUITE" = all ]; then
    # Identical app to the rust suite; the backend is a runtime choice.
    JNILIBS="$ROOT/android/milestone2/src/main/jniLibs/arm64-v8a"
    mkdir -p "$JNILIBS"
    # Builds fail the RUN, loudly: an unguarded build failure here
    # would install the PREVIOUS apk and green the legs against stale
    # code — the stale-artifact class (validation scripts build and
    # verify what they ship). Caught live 2026-07-22: a Kotlin
    # compile error produced a zero-verdict run instead of a failure.
    cargo ndk -t arm64-v8a build --example milestone2_android || exit 1
    cp "$ROOT/target/aarch64-linux-android/debug/examples/libmilestone2_android.so" "$JNILIBS/"
    (cd android && gradle --console=plain -q :milestone2:assembleDebug) || exit 1
    run_apk compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity 1 \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script milestone2)'"
    run_apk entry-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity entry \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script entry)'"
    run_apk gallery-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity gallery \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script gallery)'"
    run_apk todos-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity todos \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script todos)'"
    run_apk reorder-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity reorder \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script reorder)'"
    run_apk feed-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity feed \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script feed)'"
    run_apk grow-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity grow \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script grow)'"
    run_apk align-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity align \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script align)'"
    run_apk layout-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity layout \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script layout)'"
    # The confirm scene: alerts are phone-native — the M3 dialog is
    # this host's REAL modal, and back/outside-tap IS the cancel slot.
    run_apk confirm-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity confirm \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script confirm)'"
    # The nav scene: navigation is phone-native — the system back
    # gesture (the BackHandler dispatch) is the affordance, and
    # intercept_back answers with pop_entry.
    run_apk nav-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity nav \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script nav)'"
    # The scroll scene: verticalScroll is phone-native machinery.
    run_apk scroll-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity scroll \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script scroll)'"
    drain
    timing legs-compose
fi

if [ "$SUITE" = jvm ] || [ "$SUITE" = all ]; then
    JNILIBS="$ROOT/android/milestone2kt/src/main/jniLibs/arm64-v8a"
    mkdir -p "$JNILIBS"
    cargo ndk -t arm64-v8a build --lib || exit 1
    cp "$ROOT/target/aarch64-linux-android/debug/libkaya.so" "$JNILIBS/"
    (cd android && gradle --console=plain -q :milestone2kt:assembleDebug) || exit 1
    timing build-jvm
    run_apk jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity 1 \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script milestone2)'"
    run_apk entry-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity entry \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script entry)'"
    run_apk gallery-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity gallery \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script gallery)'"
    run_apk todos-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity todos \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script todos)'"
    run_apk reorder-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity reorder \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script reorder)'"
    run_apk feed-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity feed \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script feed)'"
    # The layout contract through the JVM binding: grow asserted as
    # shares and root-fills, layout observed.
    run_apk grow-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity grow \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script grow)'"
    run_apk align-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity align \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script align)'"
    run_apk layout-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity layout \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script layout)'"
    run_apk confirm-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity confirm \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script confirm)'"
    # The nav scene through the JVM binding (see the compose leg).
    run_apk nav-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity nav \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script nav)'"
    # The scroll scene through the JVM binding (see the compose leg).
    run_apk scroll-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity scroll \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script scroll)'"
    drain
    timing legs-jvm
fi

exit "$status"
