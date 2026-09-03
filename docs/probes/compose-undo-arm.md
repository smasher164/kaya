# The COMPOSE UNDO ARM — closing the JNI seam

Working record, written progressively. Status markers: PLANNED / DONE /
BLOCKED / MEASURED. Nothing committed.

Charge: implement the five core-facing entries the fan-out arm left as
`depthStub("undo")` in KayaCompose.kt, wire the JNI both sides, wire the
android runner's undo legs, hold seven gates green, run the lane twice.

---

## 0. Context read (DONE)

- `docs/probes/undo-fan-compose.md` — the fan-out arm's full report. Its
  §1 (§3a measurement), §3 (shipped-source instrumentation), §5 (WHY the
  five entries are stubbed) are the ground this arm stands on.
- `docs/undo-plan.md` §0 D1-D8, §1.4 (Compose's measured charges), §2
  A1-A8, §3 episode banking + the three-way routing, §3a the per-arm
  mirror rule.
- `docs/probes/derive-pin-depth.md` §8 — the blocker: the reshaped
  todos scene carries `menu_activate "Edit>Undo"`, the Android lane runs
  todos on Compose AND on the jvm APK, and every path into it enters the
  stub (enablement at render, KayaCompose.kt:2197).
- `scratchpad/undo-compose-jni-handoff.md (gone)` — the fan-out arm's written
  handoff: five declarations, five registration rows, five one-line
  bodies, two leg blocks.
- `tools/check-jni.py` in full — the gate that pins BOTH directions.
- CLAUDE.md's four-layer rule for interpreter backends.

Tree at start: HEAD `aadbe9e`, working tree DIRTY with sibling work
(bindings/{go, haskell, java, ocaml, python}, guests/*/todos.*,
crates/kaya/src/app.rs, docs/deferred.md, tools/scenes/todos.steps).
None of those are mine.

### A charge-vs-repo discrepancy, resolved

The charge names `crates/kaya/src/jvm.rs` as the JNI registration file.
The `KayaPresent` natives are NOT registered there — `jvm.rs` owns the
portable `KayaRing` transport (shared android+desktop) and the desktop
list; `register_present_natives` lives in `crates/kaya/src/android.rs`
(android.rs:124-230). `tools/check-jni.py` reads all three files plus
`KayaPresent.kt` and pins them against each other. So the JNI half of
this arm is `crates/kaya/src/android.rs` +
`android/kaya/src/main/kotlin/dev/kaya/KayaPresent.kt`, which is what
the fan-out arm's handoff also names. Recorded as a deviation; jvm.rs
needs no edit and got none.

---

## 1. §3a — the measurement is INHERITED, and here is why that is legal

§3a forbids inheriting the plan's sentence; it does not forbid citing a
MEASUREMENT another agent took on this same backend. The fan-out arm
answered §3a's question for Compose three times over, and the charge is
explicit that this arm uses its answer:

- `undo-fan-compose.md` §1 Q-a: a kaya-ROUTED `undoState.undo()` moved
  `tfsObserved` 4 → 5. The channel is PRESENT.
- §1 Q-b: even an UNINTERCEPTED hardware Ctrl+Z moved it.
- §3 point 6, on the SHIPPED interpreter with a temporary log line:
  `undoState.undo()` took the widget `teapots` → `teapot`, the shipped
  observer saw it, and the emission carried `quiet=true`.

The structural reason (and it is the reason it generalizes): a
`TextFieldState`'s text IS snapshot state, `undoState.undo()` writes that
same state, and the collector is a snapshot observer — there is no
separate commit path for an undo to bypass. §3a's premise fails where a
declarative layer sits between the widget and the model (SwiftUI's
binding setter) and HOLDS where the undo is a write to the observed
state. So Compose is on the SAME side of §3a's rule as iOS and GTK, and
the plan's guess that it would be on macOS's side is measured wrong.

CONSEQUENCE FOR THIS ARM'S CODE, stated so it is not read as an
omission: `kayaNoteNativeUndo` does NOT write `node.text` and does NOT
emit. The mac arm has to do both (nothing else would); here the
collector does both a frame later, and the emission is bracketed
ledger-quiet by [kayaNativeUndoEcho]. That is Q2's one-reporter rule
with the two platforms differing only in WHICH of the two reports they
suppress.

---

## 2. What is written

### 2.1 KayaPresent.kt — five `external fun` declarations (DONE)

`undoRoute`, `redoRoute`, `undo`, `redo`, `noteNativeUndo`. Doc'd with
the window-is-always-0 platform fact and the both-directions `canUndo`
rule.

### 2.2 crates/kaya/src/android.rs — five rows + five thunks (DONE)

Rows in `register_present_natives` (sigs `(JJZ)I`, `(JJZ)I`, `(J)V`,
`(J)V`, `(JJLjava/lang/String;Z)V`); thunks `present_undo_route`,
`present_redo_route`, `present_undo`, `present_redo`,
`present_note_native_undo`, each a straight forward to the C entry that
already existed in capi.rs. The string crosses as UTF-8 bytes, the same
shape `present_emit_text` already uses.

**Negative test, WATCHED FAILING** (android.rs is NOT compiled by the
host target, so `cargo test -p kaya` can never catch a defect here —
worth knowing):

| perturbation | substitutions | `--target aarch64-linux-android` | host target |
|---|---|---|---|
| `kaya_undo_route` → `kaya_undo_route_TYPO` | 1 (asserted) | **FAIL** `E0425 cannot find function ... android.rs:423` | 0 errors |

Restored from a sha256-compared copy:
`c84e7716544a401ded7ae3a3fc282d904ae5c4801811f801fd3982371a700bd0`,
`diff -q` → RESTORED OK.

### 2.3 KayaCompose.kt — the five bodies, and `kayaRouteCode` back (DONE)

The seam comment is replaced by the live calls. `kayaRouteCode(Int)` is
re-added exactly as the fan-out arm's handoff said to: 0/1/2 →
NOTHING/NATIVE/CORE, and an unknown code is `error(...)` rather than a
quiet NOTHING — "nothing to do" is the one wrong answer that looks like
the right one.

`kayaUndoSeamNote` deleted (its only callers were the five stubs).

**`depthStub` deleted too, and its own doc comment is what obliged it**:
"IT CAME BACK FOR THE UNDO SLICE, exactly as its own deletion note
asked ... The last call site's removal is what obliges the next one."
Grep-verified: zero remaining references anywhere in `android/`,
`tools/`, `crates/`. The re-add recipe is left in a comment where the
function was, because `tools/lib/hand-rolled-stubs.py` requires the CALL
spelling and a future slice must not invent a sentence.

### 2.4 tools/android/run-emulator.py — the two undo legs (DONE)

`undo-compose` (rust guest) at the end of the compose block, `undo-jvm`
(Java guest) at the end of the jvm block. Both guest selector arms
already existed (`guests/rust/rusthost.rs:121`,
`android/javahost/.../MainActivity.kt:75 (gone)`), each with a comment
saying it was registered ahead of the arm on purpose.

**THE HOLD-OPEN GOING GREEN, watched in both directions:**

| state | check-steps |
|---|---|
| stub present, legs absent (start of this arm) | OK |
| stub REMOVED, legs still absent | **FAIL** — `scene "undo" has no live legs in tools/android/run-emulator.py (wanted "undo")` |
| stub removed, legs wired | OK |

---

## 3. THE MEASUREMENTS — taken on the SHIPPED interpreter

Everything below was measured on `KayaCompose.kt` itself, built and
build-id VERIFIED the way `tools/android/run-emulator.py` builds it. Only
the observation was temporary; every code path under test is the shipped
one.

### 3.1 WHICH TIER ANSWERS — the routing, observed (MEASURED)

Instrument: `scratchpad/instrument-route.py (gone)` (three log lines, each
substitution count asserted 1/1/1 before the build). Read from the
device's own logcat buffer after the leg — `undo-compose` is the last
compose leg, and `logcat -c` runs at the START of each leg, so the buffer
still holds it. Raw: emulator-5558, 2026-08-05 14:14.

```
KAYA_ROUTE_PROBE: undo -> CORE                      <- 1
KAYA_ROUTE_PROBE: redo -> CORE
KAYA_ROUTE_PROBE: undo -> NATIVE                    <- 2
KAYA_ROUTE_PROBE: native walk redo=false on 5       <- 2
KAYA_ROUTE_PROBE: undo -> CORE                      <- 3
KAYA_ROUTE_PROBE: undo -> CORE                      <- 4
KAYA_ROUTE_PROBE: redo -> CORE
KAYA_ROUTE_PROBE: undo -> CORE
KAYA_ROUTE_PROBE: redo -> CORE
KAYA_ROUTE_PROBE: undo -> CORE
KAYA_ROUTE_PROBE: redo -> CORE
```

1. The first Edit>Undo, after `click button#0` — the ledger's newest
   entry is the add GROUP. §3 routing case 2.
2. **THE NATIVE TIER, ENTERED — exactly once in the whole scene.** This
   is the scene's `b` step: `type "s"` made "teas", the frontier is an
   OPEN episode on the focused field, and the field's own
   `TextUndoManager` has something. §3 routing case 1, and it is the one
   step where the platform's stack answers.
3. `X` — the star group. The native walk reached the episode's
   before-image, `note_native_undo` consumed the episode, and the
   frontier moved to the group underneath. The reconciliation loop,
   observed.
4. `a` — the EARLIER typing run, no longer frontier-live: §3 routing
   case 3, the coarse restore.

So all three of §3's routing cases fire in one leg, in the order §3
names them. `kayaNativeUndo`, `kayaNoteNativeUndo` and the echo bracket
are live code on this lane, not decoration.

### 3.2 NEGATIVE TESTS — each WATCHED, and one of them DID NOT FIRE

| # | perturbation | subs | `undo-compose` | `todos-compose` |
|---|---|---|---|---|
| N1 | `quiet` forced false (the LEDGER-QUIET bracket disabled) | 1 | **PASS** — the test FAILED as a test | PASS |
| N2 | `noteNativeUndo` silenced (`if (text != text)`) | 1 | **FAIL (42s)** | PASS |
| N3 | `kayaRouteCode` maps 1→CORE, 2→NATIVE | 1 | **FAIL (62s)** | **FAIL (6s)** |

N2's failure is the predicted one, step for step:

```
label#1 reads "undid typing, 1 total", wanted "undid star, 1 total";
entry#0 reads "tea", wanted ""; ...
```

The core never heard the walk, so its frontier episode stayed open with
`current="teas"`, and the NEXT Edit>Undo spent itself on that episode
instead of the star group. Every later assertion slides by one. That is
the report path pinned by the lane.

N3 fails the RESHAPED TODOS SCENE at its very first `menu_activate
"Edit>Undo"` — `label#0 reads "1 item left", wanted "0 items left"` —
which is the derive-pin arm's assertion doing exactly the job it was
added for, on this backend, six seconds in.

## 3.3 FINDING F1 — the ledger-quiet bracket is UNOBSERVABLE on this
## backend, and the reason generalizes

N1 is the one that matters, because a guard nobody has watched fail is
worse than none. I broke the bracket and the lane stayed green. The
reason is not that the bracket is wrong; it is that **the core has a
second wall and this backend's ordering always puts it in front**:

`Scene::note_text_changed` (crates/kaya/src/scene.rs:2180) opens with
`if before == text { return; }` — "an event that tells the ledger
nothing it already knows is not a step". And
`Scene::note_native_undo` (scene.rs:2373) writes
`field_text[field] = text` BEFORE returning. On Compose the sample is
synchronous with `undoState.undo()` and the snapshot collector delivers
the echo a frame later, so `note_native_undo` ALWAYS lands first — and
by the time the un-bracketed echo arrives, `field_text` already equals
it and the core drops it on the floor.

The core's own comment (scene.rs:2287-2294) names this exactly: "The
no-change return above catches that too, WHENEVER THE CORE'S RECORD OF
THE FIELD IS CURRENT; this holds when it is not". The bracket is the
guard for the ordering where the ECHO LEADS — which no lane on this
backend can produce, because the sample is synchronous and the echo is a
frame away.

**The bracket stays**, for three reasons stated rather than assumed:
1. Uniform semantics (invariant 1) — mac and iOS carry it, and the plan
   specifies it as the mechanism, not as a fallback.
2. It does not depend on the ordering; the core's guard explicitly does.
3. Its cost is one `HashMap` entry per routed native undo.

**And no platform-uniform scene can pin it.** Observing it needs a
PARTIAL native undo — walk back part of a multi-keystroke run, then redo
— and frontier granularity is exactly what `tools/scenes/undo.steps`
refuses to assert, because keystroke coalescing differs per platform (the
scene says so in its own header). A redo immediately after the `b` step
would not work either: the walk reached the before-image, so
`note_native_undo` POPPED the episode without pushing it to the redo side,
and the redo route is `Nothing`.

**What gate would have caught it, since no scene can**: the property is
"a backend that calls `note_native_undo` also marks the emission its own
walk provokes ledger-quiet", and it is a two-line pairing in each of five
backend files. That is a static cross-check of the shape
`tools/check-roles.py` and `tools/check-universal-props.py` already
have, and it belongs beside them. NOT WRITTEN HERE — gates are outside
this charge — recorded for the coordinator with the reasoning, because
the alternative is five backends each believing a guard they have never
seen fail.

## 3.4 FINDING F2 — A1's BACKEND CLEAR IS UNOBSERVABLE TOO, and F1+F2
## are ONE structural fact about every arm, not two Compose accidents

Having watched N1 fail as a test, I asked the same question of the OTHER
native-tier guard rather than assuming it was fine.

| perturbation | subs | `undo-compose` | `todos-compose` |
|---|---|---|---|
| `kayaClearUndoForGroup()` disabled (`if (false)`) — A1's clear, the keystone of NATIVE STACK ⊆ CURRENT EPISODE | 1 | **PASS** | PASS |

The lane cannot fail either guard, and the reason is the same one, stated
once:

**A scene can only observe a native-tier guard by taking TWO consecutive
native walks, and the routing makes that unreachable.** The first walk
reaches the episode's before-image, `Scene::note_native_undo` pops the
episode (scene.rs:2380-2383), and the frontier becomes the GROUP
underneath — so the next Edit>Undo routes CORE by construction. Everything
A1 protects (a native stack reaching back past the current episode's
start) and everything the ledger-quiet bracket protects (a second report
of a walk the core already banked) lives strictly inside that second
walk.

AND THE SCENE CANNOT BE FIXED TO REACH IT, because the fix would have to
assert FRONTIER GRANULARITY — how many keystrokes one native undo takes
back — which `tools/scenes/undo.steps` refuses in its own header ("the
frontier's granularity is platform-flavored and the order is not"), and
which differs per platform by keystroke coalescing. Invariant 6 makes
that decisive: one script, byte-compared on five lanes.

**THIS IS NOT A COMPOSE FACT.** Both premises are platform-independent —
`note_native_undo`'s pop is core code, and the scene is shared verbatim.
So the mac, iOS, GTK and WinUI arms each carry the same two guards under
the same blindness. Five backends × two guards that no lane can fail.

**Neither guard is removed here**, and the reasoning is written at the
call sites rather than left implicit: A1 is what makes the ledger
totally ordered for the ONE affordance kaya does not intercept (a
hardware Ctrl+Z the field consumes — measured live on this backend,
undo-fan-compose.md §1 Q-b), and the bracket is the guard for an
ordering the core's own no-change return does not cover.

**What I recommend, for the coordinator, gates being outside this
charge:** a static pairing check in the fast-gate set, of the shape
check-roles and check-universal-props already have — a backend that
calls `note_native_undo` must also mark the emission its own walk
provokes ledger-quiet, and a backend that handles `APPLY_CLEAR_UNDO`
must call the platform's clear in that arm. It is five two-line pairings
read out of five files, and it is the only wall available, because the
runtime one is provably out of reach.

There is one route to a RUNTIME guard, and it is Compose-only, which is
why it is a note and not a change: this backend already synthesizes real
KeyEvents through `Activity.dispatchKeyEvent` (the `type` verb), and
§1 Q-b measured a hardware Ctrl+Z at the field reaching kaya's model. So
a chord-at-the-field verb is buildable HERE and nowhere else — A8 names
the general hole ("no harness verb can press a chord at a native widget;
GTK panics on an unowned chord"). A per-backend scene would violate
invariant 6.

---

## 4. Verification

### 4.1 THE LANE — the charged runs, and then two more after every
### perturbation was reverted

Every run below is `tools/android/run-emulator.py all` (52 legs: 27
compose incl. the tablet, 25 jvm), on the three-device warm pool.

| run | source | rc | pass | fail | undo-compose | undo-jvm | todos-compose | todos-jvm |
|---|---|---|---|---|---|---|---|---|
| first | final | **0** | 52 | 0 | PASS | PASS | PASS | PASS |
| final-1 | final | **0** | 52 | 0 | PASS | PASS | PASS | PASS |
| final-2 | final | **0** | 52 | 0 | PASS | PASS | PASS | PASS |

`legs-compose` 22s / 19s, `legs-jvm` 16s / 16s — flat against the
fan-out arm's recorded shape, so nothing this arm added shows up as a
duration anomaly. (The JNI call now runs on every enablement read of an
Edit>Undo row; it is a mutex acquire and a `match`, and it does not
register.)

THE UNDO LEG'S OWN TRANSCRIPT, byte-identical on both APKs:

```
KAYA_SELFTEST: OK (no todos, history empty, no keys,
  menu "Edit>Undo" disabled, menu "Edit>Redo" disabled,
  entry#0 focused, milk, menu "Edit>Undo" enabled,
  added milk, 1 total, keys 1, , no todos, undid add milk, 0 total,
  no keys, , added milk, 1 total, redid add milk, 1 total, keys 1, ,
  tea, starred, teas, tea, added milk, 1 total, undid star, 1 total, ,
  undid typing, 1 total, nothing to add, 1 total, tea,
  redid typing, 1 total, added tea, 2 total, keys 1,2, ,
  nothing to add, 1 total, undid add tea, 1 total, keys 1,
  added tea, 2 total, redid add tea, 2 total, keys 1,2,
  removed milk, 1 total, keys 2, added tea, 2 total,
  undid remove milk, 2 total, keys 1,2, removed milk, 1 total,
  redid remove milk, 1 total, keys 2)
```

The interleave (`tea, starred, teas, tea` then `undid star` then `undid
typing`) is the b/X/a order §2 proves impossible under two bare stacks.

And the RESHAPED TODOS scene, which is what re-opened this arm:
`0 items left, 1 item left, , entry#0 focused, 0 items left, 1 item
left, 0 items left` — the derive restored by the ledger, both
directions, on both APKs.

### 4.2 Gates, on the final source

| gate | rc | verdict |
|---|---|---|
| `tools/check-jni.py` | 0 | OK (KayaRing.kt 12, **KayaPresent.kt 23**, KayaRing.java 13 natives, all registered) — 18 → 23 |
| `tools/check-stubs.py` | 0 | OK |
| `tools/check-steps.py` | 0 | OK — and its demand WATCHED FIRING (§2.4) |
| `tools/check-verbs.py` | 0 | OK (48 verbs, 77 constants + the CLIP_* mirrors + spec hash against 2 interpreters) |
| `tools/check-compose.py` | 0 | the Kotlin COMPILES |
| `tools/check-detekt.py` | 0 | no dead Kotlin — the reason `kayaUndoSeamNote` and `depthStub` were deleted rather than parked |
| `tools/check-roles.py` | 0 | OK — "fanned out everywhere: settings cut copy paste undo redo" |
| `tools/check-targets.py` | 0 | native / ios / **android** / windows ALL OK, both feature configs — the gate that covers android.rs at all |
| `tools/check-shell.py` | 0 | the runner's two new leg blocks |
| `tools/check-mirror.py` | 0 | — |
| `tools/check-keyed.py` | 0 | OK (18 gates keyed) |
| `tools/check-universal-props.py` | 0 | — |
| `tools/check-sugar-surface.py` | 0 | — |

### 4.3 Negative tests, each with its substitution count asserted
### before the build, each file restored from a sha256-compared copy

| # | file | perturbation | subs | result |
|---|---|---|---|---|
| N0 | android.rs | `kaya_undo_route` → `..._TYPO` | 1 | **FAIL** on `--target aarch64-linux-android`; **0 errors** on the host target |
| N1 | KayaCompose.kt | ledger-quiet bracket disabled | 1 | PASS — **the test failed as a test** (F1) |
| N2 | KayaCompose.kt | `noteNativeUndo` silenced | 1 | **FAIL (42s)**, at the predicted step |
| N3 | KayaCompose.kt | `kayaRouteCode` maps 1→CORE, 2→NATIVE | 1 | **FAIL** — undo-compose (62s) AND todos-compose (6s) |
| N4 | KayaCompose.kt | `kayaClearUndoForGroup()` disabled | 1 | PASS — **the test failed as a test** (F2) |
| N5 | run-emulator.py | (inherited from the fan-out arm) legs wired with the stub present | 1 | check-stubs FAIL |
| — | check-steps | stub removed, legs absent | n/a | **FAIL**: `scene "undo" has no live legs in tools/android/run-emulator.py` |

`KayaCompose.kt` restored to
`b051225b70475fcccd2c6cb7dc3cd2340cb837de9d12d463ed7fc8060187225a`
after every perturbation (`diff -q` → RESTORED OK each time), and the
tree grepped for every perturbation marker afterwards: 0 hits.

---

## 5. The sweep (invariant 2)

This is a BACKEND + TRANSPORT change. No guest-language API moved, no
spec constant moved, the spec hash did not move (check-verbs green
against both interpreters).

| backend | verdict |
|---|---|
| **Compose** | **DO** — this arm. Both tiers live, both APKs. |
| SwiftUI (mac) | N/A — landed `3044d73`; measured to need the OPPOSITE §3a treatment |
| SwiftUI (iOS) | N/A — landed in the fan-out; same side of §3a as this one |
| GTK | N/A — landed in the fan-out |
| WinUI | N/A — landed in the fan-out |

**AND WITH THIS ARM THE MILESTONE'S BACKEND ROSTER IS CLOSED**, checked
mechanically rather than assumed: `depth_stub("undo")` /
`kayaDepthStub("undo", …)` has ZERO occurrences in gtk.rs,
winui/mod.rs, KayaSwiftUI.swift and KayaCompose.kt, and all five runners
carry live undo legs —

```
tools/validate-mac.py       undo-{c,csharp,go,haskell,java,ocaml,python,rust,swift}
tools/linux/run-suites.sh   undo-rust
tools/deploy-win.py         undo_rust
tools/ios/run-sim.py        undo-swiftui
tools/android/run-emulator.py  undo-compose undo-jvm
```

Guest languages: no binding surface moved, so no per-language verdict is
owed. What DID move is coverage — this lane runs the undo scene through
the RUST binding (milestone2's `undo::app`) and the JAVA binding
(javahost's `Undo::app`), so two of the eight now exercise
`undoable` + the undone/redone absorb on a fifth backend.

Transport sweep, which is the part with a real question in it:

| JVM attach path | registers the five? | verdict |
|---|---|---|
| `android.rs::attach` (Rust guest, Compose presents) | YES | needed — `undo-compose` |
| `Java_dev_kaya_KayaRing_attach` in **android.rs** (JVM guest on Android) | YES — same `register_present_natives` | needed — `undo-jvm` |
| `Java_dev_kaya_KayaRing_attach` in **jvm.rs** (desktop JVM) | NO, and correctly | a desktop JVM guest presents through GTK/WinUI/SwiftUI; `KayaPresent` is not on its path at all. check-jni pins this by only requiring the DESKTOP list to cover `KayaRing.java`. |

---

## 6. Deviations, and things a reader should not be misled by

1. **The charge named `crates/kaya/src/jvm.rs`; the edit went to
   `crates/kaya/src/android.rs`.** `register_present_natives` lives
   there, not in jvm.rs (which owns the portable KayaRing transport and
   the desktop list). check-jni reads all three files plus
   `KayaPresent.kt` and pins them against each other, so the gate the
   charge named is satisfied — by the file that actually holds the
   registration. **jvm.rs is unmodified.**
2. **`android/kaya/src/main/kotlin/dev/kaya/KayaPresent.kt` was touched
   (+62)** and the charge did not name it. It is the Kotlin half of the
   same JNI pairing — check-jni fails if a registration has no
   declaration — so the five entries cannot exist in one file alone.
3. **`depthStub` was DELETED, not parked**, together with
   `kayaUndoSeamNote`. The helper's own doc comment is what obliged it
   ("the last call site's removal is what obliges the next one"), and
   check-detekt would not have caught it (it is `internal`). The re-add
   recipe sits in a comment where the function was, because
   `tools/lib/hand-rolled-stubs.py` requires the CALL spelling and a
   future slice must not invent a sentence of its own.
4. **F1 and F2 are the arm's real findings and they are ADMISSIONS, not
   achievements**: two of this backend's four undo guards cannot be
   failed by any lane, the reason is structural and platform-independent,
   and the same is true of the four sibling arms. §3.3 and §3.4 carry
   the argument and the recommendation.
5. **`docs/undo-plan.md` still says the wrong thing about Compose in two
   places, and I did not edit it** (docs are outside this charge; the
   fan-out arm flagged both and neither was taken):
   - §3a: "Compose is the one to expect trouble from — same declarative
     shape". Measured wrong three times over. The RULE §3a states is
     right; the guess about which side Compose falls on is not.
   - §D8/§1.4 pins: the plan says material3 1.3.2 / foundation 1.7.8;
     kaya pins NEITHER — `compose-bom:2024.10.01` decides, and it decides
     1.3.1 / 1.7.5. Nothing here turns on it; a "pin bump" would be a BOM
     bump.
6. **The route query is asked on every enablement read of an Edit>Undo
   row, and its answer is not snapshot state.** So a RENDERED row's
   enabled flag does not recompose when the ledger moves and no snapshot
   state does. Not reachable in practice — a DropdownMenu composes its
   rows when opened, activating a row closes it, and
   `kayaActivateMenuItem` re-derives enablement live before acting
   (KayaCompose.kt:5233) — and it is the SAME property
   `kayaRoleEnabled("paste")` has had since the clipboard arm (it reads
   the system clipboard, also not snapshot state). Recorded as a property
   of this host's role enablement, not as something this arm introduced.
7. **Not measured, inherited from the fan-out arm's named holes:**
   IME/soft-keyboard typing through the migrated field, and a real
   hardware keyboard (the AVD reports `hw.keyboard=no`; every keystroke
   in this lane is synthesized at the input-manager level).

### 4.4 One more fix, found while reviewing the diff

`KayaCompose.kt`'s cut/copy doc named `onValueChange` — an API the undo
migration removed — as the reason kaya can name no range to cut. The
claim survives (the MODEL carries a bare `String`); the API name does
not. Corrected, and the correction carries the thing a reader would
otherwise try: the field's `TextFieldState` DOES carry a selection now,
and reaching for it would be wrong because `edit {}` commits and a
commit CLEARS the undo history — D7's clear firing for a read.

The lane was re-run TWICE on those exact bytes
(`365c13839a92fa27fd358471ec9a961daa1a4a90e646a9f23dab6c3fe37ae6ae`)
rather than resting on the earlier pair: the runs on the record must be
runs of the shipped source, comment-only change or not.

---

## 7. Processes and disk

- **Started and stopped by me:** nine `run-emulator.py` suites (five
  `all`, four `compose`) — 52 or 27 legs each, every leg self-terminating
  under KAYA_SELFTEST. PROVEN STOPPED:
  `pgrep -fl "run-emulator|milestone2|screenrecord|logcat|undoprobe|adb shell am"`
  returns NOTHING.
- **Found running, NOT mine, NOT stopped, left exactly as found:** four
  headless emulators — pids 1856/1859/1862 (`-avd kaya`, :5554/:5556/
  :5558) and 63625 (`-avd kaya-tablet`, :5560). SAME PIDS before and
  after; `adb devices` = 4 × `device` at both ends. Three of them are now
  up 9d 19h, the tablet 9d 3h — the third report in a row to say so, and
  it is still a standing cost on every timing measured in this repo.
- **Temporary instrumentation and perturbations: ALL removed, restore
  PROVEN BY HASH, not asserted.** `KayaCompose.kt` back to
  `b051225b…` after each of the five perturbations (`diff -q` → RESTORED
  OK each time), `crates/kaya/src/android.rs` back to `c84e7716…`.
  Tree grepped afterwards for every marker
  (`KAYA_ROUTE_PROBE`, `text != text`, `false &&`, `if (false)`): **0
  hits**. Every lane run and every gate reading in §4.1/§4.2 was taken
  AFTER the removals; §4.4's pair is the final word.
- **Untracked files in the repo: NONE** (`git status --porcelain | grep
  '^??'` empty). Nothing of mine leaked into the tree.
- **Rebuilt in place, not created:** `android/{kaya, rusthost, javahost}/build` (8.7M / 356M / 190M) and
  `target/aarch64-linux-android` (970M) — the lane's own artifacts,
  rebuilt by every run of the runner, pre-existing, not mine to delete.
- **Scratchpad: 128 KB kept, everything else deleted.** Deleted after
  their verdicts were in this file: four `KayaCompose.kt` /
  `android.rs` / `run-emulator.py` restore copies (626 KB) and four
  superseded lane transcripts (289 KB). Kept because they are the
  evidence behind a claim here or a re-runnable instrument:
  `lane-ship-{1,2}.log` (the shipped runs), the four negative-test
  transcripts (`lane-neg-{quiet,note,route,a1}.log`),
  `instrument-route.py`, and this file.
- Nothing else launched: no emulator started or stopped, no simulator,
  no VM, no load generator, no watcher, no scheduled task. One gradle
  daemon was reused; none left behind beyond it.

---

## 8. Files

- `/Users/akhilindurti/Projects/kaya/android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt`
  — the five bodies, `kayaRouteCode`, the seam comment rewritten, the
  two dead helpers removed, the cut/copy comment corrected (+64/−101).
- `/Users/akhilindurti/Projects/kaya/android/kaya/src/main/kotlin/dev/kaya/KayaPresent.kt`
  — the five `external fun` declarations (+62).
- `/Users/akhilindurti/Projects/kaya/crates/kaya/src/android.rs`
  — five registration rows and five thunks in `register_present_natives`
  (+98).
- `/Users/akhilindurti/Projects/kaya/tools/android/run-emulator.py`
  — the `undo-compose` and `undo-jvm` legs (+26).

`crates/kaya/src/jvm.rs` is UNMODIFIED (see deviation 1).
