# kaya bindings

Every binding is the same three layers; only the taste differs.

**Layer 1 — the wire vocabulary (generated).** Constants, record
packers, and the occurrence parser, emitted into each language by
tools/kaya-bindgen from `kaya::spec` (Rust is the root; run
tools/gen-bindings.sh, and `--check` gates the validation scripts).
Nothing hand-written lives here, which is what keeps eight languages
current when the protocol grows: a new property or record kind is a
spec edit, not eight edits.

**Layer 2 — the runtime (hand-written, stable).** Library loading, the
occurrence transport, and submit. This is where each language's
hard-won transport recipe lives: Go reads the ring with
`sync/atomic`, C# with `Volatile`, OCaml through a Bigarray plus two
noalloc cursor stubs, Haskell through inline peeks plus the same stubs,
the JVM through Unsafe absolute loads with explicit fences (the ART
findings), while Python and Swift take the function floor
(`kaya_next_occurrence`), where C interop is already optimal. The ring
format has not changed since milestone 0; neither has this layer, much.

**Layer 3 — the structural core (hand-written, idiomatic).** Three jobs,
the same in every language, expressed in each language's own shape:

- **id allocation** behind typed handles (Signal/Widget/Collection and
  the template-node type), per-space counters owned by the App — no
  app hand-numbers ids, and using a blueprint node where a live widget
  belongs is a compile error in the typed languages;
- **template scoping** — For/When bodies as closures (`func(*Tpl)`,
  `Action<Tpl>`, trailing closures, `with` blocks) or monadic do-blocks
  (Haskell's `Tpl`), bracketing the records so declaring and
  instantiating stay visibly different;
- **occurrence dispatch** — handlers registered per button, routed by
  the app loop, with a stamped copy's key path handed to template-node
  handlers. Two tables, always: widget ids and template-node ids are
  separate spaces that collide numerically. Dispatch runs on the app
  thread after it pulls from the transport; the core never calls into
  the guest.

Settled conventions (seeding the versioned style guide the design
promises):

- Handlers receive their transaction — explicitly (`func(*Tx)`,
  `Action<Tx>`, `tx ->`) or ambiently (Python). Either way the
  semantics are the protocol's: a handler is a transaction, submitted
  when it returns; a handler that raises abandons its records, and the
  binding's mirrors roll back with them.
- The collection is the model — the only copy; mutations are patches.
  Every mutation op edits the model and becomes the wire delta in one
  recorded operation (patch-producing mutations, the Immer /
  event-sourcing shape), in order, inside the transaction, rolling back
  together if the transaction is abandoned. So reads of the model are
  exactly the committed writes — never stale — and no dual bookkeeping
  exists to diverge. Per-language frontends over the same wire deltas:
  method ops everywhere; draft scopes for dynamic languages
  (`with c.change() as d: d[k] = v` — insert-or-update resolved from
  the model); #[must_use] delta values where ownership makes dropped
  deltas loud (Rust, later); snapshot assign() with guest-side diffing
  as sugar (planned). Model reads are part of the layer-3 contract in
  every language (items/count, spelled per idiom), with
  read-your-writes inside the transaction and cascade purge along the
  declared-inside-a-For edges — and the milestone-2 selftest proves the
  fold end-to-end: the remove handler answers with the count read back
  from the model ("removed g2/a, 0 left"), so a binding with a broken
  fold, purge, or read path fails its selftest on every platform.
  Rollback on abandonment is per-language honest: a journal where
  handler exceptions are catchable (Python, C#, Java, OCaml), commit-
  time model store-back where the Build is pure (Haskell) or the
  transaction is droppable (Rust), and nothing where a handler failure
  is a crash anyway (Go panics, Swift's non-throwing closures).
  Signals expose no read: they are a render pipe,
  not a state bus; computations live in derived signals (`steps.eq(1)`,
  `sig.fmt(...)`) — binding-maintained, recomputed at write time,
  batched into the same transaction. Model reads in template position
  raise at record time (the frozen-branch guard). Widget-owned state
  (entry.text, later) should arrive as occurrences the app folds into
  its model, not as readable widget mirrors — keeping the model the
  single source and keeping eventual data out of the read path.
- The collection handle is an instance handle: the root handle
  (what `collection()` returns) is the live-zone table, and `at(key)`
  steps into a stamped copy's instance, one key per enclosing For —
  chain for deeper nesting. Mutations and reads take the same handle,
  so a handler binds the target once (`todos = items.at(group)`) and
  uses it throughout; no call spells a key path inline. `for_each`
  binds the collection itself, never an instance — every binding
  rejects an `at(...)` handle there at record time.
- Template bodies hand their declarations back out: whatever the body
  returns comes back alongside the For/When handle (Rust's generic
  closures, OCaml/Haskell's `(handle, result)` pairs, Java's
  `Stamped<H, R>` — its lambdas cannot assign captured locals; Java's
  `build` is generic for the same reason). Go, C#, Swift, and Python
  may also just capture lexically. Either way, nothing escapes a
  template through mutable slots or static fields.
- `When` takes a signal, never a raw bool — enforced by types where
  the language can (Haskell's `Declare` class makes cross-zone
  `addChild` unrepresentable; the others get it from the handle types).
- The zone split is spelled by the language's own idiom: a type family
  (Haskell), distinct handle types plus a Tpl builder (Go, C#, Swift,
  Java, Python), or a submodule path (OCaml's `Kaya_app.Tpl`, since
  OCaml has no overloading — and its binding operators live per zone,
  so `Tpl.( ... )` switches vocabulary and `let*` together).
- Where the language has monadic sugar, the declaration program is a
  value and the transaction never appears in app code: Haskell's
  do-blocks over Build/Tpl, OCaml's `let*`/`let+`/`and+` over
  `'a decl = tx -> 'a`. Both make a dropped declaration a type error
  (a non-unit value in statement position), the same loudness Rust
  will get from #[must_use] delta values.

Per-language status:

| Language | L1 generated | L2 runtime | L3 core | Notes |
|---|---|---|---|---|
| Python  | kaya_wire.py | kaya.py (function floor) | kaya_app.py | first tier-1 sugar target (ambient tx, auto-parenting, co-located handlers) |
| Haskell | KayaWire.hs | KayaRuntime.hs (peeks + stubs) | KayaApp.hs (Build/Tpl monads) | the monad-sugar experiment, realized |
| Go      | kaya_wire.go | runtime.go (atomics ring) | app.go | handlers take *Tx per convention |
| C#      | KayaWire.cs | Kaya.cs (Volatile ring) | KayaApp.cs | |
| OCaml   | kaya_wire.ml | kaya_runtime.ml (Bigarray + stubs) | kaya_app.ml | let*/let+ over 'a decl (= tx -> 'a) — the reader spelling of Haskell's Build; Tpl as submodule with its own operators, so a local open switches zone and operators together; io lifts host code; effect handlers are the flagged follow-up |
| Swift   | KayaWire.swift | function floor via kaya.h | KayaApp.swift | Kaya-prefixed handles (hosts link UI frameworks with bare Widget/Node names) |
| Java    | KayaWire.java | (ring recipe lives in KayaApp) | KayaApp.java | needs API 26 (invokeExact); Android's kaya module minSdk says so |
| C       | kaya_wire.h | kaya.h is the runtime | — none, by decision | flat functions over a caller-owned buffer *are* C's idiomatic surface; a C app that wants handles is a C app about to become a binding |

The north star for what layer 3 grows into is DESIGN.md's appendix
("the shape of an app"); the tier-1 sugar there (container
auto-parenting, co-located handlers, ambient transactions, mirrors,
derived signals) needs no protocol changes and lands per language,
Python first.
