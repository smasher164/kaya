#!/usr/bin/env python3
"""The TEMPLATE-zone census: every widget kind, every binding.

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

Usage:
    tpl-surfaces.py [--kinds a,b,c] [<app.rs path>]
Exit 0 when every zone offers every kind; 1 with a message naming the
binding, the zone and the kinds when one does not.
"""

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
    src = read("bindings/go/app.go")
    return {m.lower() for m in re.findall(r"^func \(t \*Tpl\) ([A-Z][A-Za-z]*)\(", src, re.M)}


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

    # RUST'S TWO SURFACES, held level with each other. `Tpl` is the
    # zone; `Row` is the for-STATEMENT façade over the same zone and
    # forwards its methods one at a time, by hand. It forwarded six
    # while ten kinds were missing from the zone entirely, so nobody
    # noticed it was a list rather than a surface. A constructor on one
    # and not the other is reachable through `tx.for_each` and not
    # through `for row in rows`, which is a difference no guest should
    # have to know about.
    src = read("crates/kaya/src/app.rs")
    tpl = brace_block(src, r"^impl Tpl<'_, '_> \{")
    row = brace_block(src, r"^impl<'b> Row<'_, 'b> \{")
    if tpl is None or row is None:
        print("tpl-surfaces: cannot find Rust's Tpl/Row impl blocks to compare")
        return 1
    tpl_ctors = set(re.findall(r"^\s{4}pub fn ([a-z_0-9]+)", tpl, re.M)) - NOT_FORWARDED
    row_ctors = set(re.findall(r"^\s{4}pub fn ([a-z_0-9]+)", row, re.M)) - NOT_FORWARDED
    gap = sorted(tpl_ctors - row_ctors)
    if gap:
        print(
            "tpl-surfaces: Rust's template zone has two surfaces and they have "
            "drifted. `Row` (the `for row in rows` façade) does not forward: "
            + ", ".join(gap)
            + ". Add the forward to `impl Row`, or add the name to "
            "NOT_FORWARDED here with a reason."
        )
        status = 1
    wide = sorted(row_ctors - tpl_ctors)
    if wide:
        print(
            "tpl-surfaces: `Row` offers constructors `Tpl` does not: "
            + ", ".join(wide)
            + " — the façade cannot be wider than the zone it forwards to."
        )
        status = 1

    return status


if __name__ == "__main__":
    sys.exit(main())
