# Traps — expensive lessons, already paid for

Each of these cost a debugging session (or would have). Most now have a
structural guard; the guard is named where it exists. Do not re-derive
these the hard way.

## Platform / toolkit

(Entries about AppKit, UIKit, and Android Views survive their backends
— the roster is one backend per platform since 2026-07-20 — because
the same patterns return through interpreter drop-downs
(NSViewRepresentable/AndroidView) and sibling toolkits.)

- **Layout readback must use the layout rect, never the drawing box.**
  Every toolkit separates the rect it *allocated* to a widget from the
  box it *draws* it in, and only the first is what a layout contract
  talks about. Three dialects of the same trap, all met while landing
  `grow`: AppKit inflates a slider's frame 2pt a side past its
  alignment rect (read 1:3 as 2.90:1); GTK's Adwaita theme insets a
  button 10pt inside its allocation via the CSS box (27/73); and on a
  WinUI Grid the layout rect is the *track*, not the child — a
  TextBlock reports its text height however tall its row is, so
  reading children gave 37/63. Every time the layout code was right and
  the *measurement* was wrong, which is the expensive way to debug it.
  Use `alignmentRectForFrame(frame)` on AppKit, `allocation()` rather
  than `width()`/`height()` on GTK, and `RowDefinition::ActualHeight`
  rather than the child's `ActualHeight` on WinUI. Guard:
  `Stage::child_shares` states it in its contract, and the `grow` scene
  fails loudly when a backend ignores it — which it did, for all three.
  Fourth dialect, met landing `expect_fills`: GTK4's own
  `width()`/`height()` are the CONTENT box — CSS padding lives outside
  the widget's coordinate space, and child allocations are
  content-relative — so subtracting the root's `.kaya-root` padding
  from them double-counts it (read a filling root as "259px spanning
  227px"). Every OTHER backend's own-extent read is the border box and
  DOES need its insets subtracted (AppKit bounds vs edgeInsets, UIKit
  bounds vs layoutMargins, WinUI ActualSize vs Padding, Android
  getHeight vs getPadding*).
- **A conformance scene must keep every share above every platform's
  minimum control size.** A share below it is clamped by the toolkit,
  and the scene then silently measures the minimum instead of the
  contract. Three shares of a 144pt column put the smallest at 28pt,
  under GTK's 34pt minimum button height; the `grow` scene uses two
  children at 25/75 (38 and 114pt) for exactly this reason.
- **A failing Windows leg used to report PASS.** WinUI's window-`Closed`
  handler called `request_exit(0)`, and `Application.Exit()` closes the
  window — so a failing verdict stored 1, Exit() fired Closed, and the
  handler overwrote it with 0 microseconds later. deploy-win greps
  `EXIT=0`, so a scene printing `KAYA_SELFTEST: FAILED` reported PASS,
  and had done for every Windows failure there has ever been. Two
  guards: `request_exit` is now first-writer-wins (whoever decides the
  outcome owns it; a window closing afterwards is a consequence, not a
  new decision), and deploy-win now treats the *verdict text* as
  authoritative with the exit code only corroborating — so any future
  way of losing the code is caught whatever its cause. The general
  lesson: a runner that reads only an exit code trusts every layer
  between the assertion and the process boundary.
- **An interpreter leg inherits the previous group's scene script.** The
  Rust backends embed their script at build time (`include_str!`), but
  SwiftUI and Compose read `KAYA_SELFTEST_SCRIPT` from the environment —
  and validate-mac exports it once per scene group. A new leg added
  after a group therefore runs the PREVIOUS scene's script against the
  new scene's tree, which surfaces as an index-out-of-range deep inside
  the interpreter, not as anything resembling "wrong script". Every
  interpreter leg must export its own script immediately before it.
- **The interpreters resolved `kind#index` by index alone.** `row#0`
  silently read `columns[0]` — a wrong-widget read, the false-verdict
  class — and a malformed or out-of-range index was a hard trap
  (Swift's "Index out of range") rather than a failure. check-steps
  parses every checked-in scene with the RUST grammar, so only an
  env-supplied script could reach it, which is exactly how it was found
  (a hand-run `expect_shares row#2` probe). Both interpreters now match
  the kind against the registry the verb reads and bounds-check the
  index; the outcome is a loud "no such target …", never a crash and
  never a misresolved read.
- **SwiftUI runs speculative layout passes at ARBITRARY sizes, in no
  useful order — never record observations from inside a pass.** First
  the zero-size flavor: placements at `bounds == .zero` arriving after
  the real ones clobbered a correct 96/286 into 0/0. The zero-guard
  that fixed it then lost to the general flavor: a pass at the row's
  NATURAL width arrived after the real full-width one and clobbered a
  correct 25/75 into 26/74 — positive, plausible, unfilterable by any
  size heuristic. The structural fix is the one Compose had from day
  one (onGloballyPositioned): record from GeometryReaders, which only
  ever describe the RENDERED result. Each flex child rides in an
  invisible max-size frame that accepts its track proposal, and
  KayaTrackReader on that frame records the track — the layout rect,
  not the child's drawn size; the root and its offered area are read
  the same way for expect_root_fills.
- **A widget that does not fill its assigned track lies beneath a
  passing `expect_shares`.** The verb reads the layout rect (correctly —
  see the first trap), so a size cap on the CONTROL keeps the gate green
  while the screen shows something else: the SwiftUI interpreter's
  Slider carried `.frame(maxWidth: 200)` — its stand-in for a natural
  width SwiftUI sliders do not have — which capped the drawn control
  below its track and rendered the layout scene's 1:3 row as 38/62
  while KayaFlex had assigned a contract-exact 125pt/375pt. The
  hypothesis recorded at the time ("SwiftUI's minimum Slider width
  clamps the share") was wrong; pixel-measuring the still against the
  arithmetic pinned the cap in one pass. Growers now lift the cap
  (weight-0 sliders keep the 200pt stand-in), and the recording
  pipeline is the guard for the drawn layer — this divergence class is
  precisely what it exists to catch.
- **`layoutPriority` is SwiftUI's version of the ordinal trap.** It
  looks like the proportional knob and is not: it decides the *order* in
  which children claim scarce space, never the ratio. `.frame(maxWidth:
  .infinity)` is the other near-miss — several flexible children split
  the remainder *equally*. SwiftUI has no per-child weight, exactly like
  GtkBox and the two Apple stack views; the `Layout` protocol is the
  sanctioned way to add one (and the sanctioned replacement for the
  older GeometryReader hack, which fills greedily and breaks the
  surrounding sizing).
- **A VStack returns its natural size however large a frame it is
  offered.** `.frame(maxWidth: .infinity, maxHeight: .infinity)` makes
  the FRAME fill; the stack inside is then aligned within it at its own
  size. So wrapping the mounted root in a big frame does not make the
  root fill, and nothing below it ever has leftover space to divide.
  The root has to be a layout that accepts the proposal.
- **The Linux container is not a nix dev shell.** `harness-extract.sh`
  guards on `KAYA_DEV_SHELL` and refused inside the image, so recording
  mode on Linux passed every leg and produced NO stills at all — a
  silent, complete loss of the artifact the run existed to make.
  `tools/linux/run-suites.sh` now computes and exports the fingerprint.
  The general shape: a guard meant to catch "wrong toolchain" fires
  inside a container that is the pinned toolchain by other means.
- **`simctl recordVideo` is observable only through its own log line.**
  Its output file stays ZERO bytes until finalize (a growth poll can
  never prove liveness — one burned 20s and then killed a healthy run),
  it starts capturing at an unknown moment after launch, and it drops
  its buffered tail on stop. The one true signal is the "Recording
  started" line it prints; wait for that before planting any fiducial,
  or the film contains neither flip edge and the run dies at
  extraction AFTER every leg passed. Two corollaries paid for
  separately: a fiducial stamp must be written only for an OBSERVED
  render (a poll that times out and stamps anyway anchors the film to
  a moment that never appeared in it), and a fiducial is an EDGE,
  never an absolute level — the simulator home screen accumulates one
  bright placeholder icon per installed scene bundle, and by this
  milestone "dark" read YAVG 107, over the fixed <100 threshold, while
  the flip's drop stayed a clean 68. Detect the drop (or, if the
  recorder attached mid-flip, the rise back), each anchored to its own
  stamp — and normalize the appearance to light BEFORE flipping: the
  pool keeps whatever appearance the previous run left, an aborted run
  leaves it dark, and no drop can fire from a dark base.
- **Stills accumulate across runs when a scene's script changes
  shape.** Extraction overwrites stills by step name, so a scene whose
  script shrank leaves orphans from the longer version — the count
  guard then reads 13/10 stills as extraction breakage on an otherwise
  green leg (every Android todos suite tripped at once). Extraction
  now clears `step-*.png` before writing; stills are derived data with
  no history worth keeping.
- **An arithmetic video anchor drifts, and a leg that exits right after
  its last step leaves only teardown frames under its terminal
  expects.** The GTK stills were the bare Xvfb root — but not for the
  reason first written down (the ledger guessed "every frame lands on
  teardown"; measuring the film showed the window visible from frame 0
  to 100ms before the recorder stopped, and the SETTLE stills were fine
  all along). The real mechanism needs two halves: the verdict-and-exit
  follows the final expect by milliseconds, so the window's close sits
  within ONE 15fps frame period of the last sampled moment; and the
  `kill-time − duration` anchor drifts ~150ms, which is two frames at
  that rate — enough to push the covering frame into the dark tail.
  Diagnose this class by measuring, not guessing: a per-frame
  `signalstats` YAVG scan of the film locates the window's visible span
  in seconds. (Mind the range conversion: yuv420p limited-range video
  reads ~16 dark/~34 bright where the same frames as full-range PNGs
  read ~0/~21 — comparing the two uncorrected "proves" a bright still
  dark.) The structural fix is `record_linger` in harness.rs, mirrored
  in both interpreters: under KAYA_RECORD or KAYA_HARNESS_GATE a leg
  holds its window 750ms past the last step, so every sampled moment is
  a live one whatever the anchor error. The runners thread the flag to
  where guests can see it (SIMCTL_CHILD_KAYA_RECORD on iOS, an
  `--es KAYA_RECORD 1` extra on Android); Windows needs none of it —
  its WGC capturer names frames by VM-clock epoch, one clock end to
  end, and window-scoped capture simply stops at close instead of
  filming black.
- **GTK 4.12 spells baseline alignment BASELINE_FILL, and its
  per-child allocated baselines are not comparable across widget
  kinds.** The boxes legitimately FILL the row under baseline
  alignment (a stretch-shaped geometry), and `allocated_baseline`
  reports different anchors per kind — 37 for a label beside 27 for a
  button whose captions were screenshot-verified ALIGNED (and a
  CheckButton's anchor is different again — the align scene uses a
  button, not a checkbox, for its second text child). The honest GTK
  observation is PARTICIPATION: baselines are allocated (>= 0) into
  children only under baseline mode and read -1 under every other, so
  "filled + two participants" is the discriminator, and the agreement
  itself stays GTK's — the root_fills precedent of leaving a
  platform's own notion to the platform.
- **A WinUI measure before the first real layout reads zero text
  metrics, silently.** Baseline compensation computed at apply time —
  UpdateLayout on a detached or just-attached grid — got BaselineOffset
  and ActualHeight of ~0, produced ~0 margins, and the row classified
  "start" through two full VM cycles. FrameworkElement.Loaded fires
  after the first real layout; metric-dependent passes hook it as a
  one-shot. Corollary ruling implemented there: a child with no text
  baseline contributes its BOTTOM EDGE as its baseline (the CSS
  replaced-element rule) — text-only compensation aligned label to
  checkbox at ~14dip, left the tall image at the top, and was
  geometrically indistinguishable from start.
- **A conformance scene must CONSTRUCT its geometric separability,
  never inherit it from platform metrics.** kaya's text controls share
  similar baseline-to-height ratios, so a hug-height baseline row
  collapses start/center/end/baseline inside the classification
  tolerance (measured: on macOS baseline placement equals center
  EXACTLY with a label beside an entry). The align scene's tall
  no-baseline image — whose bottom sits on the baseline — stretches
  the cross axis so the modes land tens of points apart on every
  platform. The grow scene's minimum-control-size rule was this same
  lesson's first spelling.
- **Android's addView installs fresh layout params.** A weight written
  before the child was attached is discarded by the add, so
  `layout_weight` has to be re-stamped from AddChild as well as from
  the prop write.
- **A WinUI Grid places by attached property, not child order.** Unlike
  a StackPanel, a Grid puts each child where its `Grid.Row`/
  `Grid.Column` says, and two children sharing an index silently
  overlap rather than erroring. Appending to `Children` in the right
  order does nothing on its own; the backend tracks logical order
  itself and restamps the indices after every add, move, and destroy.
- **A GTK child hugs where an AppKit contentView fills.** The mounted
  root obeys its own align on GTK, so it sat in the top-left at natural
  size and left no free space anywhere in the tree — every grow weight
  then divided nothing. The backend now forces Fill on the root; the
  normalization is recorded in DESIGN's layout worklist.
- **A share-green backend can still be POOLING the leftover beside its
  children — root_fills does not close the class, it only closes the
  root-level instance.** AppKit's NSStackView under its default
  gravity-areas distribution simply never enforces the optional bottom
  pull (the 250-priority edge pin goes unsatisfied while cost-1
  huggings sit right there to stretch — constraintsAffectingLayout
  shows the pull absent from the binding set, not outvoted), so the
  pairwise ratio constraints held at their MINIMUM: 20/32/40pt tracks
  in a 298pt column, shares an exact 25/25/50 (the button's 32pt frame
  is a 20pt alignment rect — ratios hold in alignment space), root
  full-size by construction (the stack IS the contentView), every gate
  green, 200pt of dead slack on screen. Found only because the 540x330
  window default made the slack unmissable where 320x160 had hidden it
  (~24pt). Fix: distribution=Fill + the same hidden trailing filler
  UIKit uses (fill must hand the leftover to SOMEONE; the filler is
  that someone until a weight appears — setDetachesHiddenViews(true),
  or a hidden NSStackView filler still occupies layout, unlike
  UIStackView's always-excluded hidden arranged views). Guard:
  `expect_fills` — children (plus normalized gaps) must SPAN the
  container's content box, asserted for both containers in the grow
  scene on all seven backends; `Stage::container_fills` is no-default
  so a backend cannot skip it silently. Diagnosis pattern worth the
  price of admission: attach lldb to the live process and ask the
  engine (`_subtreeDescription`, `[view constraints]`,
  `constraintsAffectingLayoutForOrientation:`), then TEST the fix by
  mutating the live process (`setDistribution:` + layout) before
  writing a line of Rust.
- **A share-green backend can still be rendering the contract inside a
  hugging root — and did, twice more.** UIKit's root was pinned
  top+leading only (a pre-grow choice to dodge distribution=.fill's
  balloon pathology), so the grow scene's 25/75 held as a ratio over a
  few dozen points and rows hugged their widths, collapsing sliders to
  thumbs; Compose's root Column wrapped its WIDTH even while weighted
  children filled its height. `expect_shares` is blind to all of it by
  construction — a share is a percentage of the children's sum, and the
  sum's absolute size never enters — so every suite stayed green until
  the first iOS recording showed the nubs. Three lessons now structural:
  UIKit fills its safe area with a hidden trailing FILLER per container
  absorbing the leftover whenever nothing grows (UIStackView has no
  gravity distribution, so something must lose the stretch contest;
  the filler hides the moment a weight appears, and the child-reading
  observations skip it by pointer); nested containers whose main axis
  crosses their parent get an explicit breadth constraint (a row spans
  its column's width — the near-native behavior every other toolkit
  ships); and `expect_root_fills` in the grow scene now gates the
  whole class — the root's placed size against the platform's own
  offered area, byte-identical "root fills" everywhere, platform
  numbers only in the failure text.
- **ART truncates VarHandle byte-buffer-view addresses to 32 bits** in
  the interpreter, and its `Unsafe` (Object, long) volatile accessors
  are heap-only. The working JVM ring formulation: Unsafe absolute
  plain loads/stores + explicit load/store fences, bound as
  MethodHandles, invoked via invokeExact. Never NewDirectByteBuffer for
  ring access — pass raw addresses as jlong.
- **D8 desugars Java records on Android** regardless of minSdk — ART
  never sees record components, `isRecord()` is false. The reflection
  fallback reads the single constructor's parameter names (gradle adds
  `-parameters`) and matches zero-arg accessors by name.
- **SerializedLambda/writeReplace does not exist on D8-desugared
  lambdas** — the MyBatis-Plus selector trick is desktop-only; probe
  records work everywhere.
- **AppKit: a focused NSTextField's firstResponder is its field
  editor**, not the field — check `currentEditor().is_some()` for
  focus. Programmatic `setStringValue` does NOT fire
  controlTextDidChange — re-fire the delegate's emit explicitly (UIKit
  `setText` likewise needs `sendActionsForControlEvents`); GTK, WinUI,
  and Android fire their change paths on programmatic set.
- **GTK: a focused GtkEntry delegates to its inner GtkText** —
  `is_focus()` on the entry is always false; read
  `state_flags() & (FOCUSED|FOCUS_WITHIN)`.
- **Android density-scales Drawable intrinsic sizes** — for pixel-exact
  observations read the Bitmap's own width/height, never
  getIntrinsicWidth/Height.
- **objc2: `UIImage::size` is unsafe where `NSImage::size` is safe**;
  `gdk::Texture::from_bytes` is feature-gated (`gtk4` `v4_6`).
- **windows-bindgen type filters do not pull referenced types
  transitively** — a class named only in a hierarchy or method
  signature must be an explicit filter, or bindings.rs is uncompilable
  (or silently missing methods, e.g. an async method whose operation
  type is unfiltered). windows-future 0.3 spells the blocking wait
  `join()`, not `get()`.
- **WinUI code-only apps need a composed Application implementing
  IXamlMetadataProvider** (COM aggregation via
  IApplicationFactory::CreateInstance) or library-type XAML lookups
  fail-fast; a plain #[implement] outer does not delegate QI — keep the
  Application handle, never Application::Current(). Exe-adjacent
  resources.pri required.
- **Rebuilding a screen-capture binary in place poisons its TCC
  identity** (survives reboots) — content-hashed binary names, one
  build per source version.
- **WerFault suspends crashing Windows processes** — tasklist reads
  corpses as alive; wait out WerFault before probing. Hung guests hold
  the DLL and block redeploy — sweep guest images before deploy.
- **OCaml ctypes `foreign` without `~from:lib` resolves against the
  process image** — finds dlopened symbols on macOS but NOT Linux.
  Always bind `~from:lib`.
- **Cabal-linked binaries need explicit `-optl-Wl,-rpath`** on Linux;
  dune's `_build` is platform-blind (separate `--build-dir` for
  containers); `eval $(opam env)` is what provides OCAMLPATH.
- **adb shell re-parses `am` args on-device** — `;`-folded script
  extras need device-side single quotes or the separators execute as
  shell commands.

## Language / binding semantics

- **Swift result builders skip declarations and assignments** — `let x
  = tx.entry(...)` inside a builder never reaches buildExpression.
  Never hang semantics on expression position; kaya parents at
  CREATION through zone-tagged ambient frames (guard: cross-zone
  creation fails loudly).
- **Blob (bulk-byte) fields cannot rebuild from wire values** — the
  wire carries handles, not bytes. Rebuild-through-wire paths
  (Swift token-form updateField, generated init(values:)) are guarded
  loudly; the key-path/model-value form is the primitive. Selector
  probes must stay PURE — encoding now has registration side effects,
  so probes use separate projections. Java byte[] probe sentinels must
  be identity-stable singletons (array equality is identity).
- **Haskell's lazy store-back can poison IORefs** under
  catch-and-continue dispatch — a throwing pure Build must be forced
  (`evaluate`) at the boundary BEFORE any IORef write, or the
  exception detonates transactions later. Registration-ordering seam:
  `bRecords :: IO Builder` runs effects in record order at the buildTx
  boundary while construction stays pure.
- **Expression lambdas are ambiguous between Consumer/Function
  overloads in Java** — use void block bodies. A block ending in
  `throw` is both void- and value-compatible — bind to an explicit
  Consumer local.
- **Python `bool` is an `int`** — bool must precede int in any
  type→wire-tag map.
- **C# `checked` is a keyword** — the emitter @-escapes; other
  languages validate identifiers against reserved lists at generation.
- **`__eq__`-overloading signals breaks naive hashing/identity** — the
  journal keys by id(); C# reference checks use `is null`.
- **A spec field named `record` collided** with Python's framer and
  C#/Java contextual keywords — renamed `fields`. Run every new spec
  name past all reserved lists (the generator does this).
- **`kaya::Messages::new()` cannot infer `M` in a handler-less scene** —
  a static scene (no `on_click`/`on_toggle`/…) leaves the message type
  unconstrained and fails to compile. Write `Messages::<()>::new()` and
  block on `next` for keep-alive (a real app stays open; the block is
  the "park until Shutdown" idiom). Candidate ergonomic guard: a named
  `kaya::park(&ctx)` keep-alive primitive so static scenes don't reach
  for `Messages` at all (see deferred.md).

## Process / testing

- **The stale-artifact class**: an old dylib × new guest decodes
  garbage. Guard: spec hash baked into every wire file, asserted at
  load. Suites rebuild; standalone checks against a stale
  target/debug/libkaya.dylib do not — rebuild first.
  The PRESENTATION side has the same class and needed its own guard
  once the interpreters became the only backends on three platforms: a
  stale compiled libkaya_swiftui.dylib or APK against a new libkaya
  would decode wire records with old constants, and check-verbs (a
  SOURCE gate) cannot see compiled staleness. Guard: the host API
  table carries kaya_spec_hash, both interpreters bake the value
  (check-verbs pins it against bindings/c/kaya_wire.h) and assert at
  entry/mount, dying with a "stale interpreter — rebuild" message;
  proven by poisoned-hash negatives on both platforms. Corollary paid
  for while proving it: the HOST binary bakes the api table too, so a
  stale host × new dylib reads garbage where the new table field
  should be — suites rebuild both together; when testing by hand,
  rebuild the example before the dylib.
- **"Apply-op landed everywhere but the observation missed one
  string-matched layer"** hit repeatedly (GTK child_texts, Kotlin
  expect_order). Guards: no-default Stage methods (compile-forced) and
  tools/check-verbs.sh (interpreters).
- **Bare `wait` in a suite deadlocks** on unrelated background children
  (headless Weston never exits) — always `wait "${pids[@]}"`.
- **A verdict can print OK while the leg fails** — the process didn't
  exit (a broken finish()/exit path; GTK/WinUI must hop to the UI
  thread before request_exit). The drains flag this combination.
- **Zero-expect scripts must fail** — a transport that mangles a script
  into a comment must not false-pass (guard in the harness; comments
  are stripped before `;`-folding so a leading comment can't swallow
  the script).
- **A value pin cannot see a FORGOTTEN sibling.** capi.rs re-exports
  the wire constants for kaya.h (cbindgen reads capi, not wire.rs),
  each pinned by `const _: () = assert!(KAYA_X == wire::X)` — but a
  NEW wire constant simply absent from capi trips no pin, and the
  spacing prop shipped to every generated wire file while kaya.h
  silently lacked KAYA_PROP_SPACING (the Swift binding, which compiles
  against the header, was the first thing to notice — at suite time,
  not generation time). Guard: a completeness assert beside the pins
  (`spec::PROPS.len() == N`) that a new prop trips, walking you to the
  export block. The general shape: agreement checks need a matching
  cardinality check, or absence passes them vacuously.
- **gen-guests --check diffs against git HEAD** — it cannot pass
  pre-commit when generated surfaces changed; prove idempotence
  (second regeneration is byte-identical) and commit generators with
  outputs.
- **git stash on a tree with parallel agents round-trips EVERYTHING**
  — avoid whole-tree operations while agents share the tree.
- **Recording mode**: anchor video to steps in-band or by fiducial,
  never by launch/stop wall-times; recorders drop buffered tails;
  sparse-VFR stills need a covering frame.
- **`swiftc`/`xcrun` in the nix shell resolve nix's macOS SDK, not
  Xcode's** — hand-building anything Swift, or any `-target
  *-apple-ios*`, fails with "framework not found" (UIKit, etc.). Guard:
  `tools/lib/swift-toolchain.sh` — source it and invoke `kaya_swiftc`
  (it resolves a real Apple toolchain + macOS SDK, preferring a full
  Xcode.app, and handles the `DEVELOPER_DIR`/`SDKROOT` unsetting). All
  three former copies (validate-mac, swift-typecheck, build-dylib) now
  route through it; any new Swift build should too, instead of
  re-deriving the dance. For an iOS `cargo build` (not a direct swiftc),
  use tools/ios/run-sim.sh's build path rather than a bare
  `cargo build --target *-apple-ios*`.
- **Observation captures orphan the app process and can grab the user's
  screen.** A non-selftest launch blocks forever on `recv` (correct app
  behavior — a real app stays open), and on macOS **closing the window
  does NOT exit the NSApp**, so a capture that forgets to `kill` the
  launched process leaves a live window/proc behind. And a full-screen
  `screencapture` grabs whatever the user has frontmost (their browser,
  editor — a privacy leak on a shared machine). Guards: capture ONE
  window by id (`CGWindowListCopyWindowInfo` → `screencapture -l<id>`),
  never full-screen; ALWAYS terminate the launched **app process** in a
  finally step. Do NOT tear down the simulator/emulator device pools —
  the runners deliberately keep them warm across runs (re-boot is slow);
  only the app process/window is the leak, not the device.
