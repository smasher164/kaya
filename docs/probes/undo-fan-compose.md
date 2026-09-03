# undo fan-out — the COMPOSE arm

Working record, written progressively. Status markers: PLANNED / DONE /
BLOCKED / MEASURED. Nothing committed.

I own `android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt` (+ the
entry/textarea migration) and the run-emulator leg wiring. NOTHING else.

---

## 0. Context read (DONE)

- `CLAUDE.md` — invariants; never commit; the fast-gate roster.
- `docs/undo-plan.md` IN FULL — §0 D1-D8, §1 the measured platform
  charges (§1.4 = Compose), §2 A1-A8, §3 episode banking, §3a THE
  AMENDMENT (measure, never inherit "native undo emits text_changed").
- `scratchpad/undo-depth-2-arm.md (gone)` — the mac REFERENCE arm.
- `scratchpad/undo-integrate.md (gone)` — the vtable, Q1's widened emit, Q2's
  one-reporter + ledger-quiet bracket, the three findings.
- `scratchpad/undo-probe-compose.md (gone)` — P3-compose, the measurements this
  arm is built on.
- `tools/scenes/undo.steps` (byte-frozen) and
  `crates/kaya/src/harness.rs`'s type-verb contract (six points).

Tree at start: `git status --short` CLEAN, HEAD `3044d73`.

Hardware found (NOT started by me, NOT stopped by me): four headless
emulators — pids 1856/1859/1862 (`-avd kaya`, :5554/:5556/:5558, up
**8d 22h**) and 63625 (`-avd kaya-tablet`, :5560, up 8d 07h). All four
`adb devices` = `device`. Left exactly as found.

---

## 1. §3a — THE MEASUREMENT, TAKEN FIRST (DONE 2026-08-04)

**THE QUESTION §3a FORBIDS INHERITING: does a native undo reach kaya's
model on Compose?**

**ANSWER: YES. Compose is the OPPOSITE of SwiftUI here, and it is the
opposite for THREE affordances, not one.** The prediction in §3a ("the
one to expect trouble from — same declarative shape") is measured WRONG
for this backend, and the reason is structural rather than lucky:
`TextFieldState.text` is snapshot state, `undoState.undo()` mutates that
same state, and the idiomatic observation (`snapshotFlow { state.text }`)
is a snapshot observer — there is no separate "commit path" for an undo
to bypass, because the undo IS a write to the observed value.

Instrument: the TRACKED probe app `tools/android/undoprobe` (unmodified;
its `tfsObserved` counter is a `snapshotFlow { state.text }` collector,
which is exactly the channel this arm's emission rides), driven by
`scratchpad/undo3a.sh (gone)` on **emulator-5558**. Raw transcript:
`scratchpad/undo3a.txt (gone)`.

| # | act | `tfs` | `canUndo/canRedo` | **`tfsObserved`** | `tfsLast` |
|---|---|---|---|---|---|
| Q-a | user types `abc` | `abc` | true/false | 4 | `abc` |
| Q-a | **`undoState.undo()`** (kaya ROUTES) | `` | **false/true** | **5** | `` |
| Q-a | **`undoState.redo()`** | `abc` | true/false | **6** | `abc` |
| Q-b | user types `abc` | `abc` | true/false | 4 | `abc` |
| Q-b | **hardware Ctrl+Z** at the field | `` | false/true | **5** | `` |
| Q-c | user types `ab` | `ab` | true/false | 3 | `ab` |
| Q-c | **programmatic `setTextAndPlaceCursorAtEnd("PROG")`** | `PROG` | **false/false** | **4** | `PROG` |

Three findings, each with its consequence for the code below:

1. **Q-a — a kaya-ROUTED undo/redo moves the observation.** So this arm
   does NOT do what the mac arm had to do (write the node's text itself
   and emit by hand). It rides the ordinary channel, and Q2's bracket is
   needed for exactly the reason Q2 exists: the ordinary emission WILL
   arrive, so it must be marked LEDGER-QUIET or the same change is banked
   twice (once by `note_native_undo`, once by the emit).
2. **Q-b — even the UNINTERCEPTED affordance moves it.** A hardware
   Ctrl+Z the field consumes (§1.4/E: the field eats the chord and it
   never reaches the Activity route) still reaches kaya's model. A6's
   protocol gap is therefore NARROWER on Android than on macOS: the app
   sees the text move; what it cannot tell is that the move was an undo.
3. **Q-c — the observation ALSO fires for kaya's OWN writes** (3 → 4 on
   a programmatic write), which the legacy `onValueChange` path never
   did. That is the echo-doctrine cost §1.4 predicted, and it is the one
   new failure class the migration introduces. The suppression is a
   COMPARISON, not a flag: the apply arm writes `node.text` and the state
   together, and the collector emits only when the observed text DIFFERS
   from `node.text`. A flag would have to survive an unknown number of
   frames; the comparison is exact and self-clearing.

Also re-confirmed in passing (§1.4's B-cells, unchanged): a programmatic
write CLEARS the field's history by itself (`canUndo` true → **false**
at Q-c), which is D7 for free on this backend.

## 2. THE SECOND MEASUREMENT: type-verb contract point 3 (DONE)

Point 3 — "before the first keystroke the insertion point goes to the
END of the widget's current text with nothing selected" — exists because
macOS SELECTS A FIELD'S WHOLE CONTENTS when it becomes first responder.
Asked of Compose before writing the verb (`scratchpad/undocaret.sh (gone)`,
transcript `scratchpad/undocaret.txt (gone)`, emulator-5558):

| # | script | result |
|---|---|---|
| M1-a | focus, type `tea`, focus AWAY, focus BACK, type `s` | **`teas`** |
| M1-b | programmatic `setTextAndPlaceCursorAtEnd("tea")`, focus, type `s` | **`teas`** |

**Point 3 holds on Compose with NO caret move, and an explicit one would
be a defect.** The only way to place the cursor from app code on this
path is `TextFieldState.edit {}`, which commits and therefore CLEARS the
undo history — the typing verb would destroy the very stack it exists to
build. So the verb dispatches keys and nothing else, and the reason is
recorded at the call site rather than left as an omission.

## 3. THE THIRD MEASUREMENT: the SHIPPED interpreter, instrumented (DONE)

Fixtures prove fixtures right. Everything above was measured on the
probe app; this was measured on `KayaCompose.kt` itself, built and
build-id VERIFIED the way `tools/android/run-emulator.py` builds it, on
**emulator-5554**. Only the observation was temporary (one log line at
the emission site, two throwaway harness verbs); every code path under
test is the shipped one. Instrument: `scratchpad/undoprobe-leg.sh (gone)`,
transcript `scratchpad/undoprobe-leg.txt (gone)`.

```
KAYA_UNDO_PROBE: id=2 widget=[] model=[] canUndo=false canRedo=false     <- 1
KAYA_UNDO_PROBE: emit id=2 text=[t]   quiet=false                        <- 2
KAYA_UNDO_PROBE: emit id=2 text=[te]  quiet=false
KAYA_UNDO_PROBE: emit id=2 text=[tea] quiet=false
KAYA_UNDO_PROBE: id=2 widget=[tea] model=[tea] canUndo=true canRedo=false
KAYA_UNDO_PROBE: id=2 widget=[tea] model=[tea] canUndo=true canRedo=false <- 3
KAYA_UNDO_PROBE: id=2 widget=[teapot] model=[teapot] canUndo=false        <- 4
KAYA_UNDO_PROBE: emit id=2 text=[teapots] quiet=false                     <- 5
KAYA_UNDO_PROBE: id=2 widget=[teapots] model=[teapots] canUndo=true
KAYA_UNDO_PROBE: walked undo -> widget=[teapot] canUndo=false             <- 6
KAYA_UNDO_PROBE: emit id=2 text=[teapot] quiet=TRUE                       <- 6
KAYA_UNDO_PROBE: id=2 widget=[teapot] model=[teapot] canUndo=false canRedo=true
KAYA_SELFTEST: OK (no todos, entry#0 focused, tea, teapots, teapot)
```

1. **D7 lives.** After kaya's own `set_text` + the scene's Clear, the
   focused field's `canUndo` is **false**. A user cannot Ctrl+Z back an
   app write on this backend any more.
2. **The typing verb is on the platform's real input path.** Three
   emissions for `type "tea"`, ONE PER CHARACTER, and `canUndo` goes
   **true** — the field's own undo stack filled exactly as a user's
   typing fills it. A `set_text` stand-in would have left it false, which
   is the whole reason harness.rs's contract point 1 refuses one.
3. **A3 holds.** `set_text entry#0 "tea"` when the field already holds
   `tea` leaves `canUndo` **true** — the no-op rewrite did not cost the
   user their typing history. (Measured B6 says the platform WOULD have
   cleared it; the guard is in front of the write, because here the write
   IS the clear.)
4. **D7 fires when the text moves.** `set_text entry#0 "teapot"` →
   `canUndo` **false**.
5. **Point 3, on the shipped verb:** typing `s` after a programmatic
   write gives `teapots`, not `steapot`.
6. **§3a + Q2 together, which is the finding this arm turns on:**
   `undoState.undo()` moved the widget `teapots` → `teapot`, the shipped
   observer saw it, and the emission it produced carries **`quiet=true`**.
   The channel is present (unlike SwiftUI) AND the change is banked once.

And the ECHO GUARD is visible as an ABSENCE: there is no `emit` line for
any of the three `set_text` writes. kaya's own writes do not come back to
the app as user edits, on a channel that measurably reports them.

---

## 4. What is written (all in KayaCompose.kt unless named otherwise)

### 4.1 The mirror constants — DONE, and check-verbs IS NOW GREEN

- `SPEC_HASH: ULong = 0x44b8c0a4228f2b33uL` (was `0x408bcf69e0ad2bfd`).
- `APPLY_CLEAR_UNDO = 27`, beside the clipboard pair.

`tools/check-verbs.py` = **OK (48 verbs, 77 constants + the CLIP_*
mirrors + spec hash against 2 interpreters)**. These two lines were the
milestone's LAST check-verbs hold-open; the gate is green for the first
time since the spec moved.

### 4.2 The entry/textarea migration — DONE

One composable, `KayaTextField(node, a11y, singleLine)`, serves both
kinds (they differed in two arguments, and a second copy is a second
place to get the echo guard wrong):
`BasicTextField(state = node.textState)` with
`TextFieldDefaults.DecorationBox`, `TextFieldLineLimits.SingleLine` /
`MultiLine(minHeightInLines = 3)`.

`KayaNode.textState` is a `TextFieldState` created `by lazy` — two of
fourteen kinds have text to edit, and a state object per label is a
state object for nothing.

TWO OPT-INS, EACH WATCHED FAILING (not asserted):

| perturbation | applied | check-compose |
|---|---|---|
| remove `@OptIn(ExperimentalMaterial3Api)` from `KayaTextField` | 1 | **FAIL**: `4744:31 This material API is experimental` — the `TextFieldDefaults.DecorationBox` call, and nothing else |
| remove `@OptIn(ExperimentalFoundationApi)` from `KayaUndoState` | 1 | **FAIL**: 10 errors, ALL inside `KayaUndoState`'s five members |

The second perturbation is also the proof that the funnel holds: every
experimental foundation touch in this 4900-line file is inside one
15-line object, so the opt-in sits at the smallest scope that covers it
instead of file-wide where a future experimental API could ride in
unnoticed.

### 4.3 D7 + A3, and the one site that needs an explicit clear — DONE

`kayaWriteText(node, next)` is the single write path. Called from the
APPLY ARMS rather than the authoring sites — `PROP_TEXT` inside
`applySetProp`, `COMMAND_CLEAR` inside `applyCommand` — so an inverse the
CORE writes (§3's coarse episode restore) travels the same clear a
forward write does with nothing special-casing it. Also from the harness
`set_text` verb and the paste role's insertion.

- **D7 is the migration itself**: `setTextAndPlaceCursorAtEnd` →
  `commitEdit` → `TextUndoManager.clearHistory()`. The explicit
  `clearHistory()` beside it is a measured no-op kept as THE RULE'S
  SPELLING, the same call the Windows arm makes for the same reason.
- **A3 sits in front of the WRITE, not in front of the clear**, and that
  is this platform's own shape: here the write IS the clear, so a guard
  behind it would be too late. Measured live at §3 point 3.
- Labels and buttons return after the model assignment: `PROP_TEXT`
  reaches them too and they have no field to write into.

`kayaClearUndoForGroup()` (A1) is the ONE site that must clear WITHOUT
touching the text, and `undoState.clearHistory()` is measured to empty
both stacks and leave the content alone. Reached from the new
`APPLY_CLEAR_UNDO` arm, which decodes `{ u64 window }` and drops it:
Android is one Activity and one surface.

### 4.4 The typing verb — DONE, and measured on the shipped source

`kayaTypeAtFocus` + `kayaSettleTypedText`, written to harness.rs's six
numbered points; the per-point reasoning is at the call site. The
mechanism is `Activity.dispatchKeyEvent` with events built from the
platform's own `KeyCharacterMap`, which §1.4/H measured reaching the
focused field's key handler and driving its real undo stack — no adb, no
permission, no instrumentation. Point 4 waits for the MODEL to catch up
with the WIDGET, which is one turn past the emission.

### 4.5 The Undo/Redo role — DONE (both halves of the filter)

- `kayaRoleEnabled` gains `"undo"` / `"redo"`, answered by the ONE
  routing function so enablement and activation cannot drift (A4).
- `kayaPerformUndoRole` is a separate function from
  `kayaPerformClipboardRole` — an undo is not a clipboard command — and
  `kayaActivateMenuItem` asks it first. `tools/check-roles.py` reads the
  UNION of `kayaPerform*Role`, which anticipates exactly this split.
- The NATIVE tier is fully live: `kayaNativeUndo(redo)` walks
  `undoState.undo()/redo()`, samples the widget at the one moment the
  sample is true, writes Q2's echo bracket, and reports the three facts.
  The third fact is `canUndo` IN BOTH DIRECTIONS, as the mac arm sends it.

**`tools/check-roles.py` now reports ZERO KayaCompose.kt findings.**

There is no hard-coded role SET to update in this file — check-roles'
third clause is written about the sets that exist, and the two
interpreters deliberately have none (their enablement refresh is
role-agnostic and delegates to `kayaRoleEnabled`, which
`kayaMenuEffectivelyEnabled` is the single funnel for: bar actions,
overflow rows, drill-ins, context rows, shortcuts, `expect_menu` and the
activation gate all read that one helper). Checked by grep, not assumed.

---

## 5. THE ONE THING THIS ARM COULD NOT DO — the core tier, BLOCKED

**The core's ledger cannot be called from this interpreter, and no edit
inside KayaCompose.kt can change that.** This is the mac arm's step-4
wall, one phase later, for the same structural reason.

`kaya_undo_route`, `kaya_redo_route`, `kaya_undo`, `kaya_redo` and
`kaya_note_native_undo` all EXIST as C symbols
(`crates/kaya/src/capi.rs`), and the SwiftUI interpreter reaches them
through the `KayaHostApi` vtable. This interpreter reaches the core ONLY
through the JNI natives registered in `crates/kaya/src/android.rs` and
declared in `android/kaya/src/main/kotlin/dev/kaya/KayaPresent.kt` —
there is no generic bridge; every core query on this host (`specHash`,
`stalledMs`, `nextCommands`, `blobData`) is a registered native. Neither
file carries an undo entry, and BOTH ARE OUTSIDE THIS CHARGE ("you own
KayaCompose.kt and the run-emulator leg wiring — NOTHING else", with
eleven siblings writing the same tree concurrently).

I did not take them. An edit to `android.rs` is an edit to the Rust core
that every one of those eleven lanes is compiling against.

### How the arm is written around it

Five named functions, each one line from done, each carrying its
replacement in a comment directly above it:

| function | the call it wants |
|---|---|
| `kayaUndoRoute()` | `KayaPresent.undoRoute(0, focused, canUndo)` |
| `kayaRedoRoute()` | `KayaPresent.redoRoute(0, focused, canRedo)` |
| `kayaNoteNativeUndo(node, text, canUndo)` | `KayaPresent.noteNativeUndo(0, node.id, text, canUndo)` |
| `kayaCoreUndo()` | `KayaPresent.undo(0)` |
| `kayaCoreRedo()` | `KayaPresent.redo(0)` |

They REFUSE rather than answer quietly, because a route that guessed or a
core undo that no-oped would be indistinguishable from an empty ledger —
the exact silent class this milestone exists to close. The refusal is
`depthStub("undo")`, which is the one spelling `tools/check-stubs.py` and
`tools/check-steps.py` both READ, preceded by a `KAYA_UNDO_TRACE` line
naming the entry, the facts the backend had computed, and the two files
to add the JNI to.

Consequence, stated plainly: **a scene that declares an Edit>Undo role
item dies on this backend at the first enablement read** — which is what
a depth stub means, and is why the legs are held off rather than wired.

The complete two-file change is written out in
`scratchpad/undo-compose-jni-handoff.md (gone)`.

### And that is why the undo LEGS ARE NOT WIRED

`tools/check-stubs.py` states one rule from both sides: a scene's legs
are wired on a runner IF AND ONLY IF that runner's backend has the
feature. With `depthStub("undo")` in KayaCompose.kt, wiring the legs is a
gate failure — and I WATCHED IT FIRE rather than assume it:

| state | check-stubs |
|---|---|
| stub present, no undo leg in run-emulator.py | **OK** |
| stub present, `run_apk undo-compose …` inserted (1 substitution, printed) | **FAIL** — `tools/android/run-emulator.py wires 'undo' legs but android/…/KayaCompose.kt still stubs it (depth_stub("undo"))` |

So the charge's "legs green ×3" is not reachable from inside this
charge's file set, and the repo's own guard says so in the message it
prints. What I ran instead is in §6.

---

## 6. Verification

### 6.1 The lane, THREE CONSECUTIVE RUNS

`tools/android/run-emulator.py compose`, on the final source, three times
in a row:

```
run 1 RC=0 pass=26 fail=0
run 2 RC=0 pass=26 fail=0
run 3 RC=0 pass=26 fail=0
```

All 26 legs, every run — including every leg the migration could have
broken: `entry`, `textarea`, `todos`, `clipboard` (the paste split, the
platform-insertion branch, `ax "field/pasted by hand"`), `a11y`,
`commands`, `menus`, `gallery`, `reorder`, `feed`, `grid`. The transcript
`clipboard-compose: … entry#0 focused, pasted pasted by hand, , entry#1
focused, pasted by hand, ,` is the migration's write path, its echo guard
and its a11y surface in one line.

THIS IS NOT THE UNDO LEG, and it is not offered as one. The undo leg is
held off by check-stubs (§5); what these runs establish is that the
migration and the D7 plumbing are regression-free on everything the lane
does carry. The undo-specific claims were measured directly instead
(§1-§3).

### 6.2 Gates

| gate | rc | verdict |
|---|---|---|
| `tools/check-verbs.py` | **0** | **OK (48 verbs, 77 constants + the CLIP_* mirrors + spec hash against 2 interpreters)** — the milestone's LAST hold-open, now green |
| `tools/check-roles.py` | 1 | **ZERO KayaCompose findings.** Reading at 18:29: 5 findings, all `crates/kaya/src/gtk.rs` (undo/redo × enablement/perform, plus its hard-coded role set). Reading at 18:47: the gate's own SELF-TEST now fails because a sibling changed gtk.rs's `matches!` filter and the perturbation anchor moved — a live cross-agent artifact, still zero Compose |
| `tools/check-stubs.py` | 0 | OK — and its refusal WATCHED FIRING (§5) |
| `tools/check-steps.py` | 1 | **ZERO android findings.** One finding, `tools/linux/run-suites.sh` — the GTK sibling's half of the same IFF |
| `tools/check-compose.py` | 0 | the Kotlin COMPILES — and proven non-vacuous twice (§4.2) |
| `tools/check-detekt.py` | 0 | no dead Kotlin (the reason `kayaRouteCode` was deleted rather than parked) |
| `tools/check-targets.py` | 0 | native / ios / android / windows ALL OK, both feature configs — covers the guest arm added to `milestone2_android.rs` |
| `tools/check-universal-props.py` | 0 | the a11y modifier still reaches both text kinds through the new composable |
| `tools/check-shell.py` | 0 | — |
| `tools/check-keyed.py` | 0 | OK (18 gates keyed) |

### 6.3 Negative tests, each WATCHED FAILING with its substitution count

| perturbation | applied | result |
|---|---|---|
| drop the M3 opt-in from `KayaTextField` | 1 | check-compose FAIL at the `DecorationBox` call |
| drop the foundation opt-in from `KayaUndoState` | 1 | check-compose FAIL, 10 errors, all inside that object |
| wire `undo-compose` into run-emulator.py with the stub present | 1 | check-stubs FAIL naming both files |

Each perturbation asserted its own application before the gate ran and
refused to proceed on 0 substitutions; each file was restored from a
byte-compared copy afterwards (`diff -q` → RESTORED OK).

---

## 7. The sweep (invariant 2): who this change touches

This is a BACKEND change, not a binding-surface change — no guest
language's API moved, and `kaya_emit_text_changed`'s widened signature
was already landed and consumed by this file before I started. Per
backend:

| backend | verdict |
|---|---|
| Compose | **DO** — this arm |
| SwiftUI (mac) | N/A — landed; measured to need the OPPOSITE treatment (§1) |
| SwiftUI (iOS), GTK, WinUI | N/A — sibling arms, disjoint files, untouched here |

And within the Compose arm, the sweep that matters is the WRITE SITES.
§1.4 named three (`PROP_TEXT`, `COMMAND_CLEAR`, the paste role's append);
there is a **fourth the probe did not name — the harness's `set_text`
verb** — and all four now go through `kayaWriteText`. Verified
mechanically: `node.text` is assigned in exactly two places in the whole
file, `kayaWriteText` and the KayaTextField observer.




---

## 8. Deviations, and things a reader should not be misled by

1. **THE ONE OPEN ITEM: the core tier is not implemented** (§5). Five
   named functions, five one-line bodies, two files outside this charge.
   `scratchpad/undo-compose-jni-handoff.md (gone)` is the whole change.
2. **The undo legs are NOT wired into run-emulator.py**, and that is
   check-stubs' refusal rather than an omission (§5). The charge asked
   for them green ×3; §6.1 is what was run in their place, and it is not
   the same claim.
3. **§3a's PREDICTION IS MEASURED WRONG for this backend, and the plan
   should say so.** §3a names Compose as "the one to expect trouble from
   — same declarative shape". Measured (§1): the channel is present on
   all three affordances. The rule §3a states is still right; its guess
   about which side of the rule Compose falls on is not, and the reason
   is worth writing down because it generalizes — the premise fails when
   an undo bypasses the path that drives the model (SwiftUI's binding
   setter) and holds when the undo IS a write to the observed state
   (Compose's snapshot). Suggested amendment: replace "Compose is the one
   to expect trouble from" with the measurement and the criterion.
4. **A6's protocol gap is NARROWER on Android than the plan assumes.**
   Measured Q-b: an unintercepted hardware Ctrl+Z the field consumes
   still reaches kaya's model. The app sees the text move; what it cannot
   tell is that the move was an undo. (And on a phone there is no
   affordance at all — no hardware keyboard, and the API 35 text toolbar
   offers Copy/Paste/Cut with no Undo — so kaya's own menu item is the
   ONLY undo affordance that exists.)
5. **The paste role now clears the focused field's typing history**, and
   §1.4 demanded this judgement be made out loud. On every other platform
   kaya's paste is a user act that lands IN the native stack; on
   TextFieldState there is measurably no public way to make an app write
   undoable, so it clears like any other write. The cost is GRANULARITY,
   not history — the episode was banked off the observation stream before
   the clear — which is A1's trade arriving one site early.
6. **`expect entry#N` / `expect textarea#N` now read the WIDGET**
   (`textState.text`), not the model mirror. That is read_text's actual
   contract ("what the user sees in the field, read from the toolkit")
   and it only became possible with the migration; a model read could no
   longer see a native undo that moved the widget and not yet the mirror.
   Behavior change, deliberate, and every text leg passes on it.
7. **One file outside KayaCompose.kt was touched:
   `guests/rust/milestone2_android.rs`, +10 lines** — `mod undo;` and
   `Ok("undo") => undo::app(ctx)`. I read this as the other half of "run-
   emulator leg wiring": that file's own comment records that a leg wired
   without its arm here "cost a debugging round", because the runner then
   silently runs the milestone-2 scene against the undo script. It is
   additive and unreachable until a leg asks for `undo`, and
   check-targets confirms it compiles for android. Trivially revertible
   if the parent scopes it elsewhere.
8. **`kayaRouteCode` was deleted, not parked.** It had no caller while
   the seam is open, and this file's own `depthStub` doc says why dead
   code kept "for later" is a cost. The 0/1/2 mapping it carried is in
   the seam comment and in the handoff.
9. **The A1 arm (`APPLY_CLEAR_UNDO`) is not exercised end to end**,
   because nothing can open an undo group on this backend until the seam
   closes. The decode is one u64 at offset 0, matching the spec row and
   the mac arm; the clear it calls is `undoState.clearHistory()`, which
   §1.4/B5 measured emptying both stacks without touching the text.
10. **The pins the plan names are still wrong.** undo-plan.md:201 says
    material3 1.3.2 / foundation 1.7.8; kaya pins NEITHER — the BOM
    (`compose-bom:2024.10.01`) decides, and it decides **1.3.1 / 1.7.5**.
    The probe recorded this on 2026-08-04 and the plan still carries the
    old numbers. Nothing here turns on it (everything used is present at
    1.7.5), but the "pin bump" that sentence contemplates would be a BOM
    bump, not a material3 line edit.
11. **Not measured, deliberately: whether a selection-only
    `TextFieldState.edit { placeCursorAtEnd() }` clears history.** The
    typing verb does not need it (point 3 holds without a caret move,
    §2), and the measurement would only be actionable if it came back
    "does not clear" — which is the answer the bytecode says is
    impossible, since `edit {}` always commits. Named rather than
    guessed at.
12. **Not measured: IME/soft-keyboard typing** through the new field, and
    **not measured: a real hardware keyboard** (the AVD reports
    `hw.keyboard=no`; every chord and keystroke was synthesized, entering
    at the input-manager level). Both inherited from the probe's own
    named holes.

---

## 9. Processes and artifacts

- **Started and stopped by me:** the probe app `dev.kaya.undoprobe`
  (three campaigns on emulator-5558), one instrumented `milestone2` leg
  on emulator-5554, and four `run-emulator.py compose` suites (26 legs
  each; every leg terminates itself under KAYA_SELFTEST). PROVEN
  STOPPED: `pgrep -fl "undoprobe|milestone2|run-emulator|screenrecord|
  logcat"` returns nothing, and all four devices report
  `undoprobe packages: 0  processes: 0`. The probe app was UNINSTALLED
  from emulator-5558 and the device returned to its home screen.
- **Found running, NOT mine, NOT stopped, left exactly as found:** four
  headless emulators — pids 1856/1859/1862 (`-avd kaya`, :5554/:5556/
  :5558) at **8d 23h**, and 63625 (`-avd kaya-tablet`, :5560) at 8d 07h.
  Same pids before and after, `adb devices` = 4 × `device`. Three of them
  have now been up nine days; that is a standing cost on every timing
  measured in this repo, and it is the second report in a row to say so.
- **Deleted:** `tools/android/undoprobe/{.gradle,app/build}` — **57.7 MB**
  of gradle debris my probe runs created inside a TRACKED directory
  (that path is not in .gitignore, unlike clipprobe's and cliphelper's,
  so it would have shown up as untracked noise in everyone's
  `git status`). `tools/android/undoprobe` is back to **52 KB**, sources
  only, byte-identical to HEAD.
- **Temporary instrumentation, all removed and verified gone**: one log
  line at the emission site and two throwaway harness verbs
  (`undo_probe`, `native_undo_probe`). Restored from a byte-compared copy
  (`diff -q` → RESTORED OK); `grep` for
  `KAYA_UNDO_PROBE|KayaUndoStateProbe|native_undo_probe|
  kayaNativeUndoEchoProbe` over the tree finds only the pre-existing
  `tools/win/undoprobe/` names, which are a sibling's. THE THREE LANE
  RUNS AND EVERY GATE ABOVE WERE TAKEN AFTER THE REMOVAL.
- **Rebuilt in place, not created** — the lane's own artifacts,
  rebuilt every run, not mine to delete:
  ```
  android/milestone2/build
  android/kaya/build
  target/aarch64-linux-android
  ```
- Kept in the scratchpad, because they are re-runnable instruments:
  `undo3a.sh` (§3a), `undocaret.sh` (contract point 3),
  `undoprobe-leg.sh` (the shipped-source measurement), their three
  transcripts, `undo-compose-jni-handoff.md`, and this file. ~60 KB.
- Nothing else launched: no emulator started or stopped, no simulator, no
  VM, no daemon, no scheduled task. One gradle daemon was reused, none
  left behind beyond it.

---

## 10. Files

- `/Users/akhilindurti/Projects/kaya/android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt`
  — the arm (+749 / −68).
- `/Users/akhilindurti/Projects/kaya/guests/rust/milestone2_android.rs`
  — the undo scene's arm in the one-APK selector (+10), see deviation 7.
- `/private/tmp/claude-501/-Users-akhilindurti-Projects-kaya/24aa5ebf-e439-4206-9ba0-de67540e4b06/scratchpad/undo-compose-jni-handoff.md (gone)`
  — the five JNI entries, the five one-line bodies, and the two leg
  lines. The whole remaining change.
