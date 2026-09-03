# The template-zone sugar pass — the design

Status: LANDED 2026-08-10 (`c20b9c2`, with S7 following in `a6c23be`) —
both zones at parity in all eight bindings, the gate reading the
template zone through tools/tpl-surfaces.py, and the three §0 defects
(D1's missing tag, D2's dropped value change, D3's Python `progress`
AttributeError) all fixed as S5 required, before any constructor
shipped. Read §0 as the survey record, not as the state of the tree.

Started 2026-08-10, from a question about one line of the text editor:
`query = row.Widget(kaya.KindEntry)`. The editor's find bar is a
one-row collection, so it is built in the TEMPLATE zone, and the
template zone had no entry constructor. The live zone did, in all eight
languages, held by a gate.

## §0 — what the survey found

Eight readers, one per binding, plus an example sweep. Three defects
came back that no one was looking for, each verified against the source
before it was written down here.

### The gap that started it

kaya has two construction zones. The LIVE zone — widgets built in the
app's build closure — has a named constructor for all 14 widget kinds in
all 8 bindings, and `tools/check-sugar-surface.py` fails the build if one
is missing. The TEMPLATE zone — the prototype inside a collection,
stamped once per row — has constructors for three kinds in Rust (label,
checkbox, button) and four in several other bindings. Everything else
falls to `widget(kind)`, the raw floor, which passes a wire constant as
a runtime value.

**No gate looked at the template zone at all.** That is why the surface
could be complete in eight languages and simultaneously reachable only
through the floor in every template. S6 closed it: `tools/tpl-surfaces.py`
now censuses the zone, and holds a zone's several surfaces level with
each other.

Python is the exception and needs NOTHING here: its transaction is
ambient, so `kaya.entry(on_change=...)` is literally the same call in
both zones (guests/python/undo.py:173). The survey confirmed all 14
kinds plus spacer already work inside a template there; the module-level
`_tpl_depth` flips one allocator between Widget and Node
(bindings/python/kaya/__init__.py:142, :1264) and every constructor
funnels through it. Python has no floor to fall to and no second surface
to drift from — it carries D3 and nothing else.

### D1 — a stamped textarea, select or radio carries no identity tag

**Two backends panic; the other three go silent.** The live path tags
seven interactive kinds (crates/kaya/src/scene.rs:1192); the stamping
path tags four (crates/kaya/src/scene.rs:4107). Textarea, Select and
Radio are missing from the second list, and those are exactly the three
whose backends treat the tag as mandatory:

    crates/kaya/src/gtk.rs:3613        tag.expect("textareas carry a tag")
    crates/kaya/src/gtk.rs:3686        .expect("radio groups carry a tag")
    crates/kaya/src/gtk.rs:3703        tag.expect("selects carry a tag")
    crates/kaya/src/winui/mod.rs:4760, 5977, 6008 — the same three

Nothing stops a guest reaching it today: the template `CreateWidget` arm
accepts every kind, and stamping emits ApplyOps without re-running the
live path's guards. A `select` inside a `for_each` records fine, declares
fine, and aborts the process on GTK and WinUI the moment a row stamps.
On the SwiftUI interpreter it reads a zero-length tag without complaint,
so there the widget appears and never reports — the silent arm.

The two lists are the same fact written twice, twelve hundred lines
apart, and nothing compares them. That is the shape of the fix, not just
the bug: **one function, both callsites**, plus a test that every kind
the backends unwrap a tag for is tagged on both paths.

### D2 — a stamped slider, select or radio's changes reach nobody

Go's occurrence dispatch has a live arm and a node arm for clicks, for
text edits and for toggles, and only a live arm for value changes
(bindings/go/app.go:2990-3017). A stamped slider's move matches no case
and is dropped with no error. Rust has `on_value_node`
(crates/kaya/src/app.rs:2517); the other seven bindings have no
registrar for it at all.

This is the same failure class check-tx-liveness exists for: a silent
drop that a scene cannot see, because no scene puts a slider in a
template — because there is no constructor for one.

### D3 — Python's `progress(value=<element field>)` raises

`bindings/python/kaya/__init__.py:2069-2071` spells the FieldRef
accessors `value._level, value._field`. `FieldRef` has `_index`, and
`_level` is a method; every other callsite in the file gets it right
(`._level(), ._index`). Verified by running it: `has _field: False`. So
binding a progress bar to a row's own field dies with an AttributeError
today, and the `_level` half would have packed a bound method if it had
got that far. No guest exercises it — the only two `progress(...)` calls
in guests/python are constants.

**The gate lesson is the point:** a check that asserts a constructor
EXISTS cannot see this. The template sweep has to assert that the
element-source arm is reachable, not that a `def` is present.

### The example work-list

Two kinds of hit, and the second was not part of the original question.

**Template-zone floor calls** — the ones that need the new sugar. The
undo scene's per-row note entry, in all seven handle bindings
(guests/{go/undo/undo.go:181, rust/undo.rs:115, swift/undo.swift:161, ocaml/undo.ml:158, haskell/undo.hs:151, csharp/UndoScene.cs:142, java/dev/kaya/guests/Undo.java:138}) plus the editor's find bar
(guests/go/editor/editor.go:450). Python already spells it with sugar.

**Live-zone floor calls that already have sugar available** — fixable
today, and an invariant 5 violation that no gate catches because these
scenes are not in check-sugar-surface's scene tables.
`guests/haskell/textarea.hs` builds its ENTIRE scene at the floor while
`textareaOn` sits in the binding (bindings/haskell/KayaApp.hs:1706);
`guests/ocaml/textarea.ml` does the same; menus.hs, menus.ml and
menus.swift each spell one label at the floor. (Line anchors dropped
2026-08-18: the comment cut moved every one of them, and what these
sentences record is a state the pass has since removed.)

## §1 — the decisions

### S1 — full parity, both zones, all eight languages

Every widget kind gets a template-zone constructor everywhere the live
zone has one. Not entry alone.

The reason is the gate. "Every kind, in both zones, in every language"
is a rule one sentence long, and a rule that short is one the next
person cannot drift from. A fix scoped to entry leaves the gate unable
to say anything general, and leaves the next person hitting this same
wall at `slider` — which is worse than today, because by then the
surface will look finished.

### S2 — a template value comes from a source; structure stays constant

Wherever the live constructor takes a plain value, the template
constructor takes that binding's spelling of a source: a constant, a
signal, or a field of the row's own element. That is already the
template zone's idiom (`label(src)`, `checkbox(src)`, `button(src)`) and
it is the whole reason a template constructor differs from its live
twin — a stamp makes N copies and each copy's value can come from its
own row.

Arguments that describe the PROTOTYPE rather than the row stay plain
constants: a slider's min and max, a grid's column count, a select's or
radio's option list. Those are one shape for every copy by construction
(§2 records the option-list limit, which is real and deliberate).

### S3 — entry and textarea get two spellings

`entry()` unbound and `entry_bound(src)`; the same for textarea. Their
text is genuinely optional in a way a label's is not — they are
uncontrolled, the guest owns the text, and the unbound form is what the
editor and the undo scene actually want. The bound form is expressible:
`Prop::Text` is legal on both kinds (crates/kaya/src/scene.rs:482), and
an editable list of names pre-filled from row data is the obvious case
the live zone has no analogue for.

kaya already spells this split in the live zone as `slider` vs
`slider_bound`, so the convention is borrowed, not invented. Each
binding uses its own idiom where it has a better one — an optional
argument, an overload — and the SEMANTICS are identical in all eight
(invariant 1).

### S4 — a stamped image DOES vary per row; Rust was the one that could not say so

Corrected 2026-08-10, after this section first claimed the opposite.
`ValueType::Blob` has always existed (crates/kaya/src/protocol.rs:671),
so a record field can hold encoded bytes, and Swift, C# and Java all
ship a per-row image already — `image(_ f: KayaField<Data>)`,
bindings/swift/KayaApp.swift:3003. The only thing missing was Rust's
marker type: `ValueKind` had Str, Bool, I64 and F64 and no `BlobKind`,
so Rust could not spell the field even though the wire carried it.

A capability three bindings have and a fourth cannot express is
divergence, and the fix is the marker, not a carve-out (invariant 1).
`BlobKind` lands with the rest of this pass and Rust's template `image`
takes a source like every other constructor in the zone.

### S4b — the zone has TWO surfaces in several bindings, and they drift

Rust's `Tpl` is not the whole template zone: `Row` (crates/kaya/src/app.rs:2343)
is the for-STATEMENT façade over the same zone and hand-delegates its
methods one at a time — it forwarded six while ten kinds were missing.
Go is worse: its template constructors are spread over four surfaces
(`*Tpl`, `Row`, `RecordCollection`, `SumCase`). A constructor present on
one and absent from the other is reachable through `for_each` and not
through `for row in rows`, which is a difference no guest should have to
know about.

So the gate holds the surfaces of a zone level with each other, not just
the zone against the kind list.

### S5 — the three defects land BEFORE any constructor ships

D1 and D2 are not adjacent work. Ship the constructors without them and
three of the new kinds are ornaments: a template `select` panics on two
backends and reports to nobody on the rest. So the order is core first,
then the surface.

D1's fix is one predicate used by both tag sites, plus a test that every
kind a backend unwraps a tag for is tagged on both paths — the two lists
become one fact. D2's fix is the missing node arm and a registrar per
binding. D3's is the line, plus a sweep clause that reaches the
element-source arm rather than the `def`.

### S6 — the gate sweeps both zones, and the scene tier grows teeth

Two halves, matching what check-sugar-surface already does for the live
zone:

- **What the binding OFFERS**: every kind has a template constructor in
  every language, with the fake-kind negative test watched failing in
  all of them, exactly as the live sweep's does.
- **What the examples USE**: the scene tier's floor rules already know
  how to fail a guest for `widget(kind)` — they just never see these
  scenes, because only `entry` and `milestone2` are in the tables. The
  scenes carrying template floor calls join, each with its anchor
  string and its plant line, and each perturbation is watched firing.

Per D3, the offers half asserts the source arm is REACHABLE, not that a
declaration exists.

### S7 — the scalar element gets a name (the follow-on slice)

Ratified 2026-08-10, after the pass proper landed. Three guests still
built a template label at the widget-kind floor —
guests/haskell/menus.hs, guests/ocaml/menus.ml, guests/swift/menus.swift
— and all three wanted the same missing thing.

A template constructor's element source is a FIELD, addressed by index
off a record. A SCALAR collection has no record: its element IS the
value. Binding it is spelled `bind_text_element` at the floor — level,
no field — and every binding's sugar wanted a field token instead. Only
Go had a name for one: `Row.Value()`, which returns literally
`FieldAt[string](0)` (bindings/go/app.go).

**The whole thing is that field 0 had no name.** `PropValue::Element {
level, field: 0 }` is exactly what a `Field` at index 0 produces, so the
floor call and the sugar call put the same bytes on the wire — the
sugar just could not say "index 0" without a spelling that meant it.

And the type is fixed, which is what makes this small: `String` is the
only non-derived `KayaSum` (crates/kaya/src/app.rs:275), so a scalar
collection is always a collection of strings and its element token is
always the string field 0. One nullary accessor per binding, named for
the protocol's own term — `element` — with Go keeping `Row.Value()`,
which already documents itself as "the element itself" and is the
idiom of a surface no other binding has.

With that, the three exemptions in tools/guest-floor.py go away and the
sweep's rule has no carve-outs left: **a sugar guest does not name a
widget kind**, everywhere, with nothing to remember.

## §2 — what genuinely cannot exist, recorded

- **A per-row option list.** `select` and `radio` build their options as
  label children of the prototype, so every stamped copy has the same
  options; only the selected index varies. Varying the option COUNT per
  row would need a nested collection inside the choice widget, which the
  scene rejects (labels only). Deliberate, not a gap.
- ~~**A per-row image.**~~ NOT A LIMIT — §S4 corrected this the same
  day: `ValueType::Blob` always existed and three bindings already
  shipped a per-row image. Rust's missing `BlobKind` marker was the
  whole gap, and it landed with this pass (crates/kaya/src/app.rs).
- ~~**Template-node props.**~~ Grow, the a11y pair, `accepts` and the
  paste hook were unreachable on a template node in most bindings, and
  this pass ledgered them rather than carrying them. CLOSED by the
  follow-on slice, docs/tpl-props-plan.md (`c36340f`).

## §3 — sequencing

Depth then breadth, per CLAUDE.md.

1. D1 + D2's Rust half + the tag guard, with the negative tests watched
   failing. Core only.
2. Rust's template constructors + the gate's offers half. Green on mac.
3. Fan out: the seven other bindings, D2's registrar in each, D3.
4. The examples, both kinds of hit, plus the scene-tier rules that would
   have caught them.
5. `guests/c/undo.c` records the current rationale — that the template
   sugar takes a source and an unbound entry has none. It stops being
   true here and gets corrected in the same commit. (Done; the paragraph
   itself went out with the 2026-08-18 comment cut.)
6. The ladder: unit tests, 31/31 gates, validate-mac, the five lanes.
