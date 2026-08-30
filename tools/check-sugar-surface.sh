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
# clause is about what a BINDING OFFERS; the SCENE-TIER clause at the
# end is about what the EXAMPLES USE (invariant 5).
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
# The three primitives (docs/ranges-plan.md D1) plus `set_text`. This
# file's other sweeps cover widget CONSTRUCTORS and WINDOW props, and a
# widget-level verb is neither, so nothing else would demand these of
# the seven non-Rust bindings.
#
# RED BY DESIGN until the sweep lands (CLAUDE.md, sequencing).
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
    # this one pattern is indented where the other seven are not: in
    # seven bindings a widget-addressed one-shot is a transaction method
    # taking a widget, while Python's transaction is ambient and has no
    # handle to hang it on. The file's other handle-verb clauses
    # (a11y_id, accepts, on_paste) are keyed on `(self` for that reason.
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

# --- THE CAPABILITIES SURFACE, in all eight ------------------------
#
# `kaya_capabilities()` is a C export every binding must wrap, or a
# guest derives the answer from its OWN platform predicate instead —
# copies of a rule the core already holds, keyed on the platform rather
# than on the capability.
#
# TWO CLAUSES, because either alone passes for the wrong reason: a
# binding can offer the QUERY and hand back the raw u64, and it can name
# a FLAG that nothing computes.
cap_want() {
    if ! grep -qE "$4" "$2"; then
        echo "check-sugar-surface: $1 has no capabilities $3" \
            "(wanted /$4/ in $2)"
        status=1
    fi
}

# check_cap_query <snake_case> <PascalCase> <camelCase> — the query
# itself: one call, no arguments, answerable any time.
check_cap_query() {
    local snake="$1" pascal="$2" camel="$3"
    cap_want rust    crates/kaya/src/app.rs              query "^pub fn ${snake}\\(\\)"
    cap_want python  bindings/python/kaya/__init__.py    query "^def ${snake}\\("
    cap_want go      bindings/go/app.go                  query "^func ${pascal}\\(\\)"
    cap_want csharp  bindings/csharp/KayaApp.cs          query "public static [A-Za-z]+ ${pascal}\\("
    cap_want java    bindings/java/dev/kaya/KayaApp.java query "public static [A-Za-z]+ ${camel}\\("
    cap_want swift   bindings/swift/KayaApp.swift        query "static func ${camel}\\("
    cap_want haskell bindings/haskell/KayaApp.hs         query "^${camel} :: IO"
    cap_want ocaml   bindings/ocaml/kaya_app.ml          query "^let ${snake} "
}
check_cap_query capabilities Capabilities capabilities

# check_cap_flag <snake_case> <PascalCase> <camelCase> — ONE named
# boolean, in every binding's own record/struct/dataclass. This is the
# line that grows when the core grows a bit: one call here, and eight
# bindings are held to it.
check_cap_flag() {
    local snake="$1" pascal="$2" camel="$3"
    cap_want rust    crates/kaya/src/app.rs              "flag '$snake'" "pub ${snake}: bool"
    cap_want python  bindings/python/kaya/__init__.py    "flag '$snake'" "^    ${snake}: bool"
    cap_want go      bindings/go/app.go                  "flag '$snake'" "^	${pascal} bool"
    cap_want csharp  bindings/csharp/KayaApp.cs          "flag '$snake'" "bool ${pascal}[,)]"
    cap_want java    bindings/java/dev/kaya/KayaApp.java "flag '$snake'" "boolean ${camel}[,)]"
    cap_want swift   bindings/swift/KayaApp.swift        "flag '$snake'" "let ${camel}: Bool"
    cap_want haskell bindings/haskell/KayaApp.hs         "flag '$snake'" "${camel} :: Bool"
    cap_want ocaml   bindings/ocaml/kaya_app.ml          "flag '$snake'" "${snake} : bool"
}
check_cap_flag aux_windows AuxWindows auxWindows

# THEIR BUILT-IN NEGATIVE TESTS, one per clause and for the same reason
# the range verbs have one: sixteen patterns that can only pass are
# sixteen patterns nobody will notice have rotted. Each runs in a
# subshell so its status=1 dies with it.
cap_fake=$(check_cap_query kaya_fake_query KayaFakeQuery kayaFakeQuery 2>&1 \
    | grep -c "has no capabilities")
if [ "$cap_fake" -ne 8 ]; then
    echo "check-sugar-surface: self-test failed ($cap_fake/8 capability-query patterns" \
        "fired for a query that exists nowhere)"
    exit 1
fi
cap_fake=$(check_cap_flag kaya_fake_cap KayaFakeCap kayaFakeCap 2>&1 \
    | grep -c "has no capabilities")
if [ "$cap_fake" -ne 8 ]; then
    echo "check-sugar-surface: self-test failed ($cap_fake/8 capability-flag patterns" \
        "fired for a bit that exists nowhere)"
    exit 1
fi
unset cap_fake

# AND THE BIT NUMBERS AGREE WITH THE CORE'S (the check-file-modes
# lesson). Five bindings have no header to read `KAYA_CAP_AUX_WINDOWS`
# out of and write the number themselves; renumber the bit in the core
# and each goes on testing the old one, which reads as a host that lost
# a capability. Three DO read the core's own name and cannot drift, so
# for them the check is that they still name it rather than quietly
# becoming copiers. Two tables, and the second table's claim is itself
# checked.
cap_out=$(python3 - <<'PY'
import pathlib
import re
import sys

# The authority: the scene core owns the bit (capi.rs's exported
# constant is static-asserted equal to it, and the header's #define is
# cbindgen's copy of capi.rs's).
scene = pathlib.Path("crates/kaya/src/scene.rs").read_text()
found = re.search(r"const CAP_AUX_WINDOWS: u64 = (\d+);", scene)
if not found:
    print("check-sugar-surface: crates/kaya/src/scene.rs declares no CAP_AUX_WINDOWS "
          "— the capability bit has no authority to check the bindings against")
    sys.exit(1)
truth = int(found.group(1))

COPIERS = {
    "python":  ("bindings/python/kaya/runtime.py",      r"^CAP_AUX_WINDOWS = (\d+)$"),
    "csharp":  ("bindings/csharp/Kaya.cs",              r"CAP_AUX_WINDOWS = (\d+);"),
    "java":    ("bindings/java/dev/kaya/KayaApp.java",  r"CAP_AUX_WINDOWS = (\d+);"),
    "haskell": ("bindings/haskell/KayaRuntime.hs",      r"^capAuxWindows = (\d+)$"),
    "ocaml":   ("bindings/ocaml/kaya_runtime.ml",       r"^let cap_aux_windows = (\d+)L$"),
}
READERS = {
    "rust":  ("crates/kaya/src/app.rs",          "KAYA_CAP_AUX_WINDOWS"),
    "go":    ("bindings/go/runtime.go",          "C.KAYA_CAP_AUX_WINDOWS"),
    "swift": ("bindings/swift/KayaApp.swift",    "KAYA_CAP_AUX_WINDOWS"),
}


def audit(number):
    """Every copier's written bit, against `number`."""
    bad = []
    for lang, (path, pattern) in COPIERS.items():
        text = pathlib.Path(path).read_text()
        wrote = [int(g) for g in re.findall(pattern, text, re.M)]
        if not wrote:
            bad.append(f"{lang} writes no capability bit at all "
                       f"({path} wanted /{pattern}/)")
        elif any(v != number for v in wrote):
            bad.append(f"{lang} writes CAP_AUX_WINDOWS={wrote} where the core says "
                       f"{number} ({path}) — the guest would test a bit the core "
                       f"no longer sets")
    return bad


fails = audit(truth)
for lang, (path, name) in READERS.items():
    if name not in pathlib.Path(path).read_text():
        fails.append(f"{lang} no longer names {name} ({path}) — it read the core's "
                     f"own constant, and anything else here is a number that drifts")

# THE WATCHED NEGATIVE: move the authority under them and EVERY copier
# must notice. A reader that silently found nothing agrees with any
# number at all, which is the census defect one file over
# (tools/tpl-surfaces.py refuses a verdict for the same reason).
missed = len(COPIERS) - len(audit(truth + 41))
if missed:
    print(f"check-sugar-surface: self-test failed ({missed} of {len(COPIERS)} "
          f"capability-number readers did not notice a renumbered bit)")
    sys.exit(1)

for line in fails:
    print("check-sugar-surface: " + line)
sys.exit(1 if fails else 0)
PY
)
cap_rc=$?
if [ "$cap_rc" -ne 0 ]; then
    echo "$cap_out"
    status=1
fi

# --- THE TABLE SURFACE, in all eight -------------------------------
#
# A TABLE IS NOT A KIND — it is a For with a header — so neither the
# constructor sweep above nor the window-prop sweep below can see it,
# and the wire records (TX 45 set_column_headers, occurrence 19
# sort_requested) reach every binding through the GENERATOR whether or
# not a guest has any way to spell them. That gap is what this clause
# closes: `columns` declares the header at the For, `on_sort` answers
# its clicks with the 0-based column (docs/tables-plan.md).
#
# PYTHON'S on_sort IS A KEYWORD, not a registration call: its ambient
# transaction has no app-level handler surface, so `columns(...,
# on_sort=f)` carries it. OCAML'S IS A LABELLED ARGUMENT on that same
# declaration, for the reason its click is one (`button ?on_click ()`):
# a binding registers a handler where its OWN click convention does
# (the maintainer's ruling, 2026-08-24), so its pattern reads `columns`'
# header and there is no `let on_sort` to find. Same observable
# semantics, different spelling — which is why the eight patterns are
# written out rather than derived from one casing rule.
want_table() {
    if ! grep -qE "$4" "$2"; then
        echo "check-sugar-surface: $1 has no sugar for the table's '$3'" \
            "(wanted /$4/ in $2)"
        status=1
    fi
}

# check_table_columns <snake_case> <PascalCase> <camelCase>
check_table_columns() {
    local snake="$1" pascal="$2" camel="$3"
    want_table rust    crates/kaya/src/app.rs              "$snake" "pub fn ${snake}\\("
    want_table python  bindings/python/kaya/__init__.py    "$snake" "def ${snake}\\(self"
    want_table go      bindings/go/app.go                  "$snake" "func \\(tx \\*Tx\\) ${pascal}\\("
    want_table csharp  bindings/csharp/KayaApp.cs          "$snake" "public void ${pascal}\\("
    want_table java    bindings/java/dev/kaya/KayaApp.java "$snake" "public void ${camel}\\("
    want_table swift   bindings/swift/KayaApp.swift        "$snake" "func ${camel}\\("
    # HASKELL'S IS A CLASS METHOD, indented: `columnsNode` died when the
    # module's header rule reached the table, and one name now dispatches
    # over the zone through 'Declare'. Keyed on the whole SIGNATURE, since
    # `El m -> … -> m ()` is the half that says it stands in both zones —
    # a live-only `Widget -> … -> Build ()` under the same name is exactly
    # what this must not accept.
    want_table haskell bindings/haskell/KayaApp.hs         "$snake" \
        "^  ${camel} :: El m -> \\[String\\] -> Sort -> m \\(\\)"
    want_table ocaml   bindings/ocaml/kaya_app.ml          "$snake" "^let ${snake} "
}
check_table_columns columns Columns columns

# check_table_on_sort <snake_case> <PascalCase> <camelCase>
check_table_on_sort() {
    local snake="$1" pascal="$2" camel="$3"
    # Rust's is the For builder's, whose generic parameter sits between
    # the name and the arguments.
    want_table rust    crates/kaya/src/app.rs              "$snake" "pub fn ${snake}(<[^>]*>)?\\("
    want_table python  bindings/python/kaya/__init__.py    "$snake" "def columns\\(self.*${snake}="
    want_table go      bindings/go/app.go                  "$snake" "func \\(a \\*App\\) ${pascal}\\("
    want_table csharp  bindings/csharp/KayaApp.cs          "$snake" "public void ${pascal}\\("
    want_table java    bindings/java/dev/kaya/KayaApp.java "$snake" "public void ${camel}\\("
    want_table swift   bindings/swift/KayaApp.swift        "$snake" "func ${camel}\\("
    # ALSO A CLASS METHOD, and the handler's own type is the class's
    # associated family: the zone decides what a click hands the handler,
    # so `Keyed e` in the signature is what makes one name serve both
    # (bindings/haskell/KayaApp.hs, class HandlerTarget — one class for
    # all six registrars, so a verb missing from a zone is a
    # -Werror=missing-methods red rather than an absent instance).
    want_table haskell bindings/haskell/KayaApp.hs         "$snake" \
        "^  ${camel} :: App -> e -> Keyed e \\(Int -> IO \\(\\)\\) -> IO \\(\\)"
    # The LIVE zone's, keyed on the whole labelled argument: the type is
    # what separates it from the template zone's own `?(on_sort :
    # (Kaya_wire.value list -> int -> unit) option)` one module over.
    want_table ocaml   bindings/ocaml/kaya_app.ml          "$snake" \
        "^let columns \\?\\(${snake} : \\(int -> unit\\) option\\)"
}
check_table_on_sort on_sort OnSort onSort

# THEIR BUILT-IN NEGATIVE TESTS, one per clause and for the reason the
# range verbs have one: sixteen patterns that can only pass are sixteen
# patterns nobody will notice have rotted. Each runs in a subshell so
# its status=1 dies with it.
table_fake=$(check_table_columns kaya_fake_cols KayaFakeCols kayaFakeCols 2>&1 \
    | grep -c "has no sugar for the table's")
if [ "$table_fake" -ne 8 ]; then
    echo "check-sugar-surface: self-test failed ($table_fake/8 table-columns patterns" \
        "fired for a declaration that exists nowhere)"
    exit 1
fi
table_fake=$(check_table_on_sort on_kaya_fake OnKayaFake onKayaFake 2>&1 \
    | grep -c "has no sugar for the table's")
if [ "$table_fake" -ne 8 ]; then
    echo "check-sugar-surface: self-test failed ($table_fake/8 table-on_sort patterns" \
        "fired for a handler that exists nowhere)"
    exit 1
fi
unset table_fake

# --- THE ROLE SUGAR: heading() and caption(), BOTH ZONES --------------
#
# One word for label+role (docs/styling-plan.md D4; ratified 2026-08-30).
# Neither is a KIND, so the kind census cannot see them — the table
# surface's problem one clause up, and the same answer: the patterns
# written out per binding, both construction zones each. Python is ONE
# pattern for both zones (its ambient _widget serves whichever zone is
# open — the live-only sentence does not apply, both zones are real).
# Go spells the live pair Text/Signal and the template pair Text/Bound,
# so it carries four patterns; Swift's LIVE constructor breaks its
# argument list after the paren, which is what the end-of-line anchor
# pins against the template overloads.
want_role() {
    if ! grep -qE "$4" "$2"; then
        echo "check-sugar-surface: $1 has no '$3' role sugar" \
            "(wanted /$4/ in $2)"
        status=1
    fi
}

# check_role_sugar <snake_case> <PascalCase> <camelCase>
check_role_sugar() {
    local snake="$1" pascal="$2" camel="$3"
    want_role rust-live crates/kaya/src/app.rs "$snake" \
        "pub fn ${snake}\(&mut self, signal: SignalId\)"
    want_role rust-tpl crates/kaya/src/app.rs "$snake" \
        "pub fn ${snake}\(&mut self, src: impl Into<TplSource<StrKind>>\)"
    want_role python bindings/python/kaya/__init__.py "$snake" \
        "^def ${snake}\(text=None, bind=None, grow=None\)"
    want_role go-live bindings/go/app.go "$snake" \
        "func \(tx \*Tx\) ${pascal}Text\(text string\) Widget"
    want_role go-live bindings/go/app.go "$snake" \
        "func \(tx \*Tx\) ${pascal}\(s Signal\[string\]\) Widget"
    want_role go-tpl bindings/go/app.go "$snake" \
        "func \(t \*Tpl\) ${pascal}Text\("
    want_role go-tpl bindings/go/app.go "$snake" \
        "func \(t \*Tpl\) ${pascal}Bound\["
    want_role csharp-live bindings/csharp/KayaApp.cs "$snake" \
        "public Widget ${pascal}\(string text = null"
    want_role csharp-tpl bindings/csharp/KayaApp.cs "$snake" \
        "public Node ${pascal}\(string text\)"
    want_role java-live bindings/java/dev/kaya/KayaApp.java "$snake" \
        "public Widget ${camel}\(String text\)"
    want_role java-tpl bindings/java/dev/kaya/KayaApp.java "$snake" \
        "public Node ${camel}\(String text\)"
    want_role swift-live bindings/swift/KayaApp.swift "$snake" \
        "func ${camel}\($"
    want_role swift-tpl bindings/swift/KayaApp.swift "$snake" \
        "func ${camel}\(_ text: String\) -> KayaNodeHandle"
    want_role ocaml-live bindings/ocaml/kaya_app.ml "$snake" \
        "^let ${snake} \?grow \?a11y_id \?a11y_label \?text \?bind \(\)"
    want_role ocaml-tpl bindings/ocaml/kaya_app.ml "$snake" \
        "^  let ${snake} \?grow \?a11y_id \?a11y_id_bind"
    want_role haskell-live bindings/haskell/KayaApp.hs "$snake" \
        "^${camel}Text :: \(LeafArgs r\) => String -> r"
    want_role haskell-tpl bindings/haskell/KayaApp.hs "$snake" \
        "^${camel} :: TplStrSource s => s -> Tpl Node"
}
check_role_sugar heading Heading heading
check_role_sugar caption Caption caption

role_fake=$(check_role_sugar kaya_fake_role KayaFakeRole kayaFakeRole 2>&1 \
    | grep -c "has no 'kaya_fake_role' role sugar")
if [ "$role_fake" -ne 17 ]; then
    echo "check-sugar-surface: self-test failed ($role_fake/17 role-sugar patterns" \
        "fired for a constructor that exists nowhere)"
    exit 1
fi
unset role_fake

# --- THE SIZE-POLICY SURFACE, in all eight --------------------------
#
# WHAT A CANVAS DOES WITH A TRACK THAT IS NOT ITS VIEWBOX
# (docs/canvas-plan.md §3.2.1). Invisible to every sweep above for the
# table's reason one surface over: `size_policy` is not a KIND and not a
# WINDOW PROP, and TX 47 plus occurrences 20/21 reach all eight bindings
# through the GENERATOR whether or not a guest can spell any of them —
# which is exactly the state this wave found (the records generated,
# nothing above them).
#
# `scale` HAS NO SPELLING ANYWHERE, deliberately: it is what a canvas
# that declares nothing gets, so there is nothing here to check for it.
# The other three are one semantics in eight idioms, each riding where
# that binding's OWN handler convention rides (the 2026-08-24 ruling
# `on_sort` was decided by): chained on rust/go/csharp/java/swift,
# KEYWORD arguments on python's `canvas`, LABELLED arguments on ocaml's,
# and on haskell a Build action for the property beside two
# App-registered handlers. Written out rather than derived from a casing
# rule for that reason.
want_policy() {
    if ! grep -qE "$4" "$2"; then
        echo "check-sugar-surface: $1 has no sugar for the canvas's '$3'" \
            "(wanted /$4/ in $2)"
        status=1
    fi
}

# check_policy_fixed <snake_case> <PascalCase> <camelCase>
check_policy_fixed() {
    local snake="$1" pascal="$2" camel="$3"
    want_policy rust    crates/kaya/src/app.rs              "$snake" \
        "pub fn ${snake}\\(self\\) -> Self"
    # The keyword on the constructor, WITH its default: `fixed` alone
    # would match the parameter list of anything.
    want_policy python  bindings/python/kaya/__init__.py    "$snake" \
        "def canvas\\(viewbox.*${snake}=None"
    want_policy go      bindings/go/app.go                  "$snake" \
        "func \\(w Widget\\) ${pascal}\\(\\) Widget"
    want_policy csharp  bindings/csharp/KayaApp.cs          "$snake" \
        "public Widget ${pascal}\\(\\)"
    want_policy java    bindings/java/dev/kaya/KayaApp.java "$snake" \
        "public Widget ${camel}\\(\\)"
    want_policy swift   bindings/swift/KayaApp.swift        "$snake" \
        "func ${camel}\\(\\) -> KayaWidget"
    # A PROPERTY IS A Build ACTION HERE, which is where every other live
    # prop in this binding stands — and it takes a Widget, which is the
    # template zone's refusal (a Node cannot be passed).
    want_policy haskell bindings/haskell/KayaApp.hs         "$snake" \
        "^${camel} :: Widget -> Build \\(\\)"
    want_policy ocaml   bindings/ocaml/kaya_app.ml          "$snake" \
        "\\?\\(${snake} = false\\)"
}
check_policy_fixed fixed Fixed fixed

# check_policy_handler <snake_case> <PascalCase> <camelCase> <hs-arg-type>
check_policy_handler() {
    local snake="$1" pascal="$2" camel="$3" hsarg="$4"
    want_policy rust    crates/kaya/src/app.rs              "$snake" \
        "pub fn ${snake}<M>\\("
    want_policy python  bindings/python/kaya/__init__.py    "$snake" \
        "def canvas\\(viewbox.*${snake}=None"
    want_policy go      bindings/go/app.go                  "$snake" \
        "func \\(w Widget\\) ${pascal}\\(fn func\\(d \\*Draw, size Viewbox"
    want_policy csharp  bindings/csharp/KayaApp.cs          "$snake" \
        "public Widget ${pascal}\\(Action<Draw, Viewbox"
    want_policy java    bindings/java/dev/kaya/KayaApp.java "$snake" \
        "public Widget ${camel}\\("
    want_policy swift   bindings/swift/KayaApp.swift        "$snake" \
        "func ${camel}\\(_ handler: @escaping \\(KayaDraw, KayaViewbox"
    # APP-REGISTERED, like this binding's other handlers, and typed on
    # Widget: the live zone is the only one a policy may be declared in.
    want_policy haskell bindings/haskell/KayaApp.hs         "$snake" \
        "^${camel} :: App -> Widget -> \\(${hsarg}\\) -> IO \\(\\)"
    want_policy ocaml   bindings/ocaml/kaya_app.ml          "$snake" \
        "\\?\\(${snake} : \\(draw -> viewbox"
}
check_policy_handler on_draw OnDraw onDraw "Viewbox -> \\[DrawOp\\]"
check_policy_handler on_tick OnTick onTick "Viewbox -> Double -> \\[DrawOp\\]"

# AND THE TEMPLATE ZONE IS REFUSED, all eight, which is the half a
# spelling census cannot see: the size policy is a LIVE-ZONE declaration
# in this slice and a canvas inside a row template keeps `scale`
# (docs/deferred.md). Six bindings refuse it with a TYPE — the template
# zone hands out its own handle and the three declarations do not exist
# on it — so what is checked there is that the template constructor
# carries no policy argument and the node type no policy method. The two
# whose one handle serves both zones raise, and their sentence is frozen
# BYTE FOR BYTE, because an app reads it and two spellings of one refusal
# is the divergence invariant 1 forbids.
#
# COMPARED FLATTENED, and that is not a convenience: python splices the
# sentence across adjacent string literals and ocaml across a
# backslash-continued one, so the bytes an app sees are one line while
# the bytes on disk are three. check-verbs' `expect_ax` clause reads its
# three harnesses the same way and for the same reason.
policy_sentence_out=$(python3 - <<'PY'
import pathlib, re, sys

SENTENCE = ("kaya: the size policy is a LIVE-ZONE declaration in this slice "
            "— a canvas inside a row template keeps `scale` "
            "(docs/deferred.md, the template-zone size policy entry)")

def flat(text: str) -> str:
    # Python's adjacent-literal splice, then OCaml's backslash-newline one.
    text = re.sub(r'"\s*\n\s*"', "", text)
    text = re.sub(r"\\\s*\n\s*", "", text)
    return re.sub(r"\s+", " ", text)

AMBIENT = ["bindings/python/kaya/__init__.py", "bindings/ocaml/kaya_app.ml"]
fails = []
want = re.sub(r"\s+", " ", SENTENCE)
for name in AMBIENT:
    if want not in flat(pathlib.Path(name).read_text(encoding="utf-8")):
        fails.append(f"{name} serves both zones with ONE handle but does not "
                     f"refuse a template-node size policy in the frozen "
                     f"words: \"{want}\"")
# THE CLAUSE'S OWN NEGATIVE, watched on every run: a copy with the
# sentence perturbed must stop matching, or this is a grep nobody has
# seen fail.
src = pathlib.Path(AMBIENT[0]).read_text(encoding="utf-8")
doctored, n = re.subn("LIVE-ZONE declaration", "live-zone declaration", src)
print(f"check-sugar-surface: template-zone sentence perturbation applied "
      f"{n} substitution(s)")
if n < 1:
    fails.append("the template-zone sentence self-test perturbed NOTHING — a "
                 "negative that did not perturb is a failed test")
elif want in flat(doctored):
    fails.append("the template-zone sentence self-test stayed GREEN against a "
                 "doctored copy — the clause reads something else")
for line in fails:
    print("check-sugar-surface: " + line)
sys.exit(1 if fails else 0)
PY
)
policy_rc=$?
echo "$policy_sentence_out"
if [ "$policy_rc" -ne 0 ]; then
    status=1
fi
# The typed refusals: a template constructor that grew a policy argument
# would be a second, unrefusable spelling of the same thing.
policy_typed_fail=0
if grep -qE "func \\(t \\*Tpl\\) Canvas\\(.*(fixed|onDraw|onTick)" bindings/go/app.go; then
    echo "check-sugar-surface: go's Tpl.Canvas takes a size policy — the" \
        "template zone is refused BY TYPE in this slice (docs/deferred.md)"
    policy_typed_fail=1
fi
if grep -qE "public Node Canvas\\(.*(Fixed|OnDraw|OnTick)" bindings/csharp/KayaApp.cs; then
    echo "check-sugar-surface: c#'s Tpl.Canvas takes a size policy — the" \
        "template zone is refused BY TYPE in this slice (docs/deferred.md)"
    policy_typed_fail=1
fi
if grep -qE "public Node canvas\\(.*(fixed|onDraw|onTick)" bindings/java/dev/kaya/KayaApp.java; then
    echo "check-sugar-surface: java's Tpl.canvas takes a size policy — the" \
        "template zone is refused BY TYPE in this slice (docs/deferred.md)"
    policy_typed_fail=1
fi
if grep -qE "^canvasOf :: Viewbox -> \\[DrawOp\\] -> .*(Bool|DrawOp\\] -> \\()" bindings/haskell/KayaApp.hs; then
    echo "check-sugar-surface: haskell's canvasOf takes a size policy — the" \
        "template zone is refused BY TYPE in this slice (docs/deferred.md)"
    policy_typed_fail=1
fi
[ "$policy_typed_fail" = 0 ] || status=1

# THEIR BUILT-IN NEGATIVE TESTS, the table clause's discipline: a
# pattern that can only pass is a pattern nobody notices has rotted.
policy_fake=$(check_policy_fixed kaya_fake_fixed KayaFakeFixed kayaFakeFixed 2>&1 \
    | grep -c "has no sugar for the canvas's")
if [ "$policy_fake" -ne 8 ]; then
    echo "check-sugar-surface: self-test failed ($policy_fake/8 size-policy" \
        "'fixed' patterns fired for a declaration that exists nowhere)"
    exit 1
fi
policy_fake=$(check_policy_handler on_kaya_fake OnKayaFake onKayaFake "Nope" 2>&1 \
    | grep -c "has no sugar for the canvas's")
if [ "$policy_fake" -ne 8 ]; then
    echo "check-sugar-surface: self-test failed ($policy_fake/8 size-policy" \
        "handler patterns fired for a handler that exists nowhere)"
    exit 1
fi
unset policy_fake policy_typed_fail

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
# kaya has TWO construction zones (CLAUDE.md's gate list). The LIVE zone
# is what an app builds in its build closure; the TEMPLATE zone is the
# prototype inside a collection, stamped once per row. They are
# different surfaces handing out different handles, so a constructor in
# one is not a constructor in the other.
#
# THE SWEEP IS PYTHON, NOT SEVEN MORE `check` LINES, and that is forced:
# three bindings namespace the template zone by SCOPE rather than by
# name (Rust's `Tpl` methods are `pub fn entry` exactly like `Tx`'s,
# OCaml's live in `module Tpl = struct`), so a line-oriented pattern
# would be satisfied by the LIVE constructor and report a zone it never
# read. tools/tpl-surfaces.py locates each zone by its structure and
# REFUSES A VERDICT from a reader that found implausibly few. It also
# holds Rust's two surfaces level: `Tpl` is the zone, `Row` is the
# for-statement façade that forwards by hand.
#
# Kinds come from the generated wire file, so the list tracks the spec
# by construction.
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

# (c2) THE DYNAMIC-TABLE READERS ARE WATCHED at every implemented point.
#      Each deletion is scoped to the block it claims to read; the same
#      names elsewhere stay in place.
tpl_table_probe=$(python3 - <<'PROBE'
import os, shutil, subprocess, sys, tempfile


def stage(text):
    root = tempfile.mkdtemp()
    os.makedirs(f"{root}/crates/kaya/src", exist_ok=True)
    for rel in ("bindings", "tools", "guests"):
        os.symlink(os.path.abspath(rel), f"{root}/{rel}")
    open(f"{root}/crates/kaya/src/app.rs", "w", encoding="utf-8").write(text)
    return root


def link_children(source, destination, skip):
    os.makedirs(destination, exist_ok=True)
    for name in os.listdir(source):
        if name != skip:
            os.symlink(os.path.abspath(f"{source}/{name}"),
                       f"{destination}/{name}")


def stage_python(app_text, python_text):
    root = stage(app_text)
    os.unlink(f"{root}/bindings")
    link_children("bindings", f"{root}/bindings", "python")
    link_children("bindings/python", f"{root}/bindings/python", "kaya")
    link_children("bindings/python/kaya", f"{root}/bindings/python/kaya",
                  "__init__.py")
    open(f"{root}/bindings/python/kaya/__init__.py", "w",
         encoding="utf-8").write(python_text)
    return root


def stage_go(app_text, go_text):
    root = stage(app_text)
    os.unlink(f"{root}/bindings")
    link_children("bindings", f"{root}/bindings", "go")
    link_children("bindings/go", f"{root}/bindings/go", "app.go")
    open(f"{root}/bindings/go/app.go", "w", encoding="utf-8").write(go_text)
    return root


def stage_csharp(app_text, csharp_text):
    root = stage(app_text)
    os.unlink(f"{root}/bindings")
    link_children("bindings", f"{root}/bindings", "csharp")
    link_children("bindings/csharp", f"{root}/bindings/csharp", "KayaApp.cs")
    open(f"{root}/bindings/csharp/KayaApp.cs", "w",
         encoding="utf-8").write(csharp_text)
    return root


def stage_swift(app_text, swift_text):
    root = stage(app_text)
    os.unlink(f"{root}/bindings")
    link_children("bindings", f"{root}/bindings", "swift")
    link_children("bindings/swift", f"{root}/bindings/swift", "KayaApp.swift")
    open(f"{root}/bindings/swift/KayaApp.swift", "w",
         encoding="utf-8").write(swift_text)
    return root


def scoped(src, start, stop, old, new):
    if src.count(start) != 1:
        return None, src.count(start)
    at = src.index(start)
    end = src.index(stop, at)
    block = src[at:end]
    n = block.count(old)
    if n == 1:
        src = src[:at] + block.replace(old, new) + src[end:]
    return src, n


def run(name, text, count, want):
    if count != 1:
        print(f"{name}=SELFTEST-BROKEN(matched {count}, expected 1)")
        return
    root = stage(text)
    r = subprocess.run([sys.executable, "tools/tpl-surfaces.py", root],
                       capture_output=True, text=True)
    shutil.rmtree(root)
    print(f"{name}=applied:1 rc:{r.returncode} named:{want in r.stdout}")


def run_python(name, app_text, text, count, want):
    if count != 1:
        print(f"{name}=SELFTEST-BROKEN(matched {count}, expected 1)")
        return
    root = stage_python(app_text, text)
    r = subprocess.run([sys.executable, "tools/tpl-surfaces.py", root],
                       capture_output=True, text=True)
    shutil.rmtree(root)
    print(f"{name}=applied:1 rc:{r.returncode} named:{want in r.stdout}")


def run_go(name, app_text, text, count, want):
    if count != 1:
        print(f"{name}=SELFTEST-BROKEN(matched {count}, expected 1)")
        return
    root = stage_go(app_text, text)
    r = subprocess.run([sys.executable, "tools/tpl-surfaces.py", root],
                       capture_output=True, text=True)
    shutil.rmtree(root)
    print(f"{name}=applied:1 rc:{r.returncode} named:{want in r.stdout}")


def run_csharp(name, app_text, text, count, want):
    if count != 1:
        print(f"{name}=SELFTEST-BROKEN(matched {count}, expected 1)")
        return
    root = stage_csharp(app_text, text)
    r = subprocess.run([sys.executable, "tools/tpl-surfaces.py", root],
                       capture_output=True, text=True)
    shutil.rmtree(root)
    print(f"{name}=applied:1 rc:{r.returncode} named:{want in r.stdout}")


def run_swift(name, app_text, text, count, want):
    if count != 1:
        print(f"{name}=SELFTEST-BROKEN(matched {count}, expected 1)")
        return
    root = stage_swift(app_text, text)
    r = subprocess.run([sys.executable, "tools/tpl-surfaces.py", root],
                       capture_output=True, text=True)
    shutil.rmtree(root)
    print(f"{name}=applied:1 rc:{r.returncode} named:{want in r.stdout}")


def stage_ocaml(app_text, ml_text):
    root = stage(app_text)
    os.unlink(f"{root}/bindings")
    link_children("bindings", f"{root}/bindings", "ocaml")
    link_children("bindings/ocaml", f"{root}/bindings/ocaml", "kaya_app.ml")
    open(f"{root}/bindings/ocaml/kaya_app.ml", "w",
         encoding="utf-8").write(ml_text)
    return root


def run_ocaml(name, app_text, text, count, want):
    if count != 1:
        print(f"{name}=SELFTEST-BROKEN(matched {count}, expected 1)")
        return
    root = stage_ocaml(app_text, text)
    r = subprocess.run([sys.executable, "tools/tpl-surfaces.py", root],
                       capture_output=True, text=True)
    shutil.rmtree(root)
    print(f"{name}=applied:1 rc:{r.returncode} named:{want in r.stdout}")


def stage_haskell(app_text, haskell_text):
    root = stage(app_text)
    os.unlink(f"{root}/bindings")
    link_children("bindings", f"{root}/bindings", "haskell")
    link_children("bindings/haskell", f"{root}/bindings/haskell", "KayaApp.hs")
    open(f"{root}/bindings/haskell/KayaApp.hs", "w",
         encoding="utf-8").write(haskell_text)
    return root


def run_haskell(name, app_text, text, count, want):
    if count != 1:
        print(f"{name}=SELFTEST-BROKEN(matched {count}, expected 1)")
        return
    root = stage_haskell(app_text, text)
    r = subprocess.run([sys.executable, "tools/tpl-surfaces.py", root],
                       capture_output=True, text=True)
    shutil.rmtree(root)
    print(f"{name}=applied:1 rc:{r.returncode} named:{want in r.stdout}")


def run_python_with_checks(name, app_text, text, count, surface_want, check_want):
    if count != 1:
        print(f"{name}=SELFTEST-BROKEN(matched {count}, expected 1)")
        return
    root = stage_python(app_text, text)
    surface = subprocess.run(
        [sys.executable, "tools/tpl-surfaces.py", root],
        capture_output=True, text=True,
    )
    env = os.environ.copy()
    env["PYTHONPATH"] = f"{root}/bindings/python"
    checks = subprocess.run(
        [sys.executable, "-m", "kaya_app_checks"],
        cwd=root, env=env, capture_output=True, text=True,
    )
    shutil.rmtree(root)
    print(
        f"{name}=applied:1 surface-rc:{surface.returncode} "
        f"surface-named:{surface_want in surface.stdout} "
        f"checks-rc:{checks.returncode} checks-named:{check_want in checks.stdout}"
    )


src = open("crates/kaya/src/app.rs", encoding="utf-8").read()
text, n = scoped(src,
                 "impl<I: for_scope::Id> Rows<'_, '_, I> {",
                 "impl Rows<'_, '_, WidgetId> {",
                 "    pub fn columns(", "    pub fn columns_removed(")
run("rust-columns", text or src, n,
    "rust's TEMPLATE-zone table cannot spell columns")

text, n = scoped(src,
                 "impl Rows<'_, '_, TemplateNodeId> {",
                 "/// The header bar's sort indicator",
                 "        f: impl Fn(Path, u32) -> M + 'static,",
                 "        f: impl Fn(u32) -> M + 'static,")
run("rust-sort", text or src, n,
    "rust's TEMPLATE-zone table cannot spell on_sort")

old = "    pub fn columns_at("
n = src.count(old)
run("rust-keyed", src.replace(old, "    pub fn columns_at_removed(") if n == 1 else src,
    n, "rust's TEMPLATE-zone table cannot spell keyed re-declaration")

# GO. The zone marker is the RECEIVER — `func (r *Rows) Columns` and
# `func (r *NodeRows) Columns` are two surfaces spelled the same — so
# every needle below carries one, and each is unique in the file.
go = open("bindings/go/app.go", encoding="utf-8").read()
go_points = (
    ("go-columns", "columns",
     "func (r *NodeRows) Columns(titles []string, sort Sort) *NodeRows {",
     "func (r *NodeRows) ColumnsRemoved(titles []string, sort Sort) *NodeRows {"),
    ("go-columns-path", "columns",
     "\t\ttx.emit(TxSetColumnHeaders(st.id, st.bar.sort.sorted, st.bar.sort.direction,\n"
     "\t\t\tuint32(len(st.bar.titles)), 0, titleValues(st.bar.titles)))",
     "\t\ttx.emit(TxSetColumnHeaders(st.id, st.bar.sort.sorted, st.bar.sort.direction,\n"
     "\t\t\tuint32(len(st.bar.titles)), 1, titleValues(st.bar.titles)))"),
    ("go-nested-for", "columns",
     "func (t *Tpl) Rows(c Collection) *NodeRows {",
     "func (t *Tpl) RowsRemoved(c Collection) *NodeRows {"),
    ("go-sort", "on_sort",
     "func (a *App) OnSortNode(n Node, fn func(*Tx, []any, uint32)) {",
     "func (a *App) OnSortNode(n Node, fn func(*Tx, uint32)) {"),
    ("go-sort-chain", "on_sort",
     "\tr.st.tx.app.OnSortNode(r.Node(), fn)",
     "\tr.st.tx.app.OnSortNode(Node{}, fn)"),
    ("go-sort-dispatch", "on_sort",
     "a.dispatch(func(tx *Tx) { fn(tx, keys, column) })",
     "a.dispatch(func(tx *Tx) { fn(tx, nil, column) })"),
    ("go-node-handle", "keyed re-declaration",
     "func (r *NodeRows) Node() Node {",
     "func (r *NodeRows) NodeRemoved() Node {"),
    ("go-keyed", "keyed re-declaration",
     "func (tx *Tx) ColumnsAt(n Node, keys []any, titles []string, sort Sort) {",
     "func (tx *Tx) ColumnsAtRemoved(n Node, keys []any, titles []string, sort Sort) {"),
    ("go-keyed-order", "keyed re-declaration",
     "\tvalues = append(values, keys...)\n"
     "\tfor _, title := range titles {\n\t\tvalues = append(values, title)\n\t}\n",
     "\tfor _, title := range titles {\n\t\tvalues = append(values, title)\n\t}\n"
     "\tvalues = append(values, keys...)\n"),
    ("go-keyed-pathlen", "keyed re-declaration",
     "\t\tuint32(len(titles)), uint32(len(keys)), values))",
     "\t\tuint32(len(titles)), 0, values))"),
)
for name, point, old, new in go_points:
    n = go.count(old)
    run_go(name, src, go.replace(old, new, 1) if n == 1 else go, n,
           f"go's TEMPLATE-zone table cannot spell {point}")

# And the reader itself: with the dispatch switch's own function gone it
# must report a zone it could not READ, never an empty one.
old = "func (a *App) Serve() {"
n = go.count(old)
run_go("go-reader", src,
       go.replace(old, "func (a *App) ServeRemoved() {", 1) if n == 1 else go,
       n, "cannot find go's dynamic-table zones")

# C# spells both zones as OVERLOADS, so every deletion below is scoped
# to one class block and the live Columns/OnSort stay where they are.
cs = open("bindings/csharp/KayaApp.cs", encoding="utf-8").read()

text, n = scoped(cs, "sealed class Tpl", "sealed class CopyRef",
                 "    public void Columns(", "    public void ColumnsRemoved(")
run_csharp("csharp-columns", src, text or cs, n,
           "csharp's TEMPLATE-zone table cannot spell columns")

text, n = scoped(
    cs, "sealed class KayaApp", "sealed class Tx",
    "    public void OnSort(Node n, Action<Tx, List<object>, uint> handler) =>",
    "    public void OnSortRemoved(Node n, Action<Tx, List<object>, uint> handler) =>")
run_csharp("csharp-sort", src, text or cs, n,
           "csharp's TEMPLATE-zone table cannot spell on_sort")

# The half a signature census cannot see, twice: drop the live arm's
# guard and every stamped copy's request is answered by the live table
# instead; drop the keys from the node arm's call and the handler can no
# longer say which copy fired.
text, n = scoped(
    cs, "sealed class KayaApp", "sealed class Tx",
    "kind == KayaWire.OccKindSortRequested && keys.Count == 0)",
    "kind == KayaWire.OccKindSortRequested)")
run_csharp("csharp-sort-arm", src, text or cs, n,
           "csharp's TEMPLATE-zone table cannot spell on_sort")

text, n = scoped(
    cs, "sealed class KayaApp", "sealed class Tx",
    "fn(tx, keys, column)", "fn(tx, column)")
run_csharp("csharp-sort-keys", src, text or cs, n,
           "csharp's TEMPLATE-zone table cannot spell on_sort")

text, n = scoped(
    cs, "sealed class Tx", "sealed class Tpl",
    "    public void Columns(Node n, IReadOnlyList<object> keys,",
    "    public void ColumnsAt(Node n, IReadOnlyList<object> keys,")
run_csharp("csharp-keyed", src, text or cs, n,
           "csharp's TEMPLATE-zone table cannot spell keyed re-declaration")

text, n = scoped(
    cs, "sealed class Tx", "sealed class Tpl",
    "(uint)titles.Length, (uint)keys.Count,", "(uint)titles.Length, 0,")
run_csharp("csharp-keyed-len", src, text or cs, n,
           "csharp's TEMPLATE-zone table cannot spell keyed re-declaration")

old = "sealed class Tpl"
n = cs.count(old)
run_csharp("csharp-reader", src,
           cs.replace(old, "sealed class TplRemoved") if n == 1 else cs,
           n, "cannot find csharp's dynamic-table zones")

# OCaml namespaces the template zone by SCOPE, so each half is deleted
# on the side it must live on: the declaration AND its ~on_sort inside
# `module Tpl`, the keyed re-declaration outside it. The handler is a
# LABELLED ARGUMENT on the declaration since 2026-08-24 (the binding
# spells a click that way), so the sort clauses perturb the same block
# the bar's do — never the name, which the live `columns` also carries.
ml = open("bindings/ocaml/kaya_app.ml", encoding="utf-8").read()
TPL = ("module Tpl = struct", "let on_click app (Widget id)")
columns_want = "ocaml's TEMPLATE-zone table cannot spell columns"
sort_want = "ocaml's TEMPLATE-zone table cannot spell on_sort"
keyed_want = "ocaml's TEMPLATE-zone table cannot spell keyed re-declaration"

text, n = scoped(ml, *TPL,
                 "  let columns\n      ?(on_sort :",
                 "  let columns_removed\n      ?(on_sort :")
run_ocaml("ocaml-columns", src, text or ml, n, columns_want)

text, n = scoped(ml, *TPL,
                 "         (List.length titles) 0",
                 "         (List.length titles) 1")
run_ocaml("ocaml-columns-pathlen", src, text or ml, n, columns_want)

# menu_selected_node is the one table with the same value type, so it is
# the only wrong table the compiler would let through.
text, n = scoped(ml, *TPL,
                 "Hashtbl.replace tx.app.node_sorts id handler",
                 "Hashtbl.replace tx.app.menu_selected_node id handler")
run_ocaml("ocaml-sort-table", src, text or ml, n, sort_want)

# And the argument itself: a `columns` that takes no handler declares a
# bar nothing can answer, which is precisely the surface this zone had
# before the labelled argument arrived.
text, n = scoped(ml, *TPL,
                 "  let columns\n      ?(on_sort : (Kaya_wire.value list -> "
                 "int -> unit) option)\n      (Node id) titles sort =",
                 "  let columns (Node id) titles sort =")
run_ocaml("ocaml-sort-arg", src, text or ml, n, sort_want)

text, n = scoped(ml, "if kind = Kaya_wire.occ_kind_sort_requested then",
                 "else if kind = Kaya_wire.occ_kind_text_changed then",
                 "Hashtbl.find_opt app.node_sorts id",
                 "Hashtbl.find_opt app.node_handlers id")
run_ocaml("ocaml-sort-dispatch", src, text or ml, n, sort_want)

KEYED = ("let columns_at (Node id) keys titles sort =", "(* Sums: a variant type")
text, n = scoped(ml, *KEYED,
                 "       (keys @ List.map (fun t -> Kaya_wire.Str t) titles))",
                 "       (List.map (fun t -> Kaya_wire.Str t) titles @ keys))")
run_ocaml("ocaml-keyed-order", src, text or ml, n, keyed_want)

text, n = scoped(ml, *KEYED,
                 "       (List.length titles) (List.length keys)",
                 "       (List.length titles) 0")
run_ocaml("ocaml-keyed-len", src, text or ml, n, keyed_want)

old = "module Tpl = struct"
n = ml.count(old)
run_ocaml("ocaml-reader", src,
          ml.replace(old, "module TplRemoved = struct") if n == 1 else ml,
          n, "cannot find ocaml's dynamic-table zones")

py = open("bindings/python/kaya/__init__.py", encoding="utf-8").read()
row_points = (
    (
        "grow", "_grow", "grow",
        "wire.tx_set_grow(self._template.handle.id, float(self._grow))",
        "wire.tx_removed_set_grow(self._template.handle.id, float(self._grow))",
        "ordinary For grow", "FAIL rows(grow=) reaches its For",
    ),
    (
        "align", "_align", "align",
        "wire.tx_set_align(self._template.handle.id, _align_value(self._align))",
        "wire.tx_removed_set_align(self._template.handle.id, _align_value(self._align))",
        "ordinary For align", "FAIL rows(align=) reaches its For",
    ),
    (
        # The handle setter, not a const emitter: `rows(a11y_id=row.key)`
        # must reach the ELEMENT arm (tools/tpl-surfaces.py says why).
        "a11y", "_a11y_id", "a11y_id",
        "self._template.handle.a11y_id(self._a11y_id)",
        "self._template.handle.a11y_removed_id(self._a11y_id)",
        "ordinary For a11y id", "FAIL rows(a11y_id=) reaches its For",
    ),
)
for name, field, arg, emitter, broken, point, check_want in row_points:
    surface_want = f"python's TEMPLATE-zone table cannot spell {point}"
    text, n = scoped(
        py, "class Collection(_BoundCollection):", "class _Scope:",
        f"        trace.{field} = {arg}", f"        trace.{field} = None",
    )
    run_python_with_checks(
        f"python-rows-{name}", src, text or py, n, surface_want, check_want,
    )
    text, n = scoped(
        py, "class _ForTrace:", "def _alloc_widget_or_node", emitter, broken,
    )
    run_python(
        f"python-rows-{name}-emitter", src, text or py, n, surface_want,
    )

text, n = scoped(py,
                 "class Collection(_BoundCollection):", "class _Scope:",
                 "    def columns(", "    def columns_removed(")
run_python("python-columns", src, text or py, n,
           "python's TEMPLATE-zone table cannot spell columns")

text, n = scoped(
    py, "class _ColumnsTrace:", "class PickedFile:",
    "                _app._register(handle, wire.OCC_SORT_REQUESTED, self._on_sort)",
    "                _app._register(handle, wire.OCC_SORT_REMOVED, self._on_sort)")
run_python("python-sort", src, text or py, n,
           "python's TEMPLATE-zone table cannot spell on_sort")

text, n = scoped(py, "    def set_columns(", "    def _absorb_key(",
                 "len(self._path)", "0")
run_python("python-keyed-len", src, text or py, n,
           "python's TEMPLATE-zone table cannot spell keyed re-declaration")

text, n = scoped(py, "    def set_columns(", "    def _absorb_key(",
                 "[*self._path, *titles]", "[*titles, *self._path]")
run_python("python-keyed-order", src, text or py, n,
           "python's TEMPLATE-zone table cannot spell keyed re-declaration")

old = "class _BoundCollection:"
n = py.count(old)
run_python("python-reader", src,
           py.replace(old, "class _BoundCollectionRemoved:") if n == 1 else py,
           n, "cannot find python's dynamic-table zones")

# SWIFT. Every point here is an OVERLOAD of a name the live zone also
# has (`columns` on two classes, `onSort` twice on one), so each
# perturbation leaves the live spelling untouched: a clause that came
# back green would be reading the wrong one.
sw = open("bindings/swift/KayaApp.swift", encoding="utf-8").read()
tpl_bar = "    func columns(_ n: KayaNodeHandle, _ titles: [String], _ sort: KayaSort) {"
n = sw.count(tpl_bar)
run_swift("swift-columns", src,
          sw.replace(tpl_bar, tpl_bar.replace("func columns(", "func columnsRemoved("))
          if n == 1 else sw,
          n, "swift's TEMPLATE-zone table cannot spell columns")

text, n = scoped(sw, tpl_bar,
                 "    func forEach<R>(_ c: KayaCollection, _ body: (KayaTpl) -> R)",
                 "UInt32(titles.count), 0,", "UInt32(titles.count), 1,")
run_swift("swift-columns-pathlen", src, text or sw, n,
          "swift's TEMPLATE-zone table cannot spell columns")

old = ("        _ n: KayaNodeHandle, "
       "_ handler: @escaping (KayaAppTx, [KayaValue], UInt32) throws -> Void")
n = sw.count(old)
run_swift("swift-sort-keys", src,
          sw.replace(old, old.replace("[KayaValue], ", "")) if n == 1 else sw,
          n, "swift's TEMPLATE-zone table cannot spell on_sort")

old = "            case (UInt16(KAYA_OCCURRENCE_SORT_REQUESTED), false):"
n = sw.count(old)
run_swift("swift-sort-dispatch", src,
          sw.replace(old, old.replace("SORT_REQUESTED", "SORT_REMOVED"))
          if n == 1 else sw,
          n, "swift's TEMPLATE-zone table cannot spell on_sort")

keyed = "    func columns(\n        _ n: KayaNodeHandle, at path:"
n = sw.count(keyed)
run_swift("swift-keyed", src,
          sw.replace(keyed, keyed.replace("func columns(", "func columnsRemoved("))
          if n == 1 else sw,
          n, "swift's TEMPLATE-zone table cannot spell keyed re-declaration")

text, n = scoped(sw, keyed, "    func bindText(",
                 "UInt32(path.count)", "0")
run_swift("swift-keyed-len", src, text or sw, n,
          "swift's TEMPLATE-zone table cannot spell keyed re-declaration")

text, n = scoped(sw, keyed, "    func bindText(",
                 "path + titles.map { .str($0) })", "titles.map { .str($0) } + path)")
run_swift("swift-keyed-order", src, text or sw, n,
          "swift's TEMPLATE-zone table cannot spell keyed re-declaration")

# count and path_len are BOTH UInt32 — the compiler cannot see them
# swapped, so this clause is the only reader that can.
text, n = scoped(sw, keyed, "    func bindText(",
                 "UInt32(titles.count), UInt32(path.count),",
                 "UInt32(path.count), UInt32(titles.count),")
run_swift("swift-keyed-swap", src, text or sw, n,
          "swift's TEMPLATE-zone table cannot spell keyed re-declaration")

old = "final class KayaTpl {"
n = sw.count(old)
run_swift("swift-reader", src,
          sw.replace(old, "final class KayaTplRemoved {") if n == 1 else sw,
          n, "cannot find swift's dynamic-table zones")
# HASKELL'S ZONE IS ITS TYPE (KayaApp.hs is one flat namespace), and
# since the module's header rule reached every paired registrar — the
# `*Node` twins are gone, one name dispatches on the handle — the zone is
# WHICH SCOPE the arm sits in. So the first perturbation of each pair
# takes the signature's zone away with the NAME LEFT ALONE: a reader that
# keyed on the name, or one that read the LIVE arm one scope up, would
# stay green there, which is the defect tools/tpl-surfaces.py exists to
# avoid.
hs = open("bindings/haskell/KayaApp.hs", encoding="utf-8").read()
haskell_want = "haskell's TEMPLATE-zone table cannot spell "

# `columns` back to a live-only signature inside `Declare` itself: the
# name still stands in the class, and both instances still spell it.
text, n = scoped(hs, "class Monad m => Declare m where", "instance Declare Build where",
                 "  columns :: El m -> [String] -> Sort -> m ()",
                 "  columns :: Widget -> [String] -> Sort -> Build ()")
run_haskell("haskell-columns-zone", src, text or hs, n, haskell_want + "columns")

# The TEMPLATE instance's arm deleted outright — the shape the live arm
# hides, since `instance Declare Build` keeps spelling `columns`.
text, n = scoped(hs, "instance Declare Tpl where", "-- Live-zone-only vocabulary.",
                 "  -- pathLen 0 against a TEMPLATE NODE: every copy's bar.\n"
                 "  columns (Node n) titles sort =\n",
                 "  columnsRemoved (Node n) titles sort =\n")
run_haskell("haskell-columns-tpl", src, text or hs, n, haskell_want + "columns")

text, n = scoped(hs, "instance Declare Tpl where", "-- Live-zone-only vocabulary.",
                 "(fromIntegral (length titles))\n          0\n",
                 "(fromIntegral (length titles))\n          1\n")
run_haskell("haskell-columns-path", src, text or hs, n, haskell_want + "columns")

text, n = scoped(hs, "instance HandlerTarget Node where",
                 "representationOf :: Maybe W.ClipValues",
                 "(appNodeSorts app)", "(appSortHandlers app)")
run_haskell("haskell-sort-registrar", src, text or hs, n, haskell_want + "on_sort")

# The SORT ARM alone taken out of the node instance, with the other five
# registrars and appNodeSorts' neighbours left standing: one class holds
# all six now, so a clause that only asked whether the instance exists
# would read green here.
text, n = scoped(hs, "instance HandlerTarget Node where",
                 "representationOf :: Maybe W.ClipValues",
                 "  onSort app (Node n) handler =\n"
                 "    modifyIORef' (appNodeSorts app) (Map.insert n handler)\n",
                 "")
run_haskell("haskell-sort-arm", src, text or hs, n, haskell_want + "on_sort")

# The copy's keys taken out of the ASSOCIATED TYPE: the node instance
# still exists, still registers in appNodeSorts, and now promises the
# live zone's handler — for every verb at once, since `Keyed` states that
# rule ONCE for all six.
text, n = scoped(hs, "instance HandlerTarget Node where",
                 "representationOf :: Maybe W.ClipValues",
                 "  type Keyed Node p = [W.Value] -> p",
                 "  type Keyed Node p = p")
run_haskell("haskell-sort-handler", src, text or hs, n, haskell_want + "on_sort")

text, n = scoped(
    hs,
    "| kind == W.occKindSortRequested -> do",
    "| kind == W.occKindTextChanged -> do",
    "            _ -> do\n"
    "              handlers <- readIORef (appNodeSorts app)\n"
    "              dispatch (mapM_ (\\h -> h keys column) (Map.lookup ident handlers))\n",
    "            _ -> return ()\n")
run_haskell("haskell-sort-dispatch", src, text or hs, n, haskell_want + "on_sort")

text, n = scoped(hs, "columnsAt :: Node", "-- Sums: the data declaration is the sum.",
                 "(fromIntegral (length keys))", "0")
run_haskell("haskell-keyed-len", src, text or hs, n,
            haskell_want + "keyed re-declaration")

text, n = scoped(hs, "columnsAt :: Node", "-- Sums: the data declaration is the sum.",
                 "(keys ++ map W.VStr titles)", "(map W.VStr titles ++ keys)")
run_haskell("haskell-keyed-order", src, text or hs, n,
            haskell_want + "keyed re-declaration")

old = "dispatchLoop :: App -> IO ()"
n = hs.count(old)
run_haskell("haskell-reader", src,
            hs.replace(old, "dispatchLoopRemoved :: App -> IO ()") if n == 1 else hs,
            n, "cannot find haskell's dynamic-table zones")
PROBE
)
want_table_probe="rust-columns=applied:1 rc:1 named:True
rust-sort=applied:1 rc:1 named:True
rust-keyed=applied:1 rc:1 named:True
go-columns=applied:1 rc:1 named:True
go-columns-path=applied:1 rc:1 named:True
go-nested-for=applied:1 rc:1 named:True
go-sort=applied:1 rc:1 named:True
go-sort-chain=applied:1 rc:1 named:True
go-sort-dispatch=applied:1 rc:1 named:True
go-node-handle=applied:1 rc:1 named:True
go-keyed=applied:1 rc:1 named:True
go-keyed-order=applied:1 rc:1 named:True
go-keyed-pathlen=applied:1 rc:1 named:True
go-reader=applied:1 rc:1 named:True
csharp-columns=applied:1 rc:1 named:True
csharp-sort=applied:1 rc:1 named:True
csharp-sort-arm=applied:1 rc:1 named:True
csharp-sort-keys=applied:1 rc:1 named:True
csharp-keyed=applied:1 rc:1 named:True
csharp-keyed-len=applied:1 rc:1 named:True
csharp-reader=applied:1 rc:1 named:True
ocaml-columns=applied:1 rc:1 named:True
ocaml-columns-pathlen=applied:1 rc:1 named:True
ocaml-sort-table=applied:1 rc:1 named:True
ocaml-sort-arg=applied:1 rc:1 named:True
ocaml-sort-dispatch=applied:1 rc:1 named:True
ocaml-keyed-order=applied:1 rc:1 named:True
ocaml-keyed-len=applied:1 rc:1 named:True
ocaml-reader=applied:1 rc:1 named:True
python-rows-grow=applied:1 surface-rc:1 surface-named:True checks-rc:1 checks-named:True
python-rows-grow-emitter=applied:1 rc:1 named:True
python-rows-align=applied:1 surface-rc:1 surface-named:True checks-rc:1 checks-named:True
python-rows-align-emitter=applied:1 rc:1 named:True
python-rows-a11y=applied:1 surface-rc:1 surface-named:True checks-rc:1 checks-named:True
python-rows-a11y-emitter=applied:1 rc:1 named:True
python-columns=applied:1 rc:1 named:True
python-sort=applied:1 rc:1 named:True
python-keyed-len=applied:1 rc:1 named:True
python-keyed-order=applied:1 rc:1 named:True
python-reader=applied:1 rc:1 named:True
swift-columns=applied:1 rc:1 named:True
swift-columns-pathlen=applied:1 rc:1 named:True
swift-sort-keys=applied:1 rc:1 named:True
swift-sort-dispatch=applied:1 rc:1 named:True
swift-keyed=applied:1 rc:1 named:True
swift-keyed-len=applied:1 rc:1 named:True
swift-keyed-order=applied:1 rc:1 named:True
swift-keyed-swap=applied:1 rc:1 named:True
swift-reader=applied:1 rc:1 named:True
haskell-columns-zone=applied:1 rc:1 named:True
haskell-columns-tpl=applied:1 rc:1 named:True
haskell-columns-path=applied:1 rc:1 named:True
haskell-sort-registrar=applied:1 rc:1 named:True
haskell-sort-arm=applied:1 rc:1 named:True
haskell-sort-handler=applied:1 rc:1 named:True
haskell-sort-dispatch=applied:1 rc:1 named:True
haskell-keyed-len=applied:1 rc:1 named:True
haskell-keyed-order=applied:1 rc:1 named:True
haskell-reader=applied:1 rc:1 named:True"
if [ "$tpl_table_probe" != "$want_table_probe" ]; then
    echo "check-sugar-surface: SELF-TEST FAIL (the dynamic-table census" \
        "did not catch its watched deletions). Wanted:" >&2
    echo "$want_table_probe" >&2
    echo "Got:" >&2
    echo "$tpl_table_probe" >&2
    exit 1
fi
echo "check-sugar-surface: dynamic-table perturbations applied:"
echo "$tpl_table_probe"
unset tpl_table_probe want_table_probe

# (c2b) AND THE HASKELL SPELLING IS COMPILED. The census above reads
#       text; Haskell states the zone and the copy's key path in TYPES,
#       so only a typecheck says the three surfaces fit together. This is
#       the compile_fail doc-test's shape in the one form this binding
#       has: tools/checks/haskell-table/NestedTable.hs must compile, and
#       the three mistakes it exists to stop must not.
hs_table_probe=$(python3 - <<'PROBE'
import shutil
import subprocess
import tempfile

FIXTURE = "tools/checks/haskell-table/NestedTable.hs"
src = open(FIXTURE, encoding="utf-8").read()
tmp = tempfile.mkdtemp()


def typecheck(module, text):
    path = f"{tmp}/{module}.hs"
    with open(path, "w", encoding="utf-8") as out:
        out.write(text.replace("module NestedTable", f"module {module}"))
    r = subprocess.run(
        ["ghc", "-fno-code", "-XGHC2021", "-ibindings/haskell",
         "-hidir", f"{tmp}/hi", "-odir", f"{tmp}/hi", path],
        capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


rc, log = typecheck("NestedTable", src)
print(f"fixture=rc:{rc}")
if rc != 0:
    print(log)

# Each is a mistake the types are the wall for: declaring the nested
# bar in the parent's LIVE scope, a handler that drops the copy's keys,
# and a re-declaration that drops them.
for module, old, new in (
    # ONE NAME, TWO ZONES, so the zone wall is no longer a wrong NAME —
    # it is the same call moved out of the template scope, where `m` is
    # Build and `El Build` is Widget while the inner For handed back a
    # Node. The move is the mistake this is here to stop: the core finds
    # the For in the scope that is still open.
    ("ZoneWall",
     '      columns t ["Symbol", "Shares"] sortNone\n'
     '      _ <- columnOf [label element, pure t]\n'
     '      return (t, positions)\n'
     '    root <- row [pure accountList]\n',
     '      _ <- columnOf [label element, pure t]\n'
     '      return (t, positions)\n'
     '    columns table ["Symbol", "Shares"] sortNone\n'
     '    root <- row [pure accountList]\n'),
    # The whole handler, so the perturbation is a TYPE error and not a
    # `keys` left dangling out of scope: dropping the copy's keys binds
    # the path where the column belongs.
    ("HandlerPath",
     '  onSort app table $ \\keys column ->\n'
     '    submitTx app (columnsAt table keys ["Symbol", "Shares"] (sortAsc column))\n',
     '  onSort app table $ \\column ->\n'
     '    submitTx app (columnsAt table [] ["Symbol", "Shares"] (sortAsc column))\n'),
    ("RedeclarePath",
     'columnsAt table keys ["Symbol", "Shares"]',
     'columnsAt table ["Symbol", "Shares"]'),
    # The rows go SCALAR: a nested plain `collection` reaches forEach but
    # not recordHandle, which is the shape this fixture used to have
    # (docs/deferred.md, the nested RECORD collection entry).
    ("ScalarNested",
     "      positions <- collectionOf (Proxy :: Proxy Position)",
     "      positions <- collection"),
    # The key path taken on the UNTYPED handle: the copy is addressed and
    # the element type is gone with it, so no record mutation can reach
    # one stamped table's rows.
    ("UntypedInstance",
     "    insertRecord (positions ",
     "    insertRecord (recordHandle positions "),
):
    n = src.count(old)
    if n != 1:
        print(f"{module}=SELFTEST-BROKEN(matched {n}, expected 1)")
        continue
    rc, log = typecheck(module, src.replace(old, new))
    print(f"{module}=applied:1 rc:{rc} type-error:{'Couldn' in log}")

shutil.rmtree(tmp)
PROBE
)
want_hs_table_probe="fixture=rc:0
ZoneWall=applied:1 rc:1 type-error:True
HandlerPath=applied:1 rc:1 type-error:True
RedeclarePath=applied:1 rc:1 type-error:True
ScalarNested=applied:1 rc:1 type-error:True
UntypedInstance=applied:1 rc:1 type-error:True"
if [ "$hs_table_probe" != "$want_hs_table_probe" ]; then
    echo "check-sugar-surface: SELF-TEST FAIL (the haskell dynamic-table typecheck)." \
        "Wanted:" >&2
    echo "$want_hs_table_probe" >&2
    echo "Got:" >&2
    echo "$hs_table_probe" >&2
    exit 1
fi
echo "check-sugar-surface: haskell dynamic-table typecheck:"
echo "$hs_table_probe"
unset hs_table_probe want_hs_table_probe

# (c2c) THE ROW'S OWN FIELDS, watched from the BINDING side. A nested
#       table whose rows cannot carry record fields is the gap this
#       closes (docs/deferred.md, "GAP — Haskell cannot declare a nested
#       RECORD collection"): `collectionOf` must stand in the TEMPLATE
#       zone, since that is the only scope a nested collection may be
#       declared in, and narrowing the handle to one stamped copy must
#       keep the element type, since every record mutation takes
#       RecordCollection.
#
#       BOTH KINDS OF WALL ARE WATCHED, because neither sees the other's
#       failure: the census catches what a typecheck cannot (a record
#       collection born with the SCALAR schema, a key silently dropped on
#       the way to the copy — both compile), and ghc catches what text
#       cannot say (a Declare method left out of ONE instance is a
#       warning in GHC's default set; KayaApp.hs's -Werror=missing-methods
#       is what turns that into a red).
#
#       A block of its own, additive: these two files are merged by hand
#       across parallel worktrees.
hs_record_probe=$(python3 - <<'PROBE'
import os, shutil, subprocess, sys, tempfile

APP = "bindings/haskell/KayaApp.hs"
FIXTURE = "tools/checks/haskell-table/NestedTable.hs"
TABLE = "haskell's TEMPLATE-zone table cannot spell "

app = open(APP, encoding="utf-8").read()
fixture = open(FIXTURE, encoding="utf-8").read()
tmp = tempfile.mkdtemp()


def stage(text):
    """A temp repo root where only KayaApp.hs differs."""
    root = tempfile.mkdtemp()
    for top in os.listdir("."):
        if top != "bindings":
            os.symlink(os.path.abspath(top), f"{root}/{top}")
    for parent, keep in (("bindings", "haskell"),
                         ("bindings/haskell", "KayaApp.hs")):
        os.makedirs(f"{root}/{parent}", exist_ok=True)
        for entry in os.listdir(parent):
            if entry != keep:
                os.symlink(os.path.abspath(f"{parent}/{entry}"),
                           f"{root}/{parent}/{entry}")
    open(f"{root}/{APP}", "w", encoding="utf-8").write(text)
    return root


def census(name, old, new, point):
    n = app.count(old)
    if n != 1:
        print(f"{name}=SELFTEST-BROKEN(matched {n}, expected 1)")
        return
    root = stage(app.replace(old, new))
    r = subprocess.run([sys.executable, "tools/tpl-surfaces.py", root],
                       capture_output=True, text=True)
    shutil.rmtree(root)
    print(f"{name}=applied:1 rc:{r.returncode} named:{TABLE + point in r.stdout}")


def library(name, text):
    """The three-module binding with one doctored KayaApp.hs."""
    lib = f"{tmp}/{name}-lib"
    os.makedirs(lib, exist_ok=True)
    for module in ("KayaWire.hs", "KayaRuntime.hs"):
        shutil.copy(f"bindings/haskell/{module}", lib)
    open(f"{lib}/KayaApp.hs", "w", encoding="utf-8").write(text)
    return lib


def ghc(name, lib, target):
    out = f"{tmp}/{name}-out"
    os.makedirs(out, exist_ok=True)
    r = subprocess.run(
        ["ghc", "-fno-code", "-XGHC2021", "-i" + lib,
         "-hidir", out, "-odir", out, target],
        capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def compiles(name, old, new, markers, through_fixture):
    """A red is only a red if it is the RIGHT error, so each row names
    substrings the log must carry — a module whose name is not a Haskell
    identifier also exits 1, and did while this was being written."""
    n = app.count(old)
    if n != 1:
        print(f"{name}=SELFTEST-BROKEN(matched {n}, expected 1)")
        return
    module = "".join(part.capitalize() for part in name.split("-"))
    lib = library(module, app.replace(old, new))
    target = f"{lib}/KayaApp.hs"
    if through_fixture:
        target = f"{tmp}/{module}.hs"
        open(target, "w", encoding="utf-8").write(
            fixture.replace("module NestedTable", f"module {module}"))
    rc, log = ghc(module, lib, target)
    print(f"{name}=applied:1 rc:{rc} named:{all(m in log for m in markers)}")


# The census half. Each is a shape that compiles and lies.
census("haskell-record-zone",
       "  collectionOf :: KayaRecord a => Proxy a -> m (RecordCollection a)",
       "  collectionOf :: KayaRecord a => Proxy a -> Build (RecordCollection a)",
       "nested record collection")
# Watched here AS WELL AS by the compiler below: this census runs where
# no ghc does, so its own reading of the Tpl instance has to be seen red.
census("haskell-record-tpl",
       "  collection = Tpl (newCollection [[W.valueStr]])\n"
       "  collectionOf p = Tpl (newRecordCollection p)\n",
       "  collection = Tpl (newCollection [[W.valueStr]])\n",
       "nested record collection")
census("haskell-record-schema",
       "  let (c, s') = newCollection [kayaSchema p] s in (RecordCollection c, s')",
       "  let (c, s') = newCollection [[W.valueStr]] s in (RecordCollection c, s')",
       "nested record collection")
census("haskell-at-record",
       "  at (RecordCollection c) key = RecordCollection (at c key)",
       "  at (RecordCollection c) _ = RecordCollection c",
       "record instance addressing")

# The compiler half. The first is the pre-fix state exactly: the template
# zone without the record constructor.
compiles("haskell-tpl-method-gone",
         "  collection = Tpl (newCollection [[W.valueStr]])\n"
         "  collectionOf p = Tpl (newRecordCollection p)\n",
         "  collection = Tpl (newCollection [[W.valueStr]])\n",
         ("Werror=missing-methods", "Declare Tpl"), False)
compiles("haskell-record-at-gone",
         "instance CollectionHandle (RecordCollection a) where\n"
         "  at (RecordCollection c) key = RecordCollection (at c key)\n",
         "",
         ("No instance for", "CollectionHandle (RecordCollection"), True)

shutil.rmtree(tmp)
PROBE
)
want_hs_record_probe="haskell-record-zone=applied:1 rc:1 named:True
haskell-record-tpl=applied:1 rc:1 named:True
haskell-record-schema=applied:1 rc:1 named:True
haskell-at-record=applied:1 rc:1 named:True
haskell-tpl-method-gone=applied:1 rc:1 named:True
haskell-record-at-gone=applied:1 rc:1 named:True"
if [ "$hs_record_probe" != "$want_hs_record_probe" ]; then
    echo "check-sugar-surface: SELF-TEST FAIL (the haskell nested-record walls" \
        "did not catch their watched deletions). Wanted:" >&2
    echo "$want_hs_record_probe" >&2
    echo "Got:" >&2
    echo "$hs_record_probe" >&2
    exit 1
fi
echo "check-sugar-surface: haskell nested-record perturbations applied:"
echo "$hs_record_probe"
unset hs_record_probe want_hs_record_probe

# (c2e) THE ROW'S OWN FIELDS IN THE OTHER SEVEN. The Haskell block above
#       was written as a Haskell gap; the sweep that closed it found the
#       same two halves missing in five more bindings, and the census
#       reads all eight now (docs/deferred.md, closed 2026-08-25).
#
#       EACH PERTURBATION IS A SHAPE THAT COMPILES AND LIES, which is why
#       a census earns its keep here and a typecheck cannot stand in: a
#       template-zone constructor that opens its own transaction, a
#       narrowing that hands back a typed handle addressing the PARENT,
#       and Python's collection born without the open-For edge all build
#       and run. Both points are watched in every binding — fourteen
#       reds, the four Haskell ones being (c2c)'s.
#
#       A block of its own, additive: these two files are merged by hand
#       across parallel worktrees.
record_probe=$(python3 - <<'PROBE'
import os, shutil, subprocess, sys, tempfile


def link_children(source, destination, skip):
    os.makedirs(destination, exist_ok=True)
    for name in os.listdir(source):
        if name != skip:
            os.symlink(os.path.abspath(f"{source}/{name}"), f"{destination}/{name}")


def stage_one(rel, text):
    """A staged repo root where exactly `rel` differs from the tree.

    One helper rather than seven: the surfaces this block watches sit in
    six different files across five directory depths, and a per-language
    stager would be six copies of the same walk.
    """
    root = tempfile.mkdtemp()
    parts = rel.split("/")
    for top in os.listdir("."):
        if top != parts[0]:
            os.symlink(os.path.abspath(top), f"{root}/{top}")
    for i in range(1, len(parts)):
        link_children("/".join(parts[:i]),
                      f"{root}/" + "/".join(parts[:i]), parts[i])
    open(f"{root}/{rel}", "w", encoding="utf-8").write(text)
    return root


def census(name, rel, old, new, lang, point):
    src = open(rel, encoding="utf-8").read()
    n = src.count(old)
    if n != 1:
        print(f"{name}=SELFTEST-BROKEN(matched {n}, expected 1)")
        return
    root = stage_one(rel, src.replace(old, new))
    r = subprocess.run([sys.executable, "tools/tpl-surfaces.py", root],
                       capture_output=True, text=True)
    shutil.rmtree(root)
    want = f"{lang}'s TEMPLATE-zone table cannot spell {point}"
    print(f"{name}=applied:1 rc:{r.returncode} named:{want in r.stdout}")


RUST = "crates/kaya/src/app.rs"
GO = "bindings/go/records.go"
CS = "bindings/csharp/KayaRecords.cs"
JAVA = "bindings/java/dev/kaya/KayaRecords.java"
SWIFT_APP = "bindings/swift/KayaApp.swift"
SWIFT_REC = "bindings/swift/KayaRecords.swift"
ML = "bindings/ocaml/kaya_app.ml"
PY = "bindings/python/kaya/__init__.py"

census("rust-record-zone", RUST,
       "    pub fn collection<T: KayaSum>(&mut self) -> Collection<T> {\n"
       "        let id = self.tx.ctx.alloc_collection();",
       "    pub fn collection_removed<T: KayaSum>(&mut self) -> Collection<T> {\n"
       "        let id = self.tx.ctx.alloc_collection();",
       "rust", "nested record collection")
# The key DROPPED on the way to the copy: the handle stays Collection<T>
# and every mutation through it addresses the parent's table.
census("rust-record-at", RUST,
       "        let mut path = self.path.clone();\n        path.push(key.into());",
       "        let path = self.path.clone();",
       "rust", "record instance addressing")

# The zone handle IGNORED: a body that opens its own transaction declares
# the collection outside the template scope and the core refuses the
# nested For — at run time, on one platform, with the guest already built.
census("go-record-zone", GO,
       "func TplCollectionOf[K Key, T any](t *Tpl) RecordCollection[K, T] {\n"
       "\treturn newRecordCollection[K, T](t.tx)",
       "func TplCollectionOf[K Key, T any](t *Tpl) RecordCollection[K, T] {\n"
       "\treturn newRecordCollection[K, T](theTx())",
       "go", "nested record collection")
census("go-record-at", GO,
       "\treturn RecordCollection[K, T]{c.Collection.At(key), c.info}",
       "\treturn RecordCollection[K, T]{c.Collection, c.info}",
       "go", "record instance addressing")

census("csharp-record-zone", CS,
       "    public static RecordCollection<T> CollectionOf<T>(this Tpl t) => Declare<T>(t.Tx);",
       "",
       "csharp", "nested record collection")
# The PRE-FIX state exactly: the promoted untyped narrowing, which drops
# T and puts Insert/Patch/UpdateField out of reach.
census("csharp-record-at", CS,
       "    public RecordCollection<T> At(object key) =>\n"
       "        new RecordCollection<T>(Collection.At(key), Info);",
       "    public Collection At(object key) => Collection.At(key);",
       "csharp", "record instance addressing")

# The ROW SURFACE overload, which is the handle a Java scene actually
# holds: with only the Tpl one, `tx.rows(c)`'s body cannot spell it.
census("java-record-zone", JAVA,
       "    public static <K, T> Collection<K, T> collectionOf(KayaApp.RowSurface row, Class<T> type) {",
       "    public static <K, T> Collection<K, T> collectionOfRow(KayaApp.RowSurface row, Class<T> type) {",
       "java", "nested record collection")
census("java-record-at", JAVA,
       "            return new Collection<>(handle.at(key), info);",
       "            return new Collection<>(handle, info);",
       "java", "record instance addressing")

census("swift-record-zone", SWIFT_APP,
       "    func collection<T: KayaRecord>(of type: T.Type) -> KayaRecordCollection<T> {\n"
       "        tx.collection(of: type)\n    }",
       "",
       "swift", "nested record collection")
census("swift-record-at", SWIFT_REC,
       "        KayaRecordCollection(collection: collection.at(key))",
       "        KayaRecordCollection(collection: collection)",
       "swift", "record instance addressing")

census("ocaml-record-zone", ML,
       "  let collection_of rt = collection_of rt\n",
       "",
       "ocaml", "nested record collection")
census("ocaml-record-at", ML,
       "let record_at rc key = { rc with rc_handle = at rc.rc_handle key }",
       "let record_at rc _key = rc",
       "ocaml", "record instance addressing")

# Python's constructor is AMBIENT, so the open-For edge is the only thing
# that says a collection born inside a template belongs to the copies
# rather than to the live tree.
census("python-record-zone", PY,
       "        _for_collections[-1]._children.append(handle)",
       "        pass",
       "python", "nested record collection")
census("python-record-at", PY,
       "        return _BoundCollection(self, list(path))",
       "        return _BoundCollection(_app._collections[self._id], list(path))",
       "python", "record instance addressing")
PROBE
)
want_record_probe="rust-record-zone=applied:1 rc:1 named:True
rust-record-at=applied:1 rc:1 named:True
go-record-zone=applied:1 rc:1 named:True
go-record-at=applied:1 rc:1 named:True
csharp-record-zone=applied:1 rc:1 named:True
csharp-record-at=applied:1 rc:1 named:True
java-record-zone=applied:1 rc:1 named:True
java-record-at=applied:1 rc:1 named:True
swift-record-zone=applied:1 rc:1 named:True
swift-record-at=applied:1 rc:1 named:True
ocaml-record-zone=applied:1 rc:1 named:True
ocaml-record-at=applied:1 rc:1 named:True
python-record-zone=applied:1 rc:1 named:True
python-record-at=applied:1 rc:1 named:True"
if [ "$record_probe" != "$want_record_probe" ]; then
    echo "check-sugar-surface: SELF-TEST FAIL (the nested-record census did not" \
        "catch its watched perturbations). Wanted:" >&2
    echo "$want_record_probe" >&2
    echo "Got:" >&2
    echo "$record_probe" >&2
    exit 1
fi
echo "check-sugar-surface: nested-record perturbations applied (7 bindings):"
echo "$record_probe"
unset record_probe want_record_probe

# (c2d) THE ZONE-SPANNING SURFACES, watched from the COMPILER side. Every
#       `*Node` twin is gone — one name dispatches on the handle (the
#       module header's rule) — so what used to be a distinct NAME per
#       zone is now an arm inside a per-zone instance, and the wall that
#       keeps a template zone's arm from going missing is KayaApp.hs's
#       -Werror=missing-methods.
#
#       ALL SIX REGISTRARS SIT IN ONE CLASS for exactly that wall: a verb
#       in a class of its own could ship with the Node instance absent
#       and nothing here would compile red, because missing-methods sees
#       an incomplete instance and never a missing one. So the watch is
#       per zone rather than per verb — one deleted arm on each side.
#
#       THE ASSOCIATED TYPE IS A DIFFERENT RED, and that is why it is
#       watched beside them: dropping `type Keyed Node p` is a plain type
#       error, NOT a missing-methods one, so a session that goes looking
#       for the missing-methods sentence would not find it.
#
#       A block of its own, additive: these two files are merged by hand
#       across parallel worktrees.
hs_zone_probe=$(python3 - <<'PROBE'
import os, shutil, subprocess, tempfile

APP = "bindings/haskell/KayaApp.hs"
app = open(APP, encoding="utf-8").read()
tmp = tempfile.mkdtemp()

TPL_COLUMNS = """  -- pathLen 0 against a TEMPLATE NODE: every copy's bar.
  columns (Node n) titles sort =
    emitT
      ( W.txSetColumnHeaders
          n
          (sortColumn sort)
          (sortDirection sort)
          (fromIntegral (length titles))
          0
          (map W.VStr titles)
      )
"""

NODE_SORT = """  onSort app (Node n) handler =
    modifyIORef' (appNodeSorts app) (Map.insert n handler)
"""

WIDGET_PASTE = """  onPaste app (Widget n) handler =
    modifyIORef' (appWidgetPastes app) (Map.insert n handler)
"""


def compiles(name, old, new, markers):
    """A red is only a red if it is the RIGHT error, so each row names
    substrings the log must carry."""
    n = app.count(old)
    if n != 1:
        print(f"{name}=SELFTEST-BROKEN(matched {n}, expected 1)")
        return
    module = "".join(part.capitalize() for part in name.split("-"))
    lib = f"{tmp}/{module}-lib"
    out = f"{tmp}/{module}-out"
    os.makedirs(lib, exist_ok=True)
    os.makedirs(out, exist_ok=True)
    for module_file in ("KayaWire.hs", "KayaRuntime.hs"):
        shutil.copy(f"bindings/haskell/{module_file}", lib)
    with open(f"{lib}/KayaApp.hs", "w", encoding="utf-8") as fh:
        fh.write(app.replace(old, new))
    r = subprocess.run(
        ["ghc", "-fno-code", "-XGHC2021", "-i" + lib,
         "-hidir", out, "-odir", out, f"{lib}/KayaApp.hs"],
        capture_output=True, text=True)
    log = r.stdout + r.stderr
    print(f"{name}=applied:1 rc:{r.returncode} named:{all(m in log for m in markers)}")


# The header bar's TEMPLATE arm gone, with the live arm one scope up
# still spelling the name: the pre-unification `columnsNode`-only state.
compiles("haskell-tpl-columns-gone", TPL_COLUMNS, "",
         ("Werror=missing-methods", "columns", "Declare Tpl"))
# The node registrar gone, with the live one still there.
compiles("haskell-node-sort-gone", NODE_SORT, "",
         ("Werror=missing-methods", "onSort", "HandlerTarget Node"))
# AND THE OTHER DIRECTION, because the class spans both zones and only a
# per-zone watch can say so: the LIVE arm of a different verb gone, with
# the template arm still there.
compiles("haskell-widget-paste-gone", WIDGET_PASTE, "",
         ("Werror=missing-methods", "onPaste", "HandlerTarget Widget"))
# The handler's SHAPE gone: not missing-methods, a stuck family.
compiles("haskell-keyed-node-gone",
         "  type Keyed Node p = [W.Value] -> p\n", "",
         ("Couldn", "Keyed Node"))

shutil.rmtree(tmp)
PROBE
)
want_hs_zone_probe="haskell-tpl-columns-gone=applied:1 rc:1 named:True
haskell-node-sort-gone=applied:1 rc:1 named:True
haskell-widget-paste-gone=applied:1 rc:1 named:True
haskell-keyed-node-gone=applied:1 rc:1 named:True"
if [ "$hs_zone_probe" != "$want_hs_zone_probe" ]; then
    echo "check-sugar-surface: SELF-TEST FAIL (the haskell zone-spanning" \
        "walls did not catch their watched deletions). Wanted:" >&2
    echo "$want_hs_zone_probe" >&2
    echo "Got:" >&2
    echo "$hs_zone_probe" >&2
    exit 1
fi
echo "check-sugar-surface: haskell zone-spanning perturbations applied:"
echo "$hs_zone_probe"
unset hs_zone_probe want_hs_zone_probe

# (c3) JAVA'S DYNAMIC-TABLE READER, watched at each of its three points
#      and at the façade half that lets the for-statement form reach
#      them. A block of its own rather than more lines in (c2)'s: the six
#      remaining bindings land in parallel worktrees, and an additive
#      block is what merges.
tpl_table_java=$(python3 - <<'PROBE'
import os, shutil, subprocess, sys, tempfile

APP = "bindings/java/dev/kaya/KayaApp.java"
TPL = "    public final class Tpl {"
BUILD = "    public void build(Consumer<Tx> build) {"
TABLE = "java's TEMPLATE-zone table cannot spell "


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


def run(name, text, count, want):
    if count != 1:
        print(f"{name}=SELFTEST-BROKEN(matched {count}, expected 1)")
        return
    root = stage({APP: text})
    r = subprocess.run([sys.executable, "tools/tpl-surfaces.py", root],
                       capture_output=True, text=True)
    shutil.rmtree(root)
    print(f"{name}=applied:1 rc:{r.returncode} named:{want in r.stdout}")


def scoped(name, src, old, new, want):
    """A perturbation confined to the Tpl class: the same spelling in
    RowSurface and in the LIVE Tx stays, so a reader satisfied by either
    of those passes and a zone-scoped one cannot."""
    if src.count(TPL) != 1:
        print(f"{name}=SELFTEST-BROKEN(zone header matched {src.count(TPL)})")
        return
    at, end = src.index(TPL), src.index(BUILD, src.index(TPL))
    block = src[at:end]
    n = block.count(old)
    run(name, src[:at] + block.replace(old, new) + src[end:] if n == 1 else src,
        n, want)


def whole(name, src, old, new, want):
    n = src.count(old)
    run(name, src.replace(old, new) if n == 1 else src, n, want)


src = open(APP, encoding="utf-8").read()

scoped("java-columns", src,
       "    public void columns(Node ", "    public void columnsRemoved(Node ",
       TABLE + "columns")
scoped("java-columns-pathlen", src,
       "titles.length, 0, values)", "titles.length, 1, values)",
       TABLE + "columns")

whole("java-sort-keys", src,
      "void accept(Tx tx, List<Object> keys, int column);",
      "void accept(Tx tx, int column);", TABLE + "on_sort")
whole("java-sort-route", src,
      "nodeSorts.get(occ.id)", "nodeSortsRemoved.get(occ.id)",
      TABLE + "on_sort")

whole("java-keyed-order", src,
      "System.arraycopy(titles, 0, values, keys.size(), titles.length);",
      "System.arraycopy(titles, 0, values, 0, titles.length);",
      TABLE + "keyed re-declaration")
whole("java-keyed-len", src,
      "titles.length, keys.size(), values)", "titles.length, 0, values)",
      TABLE + "keyed re-declaration")

# The façade half: a forward deleted from RowSurface leaves the nested
# table unspellable from a row at all — `rows` is the only For form.
# THE READER HAD TO LEARN THE RETURN TYPE FIRST: read for Node and void
# alone it saw `rows` on NEITHER side and called the façade level, which
# was measured passing with this exact forward deleted (2026-08-24).
whole("java-facade-columns", src,
      "        public void columns(Node n, String[] titles, Sort sort) {\n"
      "            t.columns(n, titles, sort);\n        }\n", "",
      "does not forward: columns(Node, String[], Sort)")
whole("java-facade-rows", src,
      "        public Rows<Node, Row> rows(Collection c) {\n"
      "            return t.rows(c);\n        }\n", "",
      "does not forward: rows(Collection)")

# And the refusal: a reader that can no longer find the zone must say so
# rather than report a binding with nothing missing.
whole("java-reader", src, TPL + "\n", "    public final class TplRenamed {\n",
      "cannot find java's dynamic-table zones")
PROBE
)
want_table_java="java-columns=applied:1 rc:1 named:True
java-columns-pathlen=applied:1 rc:1 named:True
java-sort-keys=applied:1 rc:1 named:True
java-sort-route=applied:1 rc:1 named:True
java-keyed-order=applied:1 rc:1 named:True
java-keyed-len=applied:1 rc:1 named:True
java-facade-columns=applied:1 rc:1 named:True
java-facade-rows=applied:1 rc:1 named:True
java-reader=applied:1 rc:1 named:True"
if [ "$tpl_table_java" != "$want_table_java" ]; then
    echo "check-sugar-surface: SELF-TEST FAIL (the Java dynamic-table census did" \
        "not catch its watched deletions). Wanted:" >&2
    echo "$want_table_java" >&2
    echo "Got:" >&2
    echo "$tpl_table_java" >&2
    exit 1
fi
echo "check-sugar-surface: java dynamic-table perturbations applied:"
echo "$tpl_table_java"
unset tpl_table_java want_table_java

# (c4) C#'S GENERATED FAÇADE AND ITS TWIN. Both halves are emitted by
#      tools/kaya-csgen into every guests/csharp/*Kaya.cs at once, so a
#      perturbation lands in ONE staged file and the census must still
#      name it: the nested-For vocabulary the façade forwards (a row that
#      cannot open a For cannot name the Node whose bar Columns
#      declares), and the `Each(Tpl, …)` twin without which a nested
#      typed For's body holds the raw zone. docs/deferred.md, closed
#      2026-08-24. An additive block for the reason (c3) is one.
tpl_facade_csharp=$(python3 - <<'PROBE'
import os, shutil, subprocess, sys, tempfile

GEN = "guests/csharp/TableItemKaya.cs"


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


def run(name, text, count, want):
    if count != 1:
        print(f"{name}=SELFTEST-BROKEN(matched {count}, expected 1)")
        return
    root = stage({GEN: text})
    r = subprocess.run([sys.executable, "tools/tpl-surfaces.py", root],
                       capture_output=True, text=True)
    shutil.rmtree(root)
    print(f"{name}=applied:1 rc:{r.returncode} named:{want in r.stdout}")


def cut(name, old, want):
    n = src.count(old)
    run(name, src.replace(old, "") if n == 1 else src, n, want)


src = open(GEN, encoding="utf-8").read()

cut("csharp-facade-collection",
    "    public Collection Collection() => t.Collection();\n",
    "does not forward: Collection()")
cut("csharp-facade-each",
    "    public Node Each(Collection c, System.Action<Tpl> body) => t.Each(c, body);\n",
    "does not forward: Each(Collection, Action<Tpl>)")
cut("csharp-facade-foreach",
    "    public Node ForEach(Collection c,\n"
    "        System.Action<Tpl> body) =>\n        t.ForEach(c, body);\n",
    "does not forward: ForEach(Collection, Action<Tpl>)")
cut("csharp-facade-columns",
    "    public void Columns(Node n, string[] titles, Sort sort) =>\n"
    "        t.Columns(n, titles, sort);\n",
    "does not forward: Columns(Node, string[], Sort)")

# The typed sugar's two zones, one at a time.
cut("csharp-twin-nested",
    "    public static Node Each(Tpl t, RecordCollection<TableItem> c,\n"
    "        System.Action<TableItemRow> body) =>\n"
    "        t.Each(c.Collection, inner => body(new TableItemRow(inner)));\n",
    "has no Tpl-zone `Each` handing out `TableItemRow`")
cut("csharp-twin-live",
    "    public static Widget Each(Tx tx, RecordCollection<TableItem> c,\n"
    "        System.Action<TableItemRow> body) =>\n"
    "        tx.Each(c.Collection, t => body(new TableItemRow(t)));\n",
    "has no Tx-zone `Each` handing out `TableItemRow`")

# And the reader: with the row surface renamed, the twin census must
# report that it read FEWER generated surfaces than the tree carries
# rather than agreeing with a file it stopped seeing.
n = src.count("sealed class TableItemRow\n")
run("csharp-twin-reader",
    src.replace("sealed class TableItemRow\n", "sealed class TableItemRowGone\n")
    if n == 1 else src,
    n, "typed-row reader found only 2")
PROBE
)
want_facade_csharp="csharp-facade-collection=applied:1 rc:1 named:True
csharp-facade-each=applied:1 rc:1 named:True
csharp-facade-foreach=applied:1 rc:1 named:True
csharp-facade-columns=applied:1 rc:1 named:True
csharp-twin-nested=applied:1 rc:1 named:True
csharp-twin-live=applied:1 rc:1 named:True
csharp-twin-reader=applied:1 rc:1 named:True"
if [ "$tpl_facade_csharp" != "$want_facade_csharp" ]; then
    echo "check-sugar-surface: SELF-TEST FAIL (the C# generated-façade census" \
        "did not catch its watched deletions). Wanted:" >&2
    echo "$want_facade_csharp" >&2
    echo "Got:" >&2
    echo "$tpl_facade_csharp" >&2
    exit 1
fi
echo "check-sugar-surface: csharp generated-façade perturbations applied:"
echo "$tpl_facade_csharp"
unset tpl_facade_csharp want_facade_csharp

# (c2) AND THE GUEST THAT SPELLS THEM. The census above says Python CAN
#      spell the dynamic-table geometry; the portfolio guest is what
#      spells it, and invariant 5 is why the example is the exerciser.
#
#      STRUCTURAL, over the guest's AST. Byte-exact needles carrying
#      newlines and indentation used to stand here, and a pure reformat
#      reddened them with a sentence naming a property that was present
#      (the review of 01dd633, D6). Every probe below reformats the guest
#      through ast.unparse, so each one re-measures that: `reflow`
#      removes nothing and must come back GREEN, and the count of
#      byte-exact declaration segments surviving the reformat is printed
#      beside it.
#
#      Watched exactly like (d) and (e): a staged tree where one file
#      differs, the REAL census re-run as a SUBPROCESS against that root,
#      rc AND the exact sentence demanded. The clause it replaces
#      perturbed its own helper's input and asked the SAME helper —
#      nothing else observed it, so only str.count could fail.
portfolio_probe=$(python3 - <<'PROBE'
import ast, os, shutil, subprocess, sys, tempfile

PATH = "guests/python/portfolio.py"

CENSUS = r'''
import ast
import sys

PATH = "guests/python/portfolio.py"
tree = ast.parse(open(f"{sys.argv[1]}/{PATH}", encoding="utf-8").read(), PATH)
bad = []


def is_call(node, attr):
    return (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
            and node.func.attr == attr)


def columns_with(node, holds=None):
    return [n for n in ast.walk(node) if isinstance(n, ast.With)
            and any(is_call(i.context_expr, "column") for i in n.items)
            and (holds is None or holds in n.body)]


def opener(with_node):
    return next(i.context_expr for i in with_node.items
                if is_call(i.context_expr, "column"))


def sole(what, shape, found):
    if len(found) == 1:
        return found[0]
    bad.append(f"check-sugar-surface: cannot find portfolio's {what} — {len(found)} "
               f"{shape} in {PATH}, wanted exactly 1. A reader that cannot find "
               "its subject agrees with anything.")
    return None


def declares(call, what, name, want=None):
    """`want=None`: present, any expression — a handler is not a literal."""
    node = next((k.value for k in call.keywords if k.arg == name), None)
    if node is None:
        bad.append(f"check-sugar-surface: portfolio's {what} does not declare "
                   f"`{name}` ({PATH})")
        return
    if want is None:
        return
    try:
        value = ast.literal_eval(node)
    except (ValueError, SyntaxError):
        value = None
    if value != want:
        bad.append(f"check-sugar-surface: portfolio's {what} declares {name}="
                   f"{value!r}, wanted {want!r} ({PATH})")


rows = sole("account-row For", "`for … in ….rows(…)` loops",
            [n for n in ast.walk(tree)
             if isinstance(n, ast.For) and is_call(n.iter, "rows")])
if rows is not None:
    declares(rows.iter, "account-row For", "align", "stretch")
    declares(rows.iter, "account-row For", "a11y_id", "accounts")
    detail = sole("detail column", "`with ….column(…)` statements holding it",
                  columns_with(tree, holds=rows))
    if detail is not None:
        declares(opener(detail), "detail column", "grow", 1)
        declares(opener(detail), "detail column", "align", "stretch")
    card = sole("account card", "`with ….column(…)` statements inside it",
                columns_with(rows))
    if card is not None:
        declares(opener(card), "account card", "align", "stretch")
        table = sole("positions table", "`for … in ….columns(…)` loops inside it",
                     [n for n in ast.walk(card)
                      if isinstance(n, ast.For) and is_call(n.iter, "columns")])
        if table is not None:
            declares(table.iter, "positions table", "on_sort")
            declares(table.iter, "positions table", "a11y_id", "positions")

if bad:
    print("\n".join(bad))
sys.exit(1 if bad else 0)
'''

WORK = tempfile.mkdtemp()
CENSUS_PY = f"{WORK}/portfolio-census.py"
open(CENSUS_PY, "w", encoding="utf-8").write(CENSUS)


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


def census(root):
    return subprocess.run([sys.executable, CENSUS_PY, root],
                          capture_output=True, text=True)


source = open(PATH, encoding="utf-8").read()
real = census(os.getcwd())
sys.stdout.write(real.stdout)
if real.stderr:
    sys.stderr.write(real.stderr)


def is_call(node, attr):
    return (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
            and node.func.attr == attr)


def sites(tree):
    """The four declarations, by the structure the census reads them by."""
    found = {}
    rows = next((n for n in ast.walk(tree)
                 if isinstance(n, ast.For) and is_call(n.iter, "rows")), None)
    if rows is None:
        return found
    found["rows"] = rows.iter
    withs = [n for n in ast.walk(tree) if isinstance(n, ast.With)
             and any(is_call(i.context_expr, "column") for i in n.items)]
    inside = list(ast.walk(rows))
    detail = next((n for n in withs if rows in n.body), None)
    card = next((n for n in withs if n in inside), None)
    if detail is not None:
        found["detail"] = next(i.context_expr for i in detail.items
                               if is_call(i.context_expr, "column"))
    if card is not None:
        found["card"] = next(i.context_expr for i in card.items
                             if is_call(i.context_expr, "column"))
        columns = next((n for n in ast.walk(card) if isinstance(n, ast.For)
                        and is_call(n.iter, "columns")), None)
        if columns is not None:
            found["columns"] = columns.iter
    return found


# THE EXACT BYTES of the declarations as the guest writes them today —
# what a needle-based clause would have to carry. Counted after each
# reformat, never asserted.
declarations = [ast.get_source_segment(source, node)
                for node in sites(ast.parse(source, PATH)).values()]


def reformatted(site=None, keyword=None):
    """The guest through ast.unparse, optionally with one keyword dropped
    from one declaration. Returns (text, keywords removed)."""
    tree = ast.parse(source, PATH)
    removed = 0
    if site is not None:
        call = sites(tree).get(site)
        if call is None:
            return None, 0
        keep = [k for k in call.keywords if k.arg != keyword]
        removed = len(call.keywords) - len(keep)
        call.keywords = keep
    return ast.unparse(tree), removed


def probe(name, site, keyword, want):
    text, removed = reformatted(site, keyword)
    if text is None or removed != 1:
        print(f"{name}=SELFTEST-BROKEN(removed {removed} `{keyword}` from {site})")
        return
    root = stage({PATH: text})
    r = census(root)
    shutil.rmtree(root)
    survivors = sum(1 for d in declarations if d and d in text)
    print(f"{name}=removed:1 rc:{r.returncode} named:{want in r.stdout} "
          f"byte-exact-declarations-surviving:{survivors}/{len(declarations)}")


probe("p1-rows-align", "rows", "align",
      "portfolio's account-row For does not declare `align`")
probe("p2-detail-grow", "detail", "grow",
      "portfolio's detail column does not declare `grow`")
probe("p3-card-align", "card", "align",
      "portfolio's account card does not declare `align`")
probe("p4-table-id", "columns", "a11y_id",
      "portfolio's positions table does not declare `a11y_id`")

# The reader must REFUSE when it cannot find its subject, never report a
# guest with no declarations as clean.
refusal = "cannot find portfolio's account-row For"
renamed = source.replace("accounts.rows(", "accounts.rowsRenamed(", 1)
root = stage({PATH: renamed})
r = census(root)
shutil.rmtree(root)
print(f"p5-renamed-rows=removed:{source.count('accounts.rows(')} rc:{r.returncode} "
      f"named:{refusal in r.stdout} byte-exact-declarations-surviving:-")

# The D6 control, and the only one that must come back GREEN: the guest
# reformatted, nothing removed.
text, _ = reformatted()
root = stage({PATH: text})
r = census(root)
shutil.rmtree(root)
survivors = sum(1 for d in declarations if d and d in text)
print(f"reflow=removed:0 rc:{r.returncode} "
      f"findings:{len([l for l in r.stdout.splitlines() if l])} "
      f"byte-exact-declarations-surviving:{survivors}/{len(declarations)}")
shutil.rmtree(WORK, ignore_errors=True)
sys.exit(real.returncode)
PROBE
)
portfolio_rc=$?
portfolio_watched="$(printf '%s\n' "$portfolio_probe" | grep -E '^(p[0-9]|reflow)')"
want_portfolio_probe="p1-rows-align=removed:1 rc:1 named:True byte-exact-declarations-surviving:0/4
p2-detail-grow=removed:1 rc:1 named:True byte-exact-declarations-surviving:0/4
p3-card-align=removed:1 rc:1 named:True byte-exact-declarations-surviving:0/4
p4-table-id=removed:1 rc:1 named:True byte-exact-declarations-surviving:0/4
p5-renamed-rows=removed:1 rc:1 named:True byte-exact-declarations-surviving:-
reflow=removed:0 rc:0 findings:0 byte-exact-declarations-surviving:0/4"
if [ "$portfolio_watched" != "$want_portfolio_probe" ]; then
    echo "check-sugar-surface: SELF-TEST FAIL (the portfolio guest census did not" \
        "catch a perturbation it must catch, or reddened on a pure reformat). Wanted:" >&2
    echo "$want_portfolio_probe" >&2
    echo "Got:" >&2
    echo "$portfolio_probe" >&2
    exit 1
fi
echo "$portfolio_probe"
if [ "$portfolio_rc" -ne 0 ]; then
    status=1
fi
unset portfolio_probe portfolio_watched want_portfolio_probe portfolio_rc

# (d) THE PROP CENSUS IS WATCHED THE SAME WAY, in three perturbations.
#     Each stages a temp repo root in which ONE file differs and
#     everything else symlinks the real tree, and prints its
#     substitution count: a probe that did not apply is a FAILED test.
#
#     d1 is a prop the LIVE zone has and the TEMPLATE zone does not,
#        in OCaml because its two zones spell the prop in the same
#        eleven characters. The live setter stays, so a census satisfied
#        by the live twin passes and a zone-scoped one cannot.
#     d2 is a forward deleted from a GENERATED C# façade.
#     d3 renames the zone's own header: a reader that can no longer find
#        the zone must REFUSE, never report an empty zone as clean.
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

# (e) AND THE TAKES-A-SOURCE CENSUS asks what the two above
#     structurally cannot: not whether the kind has a constructor, but
#     whether that constructor can be handed the ROW.
#     `Tpl.Button(string)` satisfies the kind census exactly as
#     `Tpl.button(Signal<String>)` does (docs/deferred.md).
#
#     e1 splices the three bindings' files back in from git at c9bb989,
#        everything else the real tree; the census must come back red
#        naming exactly csharp, swift and python. The splice is REFUSED
#        if a file comes back byte-identical to the working tree.
#     e2 deletes JAVA's field overload — a binding that slice never
#        touched — so a census keyed to the three that were fixed cannot
#        pass.
#     e3 renames Haskell's constructor: a reader that can no longer find
#        the point must REFUSE, never report a binding with no sources.
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
# A template constructor's element source is a FIELD addressed by index
# off a record. A SCALAR collection has no record — its element IS the
# value — so it needs a NAME for field 0; the wire record is identical
# either way, which is why the floor spelling worked and still taught
# the floor (invariant 5).
#
# Go keeps `Row.Value()`, scoped to a row surface no other binding has.
# Python's ambient `for_each` yields the element as `el`, so its "token"
# is the loop variable.
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
# the a11y pair + hint, accepts, and the node paste registrar. Every
# pattern is RECEIVER-KEYED on the template handle type — a
# bare-method-name pattern is satisfied by the LIVE twin every time.
# Python's clause is a separate AST reader
# (tools/checks/py-node-props.py) because its zones share one surface.
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
# HASKELL'S IS AN INSTANCE ARM, receiver-keyed on the Node pattern:
# `onPasteNode` died with the rest of the `*Node` twins, and a bare
# `onPaste` would be satisfied by the class signature and by the LIVE arm
# alike (bindings/haskell/KayaApp.hs, instance HandlerTarget Node). The
# arm's PRESENCE is also held by -Werror=missing-methods, which is the
# wall on the path nobody can avoid; this is the sweep's copy of it.
check haskell bindings/haskell/KayaApp.hs \
    "node paste registrar" "^  onPaste app \(Node n\) handler ="

# Python's, by CLASS STRUCTURE rather than grep — the reader walks
# `class Node` and its bases with `ast` and requires each prop method
# reachable. Its negative was watched by the fan-out (rename on the
# base -> exit 1 naming the prop; unhook the base -> exit 1 naming all
# of them).
#
# IT READS TWO STRUCTURES, because Python spells the zone's props in two
# ways. Most ride `_Handle`, the base `class Node` inherits. `inset` is
# a CONSTRUCTOR KEYWORD (`kaya.row(inset=8)`), so the reader holds the
# chain instead: the kwarg reaches `_set_inset`, which writes onto
# `_widget`, which is `_alloc_widget_or_node` and branches on
# `_tpl_depth`. NOTHING ON THAT PATH MAY ASK WHICH ZONE IT IS IN — a
# `_tpl_depth` read inside `_set_inset` or `_Handle.role` would make one
# zone quietly different from the other. It also refuses a verdict when
# it cannot find the allocator at all.
tpl_props_py=$(python3 tools/checks/py-node-props.py bindings/python/kaya/__init__.py 2>&1)
tpl_props_py_rc=$?
if [ "$tpl_props_py_rc" -ne 0 ]; then
    echo "check-sugar-surface: $tpl_props_py"
    status=1
fi

# A TEMPLATE NODE'S GROW WEIGHT, in all eight.
#
# `scroll` needs a grow weight — an unconstrained viewport hugs its
# content and nothing ever overflows — so a binding shipping the scroll
# constructor WITHOUT grow is a divergence. Spacing and align remain
# floor-only on template containers, in every binding alike.
#
# NEW TEMPLATE PROPS DO NOT GO HERE. The prop sweep lives in
# tools/tpl-surfaces.py's PROP_MEMBERS table, which reads each spelling
# out of the template zone's OWN BLOCK — the thing a line pattern cannot
# do. The clauses above and below stay because they already pass; they
# are not the pattern to copy. Python is the census's one exemption (its
# two zones share a surface), covered by tools/checks/py-node-props.py.
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
# guests keep the explicit floor.
#
# The scene-tier clause at the end of this file reads only the scenes in
# its `scene_guests` table, so a guest outside it could teach the floor
# indefinitely. The rule here has no per-scene table to forget: A SUGAR
# GUEST DOES NOT NAME A WIDGET KIND. tools/guest-floor.py sweeps every
# guest outside guests/c, STRIPS COMMENTS FIRST (the converted guests
# explain the old floor spelling in a comment above the new call, so a
# sweep that reads comments reports every file it just fixed), and
# carries its exemptions with reasons the way gates.sh does.
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
try:
    # SOURCES ONLY: the matrix's sweep overlaps still-running lanes,
    # and a bare copytree of guests/ dies mid-walk when a lane's build
    # churns bin/obj inside it (measured 2026-08-24 — the probe printed
    # an EMPTY finding once under the five-lane matrix). The prune set
    # is the shadows'; the except keeps any residual failure legible.
    shutil.copytree('guests', f"{root}/guests",
                    ignore=shutil.ignore_patterns(
                        'bin', 'obj', '.build', '_build', 'target',
                        '__pycache__', '.gradle', 'build', 'dist',
                        'dist-newstyle', 'node_modules', 'DerivedData'))
    open(f"{root}/{p}", "w").write(src.replace(old, new))
    r = subprocess.run([sys.executable, 'tools/guest-floor.py', root],
                       capture_output=True, text=True)
    print(f"applied=1 rc={r.returncode} named={'editor.go' in r.stdout}")
except OSError as e:
    print(f"SELFTEST-BROKEN: staging failed mid-copy: {e}")
finally:
    shutil.rmtree(root, ignore_errors=True)
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

# THE CLIPBOARD SURFACE (DESIGN.md, Clipboard). Four points, none of
# them a widget kind or a window prop: the copy record, the privileged
# read, the per-widget accept list, and the paste hook.
#
# THE SPELLINGS DIFFER AND THE SEMANTICS DO NOT: copy is a CHAIN where
# the language builds by chaining, keyword arguments where it has them,
# a record where that is the idiom — but at-most-one-per-kind is
# STRUCTURAL in all eight, never a duplicate check. `accepts` takes the
# kinds as VALUES and joins them to the wire's space-separated list.
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
# The LIVE ARM, not the class signature: an arm cannot exist without the
# method, so this reads the stronger half (bindings/haskell/KayaApp.hs,
# instance HandlerTarget Widget). The template arm is the "node paste
# registrar" clause above; both arms are also held by the file's own
# -Werror=missing-methods.
check haskell bindings/haskell/KayaApp.hs         on_paste "^  onPaste app \(Widget n\) handler ="
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

# EVERY WINDOW PROP NEEDS A SUGAR SPELLING TOO. Props come from the
# GENERATED wire file, so this tracks the spec by construction — a new
# WINDOW_PROPS entry lands here the moment the generators run. C is
# exempt for the reason it is above: the floor spells every window prop
# with one generic kaya_tx_set_window_prop call, on purpose.
#
# AND THE SPELLING HAS TO BE IN CODE. Measured 2026-08-19 while `panes`
# was fanning out: with Go's constructor renamed to `PanesXX` this loop
# still passed, because the doc comment above it opens "Panes is the
# CEILING …" and /\bPanes\b/ cannot tell prose from a declaration. Every
# prop in every binding carries such a comment, so the loop could only
# ever agree — the exact vacuity the \b tightening was meant to end, one
# layer further in. The patterns below are unchanged; they run against
# copies with comments and docstrings stripped.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/code"

python3 - "$T/code" \
    "python:bindings/python/kaya/__init__.py" \
    "go:bindings/go/app.go" \
    "csharp:bindings/csharp/KayaApp.cs" \
    "java:bindings/java/dev/kaya/KayaApp.java" \
    "swift:bindings/swift/KayaApp.swift" \
    "ocaml:bindings/ocaml/kaya_app.ml" \
    "haskell:bindings/haskell/KayaApp.hs" <<'PY' || exit 1
import re
import sys

out = sys.argv[1]


def c_like(s):
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    return "\n".join(re.sub(r"//.*", "", ln) for ln in s.split("\n"))


def python_like(s):
    s = re.sub(r'"""(?:.|\n)*?"""', "", s)
    s = re.sub(r"'''(?:.|\n)*?'''", "", s)
    return "\n".join(re.sub(r"#.*", "", ln) for ln in s.split("\n"))


def ocaml_like(s):
    """(* … *) nests, so this counts rather than matching."""
    keep, depth, i = [], 0, 0
    while i < len(s):
        if s.startswith("(*", i):
            depth += 1
            i += 2
        elif s.startswith("*)", i) and depth:
            depth -= 1
            i += 2
        else:
            if not depth:
                keep.append(s[i])
            i += 1
    return "".join(keep)


def haskell_like(s):
    s = re.sub(r"\{-(?:.|\n)*?-\}", "", s)
    return "\n".join(re.sub(r"--.*", "", ln) for ln in s.split("\n"))


STRIP = {
    "python": python_like, "go": c_like, "csharp": c_like, "java": c_like,
    "swift": c_like, "ocaml": ocaml_like, "haskell": haskell_like,
}

# A NONCE IN A COMMENT, PER LANGUAGE, and the whole point of the pass:
# the raw file must satisfy the token and the stripped one must not. It
# is planted rather than borrowed from a real prop so it cannot rot into
# a name some binding later spells in code, and it runs for all seven so
# a stripper that quietly strips nothing is caught where it lives.
NONCE = "KayaCommentOnlyNonce"
PLANT = {
    "python": f"# {NONCE} rides in a comment\n" + f'"""{NONCE} rides in a docstring"""\n',
    "go": f"// {NONCE} rides in a comment\n",
    "csharp": f"/// {NONCE} rides in a comment\n",
    "java": f"/** {NONCE} rides in a comment */\n",
    "swift": f"/* {NONCE} rides in a comment */\n",
    "ocaml": f"(* {NONCE} rides in a (* nested *) comment *)\n",
    "haskell": f"-- {NONCE} rides in a comment\n",
}

applied = []
for arg in sys.argv[2:]:
    lang, path = arg.split(":", 1)
    text = open(path, encoding="utf-8").read()
    stripped = STRIP[lang](text)
    # A stripper that ate the whole file would redden everything; one
    # that ate nothing would restore the miss this replaces. Neither is
    # allowed to reach the loop below as a verdict.
    ratio = len(stripped) / len(text)
    if not 0.25 < ratio < 0.95:
        sys.exit(f"check-sugar-surface: stripping comments from {path} left "
                 f"{len(stripped)}/{len(text)} bytes ({ratio:.2f}) — the "
                 f"{lang} comment stripper is wrong")
    planted = STRIP[lang](PLANT[lang] + text)
    if NONCE not in PLANT[lang] + text:
        sys.exit(f"check-sugar-surface: SELF-TEST FAIL ({lang}'s nonce was "
                 "not planted at all)")
    if NONCE in planted:
        sys.exit(f"check-sugar-surface: SELF-TEST FAIL (a {lang} COMMENT "
                 f"still satisfies the window-prop sweep — {path})")
    applied.append(f" {lang}={PLANT[lang].count(NONCE)}")
    open(f"{out}/{lang}", "w", encoding="utf-8").write(stripped)

print("check-sugar-surface: window-prop comment-only nonces refused:"
      + "".join(applied), file=sys.stderr)
PY

wprops=$(grep -oE "^WPROP_[A-Z_]+" bindings/python/kaya/wire.py \
    | cut -c7- | tr "[:upper:]" "[:lower:]")
[ -n "$wprops" ] || { echo "check-sugar-surface: no window props in the generated wire file"; exit 1; }

# check_wprop <language> <source file, for the message> <prop> <regex>
check_wprop() {
    if ! grep -qE "$4" "$T/code/$1"; then
        echo "check-sugar-surface: $1 has no window-prop sugar for '$3'" \
            "(wanted /$4/ in $2, comments stripped)"
        status=1
    fi
}

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
    check_wprop python bindings/python/kaya/__init__.py "$wprop" "\b$wprop\b"
    # Go folds width and height into ONE Size(w, h) chain method, the
    # same flavor as Haskell's WSize below — surfaced by the \b
    # tightening, which is the proof the old substring match was passing
    # on an accident (exactly one bare `Width` existed in the file, and
    # it was not a constructor).
    case "$wprop" in
        width | height) go_pat="\bSize\b" ;;
        *) go_pat="\b$pascal\b" ;;
    esac
    check_wprop go bindings/go/app.go "$wprop" "$go_pat"
    check_wprop csharp bindings/csharp/KayaApp.cs "$wprop" "\b$camel\b"
    check_wprop java bindings/java/dev/kaya/KayaApp.java "$wprop" "\b$camel\b"
    check_wprop swift bindings/swift/KayaApp.swift "$wprop" "\b$camel\b"
    check_wprop ocaml bindings/ocaml/kaya_app.ml "$wprop" "\b$wprop\b"
    # Haskell carries width and height as ONE WSize constructor — a
    # language flavor, not a gap, exactly like the kind spellings above.
    case "$wprop" in
        width | height) hs="WSize" ;;
        *) hs="W$pascal" ;;
    esac
    check_wprop haskell bindings/haskell/KayaApp.hs "$wprop" "\b$hs\b"
done

# ─────────────────────────────────────────────────────────────────────
# THE STYLING SURFACE (docs/styling-plan.md, slice 1). `inset` is a
# WINDOW_PROPS entry and the spec-derived loop above already demands it.
# The other two are neither widget kinds nor window props, so nothing
# else in this file can see them:
#
#   - `brand_accent` is a TRANSACTION verb, copy's shape. The
#     per-appearance override form rides the same base name, so the
#     patterns key on the base name.
#   - `role` rides the WIDGET chain the way grow does, with the closed
#     vocabulary as a real enum type wherever the language has one. The
#     root's declare-time wall refuses a misfit kind.

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

# THE BRAND TYPEFACE (Slice 2b), the accent's sibling: a transaction
# verb no other sweep can see. Same base-name rule as the accent — the
# per-platform/font-bytes form rides the base name, so one pattern per
# language.
check_styling_point brand_typeface \
    'pub fn brand_typeface\(&mut self' \
    '^def brand_typeface\(' \
    'func \(tx \*Tx\) BrandTypeface\(' \
    'public void BrandTypeface\(' \
    'public void brandTypeface\(' \
    'func brandTypeface\(' \
    '^brandTypeface ::' \
    '^let brand_typeface '

# THE APP IDENTITY (docs/app-identity-plan.md): a transaction verb no
# other sweep can see, so a binding shipping it wire-only strands apps
# in that language while every other gate passes. RED BY DESIGN until
# the eighth binding lands. Same base-name rule as the brand rows.
check_styling_point app_identity \
    'pub fn app_identity\(&mut self' \
    '^def app_identity\(' \
    'func \(tx \*Tx\) AppIdentity\(' \
    'public void AppIdentity\(' \
    'public void appIdentity\(' \
    'func appIdentity\(' \
    '^appIdentity ::' \
    '^let app_identity '

# `asset(name)` (docs/assets-plan.md): a transaction-tier call no other
# sweep can see, so a binding shipping the core entry point without
# sugar strands apps in that language while every other gate passes.
#
# EIGHT PATTERNS, FOUR SHAPES, idiom rather than semantics (invariant
# 1). Rust, Go and C# hang it off the transaction; Python, OCaml and
# Haskell are ambient and it is a plain function; Java is static on the
# app surface; Swift spells it as a CLASS whose initializer opens the
# asset, that language's idiom for a handle with a lifetime.
#
# SWIFT'S PATTERN IS THE THROWING INITIALIZER AND NOT THE CLASS NAME:
# the class is already held by a compiler (three guests name it, so
# swift-typecheck reds if it goes), while the `throws` has no such wall
# — Swift answers a `try` with nothing to throw with a WARNING, and the
# guest pass is not -warnings-as-errors.
#
# KEYED PAST THE BARE NAME: `asset` is a short common word and a pattern
# matching it alone would be satisfied by a doc comment. Every pattern
# below carries its receiver, its keyword or its type signature.
check_styling_point asset \
    'pub fn asset\(&self' \
    '^def asset\(' \
    'func \(tx \*Tx\) Asset\(' \
    'public Asset Asset\(' \
    'public static Asset asset\(' \
    'init\(_ name: String\) throws' \
    '^asset :: String -> IO Asset' \
    '^let asset = '

# The row above's other half: the sentence a miss WOULD raise, answered
# TOTALLY, without unwinding. A scene has to OBSERVE that sentence on
# five platforms in NINE languages — the eight bindings and the C floor
# — and "catch it" is not one semantics in nine, because C has no catch
# at all. A query is. The query also answers what no raise can: for a
# name that RESOLVES it says so, having opened nothing, which is the
# second half of what tools/scenes/assets.steps freezes.
#
# The bindings write no prose — every one returns
# crates/kaya/src/assets.rs's bytes unchanged.
#
# NAMED FOR CARRYING, NOT FOR DIAGNOSING: a `…WhyNot` here would opt
# into tools/check-diagnostics.sh by its name alone, and that gate reads
# a function so named as the AUTHOR of a sentence these only carry.
check_styling_point asset_miss_sentence \
    'pub fn asset_miss_sentence\(&self' \
    '^def asset_miss_sentence\(' \
    'func \(tx \*Tx\) AssetMissSentence\(' \
    'public string AssetMissSentence\(' \
    'public static String assetMissSentence\(' \
    'static func missSentence\(' \
    '^assetMissSentence :: String -> IO String' \
    '^let asset_miss_sentence = '

# THREE ROWS ARE KEYED PAST THE MENU ITEM'S ROLE, which shares the bare
# name: a bare-name pattern is satisfied by Rust's
# `role(self, role: MenuRole)`, Python's `def role(self, name)` on the
# item class and OCaml's `let item … ?role …`. Rust keys on the widget
# enum's type, Python on the parameter name, OCaml on the constructor or
# setter receiver — none of which the menu item's line can supply.
check_styling_point role \
    'pub fn role\(self, role: crate::Role\)' \
    'def role\(self, role\)' \
    'func \(w Widget\) Role\(' \
    'public void SetRole\(' \
    'public Widget role\(' \
    'func setRole\(' \
    'Role :: Role -> Attr' \
    'let (label|button) [^=]*\?role|let set_role \(Widget id\)'

# A SECTION INTO A NAMED WINDOW, in all eight. Idiom decides the
# spelling — a second name where there are no optional arguments, a
# window argument where there are — and each pattern keys on the
# window-carrying form so the primary-only spelling cannot satisfy it.
# EXCEPT Swift's and Python's, whose signatures put the window parameter
# past a line break where a line-based grep cannot key on it: those rows
# pin the wrapped signature's own first line, and the GUESTS hold the
# parameter (both sections guests call with window=/window:).
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
# ONE: NO WINDOW ATTRIBUTE LIVES AS A LOOSE FUNCTION OUTSIDE THE
# CONSTRUCT (DESIGN.md, Binding conventions). The sweep runs BOTH
# directions, because only the pair states the rule.
#
# WHERE THE LIST COMES FROM: two bindings declare the construct's
# attribute set as a CLOSED SYNTACTIC OBJECT — Haskell's
# `data WindowAttr` and OCaml's `let window` — so "what the construct
# carries" is a fact about a file rather than a judgement made here.
# The list is the UNION of the two.
#
# ADDING A NEW WINDOW HANDLER means spelling it in Haskell's WindowAttr
# or OCaml's window, at which point this sweep demands the other seven
# and refuses the loose one. Nobody edits a list here.
#
# $T is the window-prop sweep's temp dir, made above.

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
# and passes everything. The close pair is the floor: if it ever leaves
# BOTH declarations, this gate is reading the wrong thing and has to be
# re-derived rather than agree with what is left.
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
# `Messages::on_*(WindowId, …)` is the sanctioned Rust form, a MESSAGE
# VALUE in a table the transaction cannot reach. Pinning it means a
# future "fix" onto WindowRef goes red here and gets decided.
#
# The pin reads the `impl<M> Messages<M>` block with its signatures
# collapsed onto one line (rustfmt wraps them and grep is line-based)
# and its comments dropped, so a doc comment cannot satisfy it. A
# missing anchor FAILS rather than going quiet.
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
# Python, C#, Swift and OCaml spell a window's attributes as arguments
# TWICE — the primary window's construct and the auxiliary's — where
# DESIGN.md says the two take EXACTLY the same set. A whole-file grep
# cannot tell those apart: a handler dropped from `window` while
# `create_window` keeps it still matches somewhere in the file. So each
# construct's header is extracted and swept on its own.
#
# The other four need no extraction: their construct is a TYPE rather
# than an argument list, so one spelling serves both windows.
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
# RULE. KayaApp handler tables are `private`, so KayaAppTx cannot write
# them and the construct reaches them through a KayaApp method that DOES
# take a window id. So Swift is pinned as ONE DOOR: called exactly once,
# from the construct, with the construct own argument. A second callsite
# is a second door, and a guest holds the KayaApp.
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
    # REACHES WITH A WINDOW ID IN HAND — what a construct-scoped handler
    # makes unnecessary. Python, OCaml and Haskell have the simplest
    # rule (the top-level definition itself, since a construct spelling
    # is a keyword/labelled argument or a constructor there). Go's is a
    # method on the app or the transaction, or a package-level function.
    # C# and Java key on the DECLARATION rather than the window
    # parameter, because a wrapped signature puts the parameters on the
    # next line: any `OnUndone(` declaration is loose in C#, and in Java
    # the construct returns WindowRef to chain, so a `void onUndone(` is
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
# OF THE REAL FILES (docs/traps.md: the wayland seat guard passed
# VACUOUSLY TWICE against a fixture). Every perturbation prints its
# substitution count and is refused if it did not apply, and every
# refusal is checked for its REASON.

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
# not an implementation. C registers nothing: a guest reads the
# occurrence record head and matches on it. What makes that honest is
# that the header declares NO handler registrar of any kind, so a
# `kaya_app_on_undone` arriving one day fails here instead of quietly
# making C the ninth binding with a loose spelling.
deny c bindings/c/kaya_wire.h "any window handler" "kaya_[a-z_]*_on_[a-z_]+\("

# ─────────────────────────────────────────────────────────────────────
# THE SCENE TIER: THE SAME RULE, READ FROM THE OTHER SIDE.
#
# Everything above asks whether a BINDING OFFERS the sugar; this asks
# whether the EXAMPLES USE IT (invariant 5). The carve-out for entry and
# milestone2 covers the EVENT-RECEIVING mechanism ONLY (DESIGN.md,
# "SCOPE, ratified 2026-08-05"); construction follows the same sugar
# rule as every other example.
#
# So this clause reads both halves, for BOTH carve-out scenes:
#   (a) no entry and no milestone2 guest spells CONSTRUCTION at the
#       floor, in any of the eight bindings; and
#   (b) both rust guests still spell their EVENTS as the raw
#       `ctx.next()` loop. THE CARVE-OUT IS CHECKED, NOT ASSUMED — a
#       later session "finishing the job" by folding them onto
#       kaya::Messages would delete the only guests that document the
#       tier Messages is built on.
#
# THE PATTERNS ARE DERIVED FROM WHAT EACH FILE ACTUALLY SAID: every
# regex below matched guests/<lang>/<scene>.* at that scene's
# pre-graduation revision and matches nothing in the graduated one.
#
# A THIRD SCENE JOINS BY ADDING ROWS AND NOTHING ELSE: one to
# scene_facts and one per language to scene_guests. Every loop below
# sweeps those two tables.

# <scene> <the expected string every guest carries> <its script> <the
# line the self-test plants its floor snippets after>
#
# THE EXPECTED STRING IS THE ANTI-VACUITY ANCHOR: frozen and
# byte-identical in all eight languages (invariant 6), so a guest that
# was renamed, moved or emptied fails loudly here instead of satisfying
# every denial below by having nothing in it.
scene_facts=(
    entry 'nothing to add, ' tools/scenes/entry.steps '^(.*no todos.*)$'
    milestone2 '"step 0"' tools/scenes/milestone2.steps '^(.*"step 0".*)$'
)

# <scene> <language> <the guest this clause reads>
#
# THE GO ROWS NAME <scene>/<scene>.go, which is the scene ITSELF: one
# directory per scene, package named for it, App() handing back a built
# app. The desktop TAILS live in guests/go/cmd and no scene row may name
# that directory — a row pointing at a tail reads a file that cannot
# spell the floor and passes for the emptiest possible reason.
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
# subshell, where the `exit 1` for a scene missing from the table kills
# only that subshell and hands the caller an EMPTY anchor — matched by
# every file, which is the exact vacuity this clause refuses.
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
# added to the spec is denied here without anyone editing a list. The
# denial is total: no kind is exempt.
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
# LINE OF THAT LANGUAGE'S FLOOR THAT MUST TRIP IT. The last field is not
# decoration: the self-test plants every snippet in a copy of its real
# guest, once per scene the row guards, and requires the clause to name
# every row. A pattern cannot be added without a line proving it fires.
#
# THE FIRST FIELD IS "*" FOR ALL SCENES, which is what a floor spelling
# normally is. One pair of rows is scene-specific, for a reason written
# where it stands.
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

    # PYTHON HAS NO WIDGET-KIND FLOOR TO LEAVE: its public surface is
    # the sugar (the kind constructors call a private _widget). The
    # clause is written anyway, as a rule about what must NOT ARRIVE.
    # `kaya.for_each` is real today and is the tier below the `for`
    # statement this scene traces with; the other two name spellings the
    # binding does not export.
    "*" python "the for_each combinator" 'kaya\.for_each\(' \
        '    with kaya.for_each(todos) as todo:'
    "*" python "the add_child chain" '\.add_child\(' \
        '    column.add_child(field)'
    "*" python "bind_element by index" '\.bind_element\(' \
        '    label.bind_element(0)'

    "*" go "widget-kind construction" '\.Widget\(' \
        '        column := tx.Widget(kaya.KindColumn)'
    # NO SetText/setText/set_text ROW, and the reason is not an
    # oversight: in six languages the template PROP WRITE and the
    # set_text WIDGET VERB shared one name, so no pattern could fail the
    # floor use without failing the verb — the receiver TYPE decides and
    # no regex sees a type. Those six now hide the template write
    # (unexported/private, so the wall is the compiler) or rename it
    # (Haskell setTextProp, OCaml Tpl.Floor.*), and the renamed
    # spellings are swept repo-wide by tools/guest-floor.py
    # (docs/tpl-props-plan.md F3).
    "*" go "the generic BindText" '\.BindText\(' \
        '        tx.BindText(statusLabel, status)'
    # NO ForEach ROW: Go's callback For is gone (the idiom sweep,
    # 2026-08-24) — a For is a for statement over Rows.All(), and there
    # is no floor spelling of it left for a scene to fall back to.
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
    # JAVA'S CALLBACK For DIED 2026-08-24 (the one form is the eager
    # `rows` Iterable), so `.forEach(` names nothing this binding
    # exports and the compiler is that wall. What is still reachable is
    # the tier BELOW the for statement: KayaRecords.rowTrace, public
    # because the generated surfaces call it from the guests' package.
    "*" java "the rowTrace machinery" 'KayaRecords\.rowTrace\(' \
        '            KayaRecords.rowTrace(tx, todos, t -> t);'
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
    # MILESTONE2, in these two languages only: `each` IS the combinator
    # with the body's RESULT THROWN AWAY. entry's template body returns
    # () so `each` is its spelling; milestone2's body returns the two
    # handles its CENTRAL registration names, and a closure in these two
    # languages cannot assign an outer variable the way swift's and
    # java's do, so the result is the only way out.
    #
    # So milestone2 keeps the combinator and is denied the sin still
    # available to it: a For whose result is (), which is a For `each`
    # should have made. Both halves are watched firing.
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
    # would be satisfied by the sentence describing the loop rather than
    # by the loop. The other seven are read whole — a comment spelling a
    # floor call in a graduated scene teaches the floor.
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
# SCENE PER LANGUAGE: every snippet a language owes a scene is planted
# after that scene plant line, and the clause must then name EVERY rule
# the pair has, IN THAT SCENE NAME. A snippet the pattern misses is a
# pattern that would never have fired.
#
# `check_scene_sugar` runs inside `$( )` here, so the `status=1` it sets
# dies with that subshell and the real verdict is untouched.
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
# per-scene fact, so each has to be watched refusing. A file this clause
# cannot recognise as the scene it is filed under has to fail LOUDLY
# rather than satisfy every denial by having nothing in it
# (docs/traps.md). What is under test is the anchor, not the language.
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
