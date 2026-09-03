# derive-pin slice — the DEPTH arm

Working record, written progressively. Nothing committed.

Charge: reshape `tools/scenes/todos.steps` so the add is an UNDOABLE
step and the derived "items left" label is asserted after add, after
Edit>Undo and after Edit>Redo; adopt it in `guests/rust/todos.rs`; add
the deliberate-stance comment to `AppCtx::absorb_undo` in
`crates/kaya/src/app.rs`; prove the pin by deleting the undoable marker
and watching the leg fail.

Tree at start: HEAD `aadbe9e`, `docs/deferred.md` modified by a sibling
(not mine, untouched).

Baseline sha256 of the three files I own:

```
61f68b9128fa8c1a0ccb3ca4d5d19b6628e62c01ca1011c969d9a0426759e0a1  tools/scenes/todos.steps
f2526901cd27e5162fb4c3efc07566e2251e9e1e16fce61b01191c307e05b61f  guests/rust/todos.rs
9e49fabfd2b7cb84c031e99a5eea00870f2ed063b57760a94e1e940b1b6dd408  crates/kaya/src/app.rs
```

Copies saved to `scratchpad/baseline/ (gone)` (restoration source — never
`git checkout`, sibling work is uncommitted).

---

## 0. Reading pass (DONE)

`tools/scenes/todos.steps`, all nine todos guests (rust, c, python, go,
csharp, java, swift, ocaml, haskell), `guests/rust/undo.rs` +
`guests/python/undo.py` (the two spellings of the split-transaction
add), `tools/scenes/undo.steps`, `crates/kaya/src/app.rs`
(`Collection::derive`, `Tx::recompute_derived`, `Tx::undoable`,
`AppCtx::absorb_undo`, `AppCtx::next`, `Messages::next`),
`crates/kaya/src/scene.rs` (`bank_group`, `absorb_text_writes`,
`close_episodes_on`, `note_text_changed`, `route_undo`, `route_redo`,
`apply_delta`), `crates/kaya/src/harness.rs` (`SetText`, the `poll`
wrapper), `swift/KayaSwiftUI.swift` (the `set_text` verb),
`bindings/csharp/KayaApp.cs:423-437` (the comment to adapt),
`docs/deferred.md` (the retracted entry),
`scratchpad/fresh-key-depth.md (gone)` §3 (the moved-expectation precedent).

## 1. Why the reshape is sound — the mechanism, re-derived

Every claim below was read out of the source, not assumed.

**The derived write is inside the group.** `Collection::derive`
registers a compute; `Tx::recompute_derived` (app.rs:1024) pushes a
plain `TxOp::WriteSignal` into the SAME `ops` vector after each of the
six mutation paths — unconditionally, no cache, no skip. `Tx::undoable`
(app.rs:1166) inserts `TxOp::UndoGroup` at index 0 of that same vector.
So one `ctx.apply` that inserts and is named is one batch holding
`[UndoGroup, Insert, WriteSignal(derived)]`.

**The group banks it in both directions.** scene.rs:1092 marks every
`WriteSignal` id dirty and stores its pre-transaction value in
`rollback`; `bank_group` (scene.rs:2091) walks `dirty` and pushes
`rollback[id]` into `inverse.signals` and the current value into
`forward.signals`. So the step's inverse carries
`items_left = "0 items left"` and its forward carries
`items_left = "1 item left"`. Undo and redo restore the label with the
collection because they are the same banked step — which is exactly the
stance the retracted deferred entry ratified.

**No `on_undone` handler is needed, and the Rust guest registers
none.** `AppCtx::next` (app.rs:543-548) folds the delta into the
collection mirror for `Undone`/`Redone` before returning the
occurrence, and `Messages::next` folds an unmapped occurrence into
nothing (app.rs:2918-2921). That is the strongest available statement
of the thesis: **the todos app writes no undo code at all** beyond
naming the step, and the derived label still comes back.

**The undo routes to the ledger, not to the field's native stack.**
`set_text` is a programmatic write that emits a text event
(`KayaHost.emitText`, swift/KayaSwiftUI.swift:3351), so it opens a
typing Episode. `bank_group` closes the frontier episode when it pushes
the group (scene.rs:2145) and emits `ApplyOp::ClearUndo`, and
`route_undo` (scene.rs:2404) reads `done.last()` — the Group — so
`UndoRoute::Core`. On the way back `route_redo`'s native arm needs
`ep.open` (false) and `ep.current != ep.after` (equal), so it also
falls to `Core`. Neither routing decision is a coin toss.

**`clear` cannot be in the group.** D4 refuses `clear` inside an
undoable group at apply, so the add splits into two transactions —
the same split `guests/rust/undo.rs` and `guests/python/undo.py`
already carry.

## 2. THE STRING CONTRACT — the breadth arms' spec

Frozen here, byte-for-byte, for all nine languages (8 bindings + the C
floor). `tools/scenes/*.steps` is shared verbatim (invariant 6).

### 2a. The scene's expected strings

| observation | exact string | who writes it |
|---|---|---|
| `label#0` at scene start | `0 items left` | the derive's initial value (empty collection) |
| `label#0` after `click button#0` | `1 item left` | the derive, inside the add's group |
| `label#0` after `Edit>Undo` | `0 items left` | **the core**, from the group's inverse |
| `label#0` after `Edit>Redo` | `1 item left` | **the core**, from the group's forward |
| `label#0` after `toggle checkbox#0 on` | `0 items left` | the derive, after `update_field` |
| `entry#0` after `click button#0` | `` (empty) | the finishing transaction's `clear` |

The singular/plural rule is unchanged and already identical in all nine
guests: `n == 1` -> `1 item left`, otherwise `{n} items left`.

### 2b. The undo step's label

`add {draft}` — i.e. `add buy milk` for this scene. **Not observed by
the script** (todos has no history label), so it is a soft part of the
contract: pick the same spelling anyway, because a future step-name
assertion should not have to sweep nine files. The undo scene already
froze `add {title}`.

### 2c. Widget declaration order (unchanged — no widget is added)

Column children in creation order: `entry#0` (draft), `button#0`
("Add"), `label#0` (bound to the derived signal), then the For whose
template stamps `row` -> `checkbox#0`, row label. The C floor's order
is field, add, status, For — same indices.

**No widget is added by this reshape and no widget moves.** The only
structural addition is the window's Edit menu, which is not in any
index space.

### 2d. The menu

Declared on `DEFAULT_WINDOW`, menu titled `Edit`, two items:

| item text | role |
|---|---|
| `Undo` | `MenuRole::Undo` (`undo` on the wire) |
| `Redo` | `MenuRole::Redo` (`redo` on the wire) |

The script names them `Edit>Undo` and `Edit>Redo`. Every language's
undo guest already spells this; copy it from there. The window also
takes `.title("todos")`, matching every other titled scene — not
observed, but uniform.

### 2e. The add handler's transaction split (the part that is not a string)

The group must contain the insert and NOTHING that D4 refuses:

```
transaction 1 (the step):   undoable("add {draft}")  +  insert_fresh(...)
                            [the binding's derived write joins this batch]
transaction 2 (the form):   clear(field)  +  focus(field)
```

- **Handle bindings** (Rust, Go, C#, Java, Swift, OCaml, Haskell, and
  the C floor): two `apply`/`with_tx` calls, in that order.
- **Ambient bindings** (Python, and any other where a handler IS one
  transaction): name the group in the handler and POST the finishing
  work — `app.post(field.clear)` then `app.post(field.focus)`, or one
  posted callable doing both. `guests/python/undo.py:110` is the
  precedent. `tools/check-ambient-tx.py` forbids opening a second
  scope inside a handler, so posting is the only spelling.
- Keep `clear` BEFORE `focus`, as every todos guest has today: the
  script asserts `expect_focused entry#0` after the add and focus
  should be the last word. (undo.rs puts `focus` inside the group as a
  pure-effect demonstration; todos does not need that and the smaller
  group is the clearer statement.)

### 2f. The C floor is in scope

`guests/c/todos.c` runs as `todos-c` on the Linux lane
(tools/linux/run-suites.sh:383) and `tools/check-steps.py` is blind to
it (a known gap in docs/deferred.md). It has no `derive` — it writes
`SIG_LEFT` by hand in `write_items_left`. That is not an exemption, it
is the thesis at the floor: because the hand-written signal write rides
the SAME transaction as `kaya_tx_collection_insert`, the group banks it
and undo restores it identically. The C arm needs: the Edit menu
(`kaya_tx_menu_item_create` with the undo/redo roles, as in
`guests/c/undo.c`), the undo-group marker in the insert transaction,
and the existing `KAYA_COMMAND_CLEAR`/`KAYA_COMMAND_FOCUS` pair moved
out of that transaction into a second `kaya_submit`.

### 2g. What a wrong implementation looks like

The scene fails at `expect label#0 "0 items left"` (the post-undo line)
for: a guest that never named the step; a guest whose group is missing
because `clear` was left inside it (that one dies louder — D4 refuses
at apply); a core or backend that banks the collection but not the
derived signal. It does NOT distinguish a binding that (wrongly)
recomputes derived signals in `absorb_undo` — the recompute would
produce the same value. That is why the stance also gets written down
in the binding source (task 3): the scene pins the observable, the
comment holds the reason.

## 3. The reshaped scene (tools/scenes/todos.steps)

Every existing assertion is kept, in its original order and with its
original string. **Nothing moved.** The precedent the charge pointed at
(fresh-key-depth.md §3, where the undo reshape moved one expectation
because a group restores whatever it overwrote) has no analogue here:
the todos scene has one signal, the derive's, and the add is the only
step, so there is no earlier writer whose value an inverse could
restore in place of the one the old script named.

Three assertions and two verbs are new:

```
+expect label#0 "1 item left"        # after the add, before the undo
+menu_activate "Edit>Undo"
+expect label#0 "0 items left"
+menu_activate "Edit>Redo"
+expect label#0 "1 item left"
```

The first of them also closes a hole that predates this slice: the old
script never asserted `1 item left` at all, so the singular branch of
every guest's derive was dead weight in nine languages.

**Why the assertions cannot pass on a stale reading.** `expect` polls
to a 20s deadline (harness.rs), so a value that has not arrived yet is
retried rather than failed — which means an assertion CAN pass on a
value that was already there. Here the wanted value alternates
(`0 items left` -> `1 item left` -> `0 items left` -> `1 item left`)
and each is asserted before the next verb runs, so no line can be
satisfied by the state its predecessor already asserted.

**Why the undo has exactly one possible route**, and it is not luck:

- `set_text` opens a typing Episode (the SwiftUI verb calls
  `KayaHost.emitText`, so the core sees an ordinary text_changed);
- `bank_group` closes that frontier episode when it pushes the add's
  group and emits `ApplyOp::ClearUndo`;
- so at Edit>Undo, `done.last()` is the Group and `route_undo` returns
  `Core`. At Edit>Redo the native arm needs `ep.open` (now false) and
  `ep.current != ep.after` (equal), so that is `Core` too.

The header states this and says why the scene uses `set_text` where the
undo scene forbids it: routing is the undo scene's subject, and this
scene wants the group and only the group.

**The clear's echo does not disturb anything.** `absorb_text_writes`
records the field as empty when the Clear op goes out, so the echoed
`text_changed("")` hits `note_text_changed`'s no-change return
(scene.rs:2269) and neither opens an episode nor clears the redo stack.

## 4. guests/rust/todos.rs

Three changes, no logic beyond them:

1. the window construct, with the Edit menu and the two roles
   (`.title("todos")`, `.id()` to satisfy the `must_use` on `MenuRef` —
   a chain ending in `});` warns, and undo.rs's `.id();` is the
   spelling that does not);
2. the add's transaction split: `undoable(format!("add {draft}"))` +
   `insert_fresh` in the first, `clear` + `focus` in the second;
3. the doc header and two comment blocks saying why the label comes
   back without a handler.

The derive line is untouched, and the file still registers no
`on_undone` / `on_redone` — which is the point.

## 5. THE FLIP PROOF — measured

`scratchpad/dp-perturb.py (gone)`, one perturbation: `tx.undoable(step);` ->
`let _ = &step;`. The substitution count is printed and a count of 0 is
a failed self-test, not a passed one.

| state | substitutions | leg rc | verdict |
|---|---|---|---|
| correct | — | **0** | `KAYA_SELFTEST: OK (0 items left, 1 item left, , entry#0 focused, 0 items left, 1 item left, 0 items left)` |
| marker deleted | **1** | **1** | `KAYA_SELFTEST: FAILED (label#0 reads "1 item left", wanted "0 items left")` |
| restored | — | **0** | OK, byte-identical verdict, twice |

The failure is at the post-undo line and nowhere else, which is exactly
right: with no group on the ledger the Edit>Undo spends itself on the
typing episode (restoring the field from "" to "", invisible), the
collection never moves, so the later `expect label#0 "1 item left"`
after the redo and the final `0 items left` after the toggle both still
pass. **One assertion carries the whole pin, and it is falsifiable.**

The redo line is falsifiable by a DIFFERENT defect and is not
decoration: a step that banked the inverse but not the forward passes
the post-undo line and fails the post-redo one.

Restoration was from the saved bytes (`scratchpad/dp-todos.rs.good (gone)`),
never `git checkout`, and proven:

```
good      939cf9537965d7e9e6f6e40258b969d0df3f8465cb07d877e9dfbd3988cb03a8
perturbed 161dd0e55ca85bc633c4ab27ab86e433d8ec13add14f99c2bdec5952078dcb4f
restored  939cf9537965d7e9e6f6e40258b969d0df3f8465cb07d877e9dfbd3988cb03a8  MATCHES GOOD
```

## 6. crates/kaya/src/app.rs — the deliberate-stance comment

`AppCtx::absorb_undo`'s doc gains two paragraphs, adapted from
`bindings/csharp/KayaApp.cs:432-436` and made specific to Rust:

- WHY none happens: the derived write rode the same transaction as its
  mutation, so a named transaction banked it in both directions and the
  core has already restored it. Plus the structural version of the same
  sentence — recomputing is a `Tx` method and there is no `Tx` here, so
  the type already says this is not the place.
- WHAT would break if one were added: a value the ledger never banked,
  in a transaction the app never asked for, landing between the core's
  restore and the app's `on_undone`. Agreeing, it is dead code hiding
  the mechanism; disagreeing (a compute reading anything beyond the
  entries, or a derive declared after that step was banked — the one
  residual docs/deferred.md keeps), the screen and the ledger's record
  of the step drift apart and the next walk jumps back.

`git diff crates/kaya/src/app.rs` is comment-only: 20 added lines, all
`///`, no code touched.

## 7. Verification

### 7a. The leg — GREEN TWICE after a verified build

`scratchpad/derive-pin-leg.sh (gone)` builds (`cargo build --locked --lib
--example todos`), verifies `target/debug/libkaya.dylib`, builds the
SwiftUI dylib, verifies it with `--component swiftui` (the bare
`--verify` on that file can never pass — fresh-key-depth.md F2), then
takes the leg under the shared GUI lock, one run at a time.

```
build: rc=0
build-id core: rc=0
swiftui dylib: rc=0
build-id swiftui: rc=0
== leg run 1   todos-rust-swiftui: rc=0
== leg run 2   todos-rust-swiftui: rc=0
consecutive green: 2/2
```

Both verdict lines byte-identical.

### 7b. Gates

| gate | rc | note |
|---|---|---|
| `cargo test -p kaya --features harness --locked` | 0 | 266 passed, plus 3 and 13 doc-test suites; I added no test and moved no behavior |
| `tools/check-steps.py` | 0 | on the reshaped file |
| `tools/check-verbs.py` | 0 | no new verb; `menu_activate`/`expect` already in both interpreters |
| `tools/check-stubs.py` | 0 | |
| `tools/check-tx-liveness.py` | 0 | |
| `tools/check-sugar-surface.py` | 0 | |
| `tools/check-ambient-tx.py` | 0 | the Rust guest is a handle binding; nothing ambient moved |
| `tools/check-shell.py` | 0 | |
| `tools/gen-header.py --check` | 0 | no spec or wire change |
| `tools/gen-bindings.py --check` | 0 | |
| `tools/gen-guests.py --check` | 0 | |

### 7c. The hold-open, recorded rather than asserted

One sibling leg run against the new steps, so the breadth arms know
what red looks like:

```
todos-python-swiftui: rc=1
KAYA_SELFTEST: FAILED (no such menu item Edit>Undo;
  label#0 reads "1 item left", wanted "0 items left";
  no such menu item Edit>Redo)
```

Two distinct failures per guest: the missing menu (twice) and the label
that never came back. A guest that adds the menu but leaves the add
unnamed keeps only the middle one — which is the flip proof's signature
and the thing to look for when a breadth leg is half done.

## 8. FINDING F1 — BLOCKING, and it is a gate hole as well as a hole in a backend

**The reshaped todos scene needs the undo feature, and the Compose
backend refuses it.** The Android lane runs the todos scene on Compose
(`todos-compose`, tools/lib/lanes/android.py:44, and `todos-jvm`,
:61) with this same shared script.

- `android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt:3723-3774` —
  five `depthStub("undo")` bodies: `kayaUndoRoute`, `kayaRedoRoute`,
  `kayaNoteNativeUndo`, `kayaCoreUndo`, `kayaCoreRedo`. The five JNI
  entries the arm is waiting on are listed in the file at 4136-4141.
- `KayaCompose.kt:2197` — `"undo" -> return kayaUndoRoute() !=
  KayaUndoRoute.NOTHING`. ENABLEMENT is the same question as
  activation (A4), so merely having an Edit>Undo item on screen enters
  the stub: `kayaMenuEffectivelyEnabled` is called from the item row's
  `enabled =` at render (5155-5211) and again from
  `kayaActivateMenuItem` (5270) at `menu_activate`. `depthStub` returns
  `Nothing` — it throws. There is no arm of this the scene can avoid.
- The other four backends are clear. `depth_stub(` has NO callers in
  any Rust backend and `kayaDepthStub(` none in Swift; GTK and WinUI
  both carry `undo` in their lane's SCENES; the iOS lane queues
  `undo-swiftui` explicitly (tools/lib/lanes/ios.py:64). Compose is the
  only hole, and mac is proven green above.

**Why no gate caught it, which is the part worth fixing.**
`tools/check-stubs.py` and `tools/check-steps.py` state one rule
between them — a scene's legs are wired on a runner if and only if that
runner's backend has the feature — and they state it **keyed on the
SCENE NAME**. The Compose backend stubs the scene called `undo`; the
Android runner wires no `undo` legs; consistent, both gates green. What
neither gate reads is which FEATURES a scene's VERBS need, so folding
an undo assertion into a scene every backend must run is invisible to
them. `tools/check-stubs.py` returned 0 on this tree.

**The guard this failure class should get** (the doctrine's own
question — what gate would have caught it): check-steps already parses
every `.steps` file. Have it derive a feature set from the verbs —
`menu_activate "Edit>Undo"` / `"Edit>Redo"` implies the undo feature,
the way `expect_clipboard` implies the clipboard one — and cross-check
that set against each runner's scene list and each backend's
`depth_stub("<feature>")` calls. That is the rule the two gates already
enforce for scene names, one level down, and it would have failed the
moment `menu_activate "Edit>Undo"` entered todos.steps.

**Three ways forward; the coordinator's call, not mine.**

1. **Wire the Compose undo JNI** (the five entries at
   KayaCompose.kt:4136-4141). The stub's own comment says the gates
   "hand the undo legs back the moment this seam closes"; the todos
   reshape would ride the same closure. Biggest, and the one that
   removes the hole rather than routing around it.
2. **Give the derived-undo assertions their own scene name** (e.g. a
   `derive` scene) instead of folding them into todos. This reuses the
   mechanism that already exists: check-stubs and check-steps hold a
   stubbed scene's legs off the Android runner by name, so the pin runs
   on four backends today and Android picks it up automatically when
   the JNI lands. todos.steps goes back to what it was, plus the
   `1 item left` assertion, which is a strict improvement and costs
   nothing.
3. **Drop todos from the Android lane** — recorded only to reject it:
   it trades a whole backend's coverage of records-and-field-projection
   for one assertion.

My charge was explicit about reshaping `tools/scenes/todos.steps`, so
that is what is in the tree and proven green on mac. Option 2 is a
rename and a runner-list edit away if the coordinator wants it; the
guest work and the string contract are identical either way.

## 9. Processes and disk

- **Started and stopped:** 5 GUI leg runs — 4 rust (1 first green, 1
  perturbed red, 2 final green) and 1 python hold-open — each
  self-terminating under KAYA_SELFTEST and closing its own window;
  ~6 cargo builds; 3 SwiftUI dylib builds; one `check-targets`
  cross-compile sweep. No load generator, fixture, watcher, emulator or
  scheduled task was started at any point. PROVEN STOPPED:
  `pgrep -fl "examples/todos|guests/python/todos (gone)|derive-pin-leg|dp-perturb|check-targets"`
  returns nothing, and the shared GUI lock directory does not exist.
- **The GUI leg lock** was acquired and released around every leg,
  including the perturbed one and the python hold-open.
- **Disk:** my scratchpad footprint is small (this report, one leg
  script, one perturbation script, one saved-good guest copy, the
  baseline directory, and per-run logs). Nothing large was written; no
  scratch cargo target was created (the repo's own `target` was reused,
  and the three artifacts were rebuilt in place, not added to).

