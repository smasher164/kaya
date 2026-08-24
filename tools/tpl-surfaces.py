#!/usr/bin/env python3
"""The TEMPLATE-zone census: every widget kind AND every prop, every binding.

WHY THIS IS PYTHON AND NOT SEVEN MORE GREPS IN THE GATE. Three bindings
namespace the template zone by SCOPE rather than by name — Rust's `Tpl`
methods are `pub fn entry` exactly like `Tx`'s, OCaml's live in
`module Tpl = struct` — so a line-oriented pattern is satisfied by the
LIVE constructor and reports a zone it never read. That has already been
measured passing with the template setter deleted (2026-08-10). Each
zone is therefore located by its real structure and read from inside it,
and every reader is WATCHED: too few names is a broken reader, not a
clean tree.

Usage:
    tpl-surfaces.py [--kinds a,b,c] [<repo root>]
Exit 0 when every zone offers every kind and every prop and every façade
is level with its zone; 1 with a message naming the binding, the zone and
what is missing when one is not.
"""

import glob
import re
import sys

ROOT = "."

# The 14 widget kinds; the gate passes them in from the GENERATED wire
# file, so this fallback tracks the spec by construction, not by memory.
DEFAULT_KINDS = (
    "column button label entry row checkbox slider image "
    "scroll progress select radio grid textarea"
).split()

# Constructors that are plumbing rather than sugar. Named here so that
# adding a plumbing method cannot quietly widen the Rust surface rule.
NOT_FORWARDED = {
    "widget", "set", "bind", "bind_element", "bind_field", "add_child",
    "case_arm", "collection", "for_each", "for_each_sum", "when",
    # context_menu is NOT here, deliberately: a row trace legitimately
    # anchors one, so both surfaces must offer it. context_attach — the
    # raw item-id/node floor — stays.
    "context_attach",
}


def read(path):
    with open(f"{ROOT}/{path}", encoding="utf-8") as f:
        return f.read()


def brace_block(src, header_re, open_ch="{", close_ch="}"):
    """The body of the first block whose header matches, brace-matched."""
    m = re.search(header_re, src, re.M)
    if not m:
        return None
    i = src.find(open_ch, m.start())
    if i < 0:
        return None
    depth = 0
    for j in range(i, len(src)):
        if src[j] == open_ch:
            depth += 1
        elif src[j] == close_ch:
            depth -= 1
            if depth == 0:
                return src[i:j + 1]
    return None


def python_class_block(src, name):
    """One top-level Python class, through the next top-level class."""
    start = re.search(
        rf"^class\s+{re.escape(name)}(?:\([^\n]*\))?:\s*$", src, re.M
    )
    if not start:
        return None
    following = re.search(r"^class\s+", src[start.end():], re.M)
    end = len(src) if not following else start.end() + following.start()
    return src[start.start():end]


def keyword_block(src, start_re, end_re):
    """The body between a start line and its matching end line.

    OCaml's `module Tpl = struct ... end` has no braces, and `end` also
    ends the nested `for_each`/`when_` bodies — so the openers are
    tracked rather than stopping at the first `end`.
    """
    m = re.search(start_re, src, re.M)
    if not m:
        return None
    depth = 0
    out = []
    for line in src[m.start():].splitlines(keepends=True):
        out.append(line)
        depth += len(re.findall(r"\b(?:struct|sig|begin)\b", line))
        depth -= len(re.findall(r"\bend\b", line))
        if depth == 0 and len(out) > 1:
            return "".join(out)
    return None


# --- one reader per binding -------------------------------------------
#
# Each returns the set of widget-kind constructor names its template zone
# offers, in that language's own convention; compared case-normalised.

def zone_rust(_):
    body = brace_block(read("crates/kaya/src/app.rs"), r"^impl Tpl<'_, '_> \{")
    if body is None:
        return None
    return set(re.findall(r"^\s{4}pub fn ([a-z_0-9]+)", body, re.M))


def zone_go(_):
    # DIGITS AND GENERICS BOTH COUNT: `SetA11yID` has a digit in the name
    # and `BindA11yID[` a type parameter before its arguments.
    src = read("bindings/go/app.go")
    return {
        m.lower()
        for m in re.findall(r"^func \(t \*Tpl\) ([A-Z][A-Za-z0-9]*)\s*[\(\[]", src, re.M)
    }


def zone_csharp(_):
    body = brace_block(read("bindings/csharp/KayaApp.cs"), r"^\s*(public |internal )?sealed class Tpl\b")
    if body is None:
        return None
    return {m.lower() for m in re.findall(r"public Node ([A-Z][A-Za-z]*)\(", body)}


def zone_java(_):
    body = brace_block(read("bindings/java/dev/kaya/KayaApp.java"),
                       r"^\s*public final class Tpl\b")
    if body is None:
        return None
    return {m.lower() for m in re.findall(r"public Node ([a-z][A-Za-z]*)\(", body)}


def zone_swift(_):
    body = brace_block(read("bindings/swift/KayaApp.swift"), r"^final class KayaTpl\b")
    if body is None:
        return None
    return {m.lower() for m in re.findall(r"func ([a-z][A-Za-z]*)\([^)]*\)[^{]*-> KayaNodeHandle", body)}


def zone_ocaml(_):
    body = keyword_block(read("bindings/ocaml/kaya_app.ml"), r"^module Tpl = struct\b", r"^end")
    if body is None:
        return None
    return set(re.findall(r"^  let ([a-z_0-9]+)", body, re.M))


def zone_haskell(_):
    # Haskell has no module scope here: the zone is the RETURN TYPE.
    src = read("bindings/haskell/KayaApp.hs")
    return {m.lower() for m in re.findall(r"^([a-z][A-Za-z0-9]*) ::[^\n]*-> Tpl Node", src, re.M)}


# Python is EXEMPT from this census, on the record: its transaction is
# ambient, so ONE module-level surface serves both zones (`_tpl_depth`
# flips the allocator between Widget and Node) and there is no second
# surface for a kind to be missing from. C is exempt with the rest of C:
# the generated kaya_tx_create_widget IS its surface (invariant 5).
ZONES = [
    # (language, reader, zone description for the message, minimum
    #  constructors the reader must find before its verdict is believed)
    ("rust", zone_rust, "impl Tpl (crates/kaya/src/app.rs)", 10),
    ("go", zone_go, "func (t *Tpl) (bindings/go/app.go)", 4),
    ("csharp", zone_csharp, "sealed class Tpl (bindings/csharp/KayaApp.cs)", 4),
    ("java", zone_java, "class Tpl (bindings/java/dev/kaya/KayaApp.java)", 4),
    ("swift", zone_swift, "final class KayaTpl (bindings/swift/KayaApp.swift)", 4),
    ("ocaml", zone_ocaml, "module Tpl (bindings/ocaml/kaya_app.ml)", 4),
    ("haskell", zone_haskell, "-> Tpl Node (bindings/haskell/KayaApp.hs)", 3),
]


# --- the PROP census ---------------------------------------------------
#
# The zone's PROPS and the member each is spelled as INSIDE the zone.
# `set_grow`, `setGrow` and `SetGrow` each name two different surfaces in
# the same file, so every name is read out of the zone's own block.
# The seven: grow (the layout prop scroll forced), the a11y trio and
# accepts (docs/tpl-props-plan.md P1/P2), role and inset
# (docs/styling-plan.md D3/D4).
TPL_PROPS = ["grow", "a11y_id", "a11y_label", "a11y_hint", "accepts", "role", "inset"]

# Rust's `grow` is the generic floor `set(node, prop, value)` and not a
# named setter, so that one row cannot tell grow from any other generic
# write. The named rows can.
PROP_MEMBERS = {
    "rust": {
        "grow": "set", "a11y_id": "a11y_id", "a11y_label": "a11y_label",
        "a11y_hint": "a11y_hint", "accepts": "accepts", "role": "role",
        "inset": "inset",
    },
    "go": {
        "grow": "SetGrow", "a11y_id": "SetA11yID", "a11y_label": "SetA11yLabel",
        "a11y_hint": "SetA11yHint", "accepts": "SetAccepts", "role": "SetRole",
        "inset": "SetInset",
    },
    "csharp": {
        "grow": "SetGrow", "a11y_id": "SetA11yId", "a11y_label": "SetA11yLabel",
        "a11y_hint": "SetA11yHint", "accepts": "SetAccepts", "role": "SetRole",
        "inset": "SetInset",
    },
    "java": {
        "grow": "setGrow", "a11y_id": "setA11yId", "a11y_label": "setA11yLabel",
        "a11y_hint": "setA11yHint", "accepts": "setAccepts", "role": "setRole",
        "inset": "setInset",
    },
    "swift": {
        "grow": "setGrow", "a11y_id": "setA11yId", "a11y_label": "setA11yLabel",
        "a11y_hint": "setA11yHint", "accepts": "setAccepts", "role": "setRole",
        "inset": "setInset",
    },
    "ocaml": {
        "grow": "set_grow", "a11y_id": "set_a11y_id", "a11y_label": "set_a11y_label",
        "a11y_hint": "set_a11y_hint", "accepts": "set_accepts", "role": "set_role",
        "inset": "set_inset",
    },
    # Haskell's template props are not methods but CONSTRUCTORS of the
    # `TplAttr` GADT, applied by `applyTplAttr`.
    "haskell": {
        "grow": "TplGrow", "a11y_id": "TplA11yId", "a11y_label": "TplA11yLabel",
        "a11y_hint": "TplA11yHint", "accepts": "TplAccepts", "role": "TplRole",
        "inset": "TplInset",
    },
}


def members_rust(_):
    body = brace_block(read("crates/kaya/src/app.rs"), r"^impl Tpl<'_, '_> \{")
    return None if body is None else set(re.findall(r"^\s{4}pub fn ([a-z_0-9]+)", body, re.M))


def members_go(_):
    src = read("bindings/go/app.go")
    return set(re.findall(r"^func \(t \*Tpl\) ([A-Za-z][A-Za-z0-9]*)\s*[\(\[]", src, re.M))


def members_csharp(_):
    body = brace_block(read("bindings/csharp/KayaApp.cs"),
                       r"^\s*(public |internal )?sealed class Tpl\b")
    return None if body is None else set(
        re.findall(r"^\s*public\s+(?:void|Node)\s+([A-Za-z][A-Za-z0-9]*)\s*\(", body, re.M))


def members_java(_):
    body = brace_block(read("bindings/java/dev/kaya/KayaApp.java"),
                       r"^\s*public final class Tpl\b")
    return None if body is None else set(
        re.findall(r"^\s*public\s+(?:void|Node)\s+([a-zA-Z][A-Za-z0-9]*)\s*\(", body, re.M))


def members_swift(_):
    body = brace_block(read("bindings/swift/KayaApp.swift"), r"^final class KayaTpl\b")
    return None if body is None else set(
        re.findall(r"^\s*func ([a-zA-Z][A-Za-z0-9]*)\s*\(", body, re.M))


def members_ocaml(_):
    # ANY indent inside the zone, not the two the constructor reader
    # wants: OCaml's template SETTERS sit one nesting deeper.
    body = keyword_block(read("bindings/ocaml/kaya_app.ml"), r"^module Tpl = struct\b", r"^end")
    return None if body is None else set(re.findall(r"^\s+let ([a-z_0-9']+)", body, re.M))


def members_haskell(_):
    src = read("bindings/haskell/KayaApp.hs")
    return set(re.findall(r"^\s*(Tpl[A-Za-z0-9]*)\s*::", src, re.M))


# (language, reader, where, minimum members before the verdict is believed)
PROP_ZONES = [
    ("rust", members_rust, "impl Tpl (crates/kaya/src/app.rs)", 10),
    ("go", members_go, "func (t *Tpl) (bindings/go/app.go)", 10),
    ("csharp", members_csharp, "sealed class Tpl (bindings/csharp/KayaApp.cs)", 10),
    ("java", members_java, "class Tpl (bindings/java/dev/kaya/KayaApp.java)", 10),
    ("swift", members_swift, "final class KayaTpl (bindings/swift/KayaApp.swift)", 10),
    ("ocaml", members_ocaml, "module Tpl (bindings/ocaml/kaya_app.ml)", 10),
    ("haskell", members_haskell, "data TplAttr (bindings/haskell/KayaApp.hs)", 3),
]


# A table is a For surface rather than a widget kind. Read the nested
# builder and its keyed re-declaration from their own blocks so the live
# Tx/Messages methods cannot satisfy them (docs/tables-plan.md).
TABLE_POINTS = {
    "rust": ("columns", "on_sort", "keyed re-declaration"),
    "python": (
        "columns",
        "on_sort",
        "keyed re-declaration",
        "ordinary For grow",
        "ordinary For align",
        "ordinary For a11y id",
    ),
}


def table_rust(_):
    src = read("crates/kaya/src/app.rs")
    rows = brace_block(
        src, r"^impl<I:\s*for_scope::Id>\s+Rows<'_,\s*'_,\s*I>\s*\{"
    )
    nested = brace_block(
        src, r"^impl\s+Rows<'_,\s*'_,\s*TemplateNodeId>\s*\{"
    )
    tx = brace_block(src, r"^impl<'a>\s+Tx<'a>\s*\{")
    messages = brace_block(src, r"^impl<M>\s+Messages<M>\s*\{")
    if None in (rows, nested, tx, messages):
        return None

    got = set()
    if re.search(r"^\s{4}pub fn columns\s*\(", rows, re.M):
        got.add("columns")
    nested_sort = re.search(
        r"^\s{4}pub fn on_sort<M>\s*\(.*?Fn\(Path,\s*u32\).*?"
        r"msgs\.on_sort_node\(self\.id\(\),\s*f\)",
        nested,
        re.M | re.S,
    )
    node_sort = re.search(
        r"^\s{4}pub fn on_sort_node\s*\(.*?Fn\(Path,\s*u32\).*?"
        r"self\.nodes\.borrow_mut\(\)\.insert",
        messages,
        re.M | re.S,
    )
    if nested_sort and node_sort:
        got.add("on_sort")
    node_id = re.search(
        r"^\s{4}pub fn id\(&self\)\s*->\s*TemplateNodeId", nested, re.M
    )
    keyed = re.search(
        r"^\s{4}pub fn columns_at\s*\(.*?node:\s*TemplateNodeId.*?"
        r"path:\s*&Path",
        tx,
        re.M | re.S,
    )
    if node_id and keyed:
        got.add("keyed re-declaration")
    return got


def table_python(_):
    src = read("bindings/python/kaya/__init__.py")
    bound = python_class_block(src, "_BoundCollection")
    collection = python_class_block(src, "Collection")
    for_trace = python_class_block(src, "_ForTrace")
    trace = python_class_block(src, "_ColumnsTrace")
    if None in (bound, collection, for_trace, trace):
        return None

    got = set()
    columns = re.search(
        r"^\s{4}def columns\([^\n]*\bon_sort=None[^\n]*\):.*?"
        r"return _ColumnsTrace\(self,.*?\bon_sort\b",
        collection,
        re.M | re.S,
    )
    header = re.search(
        r"wire\.tx_set_column_headers\(\s*handle\.id,.*?"
        r"len\(self\._titles\),\s*0,\s*self\._titles",
        trace,
        re.S,
    )
    if columns and header:
        got.add("columns")

    registration = re.search(
        r"_app\._register\(handle,\s*wire\.OCC_SORT_REQUESTED,\s*self\._on_sort\)",
        trace,
        re.S,
    )
    if columns and registration:
        got.add("on_sort")

    rows = re.search(
        r"^\s{4}def rows\((.*?)\):\n(.*?)(?=^\s{4}def |\Z)",
        collection,
        re.M | re.S,
    )
    if rows:
        args, body = rows.groups()
        row_points = (
            (
                "ordinary For grow", "grow", "_grow",
                r"wire\.tx_set_grow\(self\._template\.handle\.id,\s*float\(self\._grow\)\)",
            ),
            (
                "ordinary For align", "align", "_align",
                r"wire\.tx_set_align\(self\._template\.handle\.id,\s*"
                r"_align_value\(self\._align\)\)",
            ),
            (
                "ordinary For a11y id", "a11y_id", "_a11y_id",
                r"wire\.tx_set_a11y_id\(self\._template\.handle\.id,\s*self\._a11y_id\)",
            ),
        )
        for point, arg, field, emitter in row_points:
            handed_off = f"{arg}=None" in args and f"trace.{field} = {arg}" in body
            emitted = re.search(
                rf"if self\.{field} is not None:.*?{emitter}",
                for_trace,
                re.S,
            )
            if handed_off and emitted:
                got.add(point)

    setter = re.search(
        r"^\s{4}def set_columns\(.*?(?=^\s{4}def |\Z)",
        bound,
        re.M | re.S,
    )
    if (
        setter
        and 'getattr(self._owner, "_for_handle", None)' in setter.group(0)
        and "len(self._path)" in setter.group(0)
        and "[*self._path, *titles]" in setter.group(0)
    ):
        got.add("keyed re-declaration")
    return got


TABLE_ZONES = [
    ("rust", table_rust, "typed Rows + Tx::columns_at (crates/kaya/src/app.rs)"),
    (
        "python",
        table_python,
        "Collection/_ColumnsTrace/_BoundCollection (bindings/python/kaya/__init__.py)",
    ),
]
# docs/deferred.md's dynamic-tables entry keeps Go, C#, Java, Swift,
# OCaml and Haskell open; each joins this depth census with its spelling.


# --- the TAKES-A-SOURCE census -----------------------------------------
#
# A constructor that EXISTS is not one that can be handed the row's own
# data (docs/deferred.md, "the template button's caption is not
# uniform"). WHAT IS ASKED IS A PAIR: each point must accept BOTH a
# SIGNAL and an ELEMENT FIELD. The signal arm alone proves nothing —
# every LIVE constructor takes a signal too — while the field arm is
# what only a template can spell, one caption per stamped copy. So the
# two are reported by name, never summed.
#
# PYTHON IS IN THIS CENSUS though it is exempt from both above, and the
# difference is the point: a source is not a kind, and Python was the one
# binding that could not spell the caption at all.
#
# Each reader returns the flavours the point accepts, or None when it
# cannot LOCATE the constructor — refused as a broken reader, never
# reported as a binding with no sources.
SOURCE_FLAVOURS = ("signal", "field")

# The points, one per (kind, prop) that must be sourceable in the zone.
# One today; the table is the shape a second one lands in.
SOURCE_POINTS = ("button caption",)


def sources_rust(_):
    src = read("crates/kaya/src/app.rs")
    body = brace_block(src, r"^impl Tpl<'_, '_> \{")
    if body is None:
        return None
    m = re.search(r"^\s{4}pub fn button\(([^)]*)\)", body, re.M)
    if m is None or "TplSource<StrKind>" not in m.group(1):
        return set() if m else None
    # The source-ness is the TYPE's, not the signature's: one `impl
    # Into<TplSource<StrKind>>` argument is both arms or neither, so the
    # flavours are read where the conversions are declared.
    got = set()
    if re.search(r"^impl<K> From<SignalId> for TplSource<K>", src, re.M):
        got.add("signal")
    if re.search(r"^impl<K> From<Field<K>> for TplSource<K>", src, re.M):
        got.add("field")
    return got


def sources_go(_):
    # The zone is the RECEIVER here, so the file is the block. Only the
    # HEADERS are read: a body mentioning Signal would otherwise answer
    # for a signature that does not take one.
    src = read("bindings/go/app.go")
    heads = re.findall(r"func \(t \*Tpl\) Button[A-Za-z0-9]*(.*?)\) Node \{", src, re.S)
    if not heads:
        return None
    joined = "".join(heads)
    got = set()
    if "Signal[string]" in joined:
        got.add("signal")
    if "Field[string]" in joined:
        got.add("field")
    return got


def _overload_params(body, pattern):
    """The parameter lists of every overload matching `pattern`."""
    return re.findall(pattern, body, re.M)


def sources_csharp(_):
    body = brace_block(read("bindings/csharp/KayaApp.cs"),
                       r"^\s*(public |internal )?sealed class Tpl\b")
    if body is None:
        return None
    pars = _overload_params(body, r"^\s*public Node Button\(([^)]*)\)")
    if not pars:
        return None
    got = set()
    for p in pars:
        if re.search(r"\bSignal\b", p):
            got.add("signal")
        if re.search(r"\bField<string>", p):
            got.add("field")
    return got


def sources_java(_):
    body = brace_block(read("bindings/java/dev/kaya/KayaApp.java"),
                       r"^\s*public final class Tpl\b")
    if body is None:
        return None
    pars = _overload_params(body, r"^\s*public Node button\(([^)]*)\)")
    if not pars:
        return None
    got = set()
    for p in pars:
        if re.search(r"\bSignal<String>", p):
            got.add("signal")
        if re.search(r"\bField<String>", p):
            got.add("field")
    return got


def sources_swift(_):
    body = brace_block(read("bindings/swift/KayaApp.swift"), r"^final class KayaTpl\b")
    if body is None:
        return None
    pars = _overload_params(body, r"^\s*func button\(([^)]*)\)\s*->\s*KayaNodeHandle")
    if not pars:
        return None
    got = set()
    for p in pars:
        if re.search(r"\bKayaSignal\b", p):
            got.add("signal")
        if re.search(r"\bKayaField<String>", p):
            got.add("field")
    return got


def sources_ocaml(_):
    body = keyword_block(read("bindings/ocaml/kaya_app.ml"), r"^module Tpl = struct\b", r"^end")
    if body is None:
        return None
    # One `let button`; the header runs to the `=` that opens the body.
    m = re.search(r"^  let button\b(.*?)=\n", body, re.S | re.M)
    if m is None:
        return None
    head = m.group(1)
    got = set()
    # `?bind` is a PREFIX of `?bind_field`, so the signal arm is matched
    # only where no further name follows.
    if re.search(r"\?bind(?![_a-z])", head):
        got.add("signal")
    if re.search(r"\?bind_field\b", head):
        got.add("field")
    return got


def sources_haskell(_):
    # The zone is the RETURN TYPE and the sources are the CLASS. Both
    # halves are read: a constraint over a class with no Signal instance
    # would be a source in name only.
    src = read("bindings/haskell/KayaApp.hs")
    m = re.search(r"^buttonBound :: (\w+) s => s -> Tpl Node$", src, re.M)
    if m is None:
        return None
    cls = m.group(1)
    got = set()
    if re.search(rf"^instance {cls} Signal\b", src, re.M):
        got.add("signal")
    if re.search(rf"^instance {cls} \(KField String\)", src, re.M):
        got.add("field")
    return got


def sources_python(_):
    # ONE surface, both zones, so the "zone" here is the constructor
    # itself. Signature AND body: a `bind=` that never reaches the
    # element encoder is the silent-nothing arm this binding has already
    # shipped once.
    src = read("bindings/python/kaya/__init__.py")
    m = re.search(r"^def button\(([^)]*)\):\n(.*?)(?=^def )", src, re.S | re.M)
    if m is None:
        return None
    params, body = m.group(1), m.group(2)
    if not re.search(r"\bbind=", params):
        return set()
    got = set()
    if "wire.tx_bind_text(" in body:
        got.add("signal")
    if "wire.tx_bind_text_element(" in body:
        got.add("field")
    return got


# (language, reader, where the point is spelled, how it is spelled)
SOURCE_ZONES = [
    ("rust", sources_rust, "impl Tpl (crates/kaya/src/app.rs)",
     "`button(impl Into<TplSource<StrKind>>)`"),
    ("go", sources_go, "func (t *Tpl) Button* (bindings/go/app.go)",
     "a `ButtonBound` over Signal[string] | Field[string]"),
    ("csharp", sources_csharp, "sealed class Tpl (bindings/csharp/KayaApp.cs)",
     "`Button(Signal)` / `Button(Field<string>)` overloads"),
    ("java", sources_java, "class Tpl (bindings/java/dev/kaya/KayaApp.java)",
     "`button(Signal<String>)` / `button(Field<String>)` overloads"),
    ("swift", sources_swift, "final class KayaTpl (bindings/swift/KayaApp.swift)",
     "`button(KayaSignal)` / `button(KayaField<String>)` overloads"),
    ("ocaml", sources_ocaml, "module Tpl (bindings/ocaml/kaya_app.ml)",
     "`?bind` / `?bind_field` on `let button`"),
    ("haskell", sources_haskell, "buttonBound (bindings/haskell/KayaApp.hs)",
     "instances of the constructor's own source class"),
    ("python", sources_python, "def button (bindings/python/kaya/__init__.py)",
     "`bind=` taking a Signal or an element field"),
]


# --- the FAÇADES, held level with the zone they forward to -------------
#
# A template zone can have a SECOND surface: a for-statement façade that
# forwards the zone's methods one at a time, by hand. A member on the
# zone and not on its façade is reachable through `for_each` and not
# through `for row in rows`, a difference no guest should have to know.
#
# Each façade carries its OWN NOT_FORWARDED set, because each binding
# drew the plumbing line in its own place; reading each one's own list is
# measuring, one shared list would be legislating.
#
# Java's four: `widget` is the kind floor and its absence is load-bearing
# (it keeps a for-statement guest off the tier invariant 5 excludes);
# `addChild` is the parenting floor; `onToggleNode` is the bridge the
# generated typed sugar reaches through `tpl()`; `forEach` is compensated
# by `collection()`, which IS forwarded.
NOT_FORWARDED_JAVA = {
    "widget", "addChild", "onToggleNode", "forEach",
}

# C#'s façade documents its own exclusions in its generated header
# (guests/csharp/*Kaya.cs). ContextMenu is on this list and off Rust's —
# a real divergence between two façades over one zone, recorded and
# ledgered rather than silently blessed.
NOT_FORWARDED_CSHARP = {
    "Widget", "AddChild", "Collection", "ForEach", "Each", "When", "ContextMenu",
    "BindTextElement", "BindTextField", "BindCheckedField", "BindValueField",
    "BindSourceField",
}


# A NAME SET CANNOT SEE AN OVERLOAD. `Button` cancels against `Button`,
# so a façade forwarding one of the zone's three Button overloads reads
# level — measured, and it is what let C#'s generated row façade lag the
# template button's caption arms for a milestone (docs/deferred.md).
# The C-family façades are therefore keyed by ARITY AND TYPE, with the
# same splitter the source census's `_overload_params` reads for.
#
# Rust's `Row` is still keyed by NAME: `pub fn` has no overloads to lose,
# so the shape this exists to catch cannot occur there.


def _split_params(params):
    """One parameter list into its parameters, generics kept whole."""
    out, depth, cur = [], 0, ""
    for ch in params:
        if ch == "<":
            depth += 1
        elif ch == ">":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return [p.strip() for p in out]


def _param_type(param):
    """A parameter's TYPE, spelled the same on both sides of a forward.

    Drops the default, the namespace the two sides spell differently
    (`System.Action` against `Action`), and the parameter NAME, which a
    forward is free to rename and routinely does."""
    p = " ".join(param.split()).split("=")[0].strip()
    p = re.sub(r"\b(?:System\.Collections\.Generic|System|java\.util\.function"
               r"|java\.util)\.", "", p)
    toks = p.split()
    if len(toks) > 1 and re.fullmatch(r"[A-Za-z_]\w*", toks[-1]):
        toks = toks[:-1]
    return re.sub(r"\s+", "", " ".join(toks))


def _typed_members(body, pattern):
    """`{(name, (type, …))}` for every method the pattern matches."""
    return {(name, tuple(_param_type(p) for p in _split_params(params)))
            for name, params in re.findall(pattern, body, re.S | re.M)}


def show_member(member):
    """A (name, types) pair as the reader would write it."""
    if isinstance(member, tuple) and len(member) == 2 and isinstance(member[1], tuple):
        return f"{member[0]}({', '.join(member[1])})"
    return str(member)


def facade_rust():
    src = read("crates/kaya/src/app.rs")
    tpl = brace_block(src, r"^impl Tpl<'_, '_> \{")
    row = brace_block(src, r"^impl<'b> Row<'_, 'b> \{")
    if tpl is None or row is None:
        return None
    pat = r"^\s{4}pub fn ([a-z_0-9]+)"
    return [(
        "Rust's `Row` (the `for row in rows` façade, crates/kaya/src/app.rs)",
        set(re.findall(pat, tpl, re.M)) - NOT_FORWARDED,
        set(re.findall(pat, row, re.M)) - NOT_FORWARDED,
        "impl Row",
    )]


def facade_java():
    src = read("bindings/java/dev/kaya/KayaApp.java")
    tpl = brace_block(src, r"^\s*public final class Tpl\b")
    row = brace_block(src, r"^\s*public abstract static class RowSurface\b")
    if tpl is None or row is None:
        return None
    pat = r"^\s*public\s+(?:void|Node)\s+([a-zA-Z][A-Za-z0-9]*)\s*\(([^)]*)\)"
    zone = {m for m in _typed_members(tpl, pat) if m[0] not in NOT_FORWARDED_JAVA}
    facade = {m for m in _typed_members(row, pat) if m[0] not in NOT_FORWARDED_JAVA}
    return [(
        "Java's `RowSurface` (the `for (var row : ...)` façade, "
        "bindings/java/dev/kaya/KayaApp.java)",
        zone,
        facade,
        "class RowSurface",
    )]


def facade_csharp():
    """Every GENERATED `<Rec>Row` in the guest tree, against `Tpl`.

    ALL of them, not one: a generator taught the forward emits it into
    every file at once, so a single laggard means someone hand-edited a
    generated file. tools/kaya-csgen is what gets fixed when this fires.
    """
    tpl = brace_block(read("bindings/csharp/KayaApp.cs"),
                      r"^\s*(public |internal )?sealed class Tpl\b")
    if tpl is None:
        return None
    pat = r"^\s*public\s+(?:void|Node)\s+([A-Za-z][A-Za-z0-9]*)\s*\(([^)]*)\)"
    zone = {m for m in _typed_members(tpl, pat) if m[0] not in NOT_FORWARDED_CSHARP}
    out = []
    for path in sorted(glob.glob(f"{ROOT}/guests/csharp/*Kaya.cs")):
        src = open(path, encoding="utf-8").read()
        for m in re.finditer(r"^sealed class (\w+Row)\b", src, re.M):
            body = brace_block(src, rf"^sealed class {m.group(1)}\b")
            if body is None:
                continue
            rel = path[len(ROOT) + 1:] if path.startswith(ROOT + "/") else path
            out.append((
                f"C#'s generated `{m.group(1)}` façade ({rel})",
                zone,
                {x for x in _typed_members(body, pat)
                 if x[0] not in NOT_FORWARDED_CSHARP},
                f"tools/kaya-csgen (the generator that emits {m.group(1)})",
            ))
    if not out:
        # NOT a pass: finding no generated façade means the reader has
        # stopped seeing them.
        return None
    return out


# THE FAÇADES THAT ARE NOT HERE, on the record rather than merely absent
# (gates.sh's EXCLUDED rule, one file over):
#
#   go — `type Row struct{ *Tpl }` EMBEDS the zone, so the pair cannot
#     drift. Its two sealed surfaces are checked by
#     bindings/go/tplzone_test.go.
#   swift — `struct <Rec>Row` (tools/kaya-swift-gen) forwards no prop
#     setter, and its `t: KayaTpl` is PUBLIC, so the zone is reachable
#     anyway. Levelling it is ledgered as a slice of its own.
FACADES = [
    ("rust", facade_rust),
    ("java", facade_java),
    ("csharp", facade_csharp),
]


def offers(names, kind):
    """Does this zone offer a constructor for `kind`?

    Prefix-loose as check-sugar-surface's live sweep is: `entryBound` and
    `entry_bound` are both `entry`.
    """
    return any(n == kind or n.startswith(kind) for n in names)


def main():
    global ROOT
    kinds = DEFAULT_KINDS
    args = [a for a in sys.argv[1:]]
    if args and args[0] == "--kinds":
        kinds = args[1].split(",")
        args = args[2:]
    if args:
        ROOT = args[0]

    status = 0
    for lang, reader, where, minimum in ZONES:
        try:
            names = reader(None)
        except OSError as e:
            print(f"tpl-surfaces: cannot read {lang}'s binding ({e})")
            status = 1
            continue

        if names is None:
            print(
                f"tpl-surfaces: cannot find {lang}'s template zone — {where}. "
                "This census locates each zone by its real structure, so a "
                "renamed or reshaped zone means the reader is wrong, not that "
                "the zone is empty. Fix the reader here rather than deleting it."
            )
            status = 1
            continue

        # THE READER IS WATCHED: a census that reads nothing agrees with
        # everything.
        if len(names) < minimum:
            print(
                f"tpl-surfaces: {lang}'s zone reader found only {len(names)} "
                f"constructors in {where}, fewer than the {minimum} that zone "
                "is known to have — the reader has stopped seeing the surface "
                "it exists to census and can no longer fail. Found: "
                + (", ".join(sorted(names)) or "nothing")
            )
            status = 1
            continue

        missing = [k for k in kinds if not offers(names, k)]
        if missing:
            print(
                f"check-sugar-surface: {lang} has no TEMPLATE-zone constructor "
                f"for {', '.join(missing)} — in {where}. A collection row can "
                "only build those through the widget-kind floor, which is the C "
                "guests' tier, not an app's (invariant 5). The LIVE zone's "
                "constructor of the same name does not count: they are "
                "different surfaces handing out different handles."
            )
            status = 1

    # THE PROP CENSUS. Same zones, read for what a stamped copy can be
    # TOLD rather than for what it can be MADE.
    for lang, reader, where, minimum in PROP_ZONES:
        try:
            names = reader(None)
        except OSError as e:
            print(f"tpl-surfaces: cannot read {lang}'s binding for the prop census ({e})")
            status = 1
            continue

        if names is None:
            print(
                f"tpl-surfaces: cannot find {lang}'s template zone for the prop "
                f"census — {where}. Fix the reader here rather than deleting it."
            )
            status = 1
            continue

        if len(names) < minimum:
            print(
                f"tpl-surfaces: {lang}'s prop reader found only {len(names)} members "
                f"in {where}, fewer than the {minimum} that zone is known to have — "
                "the reader has stopped seeing the surface it exists to census and "
                "can no longer fail. Found: " + (", ".join(sorted(names)) or "nothing")
            )
            status = 1
            continue

        want = PROP_MEMBERS[lang]
        missing = [p for p in TPL_PROPS if want[p] not in names]
        if missing:
            print(
                f"check-sugar-surface: {lang}'s TEMPLATE zone cannot spell "
                + ", ".join(f"{p} (wanted `{want[p]}`)" for p in missing)
                + f" — in {where}. A stamped copy is then the one widget in that "
                "language that cannot say what it means or how far it holds its "
                "children off its edge. THE LIVE ZONE'S SETTER OF THE SAME NAME "
                "DOES NOT COUNT: this census reads the zone's own block precisely "
                "because the two spell the prop identically."
            )
            status = 1

    # Tables are construction on a For, outside the kind/prop blocks.
    for lang, reader, where in TABLE_ZONES:
        try:
            got = reader(None)
        except OSError as e:
            print(f"tpl-surfaces: cannot read {lang}'s dynamic-table surface ({e})")
            status = 1
            continue

        if got is None:
            print(
                f"tpl-surfaces: cannot find {lang}'s dynamic-table zones — {where}. "
                "Fix the scoped reader rather than treating an unread surface as empty."
            )
            status = 1
            continue

        missing = [point for point in TABLE_POINTS[lang] if point not in got]
        if missing:
            print(
                f"check-sugar-surface: {lang}'s TEMPLATE-zone table cannot spell "
                + ", ".join(missing)
                + f" — in {where}. A live table method of the same name does not count."
            )
            status = 1

    # THE TAKES-A-SOURCE CENSUS. Same zones, read for whether the
    # constructor can be handed the ROW rather than whether it exists —
    # the question the kind census structurally cannot ask.
    for lang, reader, where, spelling in SOURCE_ZONES:
        try:
            got = reader(None)
        except OSError as e:
            print(f"tpl-surfaces: cannot read {lang}'s binding for the source census ({e})")
            status = 1
            continue

        if got is None:
            print(
                f"tpl-surfaces: cannot find {lang}'s template button constructor "
                f"for the source census — {where}. A reader that cannot LOCATE "
                "the point it censuses has not measured a binding with no "
                "sources; it has stopped reading. Fix the reader here rather "
                "than deleting it."
            )
            status = 1
            continue

        missing = [f for f in SOURCE_FLAVOURS if f not in got]
        if missing:
            print(
                f"check-sugar-surface: {lang}'s TEMPLATE-zone button caption "
                f"takes no {' or '.join(missing)} source — in {where}. A "
                "stamped copy's caption is then one string for every row, and "
                "\"Delete <that row's title>\" is spellable in that language "
                f"only at the zone's floor, or not at all. The spelling here is "
                f"{spelling}; the other seven bindings each have their own, and "
                "all eight take BOTH a signal and an element field. A "
                "CONSTRUCTOR THAT EXISTS IS NOT ONE THAT TAKES THE ROW: this "
                "clause is the half the kind census above cannot ask."
            )
            status = 1

    # THE FAÇADES, held level with the zone each forwards to.
    for lang, reader in FACADES:
        try:
            pairs = reader()
        except OSError as e:
            print(f"tpl-surfaces: cannot read {lang}'s façade ({e})")
            status = 1
            continue
        if pairs is None:
            print(
                f"tpl-surfaces: cannot find {lang}'s template zone and its façade to "
                "compare. A façade that cannot be located is not a façade that is "
                "level — fix the reader."
            )
            status = 1
            continue
        for where, zone, facade, fix in pairs:
            gap = sorted(zone - facade)
            if gap:
                print(
                    f"tpl-surfaces: {where} has drifted from the zone it forwards to. "
                    "It does not forward: " + ", ".join(show_member(g) for g in gap)
                    + f". Add the forward in {fix}, or add the name to this file's "
                    "NOT_FORWARDED set for that binding, with a reason."
                )
                status = 1
            wide = sorted(facade - zone)
            if wide:
                print(
                    f"tpl-surfaces: {where} offers members the zone does not: "
                    + ", ".join(show_member(w) for w in wide)
                    + " — a façade cannot be wider than the zone it forwards to."
                )
                status = 1

    return status


if __name__ == "__main__":
    sys.exit(main())
