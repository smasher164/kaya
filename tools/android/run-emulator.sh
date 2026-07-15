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

SUITE="${1:-all}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

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

run_apk() {
    local name="$1" apk="$2" component="$3"
    shift 3
    adb install -r "$apk" >/dev/null
    adb shell am force-stop "${component%%/*}"
    adb logcat -c
    echo "== $name =="
    adb shell am start -W -n "$component" --ez KAYA_SELFTEST true "$@" >/dev/null
    # The selftest exits the app at ~2.5s; grab the scene while it is
    # still up. logcat then reads the verdict from the buffer even if it
    # was emitted before the watch attached.
    sleep 2
    adb exec-out screencap -p > "$ROOT/target/android-shot-$name.png" 2>/dev/null || true
    local out
    out=$(timeout 60 adb logcat -s kaya:* -e 'KAYA_SELFTEST: (OK|FAILED)' -m 1 | tee /dev/stderr) || true
    if grep -q "KAYA_SELFTEST: OK" <<<"$out"; then
        echo "$name: PASS"
    else
        echo "$name: FAIL"
        status=1
    fi
}

if [ "$SUITE" = rust ] || [ "$SUITE" = all ]; then
    JNILIBS="$ROOT/android/milestone2/src/main/jniLibs/arm64-v8a"
    mkdir -p "$JNILIBS"
    cargo ndk -t arm64-v8a build --example milestone2_android
    cp "$ROOT/target/aarch64-linux-android/debug/examples/libmilestone2_android.so" "$JNILIBS/"
    (cd android && gradle --console=plain -q :milestone2:assembleDebug)
    run_apk rust \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity
fi

if [ "$SUITE" = compose ] || [ "$SUITE" = all ]; then
    # Identical app to the rust suite; the backend is a runtime choice.
    JNILIBS="$ROOT/android/milestone2/src/main/jniLibs/arm64-v8a"
    mkdir -p "$JNILIBS"
    cargo ndk -t arm64-v8a build --example milestone2_android
    cp "$ROOT/target/aarch64-linux-android/debug/examples/libmilestone2_android.so" "$JNILIBS/"
    (cd android && gradle --console=plain -q :milestone2:assembleDebug)
    run_apk compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity \
        --es KAYA_BACKEND compose
fi

if [ "$SUITE" = jvm ] || [ "$SUITE" = all ]; then
    JNILIBS="$ROOT/android/milestone2kt/src/main/jniLibs/arm64-v8a"
    mkdir -p "$JNILIBS"
    cargo ndk -t arm64-v8a build --lib
    cp "$ROOT/target/aarch64-linux-android/debug/libkaya.so" "$JNILIBS/"
    (cd android && gradle --console=plain -q :milestone2kt:assembleDebug)
    run_apk jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity
fi

exit "$status"
