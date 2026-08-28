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

The wire has ONE stack node whose axis is a property. The guest surface
keeps exactly `row()` and `column()` — sugar for the two axis values —
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
  both had to legislate around.
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
2. The settable-prop list: which properties a setter body may touch
   day one (axis, grow, visibility are the survey's usual trio).
3. Day-one scope: sugar alone, or sugar plus the general `when`
   spelling together (one mechanism either way).

Sequencing is RULED (2026-08-28): the packaging milestone's Android
step first, then this plan as its own milestone feeding the
portfolio's visual iteration.

## §2 — validation shape (sketch, firmed at build time)

A new `adaptive` conformance scene: on the desktops it drives
`resize_window` across the threshold and asserts `expect_axis` both
sides plus the setter diff applying and REVERTING (the auto-revert is
the half a one-way test would miss); on the phones the narrow side is
asserted natively — each side proven where it naturally occurs, no
platform asserting a width it cannot reach (the panes-band rule).
`expect_axis` joins all three harnesses (check-verbs holds the
coverage). check-sugar-surface grows the `stack_below` prop census and
the axis-addressability census across the eight bindings and both
construction zones. The portfolio gains its one keyword only after the
scene is green — the forcing artifact adopts the feature, never
debuts it.
