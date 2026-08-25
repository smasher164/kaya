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
# THE HARNESS LOSES LEGIBLY. Every step is entered with a CEILING, and
# once a verdict is published the process leaves within the EXIT GRACE
# whether or not the platform's exit path ever runs.
#
# The bug this replaces: a step's retry deadline is read only AFTER the
# step returns, and every step blocks in a hop to the platform's UI
# thread with no timeout of its own. A saturated app therefore printed
# NOTHING — no verdict, no timeout sentence — until something outside
# killed it. Measured on macOS, Linux, Windows and iOS 2026-08-24
# (docs/measurements/choke-*-2026-08-24.txt); on the mac lane the
# something is `timeout 120`, a KILL that takes the log with it.
#
# NO SCENE CAN FAIL THIS. A scene that wedges the UI thread would have
# to wedge it on every platform at once and would then measure nothing
# else, so — like the native-undo pair — a gate is the only wall
# available.
#
# THE CLAUSES:
#
#   A  STATIC, all three harnesses: the same two numbers, an arm inside
#      the script runner whose argument is the step (not a fixed
#      string), a publish over the exit, an exit primitive on the fire
#      path, and ONE sentence — compared flattened, so Rust's line
#      continuations and Swift's and Kotlin's `+` splices are the same
#      text or the gate says which file drifted.
#   B  RUNTIME, macOS only: the interpreter's OWN watchdog source, cut
#      out of swift/KayaSwiftUI.swift here and compiled with
#      tools/checks/swiftui-wedge.swift, against a REAL wedged main
#      thread. Clause A is what says the watchdog is wired into the step
#      loop; this is what says it fires.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

HARNESS=crates/kaya/src/harness.rs
SWIFTUI=swift/KayaSwiftUI.swift
COMPOSE=android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt
PROBE=tools/checks/swiftui-wedge.swift

# --- Clause A ---------------------------------------------------------
check() {
    # <harness.rs> <KayaSwiftUI.swift> <KayaCompose.kt>; offenders on
    # stdout, 1 on any. Any path may be a perturbed copy — that is how
    # the self-tests below drive it.
    python3 - "$@" <<'PY'
import re
import sys

paths = dict(zip(("harness.rs", "KayaSwiftUI.swift", "KayaCompose.kt"), sys.argv[1:4]))
bad = []
texts = {}
for label, path in paths.items():
    try:
        texts[label] = open(path, encoding="utf-8").read()
    except OSError as exc:
        bad.append(f"cannot read {path} for {label} ({exc.strerror}): the harness this "
                   f"rule pins is not there")


def flat(text):
    """One sentence written three ways. Rust breaks a string with `\\`
    + newline, Swift and Kotlin splice with `+`; flattening those and
    the whitespace leaves the text itself, which is the thing that has
    to agree."""
    text = re.sub(r"\\\n\s*", "", text)
    text = re.sub(r'"\s*\+\s*"', "", text)
    text = re.sub(r"\s+", " ", text)
    return text


# (label, ceiling regex, grace regex, seconds scale)
NUMBERS = {
    "harness.rs": (
        r"STEP_CEILING: Duration = Duration::from_secs\((\d+)\)",
        r"EXIT_GRACE: Duration = Duration::from_secs\((\d+)\)",
        1,
    ),
    "KayaSwiftUI.swift": (
        r"kayaStepCeiling: TimeInterval = (\d+)(?:\.0)?\b",
        r"kayaExitGrace: TimeInterval = (\d+)(?:\.0)?\b",
        1,
    ),
    "KayaCompose.kt": (
        r"STEP_CEILING_MS = ([\d_]+)L",
        r"EXIT_GRACE_MS = ([\d_]+)L",
        1000,
    ),
}
# Where the arm has to BE: a step that is not covered is the whole bug.
RUNNERS = {
    "harness.rs": (r"fn run_with_log\(", r"\n\}"),
    "KayaSwiftUI.swift": (r"private func kayaRunScript\(", r"\n\}"),
    "KayaCompose.kt": (r"private fun runScript\(", r"\n    \}"),
}
# The arm, the publish, and what the fire path leaves with.
SHAPES = {
    "harness.rs": (r"watch\.enter\(([^)]*)\)", r"watch\.published\(", r"std::process::exit\("),
    "KayaSwiftUI.swift": (r"watchdog\.enter\(([^)]*)\)", r"watchdog\.published\(", r"_exit\("),
    "KayaCompose.kt": (r"watchdog\.enter\(([^)]*)\)", r"watchdog\.published\(", r"\.halt\("),
}

seconds = {}
for label, text in texts.items():
    ceiling_pat, grace_pat, scale = NUMBERS[label]
    for what, pat in (("step ceiling", ceiling_pat), ("exit grace", grace_pat)):
        m = re.search(pat, text)
        if not m:
            bad.append(f"{paths[label]} declares no {what} — expected /{pat}/. The harness "
                       f"that has none is the one that goes silent.")
            continue
        seconds.setdefault(what, {})[label] = int(m.group(1).replace("_", "")) / scale

    start = re.search(RUNNERS[label][0], text)
    if not start:
        bad.append(f"{paths[label]}: the script runner /{RUNNERS[label][0]}/ is gone — "
                   f"re-point this gate at whatever replaced it")
        continue
    end = re.search(RUNNERS[label][1], text[start.end():])
    body = text[start.end(): start.end() + (end.start() if end else len(text))]
    arm_pat, publish_pat, leave_pat = SHAPES[label]
    arms = re.findall(arm_pat, body)
    # A LITERAL argument names every step the same, which is the
    # step-failed rule one file over (tools/check-verbs.sh): the
    # sentence has to say which step it was inside. The interpreters
    # also arm their verdict's OWN reads, with an <angle-bracketed>
    # literal, so the rule is that at least one arm carries the step.
    if not any(not a.strip().startswith('"') for a in arms):
        bad.append(f"{paths[label]}'s script runner never arms the step ceiling with the "
                   f"step itself (found {len(arms)} arm(s) matching /{arm_pat}/) — a step "
                   f"nothing armed is a step that can hang with no verdict, and a fixed "
                   f"string names every step the same")
    if not re.search(publish_pat, body):
        bad.append(f"{paths[label]}'s script runner never publishes the verdict to the "
                   f"watchdog (/{publish_pat}/) — `finish` hops to the same UI thread for "
                   f"the exit, and the linux lane measured that hop never running")
    if not re.search(leave_pat, text):
        bad.append(f"{paths[label]} has no {leave_pat} on the watchdog's fire path — a "
                   f"watchdog that reports and stays is the same silence one line later")

for what, found in seconds.items():
    if len(found) == len(texts) and len(set(found.values())) != 1:
        bad.append(f"the {what} disagrees across the three harnesses: "
                   + ", ".join(f"{k} {v}s" for k, v in sorted(found.items()))
                   + " — one rule, and a platform with a longer one is a platform whose "
                     "runner kills it first")

# ONE SENTENCE, THREE HARNESSES. Everything after the elapsed number is
# free of interpolation, so it compares byte for byte once flattened.
OPENING = "KAYA_SELFTEST: FAILED (no verdict — the harness entered step"
TAIL = (
    "s ago and has not come back from it. A step blocks in its hop to the platform's UI "
    "thread, so nothing answered from there; a wedged UI thread and a merely slow one look "
    "the same from here and this does not claim to tell them apart. Ended by the harness "
    "step ceiling, which is the cover a step's own retry deadline cannot give: that one is "
    "read only after a step returns.)"
)
GRACE_NOTE = (
    "s later — leaving under the verdict's own code (the harness exit grace)"
)
for label, text in texts.items():
    flattened = flat(text)
    for what, want in (("verdict's opening", OPENING), ("verdict's sentence", TAIL),
                       ("exit-grace note", GRACE_NOTE)):
        if want not in flattened:
            bad.append(f"{paths[label]} does not carry the {what} the other harnesses "
                       f"carry — one wedge reads one way everywhere. Wanted: {want!r}")

print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
}

status=0
if ! out="$(check "$HARNESS" "$SWIFTUI" "$COMPOSE")"; then
    echo "check-harness-ceiling: the step ceiling is not in force in all three harnesses:" >&2
    echo "$out" >&2
    status=1
fi

# --- The self-tests: perturb the REAL files, count the substitutions,
# --- demand a refusal that names the perturbation. -------------------
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

perturb() {
    # <src> <python-regex> <replacement> <dest>; prints the count.
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import re
import sys
src, pat, repl, dest = sys.argv[1:5]
text = open(src, encoding="utf-8").read()
out, n = re.subn(pat, repl.replace("\\", "\\\\"), text, count=1)
open(dest, "w", encoding="utf-8").write(out)
print(n)
PY
}

applied() {
    # <count> <what>: PRINTED, because "the negative passed" and "it
    # never touched the file" look identical otherwise.
    echo "check-harness-ceiling: self-test — $2 applied (${1:-0} substitution)"
    if [ "${1:-0}" -lt 1 ]; then
        echo "check-harness-ceiling: SELF-TEST BROKEN — $2 changed nothing, so the red" \
            "below would have been a green about an unperturbed copy." >&2
        exit 1
    fi
}

refuses() {
    # <harness> <swiftui> <compose> <expected-substring> <what>
    local out
    if out="$(check "$1" "$2" "$3")"; then
        echo "check-harness-ceiling: SELF-TEST FAILED — $5 was ACCEPTED." >&2
        exit 1
    fi
    if ! grep -qF "$4" <<<"$out"; then
        echo "check-harness-ceiling: SELF-TEST FAILED — $5 was refused, but not for the" \
            "stated reason. Wanted a sentence containing:" >&2
        echo "  $4" >&2
        echo "got:" >&2
        echo "$out" >&2
        exit 1
    fi
}

hits="$(perturb "$HARNESS" 'watch\.enter\(format!\("\{step:\?\}"\)\);' \
    'watch.enter("a step".to_string());' "$T/harness-fixed.rs")"
applied "$hits" "the harness.rs fixed-step-text perturbation"
refuses "$T/harness-fixed.rs" "$SWIFTUI" "$COMPOSE" \
    "never arms the step ceiling with the step itself" \
    "a Rust harness whose ceiling cannot name the step it was inside"

hits="$(perturb "$SWIFTUI" 'watchdog\.enter\(line\)\n' '' "$T/swiftui-unarmed.swift")"
applied "$hits" "the KayaSwiftUI.swift unarmed-step perturbation"
refuses "$HARNESS" "$T/swiftui-unarmed.swift" "$COMPOSE" \
    "never arms the step ceiling with the step itself" \
    "a SwiftUI step loop that arms nothing"

hits="$(perturb "$COMPOSE" 'STEP_CEILING_MS = 60_000L' 'STEP_CEILING_MS = 300_000L' \
    "$T/compose-drifted.kt")"
applied "$hits" "the KayaCompose.kt ceiling-drift perturbation"
refuses "$HARNESS" "$SWIFTUI" "$T/compose-drifted.kt" \
    "the step ceiling disagrees across the three harnesses" \
    "an Android ceiling longer than the other two"

hits="$(perturb "$COMPOSE" 'watchdog\.published\(code\)\n' '' "$T/compose-noexit.kt")"
applied "$hits" "the KayaCompose.kt unpublished-exit perturbation"
refuses "$HARNESS" "$SWIFTUI" "$T/compose-noexit.kt" \
    "never publishes the verdict to the watchdog" \
    "an Android verdict whose exit hop nothing covers"

hits="$(perturb "$SWIFTUI" 'and a merely slow one look the same from here' \
    'and a wedged one look the same from here' "$T/swiftui-drifted.swift")"
applied "$hits" "the KayaSwiftUI.swift sentence-drift perturbation"
refuses "$HARNESS" "$T/swiftui-drifted.swift" "$COMPOSE" \
    "does not carry the verdict's sentence the other harnesses carry" \
    "a wedge that reads differently on one platform"

# An ABSENT harness is a failure that NAMES IT, never a skip.
gone="$(check "$HARNESS" "$SWIFTUI" "$T/no-such-harness.kt")"
case "$gone" in
    *"cannot read"*"no-such-harness.kt"*) ;;
    *)
        echo "check-harness-ceiling: SELF-TEST FAILED (an absent harness failed without" \
            "naming it): $gone" >&2
        exit 1
        ;;
esac

# --- Clause B: the runtime negative, where the toolchain exists. -----
if [ "$(uname -s)" = "Darwin" ]; then
    # shellcheck source=tools/lib/swift-toolchain.sh
    source "$ROOT/tools/lib/swift-toolchain.sh"
    # The probe drives the INTERPRETER'S OWN watchdog: it is cut out of
    # the real file here, so there is no second copy to drift.
    cut_watchdog() {
        python3 - "$1" "$2" <<'PY'
import re
import sys
src, dest = sys.argv[1:3]
text = open(src, encoding="utf-8").read()
start = text.index("/// THE CEILING ON ONE STEP")
end = text.index("\n}\n", text.index("final class KayaStepWatchdog"))
open(dest, "w", encoding="utf-8").write("import Foundation\n\n" + text[start:end + 3])
print(len(text[start:end].splitlines()))
PY
    }
    lines="$(cut_watchdog "$SWIFTUI" "$T/KayaStepCeiling.swift")"
    rc=$?
    if [ "$rc" -ne 0 ] || [ "${lines:-0}" -lt 40 ]; then
        echo "check-harness-ceiling: could not cut the watchdog out of $SWIFTUI" \
            "(${lines:-0} lines) — the probe compiles the interpreter's own source, so" \
            "there is nothing to run without it." >&2
        exit 1
    fi
    echo "check-harness-ceiling: clause B — ${lines} lines of $SWIFTUI compiled into the probe"
    if ! kaya_swiftc "$T/KayaStepCeiling.swift" "$PROBE" -o "$T/swiftui-wedge"; then
        echo "check-harness-ceiling: the wedge probe did not compile" >&2
        exit 1
    fi
    "$T/swiftui-wedge"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "check-harness-ceiling: FAIL — the SwiftUI wedge probe exited $rc." >&2
        exit 1
    fi
    # AND WATCHED FAILING, on the same real source: a ceiling that never
    # expires is the pre-fix silence, and the probe has to report it.
    hits="$(perturb "$T/KayaStepCeiling.swift" 'waited >= ceiling' 'waited >= ceiling * 1000' \
        "$T/KayaStepCeilingDead.swift")"
    applied "$hits" "the never-expiring-ceiling perturbation"
    if ! kaya_swiftc "$T/KayaStepCeilingDead.swift" "$PROBE" -o "$T/swiftui-wedge-dead"; then
        echo "check-harness-ceiling: the perturbed wedge probe did not compile" >&2
        exit 1
    fi
    # 5s against the probe's own 1.5s ceiling: a live one has published
    # long before, a dead one has not.
    KAYA_WEDGE_CAP_MS=5000 "$T/swiftui-wedge-dead" >"$T/dead.log" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "check-harness-ceiling: SELF-TEST FAILED — a watchdog whose ceiling can never" \
            "expire still passed the probe, so the probe proves nothing." >&2
        exit 1
    fi
    if ! grep -qF "the step ceiling never fired" "$T/dead.log"; then
        echo "check-harness-ceiling: SELF-TEST FAILED — the dead ceiling was refused, but" \
            "not for the stated reason:" >&2
        cat "$T/dead.log" >&2
        exit 1
    fi
    echo "check-harness-ceiling: self-test — a never-expiring ceiling reported the silence"
else
    echo "check-harness-ceiling: clause B (the wedged-main-thread probe) SKIPPED — it needs" \
        "macOS and a Swift toolchain. Clause A ran."
fi

if [ "$status" -ne 0 ]; then
    exit 1
fi
echo "check-harness-ceiling: OK (3 harnesses, one ceiling and one sentence)"
