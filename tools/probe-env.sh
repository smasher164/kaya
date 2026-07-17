#!/usr/bin/env bash
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
if sims=$(xcrun simctl list devices booted 2>/dev/null); then
    if grep -q "(Booted)" <<<"$sims"; then
        report ios OK "simulator booted: $(grep -m1 -oE 'iPhone[^(]*' <<<"$sims" | sed 's/ *$//')"
    elif [ "$WARM" = 1 ]; then
        udid=$(xcrun simctl list devices available \
            | grep -m1 -oE 'iPhone[^(]*\(([0-9A-F-]{36})\)' | grep -oE '[0-9A-F-]{36}' || true)
        if [ -n "$udid" ] && xcrun simctl boot "$udid" 2>/dev/null \
            && xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1; then
            report ios OK "simulator booted (warmed now)"
        else
            report ios DOWN "could not boot a simulator"
        fi
    else
        report ios COLD "no simulator booted (~60-90s on first run, or --warm)"
    fi
else
    report ios DOWN "simctl unavailable — run inside nix develop (xcrun stub/CLT trap)"
fi

# --- Android emulator ------------------------------------------------
if command -v adb >/dev/null; then
    if adb devices 2>/dev/null | grep -q "emulator-.*device$"; then
        report android OK "emulator running"
    else
        report android COLD "no emulator running (run-emulator boots one)"
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
    report windows OK "$WIN_HOST answering (ssh — never probe with ping)"
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
