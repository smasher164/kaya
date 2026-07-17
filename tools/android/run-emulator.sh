#!/usr/bin/env bash
# Build, install, and self-test the milestone scene in the Android emulator.
# Usage: tools/android/run-emulator.sh [rust|jvm|compose|all]
#
# rust    - the milestone-0 app logic as a Rust cdylib behind the JNI
#           entry (android.widget backend driven over JNI)
# jvm     - the JVM app itself as the guest: Java app logic over the
#           direct ring tier (Unsafe fenced access on raw addresses)
# compose - the rust app with the Compose backend selected at runtime
#           (same APK, KAYA_BACKEND=compose)
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

# Boot headless; screenshots still work because the GPU renders host-side.
emulator -avd "$AVD" -no-window -no-audio -no-boot-anim \
    -gpu swiftshader_indirect >/dev/null 2>&1 &
EMULATOR_PID=$!
trap 'adb emu kill >/dev/null 2>&1 || kill "$EMULATOR_PID" 2>/dev/null || true' EXIT

adb wait-for-device
adb shell 'while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 1; done'

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

run_apk() {
    # Selftest scripts double as scene selectors on Android (one APK
    # hosts every scene); pass the script as a string extra.
    local name="$1" apk="$2" component="$3" script="$4"
    shift 4
    adb install -r "$apk" >/dev/null
    adb shell am force-stop "${component%%/*}"
    adb logcat -c
    echo "== $name =="
    # Recording mode (KAYA_RECORD=1): the emulator display is its own
    # isolated surface; screenrecord runs on-device, stopped with
    # SIGINT so the file finalizes, then pulled and mined for stills at
    # the harness transcript's offsets.
    local rec_pid=
    if [ -n "${KAYA_RECORD:-}" ]; then
        adb shell rm -f "/data/local/tmp/kaya-rec.mp4"
        adb shell screenrecord "/data/local/tmp/kaya-rec.mp4" &
        rec_pid=$!
    fi
    adb shell am start -W -n "$component" --es KAYA_SELFTEST "$script" "$@" >/dev/null
    # The selftest exits the app at ~2.5s; grab the scene while it is
    # still up. logcat then reads the verdict from the buffer even if it
    # was emitted before the watch attached.
    sleep 2
    adb exec-out screencap -p > "$ROOT/target/android-shot-$name.png" 2>/dev/null || true
    local out
    out=$(timeout 60 adb logcat -s kaya:* -e 'KAYA_SELFTEST: (OK|FAILED)' -m 1 | tee /dev/stderr) || true
    if [ -n "${KAYA_RECORD:-}" ]; then
        local dir="$ROOT/target/recordings/android/$name"
        mkdir -p "$dir"
        # The recorder's start time is unobservable from the host (it
        # buffers before its first file write), but its END is: the
        # last frame lands when this SIGINT arrives. Anchor = stop
        # time minus video duration.
        local t_kill
        t_kill=$(date +%s%3N)
        adb shell "kill -2 \$(pidof screenrecord)" 2>/dev/null || true
        wait "$rec_pid" 2>/dev/null
        sleep 1
        adb pull "/data/local/tmp/kaya-rec.mp4" "$dir/video.mp4" >/dev/null 2>&1 || true
        adb logcat -d -s kaya:* >"$dir/leg.log" 2>/dev/null || true
        local dur_ms
        dur_ms=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 \
            "$dir/video.mp4" 2>/dev/null | awk '{printf "%d", $1 * 1000}')
        if [ -z "$dur_ms" ]; then
            echo "$name: recording produced no readable video"
            status=1
        elif ! "$ROOT/tools/harness-extract.sh" "$dir/video.mp4" "$dir/leg.log" \
            "$((t_kill - dur_ms))" "$dir/steps"; then
            status=1
        fi
    fi
    if grep -q "KAYA_SELFTEST: OK" <<<"$out"; then
        echo "$name: PASS"
    else
        echo "$name: FAIL"
        # A guest that never printed a verdict crashed before dispatch;
        # the kaya-tag filter above cannot see that, so surface the
        # runtime's own crash log.
        adb logcat -d -s AndroidRuntime:E | tail -30
        status=1
    fi
}

if [ "$SUITE" = rust ] || [ "$SUITE" = all ]; then
    JNILIBS="$ROOT/android/milestone2/src/main/jniLibs/arm64-v8a"
    mkdir -p "$JNILIBS"
    cargo ndk -t arm64-v8a build --example milestone2_android
    cp "$ROOT/target/aarch64-linux-android/debug/examples/libmilestone2_android.so" "$JNILIBS/"
    (cd android && gradle --console=plain -q :milestone2:assembleDebug)
    timing build-rust
    run_apk rust \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity 1
    run_apk entry-rust \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity entry
    run_apk gallery-rust \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity gallery
    run_apk todos-rust \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity todos
    timing legs-rust
fi

if [ "$SUITE" = compose ] || [ "$SUITE" = all ]; then
    # Identical app to the rust suite; the backend is a runtime choice.
    JNILIBS="$ROOT/android/milestone2/src/main/jniLibs/arm64-v8a"
    mkdir -p "$JNILIBS"
    cargo ndk -t arm64-v8a build --example milestone2_android
    cp "$ROOT/target/aarch64-linux-android/debug/examples/libmilestone2_android.so" "$JNILIBS/"
    (cd android && gradle --console=plain -q :milestone2:assembleDebug)
    # The Kotlin interpreter reads the scene script from the
    # environment (via the KAYA_* intent-extra mapping). Intent extras
    # cannot carry newlines through the shell, so comments are stripped
    # and lines fold into `;` — the grammar's newline stand-in.
    scene_script() { grep -v '^#' "$ROOT/tools/scenes/$1.steps" | tr '\n' ';'; }
    run_apk compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity 1 \
        --es KAYA_BACKEND compose \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script milestone2)'"
    run_apk entry-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity entry \
        --es KAYA_BACKEND compose \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script entry)'"
    run_apk gallery-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity gallery \
        --es KAYA_BACKEND compose \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script gallery)'"
    run_apk todos-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity todos \
        --es KAYA_BACKEND compose \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script todos)'"
    timing legs-compose
fi

if [ "$SUITE" = jvm ] || [ "$SUITE" = all ]; then
    JNILIBS="$ROOT/android/milestone2kt/src/main/jniLibs/arm64-v8a"
    mkdir -p "$JNILIBS"
    cargo ndk -t arm64-v8a build --lib
    cp "$ROOT/target/aarch64-linux-android/debug/libkaya.so" "$JNILIBS/"
    (cd android && gradle --console=plain -q :milestone2kt:assembleDebug)
    timing build-jvm
    run_apk jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity 1
    run_apk entry-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity entry
    run_apk gallery-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity gallery
    run_apk todos-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity todos
    timing legs-jvm
fi

exit "$status"
