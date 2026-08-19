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
# Usage: tools/android/run-emulator.sh [compose|jvm|go|all]
#
# rust    - the milestone-0 app logic as a Rust cdylib behind the JNI
#           entry (android.widget backend driven over JNI)
# jvm     - the JVM app itself as the guest: Java app logic over the
#           direct ring tier (Unsafe fenced access on raw addresses)
# compose - the rust app on the Compose interpreter (the one Android
#           backend)
# go      - a Go guest as a c-shared .so on the same direct ring, loaded
#           and attached by a shell Activity (docs/go-mobile-plan.md D1);
#           milestone2 only until the scene-library split (D3 step 3)
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
# THE LANE'S FOREIGN CLIPBOARD APP. Every assertion in the clipboard
# scene crosses a process boundary on purpose (tools/scenes/clipboard.steps):
# a check where kaya reads what kaya wrote parses its own malformed
# lowering perfectly happily. This host has no `cmd clipboard` and no
# host-side path worth the name, so the outside process is an APK —
# tools/android/cliphelper, which seeds the clipboard FROM THE
# BACKGROUND (writes were never focus-gated) and reads it back as the
# DEFAULT IME, whose reads ClipboardService admits before it ever checks
# focus. The guest therefore keeps window focus for the whole leg and
# nothing has to be handed back (docs/clipboard-plan.md §7 finding 1).
#
# A SEPARATE GRADLE BUILD from android/'s, deliberately: a harness-only
# APK must never be one `assemble` away from the module graph the apps
# ship. Built HERE because it needs no device and the pool above is
# still booting — the cost hides inside the wait below.
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
# THE POOL STAYS WARM ACROSS RUNS (nothing kills it at exit), so every
# device-global switch this run flips has to come back off. The default
# IME below is per-user state: left selected it hands the next run — and
# anyone who opens this emulator by hand — a keyboard nobody chose. In
# the trap and not at the end of the script because a failed leg, a ^C
# and a `set -e` abort all leave the same mess.
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
# clipboard leg into a seed whose latch times out with nothing anywhere
# naming the cause; an `ime set` that did not take turns every foreign
# read into a null — and null is also what an empty clipboard, a denied
# read and a locked device answer, so the leg would fail three removes
# from the reason. Loud here, once, beats ambiguous there, every leg.
#
# NOT ON THE TABLET: it carries one leg (listdetail) and no clipboard
# leg may land there — it is the one device with no slot lock, so two
# legs on it would share one clipboard. check-steps pins that.
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
    # "Unknown id" and the `ime set` behind it then silently keeps the
    # previous keyboard. Same shape and same reason as the accessibility
    # bind wait below.
    while [ "$tries" -lt 50 ]; do
        if adb -s "$serial" shell ime list -a -s 2>/dev/null | tr -d '\r' \
            | grep -qF "$CLIPHELPER_PKG/"; then
            break
        fi
        tries=$((tries + 1))
        sleep 0.2
    done
    # Neither of these is the check — the poll below is, and it catches
    # every way they can fail plus the ones that report success. They are
    # explicitly non-fatal so that stays true whatever `set -e` context a
    # future caller puts this function in; their own complaint ("Unknown
    # input method ... cannot be selected") still reaches stderr.
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
# one push per asset. This block used to be TWO: font_prepare pushed
# guests/assets/fonts/sora-wght.ttf and icon_prepare pushed the declared
# mark, each with its own paragraph, its own size check and its own
# intent extra, and a third asset would have been a third of each.
# A5.1 asks for exactly this change.
#
# /data/local/tmp, AND THAT WAS MEASURED FROM THE APP rather than
# assumed. SELinux stops untrusted_app reading shell_data_file on many
# images, and `run-as` CANNOT answer the question — it runs as
# runas_app, a domain that may read what the app itself may not, so a
# green run-as check would have been evidence about the wrong process.
# The proof is the typeface scene's own verdict on emulator-5554
# (android-35 google_apis arm64), with the font pushed here and nowhere
# else:
#
#   kaya: KAYA_SELFTEST: OK (typeface, typeface Sora, clicked hi,
#                            ax "heading/typeface")
#
# and the control, the same leg pointed one path over, which dies in the
# guest naming the root it could not read.
#
# BY HASH AND NOT BY SIZE, which is the second change. A short push is
# what a size check catches, and it is not the only way a push goes
# wrong: a same-length corruption passes a size comparison and then
# fails three removes away — the typeface leg reports a resolved family
# that is not Sora (KayaCompose falls back to the family name and logs,
# so corrupt bytes are not fatal on this backend) and the identity leg
# reports declared bytes BitmapFactory refused. Both read as lowering
# bugs to anyone who did not push the file. The hash is compared here,
# where the cause is.
#
# The identity guests still name their own file in KAYA_ICON_FILE, read
# out of the declaration and never retyped (docs/app-identity-plan.md
# ruling 4, held by tools/check-app-identity.sh C6): they have not moved
# to `asset(name)` yet, and until they do the path they are handed is a
# path INSIDE the root this pushes.
ASSET_SRC="$ROOT/guests/assets"
ASSET_ON_DEVICE=/data/local/tmp/kaya-assets

# What arrived against what was sent, name by name and hash by hash.
# Reads the device's `find ... -exec sha256sum` on stdin.
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
# The declared mark, in the two places that need it: on the HOST, where
# apk_icon_verify hashes it against what gradle packaged, and INSIDE the
# pushed root, where the identity guests open it. Both derived from the
# one declaration, so there is still exactly one place the icon's
# location is written down.
ICON_SRC="$ROOT/$ICON_REL"
ICON_ON_DEVICE="$ASSET_ON_DEVICE/${ICON_REL#guests/assets/}"
assets_prepare() { # serial
    local serial="$1" listing verdict rc
    adb -s "$serial" shell rm -rf "$ASSET_ON_DEVICE" >/dev/null 2>&1 || true
    if ! adb -s "$serial" push "$ASSET_SRC" "$ASSET_ON_DEVICE" >/dev/null; then
        echo "run-emulator: could not push $ASSET_SRC to $serial" >&2
        return 1
    fi
    # World-readable on purpose: the tree is pushed by the SHELL user and
    # opened by the app's, which share nothing but the other bits.
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

# THE SELECTION HALF OF THE ABOVE, ON ITS OWN, because the default input
# method DOES NOT STAY PUT: measured 2026-08-06 on emulator-5554, the
# selection reverted to the stock keyboard between runs with nothing in
# this lane asking it to. The clipboard leg tolerates that (it reads its
# helper through a broadcast, not through the IME), but the RANGES leg
# cannot: D4's whole assertion is that a composing region is still open
# when the app's select arrives, and a third-party input method finishes
# a composing region it did not create — measured, within tens of
# milliseconds. So the ranges leg re-asserts this immediately before it
# runs, and says so rather than failing three removes away as a caret in
# the wrong place. No install and no wait for the service to register:
# cliphelper_prepare already did both at the top of the run.
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
# `Bound services:{Service[label=..., feedbackType...]}` — a LABEL and no
# component — so the only thing this runner can match on is a name the
# harness service gives itself. It used to match the bare word "kaya",
# and that worked by ACCIDENT: the service declared no label of its own,
# so it inherited the application's, and every validation app was called
# "kaya milestone 0".
#
# The app identity slice took the accident away (docs/app-identity-plan.md
# ruling 3): android:label is now the DECLARED name, which contains no
# "kaya" — and the bind check then failed on all three pool devices,
# through three arms and a reboot each, every leg reporting a picker that
# never came up. MEASURED 2026-08-18, a whole lane's worth of legs, and
# nothing anywhere named the cause.
#
# So the service names ITSELF now, and the two sides are checked against
# each other here rather than hoped at. This is the guard for a coupling
# invisible from either end: the manifests cannot see this grep, and this
# grep cannot see the manifests.
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
    # THE HARNESS'S EYES OUTSIDE THIS APP. Android's file picker is
    # DocumentsUI, a separate APK, and the platform stops one app from
    # reading another's UI — so the scene needs an accessibility service,
    # which only the user (or adb) can enable. Enabled per leg rather
    # than once for the AVD: `install -r` on the app that owns the
    # service can drop it, and a silently-disabled service looks exactly
    # like a picker that never appeared.
    #
    # Declared only by the validation apps, never by the kaya library, so
    # this reaches no user's app.
    adb -s "$serial" shell am force-stop "${component%%:*}" >/dev/null 2>&1 || true
    adb -s "$serial" shell am force-stop "${component%%/*}"
    # AND THE PICKER, which is a DIFFERENT PACKAGE and therefore survives
    # the force-stop above. A leg that failed with DocumentsUI still up
    # leaves it on top of the app's task, and the next leg's `am start`
    # then brings that task forward instead of starting the activity —
    # onCreate never runs, no scene runs, and the leg reads as a clean
    # run of nothing. Measured while building the picker probe.
    for picker in com.google.android.documentsui com.android.documentsui; do
        adb -s "$serial" shell am force-stop "$picker" >/dev/null 2>&1 || true
    done
    adb -s "$serial" logcat -c
    # ENABLED HERE, AFTER force-stop AND logcat -c, and the order is the
    # whole trick. force-stop kills every component of the package —
    # including this service, because the validation app is what declares
    # it — and logcat -c wipes the connection message that proves it came
    # up. Enabling first meant the service was killed and its one piece
    # of evidence erased, which reads exactly like a service that never
    # started.
    local a11y="${component%%/*}/dev.kaya.KayaHarnessAccessibility"
    # THE ARM, RETRIED — because enabling races the install that precedes
    # it. MEASURED 2026-08-06, after three lane runs died to "never bound"
    # on three different devices: on an IDLE device the identical sequence
    # binds in ONE SECOND, and the same service binds on a sibling device
    # at the same moment. What differs in a lane is that `install -r` has
    # just REPLACED the package that declares this service, and enabling
    # on the heels of that replacement sometimes lands before the package
    # manager has finished with it — the setting reads correct, dumpsys
    # says Enabled, and Bound stays empty forever. Re-arming costs a
    # second and clears it; a reboot (the hand-recovery that day) is kept
    # as the last resort because it was proven to work when re-arming was
    # never tried.
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
        # BOUNDED WAIT, because binding is asynchronous: the setting
        # returns long before the system has started the service, and
        # sampling once reports every leg as broken.
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
    # DEVICE-LEVEL RECOVERY, ONCE, LOUDLY: rebooting cleared this by hand
    # on 5554 and 5558. The post-boot settle matters — sys.boot_completed
    # goes 1 before the accessibility manager will bind anything, and a
    # retry that ignores that fails for a second, unrelated reason.
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
        #
        # THREE TAGS, NOT ONE, and the second was paid for. AndroidRuntime
        # carries JVM exceptions only. A GO guest's panic goes to Go's
        # runtime log under the tag `Go`, so a Go crash used to leave this
        # branch printing NOTHING AT ALL — 60 seconds of logcat timeout
        # and then a bare `FAIL`, with the message that names the cause
        # sitting in the buffer under a tag nobody asked for. Measured
        # 2026-08-07 while watching the environment guard fail: the panic
        # said exactly what to do next and the leg never showed it.
        # DEBUG:F is the tombstone header, which covers the rest of the
        # native aborts (any language) the same way.
        adb -s "$serial" logcat -d -s AndroidRuntime:E Go:E DEBUG:F | tail -30
        failed=1
    fi
    [ "$failed" = 0 ]
}

# The Kotlin interpreter reads the scene script from the environment
# (via the KAYA_* intent-extra mapping). Intent extras cannot carry
# newlines through the shell, so comments are stripped and lines fold
# into `;` — the grammar's newline stand-in.
scene_script() { grep -v '^#' "$ROOT/tools/scenes/$1.steps" | tr '\n' ';'; }

# THE PHONE-EXPRESSIBLE PREFIX of a shared scene: everything above the
# CUT VERB, for the one shape a phone cannot run end to end — a scene
# that is mostly runnable here and desktop-only in its TAIL.
#
# This runner already declines WHOLE scenes for that reason and says so
# at the top of the file (`split` drives resize_window, `panels` drives
# create_window, and this host does neither). `dirty` is the first scene
# that only goes out of reach at the end: its last six steps hang off a
# chrome close, which the interpreter refuses in as many words. The
# alternatives were an all-or-nothing carve-out — leaving D4's Compose
# arm applied but asserted by nobody — or a phone-safe sibling scene,
# which every runner would then owe legs for (check-steps' wired()),
# i.e. a cross-lane obligation minted mid-fan-out.
#
# THE SHARED FILE STAYS BYTE-FROZEN: the prefix is its own bytes, and
# the steps this lane did NOT run are printed, so a green leg still says
# what it declined. The lane composes in the other direction already —
# the tablet leg is `scene_script listdetail` plus two claims only a
# regular width can make.
#
# THE TWO WAYS A CUT GOES QUIET, BOTH REFUSED HERE: the cut verb leaving
# the scene (the cut is then stale and the leg runs everything or
# nothing), and the cut swallowing the very assertion the leg exists for
# (a gate satisfiable without exercising the real thing). The second is
# not hypothetical — cut `dirty` one step earlier, at `click button#0`,
# and the prefix asserts `dirty false` and never `dirty true`. So the
# KEEP VERB is mandatory and the comparison is against the WHOLE file:
# every distinct assertion that verb makes anywhere must survive, or a
# step added below the cut later would go silently unrun.
#
# THIS IS THE iOS LANE'S SHAPE, deliberately (tools/ios/run-sim.sh, the
# cut/keep arguments on its leg function): the two mobile lanes meet the
# same tail on the same scene, and two answers to one question is how
# lanes drift.
scene_script_cut() { # scene cut-verb keep-verb
    python3 - "$ROOT/tools/scenes/$1.steps" "$2" "$3" <<'PY'
import pathlib
import sys

path, cut, keep = sys.argv[1], sys.argv[2], sys.argv[3]
# A CUT WITHOUT A `keep` IS AN UNGUARDED CUT, and an optional guard is
# the kind that is quietly not passed. Naming what the cut may not take
# is the price of cutting at all.
#
# A LIST, because one scene's tail can be below more than one thing the
# leg exists to assert: the sections leg asserts both which section is
# showing AND what its switcher row draws, and a guard naming only the
# first would let the second slide into the tail unnoticed. Every verb
# named gets the same two clauses. THE iOS LANE TAKES THE SAME LIST —
# two mobile lanes, one question, and two answers is how lanes drift.
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
# Intent extras cannot carry newlines, so this lane's scripts fold into
# `;` — the grammar's newline stand-in, exactly as scene_script does.
print(";".join(prefix) + ";")
PY
}

# ONE STEP OUT OF THE MIDDLE, where a CUT can only take a tail.
#
# scene_script_cut above exists for a scene that goes out of reach at its
# END. The identity scene does not: its one desktop-only step is
# `expect_title window#1`, which reads the declared NAME off a window that
# has no title of its own — and this host has no auxiliary windows at all
# (create_window is capability-rejected; DESIGN.md, Presentation
# contexts). Below that step sit the live widgets and the SECOND
# expect_app_icon, which is the step that catches an icon some later pass
# disturbed. A cut would take all of it, so this takes the one step
# instead.
#
# THE SHARED FILE STAYS BYTE-FROZEN and the dropped step is printed, so a
# green leg still says what it declined — scene_script_cut's rule, and
# every guard here is that function's guard restated for a middle step:
#
#   THE STEP MUST BE THERE, EXACTLY ONCE. Not there means the scene was
#   reshaped and this drop is stale — the leg would then run everything,
#   including the step this host cannot express. More than once means the
#   drop is ambiguous about which one it takes.
#   THE KEEP VERBS ARE MANDATORY, and every distinct assertion each one
#   makes anywhere in the file must survive. A drop that could take the
#   assertion the leg exists for is a gate satisfiable without exercising
#   the real thing.
#
# NAMED BY VERB AND TARGET, never by the whole line: the line carries the
# declared NAME, and retyping a declared value in a runner is the second
# source of truth guests/assets/identity.toml exists to prevent.
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
# Intent extras cannot carry newlines, so this lane's scripts fold into
# `;` — the grammar's newline stand-in, exactly as scene_script does.
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
# rather than per block: all three guests skip the untitled window on
# this host (rust by cfg, go by build tag, java by a runtime probe), so
# all three run the same script. Assigned HERE for SECTIONS_CUT's reason
# — a refused drop must kill the lane, not run a script the drop never
# checked.
IDENTITY_SCRIPT="$(scene_script_drop identity expect_title window#1 \
    expect_app_icon)" || exit 1

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

# RULING 4'S BYTE EQUALITY, ASSERTED ON THE ARTIFACT ITSELF.
#
# The plan's mechanism is "one file, two readers", and its failure mode is
# the quiet kind: the launcher shows last month's icon, the running window
# shows this month's, and every test still passes, because each reader is
# internally consistent. tools/check-app-identity.sh holds every
# hand-written copy of the declaration level without building anything;
# this is the half only a build can make — the bytes INSIDE the apk gradle
# just wrote against the bytes guests/assets/identity.toml declares.
#
# HERE AND NOT IN A GATE, because invariant 3 puts the wall where someone
# walks into it: the packaging step refuses, so no leg ever installs an
# apk carrying a mark nobody declared.
#
# The entry name is android/build.gradle.kts's, which copies the declared
# file verbatim into each app's generated res (and pins
# `isCrunchPngs = false` so aapt cannot re-encode it behind this check).
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

# THE GO GUEST'S ARTIFACT: a `-buildmode=c-shared` .so the shell Activity
# loads beside libkaya.so, which is the JVM guest's packaging shape and
# not the Rust one (the Rust guest carries a statically-linked kaya
# inside a 48 MB .so; here kaya is a NEEDED, resolved by the app's
# linker). docs/go-mobile-plan.md D1.
#
# THREE THINGS THIS FUNCTION REFUSES TO ASSUME, each of which fails far
# from its cause when it is wrong:
#
#   1. THE NDK API LEVEL FOLLOWS THE MODULE'S minSdk, read out of the
#      module's own build.gradle.kts rather than written twice. A guest
#      cross-built against a newer platform than the manifest claims
#      links fine here and dies at load time on the device with a
#      relocation nobody can read.
#   2. THE JNI SYMBOL MUST BE IN THE BUILT .so. It is the one name that
#      binds android/kaya/.../KayaGo.kt to bindings/go/android.go, and
#      NO COMPILER ON EITHER SIDE CHECKS IT — rename either half and the
#      failure is an UnsatisfiedLinkError inside onCreate, after an
#      install and a boot, reported as a leg that never printed a
#      verdict. Two seconds of llvm-nm here instead.
#   3. `go build` writes its output even when the link only half
#      succeeded? No — but the COPY into jniLibs is what gradle
#      packages, so the build lands in target/ and the copy is what gets
#      checked, the same order the cargo-ndk steps below use.
kaya_go_build() { # lib-name jnilibs-dir
    local lib="$1" jnilibs="$2"
    local module="$ROOT/android/milestone2go/build.gradle.kts"
    local api ndkbin out
    api="$(python3 - "$module" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
# The one `minSdk = N` in the module, ignoring comment lines — the
# comment above it explains this very coupling and names the number.
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
    # rides CC and the #cgo android line in bindings/go/runtime.go
    # carries -L…/aarch64-linux-android/debug -lkaya. That directory is
    # filled by the cargo ndk build at the callsite, above this.
    # guests/go/cmd IS THE WHOLE GUEST: one main package importing every
    # scene library, one .so, and the leg names its scene in
    # KAYA_SELFTEST. `-buildmode=c-shared` allows exactly one main
    # package per library, so the alternative was a library per scene in
    # one APK — 2.6 MB each (docs/go-mobile-plan.md D3 step 3).
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
    # THE LEADING SPACE IS THE POINT. llvm-nm prints `<addr> T <name>`,
    # and cgo emits a SECOND symbol for every //export — the generated
    # trampoline `_cgoexp_<hash>_Java_dev_kaya_KayaGo_attach`, which ends
    # in the same characters. An end-anchor alone counts two and this
    # check refuses a correct build. (Measured on the first run of this
    # very block: "found 2".)
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
    apk_icon_verify \
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
    # The stall diagnostic (crates/kaya/src/stall.rs): an app thread
    # that stops taking its occurrences is REPORTED. Core-side, so no
    # Compose arm — the leg is here because a phone is where an app
    # that looks alive and ignores you is hardest to tell from a slow
    # one.
    run_apk stall-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity stall \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script stall)'"
    # The confirm scene: alerts are phone-native — the M3 dialog is
    # this host's REAL modal, and back/outside-tap IS the cancel slot.
    run_apk confirm-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity confirm \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script confirm)'"
    # The filedialog scene: ACTION_OPEN_DOCUMENT, which hands off to
    # DocumentsUI — a SEPARATE APP, which is the whole reason this lane
    # carries an accessibility service. The scene's files live under the
    # shared Documents collection rather than the temp directory, because
    # no document provider publishes an app's private storage and a
    # picker aimed there opens on Recent instead (see the guest's
    # scene_root and KayaCompose's kayaTempDir).
    run_apk filedialog-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity filedialog \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script filedialog)'"
    # The save scene: the round trip an editor walks — open, save back,
    # save as, reopen (docs/save-plan.md D5). Still a DEPTH slice while
    # the bindings fan out, so rust only.
    #
    # ACTION_CREATE_DOCUMENT, which is DocumentsUI once more: the same
    # separate APK the filedialog leg needs the accessibility service
    # for, in its CREATE mode. The service tells the two apart by the
    # node the create mode inflates (android:id/container_save) rather
    # than by remembering which intent kaya launched, so the leg above
    # and this one prove the discrimination in BOTH directions — the
    # open picker must not read as a save panel for `expect_file_dialog`
    # to pass, and the save panel must not read as a picker for
    # `expect_save_dialog` to.
    #
    # THIS IS ALSO THE ONLY LEG ON THIS PLATFORM THAT WRITES THROUGH A
    # PICKED HANDLE. `openFileDescriptor(uri, "wt")` has been reachable
    # since the picker landed and nothing has ever driven it.
    run_apk save-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity save \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script save)'"
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
        --es KAYA_SELFTEST_SCRIPT "'$SECTIONS_CUT'"
    # The menus scene: the command catalog in the top bar's overflow,
    # promoted primaries as bar actions, long-press context menus, and
    # the shortcut verb through the interpreter's dispatch table.
    run_apk menus-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity menus \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script menus)'"
    # THE TOOLBAR SCENE (docs/chrome-plan.md C2), the menus scene's
    # sibling one bit over: the same catalog with `primary` on two
    # actions, asserted as real window CHROME. Nothing new is lowered on
    # this host — the promoted pair has been in the TopAppBar's actions
    # slot since the menus milestone, with the ⋮ holding the remainder —
    # so what this leg exercises is the READ that landed 2026-08-17: the
    # composed bar's own subtree, the merged semantics node each button
    # publishes, and the disabled bit `IconButton(enabled=)` puts there.
    # The enablement round trip is the point of the scene: the guest
    # writes ONE signal, against the menu item, and the leg asserts the
    # bar button AND the catalog item follow it in both directions, off
    # two different trees.
    run_apk toolbar-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity toolbar \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script toolbar)'"
    # THE IDENTITY SCENE (docs/app-identity-plan.md, rulings 3 and 4): an
    # app says what it is called and what it looks like, and the platform
    # shows both. NOTHING IS LOWERED AT RUNTIME ON THIS HOST and that is
    # the ruling rather than the schedule — Android's launcher icon is
    # part of the installed package, so the reader is the APK gradle just
    # built (`android:icon` + a mipmap resource, `android:label`, all
    # three off guests/assets/identity.toml), and the running app's one
    # route to a picture, TaskDescription's Bitmap, stays REFUSED (I6).
    #
    # SO WHAT THIS LEG EXERCISES is the read, and the read is of the
    # PACKAGE: the system PackageManager resolving this app's launcher
    # icon out of the installed APK's own resources, sampled at the four
    # quadrant centres. It cannot pass vacuously — the packaged mark is in
    # the APK whether or not a guest declared anything, so the read also
    # requires the wire declaration to have arrived and to sample the same
    # four colours. That is the byte-equality invariant re-proved on the
    # device, one tier below apk_icon_verify's proof on the artifact.
    #
    # THE MARK RIDES KAYA_ICON_FILE for the typeface font's reason: the
    # guest's default path is repo-relative and a device has no repo;
    # assets_prepare pushed the whole asset root to every pool device
    # above, and the declared file is a path inside it.
    #
    # ONE STEP IS NOT RUN HERE, printed by scene_script_drop and named in
    # its comment: `expect_title window#1` reads the declared NAME off an
    # auxiliary window, and this host has none. The name's Android reader
    # is `android:label` in that same APK.
    run_apk identity-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity identity \
        --es KAYA_SELFTEST_SCRIPT "'${IDENTITY_SCRIPT}'" \
        --es KAYA_ICON_FILE "$ICON_ON_DEVICE"
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
    # The stamped-accessibility scene (docs/tpl-props-plan.md P3): two
    # entries stamped from one template, each named by its own row, read
    # from Compose's real semantics tree. The a11y scene's sibling,
    # split out because a For's column shifts ordinal container targets
    # per language. Graduated 2026-08-11; the go leg rides below like
    # the a11y scene's.
    run_apk a11yrows-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity a11yrows \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script a11yrows)'"
    # THE STYLING SCENE (docs/styling-plan.md slice 1): brand + roles +
    # inset. On this backend the brand SEED drives Material's own
    # scheme derivation (the other ten derived words are for the
    # backends that lower colours directly), roles lower to M3's
    # emphasis ladder, and `heading` is Compose heading() semantics —
    # the real-tree read the expect_ax step freezes. Graduated
    # 2026-08-12 when the fan-out replaced the compose depth stub; this
    # leg is also the first on-device exercise of the APPLY_SET_BRAND
    # wire decode.
    run_apk styling-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity styling \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script styling)'"
    # THE TYPEFACE SCENE (docs/styling-plan.md Slice 2b), the styling
    # scene's sibling one tier over: the brand typeface swaps the FAMILY
    # and leaves the platform's ramp alone. It exists for the SILENT
    # FALLBACK — every font API on every platform renders something for a
    # family it has not got, so a typo, a stale lowering and a working
    # swap are indistinguishable to every other observation kaya owns.
    # Only `expect_typeface`, which reads the family the text system
    # ENDED UP WITH off the real views, tells them apart
    # (tools/scenes/typeface.steps opens with the argument). The font
    # itself is `asset("fonts/sora-wght.ttf")` — the guest names the
    # asset and the core resolves it under KAYA_ASSET_DIR, which is the
    # root assets_prepare pushed to every pool device above, at a path
    # measured from the app.
    run_apk typeface-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity typeface \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script typeface)'" \
        --es KAYA_ASSET_DIR "$ASSET_ON_DEVICE"
    # The clipboard scene: one clip in several representations, the
    # privileged read, the paste split, and Paste as a standard command.
    # The foreign process on the other side of every assertion is
    # dev.kaya.cliphelper, installed and made the default IME on every
    # pool device above; the guest reaches it by ordered broadcast, with
    # no adb round trip and nothing per-leg to arrange here.
    #
    # NO DRAIN BRACKET, and that is a measured difference from the other
    # three lanes rather than an omission. The rule those lanes spell
    # with drain is that a leg must read the clipboard THAT LEG WROTE
    # (docs/clipboard-plan.md §0d, the 2026-08-02 correction: one system
    # clipboard per session, and eight legs writing it concurrently are
    # eight processes assigning one variable — six of eight failed).
    # HERE A SESSION IS A DEVICE, NOT THE LANE: the pool is separate
    # emulators, each with its own ClipboardService, and §7 finding 4
    # measured the emulator-host clipboard bridge severed in both
    # directions, so nothing joins them — not even the mac lane's
    # pbcopy under validate-all. run_apk's slot lock already gives a leg
    # its device for the leg's whole duration, which is this runner's
    # spelling of the same exclusion. A drain bracket would exclude
    # NOTHING on top of that (there is one clipboard leg per suite
    # block), so it would be a barrier that cannot fail for the reason
    # it exists; check-steps pins the property that can — the leg rides
    # run_apk, and run_apk still claims a device.
    run_apk clipboard-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity clipboard \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script clipboard)'"
    # The undo scene: ONE history over two tiers (docs/undo-plan.md
    # D1-D6, §3). Both tiers are real on this backend — the field's own
    # TextUndoManager answers the frontier, the core's ledger answers
    # everything behind it, and the routing between them is kaya's
    # (§1's table: "GTK and Compose route in kaya"), because a focused
    # Compose text field CONSUMES Ctrl+Z whether or not it has anything
    # to undo and the Activity's shortcut route never sees the chord.
    #
    # THIS LEG IS WHERE THE TYPING VERB EARNS ITS KEEP. `type` dispatches
    # real KeyEvents through the Activity, so the field's own undo stack
    # fills the way a user's typing fills it; a set_text stand-in would
    # CLEAR that stack (D7) and the native tier would have nothing to
    # answer with — the scene would pass having observed one tier.
    run_apk undo-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity undo \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script undo)'"
    # The dirty scene: unsaved work as window chrome (docs/dirty-plan.md).
    # THIS HOST HAS NO CHROME AND THAT IS THE POINT (D4) — no title bar,
    # no close button, and the platform's own unsaved-state affordance is
    # the predictive-back confirmation, which is veto_close and
    # navigation's business rather than this prop's. So the prop applies,
    # lowers to nothing visible, and `expect_dirty` reads the applied
    # value back (Stage::window_dirty's table names this lane's row).
    # Synthesizing a marker no native app shows was the rejected
    # alternative, and it is rejected in the plan, not here.
    #
    # THE SCRIPT STOPS ABOVE THE CHROME CLOSE (scene_script_cut, which
    # carries the reasoning and the guards). dirty.steps ends with D3's
    # demonstration — close_window, the veto dialog, cancel — and this
    # host has neither half: the interpreter refuses close_window in as
    # many words (the system owns surfaces; DESIGN.md, Presentation
    # contexts) and veto_close is inert here by the same physics. The
    # steps above that line are exactly what D4 asks this lane to prove,
    # and they are not a thin slice of it: the mark goes UP, comes DOWN
    # on save, and goes up again, so a lowering that only ever sets the
    # flag fails here as surely as on the desktops — watched, both ways.
    # `expect_dirty` is the keep verb, so no cut may take one of those
    # assertions with it.
    #
    # AND ONE APPENDED CLAIM, which is the tablet leg's pattern for the
    # opposite reason: not a claim the shared file may not carry because
    # only one device can make it, but one it may not carry because only
    # SOME platforms can. The trimmed script leaves the mark UP, and
    # `expect_title "dirty"` here says the task label is still exactly
    # the string the app declared — no asterisk, no bullet, nothing
    # composed in. That is the observable form of "lowers to no chrome"
    # (D4) and of "the title is never touched" (D1), and it is the wall
    # in front of the rejected design: a Compose arm that synthesized a
    # marker no Android app shows would fail right here. The shared file
    # cannot hold this line inside the dirty stretch — WinUI composes
    # its asterisk into the rendered caption, which is what expect_title
    # reads there, so one byte-compared assertion cannot serve both
    # lanes (dirty.steps says so in its own comment).
    dirty_script="$(scene_script_cut dirty close_window expect_dirty)" || exit 1
    run_apk dirty-compose \
        "$ROOT/android/milestone2/build/outputs/apk/debug/milestone2-debug.apk" \
        dev.kaya.milestone2/.MainActivity dirty \
        --es KAYA_SELFTEST_SCRIPT "'${dirty_script}expect_title \"dirty\"'"
    # The text-ranges scene (docs/ranges-plan.md): HIGHLIGHT a set,
    # SELECT one, REVEAL one, and the two rules that make those three a
    # contract — a user's keystroke DROPS the declared set (D2) and a
    # select_range arriving mid-composition is REFUSED (D4).
    #
    # THE WHOLE SCRIPT RUNS HERE, unlike `dirty` above: nothing in it
    # needs chrome this host does not have. Two of its verbs are only
    # reachable at all because this harness lives INSIDE the app —
    # `compose` takes the field's own InputConnection (no adb command
    # can open a composing region; `input text` injects key events and
    # never calls setComposingText), and the range reads walk the merged
    # semantics tree from the UI thread, which is where TalkBack's data
    # comes from.
    #
    # AND IT NEEDS THE LANE'S OWN IME, which every device in this pool
    # already has: `cliphelper_prepare` makes the helper's bare
    # InputMethodService the default input method, and D4 needs exactly
    # that. Measured 2026-08-06 with Gboard as the default instead: the
    # composing region this leg opens is FINISHED by the other input
    # method a few tens of milliseconds later — an IME resyncs when it
    # sees a composing region it did not create — so the select arrived
    # after the composition was gone, was honoured, and the leg failed
    # with a caret 763 bytes from where it wanted one. That is Android
    # being Android rather than a bug in the arm (D4's own words: the
    # same app code is correct one millisecond and refused the next),
    # and it is why the assertion needs a device where nothing else is
    # composing.
    #
    # AND THE OFFSETS ARE THE ASSERTION. The document's first line is
    # CJK, so every match sits six bytes further along than it sits in
    # UTF-16 — the unit a Kotlin CharSequence indexes — and a backend
    # that forwarded kaya's byte offsets unconverted would decorate six
    # characters early. The scene is byte-identical on all five lanes.
    # ...AND THE INPUT METHOD IS RE-ASSERTED FIRST, on every device in
    # the pool, because which one this leg lands on is the pool's choice.
    # The drain is what makes that safe: no other leg is in flight, so
    # nothing is disturbed by the switch, and the leg that needs the
    # quiet device gets it.
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
    # The stall diagnostic through the JVM binding (see the compose leg).
    run_apk stall-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity stall \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script stall)'"
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
        --es KAYA_SELFTEST_SCRIPT "'$SECTIONS_CUT'"
    # The menus scene through the JVM binding (see the compose leg);
    # this host carries the same dispatchKeyShortcutEvent override, so
    # the chord reaches the catalog identically in both languages.
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
    # The identity scene through the JVM binding (see the compose leg for
    # what the scene is for and why nothing is lowered at runtime here).
    # What this arm adds is the Java binding's `appIdentity` on the tier
    # that shares guests/java's sources with the desktop lanes, and the
    # ONE thing its guest must get right on a phone: Identity.java skips
    # the untitled window on a host with no auxiliary windows, which it
    # decides at RUNTIME because one artifact serves the desktops and
    # this device both.
    run_apk identity-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity identity \
        --es KAYA_SELFTEST_SCRIPT "'${IDENTITY_SCRIPT}'" \
        --es KAYA_ICON_FILE "$ICON_ON_DEVICE"
    # The commands scene through the JVM binding (see the compose leg).
    # The listdetail scene through the JVM binding: the same
    # guests/java/Split.java the desktop lanes run, on the tier that
    # shares its sources.
    run_apk listdetail-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity listdetail \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script listdetail)'"
    run_apk commands-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity commands \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script commands)'"
    # The clipboard scene through the JVM binding (see the compose leg,
    # including why this lane's clipboard legs need no drain bracket:
    # each rides its own emulator, which is its own clipboard session).
    run_apk clipboard-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity clipboard \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script clipboard)'"
    # The undo scene through the JVM binding (see the compose leg). Same
    # interpreter, same two tiers; what this arm adds is the Java
    # binding's `undoable` spelling and its absorb of the undone/redone
    # payload, on the tier that shares guests/java's sources with the
    # desktop lanes.
    run_apk undo-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity undo \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script undo)'"
    # The styling scene through the JVM binding (see the compose leg):
    # same interpreter, same lowerings; what this arm adds is the Java
    # binding's Role enum, brandAccent overloads and inset chain riding
    # the shared guests/java sources on a device.
    run_apk styling-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity styling \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script styling)'"
    # The typeface scene through the JVM binding (see the compose leg for
    # what the scene is for). What this arm adds is the Java binding's
    # three-argument `brandTypeface` — the BYTES form, the one a brand
    # book's licensed font takes — on the tier that shares its guest with
    # the desktop lanes, and `Files.readAllBytes` reading the pushed file
    # under this module's minSdk.
    run_apk typeface-jvm \
        "$ROOT/android/milestone2kt/build/outputs/apk/debug/milestone2kt-debug.apk" \
        dev.kaya.milestone2kt/.MainActivity typeface \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script typeface)'" \
        --es KAYA_ASSET_DIR "$ASSET_ON_DEVICE"
    drain
    timing legs-jvm
fi

# THE GO SUITE: the third language on this host, and the first one whose
# guest is neither Rust nor a JVM language. The composition is the JVM
# suite's, line for line — libkaya.so in jniLibs, the Compose interpreter
# as the backend, KayaRing.attach for the pump, the direct occurrence
# ring as the transport — with ONE difference, and it is forced: the JVM
# shell can start a JVM guest's thread itself, and it has no way to call
# a Go function, so the guest's own .so is asked to start the thread
# (KayaGo.attach -> bindings/go/android.go). docs/go-mobile-plan.md D1.
#
# THE SCENE LIST IS THE JVM SUITE'S, ENTRY FOR ENTRY AND IN ITS ORDER,
# and that is the whole justification for the set. The JVM suite is the
# sibling GUEST-LANGUAGE suite on this host: same libkaya.so in jniLibs,
# same Compose interpreter as the backend, same direct occurrence ring as
# the transport, same one-APK-many-scenes selector. The one structural
# difference is the one named above — who starts the guest thread — and
# every leg alike exercises it. Running the same scenes in the same order
# is what makes the two suites comparable leg for leg, and comparing them
# is how uniform binding semantics is checked at all (invariant 1).
# D3 step 2 shipped `milestone2` alone because the other 31 needed the
# scene-library split (step 3); that landed, so this is step 4.
#
# NOT WIDER: filedialog, dirty and ranges run on this runner from the
# RUST guest only — MainActivity.kt has no arm for filedialog or dirty at
# all — and each carries host-specific harness plumbing that the rust leg
# owns (an accessibility service driving DocumentsUI; a scene_script_cut
# plus an appended expect_title claim; an IME switch inside a drain
# bracket). A Go leg on any of them would make Go the first NON-RUST
# guest there, which is a sweep of that scene across guest languages, not
# this depth slice. window/panels/split are desktop-only by design.
#
# AND `editor` IS THE ONE ENTRY THIS LIST HAS THAT THE JVM SUITE DOES
# NOT, which the paragraph above requires be written down right here. It
# is not a divergence in coverage: the text editor (docs/editor-plan.md)
# is a GO app and there is no rust or jvm guest for it, by design rather
# than by sequencing — the plan chose Go so a BINDING's awkward corners
# would show. Its leg block sits at the end of this suite with the
# reasoning; it is the first Go leg here to drive ACTION_CREATE_DOCUMENT
# and the range reads, which is what makes it worth its own block rather
# than a name in a list.
#
# NOT NARROWER, and this is the half that has to be said out loud because
# nothing enforces it: check-steps' wired() keys on scene x runner and
# never on language, so a Go suite that stalled at six scenes would leave
# every gate green. Mirroring a sibling list is what keeps the choice
# auditable, and any future divergence has to be written down right here.
#
# THE ONE DIVERGENCE TODAY IS `clipboard`, and it is a MEASURED gap in
# two files rather than a judgement about the scene. It was wired, run,
# and WATCHED FAILING before it was taken back out, which is why this
# names a defect instead of a suspicion:
#
#   panic: failed to make the scene's directory:
#          mkdir /data/local/tmp/kaya-clip-3565: permission denied
#
# guests/go/clipboard's sceneRoot still answers os.TempDir() off
# iOS. os.TempDir() reads $TMPDIR, which under the JNI attach is EMPTY
# (tools/check-go-env.sh's whole subject), so Go falls back to its
# android default /data/local/tmp — a directory the app cannot write —
# while the interpreter expands $TMP to the shared Documents collection.
# Guest and interpreter disagree about the path, which is the SAME defect
# Clipboard.java's own comment records hitting on the JVM guest's first
# android run. The spelling that fixes it is that guest's:
# EXTERNAL_STORAGE (or /sdcard) + "/Documents", reached through kaya.Env
# rather than os.Getenv. Behind it sits a second blocker this run never
# got far enough to hit: milestone2go's manifest carries no
# `<queries><package android:name="dev.kaya.cliphelper" />`, which
# milestone2 and milestone2kt both do, and without it an explicit
# broadcast to the helper is filtered out with no error anywhere.
# Restore this leg with those two fixes; both files are outside the arm
# that wired these legs.
if [ "$SUITE" = go ] || [ "$SUITE" = all ]; then
    JNILIBS="$ROOT/android/milestone2go/src/main/jniLibs/arm64-v8a"
    mkdir -p "$JNILIBS"
    # The same libkaya.so the JVM suite ships, built the same way and
    # verified the same way — the Go guest NEEDs it by SONAME and the
    # app's linker resolves it out of this directory at load time.
    cargo ndk -t arm64-v8a build --locked --lib || exit 1
    cp "$ROOT/target/aarch64-linux-android/debug/libkaya.so" "$JNILIBS/"
    "$ROOT/tools/build-id.sh" --verify "$JNILIBS/libkaya.so" || exit 1
    # NO --verify ON THE GO .so, and that is the honest answer rather
    # than a gap: the build id lives inside libkaya, and here libkaya is
    # a SHARED library the guest merely names — so the guest carries no
    # marker, exactly as milestone2kt's guest classes carry none. (On
    # iOS the same Go sources DO carry it, because there kaya is a static
    # archive linked in, and tools/ios/run-sim.sh verifies it for that
    # reason.) What can go stale here is libkaya and the interpreter, and
    # both are verified — above and below.
    kaya_go_build milestone2go "$JNILIBS" || exit 1
    kaya_write_compose_marker
    (cd android && gradle --console=plain -q :milestone2go:assembleDebug) || exit 1
    "$ROOT/tools/build-id.sh" --verify --component compose \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" || exit 1
    apk_icon_verify \
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
    # The styling scene through the Go binding (see the compose leg).
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
    # The layout contract through the Go binding: grow asserted as
    # shares and root-fills, layout observed (see the jvm legs).
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
    # The stall diagnostic through the Go binding. The watchdog is
    # core-side, so this is the one scene whose guest carries no
    # runtime.LockOSThread init -- and it needs none here, because
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
    # The menus scene through the Go binding: this host carries the same
    # dispatchKeyShortcutEvent override, so the chord reaches the catalog
    # identically in all three languages.
    run_apk menus-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity menus \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script menus)'"
    # The toolbar scene through the Go binding (see the compose leg);
    # guests/go/toolbar rides the one c-shared .so that carries every
    # scene, so this host needs nothing per-scene of its own.
    run_apk toolbar-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity toolbar \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script toolbar)'"
    # The identity scene through the Go binding (see the compose leg).
    # Two things are this leg's alone. KAYA_ICON_FILE crosses the
    # environment trap this suite exists to keep honest — the guest reads
    # it with kaya.Env and never os.Getenv, which under the JNI attach
    # answers "" forever, and "" here is not an error but the guest's
    # repo-relative default (tools/check-go-env.sh is the static half).
    # And the untitled window is split by BUILD TAG rather than by a
    # runtime probe (guests/go/identity/untitled_{desktop,phone}.go),
    # because a Go guest is cross-built per platform.
    run_apk identity-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity identity \
        --es KAYA_SELFTEST_SCRIPT "'${IDENTITY_SCRIPT}'" \
        --es KAYA_ICON_FILE "$ICON_ON_DEVICE"
    # The listdetail scene through the Go binding: guests/go/split
    # under the `listdetail` key, the same one app behind both scripts
    # the other two hosts use. `split` itself is desktop-only.
    run_apk listdetail-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity listdetail \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script listdetail)'"
    run_apk commands-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity commands \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script commands)'"
    # The undo scene through the Go binding: ONE history over two tiers,
    # and the `type` verb is what fills the native one (see the compose
    # leg).
    run_apk undo-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity undo \
        --es KAYA_SELFTEST_SCRIPT "'$(scene_script undo)'"
    # THE TEXT EDITOR — kaya's forcing artifact (docs/editor-plan.md), and
    # the only script on this lane that drives an APP rather than a
    # feature: launch to an empty buffer, type, save-as, open, edit, undo,
    # save, and find with a regex.
    #
    # THE ONE SCENE HERE WITH NO RUST SIBLING, and that is the design
    # rather than the sequencing: the plan chose Go so a BINDING's awkward
    # corners would show, and an editor in Rust would be kaya testing
    # itself. The paragraph above says a Go leg on filedialog/dirty/ranges
    # would make Go the first non-rust guest on a rust-only scene; this is
    # not that case, because there is no rust guest for it to go first
    # ahead of. It rides the same milestone2go APK every leg above does.
    #
    # BOTH PICKERS, so it needs this lane's accessibility service in both
    # of its modes — ACTION_OPEN_DOCUMENT for File>Open… and
    # ACTION_CREATE_DOCUMENT for File>Save As…. run_apk_on arms the
    # service per leg, so this costs nothing extra here; what it does mean
    # is that this leg proves the same both-directions discrimination the
    # filedialog and save legs prove between them, in ONE script.
    #
    # AND THE SCENE'S FILES ARE FOUND, which is the trap the go clipboard
    # leg is still parked on: guests/go/editor's scene_root answers
    # EXTERNAL_STORAGE + "/Documents" through kaya.Env — never
    # os.TempDir(), which is empty under the JNI attach and falls back to
    # /data/local/tmp, a directory the app cannot write
    # (tools/check-go-env.sh). It agrees with KayaCompose's kayaTempDir
    # without either side consulting the runner.
    #
    # THE CUT IS THE CHROME CLOSE, the `dirty` leg's cut for the `dirty`
    # leg's reason: the scene's last stretch drives `close_window`, which
    # a phone has not got. `expect_dirty` is the keep verb, and the editor
    # asserts both of its spellings — false and true — before the cut, so
    # the prefix still watches the mark go up on a keystroke, down on a
    # save, down on an UNDO, and up again on a programmatic write. What
    # the cut takes is the window's own unsaved-work door; the File>New
    # door is inside the prefix, so the alert composition still runs here.
    editor_script="$(scene_script_cut editor close_window expect_dirty)" || exit 1
    run_apk editor-go \
        "$ROOT/android/milestone2go/build/outputs/apk/debug/milestone2go-debug.apk" \
        dev.kaya.milestone2go/.MainActivity editor \
        --es KAYA_SELFTEST_SCRIPT "'${editor_script}'"
    drain
    timing legs-go
fi

exit "$status"
