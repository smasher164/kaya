# Template-node props + the widened floor tier — the design

The two items docs/deferred.md carried out of the sugar pass
(2026-08-10), taken together because they are the same pass's two loose
ends: what a stamped widget can CARRY, and what a gate can SAY about a
guest that spells things at the floor. Scoped by nine survey reports
(eight per-binding, one floor census over all 284 guest files); the
survey artifacts named here were each verified against the source before
the plan relied on them.

## §0 — what is settled (probed, not assumed)

- **The core is done.** The template declare arm runs `check_prop`
  (crates/kaya/src/scene.rs:3587), so the a11y pair is admitted on every
  kind and `accepts` on entry/textarea; the stamping arm applies props
  generically. A probe proved a CONST a11y id and a ROW-FIELD a11y label
  both stamp to the right per-copy ApplyOps. Nothing to build below the
  bindings.
- **The harness already reaches stamped copies** (`set_text entry#last`,
  tools/scenes/undo.steps:279), so `expect_ax` on a stamped copy is
  expressible today. No a11y leg has ever made that read — the
  milestone's 719 legs all built their subjects live.
- **A11yHint stays activation-kinds-only** (scene.rs:566), and the
  restriction needs no binding-side type: misuse dies at declare time,
  before a row stamps, in the root's own words.
- **A duplicate a11y id across stamped copies is legal** — nothing in
  the core deduplicates, and the harness addresses by kind#index, never
  by id. The doc on each binding's setter says so; there is no guard to
  build.

## §1 — the props slice

### The finding that reshaped it: the paste hook is a SILENT REGISTRAR

The draft of this plan assumed the paste gap was a missing dispatch arm,
like the sugar pass's D2. The survey says otherwise, in seven bindings
out of eight: the node registrar EXISTS and the dispatch arm EXISTS, and
the hook can still never fire — because every backend gates the paste
occurrence on the focused widget's ACCEPT LIST (gtk.rs:2842,
winui/mod.rs:5574, KayaSwiftUI.swift:8875) and falls back to the
platform's own insertion when it is empty, and no binding can put an
accept list on a template node. `app.onPaste(node, ...)` compiles,
registers, and waits forever. Exactly as invisible as D2's dropped value
change, one layer up.

So `accepts` is the keystone of this slice, not a rider. Rust is the one
inversion: it CAN spell every prop at the floor (`Tpl::set`) and is the
only binding with NO node paste registrar at all.

### P1 — the surface, all eight

Each binding's template zone gains, in its own idiom, per its survey
report's typechecked proposal:

- `a11y_id`, `a11y_label` — source-taking (const / signal / the row's
  own field). The label from the row's field is the point: a list row
  announcing its own name to assistive tech.
- `a11y_hint` — the four activation kinds; no binding-side wall (§0).
- `accepts` — const only (an accept list does not vary per row; every
  survey agreed), following each binding's LIVE accepts idiom (a chain
  in five, a bare setter in three — docs/deferred.md's 3d table).
- the node paste registrar where missing (Rust only).

Surfaces, plural, where the binding has them: Java lands props on `Tpl`
AND `RowSurface`; Go has FIVE template surfaces (the generated Row was
uncounted); Rust's `Row` façade forwards everything (tpl-surfaces.py
already holds that pair level).

Python's shape is its own: `Node` carries only `context_menu` today and
the a11y/accepts/on_paste methods are Widget-only — the ambient-zone
exemption does NOT extend to props. Its survey's fix (a shared handle
base) is the right one; its gate clause reads the class structure by
`ast`, not by regex and not by import-probing a built dylib.

### P2 — the gate

check-sugar-surface gains receiver-keyed clauses per prop per binding,
in the grow clause's shape — WITH the lesson the survey handed back: the
OCaml grow pattern I wrote was VACUOUS (matched the live `set_grow`,
proven by perturbation; fixed 2026-08-10, watched both ways). Every new
pattern is keyed on the template receiver and every one is watched
failing against a copy with the template spelling removed and the live
one intact.

### P3 — the scenes

- **a11y.steps** gains a stamped-rows section: a collection whose row
  template is an entry with a const `a11y_id` and an `a11y_label` from
  the row's own field, two rows inserted at build, asserted with
  `expect_ax` against the platform's real tree. All nine guests
  (eight sugar + the C floor as the explicit tier); strings byte-frozen
  (invariant 6).
- **clipboard.steps** gains a stamped paste target: a one-row collection
  whose entry declares `accepts`, a paste into it, and the app's
  hook-output assertion. This is the leg that makes the node paste arm
  PRINT FOR THE FIRST TIME in every binding that has one — Go's
  OnPasteNode arm (app.go:3667) has never fired, and a branch nobody has
  seen fire is a guess (invariant 3, the why-not rule, one arm over).

## §2 — the floor tier

The census: 44 scene_rules patterns swept over all guests = 36 hits
(11 floor, 21 legitimate, 4 sugar-gap); 28 patterns had zero hits
anywhere. The classification, each part tested by the survey against its
own hit list:

### F1 — absolute patterns move into tools/guest-floor.py

The 28 zero-hit patterns plus Rust's `Prop::` and the bare
`.widget(`/`.Widget(` forms (strictly broader than the current
kind-naming pattern — closes the kind-in-a-variable hole at no cost),
per language, comment-stripped, no exemption table. Java's `.addChild(`
joins after its one offender is fixed (F4).

### F2 — sharpenings, each tested before it gates

- Generated files excluded by the `Code generated by` marker every
  generator already emits (first 5 lines) — never by a filename glob
  that would be a second list of the same fact.
- The For rules require a COLLECTION argument: ≥2 top-level arguments by
  paren-balanced scan (kaya's For takes collection-then-body; every
  stdlib forEach takes the body alone). Swift's is trailing-closure:
  `\.forEach\([^{]`.
- OCaml's element-bind family: the survey's S4 pattern, which fires on
  `bind_text_element row` and not on the sugar's `~bind_field:` labelled
  arguments. Haskell's twin pre-emptively.
- The "For whose result it drops" rows promote from milestone2-scoped to
  repo-wide once F5 lands `each` in the template zone (red-by-design
  until then, the depth-slice pattern).

### F3 — the SetText family retires by RENAMING, not by regex

Six languages spell the set_text WIDGET VERB (which the gate requires as
sugar) and the template PROP WRITE (which is the floor) with one name.
The receiver's type decides and no regex sees a type. Rust never had the
problem because it keeps them under two names (`set` + `set_text`).

So the other six get Rust's split: the template-zone prop write is
renamed (or hidden where the language allows and no generated code needs
it), the six scene_rules rows become absolute patterns, and the
contextual bucket empties. Churn is free; the verb keeps its name
everywhere; only the floor spelling moves.

### F4 — the floor calls the census actually found, fixed

- OCaml: `entry.ml:59`, `milestone2.ml:60,64` — `bind_text_element` in
  the two scenes the tier was BUILT for, unguarded because the
  `bind_text ` pattern's trailing space never matched the `_` that
  follows. The sugar exists (`label ~bind_field:element`, landed
  a6c23be); convert all three.
- Java: `TextareaScene.java:37-39` — three `addChild` calls where the
  column sugar exists; the same class as the haskell/ocaml textarea
  scenes fixed last slice, verified in the source.

### F5 — the sugar gaps the census exposed (binding work, not gate work)

- `each` in the TEMPLATE zone for OCaml and Haskell — Swift and C# have
  it in both zones, these two only live (an invariant-1 divergence with
  a guest comment already apologising for it, milestone2.ml:48-51).
  Lands first; F2's promotion depends on it.
- Haskell's live-zone bound slider (`sliderOn` takes only a constant;
  seven of eight bindings have the bound arm and their gallery guests
  use it — gallery.hs uses floor `bindValue` instead).
- Live-zone bound CAPTIONS (a button whose caption follows a signal)
  stay ABSENT in all eight — uniformly absent is uniform (invariant 1
  is about divergence, not completeness). The `bindText` sweep lands
  with zero hits; the first guest that needs a bound caption hits the
  sweep, adds an exemption naming this paragraph, and that is the signal
  to build the sugar. Recorded so the pothole is a signpost.

### F6 — loose ends from the reports, fixed in passing

Haskell's stale "template-zone props do not exist in any binding yet"
haddock (KayaApp.hs:2276); Rust's `[WidgetRef::accepts]` intra-doc link
to a type that does not exist (app.rs:1618); docs/deferred.md's props
entry names spacing/align which are floor-reachable on template
containers today — the ledger entry retires with this plan.

## §3 — sequencing

1. Rust depth slice (props P1 + the missing paste registrar + P2's
   clauses for rust), unit-green.
2. Fan out P1 to seven bindings — each agent owns its binding + its
   guests only; ALL gate files stay with the coordinator (seven agents
   editing one gate script is how sweeps drift).
3. F4 + F5 + F3's renames ride the same fan-out, assigned per language.
4. Gate work, centralized: P2 clauses × 8, guest-floor.py's F1/F2
   tables, scene_rules' retirements. Every pattern watched BOTH ways —
   firing on a survey hit, quiet on a survey legitimate.
5. The two scene extensions, C floor included, byte-frozen strings.
6. Ladder: unit tests, 31/31, validate-mac, five lanes.
