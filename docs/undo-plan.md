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

The delegated tier is currently unobservable: no harness verb can
press a chord at a native widget (GTK panics on an unowned chord),
and set_text is a programmatic write that clears the very history a
native-tier scene must assert. The milestone adds a REAL-KEYSTROKE
typing verb before the scene is written; a tier kaya cannot drive in
a scene cannot be held to invariant 1's uniform semantics, and
saying so now is cheaper than discovering it at the fan-out.

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

The depth slice: spec + core log + Rust surface + the SwiftUI mac arm
+ the scene, then the fan-out, per the sequencing doctrine.
