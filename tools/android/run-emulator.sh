#!/usr/bin/env bash
# The menus scene runs both legs here: compose (the rust guest on the
# Compose interpreter) and jvm (the Kotlin guest over milestone2kt's
# "menus" arm). Hardware chords reach the catalog through each host
# Activity's dispatchKeyShortcutEvent override.

# The panels scene is desktop-only BY DESIGN and deliberately not a
# leg here: create_window is capability-rejected on this host (no
# KAYA_CAP_AUX_WINDOWS — the system owns surfaces; DESIGN.md,
# Presentation contexts).
kaya_flake="$(cd "$(dirname "$0")/../.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# Build, install, and self-test the milestone scene in the Android
# emulator.
# Usage: tools/android/run-emulator.sh [compose|jvm|go|all]
#
# rust    - the app logic as a Rust cdylib behind the JNI entry
# jvm     - the JVM app itself as the guest, over the direct ring tier
# compose - the rust app on the Compose interpreter
# go      - a Go guest as a c-shared .so on the same direct ring, loaded
#           by a shell Activity (docs/go-mobile-plan.md D1)
#
# stdout is invisible to an Android app process, so selftest results are
# read from logcat.
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

tools/gen-header.sh --check
tools/gen-bindings.sh --check

# AVDs live under target/ so nothing leaks into $HOME.
export ANDROID_AVD_HOME="$ROOT/target/avd"
mkdir -p "$ANDROID_AVD_HOME"
AVD=kaya
IMAGE="system-images;android-35;google_apis;arm64-v8a"
# One tablet alongside the phone pool, for exactly one reason: every
# pool device is 320dp wide, an unambiguously COMPACT window, and
# Material's standard directive shows two panes only at 840dp — so
# nothing else in this lane could observe the list-detail SPLIT arm, and
# a wrong one compiled and passed everything. This is the iOS lane's
# iPad: one device carrying one scene, form-factor coverage rather than
# device-matrix breadth.
TABLET_AVD=kaya-tablet

if ! avdmanager list avd -c 2>/dev/null | grep -qx "$AVD"; then
    echo "no" | avdmanager create avd -n "$AVD" -k "$IMAGE" >/dev/null
fi
if ! avdmanager list avd -c 2>/dev/null | grep -qx "$TABLET_AVD"; then
    # medium_tablet: a 2560x1600 panel at density 320 whose NATURAL
    # orientation is landscape, so a headless instance comes up at 1280dp,
    # past Material's 840. Measured both ways: rotated to portrait the same
    # device reports 800dp, INSIDE the 400..840 band where the platforms
    # legitimately disagree about pane count. config.ini's
    # hw.initialOrientation does NOT decide this, which is why the width is
    # ASSERTED at boot below.
    echo "no" | avdmanager create avd -n "$TABLET_AVD" -k "$IMAGE" -d medium_tablet >/dev/null
fi

# A pool of emulators (KAYA_ANDROID_EMUS wide) runs the legs in
# parallel. All pool instances share the one AVD READ-ONLY — the sharing
# rule is all-or-nothing, a read-write instance locks every sibling out
# — and read-only instances quickboot from the snapshot in ~2-4s. The
# snapshot itself can only be written by a read-write instance, so it is
# created once here. Pool instances stay warm across runs on purpose.
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
# The tablet takes the port after the pool's and is NOT a pool member:
# a leg that claimed it from the pool would leave the other legs' size
# class up to a race.
TABLET_PORT=$((5554 + 2 * POOL))
TABLET_SERIAL="emulator-$TABLET_PORT"
make_snapshot "$TABLET_AVD" "$TABLET_PORT"
if ! adb -s "$TABLET_SERIAL" get-state 2>/dev/null | grep -q device; then
    emulator -avd "$TABLET_AVD" -read-only -no-window -no-audio -no-boot-anim \
        -gpu swiftshader_indirect -port "$TABLET_PORT" \
        >"$ROOT/target/emu-$TABLET_PORT.log" 2>&1 &
fi
# THE LANE'S FOREIGN CLIPBOARD APP. Every assertion in the clipboard
# scene crosses a process boundary on purpose: a check where kaya reads
# what kaya wrote parses its own malformed lowering perfectly happily.
# This host has no `cmd clipboard`, so the outside process is an APK —
# tools/android/cliphelper, which seeds from the BACKGROUND (writes were
# never focus-gated) and reads back as the DEFAULT IME, whose reads
# ClipboardService admits before it ever checks focus, so the guest
# keeps window focus for the whole leg (docs/clipboard-plan.md §7
# finding 1).
#
# A SEPARATE GRADLE BUILD from android/'s, deliberately: a harness-only
# APK must never be one `assemble` away from the module graph the apps
# ship.
CLIPHELPER_PKG=dev.kaya.cliphelper
CLIPHELPER_IME="$CLIPHELPER_PKG/.HelperIme"
CLIPHELPER_APK="$ROOT/tools/android/cliphelper/app/build/outputs/apk/debug/app-debug.apk"
(cd "$ROOT/tools/android/cliphelper" && gradle --console=plain -q :app:assembleDebug) || exit 1
if [ ! -f "$CLIPHELPER_APK" ]; then
    echo "run-emulator: the clipboard helper build produced no apk at" >&2
    echo "  $CLIPHELPER_APK" >&2
    exit 1
fi

for serial in "${SERIALS[@]}" "$TABLET_SERIAL"; do
    boot_wait "$serial"
done

# THE DEVICE IS THIS LANE'S WIDTH, so it owes the rule a resize owes.
# check-steps forbids an expect_split between 400 and 840dp, the band
# where GNOME, Material and TwoPaneView legitimately disagree about pane
# count. Read the dp the apps actually see (`am get-config`'s w<N>dp —
# the device's own answer, not width/density arithmetic a skin could
# make a lie) and refuse a device inside the band. What this catches: a
# tablet that came up portrait at 800dp, and a pool AVD that grows into
# the band during some future retune.
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
# THE POOL STAYS WARM ACROSS RUNS (nothing kills it at exit), so every
# device-global switch this run flips has to come back off. In the trap
# and not at the end of the script because a failed leg, a ^C and a
# `set -e` abort all leave the same mess.
CLIPHELPER_IME_ON=()
kaya_teardown() {
    rm -rf "$LEGS_DIR"
    local serial
    for serial in ${CLIPHELPER_IME_ON[@]+"${CLIPHELPER_IME_ON[@]}"}; do
        adb -s "$serial" shell ime reset >/dev/null 2>&1 || true
    done
}
trap kaya_teardown EXIT

# THE HELPER LANDS ON EVERY POOL DEVICE BEFORE ANY LEG RUNS, and both
# halves are VERIFIED rather than assumed. An absent helper turns every
# clipboard leg into a seed whose latch times out with nothing naming
# the cause; an `ime set` that did not take turns every foreign read
# into a null — and null is also what an empty clipboard, a denied read
# and a locked device answer.
#
# NOT ON THE TABLET: it carries one leg and no clipboard leg may land
# there — it is the one device with no slot lock, so two legs on it
# would share one clipboard. check-steps pins that.
cliphelper_prepare() { # serial
    local serial="$1" tries=0 current=''
    if ! adb -s "$serial" install -r "$CLIPHELPER_APK" >/dev/null; then
        echo "run-emulator: could not install $CLIPHELPER_PKG on $serial" >&2
        return 1
    fi
    if ! adb -s "$serial" shell pm list packages 2>/dev/null | tr -d '\r' \
        | grep -qx "package:$CLIPHELPER_PKG"; then
        echo "run-emulator: $CLIPHELPER_PKG is not on $serial after an install that" >&2
        echo "  reported success — every clipboard leg would seed into nothing" >&2
        return 1
    fi
    # BOUNDED WAIT, because the input method service is registered
    # asynchronously after the install: `ime enable` on its heels answers
    # "Unknown id" and the `ime set` behind it silently keeps the previous
    # keyboard.
    while [ "$tries" -lt 50 ]; do
        if adb -s "$serial" shell ime list -a -s 2>/dev/null | tr -d '\r' \
            | grep -qF "$CLIPHELPER_PKG/"; then
            break
        fi
        tries=$((tries + 1))
        sleep 0.2
    done
    # Neither of these is the check — the poll below is. They are
    # explicitly non-fatal so that stays true whatever `set -e` context a
    # future caller puts this function in.
    adb -s "$serial" shell ime enable "$CLIPHELPER_IME" >/dev/null || true
    adb -s "$serial" shell ime set "$CLIPHELPER_IME" >/dev/null || true
    # AND IT MUST ACTUALLY BE THE SELECTED ONE. `ime set` returns before
    # the setting settles, and the gate that reads it is consulted much
    # later, inside a leg — so poll the setting ClipboardService itself
    # reads (Settings.Secure DEFAULT_INPUT_METHOD, compared by PACKAGE)
    # rather than sleeping and hoping.
    tries=0
    while [ "$tries" -lt 50 ]; do
        current="$(adb -s "$serial" shell settings get secure default_input_method \
            2>/dev/null | tr -d '\r')"
        case "$current" in
            "$CLIPHELPER_PKG/"*) return 0 ;;
        esac
        tries=$((tries + 1))
        sleep 0.2
    done
    echo "run-emulator: $CLIPHELPER_IME did not become the default IME on $serial" >&2
    echo "  (default_input_method reads \"$current\") — the helper's reads would" >&2
    echo "  answer null, which is what an empty clipboard answers too" >&2
    return 1
}
# THE ASSET ROOT, ON EVERY POOL DEVICE BEFORE ANY LEG RUNS.
# `asset(name)` resolves every asset out of ONE root
# (docs/assets-plan.md A2) and the core finds that root through
# KAYA_ASSET_DIR, so what a device needs is the root, once, rather than
# one push per asset.
#
# /data/local/tmp, AND THAT WAS MEASURED FROM THE APP rather than
# assumed. SELinux stops untrusted_app reading shell_data_file on many
# images, and `run-as` CANNOT answer the question — it runs as
# runas_app, a domain that may read what the app itself may not. The
# proof is the typeface scene's own verdict on emulator-5554
# (android-35 google_apis arm64) with the font pushed here and nowhere
# else, and the control, the same leg pointed one path over, which dies
# in the guest naming the root it could not read.
#
# BY HASH AND NOT BY SIZE: a short push is what a size check catches,
# and a same-length corruption passes one and then fails three removes
# away — the typeface leg reports a resolved family that is not Sora
# and the identity leg reports declared bytes BitmapFactory refused.
# Both read as lowering bugs to anyone who did not push the file.
#
# THE IDENTITY GUESTS NAME NO FILE ANY MORE. The declaration is still
# read here — the HOST side of it, for apk_icon_verify, which holds the
# bytes gradle packaged against the bytes guests/assets/identity.toml
# declares (docs/app-identity-plan.md ruling 4).
ASSET_SRC="$ROOT/guests/assets"
ASSET_ON_DEVICE=/data/local/tmp/kaya-assets
# The subdirectory of the APK's own `assets/` that IS kaya's asset root.
# One string, three files: this, KayaAssets.kt's `ROOT`, and
# android/build.gradle.kts's `kayaAssetPrefix`. tools/check-assets.sh's
# C7 refuses if the three disagree — the build would copy into one and
# the reader would read the other, and the miss sentence would name a
# census the app cannot produce.
APK_ASSET_PREFIX=kaya

asset_hashes_agree() { # serial listing-file
    python3 - "$ASSET_SRC" "$ASSET_ON_DEVICE" "$1" "$2" <<'PY'
import hashlib
import pathlib
import sys

src, prefix, serial = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
there = {}
for line in pathlib.Path(sys.argv[4]).read_text().splitlines():
    line = line.strip()
    if not line or " " not in line:
        continue
    digest, path = line.split(None, 1)
    if len(digest) != 64:
        continue
    path = path.strip()
    if not path.startswith(prefix + "/"):
        continue
    there[path[len(prefix) + 1:]] = digest.lower()
here = {
    f.relative_to(src).as_posix(): hashlib.sha256(f.read_bytes()).hexdigest()
    for f in sorted(src.rglob("*")) if f.is_file()
}
bad = []
for name, want in sorted(here.items()):
    got = there.get(name)
    if got is None:
        bad.append(f"  {name}: never arrived")
    elif got != want:
        bad.append(f"  {name}: arrived as {got[:12]}, the tree has {want[:12]}")
for name in sorted(set(there) - set(here)):
    bad.append(f"  {name}: is on the device and not in the tree — a stale "
               "asset a guest can still resolve by name")
if not here:
    bad.append("  the tree's asset root is empty, so this comparison would "
               "agree with an empty device")
if bad:
    print(f"run-emulator: the asset root on {serial} does not match the tree:")
    print("\n".join(bad))
    print("  a leg would then fail three removes away — a resolved family "
          "that is not Sora, or declared bytes the decoder refused")
    sys.exit(1)
print(f"assets: {len(here)} files on {serial}, every one hash-equal to the tree")
PY
}
KAYA_IDENTITY_MANIFEST="$ROOT/guests/assets/identity.toml"
ICON_REL="$(python3 - "$KAYA_IDENTITY_MANIFEST" <<'PY'
import pathlib
import sys
import tomllib

man = pathlib.Path(sys.argv[1])
if not man.is_file():
    sys.exit(f"run-emulator: {man} is missing — the app identity is declared "
             f"there and the APK reads its icon and label from it "
             f"(docs/app-identity-plan.md ruling 4)")
decl = tomllib.loads(man.read_text(encoding="utf-8"))
icon = decl.get("icon")
if not isinstance(icon, str) or not icon.strip():
    sys.exit(f"run-emulator: {man} declares no `icon`, so there is no mark to "
             f"push to any device")
print(icon)
PY
)"
icon_rel_rc=$?
if [ "$icon_rel_rc" -ne 0 ] || [ -z "$ICON_REL" ]; then
    echo "run-emulator: could not read the declared icon from $KAYA_IDENTITY_MANIFEST" >&2
    exit 1
fi
# The declared mark on the HOST, where apk_icon_verify hashes it
# against what gradle packaged — the one derived value left, and still
# derived rather than retyped.
ICON_SRC="$ROOT/$ICON_REL"
assets_prepare() { # serial
    local serial="$1" listing verdict rc
    adb -s "$serial" shell rm -rf "$ASSET_ON_DEVICE" >/dev/null 2>&1 || true
    if ! adb -s "$serial" push "$ASSET_SRC" "$ASSET_ON_DEVICE" >/dev/null; then
        echo "run-emulator: could not push $ASSET_SRC to $serial" >&2
        return 1
    fi
    adb -s "$serial" shell chmod -R 755 "$ASSET_ON_DEVICE" >/dev/null 2>&1 || true
    listing="$(mktemp)"
    adb -s "$serial" shell "find $ASSET_ON_DEVICE -type f -exec sha256sum {} +" 2>&1 | tr -d '\r' >"$listing"
    verdict="$(asset_hashes_agree "$serial" "$listing")"
    rc=$?
    rm -f "$listing"
    printf '%s\n' "$verdict"
    return "$rc"
}
for serial in "${SERIALS[@]}"; do
    cliphelper_prepare "$serial" || exit 1
    CLIPHELPER_IME_ON+=("$serial")
    assets_prepare "$serial" || exit 1
done
timing cliphelper

# THE SELECTION HALF OF THE ABOVE, ON ITS OWN, because the default
# input method DOES NOT STAY PUT: measured 2026-08-06 on emulator-5554,
# the selection reverted to the stock keyboard between runs with
# nothing in this lane asking it to. The clipboard leg tolerates that;
# the RANGES leg cannot — D4's whole assertion is that a composing
# region is still open when the app's select arrives, and a third-party
# input method finishes a composing region it did not create within
# tens of milliseconds. So the ranges leg re-asserts this immediately
# before it runs.
select_helper_ime() { # serial
    local serial="$1" tries=0 current=''
    adb -s "$serial" shell ime enable "$CLIPHELPER_IME" >/dev/null || true
    adb -s "$serial" shell ime set "$CLIPHELPER_IME" >/dev/null || true
    while [ "$tries" -lt 50 ]; do
        current="$(adb -s "$serial" shell settings get secure default_input_method \
            2>/dev/null | tr -d '\r')"
        case "$current" in
            "$CLIPHELPER_PKG/"*) return 0 ;;
        esac
        tries=$((tries + 1))
        sleep 0.2
    done
    echo "run-emulator: $CLIPHELPER_IME is not the default IME on $serial" >&2
    echo "  (default_input_method reads \"$current\") — the ranges leg's D4 step needs a" >&2
    echo "  device where nothing else is composing, and another input method will" >&2
    echo "  finish the composing region before the select arrives" >&2
    return 1
}

# WHAT "BOUND" IS RECOGNISED BY, and why it is asserted rather than
# assumed. `dumpsys accessibility` prints its bound set as
# `Bound services:{Service[label=...]}` — a LABEL and no component — so
# the only thing this runner can match on is a name the harness service
# gives itself. It used to match the bare word "kaya", which worked by
# ACCIDENT: the service declared no label and inherited the
# application's.
#
# The app identity slice took the accident away
# (docs/app-identity-plan.md ruling 3): android:label is now the
# DECLARED name, which contains no "kaya" — and the bind check then
# failed on all three pool devices, every leg reporting a picker that
# never came up, with nothing anywhere naming the cause (MEASURED
# 2026-08-18). So the service names ITSELF now and the two sides are
# checked against each other here: the manifests cannot see this grep,
# and this grep cannot see the manifests.
A11Y_LABEL="kaya harness"
a11y_label_check() {
    python3 - "$A11Y_LABEL" android/*/src/main/AndroidManifest.xml <<'A11YPY'
import pathlib
import re
import sys

want = sys.argv[1]
bad = []
seen = 0
for path in sys.argv[2:]:
    text = pathlib.Path(path).read_text(encoding="utf-8")
    for service in re.findall(r"<service\b.*?</service>", text, re.S):
        if "KayaHarnessAccessibility" not in service:
            continue
        seen += 1
        if 'android:label="%s"' % want not in service:
            bad.append(
                "%s: the harness accessibility service declares no "
                'android:label="%s", so dumpsys prints whatever label it '
                "inherits — today the app's DECLARED name — and this runner's "
                "bind check greps that label. Every leg on every device would "
                "fail saying the picker never came up." % (path, want))
if not seen:
    bad.append("no android/*/src/main/AndroidManifest.xml declares "
               "KayaHarnessAccessibility at all — this check read nothing and "
               "would agree with any label")
if bad:
    sys.exit("run-emulator: " + "\n  ".join(bad))
print('run-emulator: harness a11y label "%s" declared by %d apps' % (want, seen))
A11YPY
}
a11y_label_check || exit 1

leg_names=()
leg_pids=()
# The tablet's leg is tracked apart from the pool's: riding leg_pids it
# would count against the phone pool's saturation gate, throttling a
# pool it does not use and eventually tripping its wedge watchdog.
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
    local serial="$1" name="$2" apk="$3" component="$4" script="$5"
    shift 5
    local failed=0
    adb -s "$serial" install -r "$apk" >/dev/null
    # THE HARNESS'S EYES OUTSIDE THIS APP. Android's file picker is
    # DocumentsUI, a separate APK, and the platform stops one app reading
    # another's UI — so the scene needs an accessibility service, which
    # only the user (or adb) can enable. Per leg rather than once for the
    # AVD: `install -r` on the app that owns the service can drop it, and a
    # silently-disabled service looks exactly like a picker that never
    # appeared. Declared only by the validation apps, so this reaches no
    # user's app.
    adb -s "$serial" shell am force-stop "${component%%:*}" >/dev/null 2>&1 || true
    adb -s "$serial" shell am force-stop "${component%%/*}"
    # AND THE PICKER, a DIFFERENT PACKAGE that survives the force-stop
    # above: left standing it sits on top of the app's task, and the next
    # leg's `am start` brings that task forward instead of starting the
    # activity — onCreate never runs and the leg reads as a clean run of
    # nothing.
    for picker in com.google.android.documentsui com.android.documentsui; do
        adb -s "$serial" shell am force-stop "$picker" >/dev/null 2>&1 || true
    done
    adb -s "$serial" logcat -c
    # ENABLED HERE, AFTER force-stop AND logcat -c, and the order is the
    # whole trick: force-stop kills every component of the package —
    # including this service, which the validation app declares — and
    # logcat -c wipes the connection message that proves it came up.
    local a11y="${component%%/*}/dev.kaya.KayaHarnessAccessibility"
    # THE ARM, RETRIED, because enabling races the install that precedes
    # it. MEASURED 2026-08-06, after three lane runs died to "never bound"
    # on three different devices: on an IDLE device the identical sequence
    # binds in ONE SECOND. What differs in a lane is that `install -r` has
    # just REPLACED the package that declares this service, and enabling on
    # the heels of that replacement sometimes lands before the package
    # manager has finished — the setting reads correct, dumpsys says
    # Enabled, and Bound stays empty forever. Re-arming costs a second; a
    # reboot is the last resort because it was proven to work when
    # re-arming was never tried.
    #
    # CLEARED BEFORE EACH SET: `settings put` with the value already there
    # is a no-op, and a no-op notifies nobody.
    local a11y="${component%%/*}/dev.kaya.KayaHarnessAccessibility"
    local bound=0 arm=0
    while [ "$arm" -lt 3 ] && [ "$bound" != 1 ]; do
        arm=$((arm + 1))
        adb -s "$serial" shell settings put secure enabled_accessibility_services "" >/dev/null
        adb -s "$serial" shell settings put secure enabled_accessibility_services "$a11y" >/dev/null
        adb -s "$serial" shell settings put secure accessibility_enabled 1 >/dev/null
        local tries=0
        while [ "$tries" -lt 50 ]; do
            if adb -s "$serial" shell dumpsys accessibility 2>/dev/null \
                | tr -d '\r' | grep -q "Bound services:.*$A11Y_LABEL"; then
                bound=1
                break
            fi
            tries=$((tries + 1))
            sleep 0.2
        done
        if [ "$bound" != 1 ] && [ "$arm" -lt 3 ]; then
            echo "run-emulator: $serial did not bind on arm $arm — re-arming" >&2
        fi
    done
    if [ "$bound" != 1 ] && [ "${KAYA_A11Y_REBOOTED:-}" != "$serial" ]; then
        echo "run-emulator: $serial did not bind after 3 arms — rebooting it once" >&2
        adb -s "$serial" reboot >/dev/null 2>&1
        adb -s "$serial" wait-for-device >/dev/null 2>&1
        local waited=0
        while [ "$waited" -lt 90 ]; do
            if [ "$(adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
                break
            fi
            waited=$((waited + 1))
            sleep 1
        done
        sleep 5
        KAYA_A11Y_REBOOTED="$serial" run_apk_on "$serial" "$name" "$apk" "$component" "$script" "$@"
        local retry_rc=$?
        return "$retry_rc"
    fi
    if [ "$bound" != 1 ]; then
        echo "run-emulator: the harness accessibility service never bound on $serial" >&2
        echo "  (three arms and a reboot; enabled_accessibility_services was set to" >&2
        echo "   $a11y, but the system never bound it — the scene would report a" >&2
        echo "   picker that never came up)" >&2
        return 1
    fi
    local rec_pid=
    local rec_extra=()
    if [ -n "${KAYA_RECORD:-}" ]; then
        adb -s "$serial" shell rm -f "/data/local/tmp/kaya-rec.mp4"
        adb -s "$serial" shell screenrecord "/data/local/tmp/kaya-rec.mp4" &
        rec_pid=$!
        rec_extra=(--es KAYA_RECORD 1)
    fi
    adb -s "$serial" shell am start -W -n "$component" --es KAYA_SELFTEST "$script" ${rec_extra[@]+"${rec_extra[@]}"} "$@" >/dev/null
    # The selftest exits the app at ~2.5s; grab the scene while it is still
    # up. logcat then reads the verdict from the buffer even if it was
    # emitted before the watch attached.
    #
    # (NO PER-LEG SCREENSHOT. 48 of 52 outputs were the launcher's
    # WALLPAPER, because the app had already exited — worse than no
    # screenshot, because it looks like evidence. Not fixable by tuning the
    # wait: measured 2026-07-27, `am start -W` already blocks until the
    # first frame, the scene runs to its verdict ~300ms later, and 2s, 1s
    # and 0s all landed on wallpaper or on the launch splash. The recording
    # pipeline is the visual record — `KAYA_RECORD=1` when you want
    # pictures.)
    local out
    out=$(timeout 60 adb -s "$serial" logcat -s kaya:* -e 'KAYA_SELFTEST: (OK|FAILED)' -m 1) || true
    printf '%s\n' "$out"
    if [ -n "${KAYA_RECORD:-}" ]; then
        local dir="$ROOT/target/recordings/android/$name"
        mkdir -p "$dir"
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
        #
        # THREE TAGS, NOT ONE. AndroidRuntime carries JVM exceptions
        # only; a GO guest's panic goes to Go's runtime log under the
        # tag `Go`, so a Go crash used to leave this branch printing
        # NOTHING AT ALL (measured 2026-08-07). DEBUG:F is the tombstone
        # header, which covers the rest of the native aborts.
        #
        # THE SENTENCE THAT NAMES THE CAUSE COMES FIRST, AND WHOLE. A
        # CORE refusal is a Rust panic under the `kaya` tag at level E,
        # and a tombstone puts its `Abort message:` ABOVE its frames, so
        # `tail -30` of a forty-frame stack drops exactly the line a
        # reader needs. MEASURED 2026-08-19: an identity guest that
        # ignored `kaya.Capabilities().AuxWindows` died with "this host
        # has no auxiliary windows" in the buffer and this branch
        # printed forty lines of libart addresses instead.
        adb -s "$serial" logcat -d -b crash,main -s AndroidRuntime:E Go:E kaya:E DEBUG:F \
            2>/dev/null | grep -E "panicked at|Abort message|FATAL EXCEPTION" | head -5
        adb -s "$serial" logcat -d -s AndroidRuntime:E Go:E DEBUG:F | tail -30
        failed=1
    fi
    [ "$failed" = 0 ]
}

# The Kotlin interpreter reads the scene script from the environment.
# Intent extras cannot carry newlines through the shell, so comments
# are stripped and lines fold into `;`, the grammar's newline stand-in.
scene_script() { grep -v '^#' "$ROOT/tools/scenes/$1.steps" | tr '\n' ';'; }

# THE PHONE-EXPRESSIBLE PREFIX of a shared scene: everything above the
# CUT VERB, for a scene that is mostly runnable here and desktop-only in
# its TAIL. This runner declines WHOLE scenes for that reason at the top
# of the file (`split` drives resize_window, `panels` drives
# create_window); `dirty` is the first that only goes out of reach at
# the end.
#
# THE SHARED FILE STAYS BYTE-FROZEN: the prefix is its own bytes, and
# the steps this lane did NOT run are printed, so a green leg still says
# what it declined.
#
# THE TWO WAYS A CUT GOES QUIET, BOTH REFUSED HERE: the cut verb leaving
# the scene (the cut is then stale), and the cut swallowing the very
# assertion the leg exists for. The second is not hypothetical — cut
# `dirty` one step earlier, at `click button#0`, and the prefix asserts
# `dirty false` and never `dirty true`. So the KEEP VERB is mandatory
# and the comparison is against the WHOLE file.
#
# THIS IS THE iOS LANE'S SHAPE, deliberately: the two mobile lanes meet
# the same tail on the same scene, and two answers to one question is
# how lanes drift.
scene_script_cut() { # scene cut-verb keep-verb
    python3 - "$ROOT/tools/scenes/$1.steps" "$2" "$3" <<'PY'
import pathlib
import sys

path, cut, keep = sys.argv[1], sys.argv[2], sys.argv[3]
# A CUT WITHOUT A `keep` IS AN UNGUARDED CUT, and an optional guard is
# the kind that is quietly not passed.
#
# A LIST, because one scene's tail can be below more than one thing the
# leg exists to assert. THE iOS LANE TAKES THE SAME LIST — two mobile
# lanes, one question, and two answers is how lanes drift.
keeps = keep.split()
if not keeps:
    sys.exit(f"run-emulator: cutting {path} at `{cut}` with no `keep` verb — "
             f"say which assertions this cut may not take with it, or the leg "
             f"can be trimmed until it asserts nothing")
lines = [line.strip() for line in pathlib.Path(path).read_text().splitlines()
         if line.strip() and not line.lstrip().startswith("#")]
verbs = [(line.split() or [""])[0] for line in lines]
if cut not in verbs:
    sys.exit(f"run-emulator: {path} has no `{cut}` step, so this lane's cut is "
             f"stale — the scene was reshaped and nobody re-read what the phone "
             f"can express. Fix the leg, do not widen the cut.")
at = verbs.index(cut)
prefix, dropped = lines[:at], lines[at:]


def asserted(seq, verb):
    """The distinct `verb` steps in seq, whitespace-normalized."""
    return {" ".join(line.split()) for line in seq
            if (line.split() or [""])[0] == verb}


for verb in keeps:
    whole, kept = asserted(lines, verb), asserted(prefix, verb)
    if not kept:
        sys.exit(f"run-emulator: cutting {path} at `{cut}` leaves no `{verb}` "
                 f"step at all — the leg would pass without asserting the thing "
                 f"it exists for")
    if kept != whole:
        sys.exit(f"run-emulator: cutting {path} at `{cut}` drops "
                 f"{sorted(whole - kept)} — the cut may not take an assertion of "
                 f"`{verb}` with it")
print("\n".join(f"run-emulator: NOT RUN on this host (after `{cut}`): {line}"
                for line in dropped), file=sys.stderr)
print(";".join(prefix) + ";")
PY
}

# ONE STEP OUT OF THE MIDDLE, where a CUT can only take a tail.
#
# The identity scene's one desktop-only step is `expect_title window#1`,
# which reads the declared NAME off a window that has no title of its
# own — and this host has no auxiliary windows at all. Below that step
# sit the live widgets and the SECOND expect_app_icon, so a cut would
# take all of it.
#
# THE SHARED FILE STAYS BYTE-FROZEN and the dropped step is printed.
# Every guard here is scene_script_cut's, restated for a middle step:
#
#   THE STEP MUST BE THERE, EXACTLY ONCE. Not there means the scene was
#   reshaped and this drop is stale; more than once means it is
#   ambiguous about which one it takes.
#   THE KEEP VERBS ARE MANDATORY, and every distinct assertion each one
#   makes anywhere in the file must survive.
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
    sys.exit(f"run-emulator: dropping `{verb} {target}` from {path} with no `keep` "
             f"verb — say which assertions this drop may not take with it, or the "
             f"leg can be trimmed until it asserts nothing")
lines = [" ".join(line.split()) for line in pathlib.Path(path).read_text().splitlines()
         if line.strip() and not line.lstrip().startswith("#")]
hits = [i for i, line in enumerate(lines)
        if line.split()[:2] == [verb, target]]
if len(hits) != 1:
    sys.exit(f"run-emulator: {path} has {len(hits)} `{verb} {target}` steps and this "
             f"lane drops exactly one — the scene was reshaped and nobody re-read "
             f"what the phone can express. Fix the leg, do not widen the drop.")
kept = lines[:hits[0]] + lines[hits[0] + 1:]


def asserted(seq, v):
    """The distinct `v` steps in seq, whitespace-normalized."""
    return {line for line in seq if line.split()[:1] == [v]}


for v in keeps:
    whole, survived = asserted(lines, v), asserted(kept, v)
    if not survived:
        sys.exit(f"run-emulator: dropping `{verb} {target}` from {path} leaves no "
                 f"`{v}` step at all — the leg would pass without asserting the "
                 f"thing it exists for")
    if survived != whole:
        sys.exit(f"run-emulator: dropping `{verb} {target}` from {path} takes "
                 f"{sorted(whole - survived)} — the drop may not take an assertion "
                 f"of `{v}` with it")
print(f"run-emulator: NOT RUN on this host (no auxiliary windows): {lines[hits[0]]}",
      file=sys.stderr)
print(";".join(kept) + ";")
PY
}

# The sections tail opens an aux window this host rejects by
# capability; the cut boundary is the tail's own first verb
# (expect_windows appears nowhere above it), and the keep guard holds
# every expect_section above the cut. Assigned HERE, not inline: a
# refused cut must kill the lane, not run an empty script — measured
# 2026-08-16, three legs green-on-nothing ("script has no expects").
SECTIONS_CUT="$(scene_script_cut sections expect_windows "expect_section expect_section_symbol")" || exit 1

# The identity scene's one desktop-only step, dropped for every suite
# rather than per block: all three guests ask the core
# (`kaya_capabilities`) rather than each deriving it from its own
# platform predicate, so all three run the same script. Assigned HERE
# for SECTIONS_CUT's reason — a refused drop must kill the lane, not
# run a script the drop never checked.
IDENTITY_SCRIPT="$(scene_script_drop identity expect_title window#1 \
    expect_app_icon)" || exit 1

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

# RULING 4'S BYTE EQUALITY, ASSERTED ON THE ARTIFACT ITSELF: the bytes
# INSIDE the apk gradle just wrote against the bytes
# guests/assets/identity.toml declares. The failure mode is the quiet
# kind — the launcher shows last month's icon, the running window shows
# this month's, and every test still passes, because each reader is
# internally consistent.
#
# HERE AND NOT IN A GATE, because invariant 3 puts the wall where
# someone walks into it: the packaging step refuses, so no leg ever
# installs an apk carrying a mark nobody declared.
#
# The entry name is android/build.gradle.kts's, which pins
# `isCrunchPngs = false` so aapt cannot re-encode behind this check.
apk_icon_verify() { # apk
    local apk="$1" declared packaged
    if ! unzip -l "$apk" res/mipmap/kaya_mark.png >/dev/null 2>&1; then
        echo "run-emulator: $apk carries no res/mipmap/kaya_mark.png — the app" >&2
        echo "  identity's picture never reached the package, so its launcher icon" >&2
        echo "  is whatever Android draws for an app that declares none" >&2
        echo "  (android/build.gradle.kts is the reader; $ICON_REL is the source)" >&2
        return 1
    fi
    declared="$(shasum -a 256 <"$ICON_SRC" | cut -d' ' -f1)"
    packaged="$(unzip -p "$apk" res/mipmap/kaya_mark.png | shasum -a 256 | cut -d' ' -f1)"
    if [ "$declared" != "$packaged" ]; then
        echo "run-emulator: the mark inside $apk is not the declared one." >&2
        echo "  declared ($ICON_REL): $declared" >&2
        echo "  packaged (res/mipmap/kaya_mark.png): $packaged" >&2
        echo "  One picture is the picture on all five platforms (ruling 1); two" >&2
        echo "  readers that disagree is the failure ruling 4 exists to prevent." >&2
        return 1
    fi
}

# THE SAME BYTE EQUALITY, FOR THE WHOLE ASSET ROOT (docs/assets-plan.md
# A6 Gate 2). Android is the ONE platform whose packaged assets are not
# files: an entry inside an APK has no path and is read through
# AssetManager. One leg below deliberately arrives with no
# KAYA_ASSET_DIR and resolves out of the package itself, and the miss
# sentence it freezes is a CENSUS of what the package carries.
#
# HERE AND NOT IN A GATE, as apk_icon_verify is: the wall goes where
# someone walks into it by building.
#
# BOTH DIRECTIONS. A missing entry is the obvious failure; an EXTRA one
# is the failure the census actually catches, because a stray file in
# `assets/` puts a name in the sentence no other platform prints.
apk_assets_verify() { # apk
    local apk="$1" listing
    listing="$(mktemp)"
    if ! unzip -Z1 "$apk" "assets/$APK_ASSET_PREFIX/*" >"$listing" 2>/dev/null; then
        : # an apk with no matching entries exits non-zero; the compare says so
    fi
    python3 - "$ASSET_SRC" "$apk" "$APK_ASSET_PREFIX" "$listing" <<'PY'
import hashlib
import pathlib
import subprocess
import sys

src, apk, prefix, listing = (
    pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], pathlib.Path(sys.argv[4])
)
root = f"assets/{prefix}/"
packaged = [
    ln.strip() for ln in listing.read_text().splitlines()
    if ln.strip().startswith(root) and not ln.strip().endswith("/")
]
here = {
    f.relative_to(src).as_posix(): hashlib.sha256(f.read_bytes()).hexdigest()
    for f in sorted(src.rglob("*")) if f.is_file()
}
there = {e[len(root):]: e for e in packaged}
bad = []
if not here:
    bad.append("  the tree's asset root is empty, so this comparison would agree "
               "with an empty package")
for name, want in sorted(here.items()):
    entry = there.get(name)
    if entry is None:
        bad.append(f"  {name}: is not in the apk under {root}")
        continue
    got = hashlib.sha256(subprocess.run(
        ["unzip", "-p", apk, entry], capture_output=True, check=True).stdout).hexdigest()
    if got != want:
        bad.append(f"  {name}: packaged as {got[:12]}, the tree has {want[:12]}")
for name in sorted(set(there) - set(here)):
    bad.append(f"  {name}: is in the apk and not in the tree — the app's own "
               "census would name an asset no other platform carries")
if bad:
    print(f"run-emulator: the assets inside {apk} are not the tree's:")
    print("\n".join(bad))
    print(f"  android/build.gradle.kts copies {src} into {root} at configuration")
    print("  time; the leg that runs with no KAYA_ASSET_DIR reads exactly these")
    print("  entries, and tools/scenes/assets.steps freezes their names")
    sys.exit(1)
print(f"assets: {len(here)} files inside {apk.rsplit('/', 1)[-1]} under {root}, "
      "every one byte-equal to the tree")
PY
    local rc=$?
    rm -f "$listing"
    return "$rc"
}

# THE GO GUEST'S ARTIFACT: a `-buildmode=c-shared` .so the shell
# Activity loads beside libkaya.so (docs/go-mobile-plan.md D1).
#
# THREE THINGS THIS FUNCTION REFUSES TO ASSUME, each of which fails far
# from its cause when it is wrong:
#
#   1. THE NDK API LEVEL FOLLOWS THE MODULE'S minSdk, read out of the
#      module's own build.gradle.kts rather than written twice. A guest
#      cross-built against a newer platform links fine and dies at load
#      time with a relocation nobody can read.
#   2. THE JNI SYMBOL MUST BE IN THE BUILT .so. It is the one name
#      binding KayaGo.kt to bindings/go/android.go and NO COMPILER ON
#      EITHER SIDE CHECKS IT.
#   3. THE COPY into jniLibs is what gradle packages, so that is what
#      gets checked.
kaya_go_build() { # lib-name jnilibs-dir
    local lib="$1" jnilibs="$2"
    local module="$ROOT/android/milestone2go/build.gradle.kts"
    local api ndkbin out
    api="$(python3 - "$module" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
# The one `minSdk = N` in the module, ignoring comment lines.
for line in text.splitlines():
    if line.lstrip().startswith("//"):
        continue
    m = re.search(r"\bminSdk\s*=\s*(\d+)", line)
    if m:
        print(m.group(1))
        break
else:
    sys.exit(f"run-emulator: {sys.argv[1]} declares no minSdk, so the Go guest "
             f"has no platform to cross-build against")
PY
)"
    local rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$api" ]; then
        echo "run-emulator: could not read minSdk from $module" >&2
        return 1
    fi
    ndkbin="$(echo "$ANDROID_NDK_ROOT"/toolchains/llvm/prebuilt/*/bin)"
    if [ ! -x "$ndkbin/aarch64-linux-android$api-clang" ]; then
        echo "run-emulator: the NDK has no aarch64-linux-android$api-clang" >&2
        echo "  (looked in $ndkbin; minSdk $api comes from $module)" >&2
        return 1
    fi
    mkdir -p "$ROOT/target/go-android"
    # cgo uses CC to LINK as well as to compile, so the cross compiler
    # rides CC and the #cgo android line in bindings/go/runtime.go carries
    # -L…/aarch64-linux-android/debug -lkaya, filled by the cargo ndk build
    # above. guests/go/cmd IS THE WHOLE GUEST: `-buildmode=c-shared` allows
    # exactly one main package per library.
    CGO_ENABLED=1 GOOS=android GOARCH=arm64 \
        CC="$ndkbin/aarch64-linux-android$api-clang" \
        go build -buildmode=c-shared \
        -o "$ROOT/target/go-android/lib$lib.so" dev.kaya/guests/go/cmd
    local build_rc=$?
    if [ "$build_rc" -ne 0 ]; then
        echo "run-emulator: the Go guest did not cross-build" >&2
        return 1
    fi
    cp "$ROOT/target/go-android/lib$lib.so" "$jnilibs/" || return 1
    # THE LEADING SPACE IS THE POINT. llvm-nm prints `<addr> T <name>`, and
    # cgo emits a SECOND symbol per //export — the generated trampoline
    # `_cgoexp_<hash>_Java_dev_kaya_KayaGo_attach` — which ends in the same
    # characters, so an end-anchor alone counts two.
    out="$("$ndkbin/llvm-nm" -D --defined-only "$jnilibs/lib$lib.so" 2>/dev/null \
        | grep -c ' Java_dev_kaya_KayaGo_attach$')"
    if [ "$out" != 1 ]; then
        echo "run-emulator: lib$lib.so does not export exactly one" >&2
        echo "  Java_dev_kaya_KayaGo_attach (found $out). That symbol is the whole" >&2
        echo "  contract between android/kaya/src/main/kotlin/dev/kaya/KayaGo.kt" >&2
        echo "  and the //export in bindings/go/android.go; nothing else checks" >&2
        echo "  it, and the failure on a device is an UnsatisfiedLinkError in" >&2
        echo "  onCreate that reads as a leg which never printed a verdict." >&2
        return 1
    fi
}

if [ "$SUITE" = compose ] || [ "$SUITE" = all ]; then
    JNILIBS="$ROOT/android/milestone2/src/main/jniLibs/arm64-v8a"
    mkdir -p "$JNILIBS"
    # Builds fail the RUN, loudly: an unguarded build failure would install
    # the PREVIOUS apk and green the legs against stale code (caught live
    # 2026-07-22, a Kotlin compile error produced a zero-verdict run).
    cargo ndk -t arm64-v8a build --locked --example milestone2_android || exit 1
    cp "$ROOT/target/aarch64-linux-android/debug/examples/libmilestone2_android.so" "$JNILIBS/"
    # Verify the COPY, not the source: gradle packages the apk from
    # jniLibs, so this covers the build and the copy at once.
    "$ROOT/tools/build-id.sh" --verify "$JNILIBS/libmilestone2_android.so" || exit 1
    kaya_write_compose_marker
    (cd android && gradle --console=plain -q :milestone2:assembleDebug) || exit 1
    "$ROOT/tools/build-id.sh" --verify --component compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" || exit 1
    apk_icon_verify \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" || exit 1
    apk_assets_verify \
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
    # The stall diagnostic (crates/kaya/src/stall.rs). Core-side, so no
    # Compose arm — the leg is here because a phone is where an app that
    # looks alive and ignores you is hardest to tell from a slow one.
    run_apk stall-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity stall \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script stall)'"
    run_apk confirm-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity confirm \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script confirm)'"
    # The filedialog scene: ACTION_OPEN_DOCUMENT hands off to DocumentsUI,
    # a SEPARATE APP, which is why this lane carries an accessibility
    # service. The scene's files live under the shared Documents
    # collection because no document provider publishes an app's private
    # storage and a picker aimed there opens on Recent instead.
    run_apk filedialog-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity filedialog \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script filedialog)'"
    # The save scene (docs/save-plan.md D5), still a DEPTH slice while the
    # bindings fan out, so rust only.
    #
    # ACTION_CREATE_DOCUMENT, which is DocumentsUI once more. The service
    # tells the two modes apart by the node the create mode inflates
    # (android:id/container_save) rather than by remembering which intent
    # kaya launched, so this leg and the one above prove the discrimination
    # in BOTH directions.
    run_apk save-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity save \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script save)'"
    run_apk nav-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity nav \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script nav)'"
    run_apk scroll-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity scroll \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script scroll)'"
    run_apk progress-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity progress \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script progress)'"
    run_apk select-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity select \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script select)'"
    run_apk radio-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity radio \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script radio)'"
    run_apk grid-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity grid \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script grid)'"
    run_apk textarea-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity textarea \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script textarea)'"
    run_apk sections-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity sections \
        --es KAYA_SELFTEST_SCRIPT "'$SECTIONS_CUT'"
    run_apk menus-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity menus \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script menus)'"
    # THE TOOLBAR SCENE (docs/chrome-plan.md C2), the menus scene's sibling
    # one bit over. Nothing new is lowered on this host, so what this leg
    # exercises is the READ: the composed bar's own subtree, the merged
    # semantics node each button publishes, and the disabled bit
    # `IconButton(enabled=)` puts there. The enablement round trip is the
    # point — the guest writes ONE signal against the menu item and the leg
    # asserts the bar button AND the catalog item follow it in both
    # directions, off two different trees.
    run_apk toolbar-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity toolbar \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script toolbar)'"
    # THE IDENTITY SCENE (docs/app-identity-plan.md, rulings 3 and 4).
    # NOTHING IS LOWERED AT RUNTIME ON THIS HOST and that is the ruling
    # rather than the schedule — Android's launcher icon is part of the
    # installed package, and the running app's one route to a picture,
    # TaskDescription's Bitmap, stays REFUSED (I6).
    #
    # SO WHAT THIS LEG EXERCISES is the read, and the read is of the
    # PACKAGE: PackageManager resolving this app's launcher icon out of the
    # installed APK, sampled at the four quadrant centres. It cannot pass
    # vacuously — the read also requires the wire declaration to have
    # arrived and to sample the same four colours.
    #
    # THIS LEG NAMES NO FILE: the guest says `asset("icons/kaya-mark.png")`
    # and the core resolves it out of the root assets_prepare pushed.
    #
    # ONE STEP IS NOT RUN HERE, printed by scene_script_drop:
    # `expect_title window#1` reads the declared NAME off an auxiliary
    # window, and this host has none.
    run_apk identity-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity identity \
        --es KAYA_SELFTEST_SCRIPT "'${IDENTITY_SCRIPT}'" \
        --es KAYA_ASSET_DIR "$ASSET_ON_DEVICE"
    # The listdetail scene: list-detail's bare invariant, the only form of
    # it this host can run — `split` drives resize_window, and Android does
    # not command its own window size.
    run_apk listdetail-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity listdetail \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script listdetail)'"
    # The same APK and the same scene on the tablet, and the reason that
    # scene exists: the pool is ALWAYS compact, so the invariant is vacuous
    # there. This device is 1280dp, past Material's 840, so it bites.
    #
    # The appended steps are the two claims the shared file may not carry,
    # because both are only true at a regular width: the literal, which
    # turns "did not violate the invariant" into "the split arm ran", and
    # THE BACK RULE — with both panes on screen back reveals nothing, so it
    # must not pop. This is the only leg in any lane that reaches Compose's
    # split arm.
    run_apk_tablet listdetail-compose-tablet \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity listdetail \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script listdetail);expect_split \"regular/split\";back;expect_entries 1;expect_split \"regular/split\"'"
    run_apk commands-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity commands \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script commands)'"
    run_apk a11yrows-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity a11yrows \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script a11yrows)'"
    # THE STYLING SCENE (docs/styling-plan.md slice 1). On this backend the
    # brand SEED drives Material's own scheme derivation, roles lower to
    # M3's emphasis ladder, and `heading` is Compose heading() semantics —
    # the real-tree read expect_ax freezes.
    run_apk styling-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity styling \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script styling)'"
    # THE TYPEFACE SCENE (docs/styling-plan.md slice 2b): the brand
    # typeface swaps the FAMILY and leaves the platform's ramp alone. It
    # exists for the SILENT FALLBACK — every font API renders something for
    # a family it has not got, so only `expect_typeface`, which reads the
    # family the text system ENDED UP WITH, tells a typo, a stale lowering
    # and a working swap apart. The font is `asset("fonts/sora-wght.ttf")`,
    # resolved under the KAYA_ASSET_DIR assets_prepare pushed.
    run_apk typeface-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity typeface \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script typeface)'" \
        --es KAYA_ASSET_DIR "$ASSET_ON_DEVICE"

    # THE ASSETS CONFORMANCE SCENE, AND THIS LEG CARRIES NO
    # KAYA_ASSET_DIR. That omission is the assertion: unset, the core takes
    # its ANDROID route and resolves every asset out of the APK's own
    # `assets/` through AssetManager (crates/kaya/src/assets.rs
    # `Place::Apk`), which is the only route a shipped app has. The staged
    # root is still on this device and this leg does not read it.
    #
    # The scene freezes the miss sentence's CENSUS of what the package
    # carries, so this leg passes only if the apk carries the whole root —
    # which apk_assets_verify checked on the artifact before install.
    run_apk assets-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity assets \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script assets)'"
    # The clipboard scene. The foreign process on the other side of every
    # assertion is dev.kaya.cliphelper, installed and made the default IME
    # on every pool device above; the guest reaches it by ordered
    # broadcast, with nothing per-leg to arrange here.
    #
    # NO DRAIN BRACKET, and that is measured rather than an omission. The
    # rule the other lanes spell with drain is that a leg must read the
    # clipboard THAT LEG WROTE (docs/clipboard-plan.md §0d). HERE A SESSION
    # IS A DEVICE: the pool is separate emulators, each with its own
    # ClipboardService, and §7 finding 4 measured the emulator-host
    # clipboard bridge severed in both directions. run_apk's slot lock
    # already gives a leg its device for the leg's whole duration.
    run_apk clipboard-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity clipboard \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script clipboard)'"
    # The undo scene: ONE history over two tiers (docs/undo-plan.md §3).
    # Both tiers are real here and the routing between them is kaya's,
    # because a focused Compose text field CONSUMES Ctrl+Z whether or not
    # it has anything to undo and the Activity's shortcut route never sees
    # the chord.
    #
    # THIS LEG IS WHERE THE TYPING VERB EARNS ITS KEEP: `type` dispatches
    # real KeyEvents, so the field's own undo stack fills the way a user's
    # typing fills it. A set_text stand-in would CLEAR that stack (D7) and
    # the native tier would have nothing to answer with.
    run_apk background-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity background \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script background)'"
    run_apk undo-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity undo \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script undo)'"
    # The dirty scene (docs/dirty-plan.md). THIS HOST HAS NO CHROME AND
    # THAT IS THE POINT (D4): the prop applies, lowers to nothing visible,
    # and `expect_dirty` reads the applied value back. Synthesizing a
    # marker no native app shows is rejected in the plan, not here.
    #
    # THE SCRIPT STOPS ABOVE THE CHROME CLOSE (scene_script_cut carries the
    # reasoning and the guards): dirty.steps ends with D3's close_window +
    # veto dialog, and this host has neither half. The steps above that
    # line are not a thin slice — the mark goes UP, comes DOWN on save, and
    # goes up again. `expect_dirty` is the keep verb.
    #
    # AND ONE APPENDED CLAIM the shared file may not carry because only
    # SOME platforms can make it: `expect_title "dirty"` says the task
    # label is still exactly the string the app declared — the observable
    # form of "lowers to no chrome" (D4) and "the title is never touched"
    # (D1). WinUI composes its asterisk into the rendered caption, so one
    # byte-compared assertion cannot serve both lanes.
    dirty_script="$(scene_script_cut dirty close_window expect_dirty)" || exit 1
    run_apk dirty-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity dirty \
        --es KAYA_SELFTEST_SCRIPT "'${dirty_script}expect_title \"dirty\"'"
    # The text-ranges scene (docs/ranges-plan.md). THE WHOLE SCRIPT RUNS
    # HERE, unlike `dirty`: nothing in it needs chrome this host has not
    # got. Two of its verbs are reachable only because this harness lives
    # INSIDE the app — `compose` takes the field's own InputConnection (no
    # adb command can open a composing region), and the range reads walk
    # the merged semantics tree from the UI thread.
    #
    # AND IT NEEDS THE LANE'S OWN IME, which cliphelper_prepare already
    # made the default. Measured 2026-08-06 with Gboard instead: the
    # composing region this leg opens is FINISHED by the other input method
    # tens of milliseconds later — an IME resyncs when it sees a composing
    # region it did not create — so the select arrived after the
    # composition was gone, was honoured, and the leg failed with a caret
    # 763 bytes from where it wanted one. D4 needs a device where nothing
    # else is composing.
    #
    # AND THE OFFSETS ARE THE ASSERTION: the document's first line is CJK,
    # so every match sits six bytes further along than in UTF-16 — the unit
    # a Kotlin CharSequence indexes — and a backend forwarding kaya's byte
    # offsets unconverted would decorate six characters early.
    # ...AND THE INPUT METHOD IS RE-ASSERTED FIRST, on every device in the
    # pool, because which one this leg lands on is the pool's choice. The
    # drain is what makes that safe.
    drain
    for serial in "${SERIALS[@]}"; do
        select_helper_ime "$serial" || exit 1
    done
    run_apk ranges-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity ranges \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script ranges)'"
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
    apk_icon_verify \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" || exit 1
    apk_assets_verify \
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
    run_apk stall-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity stall \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script stall)'"
    run_apk confirm-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity confirm \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script confirm)'"
    run_apk nav-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity nav \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script nav)'"
    run_apk scroll-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity scroll \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script scroll)'"
    run_apk progress-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity progress \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script progress)'"
    run_apk select-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity select \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script select)'"
    run_apk radio-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity radio \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script radio)'"
    run_apk grid-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity grid \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script grid)'"
    run_apk textarea-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity textarea \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script textarea)'"
    run_apk sections-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity sections \
        --es KAYA_SELFTEST_SCRIPT "'$SECTIONS_CUT'"
    run_apk menus-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity menus \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script menus)'"
    # The toolbar scene through the JVM binding (see the compose leg).
    # Same shared script, byte for byte, against the same chrome: the
    # promotion bit is a binding spelling all eight languages have
    # shipped since the menus milestone, so this leg's job is to prove
    # the Java guest reaches the identical bar rather than to exercise
    # anything new in the binding.
    run_apk toolbar-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity toolbar \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script toolbar)'"
    # The identity scene through the JVM binding (see the compose leg).
    # What this arm adds is the Java binding's `appIdentity`, and the ONE
    # thing its guest must get right on a phone: Identity.java skips the
    # untitled window on a host with no auxiliary windows, decided at
    # RUNTIME (KayaApp.capabilities()) because one source serves the
    # desktops and this device both.
    run_apk identity-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity identity \
        --es KAYA_SELFTEST_SCRIPT "'${IDENTITY_SCRIPT}'" \
        --es KAYA_ASSET_DIR "$ASSET_ON_DEVICE"
    run_apk listdetail-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity listdetail \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script listdetail)'"
    run_apk commands-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity commands \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script commands)'"
    run_apk clipboard-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity clipboard \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script clipboard)'"
    run_apk background-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity background \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script background)'"
    run_apk undo-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity undo \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script undo)'"
    run_apk styling-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity styling \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script styling)'"
    run_apk typeface-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity typeface \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script typeface)'" \
        --es KAYA_ASSET_DIR "$ASSET_ON_DEVICE"

    run_apk assets-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity assets \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script assets)'" \
        --es KAYA_ASSET_DIR "$ASSET_ON_DEVICE"
    drain
    timing legs-jvm
fi

# THE GO SUITE: the third language on this host, and the first whose
# guest is neither Rust nor a JVM language. The composition is the JVM
# suite's line for line, with ONE forced difference — the JVM shell has
# no way to call a Go function, so the guest's own .so starts the thread
# (KayaGo.attach -> bindings/go/android.go). docs/go-mobile-plan.md D1.
#
# THE SCENE LIST IS THE JVM SUITE'S, ENTRY FOR ENTRY AND IN ITS ORDER.
# That is the whole justification for the set: the two suites are
# comparable leg for leg, which is how uniform binding semantics gets
# checked at all (invariant 1).
#
# NOT WIDER: filedialog, dirty and ranges run from the RUST guest only,
# and each carries host-specific harness plumbing that leg owns. A Go
# leg on any of them would make Go the first NON-RUST guest there,
# which is a sweep of that scene across guest languages, not this depth
# slice. window/panels/split are desktop-only by design.
#
# `editor` IS THE ONE ENTRY THE JVM SUITE DOES NOT HAVE, and that is
# not a coverage divergence: the text editor is a GO app by design and
# there is no rust or jvm guest for it. Its block sits at the end of
# this suite.
#
# NOT NARROWER, and nothing enforces it: check-steps' wired() keys on
# scene x runner and never on language, so a Go suite that stalled at
# six scenes would leave every gate green. Any future divergence has to
# be written down right here.
#
# THE CLIPBOARD DIVERGENCE IS CLOSED (2026-08-19): sceneRoot answers
# the shared Documents collection on android through kaya.Env (the
# 2026-08-18 measured failure was os.TempDir falling back to
# /data/local/tmp with $TMPDIR empty under the JNI attach), and
# milestone2go's manifest declares the cliphelper under `<queries>` —
# without it an explicit broadcast to the helper is filtered out with
# no error anywhere.

# Machine-read by check-steps' wired(), which demands a `run_apk
# <scene>-` leg for every scene not declared here (milestone2 is the
# unprefixed default arm and stays a special case there). The reason is
# the coverage comment above: window/panels/split are desktop-only by
# design.
# shellcheck disable=SC2034  # read by check-steps' wired(), not by this script
ANDROID_DESKTOP_ONLY_SCENES="window panels split"
if [ "$SUITE" = go ] || [ "$SUITE" = all ]; then
    JNILIBS="$ROOT/android/milestone2go/src/main/jniLibs/arm64-v8a"
    mkdir -p "$JNILIBS"
    # The same libkaya.so the JVM suite ships: the Go guest NEEDs it by
    # SONAME and the app's linker resolves it out of this directory.
    cargo ndk -t arm64-v8a build --locked --lib || exit 1
    cp "$ROOT/target/aarch64-linux-android/debug/libkaya.so" "$JNILIBS/"
    "$ROOT/tools/build-id.sh" --verify "$JNILIBS/libkaya.so" || exit 1
    # NO --verify ON THE GO .so: the build id lives inside libkaya, and
    # here libkaya is a SHARED library the guest merely names, so the guest
    # carries no marker. (On iOS the same Go sources DO carry it, because
    # there kaya is a static archive linked in.) What can go stale here is
    # libkaya and the interpreter, and both are verified.
    kaya_go_build milestone2go "$JNILIBS" || exit 1
    kaya_write_compose_marker
    (cd android && gradle --console=plain -q :milestone2go:assembleDebug) || exit 1
    "$ROOT/tools/build-id.sh" --verify --component compose \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" || exit 1
    apk_icon_verify \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" || exit 1
    apk_assets_verify \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" || exit 1
    timing build-go
    run_apk go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity 1 \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script milestone2)'"
    run_apk a11y-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity a11y \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script a11y)'"
    run_apk a11yrows-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity a11yrows \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script a11yrows)'"
    run_apk styling-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity styling \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script styling)'"
    # The typeface scene through the Go binding (see the compose leg).
    # This is the one host where KAYA_ASSET_DIR crosses the environment
    # trap this suite exists to keep honest: the guest reads it with
    # kaya.Env and never os.Getenv, which under the JNI attach answers ""
    # forever — and "" here is not an error, it is the guest's
    # repo-relative default, so a wrong spelling would look like a device
    # that lost the font rather than like the env bug it is
    # (tools/check-go-env.sh is the static half).
    run_apk typeface-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity typeface \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script typeface)'" \
        --es KAYA_ASSET_DIR "$ASSET_ON_DEVICE"

    # The assets scene on the Go tier, taking the APK route like the
    # compose leg: no KAYA_ASSET_DIR anywhere. This is the tier whose
    # environment reads are a known trap, so it is the host where that
    # omission is most worth making.
    run_apk assets-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity assets \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script assets)'"
    run_apk entry-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity entry \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script entry)'"
    run_apk gallery-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity gallery \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script gallery)'"
    run_apk todos-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity todos \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script todos)'"
    run_apk reorder-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity reorder \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script reorder)'"
    run_apk feed-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity feed \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script feed)'"
    run_apk grow-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity grow \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script grow)'"
    run_apk align-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity align \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script align)'"
    run_apk layout-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity layout \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script layout)'"
    # The stall diagnostic through the Go binding: the one scene whose
    # guest carries no runtime.LockOSThread init, and it needs none —
    # bindings/go/android.go locks the thread it hands to the app.
    run_apk stall-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity stall \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script stall)'"
    run_apk confirm-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity confirm \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script confirm)'"
    run_apk nav-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity nav \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script nav)'"
    run_apk scroll-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity scroll \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script scroll)'"
    run_apk progress-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity progress \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script progress)'"
    run_apk select-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity select \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script select)'"
    run_apk radio-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity radio \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script radio)'"
    run_apk grid-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity grid \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script grid)'"
    run_apk textarea-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity textarea \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script textarea)'"
    run_apk sections-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity sections \
        --es KAYA_SELFTEST_SCRIPT "'$SECTIONS_CUT'"
    run_apk menus-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity menus \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script menus)'"
    run_apk toolbar-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity toolbar \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script toolbar)'"
    # The identity scene through the Go binding (see the compose leg). The
    # untitled window is one `if kaya.Capabilities().AuxWindows` rather
    # than a build tag keyed on GOOS. THIS LEG IS WHERE THE ANSWER IS
    # FALSE, so it is the only place the runtime check is exercised in the
    # direction that matters.
    run_apk identity-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity identity \
        --es KAYA_SELFTEST_SCRIPT "'${IDENTITY_SCRIPT}'" \
        --es KAYA_ASSET_DIR "$ASSET_ON_DEVICE"
    run_apk listdetail-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity listdetail \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script listdetail)'"
    run_apk commands-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity commands \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script commands)'"
    run_apk clipboard-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity clipboard \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script clipboard)'"
    run_apk background-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity background \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script background)'"
    run_apk undo-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity undo \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script undo)'"
    # THE TEXT EDITOR (docs/editor-plan.md), the only script on this lane
    # that drives an APP rather than a feature. THE ONE SCENE HERE WITH NO
    # RUST SIBLING, by design: the plan chose Go so a BINDING's awkward
    # corners would show. It rides the same milestone2go APK.
    #
    # BOTH PICKERS, so it needs this lane's accessibility service in both
    # modes — ACTION_OPEN_DOCUMENT and ACTION_CREATE_DOCUMENT — and proves
    # in ONE script the discrimination the filedialog and save legs prove
    # between them.
    #
    # AND THE SCENE'S FILES ARE FOUND, which is the trap the go clipboard
    # leg is parked on: guests/go/editor's scene_root answers
    # EXTERNAL_STORAGE + "/Documents" through kaya.Env, never os.TempDir(),
    # which is empty under the JNI attach (tools/check-go-env.sh).
    #
    # THE CUT IS THE CHROME CLOSE, the `dirty` leg's cut for its reason.
    # `expect_dirty` is the keep verb and the editor asserts both of its
    # spellings before the cut. What the cut takes is the window's own
    # unsaved-work door; the File>New door is inside the prefix.
    editor_script="$(scene_script_cut editor close_window expect_dirty)" || exit 1
    run_apk editor-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity editor \
        --es KAYA_SELFTEST_SCRIPT "'${editor_script}'"
    drain
    timing legs-go
fi

exit "$status"
