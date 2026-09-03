#!/usr/bin/env bash

kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# Is each test surface ready? Nothing here mutates state except `--warm`,
# which boots the independently warmable ones and REFUSES (exit 1) naming
# any it could not. The coupled Android phone+tablet pool is reported
# here and owned by tools/android/run-emulator.py.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
. "$ROOT/tools/lib/android-emulator-state.sh"
WARM=0
[ "${1:-}" = --warm ] && WARM=1
status=0
# Surfaces `--warm` was asked to warm and did not; retired at the foot of
# the file, where --warm refuses rather than exiting 0.
warm_skipped=""

report() { # name state detail
    printf '%-12s %-6s %s\n' "$1" "$2" "$3"
    [ "$2" = DOWN ] && status=1
}

warm_skip() { # surface
    [ "$WARM" = 1 ] && warm_skipped="$warm_skipped $1"
    return 0
}

# --- dev shell tools -------------------------------------------------
if command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null; then
    report devshell OK "ffmpeg/ffprobe present"
else
    report devshell DOWN "no ffmpeg/ffprobe — run inside nix develop"
fi

# --- toolchain provenance --------------------------------------------
# The dev-shell marker proves the env was exported, not that the PATH
# still leads with it: a login profile's `brew shellenv` can re-prepend
# /opt/homebrew over an inherited dev-shell PATH, and a homebrew ocaml —
# same version string, different build — once drove nix dune/ppxlib into
# "inconsistent assumptions over implementation Location". swiftc is
# exempt: the flake reaches it through Apple's /usr/bin shim.
shadowed=""
for tool in cargo rustc dune ocamlopt ocamlfind go python3 dotnet ghc cabal clang ffmpeg gradle; do
    tool_path=$(command -v "$tool" 2>/dev/null) || continue
    case "$tool_path" in
        /nix/store/*) ;;
        *) shadowed="$shadowed $tool:$tool_path" ;;
    esac
done
if [ -z "$shadowed" ]; then
    report toolchain OK "pinned tools resolve into /nix/store"
else
    report toolchain DOWN "PATH-shadowed:$shadowed — re-enter nix develop (or prefix nix develop -c)"
fi

# --- macOS capture ---------------------------------------------------
REC_BIN="target/tools/record-suite-$(shasum tools/record-suite/main.swift | cut -c1-12)"
if [ -x "$REC_BIN" ]; then
    if out=$("$REC_BIN" --probe 2>&1); then
        report mac-capture OK "screen capture answering"
    else
        report mac-capture DOWN "$out"
    fi
else
    report mac-capture COLD "recorder not built yet (first recorded run builds it)"
fi

# --- macOS file-panel view mode --------------------------------------
# The mode is MACHINE-WIDE (docs/traps.md). Reported, not demanded; the
# one state that IS a problem is a fourth mode KayaPanelShape cannot
# read.
panel_mode=$(defaults read -g NSNavPanelFileListModeForOpenMode2 2>/dev/null || echo unset)
panel_stamp=""
# A stamp left behind means a validate-mac run died before putting the
# mode back. The next validate-mac restores it; say so meanwhile.
if [ -f "$ROOT/target/panel-mode.orig" ]; then
    panel_stamp=" — a validate-mac run left the mode rotated (killed mid-run, or a restore that could not write); target/panel-mode.orig says the machine's own value is $(cat "$ROOT/target/panel-mode.orig"), and the next validate-mac puts it back"
fi
case "$panel_mode" in
    1) report panel-mode OK "open panel view mode 1 = columns (AXBrowser/ColumnView); validate-mac rotates 1/2/3 and restores this$panel_stamp" ;;
    2) report panel-mode OK "open panel view mode 2 = list (AXOutline/ListView); validate-mac rotates 1/2/3 and restores this$panel_stamp" ;;
    3) report panel-mode OK "open panel view mode 3 = icons (AXList/IconView); validate-mac rotates 1/2/3 and restores this$panel_stamp" ;;
    unset) report panel-mode OK "open panel view mode unset — the panel chooses; validate-mac rotates 1/2/3 and deletes the key again$panel_stamp" ;;
    *) report panel-mode CHECK "NSNavPanelFileListModeForOpenMode2 reads \"$panel_mode\", which is none of 1 columns / 2 list / 3 icons — a fourth shape needs a KayaPanelShape arm in swift/KayaSwiftUI.swift before any filedialog leg can read the panel$panel_stamp" ;;
esac

# --- macOS accessibility trust ----------------------------------------
# macOS 26.6.2 gates the AX hop into the open/save panel service on the
# Accessibility grant (docs/traps.md). The guests inherit this shell's
# TCC attribution, so this read speaks for the lane.
ax_trusted=$(python3 -c "
import ctypes
f = ctypes.CDLL('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices')
print('true' if f.AXIsProcessTrusted() else 'false')" 2>/dev/null || echo unreadable)
case "$ax_trusted" in
    true) report panel-trust OK "AXIsProcessTrusted=true — the lane shells can read the open/save panel service" ;;
    false) report panel-trust DOWN "AXIsProcessTrusted=false — macOS 26.6.2+ refuses the AX hop into the open/save panel service, so every filedialog/save leg fails reading an empty sheet; grant Accessibility to the app hosting the lane shells (System Settings > Privacy & Security > Accessibility), then re-run (docs/traps.md)" ;;
    *) report panel-trust CHECK "AXIsProcessTrusted unreadable from python3 ctypes — the ApplicationServices load failed, which this probe cannot explain; run a filedialog leg to measure the panel read directly" ;;
esac

# --- iOS simulator ---------------------------------------------------
# Same fallback run-sim.py uses: the nix xcrun stub and the
# CommandLineTools default both lack simctl; only Xcode has it.
if ! xcrun simctl help >/dev/null 2>&1; then
    for app in /Applications/Xcode.app /Applications/Xcode-*.app; do
        if [ -d "$app/Contents/Developer" ]; then
            export DEVELOPER_DIR="$app/Contents/Developer"
            break
        fi
    done
fi
# THE SAME DEFAULT tools/ios/run-sim.py USES: a probe that called a
# short pool warm left the runner booting the rest inside whatever run
# followed. check-gates holds this agreement for the Android pool and
# not yet for this one.
IOS_POOL="${KAYA_IOS_SIMS:-3}"
if xcrun simctl list devices >/dev/null 2>&1; then
    booted=$(xcrun simctl list devices booted 2>/dev/null | grep -c "kaya-sim-.*Booted" || true)
    if [ "$booted" -ge "$IOS_POOL" ]; then
        report ios OK "sim pool warm ($booted/$IOS_POOL kaya-sims booted)"
    elif [ "$WARM" = 1 ]; then
        # Same creation logic run-sim.py uses.
        dtype=$(xcrun simctl list devicetypes 2>/dev/null | grep -E "iPhone [0-9]+ Pro \(" \
            | tail -1 | grep -oE 'com.apple.CoreSimulator.SimDeviceType[^)]*')
        runtime=$(xcrun simctl list runtimes 2>/dev/null | grep -m1 -oE 'com.apple.CoreSimulator.SimRuntime.iOS[0-9-]+')
        i=0
        while [ "$i" -lt "$IOS_POOL" ]; do
            udid=$(xcrun simctl list devices 2>/dev/null | grep -m1 "kaya-sim-$i (" \
                | grep -oE '[0-9A-F-]{36}' || true)
            [ -n "$udid" ] || udid=$(xcrun simctl create 2>/dev/null "kaya-sim-$i" "$dtype" "$runtime")
            xcrun simctl boot "$udid" 2>/dev/null || true
            i=$((i + 1))
        done
        for u in $(xcrun simctl list devices 2>/dev/null | grep "kaya-sim-" | grep -oE '[0-9A-F-]{36}'); do
            timeout 180 xcrun simctl bootstatus "$u" -b >/dev/null 2>&1 || true
        done
        # COUNTED AGAIN, not asserted: every create/boot/bootstatus above
        # is deliberately non-fatal.
        booted=$(xcrun simctl list devices booted 2>/dev/null | grep -c "kaya-sim-.*Booted" || true)
        if [ "$booted" -ge "$IOS_POOL" ]; then
            report ios OK "sim pool booted ($booted/$IOS_POOL, warmed now)"
        else
            warm_skip ios
            report ios COLD "sim pool is still $booted/$IOS_POOL after --warm booted what it could — this arm discards simctl's output, so boot a missing kaya-sim-N by hand to see the error"
        fi
    else
        report ios COLD "sim pool cold ($booted/$IOS_POOL booted; --warm boots it)"
    fi
else
    report ios DOWN "simctl unavailable — run inside nix develop (xcrun stub/CLT trap)"
fi

# --- iOS clipboard isolation -----------------------------------------
# Simulator.app relays the macOS pasteboard into every booted simulator
# by default (docs/clipboard-plan.md:1502). Early warning only —
# run-sim.py measures the relay per run and refuses. It names the APP,
# not the pref: a running Simulator.app ignores a `defaults write`.
if pgrep -qx Simulator; then
    pref=$(defaults read com.apple.iphonesimulator PasteboardAutomaticSync 2>/dev/null || echo unset)
    report ios-clip CHECK \
        "Simulator.app is running (stored PasteboardAutomaticSync=$pref) — quit it or turn off Edit > Automatically Sync Pasteboard; run-sim.py measures the relay and refuses"
else
    report ios-clip OK "Simulator.app not running — device clipboards are the devices' own"
fi

# --- Android emulator ------------------------------------------------
ANDROID_POOL="${KAYA_ANDROID_EMUS:-4}"
case "$ANDROID_POOL" in
    ''|*[!0-9]*)
        report android DOWN "KAYA_ANDROID_EMUS must be a positive integer"
        ;;
    *)
        if [ "$ANDROID_POOL" -lt 1 ]; then
            report android DOWN "KAYA_ANDROID_EMUS must be at least 1"
        elif command -v adb >/dev/null && command -v emulator >/dev/null; then
            export ANDROID_AVD_HOME="$ROOT/target/avd"
            android_state=""
            if ! android_state="$(android_emulator_state_id "${ANDROID_SDK_ROOT:-}")"; then
                report android DOWN "could not resolve the pinned emulator and system image"
            else
                case "$android_state" in
                    *$'\n'*)
                        android_emulator="${android_state%%$'\n'*}"
                        android_image="${android_state#*$'\n'}"
                        android_guest_id=/data/local/tmp/kaya-emulator-identity
                        android_snapshot_stale=""
                        if ! android_snapshot_state_current \
                            "$ANDROID_AVD_HOME/kaya.avd/.kaya-default-boot-id" \
                            "$ANDROID_AVD_HOME/kaya.avd/snapshots/default_boot" \
                            "$android_emulator" "$android_image"; then
                            android_snapshot_stale=phone
                        fi
                        if ! android_snapshot_state_current \
                            "$ANDROID_AVD_HOME/kaya-tablet.avd/.kaya-default-boot-id" \
                            "$ANDROID_AVD_HOME/kaya-tablet.avd/snapshots/default_boot" \
                            "$android_emulator" "$android_image"; then
                            android_snapshot_stale="${android_snapshot_stale:+$android_snapshot_stale and }tablet"
                        fi
                        if [ -n "$android_snapshot_stale" ]; then
                            warm_skip android
                            report android COLD "$android_snapshot_stale snapshot stale — tools/android/run-emulator.py reseeds both before readers"
                        else
                            android_phone_up=0
                            i=0
                            while [ "$i" -lt "$ANDROID_POOL" ]; do
                                port=$((5554 + 2 * i))
                                if android_live_instance_current \
                                    "emulator-$port" kaya \
                                    "$android_emulator" "$android_image" "$android_guest_id"; then
                                    android_phone_up=$((android_phone_up + 1))
                                fi
                                i=$((i + 1))
                            done
                            android_tablet_port=$((5554 + 2 * ANDROID_POOL))
                            android_tablet_up=0
                            if android_live_instance_current \
                                "emulator-$android_tablet_port" kaya-tablet \
                                "$android_emulator" "$android_image" "$android_guest_id"; then
                                android_tablet_up=1
                            fi
                            if [ "$android_phone_up" -eq "$ANDROID_POOL" ] \
                                && [ "$android_tablet_up" -eq 1 ]; then
                                report android OK "current phone pool ($android_phone_up/$ANDROID_POOL) and tablet (1/1)"
                            elif [ "$WARM" -eq 1 ]; then
                                warm_skip android
                                report android COLD "phone $android_phone_up/$ANDROID_POOL, tablet $android_tablet_up/1 current — --warm does NOT boot this coupled pool; tools/android/run-emulator.py owns it"
                            else
                                report android COLD "phone $android_phone_up/$ANDROID_POOL, tablet $android_tablet_up/1 current — tools/android/run-emulator.py owns the coupled pool"
                            fi
                        fi
                        ;;
                    *)
                        report android DOWN "emulator state identity was incomplete"
                        ;;
                esac
            fi
        else
            report android DOWN "adb/emulator unavailable — run inside nix develop"
        fi
        ;;
esac

# --- Linux container -------------------------------------------------
if docker info >/dev/null 2>&1; then
    # `docker images -q` over `image inspect`: the latter misreports
    # untagged lookups under some docker CLIs.
    if [ -n "$(docker images -q kaya-linux 2>/dev/null)" ]; then
        # A cached image can predate a Dockerfile layer; the clipboard
        # tools are the youngest, so probing them names the fix early.
        if docker run --rm kaya-linux bash -c \
            'command -v wl-copy && command -v xclip && command -v wtype && command -v identify' \
            >/dev/null 2>&1; then
            report linux OK "docker up, image cached"
        else
            report linux COLD "image cached but predates the clipboard tools layer — validate-linux rebuilds it"
        fi
    else
        report linux COLD "docker up, image not built yet (first run builds it)"
    fi
else
    report linux DOWN "docker not running"
fi

# --- Windows VM ------------------------------------------------------
WIN_HOST="${KAYA_WIN_HOST:-akhil@192.168.64.2}"
if ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$WIN_HOST" 'exit 0' 2>/dev/null; then
    # Display sleep blanks every window while suites keep passing.
    if ssh -n -o BatchMode=yes "$WIN_HOST" 'powercfg /q SCHEME_CURRENT SUB_VIDEO VIDEOIDLE' 2>/dev/null \
        | grep -q 'AC Power Setting Index: 0x00000000'; then
        report windows OK "$WIN_HOST answering; display never sleeps"
    else
        report windows DOWN "$WIN_HOST answering but display CAN sleep — run: powercfg /change monitor-timeout-ac 0"
    fi
elif [ "$WARM" = 1 ]; then
    utmctl=$(command -v utmctl || echo /Applications/UTM.app/Contents/MacOS/utmctl)
    if "$utmctl" start "${KAYA_WIN_VM:-Windows}" 2>/dev/null; then
        report windows COLD "VM starting (deploy-win will wait for sshd)"
    else
        report windows DOWN "unreachable and utmctl could not start the VM"
    fi
else
    report windows COLD "unreachable (deploy-win auto-starts it, or --warm)"
fi

# --- what --warm did not do ------------------------------------------
# `--warm` CANNOT BOOT THE ANDROID POOL: it is coupled (phones + tablet +
# a snapshot identity) and tools/android/run-emulator.py owns it. This
# refusal exists because reporting COLD and exiting 0 let a benchmark pay
# 60-90s of emulator boot inside the number it was measuring.
if [ -n "$warm_skipped" ]; then
    echo "probe-env: --warm did not warm:$warm_skipped — the report line for each" >&2
    echo "  says what it needs. This exits 1 rather than 0 so a benchmark started" >&2
    echo "  behind it does not pay a boot inside the number it is measuring." >&2
    status=1
fi

exit "$status"
