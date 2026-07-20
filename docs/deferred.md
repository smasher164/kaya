# Deferred work ledger

The running inventory of punted items. Check things off here as they
land; add new deferrals with enough context that a future contributor
(human or agent) can pick them up cold. DESIGN.md's open-questions
section is the architectural counterpart; this is the working list.
Landed history lives in git; this file only carries what is still open.

## Next milestones (in rough priority order)

- **Layout props**: spacing/grow/alignment; the layout-normalization
  worklist scenes. Recording mode (KAYA_RECORD=1) was built partly as
  the cross-backend comparison vehicle for this. `grow` is landing now
  (spec + AppKit + GTK + Rust + the `grow` and `layout` scenes); still
  open on it: the SwiftUI and Compose interpreters need the prop in all
  four layers, the remaining 7 bindings need the `grow` sugar, and
  **WinUI cannot express it at all as it stands** — both containers are
  `StackPanel`, which has no star sizing, so Windows needs a migration
  to `Grid` with `RowDefinition`/`ColumnDefinition` at `GridLength`
  star. That is its own milestone: `Grid`, `ColumnDefinition`,
  `RowDefinition` and `GridLength` are not even in the generated
  bindings (the type filter in tools/winui-bindgen never names them),
  so it means extending the filter, regenerating, and rewriting every
  child insertion to maintain attached `Grid.Row`/`Grid.Column`
  properties and reindex them on add/move/remove. `alignment` is the
  prerequisite for grow being *visible* in a nested stack: kaya's
  normalized cross-axis default is leading/natural, so a nested *column*
  is only as wide as its content (rows do stretch to the parent's width,
  as the AppKit frame dump confirmed).
- ~~A geometry verb for the harness~~ LANDED as `expect_shares` /
  `Stage::child_shares`, with the `grow` scene as its first user.
  Shares, not sizes: a size is a platform metric and could never be
  compared byte-for-byte, so the verb reports each child's main-axis
  extent as a whole percentage of the children's *sum* (spacing and
  padding excluded, since those are metrics too), and the scene gives
  its column nothing but growers so the split is exactly
  weight/Σweight. Traps found doing it: read the alignment/layout rect,
  not the frame (AppKit inflates a slider's frame ±2 a side and would
  report 1:3 as 2.90:1); force the pending layout pass before reading or
  the first read after mount sees stale or zero geometry; and rounding
  lives in one shared `harness::shares` so two backends cannot disagree
  by a percentage point and read as a layout bug. Still open: the verb
  exists in the five Rust backends but not the two interpreters, and
  `grow` itself is implemented only on AppKit and GTK.
- **Window vocabulary** (DESIGN open question #4): create_window,
  per-window mount targets, lifecycle (CloseRequested + veto default,
  Present, Close), sizing/titles, dialogs/modality, mobile capability
  story. Mount target 0 is reserved so the wire doesn't break. `close()`
  joins the command enum here. Unlocks the appendix's
  `app.window(title=...)` as real protocol.
- **The versioned binding style guide** (DESIGN open question #1):
  ratify per-language tiers; ambient-transaction spellings; the
  eq/ne/fmt derived-signal vocabulary beyond Python; blob-signal
  ergonomics parity (Go has typed Signal[[]byte]; others wrap handles
  manually); decision gate for deleting the probe/reflection selector
  floor that the KayaGen generators superseded; optional static
  analyzers (Roslyn for C# is the plausible one; go/analysis; ErrorProne
  — never load-bearing, the runtime guards are the floor).

## Protocol / core

- scrollTo + ref markers (per-instance handles): brings the first
  instance-addressed command (TemplateNodeId + key path target) and the
  silent vanished-target no-op (live-zone commands fail loudly; stamped
  copies legitimately vanish under rebuild). Wants a long-list scene —
  which pairs with row-window virtualization for For.
- Command completion observability (awaitable commands — the Compose
  scrollToItem precedent); command payloads (a set_text command awaits
  an autofill-shaped artifact). Admission policy: each verb needs a
  real artifact.
- Value::Record — waits for nested fields or field-level sum payloads.
- Nesting depth >2 validation; typed keys in collection schemas.
- Occurrence growth: subscription/filtering (every click emits today),
  suspension lifecycle (Android), CloseRequested.
- Vello scene-encoding subset (open question #3) — arrives with Canvas,
  post-v1, on the surface-handle transport (pixel surfaces as
  IOSurface/DXGI/dmabuf handles; the blob channel is the byte-copy arm,
  Canvas is the zero-copy arm).
- Blob follow-ups: dedup on repeated registration (needs an artifact);
  kaya_blob_from_file/mmap escalation (needs an artifact showing the
  register copy matters — decode dominates by an order of magnitude).

## Bindings / ergonomics

- Component functions as the reusable named unit (Solid's model, slot
  proxies = the function signature) — mostly ratification for the
  typed languages; Python validates at record time.
- Switch sugar (app-level one-of-N over a signal; sum-typed elements
  already cover collection rows) — wants the comparison vocabulary
  first.
- Template-declared collection escape to handlers (`group.items` via
  the element proxy) — flagged, undesigned; wait for a motivating
  scene.
- Portal (platform overlays; protocol + backend work).
- OCaml effect-handler ambience (true Python-style ambient
  transactions; runtime-only scoping errors — OCaml has no effect
  typing).
- Binding-maintained mirrors (todos-iterable style shadow state).
- Go sum note: SumCollection.UpdateField now routes through the
  encoder (uniform with records and other languages).

## Testing / infrastructure

- The `layout` scene is half-wired: it exists (guests/rust/layout.rs,
  tools/scenes/layout.steps, harness arm, Android guest arm) and is
  functionally green on mac, but is NOT built or run by any platform
  suite (validate-mac scene list, validate-linux, run-sim, run-emulator,
  deploy-win) — every capture had to `cargo build --example layout` by
  hand. check-steps passes anyway (it validates script well-formedness,
  not runner wiring), so nothing flags the gap. DECISION: either wire it
  into the suites as a cheap functional leg (its two label expects prove
  the tree builds) or accept it as an observation-only scene and say so.
  Ties to the geometry-guard decision below (an eyeball-only scene has
  little to assert in an automated suite).
- Ergonomic: a `kaya::park(&ctx)` keep-alive primitive for static
  (handler-less) scenes, so they don't reach for `Messages::<()>` just
  to block until Shutdown (see traps.md).
- Layout has no structural guard: the harness observes only
  semantic/textual state (child_texts, read_text, is_focused,
  image_size) — there is no geometry observation (frame/position/measured
  spacing), so layout regressions are invisible to the gate layer. The
  `layout` scene (guests/rust/layout.rs + tools/scenes/layout.steps) is
  an eyeball-only observation vehicle under KAYA_RECORD; its two expects
  only prove the tree built. DECISION (maintainer, 2026-07-19):
  declined for now — keep layout eyeball-only, do NOT build a geometry
  Stage method ("idk if geometry detection will pay off"). So layout
  stays unguarded by the gate layer by choice; revisit only if layout
  regressions start biting.
- bench-encode blob leg: register+reference throughput with an MB/s
  floor, so payload-path structural regressions trip at gate time.
  (Adding it means a second phase in each language's encode_bench
  program + floors in tools/bench-encode.sh — keep it separate from
  the existing rec/s floors, which would otherwise deflate.)
- Windows entry follow-ups: IME contract notes for mobile; the WinUI
  text-flyout-open path is untested; XamlControlsResources merging can
  crash even with the metadata provider (test when adopting fluent
  styling).
- Packaging: at-release items — Hackage/opam publication, Go vanity
  import path (akhil.cc/kaya + go-import meta; dev.kaya is
  unpublishable), Maven publication under cc.akhil, npm kaya-gui after
  account recovery; a LICENSE decision before any real release;
  trusted publishing (OIDC) on nuget/PyPI/npm when releases start.
  Android Python/Go guests need binding bootstrap (briefcase/gomobile).
  Swift SPM packaging needs a modulemap target.
- Node.js guest (the roster's first async surface): Node first;
  function-floor tier via N-API (V8 pointer compression forbids
  external ArrayBuffers over native memory — no direct ring);
  main thread blocks in kaya_run, app logic in a worker; layer 3 wants
  for-await occurrence iteration.
- Arena offset+length form (row batches, audio) — returns when the row
  window and audio land; the blob table is its v1 realization.
- Attach/embedding tooling rework (parked at milestone 0).
