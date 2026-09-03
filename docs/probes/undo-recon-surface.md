# undo-recon-surface — the binding and test surface an undo design must land on

Reader pass, 2026-08-04, against the working tree at `0254879`. Nothing was
mutated and nothing was run that mutates. Every claim carries file:line.

Note on one file: `docs/deferred.md` carries an UNCOMMITTED edit in this working
tree (the clipboard entry rewritten to "COMPLETE 2026-08-04"; it was already
there when this pass started, mtime 12:41, and this pass did not make it). Line
numbers for that file are the working-tree ones, not HEAD's.

---

## 1. How the eight bindings spell a transaction today

### 1.1 The one wire object underneath all eight

There is exactly one transaction type on the protocol: `pub type Transaction =
Vec<TxOp>` (crates/kaya/src/protocol.rs:1209), "applied atomically, in
submission order, last write wins per signal within the batch"
(crates/kaya/src/protocol.rs:1207-1208). `TxOp` is the closed op vocabulary
(crates/kaya/src/protocol.rs:1082-1205): signal writes, widget creation, props,
windows, alerts, file dialogs, clipboard, navigation, sections, menus,
collection deltas, template scopes, and one-shot widget commands.

**This is the most important fact for an undo design.** The guest never mutates
core except by shipping a `Vec<TxOp>` through the ring. There is no side
channel. So an "undo group" already has a natural boundary in the protocol —
the transaction — and the design question is whether an undo step is *exactly*
one transaction or a named span over several.

The ops are not currently invertible, though. Several carry no before-image and
have no inverse op:

- `WriteSignal { id, value }` (protocol.rs:1117) — no old value on the wire.
- `CollectionUpdateField { id, path, key, variant, field, value }`
  (protocol.rs:1216-1223) — the delta ships only the new value, deliberately
  ("toggling a todo's `done` never resends its title", protocol.rs:1209-1210).
- `CollectionRemove { id, path, key }` (protocol.rs:1224) — the removed record
  is not echoed, and neither is its ordinal position.
- `CollectionMove { id, path, key, before }` (protocol.rs:1227) — `before` is
  the destination only; the source position is not on the wire.
- `SetProperty` (1119), `SetWindowProp` (1125), `SetEntryProp` (1158),
  `SetSectionProp` (1170), `SetMenuProp` (1194) — all set-only.
- `MenuItemCreate` / `MenuItemAppend` (1174 / 1178) are declared append-only,
  "never removed in v1 (DESIGN.md, Menus)" — there is no op that undoes them.
  Same for `AddSection` (1163): "the set is append-only".
- `PushEntry` / `PopEntry` (1150 / 1155) look like a matched pair but are not:
  a pop "forget[s] its mounted tree, the destroy_window teardown discipline
  (ids never reused)" (protocol.rs:1152-1153), so a pop cannot be redone by
  pushing the same id.
- `ShowAlert`, `ShowFileDialog`, `Copy`, `ReadClipboard` (1135-1144) are
  external effects. Undoing them is meaningless — exactly the "what happens to
  occurrences emitted during an undo" question docs/deferred.md:730 flags.

Core holds the authoritative scene (crates/kaya/src/scene.rs) so it *can*
compute before-images; the wire simply does not carry them today.

### 1.2 Where a transaction is opened, per language

| Language | Tier | Opened by | Handle | Committed by |
|---|---|---|---|---|
| Rust | handle | `AppCtx::apply` app.rs:569, `AppCtx::begin` app.rs:576 | `Tx<'a>` app.rs:799 | `Tx::commit` app.rs:2090 |
| Go | handle | `(*App).Build` bindings/go/app.go:409 | `*Tx` app.go:359 | `Submit(tx.records...)` app.go:449 |
| Java | handle | `KayaApp.build` bindings/java/dev/kaya/KayaApp.java:2562 and :2799 | `Tx` KayaApp.java:1479 | `tx.submitIfAny()` KayaApp.java:2818 (body KayaApp.java:1552) |
| C# | handle | `KayaApp.Build` bindings/csharp/KayaApp.cs:359 | `Tx` KayaApp.cs:707 | `tx.SubmitIfAny()` KayaApp.cs:417 (body KayaApp.cs:767) |
| Swift | handle | `KayaApp.build` bindings/swift/KayaApp.swift:701 | `KayaAppTx` (init KayaApp.swift:1278) | `tx.submitIfAny()` KayaApp.swift:757 (body KayaApp.swift:1283) |
| Python | ambient | `app.build()` `bindings/python/kaya/__init__.py:2076`, `app.window()` `:2340` | module global `_tx` `__init__.py:93` | `_TxScope.__exit__` `__init__.py:2189` |
| OCaml | ambient | `Kaya_app.build` bindings/ocaml/kaya_app.ml:327 | global `ambient_tx : tx option ref` kaya_app.ml:184; record type `tx` kaya_app.ml:167-175 | `Kaya_runtime.submit` kaya_app.ml:383 |
| Haskell | ambient | `buildTx` bindings/haskell/KayaApp.hs:2051 (`submitTx` = the handle-less alias, KayaApp.hs:2318) | the `Build` state monad / `BuildState` KayaApp.hs:2268 | `kayaSubmit [records]` KayaApp.hs:2290 |
| C floor | neither | — | caller-owned buffers | — (tools/check-tx-liveness.py:10) |

The split is stated verbatim by the gate, tools/check-tx-liveness.py:10-10
(python since the 2026-08-31 conversion; the .sh is its exec shim):

- HANDLE (Rust, Go, Java, C#, Swift) — "hand the guest a transaction object, so
  a stale one can be recognised and refused" (check-tx-liveness.py:36-37). Rust
  refuses at COMPILE time (`Tx` is `!Send`, pinned by a `compile_fail` doctest
  at crates/kaya/src/app.rs:713-730); the other four check a `closed` flag at
  ONE chokepoint (check-tx-liveness.py:38-39).
- AMBIENT (Python, OCaml, Haskell) — "keep the open transaction in a global, so
  there is no handle to invalidate and nothing to make stale ... therefore
  check the THREAD instead, at the entry to a build"
  (check-tx-liveness.py:41-45). The three guards: `_require_app_thread`
  `bindings/python/kaya/__init__.py:70`, `require_app_thread`
  bindings/ocaml/kaya_app.ml:179, `requireAppThread`
  bindings/haskell/KayaApp.hs:2034.

The chokepoints, named, because an undo-group surface has to route through the
same places:

- Go `func (tx *Tx) emit(rec []byte)` app.go:389 plus the shared panic
  `func (tx *Tx) alive()` app.go:396, and the read-side sibling
  `func (tx *Tx) mirror(...)` app.go:406.
- Java `private void emit(byte[] record)` KayaApp.java:1503, `void alive()`
  KayaApp.java:1512.
- C# the `Records` *property* — `internal List<byte[]> Records` KayaApp.cs:725,
  whose getter calls `Alive()` KayaApp.cs:739 before returning the raw list.
- Swift the `tx` *property* — `var tx: KayaTx` KayaApp.swift:1244, get and set
  both calling `alive()` KayaApp.swift:1257.
- Rust: no runtime chokepoint at all; `&mut Tx` threading is the ambience
  ("No ambient statics — the `&mut Tx` threading is the ambience, the egui
  shape", app.rs:812-813).
- Python: `_records()` `__init__.py:133`, which raises "no ambient transaction"
  when `_tx is None`.
- OCaml: `let emit tx record` kaya_app.ml:262 and `the_tx ()` kaya_app.ml:213.
- Haskell: no chokepoint — records are pure data folded in `BuildState` and
  serialized once at the IO boundary, KayaApp.hs:2275-2282.

### 1.3 Every binding already carries a rollback journal — the undo primitive in miniature

The strongest existing structure an undo design can lean on. Each binding keeps
a per-transaction *journal* of before-images so an aborted transaction restores
the model mirror. Six of the eight describe it in nearly the same words ("a
snapshot per touched collection, taken on first touch"):

- Rust `journal: Vec<(CollectionId, Vec<Instance>)>` app.rs:802-804; snapshot
  taken in `Tx::touch` app.rs:830-841; restored in `impl Drop for Tx`
  app.rs:818-827.
- Go `a.journal = make(map[uint64][]*instance)` app.go:423; restored in the
  deferred block app.go:425-442.
- Java `private final Map<Long, List<Instance>> journal` KayaApp.java:1523;
  `void rollback()` KayaApp.java:1571, called at KayaApp.java:2807.
- C# `readonly Dictionary<ulong, List<KayaInstance>> journal` KayaApp.cs:752
  **plus a signal journal** `signalJournal` KayaApp.cs:763; `Rollback()`
  KayaApp.cs:790.
- Swift `fileprivate var journal: [UInt64: [KayaInstance]?]` KayaApp.swift:1273
  **plus** `var signalJournal: [UInt64: KayaValue?]` KayaApp.swift:1274;
  `rollback()` KayaApp.swift:1305.
- OCaml `mutable journal : (int64 * instance list) list` kaya_app.ml:170;
  restored on the exception path kaya_app.ml:387.
- Python `_journal = None  # per-transaction mirror undo, run if the tx is
  abandoned` `__init__.py:130`; restored `__init__.py:2237-2238`.
- Haskell needs no journal object: `Build` is a pure state function, the whole
  final state is `evaluate`d before the first store-back
  (KayaApp.hs:2268-2274), so a throw simply never reaches the `writeIORef`s
  (KayaApp.hs:2219-2223, :2283-2285).

Two things to carry into the design pass:

1. **The mirrors are guest-side, not core state.** They exist so a guest can
   read back what it wrote. Core's authoritative copy is separate
   (crates/kaya/src/scene.rs). An undo that only rewinds core would leave eight
   guest mirrors stale; an undo that only rewinds mirrors would not move a
   pixel. Whichever side owns the stack, the *other* side has to be told.
2. **C# and Swift journal signals; the other six journal collections only**
   (KayaApp.cs:763, KayaApp.swift:1274 vs app.rs:802, app.go:423,
   KayaApp.java:1523, kaya_app.ml:170, `__init__.py:130`). Either that is a
   real abort-semantics divergence hiding under a green check-abort, or it is
   dead precision in two bindings. An undo stack that restores collections but
   not signals would be visibly wrong in the same way, so this is worth
   settling first — and it is exactly the kind of question invariant 1
   (CLAUDE.md:47-55) exists to force.

### 1.4 Where a "group" boundary could attach

Four candidates, ascending in invasiveness:

1. **The transaction, implicitly.** Handler dispatch already runs each handler
   in its own transaction — Rust "Run everything posted, each in its own
   transaction" app.rs:530-541; Go "dispatch runs one handler inside its own
   Build" app.go:453-455; OCaml `let dispatch app` kaya_app.ml:419; Python's
   `_dispatch` is the subject of tools/check-ambient-tx.py:10-18 (the
   gate's body is python since the 2026-08-27 conversion ruling; the .sh
   is its exec shim). So "one
   gesture = one transaction = one undo step" costs no new binding surface at
   all. It is also probably wrong at the edges: a per-keystroke text editor
   would get one undo step per character, which is exactly the coalescing
   problem `NSUndoManager` grouping solves.
2. **A parameter on the existing opener** — `app.build(undo="Typing")` /
   `tx.undoGroup("Typing")`. The smallest 8-language sweep, and it maps onto
   both tiers. Handle bindings put it on the Tx; ambient bindings put it on the
   scope: Python's `_TxScope.__init__` already takes fifteen keyword parameters
   (`__init__.py:2081-2085`) so one more is idiomatic; OCaml's `build app (fun
   () -> ...)` (kaya_app.ml:369) takes a labelled optional argument; Haskell's
   `buildTx :: App -> Build a -> IO a` (KayaApp.hs:2262) needs either a new
   entry point or a `Build`-level combinator, since the group would otherwise
   have to be a record in the pure state.
3. **A nesting scope inside a transaction** (`tx.group("Typing") { ... }`).
   The most expensive. Go explicitly forbids `Build` inside `Build`
   (app.go:419-421, panic "Build inside Build — one transaction at a time");
   Python's `_TxScope` permits nesting only for `push_entry`/`add_section`
   (`__init__.py:2112`, `:2128-2135`). A group scope is a NEW nesting concept
   in all eight, and the ambient three have no handle to hang it on.
4. **A new `TxOp`** (`UndoGroup { label }` or `UndoBarrier`) emitted at the head
   of a batch. This is the spec-first path invariant 7 demands anyway
   (crates/kaya/src/spec.rs is the root, CLAUDE.md:91-94), and it makes the
   group a *wire* fact rather than a binding convention — so check-verbs and
   both interpreters see it, and a binding that forgets to emit it fails a
   byte-compared scene instead of silently grouping wrong.

The protocol shape observation that matters: a transaction is a bare
`Vec<TxOp>` with **no header** (protocol.rs:1256). Per-transaction metadata (a
group label, an "undoable: no" flag, a coalescing key) has nowhere to live
today except as an op inside the batch. Decide that explicitly rather than by
default.

### 1.5 How check-abort and check-tx-liveness pin tx semantics — the template an undo gate must copy

**tools/check-abort.py — the behavioural pin.** It RUNS a negative test in each
language against a real `libkaya` (check-abort.py:27-28), asserting "a handler
abort rolls the model mirror back, ships nothing, and the app continues (idiom
decides the spelling, never the semantics)" (check-abort.py:16-18):

- Go `go test dev.kaya/bindings/go` (check-abort.py:40) — also pins
  Build-in-Build misuse and the derived-registration non-leak
  (check-abort.py:38-39).
- Swift compiles the bindings plus tools/checks/swift-abort/main.swift into ONE
  module so internal mirrors are assertable (check-abort.py:44-56).
- C# `KAYA_CHECK=abort` branch of the guest binary (check-abort.py:63-64).
- Java tools/checks/java-abort/AbortCheck.java against the ring stub — "pure
  JVM ... no natives, so mutating transactions always abort"
  (check-abort.py:66-72).
- OCaml bindings/ocaml/checks/abort_check.ml (check-abort.py:74-78).
- Haskell `kaya-abort-check` built in its OWN build tree
  (check-abort.py:97-104); the header at check-abort.py:84-96 records why —
  a shared `dist-newstyle` wipe destroyed the docker lane's freshly built
  guests mid-run (2026-07-24), and cabal's plan cache made "the gate that
  passes without linking" a real failure mode for weeks. Plus a
  must-not-compile fixture pinning the Build/Tpl wall, with a grep insisting on
  the *type* error so a syntax error cannot pass as "didn't compile"
  (check-abort.py:106-116).
- Rust is pinned in `cargo test -p kaya`; Python in
  bindings/python/kaya_app_checks.py; C has no mirror and no dispatch so there
  is nothing to pin (check-abort.py:19-22).

**tools/check-tx-liveness.py — the structural pin.** It runs nothing; it checks
each guard exists and each chokepoint is still the ONLY way in:

- Go: `Tx.emit` present (69-70), `Tx.alive` present (71-72).
- Java: `private void emit(byte[] record)` present (75-76) AND `records.add(`
  appears EXACTLY once, emit's own body (77-79).
- C#: the `Records` property present (84-85) and raw `records.` used EXACTLY
  twice — the submit's `Count` and `ToArray` (86-91). "EXACTLY TWO, not 'at
  most'" (check-tx-liveness.py:86-88).
- Swift: the `tx` property present (93-94) and `storage.` used EXACTLY twice
  (95-97).
- Python/OCaml/Haskell: the thread guard exists AND is CALLED — counted, not
  grepped (101-115). The comment at 106-107 records the misfire: "THE
  DEFINITION IS NOT THE CALL, and grepping the bare name matches both — which
  made this clause pass with the call deleted."
- All seven: the error message must NAME the post primitive as the way out
  (121-133), so the guard says "do this instead" rather than "that is illegal".

**tools/check-ambient-tx.py — the third member, and the one an undo scope would
collide with.** It forbids a *guest* from opening a transaction inside a
handler, because the binding already did (check-ambient-tx.py:18-38). The
defect it exists for: Python's dispatch called six lifecycle handlers bare, so
`kaya.destroy_window()` inside `on_close_requested` raised "no ambient
transaction" — and five guests each hid it with `with app.build():` at the top
of the handler, so the lanes were green while the binding was wrong
("The workaround WAS the camouflage", check-ambient-tx.py:33). It is Python-only
by design (check-ambient-tx.py:40-51), lints on INDENTATION
(check-ambient-tx.py:57-77), and self-tests in BOTH directions
(check-ambient-tx.py:79-90).

**What transfers to an undo-group gate.** Copy the pair: one *behavioural* gate
running the semantics in every language against a real core (check-abort's
shape), plus one *structural* gate pinning the chokepoint so a new callsite
cannot skip it (check-tx-liveness's shape). Two specific lessons:

- Count, do not grep, and prove the perturbation applied (CLAUDE.md:73-81;
  check-tx-liveness.py:106-107).
- The message names the way out (check-tx-liveness.py:117-120).

And one specific collision: if undo grouping is spelled as a scope a guest
opens inside a handler, check-ambient-tx's premise ("opens a transaction in a
handler" == wrong) needs re-reading, or the group scope has to be textually
distinct from `app.build()` so the indentation lint keeps working.

---

## 2. The scene/harness machinery a future undo scene would use

### 2.1 What a `.steps` script is, mechanically

`tools/scenes/*.steps` are line-oriented scripts, LF-only, shared byte-for-byte
across every platform (CLAUDE.md invariant 6). They are parsed by
`harness::parse` (crates/kaya/src/harness.rs:584) into `Step`
(crates/kaya/src/harness.rs:143-312) and executed against a `Stage`
implementation (crates/kaya/src/harness.rs:373) supplied per backend. **47
verbs** exist today, extracted the same way check-verbs does it
(crates/kaya/src/harness.rs `parse`'s match arms):

```
alert_choose back cancel choose click clipboard_seed close_window context_open
expect expect_alert expect_alerts expect_aligned expect_at_end expect_ax
expect_ax_hint expect_clipboard expect_entries expect_file_dialog expect_fills
expect_focused expect_grid_columns expect_menu expect_menu_presentation
expect_menus expect_no_stall expect_order expect_overflow expect_root_fills
expect_section expect_sections expect_shares expect_split expect_stall
expect_title expect_window_size expect_windows file_choose file_dialog_goto
menu_activate resize_window scroll_end select_section set_text set_value
settle shortcut toggle
```

There is **no `undo` verb and no `redo` verb** today (verified by the extraction
above and by `grep -i undo tools/scenes/ crates/kaya/src/harness.rs`, which
returns nothing).

Structural rules a new scene inherits, all enforced by tools/check-steps.py:

- **It must open with an `expect`** (check-steps.py:1016-1054). The first
  observation's bounded retry doubles as the scene-ready wait; an action-first
  script races the mount on every platform at once.
- **Container targets are creation-indexed and therefore banned above index 0**
  (check-steps.py:9-18, 155-190) — only `column#0`/`row#0`/`scroll#0`/`grid#0`
  are cross-language stable.
- **LF only** — a raw CR byte fails (check-steps.py:1270-1293), because Swift's
  grapheme-based split sees CRLF as one cluster.
- **No `\n`/`\r` into a single-line entry** (check-steps.py:1296-1330).
- **Every assertion must read something REAL.** The house rule is visible all
  over the Step docs: `expect_menu` reads "the platform's REAL menu chrome —
  never the scene model's copy" (harness.rs:353-358); `expect_ax` reads the
  platform's own accessibility peer, "not the scene model, and not kaya's copy
  of what it set" (harness.rs:362-367); `expect_aligned` classifies from
  geometry "rather than reading the prop back" (harness.rs:262-266). An undo
  scene inherits this: asserting that core's model rolled back is *not* enough
  — the scene has to assert what the widget shows.

### 2.2 What a byte-frozen undo scene would need

**The activation half is already available.** `menu_activate` takes a
`>`-joined label path and drives "the REAL activation path of the menu item …
resolved wherever the item surfaced" (harness.rs:339-347, Stage method
harness.rs:711). `shortcut` drives the platform's key-equivalent dispatch table
(harness.rs:407-412, Stage method harness.rs:778). The clipboard scene already
uses exactly this shape for the platform-owned roles:
`menu_activate "Edit>Paste"` at tools/scenes/clipboard.steps:73 and :109, and
`shortcut "primary+s"` at tools/scenes/menus.steps:41.

So `menu_activate "Edit>Undo"` **parses and runs today** — but what it means
depends entirely on how the item is declared, and the two options are not close
to each other:

1. **A guest-authored action item.** The guest declares `m.item("Undo")` under
   an `Edit` menu with an ordinary click handler, and undo is the *app's* job.
   Nothing in kaya does the undoing. This needs zero protocol work and proves
   nothing about a core-owned undo stack.
2. **A `role` item.** `MENU_ROLES` is `["settings", "cut", "copy", "paste"]`
   (crates/kaya/src/scene.rs:499) — **there is no `undo` or `redo` role today**.
   The three clipboard roles are exactly the precedent an undo role would
   follow: "they hand the item's BEHAVIOUR to the platform. Such an item lowers
   to the host's own command, acts on the FOCUSED widget, emits no occurrence
   of its own, and configures its own enablement" (DESIGN.md:1815-1820; the
   same text at scene.rs:514-521). Adding `undo`/`redo` to that array is a spec
   change with the usual consequences — and it comes with the two rules that
   keep the vocabulary from becoming a placement grammar (DESIGN.md:1824-1831):
   **one item per role per app**, judged at the root (`menu_roles:
   HashMap<String, MenuItemId>`, scene.rs:257-261), and **a role never invents
   a chord** — so an undo item must spell `shortcut("primary+z")` explicitly.
   The root already rejects a role on a non-action item (scene.rs:5224), a role
   on a context item (scene.rs:5257), and a duplicate role (scene.rs:5233).

   Note the divergence an undo role would create with the clipboard ones: a
   clipboard role acts on the FOCUSED WIDGET and is the platform's own command.
   An undo role acting on the app's *model* is a different noun entirely — it
   is not the focused widget's business — so "hand the behaviour to the
   platform" would mean something new. That is a design decision, not a
   mechanical extension.

**The assertion half is the open question.** Today a scene could assert an undo
only through its visible consequences (`expect label#0 "..."`, `expect_order`,
`expect entry#0 ""`). Two things nothing can currently assert:

- **Whether the undo command is LIVE.** `expect_menu "Edit>Undo" disabled` /
  `enabled` already works (harness.rs:353-358, and the enablement axis is
  exercised at tools/scenes/menus.steps:5-6 and :26-27) — so if undo's
  enablement is core-computed like the clipboard roles', that assertion is
  free and is the single most valuable one: it proves core knows the stack is
  empty.
- **The stack's depth or the group's label.** There is no verb for this. If an
  undo design puts a label on a group ("Undo Typing"), the natural assertion is
  the *menu item's own label*, which `expect_menu` reads from real chrome
  today only along the enablement/checked/value axes (`MenuState`,
  harness.rs:358) — reading a menu item's LABEL is not currently a verb.

Two verb-shaped gaps, then: `undo`/`redo` as ACTIONS (if driving them without a
menu item is wanted — the `back` precedent, harness.rs:309-314, drives the
platform's own back affordance rather than a widget), and a label read on
`expect_menu` (or a new `expect_menu_label`, which is exactly how
`expect_ax_hint` got its own verb rather than a third field: "its own verb
because expect_ax's `<role>/<label>` spelling is byte-frozen in every scene",
harness.rs:379-382).

### 2.3 The scene-plumbing cost of one new verb

Adding any verb touches **five** places, and check-verbs enforces three of them:

1. `Step` variant + `parse` arm, crates/kaya/src/harness.rs:143 / :785.
2. `Stage` trait method, crates/kaya/src/harness.rs:373 — "No default: a
   backend that forgets it must fail to compile" is the repeated house rule
   (harness.rs:508-510, :520-525, :709-711). That is the compile-time half.
3. GTK + WinUI implementations (they run harness.rs directly).
4. **swift/KayaSwiftUI.swift** — string-matched, not compile-checked.
5. **android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt** — same.

tools/check-verbs.py:788-800 extracts every verb from `parse()` and demands the
literal string in BOTH interpreter files. tools/check-verbs.py:1008-1037 demands
every `expect_*` arm actually append to `observed` — "an expect that records
nothing passes without verifying anything", the defect measured on the Compose
`expect_ax` arm 2026-07-25 (check-verbs.py:1098-1134). And any new scene
substitution token (`$TMP`, `$PID`-style) must expand in all THREE
implementations, interpreters plus harness.rs (check-verbs.py:961-981).

### 2.4 Which gates hold the milestone open mid-fan-out — the clipboard pattern

This is the part worth copying wholesale, because the clipboard milestone just
ran it end to end (docs/deferred.md:33-40: "COMPLETE 2026-08-04: all five
backends, all eight bindings, every lane green").

**check-verbs (tools/check-verbs.py)** goes red the moment a verb exists in
`parse()` and not in an interpreter (check-verbs.py:868-880). It also pins
private constant mirrors by NAME AND VALUE together (check-verbs.py:1036-1080),
and specifically added a `CLIP_*` clause for the clipboard's five bit-position
masks because the generic sweep could not see them (check-verbs.py:57-94). An
undo milestone that introduces its own constants (a group flag, an
undoability mask) should expect to need the same bespoke clause, with the same
perturbation-scored self-test (`named/total`, only `1/1` passes,
check-verbs.py:640-651).

**check-sugar-surface (tools/check-sugar-surface.py)** goes red for any binding
that has not spelled the new surface. Two loops track the spec by construction
— widget kinds (check-sugar-surface.py:90-126) and window props
(check-sugar-surface.py:3418-3478), both read from the GENERATED wire file — plus
a hand-written clause per non-kind, non-window-prop surface. The clipboard
added FOUR such clauses, one per point of its surface, in all eight languages:
`copy` (check-sugar-surface.py:3137-3150), `read_clipboard` (:3152-3167), `accepts`
(:3169-3184), `on_paste` (:3186-3206), with the header explaining why: "none of
them is a widget kind or a window prop, so nothing above can see them"
(check-sugar-surface.py:3127-3136). **An undo group surface is exactly that
shape**, so it needs its own hand-written 8-row clause and will not be caught by
either automatic loop. The built-in negative test is the pattern to copy: a
fake kind must fail in all 8, or the patterns have rotted
(check-sugar-surface.py:776-789; the menus variant at :3222-3249).

**check-stubs (tools/check-stubs.py)** is the other half of the depth-slice
contract: a runner may not wire a scene's legs while its backend still stubs the
feature (check-stubs.py:18-30, checks at :72-76). The stub is a CALL —
`depth_stub("<scene>")` in Rust, `depthStub("<scene>")` in Kotlin,
`kayaDepthStub("<scene>", on: "<platform>")` in Swift (check-stubs.py:32-39,
:52-55) — and a backend refusing in its own words is itself a failure
(`tools/lib/hand-rolled-stubs.py`, check-stubs.py:107-113).

**check-steps (tools/check-steps.py)** reads the same stub from the other side:
`wired()` (check-steps.py:1684-1828) demands every scene have live legs in every
one of the five runners UNLESS the backend declares the stub. Two further
clauses matter for an undo scene:
- `SCENES` vs `DEPTH_SCENES` (check-steps.py:2129-2160): a scene in `SCENES` must
  have a guest in all six file-per-scene languages plus an arm in the Java and
  C# selectors (check-steps.py:2173-2193). A rust-only depth slice goes in
  `DEPTH_SCENES`.
- The mac-only leg check (check-steps.py:2195-2214): a guest that exists but no
  leg runs is invisible to every other gate — "clipboard shipped with working
  OCaml and Haskell guests that validate-mac never executed, and nothing
  noticed".

Plus the serialization rules the clipboard needed and undo probably will not:
menus/filedialog legs run alone between drains (check-steps.py:2414-2471), and
clipboard legs run alone on every lane (check-steps.py:2604-2675 desktop
and android, :2700-2857 iOS). Undo has no shared system resource, so it
should be poolable — worth stating explicitly rather than assuming.

**So the mid-fan-out red state is expressible and expected** (CLAUDE.md:209-216:
"some gates (check-verbs, check-sugar-surface) are DESIGNED to stay red
mid-milestone, holding the remaining work open; that is not a regression").
The sequence is: spec.rs → hash moves → regenerate → one backend (SwiftUI on
mac) + one binding (Rust) + the scene in `DEPTH_SCENES` + `depth_stub` in the
other four backends → green on mac → fan out → move to `SCENES` → matrix.

---

## 3. Session restoration: is the model mirror complete?

The deferred entry claims "The same machinery gives window/session restoration
— serialize the core scene, not the app's state" (docs/deferred.md:725-728).
The question is whether the core scene IS the whole state. **It is not, and the
gaps are doctrinal rather than accidental.**

### 3.1 What core holds

`Scene` (crates/kaya/src/scene.rs:201-265) holds everything DECLARED:

- `signals: HashMap<SignalId, Value>` (scene.rs:216) and the four binding maps
  (widget scene.rs:218, window :219, entry :234, section :247, menu :265,
  element :267).
- The surface topology: `windows` (:225), `nav_entries` (:229), `nav_stacks`
  (:230-233, "The core owns the stack"), `section_of` (:240), `sections`
  (:242), `selected_section` (:243-246, explicitly "the core's mirror of the
  switcher state"), `mounted_windows` (:276).
- The command catalog: `menu_items` (:250), `window_menus` (:253),
  `window_shortcuts` (:256), `menu_roles` (:261).
- The model: `collections` (:270), `coll_instances` (:271), `for_sites`
  (:272), `stamps` (:273), `when_sites` (:274).
- Widget structure: `widgets: HashMap<WidgetId, WidgetKind>` (:268),
  `template_nodes` (:269), `filled_scrolls` (:280), `select_options` (:284).

And DESIGN's claim is the strong one: "All state at rest is core-owned signals;
the guest is the transition function" (DESIGN.md:288-289, restated at :3290).

### 3.2 What core does NOT hold — backends hold it instead

**Uncontrolled widget state.** This is the doctrine, not an oversight:
"Interactive widgets are uncontrolled: the widget owns its state and reports
each USER change as an occurrence" (DESIGN.md:379-382). And: "Widget-owned
state never grows a read: an entry's text arrives as change occurrences the app
folds into its own model (the uncontrolled widget stays the authority; the app
keeps its draft), so nothing eventual ever sits on a read path"
(DESIGN.md:547-551). Every binding repeats it — bindings/swift/KayaApp.swift:725-727
("the widget owns its text … there is no read-back, by doctrine"),
bindings/go/app.go:2257-2258, bindings/python/kaya/__init__.py:1764.

So `Prop::Text` in core is **what the app SET**, never what the user typed. The
backends carry the live value: `KayaNode.text` (swift/KayaSwiftUI.swift:149),
`.checked` (:167), `.value` (:168). The clipboard scene depends on this
distinction — `expect entry#1 "pasted by hand"` at
tools/scenes/clipboard.steps:82 reads the WIDGET, and the whole point of
clipboard.steps:104-110 is that the platform inserted text core never saw.

**If the app folds every change into a collection, core's copy is complete. If
it does not, core is behind, legally.** The `menus` scene states the licence
outright: "The Rust depth guest deliberately does not write their bound signals
back: the native control owns user state" (tools/scenes/menus.steps:7-7), and
three lines later demands "The stateful controls must survive from the
backend's user-state mirror" (menus.steps:23-24). The Compose interpreter names
that mirror in so many words: "This model is also the backend's user-state
mirror: a user toggle/radio pick lands in checked/value here (and emits), the
guest deliberately may not echo it back, and an unrelated prop write must not
clobber it" (android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt:324-331; the
SwiftUI twin is `KayaMenuItemModel.checked`/`.value`,
swift/KayaSwiftUI.swift:237-239).

**Focus.** No field in `Scene` — `grep -n focus crates/kaya/src/scene.rs`
returns only the `CommandKind::Focus` check (scene.rs:381) and a comment. The
backends own it: `focused_widget_id()` in crates/kaya/src/gtk.rs:2016 (read at
:2173, :2181, :2243 — that is where the clipboard roles' enablement is
computed), `@FocusState` in swift/KayaSwiftUI.swift:6533 and :7256,
`kayaFocusedSemanticsNode` in KayaCompose.kt:2076-2090. `expect_focused` reads
the toolkit, per-window, never a model copy (harness.rs:511-514, :221-224).

**Scroll offset.** Not in core. `filled_scrolls` (scene.rs:280) records only
that a viewport already holds its one child. The backends hold the live
position: `kayaScrollProxies: [UInt64: ScrollViewProxy]` in
swift/KayaSwiftUI.swift:374-376 is how `scroll_end` drives the real API. DESIGN
lists scroll offset as a "present-state slot … Keep-latest" in the channel
taxonomy (DESIGN.md:2469-2474) — a channel that is **designed and not built**:
"Two are BUILT (`CommandKind`): `focus()` and `clear()`. `scrollTo()` is
designed and deferred" (DESIGN.md:2484-2486), and `CommandKind` in
crates/kaya/src/scene.rs:357-369 confirms it — exactly two variants.

**Window geometry after a user resize.** `SetWindowProp` carries `width`/
`height` as an ADVISORY request (protocol.rs:1125, and Python's docstring at
`bindings/python/kaya/__init__.py:2071-2071` says "request content size in DIP
(advisory)"). The `resize_window` verb drives "the window's REAL resize — the
path a user's drag takes, not a model write" (harness.rs:413-419), and
`expect_window_size` (harness.rs:280) reads it back from the platform. Nothing
folds a user resize into `Scene`.

**Selection inside a text control.** kaya has no selection API at all, stated
as the REASON the clipboard roles had to be commands: "kaya has no selection
API: only the widget knows what is selected, so 'copy the selection' cannot be
assembled by an app out of the data layer" (crates/kaya/src/scene.rs:491-494;
same at KayaCompose.kt:4592-4594).

### 3.3 What that means for the two features

For **undo**, the split is actually convenient rather than awkward: an undo
step is a rewind of the APP'S MODEL, which is core-owned by construction
(signals + collections), and the uncontrolled widget state is by doctrine *not*
app state. So a transaction-log undo does not have to reach into widget-owned
state — a re-applied inverse transaction lands the same way the original
forward transaction did, and the widgets follow their props. The two things
that break that clean story are (a) menu toggle/radio state, where the guest is
explicitly permitted not to echo (menus.steps:12-13) so core's copy can be
stale, and (b) any transaction whose ops are not invertible (§1.1).

For **session restoration** the split is the whole problem. "Serialize the core
scene" reconstructs the declared tree, the collections, and the signals — and
loses the entry the user was halfway through typing, where the caret was, what
was scrolled where, and which control had focus. Those are precisely the things
a user notices, and precisely the things kaya deliberately does not hold.
Getting them requires either:

- **building the present-state slots** DESIGN already specifies
  (DESIGN.md:2469-2474) — a keep-latest channel core to app, "the same slots
  double as the readable mirror" — which would give core a place to keep focus,
  scroll offset and uncontrolled values; or
- **a save-state occurrence with a deadline**, which is what DESIGN already
  says the iOS suspension lifecycle needs ("the platform-specific wrinkle is
  the suspension lifecycle ('save state now'), which falls into the
  occurrence-plus-deadline class", DESIGN.md:89), letting the app fold what it
  wants preserved into core state before the process dies.

The second is cheaper and stays inside the current ownership rule; the first is
a channel the design has been carrying unbuilt since the taxonomy was written.
Either way, **"serialize the core scene" as stated in docs/deferred.md:725-728
is a partial answer**, and the design pass should say so rather than inherit the
sentence.

One more asymmetry worth deciding: the protocol has ops that are declared
irreversible on purpose — menu items "never removed in v1"
(protocol.rs:1173-1174), sections "append-only … no destruction grammar"
(scene.rs:236-239), popped entries destroyed with ids never reused
(protocol.rs:1152-1153). A restored session has to rebuild all of that from
scratch (which is fine — it is a fresh process), but an UNDO cannot, which is
another argument for restricting undoability to the model ops rather than the
whole `TxOp` vocabulary.

---

## 4. Prior art notes already in the repo, and what the references point at

### 4.1 The whole in-repo record is one paragraph

`grep -rin undo` over DESIGN.md returns **nothing**. Over docs/ it returns
exactly six lines, five of which are roadmap references. The substantive entry
is **docs/deferred.md:719-733**, quoted in full because it is the entire prior
art:

> **Undo/redo and session restoration — core-owned, and cheap only here** (from
> the 2026-07-24 survey; TRIGGER SATISFIED by the text editor). Every other
> cross-platform framework bolts undo onto application state it does not own;
> macOS has `NSUndoManager` and the other three platforms have nothing
> portable. kaya owns all state at rest and every mutation already arrives as a
> transaction, so an undo stack is a log of objects core materializes anyway.
> The same machinery gives window/session restoration — serialize the core
> scene, not the app's state — which cmyr's ingredient list names and nobody
> enjoys writing. NOT free: the design pass has to answer which transactions
> are undoable, whether an undo re-runs handlers or simply applies the inverse
> transaction, and what happens to occurrences emitted during an undo. Do the
> design pass before any protocol work; the machinery being present is not the
> same as the semantics being obvious.

The three open questions it names are the design pass's agenda:
1. which transactions are undoable,
2. whether an undo re-runs handlers or applies the inverse transaction,
3. what happens to occurrences emitted during an undo.

Two supporting references, both roadmap:
- docs/deferred.md:14-31 — the text editor is the named forcing artifact
  (Akhil, 2026-07-24); "it forces undo/redo, which core can offer far more
  cheaply than any framework that does not own the state (see the undo note in
  this file)" (deferred.md:29-31).
- docs/deferred.md:33-40 — clipboard complete 2026-08-04; "Editor
  prerequisites remaining after this: undo/redo, dirty-state window titles,
  find."
- docs/deferred.md:69-71 — the dependency ordering: "the edit roles
  (cut/copy/paste) are inert without it, while undo/redo, find and dirty-state
  titles do not depend on it." So undo is **unblocked right now**.

### 4.2 The "2026-07-24 survey" is not a document

It has no file. It is a conversation whose output is the deferred entries
themselves: `git show 6793ba2 -- docs/deferred.md` (commit 6793ba2, "setup for
next phases", 2026-07-24 23:34) adds the text-editor paragraph, the undo/session
entry, and the system-integration floor entry in one hunk. The only doc in the
tree literally named a survey is docs/layout-survey.md, which is unrelated
(platform layout, drafted 2026-07-19, layout-survey.md:1-15). DESIGN.md:2859
cites "the 2026-07-24 survey" the same way, for the Table-vs-List reasoning.
**There is no survey document to go read** — the design pass starts from the
paragraph above.

### 4.3 "cmyr's ingredient list", identified

The reference is Colin Rofls (cmyr), ["So you want to write a GUI
framework"](https://www.cmyr.net/blog/gui-framework-ingredients.html),
2021-08-09 — a checklist of everything a desktop GUI framework has to supply,
written out of the druid/xi-editor work. Fetched 2026-08-04; the list covers
windowing, tabs, menus, 2D painting, animation, text rendering and editing,
compositor integration, web views, pointer/keyboard/IME/HID input,
accessibility, i18n, copy/paste, drag-and-drop, printing, asset packaging and
manifests, async, platform extensions, dark mode, and accent colours.

Two things worth knowing about the citation:

- **The item deferred.md means is "app resumption".** The post's wording is
  *"you're going to want to remember where the user's windows were, and put
  them back when you relaunch"*, with a note about monitor changes. So the
  ledger's claim — that the ingredient list "names" session restoration — is
  accurate.
- **The ingredient list does NOT name undo/redo.** Undo is not on it. So the
  citation supports the *restoration* half of docs/deferred.md:719-733 and
  nothing about the undo half. Worth not over-reading.

### 4.4 What the platforms actually give you (researched 2026-08-04)

The ledger's line "macOS has `NSUndoManager` and the other three platforms have
nothing portable" (deferred.md:722-723) holds, but the picture is more useful
in detail — several platforms have *text-control-scoped* undo that a kaya undo
design will collide with, because kaya's entries and textareas are
**uncontrolled** (§3.2) and therefore already carry the platform's own undo
stack.

| Platform | App-level undo | Control-level undo |
|---|---|---|
| macOS / iOS | `UndoManager`, reachable in SwiftUI as `@Environment(\.undoManager)`; explicit grouping via `beginUndoGrouping()`/`endUndoGrouping()` around `registerUndo(withTarget:)`, and a mismatched pair is a runtime crash | text controls get it through the same manager |
| Windows / WinUI 3 | nothing — no application undo manager in the Windows App SDK; apps roll their own (third-party controls re-implement `BeginActionGroup`/`EndActionGroup`) | `TextBox.Undo()` / `.Redo()` on the control |
| Linux / GTK4 | nothing | `GtkTextBuffer` has real undo: `gtk_text_buffer_undo()` / `_redo()`, gated by the `enable-undo` property with `max-undo-levels` |
| Android / Compose | `android.content.UndoManager` exists in the framework but is not public API | `TextFieldState.undoState` — `undo()`, `redo()`, `canUndo`, `canRedo`, `clearHistory()`; as of Compose Foundation 1.9.0-rc01 (2025-07-30) `TextFieldState.edit {}` no longer clears the undo history but creates a standalone entry |

**The consequence for the design pass.** Three of four platforms already run an
undo stack inside every text control, and kaya does not own what is in it —
that is the uncontrolled-widget doctrine (DESIGN.md:379-382, :547-551). A
core-owned undo stack therefore has to answer what happens when the user
presses the undo chord while a text field has focus: does kaya's stack rewind
the model, or does the field rewind its own keystrokes? The clipboard roles
answered the sibling question by handing behaviour to the platform and acting
on the FOCUSED widget (DESIGN.md:1815-1820) — an undo role that did the same
thing would rewind keystrokes and never touch the model, which is almost
certainly not what "core-owned undo" means. This is the single sharpest
unresolved question the recon turned up, and it is not in the ledger's list of
three.

Session restoration, same treatment:

- **macOS**: `NSWindow.isRestorable` plus `encodeRestorableState`/
  `restoreState`, with AppKit restoring which window was minimized, frontmost
  or full screen. Real, and free if you opt in.
- **iOS**: scene-session state restoration through `NSUserActivity` /
  `stateRestorationActivity`.
- **Android**: the platform expects `onSaveInstanceState` /
  `rememberSaveable`, and it is not optional — process death is routine.
- **Windows**: nothing automatic.
- **Linux/Wayland**: historically nothing (X11's XSMP did not survive the
  transition). The new `xdg-session-management` protocol is exactly this, and
  it landed recently: merged in Mutter (disabled by default, targeting GNOME
  48) and in KWin for Plasma 6.4 (June 2025). So "Linux has nothing portable"
  is going stale — worth re-checking at design time rather than inheriting.

That divergence is an argument for kaya doing restoration itself out of the
core scene, which is what deferred.md:725-728 proposes — subject to §3.3's
finding that the core scene is not the whole of what a user would notice.

---

## Summary of the gaps this recon found

1. **The wire carries no before-images** and several ops have no inverse
   (protocol.rs:1115-1252). An undo design must either add them, compute them
   in core from the scene, or restrict undoability to a subset of `TxOp`.
2. **A transaction has no header** (`Vec<TxOp>`, protocol.rs:1256), so
   per-transaction undo metadata has nowhere to live without a protocol shape
   decision.
3. **C# and Swift journal signals; the other six bindings journal collections
   only** (KayaApp.cs:763, KayaApp.swift:1274). Either an abort-semantics
   divergence hiding under a green check-abort, or dead precision — settle it
   before building on the journals.
4. **`MENU_ROLES` has no `undo`/`redo`** (scene.rs:522), and the existing roles'
   semantics ("acts on the FOCUSED widget", DESIGN.md:1817) do not obviously
   transfer to a model-level undo.
5. **No `undo` verb, and no way to read a menu item's LABEL** in the harness
   (47 verbs, harness.rs parse; `MenuState` axes only, harness.rs:358).
6. **Core holds no focus, no scroll offset, no user-typed entry text, no
   post-resize window geometry, and no selection** — all by doctrine
   (DESIGN.md:379-382, :547-551, :2469-2486; scene.rs:215-288 has none of
   them). "Serialize the core scene" is a partial answer for session
   restoration.
7. **Three of four platforms already run a text-control undo stack kaya does
   not own**, which the ledger's three open questions do not mention.
