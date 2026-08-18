#!/usr/bin/env bash

# Everything runs inside the dev shell: the flake pins every toolchain
# (rust + cross targets, swiftc, ffmpeg, the android sdk). Running
# against anything else is an error, not something to paper over — and
# a shell entered before the flake last changed is just as much a
# bystander toolchain, so the marker carries the fingerprint of
# flake.nix+flake.lock the shell was actually built from.
kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# The sugar-surface guard: every widget kind in the spec must have a
# live-zone constructor in every binding's layer 3. The generator emits
# only the taste-free wire vocabulary; the constructors are hand-written
# per language — this check is what makes forgetting one structural
# rather than a matter of memory. Kinds come from the GENERATED python
# wire file, so the list tracks the spec by construction.
#
# Matching is by each binding's naming convention, prefix-loose so a
# language's flavor counts (Haskell's checkboxOn matches "checkbox",
# Go's Checkbox matches "checkbox"). C is exempt: it is the function
# floor on purpose.
#
# AND THE GUARD RUNS IN BOTH DIRECTIONS. Everything until the last
# clause is about what a BINDING OFFERS. The SCENE-TIER clause at the
# end is about what the EXAMPLES USE (invariant 5), because a binding
# can spell every constructor in all eight languages while the example
# scenes go on teaching the floor — which is precisely how the entry
# and milestone2 scenes stayed at the floor for five milestones.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

kinds=$(grep -oE '^KIND_[A-Z_]+' bindings/python/kaya/wire.py \
    | cut -c6- | tr '[:upper:]' '[:lower:]')
[ -n "$kinds" ] || { echo "check-sugar-surface: no kinds found in the generated wire file"; exit 1; }

status=0

# check <language> <file> <kind> <regex>
check() {
    if ! grep -qE "$4" "$2"; then
        echo "check-sugar-surface: $1 has no live-zone constructor for '$3' (wanted /$4/ in $2)"
        status=1
    fi
}

check_kind() {
    local kind="$1"
    local pascal
    pascal="$(tr '[:lower:]' '[:upper:]' <<<"${kind:0:1}")${kind:1}"
    check rust    crates/kaya/src/app.rs               "$kind" "pub fn ${kind}[a-z_]*(<[^>]*>)?\("
    check python  bindings/python/kaya/__init__.py          "$kind" "^def ${kind}[a-z_]*\("
    check go      bindings/go/app.go                   "$kind" "func \(tx \*Tx\) ${pascal}[A-Za-z]*\("
    check csharp  bindings/csharp/KayaApp.cs           "$kind" "public Widget ${pascal}[A-Za-z]*\("
    check java    bindings/java/dev/kaya/KayaApp.java  "$kind" "public Widget ${kind}[A-Za-z]*\("
    check swift   bindings/swift/KayaApp.swift         "$kind" "func ${kind}[A-Za-z]*\("
    # Leading whitespace allowed: row/column are Declare-class methods.
    check haskell bindings/haskell/KayaApp.hs          "$kind" "^[[:space:]]*${kind}[A-Za-z]* ::"
    check ocaml   bindings/ocaml/kaya_app.ml           "$kind" "^let ${kind}[a-z_]* "
}

# --- THE TEXT-RANGE SURFACE, in all eight -------------------------
#
# The three primitives (docs/ranges-plan.md D1) plus `set_text`, which
# is how an app puts a document in front of the user in the first place.
# WHY THEY NEED A CLAUSE AT ALL: this file's other two sweeps cover
# widget CONSTRUCTORS and WINDOW props, and a widget-level verb is
# neither, so nothing structural would have demanded these of the seven
# non-Rust bindings. check-verbs holds the COMPOSE INTERPRETER open and
# stops the day that arm lands; without this, the bindings' half of the
# sweep would then be held by a line in docs/deferred.md and nothing
# else. That is the shape invariant 2 exists to prevent — a change
# scoped silently to the languages a request named.
#
# RED BY DESIGN until the sweep lands, which is the depth-slice pattern
# (CLAUDE.md, sequencing).
# want_verb <language> <file> <verb> <regex> — `check`'s twin, with a
# message that says what is actually missing.
want_verb() {
    if ! grep -qE "$4" "$2"; then
        echo "check-sugar-surface: $1 has no sugar for the '$3' widget verb" \
            "(wanted /$4/ in $2)"
        status=1
    fi
}

# check_range_verb <snake_case> <PascalCase> <camelCase>
check_range_verb() {
    local snake="$1" pascal="$2" camel="$3"
    want_verb rust    crates/kaya/src/app.rs              "$snake" "pub fn ${snake}\\("
    # PYTHON PUTS WIDGET-ADDRESSED VERBS ON THE HANDLE, which is why
    # this one pattern is indented where the other seven are not. Every
    # pattern in this clause is that binding's spelling of `clear` and
    # `focus` — the widget-addressed one-shots these four join — and in
    # seven bindings that is a transaction method taking a widget
    # (`func (tx *Tx) Clear(w Widget)`, `let clear (Widget id)`), while
    # Python's is `Widget.clear(self)` because Python's transaction is
    # ambient and has no handle to hang it on. A module-level `def
    # highlight_ranges(widget, ranges)` would sit beside
    # `editor.focus()` in the same guest and read as two conventions;
    # the file's other handle-verb clauses (a11y_id, accepts, on_paste)
    # are all keyed on `(self` for the same reason.
    want_verb python  bindings/python/kaya/__init__.py    "$snake" "def ${snake}\\(self"
    want_verb go      bindings/go/app.go                  "$snake" "func \\(tx \\*Tx\\) ${pascal}\\("
    want_verb csharp  bindings/csharp/KayaApp.cs          "$snake" "public void ${pascal}\\("
    want_verb java    bindings/java/dev/kaya/KayaApp.java "$snake" "public void ${camel}\\("
    want_verb swift   bindings/swift/KayaApp.swift        "$snake" "func ${camel}\\("
    want_verb haskell bindings/haskell/KayaApp.hs         "$snake" "^[[:space:]]*${camel} ::"
    want_verb ocaml   bindings/ocaml/kaya_app.ml          "$snake" "^let ${snake} "
}
check_range_verb highlight_ranges HighlightRanges highlightRanges
check_range_verb select_range     SelectRange     selectRange
check_range_verb reveal_range     RevealRange     revealRange
check_range_verb set_text         SetText         setText

# THE BUILT-IN NEGATIVE TEST FOR THIS SWEEP, the same shape as the
# fake-kind one below: a verb that exists in no binding must fail in all
# eight, or the eight patterns have rotted into a rule that can only
# pass. Runs in a subshell so its status=1 dies with it.
range_fake=$(check_range_verb kaya_fake_verb KayaFakeVerb kayaFakeVerb 2>&1 \
    | grep -c "has no sugar for")
if [ "$range_fake" -ne 8 ]; then
    echo "check-sugar-surface: self-test failed ($range_fake/8 range-verb patterns" \
        "fired for a verb that exists nowhere)"
    exit 1
fi
unset range_fake

# The built-in negative test: a kind that exists nowhere must fail in
# every binding, or the patterns themselves have rotted. The fake runs
# inside $( ), so its `status=1` dies with that subshell and the real
# run's status is untouched — no reset here, deliberately: a reset is
# how the menus self-test below used to erase every failure the clauses
# above it had already found (caught 2026-07-25 by two real ocaml
# failures printing under a PASS verdict).
fake_failures=$(check_kind "kayafakewidget" 2>&1 | grep -c "no live-zone constructor")
if [ "$fake_failures" -ne 8 ]; then
    echo "check-sugar-surface: self-test failed ($fake_failures/8 patterns fired for a fake kind)"
    exit 1
fi

for kind in $kinds; do
    check_kind "$kind"
done

# --- THE TEMPLATE ZONE, the same sweep one zone over ----------------
#
# kaya has TWO construction zones and this file only ever checked one.
# The live zone is what an app builds in its build closure; the TEMPLATE
# zone is the prototype inside a collection, stamped once per row. They
# are different surfaces handing out different handles (Rust's zone
# yields TemplateNodeId where the live one yields Widget), so a
# constructor in one is not a constructor in the other — and until
# 2026-08-10 the template zone had three kinds where the live zone had
# fourteen.
#
# WHAT THAT COST, and why this is not tidiness: kaya's own text editor
# spells its find bar's text field `row.Widget(kaya.KindEntry)`, passing
# a wire constant as a runtime value, because there was no `entry` to
# call. The undo scene does the same in seven languages. The floor is
# the C guests' tier (invariant 5), not an app's.
#
# THE SWEEP IS PYTHON, NOT SEVEN MORE `check` LINES, and that is forced
# rather than chosen: three bindings namespace the template zone by
# SCOPE rather than by name. Rust's `Tpl` methods are `pub fn entry`
# exactly like `Tx`'s and OCaml's live in `module Tpl = struct`, so a
# line-oriented pattern cannot tell which block a line sits in — it
# would be satisfied by the LIVE constructor and report a zone it never
# read. tools/tpl-surfaces.py locates each zone by its real structure,
# reads the constructors from inside it, and REFUSES A VERDICT from a
# reader that found implausibly few (a census that reads nothing agrees
# with everything). It also holds Rust's two surfaces level with each
# other: `Tpl` is the zone, `Row` is the for-statement façade that
# forwards by hand, and it forwarded six methods while ten kinds were
# missing.
#
# Kinds come from the generated wire file, same as the live sweep, so
# the list tracks the spec by construction.
tpl_kinds=$(echo "$kinds" | tr '\n' ',')
tpl_out=$(python3 tools/tpl-surfaces.py --kinds "${tpl_kinds%,}" 2>&1)
tpl_rc=$?
if [ "$tpl_rc" -ne 0 ]; then
    echo "$tpl_out"
    status=1
fi

# ITS NEGATIVE TEST, in both directions.
#
# (a) A KIND THAT EXISTS NOWHERE must be reported missing by every zone
#     reader, or the readers have rotted into a census that can only
#     pass.
tpl_fake=$(python3 tools/tpl-surfaces.py --kinds kayafakewidget 2>&1 \
    | grep -c "no TEMPLATE-zone constructor")
if [ "$tpl_fake" -ne 7 ]; then
    echo "check-sugar-surface: template self-test failed ($tpl_fake/7 zone" \
        "readers reported a kind that exists nowhere as missing)" >&2
    exit 1
fi
unset tpl_fake

# (b) AND A KIND EVERY BINDING HAS must be reported by none. Seven
#     readers keyed on block headers are exactly the shape that goes
#     vacuous when a binding renames its template type, and a reader
#     that finds nothing is indistinguishable from a zone with nothing
#     missing. `label` is in every template zone, so a complaint about
#     it means a reader has stopped reading.
tpl_real=$(python3 tools/tpl-surfaces.py --kinds label 2>&1 \
    | grep -c "no TEMPLATE-zone constructor")
if [ "$tpl_real" -ne 0 ]; then
    echo "check-sugar-surface: template self-test failed ($tpl_real zone readers" \
        "could not find 'label', which every template zone has — those readers" \
        "have stopped matching the files they read and can no longer fail)" >&2
    exit 1
fi
unset tpl_real

# (c) AND RUST'S TWO-SURFACE CLAUSE IS WATCHED, by deleting one forward
#     from a copy of the real file. The perturbation count is printed
#     and checked: a substitution that did not apply is a FAILED test,
#     not a passed one (invariant 3).
tpl_row_probe=$(python3 - <<'PROBE'
import os, subprocess, sys, shutil, tempfile
src = open('crates/kaya/src/app.rs').read()
victim = """    pub fn entry(&mut self) -> TemplateNodeId {
        self.tpl().entry()
    }

"""
n = src.count(victim)
if n != 1:
    print(f"SELFTEST-BROKEN: perturbation matched {n} times, expected 1")
    sys.exit(0)
root = tempfile.mkdtemp()
os.makedirs(f"{root}/crates/kaya/src", exist_ok=True)
# `guests` too, since the census reads C#'s GENERATED `<Rec>Row` façades
# out of the guest tree: without it that clause reports a reader it
# cannot locate, and this probe would pass on the wrong failure.
for rel in ("bindings", "tools", "guests"):
    os.symlink(os.path.abspath(rel), f"{root}/{rel}")
open(f"{root}/crates/kaya/src/app.rs", "w").write(src.replace(victim, ""))
out = subprocess.run([sys.executable, 'tools/tpl-surfaces.py', root],
                     capture_output=True, text=True)
shutil.rmtree(root)
hit = "does not forward: entry" in out.stdout
print(f"applied=1 rc={out.returncode} named_entry={hit}")
PROBE
)
case "$tpl_row_probe" in
    "applied=1 rc=1 named_entry=True") ;;
    *)
        echo "check-sugar-surface: SELF-TEST FAIL (deleting Row's 'entry' forward" \
            "was not caught by tools/tpl-surfaces.py: $tpl_row_probe)" >&2
        exit 1
        ;;
esac
unset tpl_row_probe

# (d) THE PROP CENSUS IS WATCHED THE SAME WAY, in three perturbations —
#     the census grew prop awareness on 2026-08-17 and a prop sweep
#     nobody has seen fail is exactly the guard invariant 3 calls worse
#     than none. Each probe stages a temp repo root in which ONE file
#     differs and everything else is a symlink to the real tree, so the
#     census reads the real bindings and the real generated façades and
#     the only variable is the perturbation. Each prints its substitution
#     count: a probe that did not apply is a FAILED test.
#
#     d1 IS THE HISTORICAL SHAPE ITSELF — a prop the LIVE zone has and
#        the TEMPLATE zone does not — and OCaml is the subject because
#        its two zones spell the prop in the same eleven characters
#        (`set_role (Widget id)` against `set_role (Node id)`). The live
#        setter stays in the file throughout, so a census satisfied by
#        the live twin passes this probe and a zone-scoped one cannot.
#     d2 is a forward deleted from a GENERATED C# façade, the clause the
#        ledger asked for (docs/deferred.md, three follow-ups).
#     d3 renames the zone's own header: a reader that can no longer find
#        the zone must REFUSE, never report an empty zone as a clean one.
tpl_prop_probe=$(python3 - <<'PROBE'
import os, re, shutil, subprocess, sys, tempfile


def stage(perturb):
    """A temp repo root where exactly `perturb` (path -> text) differs."""
    root = tempfile.mkdtemp()
    dirs = {}
    for path in perturb:
        parts = path.split("/")
        for i in range(1, len(parts)):
            dirs.setdefault("/".join(parts[:i]), True)
    for top in os.listdir("."):
        if top not in dirs:
            os.symlink(os.path.abspath(top), f"{root}/{top}")
    for d in sorted(dirs):
        os.makedirs(f"{root}/{d}", exist_ok=True)
        for entry in os.listdir(d):
            child = f"{d}/{entry}"
            if child not in dirs and child not in perturb:
                os.symlink(os.path.abspath(child), f"{root}/{child}")
    for path, text in perturb.items():
        open(f"{root}/{path}", "w", encoding="utf-8").write(text)
    return root


def probe(name, path, old, new, want):
    src = open(path, encoding="utf-8").read()
    n = src.count(old)
    if n != 1:
        print(f"{name}=SELFTEST-BROKEN(matched {n}, expected 1)")
        return
    root = stage({path: src.replace(old, new)})
    r = subprocess.run([sys.executable, "tools/tpl-surfaces.py", root],
                       capture_output=True, text=True)
    shutil.rmtree(root)
    print(f"{name}=applied:1 rc:{r.returncode} named:{want in r.stdout}")


probe("d1", "bindings/ocaml/kaya_app.ml",
      "    let set_role (Node id) r = emit (the_tx ()) "
      "(Kaya_wire.tx_set_role id (role_wire r))\n",
      "", "ocaml's TEMPLATE zone cannot spell role")
probe("d2", "guests/csharp/ItemKaya.cs",
      "    public void SetRole(Node n, Role role) => t.SetRole(n, role);\n",
      "", "does not forward: SetRole")
probe("d3", "bindings/ocaml/kaya_app.ml",
      "module Tpl = struct\n", "module TplRenamed = struct\n",
      "cannot find ocaml's template zone")
PROBE
)
want_prop_probe="d1=applied:1 rc:1 named:True
d2=applied:1 rc:1 named:True
d3=applied:1 rc:1 named:True"
if [ "$tpl_prop_probe" != "$want_prop_probe" ]; then
    echo "check-sugar-surface: SELF-TEST FAIL (the template PROP census did not" \
        "catch a perturbation it must catch). Wanted:" >&2
    echo "$want_prop_probe" >&2
    echo "Got:" >&2
    echo "$tpl_prop_probe" >&2
    exit 1
fi
unset tpl_prop_probe want_prop_probe

# (e) AND THE TAKES-A-SOURCE CENSUS, which grew on 2026-08-18 and asks
#     the question the two above structurally cannot: not whether the
#     kind has a constructor, but whether that constructor can be handed
#     the ROW. `Tpl.Button(string)` satisfies the kind census exactly as
#     `Tpl.button(Signal<String>)` does, which is how a per-row button
#     caption came to be sugar in five bindings, floor-only in C# and
#     Swift and inexpressible in Python with every gate green
#     (docs/deferred.md, closed 2026-08-18).
#
#     e1 IS THAT HISTORICAL SHAPE ITSELF, spliced back in from git: the
#        three bindings' files as they stood at c9bb989, everything else
#        the real tree. The census must come back red naming exactly
#        csharp, swift and python — five quiet, three named — which is
#        the drift the ledger recorded, and is the proof that this clause
#        would have caught it. The splice is REFUSED if a file comes back
#        byte-identical to the working tree: a perturbation that applied
#        nothing is a failed test, not a passed one (invariant 3).
#     e2 deletes JAVA's field overload — a binding this slice never
#        touched — because a census keyed to the three that were fixed
#        would pass e1 and see nothing anywhere else.
#     e3 renames Haskell's constructor: a reader that can no longer find
#        the point must REFUSE, never report a binding with no sources.
#        The two outcomes are one empty set apart and could not differ
#        more.
tpl_src_probe=$(python3 - <<'PROBE'
import os, shutil, subprocess, sys, tempfile

LANGS = ("rust", "go", "csharp", "java", "swift", "ocaml", "haskell", "python")
BASE = "c9bb989"  # the commit the drift was closed on top of


def stage(perturb):
    """A temp repo root where exactly `perturb` (path -> text) differs."""
    root = tempfile.mkdtemp()
    dirs = {}
    for path in perturb:
        parts = path.split("/")
        for i in range(1, len(parts)):
            dirs.setdefault("/".join(parts[:i]), True)
    for top in os.listdir("."):
        if top not in dirs:
            os.symlink(os.path.abspath(top), f"{root}/{top}")
    for d in sorted(dirs):
        os.makedirs(f"{root}/{d}", exist_ok=True)
        for entry in os.listdir(d):
            child = f"{d}/{entry}"
            if child not in dirs and child not in perturb:
                os.symlink(os.path.abspath(child), f"{root}/{child}")
    for path, text in perturb.items():
        open(f"{root}/{path}", "w", encoding="utf-8").write(text)
    return root


def run(perturb):
    root = stage(perturb)
    r = subprocess.run([sys.executable, "tools/tpl-surfaces.py", root],
                       capture_output=True, text=True)
    shutil.rmtree(root)
    return r


# e1 — the historical shape, read out of git rather than re-typed here.
perturb = {}
for path in ("bindings/csharp/KayaApp.cs", "bindings/swift/KayaApp.swift",
             "bindings/python/kaya/__init__.py"):
    old = subprocess.run(["git", "show", f"{BASE}:{path}"],
                         capture_output=True, text=True)
    if old.returncode != 0:
        print(f"e1=SELFTEST-BROKEN(cannot read {BASE}:{path})")
        break
    if old.stdout == open(path, encoding="utf-8").read():
        print(f"e1=SELFTEST-BROKEN({path} unchanged since {BASE})")
        break
    perturb[path] = old.stdout
else:
    r = run(perturb)
    named = [l for l in LANGS if f"{l}'s TEMPLATE-zone button caption" in r.stdout]
    print(f"e1=applied:{len(perturb)} rc:{r.returncode} named:{','.join(named)}")

# e2 — an untouched sibling's field overload, deleted.
JAVA = "bindings/java/dev/kaya/KayaApp.java"
victim = """        public Node button(KayaRecords.Field<String> f) {
            Node n = widget(KayaWire.KIND_BUTTON);
            bindTextField(n, 0, f);
            return n;
        }
"""
src = open(JAVA, encoding="utf-8").read()
n = src.count(victim)
if n != 1:
    print(f"e2=SELFTEST-BROKEN(matched {n}, expected 1)")
else:
    r = run({JAVA: src.replace(victim, "")})
    hit = "java's TEMPLATE-zone button caption takes no field" in r.stdout
    print(f"e2=applied:1 rc:{r.returncode} named:{hit}")

# e3 — the reader must refuse, not report an empty set.
HS = "bindings/haskell/KayaApp.hs"
src = open(HS, encoding="utf-8").read()
old = "buttonBound :: TplStrSource s => s -> Tpl Node\n"
n = src.count(old)
if n != 1:
    print(f"e3=SELFTEST-BROKEN(matched {n}, expected 1)")
else:
    r = run({HS: src.replace(old, "buttonRenamed :: TplStrSource s => s -> Tpl Node\n")})
    hit = "cannot find haskell's template button constructor" in r.stdout
    print(f"e3=applied:1 rc:{r.returncode} named:{hit}")
PROBE
)
want_src_probe="e1=applied:3 rc:1 named:csharp,swift,python
e2=applied:1 rc:1 named:True
e3=applied:1 rc:1 named:True"
if [ "$tpl_src_probe" != "$want_src_probe" ]; then
    echo "check-sugar-surface: SELF-TEST FAIL (the template TAKES-A-SOURCE census" \
        "did not catch a perturbation it must catch). Wanted:" >&2
    echo "$want_src_probe" >&2
    echo "Got:" >&2
    echo "$tpl_src_probe" >&2
    exit 1
fi
unset tpl_src_probe want_src_probe

# THE SCALAR ELEMENT HAS A NAME, in all eight.
#
# A template constructor's element source is a FIELD, addressed by index
# off a record. A SCALAR collection has no record — its element IS the
# value — so binding it had no sugar spelling and three example scenes
# built a template label at the widget-kind floor instead
# (guests/{haskell/menus.hs, ocaml/menus.ml, swift/menus.swift}). Only
# Go had a name for it, and Go's is the reason the gap was visible at
# all: `Row.Value()` returns literally `FieldAt[string](0)`.
#
# Nothing was missing but a NAME for field 0. The wire record is
# identical either way, which is exactly why nobody noticed: the floor
# spelling WORKED, it just taught the floor (invariant 5).
#
# Go keeps `Row.Value()` — it is scoped to a row surface no other
# binding has, and its doc already says "the element itself"; the idiom
# decides the spelling, never the semantics. Python's ambient `for_each`
# yields the element as `el`, so its "token" is the loop variable.
check rust    crates/kaya/src/app.rs \
    "scalar element" "pub const fn element\(\)"
check python  bindings/python/kaya/__init__.py \
    "scalar element" "class Element\b|def __enter__"
check go      bindings/go/app.go \
    "scalar element" "func \(r Row\) Value\(\)"
check csharp  bindings/csharp/KayaRecords.cs \
    "scalar element" "static Field<string> Element"
check java    bindings/java/dev/kaya/KayaRecords.java \
    "scalar element" "static Field<String> element\("
check swift   bindings/swift/KayaRecords.swift \
    "scalar element" "static var element: KayaField<String>"
check ocaml   bindings/ocaml/kaya_app.ml \
    "scalar element" "^let element : \('a, string\) field"
check haskell bindings/haskell/KayaApp.hs \
    "scalar element" "^element :: KField String"

# THE TEMPLATE-NODE PROPS, in all eight (docs/tpl-props-plan.md P1/P2):
# the a11y pair + hint (source-taking), accepts (const — a prototype
# fact), and the node paste registrar. Every pattern is RECEIVER-KEYED
# on the template handle type, and that is the lesson this block was
# born holding: the first draft of the grow clause below matched OCaml's
# LIVE set_grow and went vacuous, proven by perturbation — a
# bare-method-name pattern is satisfied by the live twin every time.
# Swift's fan-out agent hit the same shape independently (its N2
# negative). Python's clause is a separate AST reader
# (tools/checks/py-node-props.py) because its zones share one surface
# and a file-scoped grep stayed green through the whole defect.
check rust    crates/kaya/src/app.rs \
    "template a11y id"    "pub fn a11y_id\(&mut self, node: TemplateNodeId"
check rust    crates/kaya/src/app.rs \
    "template a11y label" "pub fn a11y_label\(&mut self, node: TemplateNodeId"
check rust    crates/kaya/src/app.rs \
    "template a11y hint"  "pub fn a11y_hint\(&mut self, node: TemplateNodeId"
check rust    crates/kaya/src/app.rs \
    "template accepts"    "pub fn accepts\(&mut self, node: TemplateNodeId"
check rust    crates/kaya/src/app.rs \
    "node paste registrar" "pub fn on_paste_node\("
check go      bindings/go/app.go \
    "template a11y id"    "func \(t \*Tpl\) SetA11yID\("
check go      bindings/go/app.go \
    "template a11y id (sourced)" "func \(t \*Tpl\) BindA11yID\["
check go      bindings/go/app.go \
    "template a11y label" "func \(t \*Tpl\) SetA11yLabel\("
check go      bindings/go/app.go \
    "template a11y label (sourced)" "func \(t \*Tpl\) BindA11yLabel\["
check go      bindings/go/app.go \
    "template a11y hint"  "func \(t \*Tpl\) SetA11yHint\("
check go      bindings/go/app.go \
    "template accepts"    "func \(t \*Tpl\) SetAccepts\("
check csharp  bindings/csharp/KayaApp.cs \
    "template a11y id"    "public void SetA11yId\(Node n, Field<string>"
check csharp  bindings/csharp/KayaApp.cs \
    "template a11y label" "public void SetA11yLabel\(Node n, Field<string>"
check csharp  bindings/csharp/KayaApp.cs \
    "template a11y hint"  "public void SetA11yHint\(Node n, Field<string>"
check csharp  bindings/csharp/KayaApp.cs \
    "template accepts"    "public void SetAccepts\(Node"
check csharp  bindings/csharp/KayaApp.cs \
    "node paste registrar" "public void OnPaste\(Node"
check java    bindings/java/dev/kaya/KayaApp.java \
    "template a11y id"    "public void setA11yId\(Node"
check java    bindings/java/dev/kaya/KayaApp.java \
    "template a11y label" "public void setA11yLabel\(Node"
check java    bindings/java/dev/kaya/KayaApp.java \
    "template a11y hint"  "public void setA11yHint\(Node"
check java    bindings/java/dev/kaya/KayaApp.java \
    "template accepts"    "public void setAccepts\(Node"
check swift   bindings/swift/KayaApp.swift \
    "template a11y id"    "func setA11yId\(_ n: KayaNodeHandle"
check swift   bindings/swift/KayaApp.swift \
    "template a11y label" "func setA11yLabel\(_ n: KayaNodeHandle"
check swift   bindings/swift/KayaApp.swift \
    "template a11y hint"  "func setA11yHint\(_ n: KayaNodeHandle"
check swift   bindings/swift/KayaApp.swift \
    "template accepts"    "func setAccepts\(_ n: KayaNodeHandle"
check ocaml   bindings/ocaml/kaya_app.ml \
    "template a11y id"    "let set_a11y_id \(Node id\)"
check ocaml   bindings/ocaml/kaya_app.ml \
    "template a11y label" "let set_a11y_label \(Node id\)"
check ocaml   bindings/ocaml/kaya_app.ml \
    "template a11y hint"  "let set_a11y_hint \(Node id\)"
check ocaml   bindings/ocaml/kaya_app.ml \
    "template accepts"    "let set_accepts \(Node id\)"
check ocaml   bindings/ocaml/kaya_app.ml \
    "template a11y label (sourced)" "let bind_a11y_label_field "
check ocaml   bindings/ocaml/kaya_app.ml \
    "template each"       "^  let each c body \(\) ="
check ocaml   bindings/ocaml/kaya_app.ml \
    "node paste registrar" "^let on_paste_node "
check haskell bindings/haskell/KayaApp.hs \
    "template a11y id"    "TplA11yId ::"
check haskell bindings/haskell/KayaApp.hs \
    "template a11y label" "TplA11yLabel ::"
check haskell bindings/haskell/KayaApp.hs \
    "template a11y hint"  "TplA11yHint ::"
check haskell bindings/haskell/KayaApp.hs \
    "template accepts"    "TplAccepts ::"
check haskell bindings/haskell/KayaApp.hs \
    "node paste registrar" "^onPasteNode ::"

# Python's, by CLASS STRUCTURE rather than grep — the reader walks
# `class Node` and its bases with `ast` and requires each prop method
# reachable. Its negative was watched by the fan-out (rename on the
# base -> exit 1 naming the prop; unhook the base -> exit 1 naming all
# of them).
#
# IT READS TWO STRUCTURES NOW, not one, because Python spells the zone's
# seven props in two ways. Six ride `_Handle`, the base `class Node`
# inherits — that is the whole of why Python needed no template setter
# when role landed. The SEVENTH, inset, is a CONSTRUCTOR KEYWORD
# (`kaya.row(inset=8)`), so the reader holds the chain instead: the
# kwarg reaches `_set_inset`, which writes onto `_widget`, which is
# `_alloc_widget_or_node` and branches on `_tpl_depth`. Nothing on that
# path may ask which zone it is in — a `_tpl_depth` read inside
# `_set_inset` or `_Handle.role` is the shape that would make one zone
# quietly different from the other, and the reader refuses it. It also
# refuses a verdict when it cannot find the allocator at all.
tpl_props_py=$(python3 tools/checks/py-node-props.py bindings/python/kaya/__init__.py 2>&1)
tpl_props_py_rc=$?
if [ "$tpl_props_py_rc" -ne 0 ]; then
    echo "check-sugar-surface: $tpl_props_py"
    status=1
fi

# A TEMPLATE NODE'S GROW WEIGHT, in all eight.
#
# The template zone carried exactly ONE prop when this clause was
# written, and the clause is why it carried one rather than none.
# `scroll` needs it — an unconstrained viewport hugs its content and
# nothing ever overflows, so a template scroll without a grow weight is
# a scroll that cannot scroll — and Rust's `Tpl` could always spell it
# through the generic `set(node, prop, value)`, so a binding shipping
# the scroll constructor WITHOUT grow is a divergence opened by the same
# pass that closed one. (The zone carries seven props today: the a11y
# trio and accepts arrived with the props slice, role and inset with the
# styling one. The census in tools/tpl-surfaces.py is what sweeps them.)
#
# It is written down because the fan-out drifted on it in real time:
# five bindings shipped a template grow and two did not, each side with
# a defensible reading of a plan that ledgered template-node props as
# out of scope. One rule, eight spellings, checked (invariant 1).
#
# The rest of the template-node props landed exactly as this comment
# once demanded — as a sweep, not one binding at a time: the a11y trio,
# accepts and the paste registrar are the clause block ABOVE this one
# (docs/tpl-props-plan.md P1/P2). Spacing and align remain floor-only on
# template containers, in every binding alike.
#
# AND NEW TEMPLATE PROPS DO NOT GO HERE ANY MORE. Since 2026-08-17 the
# prop sweep lives in tools/tpl-surfaces.py's PROP_MEMBERS table, which
# reads each spelling out of the template zone's OWN BLOCK — the thing a
# line pattern cannot do, and the reason `role` and `inset` were added
# there and not as sixteen more `check` lines. The clauses above and
# below stay because they are already written and already pass; they are
# not the pattern to copy. Python is the census's one exemption (its two
# zones share a surface) and is covered by tools/checks/py-node-props.py.
check rust    crates/kaya/src/app.rs \
    "template grow" "pub fn set\(&mut self, node: TemplateNodeId"
check python  bindings/python/kaya/__init__.py \
    "template grow" "def _set_grow\("
check go      bindings/go/app.go \
    "template grow" "func \(t \*Tpl\) SetGrow\("
check csharp  bindings/csharp/KayaApp.cs \
    "template grow" "public void SetGrow\(Node"
check java    bindings/java/dev/kaya/KayaApp.java \
    "template grow" "public void setGrow\(Node"
check swift   bindings/swift/KayaApp.swift \
    "template grow" "func setGrow\(_ n: KayaNodeHandle"
# RECEIVER-KEYED, unlike the first draft of this line: `let set_grow `
# also matched the LIVE set_grow (Widget id) at kaya_app.ml:631, so the
# template setter could be deleted and this clause stayed green —
# proven by perturbation during the props survey (2026-08-10). The Node
# pattern is the part that makes it a claim about the template zone.
check ocaml   bindings/ocaml/kaya_app.ml \
    "template grow" "let set_grow \\(Node id\\)"
check haskell bindings/haskell/KayaApp.hs \
    "template grow" "setGrow[A-Za-z]* ::"

# --- AND THE OTHER DIRECTION: WHAT THE EXAMPLES USE ------------------
#
# Everything above is about what a BINDING OFFERS. This is invariant 5:
# all example scenes use each language's sugar tier, and only the C
# guests keep the explicit floor, deliberately, as the floor's
# documentation.
#
# The scene tier at the end of this file already fails a guest for using
# the floor, and it is good at it — per-language spellings, each watched
# firing against a doctored copy of the real guest. It reads only the
# scenes in its `scene_guests` table, which is `entry` and `milestone2`,
# the two carve-out scenes. So a guest outside that table could teach
# the floor indefinitely, and several did: the undo scene built its
# per-row text field with `widget(KIND_ENTRY)` in seven languages for
# five milestones, the text editor shipped its find bar the same way,
# and guests/haskell/textarea.hs built its ENTIRE scene at the floor
# while every constructor it needed sat unused in the binding.
#
# The first two had an excuse and it is now gone — the template zone had
# no constructor for those kinds. So the rule is one sentence with no
# per-scene table to forget to add to: a sugar guest does not name a
# widget kind. tools/guest-floor.py sweeps every guest outside guests/c,
# strips comments FIRST (the converted guests all explain the old floor
# spelling in a comment above the new call, so a sweep that reads
# comments reports every file it just fixed — measured while writing
# it), and carries its exemptions with reasons the way gates.sh does.
floor_out=$(python3 tools/guest-floor.py 2>&1)
floor_rc=$?
if [ "$floor_rc" -ne 0 ]; then
    echo "$floor_out"
    status=1
fi

# ITS NEGATIVE TEST: put a floor call back into the guest whose one line
# started the whole sugar pass, and require the sweep to name it. The
# substitution count is printed and checked — an unchanged file is a
# failed test, not a passed one.
floor_probe=$(python3 - <<'PROBE'
import os, shutil, subprocess, sys, tempfile
p = 'guests/go/editor/editor.go'
src = open(p).read()
old, new = "query = row.Entry()", "query = row.Widget(kaya.KindEntry)"
n = src.count(old)
if n != 1:
    print(f"SELFTEST-BROKEN: perturbation matched {n} times, expected 1")
    sys.exit(0)
root = tempfile.mkdtemp()
shutil.copytree('guests', f"{root}/guests")
open(f"{root}/{p}", "w").write(src.replace(old, new))
r = subprocess.run([sys.executable, 'tools/guest-floor.py', root],
                   capture_output=True, text=True)
shutil.rmtree(root)
print(f"applied=1 rc={r.returncode} named={'editor.go' in r.stdout}")
PROBE
)
case "$floor_probe" in
    "applied=1 rc=1 named=True") ;;
    *)
        echo "check-sugar-surface: SELF-TEST FAIL (a widget-kind floor call put" \
            "back into the editor guest was not caught by tools/guest-floor.py:" \
            "$floor_probe)" >&2
        exit 1
        ;;
esac
unset floor_probe

# The grow prop's layer-3 spelling, per language idiom (a kwarg, a
# named setter, a combinator — decided 2026-07-20, see the ledger).
# Props are not kinds, so the constructor loop above cannot see them;
# without this, a binding shipping wire-only grow would pass every
# gate until a guest failed to compile.
check rust    crates/kaya/src/app.rs              grow "fn grow\(self"
check python  bindings/python/kaya/__init__.py    grow "def grow\(self, weight\)"
check go      bindings/go/app.go                  grow "func \(w Widget\) Grow\("
check csharp  bindings/csharp/KayaApp.cs          grow "public void SetGrow\("
check java    bindings/java/dev/kaya/KayaApp.java grow "public Widget grow\("
check swift   bindings/swift/KayaApp.swift        grow "func setGrow\("
check haskell bindings/haskell/KayaApp.hs         grow "Grow :: Double -> Attr"
check ocaml   bindings/ocaml/kaya_app.ml          grow "let label \?grow "

# The spacing prop's layer-3 spelling, same rule: a binding shipping
# wire-only spacing must fail here, not on a reviewer's eye.
check rust    crates/kaya/src/app.rs              spacing "fn spacing\(self"
check python  bindings/python/kaya/__init__.py    spacing "def spacing\(self, gap\)"
check go      bindings/go/app.go                  spacing "func \(w Widget\) Spacing\("
check csharp  bindings/csharp/KayaApp.cs          spacing "public void SetSpacing\("
check java    bindings/java/dev/kaya/KayaApp.java spacing "public Widget spacing\("
check swift   bindings/swift/KayaApp.swift        spacing "func setSpacing\("
check haskell bindings/haskell/KayaApp.hs         spacing "Spacing :: Double -> Attr"
check ocaml   bindings/ocaml/kaya_app.ml          spacing "let row \?grow \?a11y_id \?a11y_label \?spacing "

# The align prop's layer-3 spelling, same rule again.
check rust    crates/kaya/src/app.rs              align "fn align\\(self"
check python  bindings/python/kaya/__init__.py    align "def align\\(self, mode\\)"
check go      bindings/go/app.go                  align "func \\(w Widget\\) Align\\("
check csharp  bindings/csharp/KayaApp.cs          align "public void SetAlign\\("
check java    bindings/java/dev/kaya/KayaApp.java align "public Widget align\\("
check swift   bindings/swift/KayaApp.swift        align "func setAlign\\("
check haskell bindings/haskell/KayaApp.hs         align "Align :: Align -> Attr"
check ocaml   bindings/ocaml/kaya_app.ml          align "let row \\?grow \\?a11y_id \\?a11y_label \\?spacing \\?align "

# THE UNIVERSAL ACCESSIBILITY PROPS, same rule as grow/spacing/align.
# These two are the only props every KIND carries, so a binding that
# ships them wire-only leaves every widget in that language unnamed and
# unaddressable to assistive tech — and nothing else would notice until
# an app shipped. The C floor is exempt with the rest of C: the
# generated kaya_tx_set_a11y_id/_label ARE its surface.
check rust    crates/kaya/src/app.rs              a11y_id "fn a11y_id\\(self"
check python  bindings/python/kaya/__init__.py    a11y_id "def a11y_id\\(self, ident\\)"
check go      bindings/go/app.go                  a11y_id "func \\(w Widget\\) A11yID\\("
check csharp  bindings/csharp/KayaApp.cs          a11y_id "public void SetA11yId\\("
check java    bindings/java/dev/kaya/KayaApp.java a11y_id "public Widget a11yId\\("
check swift   bindings/swift/KayaApp.swift        a11y_id "func setA11yId\\("
check haskell bindings/haskell/KayaApp.hs         a11y_id "A11yId :: String -> Attr"
check ocaml   bindings/ocaml/kaya_app.ml          a11y_id "let set_a11y_id \\(Widget id\\)"

check rust    crates/kaya/src/app.rs              a11y_label "fn a11y_label\\(self"
check python  bindings/python/kaya/__init__.py    a11y_label "def a11y_label\\(self, label\\)"
check go      bindings/go/app.go                  a11y_label "func \\(w Widget\\) A11yLabel\\("
check csharp  bindings/csharp/KayaApp.cs          a11y_label "public void SetA11yLabel\\("
check java    bindings/java/dev/kaya/KayaApp.java a11y_label "public Widget a11yLabel\\("
check swift   bindings/swift/KayaApp.swift        a11y_label "func setA11yLabel\\("
check haskell bindings/haskell/KayaApp.hs         a11y_label "A11yLabel :: String -> Attr"
check ocaml   bindings/ocaml/kaya_app.ml          a11y_label "let set_a11y_label \\(Widget id\\)"

# The HINT prop, same rule as the two universal ones — but note it is
# ACTIVATION-KINDS-ONLY by the root's own check (a hint needs something
# to activate; Android carries it as an action's label). The gate still
# demands a spelling per binding: a language that ships it wire-only
# leaves apps unable to author hints at all.
check rust    crates/kaya/src/app.rs              a11y_hint "fn a11y_hint\(self"
check python  bindings/python/kaya/__init__.py    a11y_hint "def a11y_hint\(self, hint\)"
check go      bindings/go/app.go                  a11y_hint "func \(w Widget\) A11yHint\("
check csharp  bindings/csharp/KayaApp.cs          a11y_hint "public void SetA11yHint\("
check java    bindings/java/dev/kaya/KayaApp.java a11y_hint "public Widget a11yHint\("
check swift   bindings/swift/KayaApp.swift        a11y_hint "func setA11yHint\("
check haskell bindings/haskell/KayaApp.hs         a11y_hint "A11yHint :: String -> Attr"
check ocaml   bindings/ocaml/kaya_app.ml          a11y_hint "let set_a11y_hint \(Widget id\)"

# THE CLIPBOARD SURFACE (DESIGN.md, Clipboard). Four points, and none
# of them is a widget kind or a window prop, so nothing above can see
# them: the copy record, the privileged read, the per-widget accept
# list, and the paste hook. A binding shipping the clipboard wire-only
# would leave apps in that language unable to copy anything at all,
# and every other gate would pass.
#
# THE SPELLINGS DIFFER AND THE SEMANTICS DO NOT, which is the binding
# convention (DESIGN.md): copy is a CHAIN where the language builds by
# chaining, keyword arguments where it has them, and a record where
# that is the idiom — but at-most-one-per-kind is structural in all
# eight, never a duplicate check. `accepts` takes the kinds as VALUES
# and joins them to the space-separated list the wire carries.
check rust    crates/kaya/src/app.rs              copy "pub fn copy\(&mut self"
check python  bindings/python/kaya/__init__.py    copy "^def copy\("
check go      bindings/go/app.go                  copy "func \(tx \*Tx\) Copy\("
check csharp  bindings/csharp/KayaApp.cs          copy "public CopyRef Copy\("
check java    bindings/java/dev/kaya/KayaApp.java copy "public CopyRef copy\("
check swift   bindings/swift/KayaApp.swift        copy "func copy\("
check haskell bindings/haskell/KayaApp.hs         copy "^copy ::"
check ocaml   bindings/ocaml/kaya_app.ml          copy "^let copy "

check rust    crates/kaya/src/app.rs              read_clipboard "pub fn read_clipboard\(&mut self"
check python  bindings/python/kaya/__init__.py    read_clipboard "^def read_clipboard\("
check go      bindings/go/app.go                  read_clipboard "func \(tx \*Tx\) ReadClipboard\("
check csharp  bindings/csharp/KayaApp.cs          read_clipboard "public ClipReadRef ReadClipboard\("
check java    bindings/java/dev/kaya/KayaApp.java read_clipboard "public ClipReadRef readClipboard\("
check swift   bindings/swift/KayaApp.swift        read_clipboard "func readClipboard\("
check haskell bindings/haskell/KayaApp.hs         read_clipboard "^readClipboard ::"
check ocaml   bindings/ocaml/kaya_app.ml          read_clipboard "^let read_clipboard "

check rust    crates/kaya/src/app.rs              accepts "pub fn accepts\(self"
check python  bindings/python/kaya/__init__.py    accepts "def accepts\(self, \*kinds\)"
check go      bindings/go/app.go                  accepts "func \(w Widget\) Accepts\("
check csharp  bindings/csharp/KayaApp.cs          accepts "public void SetAccepts\("
check java    bindings/java/dev/kaya/KayaApp.java accepts "public Widget accepts\("
check swift   bindings/swift/KayaApp.swift        accepts "func setAccepts\("
check haskell bindings/haskell/KayaApp.hs         accepts "Accepts :: \[String\] -> Attr"
check ocaml   bindings/ocaml/kaya_app.ml          accepts "^let set_accepts "

check rust    crates/kaya/src/app.rs              on_paste "pub fn on_paste\("
check python  bindings/python/kaya/__init__.py    on_paste "def on_paste\(self, fn\)"
check go      bindings/go/app.go                  on_paste "func \(a \*App\) OnPaste\("
check csharp  bindings/csharp/KayaApp.cs          on_paste "public void OnPaste\("
check java    bindings/java/dev/kaya/KayaApp.java on_paste "public void onPaste\("
check swift   bindings/swift/KayaApp.swift        on_paste "func onPaste\("
check haskell bindings/haskell/KayaApp.hs         on_paste "^onPaste ::"
check ocaml   bindings/ocaml/kaya_app.ml          on_paste "^let on_paste "

# The menu construction surface (DESIGN.md, Menus): menu items are not
# widget kinds, so the constructor loop above cannot see them — every
# binding must spell the whole item vocabulary (menu, item/action,
# toggle, radio_group, option, separator) plus BOTH context anchors
# (the live-widget attach and the free catalog for template nodes).
# A binding shipping wire-only menus would pass every other gate until
# a guest failed to compile (failures-become-guards).
check_menus() {
    local lang="$1" file="$2"
    shift 2
    local point
    for point in "$@"; do
        check "$lang" "$file" "menus:${point%%=*}" "${point#*=}"
    done
}
# The menus clause's own negative test (guard-the-guard, the fake-kind
# pattern above): an item constructor that exists nowhere must fail in
# all 8 bindings THROUGH check_menus itself, or the clause's
# point-splitting has rotted. The subshell keeps the fake's failures
# out of $status; reset anyway, matching the kind self-test.
fake_menu_failures=$(
    {
        check_menus rust    crates/kaya/src/app.rs              "kayafakemenu=pub fn kayafakemenuitem\\("
        check_menus python  bindings/python/kaya/__init__.py    "kayafakemenu=^def kayafakemenuitem\\("
        check_menus go      bindings/go/app.go                  "kayafakemenu=func \\(m MenuItem\\) Kayafakemenuitem\\("
        check_menus csharp  bindings/csharp/KayaApp.cs          "kayafakemenu=public MenuItem Kayafakemenuitem\\("
        check_menus java    bindings/java/dev/kaya/KayaApp.java "kayafakemenu=public MenuItem kayafakemenuitem\\("
        check_menus swift   bindings/swift/KayaApp.swift        "kayafakemenu=func kayafakemenuitem\\("
        check_menus haskell bindings/haskell/KayaApp.hs         "kayafakemenu=^kayafakemenuitem ::"
        check_menus ocaml   bindings/ocaml/kaya_app.ml          "kayafakemenu=^let kayafakemenuitem "
    } 2>&1 | grep -c "no live-zone constructor"
)
if [ "$fake_menu_failures" -ne 8 ]; then
    echo "check-sugar-surface: menus self-test failed ($fake_menu_failures/8 patterns fired for a fake item constructor)"
    exit 1
fi

check_menus rust crates/kaya/src/app.rs \
    "menu=pub fn menu" "item=pub fn item\\(" "toggle=pub fn toggle\\(" \
    "radio_group=pub fn radio_group" "option=pub fn option\\(" \
    "separator=pub fn separator\\(" "context_menu=pub fn context_menu" \
    "context_catalog=pub fn context_catalog"
check_menus python bindings/python/kaya/__init__.py \
    "menu=^def menu\\(" "item=^def item\\(" "toggle=^def toggle\\(" \
    "radio_group=^def radio_group\\(" "option=^def option\\(" \
    "separator=^def separator\\(" "context_menu=def context_menu\\(self" \
    "context_catalog=^def context_catalog\\("
check_menus go bindings/go/app.go \
    "menu=func \\(w WindowRef\\) Menu\\(" "item=func \\(m MenuItem\\) Item\\(" \
    "toggle=func \\(m MenuItem\\) Toggle\\(" \
    "radio_group=func \\(w WindowRef\\) RadioGroup\\(" \
    "option=func \\(m MenuItem\\) Option\\(" \
    "separator=func \\(m MenuItem\\) Separator\\(" \
    "context_menu=func \\(tx \\*Tx\\) ContextMenu\\(" \
    "context_catalog=func \\(tx \\*Tx\\) ContextCatalog\\("
check_menus csharp bindings/csharp/KayaApp.cs \
    "menu=public MenuItem Menu\\(" "item=public MenuItem Item\\(" \
    "toggle=public MenuItem Toggle\\(" "radio_group=public MenuItem RadioGroup\\(" \
    "option=public MenuItem Option\\(" "separator=public MenuItem Separator\\(" \
    "context_menu=public void ContextMenu\\(" \
    "context_catalog=public ContextCatalog ContextCatalog\\("
check_menus java bindings/java/dev/kaya/KayaApp.java \
    "menu=public MenuItem menu\\(" "item=public MenuItem item\\(" \
    "toggle=public MenuItem toggle\\(" "radio_group=public MenuItem radioGroup\\(" \
    "option=public MenuItem option\\(" "separator=public void separator\\(" \
    "context_menu=public ContextRef contextMenu\\(" \
    "context_catalog=public ContextCatalog contextCatalog\\("
check_menus swift bindings/swift/KayaApp.swift \
    "menu=func menu\\(" "item=func item\\(" "toggle=func toggle\\(" \
    "radio_group=func radioGroup\\(" "option=func option\\(" \
    "separator=func separator\\(" "context_menu=func contextMenu\\(" \
    "context_catalog=func contextCatalog\\("
check_menus haskell bindings/haskell/KayaApp.hs \
    "menu=^menu ::" "item=^item ::" "toggle=^toggle ::" \
    "radio_group=^radioGroup ::" "option=^option ::" "separator=^separator ::" \
    "context_menu=^contextMenu ::" "context_catalog=^contextCatalog ::"
check_menus ocaml bindings/ocaml/kaya_app.ml \
    "menu=^let menu " "item=^let item " "toggle=^let toggle " \
    "radio_group=^let radio_group " "option=^let option " \
    "separator=^let separator " "context_menu=^let context_menu " \
    "context_catalog=^let context_catalog "

# EVERY WINDOW PROP NEEDS A SUGAR SPELLING TOO. The kinds sweep above
# has held since the sugar tier landed; window props had no equivalent,
# so an 8-way sweep of a new one was a matter of remembering. list_detail
# was swept by hand and nothing would have caught a missed language.
#
# Props come from the GENERATED wire file, so this tracks the spec by
# construction — a new WINDOW_PROPS entry lands here the moment the
# generators run. C is exempt for the same reason it is above: the
# floor spells every window prop with one generic
# kaya_tx_set_window_prop call plus the constant, on purpose.
wprops=$(grep -oE "^WPROP_[A-Z_]+" bindings/python/kaya/wire.py \
    | cut -c7- | tr "[:upper:]" "[:lower:]")
[ -n "$wprops" ] || { echo "check-sugar-surface: no window props in the generated wire file"; exit 1; }

for wprop in $wprops; do
    # snake_case for python/ocaml, camelCase for the rest, and
    # Haskell's W-prefixed attribute constructor.
    camel=$(python3 -c "
import sys
parts = sys.argv[1].split('_')
print(parts[0] + ''.join(p.capitalize() for p in parts[1:]))" "$wprop")
    pascal=$(python3 -c "
import sys
print(''.join(p.capitalize() for p in sys.argv[1].split('_')))" "$wprop")
    # WHOLE TOKENS, NOT SUBSTRINGS. The first cut of this sweep grepped
    # the bare name, and the styling fan-out watched that go vacuous in
    # real time: a Haskell negative that renamed WInset to WInsetXX
    # still satisfied /WInset/, so the perturbation proved nothing and
    # had to be redone as an outright deletion. `\b` holds both edges
    # (`_` is a word character, so a generated `tx_set_window_inset`
    # cannot stand in for the sugar's own `inset`).
    check python bindings/python/kaya/__init__.py "$wprop" "\b$wprop\b"
    # Go folds width and height into ONE Size(w, h) chain method, the
    # same flavor as Haskell's WSize below — surfaced by the \b
    # tightening, which is the proof the old substring match was passing
    # on an accident (exactly one bare `Width` existed in the file, and
    # it was not a constructor).
    case "$wprop" in
        width | height) go_pat="\bSize\b" ;;
        *) go_pat="\b$pascal\b" ;;
    esac
    check go bindings/go/app.go "$wprop" "$go_pat"
    check csharp bindings/csharp/KayaApp.cs "$wprop" "\b$camel\b"
    check java bindings/java/dev/kaya/KayaApp.java "$wprop" "\b$camel\b"
    check swift bindings/swift/KayaApp.swift "$wprop" "\b$camel\b"
    check ocaml bindings/ocaml/kaya_app.ml "$wprop" "\b$wprop\b"
    # Haskell carries width and height as ONE WSize constructor — a
    # language flavor, not a gap, exactly like the kind spellings above.
    case "$wprop" in
        width | height) hs="WSize" ;;
        *) hs="W$pascal" ;;
    esac
    check haskell bindings/haskell/KayaApp.hs "$wprop" "\b$hs\b"
done

# ─────────────────────────────────────────────────────────────────────
# THE STYLING SURFACE (docs/styling-plan.md, slice 1). Three points,
# and the sweeps above already hold one of them: `inset` is a
# WINDOW_PROPS entry, so the spec-derived window-prop loop demands its
# spelling in all eight by construction — its rows appeared the moment
# the generators ran. The other two are neither widget kinds nor window
# props, so nothing else in this file can see them, and each would
# otherwise be held by a ledger line and memory:
#
#   - `brand_accent` is a TRANSACTION verb, copy's shape: the set-once
#     identity write carrying the one seed hex. The per-appearance
#     override form rides the same base name (a sibling `_with`, keyword
#     arguments, optional labels — the idiom's call), so the patterns
#     key on the base name and the override form's uniformity is the
#     sweep verdict's business, not a ninth pattern's.
#   - `role` rides the WIDGET chain the way grow does, with the closed
#     vocabulary (destructive/prominent/heading) as a real enum type
#     wherever the language has one. The root's declare-time wall is
#     what refuses a misfit kind; the binding's job is only to spell
#     the request.
#
# A binding shipping either wire-only leaves apps in that language
# unable to brand or to say what a widget MEANS, and every other gate
# would pass — invariant 2's exact failure shape, one pass later.

# check_styling_point <point> <rust-re> <python-re> <go-re> <csharp-re>
#                     <java-re> <swift-re> <haskell-re> <ocaml-re>
check_styling_point() {
    local point="$1"
    check rust    crates/kaya/src/app.rs              "$point" "$2"
    check python  bindings/python/kaya/__init__.py    "$point" "$3"
    check go      bindings/go/app.go                  "$point" "$4"
    check csharp  bindings/csharp/KayaApp.cs          "$point" "$5"
    check java    bindings/java/dev/kaya/KayaApp.java "$point" "$6"
    check swift   bindings/swift/KayaApp.swift        "$point" "$7"
    check haskell bindings/haskell/KayaApp.hs         "$point" "$8"
    check ocaml   bindings/ocaml/kaya_app.ml          "$point" "$9"
}

# Its negative, the fake-kind pattern above: a point that exists
# nowhere must fail in all eight THROUGH check_styling_point itself,
# or its argument-splitting has rotted. The subshell keeps the fake's
# status=1 out of the real verdict.
fake_styling=$(check_styling_point kayafakestyling \
    'pub fn kayafakestyling\(' '^def kayafakestyling\(' \
    'func \(tx \*Tx\) Kayafakestyling\(' 'public void Kayafakestyling\(' \
    'public Widget kayafakestyling\(' 'func kayafakestyling\(' \
    '^kayafakestyling ::' '^let kayafakestyling ' 2>&1 \
    | grep -c "no live-zone constructor")
if [ "$fake_styling" -ne 8 ]; then
    echo "check-sugar-surface: styling self-test failed ($fake_styling/8 patterns" \
        "fired for a styling point that exists nowhere)"
    exit 1
fi
unset fake_styling

check_styling_point brand_accent \
    'pub fn brand_accent\(&mut self' \
    '^def brand_accent\(' \
    'func \(tx \*Tx\) BrandAccent\(' \
    'public void BrandAccent\(' \
    'public void brandAccent\(' \
    'func brandAccent\(' \
    '^brandAccent ::' \
    '^let brand_accent '

# THE BRAND TYPEFACE (Slice 2b), the accent's sibling and the same
# failure shape: a transaction verb no other sweep can see — not a
# widget kind, not a window prop — so a binding shipping it wire-only
# strands apps in that language unable to brand a family while every
# other gate passes. Same base-name rule as the accent: the
# per-platform/font-bytes form rides the base name (Rust's `_with`
# sibling, keyword arguments elsewhere), so one pattern per language
# and the override form's uniformity stays the sweep verdict's
# business.
check_styling_point brand_typeface \
    'pub fn brand_typeface\(&mut self' \
    '^def brand_typeface\(' \
    'func \(tx \*Tx\) BrandTypeface\(' \
    'public void BrandTypeface\(' \
    'public void brandTypeface\(' \
    'func brandTypeface\(' \
    '^brandTypeface ::' \
    '^let brand_typeface '

# THREE ROWS ARE KEYED PAST THE MENU ITEM'S ROLE, which shares the
# bare name: Rust's `role(self, role: MenuRole)`, Python's
# `def role(self, name)` on the item class and OCaml's `let item …
# ?role …` all predate this clause, and a bare-name pattern was
# satisfied by each before any widget sugar existed (caught by running
# the clause the day it was written — the OCaml template-grow lesson,
# one surface over). Rust is keyed on the widget enum's type, Python on
# the parameter name the way grow/a11y_hint are, OCaml on the
# constructor or the setter receiver — none of which the menu item's
# line can supply.
check_styling_point role \
    'pub fn role\(self, role: crate::Role\)' \
    'def role\(self, role\)' \
    'func \(w Widget\) Role\(' \
    'public void SetRole\(' \
    'public Widget role\(' \
    'func setRole\(' \
    'Role :: Role -> Attr' \
    'let (label|button) [^=]*\?role|let set_role \(Widget id\)'

# A SECTION INTO A NAMED WINDOW, in all eight. add_section grew up
# primary-only, and six bindings gained a window target while two kept
# the hardcoded 0 — which no gate swept, so the divergence surfaced
# only when the sidebar-coverage scene put sections in an aux window
# and Python and Haskell could not say so (2026-08-15, both proven
# through the apply stream: the records went silently to window 0).
# Idiom decides the spelling — a second name where there are no
# optional arguments, a window argument where there are — and each
# pattern is keyed on the window-carrying form, so the primary-only
# spelling cannot satisfy it — except Swift's and (since the symbol
# sugar wrapped it, 2026-08-16) Python's, whose signatures put the
# window parameter past a line break where a line-based grep cannot
# key on it; those rows pin the wrapped signature's own first line and
# the GUESTS hold the parameter (both sections guests call with
# window=/window:).
check_styling_point 'sectioned aux window' \
    'pub fn add_section_in\(' \
    'def add_section\(self, section_id, title=None, symbol=None,' \
    'func \(tx \*Tx\) AddSectionIn\(' \
    'AddSection\([^)]*window' \
    'public SectionRef addSectionIn\(|addSectionIn\(' \
    'func addSection\(' \
    '^addSectionIn ::' \
    'add_section \?\(window'

# THE CONTAINER INSET (docs/styling-plan.md D3 one level down, landed
# 2026-08-12 — the prop the full-bleed editor forced). EVERY ROW IS
# KEYED PAST ITS WINDOW-INSET TWIN, which shares the bare name in all
# eight: the window's spelling rides the window construct and the
# container's rides the widget chain beside grow, so the receiver or
# the parameter is what tells them apart — the menu-role lesson, one
# prop over.
check_styling_point 'container inset' \
    'pub fn inset\(&mut self, widget: WidgetId' \
    'def inset\(self, pad\)' \
    'func \(w Widget\) Inset\(' \
    'public void SetInset\(' \
    'public Widget inset\(' \
    'func setInset\(' \
    'Inset :: Double -> Attr' \
    'let set_inset \(Widget id\)|let (row|column|grid) [^=]*\?inset'

# EVERY WINDOW HANDLER NEEDS A CONSTRUCT SPELLING TOO — AND NO LOOSE
# ONE. The props above are half of the window construct; its HANDLERS
# are the other half, and nothing swept them. That is how the undo
# fan-out shipped an app-global `OnUndone(window, fn)` in three
# bindings (Go, Java, Haskell) by transcribing Rust's Messages shape,
# while the other five already carried the pair on the window
# construct: a violation of the ratified rule that NO WINDOW ATTRIBUTE
# LIVES AS A LOOSE FUNCTION OUTSIDE THE CONSTRUCT (DESIGN.md, Binding
# conventions), found by eye on 2026-08-04 and by no gate. `window_title`
# was the first arrival of that pattern; this was the second.
#
# So the sweep runs BOTH directions, because only the pair states the
# rule: the construct must spell the handler in every binding, and
# nothing outside the construct may.
#
# WHERE THE LIST COMES FROM. Two bindings declare the window construct's
# attribute set as a CLOSED SYNTACTIC OBJECT, so "what the construct
# carries" is a fact about a file rather than a judgement made here:
# Haskell's `data WindowAttr` (a sum whose WOn* constructors ARE its
# handlers) and OCaml's `let window` (a labelled-argument list whose
# ?on_* arguments are the same set). The list is the UNION of the two —
# a handler EITHER of them claims is one every binding owes a spelling
# for, and the two sources disagreeing needs no special report because
# the sweep itself then names the one that is behind, in the same words
# it uses for the other six. Today the union is four: close_requested,
# closed, undone, redone.
#
# ADDING A NEW WINDOW HANDLER therefore means spelling it in Haskell's
# WindowAttr or OCaml's window, at which point this sweep demands the
# other seven spellings and refuses the loose one. The gate is red for
# the rest of the fan-out — that is the hold-open pattern, not a
# regression. Nobody edits a list here.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

WH_PY=bindings/python/kaya/__init__.py
WH_GO=bindings/go/app.go
WH_CS=bindings/csharp/KayaApp.cs
WH_JA=bindings/java/dev/kaya/KayaApp.java
WH_SW=bindings/swift/KayaApp.swift
WH_HS=bindings/haskell/KayaApp.hs
WH_ML=bindings/ocaml/kaya_app.ml

whandlers=$(python3 - "$WH_HS" "$WH_ML" <<'PY'
import re
import sys

hs, ml = sys.argv[1], sys.argv[2]
read = lambda p: open(p, encoding="utf-8").read()


def snake(name):
    return re.sub(r"(?<!^)([A-Z])", r"_\1", name).lower()


# Haskell: the WOn* constructors of `data WindowAttr`, which runs to the
# next column-0 line. A constructor is the first thing on its line (the
# haddock comments between them start with --), so a mention inside a
# comment cannot invent a handler.
text = read(hs)
m = re.search(r"^data WindowAttr\b.*?(?=\n\S)", text, re.S | re.M)
if not m:
    sys.exit(f"{hs}: no `data WindowAttr` block — the window construct's "
             "attribute set moved and this sweep would go vacuous")
from_hs = [snake(c) for c in
           re.findall(r"^[ \t]*(?:[=|][ \t]*)?WOn([A-Za-z]+)\b", m.group(0), re.M)]

# OCaml: the ?on_* labelled arguments of `let window`, up to the `=`
# that ends its header.
text = read(ml)
m = re.search(r"^let window\b.*?=\n", text, re.S | re.M)
if not m:
    sys.exit(f"{ml}: no `let window` construct — the window construct's "
             "attribute set moved and this sweep would go vacuous")
from_ml = re.findall(r"\?on_([a-z_]+)", m.group(0))

union = sorted(set(from_hs) | set(from_ml))
# THE ANTI-VACUITY FLOOR. A derived list that goes empty sweeps nothing
# and passes everything, and the union only empties if BOTH declarations
# drop a handler — a deliberate two-language retirement, which is the
# one case where a shrinking list is right. The close pair is the floor
# because it predates every other window handler and is the construct's
# oldest content: if it ever leaves BOTH, this gate is reading the wrong
# thing and has to be re-derived rather than quietly agree with what is
# left.
missing = [h for h in ("close_requested", "closed") if h not in union]
if missing:
    sys.exit(f"the window construct no longer carries {missing} in either {hs} "
             f"or {ml} — this sweep derives its list from that construct, so it "
             "has to be re-derived rather than pass on what is left")
print(" ".join(union))
PY
)
wh_rc=$?
if [ "$wh_rc" -ne 0 ]; then
    echo "check-sugar-surface: FAIL (no window-handler list)"
    exit 1
fi

# RUST'S CARVE-OUT IS PINNED POSITIVELY rather than left as a hole:
# `Messages::on_*(WindowId, …)` is the sanctioned Rust form, because a
# Rust handler is a MESSAGE VALUE in a table the transaction cannot
# reach — there is nowhere else for it to live. Pinning it means a
# future "fix" that moves the four onto WindowRef goes red here and gets
# decided on purpose instead of drifting.
#
# The pin reads the `impl<M> Messages<M>` block with its signatures
# collapsed onto one line (rustfmt wraps them and grep is line-based)
# and its comments dropped, so a doc comment cannot satisfy it. A
# missing anchor FAILS rather than going quiet: a gate that stops
# finding what it reads reports a clean bill about nothing.
python3 - crates/kaya/src/app.rs "$T/rust-messages.txt" <<'PY'
import sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
i = text.find("impl<M> Messages<M> {")
if i < 0:
    sys.exit(f"{src}: no `impl<M> Messages<M>` block — Rust's sanctioned "
             "handler form moved and this pin went vacuous")
j = text.find("\nimpl ", i + 1)
region = text[i:j if j > 0 else len(text)]
code = [ln for ln in region.split("\n") if not ln.strip().startswith("//")]
open(dst, "w", encoding="utf-8").write(" ".join(" ".join(code).split()) + "\n")
PY
rust_rc=$?
if [ "$rust_rc" -ne 0 ]; then
    echo "check-sugar-surface: FAIL (Rust's Messages block could not be read)"
    exit 1
fi

# AND THE FOUR ARGUMENT-LIST BINDINGS ARE READ BY REGION, NOT BY FILE.
# Python, C#, Swift and OCaml spell a window's attributes as arguments,
# and they spell them TWICE — once on the primary window's construct and
# once on the auxiliary's — where DESIGN.md says the two take EXACTLY
# the same set. A whole-file grep cannot tell those apart: a handler
# dropped from `window` while `create_window` keeps it still matches
# somewhere in the file, and the first cut of this sweep passed a tree
# doctored exactly that way (measured while writing it, 2026-08-04). So
# each construct's header is extracted and swept on its own.
#
# The other four bindings need no extraction because their construct is
# a TYPE rather than an argument list — Go's and Java's WindowRef chain,
# Haskell's WindowAttr, Rust's Messages — so one spelling serves both
# windows and the receiver is what names the construct.
python3 - "$T" "$WH_PY" "$WH_CS" "$WH_SW" "$WH_ML" <<'PY'
import re
import sys

T, py, cs, sw, ml = sys.argv[1:6]


def paren_region(path, anchor):
    """The construct's header: from the anchor to the matching close of
    its parameter list. Nested parens are counted, since a Swift closure
    parameter carries its own."""
    text = open(path, encoding="utf-8").read()
    m = re.search(anchor, text, re.M)
    if not m:
        sys.exit(f"{path}: no window construct matching /{anchor}/ — the "
                 "construct moved and this sweep would go vacuous")
    i = text.index("(", m.start())
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "(":
            depth += 1
        elif text[j] == ")":
            depth -= 1
            if depth == 0:
                return text[m.start():j + 1]
    sys.exit(f"{path}: the construct's parameter list at /{anchor}/ never closes")


def let_region(path, anchor):
    """OCaml's labelled arguments have no brackets: the header runs to
    the `=` that ends its line."""
    text = open(path, encoding="utf-8").read()
    m = re.search(anchor + r"\b.*?=\n", text, re.S | re.M)
    if not m:
        sys.exit(f"{path}: no window construct matching /{anchor}/ — the "
                 "construct moved and this sweep would go vacuous")
    return m.group(0)


for name, body in (
    ("python-window", paren_region(py, r"^    def window\(self")),
    ("python-create-window", paren_region(py, r"^    def create_window\(self")),
    ("csharp-window", paren_region(cs, r"^    public void Window\(")),
    ("csharp-create-window", paren_region(cs, r"^    public void CreateWindow\(")),
    ("swift-window", paren_region(sw, r"^    func window\(")),
    ("swift-create-window", paren_region(sw, r"^    func createWindow\(")),
    ("ocaml-window", let_region(ml, r"^let window")),
    ("ocaml-create-window", let_region(ml, r"^let create_window")),
):
    open(f"{T}/{name}.txt", "w", encoding="utf-8").write(body + "\n")
PY
region_rc=$?
if [ "$region_rc" -ne 0 ]; then
    echo "check-sugar-surface: FAIL (a window construct's header could not be read)"
    exit 1
fi

# want <language> <file> <handler> <regex> [<file to name in the message>]
want() {
    if ! grep -qE "$4" "$2"; then
        echo "check-sugar-surface: $1 has no window-construct spelling for the" \
            "'$3' handler (wanted /$4/ in ${5:-$2})"
        status=1
    fi
}

# deny <language> <file> <handler> <regex> — want's mirror.
deny() {
    if grep -qE "$4" "$2"; then
        echo "check-sugar-surface: $1 spells the '$3' window handler as a LOOSE" \
            "app-global registration (found /$4/ in $2) — a window's attributes" \
            "ride its window construct (DESIGN.md, Binding conventions)"
        status=1
    fi
}

# swift_one_door <construct argument> <KayaApp registrar> <file>
#
# SWIFT IS THE ONE BINDING WHERE "no such function exists" CANNOT BE THE
# RULE, and the carve-out is stated rather than implied. KayaApp's
# handler tables are `private`, so KayaAppTx — a different type in the
# same file — cannot write them, and the construct reaches them through
# a KayaApp method that DOES take a window id. Six bindings need no such
# method (their construct writes the table itself) and Rust's IS the
# sanctioned form, so Swift's is pinned as ONE DOOR instead: called
# exactly once, from the construct, with the construct's own argument.
# A second callsite is a second door, and a guest holds the KayaApp.
swift_one_door() {
    local doors construct
    doors=$(grep -cE "app\.$2\(" "$3")
    construct=$(grep -cE "app\.$2\(id, $1\)" "$3")
    if [ "$doors" -ne 1 ] || [ "$construct" -ne 1 ]; then
        echo "check-sugar-surface: swift's app.$2 is not the window construct's" \
            "ONE DOOR ($doors callsite(s) in $3, $construct of them the" \
            "construct's — want 1 and 1)"
        status=1
    fi
}

# check_window_handler <handler>: the construct spells it, in all eight.
check_window_handler() {
    local h="$1"
    local pascal rust_name swift_app
    # ONE conversion, and every non-snake spelling is built from it:
    # "close_requested" -> "CloseRequested", so the handler is `on` plus
    # that in six bindings and `On` plus it in Go. A camelCase of the
    # handler alone would read `onundone` for a one-word handler and
    # `onCloseRequested` for a two-word one — the same pattern quietly
    # right in one case and wrong in the other, which is what the
    # perturbation self-test below caught when this was written.
    pascal=$(python3 -c "
import sys
print(''.join(p.capitalize() for p in sys.argv[1].split('_')))" "$h")
    # Two spelling flavors get named here, the way width and height share
    # Haskell's one WSize constructor above — a language's flavor, not a
    # gap. Rust's Messages is app-global, so its closed handler has to
    # say WHICH kind of closed it means; Swift's KayaApp-level plumbing
    # follows the same name, while the construct's argument is onClosed.
    case "$h" in
        closed) rust_name="on_window_closed" swift_app="onWindowClosed" ;;
        *) rust_name="on_$h" swift_app="on$pascal" ;;
    esac
    want rust "$T/rust-messages.txt" "$h" "pub fn $rust_name\( *&self, window: WindowId" \
        "crates/kaya/src/app.rs (impl<M> Messages<M>)"
    want go "$WH_GO" "$h" "func \(w WindowRef\) On$pascal\("
    want java "$WH_JA" "$h" "public WindowRef on$pascal\("
    # Haskell's constructor has to be in CONSTRUCTOR POSITION — first on
    # its line, after an optional = or | — so a haddock comment naming
    # one cannot stand in for declaring it.
    want haskell "$WH_HS" "$h" "^[[:space:]]*([=|][[:space:]]*)?WOn$pascal \("
    # The argument-list four, each construct read on its own: the
    # primary's set and the auxiliary's are the same set or one of them
    # is wrong (DESIGN.md, Binding conventions).
    want python "$T/python-window.txt" "$h" "[ (,]on_$h=None" "$WH_PY (App.window)"
    want python "$T/python-create-window.txt" "$h" "[ (,]on_$h=None" \
        "$WH_PY (App.create_window)"
    want csharp "$T/csharp-window.txt" "$h" "\? on$pascal = null" "$WH_CS (Tx.Window)"
    want csharp "$T/csharp-create-window.txt" "$h" "\? on$pascal = null" \
        "$WH_CS (Tx.CreateWindow)"
    want swift "$T/swift-window.txt" "$h" "^ +on$pascal: \(\(KayaAppTx" \
        "$WH_SW (KayaAppTx.window)"
    want swift "$T/swift-create-window.txt" "$h" "^ +on$pascal: \(\(KayaAppTx" \
        "$WH_SW (KayaAppTx.createWindow)"
    want ocaml "$T/ocaml-window.txt" "$h" "\?on_${h}[ )]" "$WH_ML (window)"
    want ocaml "$T/ocaml-create-window.txt" "$h" "\?on_${h}[ )]" "$WH_ML (create_window)"
    swift_one_door "on$pascal" "$swift_app" "$WH_SW"
}

# deny_loose <handler> <python> <go> <csharp> <java> <haskell> <ocaml>
#
# The paths are ARGUMENTS rather than the constants above because the
# self-test runs this clause against DOCTORED COPIES OF THE REAL FILES;
# a rule about six fixed paths could never be watched failing, and a
# clause nobody has seen fail is worse than none — it stops you looking.
deny_loose() {
    local h="$1" pyf="$2" gof="$3" csf="$4" jaf="$5" hsf="$6" mlf="$7"
    local pascal
    pascal=$(python3 -c "
import sys
print(''.join(p.capitalize() for p in sys.argv[1].split('_')))" "$h")
    # Each pattern is that language's shape of a registration THE APP
    # REACHES WITH A WINDOW ID IN HAND — the thing a construct-scoped
    # handler makes unnecessary, and the exact shape Go, Java and
    # Haskell shipped. Python, OCaml and Haskell have the simplest rule
    # (the top-level definition itself: a construct spelling is a
    # keyword argument, a labelled argument and a constructor there, so
    # a function of that name can only be the loose one). Go's is a
    # method on the app or the transaction, or a package-level function
    # — the three places a Go registrar can live, the binding having no
    # fourth. C# and Java are keyed on the DECLARATION rather than on
    # the window parameter alone, because a wrapped signature puts the
    # parameters on the next line while the name and its paren stay
    # together: any `OnUndone(` declaration is loose in C# (the
    # construct is a named argument, spelled lowercase), and in Java the
    # construct returns WindowRef to chain, so a `void onUndone(` is
    # the loose one by its return type.
    deny python "$pyf" "$h" "^ *def on_$h\("
    deny go "$gof" "$h" "^func (\([a-z]+ \*(App|Tx)\) )?On$pascal\("
    deny csharp "$csf" "$h" "[A-Za-z>?] On$pascal\("
    deny java "$jaf" "$h" "(void on$pascal\(|[ .(]on$pascal\(long )"
    deny haskell "$hsf" "$h" "^on$pascal ::"
    deny ocaml "$mlf" "$h" "^let on_${h}[ (]"
}

# The built-in negative test, the fake-kind pattern above: a handler
# that exists nowhere must fail in every binding, or the patterns have
# rotted. The fake runs inside $( ), so its `status=1` dies with that
# subshell and the real run's status is untouched — no reset here,
# deliberately (see the kind self-test's note).
fake_wh=$(check_window_handler kayafakehandler 2>&1)
fake_wh_wants=$(printf '%s\n' "$fake_wh" | grep -c "no window-construct spelling")
fake_wh_doors=$(printf '%s\n' "$fake_wh" | grep -c "ONE DOOR")
# Twelve, not eight: the four argument-list bindings are read once per
# construct (the primary's and the auxiliary's).
if [ "$fake_wh_wants" -ne 12 ] || [ "$fake_wh_doors" -ne 1 ]; then
    echo "check-sugar-surface: window-handler self-test failed" \
        "($fake_wh_wants/12 construct patterns and $fake_wh_doors/1 door clause" \
        "fired for a handler that exists nowhere)"
    exit 1
fi

# AND THE LOOSE-SPELLING CLAUSE IS WATCHED FAILING, on DOCTORED COPIES
# OF THE REAL FILES rather than synthetic samples: a fixture only ever
# proves the pattern matches the fixture, which is how the wayland seat
# guard passed VACUOUSLY TWICE (docs/traps.md). Every perturbation
# prints its substitution count and is refused if it did not apply — an
# unchanged copy is a FAILED self-test, not a passed one — and every
# refusal is checked for its REASON, since a non-empty complaint is
# satisfied by any unrelated finding.

# <source> <regex> <replacement> <destination> -> substitution count
perturb() {
    python3 -c '
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
out, n = re.subn(sys.argv[2], sys.argv[3], text, flags=re.M)
open(sys.argv[4], "w", encoding="utf-8").write(out)
print(n)
' "$@"
}

wh_applied=""
applied() { # count label
    if [ "$1" -ge 1 ]; then
        wh_applied="$wh_applied $2=$1"
        return 0
    fi
    echo "check-sugar-surface: SELF-TEST FAIL ($2 applied $1 times, want at" \
        "least 1 — an unchanged copy cannot prove the rule fires)" >&2
    exit 1
}

# <handler> <python> <go> <csharp> <java> <haskell> <ocaml> <want-fragment> <label>
refuses_loose() {
    local out
    out=$(deny_loose "$1" "$2" "$3" "$4" "$5" "$6" "$7" 2>&1)
    case "$out" in
        *"$8"*) ;;
        *)
            echo "check-sugar-surface: SELF-TEST FAIL ($9 was not refused for" \
                "its own reason: ${out:-no output at all})" >&2
            exit 1
            ;;
    esac
}

hits=$(perturb "$WH_PY" '^class App:$' \
    'def on_undone(window_id, fn):\n    pass\n\n\nclass App:' "$T/python-loose.py")
applied "$hits" python
refuses_loose undone "$T/python-loose.py" "$WH_GO" "$WH_CS" "$WH_JA" "$WH_HS" "$WH_ML" \
    "python spells the 'undone' window handler" "a python binding with a loose on_undone"

hits=$(perturb "$WH_GO" '^package kaya$' \
    'package kaya\n\nfunc (a *App) OnUndone(window uint64, fn func(*Tx, string, UndoDelta)) {}' \
    "$T/go-loose.go")
applied "$hits" go
refuses_loose undone "$WH_PY" "$T/go-loose.go" "$WH_CS" "$WH_JA" "$WH_HS" "$WH_ML" \
    "go spells the 'undone' window handler" "the Go shape the fan-out actually shipped"

# The same clause on a MULTI-WORD handler and on Go's OTHER shape: the
# pattern is built from the derived name, so one that came out wrong
# would still fire on `undone` and never on `close_requested` (that is
# not hypothetical — a camelCase slip did exactly this while the sweep
# was being written), and the receiver-less branch would never fire at
# all if only a method were ever planted.
hits=$(perturb "$WH_GO" '^package kaya$' \
    'package kaya\n\nfunc OnCloseRequested(a *App, window uint64, fn func(*Tx)) {}' \
    "$T/go-loose-close.go")
applied "$hits" go-close-requested
refuses_loose close_requested "$WH_PY" "$T/go-loose-close.go" "$WH_CS" "$WH_JA" "$WH_HS" "$WH_ML" \
    "go spells the 'close_requested' window handler" "a Go binding with a loose OnCloseRequested"

hits=$(perturb "$WH_CS" '^sealed class KayaApp\n\{$' \
    'sealed class KayaApp\n{\n    public void OnUndone(ulong window, Action<Tx, string, UndoDelta> fn) { undone[window] = fn; }' \
    "$T/csharp-loose.cs")
applied "$hits" csharp
refuses_loose undone "$WH_PY" "$WH_GO" "$T/csharp-loose.cs" "$WH_JA" "$WH_HS" "$WH_ML" \
    "csharp spells the 'undone' window handler" "a C# binding with a loose OnUndone"

hits=$(perturb "$WH_JA" '^public final class KayaApp \{$' \
    'public final class KayaApp {\n    public void onUndone(long window, UndoHandler handler) { undone.put(window, handler); }' \
    "$T/java-loose.java")
applied "$hits" java
refuses_loose undone "$WH_PY" "$WH_GO" "$WH_CS" "$T/java-loose.java" "$WH_HS" "$WH_ML" \
    "java spells the 'undone' window handler" "the Java shape the fan-out actually shipped"

hits=$(perturb "$WH_HS" '^undoableTx :: App -> String -> Build a -> IO a$' \
    'onUndone :: App -> Word64 -> (String -> UndoDelta -> IO ()) -> IO ()\nonUndone _ _ _ = return ()\n\nundoableTx :: App -> String -> Build a -> IO a' \
    "$T/haskell-loose.hs")
applied "$hits" haskell
refuses_loose undone "$WH_PY" "$WH_GO" "$WH_CS" "$WH_JA" "$T/haskell-loose.hs" "$WH_ML" \
    "haskell spells the 'undone' window handler" "the Haskell shape the fan-out actually shipped"

hits=$(perturb "$WH_ML" '^let destroy_window id =' \
    'let on_undone _window _f = ()\n\nlet destroy_window id =' "$T/ocaml-loose.ml")
applied "$hits" ocaml
refuses_loose undone "$WH_PY" "$WH_GO" "$WH_CS" "$WH_JA" "$WH_HS" "$T/ocaml-loose.ml" \
    "ocaml spells the 'undone' window handler" "an OCaml binding with a loose on_undone"

# AND SWIFT'S ONE-DOOR CLAUSE FAILS ON A SECOND DOOR, not only on none:
# the fake handler above proves it fires at zero callsites, which is the
# same comparison from the other side but not the case it exists for.
hits=$(perturb "$WH_SW" '^        if let onUndone \{ app\.onUndone\(id, onUndone\) \}$' \
    '        if let onUndone { app.onUndone(id, onUndone) }\n        app.onUndone(1, onUndone!)' \
    "$T/swift-two-doors.swift")
applied "$hits" swift-second-door
door_out=$(swift_one_door onUndone onUndone "$T/swift-two-doors.swift" 2>&1)
case "$door_out" in
    *"ONE DOOR"*) ;;
    *)
        echo "check-sugar-surface: SELF-TEST FAIL (a second Swift callsite was" \
            "not refused: ${door_out:-no output at all})" >&2
        exit 1
        ;;
esac
echo "check-sugar-surface: window-handler perturbations applied:$wh_applied" >&2

for whandler in $whandlers; do
    check_window_handler "$whandler"
    deny_loose "$whandler" "$WH_PY" "$WH_GO" "$WH_CS" "$WH_JA" "$WH_HS" "$WH_ML"
done

# THE C FLOOR IS EXEMPT, AND THE EXEMPTION IS CHECKED — an exemption is
# not an implementation (check-roles' rule, from the other side). C
# registers nothing at all: a guest reads the occurrence record's head
# and matches on it, which is the floor's documentation of what every
# other binding's handler table is doing. What makes that honest rather
# than convenient is that the header declares NO handler registrar of
# any kind, so a `kaya_app_on_undone` arriving one day fails here
# instead of quietly making C the ninth binding with a loose spelling.
deny c bindings/c/kaya_wire.h "any window handler" "kaya_[a-z_]*_on_[a-z_]+\("

# ─────────────────────────────────────────────────────────────────────
# THE SCENE TIER: THE SAME RULE, READ FROM THE OTHER SIDE.
#
# Everything above asks whether a BINDING OFFERS the sugar. Nothing
# asked whether the EXAMPLES USE IT, which is invariant 5 (CLAUDE.md:
# all example scenes use each language's sugar tier; only the C guests
# keep the explicit floor, deliberately, as the floor's documentation).
# That invariant was a matter of memory, and the two carve-out scenes
# are what the memory cost: entry and milestone2 sat at the whole-file
# explicit floor in eight languages for five milestones — widget-kind
# constructors, add_child chains, bind_element by index — because their
# EVENT mechanism is deliberately the raw tier and nobody separated the
# two halves. Every reader who noticed reasoned "that is the explicit
# scene" and moved on. The maintainer ratified the split on 2026-08-05
# (DESIGN.md, "SCOPE, ratified 2026-08-05"): the carve-out covers the
# EVENT-RECEIVING mechanism ONLY, and construction follows the same
# sugar rule as every other example.
#
# So this clause reads both halves of that ratification, for BOTH
# scenes the carve-out names:
#   (a) no entry and no milestone2 guest spells CONSTRUCTION at the
#       floor, in any of the eight bindings; and
#   (b) both rust guests still spell their EVENTS as the raw
#       `ctx.next()` loop. THE CARVE-OUT IS CHECKED, NOT ASSUMED — a
#       later session "finishing the job" by folding them onto
#       kaya::Messages would delete the only guests that document the
#       tier Messages is built on, and this says so out loud instead of
#       leaving it to a reviewer's eye.
#
# THE PATTERNS ARE DERIVED FROM WHAT EACH FILE ACTUALLY SAID, not from
# what a floor might look like: every regex below matched
# guests/<lang>/<scene>.* at that scene's pre-graduation revision and
# matches nothing in the graduated one.
#
# A THIRD SCENE JOINS BY ADDING ROWS AND NOTHING ELSE: one to
# scene_facts (its expected string, its script, the line the self-test
# plants after) and one per language to scene_guests. Every loop below
# — the clause itself, the planted-snippet self-test, the raw-loop pin,
# the anti-vacuity negative — sweeps those two tables, so a scene that
# joins arrives checked AND self-tested without surgery here.

# <scene> <the expected string every guest carries> <its script> <the
# line the self-test plants its floor snippets after>
#
# THE EXPECTED STRING IS THE ANTI-VACUITY ANCHOR. Frozen by invariant 6
# and byte-identical in all eight languages by invariant 6's whole
# point, so a guest that was renamed, moved or emptied fails loudly
# here instead of satisfying every denial below by having nothing in
# it.
scene_facts=(
    entry 'nothing to add, ' tools/scenes/entry.steps '^(.*no todos.*)$'
    milestone2 '"step 0"' tools/scenes/milestone2.steps '^(.*"step 0".*)$'
)

# <scene> <language> <the guest this clause reads>
#
# THE GO ROWS NAME <scene>/<scene>.go, which is the scene ITSELF: one
# directory per scene, package named for it, App() handing back a built
# app. They briefly named guests/go/scenes/<scene>/ instead, and before
# that guests/go/<scene>/main.go — which for a while was a six-line
# desktop tail with no construction in it at all, so a row left pointing
# there would have read a file that cannot spell the floor and passed
# for the emptiest possible reason. The tails all live in
# guests/go/cmd now and no scene row may name that directory.
scene_guests=(
    entry rust guests/rust/entry.rs
    entry python guests/python/entry.py
    entry go guests/go/entry/entry.go
    entry csharp guests/csharp/EntryScene.cs
    entry java guests/java/dev/kaya/milestone2kt/Entry.java
    entry swift guests/swift/entry.swift
    entry haskell guests/haskell/entry.hs
    entry ocaml guests/ocaml/entry.ml

    milestone2 rust guests/rust/milestone2.rs
    milestone2 python guests/python/milestone2.py
    milestone2 go guests/go/milestone2/milestone2.go
    milestone2 csharp guests/csharp/Milestone2Scene.cs
    milestone2 java guests/java/dev/kaya/milestone2kt/Milestone2.java
    milestone2 swift guests/swift/milestone2.swift
    milestone2 haskell guests/haskell/milestone2.hs
    milestone2 ocaml guests/ocaml/milestone2.ml
)

# scene_fact <scene> — that scene's three facts, into fact_anchor,
# fact_steps and fact_plant.
#
# GLOBALS RATHER THAN A `$( )`: a command substitution runs in a
# subshell, where the `exit 1` for a scene missing from the table would
# kill only that subshell and hand the caller an EMPTY anchor — and an
# empty anchor is matched by every file, which is the exact vacuity
# this clause exists to refuse.
fact_anchor=""
fact_steps=""
fact_plant=""
scene_fact() {
    local i
    for ((i = 0; i < ${#scene_facts[@]}; i += 4)); do
        if [ "${scene_facts[i]}" = "$1" ]; then
            fact_anchor="${scene_facts[i + 1]}"
            fact_steps="${scene_facts[i + 2]}"
            fact_plant="${scene_facts[i + 3]}"
            return 0
        fi
    done
    echo "check-sugar-surface: the scene table has no facts for '$1' — a scene" \
        "joins with ONE scene_facts row (its expected string, its script, the" \
        "line the self-test plants after) and one scene_guests row per language" >&2
    exit 1
}

# HASKELL'S GENERIC CONSTRUCTOR IS DENIED PER KIND, and the kind list
# is the GENERATED one this file already reads at the top, so a kind
# added to the spec is denied here without anyone editing a list.
# HISTORY: this clause shipped with `kindEntry` and `kindButton`
# exempted, because the sugar then had no handler-free leaf
# constructors and entry.hs (which registers centrally) had no other
# way to build those two widgets. The binding grew `entry` and
# `button` the same day (2026-08-05, the one hole of its kind among
# the eight bindings) and the exemption was dropped as the original
# comment here instructed — the guest now builds every leaf in the
# sugar and the denial is total.
hs_kinds=$(python3 -c "
import sys

kinds = sys.argv[1].split()
if not kinds:
    sys.exit('no widget kinds reached the haskell clause — it would be vacuous')
pascal = [k[0].upper() + k[1:] for k in kinds]
print('|'.join(pascal), pascal[0])
" "$kinds")
hs_rc=$?
if [ "$hs_rc" -ne 0 ]; then
    echo "check-sugar-surface: FAIL (no haskell kind list for the scene clause)"
    exit 1
fi
hs_alt="${hs_kinds%% *}"
hs_first="${hs_kinds##* }"

# THE FLOOR VOCABULARY, FIVE FIELDS PER ROW: the SCENES the row guards,
# the language, what the spelling IS, the regex that finds it, and A
# LINE OF THAT LANGUAGE'S FLOOR THAT MUST TRIP IT. The last field is
# not decoration. The self-test below plants every one of a language's
# snippets in a copy of its real guest — ONCE PER SCENE THE ROW GUARDS
# — and requires the clause to name every row, naming the scene it
# found it in. So each regex here is watched finding something in every
# file it speaks about, and a pattern cannot be added without a line
# proving it fires. A guard nobody has seen fail is worse than none: it
# stops you looking (docs/traps.md).
#
# THE FIRST FIELD IS "*" FOR ALL SCENES, which is what a floor spelling
# normally is: `add_child` is the floor wherever it appears. One pair of
# rows is scene-specific, for a reason written where it stands.
scene_rules=(
    "*" rust "widget-kind construction" '\.widget\(WidgetKind::' \
        '        let column = tx.widget(WidgetKind::Column);'
    "*" rust "the add_child chain" '\.add_child\(' \
        '        tx.add_child(column, field);'
    "*" rust "generic prop writes" 'Prop::' \
        '        tx.set(add, Prop::Text, "add");'
    "*" rust "the for_each combinator" '\.for_each\(' \
        '        let (todo_list, ()) = tx.for_each(&todos, |t| {});'
    "*" rust "bind_element by index" '\.bind_element\(' \
        '        t.bind_element(label, Prop::Text, 0);'

    # PYTHON HAS NO WIDGET-KIND FLOOR TO LEAVE: its public surface has
    # only ever been the sugar (the kind constructors call a private
    # _widget), which is why its entry guest's graduation was the key
    # counter alone. The clause is written anyway, and written the way
    # the C exemption above is — as a rule about what must NOT ARRIVE.
    # `kaya.for_each` is real today (feed.py needs the target for a
    # variant collection) and is the tier below the `for` statement
    # this scene traces with; the other two name spellings the binding
    # does not export, so a floor arriving one day fails here instead
    # of landing in an example first.
    "*" python "the for_each combinator" 'kaya\.for_each\(' \
        '    with kaya.for_each(todos) as todo:'
    "*" python "the add_child chain" '\.add_child\(' \
        '    column.add_child(field)'
    "*" python "bind_element by index" '\.bind_element\(' \
        '    label.bind_element(0)'

    "*" go "widget-kind construction" '\.Widget\(' \
        '        column := tx.Widget(kaya.KindColumn)'
    # THE SetText/setText/set_text ROWS ARE GONE, RETIRED BY RENAME, and
    # the mechanism is worth the note: in six languages the template
    # PROP WRITE and the set_text WIDGET VERB (which check_range_verb
    # REQUIRES as sugar) shared one name, so no pattern could fail the
    # floor use without failing the verb — the receiver's TYPE decides
    # and no regex sees a type. The props pass gave those six Rust's
    # split instead: the template write is hidden (Go/C#/Java/Swift:
    # unexported/private — the wall is now the compiler) or renamed
    # (Haskell setTextProp, OCaml Tpl.Floor.*), and the renamed
    # spellings are swept repo-wide by tools/guest-floor.py. A row here
    # would either never fire (the hidden ones) or fire on the verb
    # (the one thing it must not), so the rows are gone rather than
    # weakened (docs/tpl-props-plan.md F3).
    "*" go "the generic BindText" '\.BindText\(' \
        '        tx.BindText(statusLabel, status)'
    "*" go "the ForEach combinator" '\.ForEach\(' \
        '        todoList := tx.ForEach(todos, nil)'
    "*" go "BindTextElement by index" '\.BindTextElement\(' \
        '        t.BindTextElement(label, 0)'
    "*" go "the AddChild chain" '\.AddChild\(' \
        '        tx.AddChild(column, field)'

    "*" csharp "widget-kind construction" '\.Widget\(' \
        '            var column = tx.Widget(KayaWire.KindColumn);'
    "*" csharp "the generic BindText" '\.BindText\(' \
        '            tx.BindText(statusLabel, status);'
    "*" csharp "the ForEach combinator" '\.ForEach\(' \
        '            var todoList = tx.ForEach(todos, null);'
    "*" csharp "BindTextElement by index" '\.BindTextElement\(' \
        '            t.BindTextElement(label);'
    "*" csharp "the AddChild chain" '\.AddChild\(' \
        '            tx.AddChild(column, field);'

    "*" java "widget-kind construction" '\.widget\(' \
        '            KayaApp.Widget column = tx.widget(KayaWire.KIND_COLUMN);'
    "*" java "the generic bindText" '\.bindText\(' \
        '            tx.bindText(statusLabel, status);'
    "*" java "the forEach combinator" '\.forEach\(' \
        '            KayaApp.Widget todoList = tx.forEach(todos, null);'
    "*" java "bindTextElement by index" '\.bindTextElement\(' \
        '            t.bindTextElement(label, 0);'
    "*" java "the addChild chain" '\.addChild\(' \
        '            tx.addChild(column, field);'

    "*" swift "widget-kind construction" '\.widget\(' \
        '    let column = tx.widget(UInt32(KAYA_KIND_COLUMN))'
    "*" swift "the generic bindText" '\.bindText\(' \
        '    tx.bindText(statusLabel, status)'
    "*" swift "the forEach combinator" '\.forEach\(' \
        '    let (todoList, _) = tx.forEach(todos) { t in }'
    "*" swift "bindTextElement by index" '\.bindTextElement\(' \
        '        t.bindTextElement(label)'
    "*" swift "the addChild chain" '\.addChild\(' \
        '    tx.addChild(column, field)'

    "*" haskell "the addChild chain" '(^|[^A-Za-z])addChild[[:space:]]' \
        '    addChild column field'
    "*" haskell "bindTextElement by index" '(^|[^A-Za-z])bindTextElement[[:space:]]' \
        '      bindTextElement label 0'
    "*" haskell "the generic bindText" '(^|[^A-Za-z])bindText[[:space:]]' \
        '    bindText statusLabel status'

    "*" ocaml "widget-kind construction" '(^|[^A-Za-z_])widget kind_' \
        '       let column = widget kind_column in'
    "*" ocaml "the generic bind_text" '(^|[^A-Za-z_])bind_text[[:space:]]' \
        '       bind_text status_label status;'
    "*" ocaml "the add_child chain" '(^|[^A-Za-z_])add_child[[:space:]]' \
        '       add_child column field;'

    # THE FOR COMBINATOR IS THE FLOOR IN ENTRY AND THE SUGAR IN
    # MILESTONE2, in these two languages only, and the reason is one
    # line of each binding: Haskell's `each c body = fst <$> forEach c
    # body` and OCaml's `let each c body () = fst (for_each c body ())`.
    # `each` IS the combinator with the body's RESULT THROWN AWAY.
    #
    # entry's template body returns () — one bound label, nothing
    # escapes — so `each` is its spelling and the combinator was the
    # floor it left (that is the literal pre-graduation line in the
    # fifth field). milestone2's body returns the two handles its
    # CENTRAL registration names, the per-group collection and the
    # stamped remove button, and a closure in these two languages
    # cannot assign an outer variable the way swift's and java's do
    # (`items = todos`, `items[0] = group.collection()`); the result is
    # the only way out. Idiom decides the spelling, never the semantics
    # (DESIGN.md, Binding conventions), and menus.hs/menus.ml spell it
    # the same way outside the carve-out entirely.
    #
    # So milestone2 keeps the combinator and is denied the sin that is
    # still available to it: a For whose result is (), which is a For
    # `each` should have made. Both halves are watched firing.
    entry haskell "the forEach combinator" '(^|[^A-Za-z])forEach[[:space:]]' \
        '    forEach todos body'
    milestone2 haskell "a For whose result it drops" \
        '\(\)\)[[:space:]]*<-[[:space:]]*forEach' \
        '    (todoList, ()) <- forEach todos $ do'
    entry ocaml "the for_each combinator" '(^|[^A-Za-z_])for_each[[:space:]]' \
        '       for_each todos body;'
    milestone2 ocaml "a For whose result it drops" \
        '^[[:space:]]*let [a-z_]+, \(\) =' \
        '       let todo_list, () ='
)
scene_rules+=("*" haskell "widget-kind construction" \
    "widget kind($hs_alt)([^A-Za-z]|\$)" "    column <- widget kind$hs_first")

# EVERY ROW MUST GUARD AT LEAST ONE FILE. A scene scope or a language
# that names nothing — one typo, `mileston2` — is a row that is never
# read, never planted, and so NEVER SEEN FAILING: it would pass forever
# and take its rule with it. The loops below skip a row that does not
# apply, silently and by design (that is how "*" and a scene name share
# one table), so the table's own integrity is checked here.
for ((sr = 0; sr < ${#scene_rules[@]}; sr += 5)); do
    rule_files=0
    for ((sg = 0; sg < ${#scene_guests[@]}; sg += 3)); do
        [ "${scene_guests[sg + 1]}" = "${scene_rules[sr + 1]}" ] || continue
        case "${scene_rules[sr]}" in
            "*" | "${scene_guests[sg]}") rule_files=$((rule_files + 1)) ;;
        esac
    done
    if [ "$rule_files" -eq 0 ]; then
        echo "check-sugar-surface: SELF-TEST FAIL (the floor row [${scene_rules[sr]}" \
            "${scene_rules[sr + 1]} — ${scene_rules[sr + 2]}] guards no file at" \
            "all: its scene scope or its language names nothing in the scene" \
            "table, so the rule is never read and could never be watched" \
            "failing)" >&2
        exit 1
    fi
done

# floor <language> <scene> <file> <what> <regex> [<file to name in the
# message>] — deny's scene-side sibling.
floor() {
    if grep -qE "$5" "$3"; then
        echo "check-sugar-surface: $1's $2 guest still spells $4 at the" \
            "explicit floor (found /$5/ in ${6:-$3}) — an example scene uses its" \
            "language's construction sugar (CLAUDE.md invariant 5), and $2's" \
            "carve-out is its EVENT mechanism and nothing else (DESIGN.md, scope" \
            "ratified 2026-08-05)"
        status=1
    fi
}

# scene_one <scene> <language> <file> — the clause over ONE guest.
scene_one() {
    local scene="$1" lang="$2" f="$3" shown="$3" read_from="$3"
    local i strip_rc

    scene_fact "$scene"

    # THE ANTI-VACUITY FLOOR. `grep -q` on a file that is not there
    # finds nothing, which is indistinguishable from a clean scene, so
    # a renamed or deleted guest would satisfy every denial below at
    # once. Each file therefore proves it IS the scene it is filed
    # under first, by carrying that scene script's own expected string
    # — frozen by invariant 6, and byte-identical in all eight
    # languages by invariant 6's whole point.
    if ! grep -qF "$fact_anchor" "$f" 2>/dev/null; then
        echo "check-sugar-surface: $f is not the $scene scene — it does not" \
            "carry \"$fact_anchor\", the scene script's own expected string" \
            "($fact_steps) — so this clause reads it and passes vacuously" \
            "about it"
        status=1
    fi

    # RUST IS READ WITH ITS COMMENT LINES DROPPED, and only rust: both
    # its headers NAME `ctx.next()` in prose, so the positive pin below
    # would be satisfied by the sentence describing the loop rather
    # than by the loop (measured while writing this — entry.rs carries
    # two occurrences, one of them prose, and milestone2.rs the same).
    # The other seven are read whole: a comment that spells a floor
    # call in a graduated scene teaches the floor, and is worth the
    # reader's second.
    if [ "$lang" = rust ]; then
        read_from="$T/rust-$scene-code.txt"
        python3 -c '
import sys

src, dst = sys.argv[1], sys.argv[2]
lines = [ln for ln in open(src, encoding="utf-8").read().split("\n")
         if not ln.lstrip().startswith("//")]
open(dst, "w", encoding="utf-8").write("\n".join(lines))
' "$f" "$read_from" 2>/dev/null
        strip_rc=$?
        if [ "$strip_rc" -ne 0 ]; then
            echo "check-sugar-surface: $f could not be read (this clause reads the" \
                "rust guest with its comment lines dropped)"
            status=1
            return
        fi
        shown="$f (comments dropped)"
    fi

    for ((i = 0; i < ${#scene_rules[@]}; i += 5)); do
        [ "${scene_rules[i + 1]}" = "$lang" ] || continue
        case "${scene_rules[i]}" in
            "*" | "$scene") ;;
            *) continue ;;
        esac
        floor "$lang" "$scene" "$read_from" "${scene_rules[i + 2]}" \
            "${scene_rules[i + 3]}" "$shown"
    done

    # (b) AND RUST'S RAW LOOP STAYS, IN EVERY SCENE THE CARVE-OUT NAMES.
    if [ "$lang" = rust ] && ! grep -qE 'ctx\.next\(\)' "$read_from"; then
        echo "check-sugar-surface: rust's $scene guest no longer reads occurrences" \
            "through the raw \`ctx.next()\` loop ($f) — that loop IS this" \
            "scene's carve-out and one of the two guests documenting the tier" \
            "kaya::Messages is built on (DESIGN.md, scope ratified 2026-08-05)." \
            "Graduating it is the maintainer's decision, not a cleanup"
        status=1
    fi
}

# check_scene_sugar [<scene>:<language>=<path> ...] — the clause over
# the whole table, with any row's guest swapped for a doctored copy.
#
# The overrides exist for the reason deny_loose's path arguments do:
# the self-test runs this against DOCTORED COPIES OF THE REAL GUESTS,
# and a rule about sixteen fixed paths could never be watched failing.
# The real run passes none and reads the table.
check_scene_sugar() {
    local i o scene lang file
    for ((i = 0; i < ${#scene_guests[@]}; i += 3)); do
        scene="${scene_guests[i]}"
        lang="${scene_guests[i + 1]}"
        file="${scene_guests[i + 2]}"
        for o in "$@"; do
            case "$o" in
                "$scene:$lang="*) file="${o#"$scene:$lang="}" ;;
            esac
        done
        scene_one "$scene" "$lang" "$file"
    done
}

scene_applied=""
applied_scene() { # count label
    if [ "$1" -ge 1 ]; then
        scene_applied="$scene_applied $2=$1"
        return 0
    fi
    echo "check-sugar-surface: SELF-TEST FAIL (scene perturbation $2 applied $1" \
        "times, want at least 1 — an unchanged copy cannot prove the rule fires)" >&2
    exit 1
}

# scene_block <scene> <language> — the floor snippets that language
# owes THIS scene, ready to be spliced in as a python replacement (a
# literal \n before each).
scene_block() {
    local i out=""
    for ((i = 0; i < ${#scene_rules[@]}; i += 5)); do
        [ "${scene_rules[i + 1]}" = "$2" ] || continue
        case "${scene_rules[i]}" in
            "*" | "$1") out="$out"'\n'"${scene_rules[i + 4]}" ;;
        esac
    done
    printf '%s' "$out"
}

# re_lit <string> -> a regex matching it literally. The anchors are
# data in a table and one of them will one day carry a `.` or a `(`;
# a perturbation whose pattern quietly matched something else — or
# nothing — is the vacuous self-test this whole clause is about.
re_lit() { python3 -c 'import re, sys; print(re.escape(sys.argv[1]))' "$1"; }

# shout <string> -> it, uppercased, safe as a python re.sub replacement
# (a backslash in an anchor would otherwise read as a group reference).
shout() {
    python3 -c 'import sys; print(sys.argv[1].upper().replace("\\", "\\\\"))' "$1"
}

# THE PERTURBATIONS, ON DOCTORED COPIES OF THE REAL GUESTS. One per
# SCENE PER LANGUAGE: every snippet that language owes that scene is
# planted after the scene's own plant line — a line each of its eight
# guests carries — and the clause must then name EVERY rule the pair
# has, IN THAT SCENE'S NAME. A snippet the pattern misses is a pattern
# that would never have fired; a complaint naming the other scene is a
# rule that fired about the wrong file.
#
# `check_scene_sugar` runs inside `$( )` here, so the `status=1` it
# sets dies with that subshell and the real run's verdict is untouched
# (the fake-kind self-test's reason, from the scene side).
scene_selftest() { # <scene> <language> <guest>
    local scene="$1" lang="$2" src="$3" doctored hits out i what missing=""
    scene_fact "$scene"
    doctored="$T/scene-floor-$scene-$lang.txt"
    hits=$(perturb "$src" "$fact_plant" "\\g<1>$(scene_block "$scene" "$lang")" \
        "$doctored")
    applied_scene "$hits" "$scene/$lang"
    out=$(check_scene_sugar "$scene:$lang=$doctored" 2>&1)
    for ((i = 0; i < ${#scene_rules[@]}; i += 5)); do
        [ "${scene_rules[i + 1]}" = "$lang" ] || continue
        case "${scene_rules[i]}" in
            "*" | "$scene") ;;
            *) continue ;;
        esac
        what="${scene_rules[i + 2]}"
        case "$out" in
            *"$lang's $scene guest still spells $what "*) ;;
            *) missing="$missing [$what]" ;;
        esac
    done
    if [ -n "$missing" ]; then
        echo "check-sugar-surface: SELF-TEST FAIL ($lang floor patterns that did" \
            "NOT fire on a doctored copy of the real $scene guest:$missing)" >&2
        exit 1
    fi
}

for ((sg = 0; sg < ${#scene_guests[@]}; sg += 3)); do
    scene_selftest "${scene_guests[sg]}" "${scene_guests[sg + 1]}" \
        "${scene_guests[sg + 2]}"
done

# AND THE POSITIVE PIN IS WATCHED FAILING TOO, ONCE PER RUST GUEST: (b)
# is the half that says something must STAY, so the only way to see it
# work is to take it away. The prose in each header still names
# `ctx.next()` after this substitution, which is exactly why the clause
# reads rust with its comments dropped.
for ((sg = 0; sg < ${#scene_guests[@]}; sg += 3)); do
    [ "${scene_guests[sg + 1]}" = rust ] || continue
    scene_pin="${scene_guests[sg]}"
    hits=$(perturb "${scene_guests[sg + 2]}" 'match ctx\.next\(\)' 'match ctx.peek()' \
        "$T/scene-noloop-$scene_pin.rs")
    applied_scene "$hits" "$scene_pin/rust-raw-loop"
    scene_loop_out=$(check_scene_sugar "$scene_pin:rust=$T/scene-noloop-$scene_pin.rs" 2>&1)
    case "$scene_loop_out" in
        *"rust's $scene_pin guest no longer reads occurrences through the raw"*) ;;
        *)
            echo "check-sugar-surface: SELF-TEST FAIL (rust's $scene_pin guest was" \
                "not refused for losing its raw occurrence loop:" \
                "${scene_loop_out:-no output at all})" >&2
            exit 1
            ;;
    esac
done

# AND SO IS THE ANTI-VACUITY FLOOR, ONCE PER SCENE — the anchor is a
# per-scene fact, so each scene's has to be watched refusing. A file
# this clause cannot recognise as the scene it is filed under has to
# fail LOUDLY rather than satisfy every denial by having nothing in it;
# the wayland seat guard passed vacuously twice for want of exactly
# this (docs/traps.md). The ocaml row carries it for no reason but
# that every scene has one — what is under test is the anchor, not the
# language.
for ((sg = 0; sg < ${#scene_guests[@]}; sg += 3)); do
    [ "${scene_guests[sg + 1]}" = ocaml ] || continue
    scene_vac="${scene_guests[sg]}"
    scene_fact "$scene_vac"
    hits=$(perturb "${scene_guests[sg + 2]}" "$(re_lit "$fact_anchor")" \
        "$(shout "$fact_anchor")" "$T/scene-notscene-$scene_vac.ml")
    applied_scene "$hits" "$scene_vac/ocaml-anchor"
    scene_vac_out=$(check_scene_sugar "$scene_vac:ocaml=$T/scene-notscene-$scene_vac.ml" 2>&1)
    case "$scene_vac_out" in
        *"is not the $scene_vac scene"*) ;;
        *)
            echo "check-sugar-surface: SELF-TEST FAIL (a file that is not the" \
                "$scene_vac scene was not refused:" \
                "${scene_vac_out:-no output at all})" >&2
            exit 1
            ;;
    esac
done
echo "check-sugar-surface: scene-tier perturbations applied:$scene_applied" >&2

check_scene_sugar

if [ "$status" -ne 0 ]; then
    echo "check-sugar-surface: FAIL"
    exit 1
fi
echo "check-sugar-surface: OK"
