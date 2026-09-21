# Save guests before a file handle exists

Baseline: 6d7c2858. No API or file-dialog behavior changes. The example's
existing missing-handle sentences should use a live transaction and should
precede any attempt to open a zero handle.

## Measurement before the change

Four native Mac runs used tools/run-leg.py with a counted one-substitution
script override. Each inserted one missing-handle click/expect pair immediately
after the initial `no file` assertion. The rest of the shared scene was unchanged.
Each red was read from its recorder bundle, including the step clock, before
the corresponding fix.

| Guest and click | Clock at click | Observed result |
| --- | ---: | --- |
| Swift save | 32 ms | SIGTRAP; transaction-is-over precondition |
| Swift reopen | 30 ms | SIGTRAP; same precondition |
| C save | 33 ms | `saved save failed: Invalid argument` |
| C reopen | 31 ms | `reopened open failed: Invalid argument` |

Swift's closures discarded the transaction supplied to the handler and captured
the expired construction transaction. The existing binding liveness wall named
that misuse at KayaApp.swift:3587. The C floor had no missing-handle branch and
sent zero to the file worker. Both C runs reached the final successful round-trip
assertion but retained a failed verdict for the earlier wrong text. Nothing
about either failure required additional recorder instrumentation.

## Correction and durable guard

Swift's two handlers now use their own transaction argument. The C floor writes
the same existing missing-handle messages before starting a worker. The shared
save scene now clicks save and reopen before opening anything, then clicks
reopen again after acquiring the source but before choosing a destination.
Normal save, cancellation, save-as and final disk read-back remain in place.

This shared script is the runtime guard on every save leg. The existing
tools/check-steps.py gate requires both early cases and the missing-destination
case at their positions in the flow. Three one-substitution script cuts were
watched failing that guard. The four native baseline failures above prove that
the added assertions reach the original defects, not just a source pattern.

The corrected Swift and C guests passed the complete expanded native scene,
including all three new assertions and the final accessible read-back.

## Nine-language assessment

| Language | Verdict | Missing-handle write |
| --- | --- | --- |
| Rust | Do: shared-script coverage; no guest edit needed | explicit apply |
| Python | Do: shared-script coverage; no guest edit needed | handler ambient transaction |
| Go | Do: shared-script coverage; no guest edit needed | current handler Tx |
| C# | Do: shared-script coverage; no guest edit needed | current handler inner |
| Java | Do: shared-script coverage; no guest edit needed | current handler inner |
| Swift | Do: fix both handlers and add shared coverage | current handler tx replaces captured outer tx |
| OCaml | Do: shared-script coverage; no guest edit needed | handler ambient transaction |
| Haskell | Do: shared-script coverage; no guest edit needed | explicit buildTx |
| JS | Do: shared-script coverage; no guest edit needed | handler ambient transaction |

The C floor also changes: it now refuses a missing source or destination with
the same label text. No language is carved out or deferred. All-nine runtime
coverage is measured by the full Mac and matrix runs below, not inferred from
this source audit.

## Validation

Focused Swift and C legs, check-steps and check-python passed, then the full
ladder: 644 core tests, 25 doctests (one ignored), 61 gates, 477 standalone Mac legs and all five matrix lanes: Mac 477, Linux 777, Windows 283, iOS 139, Android 148 in 1047 seconds, every timing ceiling held. The all-nine runtime coverage above is therefore measured, not
inferred: every save leg on every lane ran the three added cases. The matrix's first
run on this tree lost seven mac legs in dyld to the gate sweep relinking the host
libkaya under the mac lane (docs/traps.md, 2026-09-21), fixed in the same commit; the
second run is the one recorded here. Scratch logs and the four counted overrides are
under `target/session-notes/save-missing-2026-09-21/` (built).
