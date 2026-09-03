#!/usr/bin/env python3
"""No sugar guest may build at the FLOOR — any floor, not just widget kinds.

Invariant 5: only the C guests keep the fully explicit floor. The floor
vocabulary this sweeps is check-sugar-surface's, censused in
docs/tpl-props-plan.md §2.

WHY THE SHARPENINGS ARE SHAPES, NOT BIGGER REGEXES:

- kaya's For combinator collides with its host language's own iteration
  method (`List<T>.ForEach`, `Iterator::for_each`). kaya's takes the
  COLLECTION first and the body second; every stdlib form takes the body
  alone. So the discriminator is >= 2 top-level arguments, which needs a
  paren-balanced scan — a comma regex breaks on nested calls. (Java left
  this shape 2026-08-24: its callback For is gone and its floor rule is
  a plain name.)
- Swift's stdlib forEach is trailing-closure (`xs.forEach { .. }`);
  kaya's takes the collection in the parens. `\\.forEach\\([^{]` decides.
- Generated files are exempt BY MARKER, not by filename glob: a glob
  would be a second list of the same fact.
- OCaml's element-bind family must not match the sugar that replaced
  it: the sugar spells the same words as LABELLED ARGUMENTS
  (`label ~bind_field:element ()`), so the pattern requires whitespace
  or `(` after the name. Haskell gets the twin pre-emptively.

COMMENTS ARE STRIPPED FIRST: the converted guests explain their old
floor spelling in a comment above the new sugar call, so a sweep that
read comments would report every file it just fixed (measured — a first
pass counted 14 widget-kind hits where there were 13).

EVERY RULE IS WATCHED, EVERY RUN: each carries a `fire` line (must
match) and a `quiet` line (must not), run through the same engine as the
sweep before any verdict is printed.

Exit 0 when no sugar guest spells the floor; 1 listing each line that
does.
"""

import os
import re
import sys

# --- rule tables ------------------------------------------------------
#
# Per extension: (label, kind, pattern, fire, quiet)
#   kind 'line'  — regex against one comment-stripped line
#   kind 'for2'  — pattern locates a call; it counts as a hit only if
#                  the call has >= 2 top-level arguments (kaya's For
#                  shape; stdlib iteration takes the body alone)
# `fire` and `quiet` feed the built-in self-test.

RULES = {
    ".rs": [
        ("widget-kind construction", "line", r"\.widget\(",
         "let n = t.widget(WidgetKind::Entry);",
         "let n = t.entry();"),
        ("the add_child chain", "line", r"\.add_child\(",
         "tx.add_child(column, field);",
         "tx.column(|tx| { tx.label(s); });"),
        ("generic prop writes", "line", r"Prop::",
         "tx.set(add, Prop::Text, \"add\");",
         "tx.set_text(editor, DOC);"),
        ("bind_element by index", "line", r"\.bind_element\(",
         "t.bind_element(label, Prop::Text, 0);",
         "let row = t.label(Field::<StrKind>::element());"),
        ("the for_each combinator", "for2", r"\.for_each\(",
         "let (_, items) = tx.for_each(&groups, |t| { t.label(x); });",
         "v.iter().for_each(drop);"),
    ],
    ".go": [
        # THE ARGUMENT IS THE DISCRIMINATOR: the floor constructor takes a
        # KIND, while `rows.Widget()` — the For container a Rows chain
        # hands back — takes nothing and is the only way to name it.
        ("widget-kind construction", "line", r"\.Widget\([^)]",
         "column := tx.Widget(kaya.KindColumn)",
         "table = rows.Widget()"),
        ("the generic BindText", "line", r"\.BindText\(",
         "tx.BindText(statusLabel, status)",
         "tx.Label(status)"),
        ("BindTextElement by index", "line", r"\.BindTextElement\(",
         "t.BindTextElement(label, 0)",
         "row.Label(row.Value())"),
        ("the AddChild chain", "line", r"\.AddChild\(",
         "tx.AddChild(column, field)",
         "tx.Column(func() { tx.LabelText(\"x\") })"),
        # No ForEach rule: Go's callback For is gone — a For is a for
        # statement over Rows.All(), and there is no floor spelling of it
        # left to catch.
    ],
    ".cs": [
        ("widget-kind construction", "line", r"\.Widget\(",
         "var column = tx.Widget(KayaWire.KindColumn);",
         "var note = t.Entry();"),
        ("the generic BindText", "line", r"\.BindText\(",
         "tx.BindText(statusLabel, status);",
         "tx.Label(status);"),
        ("BindTextElement by index", "line", r"\.BindTextElement\(",
         "t.BindTextElement(label);",
         "t.Label(Todo.Title);"),
        ("the AddChild chain", "line", r"\.AddChild\(",
         "tx.AddChild(column, field);",
         "tx.Column(() => tx.Label(s));"),
        ("the ForEach combinator", "for2", r"\.ForEach\(",
         "var todoList = tx.ForEach(todos, t => {});",
         "list.ForEach(x => Console.WriteLine(x));"),
    ],
    ".java": [
        ("the addChild chain", "line", r"\.addChild\(",
         "tx.addChild(column, field);",
         "tx.mount(tx.column(() -> { tx.label(status); }));"),
        ("widget-kind construction", "line", r"\.widget\(",
         "KayaApp.Widget column = tx.widget(KayaWire.KIND_COLUMN);",
         "KayaApp.Node note = tpl.entry();"),
        ("the generic bindText", "line", r"\.bindText\(",
         "tx.bindText(statusLabel, status);",
         "tx.label(status);"),
        ("bindTextElement by index", "line", r"\.bindTextElement\(",
         "t.bindTextElement(label, 0);",
         "t.label(TodoKaya.title());"),
        # Java's callback For died 2026-08-24 — the one form is the eager
        # `rows` Iterable — so `.forEach(` names nothing the binding
        # exports and the compiler holds that. The tier below the for
        # statement is KayaRecords.rowTrace, public because the generated
        # surfaces call it from the guests' own package.
        ("the rowTrace machinery", "line", r"KayaRecords\.rowTrace\(",
         "return KayaRecords.rowTrace(tx, c, t -> new Row(t, c));",
         "for (var row : TodoKaya.rows(tx, todos)) {"),
    ],
    ".swift": [
        ("widget-kind construction", "line", r"\.widget\(",
         "let row = r.widget(UInt32(KAYA_KIND_LABEL))",
         "let row = r.label(KayaField<String>.element)"),
        ("the generic bindText", "line", r"\.bindText\(",
         "tx.bindText(statusLabel, status)",
         "tx.label(status)"),
        ("bindTextElement by index", "line", r"\.bindTextElement\(",
         "r.bindTextElement(row)",
         "let row = r.label(f)"),
        ("the addChild chain", "line", r"\.addChild\(",
         "tx.addChild(column, field)",
         "tx.column { tx.label(s) }"),
        # Swift's stdlib forEach is trailing-closure; kaya's takes the
        # collection inside the parens. `[^{` is the whole distinction.
        ("the forEach combinator", "line", r"\.forEach\([^{]",
         "let (todoList, _) = tx.forEach(todos) { t in }",
         "xs.forEach({ x in print(x) })"),
    ],
    ".hs": [
        ("widget-kind construction", "line", r"(?<![A-Za-z])widget kind[A-Z]",
         "note <- widget kindEntry",
         "note <- entry"),
        ("the addChild chain", "line", r"(?<![A-Za-z])addChild\s",
         "addChild column field",
         "root <- column [] [pure editor]"),
        ("the generic bindText", "line", r"(?<![A-Za-z])bindText\s",
         "bindText statusLabel status",
         "labelBound status"),
        ("the element/field bind family", "line",
         r"(?<![A-Za-z])bind(Text|Checked|Value|Source)(Element|Field)[\s(]",
         "bindTextElement label 0",
         "labelBound status [A11yId \"x\"]"),
        # The renamed template prop write (docs/tpl-props-plan.md F3):
        # the verb kept setText, the floor became setTextProp.
        ("the setTextProp prop write", "line",
         r"(?<![A-Za-z])setTextProp[\s(]",
         "setTextProp n \"hi\"",
         "setText editor doc"),
        # A For whose result is dropped is what `each` is.
        ("a For whose result it drops", "line",
         r"\(\)\)[\s]*<-[\s]*forEach",
         "(todoList, ()) <- forEach todos $ do",
         "(todoList, itemsColl) <- forEach groups $ do"),
    ],
    ".ml": [
        ("widget-kind construction", "line", r"(?<![A-Za-z_])widget kind_",
         "let column = widget kind_column in",
         "let editor = textarea ~on_change:f () in"),
        ("the add_child chain", "line", r"(?<![A-Za-z_])add_child\s",
         "add_child column field;",
         "let root = column [ w editor ] () in"),
        ("the generic bind_text", "line", r"(?<![A-Za-z_])bind_text\s",
         "bind_text status_label status;",
         "label ~bind:status ()"),
        # The `:` after a labelled argument is what keeps the sugar out:
        # `~bind_field:element` spells the same words and must not match.
        ("the element/field bind family", "line",
         r"(?<![A-Za-z_])bind_(text|checked|value|source)_(element|field)[\s(]",
         "bind_text_element row;",
         "let row = label ~bind_field:element () in"),
        # OCaml moved its template prop writes into Tpl.Floor
        # (docs/tpl-props-plan.md F3), so ONE module-path pattern covers
        # every floor function, including ones added later.
        ("the template floor module", "line",
         r"(?<![A-Za-z_.])Floor\.",
         "Tpl.(Floor.set_text row \"hi\")",
         "let row = label ~bind_field:element () in"),
        # A For whose result is dropped is what `each` is.
        ("a For whose result it drops", "line",
         r"^[\s]*let [a-z_]+, \(\) =",
         "       let todo_list, () =",
         "       let todo_list, items ="),
    ],
    ".py": [
        ("widget-kind construction", "line", r"_widget\(wire\.KIND_",
         "handle = _widget(wire.KIND_ENTRY)",
         "field = kaya.entry(on_change=fn)"),
        ("the add_child chain", "line", r"\.add_child\(",
         "column.add_child(field)",
         "with kaya.column():"),
        ("bind_element by index", "line", r"\.bind_element\(",
         "label.bind_element(0)",
         "kaya.label(bind=el.title)"),
    ],
    # JS (2026-09-01): the binding exports its wire tier (`kaya.wire`)
    # for the record packers and constants, and the Widget class for
    # typing — a guest that packs a record itself, submits bytes
    # itself, or mints a Widget is at the floor.
    ".ts": [
        ("a wire record packed by hand", "line", r"\bwire\.tx_[a-z_]+\(",
         "kaya.wire.tx_add_child(column.id, field.id);",
         "kaya.column(() => { kaya.label(s); });"),
        ("a submit around the sugar", "line", r"\b(runtime|hooks)\.submit\(",
         "runtime.submit(records);",
         "count.set(1);"),
        ("widget-kind construction", "line", r"\bnew (kaya\.)?Widget\(",
         "const n = new kaya.Widget(7, false);",
         "const n = kaya.entry({ onChange });"),
    ],
}

# EXEMPT, EACH WITH ITS REASON — the gates.py EXCLUDED pattern. The
# anti-vacuity check below fires only when this is non-empty, so an entry
# whose path stops matching fails rather than sitting unread.
EXEMPT = {}

GENERATED_RE = re.compile(r"Code generated by|DO NOT EDIT")


def strip_comments(lines, ext):
    """Yield (lineno, code) with comments removed."""
    marker = {".go": "//", ".rs": "//", ".swift": "//", ".cs": "//",
              ".java": "//", ".hs": "--", ".py": "#", ".ts": "//"}.get(ext)
    depth = 0
    for i, line in enumerate(lines, 1):
        code = line
        if ext == ".ml":
            out, j = [], 0
            while j < len(code):
                if code.startswith("(*", j):
                    depth += 1
                    j += 2
                elif code.startswith("*)", j) and depth:
                    depth -= 1
                    j += 2
                elif depth == 0:
                    out.append(code[j])
                    j += 1
                else:
                    j += 1
            code = "".join(out)
        elif marker and marker in code:
            code = code.split(marker, 1)[0]
        yield i, code


def top_level_args(text, open_paren):
    """Count top-level arguments of the call whose '(' is at open_paren.

    Paren/bracket/brace balanced, double-quoted strings skipped. Returns
    0 for an empty argument list, None for an unterminated call (which
    is a parse artifact, never a verdict)."""
    depth, args, j, in_str = 0, 1, open_paren, False
    saw_any = False
    while j < len(text):
        c = text[j]
        if in_str:
            if c == "\\":
                j += 2
                continue
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                return args if saw_any else 0
        elif c == "," and depth == 1:
            args += 1
        elif depth == 1 and not c.isspace():
            saw_any = True
        j += 1
    return None


def sweep_text(ext, lines):
    """All floor hits in one file's lines: [(lineno, label, code)]."""
    stripped = list(strip_comments(lines, ext))
    text = "\n".join(code for _, code in stripped)
    # Map text offsets back to line numbers for the for2 rules.
    offsets, pos = [], 0
    for lineno, code in stripped:
        offsets.append((pos, lineno))
        pos += len(code) + 1
    def line_of(off):
        lo = 0
        for start, ln in offsets:
            if start > off:
                break
            lo = ln
        return lo

    hits = []
    for label, kind, pattern, _fire, _quiet in RULES.get(ext, []):
        if kind == "line":
            rx = re.compile(pattern)
            for lineno, code in stripped:
                if rx.search(code):
                    hits.append((lineno, label, code.strip()))
        else:  # for2
            rx = re.compile(pattern)
            for m in rx.finditer(text):
                open_paren = text.find("(", m.start())
                n = top_level_args(text, open_paren)
                if n is not None and n >= 2:
                    hits.append((line_of(m.start()), label,
                                 text[m.start():m.start() + 60].split("\n")[0]))
    return hits


def selftest():
    """Every rule's fire line must hit and quiet line must not, through
    the same engine as the real sweep."""
    broken = []
    for ext, rules in RULES.items():
        for label, kind, pattern, fire, quiet in rules:
            fire_hits = [h for h in sweep_text(ext, [fire]) if h[1] == label]
            quiet_hits = [h for h in sweep_text(ext, [quiet]) if h[1] == label]
            if not fire_hits:
                broken.append(f"{ext} '{label}' no longer fires on: {fire}")
            if quiet_hits:
                broken.append(f"{ext} '{label}' fires on legitimate sugar: {quiet}")
    return broken


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."

    broken = selftest()
    if broken:
        print("guest-floor: SELFTEST-BROKEN — the sweep may not print a verdict:")
        for b in broken:
            print(f"  {b}")
        return 1

    guests = os.path.join(root, "guests")
    hits, scanned, exempted = [], 0, 0
    for base, dirs, files in os.walk(guests):
        rel_base = os.path.relpath(base, root)
        # The C guests ARE the floor, on purpose (invariant 5).
        if rel_base == "guests/c" or rel_base.startswith("guests/c" + os.sep):
            continue
        # guests/js/node_modules/kaya-gui is the workspace LINK to the
        # binding, whose index.ts packs every record — not a guest.
        dirs[:] = [d for d in dirs if d != "node_modules"]
        for fn in sorted(files):
            ext = os.path.splitext(fn)[1]
            if ext not in RULES:
                continue
            path = os.path.join(base, fn)
            rel = os.path.relpath(path, root)
            try:
                lines = open(path, encoding="utf-8", errors="ignore").read().splitlines()
            except OSError:
                continue
            # Generated files are exempt by their own marker.
            if any(GENERATED_RE.search(l) for l in lines[:5]):
                continue
            scanned += 1
            for lineno, label, code in sweep_text(ext, lines):
                if rel in EXEMPT:
                    exempted += 1
                    continue
                hits.append((rel, lineno, label, code))

    # ANTI-VACUITY, both halves: a sweep that reads no files agrees with
    # everything, and an exemption table whose paths have moved exempts
    # nothing and would never be noticed.
    if scanned < 40:
        print(
            f"guest-floor: scanned only {scanned} guest files — this sweep has "
            "stopped finding the guests it exists to read and can no longer fail."
        )
        return 1
    if EXEMPT and exempted == 0:
        print(
            f"guest-floor: the exemption table has {len(EXEMPT)} entries and "
            "matched nothing. Either those files were fixed (delete the entries) "
            "or they moved and the table exempts nothing."
        )
        return 1

    for rel, lineno, label, code in sorted(hits):
        print(
            f"guest-floor: {rel}:{lineno} spells {label} at the floor — "
            f"`{code[:70]}`. The sugar tier covers this (invariant 5 keeps the "
            "explicit floor in the C guests, where it is the documentation); "
            "use the sugar, or add the file to EXEMPT in tools/guest-floor.py "
            "WITH THE REASON."
        )
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
