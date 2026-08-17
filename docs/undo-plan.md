# Undo/redo — the design pass

Status: LANDED — the depth slice (`3044d73`), the five-arm fan-out
(`a9fbf9b`, `d41247a`), the completion pass (`43144f0`) and §3b's
stamped copies (`1d2cf95`). §5.4, the one item this file left open for
the maintainer, is answered in §3b.

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
- **And it was already misbehaving**: kaya's programmatic writes landed
  in the native stacks. On GTK, `set_text` and `Clear` were guarded
  only by apply_quiet — which suppresses occurrences, not undo — so
  Ctrl+Z could revert a write the APP made. That was a live
  defect this design had to fix regardless of everything else, and D7
  (widened by A1, narrowed by A3) is the fix.

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

## §1 — what the platforms actually charge (measured 2026-08-04)

Probes P3-P6, run before any arm (tools/{win,mac,ios,android}/undoprobe
are the probe sources; the standing rule held — every platform
overturned something).

### 1. Windows: D7 IS FREE, AND THE DOUBLE-FIRE IS A MYTH — THE REAL
### RISK IS CHORD THEFT

A programmatic write does not enter the TextBox stack and WIPES the
field's existing history by itself (typed "user" → CanUndo true;
SetProp → CanUndo false, Undo() inert). The GTK defect does not exist
here; ClearUndoRedoHistory() after a write is a measured no-op that
the arm still calls, in the text-differs branch, as the explicit
spelling of the rule. The documented accelerator double-fire never
happens because kaya dispatches chords through a thread-scoped
keyboard hook, not KeyboardAccelerator — and that inverts the risk:
the HOOK steals Ctrl+Z from the TextBox (measured: with the chord
owned, the menu fired and the TextBox never saw the key; a DISABLED
Edit>Undo still eats it dead). So D6's routing on Windows lives
INSIDE key_hook: ask the focused editable's CanUndo, call its Undo(),
consume. The minimal template already shows Undo on right-click,
Shift+F10 and VK_APPS (context_attach on text widgets is refused at
the root, so an app menu cannot displace it). A native undo emits the
ordinary text_changed. HARNESS CONSEQUENCE: the set_text verb is a
programmatic write and clears history, so the native-tier scene needs
a REAL-KEYSTROKE typing verb.

### 2. macOS: THE GTK DEFECT EXISTS HERE IN A WORSE FORM, AND APPKIT
### ALREADY IMPLEMENTS D6

A kaya entry edits through the window's FIELD EDITOR with a private
NSCellUndoManager; a textarea is an NSTextView on the WINDOW's
manager. A programmatic write on a FOCUSED entry REGISTERS an undo
action and JOINS the open "Typing" group — one Cmd+Z reverts the
user's typing and the app's write together — and on the textarea it
registers nothing but leaves a STALE RANGE: undo turns "PROG" into
"G", a string that never existed. removeAllActions() on the first
responder's manager buys exactly D7, with one trap: it must run AFTER
SwiftUI pushes the value into AppKit, not at the model write. An
unfocused write registers nothing and an entry's history dies on a
focus round trip, so the negative test types, KEEPS focus, writes,
then asserts canUndo == false. Routing: NSApp's own undo: path
resolves against the first responder's manager and already implements
the ratified focused-text-first routing INCLUDING the fall-through
(typing first, app action on the second Cmd+Z) with live titles and
enablement — kayaSendToFocusedResponder's existing shape travels it
unchanged. Do NOT implement windowWillReturnUndoManager: measured to
buy nothing and to merge textarea typing with kaya registrations into
one step. (A plausible false finding to the contrary in rounds 1-2
was an activation artifact; round 3 isolated it — one mode per
process.)

### 3. iOS: D7 IS FREE, ROUTING IS NOT

Both text kinds get a private _UITextUndoManager (never the
window's), and a programmatic write registers nothing AND clears the
field's stack by itself. The explicit clear is a redundant no-op —
it must not be mistaken for the thing that buys the rule.
sendAction(undo:) reaches the focused field only and NEVER falls
through, so kaya writes the two-step routing by hand; and
canPerformAction(undo:) answers false even when undo works — read
undoManager?.canUndo for enablement. UIMenuBuilder already hands kaya
an Edit menu containing Undo/Redo. Shake-to-edit is ON by default in
a kaya-shaped app and drives only the focused field's private manager
(discriminator-proven), so the core tier is invisible to shake.
UNMEASURED: the three-finger swipe gesture (not synthesizable by any
route short of XCTest multi-touch; named, not guessed at).

### 4. Compose: THE LEGACY PATH IS DISQUALIFIED, AND NO PIN BUMP IS
### NEEDED

The recon's "no knob" was right about the API and wrong about the
stack: CoreTextField holds an INTERNAL UndoManager (unreachable by
type — compile-proven), Ctrl+Z drives it today, and programmatic
writes ENTER it. Worst case measured: a field the user never touched,
one app write, one Ctrl+Z — field empty, and onValueChange fires,
i.e. kaya emits a phantom text_changed and the app's write is lost.
That defect disqualifies the legacy path on its own. The
TextFieldState path has D7 free (a programmatic write clears history
— even a no-op rewrite of identical text), plus readable
canUndo/undo()/redo() for D6. And the move needs NO pin bump:
material3 1.3.1 rejects TextField(state:) (compile-proven), but
BasicTextField(state=) + TextFieldDefaults.DecorationBox compiles and
renders as a proper M3 field at current pins (foundation 1.7.5 /
material3 1.3.1 via BOM 2024.10.01 — the recon's 1.7.8/1.3.2 was
wrong); the only source cost is two @OptIn annotations, each proven
required by removing it.

### The arm decisions these findings settle

- D7's spelling per arm: GTK irreversible-action bracketing; mac
  removeAllActions AFTER the AppKit sync; Windows and iOS free (call
  the explicit clear anyway where one exists, as documentation);
  Compose = the TextFieldState migration itself.
- D6's routing per arm: mac delegates to AppKit's own resolution;
  iOS hand-writes the two-step; Windows routes inside key_hook;
  GTK and Compose route in kaya (no platform path exists).
- The Compose entry/textarea move to BasicTextField(state) +
  DecorationBox lands WITH the undo arm (it fixes the phantom-undo
  defect independently of undo).
- The harness gains a real-keystroke typing verb before the
  native-tier scene is written.

## §2 — the design, stress-tested (2026-08-04) and AMENDED

Two research passes after the probes, deliberately adversarial: the
prior-art sweep (scratchpad/undo-prior-art.md, 56 sources) and the
toolkit survey (scratchpad/undo-framework-survey.md, 30 frameworks
sorted by whether they own their rendering or lower to native
widgets). The strategy stands. Five things about the WRITING of it
did not, and are amended below.

### What survived, and why it is now a citable position

- **The interleave hole is real, named and shipped.** Two stacks have
  no total order: type "a" → app action X → type "b" undoes as b, a,
  X. The literature calls it SELECTIVE UNDO, whose defining property
  is that it "creates a new node that has never existed before"
  (Yoon & Myers, ICSE 2015; Berlage, TOCHI 1994). VS Code documents
  kaya's exact model ("separate undo stacks for the editor and the
  File Explorer, and we choose which one to undo based on focus")
  and carries an open issue; Drupal Canvas filed the redo version
  ("pressing undo in our UI now undoes the undo the user did"). It
  is reachable in OUR OWN entry scene today: type "milk", click add
  (appends a todo AND clears+refocuses the field), Cmd+Z → the clear
  is undone, "milk" returns, the todo stays. A state that never
  existed.
- **Nobody solves it; four escapes exist** — amnesia (AppKit drops a
  field's history when the insertion point leaves), unify (WebKit,
  Word, Qt's proxy-command pattern), refuse (JetBrains: "Cannot
  undo. Following files affected by this action have already been
  changed"), show the history (Photoshop). D1 as ratified took none.
  A1 below takes amnesia.
- **D1 is the MAJORITY position across all toolkits, not a
  compromise.** Qt owns its rendering and still ships two disjoint
  stacks (the QTextDocument stack is not even QUndoView-compatible);
  Godot the same; only Swing unified. Every framework that keeps a
  native text widget either ships no app undo at all (React Native,
  MAUI, Xamarin.Forms, WinForms, Delphi VCL, NativeScript) or ships
  one documented as independent of the control's (wxWidgets).
  Eclipse is the one unified case and reached it by leaving the
  category: SWT's StyledText is custom-drawn with no undo to fight.
- **kaya would be the first to put the routing IN THE FRAMEWORK.**
  wxTextCtrl processes wxID_UNDO by default; the Document/View
  command processor also handles it; no precedence rule is
  documented anywhere — and the community fix is D6's routing,
  hand-written per application. Our Windows chord-theft finding
  (§1.1) is that same collision, measured twenty years later.
- **The cost of doing nothing is vendor-stated.** Unity UI Toolkit:
  Ctrl+Z in a TextField falls through to asset-level undo and
  reverts "some previous modification to an asset, which the user
  may not even notice" — and Unity's own moderators then state D4
  nearly word for word ("The UI is only a view of your data and
  cannot generally handle undo").

### A1 — WIDEN D7's TRIGGER: A CORE UNDO GROUP CLEARS THE FOCUSED
### FIELD'S NATIVE HISTORY (amends D7)

D7 clears a field's native history when kaya writes its text. Widen
it: also clear when a CORE UNDO GROUP COMMITS while that field has
focus. Then everything left in a native stack is strictly newer than
everything in the core stack, "ask the focused text first" IS "ask
the most recent first", and the interleave becomes UNCONSTRUCTIBLE
rather than merely unlikely. Same call sites, same per-arm spelling
as D7 (§1's table), no new platform surface.

The cost, stated plainly because it is the user-visible one: typing
history is lost when an app action intervenes. That is the amnesia
escape, which AppKit already ships ("Once the insertion point leaves
the field or cell, prior operations cannot be undone"), so on the
platform where users have the strongest habits it is the habituated
behavior.

### A2 — D4 IGNORES PURE EFFECTS INSTEAD OF REFUSING THEM (amends D4)

As ratified, D4 refuses a group containing ANY non-invertible op —
which refuses an ordinary handler that appends to a collection and
then focuses the new row. Split the set: ops whose omission would
leave state INCONSISTENT (create/destroy/mount, structure, const
prop sets, commands, dialog/clipboard requests) still refuse and
still teach the reactive doctrine; PURE EFFECTS (focus,
scroll_to) are permitted and simply not restored. Undo restores
state; it does not restore where you were looking.

### A3 — D7 FIRES ONLY WHEN THE WRITE CHANGES THE TEXT (amends D7)

Compose measured that even a no-op rewrite of identical text clears
history. An app that mirrors a field's text into a signal and writes
it back would therefore silently lose native undo on every
keystroke. kaya guards it: the clear runs in the text-differs
branch, which is also what the Windows probe independently
recommended.

### A4 — "CAN THE FOCUSED WIDGET UNDO?" IS ONE NAMED CORE QUERY
### (amends D6)

D6 already flags four hard-coded role filters as silent-failure
sites. Do not add a fifth expression of the same question: make it a
single named core-side query answered per backend, the way JavaFX
exposes undoableProperty()/redoableProperty() as observable state.
Avalonia had the query internally for years and never exposed it
(#9433) — the shape to avoid.

### A5 — CORRECT D1'S RATIONALE, AND STATE THE SCOPE

- D1 argued uniform suppression is unpurchasable. Partly false:
  WPF has shipped TextBoxBase.IsUndoEnabled since .NET 3.0,
  documented as "Setting this property to false clears the undo
  stack" — D7's semantics exactly. WinUI 3 dropped it, so the
  Windows leg is a WinUI REGRESSION, not a platform fact. The
  argument that does survive is COALESCING: owning typing means
  matching five native keystroke cadences with IME, and Flutter —
  which owns its whole text stack — concedes its cadence is "a best
  approximation of the native behaviors", with an open P2 and a
  Japanese-IME undo bug.
- SCOPE, now citable rather than a judgement: a genuinely unified
  history requires an EDITOR-GRADE TEXT COMPONENT that kaya has not
  bought. Eclipse paid that bill (custom-drawn StyledText), and every
  web editor pays it (ProseMirror, CodeMirror, Monaco all take undo
  over rather than ride the browser's). D8's deferral is that bill,
  named.
- The uncosted third design, recorded so it is not rediscovered:
  Flutter on iOS owns the stack and delegates only TRIGGER and
  ENABLEMENT to NSUndoManager, which buys shake and three-finger
  swipe reaching app state (§1.3 measured that as impossible under
  D1). It does not generalize — macOS is the only platform exposing
  the hook, iOS punishes the equivalent attempt, and WinUI/GTK/
  Android expose nothing.

### A6 — THE PROTOCOL GAP: A NATIVE UNDO IS INDISTINGUISHABLE FROM
### TYPING (extends D5)

A native-tier undo emits only text_changed, byte-identical to a
keystroke, so nothing tells the app the other stack moved — the
mechanism behind the Drupal Canvas failure. kaya emits undone/redone
when IT routes the undo (all four backends can know: the Windows
hook sees the chord, the others route through the role). A native
undo triggered by an affordance kaya does not intercept — the
Windows context menu, iOS shake — stays indistinguishable, and that
is a DOCUMENTED limitation bounded by A1's amnesia, not a silent
one.

### A7 — THE NATIVE TIER IS OPT-OUT-ABLE PER WIDGET

Already named in D8 as the CRDT extension point; the survey supplies
a non-collaborative artifact that demands it: JabRef #11420 — two
undo systems processed the same chord and JavaFX's internal undo
state went null; the fix was consuming the key event. An app that
owns a field's document needs to say so.

### A8 — TESTABILITY (the invariant-1 obligation)

The delegated tier was unobservable when this was written: no harness
verb could press a chord at a native widget (GTK panics on an unowned
chord), and set_text is a programmatic write that clears the very
history a native-tier scene must assert. The milestone adds a
REAL-KEYSTROKE typing verb before the scene is written; a tier kaya
cannot drive in a scene cannot be held to invariant 1's uniform
semantics, and saying so now is cheaper than discovering it at the
fan-out. DONE: the verb is `type` (crates/kaya/src/harness.rs).

## §3 — EPISODE BANKING (ratified 2026-08-04, IN the depth slice
## from day one)

The maintainer's call, after the adversarial pass: do not ship the
amnesia and upgrade later — build the ledger from the start. A1-A8
stand unchanged; banking is a strict extension that turns A1's
history LOSS into granularity degradation. The platform surface is
identical to §1/§2 (same clears, same CanUndo query, same routing
hook points); everything below is core-side bookkeeping over an
occurrence stream core already receives.

### The model

Core keeps ONE ordered ledger per window: entries are either
`Group { label, inverse-delta }` (D2/D3 as ratified) or
`TextEpisode { field, before, after }`. An episode is the run of
`text_changed` occurrences on one field between CLEARS — banked as
the events stream in (before-image captured at the first event,
after-image updated on each). The user's undo history IS the ledger,
newest-first, with no holes.

### The keystone invariant: NATIVE STACK ⊆ CURRENT EPISODE

A1's clear is what makes the ledger total-ordered: whenever a core
group commits with a field focused (A1) or kaya writes a field's
text (D7), that field's native stack is cleared — and because the
episode was already banked, the clear costs nothing. Every episode
therefore begins with an EMPTY native stack, so the native stack can
never reach past the current episode's start. Even the affordances
kaya cannot intercept (the Windows context-menu Undo, iOS shake) are
bounded by it — they can walk the frontier episode and physically
nothing else.

### Routing (extends D6; the two-tier ask becomes a three-way)

On Edit>Undo / the chord / the role:
1. Newest ledger entry is a TextEpisode on the FOCUSED field and the
   field's native CanUndo is true → call native Undo(). Native emits
   text_changed; core observes it, updates the episode's current
   text, and CONSUMES the episode when the text reaches its
   before-image or native CanUndo goes false.
2. Newest entry is a Group → apply the inverse (D3), emit `undone`
   with the delta (D5).
3. Newest entry is a TextEpisode that is NOT frontier-live (other
   field, cleared stack, focus moved) → core restores the episode's
   before-image itself — a programmatic write, which by D7 clears
   that field's stack: one coarse, correctly-ordered step. Emits
   `undone` naming the episode.
Redo is symmetric (after-image restore for banked episodes; native
Redo only at the frontier).

### Reconciliation rules (the fiddly part, each with a negative test)

- Core tracks the frontier episode's current text purely from the
  observed text_changed stream — never by reading the widget (the
  no-mirror-reads doctrine holds).
- A partial native undo leaves the episode OPEN with its current
  text between images; further typing extends the same episode
  (native redo history dies on the next keystroke — the platform's
  own rule, inherited, not fought).
- A native undo that REACHES the before-image spends the episode as a
  step back and BANKS IT FORWARD (added by the completion pass, §5).
  The frontier then moves to the entry underneath — a group, wherever
  A1's clear did its job — so the native tier can offer that run in
  neither direction, and a dropped episode would be a hole in a history
  this design promises has none. It redoes coarsely, which is the
  granularity the walk already spent.
- A native undo that exhausts CanUndo WITHOUT reaching the
  before-image (possible only if the platform coalesced across the
  episode start — the clear makes this unreachable, which is the
  negative test: provoke it and assert it cannot happen) falls back
  to the coarse restore.
- text_changed arriving for an UNFOCUSED field (programmatic; D7
  already fires) closes the episode as-is.
- Episode payloads are DELTAS for textarea-scale content (first/last
  images for entries; a diff for textareas) — the log must not
  double the memory of the widget it describes.

### What this buys, recorded so the tests assert it

- The user: Cmd+Z never hits a hole; the whole session walks back
  newest-first on every platform identically (frontier granularity
  is the only platform-flavored part). The scene asserts the
  interleave b, X, a — the exact sequence §2 proves impossible
  under two bare stacks.
- The developer: the unconditional promise (groups compose with
  typing, always); `undone`/`redone` fire for text-tier undos kaya
  routes, so dirty-state logic listens to one coherent stream; the
  ledger is the serializable half of session restoration.

## §3a — AMENDMENT FROM THE LIVE LEG (2026-08-04): §0's "the channel
## already exists" IS NOT TRUE OF EVERY BACKEND

§0 argues for delegation partly on this: "because every kaya text
widget is uncontrolled toward the app, a native undo emits the
ordinary text_changed occurrence — the channel already exists, which
is the decisive difference from the clipboard." The mac arm's first
live leg measured that FALSE under SwiftUI:

    undo took=true resp=_SystemTextFieldFieldEditor mgr=NSCellUndoManager
    text teas->tea canUndo true->false model teas->teas
    +50ms text=tea model=teas

A native undo runs on the field editor's own NSCellUndoManager and
rewrites the editor's storage directly, never touching the commit
path that drives SwiftUI's binding setter. The control shows "tea",
kaya's model says "teas", and they STAY diverged — the undo visibly
worked on screen and no channel carried it.

THE RULE THIS REPLACES THE PREMISE WITH: the premise holds where a
backend owns a RAW control (GTK's GtkEntry, a WinUI TextBox) and
FAILS wherever a declarative layer sits between the widget and the
model. **Every arm must answer "does a native undo reach kaya's model
here?" BY MEASUREMENT, not by inheriting this document's sentence.**
Compose is the one to expect trouble from — same declarative shape,
and §1.4 already disqualified its legacy path for an adjacent reason.

WHERE THE CHANNEL IS ABSENT the arm reports the change itself, in the
three places a user edit would have reached: the node's text (without
it the next render pushes the stale model back and rolls the undo
back on screen), the app (the ordinary emission — the field is
uncontrolled), and the ledger via note_native_undo exactly ONCE, with
the emission bracketed ledger-quiet. That bracket is Q2's suppression
flag, designed before this finding existed and fitting it exactly.

Two smaller findings from the same leg, both fixed, both worth
carrying to the other arms: NSMenu.update() with autoenablesItems =
false validates nothing and never reaches the delegate, so
expect_menu read enablement the item was BORN with (no scene had
caught it — none until this one asserts an enablement that MOVES);
and the typing verb must wait for a text-editing responder, because
kaya's focus is a model fact instantly while AppKit installs the
field editor a render later and a leg is never the active app.

## §3b — STAMPED COPIES JOIN THE LEDGER (2026-08-06, option A as
## ruled): the `texts` run becomes arity-first

§5.4 left one question open and the maintainer answered it: a
collection row's text field is app-facing state like any other, so it
banks episodes like any other, and the payload had to grow a way to
NAME it.

### What the shape was, and why it could not carry a row

The `undone`/`redone` payload reads as four runs. `entries` and
`orders` were arity-first groups — each opens with its own size — and
`texts` was fixed-arity PAIRS of (widget id, text). An instance field's
identity on the text channel is (template node, key path): that is what
`decode_text_changed_tag` produces and the only name an app can
resolve. A pair had nowhere to put the path, so `text_field_of_tag`
answered None for a copy, no episode was ever opened, and a row's
typing was outside the history entirely.

`texts` is now the same shape as its two neighbours:

    I64 size, I64 id, I64 path_len, path_len key values, Str text

with path_len 0 meaning `id` is a live widget id — the identity-tag
vocabulary the spec already restates for `pasted` and `button_clicked`.

### The core half: the map that was already being built

`Scene::run_body` builds a template-node-to-widget map while stamping
and used to discard it; `Stamp` now keeps it. That map is the
translation between a copy's two names, and both directions read it:
`text_field_of_tag` turns an arriving (node, path) into the internal
widget id the ledger keys on, and the payload builder turns that id
back into (node, path) on the way out. `apply_delta` resolves the
identity again when it writes, so the write follows the row rather than
an id that a re-stamp would invalidate.

Nothing else moved, and the three things that did not are worth
recording because they were measured rather than assumed: programmatic
writes to a copy were ALREADY admitted by `absorb_text_writes` (an
internal id is editable), focus is ALREADY reported as the copy's
internal id, and NO BACKEND changed — no backend decodes `undone`, and
the restore is an ordinary SetProp every backend already applies.

### THE HASH WOULD NOT HAVE MOVED, and that was the real defect

`spec::hash()` fingerprints record kinds, names, fields, types, enums
and props. The four runs' layout lived only in a doc comment, so this
change rewrote the wire and left the fingerprint identical — a binding
built against the old shape would have loaded happily and mis-read
every payload, which is precisely the stale-artifact class the hash
exists to refuse. The layout is now `spec::UNDO_DELTA_RUNS`, a declared
string that `hash()` eats, so a run that changes shape moves the hash
by construction. (`SET_PROPERTY_NOTE` describes a variable tail the
same way and is still unhashed — the same trap, one record over.)

### A destroyed row takes its typing history with it

Keying an episode on the copy's internal id means a torn-down copy
would leave a ledger entry naming a widget that no longer exists, so
`teardown` drops those entries from both sides of the window's ledger.
A step that restores text into a destroyed widget is a step that
visibly does nothing — the user presses Cmd+Z and the screen does not
move — which is the shape §2 exists to remove, one level down. The
row's own removal remains a step and still walks back; what it brings
back is a FRESH copy, because an uncontrolled field's text is
widget-owned state and undo restores app state (D4). An app that wants
a row's text to survive its removal binds it to a record field, and the
`entries` run already carries that — which is option B's answer,
surviving as the answer to the narrower question it actually fits.

### What the scene pins (tools/scenes/undo.steps, final block)

A row is added, its field is edited, Edit>Undo takes the edit back and
Edit>Redo brings it forward, and the app's own by-key map of row notes
is read at each step — the app can only put a restored note in the
right row because the payload's path says which. The undo's assertion
is the falsifiable one: an app that ignores the run reads its stale
note back out. The block addresses the row as `entry#last` and edits it
with `set_text`, both for stated reasons — a fixed index would name a
destroyed copy on a backend that does not prune its harness registry,
and nothing can FOCUS a stamped copy, so the native tier is not what
this block asserts. Focus stays on the draft, so the route is the
core's on every lane.

## §4 — the depth slice (spec → core → Rust → mac → scene)

Per the sequencing doctrine, with banking in from the start:
1. SPEC (invariant 7 — the root): `TxOp::UndoGroup { label }`;
   occurrences `undone` / `redone` carrying the label and the
   core-authoritative delta (D5); the spec hash moves; everything
   regenerates in lockstep.
2. CORE: the per-window ledger (groups + episodes), the inverse
   log (keep what Scene::apply already computes), the A1/D7 clear
   plumbed as a core-driven backend command, episode banking off
   the text_changed stream, the A4 focused-CanUndo query, refusal
   (D4/A2) with its negative tests.
3. RUST SURFACE: `tx.undoable("label")`, `Messages::on_undone` /
   `on_redone`; check-tx-liveness/check-abort-style pins extended.
4. SWIFTUI MAC ARM: MenuRole::{Undo,Redo} joining the four role
   filters (gate clause FIRST, red mid-milestone by design); D6
   routing via AppKit's own resolution; D7/A1 clears with the
   after-AppKit-sync trap (§1.2); the reconciliation loop.
5. HARNESS + SCENE: the real-keystroke typing verb (A8) on mac;
   tools/scenes/undo.steps asserting — at minimum — the b, X, a
   interleave, the coarse restore, redo symmetry, refusal, and the
   entry.rs add-scenario that motivated the whole pass.
Then the fan-out: GTK, WinUI, iOS, Compose arms (each with §1's
measured spelling), the remaining seven bindings' `undoable`
spellings, and the matrix.

Surface amendment (2026-08-04, post-fan-out): this plan specified only
the Rust `Messages` spelling, and the fan-out transcribed that shape
into Go/Java/Haskell as app-global `OnUndone(window, fn)` — violating
the ratified window-construct rule (DESIGN.md, Binding conventions)
that no window attribute lives as a loose function outside the
construct. Respelled: on_undone/on_redone are window-construct
attributes in all seven construct bindings, `Messages::on_*(WindowId,
...)` stays as Rust's sanctioned form, the C floor keeps matching on
the record head, and check-sugar-surface now sweeps window handlers
so the next window-scoped occurrence cannot ship the loose form.

The depth slice: spec + core log + Rust surface + the SwiftUI mac arm
+ the scene, then the fan-out, per the sequencing doctrine.

## §5 — THE COMPLETION PASS (2026-08-05): the ledger's open items,
## closed in one slice

The five follow-ups the depth slice and the fan-out carried
(docs/deferred.md, "Undo follow-ups") were taken together rather than
one per milestone. Four were closed here; the fifth was a ratification
the maintainer owned, stated in 5.4 below as a question — and ANSWERED
2026-08-06, option A. §3b above is the answer and the shape it took.

### 5.1 REDO BANKING (built)

`Scene::note_native_undo`'s walk-reached-the-start arm now closes the
episode and pushes it onto the window's redo side. §3's reconciliation
rules carry the entry; what is worth stating here is the SHAPE OF THE
FIX, because it is the shape the design predicted: no wire moved, no
backend changed, and the redo travels the machinery a coarsely-undone
episode already used. Every arm asks the core for the route before
acting, so a `route_redo` that answers `Core` where it answered
`Nothing` changes behaviour on all five at once. That is what "the
routing question is the core's, and the backend contributes only what it
alone can see" (A4/D6) buys, measured rather than argued.

The scene pins it at the ENABLEMENT rather than at the text
(tools/scenes/undo.steps): unbanked, Edit>Redo is inert there and no
assertion about a string says why.

### 5.2 THE TWO GUARDS NO SCENE CAN FAIL, AND THE GATE THAT CAN

The Compose arm broke the ledger-quiet bracket and A1's backend clear in
turn and watched its whole lane stay GREEN (scratchpad/compose-undo-arm.md
§3.3/§3.4). The reason is core-side and therefore true of every arm:
observing either guard needs TWO CONSECUTIVE NATIVE WALKS, and the first
walk spends the frontier episode, so the second Edit>Undo routes CORE by
construction. The scene cannot be reshaped to reach it either — that
would assert frontier granularity, which invariant 6 forbids across five
lanes with five keystroke cadences.

So the wall is static: `tools/check-native-undo.sh` (fast-gate set,
keyed) reads the two-line pairing out of each backend file — a backend
that takes the core's sample marks the emission its walk provokes, that
mark is consumed WHERE THE EDIT IS REPORTED, and a ClearUndo arm calls
the platform's clear. It watches its own four clauses fail on doctored
copies of the real files on every run, and says so out loud.

WHAT IT DOES NOT PIN, so nobody mistakes its scope: a call that is
present but disabled satisfies it. What it pins is that the arm and the
clear are ONE UNIT, which is what a new arm actually breaks.

### 5.3 THE SAMPLE'S THIRD FACT IS NOT A DIRECTION (resolved)

`note_native_undo` takes `can_undo` in both directions on every arm, and
the follow-up asked whether the first platform to distinguish canUndo
from canRedo would demand a redo twin. All five distinguish them — and
all five already consume that distinction in `route_redo`, which is
where it belongs. The sample's flag has exactly ONE consumer: the
exhausted-backward-walk fallback. A `canRedo` reported there answers
false at the end of a forward walk and sends the core backwards, which
is why three arms independently wrote the same comment at their own call
sites. The forward analogue — a redo exhausted short of the after-image
— is unreachable for A1's reason, and if a platform is ever measured
violating it, THAT is the arm that needs a twin.

### ~~5.4 OPEN, FOR THE MAINTAINER: stamped copies and the `texts` run~~

ANSWERED 2026-08-06 — **option A**: `texts` became arity-first, the hash
moved, and stamped copies joined the ledger. §3b above records the
shape, the core half and what the scene pins; no carve-out was needed,
because option A gives every binding the same payload. What follows is
the question as it was put.

The one item left as a question. A collection row's text field is not
banked, because `text_field_of_tag` cannot name it: an instance field's
identity on that channel is `(template node, key path)`, and the
`undone`/`redone` payload's `texts` run is fixed-arity PAIRS of
`(I64 widget id, Str)` — while `entries` and `orders` are arity-first
GROUPS precisely so they can carry a path. So instance fields are not
addressable on the wire as it stands.

The core half is cheap (the stamping pass already builds the
template-node-to-copy map and discards it), which is exactly what makes
the question sharp: building only that restores the widget while handing
the app a pair naming an identifier it has never seen, which breaks D5's
"this record is the ONLY thing the app hears" silently. The options and
their bills — A: make `texts` arity-first (hash moves, no backend cost);
B: ratify native-tier-only for stamped fields, with the reactive
doctrine's own answer (bind the row's text to a record field and the
`entries` run already carries it); C: carry the internal id, named only
so it is not rediscovered — are written out in
scratchpad/undo-completion.md §ITEM 2. Whichever way it goes, invariant
1 wants the carve-out stated uniformly in DESIGN.md's Binding
conventions.
