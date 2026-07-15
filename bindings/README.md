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
  `Action<Tx>`, `tx ->`) everywhere so far; Python moves to ambient
  transactions when its tier-1 sugar lands. Either way the semantics
  are the protocol's: a handler is a transaction, submitted when it
  returns.
- `When` takes a signal, never a raw bool — enforced by types where
  the language can (Haskell's `Declare` class makes cross-zone
  `addChild` unrepresentable; the others get it from the handle types).
- The zone split is spelled by the language's own idiom: a type family
  (Haskell), distinct handle types plus a Tpl builder (Go, C#, Swift,
  Java, Python), or a submodule path (OCaml's `Kaya_app.Tpl`, since
  OCaml has no overloading).

Per-language status:

| Language | L1 generated | L2 runtime | L3 core | Notes |
|---|---|---|---|---|
| Python  | kaya_wire.py | kaya.py (function floor) | kaya_app.py | first tier-1 sugar target (ambient tx, auto-parenting, co-located handlers) |
| Haskell | KayaWire.hs | KayaRuntime.hs (peeks + stubs) | KayaApp.hs (Build/Tpl monads) | the monad-sugar experiment, realized |
| Go      | kaya_wire.go | runtime.go (atomics ring) | app.go | handlers take *Tx per convention |
| C#      | KayaWire.cs | Kaya.cs (Volatile ring) | KayaApp.cs | |
| OCaml   | kaya_wire.ml | kaya_runtime.ml (Bigarray + stubs) | kaya_app.ml | Tpl as submodule |
| Swift   | KayaWire.swift | function floor via kaya.h | KayaApp.swift | Kaya-prefixed handles (hosts link UI frameworks with bare Widget/Node names) |
| Java    | KayaWire.java | (ring recipe lives in KayaApp) | KayaApp.java | needs API 26 (invokeExact); Android's kaya module minSdk says so |
| C       | kaya_wire.h | kaya.h is the runtime | — none, by decision | flat functions over a caller-owned buffer *are* C's idiomatic surface; a C app that wants handles is a C app about to become a binding |

The north star for what layer 3 grows into is DESIGN.md's appendix
("the shape of an app"); the tier-1 sugar there (container
auto-parenting, co-located handlers, ambient transactions, mirrors,
derived signals) needs no protocol changes and lands per language,
Python first.
