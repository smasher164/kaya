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
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

kinds=$(grep -oE '^KIND_[A-Z_]+' bindings/python/kaya/wire.py | sed 's/^KIND_//' | tr '[:upper:]' '[:lower:]')
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

if [ "$status" -ne 0 ]; then
    echo "check-sugar-surface: FAIL"
    exit 1
fi
echo "check-sugar-surface: OK"
