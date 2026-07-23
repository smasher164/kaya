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
  milestone: ~~a baseline alignment option for text-bearing rows~~
  LANDED as `align` (baseline mode, rows only), and ~~the dressed
  widget defaults~~ LANDED as the dressed control floor (ratified
  2026-07-21): dress is backend normalization with zero styling API —
  iOS buttons wear SwiftUI's `.bordered` dress (the button measures
  honestly there; the wrap the naive dress first showed was the flex
  cell chain's re-proposal squeeze, fixed by KayaCell in the same
  slice), and the macOS button is permanently bridged to an honest
  `NSButton` after the
  align scene caught SwiftUI's own Button measuring borderless while
  drawing bezeled in pre-26-SDK host processes — the full mechanism
  is a DESIGN.md case analysis ("The button that measured borderless
  and drew bezeled") and the host-stamp trap is in docs/traps.md. A
  styling API remains deliberately out of scope for v1.
- ~~A KayaCell layout for the SwiftUI flex cells, then un-bridge the
  iOS button~~ LANDED in the dressed-floor slice (same commit). Probe evidence (2026-07-21, in vivo on the sim): the
  `.frame(maxWidth:.infinity, alignment:)` cell idiom PLACES a child
  by re-proposing it its own fitted size; a hugging HStack proposed
  exactly its ideal runs Apple's fair-share division with zero slack
  — the image is asked first, the button second, BEFORE the label
  releases its surplus — so the button is proposed ideal−7.33 and a
  bordered button conforms by wrapping ("tic/k") while an honest
  rigid control overflows its slot by the same amount (the ±7 spill
  visible in the bridged mac dumps: same squeeze, refused). The fix as landed:
  KayaCell fills the track and aligns the child WITHOUT re-proposing
  the fitted size (full-cell proposal at placement; cross placement
  mirrors the old frame-alignment maps). BOTH frames of the old cell
  chain were re-proposers — deleting only the outer one moved the
  squeeze down a layer, byte-identical — so the inner stretch frame
  went too, with stretch folded into KayaCell (containers fill under
  the full proposal; huggers lead, as the old explicit alignment had
  it). One dependency surfaced by the deletion: the baseline
  recording hooks are alignmentGuide closures, which run only when a
  guide is QUERIED, and the deleted frames were the accidental
  querier — KayaCell now queries the child's .top explicitly, which
  cascades through stack-derived guides into the row's text children
  (offsets=[:] at classify time is the symptom of this class). The iOS button reverted to SwiftUI's Button in the
  bordered dress (probed honest at every proposal, .unspecified
  included, in kaya's own 26.5 generation); the macOS NSButton
  bridge stays — the compat generation lies at every proposal UNDER
  EVERY STYLE (automatic/bordered/prominent all 38x20-vs-52x32,
  kaya-free repro), which no cell fix can absorb. The align matrix
  and ±2 cross-axis tolerances re-proven in the same slice.
- The stock stacks' nil-frames are re-proposers too, in theory. A
  constraint-less `.frame` around a stock stack's child still places
  by re-proposing the child's fitted size; today every stock-branch
  child is a control (idempotent under its own size) or a container
  whose squeeze no scene constructs, so nothing observable fails. A
  KayaStretchCell replacement was attempted in the dressed-floor
  slice and RETREATED: a custom Layout does not forward alignment
  guides (baseline rows classified "mixed") and its guide-forwarding
  overloads SIGTRAPed the gallery leg — a correct replacement must
  forward guides for real, and per doctrine the failure wants a
  CONSTRUCTED failing scene (stock column in stock column with a
  bordered-button row) before the next fix attempt.
- An `expect_honest` gate: measured-vs-drawn self-agreement per
  control. The dressed-floor hunts exposed two symptom shapes the
  geometry gates are structurally blind to — a control whose caption
  wraps or truncates still classifies and fills correctly (the
  "tic/k" wrap shipped through two 18/18 iOS runs). Both shapes share
  one observable: the control's DRAWN box diverges from its honest
  ideal (wrapped pill 42.67x56.33 vs ideal 51.67x34.33; a compat-mac
  liar diverges the other way). Design: record each control's
  answered ideal (sizeThatFits(.unspecified) — stable like a font
  metric, so the recording trap does not apply) alongside the
  existing drawn-geometry readers, and a verb compares them under
  ample space. Interpreters first (the historic miss layer), then the
  native backends' analogs. Caveat named by the mac experiments: in
  a compat-stamped process the SwiftUI-side layout box and the AppKit
  PAINT disagree while both SwiftUI numbers agree — catching that
  class needs the AppKit frame walked, which the bridge already
  makes moot for buttons; scope the first cut to SwiftUI-side
  self-agreement.
- The suite runners screenshot AFTER teardown. run-emulator's
  android-shot-*.png and run-sim's leg captures race app exit and
  mostly record the home screen (207KB of wallpaper, byte-identical
  across legs) — useless as visual evidence and confusing next to
  real stills. Move the capture to before the final step/exit, or
  drop it and keep the recording pipeline as the visual record.
- ~~Window-event surfaces in the remaining five languages~~ LANDED:
  windows part 3 shipped the window-shape parser branches + event
  sugar in every language, and the desktop-legs slice closed the last
  gap — swift and java now run panels LIVE on mac (swift via the mac
  guest build, java via the desktop JVM tier), byte-identical with
  the other six.
- ~~A modern-stamp SwiftUI leg~~ LANDED, structurally: the Swift mac
  guests are compiled by the system toolchain against its SDK, so
  every swift-swiftui leg in validate-mac IS a modern-generation leg
  — align (button metrics, the stamp-sensitive scene) passes
  byte-identical beside the compat fleet, proving the NSButton bridge
  stamp-independent on every suite run. The guidance below remains
  load-bearing. The nix shell links every other leg binary
  against its pinned SDK (audit 2026-07-21: python3/go/dotnet/ocaml/
  rust 14.4, zulu JDK 11.3), so those legs exercise SwiftUI 26's
  COMPATIBILITY design generation — now the covered-on-purpose
  counterpart to the swift legs' modern generation.
  Do not bump the flake SDK without
  preserving a compat-generation leg — that is the generation real
  JVM/.NET-hosted apps will sit in for years, and where the Button
  measurement bug class lives. Vendor audit (2026-07-21, official
  binaries, LC_BUILD_VERSION sdk field): .NET host 10.0.10 = 15.5,
  .NET 11-preview.6 = 15.5, apphost stub = 15.5; zulu jre 21/25 =
  13.3, Temurin 21 = 14.2, Oracle JDK 25 = 14.5. No vendor ships a
  ≥26 stamp; nixpkgs' darwin `openjdk17` IS repackaged zulu (no
  source-built lever). The compat generation is a permanent
  first-class citizen, and the native-kit button bridges are
  load-bearing indefinitely, not transitional.
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
- **Window vocabulary** (DESIGN open question #4): LARGELY LANDED
  through the window/panels/confirm/nav/sections scenes —
  create_window, per-window mounts, CloseRequested + veto,
  destroy_window, titles/sizing, modal alerts (show_alert), serial
  navigation, sections with the window-scoped presentation hint, and
  the unified window-attribute spelling (2026-07-22: the window
  construct carries EXACTLY create-window's prop set in every
  binding; the window_title/window_size shortcuts are retired).
  Still open: presentation styles beyond the primary set (utility
  panels, always-on-top), and whatever the style guide ratifies for
  multi-window ergonomics.
- **The versioned binding style guide** (DESIGN open question #1):
  ~~construction-prop spellings~~ RATIFIED 2026-07-20 after the
  ecosystem survey (chains: Rust/Go/Java; named args:
  Swift/Python/C#/OCaml; config lists: Haskell — see DESIGN's Binding
  conventions; Rust's chain rides an ephemeral borrow-checked proxy,
  OCaml's combinators became ?grow/?spacing labels, Haskell's became
  _-variants over Cfg/BoxCfg lists). Still open here:
  ratify per-language tiers; ambient-transaction spellings (OCaml's
  is RATIFIED 2026-07-22 — direct style over an ambient tx ref, plus
  curried children: creators end in (), the omitted unit is the child
  form, containers realize lists left-to-right; the let*/decl reader
  is deleted — see DESIGN's Binding conventions and docs/traps.md's
  right-to-left entry); the
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
  crash even with the metadata provider — RESOLVED 2026-07-22: the
  merge landed (tiered, in OnLaunched) and works with the provider;
  the real constraint was pri adjacency (traps.md).
- Programmatic-echo divergence on slider/checkbox/entry — RESOLVED
  2026-07-22 same day (Akhil: "we should do it now; it could lead to
  an infinite loop"): GTK and WinUI now arm an apply_quiet guard
  around every interactive SetProp, so property writes never echo on
  any backend; commands (clear) and the stage's direct writes emit
  like the user ON PURPOSE (the entry scene's second-add round
  depends on clear's echo). Ratified in DESIGN.md (Binding
  conventions) and the spec's occurrence docs. The gallery scene's
  quarter button + signal-bound slider is the standing negative test
  (a programmatic write, then the assertion that the fold did NOT
  run); signal-bound slider value sugar now exists in all 8
  languages (was python-only).
- Matrix speed: bounded-retry expects — LANDED 2026-07-22, same
  day it was ratified. Every observation step polls at 20ms to a 5s
  deadline (harness.rs is the norm; both interpreters carry the
  step-level twin); scenes lost their settles (ONE deliberate one
  remains: gallery's echo test asserts an ABSENCE, which polling
  cannot prove); scripts open with an expect (check-steps' opening
  lint, replacing the pacing lint); GTK/WinUI harness reads are
  TOTAL (try_resolve / on_ui_read — a missing target or
  mid-materialization error is a retryable miss, never a panic).
  Measured: leg phases mac 52s->18s, linux 132s->71s, windows
  95s->57s, iOS 83s->51s, android 57s->45s; serial matrix 8m28s ->
  ~6m03s. SECOND PASS landed same day: mac guest builds pooled
  (38s->12s; per-language jobs + pooled swiftc), windows deploy
  stamp-skip + batched Get-FileHash + SSH ControlMaster mux (deploy
  21s->4s, suites 53s->40s — the mux carries every schtasks/poll
  round trip), iOS per-scene compiles pooled + sims 2->3 (builds
  32+19 -> 23+15), android emus 2->3 (legs 23+22 -> 18+15). Serial
  matrix now ~4m20s warm (mac 55s, linux 1m14s, windows 47s, iOS
  ~48s, android 43s); concurrent bound = linux. THIRD PASS same day: linux
  container builds pooled (dotnet/javac start before the cargo build
  — they never link libkaya; dune/cabal/go/C pool after it) —
  container phase 71s->49s, wall 50s. Every lane now runs under a
  minute: mac 55s, linux 50s, windows 47s, iOS ~48s warm, android
  43s — serial ~4m03s, concurrent bound ~55s. Remaining (diminishing
  returns): a real swiftmodule for the Swift bindings, VM with more
  cores. The
  rollout also flushed out four REAL WinUI bugs the settles had
  preserved (see traps.md).
  The original benchmark record: (benchmarked 2026-07-22; the
  full writeup is the "matrix gets a stopwatch" artifact). Per-leg
  instrumentation across all five runners showed 70% of the matrix's
  1,767 leg-seconds are scripted settle floors (settle 1500 openers
  + 400-700ms post-action settles; scene cost ranks by settle
  budget). The structural fix (RATIFIED 2026-07-22, Akhil: bounded
  polling uniformly, for one unified testing solution): make `expect`
  a BOUNDED RETRY — poll the predicate at ~10-20ms until match or
  deadline — everywhere, including the scene-open wait (the first
  expect simply polls until the scene renders); no per-platform
  event-driven variants. Then drop the settles: fixed sleeps become
  actual latency, the pacing race class dies at the root (retiring
  check-steps' pacing lint), estimated 50-65% leg-time saving. This
  is the NEXT infra move, green-lit after "add select" landed. Secondary levers:
  wider windows/phone pools (their x2.5-3.9 parallelism is
  device-bound, not leg-bound), skip-unchanged windows deploy (20s),
  pooled mac guest builds (29s serial), iOS bindings compiled once
  as a module (~60s of per-scene swiftc).
- Mount-transaction focus negative test: the Focus command now
  defers until the element is loaded/mapped on WinUI/GTK (the
  materialization class, traps.md), but no scene issues focus IN the
  mount tx — the entry scene focuses from the add fold, long after
  load. The class fix is structural; the missing gate is a scene (or
  an entry-scene opening step) that focuses at mount and asserts
  expect_focused, proving the deferral on all platforms.
- TextArea — RATIFIED-WANT (Akhil, 2026-07-22): the multi-line
  entry. Near-free under current machinery: a kind reusing
  text_changed, the uncontrolled contract, and the clear/focus
  commands; native editors everywhere (TextEditor, multiline M3
  TextField, GtkTextView, multiline WinUI TextBox). Slot before the
  sections/menus design passes.
- resize_window harness verb (Akhil asked 2026-07-22): backends
  reflow natively on user resize but the matrix never drives one —
  add a verb that resizes the REAL window then re-asserts
  root_fills/shares/fills, making reflow-under-resize a matrix fact.
  Also the place to watch WinUI's known interactive-resize flicker
  (platform-level; we already avoid the transparent-background worst
  case — keep WinAppSDK current).
- Select follow-ons, each waiting on a REAL need: a template
  (For-body) select only gets the stateless index checks — the
  option-count upper bound is live-widget-only (the count map keys
  on live ids); option disabling; multi-select (a different control
  on every platform — checkable menu items, list boxes — probably a
  separate kind); signal-bound OPTION LABELS work today (label text
  binding fans out to the rows), but signal-bound option LISTS
  (dynamic add) are append-only via add_child with no remove.
- Canvas widget (Akhil, 2026-07-22; post-style-guide, before webview):
  a drawing surface. The viable shape is a DISPLAY LIST — the guest
  transmits drawing commands (paths, fills, strokes, transforms, text
  runs) as data; core retains it as a prop; backends replay it into
  the native surface (SwiftUI Canvas, Compose DrawScope, GTK4
  DrawingArea/cairo; WinUI needs Win2D CanvasControl — a new NuGet
  dependency and packaging payload). Callback-per-frame immediate
  mode is REJECTED (8-language FFI churn, divergent frame timing).
  The slippery slope is the op vocabulary (gradients, blend modes,
  images, text shaping) — start with a deliberately minimal op set.
  Pointer-event occurrences on the canvas are a further deferral
  inside this one.
- Webview widget (Akhil, 2026-07-22; deferred furthest — the
  framework inside it is the entire web platform): minimal uniform
  surface is load-URL/load-HTML plus a navigation-requested veto
  (fits the existing veto grammar). The hard parts are the four
  embedders (WKWebView, WebView2, Android WebView, WebKitGTK) whose
  JS-bridge/cookie/permission models diverge, and distribution
  (WebView2 Evergreen runtime, webkit2gtk distro variance) — both
  land on the packaging milestone. A user-facing native-view escape
  hatch is NOT the default answer (breaks the cross-platform promise
  per-widget, forces per-platform guest code).
- Packaging: at-release items — Hackage/opam publication, Go vanity
  import path (akhil.cc/kaya + go-import meta; dev.kaya is
  unpublishable), Maven publication under cc.akhil, npm kaya-gui after
  account recovery; a LICENSE decision before any real release;
  trusted publishing (OIDC) on nuget/PyPI/npm when releases start.
  Android Python/Go guests need binding bootstrap (briefcase/gomobile).
  Swift SPM packaging needs a modulemap target.
  APP-DISTRIBUTION PAYLOADS (Akhil, 2026-07-22): a user who imports
  kaya and ships an app must get every runtime artifact the platform
  needs, per platform, without reading our runbooks. The inventory
  the suites already prove out: WINDOWS — resources.pri beside the
  PROCESS exe (the pri-adjacency rule in traps.md; for dll-hosted
  languages the packaging story must place it beside the interpreter
  or ship an apphost), the WindowsAppRuntime bootstrap dll, and
  kaya.dll on PATH; MAC — libkaya.dylib plus the SwiftUI interpreter
  dylib (KAYA_SWIFTUI_LIB or dyld-adjacent); iOS — both inside the
  bundle (the run-sim make_bundle recipe is the spec); ANDROID —
  libkaya.so in jniLibs + the Kotlin interpreter classes; LINUX —
  libkaya.so with the GTK backend compiled in. Each language's
  package should carry or fetch these so `pip install kaya-gui` /
  `go get` / `cargo add` yields a runnable, distributable app —
  wheels with platform tags, cargo build-script asset embedding,
  gradle AAR, etc. This is the packaging milestone's acceptance
  test: a fresh machine, one package-manager install, one binary
  handed to a friend.
- Alert relaxations, each waiting on a REAL need, none speculative:
  programmatic dismissal (a guest-side cancel verb — rare; adds a
  second retire path to a grammar whose whole point is ONE),
  per-window alert concurrency (the process-wide one-live-alert
  floor is ContentDialog's per-root rule spelled strictly; relaxing
  means per-window slots and a WinUI carve-out), and a third-plus
  action (the platform floor is ContentDialog's two-actions-plus-
  close; more means a custom row on WinUI — no longer the dressed
  floor).
- ~~Scroll BREADTH~~ LANDED 2026-07-22 (uncommitted): 8 guests
  byte-identical, scroll in SCENES on every runner; GTK
  ScrolledWindow (vadjustment = observation source AND the API
  scroll_end drives; vertical-only policy) and WinUI ScrollViewer
  (ScrollableHeight/VerticalOffset + ChangeView; bindgen filter grew
  ScrollViewer/ScrollMode/ScrollBarVisibility) live; Compose
  verticalScroll proven on the emulator. Still open from the depth
  ledger: horizontal axis (an axis enum prop — decide when a scene
  needs it) and For-in-scroll virtualization (protocol backlog).
- ~~Navigation BREADTH~~ LANDED 2026-07-22 (uncommitted): all 8
  languages' sugar + nav guests byte-identical (nav in SCENES on every
  desktop runner); GTK materialization (header-bar back button — the
  REAL affordance, emit_clicked-driven — entry-title-as-window-title
  with restore, destroy sweeps stacks); WinUI materialization (wrapper
  Grid back bar, automation-peer press, same title discipline); both
  reconcile the core via scene.user_popped on their own sinks. Mobile:
  Compose BackHandler + task-label title materialization; iOS
  NavigationStack with the model-title read (no title bar). HANDLER
  REWORK ratified mid-breadth (Akhil): per-entry popped/back handlers
  ride the push (chain/named-arg/config-list per language; Rust =
  msgs.on_entry_popped(entry, msg), the alert spelling); app-global
  navigation handlers DELETED everywhere; entry_popped registration is
  one-shot and retires with the pop, taking the entry's back
  registration; registrations on programmatically-popped entries go
  inert (the widget-handler discipline). Recorded in DESIGN.md's
  Navigation section. Still open from the depth ledger: (1)
  pop_to_root/pop(n) sugar + the binding stack mirrors it needs; (2)
  the macOS `back` verb drives the path binding (GTK/WinUI/Compose
  drive real chrome; mac needs a stable handle on NavigationStack's
  private toolbar button); (3) signal-bound entry titles have wire +
  scene + fan-out but no binding sugar.
- ~~A java leg on Windows~~ LANDED: 12 java legs in deploy-win (60
  checks total) — sources shipped, javac IN PLACE on the VM (the C#
  ship-and-build precedent), quote-free run_ssh lines (the sshd
  re-wrap trap), idempotent ARM64-JDK provisioning (Microsoft
  OpenJDK 17 via winget with --architecture arm64 — winget's default
  under the emulated shell is x64, whose JVM cannot load the aarch64
  dll; zulu ships no arm64 winget package). The desktop JVM tier now
  runs live on all three desktops.
- Swift guests on Linux and Windows. Upstream swift.org toolchains
  exist for both, but neither pinned world (docker image, VM) carries
  one, and the swift SURFACE is already fully proven — typecheck on
  two Apple targets plus 11 live mac legs and the iOS suite. The
  value would be backend×language matrix breadth, not new surface
  proof; take it only if a real swift-on-linux/windows user appears.
- Node.js guest (the roster's first async surface): Node first;
  function-floor tier via N-API (V8 pointer compression forbids
  external ArrayBuffers over native memory — no direct ring);
  main thread blocks in kaya_run, app logic in a worker; layer 3 wants
  for-await occurrence iteration.
- Arena offset+length form (row batches, audio) — returns when the row
  window and audio land; the blob table is its v1 realization.
- Attach/embedding tooling rework (parked at milestone 0).

- WinUI sections on NavigationView: RESOLVED and SHIPPED (2026-07-22
  third pass) — the crash was the aggregation outer refusing to
  delegate QI (docs/traps.md); with the hand-rolled KayaOuter the
  ratified NavigationView materialization is live on all five
  windows sections suites. The KAYA_WINUI_NAV_PROBE instrument
  stays for future control triage.
