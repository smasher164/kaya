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
SWIFT_ENTRY = "swift/KayaSwiftUIEntry.swift"
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
# That sweep's prefix alternation stops short of wire.rs's five clip
# masks (BIT POSITIONS, not ordinals), which are copied into both
# interpreters with nothing pinning either copy. NAME AND VALUE
# TOGETHER: a copy carrying all five names at four right values
# compiles, runs and ships one wrong kind.
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
# `expect_ink` compares within ±1 PER CHANNEL (ruled 2026-08-26,
# docs/canvas-plan.md §7.2, docs/traps.md): a macOS backing store carries
# the DISPLAY's profile and reads the core's D2E3F7 back as D2E2F7.
# PINNED AT THE RULED VALUE, not merely held equal — copies drifting
# TOGETHER make every ink assertion quieter with nothing slower or redder.
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
# An observation IS the byte-compared verdict text (invariant 6), RULED
# QUOTED 2026-08-27 (docs/deferred.md). NO LANE CAN FAIL THIS: every
# runner greps the verdict for `KAYA_SELFTEST: OK` and never diffs its
# text. The census reads each emitter out of its OWN ARM — `Step::ExpectAx(`
# alone matches harness.rs's PARSER first, and a reader anchored on the
# name found ZERO observations there.
AX_OBS = {"ax": 'ax "<v>"', "ax hint": 'ax hint "<v>"',
          "help": 'help "<v>"',
          # THE WINDOW PREFIX COMES FIRST, like every other windowed
          # observation. SwiftUI spelled it `sections window#1 sidebar`
          # where harness.rs and Compose spell `window#1 sections
          # sidebar`, and tools/scenes/sections.steps asserts the
          # WINDOWED form, so the mac lane's verdict text differed from
          # the other three every run (found 2026-09-24; docs/deferred.md).
          "sections": "<v>sections <v>"}
AX_WANTED = {"ax": 'ax "<v>", wanted "<v>"',
             "ax hint": 'ax hint "<v>", wanted "<v>"',
             "help": 'help "<v>", wanted "<v>"',
             "sections": "<v>sections presentation <v>, wanted <v>"}

AX_HARNESSES = [
    ("harness.rs", HARNESS, "rust",
     [("ax", r"Step::ExpectAx\([^()]*\) => Some\(poll\(",
       "\n            Step::"),
      ("ax hint", r"Step::ExpectAxHint\([^()]*\) => Some\(poll\(",
       "\n            Step::"),
      # HELP rides the same rule: three harnesses, one spelling
      # (docs/tooltip-plan.md T5).
      ("help", r"Step::ExpectHelp\([^()]*\) => Some\(poll\(",
       "\n            Step::"),
      ("sections", r"Step::ExpectSectionsPresentation\([^()]*\) => \{",
       "\n            Step::")],
     r"Ok\(format!\(", r"Err\(format!\("),
    ("KayaSwiftUI.swift", SWIFT, "swift",
     [("ax", 'case "expect_ax":', "\n            case "),
      ("ax hint", 'case "expect_ax_hint":', "\n            case "),
      ("help", 'case "expect_help":', "\n            case "),
      ("sections", 'case "expect_sections_presentation":',
       "\n            case ")],
     r"observed\.append\(", r"failures\.append\("),
    ("KayaCompose.kt", KOTLIN, "kotlin",
     [("ax", '"expect_ax" ->', '\n                    "'),
      ("ax hint", '"expect_ax_hint" ->', '\n                    "'),
      ("help", '"expect_help" ->', '\n                    "'),
      ("sections", '"expect_sections_presentation" ->',
       '\n                    "')],
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
    if not bad and seen < 12:
        bad.append("only " + str(seen) + " ax observations found "
                   "across three harnesses — the reader is matching "
                   "almost nothing and would pass any spelling")
    return bad


# --- THE WINDOWED TIER'S LOOP: three links no scene can see. ----------
# docs/virtualization-plan.md §3/§4. THREE OF THE FOUR LINKS ARE
# INVISIBLE TO THE ONE SCENE THAT DRIVES THEM, each measured 2026-08-25
# on a real emulator staying GREEN when removed: the visible-range report
# (scroll_to_row moves the band itself), the measured-extent report (a
# height moves the arithmetic, never the band), and both spacers zeroed.
# The SwiftUI half of the loop lives in tools/check-table-tier.py.
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
            # kayaFixedRepresentable clamps only past Compose's packing
            # edge (docs/deferred.md's portfolio-android entry). The third
            # pin holds the helper honest: fitPrioritizingWidth IS the
            # identity on every representable input.
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
# 2026-08-31): iOS is the one platform whose size class the platform
# decides, through KayaWindowMetricsReporter alone. NO LANE CAN SEE THE
# READ — the pool is phones, where deriving from the width answers compact
# exactly as the platform does, so a reporter hardcoding NONE is green on
# every leg and wrong on an iPad. The RULED BOUNDARY is pinned at 600.0:
# the scenes hold it only to (560, 900].
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


# --- NOTIFICATION AUTHORIZATION ASKS ONLY FOR WHAT IT LACKS ------------
# From provisional, a request for alerts waits on a prompt that never comes,
# so a post behind it is never made (docs/traps.md, the cold notification
# reply of 2026-09-27). NO LANE CAN SEE IT: the harness asks provisionally
# and every leg holds that grant; only a launch the platform starts asks
# for alerts. The one `requestAuthorization(` is the helper's `ask`, called
# while undecided or when the grant fails the caller's `needs`, and the post
# passes no `needs` (delivery is all it needs, and provisional has it).
def notify_auth(swift_src=None):
    bad = []
    swift = swift_src if swift_src is not None else real(SWIFT)
    code = re.sub(r"//[^\n]*", "", swift)
    calls = [m.start() for m in re.finditer(r"\.requestAuthorization\(",
                                            code)]
    m = re.search(r"^func kayaNotificationAuthorization\(", code, re.M)
    if not m:
        bad.append("KayaSwiftUI.swift has no kayaNotificationAuthorization "
                   "helper this clause can read (a finding, never a skip)")
        return bad
    end = re.search(r"^\}$", code[m.end():], re.M)
    body_end = m.end() + (end.start() if end else len(code))
    body = code[m.start():body_end]
    outside = [c for c in calls if not m.start() <= c < body_end]
    if outside:
        bad.append(f"{len(outside)} requestAuthorization call(s) outside "
                   f"kayaNotificationAuthorization — a post behind one "
                   f"waits forever from provisional")
    inside = len(calls) - len(outside)
    if inside != 1 or not re.search(
            r"let ask = \{ centre\.requestAuthorization\(", body):
        bad.append(f"kayaNotificationAuthorization asks {inside} times, "
                   f"not once through its `ask`")
    if not re.search(r"case \.notDetermined:\s*\n\s*ask\(\)", body):
        bad.append("kayaNotificationAuthorization does not ask in its "
                   ".notDetermined arm")
    if not re.search(r"default:\s*\n\s*if needs\(settings\) \{ "
                     r"then\(true, nil\) \} else \{ ask\(\) \}", body):
        bad.append("kayaNotificationAuthorization's decided arm does not "
                   "consult `needs` before asking — a decided grant that "
                   "has what the call needs is the answer")
    if not re.search(r"case \.denied:\s*\n\s*then\(false", body):
        bad.append("kayaNotificationAuthorization does not answer .denied "
                   "as refused")
    post = re.search(r"^func kayaPostNotification\(.*?^\}$", code,
                     re.M | re.S)
    if not post or not re.search(
            r"kayaNotificationAuthorization\(opts\) \{", post.group(0)):
        bad.append("kayaPostNotification does not ask through "
                   "kayaNotificationAuthorization(opts) with no `needs` — "
                   "a post that needs alerts asks from provisional")
    return bad
    end = re.search(r"^\}$", code[m.end():], re.M)
    body_end = m.end() + (end.start() if end else len(code))
    body = code[m.start():body_end]
    outside = [c for c in calls if not m.start() <= c < body_end]
    if outside:
        bad.append(f"{len(outside)} requestAuthorization call(s) outside "
                   f"kayaNotificationAuthorization — a post behind one "
                   f"waits forever from provisional")
    inside = len(calls) - len(outside)
    if inside != 1:
        bad.append(f"kayaNotificationAuthorization asks {inside} times, "
                   f"not once — only the .notDetermined arm may ask")
    arm = re.search(r"case \.notDetermined:\s*\n\s*centre\."
                    r"requestAuthorization\(", body)
    if not arm:
        bad.append("kayaNotificationAuthorization does not ask only in its "
                   ".notDetermined arm — a decided status is the answer")
    if not re.search(r"case \.denied:\s*\n\s*then\(false", body):
        bad.append("kayaNotificationAuthorization does not answer .denied "
                   "as refused")
    return bad


# --- THE PUMP STARTS WITHOUT A WINDOW -----------------------------------
# A launch for a notification reply opens no window, so a pump started only
# by the primary root's appearance never applies the reply's answer
# (docs/traps.md, the cold notification reply of 2026-09-27). NO LANE CAN
# SEE IT: every scripted launch opens a window. The pump starts through
# kayaStartPumpOnce alone, and both app delegates call it when launching
# finishes.
def pump_start(swift_src=None, entry_src=None):
    bad = []
    swift = re.sub(r"//[^\n]*", "", swift_src if swift_src is not None
                   else real(SWIFT))
    entry = re.sub(r"//[^\n]*", "", entry_src if entry_src is not None
                   else real(SWIFT_ENTRY))
    once = re.search(r"^func kayaStartPumpOnce\(_ by: String\) \{(.*?)^\}$",
                     swift, re.M | re.S)
    if not once:
        bad.append("KayaSwiftUI.swift has no kayaStartPumpOnce this clause "
                   "can read (a finding, never a skip)")
        return bad
    if not re.search(r"guard !kayaPumpStarted else \{ return \}\s*\n\s*"
                     r"kayaPumpStarted = true", once.group(1)):
        bad.append("kayaStartPumpOnce is not guarded by kayaPumpStarted — "
                   "a second caller starts a second pump")
    direct = [m for m in re.finditer(r"(?<!func )\bkayaStartCommandPump\(\)", swift)
              if not once.start() <= m.start() < once.end()]
    if direct:
        bad.append(f"{len(direct)} kayaStartCommandPump() call(s) outside "
                   f"kayaStartPumpOnce — a pump that bypasses the guard")
    for name, pattern in (
            ("macOS applicationDidFinishLaunching",
             r"func applicationDidFinishLaunching\([^)]*\) \{(.*?)\n    \}"),
            ("iOS didFinishLaunchingWithOptions",
             r"didFinishLaunchingWithOptions[^{]*\{(.*?)\n    \}")):
        m = re.search(pattern, entry, re.S)
        if not m or "kayaStartPumpOnce(\"launch\")" not in m.group(1):
            bad.append(f"the {name} delegate does not call "
                       f"kayaStartPumpOnce — a windowless launch applies "
                       f"nothing")
    return bad



# --- THE COMPOSE IMMERSIVE ARM (docs/fullscreen-plan.md §3, §5) ---------
# expect_fullscreen reads the ROOT'S INSETS and never the prop: a reader of
# KayaSceneModel.windowFullscreen passes the scene with the bars still up,
# the check-appearance read-back rule one feature over. The prop's arm
# installs immersive mode with the transient-bars behavior, and a phone's
# user_fullscreen refuses rather than pretending. NO LANE CAN SEE THE
# BEHAVIOR: no leg swipes the bars in.
def compose_immersive(kotlin_src=None):
    bad = []
    kt = re.sub(r"//[^\n]*", "", kotlin_src if kotlin_src is not None
                else real(KOTLIN))
    arm = re.search(r'"expect_fullscreen" -> \{(.*?)\n                    \}\n',
                    kt, re.S)
    if not arm:
        bad.append("KayaCompose.kt has no expect_fullscreen arm this clause "
                   "can read (a finding, never a skip)")
    else:
        if "immersiveReading(activity)" not in arm.group(1):
            bad.append("expect_fullscreen does not read immersiveReading — "
                       "the root's insets are the toolkit's answer")
        if "windowFullscreen" in arm.group(1):
            bad.append("expect_fullscreen reads KayaSceneModel.windowFullscreen, "
                       "the prop — a leg would pass with the bars still up")
    reading = re.search(r"fun immersiveReading\(.*?\n    \}\n", kt, re.S)
    if not reading or "getRootWindowInsets(" not in reading.group(0) \
            or ".isVisible(WindowInsetsCompat.Type.statusBars())" not in reading.group(0) \
            or "windowFullscreen" in reading.group(0):
        bad.append("immersiveReading does not answer from the root insets' "
                   "status bar visibility")
    install = re.search(r"fun installImmersive\(.*?\n    \}\n", kt, re.S)
    if not install or "BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE" not in install.group(0) \
            or ".hide(WindowInsetsCompat.Type.systemBars())" not in install.group(0) \
            or ".show(WindowInsetsCompat.Type.systemBars())" not in install.group(0):
        bad.append("installImmersive does not hide the system bars with the "
                   "transient-bars behavior and show them to leave "
                   "(docs/fullscreen-plan.md §3)")
    prop = re.search(r"WPROP_FULLSCREEN -> \{(.*?)\n                        \}", kt, re.S)
    if not prop or "installImmersive(" not in prop.group(1):
        bad.append("the WPROP_FULLSCREEN arm does not install immersive mode")
    user = re.search(r'"user_fullscreen" -> \{(.*?)\n                    \}\n', kt, re.S)
    if not user or "failures.add(" not in user.group(1) \
            or "installImmersive" in user.group(1):
        bad.append("user_fullscreen does not refuse on Android, which has no "
                   "user door (docs/fullscreen-plan.md §2)")
    return bad


# --- THE VERB TRACE: one ring, three harnesses ------------------------
# crates/kaya/src/vtrace.rs writes what every verb did ONLY WHEN THE RUN
# FAILS (docs/deferred.md, the flight recorder's BUILD entry). NO LANE CAN
# SEE IT: a human reads the file after a failure. Per harness: the env var
# by name, the four line shapes compared FLATTENED, and exactly two dump
# sites — the script runner's, after the green verdict's text and before
# the publish, and the watchdog's, before its exit primitive.
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

# AND THE WORD SET IS CLOSED ACROSS ALL THREE (since 2026-09-07, when the
# tasks scene asserted `switch/` on every lane and harness.rs's ROLES
# lacked it — GTK and WinUI would have refused the parse while the two
# interpreters answered it). ROLES is the vocabulary a shared scene may
# assert; each interpreter mints its words from its own platform reader.
AX_WORD_FLOOR = 8
AX_SCENE_FLOOR = 5


def ax_words(harness_src=None, swift_src=None, kotlin_src=None,
             scenes=None):
    bad = []

    def load(src, rel):
        return source_text(
            src, rel, bad,
            lambda s, exc: (
                "cannot read " + s + " for the ax word set ("
                + str(exc.strerror) + "): the harness whose words this "
                "rule closes is not there"))

    harness = load(harness_src, HARNESS)
    swift = load(swift_src, SWIFT)
    kotlin = load(kotlin_src, KOTLIN)
    if None in (harness, swift, kotlin):
        return bad
    m = re.search(r"const ROLES: \[&str; \d+\] = \[(.*?)\];", harness,
                  re.S)
    if not m:
        return bad + ["harness.rs has no ROLES array the census can read"]
    roles = set(re.findall(r'"([a-z]+)"', m.group(1)))

    def body_words(text, rel, signature):
        words, found = set(), 0
        for hit in re.finditer(re.escape(signature), text):
            end = text.find("\n    }\n", hit.end())
            if end < 0:
                bad.append(f"{rel}: {signature} has no end the census "
                           "can read")
                continue
            found += 1
            words |= set(re.findall(r'"([a-z]+)"', text[hit.end():end]))
        if not found:
            bad.append(f"{rel} has no {signature} the census can read")
        return words

    swift_words = body_words(swift, "KayaSwiftUI.swift",
                             "private func kayaAxRole(")
    kotlin_words = body_words(kotlin, "KayaCompose.kt",
                              "private fun kayaAxRole(")
    kotlin_words |= set(re.findall(r'this\[KayaAxKind\] = "([a-z]+)"',
                                   kotlin))
    for name, words in (("harness.rs ROLES", roles),
                        ("KayaSwiftUI.swift", swift_words),
                        ("KayaCompose.kt", kotlin_words)):
        if len(words) < AX_WORD_FLOOR:
            bad.append(f"{name} yields {len(words)} ax words, under the "
                       f"floor of {AX_WORD_FLOOR}: a census that reads "
                       "nothing agrees with everything")
    for rel, words in (("KayaSwiftUI.swift", swift_words),
                       ("KayaCompose.kt", kotlin_words)):
        for word in sorted(words - roles):
            bad.append(f"{rel} answers ax {word}, which harness.rs's "
                       "ROLES does not admit: no shared scene can assert "
                       "it on GTK or WinUI")
    asserted = set()
    for path in sorted(pathlib.Path(scenes or ROOT / "tools/scenes")
                       .glob("*.steps")):
        asserted |= set(re.findall(r'^\s*expect_ax \S+ "([a-z]+)/',
                                   path.read_text(encoding="utf-8"),
                                   re.M))
    if len(asserted) < AX_SCENE_FLOOR:
        bad.append(f"tools/scenes asserts {len(asserted)} ax words, under "
                   f"the floor of {AX_SCENE_FLOOR}")
    for rel, words in (("harness.rs", roles),
                       ("KayaSwiftUI.swift", swift_words),
                       ("KayaCompose.kt", kotlin_words)):
        for word in sorted(asserted - words):
            bad.append(f"tools/scenes asserts ax {word}, which {rel} "
                       "cannot answer: the scene is shared verbatim, so "
                       "that lane reads it as a parse refusal or a miss")
    return bad


words_out = ax_words()
words_status = 1 if words_out else 0
if words_out:
    print("check-verbs: the ax word set is not one closed list across "
          "the three harnesses and the shared scenes:", file=sys.stderr)
    print("\n".join(words_out), file=sys.stderr)

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

pump_out = pump_start()
pump_status = 1 if pump_out else 0
if pump_out:
    print("check-verbs: the interpreter's pump waits for a window — a "
          "launch the platform starts for a notification reply applies "
          "nothing:", file=sys.stderr)
    print("\n".join(pump_out), file=sys.stderr)

notify_auth_out = notify_auth()
notify_auth_status = 1 if notify_auth_out else 0
immersive_out = compose_immersive()
immersive_status = 1 if immersive_out else 0
if immersive_out:
    print("check-verbs: the Compose immersive arm reads or writes the wrong "
          "thing:", file=sys.stderr)
    print("\n".join(immersive_out), file=sys.stderr)
if notify_auth_out:
    print("check-verbs: notification authorization asks where a decided "
          "status must answer — a post made from a platform-started "
          "launch then never reaches the centre:", file=sys.stderr)
    print("\n".join(notify_auth_out), file=sys.stderr)


# The negatives perturb the REAL files, in both directions and on BOTH
# mirrors. THE REFUSAL IS SCORED, NOT JUST COUNTED: each half scores what
# the perturbation INTRODUCED over the real check's own findings —
# `named/total`, only 1/1 passing, baseline-relative so a genuinely
# drifted mirror does not report as a broken guard, and a clause that
# simply PASSED the drifted copy scores 0/0 and fails the same way.
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
    # AND THE HELP OBSERVATION, on the harness that joined last: the
    # verb reads a different platform surface on every backend, so its
    # verdict text is the only thing that can be compared across them.
    (KOTLIN, r'(observed\.add\("help )\\"\$want\\""', '$want"',
     "kotlin", "the Compose help observation unquoted",
     r"^KayaCompose\.kt records the help observation as help <v>, "),
    # AND THE SECTIONS OBSERVATION PUT BACK THE WAY IT SHIPPED: the
    # window prefix after the word instead of before it, which is what
    # the mac lane printed against the other three for months while
    # tools/scenes/sections.steps asserted the windowed form every run
    # (found 2026-09-24).
    (SWIFT, r'(observed\.append\(")\\\(armPrefix\)sections \\\(wantArm\)"',
     'sections \\(armPrefix)\\(wantArm)"', "swift",
     "the mac sections observation with its window prefix after the word",
     r"^KayaSwiftUI\.swift records the sections observation as "
     r"sections <v><v>, "),
):
    drifted = perturb(f"ax-spelling ({label})", rel, pattern, repl)
    kwargs = {f"{slot}_src": drifted}
    score_or_die(introduced(ax_spelling(**kwargs), ax_out, finding),
                 label)

# AND THE WORD SET'S OWN, one per harness and each a different route in:
# a scene word cut out of ROLES (three findings — the scene's, and the
# two interpreters now answering a word ROLES lacks), a Compose
# KayaAxKind word renamed (two: the new word unadmitted, the old word
# unanswered), and the mac reader's switch renamed (one: the iOS reader
# still answers it).
for label, kwargs, findings in (
    ("switch cut from harness.rs's ROLES",
     dict(harness_src=perturb("ax-words (switch cut from ROLES)", HARNESS,
                              r'("unknown", )"switch", ', "")),
     (r"^tools/scenes asserts ax switch, which harness\.rs cannot answer",
      r"^KayaSwiftUI\.swift answers ax switch, which harness\.rs's ROLES",
      r"^KayaCompose\.kt answers ax switch, which harness\.rs's ROLES")),
    ("the Compose link word renamed",
     dict(kotlin_src=perturb("ax-words (the Compose link word renamed)",
                             KOTLIN, r'(this\[KayaAxKind\] = )"link"',
                             '"hyperlink"')),
     (r"^KayaCompose\.kt answers ax hyperlink, which harness\.rs's ROLES",
      r"^tools/scenes asserts ax link, which KayaCompose\.kt cannot")),
    ("the mac switch word renamed",
     dict(swift_src=perturb("ax-words (the mac switch word renamed)",
                            SWIFT, r'(subrole == "AXSwitch" \? )"switch"',
                            '"toggle"')),
     (r"^KayaSwiftUI\.swift answers ax toggle, which harness\.rs's ROLES",
      )),
):
    base = set(words_out)
    new = [line for line in ax_words(**kwargs) if line not in base]
    hits = [sum(1 for line in new if re.search(pat, line))
            for pat in findings]
    if len(new) != len(findings) or hits != [1] * len(findings):
        print(f"check-verbs: SELF-TEST FAIL ({label}: {len(new)} findings "
              f"introduced, want {len(findings)}, named {hits}):\n"
              + "\n".join(new), file=sys.stderr)
        raise SystemExit(1)
    print(f"check-verbs: ax-words negative ({label}): {len(new)}/"
          f"{len(findings)} findings named")

# AND A CENSUS THAT READS NOTHING: a scenes directory with no .steps in
# it is under the floor, never a clean sheet.
empty = g.scratch() / "no-scenes"
empty.mkdir(exist_ok=True)
under = [line for line in ax_words(scenes=empty) if "under the floor" in line]
print(f"check-verbs: ax-words negative (an empty scenes directory): "
      f"{len(under)}/1 findings named")
if len(under) != 1:
    print("check-verbs: SELF-TEST FAIL (an empty scenes directory passed "
          "the ax word census)", file=sys.stderr)
    raise SystemExit(1)

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

# AND THE PUMP'S OWN, three negatives, each watched.
for rel, pattern, repl, label, finding in (
    (SWIFT_ENTRY, r"(        kayaInstallLinkDoor\(\)\n)        "
     r"kayaStartPumpOnce\(\"launch\"\)\n", "",
     "the mac delegate's start removed",
     "macOS applicationDidFinishLaunching"),
    (SWIFT_ENTRY, r"(didFinishLaunchingWithOptions[^{]*\{\n)        "
     r"kayaStartPumpOnce\(\"launch\"\)\n", "",
     "the iOS delegate's start removed",
     "iOS didFinishLaunchingWithOptions"),
    (SWIFT, r"(            kayaPlaceWindow\(\)\n            )"
     r"kayaStartPumpOnce\(\"the primary root\"\)", "kayaStartCommandPump()",
     "the root starting the pump directly", "outside kayaStartPumpOnce"),
):
    drifted = perturb(f"pump-start ({label})", rel, pattern, repl)
    kwargs = ({"entry_src": drifted} if rel == SWIFT_ENTRY
              else {"swift_src": drifted})
    score = introduced(pump_start(**kwargs), pump_out, finding)
    named, total = score.split("/")
    if named == "0" or named != total:
        print(f"check-verbs: SELF-TEST FAIL ({label} scored {score} "
              f"named/introduced findings, want them equal and "
              f"nonzero)", file=sys.stderr)
        raise SystemExit(1)

# AND THE IMMERSIVE ARM'S OWN, four negatives, each watched.
for pattern, repl, label, finding in (
    (r"(            else onUi\(activity\) \{ )immersiveReading\(activity\)",
     'if (KayaSceneModel.windowFullscreen) "on" else "off"',
     "expect_fullscreen reading the prop",
     "reads KayaSceneModel.windowFullscreen|does not read immersiveReading"),
    (r"(            controller\.systemBarsBehavior =\n *)"
     r"WindowInsetsControllerCompat\.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE",
     "WindowInsetsControllerCompat.BEHAVIOR_DEFAULT",
     "the transient-bars behavior dropped", "transient-bars behavior"),
    (r"(                            KayaSceneModel\.windowFullscreen = readBool\(b\)\n)"
     r" *mountedActivity\?\.let \{\n *installImmersive\(it, "
     r"KayaSceneModel\.windowFullscreen\)\n *\}",
     "",
     "the prop never installed", "does not install immersive mode"),
    (r'("user_fullscreen" -> \{\n *)failures\.add\(',
     "installImmersive(activity, false); observed.add(",
     "a phone user door that pretends", "does not refuse on Android"),
):
    drifted = perturb(f"immersive ({label})", KOTLIN, pattern, repl)
    score = introduced(compose_immersive(kotlin_src=drifted), immersive_out,
                       finding)
    named, total = score.split("/")
    if named == "0" or named != total:
        print(f"check-verbs: SELF-TEST FAIL ({label} scored {score} "
              f"named/introduced findings, want them equal and "
              f"nonzero)", file=sys.stderr)
        raise SystemExit(1)

# AND THE NOTIFICATION AUTHORIZATION'S OWN, four negatives, each watched.
for pattern, repl, label, finding in (
    (r"(    )kayaNotificationAuthorization\(opts\)",
     "centre.requestAuthorization(options: opts)",
     "the post asking directly",
     "outside kayaNotificationAuthorization|with no `needs`"),
    (r"(        default:\n            )if needs\(settings\) \{ "
     r"then\(true, nil\) \} else \{ ask\(\) \}", "ask()",
     "a decided grant asking again", "does not consult `needs`"),
    (r"(        case \.denied:\n            then\()false",
     "true", "denied answered as granted", "answer .denied"),
    (r"(    kayaNotificationAuthorization\(opts)\)",
     ", needs: { $0.alertSetting == .enabled })",
     "the post needing alerts", "with no `needs`"),
):
    drifted = perturb(f"notify-auth ({label})", SWIFT, pattern, repl)
    score = introduced(notify_auth(swift_src=drifted), notify_auth_out,
                       finding)
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
# EVERY KIND IS ADDRESSABLE: five verbs resolve `kind@id` through ONE
# per-interpreter table, so a kind missing from it answers "no such
# target" for all of them (measured 2026-08-26 — the canvas fan-out never
# added `canvas` to KayaCompose.kt's kayaWidgetTarget). READ OUT OF EACH
# TABLE'S OWN BLOCK: both interpreters spell the kind string in their
# canvas-only helper too, so a file-wide pattern reads the wrong table.
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
    # WATCHED NEGATIVE, on every run: the arm is cut out of a COPY of
    # the block, with the substitution count printed.
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
# picker then falls back to its last-used location (docs/traps.md).
# THREE SITES, NOT TWO: harness.rs is the third implementation, the one
# the GTK and WinUI backends run.
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
# `failures` is named only by the verdict, printed LAST, so an abort
# before it takes the whole list and the log shows a crash with no
# reason. A failure is printed the moment it is final, with the TEXT
# interpolated: a fixed sentence names no cause and is printed for every
# one (docs/deferred.md).
for name, text, interp in (("KayaSwiftUI.swift", swift, r"\\\("),
                           ("KayaCompose.kt", kotlin, r"\$"),
                           ("harness.rs", harness, r"\{")):
    if not re.search("KAYA_HARNESS: step-failed " + interp, text):
        fail(f"{name} never prints `KAYA_HARNESS: step-failed <text>` "
             f"with the failure text interpolated — a step's failure "
             f"reaches the log only if it is printed when it becomes "
             f"final, not saved for the verdict")

# AND IN THE WRAPPER'S FINAL-FAILURE BRANCH, not merely somewhere in the
# file: the interpreters print this line twice for different reasons, so
# presence alone is satisfied by a copy on another path. harness.rs has
# no retryStep (its `poll` retries internally) and is held by the clause
# above alone.
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
# APPLY/KIND/PROP/COMMAND/MENU_KIND/MPROP/ROLE/ALIGN: all of them. VALUE:
# only the types reachable through the spec's PROPS PropKinds (the
# scene's prop typing keeps the rest off the pump). ROLE and ALIGN joined
# 2026-09-05: the `plain` role reached both interpreters by hand with no
# gate reading either copy (docs/tasks-plan.md R6).
# SWIPE joined 2026-09-27: expect_swipe_actions spells each edge by name in
# all three harnesses (docs/swipe-actions-plan.md §4).
# The entry, section and sheet prop tables and the detent enum joined the
# alternation with the sheet slice (docs/sheet-plan.md §3): three typed
# prop tables hand-copied into two interpreters with nothing pinning them.
rows = re.findall(r"pub(?:\(crate\))? const ((?:APPLY|KIND|PROP|COMMAND|VALUE|"
                  r"MENU_KIND|MPROP|ROLE|ALIGN|EPROP|SPROP|SHPROP|DETENT|SWIPE)"
                  r"_[A-Z_0-9]+): u\d+ = (\d+);", wire)
# THE CANVAS VOCABULARIES ride the op stream as i64 rather than u32, so
# the sweep above cannot see them by type and their prefixes are not in
# its alternation — five enums hand-copied into two interpreters, the
# shape check-file-modes exists for (docs/canvas-plan.md §3.6). Kotlin
# spells a Long literal with an L suffix, so the value pattern allows one.
canvas_rows = re.findall(
    r"pub(?:\(crate\))? const ((?:DRAW|PAINT|FILL|TEXT_ALIGN|TEXT_BASELINE)"
    r"_[A-Z_0-9]+): i64 = (\d+);", wire)
if len(canvas_rows) < 22:
    fail(f"only {len(canvas_rows)} canvas constants found in wire.rs — "
         f"the sweep reads nothing and would agree with everything")
rows += canvas_rows
# The rich text vocabularies, i64 on the wire (docs/rich-text-plan.md R3).
rich_rows = re.findall(
    r"pub(?:\(crate\))? const ((?:RICH_ATTR|BLOCK|EDIT_SOURCE)"
    r"_[A-Z_0-9]+): i64 = (\d+);", wire)
if len(rich_rows) < 18:
    fail(f"only {len(rich_rows)} rich-text constants found in wire.rs — "
         f"the sweep reads nothing and would agree with everything")
rows += rich_rows
role_rows = [r for r in rows if r[0].startswith("ROLE_")]
if len(role_rows) < 5:
    fail(f"only {len(role_rows)} role constants found in wire.rs — the "
         f"sweep reads nothing and would agree with everything")
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

# THE STAMPED-OBSERVATION RULE: a field the harness READS must be written
# on every platform the interpreter serves, or the other platform leaves
# it at its initial value and the verb reads a default that looks like an
# answer. So each field has at least one write OUTSIDE every platform
# conditional; nesting is tracked, since a write is "conditional"
# whenever ANY enclosing #if is.
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
# --- THE KEYED TARGET REACHES EVERY TAGGED KIND --------------------
# Every occurrence tag carries the table tag's own node-and-keys layout,
# so every arm resolves any tagged kind through it (docs/deferred.md's
# keyed-target entry). This pins each arm's generic spelling and refuses
# the column-only guard coming back — byte-frozen markers, doctored away
# one at a time and watched red.
KEYED_ARMS = [
    ("crates/kaya/src/gtk.rs",
     "let candidates = kind_registry(core, kind);",
     "let candidates: Vec<gtk4::Widget> = Vec::new();"),
    ("crates/kaya/src/winui/mod.rs",
     "let candidates = registry_ids(core, kind);",
     "let candidates: Vec<u64> = Vec::new();"),
    ("swift/KayaSwiftUI.swift",
     'kayaTableStamp(kind == "column" ? $0.sortTag : $0.tag)',
     "kayaTableStamp($0.sortTag)"),
    ("android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt",
     'tableStamp(if (kind == "column") n.sortTag else n.tag)',
     "tableStamp(n.sortTag)"),
]
# The first-copy read: the template node taken off the first copy carrying
# the id resolved only the first template's rows when five templates shared
# one id (tools/scenes/tasks.steps, 2026-09-05); every arm matches each copy
# under its own tag's node now (harness::table_tag_keys_match).
FIRST_COPY = [
    ("crates/kaya/src/gtk.rs", ".and_then(|tag| crate::harness::table_tag_node(&tag))"),
    ("crates/kaya/src/winui/mod.rs", ".and_then(|tag| crate::harness::table_tag_node(tag))"),
    ("crates/kaya/src/winui/mod.rs",
     ".and_then(|table| crate::harness::table_tag_node(&table.tag))"),
    ("swift/KayaSwiftUI.swift", ".compactMap({ stampOf($0)?.node }).first"),
    ("android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt", ".mapNotNull { stampOf(it)?.node }"),
]
COLUMN_ONLY = [
    ("crates/kaya/src/gtk.rs",
     "if kind != K::Column {\n                    return None;"),
    ("crates/kaya/src/winui/mod.rs",
     "if kind != K::Column {\n                    return Ok(None);"),
    ("swift/KayaSwiftUI.swift", 'guard kind == "column" else { return nil }'),
    ("android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt",
     'if (kind != "column") return null'),
]


# A SHEET IS A SURFACE THE LIVE CENSUS WALKS (docs/sheet-plan.md): the two
# interpreters answer a keyed target only from a presented root's subtree,
# and a walk that stops at windows, sections and entries reads a sheet's
# `entry@quick` as `no such target` with the sheet up (the task manager's
# quick-add, 2026-09-21). The sheet scene addresses by ordinal and cannot
# see it. Byte-frozen, cut and watched like the arms above.
LIVE_ROOTS = [
    ("swift/KayaSwiftUI.swift",
     "for sheet in kayaScene.sheets.values { if let root = sheet.root { stack.append(root) } }",
     "// sheets skipped"),
    ("android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt",
     "for (sheet in KayaSceneModel.sheets) sheet.root?.let { stack.addLast(it) }",
     "// sheets skipped"),
]


def keyed_problems(texts):
    bad = []
    for rel, marker, _ in LIVE_ROOTS:
        if texts[rel].count(marker) != 1:
            bad.append(f"{rel}: the live census no longer walks sheet roots "
                       f"(`{marker}` once) — a keyed target inside a sheet "
                       f"answers `no such target` with the sheet up")
    for rel, marker, _ in KEYED_ARMS:
        if texts[rel].count(marker) != 1:
            bad.append(f"{rel}: the keyed target arm no longer spells "
                       f"`{marker}` exactly once — a stamped copy of a "
                       f"non-column kind cannot be driven by key")
    for rel, guard in COLUMN_ONLY:
        if guard in texts[rel]:
            bad.append(f"{rel}: the column-only guard `{guard.strip()}` "
                       f"is back in the keyed target arm")
    for rel, read in FIRST_COPY:
        if read in texts[rel]:
            bad.append(f"{rel}: the first-copy read `{read}` is back in the "
                       f"keyed target arm — only the first template sharing "
                       f"an id would resolve")
    return bad


keyed_texts = {rel: (ROOT / rel).read_text(encoding="utf-8")
               for rel, _, _ in KEYED_ARMS}
keyed_out = keyed_problems(keyed_texts)
for rel, marker, broken in KEYED_ARMS + LIVE_ROOTS:
    doctored = dict(keyed_texts)
    doctored[rel] = g.doctor(f"keyed arm marker cut from {rel}",
                             keyed_texts[rel], re.escape(marker), broken)
    if not keyed_problems(doctored):
        fail(f"check-verbs SELF-TEST: {rel}'s keyed arm passed with "
             f"`{marker}` doctored to `{broken}`")
for rel, guard in COLUMN_ONLY + FIRST_COPY:
    doctored = dict(keyed_texts)
    doctored[rel] = keyed_texts[rel] + "\n" + guard + "\n"
    if not keyed_problems(doctored):
        fail(f"check-verbs SELF-TEST: {rel}'s forbidden spelling "
             f"`{guard.strip()}` restored passed")
if keyed_out:
    print("check-verbs: the keyed harness target must reach every "
          "tagged kind on every backend:", file=sys.stderr)
    print("\n".join(keyed_out), file=sys.stderr)
keyed_status = 1 if keyed_out else 0
print(f"check-verbs: keyed target arms: {len(KEYED_ARMS)} markers + "
      f"{len(LIVE_ROOTS)} live-root walks pinned, "
      f"{len(KEYED_ARMS) + len(LIVE_ROOTS) + len(COLUMN_ONLY) + len(FIRST_COPY)} "
      f"watched negatives refused",
      file=sys.stderr)

# --- THE REORDER'S INSERTION INDICATOR, ON THE ONE BACKEND THAT DRAWS
# --- ITS OWN (docs/dnd-plan.md §5 step 7)
# WinUI declines `CanReorderItems` (D8), so the platform draws no
# insertion line and kaya draws it. NO SCENE CAN SEE IT: the line is
# pixels, and expect_order, the drop's anchor and its before bit all
# answer identically with it gone — which is how a reorder could ship
# with no landing affordance at all and every lane stay green. So the
# four arms are byte-frozen here, doctored away one at a time.
WINUI = "crates/kaya/src/winui/mod.rs"
DROP_LINE_ARMS = [
    ("shown at the landing edge while a row drag hovers a reorderable row",
     "    if !dropping && reorder_row && verdict != crate::wire::DRAG_OP_NONE {\n"
     "        let _ = show_drop_line(&element, upper);\n"
     "    } else {\n"
     "        hide_drop_line();\n"
     "    }",
     "    let _ = (reorder_row, upper);"),
    ("cleared when the pointer leaves the row",
     "    element.DragLeave(&DragEventHandler::new(move |_, _| {\n"
     "        hide_drop_line();\n"
     "        Ok(())\n"
     "    }))?;\n",
     ""),
    ("painted in the platform's own token, never a literal",
     '    "Background=\\"{ThemeResource AccentFillColorDefaultBrush}\\" ",',
     '    "Background=\\"#FF0078D4\\" ",'),
    ("an adorner Popup, never a child of the For's own panel",
     "            let popup = Popup::new()?;\n"
     "            popup.SetChild(&line)?;",
     "            let popup = Popup::new()?;"),
]


def drop_line_problems(text):
    bad = []
    for what, marker, _ in DROP_LINE_ARMS:
        if text.count(marker) != 1:
            bad.append(f"{WINUI}: the reorder insertion indicator is no "
                       f"longer {what} — this arm's exact text is gone "
                       f"({marker.strip().splitlines()[0]!r})")
    # A LITERAL COLOUR IS THE BREACH the token clause exists to refuse,
    # and the marker above is only one spelling of it.
    xaml = re.search(r"const DROP_LINE_XAML.*?;", text, re.S)
    if xaml and re.search(r"#[0-9A-Fa-f]{6,8}", xaml.group(0)):
        bad.append(f"{WINUI}: DROP_LINE_XAML names a colour literal — the "
                   f"indicator wears the platform's accent token, the rule "
                   f"the table card already carries")
    return bad


drop_line_text = (ROOT / WINUI).read_text(encoding="utf-8")
drop_line_out = drop_line_problems(drop_line_text)
for _what, _marker, _broken in DROP_LINE_ARMS:
    _doctored = g.doctor(f"insertion indicator: {_what}", drop_line_text,
                         re.escape(_marker), _broken)
    if not drop_line_problems(_doctored):
        fail(f"check-verbs SELF-TEST: the insertion indicator passed with "
             f"the arm {_what!r} doctored away")
if drop_line_out:
    print("check-verbs: the reorder's insertion indicator is the one "
          "reorder affordance no scene can assert:", file=sys.stderr)
    print("\n".join(drop_line_out), file=sys.stderr)
drop_line_status = 1 if drop_line_out else 0
print(f"check-verbs: insertion indicator: {len(DROP_LINE_ARMS)} arms "
      f"pinned, {len(DROP_LINE_ARMS)} watched negatives refused",
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
    # ANCHORED ON THE VERDICT'S OWN `if`, not on the green line's text:
    # the Compose verdict spells two lines now (act one's and the ordinary
    # one, docs/tasks-s9-plan.md R6) and a pattern keyed on the literal
    # matched nothing, which is a self-test that proves nothing.
    ("a Compose dump on the pass path", KOTLIN,
     r'(val code = if \(failures\.isEmpty\(\)\) \{\n)',
     r'\1            KayaVTrace.dump("green")\n',
     "verb-trace dump site(s), want exactly 2"),
    ("the Rust watchdog dump moved off the fire path", HARNESS,
     r'crate::vtrace::dump\("the step ceiling fired: no verdict"\);\n',
     "", "verb-trace dump site(s), want exactly 2"),
    ("the Rust ring's pointer line drifted", VTRACE,
     r'appended to \{\}', "written to {}",
     "does not carry the verb-trace line shape"),
    # ANCHORED ON THE VERDICT'S OWN `if` for the Compose entry's reason:
    # the SwiftUI verdict spells two lines now (act one's and the ordinary
    # one, docs/tasks-s9-plan.md R6) and the green literal moved off the
    # print, so a pattern keyed on it matched nothing.
    ("a SwiftUI dump on the pass path (outside the crash handler)", SWIFT,
     r'(\n    if failures\.isEmpty \{\n)',
     r'\1        KayaVTrace.dump("green")\n',
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


# --- EVERY TARGET OF EVERY STEP NORMALIZES -------------------------
# A `kind@id[keys]` target means nothing until the runner resolves it
# through Stage::resolve_id, and that happens ONCE PER STEP over
# Step::targets_mut. A variant that carries two Targets and hands over
# one leaves the second with `index` 0 and its id still on it, so every
# rust-native backend addresses widget #0 and says nothing: `drag
# label#0 to label@row[a]` did exactly that on GTK, and NO LANE COULD
# SEE IT, because the mac interpreter parses the script text itself and
# resolves both ends by another route (2026-09-03, docs/traps.md).
# The rule is a census: a variant's Target fields, against the bindings
# its targets_mut arm hands over.


def split_top(text, opens="([{<", closes=")]}>"):
    """Comma-separated pieces at depth 0."""
    out, depth, start = [], 0, 0
    for i, ch in enumerate(text):
        if ch in opens:
            depth += 1
        elif ch in closes:
            depth -= 1
        elif ch == "," and depth == 0:
            out.append(text[start:i])
            start = i + 1
    out.append(text[start:])
    return [piece.strip() for piece in out if piece.strip()]


def balanced(text, at):
    """The group starting at `at` (an opening bracket), with its bracket."""
    pairs = {"(": ")", "{": "}", "[": "]"}
    close = pairs[text[at]]
    depth = 0
    for i in range(at, len(text)):
        if text[i] in pairs:
            depth += 1
        elif text[i] == close and depth == 1:
            return text[at:i + 1]
        elif text[i] in pairs.values():
            depth -= 1
    return text[at:]


def step_variants(harness_src):
    """variant name -> how many Target fields it carries."""
    anchor = re.search(r"enum Step \{", harness_src)
    if not anchor:
        return {}
    body = balanced(harness_src, harness_src.index("{", anchor.start()))[1:-1]
    # Comments carry the word Target in prose; blank them positionally.
    body = re.sub(r"//[^\n]*", "", body)
    out = {}
    for piece in split_top(body):
        m = re.match(r"([A-Z]\w*)", piece)
        if not m:
            continue
        out[m.group(1)] = len(re.findall(r"\bTarget\b", piece[m.end():]))
    return out


def targets_mut_bindings(harness_src):
    """variant name -> how many bindings its targets_mut pattern hands over."""
    anchor = harness_src.index("fn targets_mut(")
    body = balanced(harness_src, harness_src.index("{", anchor))
    out = {}
    for m in re.finditer(r"Step::(\w+)", body):
        rest = body[m.end():]
        lead = len(rest) - len(rest.lstrip())
        head = rest[lead:lead + 1]
        if head in "({":
            group = balanced(rest, lead)[1:-1]
            bound = [x for x in split_top(group)
                     if re.fullmatch(r"[a-z_][a-z_0-9]*", x) and x != "_"]
        else:
            bound = []
        out[m.group(1)] = max(out.get(m.group(1), 0), len(bound))
    return out


def target_census(harness_src):
    """Findings, plus (variants read, variants carrying 2+ Targets)."""
    declared = step_variants(harness_src)
    handed = targets_mut_bindings(harness_src)
    out = []
    for name, count in sorted(declared.items()):
        got = handed.get(name, 0)
        if got != count:
            out.append(
                f"Step::{name} carries {count} Target field(s) but "
                f"targets_mut hands over {got} — an unnormalized "
                f"`kind@id` target reaches the backend as index 0")
    return out, len(declared), sum(1 for n in declared.values() if n >= 2)


norm_out, norm_variants, norm_multi = target_census(harness)
if norm_variants < 30:
    g.refuse(f"read only {norm_variants} Step variants out of {HARNESS} — "
             f"the enum's shape moved and this census agrees with anything")
if norm_multi < 1:
    g.refuse("no Step variant carries two Targets, so the rule this clause "
             "exists for matches nothing and can only ever pass")
for line in norm_out:
    print(f"check-verbs: {line}", file=sys.stderr)
norm_status = 1 if norm_out else 0

# The watched negatives: the shipped defect itself, and the same shape one
# variant over. Each on a doctored copy, count printed, red demanded.
NORM_NEGATIVES = [
    ("the Drag verb's destination dropped again",
     r"Step::Drag\(source, destination, _\) => vec!\[source, destination\],",
     "Step::Drag(source, _, _) => vec![source],", "Step::Drag"),
    # NOT a rename of the binding: `_table` still reads as a binding
    # handed over, so the census could not see it and this negative
    # passed VACUOUSLY — invisibly, because every SELF-TEST `fail()`
    # below the first drain went into a list nothing read (fixed with
    # the second drain at the foot of this file). The whole arm goes,
    # which is what dropping a Target actually looks like.
    ("the fold verb's table dropped",
     r"Step::ExpectFolded\(child, table\) => \{\n"
     r"                let mut out = vec!\[child\];\n"
     r"                if let Some\(table\) = table \{\n"
     r"                    out\.push\(table\);\n"
     r"                \}\n"
     r"                out\n"
     r"            \}",
     "Step::ExpectFolded(child, _) => vec![child],",
     "Step::ExpectFolded"),
]
for label, pattern, repl, want in NORM_NEGATIVES:
    doctored = g.doctor(label, harness, pattern, repl)
    out, _, _ = target_census(doctored)
    if not any(want in line for line in out):
        fail(f"check-verbs SELF-TEST: {label} passed the target-normalization "
             f"census (wanted a finding naming {want}; got {out!r})")
# ... and a compliant two-Target variant stays quiet, so the census is not
# simply refusing everything.
SAMPLE = ("enum Step {\n    Alpha(Target, Target, bool),\n    Beta(Target),\n}\n"
          "fn targets_mut(&mut self) -> Vec<&mut Target> {\n    match self {\n"
          "        Step::Alpha(a, b, _) => vec![a, b],\n"
          "        Step::Beta(t) => vec![t],\n    }\n}\n")
sample_out, _, sample_multi = target_census(SAMPLE)
if sample_out or sample_multi != 1:
    fail(f"check-verbs SELF-TEST: a compliant two-Target variant was refused "
         f"({sample_out!r}, {sample_multi} multi-target variant(s))")
print(f"check-verbs: step targets: {norm_variants} variants read, "
      f"{norm_multi} carrying two, {len(NORM_NEGATIVES)} watched negatives "
      f"refused", file=sys.stderr)

# --- AN ACTION RETURNS ONCE THE APP HAS ANSWERED IT ------------------
# The Compose runner states that rule in its own words and `click` kept
# it alone: `choose`, `header_click`, `toggle` and `set_value` returned
# the moment they emitted, and the OTHER TWO runners waited on none of
# the five (docs/deferred.md, the Compose action-verb entry). NO SCENE
# CAN FAIL IT — every expect is a bounded retry, so an action whose
# answer is still in flight costs poll attempts and changes no verdict,
# while the step that pays is the one with no retry over it: another
# ACTION (crates/kaya/src/harness.rs, `Stage::type_text` point 4). So
# the arms are held statically, each read out of its OWN BLOCK: the
# helper's definition and one arm's call both name the function, so a
# file-wide search is satisfied by a runner that waits on `click` and
# nothing else.
ACTION_VERBS = (
    "click", "toggle", "set_value", "choose", "header_click",
    # The ten the rule reached second (docs/deferred.md's ten-verb entry).
    # `select_range` is NOT among them and never could be: it is the
    # GUEST's command (TX_SELECT_RANGE), read back with the
    # `expect_selection` OBSERVATION, and no runner has an arm for it —
    # the harness's one `select_*` action is `select_section`.
    "set_date", "set_time", "select_section", "set_text", "type",
    "menu_activate", "back", "close_window", "scroll_end", "resize_window",
    # The search field's clear affordance (docs/search-plan.md S5): the
    # text becoming empty is the app's answer.
    "clear_search",
    # The twelve the rule reached third (docs/deferred.md's dialog,
    # clipboard and gesture entry). Several answer through a PLATFORM
    # SURFACE rather than a widget — a dialog's own presentation, the
    # drag session, the input method's composition — so each was read
    # against the occurrence table before its half was decided:
    # `alert_choose` is answered by alert_result, `file_choose` and
    # `file_save` by file_dialog_result, `drag` and `drag_file` by
    # dropped/drag_ended, `shortcut` by the same menu_activated an item's
    # own activation emits, and `compose` by the text_changed the
    # composition lands. The other five ask the guest nothing and are in
    # QUIET_ONLY below.
    "alert_choose", "file_choose", "file_save", "drag", "drag_file",
    "shortcut", "compose",
    "file_dialog_goto", "file_dialog_name", "clipboard_seed",
    "context_open", "scroll_to_row",
    # THE LINK, WHICH THE PLATFORM ROUTES BACK (docs/app-links-plan.md
    # L5): the verb asks the platform to open the URL and the app answers
    # it through `link_opened`, so the answer-wait is the real one — the
    # step after it reads a screen the link pushed.
    "open_link",
    # The Return key as its own verb (docs/rich-text-plan.md R10): the
    # widget answers it as it answers a keystroke.
    "press",
    # The sheet's cancel path (docs/sheet-plan.md §4): the app answers it
    # with dismiss_requested or the dismissal lands and it hears
    # sheet_dismissed.
    "dismiss_sheet",
    # The number field's two user doors (docs/number-field-plan.md §5):
    # focus leaving it and a step each commit, value_committed the answer.
    "unfocus", "nudge",
    # The colour picker's settled choice (docs/color-picker-plan.md §5),
    # answered by color_changed.
    "set_color",
)

# A VERB THE GUEST IS NEVER ASKED ABOUT HAS NO ANSWER TO WAIT FOR.
# crates/kaya/src/spec.rs's occurrence table decides it: thirteen of the
# fifteen reach the app (button_clicked, toggled, value_changed,
# sort_requested, date_changed, time_changed, section_selected,
# text_changed, menu_activated, back_requested, close_requested), while a
# SCROLL and a RESIZE reach nothing — what answers them is a
# BACKEND-ORIGINATED report (the row window, the window's metrics) whose
# ops never go through Scene::apply, which is the one thing the Rust
# runner's signal is built not to count. So the wait after them would
# spend its whole bound measuring nothing. The wait BEFORE is kept and is
# the half that works: the previous step's answer has to be on the
# widgets before a container is driven to its end or a window is resized
# under it.
# AND FIVE MORE JOINED THEM with the twelve: what follows each is a
# BACKEND-ORIGINATED state the next verb reads, not an answer from the
# app — the panel's own navigation and name field (`file_dialog_goto`,
# `file_dialog_name`), the pasteboard (`clipboard_seed`), a menu that
# opened for the `menu_activate` after it (`context_open`), and the row
# window a virtualized tier reports, whose ops never go through
# Scene::apply (`scroll_to_row`).
QUIET_ONLY = ("scroll_end", "resize_window", "file_dialog_goto",
              "file_dialog_name", "clipboard_seed", "context_open",
              "scroll_to_row")

# A RUNNER THAT REFUSES A VERB OUTRIGHT PERFORMS NO ACTION, so neither
# half applies — Android owns neither chrome close nor window size
# (DESIGN.md). Each entry carries the sentence its arm refuses with and
# is held to still saying it AND to still doing nothing, because an
# exemption that has stopped matching a real arm is the next stale audit.
REFUSALS = {
    (KOTLIN, "close_window"): "close_window: this host has no chrome close",
    (KOTLIN, "resize_window"):
        "resize_window: this host does not command window size",
    # No foreign source reaches a phone's app (docs/dnd-plan.md D9), so
    # the arm refuses rather than fake a drop.
    (KOTLIN, "drag_file"): "drag_file is a depth slice on android",
    # A phone's number field has no stepping door (docs/number-field-plan.md
    # §3 rule 7), so the phone lanes cut the scene at the steps.
    (KOTLIN, "nudge"): "nudge: a phone's number field has no stepping door",
}
# A DEPTH STUB on an action verb is a refusal too, for as long as it stands:
# its row here reads `(KOTLIN, "<verb>"): 'depthStub("<scene>")'` and the
# negative below knows the shape (the search field's slice, 2026-09-06).
# What "does nothing" is, in the Compose runner: every arm that acts goes
# to the UI thread to do it.
KOTLIN_ACTS = "onUi("


def rust_action_arm(src, verb):
    """One `Step::<Verb>(..) => { .. }` block of harness.rs's dispatch."""
    variant = "".join(w.capitalize() for w in verb.split("_"))
    # A unit variant (`Step::DismissSheet =>`) carries no parens: the
    # sheet's cancel path names no target, the topmost sheet is the one.
    hits = list(re.finditer(r"Step::" + variant + r"(?:\([^()]*\))?\s*=>\s*\{", src))
    if len(hits) != 1:
        return None
    return balanced(src, src.index("{", hits[0].end() - 1))


def kotlin_action_arm(src, verb):
    """One `"<verb>" -> { .. }` block of KayaCompose.kt's step `when`. The
    labels are read as a GROUP: `set_date` and `set_time` share one arm,
    and a reader anchored on a lone label finds neither."""
    hits = [
        h for h in re.finditer(r'^\s*((?:"[a-z_]+"(?:, )?)+) -> \{', src, re.M)
        if f'"{verb}"' in h.group(1)
    ]
    if len(hits) != 1:
        return None
    return balanced(src, src.index("{", hits[0].end() - 1))


def swift_action_arm(src, verb):
    """One `case "<verb>":` arm of KayaSwiftUI.swift's step `switch`. It
    has no braces of its own, so it ends at the next label indented the
    same way; the labels are read as a group, as Kotlin's are."""
    hits = [
        h for h in re.finditer(r'^(\s*)case ((?:"[a-z_]+"(?:, )?)+):', src, re.M)
        if f'"{verb}"' in h.group(2)
    ]
    if len(hits) != 1:
        return None
    indent = hits[0].group(1)
    nxt = re.search(r"^" + indent + r"(?:case |default:|\})",
                    src[hits[0].end():], re.M)
    return src[hits[0].start(): hits[0].end() + (nxt.start() if nxt else 0)]


# runner file, arm reader, (the wait BEFORE the action, the wait AFTER)
ANSWER_RUNNERS = (
    (HARNESS, rust_action_arm, ("await_quiet()", "await_answer(")),
    (SWIFT, swift_action_arm, ("kayaAwaitQuiet()", "kayaAwaitAnswer(")),
    (KOTLIN, kotlin_action_arm, ("kayaAwaitQuiet()", "kayaAwaitAnswer(")),
)
ANSWER_KWARG = {HARNESS: "harness_src", SWIFT: "swift_src",
                KOTLIN: "kotlin_src"}


def answer_wait(harness_src=None, swift_src=None, kotlin_src=None):
    """Findings, and how many action arms were actually read."""
    bad = []
    read = 0
    given = {HARNESS: harness_src, SWIFT: swift_src, KOTLIN: kotlin_src}

    def cannot(rel):
        return lambda src, exc: ("cannot read " + src + " for the action "
                                 "wait (" + str(exc.strerror) + "): the "
                                 "runner this rule holds is not there")

    for rel, reader, (before, after) in ANSWER_RUNNERS:
        text = source_text(given[rel], rel, bad, cannot(rel))
        if text is None:
            continue
        for verb in ACTION_VERBS:
            body = reader(text, verb)
            if body is None:
                bad.append(f"{rel}: no single `{verb}` action arm to read — "
                           f"the dispatch moved and this census would agree "
                           f"with anything")
                continue
            read += 1
            refusal = REFUSALS.get((rel, verb))
            if refusal is not None:
                if refusal not in body:
                    bad.append(
                        f"{rel}: the `{verb}` arm is exempt from the wait "
                        f"because it REFUSES the verb ({refusal!r}) and it "
                        f"no longer says that — an arm that acts takes both "
                        f"halves like every other, so either the sentence "
                        f"or this exemption is stale")
                if KOTLIN_ACTS in body:
                    bad.append(
                        f"{rel}: the `{verb}` arm is exempt from the wait as "
                        f"a refusal that does nothing, and it now calls "
                        f"`{KOTLIN_ACTS}` — an arm that reaches the UI "
                        f"thread ACTS, and an action returns once the app "
                        f"has answered it")
                continue
            halves = ((before, "before"),)
            if verb not in QUIET_ONLY:
                halves += ((after, "after"),)
            for call, when in halves:
                if call not in body:
                    bad.append(
                        f"{rel}: the `{verb}` arm never calls `{call}` "
                        f"{when} it acts — AN ACTION RETURNS ONCE THE APP "
                        f"HAS ANSWERED IT, and this one returns the moment "
                        f"it emits, so the step after it starts its clock "
                        f"with the answer still in flight")
    return bad, read


answer_out, answer_read = answer_wait()
g.counted("action arms read across the three runners", answer_read,
          floor=len(ACTION_VERBS) * len(ANSWER_RUNNERS))
for line in answer_out:
    print(f"check-verbs: {line}", file=sys.stderr)
answer_status = 1 if answer_out else 0

# The watched negatives: BOTH HALVES of the rule on EACH runner, cut out
# of one arm at a time on a doctored copy — a wait deleted from the arm
# that has no other reason to name it.
ANSWER_NEGATIVES = (
    (HARNESS, "header_click", r"\n\s*await_answer\(answered\);", "await_answer("),
    (HARNESS, "toggle", r"\n\s*await_quiet\(\);", "await_quiet()"),
    (SWIFT, "choose", r"\n\s*kayaAwaitAnswer\(answered\)", "kayaAwaitAnswer("),
    (SWIFT, "click", r"\n\s*kayaAwaitQuiet\(\)", "kayaAwaitQuiet()"),
    (KOTLIN, "toggle", r"\n\s*else kayaAwaitAnswer\(answered\)",
     "kayaAwaitAnswer("),
    (KOTLIN, "header_click", r"\n\s*kayaAwaitQuiet\(\)", "kayaAwaitQuiet()"),
    # ... and one of the TEN on each runner, the two QUIET_ONLY verbs
    # among them: their one half is the whole rule they carry, so an
    # exemption from the wait after must not become an exemption from
    # the wait before.
    (HARNESS, "set_text", r"\n\s*await_answer\(answered\);", "await_answer("),
    (HARNESS, "scroll_end", r"\n\s*await_quiet\(\);", "await_quiet()"),
    (SWIFT, "menu_activate", r"\n\s*kayaAwaitQuiet\(\)", "kayaAwaitQuiet()"),
    (SWIFT, "resize_window", r"\n\s*kayaAwaitQuiet\(\)", "kayaAwaitQuiet()"),
    (KOTLIN, "back", r"\n\s*kayaAwaitAnswer\(answered\)", "kayaAwaitAnswer("),
    (KOTLIN, "type", r"\n\s*kayaAwaitQuiet\(\)", "kayaAwaitQuiet()"),
    # ... and one of the TWELVE on each runner, a quiet-only verb among
    # them for the reason above.
    (HARNESS, "alert_choose", r"\n\s*await_answer\(answered\);",
     "await_answer("),
    (HARNESS, "clipboard_seed", r"\n\s*await_quiet\(\);", "await_quiet()"),
    (SWIFT, "file_save", r"\n\s*kayaAwaitAnswer\(answered\)",
     "kayaAwaitAnswer("),
    (SWIFT, "scroll_to_row", r"\n\s*kayaAwaitQuiet\(\)", "kayaAwaitQuiet()"),
    (KOTLIN, "compose", r"\n\s*else kayaAwaitAnswer\(answered\)",
     "kayaAwaitAnswer("),
    (KOTLIN, "context_open", r"\n\s*kayaAwaitQuiet\(\)",
     "kayaAwaitQuiet()"),
)
for rel, verb, pattern, call in ANSWER_NEGATIVES:
    reader = dict((r, fn) for r, fn, _ in ANSWER_RUNNERS)[rel]
    whole = real(rel)
    arm = reader(whole, verb)
    if arm is None:
        fail(f"check-verbs SELF-TEST: {rel} has no single `{verb}` action "
             f"arm to doctor")
    cut = g.doctor(f"the {verb} arm's `{call}` cut out of {rel}", arm,
                   pattern, "")
    found, _ = answer_wait(**{ANSWER_KWARG[rel]: whole.replace(arm, cut, 1)})
    if not [line for line in found
            if line not in answer_out and f"`{verb}` arm" in line
            and call in line]:
        fail(f"check-verbs SELF-TEST: the action-wait census passed with "
             f"`{call}` cut out of {rel}'s `{verb}` arm")
# AND THE EXEMPTIONS THEMSELVES, both ways: a refusal that stopped saying
# what it refuses, and a refusal that started acting. An exemption nobody
# watches is how a verb leaves the rule quietly.
REFUSAL_NEGATIVES = 0
for (refused_rel, refused_verb), sentence in REFUSALS.items():
    reader = dict((r, fn) for r, fn, _ in ANSWER_RUNNERS)[refused_rel]
    whole = real(refused_rel)
    arm = reader(whole, refused_verb)
    if arm is None:
        fail(f"check-verbs SELF-TEST: {refused_rel} has no single "
             f"`{refused_verb}` arm to doctor for the refusal exemption")
        continue
    # A DEPTH STUB refuses through the helper and has no failure sentence
    # to bank, so its "started acting" perturbation puts the UI hop in
    # front of the stub call instead (docs/search-plan.md §6).
    acting = (r'depthStub\(', KOTLIN_ACTS + "activity) { true }; depthStub(") \
        if sentence.startswith("depthStub(") \
        else (r'failures\.add\(', KOTLIN_ACTS + "activity) { true }; failures.add(")
    for label, pattern, repl in (
        ("the refusal sentence", re.escape(sentence), "gone"),
        ("a refusal that started acting", *acting),
    ):
        cut = g.doctor(
            f"{label} in {refused_rel}'s `{refused_verb}` arm", arm,
            pattern, repl)
        found, _ = answer_wait(
            **{ANSWER_KWARG[refused_rel]: whole.replace(arm, cut, 1)})
        if not [line for line in found if line not in answer_out
                and f"`{refused_verb}` arm" in line]:
            fail(f"check-verbs SELF-TEST: the action-wait census passed "
                 f"with {label} in {refused_rel}'s `{refused_verb}` arm")
        REFUSAL_NEGATIVES += 1
print(f"check-verbs: an action returns once the app has answered it: "
      f"{answer_read} action arms in 3 runners "
      f"({len(QUIET_ONLY)} verbs the guest is never asked about carry the "
      f"wait before alone, {len(REFUSALS)} arms refuse the verb and carry "
      f"neither), {len(ANSWER_NEGATIVES) + REFUSAL_NEGATIVES} watched "
      f"negatives refused", file=sys.stderr)


# --- THE REORDER'S INSERTION INDICATOR IS DRAWN --------------------
# docs/dnd-plan.md D8 declined WinUI's CanReorderItems because it writes
# the model, and its insertion line and auto-scroll went with it — so the
# two widget backends draw the line themselves (§5 step 7). NO SCENE CAN
# SEE IT: the line is pixels, and every reorder observable (expect_order,
# the dropped occurrence's anchor and its before bit) answers identically
# with it gone, which is how a reorder can ship with no landing feedback
# at all and every lane stay green. So the LINKS are held statically —
# the sheet, the provider that carries it to the display, and the six
# call sites inside the reorder's own installer — each removable on its
# own and each watched being removed. GTK's half only; WinUI's is that
# backend's own slice.
GTK = "crates/kaya/src/gtk.rs"

INDICATOR_SITES = [
    ("the enter arm puts it up", "show_insertion(&enter_rows, x, y);"),
    ("the motion arm puts it up", "show_insertion(&motion_rows, x, y);"),
    ("the motion arm takes it down when the drag stops being takeable",
     "clear_insertion(&motion_rows);"),
    ("the leave arm takes it down",
     "target.connect_drag_leave(move |_target, _drop| "
     "clear_insertion(&leave_rows));"),
    ("the drop arm takes it down", "clear_insertion(&drop_rows);"),
    ("the drag's end takes it down", "clear_insertion(&end_rows);"),
]
INDICATOR_SHEET = [
    ("the before edge's rule", ".kaya-drop-before { background-image: "
     "linear-gradient(to bottom, "),
    ("the onto edge's rule", ".kaya-drop-after { background-image: "
     "linear-gradient(to top, "),
    ("the sheet is loaded", 'load_kaya_css(&dnd_css, "drop indicator", '
     "DND_CSS, &css_error);"),
    ("the provider reaches the display",
     "gtk4::style_context_add_provider_for_display(\n"
     "                &display,\n"
     "                &dnd_css,"),
]


def reorder_body(gtk_src):
    """install_reorder's own block, or None."""
    at = gtk_src.find("fn install_reorder(")
    if at < 0:
        return None
    return balanced(gtk_src, gtk_src.index("{", gtk_src.index(")", at)))


def indicator_census(gtk_src):
    """Findings, plus the length of the installer body that was read."""
    out = []
    body = reorder_body(gtk_src)
    if body is None:
        return ["crates/kaya/src/gtk.rs declares no install_reorder, so the "
                "insertion-indicator clause read nothing"], 0
    for label, marker in INDICATOR_SITES:
        if body.count(marker) != 1:
            out.append(f"the reorder's insertion indicator: {label} — "
                       f"`{marker}` stands {body.count(marker)} times inside "
                       f"install_reorder, wanted once (docs/dnd-plan.md "
                       f"§5 step 7)")
    for label, marker in INDICATOR_SHEET:
        if marker not in gtk_src:
            out.append(f"the reorder's insertion indicator: {label} — "
                       f"gtk.rs no longer spells `{marker.strip()}`, so the "
                       f"class is added to a row nothing paints")
    return out, len(body)


ind_out, ind_read = indicator_census(real(GTK))
if ind_read < 500:
    g.refuse(f"read only {ind_read} characters of install_reorder out of "
             f"{GTK} — the installer moved and this census agrees with "
             f"anything")
for line in ind_out:
    print(f"check-verbs: {line}", file=sys.stderr)
ind_status = 1 if ind_out else 0

gtk_real = real(GTK)
for label, marker in INDICATOR_SITES + INDICATOR_SHEET:
    doctored = g.doctor(f"the indicator's {label} cut", gtk_real,
                        re.escape(marker), "")
    if not indicator_census(doctored)[0]:
        fail(f"check-verbs SELF-TEST: the insertion-indicator census passed "
             f"with `{marker}` cut out of {GTK}")
print(f"check-verbs: the reorder's insertion indicator: "
      f"{len(INDICATOR_SITES)} call sites + {len(INDICATOR_SHEET)} sheet "
      f"links, {len(INDICATOR_SITES) + len(INDICATOR_SHEET)} watched "
      f"negatives refused", file=sys.stderr)

# EVERY SELF-TEST FAILURE BELOW THE FIRST DRAIN REACHES THE EXIT. The
# `if failures:` above runs where the module reaches it, and the seven
# SELF-TEST `fail()` calls after it appended to a list nothing read
# again — so a watched negative that PASSED its doctored copy printed
# nothing and this gate exited OK, which is the one failure a guard may
# not have.
if failures:
    for f_ in failures:
        print(f"check-verbs: {f_}", file=sys.stderr)
    raise SystemExit(1)
# THE RICH LABEL'S TWO INVISIBLE HALVES (docs/rich-text-plan.md §15): no
# lane drives `format label#N`, so the four arms' refusal sentence is
# held equal here, flattened over each language's continuations; and no
# observable says the runs were DRAWN — `expect` reads the text and
# `expect_runs` the two tables — so each arm's label draw must name its
# platform's per-run trait API (check-table-card's shape).
LABEL_REFUSAL = ("is a label — a format act covers the widget's own selection "
                 "and a label has none")
LABEL_DRAWS = [
    ("KayaSwiftUI.swift", SWIFT,
     r"Text\(AttributedString\(kayaAttributedDocument\(", None,
     [r"kayaLabelBaseFont\(node\)"]),
    ("gtk.rs", GTK, r"fn draw_rich_label\(", r"\n}\n",
     [r"AttrList::new\(\)", r"set_markup\("]),
    ("winui/mod.rs", WINUI, r"fn label_restyle\(", r"\n}\n",
     [r"TextDecorations::", r"Hyperlink::new\(\)"]),
    ("KayaCompose.kt", KOTLIN, r"fun kayaRichAnnotated\(", r"\n}\n",
     [r"addStyle\(", r"LinkAnnotation"]),
]


def label_flatten(text):
    text = re.sub(r"\\\n\s*", "", text)          # Rust's continuation
    text = re.sub(r'"\s*\+\s*"', "", text)       # Swift/Kotlin concatenation
    return text


def label_clauses(gtk_src=None, winui_src=None, swift_src=None,
                  kotlin_src=None):
    bad = []
    srcs = {GTK: gtk_src, WINUI: winui_src, SWIFT: swift_src, KOTLIN: kotlin_src}
    for name, rel in (("gtk.rs", GTK), ("winui/mod.rs", WINUI),
                      ("KayaSwiftUI.swift", SWIFT), ("KayaCompose.kt", KOTLIN)):
        text = srcs[rel] if srcs[rel] is not None else real(rel)
        if LABEL_REFUSAL not in label_flatten(text):
            bad.append(f"{name} refuses a format on a label in other words than "
                       f"'{LABEL_REFUSAL}' (docs/rich-text-plan.md §15) — the "
                       f"three harnesses' sentence is compared byte for byte and "
                       f"no lane drives it")
    for name, rel, anchor, end, apis in LABEL_DRAWS:
        text = srcs[rel] if srcs[rel] is not None else real(rel)
        m = re.search(anchor, text)
        if not m:
            bad.append(f"{name} has no rich-label draw (wanted /{anchor}/)")
            continue
        body = text[m.start():]
        if end:
            stop = re.search(end, body)
            body = body[:stop.end()] if stop else body
        else:
            body = "\n".join(body.split("\n")[:6])
        for api in apis:
            if not re.search(api, body):
                bad.append(f"{name}'s rich-label draw does not name its per-run "
                           f"trait API /{api}/ — an arm that set the text and "
                           f"ignored every trait passes the whole scene")
    return bad


label_out = label_clauses()
label_status = 0
for line in label_out:
    print(f"check-verbs: {line}", file=sys.stderr)
    label_status = 1
for label, kwargs, finding in (
    ("the mac label refusal reworded",
     dict(swift_src=perturb("label-refusal (mac reworded)", SWIFT,
                            r'(a format act covers the widget\'s own )"',
                            'range"')),
     r"^KayaSwiftUI\.swift refuses a format on a label in other words"),
    ("the gtk label draw without its attribute list",
     dict(gtk_src=perturb("label-draw (gtk attrs renamed)", GTK,
                          r"(fn draw_rich_label\([\s\S]*?)AttrList::new\(\)",
                          "AttrList::gone()")),
     r"^gtk\.rs's rich-label draw does not name its per-run trait API"),
):
    score_or_die(introduced(label_clauses(**kwargs), label_out, finding), label)

# THE POLISH PASS (docs/rich-text-plan.md §18): a code run's GROUND and a
# quote's RULE are pixels — expect_runs reads the run table and no ink
# probe samples a rich field — so an arm that dropped either draws the
# same runs and passes every lane. Each arm's own style site is held to
# naming the identifier it paints with, the label draw's shape one row
# over; a row joins the table when its arm lands, and an arm whose site
# is not in the table is red here rather than absent.
POLISH_DRAWS = [
    ("gtk.rs", GTK, "the code ground",
     r"fn style_rich_tag\(", r"\n}\n",
     [r"set_background_rgba\(Some\(&rich_ground\(view, CODE_GROUND_ALPHA\)\)\)",
      r"set_paragraph_background_rgba\(Some\(&rich_ground\(\s*view,\s*CODE_GROUND_ALPHA,?\s*\)\)\)"]),
    ("gtk.rs", GTK, "the quote tint",
     r"fn style_rich_tag\(", r"\n}\n",
     [r"set_paragraph_background_rgba\(Some\(&rich_ground\(\s*view,\s*QUOTE_GROUND_ALPHA,?\s*\)\)\)"]),
    # snapshot_layer lives inside `mod rich_view`, so its body ends at the
    # indented brace; `\n}\n` would run it to the module's end.
    ("gtk.rs", GTK, "the quote rule",
     r"fn snapshot_layer\(", r"\n    \}\n",
     [r"snapshot\.append_color\(", r"QUOTE_RULE_WIDTH", r"line_yrange\("]),
    ("gtk.rs", GTK, "the appearance flip",
     r"fn restyle_rich_grounds\(", r"\n}\n",
     [r"style_rich_tag\(&view, &tag, &tag_name\)", r"draw_rich_label\("]),
    # Both Apple platforms: the ground and the rule are DRAWN by a TextKit 2
    # fragment off kaya's own keys, never stored as .backgroundColor, which
    # the accessibility read would answer as a highlight (measured).
    ("KayaSwiftUI.swift", SWIFT, "the code ground and quote rule",
     r"class KayaRichFragment", r"\n}\n",
     [r"kayaGroundKey", r"kayaRuleKey", r"kayaCodeGround", r"kayaQuoteRule",
      r"renderingSurfaceBounds", r"\.fill\("]),
    # WinUI: ITextCharacterFormat has ONE BackgroundColor and find's
    # highlight already owned it, so the order is stated in rich_ground
    # (highlight > code > quote) and the highlights read compares the
    # colour to the highlight's own rather than to AutoColor (a code run
    # read as a highlight before, measured). No quote rule is drawable
    # there: indent and tint.
    ("winui/mod.rs", WINUI, "the code and quote grounds",
     r"fn rich_ground\(", r"\n}\n",
     [r"code_ground", r"quote_ground"]),
    ("winui/mod.rs", WINUI, "the ground and indent written",
     r"fn rich_write_format\(", r"\n}\n",
     [r"SetBackgroundColor\(match rich_ground\(", r"SetIndents\(0\.0, indent, 0\.0\)"]),
    # The rich LABEL's ground on WinUI is a TextHighlighter per colour over
    # the block (Run/Span/Hyperlink carry no background); the restyle row
    # has the teeth, since a restyle that stopped calling the painter draws
    # the same runs and passes every lane.
    ("winui/mod.rs", WINUI, "the label's code ground",
     r"fn label_paint_grounds\(", r"\n}\n",
     [r"block\.TextHighlighters\(\)", r"rich_ground\(&attrs, palette\)",
      r"TextHighlighter::new\(\)"]),
    ("winui/mod.rs", WINUI, "the label restyle painting its grounds",
     r"fn label_restyle\(", r"\n}\n",
     [r"label_paint_grounds\(block, text, runs\)"]),
    ("winui/mod.rs", WINUI, "the highlights read keyed on the highlight's own colour",
     r"fn painted_runs\(", r"\n}\n",
     [r"== HIGHLIGHT_BACKGROUND"]),
    ("KayaCompose.kt", KOTLIN, "the code ground",
     r"fun kayaRichSpanStyle\(", r"\n}\n",
     [r"background = if \(mono\) palette\.code"]),
    ("KayaCompose.kt", KOTLIN, "the quote rule",
     r"fun (?:[\w.]+\.)?DrawScope\.kayaRichQuoteRule\(", r"\n}\n",
     [r"drawRect\(", r"getLineTop\(", r"getLineBottom\("]),
    ("KayaCompose.kt", KOTLIN, "the quote rule's call under the field",
     r"fun KayaHighlightLayer\(", r"\n}\n",
     [r"kayaRichQuoteRule\("]),
]


def polish_clauses(gtk_src=None, winui_src=None, swift_src=None,
                   kotlin_src=None):
    bad = []
    srcs = {GTK: gtk_src, WINUI: winui_src, SWIFT: swift_src, KOTLIN: kotlin_src}
    for name, rel, what, anchor_re, end, apis in POLISH_DRAWS:
        text = srcs[rel] if srcs[rel] is not None else real(rel)
        m = re.search(anchor_re, text)
        if not m:
            bad.append(f"{name} has no site for {what} (wanted /{anchor_re}/)")
            continue
        body = text[m.start():]
        stop = re.search(end, body)
        body = body[:stop.end()] if stop else body
        for api in apis:
            if not re.search(api, body):
                bad.append(f"{name}'s site for {what} does not name /{api}/ — "
                           f"an arm that dropped it draws the same runs and "
                           f"passes every lane (docs/rich-text-plan.md §18)")
    arms = {rel for _, rel, *_ in POLISH_DRAWS}
    for name, rel in (("gtk.rs", GTK), ("winui/mod.rs", WINUI),
                      ("KayaSwiftUI.swift", SWIFT), ("KayaCompose.kt", KOTLIN)):
        if rel not in arms:
            bad.append(f"{name} has no row in POLISH_DRAWS — its code ground "
                       f"and quote rule are held by nothing")
    return bad


# A LABEL'S DOCUMENT IS INLINE ONLY (docs/rich-text-plan.md §15 R8, §18): the
# core refuses a block run on a label, so a label never carries a quote, and
# the Compose label builder and label arm drew one anyway until 2026-09-16
# (pruned; the textarea keeps the rule). The two label sites may not name
# the quote rule or the quote paragraph style again — dead code no scene can
# reach is what this file exists to refuse.
LABEL_NO_QUOTE = [
    ("the Compose label builder", r"internal fun kayaRichAnnotated\(", r"\n}\n"),
    ("the Compose label arm", r"^        KayaCompose\.KIND_LABEL ->",
     r"\n        KayaCompose\.KIND_"),
]


def label_no_quote_clauses(kotlin_src=None):
    bad = []
    text = kotlin_src if kotlin_src is not None else real(KOTLIN)
    for what, anchor_re, end in LABEL_NO_QUOTE:
        m = re.search(anchor_re, text, re.M)
        if not m:
            bad.append(f"KayaCompose.kt has no site for {what} (wanted /{anchor_re}/)")
            continue
        body = text[m.end():]
        stop = re.search(end, body)
        body = body[:stop.start()] if stop else body
        for name in ("kayaRichQuoteRule(", "KAYA_RICH_QUOTE_PARAGRAPH"):
            if name in body:
                bad.append(f"{what} names {name} — a label's document is inline only, "
                           f"so that path draws for no document that can exist "
                           f"(docs/rich-text-plan.md §18)")
    return bad


polish_out = polish_clauses() + label_no_quote_clauses()
polish_status = 0
for line in polish_out:
    print(f"check-verbs: {line}", file=sys.stderr)
    polish_status = 1
for label, kwargs, finding in (
    ("the compose code ground dropped",
     dict(kotlin_src=perturb("polish (compose ground dropped)", KOTLIN,
                             r"(background = if \(mono\) )palette\.code",
                             "Color.Unspecified")),
     r"^KayaCompose\.kt's site for the code ground does not name"),
    ("the gtk quote rule drawing nothing",
     dict(gtk_src=perturb("polish (gtk rule cut)", GTK,
                          r"(fn snapshot_layer\([\s\S]*?)snapshot\.append_color\(",
                          "snapshot.append_nothing(")),
     r"^gtk\.rs's site for the quote rule does not name /snapshot"),
    ("the apple fragment painting nothing",
     dict(swift_src=perturb("polish (apple fragment fill cut)", SWIFT,
                            r"(class KayaRichFragment[\s\S]*?)\.fill\(",
                            ".stroke(")),
     r"^KayaSwiftUI\.swift's site for the code ground and quote rule does not name /\\.fill"),
    ("the winui highlights read keyed on any colour again",
     dict(winui_src=perturb("polish (winui read keyed on AutoColor)", WINUI,
                            r"(fn painted_runs\([\s\S]*?)== HIGHLIGHT_BACKGROUND",
                            "!= AUTO_COLOR")),
     r"^winui/mod\.rs's site for the highlights read keyed on the highlight's own"),
    ("the winui label restyle no longer painting",
     dict(winui_src=perturb("polish (winui label painter dropped)", WINUI,
                            r"(fn label_restyle\([\s\S]*?)label_paint_grounds\(block, text, runs\)",
                            "label_skip_grounds(block, text, runs)")),
     r"^winui/mod\.rs's site for the label restyle painting its grounds does not name"),
    ("the compose label builder drawing a quote again",
     dict(kotlin_src=perturb("polish (compose label quote re-added)", KOTLIN,
                             r"(internal fun kayaRichAnnotated\([^\n]*\n)",
                             "    val dead = KAYA_RICH_QUOTE_PARAGRAPH\n")),
     r"^the Compose label builder names KAYA_RICH_QUOTE_PARAGRAPH"),
    ("the compose quote rule drawing nothing",
     dict(kotlin_src=perturb("polish (compose rule cut)", KOTLIN,
                             r"(fun (?:[\w.]+\.)?DrawScope\.kayaRichQuoteRule\([\s\S]*?)drawRect\(",
                             "drawNothing(")),
     r"^KayaCompose\.kt's site for the quote rule does not name /drawRect"),
):
    score_or_die(introduced(polish_clauses(**kwargs)
                            + label_no_quote_clauses(kwargs.get("kotlin_src")),
                            polish_out, finding), label)

# THE SEED TAKES THE SEAT'S FOCUS BEFORE IT SPAWNS THE WRITER (GTK;
# docs/deferred.md's wayland clipboard seed entry). On wayland a client is
# handed a data offer only while its surface holds the seat's keyboard
# focus, so a seed against a window that lost it waits five seconds for an
# offer that cannot come — measured 2026-09-18 with a second client on the
# leg's own session: 0/5 legs before, 5/5 after. NO LANE CAN SEE THE RULE
# GO: every wayland session this lane boots holds exactly one window, so
# the focus is the guest's anyway and a seed with the request deleted is
# green on every leg of every matrix; the class shows only when something
# takes the seat. AND THE READING MAY NOT COME FROM INSIDE THE PROCESS:
# `gtk_window_is_active` is false for every step of a GREEN wayland leg
# (gtk.rs, ClipView::active) and `present()` was measured losing — sway
# denies the self-activation token — so the compositor is asked and its own
# answer is what the sentence carries (invariant 3).
#
# AND THE COPY VERB ASKS TOO, since 2026-09-18 (that entry's STILL OPEN half,
# docs/traps.md's wayland seat entry, trap 5): TAKING the selection needs an
# input serial, and the harness earns one with a wtype F24 tap the compositor
# delivers TO WHOEVER HOLDS THE FOCUS — so a copy made while another surface
# holds the seat is dropped SILENTLY, gdk goes on believing this process owns
# the board (`app_is_own_writer=true`, its own formats still listed), every
# `expect_clipboard` then reads "" for fifteen seconds, and a later seed
# expires EVEN WITH ITS OWN GRANT because the process it seeds never made its
# copy — measured twice in five runs of the whole scene under the thief. ONE
# request and ONE parse serve both sides (`clipboard_focus(what)`) and the
# copy's answer rides the copy's OWN verb-trace record, so a red with green
# seeds and failed copies names the seat instead of pointing at the seed.
# ONCE PER COPY, not once per scene: the seat can be taken between two copies
# of one leg, and under the thief it was.
SEED_FOCUS = [
    ("the request stands before the writer is spawned", "clipboard_seed",
     r"let focus = clipboard_focus\(\"clipboard_seed\"\);[\s\S]*?"
     r"foreign_clip_write\(mime, bytes\);",
     "a seed that asks for the focus AFTER the writer has set the "
     "selection has already missed the offer"),
    ("the compositor is asked, by this process's own pid",
     "clipboard_focus", r'say\(format!\("\[pid=\{pid\}\] focus"\)\)',
     "the seat's focus is the compositor's to give, and no reading inside "
     "this process can even see it"),
    ("the grant is READ BACK out of the compositor's own tree",
     "clipboard_focus",
     r'format!\("\[pid=\{pid\} con_id=__focused__\] nop',
     "sway's `success: true` is about the COMMAND, not about the seat a "
     "moment later — measured 2026-09-18, it answered success for a focus "
     "that never moved and the copy reported a grant it did not have"),
    ("a grant that did not take is its own answer", "clipboard_focus",
     r'focus=granted-not-held\(\{seen\}\)',
     "folded into `granted` it is the false green this read-back exists to "
     "end; folded into `refused` it would blame the compositor for a "
     "request it honoured"),
    ("only a wayland session pays for it", "clipboard_focus",
     r"if !linux_wayland_session\(\) \{\s*return String::new\(\);",
     "x11 serves its selection to any client that asks, so the request "
     "would be one spawn per seed for nothing"),
    ("the grant is read out of the compositor's own answer",
     "clipboard_focus",
     r'out\.status\.success\(\)\s*&&\s*answer\.replace\([^)]*\)\s*'
     r'\.contains\(',
     'sway answers `success: false, error: "No matching node."` when the '
     "criteria match nothing (measured), so a request that read only the "
     "exit status would report a grant that never happened"),
    ("the expiry says what the focus request answered", "clipboard_seed",
     r'"seed \{kind\}\{focus\} EXPIRED',
     "the sentence a reader chases must name the channel's own state"),
    ("the expiry carries BOTH readings of gtk_window_active",
     "clipboard_seed", r"gtk_window_active=\{\}->\{\}",
     "one reading cannot say whether the window's own state moved during "
     "the five seconds"),
    # THE COPY'S OWN THREE.
    ("the copy asks for the seat before the serial tap",
     "prime_if_clipboard_scene",
     r'clipboard_focus\("the copy verb"\);[\s\S]*?freshen_wayland_serial\(\);',
     "wtype's tap is delivered to whoever holds the focus, so a tap taken "
     "first spends the serial on somebody else's surface and the copy that "
     "follows is dropped with no error anywhere"),
    ("the copy's answer rides the copy's own record",
     "prime_if_clipboard_scene", r'"copy\{focus\}',
     "a red with green seeds and failed copies would point at the seed, "
     "which is the one thing that did ask"),
]
# ONCE PER COPY, NOT ONCE PER SCENE: the seat can be taken between two
# copies of one leg (measured under the thief), so the request lives at the
# per-action funnel EVERY verb that can reach a copy already passes.
COPY_VERBS = ("click", "shortcut", "menu_activate")

# ONE SPELLING OF THE REQUEST: `clipboard_focus` is the only body in gtk.rs
# that may name the compositor's focus command. A second copy would drift
# from this one's parse — which is the half that decides a grant. That both
# sides CALL it is already demanded by their two ordering links above.


def rust_fn_body(gtk_src, name):
    """One `fn <name>(`'s body, braces balanced, or None."""
    at = gtk_src.find(f"fn {name}(")
    if at < 0:
        return None
    return balanced(gtk_src, gtk_src.index("{", gtk_src.index(")", at)))


def seed_focus_clauses(gtk_src=None):
    bad = []
    text = gtk_src if gtk_src is not None else real(GTK)
    bodies = {}
    for name in ("clipboard_seed", "clipboard_focus",
                 "prime_if_clipboard_scene"):
        body = rust_fn_body(text, name)
        if body is None or len(body) < 200:
            bad.append(f"gtk.rs has no `fn {name}` body this clause can read "
                       f"— the wayland seed's focus rule is held by nothing")
        bodies[name] = body or ""
    for label, fn, pattern, why in SEED_FOCUS:
        if not re.search(pattern, bodies.get(fn, "")):
            bad.append(f"the wayland clipboard seed: {label} — `fn {fn}` in "
                       f"gtk.rs no longer matches /{pattern}/. {why}")
    # ONE SPELLING OF THE REQUEST, for the seed and the copy alike.
    # The media arm's READ of sway's tree (`-t get_tree`, the idle
    # inhibitor's record) is not a focus request and is not counted.
    asks = len(re.findall(r'Command::new\("swaymsg"\)(?!\s*\.args\(\["-r", "-t", "get_tree"\]\))',
                          text))
    if asks != 1:
        bad.append(f"the wayland clipboard seat: gtk.rs spells the "
                   f"compositor's focus command {asks} time(s), wanted 1 — "
                   f"the seed and the copy share one request and one parse "
                   f"of sway's answer, and a second copy drifts from this "
                   f"one on the half that decides a grant")
    for verb in COPY_VERBS:
        if "Self::prime_if_clipboard_scene();" not in (rust_fn_body(text, verb) or ""):
            bad.append(f"the wayland clipboard seat: `fn {verb}` in gtk.rs no "
                       f"longer passes prime_if_clipboard_scene — the seat is "
                       f"asked for ONCE PER COPY and a verb that skips the "
                       f"funnel copies with whatever focus it happens to find")
    # AND NEITHER REFUSAL MAY BE A SENTENCE THAT INTERPOLATES NOTHING: a
    # focus request that failed prints what the compositor said, or it is a
    # diagnostic that cannot discriminate. tools/check-diagnostics.py reads
    # `*WhyNot` names only, so it cannot reach this one.
    said = re.findall(r"eprintln!\(\s*\"([\s\S]*?)\"\s*\);",
                      bodies.get("clipboard_focus", ""))
    if len(said) != 3:
        bad.append(f"the wayland clipboard seat: `fn clipboard_focus` "
                   f"prints {len(said)} sentence(s) on its failure paths, "
                   f"wanted 3 — a host with no swaymsg, a compositor that "
                   f"refused, and a grant that was answered and did not take "
                   f"— since one sentence for any two cannot say which "
                   f"happened")
    for one in said:
        # `{what}` is the CALLER's name, not a measurement: a sentence
        # carrying only that is still one sentence for every cause.
        if "{" not in one.replace("{what}", ""):
            bad.append(f"the wayland clipboard seed: a refusal sentence "
                       f"interpolates nothing it measured ({one[:60]!r}) — it "
                       f"would be printed for every cause it does not name")
    return bad


seed_focus_out = seed_focus_clauses()
seed_focus_status = 0
for line in seed_focus_out:
    print(f"check-verbs: {line}", file=sys.stderr)
    seed_focus_status = 1
SEAT_NEGATIVES = (
    ("the focus request moved after the writer",
     dict(gtk_src=perturb(
         "seed focus (asked after the writer)", GTK,
         r"(        )let focus = clipboard_focus\(\"clipboard_seed\"\);\n",
         "")),
     r"the request stands before the writer is spawned"),
    ("the compositor asked about somebody else's window",
     dict(gtk_src=perturb("seed focus (pid dropped from the criteria)", GTK,
                          r'(say\(format!\(")\[pid=\{pid\}\] focus',
                          "[app_id=kaya] focus")),
     r"the compositor is asked, by this process's own pid"),
    ("the grant read off the exit status alone",
     dict(gtk_src=perturb("seed focus (the answer no longer read)", GTK,
                          r"(out\.status\.success\(\))\s*&&\s*"
                          r"answer\.replace\([^)]*\)\.contains\([^)]*\)",
                          "")),
     r"the grant is read out of the compositor's own answer"),
    ("a refusal sentence that names nothing it measured",
     dict(gtk_src=perturb("seed focus (a refusal blanked)", GTK,
                          r"(focus: swaymsg )\{e\}",
                          "somehow")),
     r"a refusal sentence interpolates nothing"),
    ("the expiry that stopped naming the focus request",
     dict(gtk_src=perturb("seed focus (the expiry sentence stripped)", GTK,
                          r'("seed \{kind\})\{focus\}( EXPIRED)',
                          " EXPIRED")),
     r"the expiry says what the focus request answered"),
    ("the expiry back to one reading of gtk_window_active",
     dict(gtk_src=perturb("seed focus (one active reading)", GTK,
                          r"(gtk_window_active=\{\})->\{\}", "")),
     r"the expiry carries BOTH readings"),
    # THE COPY'S OWN FOUR — the state the tree was in until 2026-09-18,
    # when the seed asked and the copy did not.
    ("the copy that stopped asking for the seat",
     dict(gtk_src=perturb("copy focus (the request cut out)", GTK,
                          r'(            )let focus = clipboard_focus\("the copy '
                          r'verb"\);\n',
                          '\\1let focus = String::new();\n')),
     r"the copy asks for the seat before the serial tap"),
    ("the copy asking AFTER the tap has spent the serial",
     dict(gtk_src=perturb("copy focus (asked after the tap)", GTK,
                          r'(            )let focus = clipboard_focus\("the copy '
                          r'verb"\);\n(            )freshen_wayland_serial\(\);\n',
                          '\\2freshen_wayland_serial();\n'
                          '\\1let focus = clipboard_focus("the copy verb");\n')),
     r"the copy asks for the seat before the serial tap"),
    ("the copy's record that stopped carrying the answer",
     dict(gtk_src=perturb("copy focus (the record blanked)", GTK,
                          r'("copy)\{focus\}', "")),
     r"the copy's answer rides the copy's own record"),
    ("a copying verb that stopped passing the funnel",
     dict(gtk_src=perturb("copy focus (click leaves the funnel)", GTK,
                          r"(fn click\(&self, t: crate::harness::Target\) \{)"
                          r"[\s\S]*?Self::prime_if_clipboard_scene\(\);",
                          "")),
     r"`fn click` in gtk.rs no longer passes prime_if_clipboard_scene"),
    ("the grant taken on the command's word alone",
     dict(gtk_src=perturb("seat focus (the read-back cut out)", GTK,
                          r'(    match )say\(format!\("\[pid=\{pid\} '
                          r'con_id=__focused__\] nop kaya seat read-back"\)\)',
                          'say(format!("[pid={pid}] focus"))')),
     r"the grant is READ BACK out of the compositor's own tree"),
    ("a grant that did not take folded back into `granted`",
     dict(gtk_src=perturb("seat focus (not-held folded into granted)", GTK,
                          r'(            )format!\(" focus=granted-not-held'
                          r'\(\{seen\}\)"\)',
                          '" focus=granted".to_owned()')),
     r"a grant that did not take is its own answer"),
    ("a second spelling of the compositor's focus command",
     dict(gtk_src=perturb("copy focus (a second swaymsg)", GTK,
                          r'(        let focus = clipboard_focus'
                          r'\("clipboard_seed"\);\n)',
                          '        let _second = '
                          'std::process::Command::new("swaymsg");\n')),
     r"spells the compositor's focus command 2 time"),
)
for label, kwargs, finding in SEAT_NEGATIVES:
    score_or_die(introduced(seed_focus_clauses(**kwargs), seed_focus_out,
                            finding), label)
print(f"check-verbs: the wayland clipboard seat is asked for by the seed AND "
      f"by the copy: {len(SEED_FOCUS)} links + one spelling of the request + "
      f"{len(COPY_VERBS)} copying verbs through the funnel + 3 refusal "
      f"sentences, {len(SEAT_NEGATIVES)} watched negatives refused",
      file=sys.stderr)

# EVERY COMPOSE KIND HAS ITS CREATE AND RENDER ARMS (CLAUDE.md, "Interpreter
# backends are the historic miss layer"): the constant census above holds
# the number, and a kind whose number arrives with no registry arm or no
# render arm draws nothing and answers no target. A depth stub counts as an
# arm; check-stubs holds those open.
def compose_kind_arms(kotlin_src=None):
    text = kotlin_src if kotlin_src is not None else real(KOTLIN)
    kinds = re.findall(r"const val (KIND_[A-Z_]+) = \d+", text)
    at = text.find("APPLY_CREATE -> {")
    create = text[at:text.find("APPLY_SET_PROP ->", at)] if at >= 0 else ""
    at = text.find("private fun KayaRenderCore(")
    render = text[at:] if at >= 0 else ""
    bad = []
    if not create or not render:
        bad.append("KayaCompose.kt: the create arm or KayaRenderCore is gone — "
                   "the kind census reads nothing")
    for kind in kinds:
        if f"{kind} ->" not in create:
            bad.append(f"KayaCompose.kt: {kind} has no arm in APPLY_CREATE — a "
                       f"node of that kind joins no registry and no verb finds it")
        if not re.search(rf"KayaCompose\.{kind}\b[^\n]*->", render):
            bad.append(f"KayaCompose.kt: {kind} has no arm in KayaRenderCore — "
                       f"a node of that kind draws nothing")
    return bad, len(kinds)


kind_out, kind_count = compose_kind_arms()
g.counted("Compose kinds read for their create and render arms", kind_count,
          floor=20)
kind_status = 1 if kind_out else 0
for line in kind_out:
    print(f"check-verbs: {line}", file=sys.stderr)
for label, pattern, finding in (
    ("the number field's render arm cut",
     r"\n        KayaCompose\.KIND_NUMBER_FIELD -> KayaNumberField\([^\n]*",
     "KIND_NUMBER_FIELD has no arm in KayaRenderCore"),
    ("the number field's create arm cut",
     r"\n                        KIND_NUMBER_FIELD -> \{",
     "KIND_NUMBER_FIELD has no arm in APPLY_CREATE"),
):
    cut = g.doctor(f"compose kind arms: {label}", real(KOTLIN), pattern,
                   "\n                        if (false) {")
    found, _ = compose_kind_arms(cut)
    if not [line for line in found if finding in line]:
        fail(f"check-verbs SELF-TEST: the Compose kind census passed with "
             f"{label}")

# THE RANGE'S ARMS IN BOTH INTERPRETERS (docs/range-plan.md §7): the verb
# census is satisfied by a label, so an arm that lost the thumb word, the
# range's prop arms or its drive reads every range step as a slider's.
def kotlin_if_arm(src, verb):
    """The first block of a `"<verb>" -> if (..) { .. }` arm: the branch a
    range or slider target takes."""
    at = src.find(f'"{verb}" -> if (')
    if at < 0:
        return None
    return balanced(src, src.index("{", src.index(") {", at) + 2))


def swift_where_arm(src, head):
    at = src.find(head)
    if at < 0:
        return None
    indent = src[src.rfind("\n", 0, at) + 1:at]
    nxt = re.search(r"^" + indent + r"(?:case |default:|\})", src[at + len(head):], re.M)
    return src[at: at + len(head) + (nxt.start() if nxt else 0)]


def kotlin_set_prop(src):
    at = src.find("APPLY_SET_PROP -> {")
    return balanced(src, src.index("{", at)) if at >= 0 else None


def swift_set_prop(src):
    at = src.find("case (propLow, valueF64):")
    return src[at - 4000: at + 4000] if at >= 0 else None


RANGE_ARMS = (
    (KOTLIN, "the set_value arm's range drive",
     lambda t: kotlin_action_arm(t, "set_value"),
     ('startsWith("range")', "kayaRangeSetProgress(")),
    (KOTLIN, "the expect_value arm's two thumbs",
     lambda t: kotlin_action_arm(t, "expect_value"),
     ('startsWith("range")', "kayaRangeThumbs(")),
    (KOTLIN, "the expect_thumb arm's thumb word",
     lambda t: kotlin_action_arm(t, "expect_thumb"),
     ('parts[2] == "low"', "kayaThumbTravel(")),
    (KOTLIN, "the expect_ax arm's thumb branch",
     lambda t: kotlin_if_arm(t, "expect_ax"),
     ('parts[2] == "low"', "kayaAxThumb(")),
    (KOTLIN, "the expect_axis arm's slider branch",
     lambda t: kotlin_if_arm(t, "expect_axis"),
     ("kayaTravelAxis(",)),
    (KOTLIN, "the range's prop arms", kotlin_set_prop,
     ("PROP_LOW ->", "PROP_HIGH ->", "PROP_MIN_GAP ->", "PROP_LOW_LABEL ->",
      "PROP_HIGH_LABEL ->")),
    (SWIFT, "the set_value arm's range drive",
     lambda t: swift_action_arm(t, "set_value"),
     ('hasPrefix("range")', "kayaDriveThumb(")),
    (SWIFT, "the expect_value arm's two thumbs",
     lambda t: swift_action_arm(t, "expect_value"),
     ('hasPrefix("range")', "kayaControlThumbValue(")),
    (SWIFT, "the expect_thumb arm's thumb word",
     lambda t: swift_action_arm(t, "expect_thumb"),
     ('parts[2] == "low"', "kayaThumbFraction(")),
    (SWIFT, "the expect_ax arm's thumb branch",
     lambda t: swift_where_arm(t, 'case "expect_ax" where parts[1].hasPrefix("range")'),
     ('"." + parts[2]',)),
    (SWIFT, "the range's prop arms", swift_set_prop,
     ("case (propLow, valueF64)", "case (propHigh, valueF64)",
      "case (propMinGap, valueF64)", "case (propLowLabel, valueStr)",
      "case (propHighLabel, valueStr)")),
)


def range_arms(sources=None):
    sources = sources or {}
    bad, read = [], 0
    for rel, what, reader, needles in RANGE_ARMS:
        body = reader(sources.get(rel) or real(rel))
        if body is None:
            bad.append(f"{rel}: {what} — the arm is not where the reader "
                       f"looks, so the census would agree with anything")
            continue
        read += 1
        for needle in needles:
            if needle not in body:
                bad.append(f"{rel}: {what} no longer names `{needle}` — a "
                           f"range step would be read as a slider's, or "
                           f"not at all")
    return bad, read


range_out, range_read = range_arms()
g.counted("range arms read in both interpreters", range_read,
          floor=len(RANGE_ARMS))
range_status = 1 if range_out else 0
for line in range_out:
    print(f"check-verbs: {line}", file=sys.stderr)
for rel, label, pattern in (
    (KOTLIN, "the Compose range drive", r"kayaRangeSetProgress\(activity, parts\)"),
    (KOTLIN, "the Compose thumb word in expect_thumb",
     r'kayaThumbTravel\(it\.id, if \(parts\[2\] == "low"\)'),
    (KOTLIN, "the Compose ax thumb branch", r"onUi\(activity\) \{ kayaAxThumb\("),
    (KOTLIN, "the Compose slider axis read", r"kayaTravelAxis\(it\.id\)"),
    (KOTLIN, "the Compose min_gap arm", r"PROP_MIN_GAP -> KayaSceneModel"),
    (KOTLIN, "the Compose expect_value thumbs",
     r"kayaRangeThumbs\(activity, node\.id\)\?\.joinToString"),
    (SWIFT, "the SwiftUI range drive", r"kayaDriveThumb\(control, node: node, low: parts"),
    (SWIFT, "the SwiftUI thumb word in expect_thumb",
     r'return kayaThumbFraction\(control, low: parts\[2\] == "low"\)'),
    (SWIFT, "the SwiftUI ax thumb id", r'kayaAxRead\(id \+ "\." \+ parts\[2\]\)'),
    (SWIFT, "the SwiftUI high_label arm", r"case \(propHighLabel, valueStr\)"),
):
    cut = g.doctor(f"range arms: {label} cut", real(rel), pattern, "kayaCut(")
    found, _ = range_arms({rel: cut})
    print(f"check-verbs: range-arms negative ({label}): {len(found)} finding(s)")
    if not found:
        fail(f"check-verbs SELF-TEST: the range arm census passed with {label} cut")

# --- THE MEDIA ARMS (docs/media-plan.md §3, §5) ------------------------
# Three rules no scene can see. THE VIDEO VIEW IS A BARE LAYER: AVPlayerView
# keeps Space, the arrows and J/K/L at every controls style,
# AVPlayerViewController brings its own Now Playing session and SwiftUI's
# VideoPlayer cannot hide its controls, and each would still show the
# picture every media leg asserts. EVERY PLAYER REPORT TAKES ONE DOOR,
# kayaPlayerReport, which follows the session, and the publish sets
# macOS's playbackState before anything can return: macOS routes no media
# key to an app that leaves it stale, and a report that skipped the door
# would leave it stale only on that transition. AND expect_video_ink's
# tolerance is one measured number (±2 in sRGB, docs/traps.md) in the two
# harnesses that read a video view.
VIDEO_INK_RULED = 2


def ios_media_rows(code):
    """The iOS half's own rows (docs/media-plan.md §2 rule 6, §5, §6): the
    playback category activated before every play, the view's layer class
    the bare AVPlayerLayer, a session refused in a bundle without the audio
    background mode, and the picture read from the simulator's screenshot,
    since no in-process read holds it while it plays (measured)."""
    bad = []
    play = re.search(r"\n    func play\(\) \{\n(.*?)\n    \}\n", code, re.S)
    if play is None:
        bad.append("KayaPlayer has no `func play()` to read")
    else:
        b = play.group(1)
        ios = b.find("#if os(iOS)")
        cat = b.find("setCategory(.playback")
        act = b.find("setActive(true)")
        go = b.find("player.play()")
        if min(ios, cat, act) < 0 or not ios < cat < act < go:
            bad.append("KayaPlayer.play() does not activate the .playback "
                       "category (setCategory then setActive, iOS only) "
                       "before it plays — iOS then mutes it under the Silent "
                       "switch and it never becomes Now Playing")
    view = re.search(r"final class KayaVideoView: UIView \{(.*?)\n    \}", code, re.S)
    if view is None or not re.search(
            r"override class var layerClass: AnyClass \{ AVPlayerLayer\.self \}",
            view.group(1)):
        bad.append("the iOS KayaVideoView is not backed by a bare AVPlayerLayer "
                   "(layerClass)")
    session = re.search(r"^func kayaApplySession\(.*?^\}$", code, re.M | re.S)
    if session is None or not re.search(
            r'#if os\(iOS\).*"UIBackgroundModes".*modes\.contains\("audio"\).*fatalError',
            session.group(0), re.S):
        bad.append("kayaApplySession does not refuse a session in an iOS "
                   "bundle without UIBackgroundModes audio")
    seek = re.search(r"\n    func seek\(_ ms: UInt64, report: Bool, waited: Int = 0\) \{\n"
                     r"        if legibleSwitching && waited < \d+ \{", code)
    switching = re.search(r"private var legibleSwitching: Bool \{(.*?)\n    \}", code, re.S)
    if seek is None or switching is None or "item.tracks.contains" not in switching.group(1):
        bad.append("KayaPlayer.seek does not first wait for a newly selected caption "
                   "track to be enabled (legibleSwitching over item.tracks) — a paused "
                   "seek before the switch never gets its cue (docs/traps.md)")
    ink = [m.group(0) for m in re.finditer(
        r"\n    func kayaVideoInk\(.*?\n    \}\n", code, re.S)]
    ios_ink = [b for b in ink if "KayaSimdrive" in b or "UIView" in b
               or "screen.scale" in b]
    if len(ink) != 2 or len(ios_ink) != 1 \
            or 'KayaSimdrive.ask("media_screen' not in ios_ink[0] \
            or re.search(r"displayedPixelBuffer|drawHierarchy|render\(in:",
                         ios_ink[0]):
        bad.append("the iOS kayaVideoInk does not read the simulator's own "
                   "screenshot through the host (media_screen) — an "
                   "in-process read holds no playing picture")
    hand = re.search(r"\n    private func platformURL\(_ locator: String\) -> URL\? \{"
                     r"(.*?)\n    \}\n",
                     code, re.S)
    load = re.search(r"\n    func load\(_ locator: String\) \{(.*?)\n    \}\n", code, re.S)
    rel = re.search(r"\n    func release\(\) \{(.*?)\n    \}\n", code, re.S)
    if hand is None or load is None or rel is None \
            or not re.search(r"#else\s+guard let picked = kayaPickedURLs\[locator\] else"
                             r".*?picked\.startAccessingSecurityScopedResource\(\)"
                             r".*?return picked", hand.group(1), re.S) \
            or "let url = platformURL(locator)" not in load.group(1) \
            or "releaseScope()" not in rel.group(1):
        bad.append("KayaPlayer does not hand an iOS picked file's own URL to the "
                   "player with its scope held (platformURL over kayaPickedURLs, "
                   "opened by load, the scope released with the player) — the "
                   "maintainer's ruling of 2026-09-30, which no simulator leg "
                   "can see, since a file in the app's own container needs no "
                   "scope there")
    return bad


def media_arms(swift_src=None, harness_src=None):
    bad = []
    swift = swift_src if swift_src is not None else real(SWIFT)
    harness = harness_src if harness_src is not None else real(HARNESS)
    code = re.sub(r"//[^\n]*", "", swift)
    for banned in ("AVPlayerView", "AVPlayerViewController", "VideoPlayer(",
                   "import AVKit"):
        if banned in code:
            bad.append(f"KayaSwiftUI.swift names {banned!r} — the video view "
                       f"is a bare AVPlayerLayer (docs/media-plan.md §3)")
    calls = [m.start() for m in re.finditer(r"KayaHost\.api\.player_", code)]
    if len(calls) < 7:
        bad.append(f"only {len(calls)} KayaHost.api.player_ call(s) read — "
                   f"the census reads too little to agree with anything")
    stack, doors, at = [], [], 0
    for i, ch in enumerate(code):
        if ch == "{":
            line = code[code.rfind("\n", 0, i) + 1:i]
            stack.append("kayaPlayerReport(" in line)
        elif ch == "}" and stack:
            stack.pop()
        while at < len(calls) and calls[at] == i:
            doors.append(any(stack))
            at += 1
    outside = doors.count(False)
    if outside:
        bad.append(f"{outside} player report(s) outside kayaPlayerReport — "
                   f"a transition that skips the door leaves the system's "
                   f"playback state stale")

    def body(name):
        m = re.search(r"^func " + name + r"\(.*?^\}$", code, re.M | re.S)
        return m.group(0) if m else None

    door = body("kayaPlayerReport")
    if door is None or "kayaSessionFollow(" not in door:
        bad.append("kayaPlayerReport does not call kayaSessionFollow — the "
                   "session does not follow the player's transitions")
    follow = body("kayaSessionFollow")
    if follow is None or "kayaPublishNowPlaying()" not in follow:
        bad.append("kayaSessionFollow does not publish (kayaPublishNowPlaying)")
    publish = body("kayaPublishNowPlaying")
    if publish is None:
        bad.append("KayaSwiftUI.swift has no kayaPublishNowPlaying to read")
    else:
        state = publish.find("center.playbackState =")
        ret = publish.find("return")
        if state < 0 or (0 <= ret < state):
            bad.append("kayaPublishNowPlaying does not set playbackState "
                       "before it can return — macOS routes no media key "
                       "to an app that leaves it stale")
    bad += ios_media_rows(code)
    hm = re.search(r"const VIDEO_INK_TOLERANCE\s*:\s*\w+\s*=\s*(\d+)\s*;", harness)
    sm = re.search(r"let kayaVideoInkTolerance\b[^=\n]*=\s*(\d+)\b", swift)
    for label, m in (("harness.rs VIDEO_INK_TOLERANCE", hm),
                     ("KayaSwiftUI.swift kayaVideoInkTolerance", sm)):
        if not m:
            bad.append(f"{label} is not there to read")
        elif int(m.group(1)) != VIDEO_INK_RULED:
            bad.append(f"{label} is {m.group(1)}, not the measured "
                       f"{VIDEO_INK_RULED}")
    return bad


media_out = media_arms()
media_status = 1 if media_out else 0
if media_out:
    print("check-verbs: the media arms broke a rule no scene can see:",
          file=sys.stderr)
    print("\n".join(media_out), file=sys.stderr)
MEDIA_REPORTS = len(re.findall(r"KayaHost[.]api[.]player_", real(SWIFT)))
print(f"check-verbs: media arms read ({MEDIA_REPORTS} player reports)")
for pattern, repl, label, rel, want in (
    (r"(let player = kayaPlayers\[node\.videoPlayer\]\?\.player\n)",
     "            _ = AVPlayerView()\n", "an AVPlayerView hosted (both arms)", SWIFT, 2),
    (r"(\n)                kayaPlayerReport\(self\.id\) "
     r"\{ KayaHost\.api\.player_ended\(self\.id\) \}",
     "                _ = KayaHost.api.player_ended(self.id)",
     "a report outside the door", SWIFT, 1),
    (r"(    _ = report\(\)\n)    kayaSessionFollow\(id\)", "",
     "the door not following the session", SWIFT, 1),
    (r"(    let state = KayaHost\.api\.session_state\(\)\n)    #if os\(macOS\)\n"
     r"        center\.playbackState = [^\n]*\n    #endif\n",
     "", "playbackState never set", SWIFT, 1),
    (r"(let kayaVideoInkTolerance = )2", "3", "the video ink tolerance widened", SWIFT, 1),
    (r"(\n)            try\? AVAudioSession\.sharedInstance\(\)\.setCategory\(\.playback[^\n]*\n",
     "", "iOS play without the playback category", SWIFT, 1),
    (r"(override class var layerClass: AnyClass \{ )AVPlayerLayer\.self",
     "CALayer.self", "the iOS view on a plain layer", SWIFT, 1),
    (r"(\n)        if \(session\.player != 0 \|\| session\.offered != 0\) "
     r"&& !modes\.contains\(\"audio\"\) \{",
     "        if false {", "the background-mode refusal cut", SWIFT, 1),
    (r'(KayaSimdrive\.ask\(")media_screen', "media_pixelbuffer",
     "the iOS ink read not through the screenshot", SWIFT, 1),
    (r"(\n        if )legibleSwitching && waited < ", "false && waited < ",
     "a seek not waiting for the caption switch", SWIFT, 1),
    (r"(guard let picked = )kayaPickedURLs\[locator\]", "Optional<URL>.none",
     "the iOS picked URL not handed over", SWIFT, 1),
    (r"(let url = )platformURL\(locator\)", "URL(string: locator)",
     "the iOS load not through the picked hand-off", SWIFT, 1),
    (r"(\n        player\.replaceCurrentItem\(with: nil\)\n)        releaseScope\(\)\n", "",
     "the picked scope kept past release", SWIFT, 1),
):
    cut = g.doctor(f"media arms: {label}", real(rel), pattern,
                   lambda m, repl=repl: m.group(1) + repl, want=want)
    found = [f for f in media_arms(swift_src=cut) if f not in media_out]
    print(f"check-verbs: media-arms negative ({label}): {len(found)} finding(s)")
    if not found:
        fail(f"check-verbs SELF-TEST: the media arms passed with {label}")

# --- THE COMPOSE MEDIA ARM (docs/media-plan.md §2, §3, §5, §7a) ---------
# The mac clause's rules on Android, none of which a scene can see: THE VIEW
# IS media3's PlayerSurface of the SurfaceView type, never PlayerView (its
# controller keeps its own keys) or a TextureView (no protected path); EVERY
# PLAYER REPORT TAKES ONE DOOR, kayaPlayerReport, which republishes the
# session's state (invalidateState) — media3 routes no media key to a
# session left stale; THE BACKEND REPORTS RAW FACTS: no failure reason is
# spelled in the arm outside its lane table; THE DECODABILITY CHECK reads a
# Tracks group with no supported track into playerLoaded's flag; audio focus
# and becoming-noisy are both on (§2 rule 6); and the wire's media numbers,
# hand-copied, equal kaya.h's.
KOTLIN_MEDIA = "android/kaya/src/main/kotlin/dev/kaya/KayaMedia.kt"
KAYA_H = "crates/kaya/include/kaya.h"
MEDIA_REASONS = ("unsupported_codec", "unsupported_container", "not_found",
                 "network", "decode_error", "resources", "timeout")


def kotlin_code(text):
    return re.sub(r"//[^\n]*", "", re.sub(r"/\*.*?\*/", "", text, flags=re.S))


def kotlin_fun(code, name):
    m = re.search(r"^(?:internal |private )?(?:inline )?fun " + name + r"\(",
                  code, re.M)
    if not m:
        m = re.search(r"^    (?:override |private )?fun " + name + r"\(", code, re.M)
    if not m:
        return None
    i = code.find("{", m.end())
    depth = 0
    for j in range(i, len(code)):
        if code[j] == "{":
            depth += 1
        elif code[j] == "}":
            depth -= 1
            if depth == 0:
                return code[m.start():j + 1]
    return None


def compose_media_arms(media_src=None, header_src=None):
    bad = []
    code = kotlin_code(media_src if media_src is not None else real(KOTLIN_MEDIA))
    header = header_src if header_src is not None else real(KAYA_H)
    for banned in ("PlayerView", "SubtitleView", "SURFACE_TYPE_TEXTURE_VIEW",
                   "TextureView"):
        if re.search(r"\b" + banned + r"\b", code):
            bad.append(f"KayaMedia.kt names {banned} — the video view is media3's "
                       f"PlayerSurface of the SurfaceView type (docs/media-plan.md §3)")
    if not re.search(r"PlayerSurface\((?:(?!\n\s*\)).)*?surfaceType = SURFACE_TYPE_SURFACE_VIEW",
                     code, re.S):
        bad.append("KayaMedia.kt draws no PlayerSurface with SURFACE_TYPE_SURFACE_VIEW")
    calls = [m.start() for m in re.finditer(r"KayaPresent\.player[A-Z]", code)]
    if len(calls) < 9:
        bad.append(f"only {len(calls)} KayaPresent.player* call(s) read — the "
                   f"census reads too little to agree with anything")
    stack, at, outside = [], 0, 0
    for i, ch in enumerate(code):
        if ch == "{":
            line = code[code.rfind("\n", 0, i) + 1:i]
            stack.append("kayaPlayerReport(" in line)
        elif ch == "}" and stack:
            stack.pop()
        while at < len(calls) and calls[at] == i:
            if not any(stack):
                outside += 1
            at += 1
    if outside:
        bad.append(f"{outside} player report(s) outside kayaPlayerReport — a "
                   f"transition that skips the door leaves the session's state stale")
    door = kotlin_fun(code, "kayaPlayerReport")
    if door is None or "KayaMediaSession.follow(" not in door:
        bad.append("kayaPlayerReport does not call KayaMediaSession.follow — the "
                   "session does not follow the player's transitions")
    follow = kotlin_fun(code, "follow")
    if follow is None or "publish()" not in follow:
        bad.append("KayaMediaSession.follow does not publish the session player's state")
    publish = re.search(r"fun publish\(\)\s*=\s*invalidateState\(\)", code)
    if not publish:
        bad.append("KayaSessionPlayer.publish is not invalidateState() — media3 "
                   "re-reads a SimpleBasePlayer's state only when told")
    table = kotlin_fun(code, "kayaMediaRefusal") or ""
    rest = code.replace(table, "")
    for word in MEDIA_REASONS:
        if f'"{word}"' in rest:
            bad.append(f'KayaMedia.kt spells the reason "{word}" outside its lane '
                       f"table — the core maps a platform's codes, the backend "
                       f"reports them raw (crates/kaya/src/media.rs failure_reason)")
    loaded = kotlin_fun(code, "reportLoaded") or ""
    if not re.search(r"!group\.isSupported", loaded) or "why.isNotEmpty()" not in loaded:
        bad.append("reportLoaded does not read a Tracks group with no supported "
                   "track into playerLoaded's undecodable flag (docs/media-plan.md §7a)")
    if not re.search(r"setAudioAttributes\([^;]*?,\s*true,?\s*\)", code, re.S) \
            or "setHandleAudioBecomingNoisy(true)" not in code:
        bad.append("the ExoPlayer builder turns off audio focus or becoming-noisy "
                   "(docs/media-plan.md §2 rule 6)")
    defines = dict(re.findall(
        r"#define KAYA_((?:PPROP|PLAYER_COMMAND|SESSION_ACTION|TRACK_KIND|FIT|"
        r"MEDIA_POSITION_TICK_MS|MEDIA_TIMEOUT_MS)\w*) (\d+)", header))
    copies = re.findall(r"internal const val ((?:PPROP|PLAYER_COMMAND|SESSION_ACTION|"
                        r"TRACK_KIND|FIT|MEDIA_POSITION_TICK_MS|MEDIA_TIMEOUT_MS)"
                        r"\w*) = (\d+)", code)
    if len(copies) < 20 or len(defines) < 20:
        bad.append(f"the media numbers read {len(copies)} Kotlin copies against "
                   f"{len(defines)} kaya.h defines — too few to agree with anything")
    for name, value in copies:
        if defines.get(name) != value:
            bad.append(f"KayaMedia.kt {name} = {value}, kaya.h KAYA_{name} = "
                       f"{defines.get(name)}")
    return bad


compose_media_out = compose_media_arms()
if compose_media_out:
    media_status = 1
    print("check-verbs: the Compose media arm broke a rule no scene can see:",
          file=sys.stderr)
    print("\n".join(compose_media_out), file=sys.stderr)
print(f"check-verbs: Compose media arm read "
      f"({len(re.findall(r'KayaPresent[.]player[A-Z]', real(KOTLIN_MEDIA)))} player reports)")
for pattern, repl, label, want in (
    (r"(surfaceType = )SURFACE_TYPE_SURFACE_VIEW", "SURFACE_TYPE_TEXTURE_VIEW",
     "a TextureView surface", 1),
    (r"(\n +)kayaPlayerReport\(id\) \{ KayaPresent\.playerEnded\(id\) \}",
     "KayaPresent.playerEnded(id)", "a report outside the door", 1),
    (r"(    report\(\)\n)    KayaMediaSession\.follow\(id\)\n", "",
     "the door not following the session", 1),
    (r"(fun publish\(\) = )invalidateState\(\)", "Unit", "the state never invalidated", 1),
    (r"(\s)if \(!group\.isSupported\) \{", " if (false) {",
     "the decodability check cut", 1),
    (r"(\.setHandleAudioBecomingNoisy\()true", "false", "becoming-noisy off", 1),
    (r"(internal const val SESSION_ACTION_NEXT = )7", "8", "a drifted media number", 1),
    (r"(var domain = )\"media3\"", "\"network\"", "a reason spelled by the arm", 1),
):
    cut = g.doctor(f"compose media: {label}", real(KOTLIN_MEDIA), pattern,
                   lambda m, repl=repl: m.group(1) + repl, want=want)
    found = [f for f in compose_media_arms(media_src=cut) if f not in compose_media_out]
    print(f"check-verbs: compose-media negative ({label}): {len(found)} finding(s)")
    if not found:
        fail(f"check-verbs SELF-TEST: the Compose media arm passed with {label}")

# --- THE ANDROID VIDEO READ (docs/traps.md, the media feed entry) --------
# A lane cannot see its own read go soft: expect_video_ink on Compose passed
# on media3's first-frame report while every row of the feed was black on
# screen. So the arm asks the runner for its screencap and compares what it
# says, the runner answers with `screencap`, and the tolerance is the
# measured 14. Beside the read, two rules the feed and formats legs hold only
# while the read is honest: the video renderer never moves a decoder between
# surfaces (the black rows' cause), and a view whose player has no picture
# composes no SurfaceView (the audio item's stale frame).
ANDROID_RUNNER = "tools/android/run-emulator.py"
ANDROID_VIDEO_INK_RULED = 14


def android_video_read(media_src=None, compose_src=None, runner_src=None):
    bad = []
    media = kotlin_code(media_src if media_src is not None else real(KOTLIN_MEDIA))
    compose = kotlin_code(compose_src if compose_src is not None else real(KOTLIN))
    runner = runner_src if runner_src is not None else real(ANDROID_RUNNER)
    arm = kotlin_action_arm(compose, "expect_video_ink")
    if arm is None:
        bad.append("KayaCompose.kt has no one expect_video_ink arm to read")
    elif "KAYA_REQUEST: video_ink" not in arm or "kayaVideoInkWithin(" not in arm \
            or "kayaHostAnswer(" not in arm:
        bad.append("Compose's expect_video_ink does not compare the runner's screencap "
                   "(KAYA_REQUEST: video_ink, kayaHostAnswer, kayaVideoInkWithin) — "
                   "the frames-arriving report passed a black feed")
    answer = re.search(r"^def answer_video_ink\(.*?(?=^def |\Z)", runner, re.M | re.S)
    if answer is None or '"screencap"' not in answer.group(0) \
            or "video_ink_reading(" not in answer.group(0):
        bad.append("run-emulator.py's answer_video_ink does not read the device's own "
                   "screencap through video_ink_reading")
    if not re.search(r"KAYA_REQUEST: video_ink .*\n.*\n.*\n.*\n.*answer_video_ink\(", runner):
        bad.append("run-emulator.py's leg poll does not answer KAYA_REQUEST: video_ink")
    tol = re.search(r"internal const val KAYA_VIDEO_INK_TOLERANCE = (\d+)", media)
    if not tol or int(tol.group(1)) != ANDROID_VIDEO_INK_RULED:
        bad.append(f"KayaMedia.kt KAYA_VIDEO_INK_TOLERANCE is "
                   f"{tol.group(1) if tol else 'absent'}, not the measured "
                   f"{ANDROID_VIDEO_INK_RULED} (the emulator's BT.601 composition)")
    factory = re.search(r"class KayaRenderersFactory\b.*?\n\}", media, re.S)
    if factory is None or not re.search(
            r"override fun codecNeedsSetOutputSurfaceWorkaround\([^)]*\): Boolean = true",
            factory.group(0)):
        bad.append("KayaMedia.kt's KayaRenderersFactory moves a decoder between surfaces "
                   "(codecNeedsSetOutputSurfaceWorkaround not true) — feed rows went black")
    if "ExoPlayer.Builder(context, KayaRenderersFactory(context))" not in media:
        bad.append("the ExoPlayer is not built with KayaRenderersFactory")
    view = kotlin_fun(media, "KayaVideoView") or ""
    if not re.search(r"if \(p != null && p\.showsPicture\) \{\s*val scale", view):
        bad.append("KayaVideoView composes its PlayerSurface for a player with no "
                   "picture (showsPicture) — the SurfaceView keeps the last video's frame")
    return bad


android_read_out = android_video_read()
if android_read_out:
    media_status = 1
    print("check-verbs: the Android video read broke a rule no scene can see:",
          file=sys.stderr)
    print("\n".join(android_read_out), file=sys.stderr)
print("check-verbs: Android video read held (screencap, tolerance, renderer, picture)")
for pattern, repl, label, which in (
    (r"(Log\.i\(\"kaya\", \"KAYA_REQUEST: )video_ink", "video_frames",
     "the Compose arm not asking for the screencap", "compose"),
    (r'(\["timeout", "20", "adb", "-s", serial, "exec-out", )"screencap", "-p"\]',
     '"cat", "/dev/null"]', "the runner not taking the screencap", "runner"),
    (r"(internal const val KAYA_VIDEO_INK_TOLERANCE = )14", "20",
     "the Android video ink tolerance widened", "media"),
    (r"(override fun codecNeedsSetOutputSurfaceWorkaround\(name: String\): Boolean = )true",
     "super.codecNeedsSetOutputSurfaceWorkaround(name)", "a decoder moved between surfaces",
     "media"),
    (r"(if \(p != null)( && p\.showsPicture)\) \{", ") {",
     "a SurfaceView composed for a player with no picture", "media"),
):
    src = {"media": KOTLIN_MEDIA, "compose": KOTLIN, "runner": ANDROID_RUNNER}[which]
    cut = g.doctor(f"android video read: {label}", real(src), pattern,
                   lambda m, repl=repl: m.group(1) + repl)
    found = [f for f in android_video_read(**{f"{which}_src": cut}) if f not in android_read_out]
    print(f"check-verbs: android-video-read negative ({label}): {len(found)} finding(s)")
    if not found:
        fail(f"check-verbs SELF-TEST: the Android video read passed with {label}")

# --- THE GTK MEDIA ARM (docs/media-plan.md §2, §3, §5, §7a) -------------
# The mac clause's rules on Linux, none of which a scene can see: THE VIEW IS
# a GtkPicture over gtk4paintablesink's paintable, never GtkVideo (its
# controls cannot be turned off) or GtkMediaFile/GtkMediaStream (no rate, no
# tracks, no captions); EVERY PLAYER REPORT TAKES ONE DOOR, media_report,
# which follows the session so MPRIS's PlaybackStatus moves on every
# transition; the arm reports RAW facts and spells no failure reason outside
# its lane table; and a missing codec reaches Loaded as undecodable, since
# playbin3 plays the audio of a file whose video decoder is missing with no
# error at all (docs/traps.md).
GTK_VIDEO_INK_RULED = 4


def gtk_media_arms(src=None):
    bad = []
    code = re.sub(r"//[^\n]*", "", src if src is not None else real(GTK))
    for banned in (r"gtk4::Video\b", r"gtk4::MediaFile\b", r"gtk4::MediaStream\b",
                   r"\bMediaFile::", r"\bVideo::new"):
        if re.search(banned, code):
            bad.append(f"gtk.rs names {banned!r} — the video view is a GtkPicture over "
                       f"gtk4paintablesink's paintable (docs/media-plan.md §3)")
    if 'make("gtk4paintablesink")' not in code or 'make("playbin3")' not in code:
        bad.append("gtk.rs builds no playbin3 into gtk4paintablesink (docs/media-plan.md §2)")
    door = re.search(r"\n    fn media_report\(core: &mut CoreState[^\n]*\n(.*?)\n    \}\n",
                     code, re.S)
    calls = len(re.findall(r"\.media_report\(", code))
    if door is None:
        bad.append("gtk.rs has no fn media_report door to read")
    else:
        inside = len(re.findall(r"\.media_report\(", door.group(1)))
        if calls != inside or inside != 1:
            bad.append(f"{calls - inside} scene.media_report call(s) outside the door — a "
                       f"transition that skips it leaves MPRIS's PlaybackStatus stale")
        if "session_follow(core)" not in door.group(1):
            bad.append("the media_report door does not call session_follow")
    follow = re.search(r"\n    fn session_follow\(core: &CoreState\) \{\n(.*?)\n    \}\n",
                       code, re.S)
    if follow is None or "publish_session(core)" not in follow.group(1):
        bad.append("session_follow does not publish the session")
    publish = re.search(r"\n    fn publish_session\(core: &CoreState\) \{\n(.*?)\n    \}\n",
                        code, re.S)
    if publish is None or "set_playback_status(status)" not in publish.group(1) \
            or "media_system_state()" not in publish.group(1):
        bad.append("publish_session does not set PlaybackStatus from the core's "
                   "media_system_state")
    module = re.search(r"\nmod gtk_media \{\n(.*?)\n\}\n", code, re.S)
    body = module.group(1) if module else ""
    if not body:
        bad.append("gtk.rs has no mod gtk_media to read")
    table = re.search(r"fn demoted_refusal_in\(.*?\n    \}\n", body, re.S)
    outside = body.replace(table.group(0), "") if table else body
    for word in MEDIA_REASONS:
        if f'"{word}"' in outside:
            bad.append(f'gtk.rs spells the reason "{word}" outside its lane table — the '
                       f"arm reports raw facts (crates/kaya/src/media.rs failure_reason)")
    if "MediaFailure::" in body:
        bad.append("gtk.rs names a MediaFailure — the core maps, the arm reports")
    tol = re.search(r"const GTK_VIDEO_INK_TOLERANCE: u8 = (\d+);", body)
    if not tol or int(tol.group(1)) != GTK_VIDEO_INK_RULED:
        bad.append(f"gtk.rs GTK_VIDEO_INK_TOLERANCE is {tol.group(1) if tol else 'absent'}, "
                   f"not the measured {GTK_VIDEO_INK_RULED} (GStreamer's YUV conversion, "
                   f"C6381D for C83C1E)")
    if "gtk_media::GTK_VIDEO_INK_TOLERANCE" not in code:
        bad.append("the GTK Stage does not state GTK_VIDEO_INK_TOLERANCE as its video "
                   "ink tolerance")
    raw = [m.group(0) for m in re.finditer(r"[\w.()]*\.set_state\(", body)
           if not m.group(0).startswith(("playbin.set_state", "fetch.", "held.", "pipeline.",
                                         "old.set_state"))]
    if raw or body.count("playbin.set_state(state)") != 2:
        bad.append(f"a playbin3 state change outside set_playbin_state ({raw}) — every "
                   f"one that can activate pads holds the typefinds off (docs/traps.md, "
                   f"gstreamer#4472)")
    if "wait_timeout_while(calls" not in body or "g_signal_add_emission_hook" not in body:
        bad.append("the have-type emission hook no longer waits for its pipeline's preroll call "
                   "(docs/traps.md, gstreamer#4472)")
    if not re.search(r"\(s\.missing_codec\.is_some\(\), detail,", body) \
            or "Report::Loaded { duration_ms: duration, size, undecodable, detail }" not in body:
        bad.append("gtk.rs does not carry a missing-plugin codec into Loaded's "
                   "undecodable flag (docs/media-plan.md §7a)")
    return bad


gtk_media_out = gtk_media_arms()
if gtk_media_out:
    media_status = 1
    print("check-verbs: the GTK media arm broke a rule no scene can see:",
          file=sys.stderr)
    print("\n".join(gtk_media_out), file=sys.stderr)
print(f"check-verbs: GTK media arm read "
      f"({len(re.findall(r'report\(id, crate::media::Report::', real(GTK)))} player reports)")
for pattern, repl, label, want in (
    (r"(let picture: gtk4::Picture =)", " gtk4::Video::new(); let _v:",
     "a GtkVideo built", 1),
    (r"(    fn caption_ask\(core: &mut CoreState, id: u64\) \{\n)",
     "        let _ = core.scene.media_report(crate::protocol::PlayerId(id), "
     "crate::media::Report::Ended);\n", "a report outside the door", 1),
    (r"(\n        )session_follow\(core\);\n", "", "the door not following the session", 1),
    (r"(\n            let _ = mpris\.)set_playback_status\(status\)\.await;",
     "set_rate(1.0).await;", "PlaybackStatus never set", 1),
    (r"(\()s\.missing_codec\.is_some\(\), detail,", "false, detail,",
     "the decodability check cut", 1),
    (r"(const GTK_VIDEO_INK_TOLERANCE: u8 = )4;", "8;", "the GTK video ink tolerance widened", 1),
    (r"(\n        )set_playbin_state\(&p\.pb\(\), gst::State::Paused\);\n        let id = p\.id;",
     "let _ = p.pb().set_state(gst::State::Paused);\n        let id = p.id;",
     "a preroll outside set_playbin_state", 1),
    (r"(let \(_calls, waited\) = PREROLL_DONE\n *)"
     r"\.wait_timeout_while\(calls, [^)]*\), held\)",
     ".wait_timeout(calls, std::time::Duration::ZERO)",
     "the have-type hook not waiting", 1),
    (r"(                report\(id, )crate::media::Report::Failed "
     r"\{ domain, code: 0, underlying: 0, detail \}",
     "crate::media::Report::Failed { domain: \"kaya\".into(), code: "
     "crate::protocol::MediaFailure::UnsupportedContainer as i64, underlying: 0, detail }",
     "a reason chosen by the arm", 1),
):
    cut = g.doctor(f"gtk media: {label}", real(GTK), pattern,
                   lambda m, repl=repl: m.group(1) + repl, want=want)
    found = [f for f in gtk_media_arms(src=cut) if f not in gtk_media_out]
    print(f"check-verbs: gtk-media negative ({label}): {len(found)} finding(s)")
    if not found:
        fail(f"check-verbs SELF-TEST: the GTK media arm passed with {label}")

# --- THE WINUI MEDIA ARM (docs/media-plan.md §2, §3, §5, §7a) ----------
# The same rules on Windows, none of which a scene can see: THE VIEW IS
# MediaPlayerElement WITH ITS TRANSPORT CONTROLS OFF, never MediaElement nor
# the element's own transport bar; EVERY PLAYER REPORT TAKES ONE DOOR,
# `report`, which follows the session, and the follow sets the SMTC's
# PlaybackStatus; THE BACKEND REPORTS RAW FACTS, no MediaFailure or
# PlayerState spelled in the arm; THE DECODABILITY CHECK reads each track's
# SupportInfo.DecoderStatus into Loaded's flag; and the command manager is off
# on every player, so no remote command reaches a player past the core.
WINUI_MEDIA = "crates/kaya/src/winui/media.rs"


def rust_fn(code, name):
    m = re.search(r"^(?:pub(?:\([^)]*\))? )?fn " + name + r"\b.*?^\}$", code, re.M | re.S)
    return m.group(0) if m else None


def winui_media_arms(media_src=None):
    bad = []
    src = media_src if media_src is not None else real(WINUI_MEDIA)
    code = re.sub(r"//[^\n]*", "", src)
    if re.search(r"\bMediaElement\b|[.]TransportControls[(]|SetTransportControls[(]", code) \
            or "SetAreTransportControlsEnabled(true)" in code:
        bad.append("winui/media.rs names MediaElement or the element's transport "
                   "controls — the video view is a MediaPlayerElement with its "
                   "controls off (docs/media-plan.md §3)")
    if "SetAreTransportControlsEnabled(false)" not in code:
        bad.append("winui/media.rs never turns the MediaPlayerElement's transport "
                   "controls off")
    calls = [m.start() for m in re.finditer(r"\.media_report\(", code)]
    door = rust_fn(code, "report")
    if not calls:
        bad.append("winui/media.rs has no media_report call to read — the census "
                   "reads too little to agree with anything")
    if door is None:
        bad.append("winui/media.rs has no fn report, the one door")
    else:
        start = code.find(door)
        outside = [c for c in calls if not start <= c < start + len(door)]
        if outside:
            bad.append(f"{len(outside)} media_report call(s) outside fn report — a "
                       f"transition that skips the door leaves the SMTC stale")
        if "session_follow(core)" not in door:
            bad.append("fn report does not call session_follow — the session does "
                       "not follow the player's transitions")
    follow = rust_fn(code, "session_follow")
    if follow is None or "SetPlaybackStatus(" not in follow:
        bad.append("session_follow does not set the SMTC's PlaybackStatus")
    for spelled in ("MediaFailure::", "PlayerState::"):
        if spelled in code:
            bad.append(f"winui/media.rs spells {spelled} — the backend reports raw "
                       f"facts and crate::media decides (docs/media-plan.md §2 rule 1)")
    opened = rust_fn(code, "finish_open")
    if opened is None or opened.count("DecoderStatus()") < 2 \
            or "undecodable" not in opened:
        bad.append("fn finish_open does not read every track's DecoderStatus into "
                   "Loaded's undecodable flag (docs/media-plan.md §7a)")
    tracks = rust_fn(code, "report_tracks")
    if tracks is None or not (0 <= tracks.find("if !p.loaded") < tracks.find(".AudioTracks()")):
        bad.append("report_tracks reads the item's tracks before it has opened — an HLS "
                   "item read while opening never raised MediaOpened (docs/traps.md)")
    if "CommandManager()?.SetIsEnabled(false)" not in code:
        bad.append("the players' command manager is left on — Windows would drive "
                   "a player from the flyout past the core's routing")
    # AN ADAPTIVE SOURCE IS AN AdaptiveMediaSource ON ITS OWN HttpClient, and
    # the in-box route is taken only by a progressive one: Media Foundation's
    # in-box HLS/DASH downloader goes silent for the process (docs/traps.md,
    # the WinUI adaptive pipeline that goes idle), and no quiet lane can make it.
    load = rust_fn(code, "load")
    branch = load.find("if p.adaptive {") if load else -1
    other = load.find("} else {", branch) if load else -1
    made = (load.find("AdaptiveMediaSource::CreateFromUriWithDownloaderAsync(", branch)
            if load else -1)
    inbox = [m.start() for m in re.finditer(r"MediaSource::CreateFromUri\(", load or "")]
    if load is None or branch < 0 or other < 0 or not branch < made < other \
            or not inbox or any(i < other for i in inbox) \
            or len(re.findall(r"MediaSource::CreateFromUri\(", code)) != len(inbox):
        bad.append("fn load does not give an adaptive source its own AdaptiveMediaSource "
                   "(CreateFromUriWithDownloaderAsync in the `if p.adaptive` branch, "
                   "MediaSource::CreateFromUri only in the else) — the in-box route "
                   "stalls (docs/traps.md, the WinUI adaptive pipeline that goes idle)")
    created = rust_fn(code, "adaptive_created")
    if created is None or not (0 <= created.find("trail_adaptive(") < created.find("attach(")):
        bad.append("fn adaptive_created attaches the source without trail_adaptive — a "
                   "stalled open's trail would carry no download")
    if load is None or "trail.print(generation)" not in load:
        bad.append("fn load's still-opening line does not print the open trail — the "
                   "bundle of a stalled open would not say which download it waited on")
    command = rust_fn(code, "command")
    if command is None or "SEEK_REPORT_MS" not in command \
            or "trail.print(generation)" not in command:
        bad.append("fn command's seek does not report a seek that never completes with its "
                   "trail — a paused seek the pipeline lost reads only as a missing cue")
    # MEDIA FOUNDATION IGNORES AN MP4 EDIT LIST (docs/traps.md): every read of
    # the session's clock goes through shown_ms, the seek adds the shift, a
    # progressive load reads it, and an open waits for an http(s) read.
    # media_tracks sees the seek on its one B-frame clip; a raw Position read
    # elsewhere (the position tick, the caption clock) no scene can see.
    clock = rust_fn(code, "position_ms") or ""
    reads = re.findall(r"[^\n]*\bPosition\(\)[^\n]*", code)
    raw = [r.strip() for r in reads if "shown_ms(" not in r
           and not ("shown_ms(" in clock and r in clock)]
    if not reads or raw:
        bad.append("winui/media.rs reads the session's Position without shown_ms ("
                   + ("; ".join(raw) or "no Position read at all") + ") — Media "
                   "Foundation's clock runs ahead of the picture by the edit list")
    if command is None or not re.search(r"saturating_add\(p\.shift\.load\(", command):
        bad.append("fn command's seek does not add the edit list's shift — a Windows seek "
                   "lands two frames early on a B-frame MP4")
    if load is None or not 0 <= other < load.find("read_shift(core, id, generation, url)"):
        bad.append("fn load does not read a progressive source's edit list (read_shift in "
                   "the non-adaptive branch)")
    if command is None or "let held = p.seek_in_flight;" not in command \
            or not re.search(r"if held \{\s*p\.seek_held = Some\(at\)", command):
        bad.append("fn command issues a seek while another is in flight — Media Foundation "
                   "then leaves the earlier picture drawn (docs/traps.md)")
    step = code.find("StepForwardOneFrame().and_then(|()| p.player.StepBackwardOneFrame())")
    guard = code.rfind("if !p.playing && !p.play_asked && p.seek_held.is_none()", 0, step)
    if step < 0 or guard < 0 or step - guard > 200:
        bad.append("a completed paused seek is not drawn by a frame step there and back, guarded "
                   "on the app not having asked to play — the seek alone left the old picture "
                   "(docs/traps.md, the WinUI paused seek)")
    if "seek_held.take()" not in code:
        bad.append("nothing issues a held seek when the one in flight completes")
    if opened is None or "p.shift_pending" not in opened.split("return;", 1)[0]:
        bad.append("fn finish_open does not wait for an http(s) edit list still being read")
    return bad


winui_media_out = winui_media_arms()
if winui_media_out:
    media_status = 1
    print("check-verbs: the WinUI media arm broke a rule no scene can see:",
          file=sys.stderr)
    print("\n".join(winui_media_out), file=sys.stderr)
print(f"check-verbs: WinUI media arm read "
      f"({len(re.findall(r'[.]media_report[(]', real(WINUI_MEDIA)))} report door(s))")
for pattern, repl, label, want in (
    (r"(element\.SetAreTransportControlsEnabled\()false", "true",
     "the element's transport controls on", 1),
    (r"(\n +)report\(core, id, Report::Ended\);(?=\n +ask_caption)",
     "let _ = core.scene.media_report(PlayerId(id), Report::Ended);",
     "a report outside the door", 1),
    (r"(    \}\n)    session_follow\(core\);\n    keep_awake\(core\);\n\}",
     "    keep_awake(core);\n}",
     "the door not following the session", 1),
    (r"(    if let Err\(e\) = )smtc\.SetPlaybackStatus\(status\)",
     "Ok::<(), windows_core::Error>(())",
     "the playback status never set", 1),
    (r"(\n +)let status = track\.SupportInfo\(\)\?\.DecoderStatus\(\)\?;",
     "let status = MediaDecoderStatus::FullySupported;", "the video decodability check cut", 1),
    (r"(\n    )report\(core, id, Report::Loaded",
     "let _ = MediaFailure::UnsupportedCodec;\n    report(core, id, Report::Loaded",
     "a reason spelled by the arm", 1),
    (r"(player\.CommandManager\(\)\?\.SetIsEnabled\()false", "true",
     "the command manager left on", 1),
    (r"(\n +)if !p\.loaded \{\n +return Ok\(None\);\n +\}", "",
     "the tracks read before the item opens", 1),
    (r"(\n    )if p\.adaptive \{", "if p.adaptive && false {",
     "the adaptive source left to the in-box route", 1),
    (r"(\n +)trail_adaptive\(&adaptive, &trail, generation\);", "",
     "the adaptive downloads not watched", 1),
    (r"(\n +)p\.trail\.print\(generation\);"
     r"(?=\n +\}\n +\}\);\n +std::thread::sleep\(std::time::Duration::from_millis\(crate::media)",
     "",
     "the stalled open's trail not printed", 1),
    (r"(\n +)p\.trail\.print\(generation\);(?=\n +\}\n +\}\);\n +\}\n +std::thread::sleep\("
     r"std::time::Duration::from_millis\(crate::media::TIMEOUT_MS - SEEK_REPORT_MS)", "",
     "the stalled seek's trail not printed", 1),
    (r"(\n +)let ms = position_ms\(p\);(?=\n +report\(core, id, Report::Position)",
     "let ms = p.player.PlaybackSession().and_then(|s| s.Position()).map(ms_of).unwrap_or(0);",
     "the position tick reading the raw clock", 1),
    (r"(let at = span_of\(ms\)\.Duration)\.saturating_add\(p\.shift\.load\(Ordering::SeqCst\)\)",
     "", "the seek without the edit list's shift", 1),
    (r"(\n +)read_shift\(core, id, generation, url\);", "",
     "the edit list never read", 1),
    (r"(let held = )p\.seek_in_flight;", "false;", "a seek issued over one in flight", 1),
    (r"(if let Some\(held\) = p\.)seek_held\.take\(\)", "seek_held.clone()",
     "the held seek never issued", 1),
    (r"(if !p\.playing )&& !p\.play_asked ", "", "a frame step over a play the app asked for", 1),
    (r"(if let Err\(e\) = p\.player\.)StepForwardOneFrame\(\)\.and_then\(\|\(\)\| "
     r"p\.player\.StepBackwardOneFrame\(\)\)", "Pause()", "the paused seek's frame step cut", 1),
    (r"(\|p\| p\.loaded) \|\| p\.shift_pending\)", ")",
     "the open not waiting for the edit list", 1),
):
    cut = g.doctor(f"winui media: {label}", real(WINUI_MEDIA), pattern,
                   lambda m, repl=repl: m.group(1) + repl, want=want)
    found = [f for f in winui_media_arms(media_src=cut) if f not in winui_media_out]
    print(f"check-verbs: winui-media negative ({label}): {len(found)} finding(s)")
    if not found:
        fail(f"check-verbs SELF-TEST: the WinUI media arm passed with {label}")

# --- THE BOUND'S ARMS (docs/media-plan.md §7c, RULED 2026-10-01) ----------
# The core decides an open or a seek past the bound with its own clock; each
# backend only WAKES it, after a source and after every seek, and TEARS ITS
# ITEM DOWN when the answer says the player timed out. media_timeout sees the
# open half on every lane (and the mac's teardown, since AVFoundation opens no
# next item while one hangs); no scene can make a seek hang, and no other lane
# can see an item left fetching, so these are read here.


def brace_body(code, head):
    at = code.find(head)
    if at < 0:
        return None
    start = code.find("{", at)
    depth = 0
    for i in range(start, len(code)):
        if code[i] == "{":
            depth += 1
        elif code[i] == "}":
            depth -= 1
            if depth == 0:
                return code[start:i + 1]
    return None


SWIFT_WAKE = ("KAYA_MEDIA_TIMEOUT_MS", "player_overdue(", "timedOut == 1",
              'self.load("")')
KOTLIN_WAKE = ("MEDIA_TIMEOUT_MS", "playerOverdue(", "timedOut == 1", 'load("")')
RUST_WAKE = ("crate::media::TIMEOUT_MS", "Report::Overdue")
TIMEOUT_ARMS = (
    ("SwiftUI", SWIFT, (
        ("private func wakeAtTheBound(", SWIFT_WAKE),
        ("    func load(_ locator: String)", ("wakeAtTheBound(", "cancelLoading()")),
        ("    func seek(_ ms: UInt64", ("wakeAtTheBound(",)),
    )),
    ("Compose", KOTLIN_MEDIA, (
        ("private fun wakeAtTheBound(", KOTLIN_WAKE),
        ("    fun load(locator: String)", ("wakeAtTheBound(",)),
        ("    fun seek(ms: Long", ("wakeAtTheBound(",)),
    )),
    ("GTK", GTK, (
        ("fn media_report(core: &mut CoreState",
         ("crate::media::timed_out(&published)", 'load(&p, "")')),
        ("fn load(p: &Rc<GtkPlayer>", RUST_WAKE),
        ("pub(super) fn player_command(id: u64", RUST_WAKE),
    )),
    ("WinUI", WINUI_MEDIA, (
        ("fn report(core: &mut CoreState, player: u64",
         ("crate::media::timed_out(&published)", 'load(core, player, "")')),
        ("fn load(core: &mut CoreState, id: u64, url: &str)", RUST_WAKE),
        ("pub(super) fn command(core: &mut CoreState", RUST_WAKE),
    )),
)


def timeout_arms(sources=None):
    bad = []
    for backend, path, rules in TIMEOUT_ARMS:
        text = (sources or {}).get(path)
        code = re.sub(r"//[^\n]*", "", text if text is not None else real(path))
        for head, needs in rules:
            body = brace_body(code, head)
            if body is None:
                bad.append(f"{backend} ({path}): no `{head.strip()}` to read — the census "
                           f"reads too little to agree with anything")
                continue
            for need in needs:
                if need not in body:
                    bad.append(f"{backend} ({path}): `{head.strip()}` lacks `{need}` — "
                               f"the bound's wake or its teardown is gone "
                               f"(docs/media-plan.md §7c)")
    return bad


timeout_out = timeout_arms()
timeout_status = 1 if timeout_out else 0
if timeout_out:
    print("check-verbs: the bound's arms broke a rule no scene can see:", file=sys.stderr)
    print("\n".join(timeout_out), file=sys.stderr)
print(f"check-verbs: the bound's arms read ({sum(len(r) for _, _, r in TIMEOUT_ARMS)} "
      f"bodies on {len(TIMEOUT_ARMS)} backends)")
GTK_SEEK_WAKE = (
    r"(PlayerCommand::Seek\(ms\) => \{\n +let generation = p\.inner\.borrow\(\)\.generation;\n)"
    r" +glib::timeout_add_local_once\(std::time::Duration::from_millis\("
    r"crate::media::TIMEOUT_MS\), move \|\| \{\n"
    r" +if player\(id\)[^\n]*\n +report\(id, crate::media::Report::Overdue\);\n"
    r" +\}\n +\}\);\n")
WINUI_SEEK_WAKE = (
    r"(\n +)std::thread::sleep\(std::time::Duration::from_millis\("
    r"crate::media::TIMEOUT_MS - SEEK_REPORT_MS\)\);"
    r"\n +post\(move \|core\| \{\n +if live\(core, id, generation\) \{\n"
    r" +report\(core, id, Report::Overdue\);\n +\}\n +\}\);")
for path, pattern, repl, label in (
    (SWIFT, r'(\n +)if timedOut == 1 \{ self\.load\(""\) \}', "",
     "SwiftUI's teardown cut"),
    (SWIFT, r"(\n +)wakeAtTheBound\(generation\)(?=\n +let to = CMTime)", "",
     "SwiftUI's seek wake cut"),
    (SWIFT, r"(\n +)self\.asset\?\.cancelLoading\(\)", "",
     "SwiftUI's asset left loading"),
    (KOTLIN_MEDIA, r'(\n +)if \(timedOut == 1\) load\(""\)', "",
     "Compose's teardown cut"),
    (KOTLIN_MEDIA,
     r"(fun seek\(ms: Long, report: Boolean\) \{\n +)wakeAtTheBound\(generation\)\n", "",
     "Compose's seek wake cut"),
    (GTK, r'(\n +)if torn_down \{\n +if let Some\(p\) = player\(id\) \{\n'
     r' +load\(&p, ""\);\n +\}\n +\}', "",
     "GTK's teardown cut"),
    (GTK, GTK_SEEK_WAKE, "", "GTK's seek wake cut"),
    (WINUI_MEDIA, r'(\n    )if torn_down \{\n(?: [^\n]*\n){3}    \}', "",
     "WinUI's teardown cut"),
    (WINUI_MEDIA, WINUI_SEEK_WAKE, "", "WinUI's seek wake cut"),
):
    cut = g.doctor(f"the bound: {label}", real(path), pattern,
                   lambda m, repl=repl: m.group(1) + repl)
    found = [f for f in timeout_arms({path: cut}) if f not in timeout_out]
    print(f"check-verbs: the bound negative ({label}): {len(found)} finding(s)")
    if not found:
        fail(f"check-verbs SELF-TEST: the bound's arms passed with {label}")

# --- THE READER'S ARM (docs/media-plan.md §8 ruling 4) ---------------------
# What tools/scenes/media_reader.steps cannot see: h264_frames.mp4 has ONE
# keyframe, so the nearest keyframe and the one at or before answer every
# keyframe time alike, and AVFoundation's default is the nearest (measured,
# docs/probes/media-extraction-2026-10-01.md); the bound runs from the latest
# answer and no scene's read is slow; and a stop that leaves the generator
# or the PCM reader running is invisible once the core drops the answers.
READER_ARMS = (
    ("private func answered(",
     ("KAYA_MEDIA_TIMEOUT_MS", "reader_overdue(", "self.stop(read, tearDown: true)")),
    ("    func frames(_ read: UInt64", ("requestedTimeToleranceAfter = .zero",
                                       "exact ? .zero : .positiveInfinity",
                                       "DispatchQueue.main.async", "self.answered(read)")),
    ("    func pcmArrived(", ("answered(read)", "stop(read)")),
    ("    func stop(_ read: UInt64, tearDown: Bool",
     ("cancelAllCGImageGeneration()", "cancelReading()", "if tearDown", "cancelLoading()")),
    ("    func close()", ("tearDown: true",)),
    ("func kayaPumpPCM(", ("DispatchQueue.main.sync",)),
)


def reader_arms(text=None):
    code = re.sub(r"//[^\n]*", "", text if text is not None else real(SWIFT))
    bad = []
    for head, needs in READER_ARMS:
        body = brace_body(code, head)
        if body is None:
            bad.append(f"SwiftUI ({SWIFT}): no `{head.strip()}` to read — the reader census "
                       f"reads too little to agree with anything")
            continue
        for need in needs:
            if need not in body:
                bad.append(f"SwiftUI ({SWIFT}): `{head.strip()}` lacks `{need}` — the "
                           f"reader's keyframe rule, its bound, its stop or its one "
                           f"reporting thread is gone (docs/media-plan.md §8 ruling 4)")
    return bad


reader_out = reader_arms()
if reader_out:
    print("check-verbs: the reader's arm broke a rule no scene can see:", file=sys.stderr)
    print("\n".join(reader_out), file=sys.stderr)
    timeout_status = 1
print(f"check-verbs: the reader's arm read ({len(READER_ARMS)} bodies)")
for pattern, label in (
    (r"(\n +)generator\.requestedTimeToleranceAfter = \.zero",
     "the keyframe's tolerance-after cut"),
    (r"(\n +)if live == 0 \{ self\.stop\(read\) \} else \{ self\.answered\(read\) \}",
     "the frame's bound restart cut"),
    (r"(\n +)generator\?\.cancelAllCGImageGeneration\(\)",
     "the stop leaving the generator running"),
    (r"(\n +)if KayaHost\.api\.reader_overdue\(self\.id, read\) == 1 "
     r"\{ self\.stop\(read, tearDown: true\) \}",
     "the overdue teardown cut"),
):
    cut = g.doctor(f"the reader: {label}", real(SWIFT), pattern, lambda m: m.group(1))
    found = [f for f in reader_arms(cut) if f not in reader_out]
    print(f"check-verbs: the reader negative ({label}): {len(found)} finding(s)")
    if not found:
        fail(f"check-verbs SELF-TEST: the reader's arm passed with {label}")

# --- THE WINUI FRAME UNDER RIGHT TO LEFT (docs/traps.md) ------------------
# Every window is mirrored at birth, a mirrored caption's drag regions are
# kaya's own, and expect_direction reads the frame. tasksrtl and formatar
# read the primary window; no RTL scene opens a second one, and a mirrored
# window's ClientToScreen answers its right edge, so these are read here.


def winui_frame_arms(src=None):
    bad = []
    code = re.sub(r"//[^\n]*", "", src if src is not None else real(WINUI))
    for head in ("fn setup(occ_tx", "ApplyOp::CreateWindow { window } => {"):
        at = code.find(head)
        body = brace_body(code[at + len(head) - 1:], "{") if at >= 0 else None
        if body is None or not 0 <= body.find("subclass(") < body.find("mirror_frame("):
            bad.append(f"`{head}` does not mirror its window after subclassing it "
                       f"(mirror_frame) — its caption stays left to right under an RTL locale")
    toolbar = rust_fn(code, "refresh_toolbar")
    if toolbar is None or toolbar.count("publish_mirrored_passthrough(") < 2 \
            or "SetAutoRefreshDragRegions(!frame_mirrored())" not in toolbar:
        bad.append("refresh_toolbar does not own a mirrored caption's drag regions — the "
                   "TitleBar's own land mirrored and steal the caption buttons")
    raw = [m.start() for m in re.finditer(r"ClientToScreen\(hwnd, &mut", code)]
    origin = rust_fn(code, "client_origin")
    start = code.find(origin) if origin else -1
    if origin is None or len(raw) != 1 or not start <= raw[0] < start + len(origin):
        bad.append("a ClientToScreen outside client_origin — a mirrored window answers its "
                   "right edge there")
    direction = brace_body(code, "    fn direction(&self) -> String {")
    if direction is None or "frame_direction(core)" not in direction:
        bad.append("the WinUI direction reader does not read the frame")
    return bad


frame_out = winui_frame_arms()
frame_status = 1 if frame_out else 0
if frame_out:
    print("check-verbs: the WinUI frame under right to left broke a rule no scene can see:",
          file=sys.stderr)
    print("\n".join(frame_out), file=sys.stderr)
print("check-verbs: the WinUI frame's mirroring read (2 window births, the caption's "
      "drag regions, the client origin, the direction reader)")
for pattern, repl, label in (
    (r"(\n            subclass\(&aux, window\.0\)\?;)\n            mirror_frame\(&aux\)\?;", "",
     "a second window left unmirrored"),
    (r"(titlebar\.SetAutoRefreshDragRegions\()!frame_mirrored\(\)", "true",
     "the TitleBar's own drag regions kept"),
    (r"(\n    let client = )client_origin\(hwnd\);\n    let mut outer",
     "{ let mut p = Point32 { x: 0, y: 0 }; unsafe { ClientToScreen(hwnd, &mut p) }; p };"
     "\n    let mut outer",
     "a raw ClientToScreen in the ink placement"),
    (r"(\n            Ok\(match )frame_direction\(core\) \{",
     "Ok::<(String, Vec<String>), String>((content.to_owned(), Vec::new())) {",
     "the direction reader not reading the frame"),
):
    cut = g.doctor(f"winui frame: {label}", real(WINUI), pattern,
                   lambda m, repl=repl: m.group(1) + repl)
    found = [f for f in winui_frame_arms(cut) if f not in frame_out]
    print(f"check-verbs: winui-frame negative ({label}): {len(found)} finding(s)")
    if not found:
        fail(f"check-verbs SELF-TEST: the WinUI frame passed with {label}")

# clip_mirrors() ran first and printed its own findings; its verdict
# is read here so there is exactly ONE verdict line.
if (clip_status or window_status or ink_status or ax_status
        or words_status or label_status or polish_status
        or metrics_status or keyed_status or drop_line_status
        or vtrace_status or norm_status or ind_status
        or answer_status or seed_focus_status or notify_auth_status
        or pump_status or immersive_status or kind_status
        or range_status or media_status or timeout_status or frame_status):
    raise SystemExit(1)
g.verdict(f"{len(verbs)} verbs, {len(rows)} constants "
          f"({len(canvas_rows)} of them the canvas vocabularies) + "
          f"the CLIP_* mirrors + the ink tolerance in 3 harnesses + "
          f"the ax spelling in 3 harnesses + the ax word set closed "
          f"across them + the verb trace in 3 "
          f"harnesses + the windowed tier's loop "
          f"+ the metrics class channel + the keyed target arms on 4 "
          f"backends + the reorder insertion indicator's 4 WinUI arms "
          f"+ the reorder's insertion indicator on GTK "
          f"+ every Step's Targets normalized "
          f"+ an action returns once the app has answered it in 3 "
          f"runners + the rich label's refusal sentence and draw on 4 arms "
          f"+ the polish pass's ground and rule per arm "
          f"+ the wayland clipboard seed's focus request "
          f"+ notification authorization asked only while undecided "
          f"+ the interpreter's pump started without a window "
          f"+ the Compose immersive arm read from the insets "
          f"+ every Compose kind's create and render arms "
          f"+ the range's arms in both interpreters "
          f"+ the media arms (a bare layer, one report door, playbackState first) "
          f"+ the bound's wake and teardown on 4 arms "
          f"+ the reader's keyframe rule, bound, stop and reporting thread "
          f"+ the WinUI frame mirrored under right to left "
          f"+ the Compose media arm (PlayerSurface, one door, raw facts, decodability) "
          f"+ the GTK media arm (GtkPicture over the sink, one door, raw facts, decodability) "
          f"+ the Android video read (the device's screencap, its tolerance, no decoder moved "
          f"between surfaces, no picture no SurfaceView) "
          f"+ spec hash against 2 interpreters")
