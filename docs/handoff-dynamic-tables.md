# Dynamic tables handoff — breadth and the native empty-row decision

Status: the Rust/Python depth slice and its post-capture visual fixes are
green. CLOSED 2026-08-24: the six-binding breadth followed the same day
(docs/tables-plan.md "BREADTH CLOSED 2026-08-24"); this handoff stays as
the depth slice's record. The macOS native-table appearance
question below was researched and RULED 2026-08-24 — see the resolution
note ahead of that section.

Written 2026-08-24 while the implementation and validation evidence were
still warm. Read, in order:

1. `AGENTS.md`.
2. docs/tables-plan.md, "Dynamic tables" and "The second slice,
   serialized".
3. docs/deferred.md, "Dynamically created tables — HIGH PRIORITY" and
   "RESEARCH — macOS native portfolio tables show grey empty-row bands".
4. This file.

## The state in one breath

The protocol root is b819423: TX 45 carries copy keys, the core stamps and
re-declares header bars per copy behind seven watched tests, all eight
bindings and both interpreters adapted with zero spelling changes; the
next depth work added Rust then Python nested `columns()` / `on_sort`, the
maintainer-approved string-key `kind@id[key]` harness targets, the real
nested portfolio shape replacing `repopulate()`, per-copy divergence,
and the moving censuses. The six remaining spellings closed later the
same day (docs/tables-plan.md "BREADTH CLOSED 2026-08-24").

## What the fix-forward added

- GTK's equal-weight flex measurement now inverts the exact rounded
  allocator instead of summing unequal natural sizes. The portfolio's
  AAPL row no longer overlaps the following account total.
- GTK horizontal table containment checks both the leading and trailing
  edges with the same two-pixel tolerance. The new boundary assertions
  were watched failing at 2.1 pixels before the guard landed.
- SwiftUI table geometry is generation-tagged across viewport, cells and
  assigned track. An epoch moves on every apply boundary and native
  content-size change, including same-size resize; stale coherent geometry
  can no longer answer a later assertion.
- The real-window table-tier probe covers changed-size and same-size
  invalidation/republication. Its model-only, missing-invalidation,
  unversioned-track and constant-task-key variants were each watched red.
- Swift harness startup admission now waits for mounted surfaces without
  racing its own main-queue state transitions.
- Android stages each verified suite APK once per eligible device and
  keeps ranges' IME setup inside its claimed slot. The optimized standalone
  run was 112/112 in 105s; the all-at-t0 attempt was 112/112 in 268s.
- APK staging prints `: OK`, not the scene-leg `: PASS` marker. The first
  matrix summary falsely counted 128 Android legs and 1,334 overall; the
  real counts were 112 and 1,318. `android-leg-order.py` changes the marker
  back in memory and requires `check-steps` to refuse.

## Validation record

- `cargo test -p kaya --features harness --locked`: 405 unit tests, 4
  runnable docs and 14 compile-fail docs passed.
- Direct `tools/validate-mac.sh`: all 329 legs passed.
- Final `tools/gates.sh`: 42/42 passed after the staging-census fix and
  documentation updates.
- The 2026-08-24 all-at-t0 matrix passed every one of its 1,318 real scene
  legs and the gate sweep: mac 320s/329, Linux 474s/580, Windows 533s/191,
  iOS 493s/106, Android 268s/112, gates 348s; 619s wall. `validate-all`
  exited 1 only because Linux crossed 470s by 4s and Windows crossed 520s
  by 13s. This is a functional pass, not a replacement accepted ALL PASS
  record. Per maintainer direction, do not rerun merely to chase ambient
  timing and do not move either ceiling from this sample.
- The measured timing localization: Linux spent 96s in a cold core build
  and 366s in healthy legs (both portfolio legs were 1s); Windows spent
  75/47/65s in fresh build/deploy/unit-test phases and 310s in its green
  suite, with no leg over 26s. Thermal state and unrelated application
  load were uncontrolled, so do not print either as a measured cause.

The accepted 2026-08-23 matrix remains recorded in docs/tables-plan.md and
docs/deferred.md. The local, ignored viewing artifact is
`target/artifacts/portfolio-dynamic-tables/index.html`; it includes the
inspected GTK/X11 and macOS captures plus current Python/Rust excerpts.

## Open visual research: macOS grey bands below the data

RESOLVED 2026-08-24: the bands are NSTableView's native alternating
empty-row striping in a viewport taller than its content. The maintainer
ruled option 2 — an ungrown native table hugs header + rows, a grown one
stays the fill-and-scroll viewport. Implementation, watched-red record
and the cross-platform contract live in docs/tables-plan.md decision 8
(the 2026-08-24 amendment); the section below stays as the question that
was asked.

The inspected macOS capture shows light-grey blank bands after the last
populated row in each native table — most visibly below VTI, below VXUS,
and twice below CASH. This is measured only as pixels. It has not been
classified as a defect.

Current assertions deliberately cannot decide the product question:

- `expect_column_edges` proves horizontal identity, generation and
  containment.
- the table arm of `expect_fills` permits unused vertical row space and
  rejects content outside the viewport; it does not promise whether the
  unused native viewport is blank, striped, or scrollable.
- the current capture proves all authored rows and all four columns are
  visible. It does not prove the desired empty-area treatment.

The next session must research before changing code. Use primary Apple
documentation plus a focused live AppKit/SwiftUI probe to answer:

1. Are the bands NSTableView/SwiftUI Table's native alternating empty-row
   background, selection material, or kaya-created placeholder rows?
2. Does the native Table own a vertical scroll view at these content and
   viewport sizes, and what user-visible affordance appears when rows
   overflow?
3. Should kaya preserve the platform-native filler treatment, size each
   account table to its rows, or keep the viewport but suppress empty-row
   striping? Compare the implications for three independently scrollable
   account tables.
4. What should the cross-platform contract say? GTK's synthesized tier is
   content-height here; macOS native Table need not be pixel-identical,
   but the divergence must be intentional.

Bring the findings and screenshots to the maintainer for a ruling. Do not
implement an aesthetic guess. If the ruling changes behavior, add a
toolkit-derived observable or compiled real-window probe, watch its
negative fail, then run the proportional ladder.

Relevant files:

- `swift/KayaSwiftUI.swift`: `KayaTableSurface`, `KayaNativeTable`, table
  viewport/cell/track observations, and `expect_fills` /
  `expect_column_edges` handling.
- `tools/checks/swiftui-table-tier.swift` and
  `tools/check-table-tier.sh`: the compiled native-table probe and its
  watched mutations.
- `guests/python/portfolio.py` and `tools/scenes/portfolio.steps`: the
  forcing dashboard and its shared assertions.
- `docs/tables-plan.md` decision 8: the current vertical containment
  contract.

## Remaining milestone order

DONE 2026-08-24, both halves: the empty-row decision was ruled and built
(tables-plan decision 8's amendment), and the six-language binding sweep
closed with DO on every point. Each spelling moves its own
`tpl-surfaces.py` / `check-sugar-surface` census and watches the negative
fail in the same commit. Mobile portfolio packaging remains separate.

The protocol root is b819423. Discover the fix-forward commit with
`git log` rather than copying a hash from prose. Commit and push still
require the maintainer's explicit approval and exact message; approval of
a commit never implies approval to push it.
