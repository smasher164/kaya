# UNDO COMPLETION arm — progressive report

Started 2026-08-05. HEAD at start: d41247a.
Charge: close all five open undo ledger items in one pass.
Carve-out discipline: I never decide an invariant exception; where the
honest resolution is ratification, I write the proposal and leave the
tree unchanged on that item.

## 0. Reading pass

- docs/undo-plan.md §0-§4 (D1-D8, A1-A8, §3 episode banking, §3a).
- docs/probes/compose-undo-arm.md §3.1 routing measurements, §3.3 F1,
  §3.4 F2.
- scratchpad/fresh-key-depth.md (gone) §1, §3, §4 (the reshaped scene and its
  byte-frozen string contract).
- docs/deferred.md "Undo follow-ups" (lines 896-1020).

(sections below are filled as work lands)

## ITEM 1 — REDO BANKING (BUILT, core-side only)

### The change
`crates/kaya/src/scene.rs`, `note_native_undo`: the walk that reaches the
episode's before-image now CLOSES the episode and pushes it onto the
window's redo side instead of dropping it:

```rust
if ep.current == ep.before {
    ep.open = false;
    let spent = ledger.done.pop().expect("just matched the frontier");
    ledger.redo.push(spent);
    return None;
}
```

The doc comment above the function carries the reasoning (the frontier
moves to the GROUP underneath, so `route_redo` can no longer offer the
native tier — a dropped episode would be unreachable in BOTH directions).

### "no new wire, no backend edits" — VERIFIED, not assumed
- The redo of a banked episode travels `Scene::redo`'s existing
  `LedgerEntry::Episode` arm (scene.rs:2535+): it writes the after-image
  through `apply_delta`'s texts run and emits the ordinary `Redone`. No
  spec record moved, no vtable row added, `cargo test` needed no
  regeneration.
- Every backend asks the CORE for the route before acting:
  `kayaRedoRoute()` → `KayaHost.api.redo_route(...)` →
  `.core` → `kayaCoreRedo` (swift/KayaSwiftUI.swift:6125, :6832-6838,
  :7001), Compose's `kayaRedoRoute` (KayaCompose.kt:4140+), GTK
  (gtk.rs:2605+), WinUI (winui/mod.rs:3877). A route that changes from
  `Nothing` to `Core` therefore changes behaviour on all five arms with
  no backend edit — that is what the mac leg then measures.

### Unit tests (beside the ledger tests, scene.rs)
- `a_native_walk_to_the_start_banks_the_episode_forward` — walk to the
  run's start, then: depth 2 (group + older typing), `route_redo` ==
  `Core` for BOTH values of the platform's leftover `canRedo`, the redo
  restores the after-image under the empty label, and the step goes back
  again.
- `a_new_step_after_a_banked_walk_spends_the_forward_history` — a group
  commit after the bank, and typing after the bank, each spend it. This
  is the test that decides how the SCENE can be written (below).

### The unit-level flip proof
Perturbation = the pre-change body (`ledger.done.pop(); return None;`),
1/1 substitutions asserted:

| state | the two tests |
|---|---|
| banking in | PASS (268 total, 0 failed) |
| banking reverted | **FAILED** — `left: Nothing / right: Core` at the `route_redo` assertion in both |
| restored (sha256 c3750b9e…) | PASS, 268 |

TRAP FOUND WHILE DOING IT, worth carrying: restoring a file with
`shutil.copy2` preserves the SAVED copy's mtime, which puts the restored
source BEHIND the artifact cargo built from the perturbed one — the next
`cargo test` is a no-op and the restored tree still reports the
perturbation's failures. Measured here: two tests kept failing after a
byte-identical restore. `perturb.py` now uses `copyfile` + `os.utime`.

## ITEM 4 — THE C FLOOR IN check-steps (BUILT)

`tools/check-steps.py`, new `sweep_c_floor` beside `sweep_guests`. NOT a
row in the existing sweep, and the comment says why: that sweep demands a
MAC leg for every scene in mac's SCENES whose guest file exists, and the
C floor deliberately carries a different scene set per lane (it is the
explicit-tier demonstration, not a breadth guest) — `("c",
"guests/c/{s}.c")` there would demand ten mac legs nobody intended.

Three clauses, from the two declarations the floor actually has
(guests/c/Makefile's SCENES, and each runner's C build line):
1. every C guest the Makefile builds is RUN by some lane — keyed on the
   binary path `c-guests/<scene>`, which is the one signature all three
   leg spellings share (mac's `run undo-c-swiftui … target/c-guests/undo`,
   linux's `run "$proto" todos-c … /tmp/c-guests/todos`, and the a11y
   legs that go through a helper with no leg name at all);
2. a runner that NAMES the C scenes it builds (`make -C guests/c
   SCENES=undo`) runs each one — mac's own declaration of its C floor;
3. a leg pointing at a binary the Makefile never builds is refused.

### Watched failing, each restored by sha256
| # | perturbation | subs | rc | message |
|---|---|---|---|---|
| N-C1 | `run undo-c-swiftui …` deleted from validate-mac.py | 1 | **1** | clause 1 (`guests/c/undo.c … no lane runs it`) AND clause 2 (`builds the C "undo" guest (SCENES=undo) but runs no leg`) |
| N-C2 | `run "$proto" todos-c …` deleted from linux/run-suites.sh | 1 | **1** | clause 1 for todos |
| N-C3 | linux leg re-pointed at `c-guests/todoss` | 1 | **1** | clause 3, plus clause 1 for the orphaned todos |
| — | restored | — | **0** | `check-steps: OK` |

## ITEM 1 — THE SCENE, AND THE MAC PROOF

`tools/scenes/undo.steps`, inserted right after the `b` step (the one
measured NATIVE on Compose and mac):

```
expect_menu "Edit>Redo" enabled
menu_activate "Edit>Redo"
expect entry#0 "teas"
expect label#1 "redid typing, 1 total"
menu_activate "Edit>Undo"
expect entry#0 "tea"
expect label#1 "undid typing, 1 total"
```

Three things about its shape, all reasoned in the file itself:
- THE ENABLEMENT IS READ FIRST and is the falsifiable half — unbanked,
  `route_redo` answers `Nothing` and no assertion about text says why.
  It also paces the two activations apart (the WinUI ~45ms chord rule).
- THE ROUTE IS CORE ON EVERY LANE, so this asserts no frontier
  granularity (which the file's header refuses): the walk spent the
  episode, the frontier is the star GROUP, and `route_redo`'s native
  branch needs an OPEN episode on the focused field. Whether the undo
  above was taken natively (mac, Compose) or coarsely (any lane whose
  A4 query says no) the redo restores the same after-image.
- THE SECOND UNDO PUTS THE SCRIPT BACK, so the b/X/a interleave below is
  the walk it always was. Every later expectation is byte-identical to
  before — no other surface moves.

### DEVIATION FROM THE CHARGE, stated: the star click cannot serve as the
### focus move
The charge asks for "move focus (the star click serves)" between the walk
and the redo. It cannot: the star is an UNDOABLE GROUP, and `bank_group`
ends with `ledger.redo.clear()` (scene.rs:2156) — a new step invalidates
the forward history, banking or not. A scene that clicked star first
would assert that the typing is gone, which is the opposite pin. The
unit test `a_new_step_after_a_banked_walk_spends_the_forward_history`
pins that rule so the next reader does not re-try it.
Nothing is lost by asking earlier: the fully-undone episode is
unrecoverable from the moment it is dropped, not from the moment focus
moves — `route_redo` answers `Nothing` immediately, and kaya's own
Edit>Redo consumes the command rather than falling through to the
platform's redo, so the native tier does not quietly cover for it.

### The mac leg (rust guest, the leg validate-mac runs)
Build: `cargo build --locked --lib --example undo`, `build-id.py
--verify target/debug/libkaya.dylib` (rc=0), `swiftui/build-dylib.sh`
(rc=0). Leg env `KAYA_SWIFTUI_LIB=target/swiftui/libkaya_swiftui.dylib`,
`KAYA_SELFTEST_SCRIPT` = the scene with comments stripped, exactly as
validate-mac's `scene_script` builds it.

| run | rc | verdict |
|---|---|---|
| 1 | 0 | `KAYA_SELFTEST: OK (… tea, menu "Edit>Redo" enabled, teas, redid typing, 1 total, tea, undid typing, 1 total, added milk, 1 total, undid star, 1 total, …)` |
| 2 | 0 | OK |
| FLIP (banking reverted, rebuilt, build-id verified) | **124 (timeout after 21 failed steps)** | FIRST failure is the new pin: `step-failed menu "Edit>Redo" reads "disabled", wanted "enabled"`, then `entry#0 reads "tea", wanted "teas"` |
| restored (sha256 c3750b9e…), rebuilt | 0 | OK |

AND TWO MORE TIERS, because the scene is shared verbatim and the fold is
the guest's: `undo-python-swiftui` (the AMBIENT tier) rc=0 and
`undo-c-swiftui` (the explicit floor, and the leg item 4 now gates) rc=0,
both on the restored tree. No guest source was touched — the new steps
reuse the existing history strings.

## ITEM 2 — STAMPED-COPY EPISODES: MEASURED, NOT BUILT
## (RATIFICATION PROPOSAL — the maintainer's call, tree unchanged)
## RULED option A, 2026-08-06 (docs/undo-plan.md), and SHIPPED in
## `1d2cf95`: `texts` is an arity-first group in spec.rs today, so this
## section is the record of the decision and not a live proposal.

### The deciding fact: the texts run cannot address an instance field
`undone`/`redone` carry FOUR runs, and only two of them are arity-first
groups. From spec.rs:1494-1548 and the one encoder that writes both
directions (wire.rs:948-999, decoder 1014-1048):

- `entries` GROUPS: `I64 size, I64 collection, I64 flags, I64 variant,
  I64 path_len, path values, key, record fields` — an instance path fits
  because the group says how long it is.
- `orders` GROUPS: likewise, `size` first.
- **`texts` PAIRS: `I64 widget id, Str`** — fixed arity, no path, no
  size. wire.rs:958-961 writes exactly two values per entry and
  wire.rs:1042-1048 reads exactly two.

A stamped copy's identity on the text channel is `(TemplateNodeId, key
path)` — that is what `decode_text_changed_tag` returns for a non-empty
path (wire.rs:1417-1433), and it is why `text_field_of_tag` answers
`None` (scene.rs:2342). A pair with no path cannot carry it. **So an
instance field is NOT addressable on the existing wire, and item 2 falls
under the charge's "DO NOT build" branch.**

### What the core half would cost, since that decides how big option A is
CHEAP, and provably so: `Scene::run_body` ALREADY builds the map while
stamping — `node_map: HashMap<u64 /*template node*/, WidgetId>`
(scene.rs:3785-3794) — and throws it away when `stamp_entry` returns;
`Stamp` keeps only `widgets` in creation order (scene.rs:173-185).
Persisting `node_map` in `Stamp` IS the template-node-to-copy map, and
the rest already fits:
- a copy's widgets have real (internal-bit) WidgetIds, and every
  programmatic write to one already names that id — `absorb_text_writes`
  admits it explicitly (`id.0 & INTERNAL_BIT != 0`, scene.rs:2192-2195);
- `capi.rs:1993-1996` already STATES this as the intended answer: "the
  ledger keys on the identity that CARRIES the text, which for the copy
  is its own internal widget id";
- focus is reported to `route_undo` as that same internal id (the
  interpreters' `focusedId` is the node they created from the Create op),
  so routing needs nothing new.

So the only thing missing is the app-facing half — and that is exactly
the half D5 exists for.

### Why half-building it would be worse than not building it
Bank the episode with no wire change and the coarse restore writes the
row's text back through `ApplyOp::SetProp` on the internal id (the
backends apply that today), so the WIDGET is right — while the `undone`
payload hands the app a pair naming an id it has never seen and cannot
resolve. D5's contract is "this record is the ONLY thing the app hears";
an app that folds `delta.texts` into its model would silently go stale on
exactly the field the milestone was written to keep in step. That is the
drift class this design exists to prevent, so it must not be shipped as a
side effect.

### THE OPTIONS, for the maintainer

**A. Spec change — make `texts` an arity-first group like its two
neighbours.** `I64 size, I64 id, I64 path_len, path values, Str text`,
with `path_len 0` meaning "a live widget id" exactly as the identity tag
already spells it (spec.rs:1480-1489 — "path_len 0 meaning `id` is a
widget id"). The shape is already in the record twice, so it is the
existing vocabulary rather than a new idea.
- Moves: the spec hash; wire.rs's one encoder + decoder; the eight
  bindings' `undone`/`redone` decode and their delta types; the guests
  that read `delta.texts` (the Rust guest reads `.last()`, the other
  eight fold the same way); bindings/c/kaya_wire.h's pinned hash.
- Does NOT move: any backend. No backend decodes `undone` (it is an
  app-facing occurrence), and the restore is an ordinary SetProp on an
  internal id, which every backend already applies. The charge's "every
  backend's apply extended" is, measured, not part of the bill.
- Buys: a stamped row's typing joins the ledger with the same ordering
  guarantee as everything else, and A6's gap stops widening at row
  fields.

**B. Ratify native-tier-only for stamped fields as designed behavior.**
A row field keeps the platform's own undo stack (every backend already
gives it one) and the ledger holds no episode for it. The doctrinal
defense is D4's own teachable rule — "undo restores state, and state is
signals plus collections": an app that wants a row's text undoable in the
core tier BINDS it to a record field, which kaya already supports for any
prop including text (`PropValue::Element { level, field }`,
scene.rs:3845-3861), and the undo then travels the `entries` run that
already addresses instances properly. This is the same answer D4 gives
for const props, one level down.
- Costs, stated so the ratification is informed: A1's clear still fires
  on a group commit and clears whatever field has focus, INCLUDING a row
  field — so a row's typing history is destroyed by the next app step
  rather than reordered. That is the amnesia escape (§2), scoped to
  stamped fields, and it is today's shipped behavior.
- Where it must be written: DESIGN.md's Binding conventions carve-out
  plus a line in undo-plan §3, per invariant 1's rule that a carve-out is
  stated uniformly.

**C. (named so it is not rediscovered, NOT recommended) Carry the
internal widget id in the existing pair.** No hash move, widget restored,
and an app-facing record that names an identifier no app can resolve.
It buys the appearance of the feature and none of D5.

MY READING, offered as input and not as a decision: B is coherent today
and A is the one that keeps the "no holes" promise literally true. The
question that decides it is whether an uncontrolled row field is app
state (then A) or widget state (then B) — and DESIGN.md already answers
that for every OTHER widget property with the reactive doctrine.

## ITEM 3 — THE REDO TWIN: RESOLVED BY EVIDENCE (no build)

The ledger item said: "note_native_undo has no redo twin; the mac arm
passes canUndo in both directions deliberately. Revisit with the first
arm whose platform distinguishes them."

### Every arm distinguishes them — as a ROUTING query, which is already answered
| arm | canUndo | canRedo | file:line |
|---|---|---|---|
| mac | `responder.undoManager?.canUndo` | `…canRedo` | KayaSwiftUI.swift:6562-6584 |
| iOS | `input.undoManager?.canUndo` | `…canRedo` | same pair, `#else` branch |
| Compose | `KayaUndoState.canUndo(node)` | `KayaUndoState.canRedo(node)` | KayaCompose.kt:4040-4045 |
| WinUI | `field.CanUndo()` | `field.CanRedo()` | winui/mod.rs:3658-3669 |
| GTK | textarea `buffer.can_undo()`, entry `native_dirty` | textarea `buffer.can_redo()`, entry the same set | gtk.rs:2422-2437 |

All five feed the distinct query into `route_redo`, which is where the
distinction is CONSUMED (scene.rs:2424-2448). So the trigger the item
named has been met by every arm, and the answer is the same on all five.

### The trigger was the wrong test — the flag has exactly one consumer
`note_native_undo`'s third argument is not "can this walk go on". It is
the test for ONE arm of the function: the field EXHAUSTED short of the
before-image, which is the case A1's clear is supposed to make
unreachable and which falls back to the coarse restore. That arm is
BACKWARD-ONLY by construction, and a `canRedo` reported there would be
false at the END of a forward walk and send the core backwards — undoing
the redo it was just told about. All three arms that route a redo say so
in their own comments, independently: KayaSwiftUI.swift:6921-6927,
KayaCompose.kt:4090-4095, gtk.rs:2595-2599 and 2720-2729 (GTK goes
further and does not report a redo that moved nothing).

### The forward analogue, and why it is unreachable
A native redo that exhausts short of the episode's after-image would be
the forward twin of the exhausted case. It cannot arise: the platform's
redo stack is created BY the backward walk, so it reaches exactly as far
forward as the walk came back, and the only thing that raises `after` is
new typing — which kills the platform's redo history by the platform's
own rule (§3, inherited not fought). If a platform is ever measured
violating that, THAT is the arm that needs a twin, and this paragraph is
the shape to look for.

### After item 1, what the frontier's canRedo means
`route_redo`'s native branch needs an OPEN episode on the focused field
with `current != after` — i.e. a PARTIALLY walked run. After item 1 a
FULLY walked run is on the redo side and the frontier is the entry
underneath, so `focused_can_redo` decides nothing there: the route is
Core whatever the platform still holds (asserted for both values in
`a_native_walk_to_the_start_banks_the_episode_forward`). So per arm the
query means exactly one thing — "does the platform still hold the forward
steps of a partial walk" — and nothing else.

VERDICT: no twin, no new wire, no backend edit. Closed as
resolved-by-evidence with the citations above.

## ITEM 5 — THE F1/F2 PAIRING CLAUSE (BUILT)

New gate `tools/check-native-undo.py`, wired into the fast-gate set
(`tools/validate-mac.py` beside check-roles, keyed like it) with its
input set declared in `tools/build-id.py`'s GATES
(`["crates", "swift", "android"]` — the same four backend files, and no
binding sits between the core seam and the arm that calls it).
`check-keyed.py` re-run: OK (19 gates keyed).

Three clauses per backend, over the four files that carry five arms
(KayaSwiftUI.swift serves mac AND iOS, whose brackets differ in spelling
and not in rule, so the mark is a LIST and either spelling satisfies it):
1. **SAMPLE ⇒ MARK.** A backend that calls the core's native-undo sample
   must mark the emission its own walk provokes ledger-quiet.
2. **THE MARK IS CONSUMED WHERE THE EDIT IS REPORTED.** The read and the
   report are ONE BLOCK — the two-line pairing the gate is named for. A
   read that has drifted off the emission suppresses nothing.
3. **THE CLEARUNDO ARM CLEARS.** A1's keystone, in the arm the core
   drives it from.
Plus clause 0, the vacuity guard that check-roles taught: every anchor
must still match, and an anchor that stopped matching FAILS ("either the
tier left this backend — say so here — or its spelling moved and the
clause went vacuous").

Anchors are CALL SHAPES (`core.scene.note_native_undo(`, not
`note_native_undo`): gtk.rs has its own local helper of that name, and a
gate that matches a definition passes when the call is deleted.

WHAT IT DOES NOT PIN, written into the gate: a call that is present but
disabled (`if (false)`) satisfies clause 3, and no text gate can do
better. What it pins is that the arm and the clear are one unit — the
shape a new arm or a refactor actually breaks.

### Watched failing, four self-tests, run on DOCTORED COPIES OF THE REAL
### FILES on every invocation (each prints its substitution count and is
### refused if it did not apply; each refusal is matched for its REASON)
The gate now says so out loud every run:
```
check-native-undo: watched failing: a Compose arm whose ledger-quiet read is gone
check-native-undo: watched failing: a SwiftUI arm whose bracket read drifted off the emission
check-native-undo: watched failing: a GTK ClearUndo arm that clears nothing
check-native-undo: watched failing: a WinUI backend whose core seam moved
check-native-undo: OK
```
The first IS the Compose arm's N1 perturbation — the one its whole lane
could not fail (§3.3) — and the third is F2's (§3.4). Both are now a
two-second red.

### The gate's own reader caught a defect in itself before it shipped
Clause 2 needs the enclosing block, so the gate reads braces with
comments and strings skipped — and it REFUSES to report anything if the
scan does not balance. That refusal fired twice on the real tree:
- Kotlin `"…(${reported.joinToString("; ")})"` and Swift
  `"can\(redo ? "Redo" : "Undo")"` nest a string inside an expression
  inside a string, so "scan to the next quote" ended the outer string at
  the INNER one and read the rest of the file as code;
- Kotlin's quoted-argument parser contains the character literal `'"'`,
  which read as the start of a string.
Both are now handled (interpolation-aware string skipping; a
character-literal rule written NOT to match a Rust lifetime `&'a str`).
A gate whose reader had been silently lost would have reported a clean
bill about nothing — which is the exact failure the vacuity clause
exists for, caught by it.

## THE LEDGER, UPDATED

`docs/deferred.md`'s "Undo follow-ups" now reads as finished business:
four items struck through with their evidence (fixed / resolved by
evidence / answered by the fan-out), one standing as a ratification the
maintainer owns. The two gate-gap bullets under it are struck too — the C
floor by this pass, the D5 text-run proof by the fresh-key depth arm that
reshaped the scene (its entry asked for exactly that reshape and it
happened; the ledger had not been updated).

`docs/undo-plan.md` gains one reconciliation rule in §3 (the walk that
reaches the start banks forward) and a §5 recording the completion pass:
5.1 the banking and why no backend moved, 5.2 the two unfailable guards
and the gate that answers them, 5.3 the sample's third fact is not a
direction, 5.4 the open stamped-copy question with its options.

## THE SWEEP (invariant 2)

The one behavioural change is core-side, so the sweep is short but it is
not empty — the question is whether each surface gets the new semantics
without a source change:

| surface | verdict | why |
|---|---|---|
| Rust, Python, Go, C#, Java, Swift, OCaml, Haskell | DO — no edit | the new step arrives through the `undone`/`redone` handlers each already has; a banked episode's redo is byte-identical in shape to the coarse redo they already fold |
| C floor | DO — no edit | same, on the record head it already matches |
| SwiftUI (mac), SwiftUI (iOS), Compose, GTK, WinUI | DO — no edit | every arm asks the core for the route before acting (`kayaRedoRoute`/`redoRoute`/`undo_route(redo)`), so `Core` where it used to be `Nothing` is answered by code that already exists |

Run green here: rust (handle tier), python (ambient tier), C (floor) on
the SwiftUI mac backend. NOT run here, and honestly the matrix's job: the
other six mac languages and the four non-mac lanes. The bounded risk
argument, so the next session does not re-derive it — no guest source
changed, and the new steps reuse strings the script already asserted
elsewhere; the only genuinely new assertion is a menu ENABLEMENT, which
is core routing plus each backend's existing `role_enabled`.

## VERIFICATION SUMMARY (final tree)

| gate / suite | result |
|---|---|
| `cargo test -p kaya --features harness --locked` | 268 passed, 0 failed (+13 compile-fail doctests, +3 doctests) |
| `tools/check-steps.py` | OK (with the new C-floor sweep) |
| `tools/check-native-undo.py` | OK, four clauses watched failing |
| `tools/check-stubs.py` / `check-verbs.py` / `check-roles.py` | OK |
| `tools/check-keyed.py` | OK (19 gates keyed) |
| `tools/check-shell.py` / `check-mirror.py` | OK |
| `tools/gen-header.py|gen-bindings.py|gen-guests.py --check` | OK (nothing regenerates — no spec change) |
| `tools/check-sugar-surface.py` / `check-universal-props.py` / `check-tx-liveness.py` / `check-abort.py` / `check-ambient-tx.py` | OK |
| `tools/check-targets.py` | ALL OK (every cfg'd backend, both feature configs) |
| mac legs | undo-rust-swiftui ×2 green + flip proof; undo-python-swiftui, undo-c-swiftui green |

## FILES

- `crates/kaya/src/scene.rs` — the banking arm + its doc, two unit tests.
- `tools/scenes/undo.steps` — the redo pin (7 steps, 30 lines with the
  reasoning).
- `tools/check-steps.py` — `sweep_c_floor`.
- `tools/check-native-undo.py` — NEW gate (item 5).
- `tools/validate-mac.py` — one line wiring the gate into the fast set.
- `tools/build-id.py` — the gate's keyed input set.
- `docs/deferred.md`, `docs/undo-plan.md` — the ledger and the plan.

## DEVIATIONS, stated

1. The scene asks for the redo BEFORE the star click rather than after a
   focus move (§ITEM 1): a group commit clears the forward history by the
   universal rule, so the charge's wording could not be satisfied as
   written. Unit test attached to the rule.
2. Two files outside the charge's ownership list were touched, both
   because a gate nobody runs is not a guard: `tools/validate-mac.py`
   (one line) and `tools/build-id.py` (a GATES entry). CLAUDE.md/AGENTS.md
   enumerate the fast-gate set in their validation ladder and now lag by
   one gate — left alone deliberately (they are mirrors, and the ladder is
   the maintainer's doctrine text), flagged here as the one-line follow-up.
3. Item 2 is measured and NOT built, per the carve-out discipline.

## PROCESSES AND DISK

- Processes: every leg was a foreground `timeout 120` run; none
  backgrounded. `ps -Ao pid,etime,pcpu,command | grep -Ei
  "examples/undo|c-guests/undo|guests/python/undo (gone)|record-suite|swiftui"`
  → EMPTY. The GUI leg lock was taken once and `rmdir`'d; `ls` of
  `leg.lock` → "No such file or directory".
- Scratch: saved perturbation copies (727 KB) deleted after every restore
  was sha256-proven; perturbation inputs and build logs deleted. This
  session leaves 51.0 KB in the scratchpad — the report (21 KB), the six
  leg logs, and perturb.py.
- The repo's own `target/` stands at 38 GB, of which ~3.5 GB was
  rewritten in this session — almost all of it `check-targets.py`
  cross-compiling every backend into the tree every lane builds from.
  Not deleted, deliberately: it is the project's canonical build
  directory, not agent scratch, and clearing it would cost the next lane
  a full multi-platform rebuild.

### One more run, on the FINAL tree
The green-twice runs above were made before a comment-only edit to a
`#[cfg(test)]` block, so the build id moved. Rebuilt, `build-id.py
--verify` rc=0, `undo-rust-swiftui` re-run: rc=0, `KAYA_SELFTEST: OK`.
The record is about the tree as it stands.
