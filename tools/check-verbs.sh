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
# The interpreter-coverage gate. The SwiftUI and Compose backends
# re-implement the harness verbs and carry private copies of the wire
# constants, string-matched rather than compile-checked. Every harness
# verb, every APPLY/KIND/PROP/COMMAND/MENU_KIND/MPROP constant with its
# value, and every value type reachable through the spec's PROPS must
# appear in BOTH interpreter files.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

# --- THE CLIP MASKS: the vocabulary the sweep below cannot see. -------
#
# That sweep matches APPLY_|KIND_|PROP_|COMMAND_|VALUE_|MENU_KIND_|MPROP_
# and stops, so wire.rs's five clip masks (BIT POSITIONS, not ordinals)
# are copied into both interpreters with nothing pinning either copy.
# NAME AND VALUE TOGETHER: a copy carrying all five names at four right
# values compiles, runs and ships one wrong kind.
#
# A FUNCTION, not another clause in the heredoc, so the rule can be
# pointed at a PERTURBED copy of a mirror — the self-tests below.
#
# The canonical paths live twice, python's defaults and the shell's
# variables, and both are exercised on every run: a wrong shell path
# fails the perturbation count, a wrong python default fails the real
# call with "cannot read".
CLIP_WIRE="crates/kaya/src/wire.rs"
CLIP_SWIFT="swift/KayaSwiftUI.swift"
CLIP_KOTLIN="android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"

clip_mirrors() { # [wire swift kotlin]; any path may be "-" for stdin
    python3 -c '
import re
import sys

WIRE = "crates/kaya/src/wire.rs"
SWIFT = "swift/KayaSwiftUI.swift"
KOTLIN = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"

srcs = sys.argv[1:] or [WIRE, SWIFT, KOTLIN]
bad = []


def read(src, label):
    """One mirror text. A path of "-" is stdin (how the self-tests feed
    a drifted copy). A path that is not there is a FAILURE naming both
    it and the mirror it stands in for, never a skip: the gate has to
    fail while the second copy is unwritten, which is what holds the
    remaining work open."""
    if src == "-":
        return sys.stdin.read()
    try:
        return open(src).read()
    except OSError as exc:
        bad.append("cannot read " + src + " for " + label + " (" + str(exc.strerror)
                   + "): the mirror this rule pins is not there")
        return None


wire, swift, kotlin = [read(s, l) for s, l in zip(srcs, [WIRE, SWIFT, KOTLIN])]

rows = re.findall(r"pub const (CLIP_[A-Z_0-9]+): u\d+ = (\d+);", wire or "")
if wire is not None and not rows:
    bad.append("no CLIP_* constants extracted from " + WIRE + ": the gate itself broke")

for const, value in rows:
    camel = "".join(w.capitalize() for w in const.split("_")[1:])
    # Swift spells this family kaya-prefixed (`kayaClipImage`) while its
    # other wire mirrors drop the prefix (`applyCopy`), so both pass.
    if swift is not None and not re.search(
            r"let (?:kayaClip" + camel + r"|clip" + camel + r")\b[^=\n]*=\s*" + value + r"\b", swift):
        bad.append(const + " = " + value + ": expected `let kayaClip" + camel
                   + " ... = " + value + "` in " + SWIFT)
    # Kotlin spells every wire mirror with the Rust name verbatim,
    # optionally typed. The lookahead rather than \b so a suffixed
    # literal (4u, 4L) counts while 4 still does not match 40.
    if kotlin is not None and not re.search(
            r"\b" + const + r"\b\s*(?::\s*\w+\s*)?=\s*" + value + r"(?![0-9])", kotlin):
        bad.append(const + " = " + value + ": expected `" + const + " = " + value
                   + "` in " + KOTLIN)

print("\n".join(bad))
sys.exit(1 if bad else 0)
' "$@"
}

# --- THE WINDOWED TIER'S LOOP: three links no scene can see. ---------
#
# docs/virtualization-plan.md §3/§4. The Compose tier windows its tables
# — spacer, realized band, spacer, inside its own scroll container — and
# THREE OF THE FOUR LINKS IN THAT LOOP ARE INVISIBLE TO THE ONE SCENE
# THAT DRIVES IT. Measured 2026-08-25 on a real emulator, each
# perturbation watched:
#
#   * the visible-range report deleted from the report loop:
#     windowed.steps stays GREEN, because scroll_to_row moves the band
#     itself and nothing else in the scene ever scrolls;
#   * the measured-extent report deleted: GREEN — a height moves the
#     ARITHMETIC and never the band (the mac tier measured the same);
#   * both spacers zeroed: GREEN — expect_window reads the row at the
#     viewport's top, and a tier that lays its rows out at the wrong y is
#     internally consistent about which row that is.
#
# So they are held HERE, the way check-native-undo holds a pair no scene
# can fail. The SwiftUI half of the same loop lives in
# tools/check-table-tier.sh, which reads the mac driver.
WINDOW_KOTLIN="android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"

window_tier() { # [kotlin]; "-" reads stdin (how the self-tests feed a copy)
    python3 -c '
import sys

KOTLIN = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"
src = sys.argv[1] if len(sys.argv) > 1 else KOTLIN
text = sys.stdin.read() if src == "-" else open(src).read()
bad = []


def body(anchor):
    """The braced body the declaration `anchor` opens, or None."""
    at = text.find(anchor)
    if at < 0:
        return None
    start = text.find("{", at)
    if start < 0:
        return None
    depth = 0
    for j in range(start, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[start:j + 1]
    return None


report = body("fun report()")
if report is None:
    bad.append("KayaCompose.kt has no `fun report()` — the windowed tiers "
               "report loop moved, and this clause is blind; re-point it")
else:
    for call, why in (
        ("KayaPresent.windowMoved(",
         "the visible range never reaches the core, so the band never "
         "follows the viewport (scroll_to_row moves it on its own, which "
         "is why the scene stays green)"),
        ("KayaPresent.rowsMeasured(",
         "the core never learns a row height, so its pitch, its extent "
         "and both spacers stay 0 with every scene still green"),
        ("KayaPresent.rowExtent(",
         "the height report loses its EXACT comparison and either "
         "repeats every turn or never fires"),
    ):
        if call not in report:
            bad.append("`fun report()` in KayaCompose.kt never calls "
                       "`" + call + "` — " + why)

surface = body("private fun KayaTableSurface(")
if surface is None:
    bad.append("KayaCompose.kt has no `private fun KayaTableSurface(` — the "
               "windowed tier moved, and this clause is blind; re-point it")
else:
    for pin, why in (
        ("val offsetPx = window.offsetPx",
         "the bands top stops being the core s offset"),
        ("val extentPx = window.extentPx",
         "the collection s height stops being the core s extent"),
        ("kayaWindowSpacers(offsetPx, extentPx, bandH, tail)",
         "the two spacers stop being one function of those two numbers"),
        ("Constraints.fixed(totalW, spacers.first)",
         "the TOP spacer stops being that function s answer"),
        ("Constraints.fixed(totalW, spacers.second)",
         "the BOTTOM spacer stops being that function s answer"),
    ):
        if pin not in surface:
            bad.append("KayaTableSurface does not spell `" + pin + "` — "
                       + why + ", and no scene can see it (measured: both "
                       "spacers zeroed left windowed.steps green)")

for line in bad:
    print(line)
sys.exit(1 if bad else 0)
' "$@"
}

window_status=0
window_out="$(window_tier)" || {
    echo "check-verbs: the Compose windowed tier is missing a link of its own report loop, and no scene can see it (docs/virtualization-plan.md §3/§4):" >&2
    echo "$window_out" >&2
    window_status=1
}

clip_status=0
clip_out="$(clip_mirrors)" || {
    echo "check-verbs: the CLIP_* mirrors do not match crates/kaya/src/wire.rs — both interpreters carry PRIVATE copies and nothing else pins them, so a drifted value ships a wrong clip kind silently:" >&2
    echo "$clip_out" >&2
    clip_status=1
}

# THE GUARD GUARDS ITSELF, in both directions and on BOTH mirrors,
# perturbing the REAL file rather than a fixture (docs/traps.md: the
# wayland seat guard's negative test passed VACUOUSLY TWICE).
#
# A PERTURBATION THAT DID NOT APPLY PROVES NOTHING, so the substitution
# count is printed and checked before the copy is used.
#
# AND THE REFUSAL IS SCORED, NOT JUST COUNTED: an exit code alone is
# satisfied by any unrelated finding. Each half scores what the
# perturbation INTRODUCED over the real check's own findings —
# `named/total`, and the only passing score is 1/1. Left is the refusal,
# right is the accept direction. Baseline-relative, so a genuinely
# drifted mirror does not report as a broken guard. A clause that simply
# PASSED the drifted copy scores 0/0 and fails the same way.
#
# These run AFTER the real check, so a missing mirror reports as a
# missing mirror rather than as a perturbation that would not apply.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# <source> <regex around the value> <replacement> <scratch copy>
perturb() {
    python3 -c '
import re
import sys

text = open(sys.argv[1]).read()
drifted, n = re.subn(sys.argv[2], lambda m: m.group(1) + sys.argv[3], text)
open(sys.argv[4], "w").write(drifted)
print(n)
' "$@"
}

# <findings from the drifted copy> <findings from the real check> <regex>
introduced() {
    python3 -c '
import re
import sys

baseline = set(l for l in sys.argv[2].splitlines() if l.strip())
new = [l for l in sys.argv[1].splitlines() if l.strip() and l not in baseline]
named = [l for l in new if re.search(sys.argv[3], l)]
print(str(len(named)) + "/" + str(len(new)))
' "$@"
}

hits="$(perturb "$CLIP_SWIFT" '(let kayaClipImage\b[^=\n]*=\s*)4\b' 5 "$T/drifted.swift")"
if [ "$hits" != 1 ]; then
    echo "check-verbs: SELF-TEST FAIL (the kayaClipImage perturbation applied $hits times, want 1 — an unchanged copy cannot prove the rule fires)" >&2
    exit 1
fi
drift="$(clip_mirrors "$CLIP_WIRE" - "$CLIP_KOTLIN" <"$T/drifted.swift")"
score="$(introduced "$drift" "$clip_out" "^CLIP_IMAGE = 4: expected .* in swift/KayaSwiftUI\.swift$")"
if [ "$score" != "1/1" ]; then
    echo "check-verbs: SELF-TEST FAIL (drifting kayaClipImage to 5 scored $score named/introduced findings, want 1/1)" >&2
    exit 1
fi

# The Kotlin half, a DIFFERENT constant so neither half can be passing
# on a hardcoded one. The modifier is not part of the rule, so the
# perturbation matches from the name on.
hits="$(perturb "$CLIP_KOTLIN" '(\bCLIP_FILES\b\s*(?::\s*\w+\s*)?=\s*)8\b' 9 "$T/drifted.kt")"
if [ "$hits" != 1 ]; then
    echo "check-verbs: SELF-TEST FAIL (the CLIP_FILES perturbation applied $hits times, want 1 — an unchanged copy cannot prove the rule fires)" >&2
    exit 1
fi
drift="$(clip_mirrors "$CLIP_WIRE" "$CLIP_SWIFT" - <"$T/drifted.kt")"
score="$(introduced "$drift" "$clip_out" "^CLIP_FILES = 8: expected .* in .*KayaCompose\.kt$")"
if [ "$score" != "1/1" ]; then
    echo "check-verbs: SELF-TEST FAIL (drifting CLIP_FILES to 9 scored $score named/introduced findings, want 1/1)" >&2
    exit 1
fi

# An ABSENT mirror is a failure that NAMES IT, never a skip.
gone="$(clip_mirrors "$CLIP_WIRE" "$CLIP_SWIFT" "$T/no-such-mirror.kt")"
case "$gone" in
    *"cannot read"*"KayaCompose.kt"*) ;;
    *)
        echo "check-verbs: SELF-TEST FAIL (an absent Kotlin mirror failed without naming it): $gone" >&2
        exit 1
        ;;
esac

# AND THE WINDOWED TIER'S OWN, the same shape: the three perturbations
# that were WATCHED staying green on a real emulator must be red here,
# and each prints its substitution count first, because a perturbation
# that did not apply proves nothing.
window_negative() { # <python-regex> <replacement> <label> <expected finding>
    local hits drift
    hits="$(perturb "$WINDOW_KOTLIN" "$1" "$2" "$T/window.kt")"
    if [ "$hits" != 1 ]; then
        echo "check-verbs: SELF-TEST FAIL ($3 applied $hits times, want 1 — an unchanged copy cannot prove the rule fires)" >&2
        exit 1
    fi
    echo "check-verbs: windowed-tier self-test ($3) applied $hits substitution(s)"
    drift="$(window_tier - <"$T/window.kt")" && {
        echo "check-verbs: SELF-TEST FAIL ($3 passed the windowed-tier clause)" >&2
        exit 1
    }
    case "$drift" in
        *"$4"*) ;;
        *)
            echo "check-verbs: SELF-TEST FAIL ($3 reddened, but did not name \"$4\"): $drift" >&2
            exit 1
            ;;
    esac
}

window_negative '(\n            )KayaPresent\.windowMoved\(node\.id, first\.toLong\(\), count\.toLong\(\)\)' \
    '' "the range report removed from the report loop" \
    "never calls \`KayaPresent.windowMoved("
window_negative '(\n            if \(moved\) )KayaPresent\.rowsMeasured\(node\.id, laidOutFirst\.toLong\(\), heights\)' \
    'Unit' "the height report removed from the report loop" \
    "never calls \`KayaPresent.rowsMeasured("
window_negative '(\n        val spacers = )kayaWindowSpacers\(offsetPx, extentPx, bandH, tail\)' \
    'Pair(0, 0)' "both spacers cut tier-side instead of from the core" \
    "does not spell \`kayaWindowSpacers(offsetPx, extentPx, bandH, tail)\`"

# An ABSENT interpreter is a failure that names it, never a skip.
gone="$(window_tier "$T/no-such-interpreter.kt" 2>&1)" && {
    echo "check-verbs: SELF-TEST FAIL (an absent Kotlin interpreter passed the windowed-tier clause)" >&2
    exit 1
}
case "$gone" in
    *"no-such-interpreter.kt"*) ;;
    *)
        echo "check-verbs: SELF-TEST FAIL (an absent Kotlin interpreter failed without naming it): $gone" >&2
        exit 1
        ;;
esac

KAYA_CLIP_MIRRORS="$clip_status" KAYA_WINDOW_TIER="$window_status" python3 - <<'EOF'
import os
import pathlib
import re
import sys

harness = open("crates/kaya/src/harness.rs").read()
wire = open("crates/kaya/src/wire.rs").read()
spec = open("crates/kaya/src/spec.rs").read()
swift = open("swift/KayaSwiftUI.swift").read()
kotlin = open("android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt").read()

failures = []


def fail(msg):
    failures.append(msg)


# --- Harness verbs: the parse() match arms are the grammar. ----------
parse_body = harness[harness.index("pub fn parse(") : harness.index("fn parse_target(")]
verbs = sorted(set(re.findall(r'"([a-z_]+)" =>', parse_body)) - {"on", "off"})
if not verbs:
    fail("no verbs extracted from harness.rs parse() — the gate itself broke")
for verb in verbs:
    for name, text in (("KayaSwiftUI.swift", swift), ("KayaCompose.kt", kotlin)):
        if f'"{verb}"' not in text:
            fail(f'verb "{verb}" missing from {name}')

# --- Scene substitutions: the THIRD vocabulary. ----------------------
# A scene path may carry `$TMP` or `$PID`, and an interpreter that does
# not expand a token uses it as a LITERAL PATH SEGMENT — on macOS the
# picker then falls back to its last-used location and the scene asserts
# against whatever that was (docs/traps.md). Silent on every platform.
#
# THREE SITES, NOT TWO: harness.rs is the third implementation of these
# verbs, the one the GTK and WinUI backends run.
subs = sorted(
    set(
        tok
        for f in pathlib.Path("tools/scenes").glob("*.steps")
        for tok in re.findall(r"\$([A-Z_]+)", f.read_text())
    )
)
for sub in subs:
    for name, text in (
        ("KayaSwiftUI.swift", swift),
        ("KayaCompose.kt", kotlin),
        ("harness.rs", harness),
    ):
        if f'"{sub}"' not in text:
            fail(
                f'scene substitution "${sub}" has no expansion in {name} — '
                f"it would be used as a literal path segment"
            )

# AND THE EXPANSION HAS TO REACH BOTH SIDES OF THE SCENE: an
# implementation can expand the path a verb NAVIGATES to and forget the
# one it ASSERTS against, so the picker is aimed correctly and the
# comparison fails against a literal "$PID" — reading as a broken picker
# rather than a harness one.
for name, text in (
    ("KayaSwiftUI.swift", swift),
    ("KayaCompose.kt", kotlin),
    ("harness.rs", harness),
):
    if "expect_file_dialog" in text and "unexpanded substitution" not in text:
        fail(
            f"{name} reads expect_file_dialog's directory but never refuses an "
            f"unexpanded substitution — an expansion it forgot would read as a "
            f"broken picker"
        )

# --- The step-failed line: THREE harnesses, one spelling. ------------
# `failures` is named only by the verdict, which is printed LAST, so an
# abort before it takes the whole list — the log shows a crash with no
# reason. The rule is that a failure is printed the moment it is final,
# with the TEXT interpolated: a fixed sentence names no cause and is
# printed for every one. Two of the three carried this for milestones
# while KayaCompose.kt did not, and only eyes ever compared them
# (docs/deferred.md).
for name, text, interp in (
    ("KayaSwiftUI.swift", swift, r"\\\("),
    ("KayaCompose.kt", kotlin, r"\$"),
    ("harness.rs", harness, r"\{"),
):
    if not re.search("KAYA_HARNESS: step-failed " + interp, text):
        fail(
            f"{name} never prints `KAYA_HARNESS: step-failed <text>` with the "
            f"failure text interpolated — a step's failure reaches the log only "
            f"if it is printed when it becomes final, not saved for the verdict"
        )

# AND IN THE WRAPPER'S FINAL-FAILURE BRANCH, not merely somewhere in the
# file. The interpreters print this line twice for different reasons —
# KayaSwiftUI.swift's clip-breach arm is one — so presence alone is
# satisfied by a copy that runs on another path, and the branch that
# matters is the one AFTER the retry gives up. harness.rs has no
# retryStep (its `poll` retries internally) and is held by the clause
# above alone.
for name, text in (("KayaSwiftUI.swift", swift), ("KayaCompose.kt", kotlin)):
    retries = [m.end() for m in re.finditer(r"retryStep = true", text)]
    prints = [m.start() for m in re.finditer("KAYA_HARNESS: step-failed ", text)]
    if not retries:
        fail(f"{name} has no `retryStep = true` — the bounded-retry wrapper this "
             f"gate reads is gone; re-point the clause at whatever replaced it")
    elif not any(p > retries[-1] for p in prints):
        fail(
            f"{name} prints `KAYA_HARNESS: step-failed` only BEFORE the retry "
            f"wrapper gives up — the branch that runs when an expect's deadline "
            f"lands has none, so a failing step's text still dies with an abort"
        )

# --- Wire constants the interpreters mirror privately. ---------------
# APPLY/KIND/PROP/COMMAND/MENU_KIND/MPROP: all of them. VALUE: only the
# types reachable through the spec's PROPS PropKinds (the scene's prop
# typing keeps the rest off the pump).
rows = re.findall(r"pub const ((?:APPLY|KIND|PROP|COMMAND|VALUE|MENU_KIND|MPROP)_[A-Z_0-9]+): u\d+ = (\d+);", wire)
# THE CANVAS VOCABULARIES, which no gate held until 2026-08-26. They ride
# the op stream as i64 rather than u32, so the sweep above cannot see
# them by type, and their prefixes are not in its alternation either —
# which left five enums hand-copied into two interpreters with nothing
# checking the numbers, the exact shape check-file-modes exists for
# (docs/canvas-plan.md §3.6, which asked for this clause). Kotlin spells
# a Long literal with an L suffix, so the value pattern allows one.
canvas_rows = re.findall(
    r"pub const ((?:DRAW|PAINT|FILL|TEXT_ALIGN|TEXT_BASELINE)_[A-Z_0-9]+): i64 = (\d+);", wire)
if len(canvas_rows) < 21:
    fail(f"only {len(canvas_rows)} canvas constants found in wire.rs — the sweep reads "
         "nothing and would agree with everything")
rows += canvas_rows
props_block = spec[spec.index("pub const PROPS") : spec.index("];", spec.index("pub const PROPS"))]
prop_kinds = set(re.findall(r"PropKind::(\w+)", props_block))
required_values = {"VALUE_" + k.upper() for k in prop_kinds}


def swift_name(const):
    group, rest = const.split("_", 1)
    return group.lower() + "".join(w.capitalize() for w in rest.split("_"))


for const, value in rows:
    if const.startswith("VALUE_") and const not in required_values:
        continue
    sname = swift_name(const)
    if not re.search(rf"let {re.escape(sname)}\b[^=\n]*= {value}\b", swift):
        fail(f"{const} = {value}: expected `{sname} ... = {value}` in KayaSwiftUI.swift")
    if not re.search(rf"\b{const}\b\s*(?::\s*\w+\s*)?=\s*{value}L?\b", kotlin):
        fail(f"{const} = {value}: expected `{const} = {value}` in KayaCompose.kt")

# --- The spec hash. A runtime assert also holds it (a stale compiled
# --- dylib/APK bypasses source gates); the SOURCE copy is pinned here.
wire_h = open("bindings/c/kaya_wire.h").read()
m = re.search(r"#define KAYA_SPEC_HASH 0x([0-9a-fA-F]+)ULL", wire_h)
if not m:
    fail("KAYA_SPEC_HASH not found in bindings/c/kaya_wire.h — the gate itself broke")
else:
    h = m.group(1).lower()
    if not re.search(rf"let kayaSpecHash: UInt64 = 0x{h}\b", swift):
        fail(f"spec hash 0x{h}: expected `let kayaSpecHash: UInt64 = 0x{h}` in KayaSwiftUI.swift")
    if not re.search(rf"SPEC_HASH: ULong = 0x{h}uL\b", kotlin):
        fail(f"spec hash 0x{h}: expected `SPEC_HASH: ULong = 0x{h}uL` in KayaCompose.kt")

# --- Every expect arm must RECORD what it observed. ------------------
# A verb that appends a failure on mismatch and nothing on a match
# verifies nothing when it passes: the leg prints PASS with that
# assertion silently absent from the observation list. The observation
# list is also the byte-compared verdict text, so "recorded nothing" and
# "reported the wrong thing" are one defect class.
def expect_arms(text, pattern, end_marker):
    """(verb, body) for each expect_* arm of an interpreter's switch."""
    heads = list(re.finditer(pattern, text))
    for i, m in enumerate(heads):
        stop = heads[i + 1].start() if i + 1 < len(heads) else len(text)
        end = text.find(end_marker, m.start(), stop)
        yield m.group(1), text[m.start() : end if end > 0 else stop]


# ONE EXEMPTION: an arm that calls the depth stub does not RETURN, so it
# cannot pass vacuously — the process dies naming the scene and the
# platform. Without this the rule would push a half-built backend into
# faking an observation.
def records_or_refuses(body, appender):
    return appender in body or "epthStub(" in body or "epth_stub(" in body


for verb, body in expect_arms(swift, r'case "(expect[a-z_]*)":', "\n            case "):
    if not records_or_refuses(body, "observed.append("):
        fail(f'KayaSwiftUI.swift\'s "{verb}" arm never appends to `observed` — '
             "an expect that records nothing passes without verifying anything")
for verb, body in expect_arms(kotlin, r'"(expect[a-z_]*)" ->', "\n                    \""):
    if not records_or_refuses(body, "observed.add("):
        fail(f'KayaCompose.kt\'s "{verb}" arm never adds to `observed` — '
             "an expect that records nothing passes without verifying anything")

# The vtable rule: the SwiftUI interpreter reaches the host ONLY through
# KayaHost's function-pointer table. A direct C-symbol call typechecks
# and links, then dies at dlopen against a static-rust or RTLD_LOCAL
# host ("symbol not found in flat namespace"). C symbols are exactly the
# kaya_ + underscore namespace; Swift helpers are camelCase.
for m in re.finditer(r"\bkaya_[a-z_]+\s*\(", swift):
    fail(f"KayaSwiftUI.swift calls C symbol `{m.group(0).strip('( ')}` directly — "
         "route it through KayaHost's api table (the vtable pins the one "
         "live kaya instance; direct symbols die on static/RTLD_LOCAL hosts)")

# THE STAMPED-OBSERVATION RULE. A field the harness READS must be
# written on every platform the interpreter serves, and the way that
# breaks is silent: the write sits inside a platform conditional, the
# other platform leaves the field at its initial value, and the verb
# reads a default that looks like an answer.
#
# So each of these fields must have at least one write OUTSIDE every
# platform conditional. Nesting is tracked rather than grepped, because
# a write is "conditional" whenever ANY enclosing #if is.
STAMPED = ["formFactor", "splitPresentation"]
lines = swift.splitlines()
depths, depth = [], 0
for line in lines:
    t = line.strip()
    if t.startswith("#endif"):
        depth = max(0, depth - 1)
    depths.append(depth)
    if t.startswith("#if"):
        depth += 1
for field in STAMPED:
    writes = [(n, d) for n, (line, d) in enumerate(zip(lines, depths), 1)
              if re.search(rf"\.{field}\s*=[^=]", line)]
    if not writes:
        fail(f"KayaSwiftUI.swift never writes `{field}`, which the harness reads")
    elif all(d > 0 for _, d in writes):
        where = ", ".join(str(n) for n, _ in writes)
        fail(f"every write to `{field}` in KayaSwiftUI.swift sits inside a platform "
             f"conditional (lines {where}) — the platforms it excludes read the "
             "field's initial value as if it were an observation")

if failures:
    for f in failures:
        print(f"check-verbs: {f}", file=sys.stderr)
    sys.exit(1)
# clip_mirrors() ran first and printed its own findings; its verdict is
# read here so there is exactly ONE verdict line.
if os.environ["KAYA_CLIP_MIRRORS"] != "0":
    sys.exit(1)
if os.environ["KAYA_WINDOW_TIER"] != "0":
    sys.exit(1)
print(f"check-verbs: OK ({len(verbs)} verbs, {len(rows)} constants ({len(canvas_rows)} of them the canvas vocabularies) + the CLIP_* mirrors + the windowed tier's loop + spec hash against 2 interpreters)")
EOF
