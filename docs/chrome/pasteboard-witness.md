# The pasteboard foreign-writer witness (mac SwiftUI interpreter)

Ledger entry: docs/deferred.md "The pasteboard needs a foreign-writer
witness (measured 2026-08-18)".

## What is already in the file (read 2026-08-18)

- `kayaClipOwnerChange` / `kayaClipOwned(_:)` (swift/KayaSwiftUI.swift
  ~1200-1236): the changeCount kaya itself last put on the board. Two
  writers today: `kayaCopyToPasteboard` (end of the write, line ~1104)
  and `kayaClipboardSeed`'s settle (line ~1602).
- `kayaClipOwnerClause()`: a TRACE clause appended to the
  "read answered empty" stderr note. It already knows the transition —
  it just cannot fail a step, and it only prints when the answer was
  empty.
- Consumers: `kayaReadClipboardValue` (privileged read AND the
  accepts-paste, one body), `kayaPerformClipboardRole("paste")`'s
  platform-insertion branch (NSText.paste), and the harness verb
  `expect_clipboard` (pbpaste/osascript/sips from outside).
- Missed stage site: the `cut`/`copy` roles write the board through the
  responder chain and never told `kayaClipOwned` — a false "foreign
  writer" waiting to happen (the text editor's Cmd-X then Cmd-V).

## Plan

1. `kayaClipStaging` in-flight count so a consumer that looks inside
   kaya's own clear-then-fill window does not name a foreign writer.
2. `kayaClipDrifted()` — the one comparison, shared by the trace clause
   and the witness.
3. `kayaClipWitness(_ consumer:)` at the three consumption sites; latch
   the first breach.
4. `kayaRunScript` surfaces the latch: the step fails with the
   discriminating sentence and the script stops (no point asserting
   against a board another process is writing).
5. cut/copy re-base the snapshot (self-write, not a foreign writer).

## What landed (swift/KayaSwiftUI.swift only)

- `kayaClipStaging()` / `kayaClipOwned()` bracket every stage; `kayaClipStages`
  keeps the witness quiet inside kaya's own clear-then-fill window.
- `kayaClipDrifted()` — the one comparison (staged count vs the board now),
  read by both the old trace clause and the witness.
- `kayaClipWitness(_ consumer:)` latches the first breach;
  `kayaClipBreachNote()` peeks (never takes — an expect retries).
- Three call sites, each SEEN firing (below):
  1. `kayaReadClipboardValue` — the privileged read and the accepts-paste.
  2. `kayaRoleInertNote` — the paste command's door. It had to go in FRONT
     of the enablement question: a paste whose staged clip was replaced is
     usually DISABLED, and on macOS the harness dispatches the REAL
     NSMenuItem, so kaya gets no say at all once AppKit has greyed it.
     Proven: the first placement (inside kayaPerformClipboardRole, and then
     inside kayaMenuUserActivate) did NOT fire — the leg still failed
     "entry#1 reads """.
  3. `expect_clipboard`'s poll — the harness's own foreign read.
- `cut`/`copy` roles now stage (kayaClipStaging/kayaClipOwned around the
  responder send): a native Cmd-X is this leg's own write, and without
  this the witness would call it a foreign writer.
- The harness (`kayaRunScript`) surfaces the latch: the attempt's own
  failures are retracted, the breach becomes the step's failure, and the
  script stops (`break scriptLines`).

## The watched negative (perturbation proven, both directions)

Driver: scratchpad/negative.sh (gone) — waits for the leg's own trace to reach
`settle 3000` after the seed, then writes the machine's pasteboard from
OUTSIDE the leg (osascript PNG clip, or pbcopy text). pbpaste is read
before and after, so the perturbation is measured, not assumed.

- guard OFF (scratch dylib, kayaClipWitness early-returned):
  `KAYA_HARNESS: step-failed label#0 reads "empty", wanted "text from another app"`
  — the incident's own sentence.
- guard ON, read site:
  `step-failed the pasteboard changed under this leg (changeCount 64487 -> 64488): a foreign writer replaced the staged content — the read of [text] is reading a board this leg did not stage, and it now offers ["public.png", "Apple PNG pasteboard type", "public.tiff", "NeXT TIFF v4.0 pasteboard type"]`
- guard ON, paste-command site (negative2.steps):
  `... — the paste command (menu_activate "Edit>Paste") is reading a board this leg did not stage ...`
- guard ON, foreign-read site (negative3.steps):
  `... — the foreign read of text is reading a board this leg did not stage ...`

Source restored from the saved copy: `shasum -a 256 -c` OK, file touched.

## The self-write proofs (the guard's own failure mode)

- `selfwrite.steps`: stage (the app's copy) -> consume -> re-stage (seed)
  -> consume -> re-stage (seed) -> paste. PASS.
- `nativecopy.steps`: seed, then a NATIVE `Edit>Copy` (which does move the
  count — the seeded text is gone from the board afterwards), then read.
  PASS with the cut/copy stage; with that stage removed and everything
  else identical it FAILS
  `the pasteboard changed under this leg (changeCount 64525 -> 64526): a foreign writer replaced the staged content — the foreign read of text is reading a board this leg did not stage, and it now offers []`
  — the leg's own write reported as a stranger's. That is the watched
  negative for the false positive.

## Verdicts (final artifact, tools/build-id.sh --verify OK)

- tools/swiftui/build-dylib.sh rc=0; tools/swift-typecheck.sh OK (6 passes,
  macOS + iphonesimulator).
- check-verbs, check-steps, check-roles, check-stubs, check-ledger: rc=0.
- check-diagnostics and check-doc-refs are RED for the concurrent agent's
  half-landed asset work (crates/kaya/src/assets.rs, capi.rs, jvm.rs,
  KayaRing.kt why-nots; docs/assets-plan.md citing a file that does not
  exist yet). Nothing in the Swift audit, whose self-test passed.
- All eight mac clipboard legs PASS: rust, python, go, swift, csharp,
  ocaml, haskell, java. The java leg needed its guest classes rebuilt
  (javac, as validate-mac does) — the concurrent agent's new KayaRing
  native aborts a stale class at JNI registration on EVERY scene,
  clipboard or not.

## Cleanup

pbcopy </dev/null; `pbpaste | wc -c` = 0, `clipboard info` shows the
zero-length types. No guest, driver or recorder processes left (ps
listing empty). Scratch dylibs and source copies deleted.
