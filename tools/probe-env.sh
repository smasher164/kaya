#!/usr/bin/env bash

# Everything runs inside the dev shell: the flake pins every toolchain
# (rust + cross targets, swiftc, ffmpeg, the android sdk). Running
# against anything else is an error, not something to paper over — and
# a shell entered before the flake last changed is just as much a
# bystander toolchain, so the marker carries the fingerprint of
# flake.nix+flake.lock the shell was actually built from.
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# One place that knows how to ask whether each test surface is ready —
# the probes encode every lesson their ad-hoc predecessors got wrong.
# Run it before a session (or let suites fail loud); nothing here
# mutates state except `--warm`, which boots what is cold.
#
#   tools/probe-env.sh          report readiness of every surface
#   tools/probe-env.sh --warm   also boot the simulator / emulator / VM
#
# Lessons encoded:
#   - simctl exists only under Xcode's developer dir; outside the dev
#     shell, xcrun silently resolves to a stub or CommandLineTools and
#     queries read as EMPTY, not as errors. Probe via the dev shell's
#     xcrun and treat "cannot list" as broken-env, never as "no sim".
#   - The Windows VM drops ICMP: ping reads as down while sshd answers.
#     Probe with ssh BatchMode + timeout, exactly as deploy-win does.
#   - macOS screen capture wedges silently (poisoned binary identity,
#     sick daemons); record-suite --probe answers in seconds.
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
        report linux OK "docker up, image cached"
    else
        report linux COLD "docker up, image not built yet (first run builds it)"
    fi
else
    report linux DOWN "docker not running"
fi

# --- Windows VM ------------------------------------------------------
WIN_HOST="${KAYA_WIN_HOST:-akhil@192.168.64.2}"
if ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$WIN_HOST" 'exit 0' 2>/dev/null; then
    # Display sleep blanks every window while suites keep passing;
    # recorded runs assert this too, but say it early here.
    if ssh -n -o BatchMode=yes "$WIN_HOST" 'powercfg /q SCHEME_CURRENT SUB_VIDEO VIDEOIDLE' 2>/dev/null \
        | grep -q 'AC Power Setting Index: 0x00000000'; then
        report windows OK "$WIN_HOST answering; display never sleeps"
    else
        report windows DOWN "$WIN_HOST answering but display CAN sleep — run: powercfg /change monitor-timeout-ac 0"
    fi
elif [ "$WARM" = 1 ]; then
    # deploy-win auto-starts the VM the same way; doing it here just
    # front-loads the wait.
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
