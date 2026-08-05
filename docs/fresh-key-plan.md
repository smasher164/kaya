# fresh keys and the undo scene reshape

Ratified 2026-08-04. One slice, three debts, all already in the ledger
(docs/deferred.md):

1. The shared scene's stated D5 texts-run proof cannot fail: the coarse
   undo and the redo land the draft exactly where the last ordinary
   emission left it, so every guest passes with its `delta.texts` fold
   deleted (measured on the Java and Haskell lanes independently).
2. No scene ever undoes a collection REMOVE. The inverse is implemented
   and unit-tested, and it is precisely the case where key identity
   (not content) is what undo asserts. It has never run on a matrix.
3. Nine guests hand-spell a surrogate-key counter (`next_key`) that is
   mutable global state in six languages, and its safety rests on an
   unwritten never-rewind rule whose violation is a duplicate-key panic
   reachable through an undo/redo/add interleave.

## The minter: `insert_fresh`

Identity doctrine (DESIGN.md, update algebra): keys are domain
identity, guest-chosen. Data that HAS natural identity passes its own
key, today and always. `insert_fresh` is for data that has none — the
binding authors the identity at insert and hands it over, so the app
never invents a name and never holds two names for one datum.

The contract, ONE observable semantics in all sugar bindings:

- `insert_fresh(collection, record) -> key` (per-language casing and
  receiver idiom; ambient bindings take the ambient transaction the
  way `insert_record` already does).
- The minted key is `I64`. One monotonic counter per collection
  INSTANCE, starting at 0; mint is counter+1.
- Mixing is safe by absorption: any EXPLICIT insert whose key is an
  I64 >= the counter advances the counter past it. A later
  `insert_fresh` can therefore never collide with a hand-chosen
  numeric key.
- No decrement is expressible. Undo/redo replay captured keys inside
  the core and never re-enters the guest insert path, so the counter
  never moves on history walks: a fresh key is fresh forever.
- The C floor does not take the sugar (invariant 5: the floor is the
  explicit tier). Its guests hand-mint the same I64 sequence with a
  local counter and a comment naming this contract.

No wire or core change: the key crosses the wire exactly as an
explicit key does. The spec hash does not move. A binding that forgot
the minter fails to COMPILE its own undo guest — the scene is the
wall.

## The scene reshape (tools/scenes/undo.steps)

Byte-frozen strings move on all 12 surfaces at once; the reshape and
every guest's adoption are one atomic unit, fanned out like the undo
fan-out itself.

New obligations the steps must encode:

- TEXTS-RUN FALSIFIABILITY: after the coarse undo and after the redo,
  the draft the app would hold WITHOUT folding `delta.texts` differs
  from the one it holds with the fold, and a later observable step
  (the next add's echoed name) depends on the difference. Shape:
  type, act, type again — the episode's before-image must not be
  where the last ordinary emission left the app.
  PROOF OBLIGATION: on the depth lane, delete the Rust guest's texts
  fold, watch the leg FAIL, restore, watch it pass. A reshape that
  does not flip that experiment has not paid debt 1.
- REMOVE: an undoable remove step (a button that removes a known
  entry). Undo restores the entry under ITS ORIGINAL KEY at its
  original position (the entries and orders runs assert both); redo
  removes it again. Counts echoed in status strings make it
  observable in every language.
- The sugar guests adopt `insert_fresh`; their `next_key` counters
  are deleted. The C guest keeps the explicit floor.

## Sequencing

Depth: the minter in the Rust binding + the reshaped steps + the Rust
guest + the falsifiability measurement + the rust mac leg green.
Breadth: the seven other sugar bindings' minters and guests plus the
C floor guest, in parallel; then the matrix. Mid-flight the other
undo legs are red against the new steps — the hold-open, not a
regression.

Conditional phase 2: todos and entry also hand-mint counters. If
their expected strings do not move under adoption (keys never appear
in output), they adopt in the same slice; if any string moves, they
go to the ledger instead.
