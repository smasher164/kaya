#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# The interpreter-coverage gate. The SwiftUI and Compose backends
# re-implement the harness verbs and carry private copies of the wire
# constants, string-matched rather than compile-checked. Every harness
# verb, every APPLY/KIND/PROP/COMMAND/MENU_KIND/MPROP constant with its
# value, and every value type reachable through the spec's PROPS must
# appear in BOTH interpreter files.

import re

g = Gate("check-verbs")

WIRE = "crates/kaya/src/wire.rs"
SWIFT = "swift/KayaSwiftUI.swift"
KOTLIN = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"
HARNESS = "crates/kaya/src/harness.rs"


def real(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def source_text(src, rel, bad, cannot_read):
    """One clause source: None reads the real file, a Path is read and
    a missing one appends `cannot_read` (a failure naming both sides,
    never a skip), a str IS the doctored text."""
    if src is None:
        return real(rel)
    if isinstance(src, pathlib.Path):
        try:
            return src.read_text(encoding="utf-8")
        except OSError as exc:
            bad.append(cannot_read(str(src), exc))
            return None
    return src


# --- THE CLIP MASKS: the vocabulary the sweep below cannot see. -------
#
# That sweep matches
# APPLY_|KIND_|PROP_|COMMAND_|VALUE_|MENU_KIND_|MPROP_ and stops, so
# wire.rs's five clip masks (BIT POSITIONS, not ordinals) are copied
# into both interpreters with nothing pinning either copy. NAME AND
# VALUE TOGETHER: a copy carrying all five names at four right values
# compiles, runs and ships one wrong kind.
#
# A FUNCTION, so the rule can be pointed at a PERTURBED copy of a
# mirror — the self-tests below.
def clip_mirrors(wire_src=None, swift_src=None, kotlin_src=None):
    bad = []

    def cannot(label):
        return lambda src, exc: ("cannot read " + src + " for " + label
                                 + " (" + str(exc.strerror)
                                 + "): the mirror this rule pins is "
                                   "not there")

    wire = source_text(wire_src, WIRE, bad, cannot(WIRE))
    swift = source_text(swift_src, SWIFT, bad, cannot(SWIFT))
    kotlin = source_text(kotlin_src, KOTLIN, bad, cannot(KOTLIN))

    rows = re.findall(r"pub(?:\(crate\))? const (CLIP_[A-Z_0-9]+): u\d+ = (\d+);",
                      wire or "")
    if wire is not None and not rows:
        bad.append("no CLIP_* constants extracted from " + WIRE
                   + ": the gate itself broke")

    for const, value in rows:
        camel = "".join(w.capitalize() for w in const.split("_")[1:])
        # Swift spells this family kaya-prefixed (`kayaClipImage`)
        # while its other wire mirrors drop the prefix (`applyCopy`),
        # so both pass.
        if swift is not None and not re.search(
                r"let (?:kayaClip" + camel + r"|clip" + camel
                + r")\b[^=\n]*=\s*" + value + r"\b", swift):
            bad.append(const + " = " + value + ": expected `let kayaClip"
                       + camel + " ... = " + value + "` in " + SWIFT)
        # Kotlin spells every wire mirror with the Rust name verbatim,
        # optionally typed. The lookahead rather than \b so a suffixed
        # literal (4u, 4L) counts while 4 still does not match 40.
        if kotlin is not None and not re.search(
                r"\b" + const + r"\b\s*(?::\s*\w+\s*)?=\s*" + value
                + r"(?![0-9])", kotlin):
            bad.append(const + " = " + value + ": expected `" + const
                       + " = " + value + "` in " + KOTLIN)
    return bad


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
#
# THE RULED NUMBER (2026-08-26). One unit is the macOS display-profile
# round trip; two is a different colour, and every failure expect_ink
# exists for — a dropped blit, a swizzle, an upside-down or wrongly
# sized blit — moves a channel by far more than either.
INK_RULED = 1

INK_MIRRORS = [
    ("harness.rs", HARNESS,
     r"const INK_TOLERANCE\s*:\s*\w+\s*=\s*(\d+)\s*;", "ink_matches"),
    ("KayaSwiftUI.swift", SWIFT,
     r"let kayaInkTolerance\b[^=\n]*=\s*(\d+)\b", "kayaInkMatches"),
    ("KayaCompose.kt", KOTLIN,
     r"\bINK_TOLERANCE\b\s*(?::\s*\w+\s*)?=\s*(\d+)(?![0-9])",
     "kayaInkMatches"),
]


def ink_tolerance(harness_src=None, swift_src=None, kotlin_src=None):
    bad = []
    for (label, rel, pattern, helper), src in zip(
            INK_MIRRORS, (harness_src, swift_src, kotlin_src)):
        text = source_text(
            src, rel, bad,
            lambda s, exc, label=label: (
                "cannot read " + s + " for " + label + " ("
                + str(exc.strerror) + "): the harness this rule pins "
                "is not there"))
        if text is None:
            continue
        m = re.search(pattern, text)
        if not m:
            bad.append(label + " declares no ink tolerance constant — "
                       "expect_ink there compares by some other rule "
                       "than the ruled +/-" + str(INK_RULED)
                       + " per channel (docs/canvas-plan.md 7.2)")
            continue
        if int(m.group(1)) != INK_RULED:
            bad.append(label + " sets its ink tolerance to "
                       + m.group(1) + ", not the ruled "
                       + str(INK_RULED)
                       + " — every expect_ink on that backend goes "
                         "quieter and no test anywhere reddens; "
                         "widening it is the maintainers call "
                         "(docs/canvas-plan.md 7.2)")
        if len(re.findall(r"\b" + helper + r"\b", text)) < 2:
            bad.append(label + " names " + helper + " once — the "
                       "tolerant compare is defined and never called, "
                       "so that arm still compares the bytes exactly "
                       "and the constant above is decoration")
    return bad


# --- THE AX OBSERVATION: three harnesses, one spelling. ---------------
#
# An observation is the byte-compared verdict text (invariant 6), and
# `expect_ax` was recorded TWO ways: harness.rs and KayaCompose.kt
# quote the value, KayaSwiftUI.swift left it bare, so the one verdict
# nothing compares across platforms was the accessibility one
# (docs/deferred.md). RULED QUOTED 2026-08-27: two of the three already
# spelled it that way, harness.rs is the norm the interpreters follow,
# and the bare form has no measured reason — it is just the original
# mac depth slice (b560753) never revisited. The quotes are also what
# make a placeholder answer like <not in the accessibility tree> read
# as a VALUE rather than as prose.
#
# NO LANE CAN FAIL THIS. Every runner greps the verdict for
# `KAYA_SELFTEST: OK` and never diffs its text (validate-mac.py:622,
# run-emulator.py, run-sim.py, run-suites.sh), so the spellings can
# disagree forever with every leg green — which is exactly how they
# did.
#
# The census reads each emitter out of its OWN ARM rather than
# grepping the file: `Step::ExpectAx(` alone matches harness.rs`s
# PARSER twice before it reaches the step arm, and a reader anchored on
# the name found ZERO observations there and agreed with everything.
AX_OBS = {"ax": 'ax "<v>"', "ax hint": 'ax hint "<v>"'}
AX_WANTED = {"ax": 'ax "<v>", wanted "<v>"',
             "ax hint": 'ax hint "<v>", wanted "<v>"'}

AX_HARNESSES = [
    ("harness.rs", HARNESS, "rust",
     [("ax", r"Step::ExpectAx\([^()]*\) => Some\(poll\(",
       "\n            Step::"),
      ("ax hint", r"Step::ExpectAxHint\([^()]*\) => Some\(poll\(",
       "\n            Step::")],
     r"Ok\(format!\(", r"Err\(format!\("),
    ("KayaSwiftUI.swift", SWIFT, "swift",
     [("ax", 'case "expect_ax":', "\n            case "),
      ("ax hint", 'case "expect_ax_hint":', "\n            case ")],
     r"observed\.append\(", r"failures\.append\("),
    ("KayaCompose.kt", KOTLIN, "kotlin",
     [("ax", '"expect_ax" ->', '\n                    "'),
      ("ax hint", '"expect_ax_hint" ->', '\n                    "')],
     r"observed\.add\(", r"failures\.add\("),
]


def ax_arm(text, opener, terminator):
    m = re.search(opener, text)
    if not m:
        return None
    end = text.find(terminator, m.end())
    return text[m.start():end if end > 0 else len(text)]


def ax_calls(body, opener):
    """Every <opener>(...) call in the arm, balanced to its closing
    paren."""
    out = []
    for m in re.finditer(opener, body):
        i, depth = m.end(), 1
        while i < len(body) and depth:
            c = body[i]
            if c == '"':
                i += 1
                while i < len(body) and body[i] != '"':
                    i += 2 if body[i] == "\\" else 1
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            i += 1
        out.append(body[m.end():i - 1])
    return out


def ax_literals(call):
    """The string literals of a call in order, escapes preserved. A
    Kotlin or Swift sentence spliced with + is read as one."""
    out, i = [], 0
    while i < len(call):
        if call[i] == '"':
            j, buf = i + 1, []
            while j < len(call) and call[j] != '"':
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


def ax_flatten(lang, text):
    if lang == "rust":
        # Debug ({x:?}) prints a String WITH quotes; Display does not.
        return re.sub(r"\{([^{}]*)\}",
                      lambda m: '"<v>"' if m.group(1).endswith(":?")
                      else "<v>", text)
    if lang == "swift":
        return re.sub(r"\\\((?:[^()]|\([^()]*\))*\)|\\(.)",
                      lambda m: "<v>" if m.group(1) is None
                      else m.group(1), text)
    text = re.sub(r"\\(.)", lambda m: m.group(1), text)
    return re.sub(r"\$\{[^{}]*\}|\$[A-Za-z_][A-Za-z0-9_.]*", "<v>",
                  text)


def ax_spelling(harness_src=None, swift_src=None, kotlin_src=None):
    bad = []
    seen = 0

    def spelling(lang, call):
        return "".join(ax_flatten(lang, lit) for lit in
                       ax_literals(call))

    for (label, rel, lang, arms, record, refuse), src in zip(
            AX_HARNESSES, (harness_src, swift_src, kotlin_src)):
        text = source_text(
            src, rel, bad,
            lambda s, exc, label=label: (
                "cannot read " + s + " for " + label + " ("
                + str(exc.strerror) + "): the harness this rule holds "
                "one spelling across is not there"))
        if text is None:
            continue
        for verb, opener, terminator in arms:
            body = ax_arm(text, opener, terminator)
            if body is None:
                bad.append(label + " has no " + verb + " arm the "
                           "census can read — the shape this clause "
                           "anchors on moved; re-point it rather than "
                           "letting the spelling go unwatched")
                continue
            records = ax_calls(body, record)
            if not records:
                bad.append(label + " records nothing in its " + verb
                           + " arm — an expect that records nothing "
                             "passes without verifying anything, and "
                             "its verdict compares against no one")
            for call in records:
                seen += 1
                got = spelling(lang, call)
                if got != AX_OBS[verb]:
                    bad.append(label + " records the " + verb
                               + " observation as " + got
                               + ", not the ruled " + AX_OBS[verb]
                               + " — the observation IS the "
                                 "byte-compared verdict text, and no "
                                 "lane diffs it, so two spellings sit "
                                 "green forever (docs/deferred.md)")
            sentences = [s for s in (spelling(lang, c)
                                     for c in ax_calls(body, refuse))
                         if "wanted" in s]
            if not sentences:
                bad.append(label + " never refuses a mismatched "
                           + verb + " with a sentence naming what it "
                             "wanted — the comparison this verb exists "
                             "for has no failure text")
            for got in sentences:
                if not got.startswith(AX_WANTED[verb]):
                    bad.append(label + " refuses a mismatched " + verb
                               + " with " + got + ", which does not "
                                 "open with the ruled "
                               + AX_WANTED[verb] + " — the same "
                                 "value, spelled two ways one line "
                                 "apart")

    # A census that reads nothing agrees with everything.
    if not bad and seen < 6:
        bad.append("only " + str(seen) + " ax observations found "
                   "across three harnesses — the reader is matching "
                   "almost nothing and would pass any spelling")
    return bad


# --- THE WINDOWED TIER'S LOOP: three links no scene can see. ----------
#
# docs/virtualization-plan.md §3/§4. The Compose tier windows its
# tables — spacer, realized band, spacer, inside its own scroll
# container — and THREE OF THE FOUR LINKS IN THAT LOOP ARE INVISIBLE TO
# THE ONE SCENE THAT DRIVES IT. Measured 2026-08-25 on a real emulator,
# each perturbation watched:
#
#   * the visible-range report deleted from the report loop:
#     windowed.steps stays GREEN, because scroll_to_row moves the band
#     itself and nothing else in the scene ever scrolls;
#   * the measured-extent report deleted: GREEN — a height moves the
#     ARITHMETIC and never the band (the mac tier measured the same);
#   * both spacers zeroed: GREEN — expect_window reads the row at the
#     viewport's top, and a tier that lays its rows out at the wrong y
#     is internally consistent about which row that is.
#
# So they are held HERE, the way check-native-undo holds a pair no
# scene can fail. The SwiftUI half of the same loop lives in
# tools/check-table-tier.py, which reads the mac driver.
def window_tier(kotlin_src=None):
    bad = []
    if kotlin_src is None:
        text = real(KOTLIN)
    elif isinstance(kotlin_src, pathlib.Path):
        try:
            text = kotlin_src.read_text(encoding="utf-8")
        except OSError as exc:
            return [f"cannot read {kotlin_src} for {KOTLIN} "
                    f"({exc.strerror}): the interpreter this clause "
                    f"reads is not there"]
    else:
        text = kotlin_src

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
        bad.append("KayaCompose.kt has no `fun report()` — the "
                   "windowed tiers report loop moved, and this clause "
                   "is blind; re-point it")
    else:
        for call, why in (
            ("KayaPresent.windowMoved(",
             "the visible range never reaches the core, so the band "
             "never follows the viewport (scroll_to_row moves it on "
             "its own, which is why the scene stays green)"),
            ("KayaPresent.rowsMeasured(",
             "the core never learns a row height, so its pitch, its "
             "extent and both spacers stay 0 with every scene still "
             "green"),
            ("KayaPresent.rowExtent(",
             "the height report loses its EXACT comparison and either "
             "repeats every turn or never fires"),
        ):
            if call not in report:
                bad.append("`fun report()` in KayaCompose.kt never "
                           "calls `" + call + "` — " + why)

    surface = body("private fun KayaTableSurface(")
    if surface is None:
        bad.append("KayaCompose.kt has no `private fun "
                   "KayaTableSurface(` — the windowed tier moved, and "
                   "this clause is blind; re-point it")
    else:
        for pin, why in (
            ("val offsetPx = window.offsetPx",
             "the bands top stops being the core s offset"),
            ("val extentPx = window.extentPx",
             "the collection s height stops being the core s extent"),
            ("kayaWindowSpacers(offsetPx, extentPx, bandH, tail)",
             "the two spacers stop being one function of those two "
             "numbers"),
            # kayaFixedRepresentable since 2026-08-28: the same fixed
            # constraints wherever they are representable, clamped
            # only past Compose s packing edge (the zero-width
            # portfolio mount threw; docs/deferred.md s
            # portfolio-android entry). The third pin holds the helper
            # honest: fitPrioritizingWidth IS the identity on every
            # representable input, so the spacer link survives.
            ("kayaFixedRepresentable(totalW, spacers.first)",
             "the TOP spacer stops being that function s answer"),
            ("kayaFixedRepresentable(totalW, spacers.second)",
             "the BOTTOM spacer stops being that function s answer"),
            ("Constraints.fitPrioritizingWidth(w, w, "
             "h.coerceAtLeast(0), h.coerceAtLeast(0))",
             "kayaFixedRepresentable stops being the representability "
             "clamp"),
        ):
            if pin not in surface:
                bad.append("KayaTableSurface does not spell `" + pin
                           + "` — " + why + ", and no scene can see "
                             "it (measured: both spacers zeroed left "
                             "windowed.steps green)")
    return bad


# --- THE METRICS CLASS CHANNEL (docs/adaptive-layout-plan.md D8, ruled
# 2026-08-31): iOS is the ONE platform whose size class the platform
# itself decides, and the only route it reaches the core is
# KayaWindowMetricsReporter's report. NO LANE CAN SEE THE READ: the
# simulator pool is phones, where deriving from the width answers
# compact exactly as the platform does — a reporter that silently
# hardcoded NONE (or a mac arm that invented a class) is green on
# every leg and wrong on an iPad split view. So the reporter's block is
# held to the shape: the environment read present, both platform
# classes mapped, every report passing the DERIVED class, a re-report
# on class change, and the mac arm answering NONE alone. Beside it the
# RULED BOUNDARY is pinned at 600.0 (the ink tolerance's shape): the
# scenes hold it only to (560, 900] — portfolio.steps' 560 stack and
# the adaptive scene's 900 unstack — so a drift inside that band
# reddens nothing anywhere.
def metrics_class(swift_src=None, wire_src=None):
    bad = []

    def read_src(src, rel):
        if src is None:
            src = ROOT / rel
        if isinstance(src, pathlib.Path):
            try:
                return src.read_text(encoding="utf-8")
            except OSError as e:
                bad.append(f"{rel} cannot be read ({e}) — the metrics "
                           f"class channel is unverifiable, which is a "
                           f"failure and never a skip")
                return ""
        return src

    swift = read_src(swift_src, SWIFT)
    wire = read_src(wire_src, WIRE)

    m = re.search(r"^struct KayaWindowMetricsReporter: ViewModifier "
                  r"\{$", swift, re.M)
    if swift and not m:
        bad.append("KayaSwiftUI.swift has no KayaWindowMetricsReporter "
                   "block this clause can read — the metrics class "
                   "channel moved out from under it (a finding, never "
                   "a skip)")
    if m:
        tail = swift[m.end():]
        end = re.search(r"^\}$", tail, re.M)
        block = tail[: end.start()] if end else tail
        # Comments carry the rule words too (check-appearance: a guard
        # named in the PROSE beside its call passed a negative), so
        # they go first.
        block = re.sub(r"//[^\n]*", "", block)
        if not re.search(r"@Environment\(\\\.horizontalSizeClass\)",
                         block):
            bad.append("KayaWindowMetricsReporter never reads the "
                       "environment horizontal size class — iOS then "
                       "reports a class it never measured")
        if not re.search(r"case \.compact: return "
                         r"Int64\(KAYA_SIZE_CLASS_COMPACT\)", block):
            bad.append("KayaWindowMetricsReporter does not map "
                       ".compact to KAYA_SIZE_CLASS_COMPACT — the "
                       "platform class never reaches the core")
        if not re.search(r"case \.regular: return "
                         r"Int64\(KAYA_SIZE_CLASS_REGULAR\)", block):
            bad.append("KayaWindowMetricsReporter does not map "
                       ".regular to KAYA_SIZE_CLASS_REGULAR — the "
                       "platform class never reaches the core")
        if not re.search(r"\.onChange\(of: horizontalSizeClass\)",
                         block):
            bad.append("KayaWindowMetricsReporter never re-reports on "
                       "a size-class change — an iPad split drag that "
                       "keeps the width moves no breakpoint")
        calls = re.findall(r"KayaHost\.windowMetrics\([^)]*\)", block)
        if not calls:
            bad.append("KayaWindowMetricsReporter never calls "
                       "KayaHost.windowMetrics — the report this "
                       "modifier exists for")
        for c in calls:
            if not re.search(r",\s*sizeClass\)$", c):
                bad.append(f"a KayaWindowMetricsReporter report does "
                           f"not pass the derived class: `{c}` — a "
                           f"literal there is the platform class "
                           f"silently dropped")
        prop = re.search(r"private var sizeClass: Int64 \{(.*?)\n    \}",
                         block, re.S)
        if not prop:
            bad.append("KayaWindowMetricsReporter has no sizeClass "
                       "property this clause can read (a finding, "
                       "never a skip)")
        else:
            mac = re.search(r"#if os\(macOS\)(.*?)#else",
                            prop.group(1), re.S)
            if not mac or "KAYA_SIZE_CLASS_NONE" not in mac.group(1):
                bad.append("KayaWindowMetricsReporter macOS arm does "
                           "not answer KAYA_SIZE_CLASS_NONE — macOS "
                           "has no platform class and must say so")
            elif re.search(r"KAYA_SIZE_CLASS_(COMPACT|REGULAR)",
                           mac.group(1)):
                bad.append("KayaWindowMetricsReporter macOS arm names "
                           "a real class — macOS has no platform "
                           "class; the core derives from the width")

    if wire and not re.search(
            r"pub(?:\(crate\))? const SIZE_CLASS_COMPACT_BELOW: f64 = 600\.0;",
            wire):
        bad.append("wire.rs does not pin SIZE_CLASS_COMPACT_BELOW at "
                   "the ruled 600.0 — the scenes hold the boundary "
                   "only to (560, 900], so a drift inside that band "
                   "reddens nothing")
    return bad



# --- THE VERB TRACE: one ring, three harnesses ------------------------
#
# crates/kaya/src/vtrace.rs keeps what every harness verb did, attempt
# by attempt, and writes it ONLY WHEN THE RUN FAILS to the file
# KAYA_VERB_TRACE names. The two interpreter harnesses re-implement it
# by hand (KayaVTrace in swift/KayaSwiftUI.swift and KayaCompose.kt),
# and a hand-copied diagnostic with no compile-time link is the drift
# class that let the ax observation sit spelled two ways for months
# (docs/deferred.md, the flight recorder's BUILD entry). NO LANE CAN
# SEE IT: the file is read by a human after a failure, so a ring whose
# line shape drifted, or whose dump crept onto the pass path, reddens
# nothing. So this holds, per harness: the env var by name, the four
# line shapes compared FLATTENED (interpolation to <v>), exactly two
# dump sites — one in the script runner AFTER the green verdict's text
# and BEFORE the publish, one on the watchdog's fire path right before
# its exit primitive — and none anywhere else.
VTRACE = "crates/kaya/src/vtrace.rs"
VTRACE_ENV = '"KAYA_VERB_TRACE"'
VTRACE_LINES = [
    "KAYA_VERB_TRACE: dump reason=<v> t=<v> records=<v> dropped=<v> "
    "steps=<v>",
    "KAYA_VERB_TRACE: step=<v> text=<v>",
    "KAYA_VERB_TRACE: t=<v> step=<v> verb=<v> try=<v> what=<v>",
    "KAYA_HARNESS: verb trace (<v> records, <v> dropped) appended to <v>",
]
# (label, lang, ring file, runner file, dump-call regex,
#  runner (opener, closer), publish regex, fire-path exit regex)
VTRACE_HARNESSES = [
    ("harness.rs", "rust", VTRACE, HARNESS, r"vtrace::dump\(",
     (r"fn run_with_log\(", "\n}"), r"watch\.published\(",
     r"harness_exit\("),
    ("KayaSwiftUI.swift", "swift", SWIFT, SWIFT, r"KayaVTrace\.dump\(",
     (r"private func kayaRunScript\(", "\n}"), r"watchdog\.published\(",
     r"_exit\(1\)"),
    ("KayaCompose.kt", "kotlin", KOTLIN, KOTLIN, r"KayaVTrace\.dump\(",
     (r"private fun runScript\(", "\n    }"), r"watchdog\.published\(",
     r"\.halt\(1\)"),
]
VTRACE_OK = "KAYA_SELFTEST: OK"


def vtrace_flat(lang, text):
    """The ax flattener plus the ceiling gate's splice rule: one line
    shape written three ways is one string once the interpolation is
    <v> and the `+` splices and line breaks are gone."""
    text = re.sub(r"\\\n\s*", "", text)
    text = re.sub(r'"\s*\+\s*"', "", text)
    text = ax_flatten(lang, text)
    return re.sub(r"\s+", " ", text)


def verb_trace(harness_src=None, swift_src=None, kotlin_src=None,
               vtrace_src=None):
    bad = []
    for (label, lang, ring_rel, runner_rel, dump_pat, runner, publish_pat,
         exit_pat), src in zip(VTRACE_HARNESSES,
                               (harness_src, swift_src, kotlin_src)):
        ring_src = vtrace_src if lang == "rust" else src
        ring = source_text(
            ring_src, ring_rel, bad,
            lambda s, exc, label=label: (
                "cannot read " + s + " for " + label + "\'s verb trace ("
                + str(exc.strerror) + "): the ring this rule holds level "
                "is not there"))
        runner_text = source_text(
            src, runner_rel, bad,
            lambda s, exc, label=label: (
                "cannot read " + s + " for " + label + "\'s verb trace ("
                + str(exc.strerror) + "): the runner this rule holds "
                "level is not there"))
        if ring is None or runner_text is None:
            continue
        # The Rust runner's unit tests drive the ring too; the sites this
        # clause counts are the shipped ones, above the test module.
        runner_text = runner_text.split("\n#[cfg(test)]", 1)[0]
        if VTRACE_ENV not in ring:
            bad.append(f"{ring_rel} never names {VTRACE_ENV}: the ring "
                       f"reads its file from a variable of another name, "
                       f"or from none, and a runner setting the ruled one "
                       f"gets no trace")
        flat = vtrace_flat(lang, ring)
        for line in VTRACE_LINES:
            if line not in flat:
                bad.append(f"{ring_rel} does not carry the verb-trace line "
                           f"shape {line!r} the other rings carry — one "
                           f"trace reads one way everywhere, or a reader "
                           f"written against one harness misparses the "
                           f"other two")
        calls = [m.start() for m in re.finditer(dump_pat, runner_text)]
        # THE CRASH SITE: an uncaught NSException ends a SwiftUI run
        # before either dump, so its handler dumps too — the one third
        # site allowed, and only inside that handler's own block.
        crash = [c for c in calls
                 if runner_text.rfind("NSSetUncaughtExceptionHandler", 0, c) >= 0
                 and c - runner_text.rfind("NSSetUncaughtExceptionHandler", 0, c) < 300]
        calls = [c for c in calls if c not in crash]
        if len(crash) > 1 or (crash and lang != "swift"):
            bad.append(f"{runner_rel} dumps the verb trace from "
                       f"{len(crash)} uncaught-exception handler(s) — one, "
                       f"and only where NSException exists")
        if len(calls) != 2:
            bad.append(f"{runner_rel} has {len(calls)} verb-trace dump "
                       f"site(s), want exactly 2 (the failed verdict and "
                       f"the watchdog's fire path): a third is a dump on "
                       f"a path that is not a failure, a first-or-only is "
                       f"a wedge or a red verdict that leaves no trace")
            continue
        opener, closer = runner
        head = re.search(opener, runner_text)
        if head is None:
            bad.append(f"{runner_rel} has no script runner matching "
                       f"{opener!r} — re-point this clause rather than "
                       f"weaken it")
            continue
        end = runner_text.find(closer, head.end())
        body_start, body_end = head.start(), (end if end >= 0
                                              else len(runner_text))
        inside = [c for c in calls if body_start <= c < body_end]
        outside = [c for c in calls if not body_start <= c < body_end]
        if len(inside) != 1 or len(outside) != 1:
            bad.append(f"{runner_rel}: {len(inside)} dump site(s) inside "
                       f"the script runner and {len(outside)} outside it, "
                       f"want one of each (the failed verdict, and the "
                       f"watchdog's fire path)")
            continue
        body = runner_text[body_start:body_end]
        at = inside[0] - body_start
        ok_at = body.rfind(VTRACE_OK)
        if ok_at < 0 or ok_at > at:
            bad.append(f"{runner_rel}: the runner's dump site sits BEFORE "
                       f"the green verdict's text, so a passing run would "
                       f"write a trace — the rule is failure only")
        publish = re.search(publish_pat, body[at:])
        if publish is None:
            bad.append(f"{runner_rel}: no {publish_pat!r} follows the "
                       f"runner's dump site — after the publish the "
                       f"watchdog may end the process at any moment, so "
                       f"the dump must precede it")
        elif VTRACE_OK in body[at:at + publish.start()]:
            bad.append(f"{runner_rel}: the green verdict's text sits "
                       f"between the runner's dump site and the publish "
                       f"— the dump is on the pass path")
        fire = runner_text[outside[0]:outside[0] + 1200]
        if not re.search(exit_pat, fire):
            bad.append(f"{runner_rel}: the watchdog's dump site is not "
                       f"followed by its exit primitive {exit_pat!r} "
                       f"within the fire path — a trace dumped somewhere "
                       f"the process does not leave is a trace on a "
                       f"path that is not the wedge")
        elif VTRACE_OK in fire[:re.search(exit_pat, fire).start()]:
            bad.append(f"{runner_rel}: the green verdict's text sits "
                       f"between the watchdog's dump site and its exit")
    return bad

# --- the real clauses, run first so a missing mirror reports as one --
window_out = window_tier()
window_status = 1 if window_out else 0
if window_out:
    print("check-verbs: the Compose windowed tier is missing a link "
          "of its own report loop, and no scene can see it "
          "(docs/virtualization-plan.md §3/§4):", file=sys.stderr)
    print("\n".join(window_out), file=sys.stderr)

ink_out = ink_tolerance()
ink_status = 1 if ink_out else 0
if ink_out:
    print("check-verbs: the expect_ink tolerance does not match the "
          "ruling — three harnesses hand-copy that number and nothing "
          "compiles them against each other, so a widened copy makes "
          "every ink assertion quieter with no lane the wiser "
          "(docs/canvas-plan.md §7.2):", file=sys.stderr)
    print("\n".join(ink_out), file=sys.stderr)

ax_out = ax_spelling()
ax_status = 1 if ax_out else 0
if ax_out:
    print("check-verbs: the ax observation is spelled more than one "
          "way — that text IS the byte-compared verdict and every "
          "lane only greps it for PASS, so the spellings can disagree "
          "forever with every leg green (docs/deferred.md):",
          file=sys.stderr)
    print("\n".join(ax_out), file=sys.stderr)

clip_out = clip_mirrors()
clip_status = 1 if clip_out else 0
if clip_out:
    print("check-verbs: the CLIP_* mirrors do not match "
          "crates/kaya/src/wire.rs — both interpreters carry PRIVATE "
          "copies and nothing else pins them, so a drifted value "
          "ships a wrong clip kind silently:", file=sys.stderr)
    print("\n".join(clip_out), file=sys.stderr)

vtrace_out = verb_trace()
vtrace_status = 1 if vtrace_out else 0
if vtrace_out:
    print("check-verbs: the verb trace is not one ring in three "
          "harnesses — the file is read by a human after a failure, so "
          "a drifted line shape or a dump on the pass path reddens no "
          "lane (docs/deferred.md, the flight recorder entry):",
          file=sys.stderr)
    print("\n".join(vtrace_out), file=sys.stderr)

metrics_out = metrics_class()
metrics_status = 1 if metrics_out else 0
if metrics_out:
    print("check-verbs: the metrics class channel is broken — iOS "
          "reports its platform size class through "
          "KayaWindowMetricsReporter and NO lane can see that read "
          "(the phone pool answers compact by width too):",
          file=sys.stderr)
    print("\n".join(metrics_out), file=sys.stderr)


# THE GUARD GUARDS ITSELF, in both directions and on BOTH mirrors,
# perturbing the REAL file rather than a fixture (docs/traps.md: the
# wayland seat guard's negative test passed VACUOUSLY TWICE).
#
# A PERTURBATION THAT DID NOT APPLY PROVES NOTHING, so the substitution
# count is printed and checked before the copy is used — the prelude's
# doctor does both.
#
# AND THE REFUSAL IS SCORED, NOT JUST COUNTED: an exit code alone is
# satisfied by any unrelated finding. Each half scores what the
# perturbation INTRODUCED over the real check's own findings —
# `named/total`, and the only passing score is 1/1. Left is the
# refusal, right is the accept direction. Baseline-relative, so a
# genuinely drifted mirror does not report as a broken guard. A clause
# that simply PASSED the drifted copy scores 0/0 and fails the same
# way.
def perturb(label, rel, pattern, repl, want=1):
    """A doctored COPY of a real file's text: the matched group 1 plus
    the literal `repl` (a lambda, never a template, so a backslash in
    the replacement stays a backslash)."""
    return g.doctor(label, real(rel), pattern,
                    lambda m: m.group(1) + repl, want=want)


def introduced(drift, baseline, pattern):
    base = set(line for line in baseline if line.strip())
    new = [line for line in drift if line.strip() and line not in base]
    named = [line for line in new if re.search(pattern, line)]
    return f"{len(named)}/{len(new)}"


def score_or_die(score, label):
    if score != "1/1":
        print(f"check-verbs: SELF-TEST FAIL ({label} scored {score} "
              f"named/introduced findings, want 1/1)", file=sys.stderr)
        raise SystemExit(1)


drifted = perturb("the kayaClipImage drift", SWIFT,
                  r"(let kayaClipImage\b[^=\n]*=\s*)4\b", "5")
score_or_die(introduced(clip_mirrors(swift_src=drifted), clip_out,
                        r"^CLIP_IMAGE = 4: expected .* in "
                        r"swift/KayaSwiftUI\.swift$"),
             "drifting kayaClipImage to 5")

# The Kotlin half, a DIFFERENT constant so neither half can be passing
# on a hardcoded one. The modifier is not part of the rule, so the
# perturbation matches from the name on.
drifted = perturb("the CLIP_FILES drift", KOTLIN,
                  r"(\bCLIP_FILES\b\s*(?::\s*\w+\s*)?=\s*)8\b", "9")
score_or_die(introduced(clip_mirrors(kotlin_src=drifted), clip_out,
                        r"^CLIP_FILES = 8: expected .* in "
                        r".*KayaCompose\.kt$"),
             "drifting CLIP_FILES to 9")

# AND THE INK TOLERANCE'S OWN, all THREE harnesses, each widened to 2
# on a copy — the drift that matters here is the one that moves every
# copy the same way, so each is watched being refused on its own.
for slot, rel, pattern, finding in (
    ("harness", HARNESS,
     r"(const INK_TOLERANCE\s*:\s*\w+\s*=\s*)1\b",
     r"^harness\.rs sets its ink tolerance to 2, "),
    ("swift", SWIFT, r"(let kayaInkTolerance\b[^=\n]*=\s*)1\b",
     r"^KayaSwiftUI\.swift sets its ink tolerance to 2, "),
    ("kotlin", KOTLIN,
     r"(\bINK_TOLERANCE\b\s*(?::\s*\w+\s*)?=\s*)1(?![0-9])",
     r"^KayaCompose\.kt sets its ink tolerance to 2, "),
):
    drifted = perturb(f"ink-tolerance ({slot} widened to 2)", rel,
                      pattern, "2")
    kwargs = {f"{'harness' if slot == 'harness' else slot}_src":
              drifted}
    score_or_die(introduced(ink_tolerance(**kwargs), ink_out, finding),
                 f"widening {slot}'s ink tolerance to 2")

# AND A TOLERANCE NOTHING CALLS: the constant alone is decoration, and
# the arm beside it still compares the bytes exactly.
drifted = perturb("ink-tolerance (the Compose arm put back to an "
                  "exact compare)", KOTLIN,
                  r"(if \()kayaInkMatches\(got, want\)", "got == want")
score_or_die(introduced(ink_tolerance(kotlin_src=drifted), ink_out,
                        r"^KayaCompose\.kt names kayaInkMatches once"),
             "an uncalled tolerant compare")

# An ABSENT harness is a failure that NAMES IT, never a skip.
gone = ink_tolerance(kotlin_src=g.scratch() / "no-such-harness.kt")
if not any("cannot read" in b and "KayaCompose.kt" in b for b in gone):
    print("check-verbs: SELF-TEST FAIL (an absent Kotlin harness "
          "failed the ink clause without naming it): "
          + "\n".join(gone), file=sys.stderr)
    raise SystemExit(1)

# An ABSENT mirror is a failure that NAMES IT, never a skip.
gone = clip_mirrors(kotlin_src=g.scratch() / "no-such-mirror.kt")
if not any("cannot read" in b and "KayaCompose.kt" in b for b in gone):
    print("check-verbs: SELF-TEST FAIL (an absent Kotlin mirror "
          "failed without naming it): " + "\n".join(gone),
          file=sys.stderr)
    raise SystemExit(1)

# AND THE WINDOWED TIER'S OWN, the same shape: the three perturbations
# that were WATCHED staying green on a real emulator must be red here.
for pattern, repl, label, finding in (
    (r"(\n            )KayaPresent\.windowMoved\(node\.id, "
     r"first\.toLong\(\), count\.toLong\(\)\)", "",
     "the range report removed from the report loop",
     "never calls `KayaPresent.windowMoved("),
    (r"(\n            if \(moved\) )KayaPresent\.rowsMeasured\("
     r"node\.id, laidOutFirst\.toLong\(\), heights\)", "Unit",
     "the height report removed from the report loop",
     "never calls `KayaPresent.rowsMeasured("),
    (r"(\n        val spacers = )kayaWindowSpacers\(offsetPx, "
     r"extentPx, bandH, tail\)", "Pair(0, 0)",
     "both spacers cut tier-side instead of from the core",
     "does not spell `kayaWindowSpacers(offsetPx, extentPx, bandH, "
     "tail)`"),
):
    drifted = perturb(f"windowed-tier ({label})", KOTLIN, pattern, repl)
    drift = window_tier(kotlin_src=drifted)
    if not drift:
        print(f"check-verbs: SELF-TEST FAIL ({label} passed the "
              f"windowed-tier clause)", file=sys.stderr)
        raise SystemExit(1)
    if not any(finding in b for b in drift):
        print(f"check-verbs: SELF-TEST FAIL ({label} reddened, but did "
              f"not name \"{finding}\"): " + "\n".join(drift),
              file=sys.stderr)
        raise SystemExit(1)

# An ABSENT interpreter is a failure that names it, never a skip.
gone = window_tier(kotlin_src=g.scratch() / "no-such-interpreter.kt")
if not gone:
    print("check-verbs: SELF-TEST FAIL (an absent Kotlin interpreter "
          "passed the windowed-tier clause)", file=sys.stderr)
    raise SystemExit(1)
if not any("no-such-interpreter.kt" in b for b in gone):
    print("check-verbs: SELF-TEST FAIL (an absent Kotlin interpreter "
          "failed without naming it): " + "\n".join(gone),
          file=sys.stderr)
    raise SystemExit(1)

# AND THE AX SPELLING'S OWN. The observation and the failure sentence
# are perturbed SEPARATELY, and on two different harnesses, so neither
# half can be passing on a hardcoded one — and the bare form each puts
# back is the one that actually shipped (docs/deferred.md).
for rel, pattern, repl, slot, label, finding in (
    # The SwiftUI observation put back to the bare form it shipped
    # with.
    (SWIFT, r'(observed\.append\("ax )\\"\\\(wantAx\)\\""',
     '\\(wantAx)"', "swift",
     "the mac ax observation put back to the bare form",
     r"^KayaSwiftUI\.swift records the ax observation as ax <v>, "),
    # The Compose HINT observation unquoted — a different harness and
    # a different verb, so the clause cannot be passing on one
    # hardcoded arm.
    (KOTLIN, r'(observed\.add\("ax hint )\\"\$want\\""', '$want"',
     "kotlin", "the Compose ax-hint observation unquoted",
     r"^KayaCompose\.kt records the ax hint observation as "
     r"ax hint <v>, "),
    # The FAILURE sentence half, on the third harness: the same value
    # one line over, which a clause reading only the observation would
    # miss.
    (HARNESS, r'(Err\(format!\("ax )\{got:\?\}, wanted \{want:\?\}"\)\)',
     '{got}, wanted {want}"))', "harness",
     "the harness ax failure sentence unquoted",
     r"^harness\.rs refuses a mismatched ax with ax <v>, "
     r"wanted <v>, "),
    # AND AN ARM THAT RECORDS NOTHING: an expect that appends no
    # observation passes while verifying nothing, and its verdict
    # compares against no one.
    (KOTLIN, r'(observed\.add\("ax hint )\\"\$want\\""', 'ok"',
     "kotlin", "the Compose ax-hint observation made a fixed string",
     r"^KayaCompose\.kt records the ax hint observation as "
     r"ax hint ok, "),
):
    drifted = perturb(f"ax-spelling ({label})", rel, pattern, repl)
    kwargs = {f"{slot}_src": drifted}
    score_or_die(introduced(ax_spelling(**kwargs), ax_out, finding),
                 label)

# An ABSENT harness is a failure that NAMES IT, never a skip.
gone = ax_spelling(kotlin_src=g.scratch() / "no-such-ax.kt")
if not any("cannot read" in b and "KayaCompose.kt" in b for b in gone):
    print("check-verbs: SELF-TEST FAIL (an absent Kotlin harness "
          "failed the ax clause without naming it): "
          + "\n".join(gone), file=sys.stderr)
    raise SystemExit(1)

# AND AN ARM THE CENSUS CANNOT FIND is a finding too: the shape this
# clause anchors on is exactly what moved out from under an earlier
# reader, which found ZERO observations in harness.rs and agreed with
# everything.
drifted = perturb("ax-spelling (the harness ax arm reshaped out of "
                  "the census's reach)", HARNESS,
                  r"(Step::ExpectAx)\(target, want\) => Some\(poll\(",
                  "{ .. } => Some(poll(")
score_or_die(introduced(ax_spelling(harness_src=drifted), ax_out,
                        r"^harness\.rs has no ax arm the census can "
                        r"read"),
             "an unreadable ax arm")

# AND THE METRICS CLASS CHANNEL'S OWN, six negatives, each watched.
for slot, pattern, repl, want, label, finding in (
    ("swift", r"(case \.compact: return Int64\(KAYA_SIZE_CLASS_)"
     r"COMPACT\)", "NONE)", 1, "compact mapped to NONE",
     r"does not map \.compact"),
    ("swift", r"(\.onChange\(of: horizontalSizeClass\) \{\n\s+"
     r"KayaHost\.windowMetrics\(windowId, geo\.size, )sizeClass\)",
     "Int64(KAYA_SIZE_CLASS_NONE))", 1, "one report passing a literal",
     "does not pass the derived class"),
    ("swift", r"(\.onChange\(of: )horizontalSizeClass\)", "geo.size)",
     3, "the class re-report removed (3 structs share the pattern)",
     "never re-reports on a size-class change"),
    ("swift", r"(#if os\(macOS\)\n\s+return Int64\(KAYA_SIZE_CLASS_)"
     r"NONE\)", "COMPACT)", 1, "the mac arm inventing a class",
     "macOS arm"),
    ("swift", r"(struct KayaWindowMetricsReporter: ViewModifier \{\n"
     r"    let windowId: UInt64\n)    #if !os\(macOS\)\n        "
     r"@Environment\(\\\.horizontalSizeClass\) private var "
     r"horizontalSizeClass\n    #endif\n", "", 1,
     "the environment read deleted", "never reads the environment"),
    ("wire", r"(SIZE_CLASS_COMPACT_BELOW: f64 = )600\.0", "650.0", 1,
     "the ruled boundary drifted to 650", "ruled 600"),
):
    rel = SWIFT if slot == "swift" else WIRE
    drifted = perturb(f"metrics-class ({label})", rel, pattern, repl,
                      want=want)
    kwargs = ({"swift_src": drifted} if slot == "swift"
              else {"wire_src": drifted})
    score = introduced(metrics_class(**kwargs), metrics_out, finding)
    named, total = score.split("/")
    if named == "0" or named != total:
        print(f"check-verbs: SELF-TEST FAIL ({label} scored {score} "
              f"named/introduced findings, want them equal and "
              f"nonzero)", file=sys.stderr)
        raise SystemExit(1)

# --------------------------------------------------------------------
# The main coverage sweep.
harness = real(HARNESS)
wire = real(WIRE)
spec = real("crates/kaya/src/spec.rs")
swift = real(SWIFT)
kotlin = real(KOTLIN)

failures = []


def fail(msg):
    failures.append(msg)


# --- Harness verbs: the parse() match arms are the grammar. -----------
parse_body = harness[harness.index("pub fn parse("):
                     harness.index("fn parse_target(")]
verbs = sorted(set(re.findall(r'"([a-z_]+)" =>', parse_body))
               - {"on", "off"})
if not verbs:
    fail("no verbs extracted from harness.rs parse() — the gate itself "
         "broke")
for verb in verbs:
    for name, text in (("KayaSwiftUI.swift", swift),
                       ("KayaCompose.kt", kotlin)):
        if f'"{verb}"' not in text:
            fail(f'verb "{verb}" missing from {name}')

# --- Target kinds: the core's grammar, both interpreters' tables. -----
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
        fail(f"{name} has no `{opener}` — the target table this gate "
             f"reads is gone; re-point the clause at whatever replaced "
             f"it")
        return None
    end = text.find(closer, at)
    if end < 0:
        fail(f"{name}'s `{opener}` block never closes with {closer!r}")
        return None
    return text[at:end]


TARGET_TABLES = (
    ("KayaSwiftUI.swift", swift, "private func kayaAnyTarget(",
     "\n}\n", 'case "{}"'),
    ("KayaCompose.kt", kotlin, "private fun kayaWidgetTarget(",
     "\n    }\n", '"{}" ->'),
)

kind_body = harness[harness.index("fn parse_target_kind("):
                    harness.index("fn parse_string(")]
kinds = sorted(set(re.findall(r'"([a-z_]+)" => TargetKind::',
                              kind_body)))
if len(kinds) < 10:
    fail(f"only {len(kinds)} target kinds read out of harness.rs "
         f"parse_target_kind — a census that reads nothing agrees "
         f"with everything")


def missing_kinds(body, spelling):
    return [k for k in kinds if spelling.format(k) not in body]


for name, text, opener, closer, spelling in TARGET_TABLES:
    body = table_body(text, opener, closer, name)
    if body is None:
        continue
    for kind in missing_kinds(body, spelling):
        fail(
            f'target kind "{kind}" is in the core\'s parse_target_kind '
            f"but not in {name}'s "
            f"{opener.split('(')[0].split()[-1]} table — every verb "
            f'that resolves a `kind@id` there answers "no such target '
            f'{kind}@..." whatever the scene does')
    # WATCHED NEGATIVE, on every run: a census nobody has seen refuse
    # is a guess. The arm is cut out of a COPY of the block and the
    # substitution count is printed, because a perturbation that did
    # not apply is a failed test, not a passed one (invariant 3).
    victim = spelling.format(kinds[0])
    hits = body.count(victim)
    doctored = g.doctor(f"{name} target census victim removed", body,
                        re.escape(victim), "", want=hits or 1)
    if not missing_kinds(doctored, spelling):
        fail(f"check-verbs SELF-TEST: {name}'s target census passed "
             f"with {victim!r} cut from the block ({hits} "
             f"substitution(s))")
    else:
        print(f"check-verbs: self-test OK ({name} target census "
              f"refuses {victim!r} removed, {hits} substitution(s))")

# --- Scene substitutions: the THIRD vocabulary. -----------------------
# A scene path may carry `$TMP` or `$PID`, and an interpreter that does
# not expand a token uses it as a LITERAL PATH SEGMENT — on macOS the
# picker then falls back to its last-used location and the scene
# asserts against whatever that was (docs/traps.md). Silent on every
# platform.
#
# THREE SITES, NOT TWO: harness.rs is the third implementation of these
# verbs, the one the GTK and WinUI backends run.
subs = sorted(set(
    tok
    for f in (ROOT / "tools" / "scenes").glob("*.steps")
    for tok in re.findall(r"\$([A-Z_]+)",
                          f.read_text(encoding="utf-8"))))
for sub in subs:
    for name, text in (("KayaSwiftUI.swift", swift),
                       ("KayaCompose.kt", kotlin),
                       ("harness.rs", harness)):
        if f'"{sub}"' not in text:
            fail(f'scene substitution "${sub}" has no expansion in '
                 f"{name} — it would be used as a literal path segment")

# AND THE EXPANSION HAS TO REACH BOTH SIDES OF THE SCENE: an
# implementation can expand the path a verb NAVIGATES to and forget the
# one it ASSERTS against, so the picker is aimed correctly and the
# comparison fails against a literal "$PID" — reading as a broken
# picker rather than a harness one.
for name, text in (("KayaSwiftUI.swift", swift),
                   ("KayaCompose.kt", kotlin),
                   ("harness.rs", harness)):
    if "expect_file_dialog" in text \
            and "unexpanded substitution" not in text:
        fail(f"{name} reads expect_file_dialog's directory but never "
             f"refuses an unexpanded substitution — an expansion it "
             f"forgot would read as a broken picker")

# --- The step-failed line: THREE harnesses, one spelling. -------------
# `failures` is named only by the verdict, which is printed LAST, so an
# abort before it takes the whole list — the log shows a crash with no
# reason. The rule is that a failure is printed the moment it is
# final, with the TEXT interpolated: a fixed sentence names no cause
# and is printed for every one. Two of the three carried this for
# milestones while KayaCompose.kt did not, and only eyes ever compared
# them (docs/deferred.md).
for name, text, interp in (("KayaSwiftUI.swift", swift, r"\\\("),
                           ("KayaCompose.kt", kotlin, r"\$"),
                           ("harness.rs", harness, r"\{")):
    if not re.search("KAYA_HARNESS: step-failed " + interp, text):
        fail(f"{name} never prints `KAYA_HARNESS: step-failed <text>` "
             f"with the failure text interpolated — a step's failure "
             f"reaches the log only if it is printed when it becomes "
             f"final, not saved for the verdict")

# AND IN THE WRAPPER'S FINAL-FAILURE BRANCH, not merely somewhere in
# the file. The interpreters print this line twice for different
# reasons — KayaSwiftUI.swift's clip-breach arm is one — so presence
# alone is satisfied by a copy that runs on another path, and the
# branch that matters is the one AFTER the retry gives up. harness.rs
# has no retryStep (its `poll` retries internally) and is held by the
# clause above alone.
for name, text in (("KayaSwiftUI.swift", swift),
                   ("KayaCompose.kt", kotlin)):
    retries = [m.end() for m in re.finditer(r"retryStep = true", text)]
    prints = [m.start() for m in
              re.finditer("KAYA_HARNESS: step-failed ", text)]
    if not retries:
        fail(f"{name} has no `retryStep = true` — the bounded-retry "
             f"wrapper this gate reads is gone; re-point the clause at "
             f"whatever replaced it")
    elif not any(p > retries[-1] for p in prints):
        fail(f"{name} prints `KAYA_HARNESS: step-failed` only BEFORE "
             f"the retry wrapper gives up — the branch that runs when "
             f"an expect's deadline lands has none, so a failing "
             f"step's text still dies with an abort")

# --- Wire constants the interpreters mirror privately. ----------------
# APPLY/KIND/PROP/COMMAND/MENU_KIND/MPROP: all of them. VALUE: only the
# types reachable through the spec's PROPS PropKinds (the scene's prop
# typing keeps the rest off the pump).
rows = re.findall(r"pub(?:\(crate\))? const ((?:APPLY|KIND|PROP|COMMAND|VALUE|"
                  r"MENU_KIND|MPROP)_[A-Z_0-9]+): u\d+ = (\d+);", wire)
# THE CANVAS VOCABULARIES, which no gate held until 2026-08-26. They
# ride the op stream as i64 rather than u32, so the sweep above cannot
# see them by type, and their prefixes are not in its alternation
# either — which left five enums hand-copied into two interpreters
# with nothing checking the numbers, the exact shape check-file-modes
# exists for (docs/canvas-plan.md §3.6, which asked for this clause).
# Kotlin spells a Long literal with an L suffix, so the value pattern
# allows one.
canvas_rows = re.findall(
    r"pub(?:\(crate\))? const ((?:DRAW|PAINT|FILL|TEXT_ALIGN|TEXT_BASELINE)"
    r"_[A-Z_0-9]+): i64 = (\d+);", wire)
if len(canvas_rows) < 21:
    fail(f"only {len(canvas_rows)} canvas constants found in wire.rs — "
         f"the sweep reads nothing and would agree with everything")
rows += canvas_rows
props_block = spec[spec.index("pub const PROPS"):
                   spec.index("];", spec.index("pub const PROPS"))]
prop_kinds = set(re.findall(r"PropKind::(\w+)", props_block))
required_values = {"VALUE_" + k.upper() for k in prop_kinds}


def swift_name(const):
    group, rest = const.split("_", 1)
    return group.lower() + "".join(w.capitalize()
                                   for w in rest.split("_"))


for const, value in rows:
    if const.startswith("VALUE_") and const not in required_values:
        continue
    sname = swift_name(const)
    if not re.search(rf"let {re.escape(sname)}\b[^=\n]*= {value}\b",
                     swift):
        fail(f"{const} = {value}: expected `{sname} ... = {value}` in "
             f"KayaSwiftUI.swift")
    if not re.search(rf"\b{const}\b\s*(?::\s*\w+\s*)?=\s*{value}L?\b",
                     kotlin):
        fail(f"{const} = {value}: expected `{const} = {value}` in "
             f"KayaCompose.kt")

# --- The spec hash. A runtime assert also holds it (a stale compiled
# --- dylib/APK bypasses source gates); the SOURCE copy is pinned here.
wire_h = real("bindings/c/kaya_wire.h")
m = re.search(r"#define KAYA_SPEC_HASH 0x([0-9a-fA-F]+)ULL", wire_h)
if not m:
    fail("KAYA_SPEC_HASH not found in bindings/c/kaya_wire.h — the "
         "gate itself broke")
else:
    h = m.group(1).lower()
    if not re.search(rf"let kayaSpecHash: UInt64 = 0x{h}\b", swift):
        fail(f"spec hash 0x{h}: expected `let kayaSpecHash: UInt64 = "
             f"0x{h}` in KayaSwiftUI.swift")
    if not re.search(rf"SPEC_HASH: ULong = 0x{h}uL\b", kotlin):
        fail(f"spec hash 0x{h}: expected `SPEC_HASH: ULong = 0x{h}uL` "
             f"in KayaCompose.kt")

# --- Every expect arm must RECORD what it observed. -------------------
# A verb that appends a failure on mismatch and nothing on a match
# verifies nothing when it passes: the leg prints PASS with that
# assertion silently absent from the observation list. The observation
# list is also the byte-compared verdict text, so "recorded nothing"
# and "reported the wrong thing" are one defect class.
def expect_arms(text, pattern, end_marker):
    """(verb, body) for each expect_* arm of an interpreter's
    switch."""
    heads = list(re.finditer(pattern, text))
    for i, m in enumerate(heads):
        stop = heads[i + 1].start() if i + 1 < len(heads) else len(text)
        end = text.find(end_marker, m.start(), stop)
        yield m.group(1), text[m.start():end if end > 0 else stop]


# ONE EXEMPTION: an arm that calls the depth stub does not RETURN, so
# it cannot pass vacuously — the process dies naming the scene and the
# platform. Without this the rule would push a half-built backend into
# faking an observation.
def records_or_refuses(body, appender):
    return (appender in body or "epthStub(" in body
            or "epth_stub(" in body)


for verb, body in expect_arms(swift, r'case "(expect[a-z_]*)":',
                              "\n            case "):
    if not records_or_refuses(body, "observed.append("):
        fail(f'KayaSwiftUI.swift\'s "{verb}" arm never appends to '
             f"`observed` — an expect that records nothing passes "
             f"without verifying anything")
for verb, body in expect_arms(kotlin, r'"(expect[a-z_]*)" ->',
                              '\n                    "'):
    if not records_or_refuses(body, "observed.add("):
        fail(f'KayaCompose.kt\'s "{verb}" arm never adds to '
             f"`observed` — an expect that records nothing passes "
             f"without verifying anything")

# The vtable rule: the SwiftUI interpreter reaches the host ONLY
# through KayaHost's function-pointer table. A direct C-symbol call
# typechecks and links, then dies at dlopen against a static-rust or
# RTLD_LOCAL host ("symbol not found in flat namespace"). C symbols
# are exactly the kaya_ + underscore namespace; Swift helpers are
# camelCase.
for m in re.finditer(r"\bkaya_[a-z_]+\s*\(", swift):
    fail(f"KayaSwiftUI.swift calls C symbol "
         f"`{m.group(0).strip('( ')}` directly — route it through "
         f"KayaHost's api table (the vtable pins the one live kaya "
         f"instance; direct symbols die on static/RTLD_LOCAL hosts)")

# THE STAMPED-OBSERVATION RULE. A field the harness READS must be
# written on every platform the interpreter serves, and the way that
# breaks is silent: the write sits inside a platform conditional, the
# other platform leaves the field at its initial value, and the verb
# reads a default that looks like an answer.
#
# So each of these fields must have at least one write OUTSIDE every
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
    writes = [(n, d) for n, (line, d) in
              enumerate(zip(lines, depths), 1)
              if re.search(rf"\.{field}\s*=[^=]", line)]
    if not writes:
        fail(f"KayaSwiftUI.swift never writes `{field}`, which the "
             f"harness reads")
    elif all(d > 0 for _, d in writes):
        where = ", ".join(str(n) for n, _ in writes)
        fail(f"every write to `{field}` in KayaSwiftUI.swift sits "
             f"inside a platform conditional (lines {where}) — the "
             f"platforms it excludes read the field's initial value as "
             f"if it were an observation")

if failures:
    for f_ in failures:
        print(f"check-verbs: {f_}", file=sys.stderr)
    raise SystemExit(1)
# --- THE KEYED TARGET REACHES EVERY TAGGED KIND (2026-09-01) --------
# `kind@id[key.path]` used to resolve for `column` alone on all four
# backends — each early-returned on any other kind — so no scene could
# click a stamped button (docs/deferred.md's keyed-target entry, the
# portfolio's per-account affordance). Every occurrence tag carries the
# table tag's own node-and-keys layout, so the arms resolve any tagged
# kind through it now; this pins each arm's generic spelling and refuses
# the column-only guard coming back. Byte-frozen markers, doctored away
# one at a time and watched red.
KEYED_ARMS = [
    ("crates/kaya/src/gtk.rs",
     "let candidates = kind_registry(core, kind);",
     "let candidates: Vec<gtk4::Widget> = Vec::new();"),
    ("crates/kaya/src/winui/mod.rs",
     "K::Button => find(&core.button_controls, &id),",
     "K::Button => None,"),
    ("swift/KayaSwiftUI.swift",
     'kayaTableStamp(kind == "column" ? $0.sortTag : $0.tag)',
     "kayaTableStamp($0.sortTag)"),
    ("android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt",
     'tableStamp(if (kind == "column") n.sortTag else n.tag)',
     "tableStamp(n.sortTag)"),
]
COLUMN_ONLY = [
    ("crates/kaya/src/gtk.rs",
     "if kind != K::Column {\n                    return None;"),
    ("swift/KayaSwiftUI.swift", 'guard kind == "column" else { return nil }'),
    ("android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt",
     'if (kind != "column") return null'),
]


def keyed_problems(texts):
    bad = []
    for rel, marker, _ in KEYED_ARMS:
        if texts[rel].count(marker) != 1:
            bad.append(f"{rel}: the keyed target arm no longer spells "
                       f"`{marker}` exactly once — a stamped copy of a "
                       f"non-column kind cannot be driven by key")
    for rel, guard in COLUMN_ONLY:
        if guard in texts[rel]:
            bad.append(f"{rel}: the column-only guard `{guard.strip()}` "
                       f"is back in the keyed target arm")
    return bad


keyed_texts = {rel: (ROOT / rel).read_text(encoding="utf-8")
               for rel, _, _ in KEYED_ARMS}
keyed_out = keyed_problems(keyed_texts)
for rel, marker, broken in KEYED_ARMS:
    doctored = dict(keyed_texts)
    doctored[rel] = g.doctor(f"keyed arm marker cut from {rel}",
                             keyed_texts[rel], re.escape(marker), broken)
    if not keyed_problems(doctored):
        fail(f"check-verbs SELF-TEST: {rel}'s keyed arm passed with "
             f"`{marker}` doctored to `{broken}`")
for rel, guard in COLUMN_ONLY:
    doctored = dict(keyed_texts)
    doctored[rel] = keyed_texts[rel] + "\n" + guard + "\n"
    if not keyed_problems(doctored):
        fail(f"check-verbs SELF-TEST: {rel}'s column-only guard "
             f"restored passed")
if keyed_out:
    print("check-verbs: the keyed harness target must reach every "
          "tagged kind on every backend:", file=sys.stderr)
    print("\n".join(keyed_out), file=sys.stderr)
keyed_status = 1 if keyed_out else 0
print(f"check-verbs: keyed target arms: {len(KEYED_ARMS)} markers pinned, "
      f"{len(KEYED_ARMS) + len(COLUMN_ONLY)} watched negatives refused",
      file=sys.stderr)

# The verb trace's watched negatives, each on a doctored copy with its
# substitution count printed (kaya_gate.doctor), each demanding the
# sentence the real clause would print.
vtrace_texts = {rel: real(rel) for rel in (HARNESS, SWIFT, KOTLIN, VTRACE)}
VTRACE_NEGATIVES = [
    ("the SwiftUI verdict dump cut", SWIFT,
     r'\n    KayaVTrace\.dump\("the verdict failed: [^\n]*\n', "\n",
     "verb-trace dump site(s), want exactly 2"),
    ("the Compose line shape drifted", KOTLIN,
     r'records=\$\{recs\.size\} dropped=', "recs=${recs.size} dropped=",
     "does not carry the verb-trace line shape"),
    ("the SwiftUI env var renamed", SWIFT,
     r'environment\["KAYA_VERB_TRACE"\]', 'environment["KAYA_VTRACE"]',
     "never names"),
    ("a Compose dump on the pass path", KOTLIN,
     r'(\n\s+)(Log\.i\("kaya", "KAYA_SELFTEST: OK)',
     r'\1KayaVTrace.dump("green")\1\2',
     "verb-trace dump site(s), want exactly 2"),
    ("the Rust watchdog dump moved off the fire path", HARNESS,
     r'crate::vtrace::dump\("the step ceiling fired: no verdict"\);\n',
     "", "verb-trace dump site(s), want exactly 2"),
    ("the Rust ring's pointer line drifted", VTRACE,
     r'appended to \{\}', "written to {}",
     "does not carry the verb-trace line shape"),
    ("a SwiftUI dump on the pass path (outside the crash handler)", SWIFT,
     r'(\n\s+)(print\("KAYA_SELFTEST: OK)',
     r'\1KayaVTrace.dump("green")\1\2',
     "verb-trace dump site(s), want exactly 2"),
]
for label, rel, pattern, repl, want in VTRACE_NEGATIVES:
    doctored = g.doctor(label, vtrace_texts[rel], pattern, repl)
    args = {HARNESS: "harness_src", SWIFT: "swift_src", KOTLIN: "kotlin_src",
            VTRACE: "vtrace_src"}
    out = verb_trace(**{args[rel]: doctored})
    if not any(want in line for line in out):
        fail(f"check-verbs SELF-TEST: {label} passed the verb-trace clause "
             f"(wanted a finding naming {want!r}; got {out!r})")
print(f"check-verbs: verb trace: {len(VTRACE_LINES)} line shapes in 3 "
      f"harnesses, {len(VTRACE_NEGATIVES)} watched negatives refused",
      file=sys.stderr)

# clip_mirrors() ran first and printed its own findings; its verdict
# is read here so there is exactly ONE verdict line.
if (clip_status or window_status or ink_status or ax_status
        or metrics_status or keyed_status or vtrace_status):
    raise SystemExit(1)
g.verdict(f"{len(verbs)} verbs, {len(rows)} constants "
          f"({len(canvas_rows)} of them the canvas vocabularies) + "
          f"the CLIP_* mirrors + the ink tolerance in 3 harnesses + "
          f"the ax spelling in 3 harnesses + the verb trace in 3 "
          f"harnesses + the windowed tier's loop "
          f"+ the metrics class channel + the keyed target arms on 4 "
          f"backends + spec hash against 2 interpreters")
