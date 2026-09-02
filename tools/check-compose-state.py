#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import Gate, dev_shell_or_die

dev_shell_or_die()

# A KayaSceneModel FIELD THAT A COMPOSABLE DRAWS FROM MUST BE COMPOSITION
# STATE. Compose recomposes a function when a `mutableStateOf` it read
# changes; a plain field is read once, at the first composition, and the
# surface never moves again. `windowTitle` shipped as a plain field for a
# milestone and only a film caught it (docs/deferred.md, "The CLASS behind
# the stale title bar has no gate"): nothing about a plain field is a
# compile error, and the scenes read the OTHER surface (the task label).
#
# THE RULE, read off the file rather than off a list somebody keeps: every
# `KayaSceneModel.<field>` READ inside a `@Composable fun` body names a
# field declared `by mutableStateOf` / `mutableStateListOf` /
# `mutableStateMapOf`, or is in the EXEMPT table below with its reason —
# and every exemption is still LIVE (some composable still reads it),
# because an exemption nobody needs is the next stale audit. Writes are
# not reads: a composable STAMPING a plain field for the harness to read
# (formFactor, menuPresentation, …) is fine; only a draw read recomposes.
# Comments and strings are blanked positionally first, since the file's
# prose names every field and a bare-word census reported `rows`,
# `columns` and `labels` off comments and KayaNode locals alike.
#
# AND THE ONE ORDERING THE EXEMPTIONS LEAN ON IS ASSERTED, NOT ASSUMED:
# the four alert fields are plain and read to draw, safe only because
# APPLY_PRESENT_ALERT writes them BEFORE `alertId`, which IS state and is
# the recomposition key. Swap two lines and the dialog draws last time's
# title — so that arm is read and the order is held.

import re

g = Gate("check-compose-state")

COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"
MODEL = "KayaSceneModel"

# (field, why a plain read from a composable is safe). Each must still be
# read by some composable, or the gate says the exemption is stale.
EXEMPT = {
    "alertTitle": "written before alertId (state) in APPLY_PRESENT_ALERT; "
                  "the ordering is asserted below",
    "alertMessage": "same",
    "alertActions": "same",
    "alertCancel": "same",
    "sectionIndex": "a registry: the composable looks it up by "
                    "selectedSection, which IS state, and KayaSection's own "
                    "fields are state",
    "menuItems": "a registry: looked up by menuOverflowDrilled, which IS "
                 "state, and KayaMenuItem's fields are state",
}
# The file spells the collections both bare and fully qualified
# (`androidx.compose.runtime.mutableStateListOf`).
STATE_INITIALIZERS = re.compile(
    r"(?:\bby\s+(?:[\w.]+\.)?mutable(?:Int|Long|Float|Double)?StateOf\b"
    r"|=\s*(?:[\w.]+\.)?mutableState(?:List|Map)Of\b)")
# `[ \t]*`, never `\s*`: a blanked comment line is all spaces, and `\s*`
# from its start would swallow the newline and the next line's indent,
# leaving every field after a comment uncounted (the first draft read
# 29 of 56).
FIELD = re.compile(
    r"^([ \t]*)(?:@\w+(?:\([^)]*\))?[ \t]*)?(?:(?:internal|private|public)[ \t]+)?"
    r"(?:lateinit[ \t]+)?(var|val)[ \t]+(\w+)\b(.*)$", re.M)


def blank(text):
    """Comments and string literals replaced by spaces of the same length,
    newlines kept, so line numbers survive and prose cannot match."""
    out = []
    i, n = 0, len(text)
    while i < n:
        two = text[i:i + 2]
        if two == "//":
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif two == "/*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
        elif text.startswith('"""', i):
            j = text.find('"""', i + 3)
            j = n if j < 0 else j + 3
            out.append(re.sub(r"[^\n]", " ", text[i:j]))
            i = j
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            j = min(j + 1, n)
            out.append('"' + " " * (j - i - 2) + '"' if j - i >= 2 else '"')
            i = j
        elif text[i] == "'":
            j = i + 1
            while j < n and text[j] != "'":
                j += 2 if text[j] == "\\" else 1
            j = min(j + 1, n)
            out.append("'" + " " * (j - i - 2) + "'" if j - i >= 2 else "'")
            i = j
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def brace_block(text, open_at):
    """The index one past the `}` matching the `{` at open_at."""
    depth = 0
    for i in range(open_at, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return i + 1
    return len(text)


def line_of(text, at):
    return text.count("\n", 0, at) + 1


def model_fields(code):
    """(name -> (line, state_backed)) for every field of the model object."""
    head = re.search(r"^object " + MODEL + r"\s*\{", code, re.M)
    if head is None:
        return None
    end = brace_block(code, head.end() - 1)
    block = code[head.end():end]
    fields = {}
    for m in FIELD.finditer(block):
        # A declaration at the object's own indentation (4), not a local
        # inside one of its functions.
        if len(m.group(1)) != 4:
            continue
        name = m.group(3)
        if m.group(4).lstrip().startswith("("):
            continue  # a function's parameter list, not a field
        # The initializer may sit on the next line (`val contextMenus =`
        # then `mutableStateMapOf…`): read to the next member at the
        # object's indentation.
        nxt = re.compile(r"\n {4}\S").search(block, m.end())
        rest = block[m.end(3):nxt.start() if nxt else len(block)]
        fields[name] = (line_of(code, head.end() + m.start()),
                        bool(STATE_INITIALIZERS.search(rest)))
    return fields


def composables(code):
    """(name, body_start, body_end) for every `@Composable fun`. An
    `@Composable` that annotates a lambda TYPE (`inner: @Composable () ->
    Unit`) or a return type is skipped: it is followed by `(`, not `fun`."""
    out = []
    for m in re.finditer(r"@Composable\b", code):
        after = code[m.end():m.end() + 80]
        head = re.match(r"\s*(?:(?:private|internal|public|inline)\s+)*fun\s+"
                        r"(?:<[^>]*>\s*)?(\w+)\s*\(", after)
        if head is None:
            continue
        name = head.group(1)
        params_open = m.end() + head.end() - 1
        depth = 0
        i = params_open
        while i < len(code):
            if code[i] == "(":
                depth += 1
            elif code[i] == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        # Past the return type to the body: `{` or `=`.
        j = i + 1
        while j < len(code) and code[j] not in "{=":
            if code[j] == "\n" and code[j:j + 2] == "\n\n":
                break
            j += 1
        if j >= len(code) or code[j] not in "{=":
            continue
        if code[j] == "{":
            end = brace_block(code, j)
        else:
            # An expression body runs to the first line at or above the
            # declaration's own indentation.
            decl_line_start = code.rfind("\n", 0, m.start()) + 1
            indent = len(code[decl_line_start:m.start()])
            end = j
            for ln in re.finditer(r"\n([ \t]*)(?=\S)", code[j:]):
                if len(ln.group(1)) <= indent:
                    end = j + ln.start()
                    break
            else:
                end = len(code)
        out.append((name, j, end))
    return out


def model_reads(code, name, body_start, body_end):
    """Every `KayaSceneModel.<field>` in a composable body, as
    (field, line, is_write)."""
    body = code[body_start:body_end]
    out = []
    for m in re.finditer(MODEL + r"\.(\w+)", body):
        tail = body[m.end():m.end() + 40]
        # An indexed write may nest brackets (`cellMinX[node.children[i].id]
        # = x`), so the index is matched to one nesting level.
        is_write = bool(re.match(r"\s*(?:=(?!=)|\+=|-=|\.add\(|\.remove\("
                                 r"|\.clear\(|\[(?:[^\[\]]|\[[^\]]*\])*\]\s*=(?!=))",
                                 tail))
        out.append((m.group(1), line_of(code, body_start + m.start()),
                    is_write))
    return out


def alert_order(code):
    """The APPLY_PRESENT_ALERT arm's writes, as the ordered field list."""
    arm = re.search(r"APPLY_PRESENT_ALERT\s*->\s*\{", code)
    if arm is None:
        return None
    end = brace_block(code, arm.end() - 1)
    return re.findall(MODEL + r"\.(alert\w+)\s*=(?!=)", code[arm.end():end])


def census(text):
    """The findings for one KayaCompose.kt text, plus the counts the
    verdict prints. A pure function of its input, so the negatives can
    feed it doctored copies."""
    bad = []
    code = blank(text)
    fields = model_fields(code)
    if fields is None:
        return [f"{COMPOSE}: no `object {MODEL}` — the census anchors on "
                f"it; re-point the gate rather than weaken it"], {}
    comps = composables(code)
    reads = 0
    live_exempt = set()
    for name, start, end in comps:
        for field, line, is_write in model_reads(code, name, start, end):
            if field not in fields:
                continue  # a method call on the model, not a field
            if is_write:
                continue
            reads += 1
            fline, state = fields[field]
            if state:
                continue
            if field in EXEMPT:
                live_exempt.add(field)
                continue
            bad.append(
                f"{COMPOSE}:{line}: {name} draws from {MODEL}.{field}, "
                f"declared plain at line {fline} — a composable reads a "
                f"plain field once and never recomposes on it; declare it "
                f"`by mutableStateOf` (or add it to EXEMPT with the reason "
                f"it cannot go stale)")
    for field in EXEMPT:
        if field not in fields:
            bad.append(f"EXEMPT names {MODEL}.{field}, which the model no "
                       f"longer declares — a stale exemption")
        elif field not in live_exempt:
            bad.append(f"EXEMPT names {MODEL}.{field}, which no composable "
                       f"reads any more — a stale exemption is the next "
                       f"stale audit; drop it")
    order = alert_order(code)
    if order is None:
        bad.append(f"{COMPOSE}: no APPLY_PRESENT_ALERT arm — the alert "
                   f"ordering the four exemptions lean on cannot be read")
    else:
        four = ["alertTitle", "alertMessage", "alertActions", "alertCancel"]
        if "alertId" not in order or order[-1] != "alertId":
            bad.append(f"{COMPOSE}: APPLY_PRESENT_ALERT does not write "
                       f"alertId LAST (writes: {', '.join(order)}) — the "
                       f"four plain alert fields are read to draw and are "
                       f"safe only because the state key lands after them")
        missing = [f for f in four if f not in order]
        if missing:
            bad.append(f"{COMPOSE}: APPLY_PRESENT_ALERT never writes "
                       f"{', '.join(missing)} — the exemption's premise")
    counts = {"fields": len(fields),
              "state": sum(1 for _l, s in fields.values() if s),
              "composables": len(comps), "reads": reads}
    return bad, counts


real = g.read(COMPOSE)

# THE WATCHED NEGATIVES, each a doctored copy with its substitution count
# printed, each demanding the sentence the real census would print.
NEGATIVES = [
    ("windowTitle made a plain field (the shipped defect)",
     r"var windowTitle by mutableStateOf\(\"\"\)", 'var windowTitle = ""',
     "draws from KayaSceneModel.windowTitle, declared plain"),
    ("alertId written before alertCancel",
     r"(\n\s+)KayaSceneModel\.alertCancel = cancel(\n\s+)"
     r"KayaSceneModel\.alertId = alert",
     r"\1KayaSceneModel.alertId = alert\2KayaSceneModel.alertCancel = cancel",
     "does not write alertId LAST"),
    ("an exemption nobody reads (alertCancel's read cut)",
     r"Text\(KayaSceneModel\.alertCancel\)", "Text(\"\")",
     "which no composable reads any more"),
    ("a composable drawing from a plain registry (labels)",
     r"(\n\s+)(Text\(KayaSceneModel\.alertCancel\))",
     r"\1val stale = KayaSceneModel.labels.size\1\2",
     "draws from KayaSceneModel.labels, declared plain"),
]
for label, pattern, repl, want in NEGATIVES:
    doctored = g.doctor(label, real, pattern, repl)
    g.negative(label, lambda d=doctored: census(d)[0], want=want)
g.negatives_ran(len(NEGATIVES))

findings, counts = census(real)
g.counted("KayaSceneModel fields", range(counts.get("fields", 0)), floor=40)
g.counted("composable functions", range(counts.get("composables", 0)),
          floor=15)
g.counted("model reads inside composables", range(counts.get("reads", 0)),
          floor=10)
for line in findings:
    g.finding(line)
g.verdict(f"{counts['fields']} fields ({counts['state']} state-backed), "
          f"{counts['composables']} composables, {counts['reads']} model "
          f"reads classified, {len(EXEMPT)} exemptions live, the alert "
          f"ordering held, {len(NEGATIVES)} watched negatives")
