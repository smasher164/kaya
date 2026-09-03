# undo-recon-core — the CORE architecture an undo stack would live in

Reconnaissance only; nothing was changed or run. Every claim carries
`file:line`. Paths are repo-relative to `/Users/akhilindurti/Projects/kaya`.

---

## 0. The one-paragraph answer

A committed transaction at rest is `Vec<TxOp>` (`crates/kaya/src/protocol.rs:1209`)
— a *forward* delta with no before-image anywhere in it. The core
(`crates/kaya/src/scene.rs:201`) holds current state for **signals**
(`scene.rs:216`) and for **collection entries** (`scene.rs:271`,
`CollInstance` at `scene.rs:143`), and for **structure** (widget kinds, nav
stacks, section sets, menu trees). It holds **no value at all** for a widget
property set from a constant: `TxOp::SetProperty` is validated, converted to
`ApplyOp::SetProp`, and forgotten (`scene.rs:901-976`). So the core can derive
an inverse for the *reactive* half of the protocol (signal writes, collection
deltas) and cannot for the *imperative* half (const prop sets, creates,
destroys, mounts, window/nav/section/menu structure, commands, dialogs,
clipboard). That asymmetry is the design decision the pass has to make, and it
is not accidental — DESIGN.md's "All state at rest is core-owned signals"
(`DESIGN.md:290-291`) is exactly the claim that *would* make undo cheap, and
the const-prop path is the place it is not true today.

---

## 1. Transaction lifecycle, end to end

### 1a. Built (guest side, Rust binding as the reference)

- `AppCtx::begin` mints a `Tx` — `crates/kaya/src/app.rs:529-537`. Fields:
  `ops: Vec<TxOp>`, `journal`, `pending_derived`, `parents`, `committed`
  (`app.rs:799-816`).
- `AppCtx::apply(body)` is the closure-scoped form: begin, run, commit
  (`app.rs:569-574`). Its doc states the abort rule: "A panic inside the body
  abandons the transaction before the unwind continues: commit is never
  reached, and Tx's Drop rolls the model mirrors back" (`app.rs:565-568`).
- Every builder method pushes a `TxOp` onto `self.ops`: `tx.signal`
  (`app.rs:1016`), `tx.write` (`app.rs:1025`), `tx.widget` (`app.rs:1032`),
  `tx.set` (`app.rs:1055`), `tx.insert` (`app.rs:1581`), `tx.update_field`
  (`app.rs:1626`), `tx.remove` (`app.rs:1849`), and so on.
- `Tx` is `!Send` by construction (it borrows the `Cell`/`RefCell`-holding
  `AppCtx`), pinned by a `compile_fail` doctest at `app.rs:781-784`. The
  narrative at `app.rs:775-779` says nobody designed this and the other
  bindings police the same rule at runtime.

### 1b. Committed

- `Tx::commit` — `app.rs:2090-2106`. Three steps: promote `pending_derived`
  into the app registry, set `committed = true`, `mem::take(&mut self.ops)`,
  `self.ctx.transactions.send(ops)`, then `crate::backend::ring_doorbell()`.
  The comment is load-bearing for undo: "The model edits stand: they are
  exactly what was sent" (`app.rs:2088-2089`).
- The C floor's equivalent is `kaya_submit(records, len)` —
  `crates/kaya/src/capi.rs:908-923`. It decodes the byte buffer into a
  `Transaction` (`wire::decode_transaction_with_blobs`), resolving blob
  handles against the pending registration table, which **drains at this
  boundary whether referenced or not** (`capi.rs:787-792`, `capi.rs:941-946`),
  then sends on the same channel and rings the doorbell.
- Decoding lives in `crates/kaya/src/wire.rs:497` (`decode_transaction`) and
  `wire.rs:518` (`decode_transaction_with_blobs`).

### 1c. Applied (core side)

**Precision worth having before designing a log: the transaction direction is
NOT a ring.** DESIGN describes both directions as SPSC logs
(`DESIGN.md:2414-2418`), but as shipped only occurrences use `OccRing`
(`ring.rs:94`); transactions travel on a plain `std::sync::mpsc` channel —
`Sender<Transaction>` at `app.rs:455` and `capi.rs:709`, `Receiver` handed out
by `take_core_ends` (`capi.rs:765-767`) — with a doorbell to wake the UI loop
(`gtk.rs:608-613`). So a transaction is an owned `Vec<TxOp>` in process memory
by the time the core sees it, not bytes in a shared arena. An undo log at the
core is therefore ordinary heap, and nothing about the ring's fixed capacity
(`ring.rs:175`, growth unbuilt) constrains it.

Two drains, one `Scene`:

- **Interpreter platforms (SwiftUI, Compose)** — `kaya_next_commands`,
  `capi.rs:2011-2046`. The interpreters reach it indirectly: SwiftUI through a
  vtable field `next_commands` (`swiftui_host.rs:126`, wired at `:237`, called
  from `KayaSwiftUI.swift:2133-2154`), Compose through the JNI export
  `nextCommands` (`android.rs:104,210`, called at `KayaCompose.kt:715`). Blocks on `recv()` for one transaction
  (`capi.rs:2023`), calls `scene.apply(tx)` (`capi.rs:2027`), encodes the
  resulting `Vec<ApplyOp>` with `wire::Writer` (`capi.rs:2028-2031`),
  publishes the batch-local blob out-table (`capi.rs:2037`), and memcpys the
  records into the pump's buffer. The `Scene` is a process singleton at
  `capi.rs:1109` (`PRESENTATION_SCENE`), created lazily at `capi.rs:2021`.
- **Rust-native backends (GTK, WinUI)** — `gtk.rs:615-624`
  (`drain_transactions`): `while let Ok(tx) = core.transactions.try_recv() {
  for op in core.scene.apply(tx) { apply(core, op) } }`. The doorbell is a
  `glib::idle_add` (`gtk.rs:608-613`). The `Scene` lives inside `CoreState`
  (`gtk.rs:4043`).
- The core entry is `Scene::apply(&mut self, tx: Transaction) -> Vec<ApplyOp>`
  — `scene.rs:841`. Its contract paragraph is `scene.rs:832-840`: construction
  ops in submission order; signal writes coalesce (last write wins per signal
  per batch) and flush **at the end** as targeted property sets and When
  toggles; collection deltas apply in place, in order, never coalesced.

### 1d. What `apply` does per op class (the ones undo cares about)

| Op | Core state touched | Before-state retained? |
|---|---|---|
| `CreateSignal` | `signals.insert` — `scene.rs:862-865` | n/a (creation) |
| `WriteSignal` | `signals` replace; `old` captured into `rollback` map — `scene.rs:866-879` | **yes, batch-scoped only** |
| `CreateWidget` | `widgets.insert(id, kind)` — `scene.rs:880-900` | kind only, never props |
| `SetProperty(Const)` | validate, emit `ApplyOp::SetProp` — `scene.rs:901-936` | **NO** — value is not stored |
| `SetProperty(Signal)` | records `bindings[signal] += (widget, prop)`, emits current value — `scene.rs:937-971` | value lives in the signal |
| `SetWindowProp` | same shape; `window_bindings` — `scene.rs:977-1020` | **NO** for const |
| `CreateWindow`/`DestroyWindow` | `windows` set; destroy sweeps nav stacks, sections, catalog anchors — `scene.rs:1021-1089` | structure only |
| `CollectionInsert/Update/UpdateField/Remove/Move` | `coll_instances` — `insert_entry` `scene.rs:2532`, `update_entry` `scene.rs:2555`, `update_field_entry` `scene.rs:2646`, `remove_entry` `scene.rs:2693`, `move_entry` `scene.rs:2716` | **yes, the entry table IS the state** |
| `WidgetCommand` | nothing — "Momentary by construction: nothing is recorded, so nothing replays on rebuild" — `scene.rs:1619-1629` | **NO, by doctrine** |
| `ShowAlert` / `ShowFileDialog` | process-global liveness slot in capi — `scene.rs:1120`, `scene.rs:1142` | n/a |
| `SetMenuProp` | shortcut table, role table, item.role — `scene.rs:2002-2056`; `claim_menu_role` `scene.rs:1983-2000` | shortcut + role only |

The end-of-batch flush is `scene.rs:1662-1712`: for each dirtied signal, fan
out to `bindings`, `window_bindings`, `section_bindings`, `entry_bindings`,
`menu_bindings`, then `toggle_whens`.

### 1e. What a committed transaction contains at rest

`pub type Transaction = Vec<TxOp>` — `protocol.rs:1256`. The variants are
`protocol.rs:1115-1252`. On the wire it is the framed record stream: header
`{u32 size, u16 kind, u16 flags}`, 8-aligned, fields drawn from
`{U32, U64, Value, Values, VariantSchemas}` (`spec.rs:29-45`), record table at
`spec.rs:356-861` (36 tx kinds, pinned against `wire.rs` constants by
`spec.rs:1711-1754`). The record kinds' numeric ids are `wire.rs:27`ff.

Two facts that matter for an undo log:

1. **Blob payloads never enter the record stream.** A `Value::Blob` rides as a
   u64 registration handle (`spec.rs:1679-1685`, `capi.rs:814-819`), and the
   handle is **consumed by the next submit whether referenced or not**
   (`capi.rs:787-792`). Bytes live once, refcounted, reachable only through
   whatever scene state holds an `Arc` clone (`protocol.rs:516-525`,
   `DESIGN.md:2436-2453`). So a transaction *replayed from its bytes* cannot
   resolve its blobs a second time; a transaction *retained as `Vec<TxOp>`*
   can, because `Value::Blob` holds the `Arc`.
2. **`Vec<TxOp>` is `Debug` but not `Clone`** (`protocol.rs:1114`); `ApplyOp`
   is `Debug + PartialEq` (`protocol.rs:1265`). Retaining a log means deriving
   `Clone` or moving to a stored-bytes form.

---

## 2. Is an INVERSE derivable at apply time?

### 2a. What the core sees the before-state of

**Signals — yes, and the machinery already exists.** `apply` builds a
`rollback: HashMap<SignalId, Value>` capturing each signal's pre-transaction
value on its first write in the batch (`scene.rs:845-851`, populated at
`scene.rs:873-878`). It is used at `scene.rs:1648-1660` to restore every
touched signal before propagating a menu-domain panic. **This is a
per-transaction inverse of the signal half, computed today, and thrown away at
the end of `apply`.** Widening its lifetime is the single cheapest structural
move toward undo in the whole codebase.

**Collection entries — yes.** `CollInstance { order: Vec<Key>, entries:
HashMap<Key, (u32, Record)> }` (`scene.rs:143-150`) is the authoritative
table. Every delta reads it before writing:
- `update_entry` reads the current `(variant, record)` — `scene.rs:2555`.
- `update_field_entry` asserts the witnessed variant against the stored one —
  `scene.rs:2646`, and the doctrine at `protocol.rs:1209-1223`.
- `remove_entry` has the entry in hand before deleting — `scene.rs:2693`.
- `move_entry` has `order` before repositioning — `scene.rs:2716`.
An inverse is mechanical for all five delta ops.

### 2b. What is NOT invertible from what the core holds

Ranked by how hard each is to fix.

1. **Constant property sets — the big one.** `SetProperty { value:
   PropValue::Const(v) }` is checked (`check_prop` `scene.rs:298`,
   `check_prop_value`) and forwarded as `ApplyOp::SetProp` (`scene.rs:931-936`).
   The `Scene` struct has no prop-value map at all — look at its fields,
   `scene.rs:215-288`: `widgets: HashMap<WidgetId, WidgetKind>` and nothing
   else per widget. Same for `SetWindowProp` (`scene.rs:988-996`),
   `SetEntryProp`, `SetSectionProp`, and `SetMenuProp`
   (`scene.rs:2016-2033` — only `shortcut` and `role` are retained,
   `scene.rs:1974`, `scene.rs:1998-1999`).
   There is also **no read-back from the backend by doctrine**: "There are no
   widget mirror reads" (`DESIGN.md:261-264`), and the harness reads the a11y
   tree rather than any model. So the core cannot recover a prior const value
   from anywhere.
   *The clean exit is doctrinal, not mechanical:* DESIGN already says every
   display value should be a signal (`DESIGN.md:284-291`). If undo is defined
   over the reactive surface only, const sets are construction-time and never
   need inverting. That is a decision the pass must make explicitly.

2. **Creates and destroys.** `ApplyOp::Create` (`protocol.rs:1271`) carries the
   click tag; `Destroy` (`protocol.rs:1329`) is emitted children-first by the
   core so backends never walk. But *undoing a destroy* means re-creating with
   the same id, and **ids are never reused by contract** —
   `spec.rs:578-585` (`destroy_window`: "widget ids are never reused, so stale
   entries are inert"), `spec.rs:630-638` (`pop_entry`: "ids are never reused,
   so stale targets fail loudly"), `scene.rs:886` (`id already exists` is a
   panic), `scene.rs:1046`, `scene.rs:1573`. An undo cannot resurrect a widget
   under its old id without breaking that invariant, and the guest holds the
   old id in its handler tables. Note the live zone rarely destroys — the
   protocol has **no `remove_child`** (`scene.rs:282-284`) — so live-zone
   teardown only happens via `destroy_window` / `pop_entry`. Stamped copies
   are destroyed by the core itself (`teardown`, `scene.rs:2990`) as a
   *consequence* of a collection delta, which means undoing the delta already
   restamps: `Stamp` (`scene.rs:173-185`) is exactly the "what this copy put
   into the world" record, and `reposition_restamp` (`scene.rs:2603`) already
   does teardown-then-restamp in place.

   Same asymmetry for ORDER: `ApplyOp::MoveChild` (`protocol.rs:1325`) has no
   tx-level counterpart for live widgets — its only two producers are
   `reposition_restamp` (`scene.rs:2632`) and `move_entry` (`scene.rs:2771`),
   both driven by collection deltas. So live-zone child order is set once at
   `add_child` and is not addressable afterwards, forward or backward; stamped
   order is fully invertible because `CollInstance::order` (`scene.rs:144`)
   holds it.

3. **Blob payloads.** Registration handles die at the submit boundary
   (`capi.rs:787-792`). A signal or collection record holding
   `Value::Blob(Arc<[u8]>)` keeps the bytes alive by refcount
   (`DESIGN.md:2443-2448`), so a retained `Vec<TxOp>` undo log **keeps blobs
   alive as long as the log lives** — a memory-growth consequence to state,
   not a correctness one. A byte-replay log cannot re-resolve them at all.

4. **Focus.** `WidgetCommand { command: Focus }` (`protocol.rs:1088-1094`,
   `CommandKind::Focus`) is momentary: `scene.rs:1625-1628` says "nothing is
   recorded, so nothing replays on rebuild". The core does **not** know what
   is focused — the *backends* do, independently: `gtk.rs:2170-2179`
   (`focused_widget_id`), `winui/mod.rs:3453-3456` (`focused_editable_id`),
   `swift/KayaSwiftUI.swift:5155` (`kayaScene.focusedId`),
   `KayaCompose.kt:1962`. So restoring focus across an undo is a *new*
   core↔backend read that does not exist today.

5. **`clear`.** `CommandKind::Clear` is not invertible in principle: the widget
   owns its text (`DESIGN.md:261-264`), and the core never held it. Undoing a
   clear means the app writing the text back — which it can only do if it kept
   it, which is exactly the model-ownership rule.

6. **Window / nav / section / menu ops.** `CreateWindow`/`DestroyWindow` are
   the id-reuse problem above. `PushEntry`/`PopEntry` have core-owned stacks
   (`nav_stacks`, `scene.rs:233`) so the *stack* is invertible, but the popped
   entry's mounted tree is forgotten (`spec.rs:630-638`). `AddSection` is
   **append-only by design — the grammar has no destruction verb**
   (`scene.rs:236-240`, `spec.rs:655-666`), so `add_section` has no inverse
   expressible in the protocol. Menu items are likewise "live, append-only,
   and never removed in v1" (`protocol.rs:1171-1174`, `scene.rs:248-250`).

7. **Dialogs and clipboard.** `ShowAlert`, `ShowFileDialog`, `ReadClipboard`,
   and `Copy` are requests to the outside world. `Copy` mutates the *system*
   clipboard (`protocol.rs:1140-1141`); an undo of it would have to restore the
   previous clipboard contents, which no platform reliably offers. These are
   the clear "not undoable" class.

### 2c. Where an inverse would be computed

`Scene::apply` is the only place that sees both the transaction and the
pre-state, on the app-owning thread, atomically per batch (`scene.rs:841`).
Its existing `rollback` map (`scene.rs:851`) is the prototype. Everything
downstream (`ApplyOp`) is post-resolution and carries no before-image.

---

## 3. The occurrence channel

### 3a. Every kind, and who emits

Spec table: `spec.rs:1171-1427`. Wire constants: `ring.rs:21-47`. Rust enum:
`protocol.rs:412-514`. Ring encoder: `protocol.rs:1355-1470`.

| # | Kind | Emitter | Class |
|---|---|---|---|
| 1 | `button_clicked` (`spec.rs:1174`) | backend on user click | external |
| 2 | `text_changed` (`spec.rs:1187`) | backend on user edit **and on `clear`** | external + **consequence of a command** |
| 3 | `toggled` (`spec.rs:1202`) | backend, user only | external |
| 4 | `value_changed` (`spec.rs:1215`) | backend, user only | external |
| 5 | `close_requested` (`spec.rs:1231`) | chrome close on a `veto_close` window | external (veto) |
| 6 | `window_closed` (`spec.rs:1241`) | chrome close, non-veto | external (post-fact) |
| 7 | `alert_result` (`spec.rs:1250`) | presentation, answering `show_alert` | **consequence of an app request** |
| 8 | `entry_popped` (`spec.rs:1265`) | native back gesture | external (post-fact) |
| 9 | `back_requested` (`spec.rs:1276`) | back with `intercept_back` armed | external (veto) |
| 10 | `section_selected` (`spec.rs:1287`) | user switcher only | external |
| 11 | `menu_activated` (`spec.rs:1299`) | click **or shortcut**, one path | external |
| 12 | `menu_toggled` (`spec.rs:1314`) | user only | external |
| 13 | `menu_value_changed` (`spec.rs:1329`) | user only | external |
| 14 | `file_dialog_result` (`spec.rs:1343`) | presentation, answering `show_file_dialog` | **consequence of an app request** |
| 15 | `clipboard_result` (`spec.rs:1368`) | presentation, answering `read_clipboard` | **consequence of an app request** |
| 16 | `pasted` (`spec.rs:1393`) | user paste gesture at an accepting widget | external |
| — | `Shutdown` (`protocol.rs:511-513`) | core teardown. No ring record exists for it; the C floor signals it out of band as the return code `KAYA_OCCURRENCE_SHUTDOWN = 0` (`capi.rs:953`) | lifecycle |

C-ABI emit entries (interpreter backends call these):
`capi.rs:1133` close_requested, `1148` window_closed, `1192` entry_popped,
`1215` section_selected, `1242` back_requested, `1654` file_dialog_result,
`1752` clipboard_result, `1792` pasted, `1843` alert_result, `1859` clicked,
`1874` toggled, `1891` value_changed, `1908` text_changed, `1955`
menu_activated, `1968` menu_toggled, `1989` menu_value_changed.
Rust-native backends push through `OccSink::send` instead —
`gtk.rs:683,689,745,754,1003,3291,3362,3453,5732` and
`winui/mod.rs:1106,1115,1396,2337,4357,4510,7372`.

### 3b. The echo doctrine — the rule an undo design must reckon with

Stated repeatedly and uniformly: **a programmatic write never echoes; only the
user's act emits.**
- `text_changed`: "USER edits and commands (clear acts like the user) emit; a
  property write is configuration and never echoes" — `spec.rs:1196-1198`.
- `value_changed`: "programmatic writes never echo — without that, a handler
  writing back a different value would ping-pong forever" —
  `spec.rs:1225-1228`.
- `select_section`: "configuration, not a user act — it never echoes
  section_selected" — `spec.rs:672-675`; enforced by the *quiet*
  `ApplyOp::SelectSection` (`spec.rs:1026-1028`).
- `pop_entry`: "A programmatic pop_entry does not echo here: its caller already
  knows" — `spec.rs:1272-1274`.
- `menu_toggled`: "a programmatic `checked` write is configuration and never
  echoes" — `spec.rs:1324-1326`.

**Consequence for the design question.** If an undo is applied as an inverse
*transaction*, the echo doctrine says it emits **nothing** — it is
programmatic by construction, and every occurrence in the table above is either
a user act or the answer to a request. The two exceptions to check:
1. `WidgetCommand::Clear` **does** emit `text_changed` (`spec.rs:1196-1198`,
   `protocol.rs:1330-1336`). An inverse that contains a command emits.
2. `show_alert` / `show_file_dialog` / `read_clipboard` each emit exactly one
   result, and the id **retires on it** (`spec.rs:609-611`, `spec.rs:1366`,
   `spec.rs:1386-1391`). Replaying one of those forward would re-present a
   dialog; replaying one *backwards* has no meaning at all. Liveness is
   process-global and lives in capi (`scene.rs:1115-1120`, `scene.rs:1138-1142`).

So: **an inverse-transaction undo is silent under today's doctrine**, provided
the undoable set excludes commands and requests. An undo that *re-runs
handlers* would replay user-shaped occurrences and immediately break the echo
doctrine — the app would see `button_clicked` for a click nobody made.

### 3c. Transport

The ring is `ring.rs:94-111` (SPSC, io_uring-shaped, `head`/`tail` cursors,
`REC_PAD` for wrap). Producer `push_record` (`ring.rs:167-177`) panics when
full — segment growth is unbuilt (`ring.rs:14-15`, `ring.rs:175`). The Rust
API's parallel path is an mpsc `Inbox` (`protocol.rs:405-408`) with `Woken` for
posted work.

---

## 4. Handlers and transactions — the adjacent, already-built machinery

### 4a. A handler IS a transaction

`DESIGN.md:2417-2421`: "A handler is a transaction: the binding runtime wraps
each dispatched occurrence batch in an implicit transaction committed when the
handler returns, so handlers are atomic without any effort from the author.
Explicit transactions exist only for writes outside handlers, such as timers
and background completions."

Enforced by `tools/check-ambient-tx.py` (CLAUDE.md:185-188): no guest may open
its own transaction inside a handler — one that does is camouflage, and it hid
a real Python defect for months.

### 4b. The ambient/handle split

`tools/check-tx-liveness.py:10-10` states the rule and the split verbatim:

- **HANDLE bindings** hand the guest a transaction object, so a stale one can be
  recognised and refused. **Rust at compile time** (`Tx` is `!Send`/`!Sync`,
  `app.rs:781-784`); **Go, Java, C#, Swift** check a `closed` flag at *one*
  chokepoint every write goes through — `bindings/go/app.go` `Tx.emit`/`Tx.alive`
  (gate at `check-tx-liveness.py:69-72`), `bindings/java/dev/kaya/KayaApp.java`
  private `emit` with **exactly one** `records.add(` (`:75-79`),
  `bindings/csharp/KayaApp.cs` `internal List<byte[]> Records` property with
  exactly two raw-field uses (`:84-91`), `bindings/swift/KayaApp.swift`
  `var tx: KayaTx {` with exactly two `storage.` uses (`:93-97`).
- **AMBIENT bindings** keep the open transaction in a global, so there is no
  handle to invalidate; they check the **thread** at build entry instead —
  Python `_require_app_thread` (`:101-102`), OCaml `require_app_thread`
  (`:103-109`, counted ≥2 so the definition isn't mistaken for the call),
  Haskell `requireAppThread` (`:110-115`, counted ≥3).
- **The C floor has neither**: caller-owned buffers, nothing to outlive
  (`:47-48`).

The failure this guards is silent — a write through an already-submitted
transaction vanishes with no error (`:23-30`).

### 4c. Rollback-on-abort — what already exists, and what it proves

**The doctrine** — `DESIGN.md:669-683`: "One abort semantics in every binding,
idiom deciding only the spelling: a handler abort at the transaction boundary
restores the binding's model and signal mirrors from a journal (or by purity,
where the transaction is pure state), ships nothing — commands and
derived-signal registrations dying with the record buffer — and propagates;
the binding-owned dispatch loop then catches, logs, and goes on to the next
occurrence, so one buggy handler never takes the app down." Rust is the one
structural exception (its binding owns no dispatch loop), so "the tx boundary's
Drop-rollback is where its uniformity lives".

**Rust's implementation** — `app.rs:818-827`:
```rust
impl Drop for Tx<'_> {
    fn drop(&mut self) {
        if !self.committed {
            let mut model = self.ctx.model.borrow_mut();
            for (id, snapshot) in self.journal.drain(..).rev() {
                model.insert(id, snapshot);
            }
        }
    }
}
```
The journal is declared at `app.rs:802-804` ("How to undo this transaction's
model edits: a snapshot per touched collection, taken on first touch") and
filled by `Tx::touch` (`app.rs:830-841`) — a whole-collection clone on first
mutation, taken by `model_set` (`app.rs:851`), `model_set_field`
(`app.rs:881`), `model_remove` (`app.rs:925`), `purge_children` (`app.rs:951`).

**The other bindings' journals**, all with the same comment:
`bindings/go/app.go:150`, `bindings/java/dev/kaya/KayaApp.java:1386`,
`bindings/swift/KayaApp.swift:1167`, `bindings/csharp/KayaApp.cs:699`,
`bindings/python/kaya/__init__.py:97` (`_journal`), with `_journal_once`
at `:142-151` and per-object restores at `:188`, `:283`, `:307`, `:578`,
`:604`, `:900`; run-or-clear at `:2219-2244`; dispatch at `:2443-2462` and
`:2510+`.

**The core's own rollback** — `scene.rs:845-851` and `scene.rs:1648-1660`: the
menu-domain barrier restores every signal the batch wrote before propagating
the panic, so a caught panic never leaves partially-applied signal state.

**The gate** — `tools/check-abort.py`: every binding carries the same negative
test (abort mid-handler → mirror restored, nothing shipped, next dispatch
works), run for Go, Swift, C#, Java, OCaml, Haskell; Rust's pin is in
`cargo test -p kaya`, Python's in `kaya_app_checks.py`, C has no mirror.

**What this proves for undo.** Three things, precisely:
1. Snapshot-and-restore *of the guest-side model mirror* is already
   implemented uniformly in eight languages, with a gate. The shape of "undo
   one transaction's model edits" is not new work at the binding tier.
2. But it is a **whole-collection snapshot on first touch** (`app.rs:830-841`),
   not a delta. It is right for abort (one transaction, discarded immediately)
   and wrong for a stack (N snapshots of the whole model).
3. And it only covers the **guest mirror**, never the core. Rollback today
   works because *nothing was shipped* — `commit` was never reached, so the
   core never saw the ops (`app.rs:2090-2106`). Undo is the opposite case: the
   core *did* see them. The abort machinery therefore proves the ergonomics
   and proves nothing about applying an inverse to a live scene.

---

## 5. DESIGN.md and docs/deferred.md

### 5a. DESIGN.md sections to read before the pass

- **Core object model** — `DESIGN.md:99-125`. The core owns a retained tree of
  widget records; ids are guest-allocated monotone u64, **never reused**
  (`:113-117`); removal must cascade, "This bookkeeping, not the choice of
  arena, is where leak and double-free bugs live" (`:118-122`).
- **The reactive surface** — `DESIGN.md:186-310`. The claim undo depends on:
  "**All state at rest is core-owned signals; the guest is the transition
  function; bare guest values exist only in flight between being computed and
  being written**" (`:290-291`). Also "There are no widget mirror reads:
  widget-owned state (an entry's text) reaches the app as occurrences it folds
  into its own model, so the model stays the single source and nothing eventual
  sits on a read path" (`:261-264`).
- **Structural operators** — `:199-224`: `When` controls existence, `For`
  holds the keyed-reconciliation kernel. `When` is `For` over a zero-or-one
  collection (`:244-249`).
- **Binding conventions** — `DESIGN.md:331-684`, in particular the record-time
  mirror-read guard (`:639-668`) and the abort semantics (`:669-683`).
- **Threading model and protocol** — `DESIGN.md:2312-2453`: one UI thread; a
  handler is a transaction (`:2417-2421`); begin/end markers applied atomically
  at a frame boundary so there are no torn multi-signal states (`:2416-2417`);
  the blob arena and its refcount reclamation (`:2436-2453`).
- **Traffic taxonomy** — `DESIGN.md:2459-2502`.
- **Serialization**: templates have a "serialized form" (`:255-258`,
  `:272-280`) — the prebuilt-buffer path, which is the same currency session
  restoration would use.
- There is **no undo section in DESIGN.md**, and no session-restoration
  section. A repo-wide grep finds undo/redo only in `docs/deferred.md`, the
  binding journals' comments, `winui/bindings.rs` (generated Windows API
  surface: `RichEditBox.Undo`/`Redo`/`CanUndo`/`ClearUndoRedoHistory` at
  `winui/bindings.rs:48198-48407`, `107776-108093` — a *widget-local* undo the
  platform gives free, worth noting as a conflict surface), and the `confirm`
  scene's alert text "this cannot be undone".

### 5b. docs/deferred.md — the undo note, verbatim context

`docs/deferred.md:719-733`:

> **Undo/redo and session restoration — core-owned, and cheap only here**
> (from the 2026-07-24 survey; TRIGGER SATISFIED by the text editor). Every
> other cross-platform framework bolts undo onto application state it does not
> own; macOS has `NSUndoManager` and the other three platforms have nothing
> portable. kaya owns all state at rest and every mutation already arrives as a
> transaction, so an undo stack is a log of objects core materializes anyway.
> The same machinery gives window/session restoration — serialize the core
> scene, not the app's state — which cmyr's ingredient list names and nobody
> enjoys writing. NOT free: the design pass has to answer which transactions
> are undoable, whether an undo re-runs handlers or simply applies the inverse
> transaction, and what happens to occurrences emitted during an undo. Do the
> design pass before any protocol work; the machinery being present is not the
> same as the semantics being obvious.

Coupling notes elsewhere in the same file:
- `docs/deferred.md:22`: undo/redo is listed with cut/copy/paste as an
  editor prerequisite.
- `:29-31`: a design choice "forces undo/redo … own the state (see the undo
  note in this file)".
- `:39`: "Editor prerequisites remaining after this: undo/redo, …".
- `:71`: "while undo/redo, find and dirty-state titles do not depend on it" —
  i.e. undo is **not** blocked by the named-addressing work.
- `:743-746`: clipboard was "the unblocker for the deferred cut/copy/paste
  roles" — which have now landed, so the editor prerequisite list has shortened
  to undo/redo plus find and dirty-state titles.

**Session restoration** is named only here and inherits the same machinery
claim. The concrete asset is that `Scene` (`scene.rs:215-288`) is the whole
serializable state — signals, collections, structure, menus — and the
`Vec<TxOp>` stream that produced it is already the canonical serialized form
(`DESIGN.md:272-280`). The two live obstacles are the same as undo's: blob
handles die at the submit boundary (`capi.rs:787-792`) so a serialized scene
must carry bytes or re-register them, and const prop values are not in the
scene at all (§2b.1) so a serialized scene cannot round-trip a scene built the
const way.

---

## 6. Menu roles — the surface Undo/Redo would ride

Cut/Copy/Paste landed as roles on 2026-08-02 (`DESIGN.md:1924`, Clipboard
ratified). Undo/Redo would be two more entries in the same closed vocabulary.

### 6a. Spec and core

- The prop: `("role", 8, PropKind::Str)` in `MENU_PROPS` (`spec.rs:278`) and
  the `mprop` enum (`spec.rs:1540`), pinned to `wire::MPROP_ROLE`
  (`spec.rs:1940`). Rust enum member `MenuProp::Role` at `protocol.rs:835`
  with its doc at `:831-834`.
- **The closed vocabulary is one line**: `pub(crate) const MENU_ROLES: &[&str]
  = &["settings", "cut", "copy", "paste"];` — `scene.rs:522`. Validated by
  `check_menu_role` (`scene.rs:524-533`), which names the whole set in its
  error.
- Its doc comment (`scene.rs:506-521`) is the argument an Undo role would
  reuse: a role is the only thing that can move an authored item into
  dress-owned chrome or hand its behaviour to the platform; cut/copy/paste
  "exist because kaya has no selection API: only the widget knows what is
  selected". **Undo has the same shape for text widgets** and a *different*
  shape for app-level undo, which is the tension the design pass owns.
- Kind scoping: `MenuProp::Primary | MenuProp::Role => matches!(kind,
  MenuItemKind::Action)` — `scene.rs:500`. Type: `Str` —
  `scene.rs:539`. Const-only (rejects signal sources) — `scene.rs:2034-2039`.
- Claim rule: one item per role, app-wide, window-anchored only —
  `claim_menu_role` `scene.rs:1983-2000`; table `menu_roles: HashMap<String,
  MenuItemId>` at `scene.rs:257-261`; per-item copy `role: Option<String>` at
  `scene.rs:208-211` so a subtree walk can reject a role landing under a
  context anchor (`scene.rs:1839-1843`).
- Applied as `ApplyOp::SetMenuProp { item, prop: Role, value: Str }` —
  `scene.rs:2032`, spec record `spec.rs:1092-1101`.
- Tests: `scene.rs:5198-5285` (accepted on a window-anchored action; unknown
  role rejected `:5216`; wrong kind `:5226`; two claimants `:5229`; idempotent
  re-set `:5243`; context-attach scan `:5268`).

### 6b. Binding surface

`MenuRole` enum — `app.rs:3518-3536` (`Settings`, `Cut`, `Copy`, `Paste`,
`#[non_exhaustive]`), wire spelling at `app.rs:3538-3549`; exported from
`lib.rs:70`. Adding `Undo`/`Redo` is one variant each here plus the same in
each of the other seven bindings (invariant 2, sweep all bindings) — and the
enum is already `#[non_exhaustive]`, so Rust's side is additive.

### 6c. Per-backend role plumbing — the four slots an Undo role slots into

Each backend implements the same three-part shape. **This is the checklist.**

**GTK** (`crates/kaya/src/gtk.rs`)
1. Item model field: `role: String` — `gtk.rs:1149-1154` ("A standard-command
   role from the closed vocabulary (`""` = none) … folds in role_enabled
   (refresh_clipboard_roles)").
2. Enablement predicate: `fn role_enabled(&self, role: &str) -> bool` —
   `gtk.rs:2170-2206`. Falls through to `_ => true` for unknown roles.
3. Performance: `fn perform_role(self: &Rc<Self>, role: &str) -> bool` —
   `gtk.rs:2219-2287`; returns whether it *was* a role so a plain action falls
   through to its own dispatch. Called at activation, `gtk.rs:1349-1356`, and
   the comment there notes the role is read **at activation time**.
4. Refresh: `fn refresh_clipboard_roles(core: &CoreState)` —
   `gtk.rs:2299-2321`. Its header states the rule: enablement is a live
   intersection and "both move long after the bar was built", so it runs
   wherever enablement can change hands (focus moves, clipboard changes, a role
   or accepts list lands, a copy goes out, and before a harness activation).
   Note it currently **filters on `matches!(item.role.as_str(), "cut" | "copy"
   | "paste")`** (`gtk.rs:2312`) — a hard-coded list an Undo role must join.

**WinUI** (`crates/kaya/src/winui/mod.rs`)
1. Model note at `winui/mod.rs:356` ("folds in role_enabled
   (refresh_clipboard_roles)").
2. `fn role_enabled(core, role)` — `winui/mod.rs:3453-3460`.
3. Perform — `winui/mod.rs:3512-3530`; activation guard at `:2918`
   (`if matches!(role.as_str(), "cut"|"copy"|"paste") && !role_enabled(...)`).
4. Refresh — `winui/mod.rs:3487-3490`, same hard-coded triple at `:3487`.

**SwiftUI interpreter** (`swift/KayaSwiftUI.swift`)
1. Model field `var role = ""` — `:315-319`.
2. Apply arm: `MPROP_ROLE` decode — `:2797-2802`.
3. Enablement folded into the inherited-enabled walk:
   `kayaMenuEffectiveEnabled` returns `enabled && kayaRoleEnabled(item.role)`
   — `:5719-5734`; `kayaRoleEnabled` at `:5743-5780`.
4. Perform: `kayaPerformClipboardRole` — `:5915-5960`, called at activation
   `:6058`; inert-note diagnostics `kayaRoleInertNote` `:5831-5845` (and its
   call sites `:4778`, `:4789`, `:4849`).
5. Refresh: `kayaRefreshRoleEnablement()` — `:6589-6594`, plus the
   `NSMenuDelegate` that gives a real user the same freshness
   (`KayaMenuRefresher`, `:6598-6604`). **Read `:6585-6588`**: the first cut
   computed enablement once at sync and every paste leg failed *silently*,
   because `performActionForItem` leaves a disabled item inert.
6. Relocation: `settings` is skipped in normal rendering (`:6315-6319`) and
   placed in the application menu (`:6421-6448`, `kayaCatalogRoleItem`). This
   is the "a role can move an item into dress-owned chrome" mechanism — Undo
   would *not* use it on macOS (Undo lives in the Edit menu the app authors),
   which is worth stating explicitly since it makes Undo behave like cut/copy/
   paste (in-place, behaviour-bearing) rather than like settings (relocated).

**Compose** (`android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt`)
1. Model field `var role by mutableStateOf("")` — `:391-393`.
2. Apply arm `MPROP_ROLE -> item.role = readString(b)` — `:1167`, with the
   comment at `:1154-1165` that Android has no native role placement "but the
   role CHANGES BEHAVIOR", and that a role can arrive after the bar was built.
3. `kayaRoleEnabled` — `:1962-1989`; `kayaPerformClipboardRole` — `:2001-2010`;
   `kayaEditFocusedText` driving the semantics actions (`SemanticsActions.CutText`
   etc.) — `:2072-2085`.
4. Refresh is by Compose snapshot state: `:4558-4573`
   (`KayaCompose.kayaRoleEnabled(item.role)` inside the enabled computation)
   and activation at `:4597`.

### 6d. What an Undo role would cost, mechanically

Additive, and the shape is fully precedented: one string in `MENU_ROLES`
(`scene.rs:522`) — which moves the spec hash **only if** the vocabulary is
hashed; it is **not** (`hash()` at `spec.rs:298-353` walks records, enums, and
the four prop tables; `MENU_ROLES` is a scene-side const, not a spec enum). So
adding a role does **not** regenerate the bindings, which is why `MenuRole` in
each binding is hand-maintained and why `check-sugar-surface.py` /
`check-verbs.py` would need to grow a clause if role coverage is to be gated
across the eight bindings and both interpreters. Every backend has a
hard-coded `"cut" | "copy" | "paste"` triple in its refresh filter
(`gtk.rs:2312`, `winui/mod.rs:3487`) — four places that must be found by
someone who does not know they exist. **That is the guard-placement question
for this milestone** (invariant 3): a role that is validated by the core but
silently ignored by a backend's refresh is exactly the SwiftUI failure recorded
at `KayaSwiftUI.swift:6585-6588`.

---

## 7. Open design questions this recon surfaces (for the pass, not answered here)

1. **Which transactions are undoable.** The natural cut is *the reactive half*:
   `WriteSignal` + the five collection deltas. Everything else (creates,
   const prop sets, mounts, window/nav/section/menu structure, commands,
   dialogs, clipboard) is construction or request, and has no inverse the core
   can compute (§2b). This cut is exactly the set the core already keeps
   before-state for (§2a) — which is why the deferred note calls it cheap here.
2. **Inverse-transaction vs re-run-handlers.** Inverse-transaction is silent
   under the echo doctrine (§3b) and needs no new occurrence semantics.
   Re-running handlers would require synthesizing user-shaped occurrences,
   which contradicts "only the user's act emits" in five separate spec
   docs (`spec.rs:672-675`, `1196-1198`, `1225-1228`, `1272-1274`, `1324-1326`).
3. **Where the log lives.** Core (`Scene`) is the only place with the
   before-state; `Vec<TxOp>` is not `Clone` today (`protocol.rs:1114`), and a
   log that retains `Value::Blob` retains bytes (§2b.3).
4. **Transaction granularity.** A handler is a transaction (`DESIGN.md:2417`),
   so "one undo step = one handler" falls out free — but so does "one undo step
   = one keystroke" for a text field folding `text_changed` into its model,
   which is the wrong grain for an editor and is the coalescing question every
   undo system has.
5. **Widget-local undo already exists on one platform.** WinUI's `RichEditBox`
   carries `Undo`/`Redo`/`CanUndo`/`ClearUndoRedoHistory`
   (`winui/bindings.rs:48198-48407`). A kaya Undo role acting on the focused
   widget would race it, exactly as Cut/Copy/Paste do today — and cut/copy/
   paste resolved that by *delegating to the platform command*
   (`gtk.rs:2238` `clipboard.{role}`, `KayaCompose.kt:2078`
   `SemanticsActions.CutText`). Whether Undo delegates or owns is the
   equivalent decision, and it is the one that decides whether Undo is a
   gesture-layer role at all or a new core verb.
