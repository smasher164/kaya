# Undo/redo — the design pass

The working record for the undo/redo milestone, in the shape
docs/clipboard-plan.md proved out: the argument first, every decision
stated with what it REPLACED, measurements before arms. The recon this
section rests on is three reports with file:line for every claim
(scratchpad/undo-recon-{core,platforms,surface}.md, 2026-08-04); the
load-bearing findings are restated here so this file stands alone.

## §0 — the argument, and the decisions (RATIFIED 2026-08-04)

D1 through D8 ratified by the maintainer as a set, 2026-08-04. The
D4 strictness question (refusing non-invertible ops in a group,
pressing apps toward the reactive doctrine) was flagged explicitly
and accepted with the rest.

### The finding that reframes the milestone

kaya does not get to introduce undo. It already has undo — twice —
and the two are not on speaking terms:

- **Native text undo is live inside kaya's own widgets on four
  backends today.** GTK's is ON BY DEFAULT by documented spec
  (GtkEditable:enable-undo and GtkTextBuffer:enable-undo both default
  TRUE); AppKit, UIKit and WinUI's text controls all carry working
  stacks; Compose's TextFieldState has one behind a version pin.
  Because every kaya text widget is uncontrolled toward the app, a
  native undo emits the ordinary `text_changed` occurrence — the
  channel already exists, which is the decisive difference from the
  clipboard (where copy had no channel and had to become a command).
- **It cannot be uniformly suppressed.** GTK alone has a clean
  per-widget switch. WinUI's TextBox has no IsUndoEnabled at all
  (confirmed by absence in kaya's own generated bindings); iOS's
  levers are app-granular; Compose's legacy path has no knob. A
  design where kaya owns typing undo must first win a fight that
  three platforms make unwinnable — that is carve-out territory for
  no benefit.
- **And it is already misbehaving**: kaya's programmatic writes land
  in the native stacks. On GTK, `set_text` and `Clear` are guarded
  only by apply_quiet — which suppresses occurrences, not undo — so
  Ctrl+Z today can revert a write the APP made. That is a live
  defect this design must fix regardless of everything else.

Meanwhile the core's half is genuinely cheap, as the ledger promised,
but only for half the protocol: a committed transaction is a forward
`Vec<TxOp>` with no before-image, and the core retains current state
for SIGNALS and COLLECTION ENTRIES but not for const widget props
(validated, emitted, forgotten — the no-widget-mirror doctrine). The
inverse of the reactive half is mechanically derivable — `Scene::apply`
already builds a per-batch rollback map of pre-transaction signal
values and throws it away at the end of every batch. The inverse of
the imperative half (const props, creates/destroys under never-reuse
ids, structure, focus, commands, dialogs) is not derivable from
anything the core holds.

### D1 — TWO TIERS, ONE SURFACE (replaces: one kaya-owned unified stack)

Text-local undo DELEGATES to the platform's native stacks, the way
Cut/Copy/Paste delegate. App-state undo is CORE-OWNED. The user sees
one Edit>Undo; the routing (D6) decides which tier answers.

The unified-stack alternative dies on the suppression matrix above,
and delegation buys native coalescing ("Undo Typing" merges
keystrokes) for free on every platform that has it. The editor's
typing undo is the native tier; its structural operations are the
core tier.

### D2 — THE UNDOABLE UNIT IS A NAMED GROUP, DECLARED AT THE OPENER,
### SPELLED ON THE WIRE (replaces: every transaction is an undo step;
### replaces: a nesting group scope)

The app marks an undoable transaction by naming it at the existing
opener — the handle five spell it on the transaction
(`tx.undoable("add todo")` in each language's casing), the ambient
three on the scope (Python a keyword argument, OCaml a labelled
optional, Haskell an entry-point variant). No new nesting concept
anywhere (Go forbids Build-in-Build; the ambient three have no handle
to hang a scope on).

On the wire the group is a new head-of-batch `TxOp::UndoGroup{label}`
— a transaction is a bare Vec with no header, so per-transaction
metadata has nowhere else to live, and making the group a WIRE fact
rather than a binding convention means both interpreters and
check-verbs see it, and a binding that forgets to emit it fails a
byte-compared scene instead of silently grouping wrong. Spec-first
per invariant 7.

Implicit one-transaction-one-step is rejected: handlers fire
per-gesture transactions constantly, most of them consequences rather
than intents, and a per-keystroke editor would earn one step per
character — the exact problem grouping exists to solve.

### D3 — UNDO APPLIES THE INVERSE; IT NEVER RE-RUNS HANDLERS
### (replaces: replay)

The echo doctrine ("a programmatic write never echoes; only the
user's act emits" — stated five times in spec.rs) makes replay
impossible without synthesizing user-shaped occurrences: the app
would see button_clicked for a click nobody made. The inverse is
computed core-side at APPLY time by keeping what apply already
computes and discards — the pre-transaction values of every signal
the batch touches, extended to the five collection deltas (whose
before-state the core retains in full). The log is ordinary heap
behind the mpsc; nothing rides the ring.

### D4 — THE UNDOABLE SET IS THE REACTIVE HALF, ENFORCED AT APPLY
### (replaces: best-effort undo of everything)

A group containing an op whose inverse the core cannot derive —
const prop sets, create/destroy/mount, window/nav/section/menu
structure, focus, commands, dialog/clipboard requests — is REFUSED
at apply, loudly, naming the op and the rule. The wall sits on the
path nobody can avoid (the guest dies on the scene that tries it),
the same shape as the one-dialog-per-process rule.

The teachable rule this buys: **undo restores state, and state is
signals plus collections.** It is also the rule that makes
DESIGN.md's "all state at rest is core-owned signals" claim true
where it is not yet — an app that wants a widget property undoable
binds it to a signal, which is the reactive doctrine saying what it
already said.

### D5 — AN UNDO IS SILENT EXCEPT FOR ONE OCCURRENCE, AND THE
### OCCURRENCE CARRIES THE DELTA (replaces: replayed occurrences;
### replaces: a bare notification)

Applying an inverse emits nothing (echo doctrine; D4 excludes the two
documented exceptions — commands and requests — from groups, so they
cannot arise). The app learns what happened from one new occurrence,
`undone` / `redone`, carrying the group label and the
CORE-AUTHORITATIVE list of reverted values (signal id → value,
collection deltas). The eight bindings update their mirrors from that
payload the way they already journal rollbacks — core stays the owner
of truth, and mirror drift across eight languages has one source
instead of eight reimplementations. This is the subtlest wire
question in the design; it gets the fattest negative tests.

### D6 — MenuRole::{Undo, Redo}, ROUTED FOCUSED-TEXT-FIRST
### (replaces: core-stack-only routing)

Edit>Undo asks the focused widget first: if it is a text widget whose
native stack reports undoable content (CanUndo and kin), the native
tier answers. Otherwise the core stack answers. Enablement is that
same question, computed live at activation exactly as paste's
offer∩accepts is. This generalizes Apple's own responder-chain model
and is what an editor user expects: mid-typing, Undo means the
typing; after a structural action, Undo means the action.

Landing note recorded by the recon: MENU_ROLES is one line NOT in the
spec hash (adding roles regenerates nothing and no gate fires), and
all four backends carry a hard-coded "cut"|"copy"|"paste" filter in
their enablement refresh — four silent-failure sites a new role must
join. The milestone therefore adds the gate clause FIRST (the
clipboard hold-open pattern): a role in MENU_ROLES must appear in
every backend's filter, self-tested, red until the fan-out completes.

### D7 — A PROGRAMMATIC WRITE RESETS THE WIDGET'S NATIVE UNDO
### HISTORY (replaces: the live bug; replaces: trying to keep the
### user's stack across app writes)

Uniform semantics, per-platform spelling: GTK wraps kaya writes in
begin/end_irreversible_action (documented to keep them out of the
stack while CLEARING history); WinUI calls ClearUndoRedoHistory after
each write (the only lever it has); Compose TextFieldState
undoState.clearHistory(); AppKit/UIKit the field's undoManager
removeAllActions — SUBJECT TO PROBE P3, which must first establish
whether writes enter those stacks at all. "Keep the user's history
across app writes" is not purchasable on WinUI, so the uniform rule
is the one every platform can spell: an app overwrite invalidates the
field's edit history. This applies at every apply_quiet text site and
fixes the Ctrl+Z-reverts-app-writes defect on day one.

### D8 — NAMED DEFERRALS

- **Collaborative/CRDT apps and app-owned undo** (raised by the
  maintainer, 2026-08-04). Collaborative undo is SELECTIVE — undo my
  operations, not the merged state — and belongs to the CRDT library;
  a state-revert stack imposed on synced state would be wrong, so the
  core stack being OPT-IN is load-bearing, not incidental. Two
  extension points this design must not foreclose, and does not:
  an app-intercept tier for the Undo role (the on_paste shape —
  routing gains "ask the app first" ahead of D6's two tiers), and a
  PER-WIDGET OPT-OUT of the native text-undo tier, so a field whose
  document lives in an app-owned model does not carry a native stack
  that can diverge from it (D7's clear-on-write mitigates this by
  accident for remote edits; the opt-out is the design). Both are
  additive; neither is built until an artifact demands it. The real
  cost of a CRDT editor is elsewhere entirely — an editor-grade text
  component with range edits and a selection model, which no
  form-field textarea provides and which the text-editor artifact
  will surface on its own terms.

- **Dynamic labels** ("Undo Typing") are an Apple-only convention
  (setActionName); scene strings stay static per invariant 6. Apple
  dress, later, if ever.
- **Session restoration** shares the log's serialization machinery
  but needs its own design: the recon shows backends hold state core
  never sees (scroll position, selection, in-field text), so
  "serialize the core scene" under-restores today. Sibling milestone.
- **Compose pin bump**: the TextFieldState tier wants Material3 1.4
  (kaya pins 1.3.2; foundation 1.7.8 already suffices for undoState).
  Decide at the Compose arm, not before.

### The probe plan (before any arm — the standing rule)

- **P3** Do programmatic writes enter the native stacks on
  WinUI/SwiftUI-mac/iOS/Compose as they measurably do on GTK? Decides
  D7's spelling per arm.
- **P4** Does kaya's minimal WinUI TextBox template still carry a
  context menu (any user-visible undo affordance at all on Windows)?
- **P5** The Windows double-fire: TextBoxes bypass keyboard
  accelerators, so a kaya Ctrl+Z chord fires beside the TextBox's own
  undo. Measure, then decide who wins.
- **P6** iOS gesture undo (shake, three-finger swipe) — which stack
  do they hit once D6/D7 are in place?
- **The harness hole**: no verb can press a chord at a native widget
  (GTK panics on an unowned chord), so the delegated tier is
  invisible to every gate today. The undo scene drives the role
  through menu_activate "Edit>Undo" — which parses already — and the
  chord-level coverage question is answered by the probe before the
  scene is written.

## §1 onwards — to be written

The depth slice after ratification: spec + core log + Rust surface +
the SwiftUI mac arm + the scene, then the fan-out, per the sequencing
doctrine.
