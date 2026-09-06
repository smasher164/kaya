# Adaptive content layout — the design pass

Status: DESIGN, ratified by the maintainer 2026-08-28 in an iterative
session over the phone captures of the portfolio dashboard (the iOS
depth slice's screenshots: the desktop's second column running off the
phone's right edge). The forcing artifact is that dashboard; the
evidence base is docs/probes/adaptive-layout-2026.md (every API name
verified against a live primary source, six frameworks plus the web).

## §0 — what the research settled

The convergences the plan stands on, in one breath (the probe holds the
details and quotations): key on the WINDOW, never the device; a
density-independent unit; monotone at-least thresholds, never equality
on classes; the adaptation is a DIFF against the base declaration;
children keep identity across the switch — the naive
`if narrow { column } else { row }` is the one spelling every framework
built machinery to avoid; and the arrangement axis is DATA, not TYPE,
in every mainstream toolkit — the two that made it a type both paid,
SwiftUI with AnyLayout and Compose by capitulating in 2026 with
FlexBox. The container-riding one-keyword spelling kaya adds is the
web's most-used responsive idiom (Tailwind's `flex-col md:flex-row`)
and Flutter's most popular community widget (ResponsiveRowColumn, one
underlying Flex so child state survives) — a pattern users demonstrably
reach for that no native toolkit ships first-class.

## §1 — the decisions

### D1 — one container node; row and column are its only two spellings

ONE NODE, TWO CONSTRUCTOR SPELLINGS — refined at build time
(2026-08-28 recon): the wire KEEPS kinds `column`=1 and `row`=5,
because the harness addresses widgets by kind (`row#0`,
`column@detail`) and merging the kinds would reindex every
byte-frozen scene in the roster. The kinds are the constructor sugar
ON THE WIRE — each names the initial axis — while the NODE every
backend implements is one, parameterized by the `axis` property; a
widget created as `row` stays addressable as `row#N` whatever its
axis says today (identity is the creation kind, presentation is the
prop — the same split the template zone already lives by). The guest
surface keeps exactly `row()` and `column()`
and deliberately does NOT surface a third `stack()` constructor
(ruled 2026-08-28): build-time axis choice is a legal build-time
conditional (the trace runs once), the adaptive switch is D3's job, and
the runtime toggle is D2's — so the constructor would be a third name
for nothing. Flutter exposes `Flex` and nobody writes it; Tailwind
never named a "stack".

### D2 — the axis is addressable on the handle

Ruled explicitly: `.axis` is readable and settable on a row/column
handle even though no constructor spells it. Three consumers force it:
a `when` setter body needs a property to write (`dash.axis =
"vertical"`); a USER-driven orientation toggle — the editor's
flip-split button, a filmstrip going vertical on command — is a click
handler writing the prop, keyed on nothing about the window, and is
inexpressible without it; and the harness observable is the property
(`expect_axis`), whatever spelling set it.

### D3 — adaptive switching: a core-evaluated breakpoint applying property setters

D3'S DEPTH LANDED 2026-08-28, the axis increment's same evening:
`TxOp::CreateBreakpoint` (wire kind 48 — window, threshold, setter
list), the scene evaluating on `kaya_window_metrics` reports with the
width LATCHED (a breakpoint declared before any report applies at the
first — the phone that never resizes), same-width reports emitting
nothing, and the revert restoring the GUEST-AUTHORED value
(`authored_axis`, written only by guest SetProperty) or the creation
kind's own. The setter list was axis-only at the root until D6.2 widened
it on 2026-09-05 to a grid's `columns` (the same authored-value revert,
`authored_columns`), with the refusal of anything else unit-watched. Reporters: SwiftUI through the
vtable (`window_metrics` beside `canvas_track` — a flat-namespace call
was measured unresolvable, the vtable IS the interpreters' contract),
whole-window beside the form-factor recorder; GTK into ITS OWN scene
(canvas_track_report's route — the capi presentation slot belongs to
the interpreters, and a report there reaches a scene the widget
backend never reads), scheduled past held CORE borrows. Rust surface:
`Tx::breakpoint_below(width, |bp| bp.axis(..))`. The adaptive scene's
breakpoint half asserts apply AND auto-revert across resize_window on
the desktops; the iOS leg cuts at resize_window and asserts its
always-narrow truth as a per-leg EXTRA — each side proven where it
naturally occurs (§2's sentence, running). Unit-walked in
`breakpoint_applies_and_reverts_around_the_threshold` + the wire
round-trip. TWO MEASURED TRAPS from the lanes: a GTK harness read may
not pump the main context once an idle can trigger relayouts
(gtk.rs's 1630 rule — the x11 abort), and polled assertions cannot
serve as stale-value negatives (expecting the old value wins the race
by construction; the valid negative expects a state that never
arrives).

The mechanism is one wire record: a width threshold plus a list of
(node, prop, value) setters, applied when the window crosses down,
auto-reverted crossing back (the diff-against-base rule). THE CORE
EVALUATES THE CONDITION — never the platform's own breakpoint
machinery (AdwBreakpoint on one lane and AdaptiveTrigger on another
would put uniform semantics at the platforms' mercy), and never a
guest-side derived-signal lambda (the binding's `_derive` shape): the
core owns the window's width, a guest round trip per resize is wrong,
and a wedged app thread must not stop the layout from adapting. Two
spellings lower to the record:

- `row(stack_below=600)` — the container-riding sugar for the
  overwhelmingly common one-prop case; the portfolio dashboard's whole
  phone fix is this one keyword on its outer row. Keys on WINDOW
  width: self-measurement is the circularity trap CSS and libadwaita
  both had to legislate around. (SUPERSEDED 2026-08-31: the authored
  width died — the spelling is `stack_when(compact)`, D8.)
- `with kaya.when(win.width < 600): dash.axis = "vertical"` — the
  general spelling for multi-prop diffs and shared thresholds,
  extending `kaya.when`'s existing contract (traced, not taken):
  widgets CREATED in a when body remain a conditional subtree (the
  existing semantics), property writes to FOREIGN handles become the
  setter list. One construct, both meanings, distinguished by what the
  trace saw.

### D4 — keyed when/otherwise arms: LEDGERED (ruled 2026-08-28)

For narrow layouts that are a DIFFERENT TREE rather than different
property values, the researched design is keyed arms — both traced at
declaration, SAME-KEY children unified into one living widget
re-parented at the switch, checkable at declaration where React's
reconciliation is a runtime gamble. No current scene or app needs it,
so the maintainer ruled it to the ledger rather than a plan phase:
docs/deferred.md carries the entry with the design's shape and its
recorded costs. It returns when a narrow layout a property diff cannot
serve actually exists.

### D5 — what is deliberately NOT in the design

- NO automatic reflow default: most rows are COMPOSITION (the mark chip
  beside its title, a button pair), not page layout; no surveyed
  framework auto-stacks (even CSS makes flex-wrap opt-in); and a
  default would make every scene's layout width-dependent, detonating
  the byte-frozen suite.
- NO fit-based selection (ViewThatFits): selects a different subtree
  per platform font metrics — the worst fit for invariant 6.
- NO measure-and-branch (LayoutBuilder/BoxWithConstraints): a build
  closure that cannot run until layout has run is a different
  execution model, not a new widget.
- The MIRRORED SUGAR (`column(row_above=)`, the web's mobile-first
  direction) is LEDGERED, not built (ruled 2026-08-28): one adaptive
  sugar until demand shows up. docs/deferred.md carries the entry.

### D6 — open rulings, marked for the maintainer at build time

1. Threshold spelling and unit: `stack_below=` reads naturally; the
   general form's comparison direction (below vs at-least) and the
   unit's name (logical points, matching the platforms' convergence).
   (Settled 2026-08-28 as `stack_below=<points>`, then SUPERSEDED
   2026-08-31 by the size-class ruling — D8.)
2. The settable-prop list: which properties a setter body may touch
   day one (axis, grow, visibility are the survey's usual trio).
   (Settled 2026-08-28 as axis alone; WIDENED 2026-09-05 by the
   maintainer to a GRID's `columns` — `columns_when(compact, n)` in all
   nine bindings — when the task manager's three-column Details form
   overflowed a 320dp phone, docs/tasks-plan.md §5. Grow and visibility
   stay unruled.)
3. Day-one scope: sugar alone, or sugar plus the general `when`
   spelling together (one mechanism either way).

Sequencing is RULED (2026-08-28): the packaging milestone's Android
step first, then this plan as its own milestone feeding the
portfolio's visual iteration.

### D7 — the adaptive fold (ratified 2026-08-30)

RATIFIED BY THE MAINTAINER 2026-08-30, choosing the derived fold over an
explicit `header=` slot: when a stacked-breakpoint row (`stack_when`
today; `stack_below` when ratified) is STACKED, its leading
hugging children fold into the viewport of its one grown table as
scroll-away content above row 0 — one scroll where the interim shape had
two — and crossing back restores them. NO NEW SPELLING ANYWHERE: the
surface is the stacking breakpoint itself, already in all eight
bindings, and the
fold is derived from the row's own shape, which is why the portfolio's
guest change was a deletion (the interim `scroll(grow=1)` wrapper came
out). An explicit header slot was rejected because a header renders
inside the collection's scroll on EVERY width, which would have changed
the desktop's two-column screen or dragged conditional layout into the
guest — the ledgered breakpoint-vocabulary question, made worse.

THE SHAPE RULE IS TOTAL and the core owns it (`fold_assignment` in
scene.rs, apply record 37 on the apply channel — a record and not a
prop, because a PROPS entry generates a guest setter in every binding
and no guest may spell derived state): a stacked row folds IF AND ONLY
IF exactly one child grows, that child is a declared table, and at least
one hugging child precedes it. Trailing children keep stacking —
trailing content on a stacked screen is bottom-bar-shaped, and a bar
that scrolls away with the rows would be wrong. Two growers keep the
two-viewport split; a grown non-table keeps stacking; everything that
fails the shape is exactly what it was before.

EVALUATION IS AT THE BATCH TAIL, not at the CreateBreakpoint op: the
sugar spells `stack_when` in the row's constructor, so at that op the
row has no children and the rule would read an empty shape — watched
failing under the op-time evaluation (scene.rs's
`stacked_fold_computed_at_the_batch_tail_sees_the_rows_children`).

LOWERINGS, one semantics in four spellings: SwiftUI renders folded
children above `rows()` inside the synthesized tier's ScrollView, and a
FOLDED table routes to the synthesized tier at every width on every
platform (`kayaTableTier`'s `folded` input; the native NSTableView owns
its scroll and takes no content above row 0) — which is also what makes
the mac reach that tier through the app. Compose folds them into the
table's own Layout (this backend cannot nest a second vertical
scrollable), the `rowsTopPx` origin carrying the folded block so the
band arithmetic never changes. GTK and WinUI move the widget into the
scrolling side under their pinned headers — GTK into the content box
above the top spacer behind the `kaya-folded` class, WinUI into an
Auto-row wrap Grid above the band — each with the folded extent added
back wherever band space meets scroll space.

THE OBSERVABLE IS `expect_folded <child> <table|none>`, in all three
harnesses with one spelling, reading which viewport the child RENDERS in
(class + ancestry on GTK, wrap membership on WinUI, the render's own
fold registry on the interpreters). The portfolio scene asserts the full
round trip at its END — not-folded at 900, folded at 640, not-folded
back at 900 — so the phones' cut costs nothing above it, and each phone
leg asserts its always-stacked truth as its extra.

FOUND BY ITS OWN ASSERTIONS ON DAY ONE: the Windows leg reddened because
every pushed-entry screen's breakpoint was DEAD on that backend —
`mounted_roots` is keyed by SURFACE and the metrics loop handed entry
ids to `window_client_width`, which answered None (eighteen metrics
passes, not one width reaching the core). The adaptive scene could never
see it: no entries.

### D7.5 — the grouped screen, general (ratified 2026-08-30)

RATIFIED BY THE MAINTAINER in two steps the same day: first the folded
screen ("yes" to screen-scoped ground + section carding), then the
general rule when the dashboard was seen lagging the transactions
screen. ONE DERIVATION, iOS ONLY: a screen whose content holds a table
lowers as a grouped screen — `systemGroupedBackground` on the SCREEN,
edge to edge behind the title, worn by the surface roots off a registry
(`kayaRecomputeGroupedSurfaces`) rewritten at every apply batch tail.
The screen's PRIMARY FLOW (highest vertical container whose subtree
holds a table, reached through wrappers along a single table-bearing
child) renders as the SECTION STREAM: the flow flattens through its
vertical containers, then a `heading`-role label opens a section as its
header, a `caption`-role label closes one as its footer, a table is a
section body of its own, and every other run of consecutive children is
one `secondarySystemGroupedBackground` card. Headers and footers sit
bare on the ground in Settings' own dress (footnote scale, secondary,
headers uppercased) — full-size content never does. The per-table
GROUND BAND DIED with this rule: a synthesized card can only ever
appear on a grouped screen now, so the fold-era suppression machinery
(the foldHost flag, the folded-ground environment key, the live-pad
instrument read) collapsed back to constants, and the fold's interior
speaks the same section grammar through the same renderer. Android and
the desktops are UNCHANGED BY DESIGN — Material's bare headline on the
background is the same semantics in that platform's spelling.
tools/check-table-card.py pins the screen ground, its two wearers and
the card's one spelling; a side-by-side screen (two table-bearing
children, e.g. the pad's unstacked row) grounds but does not section.

WIDENED TO FORMS 2026-09-06 (ratified that morning, docs/forms-plan.md): the
carrier is a table OR a form — a column of two or more labelled rows.
The task manager's Details screen has no table, and its form's
inset-grouped card was invisible on the white ground (captured
2026-09-06): the card only reads against `systemGroupedBackground`. A
form is a section body of its own, like a table, rendered by the form
arm (which draws the card); the run before it (the notes field) and the
run after it (the Delete button) are cards of their own, the Settings
shape. The flatten does not dissolve a form. macOS is unchanged, since
`kayaIsGroupedFlow` is false there by construction.

### D8 — the breakpoint speaks size classes (ruled and built 2026-08-31)

THE RAW NUMBER DIED. `stack_below=<points>` made the author invent the
one number every platform then had to honor; the maintainer's question
("how is the user supposed to know what the breakpoint value is?") is
the same one that moved Apple, Material and the CSS frameworks to NAMED
CLASSES, and kaya followed: `stack_when(compact)` in every binding's own
idiom (Rust `SizeClass::Compact`, Swift `.stackWhen(.compact)`, Python
`stack_when=kaya.COMPACT`, Go `StackWhen(kaya.SizeClassCompact)`, Java
`stackWhen(SizeClass.COMPACT)`, C# `stackWhen: SizeClass.Compact`,
OCaml `~stack_when:Compact`, Haskell `StackWhen Compact`) — a TYPED
name, so a typo is a compile error in the six compiled languages.
`compact` is the only class a guest may name day one; the root refuses
the rest by name.

WHO ANSWERS "IS THE WINDOW COMPACT": iOS reports the platform's own
horizontal size class with every metrics report — kaya_window_metrics
grew a `size_class` argument, one call carrying width and class so a
rotation never evaluates a stale pair — and every other platform
reports NONE, the core deriving the class from the latched width at the
kaya-owned 600-point boundary (wire::SIZE_CLASS_COMPACT_BELOW,
Material's compact edge). A reported platform class BEATS the width —
an iPad split-view pane can be compact at widths the boundary calls
regular — which is the one behavior separating this design from a
renamed threshold (scene.rs's
`a_reported_platform_class_beats_the_width_boundary`). An unresolved
environment class reports NONE rather than a guess.

On the wire, record 48's threshold field became `size_class` (i64; the
spec enum "size_class" generates the vocabulary into all eight bindings
and both headers, and capi.rs carries the KAYA_-prefixed copies pinned
by const-assert). The interpreters never see the record — the core
evaluates, as D3 always said; their only change is the metrics report.
The portfolio's `stack_below=700` and the adaptive scene's 520 became
`stack_when(compact)`, and portfolio.steps' stacked assert moved inside
the boundary (640 -> 560).

## §1.5 — the milestone landed 2026-08-28

The breadth slice closed the same evening as the depth: the record went
to the SPEC ROOT (kind 48, threshold a tagged f64, setters one flat
Values list of thirds), so all eight encoders come out of the generator;
`stack_below` rides the row in each binding's own idiom and the template
zone is refused BY TYPE in seven, by the frozen live-only sentence in
Python (its one handle serves both zones); the axis setter joins it
everywhere for D2. WinUI's stub is gone — `core.axes` plus
`effective_vertical`, with reindex clearing the axis it is not using and
stamping both attached indices — and Compose reports the width through a
new JNI native. The scene runs in eight languages on the mac, seven on
linux, five on windows and one on each phone (cut at the resize a phone
cannot command, with the always-narrow truth as the leg's extra). The
portfolio adopted the feature after the scene was green, as §2 requires:
`stack_below=700` on the dashboard's outer row.

D6's three rulings, settled by building: the threshold spelling is
`stack_below=<points>` (below, logical points, matching the platforms'
convergence); the setter list is axis-only, refused at the root by name
(widened to a grid's columns 2026-09-05, see D6 item 2);
and day one is the SUGAR ALONE — the general `when` spelling is D4's
neighbour on the ledger, unbuilt, since no scene or app needs a
multi-prop diff yet. (The threshold half is SUPERSEDED 2026-08-31 by
D8: the record's f64 width became the i64 spec enum "size_class".)

## §2 — validation shape (sketch, firmed at build time)

A new `adaptive` conformance scene: on the desktops it drives
`resize_window` across the threshold and asserts `expect_axis` both
sides plus the setter diff applying and REVERTING (the auto-revert is
the half a one-way test would miss); on the phones the narrow side is
asserted natively — each side proven where it naturally occurs, no
platform asserting a width it cannot reach (the panes-band rule).
`expect_axis` joins all three harnesses (check-verbs holds the
coverage). The eight-language wall on the sugar is the adaptive guests
themselves — every binding's `stack_when` spelling is exercised by a
compiled (or run) guest on the mac lane, so a dropped constructor fails
a build, not a census. The portfolio gains its one keyword only after the
scene is green — the forcing artifact adopts the feature, never
debuts it.
