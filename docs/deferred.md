# Deferred work ledger

The running inventory of punted items. Check things off here as they
land; add new deferrals with enough context that a future contributor
(human or agent) can pick them up cold. DESIGN.md's open-questions
section is the architectural counterpart; this is the working list.
Landed history lives in git; this file only carries what is still open.

## Next milestones (in rough priority order)

- **Layout props**: spacing/grow/alignment; the layout-normalization
  worklist scenes.
  **`grow` is LANDED on all seven backends** — spec, the `grow` and
  `layout` scenes, the `expect_shares` verb, and every backend green on
  its own suite (mac 76 legs, Linux X11+Wayland, Windows 26, iOS UIKit
  and SwiftUI suites both carrying grow/layout legs, Android Views and
  Compose). `check-verbs` is green.
  How each backend expresses it, which is the useful map for the next
  layout prop: **native weights** on WinUI (`Grid` star sizing),
  Compose (`Modifier.weight`) and Android Views (`layout_weight` with a
  0 main-axis size); **constructed** on AppKit and UIKit (pairwise
  `NSLayoutConstraint` multipliers between growers), GTK4 (a custom
  `GtkLayoutManager`) and SwiftUI (a custom `Layout`). Four of the seven
  toolkits have no per-child weight concept at all.
  WinUI's `StackPanel`→`Grid` migration is DONE (star sizing is
  literally the contract, so the weights map straight onto
  `GridLength` with no arithmetic); its cost was that Grid places by
  attached `Grid.Row`/`Grid.Column` rather than by child order, so the
  backend now tracks logical order itself and restamps every child on
  add/move/destroy.
  ~~The remaining 7 bindings need the grow sugar / the scenes exist
  only as Rust guests~~ LANDED (2026-07-20): every binding spells grow
  declaratively in its own idiom — Python `grow=` kwargs plus
  `Widget.grow`, C# `grow:` optional args, Swift `grow:` labeled args,
  OCaml a `grow weight decl` combinator, Haskell a `grow` combinator
  over `setGrow` (Build-only: no language has template grow, so it
  stays off Declare until all do), and Go and Java a construction
  CHAIN — `tx.Label(s).Grow(1)` / `tx.label(s).grow(1)`. The chain is
  Akhil's call over my named-setter first cut ("the sugar looks very
  imperative" — right): their handles now carry the minting
  transaction, so chains read declaratively, and a `closed` flag set
  when the build ends (committed or rolled back) makes a chain on an
  outlived widget die loudly rather than append into an orphaned
  record list. The Set*/set* setters stay underneath as the dynamic
  path everywhere. The grow/layout scenes run as guests in all
  languages, including the Kotlin jvm pair that gives the Android jvm
  suite its legs. check-sugar-surface gates the DECLARATIVE spelling
  per binding.
  Still out on purpose: the C floor's grow/layout scenes (the floor
  documents the explicit wire; a separate exercise), and Rust's
  chained `.grow()` form, which waits on proxy handles with the style
  guide.
  The sugar's shape is DECIDED (2026-07-20): declarative at
  construction in each language's idiom — a Python keyword argument,
  a named parameter where the language has them, a chained builder
  call in Rust — all compiling to the same Create+SetProp pair;
  container-SCOPED where the type system can express it (grow only
  spellable inside a row/column context, Compose-receiver style), so
  a weight outside a container is a compile error rather than a
  runtime no-op; and the imperative setter stays as the
  dynamic-update path — weights change at runtime and the backends
  already re-solve. No wrapper-widget spelling ever: a phantom
  Expanded-style node would change the tree shape per language,
  breaking creation-order targets and byte-identical scenes.
  STATUS after the sweep: the un-scoped spellings shipped (see the
  LANDED note above); container SCOPING — typed row/column contexts
  making an orphan weight a compile error — waits for the style-guide
  phase alongside Rust's chained form, since the ambient languages'
  nullary container bodies cannot express a receiver without a
  redesign.
  ~~The horizontal contract was asserted nowhere~~ LANDED (2026-07-20):
  `row` is a target kind, blessed as `row#0` under the same
  unique-by-convention rule as `column#0` (check-steps holds both),
  and the grow scene now carries a weighted row — column splits
  25/25/50, the row's width splits 25/75, asserted on all seven
  backends. The runner also rejects container verbs on non-container
  targets and expects on anything but labels/entries/images, closing
  the registry-misresolution class on the Rust side the way the
  interpreters already had.
  `alignment` is the prerequisite for grow being *visible* in a nested
  stack: kaya's normalized cross-axis default is leading/natural, so a
  nested *column* is only as wide as its content (rows do stretch to the
  parent's width, as the AppKit frame dump confirmed).
- **What the recording matrix's first pass left for `alignment`**
  (2026-07-20; the pipeline itself runs end to end on all five
  platforms, its traps live in docs/traps.md, and its first two finds
  — the UIKit root hugging its window, the Compose root wrapping its
  width — are FIXED and now gated by `expect_root_fills` in the grow
  scene). ~~Still alignment's to own~~ LANDED (2026-07-20): the `align`
  prop (container-level enum: start/center/end/stretch/baseline,
  rows-only baseline, first enum prop on the wire) on all four
  backends with the `expect_aligned` classification verb and the
  align scene (center + baseline asserted; end/stretch have live
  classification arms on every backend, recordings as their visual
  record until a scene earns them). The control-in-track RULING:
  the child's BOX fills its main-axis grow track (flex-item
  semantics — CSS/Flutter, and natively GTK/WinUI); whether a
  control PAINTS its whole box is platform dressing, the Zen Garden
  layer, not layout contract. Scene separability lesson paid for:
  kaya's text controls share similar baseline-to-height ratios, so
  a hug-height baseline row collapses the modes inside tolerance —
  the align scene CONSTRUCTS separation with a tall no-baseline
  image whose bottom sits on the baseline (CSS replaced-element
  rule).
  Found by adjacency during the sweep: the Swift binding's
  containerOf ACCEPTED construction-time `spacing:` but never
  applied it (one commit's worth of silently dropped writes) — and
  no gate could see it, because the interpreter's render and its
  fills observation share the node state a wire-dropped write never
  reaches; recordings are the only current gate for that class.
  Structural fix belongs to the bindings program: per-binding
  EMISSION checks (kaya_app_checks.py-style — assert the records a
  construction emits) in every language, not just Python.
  ~~The `spacing` prop~~ LANDED (2026-07-20): container-only F64,
  normalized default 8, domain-checked at the root; all four backends,
  both interpreter fills observations read the per-container value,
  sugar in all eight bindings (kwargs/chains/combinators mirroring
  grow's spellings), gated by check-sugar-surface, and exercised by
  the grow scene's row (12-unit gap) under `expect_fills`.
  The grow contract's consumption half is now gated: `expect_fills`
  (children + normalized gaps span the container's content box, both
  grow-scene containers, all seven backends, no-default
  Stage::container_fills) — added when the 540x330 default exposed
  AppKit's gravity-areas distribution pooling 200pt of leftover under
  share-green ratios; fixed with Fill distribution + the UIKit filler
  architecture (docs/traps.md has the full autopsy).
  ~~Also found comparing the matrix stills (2026-07-20): root padding
  diverges — the SwiftUI interpreter's KayaRoot carries a `.padding()`
  (~16pt) no other backend has~~ RESOLVED (2026-07-20): the normalized
  default is **16 units of inset applied INSIDE the mounted root** on
  all seven backends (AppKit edge insets, GTK CSS padding, UIKit
  layout margins, WinUI Grid.Padding, Android setPadding
  density-scaled, SwiftUI `.padding(16)` outside the offer reader,
  Compose `.padding(16.dp)` before the offer reader) — inside, so the
  root still fills its offered area and `expect_root_fills` stays
  strict. The desktop default window normalized to 540×330 (SwiftUI's
  existing size) in the same slice, keeping the grow scene's smallest
  track ~63pt, clear of GTK's 34pt control minimum. Related "presentable floor" items for the same
  milestone: a baseline alignment option for text-bearing rows (a
  switch, a label and a slider currently scatter on the cross axis),
  and — separate layer, the Zen Garden one — a way to ask for each
  platform's DRESSED widget defaults (an unstyled UIButton is bare
  blue text; every other toolkit's default button has chrome, so the
  UIKit floor reads broken when it is merely undressed).
- ~~A geometry verb for the harness~~ LANDED as `expect_shares` /
  `Stage::child_shares`, with the `grow` scene as its first user.
  Shares, not sizes: a size is a platform metric and could never be
  compared byte-for-byte, so the verb reports each child's main-axis
  extent as a whole percentage of the children's *sum* (spacing and
  padding excluded, since those are metrics too), and the scene gives
  its column nothing but growers so the split is exactly
  weight/Σweight. Traps found doing it are in docs/traps.md. The verb
  now exists in all five Rust backends and both interpreters.
  Known limitation: `expect_shares` reads back the extents a container
  recorded during layout, and on SwiftUI only the custom `Layout` path
  records them — so the verb is meaningful on containers that actually
  grow something, which is what a conformance scene always is.
- **Window vocabulary** (DESIGN open question #4): create_window,
  per-window mount targets, lifecycle (CloseRequested + veto default,
  Present, Close), sizing/titles, dialogs/modality, mobile capability
  story. Mount target 0 is reserved so the wire doesn't break. `close()`
  joins the command enum here. Unlocks the appendix's
  `app.window(title=...)` as real protocol.
- **The versioned binding style guide** (DESIGN open question #1):
  ~~construction-prop spellings~~ RATIFIED 2026-07-20 after the
  ecosystem survey (chains: Rust/Go/Java; named args:
  Swift/Python/C#/OCaml; config lists: Haskell — see DESIGN's Binding
  conventions; Rust's chain rides an ephemeral borrow-checked proxy,
  OCaml's combinators became ?grow/?spacing labels, Haskell's became
  _-variants over Cfg/BoxCfg lists). Still open here:
  ratify per-language tiers; ambient-transaction spellings; the
  eq/ne/fmt derived-signal vocabulary beyond Python; blob-signal
  ergonomics parity (Go has typed Signal[[]byte]; others wrap handles
  manually); decision gate for deleting the probe/reflection selector
  floor that the KayaGen generators superseded; optional static
  analyzers (Roslyn for C# is the plausible one; go/analysis; ErrorProne
  — never load-bearing, the runtime guards are the floor).

- ~~Backend roster: two backends on Apple and Android~~ DONE
  (2026-07-20, ratified by Akhil): **one backend per platform** —
  SwiftUI interpreter (macOS + iOS, one file), Compose (Android), GTK4
  (Linux), WinUI3 (Windows). AppKit, UIKit, and the Android Views
  backend are deleted (~3,900 lines: appkit.rs, uikit.rs, the Views
  interpreter in android.rs, five Kotlin listener shims);
  KAYA_BACKEND is gone — there is nothing to select. The JVM ring
  guests now present through Compose (KayaRing.attach registers the
  pump natives and the Activity mounts KayaCompose; transactions flow
  guest -> kaya_submit -> the same channel the pump drains, and
  occurrences fall through to the ring when no presentation sink is
  set). The Rust-side harness is cfg'd to the Rust-native backends
  (GTK, WinUI) plus tests. Capability-gap policy recorded in DESIGN's
  roster bullet: interpreter-internal per-widget drop-downs via
  Representable/AndroidView, intersection-first, each recorded with a
  conformance scene.

## Protocol / core

- **A stable identifier prop (`test_id`, doubling as the accessibility
  identifier)** — Akhil's instinct, 2026-07-20: harness scripts should
  address widgets by the same authored key on every platform, not by
  `kind#index`. Positional targets exist only because they were free
  (the per-kind driving registries already existed); an authored key
  flowing over the wire dissolves the creation-order instability
  entirely — containers freely addressable, no unique-by-convention
  discipline, no check-steps container lint, and the layout scene's
  rows become assertable instead of observation-only. Frame it as the
  accessibility identifier (accessibilityIdentifier / testTag /
  resource-id are the platform mappings) so it is a real product
  surface with the harness as first consumer, not test plumbing on the
  production wire. Cost: a Prop in spec.rs (hash moves, everything
  regenerates), a name→widget map in 7 backends + 2 interpreters, and
  a steps migration. TRIGGER: the first scene that needs to assert on
  a container the uniqueness convention cannot name — the layout
  scene already qualifies whenever its rows deserve assertions.

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

- ~~The `layout` scene is half-wired~~ RESOLVED: `layout` and `grow` are
  now built and run by every platform suite (validate-mac on both
  AppKit and SwiftUI, validate-linux on X11 and Wayland, deploy-win,
  run-sim, run-emulator on both Views and Compose). Packaging notes for
  whoever adds the next scene: iOS needs a bundle per example in
  run-sim.sh; Android has ONE apk whose guest
  (guests/rust/milestone2_android.rs) is a scene selector keyed on
  KAYA_SELFTEST, so a new scene needs a `mod` + match arm there; Windows
  needs a tools/guest/run_<scene>_<lang>.cmd plus build/scp/verify/kill
  entries in deploy-win.sh. NOTE the gap this exposed: check-steps
  validates script well-formedness and scene REGISTRATION (harness.rs),
  but nothing checks that a scene is actually RUN by a suite — a scene
  can still exist, be registered, and be exercised nowhere.
- Ergonomic: a `kaya::park(&ctx)` keep-alive primitive for static
  (handler-less) scenes, so they don't reach for `Messages::<()>` just
  to block until Shutdown (see traps.md).
- Android recording anchors flake under load: one todos-rust leg
  failed extraction with "anchor implausible (leg spans
  -10106..-6353ms)" — screenrecord buffered its start ~10s, the
  kill-minus-duration arithmetic drifted by that much, and the
  plausibility guard rightly refused to fabricate stills (the scene
  itself passed; a rerun was clean). One transient in dozens of runs,
  but the class is structural: if it recurs, Android earns a
  content-anchored scheme the way iOS earned its appearance-flip
  fiducial — the arithmetic anchor is the last one left.
- The WinUI bindings have no regeneration gate:
  crates/kaya/src/winui/bindings.rs comes from tools/winui-bindgen, but
  unlike gen-header/gen-bindings/gen-guests there is no `--check`
  proving the checked-in file matches the generator — a hand edit (or a
  filter change without regeneration) goes unnoticed until the next
  regeneration clobbers it. deploy-win compiling the file is the only
  gate today, and it proves compilability, not provenance.
- ~~Layout has no structural guard~~ SUPERSEDED (2026-07-20). The
  2026-07-19 decision was to keep layout eyeball-only and NOT build a
  geometry Stage method. That was revisited when `grow` landed, because
  a proportional split is a *semantic* contract and eyeballing it does
  not scale to seven backends. `expect_shares` is the resulting verb —
  and it earned its place immediately, catching three real bugs that
  inspection had missed (AppKit's inflated frame, GTK's CSS box, WinUI's
  track-vs-child). It works precisely because it reports SHARES rather
  than sizes, which sidesteps the original objection: sizes are metrics
  and would have been unassertable across platforms.
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
