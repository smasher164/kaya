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
  under GTK's 34pt minimum button height, which is why the `grow` scene
  was two children at 25/75 (38 and 114pt) then. It is three at 25/50/25
  now, in a 540x330 window whose ~250pt column divides ~63/126/63, and
  the BINDING minimum has moved to the textarea's declared 96pt floor.
  The arithmetic lives beside the widgets in guests/rust/grow.rs and in
  grow.steps' own header — recompute it there whenever a share moves.
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
- **GTK flex measurement must invert its own weighted allocation, not
  sum grower naturals.** The portfolio's three equal-weight account
  cards needed 145/100/70px naturally. Their sum, 315px, was not a
  valid answer: allocation gives each grower one equal track, so the
  first card received about 105px and its table and total overlapped.
  The smallest valid pool is 435px. The inverse must run the exact
  allocator too: weights 1/1/2 with requirements 1/1/3 need 7px, not
  the ratio estimate's 6, because the last grower absorbs rounding
  dust. Nor is the floating-point ratio seed always conservative:
  weights 3/1 with requirements 1/4 seed 14px, whose exact allocation
  is 11/3; the verifier must advance to 15px and 11/4. `check-gtk` runs
  all three cases in the Linux backend container.
- **A table viewport contains rows; rows do not have to fill it.** At
  the corrected 800x600 portfolio size, X11's short Brokerage table
  legitimately drew 97px of a 117px vertical viewport and Wayland's
  drew 105px. Exact `expect_fills` made both green layouts red. The
  table arm is therefore one-sided against vertical overflow, while
  `expect_column_edges` owns horizontal clipping. Native macOS cell
  ink is one-sided too: it measured 527pt inside a correct 636pt
  viewport because the last label ends before its column does; the
  broken capture was the opposite fact, 409pt of ink inside a 145pt
  viewport. A cell-ink endpoint may reject overflow, never demand
  equality with a native column boundary. The first cross-backend audit
  found three different `expect_fills` meanings hiding behind that
  sentence: Swift returned success without reading rows, Compose had no
  table extent, and WinUI demanded exact equality. The shared table
  scene now forces the one-sided vertical read on every backend; its
  pre-fix Compose and WinUI diagnostics were watched printing "no
  container layout recorded" and 113dip/307dip respectively. Horizontal
  readers require live current-cell bounds inside a positioned viewport,
  and the viewport must match its assigned track in both directions: a
  300pt viewport against a 297pt track passed the first one-sided
  predicate just as the clipped 145pt viewport did. The compiled probe
  drives exact 300/300, underfill 300/303, and overflow 300/297. The
  start is two-sided too: GTK's first reader tracked only each line's
  right endpoint, so a whole table shifted left or inset right could keep
  the wanted clusters and still pass. Starts at -2/+2px are the tolerance
  boundary; -2.1/+2.1 are watched overflow/underfill failures. The scene
  repeats the read after each header re-declaration rather than letting
  the first frame answer forever.
- **A main-queue resize is not a completed SwiftUI layout turn.** The
  harness returned from `DispatchQueue.main.sync { setContentSize(...) }`
  with the previous viewport, cell frames and flex track still mutually
  consistent, so the following retryable expect could pass once without
  ever yielding for their reporters. Hashing the table subtree did not
  help a resize or a sibling-only transaction, and an unversioned track
  could still agree with the wrong viewport. Every applied batch and
  native content-size change now advances an observable table geometry
  epoch before acting; viewport, cells and track carry that generation,
  and the track reporter's task is keyed by it so even a same-size resize
  republishes. The real-NSWindow probe watches the old triple become
  unusable synchronously, then waits for one fresh matching triple at a
  changed size and again at the same size.
- **Stretch does not jump over a same-axis collection wrapper.** The
  mac portfolio's detail column already filled its track, but its new
  nested accounts For still defaulted to start and handed each native
  table a 145pt viewport. `accounts.rows(align="stretch")` is the
  required inner hop; the forcing scene checks both authored alignments
  and the 800x600 window before it reads table edges.
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
- **A TextKit 2 scroll to a range the view has never shown lands on a
  GUESS, and the miss is permanent.** TextKit 2 lays out the viewport
  and ESTIMATES the rest, so `scrollRangeToVisible` for a range below
  the laid-out region scrolls to an estimated position and reports
  nothing. Measured on iOS with the editor's 59-line document, revealing
  its last two bytes from the top: the scroll landed at offset 1178 with
  `contentSize` reading 1369; when the real layout replaced the guess,
  `contentSize` was 1314 and the target line sat at 1276..1298 against a
  visible 1178..1274 — ten points below the fold, with the one-shot
  already spent so nothing scrolled again. The same estimate is why that
  document's `contentSize` reads 1369 from the top and 1314 from the
  bottom. Force the layout up to the target first
  (`NSTextLayoutManager.ensureLayout(for:)` over document-start..target)
  and then call the platform's scroll. Only up to the target: nothing
  below it can move it, and everything above it must be real anyway —
  a character's position IS the height of everything before it. Guard:
  `editor.steps` reveals the LAST match of a document far taller than
  the viewport, which is where an estimate has the most room to be
  wrong; `ranges.steps` reveals mid-document and cannot catch it.
- **A text segment's frame is in the CONTAINER's coordinate space, not
  the view's.** They differ by `textContainerInset` — 8pt top on a
  stock UITextView — so a visibility read that intersects segment frames
  with `view.bounds` answers "visible" for glyphs up to 8pt below the
  fold. The arithmetic that proves it on any document: `contentSize`
  minus `usageBoundsForTextContainer` is exactly the two insets (1314 vs
  1298, measured). Move the viewport rectangle into the segments' space
  rather than the other way round, so both sides of the comparison come
  from the text system itself.

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
  built the host binary — so the SAME dylib renders different control
  generations per host runtime. SINCE THE 2026-08-16 SDK BUMP
  (flake.nix's `buildInputs = [ apple-sdk_26 ]`), the kaya-linked legs
  (rust, go, c, ocaml, haskell — and swift, modern already via the
  system toolchain) stamp sdk 26.5 with minos 14.0 and exercise the
  MODERN generation, while the vendor-stamped hosts (python 14.4,
  .NET 14.4, zulu JDK 11.3) keep the COMPAT generation covered —
  observed coverage, held by tools/check-design-generation.sh rather
  than by this paragraph. In the compat generation `Button.sizeThatFits` answers borderless metrics while
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
  wired legs.** Depth stubs are the sanctioned way to hold breadth
  open, and they COMPILE
  — so every compile gate (check-targets, check-gtk) stays green
  while a runner that has since gained the scene's legs will die on
  the stub at suite time (the GTK scroll materialization was
  believed applied while the stub survived; the linux suite was the
  first to notice, 2026-07-22). Guard: tools/check-stubs.sh
  cross-checks every runner's wired scenes against its backend's
  stubs. A STUB IS A CALL, NOT A SENTENCE, since 2026-08-05:
  `depth_stub("<scene>")` in Rust, `depthStub` in Kotlin,
  `kayaDepthStub(_:on:)` in Swift. It was a free-form string — the
  spelling "<scene> is not yet materialized" — for four milestones,
  which no backend ever wrote, so the gate could only ever pass;
  a companion check now fails any backend that refuses in its own
  words. Self-tested with a synthesized bad pair. Corollary
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
- **A textual leg census needs a marker setup cannot print.** The
  2026-08-24 summary reported Android 128 and total 1,334, but the runner
  had 112 real Android legs and the matrix 1,318. Thirteen per-device and
  three per-suite APK-staging successes also ended `: PASS`, exactly what
  `validate-all` counts. Staging now prints `: OK`;
  `android-leg-order.py`'s real-source self-test changes it back and
  `check-steps` must refuse.
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

## A vacuous opening expect is not Swift scene admission

2026-08-23, the dynamic-table matrix. Only
`listdetail-python-swiftui` failed: its opening `expect_entries 0`
passed against the pristine model, then the click 10ms later could not
resolve `button#0`. The label existed afterward. Python had submitted
the label, button and mount in one atomic build transaction, so this was
not a partial transaction; SwiftUI's primary `onAppear` had started the
command pump and selftest as siblings, and the selftest outran the main
queue apply. The neighbouring languages passed by timing.

An opening observation supplies a bounded render retry, but a model-only
zero can be true before a scene exists. Swift therefore admits the
selftest only at the completed apply-batch boundary after any surface
has mounted content. A node-bearing batch with no mount arms one
five-second grace period instead, so the unmounted-scene diagnosis above
still runs; a later mount wins immediately and a stale timer cannot
start a second harness. `tools/check-steps.sh` holds the all-surface
route and the one-shot transition, including a compiled truth table and
watched-red shadows.

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

The GUARD is not the FIX, and for a long time we had the fix wrong too:
we called it resourcing (more cores, or stop running windows fully
concurrent). Concurrency is the TRIGGER, but the failure is a guest
driver bug — see "The wedge is a BSOD in viogpudo.sys" below. Read that
before treating a red windows lane as a contention artifact.

## The wedge is a BSOD in viogpudo.sys (VirtIO GPU), not a hang

2026-08-04, from the five minidumps in `C:\Windows\Minidump`. Every
"wedged VM" we have logged since 2026-07-22 is the SAME crash, and the
guest is not hanging — it is bugchecking, writing a dump, and rebooting.
ssh dies and utmctl still says `started` because the VM really is
running; it is on the blue screen and then in early boot.

Bugcheck 0x1000007E (SYSTEM_THREAD_EXCEPTION_NOT_HANDLED),
param1 0xC0000005, faulting at `viogpudo.sys+0xB52C` in ALL five dumps —
the only thing that varies is the driver's ASLR base, which is why the
address always ends in `b52c`. viogpudo.sys is Red Hat's VirtIO GPU
display-only (WDDM DOD) driver, 22.7.38.43, PE timestamp 2025-03-14.

The defect is a NULL-pointer WRITE (exception Info[0]=1,
Info[1]=0x30) in `CtrlQueue::TransferToHost2D`:

    bl   AllocCmd(&vbuf, 0x38)   ; returns NULL when the ring is full
    ldr  x1, [sp, #0x10]         ; x1 = vbuf, NOT CHECKED
    str  x8, [x1, #0x30]         ; <-- bugcheck

`GetBuf` hands out pre-allocated command buffers by popping a free list
with `ExInterlockedRemoveHeadList`; when the guest has more commands
outstanding than the ring has buffers it returns NULL, `AllocCmd`
propagates it correctly, and only `TransferToHost2D` fails to check.
`TRANSFER_TO_HOST_2D` runs on every screen update, so the crashing
process is always `dwm.exe` and the stack is always
`dxgkrnl.sys -> viogpudo.sys`.

This is upstream kvm-guest-drivers-windows PR #1330, merged 2025-03-31;
our binary predates it. The fix makes GetBuf allocate when the free list
is empty. Do not trust version numbers here — verify the code:
`GetBuf` must reference an allocator, and in ours it references only
`ExInterlockedRemoveHeadList` and returns NULL. Upstream's own
reproduction note is the tell for why concurrency matters: it "may
depend on whether the host can keep catching up with frames".

Timeline, which is the whole argument for the trigger: `parallel sweep
by default` (d4ddc03) landed 2026-07-22 13:42; the first of these
bugchecks is 2026-07-22 16:07. Twelve since, none before. The one crash
we can place against a lane log (2026-08-03) was in `select_java`, not
a clipboard suite — the mechanism is per-frame, so no suite owns it.

AND DO NOT FORCE-KILL A VM THAT IS MID-CRASH. deploy-win's boot block
runs `utmctl stop --kill` whenever ssh fails while utmctl says
`started` — which is exactly the state a bugchecking guest is in. On
2026-08-03 the guest booted at 17:10:51 and was killed at 17:10:56,
five seconds into its boot. That is how you corrupt a Windows boot (it
has cost a manual console recovery once), and it is the likeliest
reason 7 of the 12 crashes left no minidump behind: the pagefile dump
is converted to a `.dmp` on the NEXT boot, and killing that boot throws
the evidence away. Wait out a possible bugcheck reboot before deciding
a guest is wedged, and after any recovery check
`C:\Windows\Minidump` — a new file there means the lane did not lose to
contention, it lost to this bug.

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
prints its verb and constant counts on every run (62 and 86 on
2026-08-17, up from 43 and 73 when this was written — read the shape, not
the numbers); check-sugar-surface bails if the kind list comes back
empty. Auditing the rest after the check-stubs vacuity
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

## The mac open panel has THREE shapes, and the machine picks one

The file browser inside NSOpenPanel publishes a different accessibility
identifier per view mode, and the mode is not the app's to choose: it is
the machine-wide `NSGlobalDomain NSNavPanelFileListModeForOpenMode2`
(1 columns, 2 list, 3 icons), which any application's open panel writes
for every application on the box the moment a human clicks View Options.

    View Options -> List     AXOutline                id=ListView
    View Options -> Icons    AXList/AXCollectionList   id=IconView
    View Options -> Columns  AXBrowser                 id=ColumnView

The harness knew only `ListView`. On 2026-08-06 the eight filedialog
legs — one per language — went red together, an hour after passing 8/8,
because that preference had moved to Icons. The panel itself was
perfect: presented, aimed at the right directory, both files in it,
Cancel and OK reachable. Only the identifier had changed. THE LANE'S
COLOUR WAS DECIDED BY A SETTING NO GATE READS AND NOTHING IN THE LOG
NAMED IT.

Three measured facts about driving that browser, all of which cost
something to learn:

**The wrong selection attribute fails silently.** `AXSelectedRows` on an
icon-view browser returns err=0 and selects nothing; icons and columns
take `AXSelectedChildren`, list takes `AXSelectedRows`. A list-shaped
call on an icon-shaped panel therefore looks like it worked and then
opens whatever was already selected — the silent wrong file the scene's
decoy exists to catch.

**In columns mode the selection call lies the other way**, returning
kAXErrorAttributeUnsupported (-25205) while the selection takes. Proved
differentially rather than by hope: picked.txt answered picked.txt,
decoy.txt answered decoy.txt, same panel, same call, same error. The OK
press has always lied the same way (-25204); trust the completion, not
the return code.

**Never walk the whole tree.** In columns mode the panel publishes one
column per path component, and an ancestor column here held 8362 items,
each attribute read a mach round trip to the panel service. An unpruned
identifier search did not finish in 45 seconds; pruned at item roles it
reads the same panel in 40ms. That applies to every panel lookup, not
just the browser — the OK button sorts after the browser in the walk.

**There is a second preference and it decides nothing.**
`NSNavPanelFileLastListModeForOpenModeKey` sits in the same domain, holds
the same 1/2/3 vocabulary, and is the obvious thing to reach for. Every
rotation moved `…ForOpenMode2` alone and the panel followed it while this
key stayed put — measured across all three modes on 2026-08-06, and
again while the rotation landed. Write the one with the `2`.

**Fix the MEASUREMENT TOOL as well as the reader.** The shipped reader
learned all three shapes on 2026-08-06; `tools/mac/paneldrive.swift` —
the probe the reader's own comments cite for those identifiers — kept
hunting `ListView` alone for two more milestones. That is worse than an
ordinary residual: a probe is reached for by someone who does not yet
know what is wrong, so `NO ListView` on a perfectly good panel is the
same wrong answer that cost the original day, delivered by the tool
brought in to answer it. Watched on 2026-08-07: the old probe failed in
columns and icons and passed in list, and in list it printed the header
row twice beside the file. It now reads and drives all three (pruned
walk, per-shape rows, per-shape selection attribute), and names the mode
and the published identifiers when it cannot.

### The browser EXISTS BEFORE ITS CONTENTS DO, and one blocked hop eats the retry

Rotating that preference across the filedialog legs — which is what
`tools/validate-mac.sh` now does, so columns mode runs on every mac lane
— turned up a live race the tree had never exercised.
`filedialog-rust-swiftui` failed every time in columns mode with

    step-failed file dialog list has [], missing "decoy.txt"

on a panel that was up, correctly aimed, and holding both files.

The obvious reading is wrong, and it is worth knowing why, because the
mechanism is not about file dialogs at all. Every `expect` is a bounded
retry (5s on macOS), so the natural conclusion is that the retry compared
content once and gave up. It did not: **it never ran a second time.**
Instrumented on 2026-08-07, the read was submitted 15ms into the step and
returned 6695ms later, HAVING RUN ONCE. The read is a
`DispatchQueue.main.sync`, and the main thread is the very thread busy
presenting the panel, so the whole retry budget went by *inside a single
blocked hop*. When it landed the panel was live, the ColumnView published
0 children, and the deadline was already past, so the miss was final.

    A RETRY BUDGET SPENT WAITING ON THE MAIN QUEUE IS NOT A RETRY BUDGET.
    If a wait is a hop to the thread that is doing the work, the loop
    around it can be arbitrarily generous and still take exactly one
    sample.

python and go pass in columns mode for no better reason than that their
panels present in ~1.3s, so their one hop returns with budget left over.
That is the shape of every "only language X fails" report: a timing
threshold, not a property of X. And the second panel in the same process
reads `rows=2` immediately — the race is with the FIRST panel's fill.

The fix is a bounded poll BELOW the deadline —
`kayaAwaitOpenPanelState(requireRows:)` in `swift/KayaSwiftUI.swift`,
same shape as `kayaAwaitTextWindow` — whose second read is the first one
the main thread is free to serve. Measured fill after the panel presents:
3 polls, ~120ms, in every mode.

`requireRows` is a parameter and not a constant, which is the load-bearing
part: **an empty list is a legitimate answer** to the bare
`expect_file_dialog` (the "wait until a panel exists" form) and to the
directory-only form aimed at an empty directory. Forcing the wait on
regardless was watched costing ~2.9s per expect on an empty directory —
a stall on every use, in exchange for nothing. Only the forms that NAME
FILES wait.

The save-panel sibling needs its own longer post-hop tail. Measured in the
2026-08-23 five-lane matrix: the second request began at +9682ms, its state
read returned nil at +20202ms, and the same panel was readable less than
291ms later; rename, save, and disk readback then all passed. The first main
hop already costs about 8.7s, so the former 100 x 20ms tail expired just
before the sheet's accessibility state arrived. `kayaAwaitSavePanelState()`
now owns a five-second tail; the open-panel browser keeps its shorter bound.

`file_choose <name>` needs the same wait and for a sharper reason: it is
an ACTION, so the step wrapper never re-runs it, and its own read of the
empty browser refuses the row permanently. A read with no retry cover
must do its own waiting.

## The diagnostic that named a cause nobody had measured

The entry that used to sit here said the legs need the app to reach the
front: that NSOpenPanel is XPC-hosted and must become key before it will
present, so a FULLSCREEN application elsewhere keeps this app off the
front and no panel appears. `kayaOpenPanelWhyNot()` printed that
sentence, and half an hour went into a filedialog "regression" that was
not one.

Every load-bearing claim in it is false, and the shape of the error is
worth more than the correction.

* The panel presents and its accessibility tree fully materializes —
  sheet, browser, both files, where popup, Cancel, OK — with the app
  INACTIVE, another app frontmost, no fullscreen app anywhere, unbundled
  and `.accessory`. Measured 2026-08-06 in eight conditions.
* Apple documents no activation requirement anywhere: `NSSavePanel.h`
  conditions `beginSheetModal(for:)` on nothing at all.
* The branch printing it was reached on EVERY mac leg. kaya's guests run
  `.accessory` and never call `activate`, so `NSApp.isActive` is always
  false. **That clause never discriminated anything — it was the only
  sentence that arm could print**, so it was guaranteed to be the answer
  whatever the real cause was.

It then misdirected a second investigation, months later, for the icon
view failure above — an entire session spent on cooperative activation,
`yieldActivation`, launch chains and responsible processes, all of it
downstream of one confident sentence in a failure message.

THE RULE, and it is not about file dialogs: A DIAGNOSTIC MAY ONLY PRINT
WHAT IT MEASURED. `kayaOpenPanelWhyNot()` now answers in facts — no
panel requested; or a panel up (visible=true) that published no
`open-panel` sheet, with `isActive`, the frontmost app's name and the
window count printed as FACTS rather than as a theory; or a sheet whose
browser is none of the three known shapes, listing the identifiers the
sheet actually published and naming the preference that chooses among
them. Both of those branches were perturbed and watched to print before
this was written down, because a message nobody has ever seen fail is
not a guard.

A cause that is merely PLAUSIBLE, printed in the failure text, is worse
than "unknown": it is believed. If the code cannot tell two causes
apart, it says so and prints what it can see.

Activation was measured while the true cause was still open, so the
answer is on the record: an unbundled `.accessory` process CAN take the
front, but only with `activate(ignoringOtherApps:)` — the cooperative
macOS 14 `NSApp.activate()` is refused. kaya does not call either.
Presentation never needed it, and the call that works would take the
user's focus, or another lane's mid-`type` keystrokes, for nothing.

Stale `openAndSavePanelService` processes from earlier aborted runs are
a red herring, checked and cleared during both searches: killing them
changes nothing, and the system relaunches on demand.

## What the Windows file dialog publishes, and the setting that changes it

Measured before writing the arm, like mac and GTK. The shell's common
item dialog is far more legible to UI Automation than either: a
`#32770` window named "Open", the file list under a `List` named "Items
View", the directory in a pane with AutomationId `1001` whose name is
"Address: <full path>", and Open and Cancel as the classic control ids
`1` and `2` — IDOK and IDCANCEL, exposed as ControlType.Pane with class
Button, which is worth knowing before looking for a Button. Rows support
SelectionItem and Invoke patterns, so unlike GTK's they can be selected
directly.

THE ONE THAT WOULD HAVE COST A DAY: rows publish "picked", not
"picked.txt". No UIA property recovers the extension — the Name column
cell reads "picked" too. It is not a property of the platform, it is
Explorer's HideFileExt, which ships as 1, and .txt is a "known type".
With HideFileExt=0 the same rows publish "picked.txt" and match what mac
and GTK publish, which is what tools/scenes/*.steps being compared
byte-for-byte across platforms requires (CLAUDE.md, invariant 6).

So the deploy sets it and then VERIFIES it, every run rather than once at
--provision: it is a per-user registry value any Explorer settings change
can put back, and a silent revert would spend the same debugging round
twice. A fresh VM with the default fails the filedialog leg looking
exactly like a backend bug.

Two things about probing Windows interactively, both of which ate a
cycle here. An SSH session has NO DESKTOP, so the dialog never appears
and the probe reports an empty tree rather than an error — every
interactive probe goes through `schtasks /it` like the legs do. And a
probe that leaves its dialog up keeps the task RUNNING, so the next
`schtasks /run` is a silent no-op and the output file read back is the
PREVIOUS run's. Twice that looked like a code change having no effect.
End the task before re-running, and check `schtasks /query` for Status
when output looks impossibly stale.

## The capability that had no Windows expression

The picked-file redemption path shipped `#[cfg(unix)]` end to end:
PathSource, PickedOpen, PickedFile::open, and a PickedSource::open
returning a POSIX descriptor, with `kaya_open_picked` taking an
`int32_t *out_fd`. On Windows there was no way to redeem a picked handle
at all — the design's whole claim, that kaya hands over a capability the
guest opens with its own file API, had no Windows expression.

IT PASSED EVERY GATE, and the reason is worth keeping. check-targets
cross-compiles the WinUI backend in both feature configurations and was
perfectly happy, because the only thing that would have referenced
PathSource on Windows was the file-dialog apply arm — and that arm was a
depth stub. A cfg'd-out surface whose only cfg'd-in consumer is also
cfg'd out is invisible to a compiler. Nothing is missing until something
asks for it, and the thing that would have asked had not been written.

The handle is now an i64 that means a DESCRIPTOR on POSIX and a HANDLE
on Windows: one integer, two spellings, uniform semantics — the
carve-out shape the binding conventions allow. The rejected alternative
was minting a CRT file descriptor with `_open_osfhandle`, which keeps
the ABI byte-identical and is a trap: a CRT fd is valid only inside the
CRT that minted it, and Python, Go and the JVM each bring their own, so
it would have worked for the Rust and C guests and quietly broken the
other six.

tools/lib/paired-cfg.py is the structural guard: in the core, an item
gated to one platform must have a counterpart gated to the other. The
counterpart may be a stub that returns an error; what it may not be is
absent, because absent reads as fine right up until a backend needs it.
The backends themselves are exempt — gtk.rs IS linux and winui/mod.rs IS
windows, so a one-sided gate there states a fact.

## Show() with an owner on another thread never comes back

The WinUI file-dialog arm runs IFileOpenDialog on its own STA thread, so
the modal Show() does not stall the dispatcher. Passing the app window
as the owner made Show() BLOCK FOREVER without ever creating a dialog:
it disables its owner and waits on the owner's input queue, and the
owner belongs to the UI thread, not this one.

Every symptom pointed away from that. No COM error was logged, because
the one error the arm deliberately suppresses is ERROR_CANCELLED —
cancel is the empty list, so a swallowed failure looks exactly like a
user dismissing the dialog. UI Automation reported no #32770 anywhere on
the desktop, which reads as "the dialog closed" rather than "the dialog
was never created". And the guest ended up showing "cancelled", the
correct response to an empty result.

What found it was tracing each COM call by NAME and the thread by phase:
the arm entered, the thread ran with a good HWND and the right
directory, and then nothing at all — no Show trace, no stage error. A
call that neither returns nor errors is a block, and the only thing
Show() waits on is its owner. Passing None fixes it, and modality is not
lost: kaya already allows exactly one live file dialog per process, and
capi::file_dialog_shown refuses a second — it reports through
crates/kaya/src/fault.rs and the op is dropped, so the leg reddens
instead of aborting.

TWO MORE THINGS THAT COST A CYCLE EACH. windows-bindgen OMITS A METHOD
whose parameter types are outside the enabled feature set, so
SetFileTypes simply did not exist until Win32_UI_Shell_Common was added
— and the error names the method, never the feature. And Windows'
temp_dir() ends in a separator, so an expander that trimmed only '/'
produced "…\Temp\/kaya-picked-N": SHCreateItemFromParsingName rejects
that outright while POSIX shrugs at "//", which is why neither Unix lane
ever noticed. The scene keeps writing POSIX separators, as one file
serving five platforms must, and the expander normalizes.

And the press needs a BOUNDED RETRY. The dialog becomes interactive
slightly after its list populates, so a single BM_CLICK is swallowed
with no error anywhere and the leg fails three steps later on an
assertion about the guest. The observable is the dialog GOING AWAY, so
that is what choose_file waits for rather than any return code — it
passed once and flaked on the next run before this.

## Android's picker is another app, and the service that reaches it

Every other platform's file picker is reachable from inside the process:
GTK's chooser is our own widget, the Shell's dialog is COM in our
address space, and NSOpenPanel is XPC but still our application as far
as the accessibility API is concerned. Android's is not — ACTION_OPEN_
DOCUMENT hands off to DocumentsUI, a separate APK, and the platform
deliberately stops one app from reading or touching another's UI.

UI Automator crosses that line but is INSTRUMENTATION: it runs under
AndroidJUnitRunner, while this lane launches the app with `am start` and
reads verdicts from logcat. An accessibility service crosses the same
line without restructuring the lane — it sees every window on the device
and can act on them, which is what a screen reader does. It is declared
ONLY by the validation apps, never by the kaya library, so no user's app
carries an accessibility service it did not ask for, and the runner
enables it over adb.

THE ORDER IS THE WHOLE TRICK, and getting it wrong cost two runs.
`am force-stop` kills every component of the package — including this
service, because the validation app is what declares it — and
`logcat -c` wipes the connection message that proves it came up. Enable
first and the service is killed and its one piece of evidence erased,
which reads exactly like a service that never started. Disable and retire
the previous service before install; enable the fresh one after the
post-install force-stop and log clear.

And writing the setting is not the same as the system binding the
service. An unbound service fails exactly like a picker that never
appeared: the scene sees no windows and reports a missing dialog, three
removes from the cause. `dumpsys accessibility` is the only place that
distinguishes them, so the runner asks it there — with a BOUNDED WAIT,
because binding is asynchronous and sampling once reports every leg as
broken. Negative-tested by pointing the setting at a class that does not
exist: all 45 legs say "never bound" instead of failing later and
elsewhere.

## An ordering constraint nothing enforces is a comment waiting to rot

The Android per-leg setup is five adb calls, and every one of them has a
reason to be exactly where it is. Enabling the accessibility service
before `am force-stop` kills it, because the validation app is what
declares the service. Enabling it before `logcat -c` erases its
connection message. Between them those two produced a service that was
configured, dead, and undetectable — which reads exactly like a service
that never started, and sent the search to the far end of the pipeline.

What makes this class nasty is that nothing looks wrong at the call
site. Each line is a plausible adb command in a plausible place, the
lane stays green because the legs that do not need the service do not
care, and the failure surfaces later and elsewhere. A comment saying
"this must come after the force-stop" is exactly the kind of thing a
future edit steps over without reading.

So tools/lib/android-leg-order.py states the order as a rule with its
reasons attached, and check-steps runs it. Move the enable back above
the force-stop and the gate names the step, the step it must follow, and
why — negative-tested that way. It reads the shell rather than running
it, so it cannot see an order produced dynamically; that is the honest
limit, and it still catches the thing that actually happened.

The general shape is worth reaching for: when a sequence's correctness
lives in the ADJACENCY of its steps rather than in any one of them,
write the adjacency down somewhere executable. Every gate in this repo
that pays for itself has that shape — check-stubs pairs a runner's legs
against a backend's stub, paired-cfg pairs a unix item against a windows
one, and this pairs a step against the step it must follow.

## Package replacement can resurrect a service after force-stop

`adb install -r` restarts an accessibility service whose component is
still enabled, asynchronously. The old Android order installed and then
force-stopped. In the 2026-08-23 save-compose failure, force-stop returned
before that restart: the service process began at 19:48:43.456 and bound
at .536, then AccessibilityManagerService timed out adding both the app
window (id 103) and the focused, rendered picker (id 105). `getWindows()`
stayed empty and the harness truthfully printed `KAYA_DIALOG_UNSEEN` with
zero windows. A working Go trace killed the replacement-started process
and bound a new one; its picker was readable.

Disarm is therefore a PRE-INSTALL operation: clear the enabled component,
disable accessibility, force-stop its package, and wait until the service
is unbound and the process is gone. After install, the existing
force-stop/log-clear/enable order still applies. Bound is not enough
either: the service publishes `KAYA_A11Y_WINDOWS: READY` only after a
readable current window exists, and the runner will not launch a scene
before seeing it. One spelling that looks like a clear is not one:
`settings put secure enabled_accessibility_services ""` prints `Bad
arguments` and retains the old component. The first positive run made the
new disarm wall print that value through every JVM leg; the runner uses
`settings delete` now. tools/lib/android-leg-order.py holds all three
boundaries.

That wall is for PACKAGE REPLACEMENT, not every scene. The first
contended matrix with the wall armed the service before all 112 legs and
took 415s against the 310s ceiling; 220s of the standalone-to-matrix
growth sat in the three leg phases, with cached builds. Interrupted-run
state is now removed by one startup `a11y_hygiene` census across every
phone and the tablet. Only `filedialog`, `save` and `editor` leave the app
for DocumentsUI, so only those scenes retain the guarded pre-install
disarm, READY admission and post-leg disarm; ordinary legs perform no
settings query. The shared scripts are the source of that set:
tools/lib/android-leg-order.py derives it from the picker verbs, so a
fourth scene cannot silently launch without eyes. The post-admission
standalone run passed all 112 legs with Compose/JVM/Go at 52/32/34s.

## What DocumentsUI publishes, and the directory it cannot reach

The Compose picker arm was measured before it was written
(tools/android/pickerprobe, a throwaway app with its own copy of the
accessibility service). Four assumptions did not survive.

**The picker's package has two spellings.** AOSP images carry
`com.android.documentsui`; the google_apis images run-emulator creates
carry `com.google.android.documentsui`. The constant landed with the
AOSP one alone, which names a package that is not on the device the lane
runs. Both are in the list now, and a read that finds neither reports
which packages DO own windows rather than saying the picker is missing.

**The temp directory is the right answer to the wrong question.**
`java.io.tmpdir` and the `TMPDIR` environment variable are the same
string on Android — the app's cache dir — so a Rust guest and the Kotlin
interpreter really do agree on it with no runner involvement, which is
what the scene's premise needs. It is still unusable: DocumentsUI
browses document PROVIDERS, and none of them publishes another app's
private storage. A picker aimed at the cache dir opens on Recent
instead, with no error anywhere. The scene's directory lives under the
shared Documents collection instead, which an app targeting 35 may
create and fill with ordinary file I/O and NO storage permission
(measured with the permission removed from the probe's manifest, since a
probe whose manifest differs from the app's is measuring a different
app).

The same silence swallows a bad aim: `EXTRA_INITIAL_URI` pointed at
`Android/data/...`, which the platform hides, is accepted and lands on
Recent. Nothing reports it. `expect_file_dialog` reading the breadcrumb
back is the only thing that catches it, which is the general lesson —
a picker that opens somewhere else looks exactly like a picker working.

**There is no Open button and no Cancel button.** The click on a row IS
the answer, and with `EXTRA_ALLOW_MULTIPLE` set a single click still
answers through `data.data` with an empty clipData. Dismissal is the
system back gesture, and ONE BACK IS NOT ENOUGH: the first backs walk UP
the directory tree the picker was aimed into, and only the one taken at
the root dismisses — three, from the depth the scene aims at. So it is a
bounded loop whose proof is the picker being gone, never the action's
return value.

**The drive must not run on the main thread.** `getWindows()` is
refreshed on the accessibility service's main looper, which is the app's
own, so a caller that blocks main watches a FROZEN window list and
concludes the picker is still up when it has already gone. The same
cancel loop reported `backs=8 gone=false` on the main thread and
`backs=3 gone=true` off it. The service asserts the thread now rather
than commenting on it, because the symptom is a timeout nobody would
trace back here.

## A changed event is not a changed picker path

The event-handshake cancel gate still admitted a straggler under the
2026-08-23 dynamic-table matrix. Three BACKs at 19:30:29.537,
19:30:30.186 and 19:30:30.639 walked from the scene directory to
Documents, to the storage root, then dismissed PickActivity. Its cancel
result and kaya's onResume landed at 19:30:31.073. A fourth BACK was
already queued at 19:30:31.082; it landed when MainActivity gained focus
and finish()ed it at 19:30:31.238. `KAYA_DISMISS_REMOVED` was absent.

`windowEpoch` was the false witness. Picker closing generates
accessibility events too, so “some event happened” cannot prove the
previous BACK navigated to another directory. The next press is now
earned only by the same picker window publishing a full breadcrumb trail
that is stable on two reads and is a strict prefix of the last path that
earned one. A path is spent before dispatch; unreadable, oscillating and
already-spent states only withhold. A row or Save action marks the whole
presentation as closing so cleanup cannot inject a BACK behind it.

The gate's cancel-path self-test feeds three successively shorter paths,
same-state repeats, old/new oscillation, an unreadable read and a closing
action. With the spent-state and strict-shortening walls both removed,
the real filedialog and save legs were watched crashing at that self-test
instead of passing vacuously.

Two more, from the same session. `openFileDescriptor` in mode `w` does
NOT truncate — the provider maps it to O_WRONLY without O_TRUNC, and
`PathSource` truncates, so the same `FileMode` would have meant two
things on two platforms; Android asks for `wt`, and a unit test that
runs on every platform holds it. And `FindClass` on a thread attached
with AttachCurrentThread resolves through the SYSTEM class loader, which
knows the framework and nothing of the app: the by-name spelling of
`dev/kaya/KayaPresent` works on the Activity's thread and fails on the
guest's — which is precisely the thread hop the filedialog scene exists
to exercise. The class is held as a global reference taken at attach.

## A probe that leaves its dialog up measures the run before it

Three separate ways an Android probe rerun silently reports the previous
run's answer, all met while measuring the picker:

- **The task is still alive.** `am start -n <component>` carries
  FLAG_ACTIVITY_NEW_TASK, and an existing task whose root is that
  component is simply brought forward — onCreate never runs again. Three
  probe variants produced NO output at all and read as clean runs. The
  same shape reaches the lane: a leg that failed with DocumentsUI still
  up leaves it on top of the app's task, and the next leg's `am start`
  brings that task forward instead of starting the activity. run-emulator
  force-stops the picker's package now, which the app's own force-stop
  does not cover — it is a different package.
- **`am start -S` fixes that and breaks something else.** It force-stops
  the package first, and the accessibility service lives in the app's
  process, so `-S` kills the service that `dumpsys` just confirmed bound
  and brings the activity up in a fresh process where `live` is null.
  The probe reported "NO SERVICE" immediately after the bind check
  passed. The lane's order — force-stop, then enable, then start without
  `-S` — is the one that works, which is why it is a rule
  (tools/lib/android-leg-order.py).
- **The scene selector has a fallthrough.** One APK hosts every scene on
  Android and the leg names one through `--es KAYA_SELFTEST`; an
  unrecognized name used to run the milestone-2 scene. The leg launches,
  a scene runs, it draws, and every step fails against labels from a
  scene nobody selected — the verdict named eight unrelated widgets and
  read like a broken interpreter. The guest panics on an unknown name
  now, and check-steps pairs every selector in the runner against an arm
  in the guest so it is a two-second answer rather than an emulator boot.

## A shell toast holds the foreground, and ten legs die of it

The windows lane came back with exactly ten failures — `menus_*` and
`commands_*`, one of each per language — all panicking with "could not
foreground the guest window for shortcut injection after 3s". The other
121 legs passed. Nothing in the tree had touched WinUI, and the lane had
been green the day before.

The cause was a **notification toast**: "Turn off notifications from
OneDrive?", a SUGGESTION the shell raised on its own, sitting on the
desktop. A toast is a foreground window owned by the shell, and while
one is up `SetForegroundWindow` fails for everything else — so every leg
that injects a real keyboard chord cannot raise the guest first. ESC and
the ALT foreground-lock release, which the backend already tries, do not
touch it.

What made this expensive is that it is INVISIBLE FROM THE LANE. `query
session` says the console is Active and unlocked; `Get-Process` over ssh
lists no window titles, because the toast has none. The only thing that
answered was a screenshot of the console session, taken through the same
`schtasks /it` route the legs themselves run under (tools/guest/shot.cmd
— take it through the wrapper, not by hand; the hand-written version is
a trap of its own, two entries down). When a Windows leg fails in a way
that implicates the DESKTOP rather than the app, take the picture first
— it is two minutes and it ends the search.

deploy-win now turns toasts off and verifies it, beside the HideFileExt
write and for the same reason: an OS default that fails a leg looking
exactly like a backend bug, on a per-user registry value any settings
visit can put back. Three values, because the shell has three places to
say it — toasts at all, the notification centre's master switch, and the
"suggestions" channel that raised this one unprompted.

The general shape, worth carrying to any GUI lane: a machine that shows
the user things is a machine that can interrupt the harness, and the
interruption does not look like one from inside the test.

## The iOS picker is another app too, and the eyes have to go on the host

`UIDocumentPickerViewController` is a REMOTE view controller. Measured
2026-07-31 in the simulator, from inside the app: its view subtree is six
empty `UIView`s plus one `DOCRemoteBarButtonTrackingView`, it publishes
ZERO accessibility elements, none of the process's views mentions a file
the picker is plainly showing, and `accessibilityActivate()` on that one
in-process affordance returns false and dismisses nothing. There is no
in-app route to this picker, and iOS has no accessibility service an app
can install the way Android does.

Ordinary macOS `AXUIElement` against `Simulator.app` does not help
either: it exposes the simulator's chrome always and SpringBoard's icons
when a device is the presented one, but never an app's content — with
`ApplicationAccessibilityEnabled` set on the device, with the window
raised and activated, either way. And only one device window is bridged
at a time, so it would force the lane serial even if it worked.

WHAT DOES WORK is the simulator's own frameworks, from the host — the
same private surface `simctl` talks to, shipped inside Xcode.
tools/ios/simdrive owns it: read through
`-[SimDevice sendAccessibilityRequestAsync:completionQueue:completionHandler:]`
with an `AXPTranslator` bridge delegate, drive through
`SimulatorKit.SimDeviceLegacyHIDClient` with an Indigo digitizer message.
Both proved end to end: the picker's rows read out of DocumentsUI's own
process, and a tap composed on macOS landed on a row so that the app's
delegate fired with `["picked.txt"]`.

Five things on that path look exactly like failure and are not:

1. **`frontmostApplication` returns THE APP**, whose `AXChildren` are
   empty — the picker is a different process sitting on top of it. The
   app is not the thing to read. Hit-test a point to learn the picker's
   pid, then `translationApplicationObjectForPid:`.
2. **Translated elements expose no `AXParent`**, so a hit test cannot be
   climbed out of. Entering by pid is the only way in.
3. **`AXPMacPlatformElement` is a LEGACY element.** It answers
   `-accessibilityAttributeValue:`; the modern `accessibilityLabel` /
   `accessibilityChildren` properties return nothing and read as an
   empty tree. This one cost a round on its own.
4. **The bridge delegate must go on EVERY `AXPTranslator` singleton.**
   With it on one, the first fetch succeeds and every attribute read
   afterwards silently returns nothing — the worst possible shape, since
   the thing that proves the transport works is the thing that then
   stops working.
5. **The picker's element tree is SHALLOW**: file rows and the tab bar,
   and nothing else. The navigation strip that carries the directory
   name and the Cancel button is not a child of anything reachable, but
   it answers a hit test perfectly well. simdrive sweeps that strip
   rather than walking it.

And one that is not a failure: `AXPress` IS advertised on a row and does
nothing. Only the HID tap actually picks.

Finally, a naming trap with a Windows twin. The row's accessibility
description omits the extension — "picked, Text file, 12 bytes" — while
the URL the picker finally answers with carries it in full,
"picked.txt". Windows had the same divergence and could be fixed with a
setting (`HideFileExt`); this is the accessibility label itself, so
simdrive matches rows on the STEM. The scene still proves the right file
was chosen, because it reads the file's BYTES and the decoy's differ —
which is exactly why the decoy carries different contents rather than
just a different name.

## Three ways the iOS picker is not the picker you measured

The host-side driver worked on the first app it was pointed at and then
failed on the real leg, three times over, each for a different reason.
All three share a shape worth naming: a picker measured in ONE
configuration is not the picker the scene drives.

**An unretired accessibility token stops the taps, not the reads.**
Every response from `sendAccessibilityRequestAsync:` has to be handed
back through `_resetBridgeTokensForResponse:bridgeDelegateToken:`.
Forget it and nothing looks wrong: the reads keep working, run after
run, and the next TAP is silently ignored. Measured exactly that way —
a tap with no reads before it lands, and the same tap after a tree walk
does not, so the bug hides behind the very call that proves the
transport works. idb pops each request's token for this reason; simdrive
now does it in the bridge callback, where it cannot be forgotten per
call site.

**Multi-selection is a different interaction.** With
`allowsMultipleSelection` false the tap IS the answer and the picker
leaves. With it true — which is what `pick_files()` asks for, and the
scene's first pick — the tap SELECTS, a Select All / Deselect All bar
appears at the foot, and an `Open` button replaces `Cancel` in the
navigation strip. So the drive taps the row, and if the picker is still
up, presses the confirm. Which is the desktops' shape all along; iOS
single-selection is the odd one out, and measuring only that taught the
wrong lesson.

**The Cancel button is not always there.** A picker aimed into a
subdirectory shows a BACK chevron where Cancel would be, and only the
provider's root carries Cancel — while a multi-selection picker carries
it throughout. The scene cancels its SECOND picker, which is
single-selection and aimed, so it meets the case with no Cancel at all.
simdrive walks back until the dismissal exists and then presses it, the
way a person would. The back control is identified BY POSITION, as the
leftmost thing in the strip: its accessibility label is the presenting
app's name, so keying on a word would have bound the driver to whichever
bundle was under test.

A fourth, smaller: an early reading claimed a single-selection picker
DID have Cancel. It came from a hit test landing on the app's own
`DOCRemoteBarButtonTrackingView`, which is in the HOST app's process and
carries that label while the picker's chrome does not. Hit tests answer
with whatever owns the point, across processes — so an element found
that way is only evidence about the picker if its pid says so.

## The first picker a device shows after a boot ignores where you aimed it

The iOS lane's `filedialog-swiftui` leg failed five times running and
passed on the sixth, and the two states it was A/B'd against —
Simulator.app running or quit — turned out to be the wrong axis
entirely.

**What actually fails.** `UIDocumentPickerViewController.directoryURL`
is honoured by com.apple.DocumentManager.Service as a REVEAL that races
the service's own "which location does this picker open at" strategy.
Both are in its log, and the loser is whichever lands first:

    Will reveal location <kaya-picked-26596> (from root, animated: NO)
    Attempt to reset locations, while a reset is already in progress
    2.2.2 Will use getSaveLocation's suggested location <filedialogrs-swiftui>

Measured on this machine, 2026-08-03, ten leg runs across three devices
— five on a device whose first picker this was, all five at the root;
five after one, all five where they were aimed:

| device state | getSaveLocation | reveal arrives | picker opens at |
| --- | --- | --- | --- |
| first picker after boot | 708ms | 381ms | the container ROOT |
| every picker after that | 160ms | 297ms | the asked-for directory |

The reveal lands ~300-450ms after the service starts resolving, so a
resolution slower than that overwrites it. The first resolution on a
boot is slow because the LocalStorage file provider populates its tree
lazily; Apple's forums carry the symptom ("since iOS 18 directoryURL
opens the root instead", no official explanation) and one relevant
remark, that some providers populate lazily and the folder is not
guaranteed to be there the first time you ask.

**What it looks like from the lane**, which is why it cost a session:
the picker IS up, IS accessible, and lists real rows — the app's
Documents directory. `expect_file_dialog` fails on the directory,
`file_choose picked.txt` then refuses a row that is genuinely not in
that list, the guest's result handler never runs, and the scene's SECOND
`pick_file` trips the one-per-process dialog guard
(crates/kaya/src/capi.rs) whose abort took the harness's failure list
with it. The visible remains were a panic and a timeout. The fix for
that half is one line in the interpreter's step wrapper: a step's final
failure text is printed as `KAYA_HARNESS: step-failed ...` the moment it
becomes final, so it survives an abort — plus `KAYA_PICKER_TRACE` lines
for present/didPick/cancelled/emitted, the picker being the one piece of
UI in that backend nobody in the process can see.

**Simulator.app is not the axis.** It looked decisive because quitting
it SHUTS DOWN every device it shows, so each "headless" trial was a cold
boot while each "with the app" trial ran on a device that had already
shown a picker. Measured directly: a cold-booted device fails the same
way with Simulator.app running, and a warm one passes with it quit. The
lane needs no renderer — HID taps land, the picker is readable, and
`simctl io screenshot` (which forces composition) changes nothing.

**No app-side fix exists.** Setting `directoryURL` again after
presentation is inert — four re-assertions at 0.8/1.6/2.4/3.2s produced
no second reveal and the picker never moved. The property is read when
the remote view controller is configured and never again.

**So the runner owns the aim**: after the exact prior-run cleanup below,
`picker_warm` in tools/ios/run-sim.sh launches the system's own Files app
on each pool phone before any leg
(same DocumentManager, same file provider), waits for
`com.apple.FileProvider` to carry a pid — it carries none until
something on that boot has used the document stack, which is exactly the
cold/warm edge — settles, and terminates it. 5.2s on a cold device,
0.23s on a warm one. The export-health trap below is a distinct state of
the same provider; tools/check-steps.sh holds both walls on the
per-device preparation path.

## A live iOS FileProvider can have a stale LocalStorage item index

A dynamic-table matrix ran 105 of 106 iOS legs green; `save-swiftui`
delivered one HID tap to DocumentManager's real Save AXButton, observed
the sheet leave with no accessibility timeout, then received
`documentPickerWasCancelled`. The device log supplied the missing cause:
LocalStorage failed `did=8079` with FP -1005, "The file doesn't exist";
DocumentManager could not tag the item, declared its index out of sync
and forced a reindex, then called `didPickDocumentURLs` with an empty
array because the export could not be prepared and materialized. UIKit
maps that empty result to the public cancellation delegate. A passing
sibling instead acquired a file-coordination claim on its final
destination and returned that URL.

This is not a presentation/dismissal race. On the failed device the old
picker scene was invalidated 57ms before the next remote controller was
ready; a passing sibling had the new controller ready 15ms before the
old scene finished invalidating. Deferring the callback or retrying
`documentPickerWasCancelled` would therefore target the wrong state,
and the public callback cannot distinguish failed materialization from
a person's real Cancel.

A later `editor-go` leg reproduced the same failure after its clean
preflight passed: one real Save tap dismissed the sheet in 820ms, then
LocalStorage emitted FP -1005/out-of-sync/empty URLs. The failing phone
held 101 installed `dev.kaya.*` apps; editor-go's container alone held 58
old editor directories, and 12 retained data containers held 503 Kaya
scratch directories. `simctl install` preserves app data, while the
probe's fresh container had tested only itself.

Preparation now parses `simctl listapps` through `plutil`, accepts only
the exact `dev.kaya.` prefix, uninstalls that finite list through official
`simctl uninstall` and requires a second empty census before warm/probe.
A live negative removed 100 apps while deliberately retaining
`dev.kaya.editorgo`; the postcondition named it, and restoration removed
the last app. The runner then exports a unique known-byte file through a
real `UIDocumentPickerViewController`, drives and reads back its name,
requires a nonempty URL and reopens the destination byte for byte. Empty
cancellation or a contemporaneous FP -1005/out-of-sync log re-seeds only
that simulator, warms it and runs the export once more; anything else, or
a second health failure, refuses before a leg. The probe attests the
provider route and its own clean container; cleanup makes prior guest
containers unable to poison the run. tools/check-steps.sh holds the exact
cleanup scope/emitter/postcondition, bounded destructive surface,
per-phone call, two attempts, one-device erase, recording/clipboard
ordering and probe semantics; its real-source perturbations are watched
red.

## A freshness check by mtime, against a build system that hashes

The linux lane went red on a run where every leg passed, twice in a row,
reporting `guest build FAILED: ocaml` above the words `stale ocaml
artifact ...; forcing a full rebuild`. The forced rebuild ran, did
nothing, and the check failed anyway.

The check compared each built exe's MTIME against the newest binding
source's. Dune keys targets on source HASHES. Those two rules disagree
in one direction that matters: a source rewritten with IDENTICAL BYTES —
which is what `tools/gen-bindings.sh` does to every generated file on
every run — moves the mtime and not the hash. Dune correctly rebuilds
nothing, the exe keeps its old timestamp, and the check declares it
stale forever. Measured 2026-07-31: `bindings/ocaml/kaya_wire.ml`
byte-identical to `HEAD`, exes two days older, lane red on both runs.

A guard that cannot be satisfied is as broken as one that cannot fail,
and worse in one respect: it trains the reader to skip a red lane. The
check now stamps the sources' CONTENT into the build dir and compares
that, which is what dune itself tracks — so it fires when the sources
really moved and stays quiet when only a timestamp did. The leg-time
per-guest spec-hash guard remains the backstop for a link that really is
stale.

The general shape: when a check and the tool it polices disagree about
what "changed" means, the check is the one that is wrong. Ask what the
build system keys on, and key on the same thing.

## A restored copy keeps its OLD mtime, so the PERTURBED artifact
## survives the restore

The ritual for a watched negative — perturb a file, see the guard go
red, put the file back — is five steps and git is in none of them:
(1) `cp` the file to the scratchpad and record `shasum -a 256`;
(2) perturb, PRINTING the substitution count, because an unchanged file
is a failed test and not a passed one; (3) watch the guard fail;
(4) `cp` the backup over the file; (5) `shasum -a 256 -c` the recorded
sum. `git checkout -- <file>` is not step 4 and never is: it restores
HEAD, and on a mid-slice tree that erases whatever uncommitted work the
file was carrying. Measured 2026-08-16, when it took out an entire
uncommitted fan-out that could only be recovered by replaying an agent's
Edit calls out of a transcript.

THE HALF THAT ONLY BITES WHEN SOMETHING GETS BUILT, measured 2026-08-18
by the GTK identity arm. `shutil.copy2` and `cp -p` preserve the saved
copy's METADATA, mtime included — and that mtime predates the build made
from the perturbation. So after the restore the source is byte-correct
and OLDER than the artifact compiled from the doctored bytes, cargo
calls the tree up to date, builds nothing, and the next run executes the
PERTURBED artifact. Every hash checked in step 5 passes. The negative
after it then measures a binary nobody asked for, in either direction:
a guard can appear broken because the fix never got compiled, or appear
fine because the perturbation is still live.

What caught it was the stale-artifact guard, doing exactly its job:

    libkaya.so: STALE — carries 00f372a973117341,
      but core in this tree is 5f34bf2e3fa43428

So the ritual gains a sixth step: after copying the backup back, TOUCH
the file (or copy without metadata), rebuild, and `tools/build-id.sh
--verify` the artifact. The source hash is not the thing the next run
executes.

The neighbour above is the same disagreement seen from the other side.
There a check keyed on mtime while dune keyed on hashes, and the CHECK
was the liar; here cargo's mtime key is right and the RESTORE lied to
it. Both come out of one question worth asking whenever a file is put
back by hand: what does the build key on, and did the restore move it?

## Two file dialogs on one desktop take each other down

The windows lane's `filedialog_rust` leg had been green for weeks. It
started failing the moment a `filedialog_python` leg joined it — and the
python leg failed too, so the evidence pointed at the newly added
language rather than at the pair. Watching the VM is what settled it:
BOTH dialogs were on screen at once, one showing the scene's two files
and the other showing a directory full of folders.

A file dialog needs the desktop to itself. It is modal, it must hold the
FOREGROUND to be driven, and the harness finds it by searching for a
dialog window. Two of them up together means one is in the background
with its presses swallowed, and the leg then fails three steps later on
an assertion about the GUEST — which is where nobody looks for a
scheduling problem.

That is the same ruling the menus legs already carry for OS-global
shortcut injection, so check-steps' barrier gate now covers both
families rather than one: every `run_suite menus_*` and `run_suite
filedialog_*` must have `drain_suites` as its nearest significant
neighbour on both sides. Negative-tested in both directions.

THE SECOND DIALOG WAS A SECOND BUG, found only because the first was
being looked at. The python guest computed its scene directory from
`os.environ["TMPDIR"]`, which is a POSIX spelling with no Windows
equivalent — so it fell back to a literal "/tmp", wrote its files to the
root of the current drive, and the picker opened on the real temp
directory with none of them in it. `tempfile.gettempdir()` is Python's
own answer and matches what the interpreter computes. The scene's
premise is that both halves agree WITHOUT runner involvement, and that
only holds if each computes the directory the way its own language does
— an environment variable read directly is a guess about the platform,
not a computation.

## A generator edited and never rerun compiles perfectly

Twice in one afternoon, adding the picker's decoder arm to a binding
generator and then testing the guest without regenerating: the OCaml
picker reported every result as cancel, then the Haskell one did. Both
looked like a decode bug in the new arm. Neither had the arm at all —
`bindings/*/kaya_wire.*` still held the previous generation, and nothing
says so, because stale generated code COMPILES. The guest builds, the
scene runs, the dialog opens, and the answer is silently empty.

`tools/gen-bindings.sh --check` is the authoritative detector and every
lane runs it. That is one run too late for someone iterating by hand,
and a gate you have to remember is not a guard.

So the BUILD refuses. `crates/kaya/build.rs` stamps and compares a hash
of `tools/kaya-bindgen/src/*.rs` against `bindings/.generator-id`, which
`gen-bindings.sh` writes on a real generation. Everything downstream
compiles this crate first, so the refusal is the earliest possible
answer and the one nobody can skip: `cargo build` fails naming the fix.

TWO EXEMPTIONS, both necessary rather than convenient. A published
dependency has no `tools/` and nothing to be out of date with. And
`gen-bindings.sh` sets `KAYA_REGENERATING`, because the generator
DEPENDS on the kaya crate — without it a generator edit would deadlock,
the build of the tool that fixes the staleness being the thing the
staleness stops. Negative-tested in all three directions: a moved
generator fails the build, `gen-bindings.sh` still runs while it is
failing, and the build passes again once it has.

Content, not timestamps, on both sides — the shell hashes the sorted
glob and build.rs hashes the sorted read, for the reason the neighbouring
mtime-versus-hash entry gives.

## Two languages disagree with everyone else about where "temp" is

The filedialog scene's premise is that the guest and the interpreter
land on the same directory WITHOUT runner involvement — each computes it
the way its own language does, and they agree because every language
agrees. Two do not.

`std::env::temp_dir` (Rust, which is what the interpreter uses),
`tempfile.gettempdir()`, `os.TempDir()`, `Path.GetTempPath()`,
`Filename.get_temp_dir_name` and `getTemporaryDirectory` all honour the
TMPDIR environment variable. **Java's `java.io.tmpdir` and Swift's
`NSTemporaryDirectory()` do not** — on macOS both answer with the
per-user Darwin temp directory and ignore TMPDIR entirely. Inside the
nix dev shell, which sets TMPDIR, that puts the guest's files somewhere
the picker was never aimed. Both guests therefore read TMPDIR first and
fall back to the platform answer, which is also correct on Windows,
where there is no TMPDIR and `java.io.tmpdir` is right.

A third variant of the same bug, from the Python port: reading
`os.environ["TMPDIR"]` DIRECTLY is not a computation, it is a guess
about the platform — there is no TMPDIR on Windows, so it fell back to a
literal "/tmp" and wrote to the root of the current drive.

The rule that survives all three: ask the language for its temp
directory, and consult TMPDIR only to correct a language that is known
to ignore it. Every one of these was caught on the first run by
`file_dialog_goto`'s "does not exist" refusal rather than by a confusing
comparison three steps later, which is the whole reason that guard
checks the directory before aiming at it.

  SINCE 2026-08-17 the doctrine covers the other half too: a GUEST asks KAYA for platform locations (kaya.Env and siblings), never the language runtime's snapshot — embedded runtimes carry a dead environment copy (measured on Android), so the language's own answer is exactly the one that breaks on phones. check-go-env now catches os.TempDir alongside os.Getenv; the rule is stated in DESIGN.md's settled rules.

## UI Automation cannot read the Shell's file dialog from a guest

Measured 2026-07-31, after it cost most of a milestone.

The Windows harness used to read the file dialog over UI Automation.
Under a JVM that killed the run outright — `Internal Error (0x8001010d)`,
`RPC_E_CANTCALLOUT_ININPUTSYNCCALL` — while the same scene passed in
Rust, Python, Go and C#. It reads exactly like a Java binding defect and
is nothing of the kind.

WHAT IS ACTUALLY HAPPENING, from the stack a vectored exception handler
captured in the guest: USER32 dispatches a message, the shell's DirectUI
(DUI70) handles it, and while handling it `uiautomationcore` raises an
automation event to whatever client has attached. That notification is
an outgoing COM call, and Windows refuses one from a thread that is
dispatching an input-synchronous call, raising a structured exception
flagged NONCONTINUABLE. COM catches it and carries on.

So it is NORMAL, HANDLED, FIRST-CHANCE control flow. The identical
exception — same code, same address — fires in the Rust guest on every
green run. What differs is the runtime: HotSpot installs a vectored
exception handler on 64-bit Windows, sees the same first-chance event,
and reports a fatal error.

THREE CONSEQUENCES WORTH KEEPING:

- The fault is on the PROVIDER side, inside the guest. Moving the UIA
  CLIENT to another process cannot help, and a helper was built,
  measured and thrown away proving it. Where the client lives is
  irrelevant.
- NONCONTINUABLE means no exception handler may dismiss it. There is no
  workaround on the calling side at all.
- Four runtimes swallowing an exception is not four runtimes being
  fine. It was racing undetected in all of them.

The dialog is created in the app's own process, so the shell will simply
say what its view holds: `IServiceProvider` -> `SID_STopLevelBrowser` ->
`IShellBrowser` -> `QueryActiveShellView` -> `IFolderView` -> `Items`.
No client attaches, no `WM_GETOBJECT` is sent, nothing is raised. It is
also four times faster than the UIA walk it replaced.

THE GUARD IS THE ABSENT CARGO FEATURE: `crates/kaya/Cargo.toml` does not
enable `Win32_UI_Accessibility`, so reaching for `IUIAutomation` fails
`cargo build` with the reason written beside it, rather than dying as an
unexplained JVM crash on one lane months later.

## A rebooted Windows VM refuses every shortcut-injection leg

Measured 2026-07-31. Ten legs — menus and commands, all five languages
— failed reproducibly with "could not foreground the guest window for
shortcut injection", alone and concurrent, on a commit that had passed
three times earlier the same evening. Nothing in kaya had changed; the
VM had been rebooted in between.

WHY. Windows denies SetForegroundWindow to a process that did not
receive the last input event, and makes everyone else wait
ForegroundLockTimeout — 200000 ms by default. Shortcut injection needs
the guest window foregrounded, so with the default value those legs
only ever passed because the session had incidentally accumulated input
from earlier runs. A long-lived VM hides this completely. A fresh boot
removes it, and every one of those legs fails at once.

TWO THINGS THAT LOOK LIKE FIXES AND ARE NOT. Synthesizing input from a
helper does nothing: the foreground right is granted to the process
that RECEIVED the input, which is the helper, not the guest. And the
assert's own wording sent the search the wrong way — it names an active
Start menu as "the usual cause", which was true of the 2026-07-25
incident but not of this one, so a screenshot showing an idle desktop
read as ruling nothing out.

THE FIX IS A SETTING THE DEPLOY OWNS. tools/deploy-win.sh writes
ForegroundLockTimeout=0 and VERIFIES it — the third setting in that file
to exist because the desktop can quietly refuse a window the foreground,
after HideFileExt and toasts. Any settings visit, or any reboot, can put
it back. (The half of that fix which applied the value to the LIVE
session used to be a `SystemParametersInfo` call made over ssh, and
could never have worked; it moved into the desktop warm-up on
2026-08-04, for the reason the next entry gives.)

THE LESSON FOR NEXT TIME, since two of the night's dead ends were the
same shape: when a lane goes red after an environment event and the
same commit was green before it, bisect against the ENVIRONMENT first
(stash the changes and re-run the old commit) rather than reading the
diff. Both answers came in one command.

## Whether the desktop will hand over the foreground is invisible from ssh

2026-08-04, the same failure one boot later. After the VM was restarted,
every chord-injecting leg — `menus_*` and `commands_*`, ten of them —
died 6-8s in with kaya's own guard text, while the other 135 legs passed,
the clipboard suites among them: nothing else on this lane needs the
foreground. A reboot cleared it and the lane ran 145/145. Both halves of
that, the diagnosis and the remedy, lived in a human's head.

WHAT ACTUALLY REFUSES, measured that day on the VM through
`schtasks /it` — a bare `SetForegroundWindow` poll beside a real
`menus_rust` run, one leg per row:

| desktop state | bare SetForegroundWindow | menus_rust |
| --- | --- | --- |
| idle (Progman or the taskbar in front) | won on the first try | PASS |
| Start menu open (SearchHost's CoreWindow) | LOST, 150 tries, 5.5s | PASS |
| another process holds the foreground lock | LOST, 150 tries | PASS |
| an ordinary window in front (Notepad) | won in 5ms | — |
| **input desktop is not the legs' desktop** | **LOST, 150 tries** | **FAIL** |

The two middle rows are the ones the guard's message names, and it
BEATS BOTH on its own: the ESC it taps at 200ms dismisses the menu (the
next `SetForegroundWindow` then wins in 49ms), and the bare ALT at 1s
releases a held foreground lock, which is the documented way out of
`LockSetForegroundWindow` — the mechanism the Start menu and toasts use.
So "a Start menu left open on the VM", which the assert calls the usual
cause, is measurably a cause the backend already survives.

THE ROW THAT KILLS LEGS is the last one, and it kills them because no
key can reach it. When the console session is locked the input goes to
`WinSta0\Winlogon`; when a UAC prompt is up it goes to the secure
desktop. The legs' windows stay on `WinSta0\Default`, so ESC and ALT are
injected into a desktop nobody is looking at, `SetForegroundWindow` can
never be satisfied, and every chord leg dies at 3s. Everything that does
not need the foreground keeps passing, which is exactly the shape the
lane reported.

NONE OF IT IS VISIBLE FROM SSH, and that is the trap. An ssh session
gets its OWN window station — `query session` marks it `>services`,
session 0 — so it can see neither the input desktop nor a toast, which
has no title to list. Two consequences, both of which cost real time:
the lane could not tell a sick desktop from a WinUI bug, and the
`SystemParametersInfo` call the deploy made over ssh to clear the
foreground lock in the "live session" cleared it in session 0 and
nowhere else. Measured: the console session still read
`ForegroundLockTimeout = 2147483647` after every deploy that day, while
the registry check beside it passed on the 0 it had just written.

THE GUARD IS NOW THE LEGS' OWN QUESTION, ASKED ONCE. tools/deploy-win.sh
runs a desktop warm-up before the suites (`desk_warm`, with
tools/guest/desk-warm.ps1 doing the work inside an interactive scheduled
task): it names the input desktop, applies the foreground-lock setting
where it actually lands, and then PROVES the handover by creating a
window and taking the foreground with the guard's own sequence — 3s,
ESC at 200ms, ALT at 1s. Winning clears the desktop as a side effect and
prints what it had to get past; losing stops the lane in ~3s with the
holder's window class, title and process, and the remedy for that
holder. A Start menu costs it 8 tries and 641ms and the lane goes on.

Two things worth keeping from how it was built. The proof is bounded by
the CLOCK, not by a try count: PowerShell's loop costs ~120ms a turn
against the guard's 20ms, so counting to 150 would have waited 18s and
passed a desktop that hands over far too slowly for any leg. And the
negative test was watched twice — the fixture (a temporary desktop with
`SwitchDesktop`, which stands in for Winlogon because it can be switched
back without credentials) made `menus_rust` FAIL with the real guard
text, and the warm-up then refused the same lane invocation before any
leg ran. A Ctrl+Esc fixture toggled a Start menu SHUT once instead of
open, which would have been a vacuous pass; the fixture check now reads
the foreground window back and aborts if it does not name the intruder.

AND THE PHOTOGRAPH ROUTE ITSELF WAS BROKEN, which is worth its own
sentence because the entry above prescribes it. `schtasks /tr "powershell
-File C:\kaya\shot.ps1"` exits 1 without ever running the script —
PowerShell needs `-ExecutionPolicy Bypass` for a shipped .ps1 — and
since shot.ps1 only writes its output on success, what you find
afterwards is the PREVIOUS run's shot.png, with an old timestamp nobody
checks. tools/guest/shot.cmd is now the route: right policy, hidden
console (a visible one would take the foreground it is photographing),
and it deletes the old picture first so a failure cannot look like a
fresh one.

## Headless Weston has no seat, so it has no clipboard

Measured 2026-08-01 by tools/linux/clipprobe, before the clipboard arm
was written.

The linux lane started `weston --backend=headless` then. That compositor
advertises `wl_data_device_manager` but no `wl_seat`, and a data device
is obtained FROM A SEAT. No seat, no data device, no clipboard — for
any client, including kaya's own GTK apps. It is not a harness
limitation and not something a flag fixes: Weston registers no seat for
the headless backend deliberately.

WHY THIS WENT UNNOTICED FOR SO LONG: nothing before the clipboard
needed a seat. kaya's harness clicks by driving the toolkit, not by
injecting input events, so the wayland legs never wanted keyboard or
pointer input and never noticed there was none to want.

SECOND FINDING FROM THE SAME PROBE: on Weston, wl-clipboard works
WITHOUT the wlr-data-control protocol (which Weston does not implement)
by creating its own surface and TAKING FOCUS. So an out-of-process
clipboard read there is not passive, and any leg that does one while
another leg holds focus is asking for trouble.

THE FIX THAT SHIPPED, 2026-08-02 (f8448ae): the lane runs HEADLESS SWAY,
not a nested Weston, and the second finding is why. A wlroots compositor
speaks data-control, so a privileged client reads the selection with no
surface and no focus — which is what lets the clipboard legs stay in the
parallel pool. The nested Weston on `--backend=x11` inside the lane's
Xvfb also has a seat and would have served the first finding alone; it
is still what tools/linux/record-leg.sh uses for recording. Two things
the swap costs, both in tools/linux/run-suites.sh: sway tiles by
default, so every window must be floated by app_id or `expect_window_size`
reads the output's size instead of the asked-for one, and the socket
name is sway's to choose rather than declared, so it is discovered after
start. The lane checks for THE SEAT rather than the compositor's name,
so the next swap meets that line instead of a mystery.

## Android hands an unfocused reader an empty clipboard, silently

Measured 2026-08-02 by tools/android/clipprobe on API 35.

Android 10+ gives `ClipboardManager.getPrimaryClip()` nothing unless the
caller has window focus or is the default IME. It does not throw and it
does not log: it returns null, which is indistinguishable from an empty
clipboard.

THE PART THAT WILL CATCH SOMEONE: the window does not have focus at
`onCreate`. An app that reads the clipboard while starting up gets null
even though it is the app the user just launched. Measured, in order:

    read at onCreate (focus=false) -> null
    window has focus: true              (2.5 seconds later)
    read (focused)  -> kaya-own-content (1ms)
    read (focus=false, another app in front) -> null

The host cannot help either. There is no `cmd clipboard`; the service is
only reachable through `service call clipboard <n>` with a transaction
number that shifts per API level (a guess on API 35 mis-parsed its own
arguments into a 7MB allocation); and the shell is never the focused
app, so even a correct number would read nothing.

SECOND FINDING FROM THE SAME PROBE: copying pops a SYSTEM OVERLAY on
API 33+ — a floating preview of the copied text with dismiss and share
buttons — over the top of the app for several seconds. It steals
neither focus nor the read, but it is on screen and in the
accessibility tree while a scene is asserting, and it lands in recording
mode's video. A leg that fails oddly right after a copy should suspect
it before suspecting kaya.

## A menus flake that survived 86 attempts to reproduce it

Seen once, 2026-08-02, on `menus-java-wayland` inside a full parallel
lane:

    kaya: no such menu item "Remove"

That message is the BAR route. It means the open-context claim was None
when the harness activated a CONTEXT item, so resolution fell through to
the menu bar, where "Remove" does not exist.

NOT REPRODUCED, and the numbers are worth knowing before anyone spends
the afternoon again: six full linux lane runs, six full windows lane
runs, fifty-three runs of the leg on its own, twenty runs of the whole
menus family under 8-wide contention. Eighty-six samples, zero
failures. It only ever appeared inside a complete 412-leg lane, so the
window is opened by contention the leg cannot create for itself — which
also means REDUCING PARALLELISM WOULD HIDE IT RATHER THAN FIX IT.

TWO MECHANISMS PROPOSED AND DISPROVED. Recorded because eliminating them
is the only durable thing that came out of the hunt:

- **The claim is set late.** It is not: `context_open` writes
  `open_context` synchronously inside its own main-thread closure,
  before `popup()`, so a following `menu_activate` on the same queue
  cannot see None for that reason.
- **The preceding Rename's re-render destroys the anchor and releases
  the claim.** Tested by DELETING the scene's intervening
  `expect label#0 "renamed"`, which should have made that race
  near-certain by removing the partial synchronisation. It still passed.

Both clear-paths carry equality guards that read correctly
(`connect_closed` and `ApplyOp::Destroy` each clear only when the claim
is their own anchor).

SOLVED 2026-08-02, BY THE TRAIL, ON ITS FIRST FIRING. Two legs failed
in the next matrix and both printed the same thing:

        -   388ms  harness context_open -> claimed by widget 6
        -   185ms  context item activated -> cleared
        -    89ms  harness context_open -> claimed by widget 9223372036854775811
        -     0ms  popover closed (chrome dismissal) -> cleared

The clearer is the POPOVER'S OWN `closed` HANDLER, 0ms before the
panic — neither thing that had been guessed. The anchor
9223372036854775811 is 0x8000...0003, the high-bit namespace: a STAMPED
TEMPLATE ROW, restamped by the re-render the preceding Rename caused.
Popping over a freshly restamped row does not stay up on Wayland, GTK
emits `closed`, and the handler correctly releases a claim 89ms old.

THE FIX: under the harness, a `closed` arriving with the claim still set
is a FAILED PRESENTATION, not a dismissal, so it re-presents instead of
releasing. The handler's own comment had said for months that it
no-ops on the harness path — a scene has no user to press Esc or click
away — so a close reaching it is by definition the failure case.

AND IT REPRODUCES DETERMINISTICALLY, once the mechanism is known: inject
`popover.popdown()` immediately after the `popup()` in `context_open`
and the leg fails every time with that exact trail. With the fix in, the
same injection passes. Twelve runs of the menus family under contention
afterwards: clean. That is the whole loop — fails without the fix,
passes with it, same forced condition both ways — and it is what 86
statistical samples could not buy.

WHAT TO DO IF SOMETHING LIKE IT FIRES AGAIN: read the trail the panic
prints.
Five sites record every touch of the claim with elapsed time — the
right-click gesture, chrome dismissal, anchor destruction, activation,
and the harness verb — so the message names which one cleared it and how
long before. That was the question 86 samples could not answer.

The instruments are `tools/flake-hunt.sh` (repeat a lane, parallel
versus serial columns) and `KAYA_ONLY=` on the linux runner (one leg, or
one family, repeatedly). The lesson about them: whole-lane repetition is
far too coarse for a per-leg rate this low, and a single-leg hammer
removes the contention that triggers it. A family of related legs under
the pool is the middle instrument, and even that did not catch this one.


## A caller-sized occurrence buffer put a CAP ON HOW MUCH CONTENT A GUEST COULD RECEIVE

The function floor used to copy each occurrence into a buffer the caller
sized, and every caller sized it 256: Python, Swift and all ten C
guests. The core asserted the record fit. It does not fit for long.

Measured 2026-08-02 with a throwaway probe (`kaya_emit_pasted` with a
long text, drained at the buffer size the bindings really pass):

        200 bytes of pasted text -> next_occurrence returned 248, fine
        240 bytes of pasted text -> "occurrence record of 288 bytes
                                     exceeds the buffer of 256"
                                     thread caused non-unwinding panic.
                                     aborting.   (exit 134, SIGABRT)

So the ceiling was **208 bytes of payload** on a live-widget occurrence,
and going over it did not raise anything a guest could catch — the
assert fires inside an `extern "C"` frame, so the panic cannot unwind
and the process aborts. No guest in any language could have guarded
against it.

THE BUG PREDATES THE CLIPBOARD; the clipboard is what made it routine.
`text_changed` has carried unbounded entry text since milestone 0 and
every scene's text happened to be short. A pasted paragraph is over the
line, and an `html` representation is over it every time — kilobytes is
ordinary for one.

THE FIX WAS TO DELETE THE CAP, NOT RAISE IT. `kaya_next_occurrence` now
hands back a BORROWED POINTER to a core-owned record —
`uintptr_t kaya_next_occurrence(const uint8_t **record)`, the same
0/1/size return — and the caller copies out what it keeps, exactly as
`kaya_blob_data` and `kaya_occurrence_blob` already ask. There is no
buffer to be too small. A bigger buffer would only have moved the
number, and a limit on how much content may reach a guest is not
something kaya gets to have.

THE SENTINELS NULL THE POINTER, which is the second half of the lesson.
Only one of the ten C guests handled `KAYA_OCCURRENCE_WOKEN`; the other
nine fell through and re-parsed whatever their buffer still held — the
PREVIOUS occurrence, dispatched twice, silently. Under the old shape a
zeroed buffer made that harmless by accident. Nulling turns it into a
crash on the line that forgot, and all ten now carry the arm.

THE GUARD is `capi::tests::the_function_floor_hands_out_a_record_of_any_size`:
it pushes an 8 KiB pasted text and asserts the whole record arrives,
header and all. Watched failing — reinstating the 256-byte cap aborts
the test process with SIGABRT, which is the production failure exactly.


## Heavy concurrent GUI churn degrades the macOS accessibility subsystem, LANE-WIDE

Symptom: `expect_ax` fails with `<not in the accessibility tree>` across
scenes that have nothing to do with each other and were not touched —
background, split, listdetail, filedialog, clipboard, all at once. The
model assertions in those same legs pass; only the real-tree reads
fail. Reads take about 5s each rather than milliseconds, which is the
2.0s messaging timeout being hit two or three times per read, not a
missing tree.

IT IS THE MACHINE, NOT THE CODE, and it self-heals. Measured 2026-08-02,
twice in one session:

1. Eight clipboard legs run concurrently by hand (an experiment that
   left six failing). The lane started immediately afterwards lost 31
   legs to `<not in the accessibility tree>`. Minutes later the same
   a11y leg passed in 0.6s.
2. Earlier the same day, a single OCaml leg failed its AX read and the
   untouched a11y OCaml scene then failed 12/12 AX reads in 64 seconds.
   Both passed on a re-run with nothing changed.

WHY IT MATTERS FOR DIAGNOSIS. Episode 2 cost a wrong conclusion: the
a11y scene was used as a CONTROL to prove a defect was OCaml-specific,
but the control was measured inside the degraded window, so it
"confirmed" a language difference that does not exist. A control taken
during the same degraded window is not a control.

WHAT TO DO. Before believing any `<not in the accessibility tree>`
result, re-run ONE known-good AX leg (`a11y-rust` is cheapest) on a
settled machine. If it passes, the earlier failures were the
environment. Only if it still fails is there something to debug — and
then `KAYA_AX_TRACE=1` distinguishes "tree missing" from "read timed
out" in one run, because it dumps what the platform actually publishes.

The underlying mechanism is not proven, and the honest statement is
that it correlates with a burst of GUI processes starting and dying in
quick succession — especially a batch that left legs wedged. The
related and PROVEN cost is documented at KayaSwiftUI.swift's
kayaAxReadOnMain: announcing AXEnhancedUserInterface makes AppKit
rebuild its whole accessibility hierarchy and drive a full layout pass,
which on 2026-07-25 put legs past a 120s timeout under the 8-wide pool
while the same binary passed standalone.

## A windows race can stop reproducing, and a green run then proves nothing

MEASURED 2026-08-03 while fixing the filedialog_java coin flip
(deferred.md). Same VM, same boot, same binary:

| time  | build                          | filedialog_java |
|-------|--------------------------------|-----------------|
| 20:00 | HEAD (defective)               | 2/10 pass       |
| 20:19 | last observed failure anywhere | —               |
| 20:37 | HEAD (defective, redeployed)   | 10/10 pass      |

Nothing was updated: comdlg32/combase/shcore/rpcrt4 all still carried
their July timestamps, no servicing event ran, the machine had not
rebooted. Between those two rows sit about a hundred dialog opens, and
somewhere in them the machine got fast enough that the Shell's workers
finished before the apartment closed. The race was still there; the
window had shut.

THE COST IF YOU DO NOT KNOW THIS. Every verification after 20:19 is
vacuous. A fix measured 22/22 green against a defect that had stopped
reproducing says nothing about the fix, and a NEGATIVE TEST that puts
the defect back and sees green reads as "the guard is broken" when the
guard is fine — that exact sequence cost an hour here.

WHAT TO DO. Reproduce under load, not on an idle machine, and prove
the reproduction is live in the same session as the verification. The
load that worked, on the 6-core VM: four hidden
`powershell -Command "while($true){ Get-ChildItem C:\Windows\System32
-Recurse | Out-Null }"` plus four hidden
`cmd /c "for /l %i in (1,0,2) do rem"`, started with
`Start-Process -PassThru`, their PIDs written to a file so every one
of them can be stopped afterwards. Under it the defective build went
back to 4/10 failing within one batch, and the A/B became meaningful
— 25/25 for the fix under the same load. CPU SPINNERS ALONE DID
NOTHING (10/10 pass); the recursive metadata walks are what makes a
Shell worker late.

The general rule this is an instance of: when a race stops
reproducing, the first thing to establish is that your reproducer
still reproduces — on the unfixed code, in this session. A guard you
have never watched fail is worse than none, and so is a race you have
never watched happen.

## `set the clipboard to` reports success and writes NOTHING

MEASURED 2026-08-04, chasing a mac clipboard leg that died only under
the five-lane matrix — a different guest each run, always
`clipboard_seed files never appeared on the clipboard`, always after
consuming the settle's whole deadline (widening it 5s -> 15s changed
nothing at all).

AppleScript's clipboard write is REFUSED, silently, when another
process touches the pasteboard inside its clear-then-put window. The
seed's exact command, run against a competitor doing plain `pbcopy`
every 10ms, with a 1ms poll watching for the type afterwards:

| competitor        | writes | landed | osascript said |
|-------------------|--------|--------|----------------|
| none, heavy load  | 200    | 200    | rc=0, silent   |
| `pbcopy` @ 10ms   | 12     | 0      | rc=0, silent   |

Not "landed and was replaced": the type never appeared once, at 1ms
resolution, in any round. That is the Carbon Pasteboard Manager's
`badPasteboardSyncErr` shape with AppleScript swallowing the error.
The same command with a path that does not exist (`POSIX file
"/tmp/gone"`) is the other silent no-write: rc=0, nothing printed,
board untouched — while a path that DOES exist writes fine.

So the failure needs a second principal on the one macOS pasteboard,
which is what the matrix adds and a solo lane does not. CPU load alone
does not do it (200/200 above ran under twelve spinners and a looping
`cargo build -j 18`).

THE COST IF YOU DO NOT KNOW THIS. Every symptom points at the wait:
you widen the deadline, you poll harder, you suspect the pasteboard
server — and the write never happened. Worse, the interpreter used to
DISCARD the tool's exit status and stderr, so a tool that refused and
a tool that worked were the same empty string, and the only evidence
either way was a settle timing out fifteen seconds later.

WHAT TO DO, all of it now in `swift/KayaSwiftUI.swift`:

- Carry what the child process DID (`KayaToolRun`: status, stderr,
  stdout), fail the seed with the tool's own words, and trace a read
  whose tool refused (`KAYA_CLIP_TRACE: osascript exited 1: ...`).
- RE-ISSUE a write that did not land, up to the deadline. The seed is
  idempotent by construction — same file, same content, same command —
  and a write that is gone cannot be waited into existence.
- Prove the file exists before handing its path to a tool that will
  say nothing about it.
- Demand the changeCount MOVE, not merely that the type be offered:
  the scene's own copy leaves a union clip carrying nearly every type,
  so a type-only poll passes on the stale board (three of this scene's
  four seeds waited on nothing until this was fixed — the same vacuity
  §8 finding 6 found on iOS).
- And keep the evidence: the settle's fatal now lists every distinct
  clip it saw, `+Nms cc=NNN [types]`, which separates "nobody ever
  wrote" from "somebody else is writing this board too".

Guard: `kayaRunTool` is no longer `@discardableResult`, and the
interpreter compiles with `-warnings-as-errors` in BOTH
tools/swiftui/build-dylib.sh and tools/swift-typecheck.sh — so
dropping a tool's result is a BUILD ERROR, not a warning nobody reads.
Watched failing with the perturbation proven applied; the first
version of this guard was watched NOT failing, because a bare
`kayaRunTool(...)` is only a warning and `swift-typecheck: OK` still
passed.

WHO THE SECOND PRINCIPAL IS was not proven. Ruled out by measurement:
the mac lane (its clipboard legs are drain-bracketed), the android
pool (§7 finding 4, bridge severed, `-no-window`), the iOS lane
(Simulator.app not running, and run-sim.sh refuses a live relay per §8
finding 7). Left standing: this machine's Windows VM is configured
`/Sharing/ClipboardSharing = True` with the SPICE vdagent channel on
its running qemu command line, and the windows lane runs five
clipboard legs of 10-12s each, concurrent with the mac lane's
clipboard block. Something on this machine also reads every clip
within 15ms of it being written (measured with a promised-type probe).
If it happens again, the settle's clip list now names the intruder.


## A watchdog that reports a stall on a HEALTHY app, in five of eight languages

Symptom: a matrix leg fails and the log carries

    kaya: THE APP THREAD IS STALLED — 13 occurrences have been waiting
    1027ms and nothing has taken them. ... The cause is a handler that
    has not returned: something blocking ran on the app thread instead
    of on a thread of its own.

and the next session spends its first hours sampling a main thread that
was never blocked.

THE LINE WAS ALWAYS THERE — it just needs a leg that lives long enough
to cross the threshold. Measured 2026-08-04 on a PASSING haskell
clipboard leg (`KAYA_SELFTEST: OK` in the same run), varying only
`KAYA_STALL_MS`: 1ms -> "1 occurrences ... 106ms", 50ms -> "5", 100ms ->
"7", 400ms -> "9 occurrences ... 422ms". The pending count is simply the
running total of occurrences enqueued so far. One leg each, all passing,
at `KAYA_STALL_MS=100`: go 1, csharp 1, ocaml 1, haskell 1, java 1;
rust 0, python 0, swift 0.

THE MECHANISM. `crates/kaya/src/stall.rs` compared two counters,
ENQUEUED and TAKEN, and its own comment claimed they "say the same thing
about either transport". They do not. TAKEN was bumped only where the
CORE hands a record over — `OccRing::wait_pop` (the C function floor)
and `AppCtx::next` (the Rust mpsc path). The five languages that map the
ring and advance `head` themselves (go, csharp, ocaml, haskell, java)
never pass through either, so TAKEN sat at 0 for the life of the process
while ENQUEUED climbed: pending was permanently positive, the consumer
that WAS moving was never read, and the watchdog reported as soon as the
threshold elapsed.

WHY NO GATE SAW IT. `tools/scenes/stall.steps` asserted only
`expect_stall` — that a stall IS reported. Nothing anywhere asserted the
negative, and a watchdog that reports unconditionally passes that scene
in every language. A diagnostic that fires when it should not is worse
than none, because the line is read as evidence.

THE FIX: each transport is asked in the terms it actually has — the ring
through its `head`/`tail` cursors (which is what DESIGN promised: "the
core reads the app's consumer cursor directly"), the mpsc channel
through its counters. A cursor is also the better half of the pair: no
binding can forget to advance it, because a consumer that does not
wedges itself.

THE GUARD: `expect_no_stall`, asserted in stall.steps right after the
recovery the scene already proves, so every lane and every language runs
it. Watched failing with the watchdog put back in its blind form
(2 substitutions, both printed): haskell, go and java FAIL with "the
stall watchdog reports 7431ms of unclaimed occurrences about an app that
is answering this scene", rust passes. Restored: 8/8 green with two real
stall reports each.


## A standard clipboard command that is DISABLED does nothing, and said so
## to nobody

Symptom, from the 2026-08-04 matrix run: `menu_activate "Edit>Paste"`
reports success, no occurrence is emitted, and five seconds later the
scene fails on a label that still reads what it read before —
`label#0 reads "files pasted.txt pasted bytes", wanted "pasted pasted by
hand"`. Then the second paste, into a different widget, does the same.

THAT IS THE DESIGNED BEHAVIOR, and the diagnostic gap around it is the
bug. A role item computes its own enablement — what the clipboard OFFERS
intersected with what the FOCUSED widget accepts — and a disabled item
is inert, exactly as native chrome leaves a greyed one. For a person
that needs no words: they can see the grey. For a scene it is silent.

WHAT MAKES IT DISABLED MID-SCENE: a second principal writing the one
macOS pasteboard between the seed's settle and the activation (the trap
above names the candidates). An image-only clip is enough — the widget
accepts `text`, the board offers `public.png`, the intersection is
empty. Reproduce it deterministically with a second seed, no
concurrency needed:

    clipboard_seed text "pasted by hand"
    click button#5
    expect_focused entry#0
    clipboard_seed image "$TMP/kaya-clip-$PID/pixel.png"
    menu_activate "Edit>Paste"
    expect label#0 "pasted pasted by hand"

HOW TO TELL IT APART FROM A READ THAT ANSWERED EMPTY: the read's own
note. `kayaReadClipboardValue` traces every nil answer
(`KAYA_CLIP_TRACE: read of [text] answered empty; the clipboard offered
[...]`), so if the paste were reaching the read and coming back empty
that line would be in the log. In the failing run it was NOT, which is
what proved the command never dispatched.

WHAT TO DO, now in `swift/KayaSwiftUI.swift` (mac and iOS, one body):
`kayaRoleInertNote` prints one line when a harness `menu_activate` lands
on a role item whose command is disabled, naming the intersection that
came up empty, and `kayaClipOwned`/`kayaClipOwnerClause` remember the
changeCount kaya itself last put on the board — the app's own copy and
any seed that settled — so the note can say whether the board has been
REPLACED since:

    KAYA_CLIP_TRACE: menu_activate "Edit>Paste" did nothing — the paste
    command is disabled and a disabled item is inert. the focused widget
    (node 1) accepts [text]; the clipboard offers ["public.png", ...] at
    cc 48312 — AND THE BOARD HAS MOVED SINCE KAYA WROTE IT (cc 48308 ->
    48312): another process is writing this clipboard

The dispatch itself is untouched: inert stays inert, on every platform.
A pasteboard has no "who wrote it", and the changeCount kaya owns is the
only evidence that separates "kaya read the wrong thing" from "somebody
else replaced the board".


## A paste can land on the widget that WAS focused: kaya's focus is synchronous,
## the platform's first responder is not

Symptom, twice in one mac lane run (2026-08-04) and not reproducible on demand:

    KAYA_HARNESS: +690ms click button#6
    KAYA_HARNESS: +690ms expect_focused entry#1
    KAYA_HARNESS: +715ms menu_activate "Edit>Paste"
    KAYA_HARNESS: step-failed entry#1 reads "", wanted "pasted by hand"
    KAYA_HARNESS: step-failed ax field/, wanted field/pasted by hand

with no `KAYA_CLIP_TRACE` of any kind — so the Paste command was ENABLED (the
trap above is a different failure), it dispatched, and the platform's own
insertion did not reach entry#1. The AX read agrees the field is really empty, so
the text went somewhere else or nowhere.

THE MECHANISM, hypothesis not yet proven: `tx.focus(entry#1)` sets
`kayaScene.focusedId` immediately and `expect_focused` reads exactly that, so the
scene proceeds at once — but the AppKit first responder only moves when SwiftUI
applies the @FocusState change on its next update pass. `kayaSendToFocusedResponder`
sends `NSText.paste(_:)` to `window.firstResponder`, which in that window is
still entry#0's field editor — another editable field, which takes the paste
happily. Under load the pass takes longer than the 25ms the scene leaves.

WHAT MAKES IT HARD: every assertion in the scene reads the same either way. The
symptom is a field that stayed empty, which is also what "nobody took it" and
"the widget ignored it" look like.

WHAT IS IN PLACE NOW (do not re-derive this from scratch):

- `kayaSendToFocusedResponder` reports a command NOBODY took — the callsite's
  comment claimed it did and it did not. One line naming the selector, kaya's
  focused node, and each window's first responder.
- `tools/scenes/clipboard.steps` asserts `expect entry#0 ""` after the second
  paste. entry#0 declares an accept list, so kaya delivers to its paste hook and
  the platform never inserts there; it must stay empty for the whole scene on
  every backend. A paste that landed on the wrong widget fails THAT line and
  names itself.

WHAT WOULD SETTLE IT, next time it fires: read the two new lines. `entry#0 reads
"pasted by hand"` proves the wrong-widget path (fix: make the platform paste wait
for the responder to match kaya's focus, or make `expect_focused` a real-tree
observation on macOS rather than a model read). `reached no responder that would
take it` proves the no-responder path (fix: the focus never reached AppKit at
all). Nothing in the mac lane's 260+ green clipboard legs distinguishes them
today.

NOT A PRODUCT RACE, as far as anything shows: a person focuses a field and pastes
hundreds of milliseconds later. It needs focus and paste inside the same ~20ms,
which only a harness does.

## An ad-hoc `cabal build` poisons the shared dist-newstyle for the whole mac lane

Measured 2026-08-10, cost one full validate-mac run (~14 minutes).

The Haskell guests link against libkaya, which is not on any default
search path: `guests/haskell/kaya-guests.cabal` declares
`extra-libraries: kaya` and every caller supplies the directory —
`--extra-lib-dirs="$ROOT/target/debug"` plus the matching `-L` and
`-rpath` in `--ghc-options` (tools/validate-mac.sh's `build_haskell`,
tools/check-abort.sh).

Run `cabal build <target>` WITHOUT those flags — the obvious thing to
type when checking one guest compiles — and it fails immediately with
"Missing (or bad) C library: kaya", which reads like a broken
environment and is easy to shrug off. What is not obvious is that the
attempt writes a configuration into the shared `dist-newstyle`, and
every later build in that directory reuses it. validate-mac then fails
in its `guest build` phase with

    ld: library not found for -lkaya

**even though its own command line carries the flags**, and even though
building the same target into a FRESH `--builddir` succeeds. The lane
failure looks like a code regression in the binding that was just
edited. It is not; nothing is wrong with the tree.

The fix is `rm -rf guests/haskell/dist-newstyle` and rebuild.

The habit that avoids it: when compile-checking one Haskell guest by
hand, either pass the same three flags the lane passes, or send the
output to a private `--builddir` (what tools/check-abort.sh does, for
its own reason — it wants a guaranteed relink). Never a bare `cabal
build` in that directory.

This is the second time cabal's caching has cost a debugging round
here; the first is the never-relinking one two sections up. Both have
the same shape — cabal trusts a cache over the world — and neither is
visible in the error message.

## A per-app font is never in the system font collection, and the read
## believed the collection

Measured 2026-08-16, cost the windows lane five legs of a five-lane
matrix — four lanes green, the same five typeface legs red on windows,
with the font rendering correctly on screen the whole time.

The typeface scene ships a VENDORED font as bytes. On WinUI those bytes
become a file under the app root and a `FontFamily` source naming it,
`ms-appx:///kaya-fonts/brand-<hash>.ttf#Sora` (`register_font_blob`) —
the register-then-resolve route a brand's licensed font takes. XAML
resolves it, lays text out in it, and the harness read's own fingerprint
measurement PROVED that: the laid-out width and baseline differed from
the fallback's.

The read then printed

    KAYA_SELFTEST: FAILED (typeface Sora (XAML lays it out, but it is
    not one of this machine's 81 font families), wanted Sora)

because its third answer asked `IDWriteFontCollection::FindFamilyName`
against the SYSTEM font collection. A per-app font file's family is not
in that collection — that is what per-app means — so the question has a
permanent "no" in it, the answer could never be the bare family name,
and the scene could never pass on this backend. The verdict claimed
LESS than the measurement supported, which is the mirror image of the
usual diagnostic failure and just as misleading: every reader of that
sentence goes looking at the machine's installed fonts.

The rule that comes out of it: A PRESENCE QUESTION FOLLOWS THE SOURCE.
A bare family name is the system collection's question. A `path#family`
source is the FILE's question — is the file there, and does its own
name table declare that family — which is the inverse of what the
registration wrote, and is now `typeface_availability`, shared by both
sentence sites so they cannot answer differently.

### The second half: Windows will not overwrite a MAPPED file

Found the same day by the test written for the above.
`register_font_blob` rewrote its file on every launch. DirectWrite (and
XAML behind it) memory-maps a font file it has open, and Windows
refuses to write a mapped file:

    C:\kaya\kaya-fonts\brand-e67019d22467d0da.ttf could not be written:
    The requested operation cannot be performed on a file with a
    user-mapped section open. (os error 1224)

The caller turns that into a panic, and the windows lane runs four
guests at once with two of them (the rust and go legs) sharing one app
directory — so this was a startup crash waiting for the right
interleaving, on a scene that had never been green long enough to flake.
The file is named by the hash of its own content, so the fix is not to
write it when the bytes on disk are already the bytes asked for.

### The third half: POSIX will — and that is worse

Found hours later by the matrix rerun: linux went red where it had been
green, one leg (typeface-java-wayland), one second in, SIGBUS inside
libfreetype. The GTK arm has the same shared, content-named file
(`/tmp/kaya-font-<hash>`, `register_font_blob` in gtk.rs) and rewrote
it the same way — but POSIX PERMITS truncating a file another process
has mapped, so instead of a loud os error 1224 there, the reader
crashes: `fs::write` is open(O_TRUNC), the file is momentarily zero
length, and the neighbor that mapped it dies with BUS_ADRERR the next
time freetype touches a page past the new EOF. The linux lane runs its
legs in a parallel pool, so two typeface guests really are in flight at
once; the hs_err file's memory map named the faulting mapping and
closed the case.

The rule, now with both halves: NEVER REWRITE A SHARED FONT PATH IN
PLACE. Skip the write when the bytes are already there (both arms), and
when a write is needed, write a unique staged name and rename() it in
(the gtk arm) — the directory entry flips atomically and a mapped old
inode stays alive under every process reading it. Windows turns the
in-place rewrite into a crash in the WRITER; POSIX turns it into a
crash in the READER, later, in a different process, with a stack that
points at freetype instead of at the write.

## A live-zone `When` stamps an EMPTY key path, and the wire reads that
## as "this id is a widget id"

Measured 2026-08-10 with the text editor (guests/go/editor), and the
reason its find bar is a collection of ONE ROW rather than the `When` a
reader would expect. Every occurrence a live-zone When's body produces
is misrouted, silently, to whatever widget happens to hold the same
number.

The wire's identity rule is one sentence (crates/kaya/src/wire.rs, the
click-tag block, and spec.rs's `button_clicked` doc): the occurrence
body is `{ u64 id; u32 path_len; ... path }`, and PATH_LEN 0 MEANS `id`
IS A WIDGET ID. Otherwise `id` is a template node id and the values are
the copy's key path. `decode_click_tag` branches on exactly that.

A For's copies each carry their key, so a For occurrence decodes as the
instance it came from. A When has no keys — `register_when_site` in
scene.rs is handed the enclosing path, and in the LIVE zone that path is
empty — so its stamped copy's occurrences go out with path_len 0 and a
TEMPLATE NODE id sitting in the field the decoder has just decided is a
widget id. The two spaces are separate counters that both start at 1
(the `counters` struct in each binding, e.g. bindings/go/app.go), so the
ids collide from the very first widget.

What that looked like: typing in a When-stamped find field arrived at
the TEXTAREA's change handler — template node 2 read as widget 2 — and
the document went dirty with text nobody had typed into it. The bar's
three buttons landed on widgets that had no click handler at all and
simply vanished. Nothing errors anywhere on this path.

Why four milestones missed it: the only `When` any guest declares
(guests/go/milestone2) holds a STATIC LABEL, which produces no
occurrences, so no scene had ever exercised a When body that could
report anything.

No guard exists. Until there is one, a live-zone When whose body
contains an interactive widget is a trap, and the workaround is a `For`
over a one-entry collection: its copy carries a key, so the path is
non-empty and the occurrence decodes as the instance it is.

## An app can VETO a close but cannot AGREE to one, and the arm that
## tries aborts the process

`veto_close` hands the window's close to the app, `close_requested` is
the question, and the alert machinery is the answer — but there is no
verb for the affirmative. `destroy_window(0)` is the obvious candidate
and it is refused by assertion (crates/kaya/src/scene.rs's
`TxOp::DestroyWindow`: "kaya: the primary window is not destroyable —
the process owns it"). The assertion is right; the gap is that nothing
else says yes.

Measured while writing the text editor, not reasoned about: a perturbed
run reached that arm and died with the assertion plus `fatal runtime
error: failed to initiate panic, error 5` — the non-unwinding-context
abort recorded under "A GUARD THAT ABORTS THE PROCESS IS THE WRONG
SHAPE" (docs/deferred.md), so the leg has no verdict list either
— until 2026-08-21, when `Scene::apply` moved under `crate::fault::guard`
and that arm began reddening the leg instead. The nine guests still carry
`destroy_window(0)` and no scene still takes the arm, so the exposure is
unchanged; only the failure mode is.

THE LIVE EXPOSURE IS NINE FILES: every port of the dirty scene — one
per language, guests/rust/dirty.rs and guests/c/dirty.c among them —
carries `destroy_window(0)` in exactly the arm that
agrees to discard. No scene has ever taken that arm, so nothing has
ever run it, and the day a scene does, nine legs abort at once.
guests/go/editor/editor.go's `quit` is the only guest that works around
it, with `os.Exit` — the one call in that file that leaves the
framework.

## The stall scene wedges for a DAY, not forever, because several
## runtimes catch a true permanent park

The stall scene is the one guest that misuses kaya on purpose: its
`wedge` button blocks the app thread and the scene asserts that kaya
NOTICES. The obvious spelling is a permanent park, and it is wrong in
this scene — every guest deliberately sleeps for 24 hours instead
(`wedge`, `WEDGE_SECONDS` and their seven siblings).

The reason is that "forever" is a different call in each of the eight
languages and several runtimes treat a thread that can never be woken
as a DETECTABLE DEADLOCK: they raise instead of hanging, the app dies
with a runtime error, and the scene then measures the runtime's
detector rather than kaya's watchdog. A day is indistinguishable from
forever inside a leg that lasts seconds, and no runtime objects to it.

Do not "simplify" any of the eight back to a real park. The note this
entry replaces lived in all eight stall guests and named no runtime,
so neither does this — what is established is the rule and the reason
for the number, not a list of which detectors fire.

## A range offset is a UTF-8 BYTE offset, and almost no language's own
## search agrees

kaya's ranges are UTF-8 byte offsets in every language. Almost every
guest language's native string search answers in a DIFFERENT unit, and
the disagreement is silent: the offset that comes back is a legal
number on a character boundary, so nothing refuses it — the highlight
just covers the wrong text, and only on a document containing
non-ASCII.

The ranges scene is built to catch exactly that. Its frozen document
opens with a CJK word, which is why docs/deferred.md records that
"every match sits six bytes further along than it sits in UTF-16": the
document is 813 bytes and 807 UTF-16 code units. A guest that converts
in its own unit decorates six characters early from the first match
onward and the scene's byte-frozen assertions fail.

WHAT EACH LANGUAGE'S OWN UNIT IS, since the trap is per-language and
the guests are where it shows:
  - Swift — NEITHER bytes nor integers. `firstRange(of:)` returns
    `Range<String.Index>`, and BOTH conversions an author reaches for
    first are six early: `distance(from:to:)` counts Characters
    (grapheme clusters) and `utf16Offset(in:)` counts UTF-16 code
    units. The route is `kayaByteRange` in
    bindings/swift/KayaApp.swift — hand it the `Range<String.Index>`
    you already have, `in:` the string that indexes it, and let the
    binding convert. Never convert by hand.
  - C# and Java — `IndexOf` / `indexOf` answer in UTF-16 code units.
  - Python — `str.find` answers in Unicode scalars (the conversion
    rule is written up in `highlight_ranges`' docstring,
    bindings/python/kaya/__init__.py).
  - Go, Rust, C, Haskell (over `BS.breakSubstring`) — already bytes,
    so their guests hand kaya what they already had. That is why those
    ports read as if there were nothing to think about, and why the
    other four need this entry.

docs/ranges-plan.md covers the design and says nothing about any
language's indexing.

## UIPasteboard's changeCount is a PER-PROCESS number, and a text field
## taking focus inflates the reader's copy of it

Measured 2026-08-18 on the iOS 26.5 simulator, with Simulator.app not
running and `PasteboardAutomaticSync` = 0 (so no host relay is in the
picture). One action per phase, a 5ms poller printing every distinct
count, and a bounded off-thread read of the bytes at each phase:

    write a union clip        cc 722 -> 723   (+1, SYNCHRONOUS)
    nothing, 4.5s                    723      (+0)
    becomeFirstResponder      cc 723 -> 727   (+4)
    resignFirstResponder             727      (+0)
    becomeFirstResponder      cc 727 -> 731   (+4)
    selectAll                        731      (+0)
    responder-chain copy      cc 731 -> 732   (+1, SYNCHRONOUS)
    nothing, 4.5s                    732      (+0)

The +4 arrives as two +2 steps: one inside the ~105ms
`becomeFirstResponder` call, one about 10ms after it returns. Across
every one of those increments the board is the SAME board — `types`
identical (six entries), `numberOfItems` identical, and the bytes
identical, the read answering promptlessly, which is also the proof the
clip is still the app's own. No `changedNotification` is posted for any
of them (the app's own writes DO post it, twice each: once bare, once
carrying `UIPasteboardChangedTypesAddedKey`/`...RemovedKey`).

SO THE COUNT IS NOT A FUNCTION OF THE CONTENT on this platform. That
breaks the one premise a foreign-writer witness can be built on — kaya
staged the board at one count, wrote nothing since, so another count
means another writer — and it broke it in the most expensive way
available: the guard was correct on macOS, shipped, and then failed all
three iOS clipboard legs with a confident sentence naming a stranger
("the pasteboard changed under this leg (changeCount N -> N+2): a
foreign writer replaced the staged content"). The stranger was the
leg's own keyboard: clipboard.steps focuses an entry and then pastes.

NSPasteboard does NOT do this — the same steps on the eight mac legs
focus the same entries and the count sits still — which is why a guard
written and watched failing on macOS says nothing at all about iOS.

### AND THE INFLATION IS PRIVATE TO THE FOCUSING PROCESS

Measured 2026-08-18, and this is the part no published report has: the
pasteboard SERVER's count is correct throughout. It is the reader's copy
that is wrong, and only in the process that focused.

- An app and a second process on the same simulator polled the same
  `UIPasteboard.general.changeCount` at 5ms. The outside process moved
  by exactly +1 per write and by NOTHING on focus, while the app went
  747 -> 751 on one focus and 752 -> 756 on the next.
- Two FRESH processes reading cold after the run read 748 while the
  focusing app had reached 756. The same board, the same instant, two
  numbers.
- The simulator's own `com.apple.Pasteboard` log carries a line for
  every write ("is saving pasteboard", "Saved item … type
  public.utf8-plain-text") and NOT ONE for any focus, in either process.

AND IT NEVER RESYNCS. When another process really did write, the server
went 753 -> 754 while the app went 757 -> **758** — the foreign write
arrives as a +1 delta on top of the inflation, never as a correction. So
what the property returns is *the server's count when this process first
read it, plus every increment it has seen since, including the ones only
it can see*. Absolute values are not comparable across processes, and no
amount of waiting, coalescing or re-reading reconciles them: THE TWO
COUNTERS ARE SIMPLY DIFFERENT NUMBERS. That is why there is no tolerance
window and no settle that could have rescued the count route.

WHAT RAISES THEM is the text-input session, isolated by measurement
rather than by argument. A bare `UIView & UIKeyInput` with none of
UITextField's machinery is +4; a `UITextView` with `isEditable = false,
isSelectable = true` — a real first responder with an edit menu and a
Copy command, but no input session — is 0; a plain `UIView` with
`canBecomeFirstResponder` is 0. Ruled out: the system keyboard's UI (a
custom `inputView` still bumps +4), the correction/prediction stack (all
of it off, still +4), the board's content (an EMPTY board bumps +4, an
image-only board bumps +4), and every pasteboard API an app can call
(`string`, `hasStrings`, `itemProviders`, `detectPatterns`,
`setNeedsRebuild` — all 0). A field with `isSecureTextEntry = true` is
0, which is the one functional clue: a secure field is exactly the one
iOS does not offer clipboard content to. The exact UIKit function is NOT
identified.

THE PUBLISHED REPORTS ARE OLD AND THEIR FRAMING IS WRONG. Apple's own
forums, thread 123596 (Sep 2019, iOS 13, Feedback FB7397122) and thread
131419 (Apr 2020, an independent Objective-C reproduction), both report
+2 per `becomeFirstResponder` with no notification, both note iOS 11 and
12 did not do it, and people were still asking in Jan 2024 — four and a
half years unacknowledged. Both read it as a WRONG GLOBAL COUNT; it is
not, and anyone who starts from that will look for a way to make the
number right. The delta grew from +2 (iOS 13) to +4 (iOS 26.5), still in
units of two. Thread 123596's reporter attributed his +2 to
`canPerformAction(_:withSender:)` for `paste:` — called directly on iOS
26.5, once or five times, focused or not, that moves NOTHING, so the
2019 mechanism is not the callable cause today.

### changedNotification IS NOT THE WAY BACK — MEASURED, TWICE

The obvious replacement — treat a `changedNotification` arriving while
this leg is not staging as a foreign writer — is UNSOUND, and it fails
in the silent direction. A genuine foreign write from a separate process
on the same simulator produced **zero** notifications in the observing
app: probe 7 (one write, 23s of watching, one notification, the app's
own) and probe 8 (25s of watching after the stranger's write, two
notifications, both the app's own). The app was `active` at the time —
PRINTED in every sample rather than assumed — its runloop was turning,
and the observer was registered with `object: nil`, which is the
registration shape that matters (forums 54227: `general` does not always
vend the same instance, so registering on the object can silently miss
even your own writes). It fires for the app's OWN writes only, and for
those it fires TWICE.

Third-party attestation for the same shape: rdar 28771678 (PSPDFKit,
iOS 10, another app copying in SplitScreen delivers nothing), forum
threads 760154 and 110504 (the same question asked twice, zero replies),
rdar 43844502 (an XCUITest write delivers nothing to the app under
test). Apple has never documented a delivery condition either way — not
in the current page, not in the 2018 archive guide, not in the iOS 3.0
reference — while `changeCount`'s page still says, and has said for 17
years, that increments happen when "items are added, modified, or
removed" and that UIPasteboard "posts the notifications" after each one.
Both halves are false as measured.

### WHAT IS SOUND: A PRIVATE MARKER TYPE

`pb.contains(pasteboardTypes: ["dev.kaya/…"])` held TRUE through the
entire focus inflation and flipped FALSE within 13ms of the stranger's
write, prompt-free, one call. That is the signal the counter was
standing in for, and it is also the answer Apple's own DTS gave the 2019
reporter: stop trusting the count, put a type you control on your own
clip and look for it.

kaya does exactly that. `kayaClipMarkerType` (`dev.kaya/staged`,
swift/KayaSwiftUI.swift) rides on every clip a kaya-controlled writer
composes — the app's own `items =`, and tools/ios/clipctl/main.swift for
a seed — and `kayaClipDrifted` compares the MARKER on iOS and the COUNT
on macOS. Its honest limits, in the comment at the check: it sees the
staged clip being REPLACED, never a stranger carrying kaya's own marker
(a second kaya leg on one device would; the lane runs one leg per
simulator), and never a writer who APPENDS an item and leaves kaya's in
place (which the macOS count does catch). The threat model is the
machine-wide resource shared by ACCIDENT — a human pressing Cmd-C, a
clipboard manager, a VM relay, a sibling lane — not an adversary.

THE MARKER'S OWN FAILURE MODE IS VACUITY, and it is guarded rather than
trusted: a stage that closes without the marker makes the witness stand
down, so a marker that silently stopped being written would leave a
guard that can only ever agree. `kayaClipOwned(_:composed:)` fails the
leg at that moment instead, which is what pins the spelling across the
two binaries no compiler spans. Both branches were watched failing:
strike the board from another process and the leg dies naming the marker;
delete the marker from clipctl and the leg dies naming the stage.

THE NEGATIVE HAS TO BE FAST. The window between the scene's last stage
closing and the last step that consumes it measured 1.3s, and a
host-side trigger (`simctl spawn` to poll, `simctl spawn` to write) takes
about two — the first attempt struck the board AFTER the scene and the
leg passed. Put the striker INSIDE the guest (a resident CLI polling
`pb.types` on a runloop at 10ms, writing the instant it sees the scene's
last stage) and detection costs milliseconds. A process that reads the
pasteboard with NO runloop turning reads a frozen number forever — the
client learns of changes by a Darwin notification and nothing delivers
it — which cost one probe 120 seconds of a single unchanging value.

The guard is scoped in `kayaClipDrifted` (swift/KayaSwiftUI.swift), the
one comparison both the witness and the trace clause read. The probes
are throwaway (a UIKit app, `simctl launch --console-pty`); the shape to
reuse is one action per phase plus a poller, since a timeline that only
samples after WRITES would have concluded "no async bump" and stopped —
which is exactly what the first probe concluded.

A SECOND FINDING FROM THE SAME PROBE, paid for at five minutes of a
parked main thread: reading `pb.string` at launch BLOCKS on the
per-clip paste alert when the board holds anything this install did not
write, and a probe with nobody to answer it simply hangs. Sample the
prompt-free surface (`changeCount`, `types`, `numberOfItems`) and put
any read of the bytes on a background queue behind a deadline, so a
block is a measurement instead of a wedge.

## Cutting comments is its own trap family

Measured across the 2026-08-19 tree-wide sweep (13 lanes, ~21,000 lines
cut, every one proven comment-only by a string-literal-aware skeleton
diff). The next comments pass starts from these, not from scratch:

- THE PROOF TOOL DEFINES "COMMENT", AND THREE THINGS ARE NOT ONE. A
  python triple-quoted docstring is a STRING LITERAL — including inside
  a shell heredoc — so rewriting one is a code change and fails the
  skeleton proof (two lanes hit this live). Haskell `{-# … #-}` pragmas
  look like block comments and are code. A line beginning `# shellcheck`
  is a DIRECTIVE: prepend prose to it and shellcheck dies SC1072/SC1073.
- REGEX STRIPPERS DIE ON STRINGS, VACUOUSLY. `.setType("*/*")` in
  KayaCompose.kt terminates a naive block-comment regex (~87 live lines
  eaten); a `///` doc line containing `"""` silently spared 2,302 lines
  in one probe and LOOKED like a clean pass. A cutter is validated the
  same way a negative test is: run it on a file where you know the
  answer, and treat "nothing to cut" as a failure to explain. The
  sibling shell trap: counting doctest fences with grep -c over a
  backtick pattern returned 0 because the SHELL ate the backticks —
  count fences from python.
- RUST DOCTESTS LIVE IN `///`. Thirteen `compile_fail` walls in app.rs
  are comments to a stripper and tests to cargo; compare doctest COUNTS
  before/after, because their loss is silent.
- SOME COMMENTS ARE LOAD-BEARING TO GATES. check-go-env demands a `//`
  line naming `os.Getenv`; generated files are exempted by their
  `DO NOT EDIT` banner (guest-floor.py); check-steps' `wired()` greps
  bare scene names that in four (scene,runner) pairs exist only in
  comments; and two docs DELEGATE line-numbered comment blocks as the
  durable home of measurements (run-suites.sh's app_id table,
  validate-all's duration ceilings). The gate-read survey's map is the
  census route: cut, run the gate, watch the red, restore.
- TWO GENERATORS PUNISH THE CUT ITSELF. tools/kaya-bindgen sources are
  whole-file-hashed by crates/kaya/build.rs — any comment byte moved
  there reddens every cargo run until tools/gen-bindings.sh restamps
  (the panic names the fix). tools/gen-guests.sh --check REGENERATES
  unconditionally, so a cut made in a generated guest silently reverts
  and the gate exits 0 — cut generators, never their outputs.
- CITATIONS SHRINK-BREAK AND MEANING-DRIFT. check-doc-refs holds
  `path:NNN` anchors only to `NNN <= file length`, so a big cut breaks
  anchors (13 files went red from shrinking alone) and a small one can
  leave an anchor pointing at the WRONG line with the gate green —
  re-anchor by TEXT, never by arithmetic.


## Transcript replay: a Write/Edit-only reconstruction silently invents
## or truncates files — replay VERDICTS, not just payloads

Measured 2026-08-19, recovering 49 dead scratchpad documents out of
session transcripts (the docs/probes/ landing). Four traps, each of
which corrupted a first-cut reconstruction:

1. REPLAY ONLY OPERATIONS THAT SUCCEEDED. A transcript records the tool
   CALL even when it errored (InputValidationError, “String to replace
   not found”, “File has not been read yet”). Replaying an errored Edit
   invents content the file never carried; skipping errored ops turned
   one false PARTIAL into a clean FULL. The op’s RESULT block is part of
   the recipe.
2. A FILE CAN EXIST WITH NO Write AT ALL. One 26 KB report was built by
   seven Bash heredocs appending in sequence — search Bash commands for
   redirections into the path, not just Write/Edit file_paths.
3. GROUP BY EXACT PATH, NEVER BY BASENAME. Sessions also wrote
   same-named siblings to mistyped roots, some containing the literal
   word “placeholder”; a basename-keyed replay truncates the real
   document to one word.
4. MATCH DELIMITERS EXACTLY. An Edit whose old_string was matched with a
   whitespace-flexible pattern desynchronises every later Edit — one
   recovery matched a heredoc delimiter with a pattern whose \s ate the
   following newline, and every subsequent old_string then missed.

The proof of a reconstruction is per-file: every Edit found its
old_string exactly as declared, in order, and a re-run reproduces the
bytes. The recovery tooling and per-file op indexes from the 2026-08-19
run are kept beside the recovered set’s staging area in that session’s
artifacts; the landed files are docs/probes/ (see its README).


## The emulator pool degrades across a long day of lane runs — reboot it
## before believing a new android one-off

Measured 2026-08-19, after ~20 lane/matrix runs on the same four
long-lived emulators: three DISTINCT android one-off failures in three
different matrix runs (a storage AccessDeniedException, two
empty-logcat 62s timeouts where the app never reached the harness),
every one 20/20-green solo and none reproducible — then a pool kill
(`adb emu kill` x4), a cold boot by the lane itself, and the very next
matrix ran ALL PASS. The mac lane has the same trap one platform over
("Heavy concurrent GUI churn degrades the macOS accessibility
subsystem, LANE-WIDE"). The rule: on a long session, when a SECOND
unrelated android one-off appears, reboot the pool BEFORE chasing the
leg — the reboot costs two minutes and the chase costs an evening.

## An Android toolchain move outlives its dev shell

Measured 2026-08-23 after cab6d33 moved the pinned emulator from
36.6.11 to 37.1.11: the four v36 emulator processes stayed alive across
the flake change, so two matrices on the new tree silently reused the
old host binary. Killing them finally started v37, but both AVDs still
had July quickboot snapshots. `make_snapshot` treated the directory's
existence as compatibility; all four v37 readers logged `Failed to load
snapshot 'default_boot'` and `starting from scratch. Reason:
incompatible snapshot version`, then booted from scratch in 36.244–
38.664s. The lane passed functionally in 498s while `TIMING boot` said
0s because its clock started after every boot wait. Compose carried the
post-boot churn (11s median, 481s summed leg time), JVM fell to 8s and
Go to 6s; the changing cost across one unchanged interpreter rules out
work added to every leg.

The dev-shell fingerprint cannot evict a process outside its shell, a
snapshot on disk does not attest which emulator can restore it, and a
restored boot id is not a process identity. The Android launchers now
fingerprint the immutable emulator and system-image store paths, tie a
saved snapshot to that pair, and tie each read-only guest overlay to
the pair, AVD and serial. A mismatch reseeds with one writable instance
before any readers launch; readers force `default_boot` to load instead
of accepting a cold fallback. The only host marker lives under
`target/avd`; the live `/data/local/tmp/kaya-emulator-identity` marker
lives only in each read-only process's guest overlay and is removed from
the writable seed before shutdown, so it is never stored in the seed
snapshot.

## The x11 lane has NO window manager, so X focus reverts to POINTERROOT
## when a dialog closes — and the POINTER'S POSITION decides who types

Measured 2026-08-20, deterministic per screen size: growing the Xvfb
screen from 1024x768 (to hold the panes scene's 1400px resize) turned
editor-go-x11's post-dialog typing into keys that landed nowhere, on
every run, while the SAME leg stayed green at 1024x768 and the failure
followed ANY growth of either axis. The mechanism: without a WM,
closing the GTK file dialog reverts X input focus to PointerRoot, so
FocusIn goes to whatever sits under the pointer — which rests at the
screen's centre, INSIDE an 800x600 window on the old stage and on the
bare root of a bigger one. GTK then reads active=false on its toplevel
and delivers no keys, while its OWN focus widget still reports the
textarea — so expect_focused passes, xdotool reports success, and the
buffer never moves. Every plausible-looking fix short of the real one
fails: re-asserting focus with `xdotool windowfocus` does not flip
GTK's active state (GDK tracks FocusIn on its focus proxy, not a
direct XSetInputFocus on the toplevel), and a 2s-later resend dies the
same way. THE FIX IS THE POINTER: the typing verb now parks it over
the primary window (mousemove --window <id> 40 40) before focusing and
typing, so every later PointerRoot revert lands on kaya's window. The
diagnosis took the discriminating print — each toplevel's
visible/active/focus plus X's focus window — added to KAYA_UNDO_TRACE's
timeout branch, where it stays. If typed keys ever vanish on the x11
leg again, read that trace FIRST: active=false with the right focus
widget is this trap; a wrong focus widget is a different one.


## GtkColumnView cannot host kaya's stamped children (2026-08-21)

MEASURED in the lane's own container, not reasoned. A `GtkListItem`
OWNS its child, so handing a `GtkSignalListItemFactory` a widget
kaya's stamp already parented trips

    Gtk-CRITICAL gtk_widget_set_parent:
        assertion '_gtk_widget_get_parent (widget) == NULL' failed

and the list item stays empty: the labels keep their kaya parent and
the ColumnView draws nothing. Two more facts from the same run, each
fatal alone — `setup` fires once per VISIBLE item, driven by the model
and the recycler rather than by kaya's stamp (so one widget cannot be
split across the recycler), and the MODEL is the order authority where
kaya's core owns order (`collection_move` -> `ApplyOp::MoveChild` ->
`gtk_box_reorder_child_after`). That is why the GTK table is the
SYNTHESIZED header of docs/tables-plan.md decision 6 and not the
native construct. Re-probing costs a session.

BESIDE IT, THE PART WORTH REUSING: GtkBox + one horizontal
GtkSizeGroup per column + `hexpand` on every cell IS
floor-plus-equal-leftover, exactly, and the toolkit does the
arithmetic. Measured at two widths on one tree: the columns' width
DELTA stayed constant (112px) across a 500px window change while each
column took +250, and a column's header cell and every row's cell
shared an x TO THE PIXEL. GtkGrid with hexpand columns does the same
arithmetic (delta constant at 146) but cannot host kaya's stamped Row
boxes without dissolving them.

## A thread_local holding a XAML object aborts the process at exit, AFTER the scene has passed (2026-08-21, second bite)

On Windows, Rust TLS destructors still run during `process::exit` (TLS
callbacks), and by then `Application::Start` has returned and XAML's
apartment is dead. Releasing a XAML COM reference there is an access
violation the CRT turns into `0xC0000409` (`FAST_FAIL_FATAL_APP_EXIT`).
The signature is unmistakable and useless: the guest prints
`KAYA_SELFTEST: OK`, then `EXIT=-1073740791`, and nothing anywhere says
why — the leg fails on the exit code alone.

MEASURED TWICE. `APP_ICON_BITMAP` (a `BitmapImage`) on every identity
leg, 2026-08-18, found by bisecting. `TABLES` (a header Grid, a rule
and the header cell Buttons) on the first windows table leg,
2026-08-21 — the comment recording the first incident was three
screens away from the new thread_local and nobody read it.

THE RULE: any thread_local in the WinUI backend that can hold a XAML
handle is drained and `std::mem::forget`-ed in `run_core`, beside
`CORE` and `APP_ICON_BITMAP`. The process reclaims the memory; nothing
else can reclaim the apartment.

## An observable with no discriminator cannot be asserted onto a device (2026-08-21)

Decision 5 took the size class out of `expect_columns` so the table
scene would be byte-identical everywhere; the cost, paid on the iOS
slice, is that the iPad leg cannot say WHICH tier drew it. The two pad
legs beside it (menus, listdetail) each append a literal naming the
regular arm; the table pad leg has no such literal available, because
the design deliberately made the tiers indistinguishable. When a
design removes the discriminator on purpose, the only remaining proof
that a device took the arm you think it took is a ONE-ARM PERTURBATION
with the other device's leg watched staying green — — GATED SINCE 2026-08-21: tools/check-table-tier.sh compiles the
interpreter's own source with a probe that drives the extracted
routing function through its whole truth table, and a static clause
holds KayaTableSurface as the routing's only caller. What no gate can
hold is only whether a PHYSICAL device reports the size class the
simulator did; the one-arm perturbation remains the tool for that
question alone.

## A scene that asserts a BOUNDED absence is racing the machine, not checking the code (2026-08-21)

`tools/scenes/stall.steps` used to assert `expect_stall` twice: once
against the guests' 2500ms `block`, and once against the `wedge` that
never returns. The first one failed about 1 run in 11 on the android
lane, saying "the app thread is keeping up" — which reads as a broken
watchdog and is not one.

THE ARITHMETIC. A stall is PENDING WORK the consumer has not touched for
`KAYA_STALL_MS` (1000ms). The pending work is the harness's second
click, so the leg passes only while

    gap(click#0 -> click#1) + 1000ms  <  the guest's block

and that gap is the harness's own two round trips through the UI thread.
IT GROWS WITH THE MACHINE. Measured on the compose leg: 404-595ms idle,
518-718ms under 6 burners, and 1823/2542/2840ms under 24 — the 2542ms
run failed, with the ping landing after the block had already ended, so
no occurrence was ever pending while the app thread was away and there
was nothing for the watchdog to report.

NO HARNESS-SIDE FIX REACHES IT. Bounding `kayaAwaitAnswer` by wall clock
(it was `repeat(60) { Thread.sleep(5) }` — "300ms" that measured 2400ms
under load) moved the mean gap from 2401ms to 1770ms and no further: the
two UI-thread round trips are what a click genuinely costs. Latching the
reading on the harness side does not help either, because in the failing
case the episode NEVER HAPPENS and there is nothing to latch.

THE SHAPE THAT WORKS: assert the report only of an absence that never
ends. The wedge blocks for a day, so the click it strands stays pending
for as long as the assertion needs and there is no window to miss. The
bounded block keeps the two claims that do not race — it came back and
nothing was dropped (`expect label#0 "pinged"`), and the watchdog took
its reading back (`expect_no_stall`). Reshaped scene under 32 burners:
5/5 PASS, including gaps of 2751ms and 2889ms that were guaranteed reds
before. Both directions watched failing with the watchdog perturbed —
`Verdict::Stalled` storing nothing gives "the app thread is keeping up",
and a `pending`/`claimed` pair blind to the consumer gives "the stall
watchdog reports 7391ms of unclaimed occurrences about an app that is
answering this scene".

DO NOT PUT `expect_stall` BACK ON THE BLOCK. The only way to make a
bounded absence assertable is to stop it being a wall-clock sleep — the
guest would have to end the block on the watchdog's own report, which
needs a guest-visible stall reading in all 8 bindings (the C floor
already exports `kaya_stalled_ms`).

## Restoring a perturbed file with its MTIME leaves the perturbation in the artifact (2026-08-21)

The perturb-restore doctrine says restore from a saved copy, never from
git. `shutil.copy2` is the obvious way to make that copy, and it is the
wrong one: it carries the metadata, so the restore puts the ORIGINAL
mtime back, cargo compares it against the fingerprint written by the
PERTURBED build, decides nothing changed, and skips the rebuild. The
tree is clean, `git status` is empty, the source hash matches — and the
binary still holds the perturbation. The next leg then measures the
perturbed build and is believed.

Caught by `tools/build-id.sh --verify` inside the build step, which is
the wall nobody can walk around: "STALE — carries 43093e27a31a1da0, but
core in this tree is b1893d607e72a221". Without it the "restored
baseline" run would have been the perturbed one.

Restore with `shutil.copyfile` plus `os.utime(path, None)`, and keep the
verify in every perturb loop that rebuilds anything.

## A cache self-test outside its own key can still invalidate Cargo (2026-08-23)

`check-keyed` used `crates/.keyed-probe` (gone) to prove that changing a path outside
the fixture gate's input set leaves its key stable. Creating and removing that
one file left the tree byte-clean but advanced the top-level `crates/` directory
mtime. The core build script declares that whole directory with
`rerun-if-changed`, so the next matrix rebuilt every core target. On Windows
that became 13s of target checks, 53s of release builds and 45s of test builds;
the relink changed the same 41 of 288 deploy artifacts, missed the combined
deploy stamp and paid another 42s for the source rebuilds on the guest.

The timestamp identified the writer exactly: a 494s gate sweep began at
18:35:34, `check-keyed` occupied its +310s window, and `crates/` moved at
18:40:46.551 while no file below it had moved after 18:00. An outside-key probe
therefore lives under ignored `target/`, which is outside both the fixture's
declared inputs and every shipped artifact's source set; `check-keyed` refuses
any other root before it creates the file.

## A deep worktree makes deploy-win.sh unreachable, and the error names ssh

`tools/deploy-win.sh` multiplexes over
`ControlPath=$ROOT/target/.ssh-mux-%r@%h`, and `$ROOT` comes from `$0`. From
a `.claude/worktrees/wf_<id>` checkout that socket path is EXACTLY 104 bytes —
one over the unix-socket limit — and every ssh in the lane refuses with
`ControlPath too long (… >= 104 bytes)`. The deploy exits 255 immediately after
`TIMING build`, i.e. after a full cross-compile, having never touched the VM,
and nothing in the message mentions the worktree.

`$0` decides `$ROOT`, so the fix moves no file: symlink the worktree somewhere
short and invoke the script through it —
`ln -s <worktree> /tmp/kw && nix develop -c /tmp/kw/tools/deploy-win.sh …`
(socket path 42 bytes). `probe=<exe>` confirms the route in seconds.
Measured 2026-08-21.

## GNU grep in a UTF-8 locale cannot read a windows lane log

A fault or panic sentence that carries a Rust `Debug` dump reaches the windows
console through a codepage that mangles non-ASCII — kaya's `op_head` truncates
with `…`, which arrives as an invalid byte. `file` then calls the log
`Non-ISO extended-ASCII`, and:

  grep -aq "applying .* failed: .*0x8000FFFF" win.log   -> rc=1  (the line IS there)
  LC_ALL=C grep -aq "applying .* failed: .*0x8000FFFF"  -> rc=0

`.` will not match an invalid byte in a UTF-8 locale, so a pattern SPANNING the
mangled character misses a line you can read plainly; `-a` does not help,
because the problem is the locale, not the binary classification. (ugrep, which
the interactive shell wraps with `-I`, skips such a file outright — so the same
command can answer differently in a script and at a prompt.)

EVERY read of a windows-lane log is `LC_ALL=C grep -a`. Measured 2026-08-21,
when a watched negative's own verdict logic printed "DID NOT FIRE" twice for a
negative that had fired perfectly — the "a guard you have never seen fail"
failure arriving from the checking side.

## A stretched WinUI TextBlock arranges text-sized — its box does not exist

Stamp `HorizontalAlignment::Stretch` on a TextBlock in a 457dip Grid cell
and its `ActualWidth` answers 12.5 — the text — while the Button beside it,
same stamp, same cell, answers 457. Measured 2026-08-22 on the windows
guest (the probe printed `ha=HorizontalAlignment(3) desired=13x19
actual=12.5x18.6` for the label and `desired=54x32 actual=457x32` for the
button): a Control's template fills its arrange rect, but a content-sized
element like TextBlock returns its used size from ArrangeOverride, so
RenderSize — which ActualWidth reads — is the text whatever the slot was.
The pixels are IDENTICAL to a start-aligned label (text at the slot's
start), so no screenshot separates them either.

Consequence: any measurement that means "the child's box" cannot read
ActualWidth for such elements. The stretch classifier (winui/mod.rs
cross_mode) reads the RESOLVED alignment for the box under Stretch — the
lowering's own output, loud on regression because the un-stamped WinUI
default is Stretch, which reddens every center/start scene rather than
passing one. First bitten: the align scene's stretch legs classified
"start" on windows alone while expect_fills on the same container passed,
because the container (a Grid) spans for real and its label child does not.

The second reader bitten, same day: expect_fills' WIDGET arm — a
TextBlock in a 124dip star column reported 13. Both readers now share
one rule in `drawn_extent` (winui/mod.rs): under a RESOLVED Stretch the
box is the slot, CAPPED by a declared Width/Height — the cap is what
keeps the verb falsifiable, since kaya stamps the main axis Stretch on
every flex child and an uncapped slot-read could never fail, while the
textarea's 96dip-in-126dip case is the verb's founding subject. And the
same red's other conviction: nothing had stamped the main axis at all,
so a Button in a 372dip star track drew 57dip — the reindex stamp now
writes main-axis Stretch on every flex child (identical for Auto
tracks, the grower's box for star ones).

## A restored copy that preserves mtime runs the PREVIOUS binary

`shutil.copy2` (and `cp -p`) preserve modification time; cargo's
rebuild check is mtime-keyed; so a perturb-restore cycle that copies
the good file back CAN leave the tree textually perturbed-then-restored
while every subsequent "rebuild" reuses the artifact from BEFORE the
perturbation. Measured 2026-08-22 during the GTK spacing fix's watched
negative: the perturbation printed its substitution count correctly,
the probe ran, and it reported PASS — because the binary under test
predated the perturbation. The count was right and proved nothing.

The guard, both halves: `touch` the file after EVERY write in a
perturb-restore cycle (perturbation and restore alike), and refuse any
watched-negative verdict whose build log does not show the crate
actually recompiling (`Compiling kaya` for this repo). A watched
negative is only watched if the thing that ran contains the
perturbation — the build's freshness is part of the proof, not
plumbing. The same session's WinUI sibling fix carried the guard from
the start (the Compiling line is quoted in the ledger's strike note).

## A sixth compile unit can starve Android past both its duration ceiling and first draw

Measured 2026-08-23 after the dynamic-table sweep grew to 42 gates. The
optimized Android lane was 142s standalone (Compose/JVM/Go legs
49/32/36s), then passed all 112 legs in the matrix but took 373s against
its unchanged 310s ceiling: the same blocks were 118/99/107s. Its three
builds stayed cached at 0.13-0.15s, no accessibility arm retried and no
device rebooted. The 427s gate sweep overlapped every block at ordinary
priority, so the slowdown was host scheduling across the whole lane,
not work added to one guest or one picker. The iOS export admission was
healthy on its first attempt and ended at the front of its lane; it
cannot explain three equal deltas through Android's end.

Niceness was necessary and NOT sufficient. It moved Android 373 -> 339s
(blocks 108/90/91s) and left the sweep green at 467s. Linux's container
VM was sampled at about 495% CPU, but lowering its pool from eight to six
falsified that as the remaining lever: Android moved only 339 -> 333s
while Linux moved 371 -> 419s. The eight-job balance stays. A later
nice-only matrix still took Android 338s and exposed the startup boundary:
`clipboard-compose`'s first five-second label wait began before a real
frame; launch took 6.774s, HWUI logged a 4682ms Davey frame and 234
skipped frames, and display landed only 10–23ms before expiry. Its other
21 assertions passed, so this was admission plus CPU starvation, not
clipboard behavior.

Compose now starts the harness from a one-shot decor-view pre-draw.
The first barrier-only matrix proved the sixth unit was not the whole
remaining cost: every Android leg passed, gates waited and then passed in
218s, but Android took 311s/310. Its phase sum accounted for every second
(preflight 3, boot 18, helper 17, Compose 103, JVM build+legs 2+68, Go
build+legs 4+96); broad five-platform host share was the residual, not a
hidden wait. Nicing the four sibling runner shells was falsified next:
Android worsened to 316s while only the directly spawned mac lane moved
materially (325 -> 338s); Docker, CoreSimulator and UTM work is
daemon-launched and does not reliably inherit the wrapper's niceness.

The saved three-phone log made the bounded lever arithmetic: phone-leg
service demand was Compose/JVM/Go 228/174/232s. The same submission order
has greedy makespans 80/59/84s on three slots and 61/47/64s on four,
projecting the lane near 266s with measured non-pool overhead. The stable
runner and environment-probe default is therefore four phone emulators,
not a matrix-only override; changing it back to the live-red three is a
watched perturbation.

The pool alone was then falsified under the real host share: standalone
four-phone phases were 3+9+11+40+2+27+2+32 = 126s, while an all-five-at-t0
matrix made the same green 112 legs take
3+22+31+102+6+81+4+101 = 350s. The other lanes and delayed gates all
passed (332/384/414/454/208s); only Android crossed its unchanged 310s
ceiling. Reserving merely boot+helper projects 317s and cannot clear it.

A staged experiment reserved Android through the drained Compose suite
before admitting macOS, Linux, Windows and iOS. Its bounded arithmetic was
63s for that standalone prefix plus the measured 192s contended JVM/Go
suffix, projecting 255s. That was a projection, not a passing matrix
result, and the experiment was rejected: it violated the ratified rule
that all five platform lanes launch together. Its atomic
`compose-complete` token and sibling barrier are not matrix doctrine.

The runner now carries two bounded work removals that do not change that
doctrine. First, its former 38 Compose, 36 JVM and 38 Go legs each ran
`adb install -r` on their suite's SAME APK. The measured artifacts in
the current tree are 111095703, 64911093 and 74364739 bytes respectively:
112 installs transfer 9.384 GB. Installing once after each verified build
on every device that can claim that suite is 5 Compose installs (four
phones plus the tablet), 4 JVM and 4 Go: 13 installs and 1.113 GB, removing
99 replacements and 8.272 GB. This is not a clean-data boundary — `-r`
preserves app data, and the exact-package force-stop already supplies the
per-leg process boundary.

The retained evidence bounds the time claim separately from the byte
census. Nine `target/validate-failures/android-*-buffers.log` files were
read per file, then overlapping install events were deduplicated by their
full `installer_clear_app_data_caller` line. From the preceding
`am_proc_died` to that install commit, the Compose/JVM/Go samples numbered
646/563/563, with medians 0.734/0.884/0.804s and means
1.114/1.735/1.019s. Commit to the next `wm_create_activity` or
`am_proc_start` numbered 702/622/608, with medians
0.064/0.097/0.079s. Removing the repeated installs projected about 88s of
median or 143s of mean aggregate device-slot work, roughly 22-36s over four
phones. The implementation stages only after build-id, icon and asset
verification, disarms the target package immediately before replacement,
refuses a missing/duplicate target or verdict, and admits no suite leg
until every eligible device passed. Per-leg install is forbidden by the
same executable guard.

Second, every suite formerly drained the phone pool, reselected the helper
IME on all four devices, ran its one ranges leg, and drained again. In the retained
350s log the measured phone-leg sums were 309/262/332s; assigning those
same recorded durations greedily in submission order with no ranges
barrier gives 86/67/87s, against the observed 102/81/101s phases. The 44s
gap is an UPPER BOUND, not promised savings: those phases also contain
control and adb overhead. What the source proves is the serialized tail:
ranges-compose was 15s; ranges-jvm was 5s before a separate final
three-leg wave whose maximum was 5s; ranges-go was 4s before editor-go's
9s. The worker now claims one device slot, reselects that exact device's
IME, and retains the slot through `run_apk_on`, allowing the other devices
to keep working; ranges and editor share each suite's one final drain.
`tools/lib/android-leg-order.py` holds both topologies and watches every new
branch red with a counted perturbation.

The first optimized default four-phone standalone run passed all 112 legs
in 105s: preflight 3 + boot 8 + helper 11 + Compose 35 + JVM build/legs
2/21 + Go build/legs 2/23. The prior four-phone baseline was 126s and the
rejected five-phone experiment was 141s. This establishes the runner
change, not the scheduler: no accepted all-at-t0 matrix had yet run on it.

The accepted scheduler therefore still launches all five platform lanes
concurrently, keeps the stable four-phone Android default and the 310s
ceiling, and waits for Android's recorded pid before starting the one gate
sweep at niceness 10 while longer lanes continue. The 350s all-at-t0
measurement means the Android duration anomaly remains open; there is no
final matrix pass on this scheduler. `tools/check-gates.sh` must reject a
future platform launch moved behind Android admission as well as drift in
pool width, pid provenance, single-sweep shape or niceness.

The first optimized-runner attempt under that scheduler, 2026-08-24,
passed every scene assertion and the gate sweep: mac 320s/329, Linux
474s/580, Windows 533s/191, iOS 493s/106, Android 268s/112, gates 348s;
619s wall. `validate-all` still exited 1 because Linux exceeded its
ceiling by 4s and Windows by 13s. The overages were not a per-leg blast
radius: Linux spent 96s in its cold core build and 366s in 580 green legs,
with both portfolio legs at 1s; Windows spent 75/47/65s in fresh
build/deploy/unit-test phases and 310s in 191 green legs, none over 26s.
Android is now positively measured below 310s, but there is still no
accepted ALL PASS record on these removals. Thermal state and unrelated
application load were uncontrolled variables, not measured causes.
