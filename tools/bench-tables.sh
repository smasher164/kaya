#!/usr/bin/env bash

# Dev-shell guard; the marker is the flake fingerprint (CLAUDE.md).
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# The table/scroll bench, one platform per run. A measuring INSTRUMENT,
# not a gate: check-gates' census does not see a `bench-` name, because a
# benchmark has no pass/fail to sweep.
#
# Usage: tools/bench-tables.sh <platform> [--dry-run] [--rows N,N,N]
#                              [--repeats K] [--chunk C] [--out PATH]
#        platform: guest | macos | linux | windows | android | ios
#
# What each number means, the 2026-08-24 baselines, the recipes for the
# four platforms this does not drive itself, and the CAVEATS that decide
# whether a number is worth anything: docs/measurements/README.md.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

DATE="$(date -u +%Y-%m-%d)"

case "$(uname -s)" in
    Darwin) CORE_LIB="libkaya.dylib" ;;
    *) CORE_LIB="libkaya.so" ;;
esac

usage() {
    echo "usage: $0 <guest|macos|linux|windows|android|ios> [--dry-run]" >&2
    echo "          [--rows N,N,N] [--repeats K] [--chunk C] [--out PATH]" >&2
}

PLATFORM="${1:-}"
if [ -z "$PLATFORM" ]; then
    usage
    exit 2
fi
shift

DRY_RUN=0
ROWS=""
REPEATS=3
CHUNK=""
OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --rows) shift; ROWS="${1:-}" ;;
        --repeats) shift; REPEATS="${1:-}" ;;
        --chunk) shift; CHUNK="${1:-}" ;;
        --out) shift; OUT="${1:-}" ;;
        *)
            echo "$0: unknown argument '$1'" >&2
            usage
            exit 2
            ;;
    esac
    shift
done

case "$PLATFORM" in
    guest | macos | linux | windows | android | ios) ;;
    *)
        echo "$0: '$PLATFORM' is not a bench platform." >&2
        usage
        exit 2
        ;;
esac

# ---- refuse to measure next to a matrix -----------------------------
# A saturated machine makes a number worthless: macOS Part B carried
# "+/- 50% run-to-run" beside four lanes, and Linux's 5000-6000 band went
# wide enough that 2250 came in slower than 2500. There is no lockfile to
# consult, so the two causes are read two ways and answered in two.

# The converted runners run as python bodies (the .sh beside each is an
# exec shim), so pgrep must look for the .py names.
MATRIX_RUNNERS="validate-all.py validate-mac.py validate-linux.py deploy-win.py run-sim.py run-emulator.py"

if [ -n "${KAYA_MATRIX_GATES_TOKEN:-}" ]; then
    echo "$0: refusing — this shell carries KAYA_MATRIX_GATES_TOKEN, which" >&2
    echo "  tools/validate-all.py exports to the lanes it starts. A bench run" >&2
    echo "  inside the matrix measures the matrix's contention, not kaya." >&2
    exit 3
fi

busy=""
for runner in $MATRIX_RUNNERS; do
    if pgrep -f "tools/.*$runner" >/dev/null 2>&1; then
        busy="$busy $runner"
    fi
done
if [ -n "$busy" ]; then
    echo "$0: refusing — these lane runners are live on this machine:$busy" >&2
    echo "  Every number here would be a measurement of the contention" >&2
    echo "  instead (docs/measurements/README.md, CAVEATS). Wait for them," >&2
    echo "  or re-run on a machine nobody is using." >&2
    exit 3
fi

# ---- the environment each platform needs ----------------------------
#
# The checks are probe-env.sh's, copied rather than sourced: its report()
# is file-local and its exit code answers about ALL FIVE lanes at once,
# which is the wrong question here. Run tools/probe-env.sh for the whole
# board.

probe_guest() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "$0: python3 is not on PATH." >&2
        return 1
    fi
    return 0
}

probe_macos() {
    if [ "$(uname -s)" != "Darwin" ]; then
        echo "$0: the macos bench needs a mac; this host is $(uname -s)." >&2
        return 1
    fi
    local session
    session="$(launchctl managername 2>/dev/null)"
    if [ "$session" != "Aqua" ]; then
        echo "$0: the macos bench needs a logged-in GUI session — the" >&2
        echo "  interpreter opens real windows (validation ladder, rung 3)." >&2
        echo "  launchctl managername says '${session:-nothing}', not 'Aqua'." >&2
        return 1
    fi
    if [ ! -f target/swiftui/libkaya_swiftui.dylib ]; then
        echo "$0: target/swiftui/libkaya_swiftui.dylib is missing — build it" >&2
        echo "  with tools/swiftui/build-dylib.sh, then re-run." >&2
        return 1
    fi
    return 0
}

probe_linux() {
    if ! docker info >/dev/null 2>&1; then
        echo "$0: the linux bench needs docker running (probe-env.sh reports" >&2
        echo "  the same thing as 'linux DOWN docker not running')." >&2
        return 1
    fi
    if [ -z "$(docker images -q kaya-linux 2>/dev/null)" ]; then
        echo "$0: the kaya-linux image is not cached — build it the way" >&2
        echo "  tools/validate-linux.py does, then re-run." >&2
        return 1
    fi
    return 0
}

probe_windows() {
    local host="${KAYA_WIN_HOST:-akhil@192.168.64.2}"
    if ! ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$host" 'exit 0' 2>/dev/null; then
        echo "$0: the windows VM ($host) is not answering ssh." >&2
        echo "  Start it (tools/probe-env.sh --warm) and re-run." >&2
        return 1
    fi
    return 0
}

probe_android() {
    if ! command -v adb >/dev/null 2>&1 || ! command -v emulator >/dev/null 2>&1; then
        echo "$0: adb/emulator are not on PATH — run inside nix develop." >&2
        return 1
    fi
    local booted
    booted="$(adb devices 2>/dev/null | grep -c 'emulator-.*device$')"
    if [ "$booted" -lt 1 ]; then
        echo "$0: no emulator is booted; 'adb devices' lists none." >&2
        echo "  Start the pool (tools/probe-env.sh --warm) and re-run." >&2
        return 1
    fi
    return 0
}

probe_ios() {
    if ! xcrun simctl list devices >/dev/null 2>&1; then
        echo "$0: simctl is unavailable — run inside nix develop (the xcrun" >&2
        echo "  stub/CLT trap; probe-env.sh reports it the same way)." >&2
        return 1
    fi
    local booted
    booted="$(xcrun simctl list devices booted 2>/dev/null | grep -c 'kaya-sim-.*Booted')"
    if [ "$booted" -lt 1 ]; then
        echo "$0: no kaya-sim-* simulator is booted." >&2
        echo "  Start the pool (tools/probe-env.sh --warm) and re-run." >&2
        return 1
    fi
    return 0
}

"probe_$PLATFORM"
probe_status=$?

# ---- the four rigs this script does not drive itself ----------------
# Their recipes are in the README, NOT transcribed into never-run
# orchestration here: code no run exercises rots silently (invariant 3).
# The sentences below discriminate — a rig that is not automated and a
# device that is not up are different problems.
case "$PLATFORM" in
    linux | windows | android | ios)
        if [ "$probe_status" -eq 0 ]; then
            env_state="its environment is up"
        else
            env_state="its environment is down too — the sentence above says how"
        fi
        echo "$0: this script does not drive the $PLATFORM rig yet; only" >&2
        echo "  'guest' and 'macos' are automated, and $env_state." >&2
        echo "  The recorded $PLATFORM recipe, step by step, is in" >&2
        echo "  docs/measurements/README.md under 'The five rigs'." >&2
        exit 5
        ;;
esac

if [ "$probe_status" -ne 0 ]; then
    exit 4
fi

# ---- build what the bench reads, and verify it -----------------------
#
# A bench that runs a stale library measures a tree nobody has.
if [ "$PLATFORM" = "guest" ] || [ "$PLATFORM" = "macos" ]; then
    cargo build --locked --lib
    build_status=$?
    if [ "$build_status" -ne 0 ]; then
        echo "$0: cargo build --locked --lib failed — not benching a stale library." >&2
        exit 1
    fi
    tools/build-id.py --verify "target/debug/$CORE_LIB" || exit 1
    if [ "$PLATFORM" = "macos" ]; then
        tools/build-id.py --verify --component swiftui \
            target/swiftui/libkaya_swiftui.dylib || exit 1
    fi
fi

# ---- where the record lands -----------------------------------------
#
# A dry run is not a measurement and never lands in docs/measurements.
if [ -z "$OUT" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        OUT="target/bench/tables-$PLATFORM-$DATE-dryrun.txt"
    else
        OUT="docs/measurements/tables-$PLATFORM-$DATE.txt"
    fi
fi
mkdir -p "$(dirname "$OUT")"

cmd=(python3)
case "$PLATFORM" in
    guest) cmd+=(tools/bench/insert_bench.py) ;;
    macos) cmd+=(tools/bench/drive_mac.py) ;;
esac
cmd+=(--repeats "$REPEATS")
if [ -n "$ROWS" ]; then
    cmd+=(--rows "$ROWS")
fi
if [ -n "$CHUNK" ] && [ "$PLATFORM" = "macos" ]; then
    cmd+=(--chunk "$CHUNK")
fi
if [ "$DRY_RUN" -eq 1 ]; then
    cmd+=(--dry-run)
fi

tmp="$(mktemp)"
"${cmd[@]}" 2>&1 | tee "$tmp"
run_status="${PIPESTATUS[0]}"
if [ "$run_status" -ne 0 ]; then
    rm -f "$tmp"
    echo "$0: the $PLATFORM bench exited $run_status — nothing recorded." >&2
    exit 1
fi
mv "$tmp" "$OUT"
echo "$0: recorded $OUT"
