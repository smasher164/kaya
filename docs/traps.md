# Traps — expensive lessons, already paid for

Each of these cost a debugging session (or would have). Most now have a
structural guard; the guard is named where it exists. Do not re-derive
these the hard way.

## Platform / toolkit

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
- **SwiftUI runs speculative zero-size layout passes.** A custom
  `Layout` is asked to place its subviews at `bounds.size == .zero`, and
  those passes arrive AFTER the real ones — so recording measurements
  unconditionally clobbered a correct 96/286 split with 0/0, which
  `expect_shares` then read as the empty string. Record geometry only
  from passes with a positive main-axis extent; a degenerate pass is not
  a placement.
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
