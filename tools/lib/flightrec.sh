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
    # made of it. Caught by tools/flightrec-selftest.sh's N0.
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

flightrec_mac_winlist_bin() {
    local root="${FLIGHTREC_ROOT:-.}"
    local src="$root/tools/mac/flightrec-winlist.swift"
    [ -f "$src" ] || return 1
    local h
    h="$(shasum -a 256 "$src" | cut -c1-12)"
    local bin="$root/target/tools/flightrec-winlist-$h"
    if [ -x "$bin" ]; then
        echo "$bin"
        return 0
    fi
    command -v kaya_swiftc >/dev/null 2>&1 || declare -F kaya_swiftc >/dev/null || return 1
    mkdir -p "$root/target/tools" || return 1
    kaya_swiftc -O -o "$bin.$$" "$src" >/dev/null 2>&1 || return 1
    mv "$bin.$$" "$bin" 2>/dev/null || return 1
    echo "$bin"
}

# Every descendant of a pid, deepest last — the guest is under `timeout`
# and often under `env` as well, so the leg's own pid is never the app's.
flightrec_descendants() {
    local pid="$1" kid
    for kid in $(pgrep -P "$pid" 2>/dev/null); do
        echo "$kid"
        flightrec_descendants "$kid"
    done
}

# ANCHORED ON `timeout`, not on a list of names to ignore. Both of the
# runner's leg paths run the guest as `timeout 120 <guest>`, so the guest
# is timeout's descendant and nothing else is.
#
# A blocklist was measured getting this wrong: when the serial path grew a
# `tee`, the pipeline's tee became the last descendant, `sample` profiled
# TEE for two seconds, and the bundle recorded that as the guest's stack —
# a section that read "ok 8481" and was evidence about the wrong process.
# The wrong-process shot is what exposed it; the stack alone looked fine.
flightrec_guest_pid() {
    local root="$1" pid kid comm best=""
    for pid in $(flightrec_descendants "$root"); do
        comm="$(ps -o comm= -p "$pid" 2>/dev/null | xargs basename 2>/dev/null)"
        [ "$comm" = timeout ] || continue
        for kid in $(flightrec_descendants "$pid"); do
            comm="$(ps -o comm= -p "$kid" 2>/dev/null | xargs basename 2>/dev/null)"
            case "$comm" in
                env | sh | bash | "") ;;
                *) best="$kid" ;;
            esac
        done
    done
    echo "$best"
}

# flightrec_mac_sampler <scratch> <leg-pid> — runs in the background for
# the life of the leg. Cheap lines every 2s; ONE expensive `sample` taken
# while the process is still alive, just before the runner's kill.
flightrec_mac_sampler() {
    local scratch="$1" legpid="$2"
    local at=0 sampled=0 gpid="" gcomm="" ws=""
    local hang_at="${KAYA_FLIGHTREC_SAMPLE_AT:-100}"
    mkdir -p "$scratch" 2>/dev/null || return 0
    while [ "$at" -lt 130 ]; do
        kill -0 "$legpid" 2>/dev/null || break
        # RESOLVED ONCE. The walk is a recursive pgrep plus a `ps` per
        # descendant, and it ran every two seconds for every one of the
        # pool's concurrent legs; a pid that is still alive is still the
        # answer, so this only walks again once the guest is gone.
        if [ -z "$gpid" ] || ! kill -0 "$gpid" 2>/dev/null; then
            gpid="$(flightrec_guest_pid "$legpid")"
            gcomm=""
        fi
        ws="$(ps -Ao pcpu=,comm= 2>/dev/null | grep WindowServer | head -1 | tr -s ' ')"
        # The pid's OWN NAME rides every line. A pid is not self-evidently
        # the guest, and the one time it was not, the bundle said nothing
        # about it (see flightrec_guest_pid).
        if [ -n "$gpid" ] && [ -z "$gcomm" ]; then
            gcomm="$(ps -o comm= -p "$gpid" 2>/dev/null | xargs basename 2>/dev/null)"
        fi
        printf 't=%ss guest_pid=%s guest=%s windowserver=[%s]\n' \
            "$at" "${gpid:-none}" "${gcomm:-none}" "${ws# }" >>"$scratch/sampler.txt"
        if [ -n "$gpid" ] && [ "$at" -ge "$hang_at" ] && [ "$sampled" = 0 ]; then
            sampled=1
            # THE SHOT COMES FIRST, and the order is measured. It is
            # instantaneous where `sample` BLOCKS for its two seconds, and
            # the window is the thing that vanishes: with sample first, a
            # leg that ended during those two seconds got a stack and no
            # picture. The shot has the same lifetime problem as the stack
            # — an assertion failure exits at once, so by the time the
            # runner knows the verdict there is nothing left to photograph
            # — and a WEDGED leg, the one actually worth a picture, is
            # exactly the one still on screen now.
            flightrec_mac_shot_pid "$gpid" "$scratch/shot-live.png" "$at"
            {
                echo "== sample $gpid 2, taken at t=${at}s while the guest was STILL ALIVE"
                echo "== (the runner's timeout kill lands at 120s and would take it with it)"
                sample "$gpid" 2 2>&1
            } >>"$scratch/sample.txt"
        fi
        sleep 2
        at=$((at + 2))
    done
    printf 'sampler: stopped at t=%ss (sample taken: %s)\n' "$at" "$sampled" >>"$scratch/sampler.txt"
    return 0
}

# flightrec_mac_capture <bundle> <leg> <log> <scratch> — the at-fail
# collection. Called with the verdict already FAIL.
flightrec_mac_capture() {
    local bundle="$1" leg="$2" log="$3" scratch="$4"
    [ -n "$bundle" ] && [ -d "$bundle" ] || return 0

    # The poller's history, and the stack it caught while the guest lived.
    flightrec_adopt "$bundle" "sampler" "$scratch/sampler.txt"
    flightrec_adopt "$bundle" "sample" "$scratch/sample.txt"

    # The leg's own log, which the mac lane otherwise only ever prints.
    # KAYA_JOBS=1 streams to the terminal and has no file — an honest skip
    # naming the reason, never a silently absent section.
    if [ -n "$log" ] && [ -f "$log" ]; then
        flightrec_adopt "$bundle" "leg-log" "$log"
    else
        printf 'flightrec: this leg streamed to the terminal (KAYA_JOBS=1), so there is no log file to keep\n' \
            >"$bundle/leg-log.skip"
        flightrec_mark "$bundle" "leg-log" skip 0
    fi

    # WindowServer at the moment of failure: the mac's shared graphics
    # server, and a saturated one is what a whole matrix's slow legs have
    # in common.
    flightrec_section "$bundle" "windowserver" ps \
        sh -c 'ps -Ao pid=,pcpu=,pmem=,comm= | grep -E "WindowServer|loginwindow" || true'

    # The window list, and then ONE window by id. Never a full-screen
    # grab: docs/traps.md — that photographs whatever the human had
    # frontmost, which is a privacy leak on a shared machine.
    local winlist
    winlist="$(flightrec_mac_winlist_bin || true)"
    if [ -n "$winlist" ]; then
        flightrec_section "$bundle" "windows" "" "$winlist"
        flightrec_mac_shot "$bundle" "$winlist" "$scratch"
    else
        printf 'flightrec: no swiftc, or tools/mac/flightrec-winlist.swift would not build — no window list and therefore no window shot\n' \
            >"$bundle/windows.skip"
        flightrec_mark "$bundle" "windows" skip 0
        flightrec_mark "$bundle" "shot" skip 0
    fi

    # The unified log, scoped to kaya and BOUNDED. Retrospective, so this
    # one still answers after the guest is gone.
    flightrec_section "$bundle" "unified-log" log \
        log show --last 2m --style compact \
        --predicate 'process CONTAINS "kaya" OR senderImagePath CONTAINS "kaya" OR eventMessage CONTAINS "kaya"'

    flightrec_bundle_report "$bundle"
    return 0
}

# flightrec_mac_sampler_start <scratch> <root-pid> — prints the sampler's
# pid. EVERY CALLER MUST STOP IT: a poller left running outlives the lane
# and quietly loads the machine the next lane is timed on.
flightrec_mac_sampler_start() {
    [ "${FLIGHTREC_OK:-0}" = 1 ] || return 0
    local scratch="$1" root="$2"
    mkdir -p "$scratch" 2>/dev/null || return 0
    flightrec_mac_sampler "$scratch" "$root" >/dev/null 2>&1 &
    echo $!
}

flightrec_mac_sampler_stop() {
    local pid="${1:-}"
    [ -n "$pid" ] || return 0
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 0
}

# flightrec_mac_leg <leg> <verdict> <secs> <log-or-empty> <scratch>
# The one entry point both of validate-mac's leg paths call, so the
# serial and pooled paths cannot record different things.
flightrec_mac_leg() {
    [ "${FLIGHTREC_OK:-0}" = 1 ] || return 0
    local leg="$1" verdict="$2" secs="$3" log="$4" scratch="$5"
    local bundle="" fail=""
    if [ "$verdict" != PASS ]; then
        bundle="$(flightrec_bundle mac "$leg")"
        fail="$(flightrec_fail_sentence "$log")"
        [ -n "$bundle" ] && flightrec_mac_capture "$bundle" "$leg" "$log" "$scratch"
    fi
    flightrec_leg mac "$leg" "$verdict" "$secs" "$fail" "$bundle"
    rm -rf "$scratch" 2>/dev/null || true
    return 0
}

# The shot: ONE window, the GUEST'S OWN, addressed by pid.
#
# NEVER BY TITLE, and never full-screen. A title match on "kaya"
# photographed the maintainer's editor — its window is titled after the
# repository — which is the privacy leak docs/traps.md warns about arriving
# by a different door. The sampler resolved the guest's pid while it was
# alive, so the pid is what the window list is filtered by; no pid means no
# shot and a sentence saying why.
# flightrec_mac_shot_pid <pid> <dest.png> <at-seconds> — one window, the
# one that pid owns, by id. Shared by the sampler's live shot and the
# fail-time attempt so there is one rule about what may be photographed.
flightrec_mac_shot_pid() {
    local pid="$1" dest="$2" at="${3:-}" winlist="" id=""
    command -v screencapture >/dev/null 2>&1 || return 1
    winlist="$(flightrec_mac_winlist_bin)" || return 1
    id="$("$winlist" "$pid" 2>/dev/null | grep 'layer=0 ' | head -1 \
        | tr ' ' '\n' | grep '^win=' | cut -d= -f2)"
    [ -n "$id" ] && [ "$id" != "-1" ] || return 1
    screencapture -x -o "-l$id" "$dest" >/dev/null 2>&1 || true
    [ -s "$dest" ] || return 1
    [ -z "$at" ] || printf 'taken at t=%ss, window %s of pid %s\n' "$at" "$id" "$pid" >"$dest.when"
    return 0
}

flightrec_mac_shot() {
    local bundle="$1" winlist="$2" scratch="${3:-}" id="" pid=""
    if [ -n "$scratch" ] && [ -f "$scratch/sampler.txt" ]; then
        pid="$(grep -o 'guest_pid=[0-9][0-9]*' "$scratch/sampler.txt" 2>/dev/null \
            | tail -1 | cut -d= -f2)"
    fi
    # The guest is usually GONE by now — an assertion failure exits at
    # once — so the fail-time attempt is tried first and the sampler's
    # live shot is what answers when it finds nothing.
    if [ -n "$pid" ] && flightrec_mac_shot_pid "$pid" "$bundle/shot.png"; then
        local bytes
        bytes="$(wc -c <"$bundle/shot.png" | tr -d ' ')"
        flightrec_mark "$bundle" "shot" ok "$bytes"
        return 0
    fi
    rm -f "$bundle/shot.png"
    if [ -n "$scratch" ] && [ -s "$scratch/shot-live.png" ]; then
        cp "$scratch/shot-live.png" "$bundle/shot.png" 2>/dev/null || true
        cp "$scratch/shot-live.png.when" "$bundle/shot.when" 2>/dev/null || true
        local bytes
        bytes="$(wc -c <"$bundle/shot.png" 2>/dev/null | tr -d ' ')"
        [ -n "$bytes" ] || bytes=0
        flightrec_mark "$bundle" "shot" ok "$bytes"
        return 0
    fi
    if [ -z "$pid" ]; then
        printf 'flightrec: the sampler never resolved a guest pid for this leg, so no window is attributed to the guest and none was photographed. The window list beside this file is the whole desktop.\n' \
            >"$bundle/shot.skip"
    else
        printf 'flightrec: guest pid %s owned no on-screen window at failure and the sampler took none while it lived — the leg failed faster than the sampler'"'"'s first shot. The window list beside this file is what was there.\n' \
            "$pid" >"$bundle/shot.skip"
    fi
    flightrec_mark "$bundle" "shot" skip 0
    return 0
}
