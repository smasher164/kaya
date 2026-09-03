# shellcheck shell=bash
# The flight recorder, shared by the lane runners — source, don't execute.
# No shebang for that reason; line 1's directive is what names the dialect,
# and without it check-shell errors out. (No comment line below may begin
# with the word shellcheck — it would parse as a second directive.)
#
# ONE FAILURE IS ENOUGH EVIDENCE. A leg that fails once and passes on the
# rerun currently leaves nothing behind but a verdict, so the next sighting
# starts from zero. This appends every leg to a journal outside the build
# tree (tools/lib/flightrec.py says why that location and no other), and on
# a FAIL collects a bundle of the state that was live at the time.
#
# THE RECORDER MAY NEVER COST A LANE ITS LEGS. Every entry point is a
# no-op when the journal could not be opened, the miss is printed ONCE by
# flightrec_start, and no function here returns nonzero to its caller.

FLIGHTREC_OK=0
FLIGHTREC_RUN=""
# Per-section byte cap and the whole bundle's, both printed by
# flightrec_bundle_report. A capture nobody can afford to keep is a
# capture nobody keeps.
FLIGHTREC_SECTION_CAP="${KAYA_FLIGHTREC_SECTION_CAP:-2097152}"
FLIGHTREC_BUNDLE_CAP="${KAYA_FLIGHTREC_BUNDLE_CAP:-33554432}"

flightrec_lib() {
    echo "${FLIGHTREC_ROOT:-.}/tools/lib/flightrec.py"
}

# flightrec_start <lane> — open a run. Sets FLIGHTREC_RUN/FLIGHTREC_OK.
flightrec_start() {
    local lane="$1" root="${FLIGHTREC_ROOT:-.}" out=""
    FLIGHTREC_OK=0
    FLIGHTREC_RUN=""
    if ! command -v python3 >/dev/null 2>&1; then
        echo "flightrec: python3 is not on this host — no journal for this run" >&2
        return 0
    fi
    # STDOUT ONLY. Merging stderr in with 2>&1 put the retention sentence
    # FIRST — stderr is unbuffered and stdout is not — so the run id
    # became that sentence and every leg record was filed under a path
    # made of it. Caught by tools/flightrec-selftest.py's N0.
    out="$(python3 "$(flightrec_lib)" start "$lane" "$root")" || out=""
    if [ -z "$out" ]; then
        echo "flightrec: the journal could not be opened — this run is not recorded," \
            "but every leg still runs" >&2
        return 0
    fi
    FLIGHTREC_RUN="${out%%$'\t'*}"
    FLIGHTREC_RUNDIR="${out#*$'\t'}"
    FLIGHTREC_SPOOL="$FLIGHTREC_RUNDIR/spool.tsv"
    FLIGHTREC_OK=1
    export FLIGHTREC_OK FLIGHTREC_RUN FLIGHTREC_ROOT FLIGHTREC_RUNDIR FLIGHTREC_SPOOL
    return 0
}

# flightrec_flush — spool -> journal, once. Called at lane end AND from the
# runner's EXIT trap; the flush truncates the spool, so the second call is
# a no-op rather than a second copy of every record.
flightrec_flush() {
    [ "${FLIGHTREC_OK:-0}" = 1 ] || return 0
    [ -s "${FLIGHTREC_SPOOL:-/nonexistent}" ] || return 0
    local n
    n="$(python3 "$(flightrec_lib)" flush "$FLIGHTREC_RUN" "$FLIGHTREC_SPOOL" 2>/dev/null)" || n=""
    [ -z "$n" ] || echo "flightrec: $n leg record(s) written to $FLIGHTREC_RUNDIR/journal.jsonl"
    return 0
}

# flightrec_bundle <lane> <leg> — print a bundle directory, or nothing.
flightrec_bundle() {
    [ "${FLIGHTREC_OK:-0}" = 1 ] || return 0
    python3 "$(flightrec_lib)" bundle "$FLIGHTREC_RUN" "$1" "$2" 2>/dev/null || true
}

# flightrec_leg <lane> <leg> <verdict> <secs> [<fail sentence>] [<bundle>]
#
# NO SUBPROCESS. This runs on EVERY leg of two lanes, and the pass path is
# where an observer has to be free: one python3 spawn per leg measured 27ms
# on the mac host, and it was part of the 110s that took the windows lane
# over its ceiling on the recorder's first matrix. One `printf` appends a
# TAB-separated line; flightrec_flush turns the whole spool into JSONL once.
# `printf` is a bash BUILTIN, and one write under the pipe-buffer size is
# atomic on O_APPEND, which is what keeps the concurrent leg pools from
# interleaving a line.
flightrec_leg() {
    [ "${FLIGHTREC_OK:-0}" = 1 ] || return 0
    local lane="$1" leg="$2" verdict="$3" secs="$4" fail="${5:-}" bundle="${6:-}"
    # TABs and newlines are the record separators, so they cannot survive
    # inside a field. Bash substitution, still no subprocess.
    fail="${fail//$'\t'/ }"
    fail="${fail//$'\n'/ }"
    fail="${fail//$'\r'/ }"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$lane" "$leg" "$verdict" "$secs" "${EPOCHSECONDS:-0}" "$bundle" "$fail" \
        >>"$FLIGHTREC_SPOOL" 2>/dev/null || true
    return 0
}

# The failure sentence the harness itself printed, pulled out of a leg log
# so the journal carries WHY and not merely THAT.
flightrec_fail_sentence() {
    local log="$1"
    [ -f "$log" ] || return 0
    grep -m1 "KAYA_SELFTEST: FAILED" "$log" 2>/dev/null \
        || grep -m1 "KAYA_HARNESS: step-failed" "$log" 2>/dev/null \
        || true
}

flightrec_mark() { # <bundle> <name> <state> <bytes>
    printf '%s %s %s\n' "$2" "$3" "$4" >>"$1/MANIFEST"
}

# flightrec_section <bundle> <name> <tool-or-empty> <cmd...>
#
# THE HONEST SKIP IS THE POINT. A capture tool this host does not have
# leaves a .skip file naming the tool, never a silently missing section:
# an absent section and an empty one are different findings, and the
# reader of a bundle must be able to tell them apart (invariant 3).
flightrec_section() {
    local bundle="$1" name="$2" tool="$3"
    shift 3
    [ -n "$bundle" ] && [ -d "$bundle" ] || return 0
    if [ -n "$tool" ] && ! command -v "$tool" >/dev/null 2>&1; then
        printf 'flightrec: %s is not on this host — section %s not collected\n' \
            "$tool" "$name" >"$bundle/$name.skip"
        flightrec_mark "$bundle" "$name" skip 0
        return 0
    fi
    local out="$bundle/$name.txt" rc=0
    "$@" >"$out" 2>&1 || rc=$?
    local bytes
    bytes="$(wc -c <"$out" 2>/dev/null | tr -d ' ')"
    [ -n "$bytes" ] || bytes=0
    if [ "$bytes" -gt "$FLIGHTREC_SECTION_CAP" ]; then
        head -c "$FLIGHTREC_SECTION_CAP" "$out" >"$out.cut" 2>/dev/null
        printf '\n... truncated at %s bytes (flightrec section cap)\n' \
            "$FLIGHTREC_SECTION_CAP" >>"$out.cut"
        mv "$out.cut" "$out" 2>/dev/null
        bytes="$FLIGHTREC_SECTION_CAP"
    fi
    if [ "$rc" != 0 ]; then
        flightrec_mark "$bundle" "$name" error "$bytes"
    elif [ "$bytes" = 0 ]; then
        flightrec_mark "$bundle" "$name" empty "$bytes"
    else
        flightrec_mark "$bundle" "$name" ok "$bytes"
    fi
    return 0
}

# flightrec_adopt <bundle> <name> <file> — take a file a sampler already
# wrote into the bundle, under the manifest.
flightrec_adopt() {
    local bundle="$1" name="$2" src="$3"
    [ -n "$bundle" ] && [ -d "$bundle" ] || return 0
    if [ ! -f "$src" ]; then
        printf 'flightrec: nothing was sampled for section %s\n' "$name" >"$bundle/$name.skip"
        flightrec_mark "$bundle" "$name" skip 0
        return 0
    fi
    cp "$src" "$bundle/$name.txt" 2>/dev/null || true
    local bytes
    bytes="$(wc -c <"$bundle/$name.txt" 2>/dev/null | tr -d ' ')"
    [ -n "$bytes" ] || bytes=0
    if [ "$bytes" = 0 ]; then
        flightrec_mark "$bundle" "$name" empty 0
    else
        flightrec_mark "$bundle" "$name" ok "$bytes"
    fi
    return 0
}

# flightrec_bundle_report <bundle> — the counts and the size, PRINTED. A
# bundle whose sections silently stopped being collected looks exactly
# like one that was never needed, so the numbers go on the lane's log.
flightrec_bundle_report() {
    local bundle="$1"
    [ -n "$bundle" ] && [ -d "$bundle" ] || return 0
    # ONE reader for the counts. Four `grep -c ... || echo 0` calls print
    # TWO numbers when grep finds none — it prints its own 0 and exits 1 —
    # so the sentence read "0\n0 empty". Measured on the first bundle.
    local counts
    counts="$(python3 - "$bundle/MANIFEST" <<'PY'
import collections
import pathlib
import sys

states = collections.Counter()
total = 0
p = pathlib.Path(sys.argv[1])
if p.is_file():
    for line in p.read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) >= 2:
            total += 1
            states[parts[1]] += 1
print(f"{total} {states['ok']} {states['skip']} {states['empty']} {states['error']}")
PY
)" || counts="0 0 0 0 0"
    local bytes
    bytes="$(python3 "$(flightrec_lib)" size "$bundle" 2>/dev/null || echo 0)"
    # shellcheck disable=SC2086
    set -- $counts
    echo "flightrec: bundle $bundle — $1 sections ($2 ok, $3 skipped," \
        "$4 empty, $5 error), $bytes bytes (cap $FLIGHTREC_BUNDLE_CAP)"
    if [ "$bytes" -gt "$FLIGHTREC_BUNDLE_CAP" ] 2>/dev/null; then
        echo "flightrec: bundle $bundle is OVER its cap — the section caps did not hold it" >&2
    fi
    return 0
}

# The Windows half lives in tools/lib/flightrec_lane.py since the
# runner conversion — it crossed with tools/deploy-win.py, the first
# runner that stopped sourcing this file.

# ---------------------------------------------------------------- macOS --
#
# THE SAMPLER IS THE ONLY HONEST WAY TO HAVE A STACK AT FAIL TIME. A leg's
# verdict is known only once the guest has exited, and `sample` needs a
# LIVE process — so by the time the runner knows the leg failed there is
# nothing left to sample. The runner therefore starts a cheap poller
# alongside each leg and keeps its output only when the leg fails, which
# is also what makes a HANG legible: the mac lane's `timeout 120` is a
# KILL that takes the buffered log with it (docs/traps.md), and this
# samples the wedged process a few seconds BEFORE that kill lands.

# The mac half — the per-leg sampler, the window-scoped shot and
# flightrec_mac_leg's capture — crossed into tools/lib/flightrec_lane.py's
# MacRecorder with the runner conversion (validate-mac was its only
# caller; tools/flightrec-selftest.py drives the crossed capture).
