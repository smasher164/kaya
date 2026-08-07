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
    check python bindings/python/kaya/__init__.py "$wprop" "$wprop"
    check go bindings/go/app.go "$wprop" "$pascal"
    check csharp bindings/csharp/KayaApp.cs "$wprop" "$camel"
    check java bindings/java/dev/kaya/KayaApp.java "$wprop" "$camel"
    check swift bindings/swift/KayaApp.swift "$wprop" "$camel"
    check ocaml bindings/ocaml/kaya_app.ml "$wprop" "$wprop"
    # Haskell carries width and height as ONE WSize constructor — a
    # language flavor, not a gap, exactly like the kind spellings above.
    case "$wprop" in
        width | height) hs="WSize" ;;
        *) hs="W$pascal" ;;
    esac
    check haskell bindings/haskell/KayaApp.hs "$wprop" "$hs"
done

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
scene_guests=(
    entry rust guests/rust/entry.rs
    entry python guests/python/entry.py
    entry go guests/go/entry/main.go
    entry csharp guests/csharp/EntryScene.cs
    entry java guests/java/dev/kaya/milestone2kt/Entry.java
    entry swift guests/swift/entry.swift
    entry haskell guests/haskell/entry.hs
    entry ocaml guests/ocaml/entry.ml

    milestone2 rust guests/rust/milestone2.rs
    milestone2 python guests/python/milestone2.py
    milestone2 go guests/go/milestone2/main.go
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
    "*" go "the SetText prop write" '\.SetText\(' \
        '        tx.SetText(add, "add")'
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
    "*" csharp "the SetText prop write" '\.SetText\(' \
        '            tx.SetText(add, "add");'
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
    "*" java "the setText prop write" '\.setText\(' \
        '            tx.setText(add, "add");'
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
    "*" swift "the setText prop write" '\.setText\(' \
        '    tx.setText(add, "add")'
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
    "*" ocaml "the set_text prop write" '(^|[^A-Za-z_])set_text[[:space:]]' \
        '       set_text add "add";'
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
