#!/usr/bin/env bash
# The menus scene runs both legs here: compose (the rust guest on the
# Compose interpreter) and jvm (the Kotlin guest over milestone2kt's
# "menus" arm). Hardware chords reach the catalog through each host
# Activity's dispatchKeyShortcutEvent override; the harness verb
# drives the same interpreter table, so the emulator needs no
# keyboard.

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
# The split scene is desktop-only BY DESIGN and deliberately not a leg
# here: it drives resize_window, and Android does not command its own
# window size (the system owns it; DESIGN.md, Windows). Its phone-safe
# sibling `listdetail` covers this backend instead — the bare
# invariant, on the pool AND on the tablet, which is where the split
# arm is observable at all.
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
# One tablet alongside the phone pool. It exists for exactly one
# reason: every pool device is 320dp wide, an unambiguously COMPACT
# window, and Material's standard directive shows two panes only at
# 840dp — so nothing in this lane could observe the list-detail SPLIT
# arm, and a wrong one compiled and passed everything. This is the iOS
# lane's iPad, for the same defect class and with the same scope: one
# device carrying one scene, form-factor coverage rather than
# device-matrix breadth.
TABLET_AVD=kaya-tablet

if ! avdmanager list avd -c 2>/dev/null | grep -qx "$AVD"; then
    echo "no" | avdmanager create avd -n "$AVD" -k "$IMAGE" >/dev/null
fi
if ! avdmanager list avd -c 2>/dev/null | grep -qx "$TABLET_AVD"; then
    # medium_tablet: a 2560x1600 panel at density 320, whose NATURAL
    # orientation is landscape — so a headless instance comes up at
    # 1280dp, past Material's 840. Measured on this AVD, both ways:
    # rotated to portrait the same device reports 800dp, which is
    # INSIDE the 400..840 band where the platforms legitimately
    # disagree about pane count (check-steps' band rule), and the
    # listdetail leg would fail there for a reason that is not a bug.
    # config.ini's hw.initialOrientation does NOT decide this (it is
    # `portrait` on a device that boots landscape), which is exactly
    # why the width is ASSERTED at boot below rather than assumed from
    # the AVD definition.
    echo "no" | avdmanager create avd -n "$TABLET_AVD" -k "$IMAGE" -d medium_tablet >/dev/null
fi

# A pool of emulators (KAYA_ANDROID_EMUS wide) runs the legs in
# parallel. All pool instances share the one AVD READ-ONLY — the
# sharing rule is all-or-nothing, a read-write instance locks every
# sibling out — and read-only instances quickboot from the snapshot in
# ~2-4s. The snapshot itself can only be written by a read-write
# instance, so it is created once here. Pool instances stay warm
# across runs on purpose; nothing kills them at exit.
POOL="${KAYA_ANDROID_EMUS:-3}"
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
make_snapshot() { # avd port
    local avd="$1" port="$2"
    [ -d "$ANDROID_AVD_HOME/$avd.avd/snapshots/default_boot" ] && return 0
    echo "== creating quickboot snapshot for $avd (one-time) =="
    emulator -avd "$avd" -no-window -no-audio -no-boot-anim \
        -gpu swiftshader_indirect -port "$port" >"$ROOT/target/emu-$port.log" 2>&1 &
    boot_wait "emulator-$port"
    adb -s "emulator-$port" emu kill >/dev/null 2>&1 || true
    sleep 5
}
make_snapshot "$AVD" 5554
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
# The tablet takes the port after the pool's, and is NOT a pool member:
# it carries one leg, and a leg that claimed it from the pool would
# leave the other legs' size class up to a race.
TABLET_PORT=$((5554 + 2 * POOL))
TABLET_SERIAL="emulator-$TABLET_PORT"
make_snapshot "$TABLET_AVD" "$TABLET_PORT"
if ! adb -s "$TABLET_SERIAL" get-state 2>/dev/null | grep -q device; then
    emulator -avd "$TABLET_AVD" -read-only -no-window -no-audio -no-boot-anim \
        -gpu swiftshader_indirect -port "$TABLET_PORT" \
        >"$ROOT/target/emu-$TABLET_PORT.log" 2>&1 &
fi
for serial in "${SERIALS[@]}" "$TABLET_SERIAL"; do
    boot_wait "$serial"
done

# THE DEVICE IS THIS LANE'S WIDTH, so it owes the rule a resize owes.
# check-steps forbids an expect_split between 400 and 840dp, the band
# where GNOME, Material and TwoPaneView legitimately disagree about
# pane count; a lane that picks a DEVICE rather than resizing is making
# the same choice with none of that gate's visibility. Read the dp the
# apps actually see (`am get-config`'s w<N>dp — the device's own
# answer, not width/density arithmetic that a skin or an override could
# make a lie) and refuse to run against a device inside the band. What
# this catches: a tablet that came up portrait at 800dp, and a pool AVD
# that grows into the band during some future retune.
width_dp() { # serial -> the width in dp its apps see
    adb -s "$1" shell am get-config 2>/dev/null | python3 -c '
import re
import sys

m = re.search(r"-w([0-9]+)dp-", sys.stdin.read())
print(m.group(1) if m else "")'
}
assert_outside_band() { # serial label
    local dp
    dp="$(width_dp "$1")"
    if [ -z "$dp" ]; then
        echo "$2 ($1): could not read the display width in dp" >&2
        exit 1
    fi
    if [ "$dp" -ge 400 ] && [ "$dp" -lt 840 ]; then
        echo "$2 ($1) is ${dp}dp wide, inside the 400..840 band where the" \
            "platforms disagree about pane count — the listdetail leg would" \
            "fail there for a reason that is not a bug" >&2
        exit 1
    fi
    echo "$2: ${dp}dp"
}
assert_outside_band "${SERIALS[0]}" "phone pool"
assert_outside_band "$TABLET_SERIAL" "tablet"

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
# The tablet's leg is tracked apart from the pool's. If it rode
# leg_pids, a running tablet leg would count against the phone pool's
# saturation gate below, throttling a pool it does not use and
# eventually tripping its wedge watchdog (the iOS lane's pad_pids, the
# same reason).
tablet_pids=()

drain() {
    if [ ${#leg_pids[@]} -gt 0 ] || [ ${#tablet_pids[@]} -gt 0 ]; then
        wait "${leg_pids[@]}" "${tablet_pids[@]}" 2>/dev/null || true
    fi
    leg_pids=()
    tablet_pids=()
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
        # Per-leg wall time rides the verdict (the bottleneck-hunt
        # instrumentation, uniform across runners).
        local t0=$SECONDS
        local verdict=FAIL
        if run_apk_on "$serial" "$@"; then
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
    while [ "$(running_legs)" -ge "${#SERIALS[@]}" ]; do
        spins=$((spins + 1))
        if [ "$spins" -gt 900 ]; then
            echo "pool wedged: $(running_legs) legs running, none finishing; queued=${#leg_names[@]}" >&2
            exit 1
        fi
        sleep 0.2
    done
}

# The tablet's leg: the same verdict/timing protocol as run_apk, bound
# to the one tablet instead of claiming a pool slot. No saturation gate
# and no slot lock — there is one device and one leg on it.
run_apk_tablet() {
    local name="$1"
    leg_names+=("$name")
    (
        local t0=$SECONDS
        local verdict=FAIL
        if run_apk_on "$TABLET_SERIAL" "$@"; then
            verdict=PASS
        fi
        echo $((SECONDS - t0)) >"$LEGS_DIR/$name.secs"
        echo "$verdict" >"$LEGS_DIR/$name.verdict"
    ) >"$LEGS_DIR/$name.log" 2>&1 &
    tablet_pids+=($!)
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
    #
    # (NO PER-LEG SCREENSHOT. There used to be a `sleep 2; screencap`
    # here, and 48 of its 52 outputs were the launcher's WALLPAPER —
    # 207KB, near-identical across legs — because the app had already
    # exited. That is worse than no screenshot: it looks like evidence.
    #
    # Not fixable by tuning the wait, which is why it is gone rather
    # than adjusted. Measured on emulator-5554, 2026-07-27: `am start -W`
    # already blocks until the first frame (TotalTime ~420ms), the scene
    # then runs to its verdict and exits ~300ms later, and screencap
    # itself costs ~100ms of that. Waiting 2s and 1s both landed on
    # wallpaper; waiting 0s landed on the launch SPLASH, before the
    # scene had drawn. The window where the real UI is on screen is
    # narrower than the jitter around it.
    #
    # The recording pipeline is the visual record and always was: it
    # samples a still at EVERY step, anchored to the harness transcript
    # rather than to a guessed delay. `KAYA_RECORD=1` when you want
    # pictures.)
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
            "$dir/video.mp4" 2>/dev/null | python3 -c 'import sys; print(int(float(sys.stdin.read().strip() or 0) * 1000))')
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

# The Compose interpreter carries the id of the sources it was compiled
# from, the same contract libkaya and the SwiftUI dylib have. Written
# before gradle so it is compiled in; the apk is asked afterwards
# (tools/build-id.sh reads the dex members, since an apk is a zip and
# the string is not visible in the raw file).
kaya_write_compose_marker() {
    local dir="$ROOT/android/kaya/generated/dev/kaya"
    mkdir -p "$dir"
    cat >"$dir/KayaBuildId.java" <<EOF
// Generated by tools/android/run-emulator.sh. Do not edit, do not commit.
package dev.kaya;

public final class KayaBuildId {
    public static final String MARKER = "kaya-build-id:$("$ROOT/tools/build-id.sh" compose)";

    private KayaBuildId() {}
}
EOF
}

if [ "$SUITE" = compose ] || [ "$SUITE" = all ]; then
    # Identical app to the rust suite; the backend is a runtime choice.
    JNILIBS="$ROOT/android/milestone2/src/main/jniLibs/arm64-v8a"
    mkdir -p "$JNILIBS"
    # Builds fail the RUN, loudly: an unguarded build failure here
    # would install the PREVIOUS apk and green the legs against stale
    # code — the stale-artifact class (validation scripts build and
    # verify what they ship). Caught live 2026-07-22: a Kotlin
    # compile error produced a zero-verdict run instead of a failure.
    cargo ndk -t arm64-v8a build --locked --example milestone2_android || exit 1
    cp "$ROOT/target/aarch64-linux-android/debug/examples/libmilestone2_android.so" "$JNILIBS/"
    # Verify the COPY, not the source: gradle packages the apk from
    # jniLibs, so this covers the build and the copy at once.
    "$ROOT/tools/build-id.sh" --verify "$JNILIBS/libmilestone2_android.so" || exit 1
    kaya_write_compose_marker
    (cd android && gradle --console=plain -q :milestone2:assembleDebug) || exit 1
    "$ROOT/tools/build-id.sh" --verify --component compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" || exit 1
    run_apk compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity 1 \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script milestone2)'"
    run_apk a11y-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity a11y \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script a11y)'"
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
    # The progress scene: M3's LinearProgressIndicator, both arms.
    run_apk progress-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity progress \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script progress)'"
    # The select scene: M3's exposed dropdown menu.
    run_apk select-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity select \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script select)'"
    # The radio scene: M3 RadioButton rows, the choice contract inline.
    run_apk radio-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity radio \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script radio)'"
    # The grid scene: the custom measurement Layout (Compose has no
    # grid primitive) + the spacer's grow sugar.
    run_apk grid-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity grid \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script grid)'"
    # The textarea scene: multiline M3 TextField, entry contract.
    run_apk textarea-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity textarea \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script textarea)'"
    # The sections scene: M3 NavigationBar, the presentation context.
    run_apk sections-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity sections \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script sections)'"
    # The menus scene: the command catalog in the top bar's overflow,
    # promoted primaries as bar actions, long-press context menus, and
    # the shortcut verb through the interpreter's dispatch table.
    run_apk menus-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity menus \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script menus)'"
    # The listdetail scene: list-detail's bare invariant, which is the
    # only form of it this host can run — the `split` scene drives
    # resize_window, and Android does not command its own window size
    # (the system owns it; DESIGN.md, Windows).
    run_apk listdetail-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity listdetail \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script listdetail)'"
    # The same APK and the same scene on the tablet, and the reason
    # that scene exists. The pool above is ALWAYS compact, so the
    # invariant is vacuous there — the leg can only report that the
    # stacked arm ran. This device is 1280dp, past Material's 840, so
    # the invariant bites: with the detail pushed, one pane on screen
    # is a failure.
    #
    # The appended steps are the two claims the shared file may not
    # carry, because both are only true at a regular width. First the
    # literal, which turns "did not violate the invariant" into "the
    # split arm ran". Then THE BACK RULE: with both panes on screen
    # back reveals nothing, so it must not pop — Compose's own rule
    # (canNavigateBack is false in this state), spelled here as a
    # disabled BackHandler. This is the only leg in any lane that
    # reaches Compose's split arm, so it is the only place that rule
    # can be asserted at all.
    run_apk_tablet listdetail-compose-tablet \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity listdetail \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script listdetail);expect_split \"regular/split\";back;expect_entries 1;expect_split \"regular/split\"'"
    # The commands scene, the DEPTH slice (rust only until the sweep).
    run_apk commands-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity commands \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script commands)'"
    drain
    timing legs-compose
fi

if [ "$SUITE" = jvm ] || [ "$SUITE" = all ]; then
    JNILIBS="$ROOT/android/milestone2kt/src/main/jniLibs/arm64-v8a"
    mkdir -p "$JNILIBS"
    cargo ndk -t arm64-v8a build --locked --lib || exit 1
    cp "$ROOT/target/aarch64-linux-android/debug/libkaya.so" "$JNILIBS/"
    "$ROOT/tools/build-id.sh" --verify "$JNILIBS/libkaya.so" || exit 1
    kaya_write_compose_marker
    (cd android && gradle --console=plain -q :milestone2kt:assembleDebug) || exit 1
    "$ROOT/tools/build-id.sh" --verify --component compose \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" || exit 1
    timing build-jvm
    run_apk jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity 1 \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script milestone2)'"
    run_apk a11y-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity a11y \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script a11y)'"
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
    # The progress scene through the JVM binding.
    run_apk progress-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity progress \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script progress)'"
    # The select scene through the JVM binding.
    run_apk select-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity select \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script select)'"
    # The radio scene through the JVM binding.
    run_apk radio-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity radio \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script radio)'"
    # The grid scene through the JVM binding.
    run_apk grid-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity grid \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script grid)'"
    # The textarea scene through the JVM binding.
    run_apk textarea-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity textarea \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script textarea)'"
    # The sections scene through the JVM binding.
    run_apk sections-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity sections \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script sections)'"
    # The menus scene through the JVM binding (see the compose leg);
    # this host carries the same dispatchKeyShortcutEvent override, so
    # the chord reaches the catalog identically in both languages.
    run_apk menus-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity menus \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script menus)'"
    # The commands scene through the JVM binding (see the compose leg).
    run_apk commands-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity commands \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script commands)'"
    drain
    timing legs-jvm
fi

exit "$status"
