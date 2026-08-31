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

# --- THE INK TOLERANCE: one ruled number, three hand-written copies. --
#
# `expect_ink` compares within ±1 PER CHANNEL (ruled 2026-08-26,
# docs/canvas-plan.md §7.2). The reason is measured: a macOS window's
# backing store carries the DISPLAY's profile, so the core's D2E3F7 is
# sampled back as D2E2F7 there while Android's PixelCopy reports the
# core's own bytes, and no one frozen string can exact-match both
# (docs/traps.md).
#
# THREE HARNESSES SPELL THAT NUMBER, and nothing compiles them against
# each other — check-file-modes' trap one surface over. The danger is
# not that they drift apart, which a lane would eventually show; it is
# that they drift TOGETHER, because widening the tolerance makes every
# ink assertion quieter and no test anywhere gets slower or redder. So
# the number is pinned at the RULED value, not merely held equal:
# moving it is the maintainer's call, and this gate is where that
# conversation starts.
INK_HARNESS="crates/kaya/src/harness.rs"
INK_SWIFT="swift/KayaSwiftUI.swift"
INK_KOTLIN="android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"

ink_tolerance() { # [harness swift kotlin]; any path may be "-" for stdin
    python3 -c '
import re
import sys

HARNESS = "crates/kaya/src/harness.rs"
SWIFT = "swift/KayaSwiftUI.swift"
KOTLIN = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"

# THE RULED NUMBER (2026-08-26). One unit is the macOS display-profile
# round trip; two is a different colour, and every failure expect_ink
# exists for — a dropped blit, a swizzle, an upside-down or wrongly
# sized blit — moves a channel by far more than either.
RULED = 1

# (label, path, the constant spelled this language s way, the helper)
MIRRORS = [
    ("harness.rs", HARNESS,
     r"const INK_TOLERANCE\s*:\s*\w+\s*=\s*(\d+)\s*;", "ink_matches"),
    ("KayaSwiftUI.swift", SWIFT,
     r"let kayaInkTolerance\b[^=\n]*=\s*(\d+)\b", "kayaInkMatches"),
    ("KayaCompose.kt", KOTLIN,
     r"\bINK_TOLERANCE\b\s*(?::\s*\w+\s*)?=\s*(\d+)(?![0-9])", "kayaInkMatches"),
]

srcs = sys.argv[1:] or [m[1] for m in MIRRORS]
bad = []

for (label, _, pattern, helper), src in zip(MIRRORS, srcs):
    if src == "-":
        text = sys.stdin.read()
    else:
        try:
            text = open(src).read()
        except OSError as exc:
            bad.append("cannot read " + src + " for " + label + " ("
                       + str(exc.strerror) + "): the harness this rule pins "
                       "is not there")
            continue
    m = re.search(pattern, text)
    if not m:
        bad.append(label + " declares no ink tolerance constant — expect_ink "
                   "there compares by some other rule than the ruled +/-"
                   + str(RULED) + " per channel (docs/canvas-plan.md 7.2)")
        continue
    if int(m.group(1)) != RULED:
        bad.append(label + " sets its ink tolerance to " + m.group(1)
                   + ", not the ruled " + str(RULED)
                   + " — every expect_ink on that backend goes quieter and no "
                     "test anywhere reddens; widening it is the maintainers "
                     "call (docs/canvas-plan.md 7.2)")
    if len(re.findall(r"\b" + helper + r"\b", text)) < 2:
        bad.append(label + " names " + helper + " once — the tolerant compare "
                   "is defined and never called, so that arm still compares "
                   "the bytes exactly and the constant above is decoration")

print("\n".join(bad))
sys.exit(1 if bad else 0)
' "$@"
}

# --- THE AX OBSERVATION: three harnesses, one spelling. --------------
#
# An observation is the byte-compared verdict text (invariant 6), and
# `expect_ax` was recorded TWO ways: harness.rs and KayaCompose.kt quote
# the value, KayaSwiftUI.swift left it bare, so the one verdict nothing
# compares across platforms was the accessibility one
# (docs/deferred.md). RULED QUOTED 2026-08-27: two of the three already
# spelled it that way, harness.rs is the norm the interpreters follow,
# and the bare form has no measured reason — it is just the original mac
# depth slice (b560753) never revisited. The quotes are also what make a
# placeholder answer like <not in the accessibility tree> read as a
# VALUE rather than as prose.
#
# NO LANE CAN FAIL THIS. Every runner greps the verdict for
# `KAYA_SELFTEST: OK` and never diffs its text (validate-mac.sh:523,
# run-emulator.sh, run-sim.sh, run-suites.sh), so the spellings can
# disagree forever with every leg green — which is exactly how they did.
#
# The census reads each emitter out of its OWN ARM rather than grepping
# the file: `Step::ExpectAx(` alone matches harness.rs`s PARSER twice
# before it reaches the step arm, and a reader anchored on the name
# found ZERO observations there and agreed with everything.
AX_HARNESS="crates/kaya/src/harness.rs"
AX_SWIFT="swift/KayaSwiftUI.swift"
AX_KOTLIN="android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"

ax_spelling() { # [harness swift kotlin]; any path may be "-" for stdin
    python3 -c '
import re
import sys

HARNESS = "crates/kaya/src/harness.rs"
SWIFT = "swift/KayaSwiftUI.swift"
KOTLIN = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"

# The ruled spelling, with every interpolated value flattened to <v> so
# three languages that spell interpolation three ways compare as one
# string (check-harness-ceiling`s idiom).
OBS = {"ax": "ax \"<v>\"", "ax hint": "ax hint \"<v>\""}
# The failure sentence is the same value one line over. It is compared as
# a PREFIX because the interpreters append a platform why-not that
# harness.rs has no equivalent of.
WANTED = {"ax": "ax \"<v>\", wanted \"<v>\"",
          "ax hint": "ax hint \"<v>\", wanted \"<v>\""}

# (label, path, language, [(verb, arm opener, arm terminator)], record, refuse)
HARNESSES = [
    ("harness.rs", HARNESS, "rust",
     [("ax", r"Step::ExpectAx\([^()]*\) => Some\(poll\(", "\n            Step::"),
      ("ax hint", r"Step::ExpectAxHint\([^()]*\) => Some\(poll\(", "\n            Step::")],
     r"Ok\(format!\(", r"Err\(format!\("),
    ("KayaSwiftUI.swift", SWIFT, "swift",
     [("ax", "case \"expect_ax\":", "\n            case "),
      ("ax hint", "case \"expect_ax_hint\":", "\n            case ")],
     r"observed\.append\(", r"failures\.append\("),
    ("KayaCompose.kt", KOTLIN, "kotlin",
     [("ax", "\"expect_ax\" ->", "\n                    \""),
      ("ax hint", "\"expect_ax_hint\" ->", "\n                    \"")],
     r"observed\.add\(", r"failures\.add\("),
]


def arm(text, opener, terminator):
    m = re.search(opener, text)
    if not m:
        return None
    end = text.find(terminator, m.end())
    return text[m.start():end if end > 0 else len(text)]


def calls(body, opener):
    """Every <opener>(...) call in the arm, balanced to its closing paren."""
    out = []
    for m in re.finditer(opener, body):
        i, depth = m.end(), 1
        while i < len(body) and depth:
            c = body[i]
            if c == "\"":
                i += 1
                while i < len(body) and body[i] != "\"":
                    i += 2 if body[i] == "\\" else 1
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            i += 1
        out.append(body[m.end():i - 1])
    return out


def literals(call):
    """The string literals of a call in order, escapes preserved. A
    Kotlin or Swift sentence spliced with + is read as one."""
    out, i = [], 0
    while i < len(call):
        if call[i] == "\"":
            j, buf = i + 1, []
            while j < len(call) and call[j] != "\"":
                if call[j] == "\\":
                    buf.append(call[j:j + 2])
                    j += 2
                else:
                    buf.append(call[j])
                    j += 1
            out.append("".join(buf))
            i = j + 1
        else:
            i += 1
    return out


def flatten(lang, text):
    if lang == "rust":
        # Debug ({x:?}) prints a String WITH quotes; Display does not.
        return re.sub(r"\{([^{}]*)\}",
                      lambda m: "\"<v>\"" if m.group(1).endswith(":?") else "<v>",
                      text)
    if lang == "swift":
        return re.sub(r"\\\((?:[^()]|\([^()]*\))*\)|\\(.)",
                      lambda m: "<v>" if m.group(1) is None else m.group(1), text)
    text = re.sub(r"\\(.)", lambda m: m.group(1), text)
    return re.sub(r"\$\{[^{}]*\}|\$[A-Za-z_][A-Za-z0-9_.]*", "<v>", text)


def spelling(lang, call):
    return "".join(flatten(lang, lit) for lit in literals(call))


srcs = sys.argv[1:] or [h[1] for h in HARNESSES]
bad = []
seen = 0

for (label, _, lang, arms, record, refuse), src in zip(HARNESSES, srcs):
    if src == "-":
        text = sys.stdin.read()
    else:
        try:
            text = open(src).read()
        except OSError as exc:
            bad.append("cannot read " + src + " for " + label + " ("
                       + str(exc.strerror) + "): the harness this rule "
                       "holds one spelling across is not there")
            continue
    for verb, opener, terminator in arms:
        body = arm(text, opener, terminator)
        if body is None:
            bad.append(label + " has no " + verb + " arm the census can read "
                       "— the shape this clause anchors on moved; re-point it "
                       "rather than letting the spelling go unwatched")
            continue
        records = calls(body, record)
        if not records:
            bad.append(label + " records nothing in its " + verb + " arm — an "
                       "expect that records nothing passes without verifying "
                       "anything, and its verdict compares against no one")
        for call in records:
            seen += 1
            got = spelling(lang, call)
            if got != OBS[verb]:
                bad.append(label + " records the " + verb + " observation as "
                           + got + ", not the ruled " + OBS[verb]
                           + " — the observation IS the byte-compared verdict "
                           "text, and no lane diffs it, so two spellings sit "
                           "green forever (docs/deferred.md)")
        sentences = [s for s in (spelling(lang, c) for c in calls(body, refuse))
                     if "wanted" in s]
        if not sentences:
            bad.append(label + " never refuses a mismatched " + verb + " with "
                       "a sentence naming what it wanted — the comparison this "
                       "verb exists for has no failure text")
        for got in sentences:
            if not got.startswith(WANTED[verb]):
                bad.append(label + " refuses a mismatched " + verb + " with "
                           + got + ", which does not open with the ruled "
                           + WANTED[verb] + " — the same value, spelled two "
                           "ways one line apart")

# A census that reads nothing agrees with everything.
if not bad and seen < 6:
    bad.append("only " + str(seen) + " ax observations found across three "
               "harnesses — the reader is matching almost nothing and would "
               "pass any spelling")

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
        # kayaFixedRepresentable since 2026-08-28: the same fixed
        # constraints wherever they are representable, clamped only past
        # Compose s packing edge (the zero-width portfolio mount threw;
        # docs/deferred.md s portfolio-android entry). The third pin
        # holds the helper honest: fitPrioritizingWidth IS the identity
        # on every representable input, so the spacer link survives.
        ("kayaFixedRepresentable(totalW, spacers.first)",
         "the TOP spacer stops being that function s answer"),
        ("kayaFixedRepresentable(totalW, spacers.second)",
         "the BOTTOM spacer stops being that function s answer"),
        ("Constraints.fitPrioritizingWidth(w, w, h.coerceAtLeast(0), h.coerceAtLeast(0))",
         "kayaFixedRepresentable stops being the representability clamp"),
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

ink_status=0
ink_out="$(ink_tolerance)" || {
    echo "check-verbs: the expect_ink tolerance does not match the ruling — three harnesses hand-copy that number and nothing compiles them against each other, so a widened copy makes every ink assertion quieter with no lane the wiser (docs/canvas-plan.md §7.2):" >&2
    echo "$ink_out" >&2
    ink_status=1
}

ax_status=0
ax_out="$(ax_spelling)" || {
    echo "check-verbs: the ax observation is spelled more than one way — that text IS the byte-compared verdict and every lane only greps it for PASS, so the spellings can disagree forever with every leg green (docs/deferred.md):" >&2
    echo "$ax_out" >&2
    ax_status=1
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

# AND THE INK TOLERANCE'S OWN, all THREE harnesses, each widened to 2 on
# a copy — the drift that matters here is the one that moves every copy
# the same way, so each is watched being refused on its own.
ink_negative() { # <source> <regex around the value> <scratch copy> <slot> <expected finding>
    local hits drift score args
    hits="$(perturb "$1" "$2" 2 "$3")"
    if [ "$hits" != 1 ]; then
        echo "check-verbs: SELF-TEST FAIL (the $4 ink-tolerance perturbation applied $hits times, want 1 — an unchanged copy cannot prove the rule fires)" >&2
        exit 1
    fi
    echo "check-verbs: ink-tolerance self-test ($4 widened to 2) applied $hits substitution(s)"
    case "$4" in
        harness) args=("-" "$INK_SWIFT" "$INK_KOTLIN") ;;
        swift) args=("$INK_HARNESS" "-" "$INK_KOTLIN") ;;
        *) args=("$INK_HARNESS" "$INK_SWIFT" "-") ;;
    esac
    drift="$(ink_tolerance "${args[@]}" <"$3")"
    score="$(introduced "$drift" "$ink_out" "$5")"
    if [ "$score" != "1/1" ]; then
        echo "check-verbs: SELF-TEST FAIL (widening $4's ink tolerance to 2 scored $score named/introduced findings, want 1/1)" >&2
        exit 1
    fi
}

ink_negative "$INK_HARNESS" '(const INK_TOLERANCE\s*:\s*\w+\s*=\s*)1\b' \
    "$T/ink.rs" harness "^harness\.rs sets its ink tolerance to 2, "
ink_negative "$INK_SWIFT" '(let kayaInkTolerance\b[^=\n]*=\s*)1\b' \
    "$T/ink.swift" swift "^KayaSwiftUI\.swift sets its ink tolerance to 2, "
ink_negative "$INK_KOTLIN" '(\bINK_TOLERANCE\b\s*(?::\s*\w+\s*)?=\s*)1(?![0-9])' \
    "$T/ink.kt" kotlin "^KayaCompose\.kt sets its ink tolerance to 2, "

# AND A TOLERANCE NOTHING CALLS: the constant alone is decoration, and
# the arm beside it still compares the bytes exactly.
hits="$(perturb "$INK_KOTLIN" '(if \()kayaInkMatches\(got, want\)' 'got == want' "$T/ink-unused.kt")"
if [ "$hits" != 1 ]; then
    echo "check-verbs: SELF-TEST FAIL (the uncalled-helper perturbation applied $hits times, want 1)" >&2
    exit 1
fi
echo "check-verbs: ink-tolerance self-test (the Compose arm put back to an exact compare) applied $hits substitution(s)"
drift="$(ink_tolerance "$INK_HARNESS" "$INK_SWIFT" - <"$T/ink-unused.kt")"
score="$(introduced "$drift" "$ink_out" "^KayaCompose\.kt names kayaInkMatches once")"
if [ "$score" != "1/1" ]; then
    echo "check-verbs: SELF-TEST FAIL (an uncalled tolerant compare scored $score named/introduced findings, want 1/1)" >&2
    exit 1
fi

# An ABSENT harness is a failure that NAMES IT, never a skip.
gone="$(ink_tolerance "$INK_HARNESS" "$INK_SWIFT" "$T/no-such-harness.kt")"
case "$gone" in
    *"cannot read"*"KayaCompose.kt"*) ;;
    *)
        echo "check-verbs: SELF-TEST FAIL (an absent Kotlin harness failed the ink clause without naming it): $gone" >&2
        exit 1
        ;;
esac

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

# AND THE AX SPELLING'S OWN. The observation and the failure sentence are
# perturbed SEPARATELY, and on two different harnesses, so neither half
# can be passing on a hardcoded one — and the bare form each puts back is
# the one that actually shipped (docs/deferred.md).
ax_negative() { # <source> <regex around the value> <replacement> <slot> <copy> <label> <expected finding>
    local hits drift score args
    hits="$(perturb "$1" "$2" "$3" "$5")"
    if [ "$hits" != 1 ]; then
        echo "check-verbs: SELF-TEST FAIL ($6 applied $hits times, want 1 — an unchanged copy cannot prove the rule fires)" >&2
        exit 1
    fi
    echo "check-verbs: ax-spelling self-test ($6) applied $hits substitution(s)"
    case "$4" in
        harness) args=("-" "$AX_SWIFT" "$AX_KOTLIN") ;;
        swift) args=("$AX_HARNESS" "-" "$AX_KOTLIN") ;;
        *) args=("$AX_HARNESS" "$AX_SWIFT" "-") ;;
    esac
    drift="$(ax_spelling "${args[@]}" <"$5")"
    score="$(introduced "$drift" "$ax_out" "$7")"
    if [ "$score" != "1/1" ]; then
        echo "check-verbs: SELF-TEST FAIL ($6 scored $score named/introduced findings, want 1/1)" >&2
        exit 1
    fi
}

# The SwiftUI observation put back to the bare form it shipped with.
ax_negative "$AX_SWIFT" '(observed\.append\("ax )\\"\\\(wantAx\)\\""' '\(wantAx)"' \
    swift "$T/ax.swift" "the mac ax observation put back to the bare form" \
    "^KayaSwiftUI\.swift records the ax observation as ax <v>, "
# The Compose HINT observation unquoted — a different harness and a
# different verb, so the clause cannot be passing on one hardcoded arm.
ax_negative "$AX_KOTLIN" '(observed\.add\("ax hint )\\"\$want\\""' '$want"' \
    kotlin "$T/ax.kt" "the Compose ax-hint observation unquoted" \
    "^KayaCompose\.kt records the ax hint observation as ax hint <v>, "
# The FAILURE sentence half, on the third harness: the same value one
# line over, which a clause reading only the observation would miss.
ax_negative "$AX_HARNESS" '(Err\(format!\("ax )\{got:\?\}, wanted \{want:\?\}"\)\)' \
    '{got}, wanted {want}"))' \
    harness "$T/ax.rs" "the harness ax failure sentence unquoted" \
    "^harness\.rs refuses a mismatched ax with ax <v>, wanted <v>, "
# AND AN ARM THAT RECORDS NOTHING: an expect that appends no observation
# passes while verifying nothing, and its verdict compares against no one.
ax_negative "$AX_KOTLIN" '(observed\.add\("ax hint )\\"\$want\\""' 'ok"' \
    kotlin "$T/ax-silent.kt" "the Compose ax-hint observation made a fixed string" \
    "^KayaCompose\.kt records the ax hint observation as ax hint ok, "

# An ABSENT harness is a failure that NAMES IT, never a skip.
gone="$(ax_spelling "$AX_HARNESS" "$AX_SWIFT" "$T/no-such-ax.kt")"
case "$gone" in
    *"cannot read"*"KayaCompose.kt"*) ;;
    *)
        echo "check-verbs: SELF-TEST FAIL (an absent Kotlin harness failed the ax clause without naming it): $gone" >&2
        exit 1
        ;;
esac

# AND AN ARM THE CENSUS CANNOT FIND is a finding too: the shape this
# clause anchors on is exactly what moved out from under an earlier
# reader, which found ZERO observations in harness.rs and agreed with
# everything.
hits="$(perturb "$AX_HARNESS" '(Step::ExpectAx)\(target, want\) => Some\(poll\(' \
    '{ .. } => Some(poll(' "$T/ax-gone.rs")"
if [ "$hits" != 1 ]; then
    echo "check-verbs: SELF-TEST FAIL (the moved-arm perturbation applied $hits times, want 1)" >&2
    exit 1
fi
echo "check-verbs: ax-spelling self-test (the harness ax arm reshaped out of the census's reach) applied $hits substitution(s)"
drift="$(ax_spelling - "$AX_SWIFT" "$AX_KOTLIN" <"$T/ax-gone.rs")"
score="$(introduced "$drift" "$ax_out" "^harness\.rs has no ax arm the census can read")"
if [ "$score" != "1/1" ]; then
    echo "check-verbs: SELF-TEST FAIL (an unreadable ax arm scored $score named/introduced findings, want 1/1)" >&2
    exit 1
fi

# THE METRICS CLASS CHANNEL (docs/adaptive-layout-plan.md D8, ruled
# 2026-08-31): iOS is the ONE platform whose size class the platform
# itself decides, and the only route it reaches the core is
# KayaWindowMetricsReporter's report. NO LANE CAN SEE THE READ: the
# simulator pool is phones, where deriving from the width answers
# compact exactly as the platform does — a reporter that silently
# hardcoded NONE (or a mac arm that invented a class) is green on every
# leg and wrong on an iPad split view. So the reporter's block is held
# to the shape: the environment read present, both platform classes
# mapped, every report passing the DERIVED class, a re-report on class
# change, and the mac arm answering NONE alone. Beside it the RULED
# BOUNDARY is pinned at 600.0 (the ink tolerance's shape): the scenes
# hold it only to (560, 900] — portfolio.steps' 560 stack and the
# adaptive scene's 900 unstack — so a drift inside that band reddens
# nothing anywhere.
METRICS_SWIFT="swift/KayaSwiftUI.swift"
METRICS_WIRE="crates/kaya/src/wire.rs"

metrics_class() { # [swift wire]; either may be "-" for stdin
    python3 -c '
import re
import sys

SWIFT = "swift/KayaSwiftUI.swift"
WIRE = "crates/kaya/src/wire.rs"

srcs = sys.argv[1:] or [SWIFT, WIRE]
bad = []


def read(src, label):
    if src == "-":
        return sys.stdin.read()
    try:
        with open(src, encoding="utf-8") as f:
            return f.read()
    except OSError as e:
        bad.append(f"{label} cannot be read ({e}) — the metrics class channel is unverifiable, which is a failure and never a skip")
        return ""


swift = read(srcs[0], SWIFT)
wire = read(srcs[1], WIRE)

m = re.search(r"^struct KayaWindowMetricsReporter: ViewModifier \{$", swift, re.M)
if swift and not m:
    bad.append("KayaSwiftUI.swift has no KayaWindowMetricsReporter block this clause can read — the metrics class channel moved out from under it (a finding, never a skip)")
if m:
    tail = swift[m.end():]
    end = re.search(r"^\}$", tail, re.M)
    block = tail[: end.start()] if end else tail
    # Comments carry the rule words too (check-appearance: a guard named
    # in the PROSE beside its call passed a negative), so they go first.
    block = re.sub(r"//[^\n]*", "", block)
    if not re.search(r"@Environment\(\\\.horizontalSizeClass\)", block):
        bad.append("KayaWindowMetricsReporter never reads the environment horizontal size class — iOS then reports a class it never measured")
    if not re.search(r"case \.compact: return Int64\(KAYA_SIZE_CLASS_COMPACT\)", block):
        bad.append("KayaWindowMetricsReporter does not map .compact to KAYA_SIZE_CLASS_COMPACT — the platform class never reaches the core")
    if not re.search(r"case \.regular: return Int64\(KAYA_SIZE_CLASS_REGULAR\)", block):
        bad.append("KayaWindowMetricsReporter does not map .regular to KAYA_SIZE_CLASS_REGULAR — the platform class never reaches the core")
    if not re.search(r"\.onChange\(of: horizontalSizeClass\)", block):
        bad.append("KayaWindowMetricsReporter never re-reports on a size-class change — an iPad split drag that keeps the width moves no breakpoint")
    calls = re.findall(r"KayaHost\.windowMetrics\([^)]*\)", block)
    if not calls:
        bad.append("KayaWindowMetricsReporter never calls KayaHost.windowMetrics — the report this modifier exists for")
    for c in calls:
        if not re.search(r",\s*sizeClass\)$", c):
            bad.append(f"a KayaWindowMetricsReporter report does not pass the derived class: `{c}` — a literal there is the platform class silently dropped")
    prop = re.search(r"private var sizeClass: Int64 \{(.*?)\n    \}", block, re.S)
    if not prop:
        bad.append("KayaWindowMetricsReporter has no sizeClass property this clause can read (a finding, never a skip)")
    else:
        mac = re.search(r"#if os\(macOS\)(.*?)#else", prop.group(1), re.S)
        if not mac or "KAYA_SIZE_CLASS_NONE" not in mac.group(1):
            bad.append("KayaWindowMetricsReporter macOS arm does not answer KAYA_SIZE_CLASS_NONE — macOS has no platform class and must say so")
        elif re.search(r"KAYA_SIZE_CLASS_(COMPACT|REGULAR)", mac.group(1)):
            bad.append("KayaWindowMetricsReporter macOS arm names a real class — macOS has no platform class; the core derives from the width")

if wire and not re.search(r"pub const SIZE_CLASS_COMPACT_BELOW: f64 = 600\.0;", wire):
    bad.append("wire.rs does not pin SIZE_CLASS_COMPACT_BELOW at the ruled 600.0 — the scenes hold the boundary only to (560, 900], so a drift inside that band reddens nothing")

for b in bad:
    print(b)
sys.exit(1 if bad else 0)
' "$@"
}

metrics_status=0
metrics_out="$(metrics_class)" || {
    echo "check-verbs: the metrics class channel is broken — iOS reports its platform size class through KayaWindowMetricsReporter and NO lane can see that read (the phone pool answers compact by width too):" >&2
    echo "$metrics_out" >&2
    metrics_status=1
}

metrics_negative() { # <src slot: swift|wire> <pattern> <repl> <copy> <want-hits> <label> <finding regex>
    local hits drift score
    hits="$(perturb "$([ "$1" = swift ] && echo "$METRICS_SWIFT" || echo "$METRICS_WIRE")" "$2" "$3" "$4")"
    if [ "$hits" != "$5" ]; then
        echo "check-verbs: SELF-TEST FAIL (the $6 perturbation applied $hits times, want $5 — an unchanged copy cannot prove the rule fires)" >&2
        exit 1
    fi
    echo "check-verbs: metrics-class self-test ($6) applied $hits substitution(s)"
    if [ "$1" = swift ]; then
        drift="$(metrics_class - "$METRICS_WIRE" <"$4")"
    else
        drift="$(metrics_class "$METRICS_SWIFT" - <"$4")"
    fi
    score="$(introduced "$drift" "$metrics_out" "$7")"
    if [ "${score%%/*}" = 0 ] || [ "${score%%/*}" != "${score##*/}" ]; then
        echo "check-verbs: SELF-TEST FAIL ($6 scored $score named/introduced findings, want them equal and nonzero)" >&2
        exit 1
    fi
}

metrics_negative swift '(case \.compact: return Int64\(KAYA_SIZE_CLASS_)COMPACT\)' 'NONE)' \
    "$T/metrics-compact.swift" 1 "compact mapped to NONE" "does not map \.compact"
metrics_negative swift '(\.onChange\(of: horizontalSizeClass\) \{\n\s+KayaHost\.windowMetrics\(windowId, geo\.size, )sizeClass\)' \
    'Int64(KAYA_SIZE_CLASS_NONE))' "$T/metrics-literal.swift" 1 "one report passing a literal" \
    "does not pass the derived class"
metrics_negative swift '(\.onChange\(of: )horizontalSizeClass\)' 'geo.size)' \
    "$T/metrics-rereport.swift" 3 "the class re-report removed (3 structs share the pattern)" \
    "never re-reports on a size-class change"
metrics_negative swift '(#if os\(macOS\)\n\s+return Int64\(KAYA_SIZE_CLASS_)NONE\)' 'COMPACT)' \
    "$T/metrics-macarm.swift" 1 "the mac arm inventing a class" "macOS arm"
metrics_negative swift '(struct KayaWindowMetricsReporter: ViewModifier \{\n    let windowId: UInt64\n)    #if !os\(macOS\)\n        @Environment\(\\\.horizontalSizeClass\) private var horizontalSizeClass\n    #endif\n' \
    '' "$T/metrics-noenv.swift" 1 "the environment read deleted" "never reads the environment"
metrics_negative wire '(SIZE_CLASS_COMPACT_BELOW: f64 = )600\.0' '650.0' \
    "$T/metrics-boundary.rs" 1 "the ruled boundary drifted to 650" "ruled 600"

KAYA_CLIP_MIRRORS="$clip_status" KAYA_WINDOW_TIER="$window_status" \
    KAYA_AX_SPELLING="$ax_status" \
    KAYA_METRICS_CLASS="$metrics_status" \
    KAYA_INK_TOLERANCE="$ink_status" python3 - <<'EOF'
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

# --- Target kinds: the core's grammar, both interpreters' tables. ----
# EVERY KIND IS ADDRESSABLE, which is what makes a universal prop
# universal: expect_ax, expect_ax_hint, expect_inset, expect_fills and
# context_open all resolve a `kind@id` through ONE per-interpreter
# table, and a kind missing from that table answers "no such target"
# for all of them at once. Measured 2026-08-26: the canvas fan-out
# added KayaSceneModel.canvases and a private kayaCanvasTarget for the
# canvas verbs, and never added `canvas` to KayaCompose.kt's
# kayaWidgetTarget — so `expect_ax canvas@chart` could not resolve on
# that backend at all, and read in the log like a teardown after the
# step before it failed.
#
# READ OUT OF EACH TABLE'S OWN BLOCK, never grepped from the file: both
# interpreters spell the kind string in their canvas-only target helper
# too (`target(spec, "canvas", ...)`), so a file-wide pattern is
# satisfied by the helper and reports a table it never read — the
# check-sugar-surface trap one gate over.
def table_body(text, opener, closer, name):
    at = text.find(opener)
    if at < 0:
        fail(f"{name} has no `{opener}` — the target table this gate reads is "
             f"gone; re-point the clause at whatever replaced it")
        return None
    end = text.find(closer, at)
    if end < 0:
        fail(f"{name}'s `{opener}` block never closes with {closer!r}")
        return None
    return text[at:end]


TARGET_TABLES = (
    ("KayaSwiftUI.swift", swift, "private func kayaAnyTarget(", "\n}\n", 'case "{}"'),
    ("KayaCompose.kt", kotlin, "private fun kayaWidgetTarget(", "\n    }\n", '"{}" ->'),
)

kind_body = harness[
    harness.index("fn parse_target_kind(") : harness.index("fn parse_string(")
]
kinds = sorted(set(re.findall(r'"([a-z_]+)" => TargetKind::', kind_body)))
if len(kinds) < 10:
    fail(f"only {len(kinds)} target kinds read out of harness.rs parse_target_kind "
         f"— a census that reads nothing agrees with everything")


def missing_kinds(body, spelling):
    return [k for k in kinds if spelling.format(k) not in body]


for name, text, opener, closer, spelling in TARGET_TABLES:
    body = table_body(text, opener, closer, name)
    if body is None:
        continue
    for kind in missing_kinds(body, spelling):
        fail(
            f'target kind "{kind}" is in the core\'s parse_target_kind but not in '
            f"{name}'s {opener.split('(')[0].split()[-1]} table — every verb that "
            f'resolves a `kind@id` there answers "no such target {kind}@..." '
            f"whatever the scene does"
        )
    # WATCHED NEGATIVE, on every run: a census nobody has seen refuse is
    # a guess. The arm is cut out of a COPY of the block and the
    # substitution count is printed, because a perturbation that did not
    # apply is a failed test, not a passed one (invariant 3).
    victim = spelling.format(kinds[0])
    doctored, hits = re.subn(re.escape(victim), "", body)
    if hits < 1:
        fail(f"check-verbs SELF-TEST: the {name} target census could not perturb "
             f"{victim!r} — the pattern never matched, so the clause above "
             f"passed vacuously")
    elif not missing_kinds(doctored, spelling):
        fail(f"check-verbs SELF-TEST: {name}'s target census passed with "
             f"{victim!r} cut from the block ({hits} substitution(s))")
    else:
        print(f"check-verbs: self-test OK ({name} target census refuses "
              f"{victim!r} removed, {hits} substitution(s))")

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
if os.environ["KAYA_INK_TOLERANCE"] != "0":
    sys.exit(1)
if os.environ["KAYA_AX_SPELLING"] != "0":
    sys.exit(1)
if os.environ["KAYA_METRICS_CLASS"] != "0":
    sys.exit(1)
print(f"check-verbs: OK ({len(verbs)} verbs, {len(rows)} constants ({len(canvas_rows)} of them the canvas vocabularies) + the CLIP_* mirrors + the ink tolerance in 3 harnesses + the ax spelling in 3 harnesses + the windowed tier's loop + the metrics class channel + spec hash against 2 interpreters)")
EOF
