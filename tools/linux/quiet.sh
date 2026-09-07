# shellcheck shell=bash
# The linux lane's half of the matrix-wide quiet token (tools/lib/quiet.py
# is the spelling of record; tools/check-quiet.py holds the two equal):
# one mkdir lock in the state home the container already mounts, a
# `holder` file inside it, a bounded wait, a stale break. Sourced by
# tools/linux/run-suites.sh beside flightrec.sh. NEVER nonzero: a lane
# must not lose a leg to its scheduler.

KAYA_QUIET_WAIT_S=360
KAYA_QUIET_STALE_S=300
KAYA_QUIET_HELD_N=0
KAYA_QUIET_HELD_S=0
KAYA_QUIET_WAITED_N=0
KAYA_QUIET_WAITED_S=0

kaya_quiet_dir() {
    echo "${KAYA_QUIET_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/kaya/quiet}"
}

kaya_quiet_holder() { # lock
    cat "$1/holder" 2>/dev/null || echo "<holder unknown>"
}

kaya_quiet_age() { # lock -> seconds
    local now taken_at
    now=$(date +%s)
    taken_at=$(stat -c %Y "$1" 2>/dev/null || echo "$now")
    echo $((now - taken_at))
}

kaya_quiet_break_if_stale() { # lane lock -> 0 when broken
    local age holder
    age=$(kaya_quiet_age "$2")
    [ "$age" -gt "$KAYA_QUIET_STALE_S" ] || return 1
    holder=$(kaya_quiet_holder "$2")
    rm -f "$2/holder" 2>/dev/null
    rmdir "$2" 2>/dev/null || return 1
    echo "quiet: $1 broke a lock ${age}s old held by $holder — a quiet leg's own ceiling is far shorter, so its lane is gone" >&2
    return 0
}

kaya_quiet_wait() { # lane leg
    local lane="$1" leg="$2" dir lock t0 holder told=0 waited
    dir=$(kaya_quiet_dir)
    lock="$dir/lock"
    t0=$SECONDS
    while [ -d "$lock" ]; do
        holder=$(kaya_quiet_holder "$lock")
        case "$holder" in "lane=$lane "*) break ;; esac
        if kaya_quiet_break_if_stale "$lane" "$lock"; then continue; fi
        if [ "$told" = 0 ]; then
            echo "quiet: $lane waits to admit $leg — $holder holds" >&2
            told=1
        fi
        if [ $((SECONDS - t0)) -gt "$KAYA_QUIET_WAIT_S" ]; then
            echo "quiet: $lane waited ${KAYA_QUIET_WAIT_S}s to admit $leg; $holder still holds — proceeding without quiet" >&2
            break
        fi
        sleep 0.25
    done
    waited=$((SECONDS - t0))
    if [ "$told" = 1 ]; then
        KAYA_QUIET_WAITED_N=$((KAYA_QUIET_WAITED_N + 1))
        KAYA_QUIET_WAITED_S=$((KAYA_QUIET_WAITED_S + waited))
        echo "quiet: $lane waited ${waited}.0s to admit $leg" >&2
    fi
    return 0
}

kaya_quiet_take() { # lane leg lock -> 0 when taken and confirmed
    local stamp
    mkdir "$3" 2>/dev/null || return 1
    stamp="lane=$1 leg=$2 pid=$$ scope=container host=$(hostname) start=$(date +%s)"
    echo "$stamp" >"$3/holder"
    [ "$(kaya_quiet_holder "$3")" = "$stamp" ]
}

kaya_quiet_hold_begin() { # lane leg
    local lane="$1" leg="$2" dir lock t0 holder told=0
    dir=$(kaya_quiet_dir)
    lock="$dir/lock"
    mkdir -p "$dir" 2>/dev/null || {
        echo "quiet: $lane cannot use $dir (mkdir failed) — running without quiet" >&2
        KAYA_QUIET_TAKEN=0
        return 0
    }
    t0=$SECONDS
    KAYA_QUIET_TAKEN=0
    while :; do
        if kaya_quiet_take "$lane" "$leg" "$lock"; then KAYA_QUIET_TAKEN=1; break; fi
        holder=$(kaya_quiet_holder "$lock")
        case "$holder" in "lane=$lane "*) rm -f "$lock/holder"; rmdir "$lock" 2>/dev/null; continue ;; esac
        if kaya_quiet_break_if_stale "$lane" "$lock"; then continue; fi
        if [ "$told" = 0 ]; then
            echo "quiet: $lane waits to hold for $leg — $holder holds" >&2
            told=1
        fi
        if [ $((SECONDS - t0)) -gt "$KAYA_QUIET_WAIT_S" ]; then
            echo "quiet: $lane waited ${KAYA_QUIET_WAIT_S}s to hold for $leg; $holder still holds — running it beside them" >&2
            break
        fi
        sleep 0.25
    done
    if [ "$KAYA_QUIET_TAKEN" = 1 ]; then
        if [ "$told" = 1 ]; then
            echo "quiet: $lane holds for $leg after $((SECONDS - t0)).0s" >&2
        else
            echo "quiet: $lane holds for $leg" >&2
        fi
    fi
    KAYA_QUIET_HELD_T0=$SECONDS
    return 0
}

kaya_quiet_hold_end() { # lane leg
    local lane="$1" leg="$2" dir lock held
    dir=$(kaya_quiet_dir)
    lock="$dir/lock"
    held=$((SECONDS - KAYA_QUIET_HELD_T0))
    if [ "${KAYA_QUIET_TAKEN:-0}" = 1 ]; then
        KAYA_QUIET_HELD_N=$((KAYA_QUIET_HELD_N + 1))
        KAYA_QUIET_HELD_S=$((KAYA_QUIET_HELD_S + held))
        rm -f "$lock/holder" 2>/dev/null
        rmdir "$lock" 2>/dev/null || echo "quiet: $lane cannot use $dir (the lock would not release) — running without quiet" >&2
        echo "quiet: $lane released after $leg (${held}.0s held)" >&2
    fi
    return 0
}

kaya_quiet_summary() { # lane
    echo "quiet: $1 held $KAYA_QUIET_HELD_N legs for ${KAYA_QUIET_HELD_S}s; waited $KAYA_QUIET_WAITED_N times for ${KAYA_QUIET_WAITED_S}s" >&2
    return 0
}

# THE ONE INHERITED PREMISE, watched where it is used: mkdir over the
# container's bind mount is atomic. Two background mkdirs of one path in
# the real quiet directory; exactly one may win. Printed every run.
kaya_quiet_selftest() { # lane
    local dir probe a b wins
    dir=$(kaya_quiet_dir)
    mkdir -p "$dir" 2>/dev/null || { echo "quiet: $1 self-test skipped — $dir is not writable" >&2; return 0; }
    probe="$dir/selftest-$$"
    rm -rf "$probe"
    local pa pb
    (mkdir "$probe" 2>/dev/null && echo won || echo lost) >"$probe.a" &
    pa=$!
    (mkdir "$probe" 2>/dev/null && echo won || echo lost) >"$probe.b" &
    pb=$!
    # The two racers alone: a bare wait would also wait on the lane's
    # compositor, which runs forever (run-suites.sh's drain).
    wait "$pa" "$pb"
    a=$(cat "$probe.a"); b=$(cat "$probe.b")
    rm -rf "$probe" "$probe.a" "$probe.b"
    wins=0
    [ "$a" = won ] && wins=$((wins + 1))
    [ "$b" = won ] && wins=$((wins + 1))
    if [ "$wins" = 1 ]; then
        echo "quiet: $1 self-test — two mkdirs raced over $dir, exactly one won" >&2
    else
        echo "quiet: $1 SELF-TEST FAILED — two mkdirs raced over $dir and $wins won; the lock is not atomic here, and quiet cannot be trusted on this lane" >&2
    fi
    return 0
}
