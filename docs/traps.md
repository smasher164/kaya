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
- **A leg inherits the previous group's scene script.** Every backend
  reads `KAYA_SELFTEST_SCRIPT` when it is set — `harness::script` checks
  the env var FIRST and only then falls back to
  `$KAYA_SCENES_DIR/<scene>.steps` — and validate-mac exports it once
  per scene group. This entry used to exempt the Rust backends on the
  grounds that they embedded their script with `include_str!`; that
  stopped being true when the include_str match was replaced by
  file resolution, so the exemption was BACKWARDS — a rust leg in the
  wrong group inherits exactly like an interpreter leg. A new leg added
  after a group therefore runs the PREVIOUS scene's script against the
  new scene's tree, which surfaces as an index-out-of-range deep inside
  the interpreter, not as anything resembling "wrong script". Every
  interpreter leg must export its own script immediately before it.
- **The interpreters resolved `kind#index` by index alone.** `row#0`
  silently read `columns[0]` — a wrong-widget read, the false-verdict
  class — and a malformed or out-of-range index was a hard trap
  (Swift's "Index out of range") rather than a failure. check-steps
  never PARSES a scene — it is regex and python lints — but one of them
  rejects any container target except index 0, so no checked-in scene
  could reach the bug and only a hand-run script could, which is
  exactly how it was found (an `expect_shares row#2` probe). Both interpreters now match
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
  scene on all four backends; `Stage::container_fills` is no-default
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
- **AppKit menus auto-enable through the responder chain by default.**
  Every Kaya-owned `NSMenu` sets `autoenablesItems = false`; otherwise
  AppKit silently disables an item whose bridge target is not in the
  responder chain, fighting the menu item's live `enabled` property.
  The interpreter owns a segment of `NSApp.mainMenu`, not the whole
  bar, and re-synchronizes it after SwiftUI rebuilds and key-window
  changes — a one-shot insertion races the same asynchronous scene
  machinery as a one-shot window registration.
- **A WinUI accelerator's default action is a UI Automation PATTERN,
  and only Invoke raises Click.** The framework looks the element up
  for Invoke, else Toggle, else Selection. A `MenuFlyoutItem` has
  Invoke (so its chord raises Click, the backend's one dispatch path)
  and a `RadioMenuFlyoutItem` has SelectionItem (which also raises
  Click and updates the native selection — suppressing it with
  `Handled = true` BREAKS the selection). A `ToggleMenuFlyoutItem` has
  Toggle, which flips `IsChecked` and raises nothing, and its
  accelerator is never matched at all: measured every way this backend
  can reach it — on the item, on the MenuBar, on the content Grid, as a
  collapsed companion, with an explicit Invoked handler, with
  ScopeOwner (which SCOPES rather than widens, breaking the kind that
  worked), and with routed KeyDown/PreviewKeyDown. That one kind takes
  its dispatch from a thread-scoped `WH_KEYBOARD` hook instead.
- **A harness verb gated on a table is a chord that never fires.**
  deploy-win's shortcut verb injects a real OS chord only for a
  spelling the catalog table holds, and that table was built from
  ACTIONS alone. A checkable command's chord was therefore never
  pressed, and eight platform experiments "explaining" the silence were
  all measuring an uninjected key (2026-07-24). Check the gate before
  theorizing about the platform.
- **javac takes the PLATFORM charset, and Windows is not UTF-8.** A
  non-ASCII menu label ("Settings…") reached the wire as mojibake from
  the VM's classes while the same source worked on mac and linux; every
  javac invocation now pins `-encoding UTF-8`. deploy-win's
  skip-unchanged stamp hashes the shipped BYTES, so a build-flag change
  with unchanged sources reused the stale classes until the script
  itself joined the stamp.
- **Accessibility reads of a CLOSED NSMenu are pre-validation.**
  Scripting a mac menu check through System Events reports what the
  menu was built with, not what it will show: items whose live flag is
  false still read `enabled = true`, and AppKit's display-time
  insertions (Enter Full Screen in a menu titled `View`) are absent
  from the item list entirely. Both appear only once the menu is
  actually presented — so a screenshot of an open menu is evidence and
  an AX query of a closed one is not (measured 2026-07-24, while
  photographing the menus scene).
- **A native menu rebuild must start from the post-user mirror.**
  Toggle/radio chrome owns the immediate user change, so its callback
  updates the backend's retained `checked`/`value` mirror before it
  emits. Rebuilding later from the pre-click model silently reverts
  the choice. Enablement is likewise inherited: every descendant,
  shortcut, automation route, and harness activation uses the AND of
  its own flag and every grouping ancestor. The menus scene disables
  File, changes View/Sort, then enables File to force an unrelated
  rebuild and pins both rules.
- **WinUI `MenuFlyout.ShowAt` is a request, not a readiness
  boundary.** Invoking a menu-item automation peer on the next
  dispatcher hop can return successfully before the flyout presenter
  is live and silently drop the routed Click; opening another context
  flyout can likewise overtake the prior close animation. The harness
  registers `Opened` before `ShowAt` and does not activate until that
  event arrives, then registers and awaits `Closed` around the native
  item invocation before another open may start. Keep that native
  flyout handle through `Closed`: the item's occurrence may remove its
  stamped anchor (and therefore its entry in the live-widget map)
  before event cleanup runs. The menus scene's consecutive Rename and
  row-removing Remove activations are the integration guard. A sleep is
  not a substitute for either lifecycle edge (2026-07-23).
- **WinUI shortcut injection is OS-global, so Windows menu legs cannot
  share the suite pool.** The harness foregrounds the guest and uses
  `keybd_event` to exercise the real `KeyboardAccelerator` path; with
  four guests in flight, their `SetForegroundWindow` calls steal focus
  and another process receives the chord. The formerly tautological
  shortcut check hid this until the menus scene required `ready` to
  become `saved`. `deploy-win` now runs every menu leg through a
  drain/run/drain barrier, and `check-steps` pins both the serial calls
  and that barrier. Do not replace it with sleeps or weaken the
  pre-shortcut assertion (2026-07-23).
- **A flat per-item menu-native map is the wrong-noun bug.** A
  template context catalog attaches the SAME item ids to every
  stamped copy, and the copy's keys ARE the noun (DESIGN.md, Menus) —
  so a map keyed by item id alone keeps only the last-built copy's
  native, in whatever order the rebuild iterates the anchors, and the
  harness then invokes THAT row's chrome (emitting its noun) from
  every other row, nondeterministically. Natives are keyed per
  attachment (`protocol::MenuAttachment`), the noun resolves at
  dispatch from the firing copy's own anchor (the SwiftUI parity
  rule), and the Destroy arm purges the dead attachment's instances —
  a detached item still raises Click through its automation peer (the
  menu probe proves it), so a stale entry stays invoke-capable with
  the dead row's noun. GTK reaches the same invariant with
  per-attachment action instances retained out at Destroy. The
  frozen menus scene stamps ONE row, so no scene leg can see the
  collision: the negative tests are protocol.rs's
  `stamped_copies_keep_one_native_per_attachment` and
  `destroying_an_anchor_purges_only_its_natives`, and the composite
  key makes an anchor-less lookup a compile error on the
  check-targets windows cross-compile (2026-07-24).
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
  `join()`, not `get()`. Enums count: adopting `TwoPaneView` meant
  naming `Visibility` and every `TwoPaneView*` enum by hand
  (2026-07-27). Regenerating is `cargo run` in
  `tools/winui-bindgen` WITH THAT AS THE CWD — it writes a relative
  `../../crates/kaya/src/winui/bindings.rs`, so from the repo root it
  silently writes somewhere else.
- **`unparent` must know every parent that owns its child through a
  PROPERTY**, not just the container kinds. `adw::NavigationPage` is
  one: a bare `child.unparent()` detaches the widget while the page
  goes on pointing at it, so the pane lives in no tree the
  accessibility walk can reach. `expect_ax` then reports it absent
  while kaya's model still has it — every model assertion passes and
  only the real-tree one fails, which reads like a broken a11y read
  rather than a broken detach (2026-07-27; the arm is in gtk.rs's
  `unparent`).
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
- **WinUI's `SystemAccentColor` is not overridable, and failing is
  silent.** Microsoft's own theming documentation says you can override
  it in `Application.Resources` or a theme dictionary, or set
  `ColorPaletteResources.Accent`. None of them take
  (microsoft-ui-xaml#6394) — the system accent wins and the app's value
  is ignored with no error, no warning, and no visual change to
  diagnose from. The route that works is the DERIVED brushes:
  `AccentFillColorDefaultBrush` and its siblings, injected into
  `Application.Current.Resources.ThemeDictionaries` at startup. Because
  the failure mode is a silent no-op rather than a crash, any accent
  lowering wants a gate that READS the rendered brush back, not a
  comment saying which key to use.
- **WinUI 3 XAML cannot host a child HWND.** WPF has `HwndHost`; UWP
  and WinUI never did, because HWNDs and the composition tree are
  separate airspaces, and the `DesktopWindowXamlSource` /
  `DesktopChildSiteBridge` machinery runs the other direction (XAML
  *into* Win32, the XAML Islands case). So "Win32 common controls
  remain the fallback" is true only for a whole window, never for one
  widget inside a XAML tree. On Windows there is no interpreter
  drop-down tier — see DESIGN's lowering tiers — and a gap that other
  backends solve by reaching into the older toolkit must be
  CONSTRUCTED here.

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
- **SwiftUI resolves its design generation from the MAIN EXECUTABLE's
  SDK stamp (the sdk field, NOT minos — verified: minos 14 + sdk 26.5
  takes the modern path), and the compat path mis-measures Button.** `otool -l
  <bin> | rg -A4 LC_BUILD_VERSION`: the stamp belongs to whoever
  built the host binary (audited here: everything nix-linked 14.4,
  zulu JDK 11.3, Apple's /usr/bin/python3 26.5) — so the SAME dylib
  renders different control generations per host runtime. The dev
  shell is uniformly old-stamped, so validate-mac exercises the
  compat generation; the modern generation has no dedicated leg yet
  (ledgered). In the compat generation `Button.sizeThatFits` answers borderless metrics while
  the renderer draws the bezel (caption truncates to "t…"). Guard:
  macOS controls that own chrome are bridged to AppKit
  (NSViewRepresentable + `fittingSize`), which cannot self-disagree
  under any stamp. When mac-only geometry differs BY GUEST LANGUAGE,
  check the host binaries' LC_BUILD_VERSION before suspecting kaya.
- **An alignment frame PLACES its child by re-proposing the child's
  own fitted size.** `.frame(maxWidth:.infinity, alignment:)` used as
  a track cell hands a hugging stack a proposal exactly equal to its
  ideal; the stack's fair-share division then runs with zero slack
  and shortchanges whichever child it asks before the huggers release
  their surplus — a conforming control absorbs the deficit silently
  (a bordered button wraps mid-word; a rigid bridge overflows its
  slot by the same amount). A CONSTRAINT-LESS `.frame` (all-nil
  maxes) re-proposes identically — deleting only the outer frame of
  a two-frame cell moved the squeeze down a layer, byte-identical.
  Guard: KayaCell — the flex cells propose the FULL cell at
  placement and align the returned size; never use any frame as a
  cell.
- **alignmentGuide recording closures run only when somebody QUERIES
  the guide.** The baseline recorders (`.alignmentGuide(.top)` hooks)
  were powered by the flex cells' alignment frames — aligning a child
  queries its guides, and stack guides derive from children, so the
  query cascaded into row children. Deleting the frames silently
  emptied `kayaBaselineOffsets` (baseline rows classify "mixed" with
  offsets=[:]) while rendering stayed correct. KayaCell queries the
  child's `.top` explicitly to keep the recorders running; if
  baseline classification ever reads mixed with correct-looking
  geometry, print the offsets dict first.
- **@Observable macro-expands IN-CLASS computed properties as stored**
  ("variable already has a getter/init accessor", duplicate `_name`
  backing) — the swift-typecheck pass can even stay green while the
  full dylib emit fails. Guard: single-window forwards and any other
  computed conveniences live in an `extension` of the @Observable
  class; extensions are outside the macro's expansion and observation
  still tracks through the stored properties they read.
- **A new occurrence record shape must extend EVERY generated
  parser.** The generated parsers assumed the click shape ({id,
  path_len, keys...}) until window lifecycle records ({window_id}
  alone) arrived; six languages silently misparsed them — dormant
  only because no scene in those languages received one. Guard: the
  emitters carry an explicit per-shape branch, and the per-language
  event legs (panels) are the gate — a new occurrence kind is not
  landed until a scene exercises its parse in every language that
  can run it.
- **Every mechanical per-scene surface in a runner derives from that
  runner's ONE `SCENES` variable** (deploy-win: cross-build, exe/
  python/go shipping, taskkill; validate-mac and run-suites: build
  args and guest loops). A new scene is one registration; the leg
  blocks alone stay explicit, encoding per-language coverage. The
  class this killed: deploy-win's fourth hand-maintained list
  (panels_go's sources never shipped) while check-steps' per-runner
  grep was satisfied by the other three.
- **A mount can apply before the first view appears** (SwiftUI):
  environment actions (openWindow/dismissWindow) are stashed in
  onAppear, but a batch — especially a guest's second transaction —
  can be applied earlier. Presentation calls park in
  kayaPendingOpens and the stash drains them; the panels-python leg
  (two transactions) is the regression gate, and rust's
  single-transaction pass was timing luck, not proof.
- **Generated-comment text is code in OCaml: `*)` terminates the
  comment.** The emitters copy spec Record docs (and their own
  branch notes) into generated comments verbatim; an OCaml comment
  containing `*)` — even inside a word like `alert_choice_*)` —
  closes early and the remainder is a syntax error in the GENERATED
  file, far from the sentence that caused it (first hit: the alert
  parser branch's own comment). Guard: the ocaml emitter defuses
  both delimiters (`*)` → `* )`, `(*` → `( *`) on every doc it
  copies, so no future spec doc can break the generated module.
- **WinUI resource resolution is anchored to the PROCESS exe's
  directory — every kaya host needs resources.pri beside its exe.**
  ProgressBar was the first control whose template REQUIRES the
  merged XamlControlsResources (missing-theme-key death at
  realization: "TabViewScrollButtonBackground"); the merge loads via
  ms-appx, and ms-appx in an unpackaged process resolves against the
  directory of the EXECUTABLE — not the dll, not the CWD. Rust scene
  exes sat beside C:\kaya\resources.pri and worked; python.exe,
  java.exe, dotnet.exe, and go-run's temp exe did not, and the
  process fail-fasts 0xC000027B (bare
  RoFailFastWithErrorContextInternal2; app-scope stub keys do NOT
  satisfy the walk). The rule, applied per host in deploy-win's
  progress legs: arrange kaya's minimal resources.pri beside the
  host exe — go builds into C:\kaya (never `go run` for WinUI
  legs), C# runs its APPHOST exe with the pri copied beside it,
  python/java get the pri placed beside their interpreters
  (idempotent; inert for non-WinUI programs). The merge itself is
  tiered in OnLaunched: real XamlControlsResources where ms-appx
  resolves, log-and-continue where it cannot — never fatal, so a
  host without the pri keeps every control whose template resolves
  locally.
- **A depth-slice stub compiles; only a suite notices it against
  wired legs.** `unimplemented!("<scene> is not yet materialized")`
  arms are the sanctioned way to hold breadth open, and they COMPILE
  — so every compile gate (check-targets, check-gtk) stays green
  while a runner that has since gained the scene's legs will die on
  the stub at suite time (the GTK scroll materialization was
  believed applied while the stub survived; the linux suite was the
  first to notice, 2026-07-22). Guard: tools/check-stubs.sh
  cross-checks every runner's wired scenes against its backend's
  stub strings (the "<scene> is not yet materialized" spelling is
  the contract), self-tested with a synthesized bad pair. Corollary
  for agents: never chain an edit script and its verification in one
  background command — the tail shows the LAST command's success,
  not the edit's failure; verify the edit itself (grep the new
  symbol) before trusting anything downstream.
- **An unguarded suite-runner build greens legs against stale
  artifacts.** run-emulator's gradle/cargo-ndk lines had no
  `|| exit 1`: a Kotlin compile failure produced a zero-verdict run
  (and would have installed the PREVIOUS apk had one leg still
  queued) — the stale-artifact class inside the runner itself. All
  four build lines now fail the run loudly, and KayaCompose.kt has a
  mac-side compile gate at last (tools/check-compose.sh — the
  swift-typecheck sibling; the emulator used to be the FIRST
  compiler to see the Kotlin layer). When reading suite results,
  check verdict COUNTS, never just exit codes — pipeline wrappers
  can eat the code.
- **One-shot registration hooks race window attachment — register on
  viewDidMoveToWindow, never on a queued closure.** (Corrected
  diagnosis 2026-07-21; the entry here previously blamed
  openWindow(value:) drops.) The panels-java aux-open flake's real
  cause: KayaWindowAccessor registered its NSWindow via a one-shot
  `DispatchQueue.main.async { register }` from makeNSView; under
  suite load the window attached AFTER that drain, the
  `view.window == nil` guard returned silently, and updateNSView
  never re-fired (the aux surface's state was fully set before
  mount, so nothing re-evaluated). Instrumented repro proved the
  window EXISTED — visible, titled, in NSApp.windows — while
  kayaNSWindows stayed empty, so every window-targeted verb burned
  its await and close_window no-oped; os_log showed zero SwiftUI
  scene errors, i.e. the openWindow request was never dropped at
  all. Java-only was pure timing (slowest-booting guest under
  contention). Guard: the accessor's view subclass overrides
  viewDidMoveToWindow — AppKit's attachment event — so registration
  cannot race; kayaEnsureOpen stays as an idempotent belt whose
  exhausted case now logs a self-diagnosing state dump (window
  present-but-unregistered vs truly absent), and kayaAwaitWindow
  still awaits materialization event-driven. The general rule: a
  hook that must observe "X became true" must subscribe to X's own
  event, not sample X once from a queue.
- **Interior double quotes break run_ssh commands to the Windows
  VM.** Windows sshd wraps the whole received command in its own
  `cmd /c "..."`, so double quotes INSIDE the command re-pair across
  the line — chained `& mkdir` halves land inside a quoted region
  and the exit code still reads 0. The older `cmd /c "if exist ..."`
  lines survive only by accident: their single TRAILING quote is
  eaten harmlessly. Guard: write run_ssh commands quote-free (cmd
  needs no quotes for backslash paths; split chains into separate
  run_ssh calls; mkdir creates parents with extensions on).

- **A WinUI ComboBoxItem with UIElement content gets STOLEN by the
  collapsed box.** While a row is selected and the popup closed, the
  ComboBox moves the item's UIElement content into its
  SelectionBoxItem (an element lives in ONE visual tree), so the
  row's Content() reads back null — the harness's selected-label
  read panicked on a null-interface cast, and the panic wedged the
  XAML dispatcher into a hang with no EXIT line (2026-07-22). Guard:
  option rows carry STRING content (PropertyValue::CreateString),
  which is templated independently in the popup and the selection
  box; read it back by casting Content to IReference<HSTRING>.
- **Sugar construction order differs per language: SetProp can land
  BEFORE AddChild.** Statement-shaped sugars (Rust, Python, Go, C#,
  Java, Swift) parent a child at creation, then set its props;
  expression-shaped sugars (OCaml, Haskell) build children FIRST, so
  their prop writes precede the AddChild. A backend that materializes
  a relationship at AddChild (a select's option rows) must therefore
  initialize from the child's CURRENT state, not from empty — every
  ocaml/haskell dropdown row read "" on linux until GTK's rows
  seeded from the label's text (2026-07-22). The matrix's
  children-first legs are the standing negative test for this class.
- **A scene script needs a settle between an action and the expects
  that observe its guest fold.** choose→expect with no settle passed
  on the in-process mac interpreter and raced on GTK: the fold's
  round trip (occurrence → guest write → apply → render) is
  asynchronous everywhere, and 2ms is not a contract. The gallery
  scene's 400–700ms post-action settles are the convention; select
  learned it the hard way (2026-07-22).

- **Scripted settles were hiding four real WinUI bugs; bounded-retry
  expects flushed them all out in one run (2026-07-22).** When the
  scenes dropped their sleeps: (1) observation reads that error
  mid-materialization (null Content cast, not-yet-live XamlRoot)
  panicked — on the harness thread via on_ui's expect, or fatally
  inside a dispatcher callback where a panic cannot unwind and
  ABORTS the process (the 390s hung legs). Guard: on_ui_read — a
  read's WinRT error is a retryable miss, never a panic. (2)
  TextBox.TextChanged is raised ASYNCHRONOUSLY (Checked/ValueChanged
  are not), so a click's occurrence overtook the edit and add
  handlers ran on empty drafts; a FIFO flush hop does NOT fix it.
  Guard: per-entry swallow counters — every programmatic text path
  (SetProp, clear, the stage) writes, emits synchronously where it
  must, and swallows the late native raise 1:1. (3) Presenting a
  ContentDialog milliseconds after launch dies on the not-yet-live
  XamlRoot, and deferring by dispatcher SELF-RE-ENQUEUE starves the
  very queue that loads the island. Guard: present from the root's
  Loaded event. (4) alert_title answered from the stored dialog
  handle BEFORE the popup opened, so expect_alert passed early and
  the automation press dropped silently on a not-yet-interactive
  dialog — the alert never retired and the next show tripped the
  one-alert floor. Guard: alert_title gates on dialog.IsLoaded.
  The class lesson: a fixed sleep in a test is a bug preservative —
  every one of these was a real app-facing defect (an app showing an
  alert at launch aborts), reachable the day a guest got faster.

- **The materialization class, generalized: any IMPERATIVE platform
  call in the APPLY path whose prerequisite materializes
  asynchronously.** A guest's ops can arrive milliseconds after
  launch — before the first layout, before the content island,
  before tree attachment — and the strict imperative backends (WinUI
  above all; GTK for focus) either abort or silently drop. The
  full audit (2026-07-22) found four instances, all now on one of
  three strategies: presents and metrics DEFER to the platform's own
  readiness event, one-shot (ContentDialog on the root's Loaded;
  baseline reindex on the panel's Loaded; Focus on the element's
  Loaded / GTK map); observations are TOTAL reads that return a
  retryable miss; plain object manipulation (create/set/add_child)
  needs nothing. The declarative backends (SwiftUI, Compose) are
  immune by architecture — presentation derives from model state.
  When ADDING an apply-path call, ask: does this need a live tree,
  a layout pass, or an island? If yes, it rides a readiness event,
  one-shot, or it is a bug that a fast guest will find.

- **Parallel lanes can hand a container a stale dune artifact.** With
  validate-all's lanes concurrent, the linux container's incremental
  dune build once linked 15 of 17 ocaml exes fresh and left two on
  the previous run's binaries — dune's digest view through the
  virtiofs mount racing the mac lane's concurrent host builds. The
  per-guest spec-hash check caught it loudly at LEG time (that guard
  paying rent); the durable guard moved the catch to BUILD time: the
  container's build_ocaml asserts every exe is newer than the newest
  binding source and self-heals with one `dune build --force`
  (2026-07-22). The general rule for mounted-tree builds: an
  incremental build that shares sources with a concurrent writer
  must assert output freshness itself.

- **...and that freshness assert can be made UNSATISFIABLE by a
  regeneration that changes nothing.** `tools/gen-bindings.sh` without
  `--check` rewrites the binding sources with byte-identical content
  and fresh mtimes. dune is CONTENT-based, so it correctly declines to
  relink; the assert above is MTIME-based, so it demands a relink that
  will never happen, and the lane cannot clear (2026-07-27). The two
  halves are each right and the pair is stuck — which is the general
  shape to watch for whenever a guard and the tool it guards measure
  staleness differently. Deleting the stale `.exe` files makes it
  worse: dune's database then believes targets exist that do not, and
  `--force` does not repair it. The repair is `rm -rf _build-linux`.
  Run gen-bindings with `--check` unless you actually mean to
  regenerate.

## A deferral trigger written against a platform's current shape expires

2026-07-24, the menus close-out review. The ledger deferred iPad menu
exposure with an explicit trigger: "an artifact running on iPad with a
keyboard", framed around `UIKeyCommand` and the hold-Command HUD. That
framing was correct when it was written — a hardware keyboard was then
the only route to commands on iPad. iPadOS 26 then gave every iPad app
a real system menu bar reachable by swiping down from the top edge or
hovering a trackpad, with no keyboard involved. The recorded trigger
could no longer fire for the case that had become the important one: a
plain iPad, no keyboard, and a menu bar the app never fills. Both menus
implementations (shipped, and the `menus/first-cut` stash) meanwhile
gate on `#if os(iOS)` and route the whole catalog into a phone-shaped
More overflow.

Trigger-gating is still the right admission policy; the failure is in
how the trigger was PHRASED. A trigger naming a user artifact ("an app
that needs a Recent Files menu") stays valid indefinitely, because it
describes a demand. A trigger naming a platform's current capability
("an iPad with a keyboard, because that is the only route") silently
encodes an assumption about the platform that the platform can revoke.
Guard: when a deferral's trigger rests on what a platform can do today,
record the assumption separately and give the entry a re-read date, so
a platform release re-opens it instead of a deferral quietly becoming
unreachable. The general form of the bug: the deferral did not go
stale — its PREMISE did, and nothing was watching the premise.

## A scene that never mounts measures an invisible app

2026-07-25, the a11y depth slice. A guest built its widgets and never
called `tx.mount(root)`. The window rendered EMPTY — and nothing said
so. Target resolution could not catch it: the widgets exist in the scene
model, so `kind#index` resolves happily and every read simply describes
nothing.

The cost was not the bug, it was the cascade. An empty accessibility
tree was misdiagnosed in turn as (1) SwiftUI's compatibility design
generation not publishing accessibility, (2) the guest LANGUAGE
affecting accessibility, and (3) macOS not exposing AXIdentifier at all.
Three confident, wrong conclusions, each with evidence, all downstream
of one silent omission. The third was disproved only when the maintainer
pushed back with documentation.

Two process lessons worth as much as the guard:
- CHANGE ONE VARIABLE. The "language matters" conclusion came from
  comparing a rust A11Y scene against a swift GALLERY scene — two
  differences at once, and the one that mattered was the broken scene.
- A conclusion that indicts the PLATFORM should be the last one reached,
  not the first. Every platform-level theory here was wrong.

Guard (KayaSwiftUI.swift, the failure path): when a run fails and
widgets exist while no surface has a mounted root, the verdict says so
first — "N widgets exist but NO ROOT IS MOUNTED … every assertion above
measured an empty window". Deliberately on the FAILURE path: the first
attempt checked before the first step and fired never, because the
guest's transactions have not arrived yet at that point, so the scene
legitimately looks empty. On the failure path it also cannot
false-positive on a scene that mounts late.

## A gate that does not compile the layer it is named for

2026-07-25. `swift-typecheck` typechecks the swift GUEST examples and the
swift BINDINGS. It never touched swift/KayaSwiftUI.swift — ~4300 lines,
the historic miss layer, which re-implements every harness verb and
carries private copies of the wire constants. So the interpreter's only
compiler was build-dylib.sh inside validate-mac, and a broken
interpreter reported `swift-typecheck: OK` while the dylib build
rejected it outright (measured: `NSObject.accessibilityIdentifier`).
CLAUDE.md even described check-compose as "the swift-typecheck sibling",
implying a coverage that did not exist.

Guard: swift-typecheck now typechecks the interpreter as its last step,
negative-tested both directions. The general rule: a gate named after a
LAYER must compile that layer, and "it is in the same directory" is not
coverage. Check what a gate actually feeds its compiler, not what its
name suggests.

## A failed build must not leave a usable artifact

2026-07-25. build-dylib.sh compiled straight to
target/swiftui/libkaya_swiftui.dylib. A compile error therefore left the
PREVIOUS dylib in place, and the next run tested that — a green scene
against stale code, with the build's exit status as the only evidence.
Anything that reads output instead of status (a grep, a tail, a human
skimming) misses it completely. This is the sibling of the
never-pipe-a-build-through-tail rule, and it bit within an hour of that
rule being cited.

Guard: compile to a scratch path, delete the old artifact first, and
move into place only on success; on failure remove the temp and exit 1.
A stale dylib then cannot exist, so the next run fails loudly with
"could not load the SwiftUI backend" instead of lying. Callers should
still check exit status — this makes the ARTIFACT honest even when they
do not.

## SwiftUI containers do not take accessibility props the way leaves do

2026-07-25, landing a11y_id/a11y_label as UNIVERSAL props. On a leaf
control both behave as expected. On a container neither does:
- an IDENTIFIER set on a container PROPAGATES DOWN and lands on its
  first child (the row reported its first button's identity);
- a LABEL set on a container COLLAPSES it into a single accessibility
  element and HIDES its children entirely (the row became
  `button/Actions` and neither button inside was reachable).
Both are correct platform behaviour — a named thing is one thing — but
they silently make a "universal" prop mean something different per kind.

Fix: containers get `.accessibilityElement(children: .contain)` before
the props are applied, which makes the container its own element while
its children stay individually reachable. Also note the related shape: a
container holding a SINGLE control is collapsed into that control, which
is correct screen-reader design, so conformance scenes want two children
when they mean to assert a group.

## Filtering compiler output through `grep -E "^e:"` discards warnings

2026-07-25, iterating on the Compose backend. The build loop in a
handoff doc read `gradle :kaya:compileDebugKotlin | grep -E "^e:"` —
errors only. It ran green for several rounds while the compiler was
reporting a deprecation the whole time, and that deprecation was the
first clue to a real API mismatch.

This is the `tail`/`head` rule's sibling: anything that reads a filtered
VIEW of a build instead of its whole output loses the diagnostics that
are not errors yet. Warnings are where a build tells you it is about to
break. Read the output, check the status, filter nothing.

The related guard that does work: a gate for the diagnostics the
compiler CANNOT produce (tools/check-detekt.sh — K2 moved the UNUSED_*
diagnostics into IDE inspections, KT-69698).

## iOS materializes no accessibility tree until automation is enabled

2026-07-25, the same day macOS's lazy tree was measured — the Apple
platforms share the laziness and spell the cure differently.

Under SwiftUI on iOS, a walk of the whole UIView hierarchy found the
real controls (UISwitch, UITextField, UISlider, UISegmentedControl) and
EVERY ONE reported `isAccessibilityElement=false`, zero accessibility
elements and a nil identifier. Nothing to read, no error, no warning:
the verb simply reported "not in the accessibility tree" for every
element in the scene, which reads exactly like a lowering bug.

VoiceOver cannot be started from inside the app, but the AX runtime's
automation switch can be (`_AXSSetAutomationEnabled` in
libAccessibility, resolved with dlsym — what XCUITest, KIF and EarlGrey
all flip). With it on, the tree appears in full.

Two more iOS-only shapes worth knowing, both measured the same session:
- SwiftUI's accessibility elements are NOT UIViews and do not conform to
  `UIAccessibilityIdentification`, so `as? UIAccessibilityIdentification`
  misses them. The ObjC selector `accessibilityIdentifier` reaches them.
- UIKit publishes no role vocabulary at all — classification is a TRAIT
  BITMASK plus the element's class, and the same trait rides several
  kinds (a toggle is button|toggleButton, a chooser is a plain button
  that owns a `menu`). Specific signals must be weighed before
  `.button`, or every one of them reads as a plain button.

## Compose sends services the UNMERGED tree, and the SERVICE merges it

2026-07-25. `provider.createAccessibilityNodeInfo(id)` looks like the
answer to "what does the platform publish for this node", and it is
not. Compose hands an accessibility service the UNMERGED semantics
nodes plus `mergeDescendants` instructions, and the SERVICE applies its
own merging — so that call returns a PRE-MERGE node that no client ever
sees in that form. TalkBack sees the merged result.

Read `SemanticsOwner.rootSemanticsNode` instead: it is merging-enabled,
so walking it is the post-merge view, one node per thing a client
focuses. Same trap the macOS backend documents from the other side —
reading the server's private view rather than the client's.

THE `extras` PUZZLE THIS EXPLAINS, recorded because a handoff left it
open as "unresolved, do not build on extras": a dump showed
`cd=Full name` and `tag=null` on what looked like the SAME node, which
seemed to disprove the documented rule that Compose republishes testTags
into `AccessibilityNodeInfo.extras`. Nothing was wrong with extras. In
the UNMERGED tree those two properties genuinely sit on DIFFERENT nodes
of one modifier chain, and the walk was conflating them. The AOSP notes
were right; the read was mismodelled. The merged read needs neither
`extras` nor the experimental `testTagsAsResourceId` opt-in, so the
question stops mattering — but "everyone else's docs are wrong" should
have been read as a signal about our model, and it is the second time
that signal was ignored in this file.

Two more Compose-specific shapes, both measured the same day:
- `className` is a compatibility fiction. There is no class in a Compose
  world, so Compose fills one in only for particular semantics. Take
  `Role` first and fall back to the class name for the controls it
  classifies without one (a slider and a progress bar are one semantics
  told apart by whether the range can be set).
- An INDEPENDENTLY FOCUSABLE descendant is not merged into its parent —
  that is deliberate. A caption row wrapping a `Checkbox` that owns its
  own `onCheckedChange` therefore publishes a group containing a
  separate checkbox, not one control. Material's own labeled-checkbox
  recipe (toggle on the row, `onCheckedChange = null` on the box) is
  what makes it one element to a service.

## Reading your OWN process's accessibility tree runs INLINE, on your thread

2026-07-25, and it cost most of a day because every symptom pointed
somewhere else. Accessibility legs hung forever — never a wrong answer,
always a 120s timeout — at roughly one leg per lane run, a different
language each time, and never reproducibly standalone.

THE ACTUAL DEFECT, off a `sample` of a wedged process: for your own pid
`AXUIElementCopyAttributeValue` does not send a message at all. It
short-circuits into AppKit and runs
`-[NSObject _accessibilityValueForAttribute:]` INLINE on the calling
thread. That is main-thread-only API, so a read from the harness thread
executed AppKit's accessibility server code concurrently with the main
thread's layout pass and inverted AppKit's own locks.

The fix is one line of thread discipline: do the read inside
`DispatchQueue.main.sync`. An older comment in the backend argued the
opposite — that a main-thread read returns empty subtrees — but that
was the LAZY TREE (docs above), measured before the client announcement
existed; with the announcement in place a main-thread read sees
everything.

THREE WRONG DIAGNOSES, worth knowing because each one was plausible and
each one "improved" things enough to be believable:
1. AX messaging timeout. `AXUIElementSetMessagingTimeout` cannot bound a
   call that never sends a message. It changed nothing.
2. Cost of announcing. Announcing DOES make AppKit rebuild its
   accessibility hierarchy and drive a layout pass, so announcing once
   per process instead of once per read is a real improvement — keep it
   — but it only shifted the odds.
3. Pool contention. Serializing the legs made lane runs mostly green,
   which is exactly what a load explanation predicts. It was wrong:
   load merely widened the window in which the main thread was inside
   layout. With the lock inversion fixed, nine concurrent accessibility
   guests pass, and the serialization was removed again.

The tell that should have been read sooner: a HANG, not a wrong answer,
and never standalone. Contention makes things slow; deadlocks make them
stop. When a leg stops dead with its window up, sample it before
theorizing — `sample <pid>` named this in one shot after three
theories had not.

Its sibling trap, still true: a leg killed at its timeout loses
block-buffered stdout, so the harness trace vanishes exactly when it is
most needed. The Swift interpreter line-buffers stdout for that reason;
without it the log shows only the backend's stderr and the hang looks
like a failure to start.

## macOS builds the accessibility tree lazily

2026-07-25. Until an assistive client attaches, an app publishes a
SKELETON: correct top-level roles, and under an accessory activation
policy not even its windows. VoiceOver announces itself with
`AXEnhancedUserInterface`; third-party assistive technology uses
`AXManualAccessibility`. Setting both on our own application element
makes the real tree readable — including under `.accessory`, which is
what lets the suites read accessibility WITHOUT stealing focus (the
selftest policy exists so suite windows do not steal the keyboard, and
the two requirements looked irreconcilable until this).

Reading is the CLIENT API (`AXUIElementCreateApplication` on our own
pid), never the server-side NSAccessibility protocol — that side is for
SETTING accessibility, and a server-side walk returns nil for every
identifier and label. `AXIsProcessTrusted()` is true for processes
launched from an already-trusted terminal, so no permission prompt.

The GTK sibling is the opposite shape: there is no in-process read at
all. GTK exposes no getter for accessible properties — the accessible
surface IS AT-SPI — so a read that stays in-process can only return
kaya's own writes. And the bus tree is not kaya's tree: every button and
check box contains a real Label node, an entry's internal text widget is
hidden, and an unmapped popover publishes nothing, so any ordinal that
counts kaya's widgets instead of the bus's is silently off.

One more GTK precedence rule worth knowing: the accessible name comes
from the LABELLED_BY relation FIRST and the label property second
(gtkatcontext.c), so a control that points a relation at its own content
outranks anything an app authors — a named GtkDropDown reads back as its
selected option until that relation is reset.

## Windows guests wedge UNKILLABLY, and taskkill cannot say so

2026-07-25, second occurrence (first: textarea matrix, 2026-07-22). The
windows lane stalled ~20 minutes with ZERO verdicts. Two guests —
`go.exe` running `reorder`, `java.exe` running `milestone2kt` — sat in a
state where `tasklist` LISTS them but `taskkill /F` answers:

    ERROR: The process ... could not be terminated.
    Reason: There is no running instance of the task.

That message is the diagnosis, and it is NOT a permissions failure:
insufficient rights report "Access is denied", a different message and a
different fix. "No running instance" means the process is past the point
where it can be signalled — a terminating/zombie state. Elevating the
ssh session or the scheduled task changes nothing; the documented escape
for this class is a reboot, which is why `utmctl stop --kill` worked
when nothing else did. Consistent with kaya's known WinUI teardown
hazards (XAML COM refs must be LEAKED after Start returns;
MddBootstrapShutdown must run while the process is healthy) and with
both occurrences being GUI guests on a virtual GPU.

WHY IT COST 20 MINUTES rather than 5: run_one_suite ALREADY had a 300s
per-leg timeout, and it fired. The gap was recovery — its remedy is
`kill_guests`, i.e. taskkill, which by definition cannot clear this
state. So every REMAINING leg hit the same 300s wall; at 110 legs that
is hours of silence, and the lane looked hung rather than failing.
A timeout without a recovery path is not a guard, it is a slower hang.

Guard (deploy-win.sh): `guests_wedged` fingerprints the contradiction —
tasklist lists an image AND taskkill reports "no running instance" — and
on a leg timeout escalates to `vm_restart` (stop --kill, wait stopped,
start, wait for sshd, grace for the /it console session). Once per run:
a wedge that RECURS after a restart is not this class and says so
loudly instead of retrying forever.

## The windows lane degrades under the full matrix — three shapes

2026-07-25. The windows lane failed three DIFFERENT ways in one day,
and all three share a cause that took until the third to see.

    windows alone      110/110, 67s   green, repeatedly
    windows alone      110/110, 64s   green
    under validate-all 843s, guests wedged unkillably
    under validate-all OS hang, 0 legs, 14 minutes of silence

Standalone it is fast and green every time. Concurrent with the other
four lanes it degrades or dies. The mechanism is host starvation:
validate-all runs a Docker VM building 324 legs 8-wide, four iOS
simulators, an Android emulator, the mac legs, AND a 4-core QEMU
Windows guest on one machine. The Windows guest is the one that cannot
take it. This also retroactively explains the confirm_* timeouts that
would not reproduce standalone earlier the same day.

THE THREE SHAPES, so the next one is recognized fast:
1. Guests hang but are killable — ordinary timeout, kill_guests clears.
2. Guests unkillable — tasklist lists them, taskkill says "no running
   instance". Needs a VM restart; see the entry below.
3. The guest OS itself hangs — no guests at all in tasklist, tasks
   never start, ssh dies, and utmctl still reports "started".

Shape 3 was the expensive one because nothing looked for it: the ssh
reachability check ran ONCE at lane startup and never again, so every
remaining leg burned its own 300s in silence. Guard: on any leg
timeout, deploy-win now probes ssh FIRST — before the wedge
fingerprint, which cannot work when the host is gone — and aborts the
lane immediately with the diagnosis rather than stalling.

The GUARD is not the FIX. The fix is resourcing: give the VM more
cores, or stop running the windows lane fully concurrent with the other
four. Until then a red windows lane under validate-all that is green
standalone is a contention artifact, not a regression — check
standalone before believing it.

## The wedged-VM class: "started" is not "reachable"

2026-07-22, textarea matrix: the UTM Windows guest OS hung mid-suite
(cause unknown — four legs in flight). UTM kept reporting `started`,
so nothing restarted it, while the suite poll loops' try-bounded
deadlines ran against SSH's default TCP timeout (~75s per poll
instead of ~1s) — a 300-try bound became hours, and the lane looked
"slow" rather than dead. Two guards now hold:

- `ConnectTimeout=5` rides SSH_MUX (every run_ssh/scp/poll), so a
  dead guest fails polls fast and try-bounds mean minutes again.
- deploy-win's boot block distinguishes stopped from wedged: if the
  host is unreachable but utmctl says started, it force-kills the VM
  and boots it fresh (`utmctl start` on a started VM is a no-op — the
  old loop waited five minutes and gave up).

The general lesson pairs with the materialization class: liveness is
proven by the layer you actually talk to (sshd), never by the
supervisor's state word.

Sibling case, 2026-07-24: the VM stayed perfectly reachable while two
GUEST processes wedged. `tasklist` listed `progress.exe` and a
`java.exe`, but `taskkill` — by image name AND by pid — answered
"there is no running instance of the task" for both: processes stuck
mid-termination, which Windows reports as gone and lists as present.
No new `C:\kaya\out_*.txt` appeared, so the lane sat in a poll for a
scheduled task that could never produce output, and the other four
lanes had long since finished.

Recognizing it matters because every symptom says "slow lane": ssh
answers, utmctl says started, and the runner's own 300-try bound only
fires after five minutes per leg — then the next leg wedges the same
way. The tells are (1) the newest `out_*.txt` stops advancing while
the run continues, and (2) taskkill disagreeing with tasklist about
the same pid. The remedy is the one the boot block already knows,
applied by hand: `utmctl stop --kill`, then let the lane's own boot
path bring it up fresh. Nothing softer clears a process the kernel
will not reap — and the wedged scenes had no bearing on the change
under test, which is exactly why the state, not the code, is where to
look when four lanes pass and one goes quiet.

## Container linker OOM scales with the example count

Same day: the linux lane died with `ld terminated with signal 9`
linking the 18th example — the pooled builds' parallel example links
crossed the docker container's memory ceiling, and the kernel chose
ld. aarch64 BFD ld's footprint is dominated by debuginfo, so
run-suites now builds with `CARGO_PROFILE_DEV_DEBUG=0` (nothing in
the container asserts on symbols). If it ever recurs despite that,
bound the link parallelism (`cargo build -j`), not the example count.

## WinUI TextBox speaks CR, everything else speaks LF

The textarea scene's first Windows run failed byte-for-byte: text SET
with `\n` read back with `\r` — WinUI's TextBox stores every line
break as a bare CR (its Rich Edit heritage). Guest-visible strings
are compared identically across all languages, so the backend
normalizes CR to LF at every boundary where TextBox text escapes
(occurrence payloads, harness reads) or is compared against guest
text (the quiet-set and set_text guards — an unnormalized compare
never matches multi-line text and re-sets on every write). The `lf()`
helper in winui/mod.rs is that boundary; any new TextBox read goes
through it.

## Shared build directories cannot be built per-leg

entry_csharp flaked CS2012 ("kaya-guests.dll locked by VBCSCompiler")
when four-wide suites had every C# leg run `dotnet build`/`dotnet
run` in the shared C:\kaya\cs — and the five pri-adjacency legs all
built into the SAME C:\kaya\cs-out. Latent since KAYA_WIN_JOBS=4.
The fix is the javac precedent: deploy builds ONCE (both outputs:
bin\Debug for plain legs, cs-out with resources.pri beside the
apphost for the pri legs) and legs only execute. Legs run the APPHOST
exe, not `dotnet exec`, so the process name stays kaya-guests.exe for
the kill sweep. The class: any per-leg build step in a directory two
legs share is a race; builds belong to the deploy phase.

## Swift graphemes: CRLF is one Character, and it does not "contain" CR

The LF-contract negative test failed ONLY on SwiftUI, with a failure
message whose "reads" and "wanted" printed identically — the
difference was invisible bytes. Swift's `String.contains("\r")` walks
grapheme clusters, and CRLF is a SINGLE cluster that is not equal to
CR, so a cheap-out guard `s.contains("\r")` skips exactly the CRLF
input the normalization exists for. Check `s.unicodeScalars.contains`
(or drop the guard); `replacingOccurrences` is UTF-16-literal and
unaffected. Kotlin (Char = UTF-16 unit) and Rust (bytes) do not have
this trap — which is why three backends passed and one failed a test
whose two printed strings looked identical.

## An unchecked interpreter build degrades to yesterday's dylib

validate-mac invoked `tools/swiftui/build-dylib.sh >/dev/null` with no
status check. When a type error landed in KayaSwiftUI.swift, swiftc
failed, the failure vanished into the lane log, and all 152 mac legs
ran — and PASSED — against the previous green dylib sitting at
target/swiftui/libkaya_swiftui.dylib. The false PASS surfaced only
because the iOS lane compiles the same file and checks its build.
The fix: the dylib build's exit status kills the lane. The class
(same family as the dune-staleness trap): every build a validation
script runs must fail the run when IT fails — a build whose output
path already holds yesterday's artifact fails SILENT by default,
because the legs it feeds still find something to load.

## Measuring the thing you are about to replace is circular

The WinUI list-detail arm decides which presentation to render by
reading the window's width — and it read it the way `menu_presentation`
does, off `Content().XamlRoot().Size()`. That is safe for menus, which
never replace the window's content. The list-detail arm's whole job IS
to replace it, so the reading and the thing being read were the same
object at different moments. `KAYA_SPLIT_TRACE` showed the measurement
alternating between `Some(900.0)` and `None` across consecutive
reconciles as the tree was swapped underneath it, and the leg failed
with the ARM saying `stacked` while the ASSERTION said `regular` about
the same instant.

The mechanism is DOCUMENTED rather than a quirk, and looking it up
would have produced it directly: a UIElement's `XamlRoot` is null until
the element is parented into a live tree, and returns its parent's once
it is. An element mid-reparent therefore has no XamlRoot at all, so
anything measuring through it reads null exactly when the arm needs an
answer.

Two lessons. A size class is a property of the WINDOW, so read it from
the window (`GetClientRect` + the DPI scale) — available before XAML
has laid anything out, and unaffected by what currently occupies it.
And the arm and the assertion must read from ONE source: when they
measure differently they can disagree about a single instant, which
looks like a lowering bug and is not one.

A CORRECTION WORTH KEEPING, because it shows how a guess calcifies: the
first fix cast the content to `FrameworkElement` "because XamlRoot
lives there, not on UIElement", and that reason was FALSE — XamlRoot is
declared on UIElement, in Microsoft's docs and in this repo's own
generated bindings. The cast fixed nothing; it rode along with other
changes and its wrong rationale went into a code comment, where it
would have been read as established fact by the next person. Verify a
platform claim before writing it down as one.

The wider process note, because this cost several round trips: four
consecutive fixes were guesses (cast, short-circuit, layout pass,
optional read), each plausible, each moving the failure rather than
ending it. At least two were DOCUMENTED — "Element is already the child
of another element" is a well-known WinUI error, and XamlRoot's
availability is written down — so a search would have ended them
without a lane round trip each.

THE TRIGGER IS THE SECOND FAILED FIX. One guess is a hypothesis; two in
a row means the model of the platform is wrong, and no further guess
repairs a wrong model. At that point do both: SEARCH (the platform's
error strings are the query) and INSTRUMENT (an env-gated trace, the
KAYA_MENU_TRACE precedent). The trace ended this in one run.

## A field only ONE lowering writes reads as an answer to the next one

`formFactor` was recorded by the menu chrome and nowhere else. That
chrome lives inside `#if !os(macOS)` and derives the class from
`horizontalSizeClass`, which macOS does not have — so every desktop
window carried `unknown` from the day form factor landed. Nothing
noticed for two milestones, because the only consumer was the menu
verb and macOS answers that off the REAL NSApp.mainMenu instead of the
model. The bug was invisible precisely because the one platform that
could see it had a better source.

The second adaptive lowering asked the model, got `unknown`, and took
the wrong arm. The fix was structural: the reading moved out of the
menu chrome into a recorder applied to every window on every platform,
width-derived where there is no size class.

The general shape, now enforced by check-verbs' stamped-observation
rule: a field the harness READS must have at least one write outside
every platform conditional. A conditional-only write leaves the other
platform reading an initial value that is indistinguishable from an
observation. Two related habits: an observation must be stamped by
EVERY arm that can render (an arm that never writes is derived-by-
default in the others), and the field's initial value should be the
one that is honestly wrong, never a plausible reading.

## Two collections named `entries`, and the wrong one compiles

Both interpreters had a navigation stack and an entry-WIDGET registry
sharing the name `entries`. A harness verb that meant "how deep is the
nav stack" referenced the registry instead and counted text-entry
widgets. It type-checked, compiled, and would have reported a number.
No gate could see it: the field exists, the type is right, and the
value is a plausible integer.

Renamed to `entryWidgets` in both interpreters, because this is a class
no checker catches — the fix has to be the name. When two collections
in one file can both satisfy a reference, the one that is easier to
reach by accident is the one to rename.

## A green `cargo build` proves less than it looks like it does

Adding two methods to the `Stage` trait with no defaults, then running
`cargo build --lib --features harness`: clean. The real `Stage` impls
are cfg'd per platform (gtk.rs on Linux, winui on Windows) and the
mock ones are `#[cfg(test)]`, so a host build compiles NONE of them.
`cargo test` found three unimplemented impls and one non-exhaustive
match; `check-targets` found the cross-compiled backends. Neither was
optional. When a trait grows on this codebase, the build is the weakest
of the three signals.

## Editing a script a lane is CURRENTLY EXECUTING corrupts that run

A negative test doctored tools/validate-mac.sh and restored it seconds
later, while a matrix run was executing that same file. The mac lane
died with `line 96: ls/check-compose.sh: No such file or directory` —
"tools/" with three bytes missing. bash does not read a script into
memory; it reads it incrementally by BYTE OFFSET, so rewriting the file
under a running interpreter makes it resume mid-token at a position
that no longer means what it meant. Four lanes passed, one failed, and
nothing was wrong with the tree: `bash -n` was clean and line 96 was
correct by the time anyone looked.

Two habits fall out. Do not modify tools/ while any lane is live —
doctor a COPY, or wait. And when a lane fails with a syntax or
not-found error naming a file that is demonstrably fine, suspect
concurrent modification before suspecting the change under test; the
evidence is gone by the time you read the log, which is exactly what
makes it worth writing down.

## `$?` after an `if` that took no branch is 0, not the command's status

tools/keyed.sh wrapped each gate as `if "$@"; then store; fi; status=$?`
— and a FAILING gate came back as a pass. An `if` compound whose
condition is false and which has no `else` exits 0 itself, so `$?`
reads the `if`, not the command inside it. Under KAYA_FAST=1 every
wrapped gate would have reported success no matter what it found.
Spell it `"$@"; status=$?` and branch on the variable.

The general rule, now enforced by check-shell: `$?` is read ONCE, on the
line right after the command, into a named variable, and everything
downstream tests the variable. Two more ways it slips, measured in bash
5.3 rather than assumed — the assumption was wrong the first time:

    cmd; local rc=$?        rc=1. FINE. $? expands before `local` runs.
    cmd; local rc; rc=$?    rc=0. BROKEN — the bare `local rc` is the
                            last command, and the capture reads IT.
                            shellcheck says nothing at any severity.
    local rc=$(cmd)         $? masked. SC2155, warning, already caught.
    cmd; if [ $? -ne 0 ]    SC2181, but STYLE only, which the gate does
                            not run.

Note the shape everyone repeats as the safe one — declare first, assign
second — is precisely the broken one here. "Declare and assign
separately" is right for `$(cmd)` substitution (SC2155) and wrong for
`$?`, because the two are masked at different moments: a substitution
runs during the assignment, and `$?` is already gone by then.

Two things about how it was caught, both worth copying. The wrapper's
own gate found it on its first run, because that gate asserts a FAILING
task is never cached — an assertion about the failure path, which is
the path nobody exercises by accident. And the same gate then failed a
SECOND way: its "KAYA_FAST unset consults no cache" clause ran inside a
lane launched with `KAYA_FAST=1 tools/validate-mac.sh`, inherited the
exported variable, and was quietly testing the opposite of what it
claimed. A self-test has to CONSTRUCT its environment (`env -u`), never
inherit one — an inherited variable turns an assertion into a
tautology, silently, and only under the conditions you were trying to
check.

## A gate that reads PHYSICAL lines cannot see a continued command

check-pins grew a clause requiring `--disable-automatic-resolution` on
SwiftPM invocations, self-tested by deleting the flag from
gen-guests.sh — and the gate reported OK. The invocation is
backslash-continued: `swift run \` on one line, `--package-path` on the
next. The scanner matched both tokens on ONE physical line, found no
line carrying both, and concluded there was no SwiftPM invocation to
judge. A missing flag and an absent command are indistinguishable to a
clause built that way, and the polarity is the bad one — silence reads
as clean.

Every line-based scanner over shell must join continuations first
(check-shell and check-pins both do now, numbered by the first physical
line so the finding still points somewhere useful). The general shape:
when a gate looks for the ABSENCE of something, ask what makes the
whole construct invisible — that path, not the one you tested, is where
the false green lives. The sibling failure surfaced immediately after:
the self-test fixture, a string literal holding a fake invocation,
matched the scanner's own file. A gate that scans a directory scans
itself.

## The aggregation outer MUST delegate QI (the NavigationView saga)

NavigationView stow-crashed (c000027b, bare E_NOINTERFACE) in every
kaya process ~100ms after creation. Three sessions of suspects fell:
not the SelectionChanged delegate, not resources.pri adjacency, not
the metadata provider, not XamlControlsResources placement, and NOT
a hosting constraint (a first verdict said "unpackaged hosting" —
wrong: rust hosts only looked immune because they exited before the
async work ran). The KAYA_WINUI_NAV_PROBE instrument (permanent,
flag-gated: wraps the primary mount in a NavigationView) plus one
probe line found it: Application::Current() ITSELF failed
0x80004002.

Root cause: kaya's Application is COM-aggregated with a kaya outer,
and windows-core's #[implement] answers unknown-IID QIs with
E_NOINTERFACE — but the AGGREGATION CONTRACT requires the outer to
forward every IID it does not implement to the inner's
non-delegating IUnknown. Application.Current() is an identity QI for
IApplication through the outer, so it failed; simple controls never
consult Current at runtime, but NavigationView's ResourceAccessor
does — hence one control crashing while ComboBox and friends lived.

The fix is the hand-rolled KayaOuter (winui/mod.rs): three vtable
slots (identity / IApplicationOverrides / IXamlMetadataProvider) and
a QueryInterface that forwards everything else to the stored inner.
A startup assert now calls Application::Current() right after
composition — if the delegation ever regresses, the process fails AT
THE SOURCE with a named message instead of stowing minutes later.
The lesson: a bare async E_NOINTERFACE in XAML work points at an
identity QI the Application outer refused — check the aggregation
before anything else.

Two sub-traps from the same session:
- XAML refuses re-parenting ("Element is already the child of
  another element"): long-lived elements (switcher buttons, section
  panes) must be DETACHED from their old panel before appending to a
  new one — or better, build chrome once and grow it incrementally
  (the shipped shape; a full rebuild happens only on a presentation
  hint change and detaches everything first).
- WinRT SelectionChanged (like TextChanged) is raised ASYNC: a
  quiet-FLAG guard's window closes before the late raise arrives.
  If a native selection control ever returns here, the guard must be
  the entry_swallow COUNTER, incremented only on real moves (a no-op
  set raises nothing and would leave the counter armed).

## OCaml evaluates list literals right-to-left

The first direct-style OCaml cut kept containers as
`column [ label ...; button ... ]` with eagerly-evaluated children.
OCaml's evaluation order for constructor arguments (and therefore
list literals) is right-to-left, so children were CREATED in reverse
document order — every index-based harness registry shifted, and
half the scenes failed with swapped labels. The reader-era binding
was immune (the list held closures; List.map applied left-to-right).
(Array literals happen to evaluate left-to-right today, but the
manual calls the order unspecified — building the API on it would
mean a toolchain bump could scramble every scene.) An interim fix
used statement-shaped bodies with an ambient parent stack; the final
shape is CURRIED CHILDREN: every creator ends in [()], and omitting
that unit leaves a pure [unit -> widget] partial application, so a
child list literal only allocates closures — the container realizes
them itself with [List.iter], whose left-to-right order IS specified.
Corollaries: [w] wraps an already-realized widget for a child slot,
a creator with NO argument applied is expectation-dependent — OCaml
discards its leading optionals only where the expected type is
already known when the expression is checked (tested on 5.4.1: bare
[spacer] typechecks INLINE in a container's list literal, but the
identical list factored into a [let] fails with "the first argument
is labeled ?grow, but an unlabeled argument was expected") — so
scenes apply an argument ([spacer ~grow:1.0]) or eta-wrap, the
expectation-independent spellings that survive refactors, and an
add_child for a For/When must land AFTER its
template_end (inside the scope it reads as blueprint content and the
scene rejects it).

## ffmpeg in a `while read` loop eats the loop's input

`grep … | while IFS= read -r line; do … ffmpeg …; done` — ffmpeg reads
stdin when it has one, and the stdin it inherits inside that loop IS
the pipe the loop is reading. It consumed whole transcript lines and
the leading bytes of the next, so a step arrived as
`AYA_HARNESS: +107ms expect_ax …` with the `K` gone.

What made it survive for milestones is that a corrupted line still
produces A still. The step-name parse fails to match, the offset falls
back to 0, and the frame gets cut from the wrong moment in the film —
but the file exists, and the gate counted FILES. The two eras failed
differently and neither looked like corruption: the sed-era parse
didn't match, stripped nothing, and sanitized the whole broken line
into the filename (`step-12-AYA_HARNESS___107ms_expect_ax_radio…`,
which reads as an odd name, not a bug); the python-era regex correctly
refuses to match and yields an empty name (`step-07-.png`). Measured on
one 185-leg recording run: 908 of 1790 stills affected, and the sed era
also lost 38 steps outright.

It is LOAD-DEPENDENT — zero occurrences with the extraction fan-out
capped at 8, hundreds unbounded — so it hides completely when you
reproduce a single leg by hand, which is exactly what you do when
chasing it.

Fixed two ways, deliberately. `-nostdin` is what ffmpeg ships for this
and `tools/check-shell.sh` now requires it on every invocation. But
the loop ALSO reads from fd 3 (`done 3< <(grep …)`), because -nostdin
only fixes the command someone already thought about — the fd makes
the loop immune to the next stdin-reader added inside it. Same shape
to watch for with `ssh`, `adb`, `dotnet` and `java` in a read loop.

## A per-entry affordance built once at mount cannot be rebuilt later

2026-07-27, the list-detail wrapper swap. WinUI's back bar is created
in `mount_entry`: the entry's WRAPPER is a two-row Grid whose row 0 is
the bar and row 1 the content, and `entry.back_button` is the handle
kept to it. Nothing rebuilds that wrapper afterwards.

So the split arm, wanting no back arrow above a detail pane that covers
nothing, cleared the handle. The arrow went away and the window was
then permanently unable to pop: collapse it back to one pane and the
affordance the other arm restores no longer exists. HIDE IT, NEVER
CLEAR IT — `Visibility`, both arms writing it, so neither reads as an
answer the other one left behind.

Two smaller pieces of the same lesson. The split arm renders the
entry's WRAPPER rather than its content, which is why a back arrow
appeared above the detail pane at all — the bar is row 0 of the thing
being handed to the pane. And the Windows lane was the only one that
caught it: every other backend builds its back affordance per refresh,
so the bug does not exist there to find.

## libadwaita's collapse and its navigation stack are independent signals

Measured on libadwaita 1.7.6 before the GTK list-detail arm was
written, and worth keeping because two of the three are the reason the
arm is shaped the way it is.

- Flipping `collapsed`, which is what crossing the breakpoint does,
  does NOT change `show-content`. A resize is therefore not mistakable
  for a pop, and the detail page stays alive across the flip — which is
  what lets `notify::show-content` going false MEAN "the user went
  back" rather than "the window got narrow".
- `navigation.pop` sets `show-content` false and emits that notify.
  One signal, one meaning.
- An UNCOLLAPSED view still accepts `navigation.pop`. GTK does not
  decline back on a wide window the way Compose's `canNavigateBack`
  does, so the two-pane rule CANNOT be enforced by trusting the widget
  to refuse. It is enforced by removing the affordance: no button when
  both panes are up, and a harness `back` that declines to press a
  button that is not there.

## A case-only rename does not stick on macOS

2026-07-28, the background-work sweep. A Haskell guest was written as
`Background.hs` while its cabal stanza said `main-is: background.hs`.
The local build found it, the scene ran, validate-mac went green. Linux
is case-sensitive and would have failed — after a full matrix, on the
lane furthest from the change.

TWO THINGS COMPOUND HERE. First, every build manifest in this repo
names files as STRINGS — cabal `main-is`, dune `modules`, Cargo `path`,
csproj globs, gradle sources, the C Makefile's SCENES — so a case
disagreement is invisible to every macOS tool. Second, the obvious fix
does not work: `mv Background.hs background.hs` is a NO-OP on a
case-insensitive filesystem, and `git add` keeps the old name, so the
mismatch survives a fix that looks like it worked. RENAME THROUGH A
TEMP PATH, then `git add` the lowercase name and confirm with
`git diff --cached --name-only`.

Gated since, by tools/check-case.sh: git already stores the exact bytes
of every tracked path, so the check compares them against the directory
listing case-sensitively. It is self-tested both directions and it
reproduces this exact defect.

## A test that waits on another thread must be bounded

Same day, adding `kaya_wake`. The wake test spawned a consumer, parked
it, rang the doorbell and `join`ed. To prove the test could fail I
deleted the notify — and the suite HUNG for ten minutes before the
harness killed it.

A hanging gate is the worst way to report: it burns the timeout, says
nothing about what broke, and on a matrix lane reads as contention. The
test now hands the result back over a channel and takes it with
`recv_timeout`, so a missing notify says "wake left the consumer
parked: the notify is missing" in five seconds. Any test that waits on
another thread wants the same shape — `join` is only safe when the
thread cannot fail to finish.

## The iOS simulator does not enforce the app sandbox

2026-07-27, designing file dialogs. The whole shape of that feature
rests on one fact — that a file descriptor opened from a security-scoped
URL stays readable after `stopAccessingSecurityScopedResource()` — and
the obvious move was to prove it on the iOS lane.

It cannot be proven there. A simulator app built and installed the
normal way read `/Users/<me>/Projects/kaya/DESIGN.md` — arbitrarily far
outside its container, on the host filesystem — with a plain `open()`
and no security scope of any kind. There is nothing to enforce, so any
scope-related assertion passes for free.

That makes the simulator lane STRUCTURALLY BLIND to an entire class:
anything whose behaviour depends on the sandbox denying something. A
green leg there is not evidence. It is the same shape as the iPadOS
menu-bar gate (docs/deferred.md) — a platform behaviour the lane cannot
witness — and it will not be the last one, because the simulator is a
different security world wearing the same SDK.

The remedy is a real device, which needs code signing that this repo
otherwise never wants: `security find-identity -p codesigning` was empty
until an Apple ID was added to Xcode. The file-dialog facts were
measured that way on an iPhone 17 Pro, and the measurement CARRIED ITS
OWN VACUITY GUARD — step one opened the picked file with no scope and
required EPERM, so a phone that also failed to enforce would have
reported that rather than a row of green ticks. Copy that shape: when a
test depends on something being DENIED, assert the denial first, or the
result means nothing.

That probe is KEPT, at tools/ios/scopeprobe/, because the next question
the simulator cannot answer will not be the last one. `build.sh` there
compiles, signs, installs and launches it on a paired phone; it is
deliberately NOT a lane and cannot become one, since it needs hardware,
a developer account, and a human to tap through a picker. New
measurements go in main.swift, behind the same vacuity guard.

IT PAID OFF THE SAME DAY, on a question the published material answers
WRONGLY AND CONFIDENTLY: whether a URL from `forOpeningContentTypes`
permits writing. Forum answers and tutorials say it is read-only and
that you must use `init(forExporting:)` to write. On hardware,
`open(O_RDWR)` succeeds, the write lands, and the write descriptor
outlives the scope exactly as the read one does. Had that been taken on
reputation, save would have been designed around a second picker it
does not need. When hardware can answer a capability question, ask the
hardware — and make the probe's write a NO-OP (read a byte, seek back,
put the same byte) so proving the capability never edits the file.

Two smaller things that cost time on the way in. Adding the probe put a
shell script in a NEW tools/ subdirectory, and check-shell's shellcheck
loop enumerated the directories it knew about instead of walking the
tree — so the new script was linted by nothing, silently. Widening it to
`find tools -name '*.sh'` immediately surfaced tools/lib/swift-toolchain.sh,
a sourced library that had never been linted at all. And when writing
that fix: a comment line STARTING with `# shellcheck` is parsed as a
directive rather than prose, so a sentence that happens to begin with
the tool's name fails the gate with a parse error about a missing `=`.

## The panel that shows you someone else's directory

Driving a real NSOpenPanel in the filedialog scene cost most of a
session to two facts that produce the SAME symptom — the panel opens
somewhere other than where it was aimed — and neither says anything at
all when it happens.

**`directoryURL` is read only at presentation.** Setting it on a panel
that is already on screen is not an error and has no effect. The
interpreter first did exactly that: presented the panel, then pointed
it. The fix is to ARM the directory on a pending variable and apply it
in the presentation path; the scene's `file_dialog_goto` therefore comes
BEFORE the click that shows the panel, which reads backwards until you
know why.

**A panel aimed at a directory that does not exist silently restores
its last-used location** — where "last used" is remembered per app
identity and outlives the process. One run inherited `kaya-paneldrive`,
a directory left by an unrelated probe binary that had run an hour
earlier. The scene then compared against that. Nothing in the panel, the
logs, or the completion mentions a substitution happened, so the failure
reads as "our aim is wrong" rather than "our aim was ignored".

**And the two APIs named after the temp directory disagree.** `nix
develop` sets a fresh `$TMPDIR` per invocation; `std::env::temp_dir()`
honors it, and Foundation's `NSTemporaryDirectory()` does not. The guest
wrote its file under `/tmp/nix-shell.PDldIE/...` while the interpreter
aimed the panel at `/var/folders/.../T/...`, which had never existed —
straight into the silent-fallback above. The scene's whole premise is
that guest and interpreter are one process and can agree on a path
without runner involvement; that premise holds only if both sides
compute the path the same way, so the Swift side reads `$TMPDIR` itself
(`kayaTempDir()`) rather than asking Foundation.

The guard for all three is one line of precondition in the
`file_dialog_goto` verb: if the resolved directory does not exist, FAIL
THERE, naming the resolved path. Whichever of the three went wrong, the
scene now stops at the aim with the path in hand instead of at an
assertion about a directory nobody chose. A sibling check rejects a path
still containing `$` after expansion, since an unknown substitution
otherwise becomes a literal path segment and lands in the same fallback.

That expander is worth one more line. Substituting `$TMP` by plain text
replacement also consumes the first four characters of `$TMPDIR` and
leaves `<tmp>DIR` — a nonexistent path that looks like the scene author's
typo rather than the expander's. It takes the whole identifier after the
`$` and looks THAT up, so an unknown name survives intact and is
reported by the name that is actually wrong.

## check-targets is blind to exactly one backend

`gtk-sys` needs the distro's pkg-config world, so check-targets cannot
cross-compile the GTK backend — only check-gtk (docker) compiles it, and
CLAUDE.md therefore says to run check-gtk after any gtk.rs change. That
is an instruction someone has to remember, and it failed the first time
it mattered: the file-dialog slice added three `Stage` methods, mac and
windows compiled, every fast gate went green, and the linux lane died on
`not all trait items implemented, missing: goto_directory`. A whole
matrix run to learn a one-word fact.

check-targets now also reads the `Stage` trait and each backend's impl
as TEXT and requires every method with no default body to appear.
Weaker than compiling — it cannot see a wrong signature — and that is
the trade: no docker, runs with the fast gates, catches the class that
actually escaped. check-gtk still compiles the real thing.

The general shape is worth keeping: when a gate is structurally unable
to cover one member of a set it otherwise covers, the gap does not
announce itself. Everything is green and one platform is simply not
being asked. Give the uncovered member a cheaper check rather than an
instruction in a document.

## Two more vocabularies nobody was counting

The file-dialog slice needed a `$TMP`/`$PID` expansion in scene paths,
and it went into KayaSwiftUI.swift only. Nothing said so. Verbs and wire
constants are checked across both interpreters by check-verbs precisely
because that layer is where "landed everywhere except..." lives — but
SUBSTITUTIONS were a third vocabulary on the same layer, and an
interpreter that does not expand a token uses it as a literal path
segment: a directory that cannot exist, which on macOS means the picker
quietly shows its last-used location instead. Wiring the scene onto
android would have shipped exactly that. check-verbs now reads every
`$TOKEN` out of tools/scenes/*.steps and requires an expansion in both
interpreters, the same way it requires the verbs.

The second one is about the gate cache. tools/keyed.sh skips a gate
whose declared inputs have not moved, so a file a gate READS but does
not DECLARE is a false-PASS generator that misfires exactly when that
file is what changed. check-steps was declared `["guests"]` from the day
it was written; it later grew a rule reading all four backends, and
removing a depth-stub declaration — the edit that makes its missing legs
a real failure — would have re-run nothing. That was caught by hand,
which is not a mechanism. check-keyed now reads each gate's script for
repo paths it names in code and requires the declared set to cover them.

TWO ROUNDS OF FALSE POSITIVES ON THE WAY, both the same mistake: prose
mentioning a path is not a gate reading it. Comments citing CLAUDE.md
for the reasoning behind a rule, then `echo` messages citing
docs/traps.md the same way. The rule that separates them is that a
quoted string with a SPACE in it is a message; a path in a read position
is a bare word or a quoted string of just the path. It gives up paths
built at runtime, which is the honest limit of reading a script rather
than running it.

And the general shape behind both: a gate that string-matches should say
HOW MUCH it matched, and refuse a count that cannot be right. check-verbs
prints "43 verbs, 73 constants"; check-sugar-surface bails if the kind
list comes back empty. Auditing the rest after the check-stubs vacuity
turned up no third case — check-abort builds and runs real artifacts,
check-ambient-tx self-tests both directions — but check-stubs went four
milestones on a convention no backend ever wrote, so the audit is worth
repeating whenever a gate's verdict rests on finding a literal.

## What GTK's file chooser publishes, and what it does not

The mac panel was measured with tools/mac/paneldrive.swift before a line
of the arm was written, and it overturned a carve-out already accepted
into the plan. Same discipline for GTK, and the probe answered four
questions the code would otherwise have guessed at.

**It is in our process.** With no xdg-desktop-portal installed — the
validation image has none — `gtk::FileDialog` presents its own chooser
rather than handing off, so it sits on the same a11y bus as every other
widget. This matters less than it would on mac: the AT-SPI walk starts
at the DESKTOP, so a portal-hosted chooser in another process would
still be reachable. It would simply be a different application node.

**It publishes no accessible ids at all.** Not on the dialog, not on the
buttons, not on the rows. Everything is found by role and name, which is
why the arm titles the dialog itself — that title is the only identity
there is.

**There is no "where" control.** mac has a popup naming the directory;
GTK has a path bar of toggle buttons, one per component, and the current
folder is the one whose state is PRESSED. Not CHECKED — checked is false
on every one of them. The filter combo's own toggle button is in the
same tree and has to be excluded or it collides.

**Rows are one string.** `picked.txt 12 bytes Text 01:00`, so the
filename is the first field. The column header is a `table row` too; the
data rows are the ones parented to the inner `list`, while the header
hangs off the `tree table` directly.

**Rows cannot be clicked.** Their only action is `listitem.scroll-to`,
and `grab_focus` fails outright. Selection is the parent list's job,
through the Selection interface and an index.

Three findings cost a run each and are worth knowing before the next
platform:

**Pressing Open with nothing selected still returns a file.** With one
row in the directory the chooser completes with that row, so
`file_choose picked.txt` would have passed on a backend that never
selected anything. The scene now keeps a DECOY that sorts before the
target and holds different bytes, so skipping selection returns the
wrong file and fails both the name and the byte assertion. That hole was
open on mac too.

**select_child ADDS in a multi-select chooser.** Choosing "picked.txt"
returned BOTH files, decoy first, because the list already carried a
selection. Clear it first.

**A second picker inherits nothing.** NSOpenPanel happens to reopen
where it last was; GTK opens on Recent, which has no path bar at all. A
scene that armed the directory once and relied on the platform
remembering reads a directory nobody chose on one platform and an empty
one on the other. The scene arms before every pick.
