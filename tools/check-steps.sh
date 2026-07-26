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
# Lint the shared .steps scripts: container-kind targets index widgets
# by CREATION order, which legitimately differs per language
# (statement-shaped construction is parent-first, expression trees are
# children-first — argument evaluation forces it). Leaf kinds are safe
# (body order is screen order everywhere); containers are targetable
# only through the blessed pattern — column#0, the For container that
# the root-is-a-row convention keeps unique. Anything else would name
# different widgets on different platforms, so it dies here, not in
# one platform's leg.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

lint() {
    # $1: a steps file (or - for stdin). Prints offenders, returns 1 on any.
    python3 -c '
import re
import sys

path = sys.argv[1]
text = sys.stdin.read() if path == "-" else open(path).read()
bad = []
for lineno, line in enumerate(text.splitlines(), 1):
    if line.lstrip().startswith("#"):
        continue
    for kind, index in re.findall(r"\b(row|column|scroll|grid)#(\d+)\b", line):
        # Index 0 of a container kind is the blessed pattern, on one
        # convention: the scene keeps exactly one widget of that
        # kind, so creation order cannot enter. column#0 is the For
        # container in milestone2 (root-is-a-row keeps it unique);
        # row#0 carries the horizontal grow contract in the grow
        # scene; scroll#0 the one scroll viewport in the scroll scene.
        if index == "0":
            continue
        bad.append(f"{path}:{lineno}: {kind}#{index}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
' "$1"
}

# The guard guards itself: a known-bad sample must fail, or the lint
# is a false green.
if printf 'click row#1\nexpect column#2 "x"\n' | lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (bad sample passed)" >&2
    exit 1
fi

status=0
for f in tools/scenes/*.steps; do
    out="$(lint "$f")" || {
        echo "check-steps: $f targets a container by creation index — only column#0/row#0 (unique-by-convention containers) are cross-language stable:" >&2
        echo "$out" >&2
        status=1
    }
done

# The opening lint: a script must OPEN with an observation. Expects
# are bounded retries (harness.rs POLL_DEADLINE), and the FIRST one
# doubles as the scene-ready wait — a script that opens with an
# action races the mount on every platform at once (scripted settles
# are gone; retries replaced them, 2026-07-22).
opening_lint() {
    python3 -c '
import sys

path = sys.argv[1]
text = sys.stdin.read() if path == "-" else open(path).read()
for line in text.splitlines():
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        continue
    first = stripped.split(";")[0].split()
    verb = first[0] if first else ""
    if verb.startswith("expect"):
        sys.exit(0)
    print(f"{path}: opens with {verb!r} — the first step must be an "
          "expect (its bounded retry is the scene-ready wait)")
    sys.exit(1)
sys.exit(0)
' "$1"
}

# The guard guards itself.
if printf 'click button#0\nexpect label#0 "x"\n' | opening_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (action-first script passed)" >&2
    exit 1
fi

for f in tools/scenes/*.steps; do
    out="$(opening_lint "$f")" || {
        echo "check-steps: $f must open with an expect (the retry is the scene-ready wait):" >&2
        echo "$out" >&2
        status=1
    }
done

# Raw CR bytes: the scripts are LF files by contract. The Swift
# interpreter splits script text on "\n", and Swift's grapheme-based
# split sees CRLF as ONE cluster — a CRLF-ended script would parse as
# a single giant line there while parsing fine everywhere else
# (docs/traps.md, the grapheme family). CR as DATA rides the \r
# escape, never a raw byte.
cr_lint() {
    python3 -c '
import sys

path = sys.argv[1]
data = sys.stdin.buffer.read() if path == "-" else open(path, "rb").read()
if b"\r" in data:
    print(f"{path}: raw CR byte — steps files are LF-only "
          "(use the \\r escape for CR as data)")
    sys.exit(1)
' "$1"
}

# The guard guards itself.
if printf 'expect label#0 "x"\r\n' | cr_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (CRLF sample passed)" >&2
    exit 1
fi

for f in tools/scenes/*.steps; do
    out="$(cr_lint "$f")" || {
        echo "check-steps: $f contains a raw CR byte:" >&2
        echo "$out" >&2
        status=1
    }
done

# Entries are single-line controls: what a platform does with an
# embedded line break in one is platform-defined input behavior
# (WinUI strips, GTK filters, others vary), so a scene asserting it
# would pin one platform's behavior against the rest. The multi-line
# round trip belongs to the textarea. set_text into an entry must not
# carry \n or \r.
entry_newline_lint() {
    python3 -c '
import re
import sys

path = sys.argv[1]
text = sys.stdin.read() if path == "-" else open(path).read()
bad = []
for lineno, line in enumerate(text.splitlines(), 1):
    if line.lstrip().startswith("#"):
        continue
    for step in line.split(";"):
        s = step.strip()
        if re.match(r"set_text\s+entry#", s) and re.search(r"\\[nr]", s):
            bad.append(f"{path}:{lineno}: {s}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
' "$1"
}

# The guard guards itself.
if printf 'set_text entry#0 "a\\nb"\n' | entry_newline_lint - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (entry-newline sample passed)" >&2
    exit 1
fi

for f in tools/scenes/*.steps; do
    out="$(entry_newline_lint "$f")" || {
        echo "check-steps: $f drives a line break into a single-line entry (platform-defined; textarea owns the multi-line contract):" >&2
        echo "$out" >&2
        status=1
    }
done

# Every scene script must be reachable by name from harness::script.
# That match ends in a catch-all returning the milestone2 script, so an
# unregistered scene does not fail — it silently runs a DIFFERENT
# script, and a leg that passes then proves nothing about the scene it
# claims to be. Registration is easy to forget precisely because

# (The former `registered` check lived here: it asserted every scene had
# an arm in harness::script's include_str! match. That match is gone —
# the Rust backends now resolve a scene NAME to
# <KAYA_SCENES_DIR>/<name>.steps, and a missing scene makes spawn fail
# loudly instead of falling through to a catch-all that silently ran
# the milestone2 script. The gate policed a registry that no longer
# exists; the failure it guarded is now structural.)

# Every scene must be WIRED into every platform runner, not merely
# registered: a scene can exist, parse, and be registered, yet run
# nowhere on a platform — the layout scene shipped exactly that way
# (functionally green on mac, absent from every suite), and the iOS
# SwiftUI suite later missed the grow/layout legs the same silent way.
# The grep demands each runner's LEG SIGNATURE, not the bare name: a
# scene listed in SCENES whose leg block is dead (cloned below the
# script's exit, commented out, mangled) satisfies a name check while
# running nowhere — the sections regex-clone near-miss, 2026-07-22.
# (iOS and Android stay name-level: their legs derive mechanically
# from the scene list, so the name IS the wiring — except the scenes
# each platform deliberately skips, carved out below.)
wired() {
    local runner scene sig status=0
    for scene in tools/scenes/*.steps; do
        scene="$(basename "${scene%.steps}")"
        for runner in tools/validate-mac.sh tools/linux/run-suites.sh \
            tools/deploy-win.sh tools/ios/run-sim.sh tools/android/run-emulator.sh; do
            case "$runner" in
                tools/validate-mac.sh) sig="run $scene-" ;;
                tools/linux/run-suites.sh) sig="run \"\$proto\" $scene-" ;;
                tools/deploy-win.sh) sig="run_suite ${scene}_" ;;
                *) sig="$scene" ;;
            esac
            # milestone2's legs drop the scene prefix (they ARE the
            # unprefixed originals); its name check stays coarse.
            [ "$scene" = milestone2 ] && sig="$scene"
            if ! grep -qF "$sig" "$runner"; then
                echo "check-steps: scene \"$scene\" has no live legs in $runner (wanted \"$sig\")" >&2
                status=1
            fi
        done
    done
    return "$status"
}
wired || status=1

# EVERY WINDOWS LEG NEEDS ITS LAUNCHER. deploy-win runs a leg by
# scheduling C:\kaya\run_<scene>_<lang>.cmd on the VM, and those .cmd
# files are CHECKED IN under tools/guest. A leg whose launcher does not
# exist does not fail — schtasks starts nothing, no output ever appears,
# and the runner waits out its full 300s timeout before calling it a
# hang. Measured 2026-07-25: a scene joined SCENES with four of its five
# launchers missing and cost four silent 300s timeouts, diagnosed as
# load because the lane's duration anomaly fired first.
launchers() {
    local status=0 leg scene lang
    for leg in $(grep -oE '^[[:space:]]*run_suite [a-z0-9_]+' tools/deploy-win.sh \
        | awk '{print $2}' | sort -u); do
        case "$leg" in
            # The milestone2 legs are the unprefixed originals
            # (run_rust.cmd, run_python.cmd, ...).
            rust | python | go | csharp | java) continue ;;
        esac
        scene="${leg%_*}"
        lang="${leg##*_}"
        if [ ! -f "tools/guest/run_${scene}_${lang}.cmd" ]; then
            echo "check-steps: deploy-win runs leg \"$leg\" but" \
                "tools/guest/run_${scene}_${lang}.cmd does not exist —" \
                "that leg would wait out its whole timeout in silence" >&2
            status=1
        fi
    done
    return "$status"
}
launchers || status=1

# The staged WinUI menus ruling (docs/traps.md): shortcut injection is
# OS-global — the harness foregrounds the guest and puts the real
# chord on the system input queue — so deploy-win must run every menu
# leg ALONE, between drains. Pinned structurally: each `run_suite
# menus_*` call in deploy-win.sh must have `drain_suites` as its
# nearest significant neighbor on BOTH sides, so a parallelizing
# refactor (or a sweep adding menus_python beside it) cannot silently
# re-pool the injection legs.
menu_serial() {
    python3 -c '
import re
import sys

path = sys.argv[1]
lines = [l.strip() for l in (sys.stdin.read() if path == "-" else open(path).read()).splitlines()]

def significant(seq):
    return [l for l in seq if l and not l.startswith("#")]

bad = []
seen = 0
for n, line in enumerate(lines):
    if not re.match(r"run_suite\s+menus_", line):
        continue
    seen += 1
    before = significant(lines[:n])
    after = significant(lines[n + 1:])
    if not before or before[-1] != "drain_suites" or not after or after[0] != "drain_suites":
        bad.append(f"{path}:{n + 1}: {line} lacks the drain/run/drain barrier")
if seen == 0:
    bad.append(f"{path}: no run_suite menus_* leg found (the menus scene must stay wired)")
print("\n".join(bad))
sys.exit(1 if bad else 0)
' "$1"
}

# The guard guards itself: a pooled menu leg must fail.
if printf 'run_suite layout_java\nrun_suite menus_rust\ndrain_suites\n' | menu_serial - >/dev/null; then
    echo "check-steps: SELF-TEST FAIL (pooled menus leg passed)" >&2
    exit 1
fi

out="$(menu_serial tools/deploy-win.sh)" || {
    echo "check-steps: deploy-win.sh menu legs must run serially between drain_suites calls (docs/traps.md, OS-global shortcut injection):" >&2
    echo "$out" >&2
    status=1
}

[ "$status" = 0 ] && echo "check-steps: OK"
exit "$status"
