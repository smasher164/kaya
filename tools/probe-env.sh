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
# One place that knows how to ask whether each test surface is ready.
# Nothing here mutates state except `--warm`, which boots what is cold.
#
#   tools/probe-env.sh          report readiness of every surface
#   tools/probe-env.sh --warm   also boot the simulator / emulator / VM
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
WARM=0
[ "${1:-}" = --warm ] && WARM=1
status=0

report() { # name state detail
    printf '%-12s %-6s %s\n' "$1" "$2" "$3"
    [ "$2" = DOWN ] && status=1
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
# /opt/homebrew on top of an inherited dev-shell PATH (Claude Code's
# shell snapshots do exactly this), and any formula shadowing a pinned
# tool then wins by order. A homebrew ocaml — same "5.4.1" version
# string, different build — once drove nix dune/ppxlib into
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
# NSOpenPanel publishes a different accessibility identifier per view
# mode, and the mode is MACHINE-WIDE (docs/traps.md). Reported, not
# demanded: validate-mac rotates 1/2/3 across the filedialog legs and
# restores this value. The one state that IS a problem is a fourth mode
# the interpreter's KayaPanelShape cannot read.
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

# --- iOS simulator ---------------------------------------------------
# Same fallback run-sim.sh uses: the nix xcrun stub and the
# CommandLineTools default both lack simctl; only Xcode has it.
if ! xcrun simctl help >/dev/null 2>&1; then
    for app in /Applications/Xcode.app /Applications/Xcode-*.app; do
        if [ -d "$app/Contents/Developer" ]; then
            export DEVELOPER_DIR="$app/Contents/Developer"
            break
        fi
    done
fi
IOS_POOL="${KAYA_IOS_SIMS:-2}"
if xcrun simctl list devices >/dev/null 2>&1; then
    booted=$(xcrun simctl list devices booted 2>/dev/null | grep -c "kaya-sim-.*Booted" || true)
    if [ "$booted" -ge "$IOS_POOL" ]; then
        report ios OK "sim pool warm ($booted/$IOS_POOL kaya-sims booted)"
    elif [ "$WARM" = 1 ]; then
        # Same creation logic run-sim.sh uses.
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
        report ios OK "sim pool booted (warmed now)"
    else
        report ios COLD "sim pool cold ($booted/$IOS_POOL booted; --warm boots it)"
    fi
else
    report ios DOWN "simctl unavailable — run inside nix develop (xcrun stub/CLT trap)"
fi

# --- iOS clipboard isolation -----------------------------------------
# Simulator.app relays the macOS pasteboard into and out of every booted
# simulator by default (docs/clipboard-plan.md:1502), so the clipboard
# legs would share one board with the mac lane. Early warning only —
# run-sim.sh MEASURES the relay per run and refuses. It names the APP,
# not the pref: a running Simulator.app ignores a `defaults write` and
# the pref can read NO while the relay is live.
if pgrep -qx Simulator; then
    pref=$(defaults read com.apple.iphonesimulator PasteboardAutomaticSync 2>/dev/null || echo unset)
    report ios-clip CHECK \
        "Simulator.app is running (stored PasteboardAutomaticSync=$pref) — quit it or turn off Edit > Automatically Sync Pasteboard; run-sim.sh measures the relay and refuses"
else
    report ios-clip OK "Simulator.app not running — device clipboards are the devices' own"
fi

# --- Android emulator ------------------------------------------------
ANDROID_POOL="${KAYA_ANDROID_EMUS:-2}"
if command -v adb >/dev/null; then
    up=$(adb devices 2>/dev/null | grep -c "emulator-.*device$" || true)
    if [ "$up" -ge "$ANDROID_POOL" ]; then
        report android OK "emulator pool warm ($up/$ANDROID_POOL)"
    elif [ "$WARM" = 1 ] && command -v emulator >/dev/null; then
        # Read-only instances of the shared AVD, like run-emulator.
        export ANDROID_AVD_HOME="$ROOT/target/avd"
        i=0
        while [ "$i" -lt "$ANDROID_POOL" ]; do
            port=$((5554 + 2 * i))
            if ! adb -s "emulator-$port" get-state 2>/dev/null | grep -q device; then
                emulator -avd kaya -read-only -no-window -no-audio -no-boot-anim \
                    -gpu swiftshader_indirect -port "$port" \
                    >"$ROOT/target/emu-$port.log" 2>&1 &
            fi
            i=$((i + 1))
        done
        report android OK "emulator pool booting ($ANDROID_POOL instances; quickboot ~5s)"
    else
        report android COLD "emulator pool cold ($up/$ANDROID_POOL; --warm or run-emulator boots it)"
    fi
else
    report android DOWN "adb unavailable — run inside nix develop"
fi

# --- Linux container -------------------------------------------------
if docker info >/dev/null 2>&1; then
    # `docker images -q` over `image inspect`: the latter misreports
    # untagged lookups under some docker CLIs.
    if [ -n "$(docker images -q kaya-linux 2>/dev/null)" ]; then
        # A cached image can predate a Dockerfile layer. The clipboard
        # tools are the youngest layer, so probing them names the fix
        # early instead of a clipboard leg failing on a missing tool.
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

exit "$status"
