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

if [ "$status" -ne 0 ]; then
    echo "check-sugar-surface: FAIL"
    exit 1
fi
echo "check-sugar-surface: OK"
