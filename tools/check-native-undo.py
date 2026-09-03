#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import Gate, dev_shell_or_die

dev_shell_or_die()

# The two native-tier guards no scene can fail (CLAUDE.md's gate list).
# What it does NOT pin: a call that is present but disabled satisfies
# clause 3, and no text gate can do better — what it pins is that the arm
# and the clear are one unit.

import re

GTK = "crates/kaya/src/gtk.rs"
WINUI = "crates/kaya/src/winui/mod.rs"
SWIFTUI = "swift/KayaSwiftUI.swift"
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"

gate = Gate("check-native-undo")

# KayaSwiftUI.swift serves mac AND iOS, whose brackets differ in spelling
# and not in rule, so `mark` is a LIST and any one entry satisfies it.
# ANCHORS ARE CALL SHAPES, not bare names: a bare `note_native_undo`
# matches gtk.rs's own helper DEFINITION, and a gate that matches a
# definition passes when the call is deleted.
BACKENDS = [
    dict(
        path=GTK, name="gtk",
        sample=r"core\.scene\.note_native_undo\(",
        mark=[r"ledger_quiet\.set\(true\)"],
        readback=r"ledger_quiet\.get\(\)",
        bank=r"bank_text_changed\(",
        arm=r"ApplyOp::ClearUndo\b",
        clear=r"clear_native_undo\(",
    ),
    dict(
        path=WINUI, name="winui",
        sample=r"core\.scene\.note_native_undo\(",
        mark=[r"core\.ledger_quiet\.insert\("],
        readback=r"core\.ledger_quiet\.get\(",
        bank=r"\.note_text_changed\(",
        arm=r"ApplyOp::ClearUndo\b",
        clear=r"clear_native_undo\(",
    ),
    dict(
        path=SWIFTUI, name="swiftui",
        sample=r"api\.note_native_undo\(",
        mark=[r"kayaNoteNativeUndoEcho\(",
              r"kayaRoutedNativeUndoDepth \+= 1"],
        readback=r"kayaTakeNativeUndoEcho\(",
        bank=r"api\.emit_text_changed\(",
        arm=r"case applyClearUndo:",
        clear=r"kayaClearUndoForGroup\(",
    ),
    dict(
        path=COMPOSE, name="compose",
        sample=r"KayaPresent\.noteNativeUndo\(",
        mark=[r"kayaNativeUndoEcho\[[^\]]*\] = "],
        readback=r"kayaTakeNativeUndoEcho\(",
        bank=r"KayaPresent\.emitTextChanged\(",
        arm=r"APPLY_CLEAR_UNDO ->",
        clear=r"kayaClearUndoForGroup\(",
    ),
]

DECL = re.compile(r"(?:func|fun|fn)\s+$")

# How far a ClearUndo arm's body may reach before the pairing stops
# being one.
ARM_LINES = 25


def hits(text, pattern):
    """Every occurrence of `pattern` that is a USE rather than a
    DECLARATION."""
    out = []
    for m in re.finditer(pattern, text):
        head = re.match(r"[A-Za-z_][A-Za-z0-9_]*", text[m.start():])
        before = text[:m.start()]
        if head and DECL.search(before[-24:]):
            continue
        out.append(m)
    return out


def skip_string(text, j):
    """Past the string literal starting at `j`, INTERPOLATIONS AND ALL.

    Scanning to the next quote desyncs on both interpreted files: Kotlin's
    `"…(${list.joinToString("; ")})"` and Swift's
    `"can\\(redo ? "Redo" : "Undo")"` nest a string inside an expression
    inside a string, so the next quote opens the inner one."""
    n = len(text)
    j += 1
    while j < n:
        c = text[j]
        if c == "\\" and not text.startswith("\\(", j):
            j += 2
            continue
        if c == '"':
            return j + 1
        # Kotlin `${…}` and Swift `\(…)`: a code region inside a string.
        opener = "${" if text.startswith("${", j) else (
            "\\(" if text.startswith("\\(", j) else None)
        if opener:
            close = "}" if opener == "${" else ")"
            open_ch = "{" if opener == "${" else "("
            depth = 0
            j += len(opener) - 1
            while j < n:
                if text[j] == '"':
                    j = skip_string(text, j)
                    continue
                if text[j] == open_ch:
                    depth += 1
                elif text[j] == close:
                    depth -= 1
                    if depth == 0:
                        j += 1
                        break
                j += 1
            continue
        j += 1
    return j


def blocks(text):
    """Every {..} block in the file, comments and string literals
    skipped. None if the scan lost sync: a reader that is lost must fail
    rather than report a clean bill."""
    stack, out, j, n = [], [], 0, len(text)
    while j < n:
        c = text[j]
        if c == "/" and text.startswith("//", j):
            j = text.find("\n", j)
            if j < 0:
                break
            continue
        if c == "/" and text.startswith("/*", j):
            j = text.find("*/", j)
            if j < 0:
                break
            j += 2
            continue
        if text.startswith('r#"', j):
            j = text.find('"#', j)
            if j < 0:
                break
            j += 2
            continue
        if text.startswith('"""', j):
            j = text.find('"""', j + 3)
            if j < 0:
                break
            j += 3
            continue
        if c == '"':
            j = skip_string(text, j)
            continue
        # A character literal, and only a real one: the pattern must not
        # match a Rust LIFETIME (`&'a str`), which has no closing quote
        # and would eat the rest of the file.
        if c == "'":
            lit = re.match(r"'(?:\\.|[^\\'])'", text[j:])
            if lit:
                j += lit.end()
                continue
        if c == "{":
            stack.append(j)
        elif c == "}":
            if not stack:
                return None
            out.append((stack.pop(), j))
        j += 1
    return None if stack else out


def innermost(spans, at):
    """The smallest block containing `at`, or None at file scope."""
    best = None
    for a, b in spans:
        if a < at < b and (best is None or (b - a) < (best[1] - best[0])):
            best = (a, b)
    return best


def line(text, at):
    return text.count("\n", 0, at) + 1


def check(texts):
    """texts: {site: text}. Offender sentences."""
    bad = []
    for be in BACKENDS:
        path, name = be["path"], be["name"]
        text = texts[path]
        spans = blocks(text)
        if spans is None:
            bad.append(f"{path}: this gate's block reader lost sync with "
                       "the file (unbalanced braces after skipping "
                       "comments and strings) — every clause below would "
                       "be guesswork")
            continue

        # 0. VACUITY: a clause whose anchor stopped matching reports a
        #    clean bill about nothing.
        missing = [what for what in ("sample", "readback", "bank", "arm",
                                     "clear")
                   if not hits(text, be[what])]
        if not any(hits(text, m) for m in be["mark"]):
            missing.append("mark")
        if missing:
            bad.append(
                f"{path}: this gate looks for {', '.join(sorted(missing))} "
                f"in the {name} arm and no longer finds "
                f"{'it' if len(missing) == 1 else 'them'} — either the "
                "native-undo tier left this backend (say so here) or its "
                "spelling moved and the clause went vacuous")
            continue

        # 1. SAMPLE ⇒ MARK.
        if not any(hits(text, m) for m in be["mark"]):
            bad.append(
                f"{path}: the {name} arm calls the core's native-undo "
                "sample but marks no emission ledger-quiet — the ordinary "
                "text_changed its own walk provokes is banked a second "
                "time, which restates the walk's position as a new "
                "high-water and loses the run the redo side needs")

        # 2. THE MARK IS CONSUMED WHERE THE EDIT IS REPORTED — a read
        #    that drifts away from the report decides nothing.
        for m in hits(text, be["readback"]):
            span = innermost(spans, m.start())
            where = text[span[0]:span[1]] if span else ""
            if not hits(where, be["bank"]):
                bad.append(
                    f"{path}:{line(text, m.start())}: the ledger-quiet "
                    f"read is not in the block that reports the edit "
                    f"({be['bank']}) — a bracket read away from the "
                    "report suppresses nothing, and the walk is banked "
                    "twice")

        # 3. THE CLEAR ARM CLEARS. The body is a WINDOW, not a block,
        #    deliberately: Rust's `=> { … }` opens on the PATTERN's brace
        #    (`{ window }`) and Swift's `case x:` has none at all, so only
        #    a line window reads all three languages.
        for m in hits(text, be["arm"]):
            span = innermost(spans, m.start())
            stop = len(text) if span is None else span[1]
            cut = text.find("\n", m.start())
            for _ in range(ARM_LINES):
                if cut < 0:
                    break
                cut = text.find("\n", cut + 1)
            if cut >= 0:
                stop = min(stop, cut)
            where = text[m.start():stop]
            if not hits(where, be["clear"]):
                bad.append(
                    f"{path}:{line(text, m.start())}: the ClearUndo arm "
                    f"does not call the platform's clear ({be['clear']}) "
                    "— A1's keystone is what makes every episode begin "
                    "with an empty native stack, so without it a native "
                    "undo can reach back past the frontier episode's "
                    "start and the ledger stops being ordered")
    return bad


REAL = {p: gate.read(p) for p in (GTK, WINUI, SWIFTUI, COMPOSE)}


# The self-tests doctor COPIES OF THE REAL FILES, and each refusal is
# checked for its REASON: an exit code alone is satisfied by any unrelated
# finding (CLAUDE.md's watch-the-negative-fail rule).
def refuses(texts, fragment, label):
    out = check(texts)
    if not out:
        print(f"check-native-undo: SELF-TEST FAIL ({label} passed)",
              file=sys.stderr)
        sys.exit(1)
    blob = "\n".join(out)
    if fragment not in blob:
        print(f"check-native-undo: SELF-TEST FAIL ({label} failed for "
              f"another reason: {blob})", file=sys.stderr)
        sys.exit(1)
    print(f"check-native-undo: watched failing: {label}", file=sys.stderr)


# 1. THE BRACKET DELETED.
no_bracket = gate.doctor(
    "the compose bracket-deletion perturbation", REAL[COMPOSE],
    r"val quiet = kayaTakeNativeUndoEcho\([^)]*\)", "val quiet = false",
    flags=re.S)
refuses({**REAL, COMPOSE: no_bracket}, "no longer finds",
        "a Compose arm whose ledger-quiet read is gone")

# 2. THE BRACKET DRIFTED AWAY FROM THE REPORT — the shape a presence
#    check would pass. Two substitutions: the read has to LEAVE the
#    emission and land somewhere real.
half = gate.doctor(
    "the swiftui bracket-deletion half", REAL[SWIFTUI],
    r"let quiet = kayaTakeNativeUndoEcho\(node\.id, text\)",
    "let quiet = false", flags=re.S)
stranded = gate.doctor(
    "the swiftui stranded-read half", half,
    r"func kayaCoreUndo\(_ window: UInt64\) \{",
    'func kayaCoreUndo(_ window: UInt64) {\n'
    '    _ = kayaTakeNativeUndoEcho(window, "")', flags=re.S)
refuses({**REAL, SWIFTUI: stranded},
        "is not in the block that reports the edit",
        "a SwiftUI arm whose bracket read drifted off the emission")

# 3. THE CLEAR DROPPED FROM THE APPLY ARM.
no_clear = gate.doctor(
    "the gtk clear-arm perturbation", REAL[GTK],
    r"ApplyOp::ClearUndo \{ window \} => \{\n            "
    r"if let Some\(id\) = focused_text_in\(core, window\) \{\n"
    r"                core\.clear_native_undo\(id\);\n            \}",
    "ApplyOp::ClearUndo { window } => {\n            let _ = window;",
    flags=re.S)
refuses({**REAL, GTK: no_clear}, "does not call the platform's clear",
        "a GTK ClearUndo arm that clears nothing")

# 4. THE SAMPLE'S OWN ANCHOR MOVED — the vacuity direction.
moved = gate.doctor(
    "the winui anchor-rename perturbation", REAL[WINUI],
    r"core\.scene\.note_native_undo\(",
    "core.scene.note_native_undo_renamed(", flags=re.S)
refuses({**REAL, WINUI: moved}, "no longer finds",
        "a WinUI backend whose core seam moved")

offenders = check(REAL)
if offenders:
    print("\n".join(offenders))
    print("check-native-undo: FAIL")
    sys.exit(1)
print("check-native-undo: OK")
