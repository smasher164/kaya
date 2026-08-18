#!/usr/bin/env python3
"""The TEMPLATE-zone census: every widget kind AND every prop, every binding.

kaya has two construction zones. The LIVE zone is what an app builds in
its build closure; the TEMPLATE zone is the prototype inside a
collection, stamped once per row. `tools/check-sugar-surface.sh` has
always swept the live one, and until 2026-08-10 nothing swept this one —
so the surface was complete in eight languages and, in a collection row,
reachable only through `widget(kind)`, the raw floor that passes a wire
constant as a runtime value. kaya's own text editor spells its find
bar's text field that way; the undo scene does it in seven languages.

WHY THIS IS PYTHON AND NOT SEVEN MORE GREPS IN THE GATE. Three of the
bindings namespace the template zone by SCOPE rather than by name:
Rust's `Tpl` methods are `pub fn entry` exactly like `Tx`'s, OCaml's
live in `module Tpl = struct`, and a line-oriented pattern cannot tell
which block a line sits in. A regex keyed on the name alone would be
satisfied by the LIVE constructor and report a zone it never read —
which is the failure mode a gate exists to prevent, not one it may
have. So each binding's zone is located by its real structure and the
constructors are read from inside it.

Every zone reader is watched: a binding whose zone yields fewer
constructors than MIN_CTORS fails as a BROKEN READER rather than passing
quietly, because two empty sets agree perfectly and a census that reads
nothing is indistinguishable from a clean tree.

IT ALSO CENSUSES PROPS, since 2026-08-17. It did not until then, and the
gap was ledgered with three named consequences (docs/deferred.md, "sees
constructors, not props"): the props slice's surfaces were held by
check-sugar-surface's line patterns and per-binding tests instead, Go's
reader could see neither a digit in a method name (`SetA11yID`) nor a
generic one (`BindA11yID[`), and two hand-written FAÇADES — Java's
`RowSurface` and C#'s generated `<Rec>Row` — had no level-holding clause
at all, where Rust's `Row` had one. A file-scoped grep cannot replace
this for the same reason the constructor census is not one: OCaml's live
`set_grow (Widget id)` and its template `set_grow (Node id)` are the same
eleven characters, and a pattern keyed on the name has ALREADY been
measured passing with the template setter deleted (2026-08-10).

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

# The 14 widget kinds, passed in by the gate from the GENERATED wire file
# so this list tracks the spec by construction rather than by memory.
DEFAULT_KINDS = (
    "column button label entry row checkbox slider image "
    "scroll progress select radio grid textarea"
).split()

# `spacer` is sugar for an empty grown column rather than a kind, so it
# is not in the spec's list and not swept; it rides along in each
# binding because the live zone has one.

# Constructors that are plumbing rather than sugar. Named here so that
# adding a plumbing method cannot quietly widen the Rust surface rule.
NOT_FORWARDED = {
    "widget", "set", "bind", "bind_element", "bind_field", "add_child",
    "case_arm", "collection", "for_each", "for_each_sum", "when",
    # context_menu is NOT here, deliberately: a row trace legitimately
    # anchors one (the menus scene's item rows), so both surfaces must
    # offer it. context_attach — the raw item-id/node floor — stays.
    "context_attach",
}


def read(path):
    with open(f"{ROOT}/{path}", encoding="utf-8") as f:
        return f.read()


def brace_block(src, header_re, open_ch="{", close_ch="}"):
    """The body of the first block whose header matches, brace-matched.

    A regex cannot find the end of a Rust impl or a C# class: the bodies
    contain braces, strings and closures. Counting delimiters is crude,
    but it is reading the real structure instead of guessing at it.
    """
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


def keyword_block(src, start_re, end_re):
    """The body between a start line and its matching end line.

    OCaml's `module Tpl = struct ... end` has no braces. `end` also ends
    the nested `for_each`/`when_` bodies, so the reader tracks the
    struct/sig/begin openers rather than stopping at the first `end`.
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
# Each returns the set of widget-kind constructor names its template
# zone offers, spelled in that language's own convention. The gate
# compares against the kind list after normalising case.

def zone_rust(_):
    body = brace_block(read("crates/kaya/src/app.rs"), r"^impl Tpl<'_, '_> \{")
    if body is None:
        return None
    return set(re.findall(r"^\s{4}pub fn ([a-z_0-9]+)", body, re.M))


def zone_go(_):
    # DIGITS AND GENERICS BOTH COUNT. The first draft read
    # `([A-Z][A-Za-z]*)\(` and could see neither `SetA11yID` (a digit in
    # the name) nor `BindA11yID[` (a type parameter before the arguments),
    # which is why Go's half of the props slice was ledgered as unswept
    # while its pairing lived in bindings/go/tplzone_test.go instead.
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
    # Haskell has no module scope here: the template constructors are
    # distinguished by their RETURN TYPE, `Tpl Node`, which is exactly
    # as structural as a block and rather more readable.
    src = read("bindings/haskell/KayaApp.hs")
    return {m.lower() for m in re.findall(r"^([a-z][A-Za-z0-9]*) ::[^\n]*-> Tpl Node", src, re.M)}


# Python is EXEMPT, and the exemption is a fact about its design rather
# than a hole. Its transaction is ambient, so ONE module-level surface
# serves both zones: `_tpl_depth` flips the allocator between Widget and
# Node (bindings/python/kaya/__init__.py:182) and every constructor
# funnels through it. Every kind already works in a template there, and
# there is no second surface for one to be missing from — the live sweep
# in check-sugar-surface covers Python's template zone by construction.
# C is exempt with the rest of C: the generated kaya_tx_create_widget IS
# its surface, deliberately (invariant 5).
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
# The zone's PROPS, and the member each is spelled as INSIDE the zone.
# Every name below is read out of the template zone's own block, never out
# of the file: the whole reason this census is python is that a
# line-oriented pattern is satisfied by the LIVE twin, and props are where
# that bites hardest — `set_grow`, `setGrow` and `SetGrow` each name two
# different surfaces in the same file.
#
# WHY THESE SEVEN. grow is the layout prop scroll forced; the a11y trio
# and accepts are the props slice (docs/tpl-props-plan.md P1/P2); role and
# inset are the styling pair (docs/styling-plan.md D3/D4), which the live
# zone carried alone until 2026-08-17 — a stamped "Delete" button could be
# declared destructive in no language, and the editor's find bar, a
# STAMPED row, sat flush while the live status row beside it insets.
TPL_PROPS = ["grow", "a11y_id", "a11y_label", "a11y_hint", "accepts", "role", "inset"]

# Rust's `grow` is the generic floor `set(node, prop, value)` and not a
# named setter — the zone deliberately has one generic write and names
# only the props whose spelling would otherwise be a wire constant. That
# is a fact about the surface, so it is recorded here rather than hidden:
# this row cannot tell grow from any other generic write, and the named
# rows can.
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
    # `TplAttr` GADT, applied by `applyTplAttr` — which is as structural a
    # zone as a block and rather more so, since the type is the zone.
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
    # wants: OCaml's template SETTERS sit one nesting deeper than its
    # constructors (bindings/ocaml/kaya_app.ml, inside module Tpl).
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


# --- the TAKES-A-SOURCE census -----------------------------------------
#
# A constructor that EXISTS is not a constructor that can be handed the
# row's own data, and until 2026-08-18 nothing in the tree asked the
# second question. `Tpl.Button(string)` satisfied the kind census exactly
# as `Tpl.button(Signal<String>)` did, so a per-row button caption was
# sugar in five bindings, floor-only in C# and Swift, and inexpressible
# in Python — for as long as the sweep only asked whether the kind was
# there (docs/deferred.md, "the template button's caption is not
# uniform", found 2026-08-17). It is the gap-shape the ledger already
# named once for Python's `progress`: a check that asserts a constructor
# EXISTS cannot see which arm is reachable.
#
# WHAT IS ASKED IS A PAIR, not "does it take a source". Each point must
# accept BOTH a SIGNAL and an ELEMENT FIELD. The signal arm alone proves
# nothing about this zone — every LIVE constructor in the tree takes a
# signal too — while the field arm is the thing only a template can
# spell: "Delete <that row's title>", one caption per stamped copy. A
# binding with the signal arm and not the field arm is the drift this
# census exists to see, so it is reported by name and not summed away.
#
# PYTHON IS IN THIS CENSUS, though it is exempt from both censuses above,
# and the difference IS the finding. Its transaction is ambient, so one
# module-level surface serves both zones and every KIND works in a
# template by construction — a kind census has nothing to measure there.
# A SOURCE IS NOT A KIND: `_text_value` raises on anything but `str`, so
# `kaya.button` refused a row's field while looking complete to every
# sweep in the tree, and Python was the one binding that could not spell
# the caption at all.
#
# Each reader returns the set of source flavours the point accepts, or
# None when it cannot LOCATE the constructor — which is refused as a
# broken reader, never reported as a binding with no sources. The two
# outcomes look identical in a name set and could not be more different.
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
    # The zone is the RECEIVER here, so the file is the block. Every
    # `Button*` header is read — the constant arm and the bound one are
    # different methods in this binding — and only the header, since a
    # body mentioning Signal would otherwise answer for a signature that
    # does not take one.
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
    # One `let button`, its sources spelled as optional arguments; the
    # header runs to the `=` that opens the body.
    m = re.search(r"^  let button\b(.*?)=\n", body, re.S | re.M)
    if m is None:
        return None
    head = m.group(1)
    got = set()
    # `?bind` and `?bind_field` are different arguments and the first is
    # a prefix of the second, so the signal arm is matched only where no
    # further name follows.
    if re.search(r"\?bind(?![_a-z])", head):
        got.add("signal")
    if re.search(r"\?bind_field\b", head):
        got.add("field")
    return got


def sources_haskell(_):
    # The zone is the RETURN TYPE and the sources are the CLASS: the
    # constructor's constraint names the class, and the class's instances
    # say which flavours it admits. Both halves are read, because a
    # constraint over a class with no Signal instance would be a source
    # in name only.
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
    # itself: the `bind=` argument and the ladder under it. A signature
    # with `bind=` whose body never reaches the element encoder would be
    # the silent-nothing arm this binding has already shipped once
    # (kaya.label(bind=) before its floor), so both are read.
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
# forwards the zone's methods one at a time, by hand. Three bindings have
# one, and until 2026-08-17 only Rust's was checked — the other two were
# ledgered follow-ups with a measured price (C#'s was offered at the props
# fan-out with eleven missing forwards, including a year-old SetGrow
# drift). A member on the zone and not on its façade is reachable through
# `for_each` and not through `for row in rows`, which is a difference no
# guest should have to know about.
#
# Each façade carries its own NOT_FORWARDED set, because each binding drew
# the plumbing line in its own place and the line is documented AT the
# façade. Reading each one's own list is measuring; one shared list would
# be legislating.
# Java's set was MEASURED at the fan-out rather than guessed: every name
# in Tpl and not in RowSurface was read off and classified, and only these
# four survived as plumbing. `widget` is the kind floor itself and its
# absence is load-bearing (it keeps a for-statement guest off the tier
# invariant 5 excludes); `addChild` is the parenting floor; `onToggleNode`
# is the bridge the generated typed sugar reaches through `tpl()`;
# `forEach` is compensated, since `collection()` IS forwarded and a nested
# `Collection.rows()` opens its trace off the ambient transaction.
# Everything else that was missing was drift, and was forwarded rather
# than excluded — including the five level-taking binds (the zone already
# forwarded their three a11y twins) and `when`, whose absence was the
# sharpest of them: `Tx.when` mints a LIVE widget id where `Tpl.when`
# mints a node id, so a guest inside a row trace that reached for the
# statement-level one emitted the wrong id space silently.
NOT_FORWARDED_JAVA = {
    "widget", "addChild", "onToggleNode", "forEach",
}

# C#'s façade documents its own exclusions in its generated header
# (guests/csharp/*Kaya.cs): "The zone's PLUMBING — Widget, the Bind*Field
# setters, AddChild, Collection/ForEach/When, ContextMenu — stays off
# deliberately". ContextMenu is on this list and off Rust's, which is a
# real divergence between two façades over one zone rather than a fact
# about C#; it is recorded here and ledgered rather than silently blessed.
NOT_FORWARDED_CSHARP = {
    "Widget", "AddChild", "Collection", "ForEach", "Each", "When", "ContextMenu",
    "BindTextElement", "BindTextField", "BindCheckedField", "BindValueField",
    "BindSourceField",
}


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
    pat = r"^\s*public\s+(?:void|Node)\s+([a-zA-Z][A-Za-z0-9]*)\s*\("
    return [(
        "Java's `RowSurface` (the `for (var row : ...)` façade, "
        "bindings/java/dev/kaya/KayaApp.java)",
        set(re.findall(pat, tpl, re.M)) - NOT_FORWARDED_JAVA,
        set(re.findall(pat, row, re.M)) - NOT_FORWARDED_JAVA,
        "class RowSurface",
    )]


def facade_csharp():
    """Every GENERATED `<Rec>Row` in the guest tree, against `Tpl`.

    The generated files are what a guest actually calls, so they are what
    is measured; the generator (tools/kaya-csgen) is what gets fixed when
    this fires. Reading all of them and not one is deliberate — they are
    stamped per record type, and a generator taught the forward emits it
    into every file at once, so a single laggard means someone
    hand-edited a generated file.
    """
    tpl = brace_block(read("bindings/csharp/KayaApp.cs"),
                      r"^\s*(public |internal )?sealed class Tpl\b")
    if tpl is None:
        return None
    pat = r"^\s*public\s+(?:void|Node)\s+([A-Za-z][A-Za-z0-9]*)\s*\("
    zone = set(re.findall(pat, tpl, re.M)) - NOT_FORWARDED_CSHARP
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
                set(re.findall(r"^\s*public\s+(?:void|Node)\s+([A-Za-z][A-Za-z0-9]*)\s*\(",
                               body, re.M)),
                f"tools/kaya-csgen (the generator that emits {m.group(1)})",
            ))
    if not out:
        # NOT a pass. The façades are generated files; finding none means
        # the reader has stopped seeing them, which is the empty-census
        # shape this whole file exists to refuse.
        return None
    return out


# THE FAÇADES THAT ARE NOT HERE, on the record rather than merely absent
# (gates.sh's EXCLUDED rule, one file over — an exemption nobody wrote
# down is indistinguishable from an oversight):
#
#   go — `type Row struct{ *Tpl }` EMBEDS the zone, so every method is
#     promoted by the compiler and the pair cannot drift. Its two sealed
#     surfaces (`SumCase`, and the `<name>Row` cmd/kaya-gen emits) hold a
#     private `t` and ARE checked, by bindings/go/tplzone_test.go, which
#     turns red on its own for any `*Tpl` prop they lack.
#   swift — `struct <Rec>Row` (tools/kaya-swift-gen) forwards constructors
#     and NO prop setter at all, and its `t: KayaTpl` is PUBLIC: guests
#     reach the zone through it today (guests/swift/undo.swift), so the
#     zone is not unreachable the way C#'s private field makes it. Being
#     level with C#'s façade is a slice of its own (~7 setters and ~20
#     constructors) and is ledgered as one; a clause here would be red
#     for reasons this census cannot fix.
FACADES = [
    ("rust", facade_rust),
    ("java", facade_java),
    ("csharp", facade_csharp),
]


def offers(names, kind):
    """Does this zone offer a constructor for `kind`?

    Prefix-loose in the same way check-sugar-surface's live sweep is, so
    a language's own flavour counts: `entryBound` and `entry_bound` are
    both `entry`, `progressIndeterminate` is `progress`.
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

        # THE READER IS WATCHED. A census that reads nothing agrees with
        # everything, and that is the shape a guard must never have.
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
    # TOLD rather than for what it can be MADE — the half that was
    # ledgered missing (docs/deferred.md, "sees constructors, not props").
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

    # THE TAKES-A-SOURCE CENSUS. Same zones, read for whether the
    # constructor can be handed the ROW rather than for whether it is
    # there at all — the question the kind census structurally cannot
    # ask, and the one the template button's caption drifted under.
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
                    "It does not forward: " + ", ".join(gap)
                    + f". Add the forward in {fix}, or add the name to this file's "
                    "NOT_FORWARDED set for that binding, with a reason."
                )
                status = 1
            wide = sorted(facade - zone)
            if wide:
                print(
                    f"tpl-surfaces: {where} offers members the zone does not: "
                    + ", ".join(wide)
                    + " — a façade cannot be wider than the zone it forwards to."
                )
                status = 1

    return status


if __name__ == "__main__":
    sys.exit(main())
