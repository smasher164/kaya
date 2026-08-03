#!/usr/bin/env bash

# Everything runs inside the dev shell; the marker carries the flake
# fingerprint the shell was built from.
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
# constants — string-matched layers the compiler cannot hold to the
# Rust source, and the layer where "landed everywhere except..." bugs
# have twice reached a device suite (GTK child_texts, Kotlin
# expect_order). This gate holds them structurally: every harness verb,
# every APPLY/KIND/PROP/COMMAND constant (with its value), and every
# value type reachable through the spec's PROPS must appear in BOTH
# interpreter files, as is every MENU_KIND/MPROP menu constant. A new
# widget, prop, verb, menu item kind, or value type that misses an
# interpreter fails here, in seconds, not on an emulator.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

# --- THE CLIP MASKS: the vocabulary the sweep below cannot see. -------
#
# That sweep matches APPLY_|KIND_|PROP_|COMMAND_|VALUE_|MENU_KIND_|MPROP_
# and stops, so wire.rs's five clip masks (CLIP_TEXT/HTML/IMAGE/FILES/
# CUSTOM — BIT POSITIONS, not an ordinal) are copied into both
# interpreters with nothing pinning either copy to the Rust. Every other
# backend reads the source: gtk.rs says `crate::wire::CLIP_FILES` and
# the compiler holds it there. An interpreter cannot, and the drift is
# SILENT — `present and CLIP_IMAGE` against a copy that spells image 8
# reads the FILES slot as a picture, so the leg fails describing the
# wrong content one layer away from the constant that is wrong.
#
# NAME AND VALUE TOGETHER, because half a mirror is the whole bug: a
# copy carrying all five names at four right values compiles, runs and
# ships one wrong kind.
#
# A FUNCTION, not another clause in the heredoc, so the rule can be
# pointed at a PERTURBED copy of a mirror. A rule nobody has watched
# refuse is a rule nobody knows fires (CLAUDE.md, invariant 3), and this
# tree has had two negative tests pass vacuously against patterns that
# never matched their file at all. The self-tests below are that watch.
#
# The canonical paths live twice — python's defaults (which name the
# mirrors in every message, so a stdin stand-in still reports the file
# it stands in for) and the shell's variables (which the self-tests
# read). Both copies are exercised on every run: a wrong shell path
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
    # Swift spells this family file-scope and kaya-prefixed
    # (`private let kayaClipImage: UInt32 = 4`); its other wire mirrors
    # drop the prefix (`applyCopy`), so both spellings pass and the
    # message names the one the file carries today.
    if swift is not None and not re.search(
            r"let (?:kayaClip" + camel + r"|clip" + camel + r")\b[^=\n]*=\s*" + value + r"\b", swift):
        bad.append(const + " = " + value + ": expected `let kayaClip" + camel
                   + " ... = " + value + "` in " + SWIFT)
    # Kotlin spells every wire mirror with the Rust name verbatim
    # (`private const val APPLY_COPY = 25`), optionally typed. The
    # lookahead rather than \b so a suffixed literal (4u, 4L) counts
    # while 4 still does not match 40.
    if kotlin is not None and not re.search(
            r"\b" + const + r"\b\s*(?::\s*\w+\s*)?=\s*" + value + r"(?![0-9])", kotlin):
        bad.append(const + " = " + value + ": expected `" + const + " = " + value
                   + "` in " + KOTLIN)

print("\n".join(bad))
sys.exit(1 if bad else 0)
' "$@"
}

clip_status=0
clip_out="$(clip_mirrors)" || {
    echo "check-verbs: the CLIP_* mirrors do not match crates/kaya/src/wire.rs — both interpreters carry PRIVATE copies and nothing else pins them, so a drifted value ships a wrong clip kind silently:" >&2
    echo "$clip_out" >&2
    clip_status=1
}

# THE GUARD GUARDS ITSELF, in both directions and on BOTH mirrors.
#
# Each half is perturbed out of the REAL file, in a scratch copy piped
# back through the rule, so what is proven is that the pattern matches
# the spelling that file actually carries. A fixture would only ever
# prove the pattern matches the fixture — which is how the wayland seat
# guard's negative test passed VACUOUSLY TWICE against a pattern that
# never matched its file at all.
#
# A PERTURBATION THAT DID NOT APPLY PROVES NOTHING, so the substitution
# count is printed and checked before the copy is used at all.
#
# AND THE REFUSAL IS SCORED, NOT JUST COUNTED. An exit code alone is
# satisfied by any unrelated finding — with the Kotlin mirror unwritten,
# the drifted SWIFT copy failed for the MISSING KOTLIN COPY and a
# status-only test read that as success (measured while writing this).
# So each half scores what the perturbation INTRODUCED over the real
# check's own findings: `named/total`, and the only passing score is
# 1/1. The left number is the refusal (the drift must be seen); the
# right is the accept direction (nothing else may move, so a rule that
# refused everything fails too). Baseline-relative, because a genuinely
# drifted mirror is not a broken guard and must not report as one — the
# absolute count said otherwise, measured. A clause that simply PASSED
# the drifted copy scores 0/0 and fails this the same way, which is why
# there is no separate exit-code clause: that one is the vacuous shape.
#
# These run AFTER the real check above, so a mirror that is missing
# entirely reports as a missing mirror rather than as a perturbation
# that would not apply.
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
# on a hardcoded one. The modifier is not part of the rule (the file
# says `internal const val`, the sweep below spells its own constants
# `private const val`), so the perturbation matches from the name on.
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

# An ABSENT mirror is a failure that NAMES IT, never a skip — the state
# this rule was in for the hours between the two mirrors being written,
# and the one where a skip would have been most tempting. The message is
# itself the refusal: a line in the findings is what makes the exit
# nonzero, so there is nothing to check twice.
gone="$(clip_mirrors "$CLIP_WIRE" "$CLIP_SWIFT" "$T/no-such-mirror.kt")"
case "$gone" in
    *"cannot read"*"KayaCompose.kt"*) ;;
    *)
        echo "check-verbs: SELF-TEST FAIL (an absent Kotlin mirror failed without naming it): $gone" >&2
        exit 1
        ;;
esac

KAYA_CLIP_MIRRORS="$clip_status" python3 - <<'EOF'
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
# Verbs and wire constants are not the only thing the interpreters
# mirror. A scene path may carry `$TMP` or `$PID`, and an interpreter
# that does not expand a token uses it as a LITERAL PATH SEGMENT — a
# directory that cannot exist, which on macOS means the picker quietly
# falls back to its last-used location and the scene asserts against
# whatever that was (docs/traps.md). Silent on every platform.
#
# When this was written the expansion lived in KayaSwiftUI.swift ALONE,
# and nothing anywhere said so; wiring the filedialog scene onto android
# would have shipped the literal. Same shape as the verbs above, same
# reason: the interpreters are the historic miss layer.
#
# THREE SITES, NOT TWO. harness.rs is the third implementation of these
# verbs — the one the GTK and WinUI backends run — and the first cut of
# this rule checked only the two interpreter files, which is the very
# hole it was written to close, one file over. Nothing else in this gate
# looks at harness.rs as a MIRROR (it is the source the verbs are
# extracted FROM), so the omission read as correct.
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

# AND THE EXPANSION HAS TO REACH BOTH SIDES OF THE SCENE. Carrying the
# tokens is not enough: an implementation can expand the path a verb
# NAVIGATES to and forget the one it ASSERTS against, which is the worst
# shape of the bug — the picker is aimed correctly, shows the right
# directory, and the comparison fails against a literal "$PID", reading
# as a broken picker rather than a harness one. Measured 2026-07-31 on
# the Compose interpreter. All three carry the refusal now, and this is
# what keeps them carrying it.
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

# --- Wire constants the interpreters mirror privately. ---------------
# APPLY/KIND/PROP/COMMAND/MENU_KIND/MPROP: all of them. VALUE: only the
# types reachable through the spec's PROPS PropKinds (the scene's prop
# typing keeps the rest off the pump).
rows = re.findall(r"pub const ((?:APPLY|KIND|PROP|COMMAND|VALUE|MENU_KIND|MPROP)_[A-Z_0-9]+): u\d+ = (\d+);", wire)
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
    if not re.search(rf"\b{const}\b\s*(?::\s*\w+\s*)?=\s*{value}\b", kotlin):
        fail(f"{const} = {value}: expected `{const} = {value}` in KayaCompose.kt")

# --- The spec hash: the one constant whose staleness a runtime assert
# --- must also hold (a stale compiled dylib/APK bypasses source gates),
# --- but the SOURCE copy is pinned here like every other constant.
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
# assertion silently absent from the observation list. Measured
# 2026-07-25 — the Compose expect_ax arm did exactly this, and the only
# reason it surfaced is that EVERY step in that scene was expect_ax, so
# the whole-script "script has no expects" fallback fired. One
# non-accessibility expect in the same scene and it would have shipped
# a verb that never checked anything.
#
# The observation list is also the byte-compared verdict text, so
# "recorded nothing" and "reported the wrong thing" are the same defect
# class. String-matched per arm, the house style of this gate.
def expect_arms(text, pattern, end_marker):
    """(verb, body) for each expect_* arm of an interpreter's switch."""
    heads = list(re.finditer(pattern, text))
    for i, m in enumerate(heads):
        stop = heads[i + 1].start() if i + 1 < len(heads) else len(text)
        end = text.find(end_marker, m.start(), stop)
        yield m.group(1), text[m.start() : end if end > 0 else stop]


# ONE EXEMPTION, and it is not a loophole: an arm that calls the depth
# stub does not RETURN. It cannot pass vacuously because it cannot pass
# at all — the process dies naming the scene and the platform. That is
# the honest spelling for a verb whose backend has no feature yet, and
# without this the rule would push a half-built backend into faking an
# observation, which is the exact defect it exists to catch.
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

# The vtable rule: the SwiftUI interpreter reaches the host ONLY
# through KayaHost's function-pointer table. A direct C-symbol call
# (kaya_emit_*, kaya_next_*, ...) typechecks and even links, then
# dies at dlopen against a static-rust or RTLD_LOCAL host ("symbol
# not found in flat namespace" — the confirm slice hit it live).
# C symbols are exactly the kaya_ + underscore namespace; Swift-side
# helpers are camelCase and never match.
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
# It happened. `formFactor` was written only by the menu chrome, which
# lives inside `#if !os(macOS)` and reads `horizontalSizeClass` — a
# thing macOS does not have. Every desktop window carried `unknown`
# from the day form factor landed, and nothing noticed for two
# milestones because macOS answers the MENU verb off the real NSMenu
# instead of the model. The second lowering to ask the model got
# `unknown` and took the wrong arm.
#
# So: each of these fields must have at least one write OUTSIDE every
# platform conditional. Nesting is tracked rather than grepped,
# because a write is "conditional" whenever ANY enclosing #if is.
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

# (THE PANE PROPORTION pin lived here: protocol::leading_pane_width's
# 25%/180..280 served the GTK and WinUI arms, and the Compose arm
# restated the same numbers in Kotlin because it cannot call Rust, so
# this pinned the two copies together. There is one copy again. Each
# backend that adopted its platform's list-detail wrapper adopted that
# wrapper's proportions with it — libadwaita's sidebar-width-fraction,
# which is where the 25%/180..280 came from in the first place, and
# Material's own pane sizing — leaving WinUI the only caller, because
# TwoPaneView's default is the down-the-middle split no platform
# ships. A single Rust function needs no cross-language pin, and
# scene.rs unit-tests its rule directly.)

if failures:
    for f in failures:
        print(f"check-verbs: {f}", file=sys.stderr)
    sys.exit(1)
# The CLIP_* mirrors are checked by clip_mirrors(), which ran first and
# printed its own findings. Its verdict is read here rather than left to
# the shell so there is exactly ONE verdict line: an OK printed beside a
# failing clause is the shape a reader believes.
if os.environ["KAYA_CLIP_MIRRORS"] != "0":
    sys.exit(1)
print(f"check-verbs: OK ({len(verbs)} verbs, {len(rows)} constants + the CLIP_* mirrors + spec hash against 2 interpreters)")
EOF
