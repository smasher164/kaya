# Deferred work ledger

The running inventory of punted items. Check things off here as they
land; add new deferrals with enough context that a future contributor
(human or agent) can pick them up cold. DESIGN.md's open-questions
section is the architectural counterpart; this is the working list.
Landed history lives in git; this file only carries what is still open.
(Pruned 2026-07-23: the grow/spacing/align, dressed-floor, window,
scroll/nav breadth, matrix-speed, and backend-roster sagas landed and
moved to git history; their traps live in docs/traps.md.)

## Next milestones (in rough priority order)

THE NAMED FORCING ARTIFACT IS A **TEXT EDITOR** (Akhil, 2026-07-24).
This is a roadmap-selection decision, not a build order — the editor is
written once enough features exist. Its purpose is to resolve the
admission policy: this ledger is full of items that "wait for an
artifact", and until one is named those triggers cannot fire, so the
items sit unordered. Anything the editor needs is now trigger-SATISFIED
and can be scheduled on its merits; anything it does not need stays
gated. What it forces: file dialogs, clipboard, the edit roles
(cut/copy/paste, currently deferred past `settings`), undo/redo,
dirty-state window titles (the close veto already exists), and find.
Chosen over chat / todo / media on COMPOUNDING — those four features
are wanted by every other candidate app too, whereas media's are wanted
by exactly one, and todo is largely proven already by the `todos`,
`reorder`, and `feed` scenes. Two further reasons: the editor is the
field's standard litmus test for the text/IME stack, which kaya passes
by construction and has never demonstrated; and it forces undo/redo,
which core can offer far more cheaply than any framework that does not
own the state (see the undo note in this file).

- **Clipboard — LANDED ON MAC 2026-08-02, fan-out outstanding.** The
  protocol, the SwiftUI arms, the Rust surface, the scene and the three
  edit roles are green on the mac lane; docs/clipboard-plan.md §1-§3
  record what each slice decided and what the probes overturned. WHAT
  REMAINS: the seven other bindings, the GTK/WinUI/Compose/iOS arms,
  and the Android helper APK that gives that lane a foreign reader.
  The edit roles are no longer deferred — `cut`, `copy` and `paste`
  joined the closed role vocabulary beside `settings`.

  The original entry follows, for the reasoning it carries.

- **Clipboard** — the next editor prerequisite, and the one that
  unblocks the most: the edit roles (cut/copy/paste) are inert without
  it, while undo/redo, find and dirty-state titles do not depend on it.
  THE DESIGN IS WRITTEN: docs/clipboard-plan.md §0, with the reasoning
  and, for each decision that replaced an earlier answer, the answer it
  replaced. Four things worth knowing before opening it:
  - the clipboard is ONE CLIP IN SEVERAL REPRESENTATIONS on all six
    targets, so a text-only surface is a misstatement of it rather than
    a simplification;
  - COPY TAKES A RECORD AND PASTE RETURNS A SUM (you offer many, you
    receive one), which makes "at most one per kind" structural instead
    of a runtime check;
  - ACCEPTANCE IS PER-WIDGET, not app-global, because whether Paste is
    live is the intersection of what the clipboard offers and what the
    focused target accepts — which is exactly what the platforms
    already ask the focused responder;
  - files on the clipboard ARE the file-dialog capability, so a picked
    file goes straight on and a pasted one opens with the call that
    already exists.
  Four probes stood between the plan and any code (§0d); all four have
  reported, and §0e/§1b record what they found — including the two
  assumptions they overturned (Weston has no clipboard at all, and
  macOS does not prompt).
- **GAP — the stall diagnostic DESIGN promises is not implemented.**
  DESIGN's threading section says it comes free from the transport:
  "the core reads the app's log-consumer cursor, and undrained for N
  seconds is the health signal". Nothing in crates/ reads that cursor,
  so today an app thread stuck inside a handler is INVISIBLE — the
  window keeps drawing while input silently stops.
  WHAT MAKES IT WORTH BUILDING (2026-07-28): the background sweep found
  Haskell's release using `putMVar`, which BLOCKS when the MVar is
  full, so a second click would have blocked the app thread forever.
  The scene clicks once, so no gate saw it; Akhil found it by asking
  whether Go's `close` blocks. That is the general class — a handler
  that blocks — and it has no gate at all. The stall signal IS that
  gate, and it would also catch the misuse the file-dialog design
  explicitly permits (a guest calling the blocking open on the app
  thread), turning "the app looks alive and ignores you" into a
  reported fault. Wire it into the harness so a scene FAILS on a stall
  rather than timing out.
  DEPTH SLICE LANDED 2026-07-31: crates/kaya/src/stall.rs, the
  `expect_stall` verb in all three interpreters, the `stall` scene, and
  the Rust guest on mac + linux + windows. Matrix ALL PASS at 841 legs.
  THREE THINGS THE SLICE TAUGHT, all of which cost a lane run each:
  - **The cursor is not the signal, the COUNTERS are.** DESIGN says the
    core reads the app's consumer cursor, and the occurrence ring has
    one — but the ring is only ONE of two transports. The Rust binding's
    own path is an mpsc channel (lib.rs sets `OccSink::Mpsc`), so on mac
    and iOS nothing ever moves a ring cursor and the first watchdog
    reported "keeping up" about an app that was provably asleep. Two
    counters (enqueued, taken) say the same thing about either.
  - **Nothing may start from an entry point.** It was started from
    `kaya_run`, which is one of three entries — `kaya::run` reaches
    `swiftui_host::run` and `backend::run_core` directly. Every Rust
    guest on every platform ran with no watchdog. It now starts itself
    from the first enqueue, which no path can avoid.
  - **A stall needs PENDING work to be visible, and that is correct.**
    The consumer cursor advances before a record reaches the guest, so a
    handler blocking on an empty ring is indistinguishable from an idle
    app — and nothing is waiting on it, so it may as well be. The scene
    therefore clicks twice, which is also what a person does.
  BREADTH SWEEP COMPLETE 2026-08-01. All eight guest languages, every
  runner: mac (8 languages), linux (7), windows (5), iOS (rust + swift),
  android (compose + jvm). `stall` graduated out of DEPTH_SCENES on all
  three desktop runners. Matrix ALL PASS at 868 legs, green on the first
  try — the watchdog being core-side meant the sweep was guests and
  runner wiring only, with no backend arm anywhere.
  WHY EVERY LANGUAGE AND NOT JUST RUST: the misuse is available in all
  of them, and it is the one discipline no gate enforced — each guest's
  "do the blocking work on a worker" comment was honour-system until
  this scene existed. A diagnostic that only fired for Rust guests would
  have left seven bindings exactly as blind as before. Each leg is also
  self-verifying: a guest whose block does not block reports no stall
  and FAILS, so a passing leg is evidence that language really did wedge
  its app thread and that kaya really did notice.
  AND THE NEVER-RECOVERS HALF, added the same day: a third button whose
  handler never returns, asserted LAST because nothing can follow it. A
  handler that blocks for 2.5 seconds is a SLOW handler, and every
  assertion in the first half would also pass for one; a real deadlock
  does not politely end. Two findings from it:
  - **The verdict has to be final.** `finish` prints the verdict and
    asks the MAIN thread for an orderly exit, which is what normally
    ends the process. But an app thread that never returns cannot take
    part in shutdown — the cleanup would have to run on the thread that
    is gone — and five of the eight bindings then hung at exit waiting
    for it (python, go, csharp, ocaml, haskell; rust and java exited
    fine). Every assertion passed and the legs still burned their whole
    180-second timeout. No framework can fix that: there is nowhere
    left to run the cleanup. The harness now waits a grace period after
    `finish` and then leaves under its own verdict, so the normal path
    still wins everywhere it works.
  - **The settle before the second stall is load-bearing.** The
    watchdog clears its reading when the queue drains and polls at
    100ms, so without a pause the second assertion could be satisfied
    by the FIRST stall's leftover reading. Negative-tested: with the
    wedge made a no-op the leg fails, so it cannot pass on the stale
    value.
  ONE CHARACTERISTIC WORTH KNOWING, seen 2026-08-02: the watchdog fired
  inside `commands_csharp` on the windows lane, which has nothing to do
  with stalls. The leg passed 3/3 when run alone and failed under the
  4-wide pool, so the app thread was STARVED by contention rather than
  blocked in a handler — and from outside those look identical, because
  both are "nobody took the queued occurrence for a second". The report
  is diagnostic and failed nothing on its own (the leg's own assertions
  timed out), but a reader who sees it under load should suspect
  scheduling before suspecting a handler. KAYA_STALL_MS raises the
  threshold if a lane ever needs it to.
- **GAP — a kaya app cannot do background work.** Found 2026-07-28
  while designing file dialogs, and it is the reason that design kept
  contorting. There is NO way for a guest thread to get back onto the
  app thread: `App` is not thread-safe (Go's `Build` has a re-entrancy
  panic but no lock, and its maps are unsynchronized), no binding has a
  post primitive (grepped, all eight), and the app thread's only wake-up
  is `kaya_wait_occurrences`, blocked in C. So a guest that opens a file
  over the network, reads 2 GB, or calls an HTTP API either blocks the
  app thread — where the window keeps drawing but input stops doing
  anything, which is the worst possible failure because it LOOKS alive —
  or does it on its own thread and then cannot write the result into a
  signal. Without this, features whose result arrives late have to be
  designed in continuation-passing style, one callback per step, which
  is designing around the hole rather than fixing it.
  DEPTH SLICE LANDED 2026-07-28 (`c8a7ae1`, `1dc01c0`, `6f18896`,
  `0f65315`), validate-mac ALL PASS at 202 legs. `kaya_wake` rings both
  waiting paths; Go got `App.Post` with a drain-poll-wait loop; Rust got
  `Poster`, which must be a SEPARATE Send+Sync handle because `AppCtx`
  holds `Cell`/`RefCell` and is deliberately `!Sync` — making it
  shareable would legalize the danger rather than remove it. Closures
  never cross the C ABI: the floor says only "wake up".
  SWEEP LANDED the same day: all EIGHT languages post, each parking in
  its own idiom (channel, Event, DispatchSemaphore, ManualResetEventSlim,
  Mutex+Condition, MVar, CountDownLatch, mpsc), and the background scene
  runs in all eight on mac. Two finds the sweep paid for: the byte-path
  bindings (Python, Swift) would have RE-PARSED THE PREVIOUS RECORD on a
  wake, since they decoded the buffer whenever the size was non-zero —
  latent until they got a post; and Haskell's release used `putMVar`,
  which BLOCKS when full, so a second click would have blocked the app
  thread forever (`tryPutMVar` now). OCaml's release takes a bounded
  lock, the only one that does, and says so.
  COMPLETE 2026-07-28, matrix ALL PASS at 808 legs across all five
  lanes (up from 779). NINE languages including the C floor, which is
  where queue-plus-wake is written out rather than hidden behind a
  `post` — and which found a defect no sugar binding could: C queues
  DATA where every other language queues a CLOSURE, so one queue cannot
  carry two destinations, and the first version wrote every posted step
  to the wrong signal. Each entry now names its own target.
  Two things the slice cost that the plan did not predict: the wake
  CANNOT be gated by a scene (after the release click the app thread is
  freshly awake, so re-entering the wait before the worker posts is a
  genuine race), so it is a `cargo test` that spins on a new parked-count
  observation; and a public `Occurrence::Woken` variant was the wrong
  shape, because guests match that enum exhaustively — it is a
  `pub(crate) enum Inbox` instead. This unblocks file dialogs
  (docs/file-dialogs-plan.md), clipboard, notifications, and the
  editor's own reads.
- **DEFECT — Go silently drops a write to a closed transaction.**
  `Tx` carries a `closed` flag and the Widget/MenuItem chain methods
  check it, but `tx.Write` and `tx.Signal` do not: they append to
  `tx.records`, a slice `Build` has already submitted and will never
  submit again. The write vanishes with no panic and no error. Today it
  is nearly unreachable because nothing invites a guest to hold a `Tx`
  past its handler; the post primitive above is exactly that invitation,
  so this must be fixed WITH it.
  FIXED FOR GO AND RUST 2026-07-28. Go routes all 109 append sites
  through one `Tx.emit` (plus `Tx.mirror` for model reads), so the
  liveness check cannot be missed at a new callsite, and a test asserts
  exactly one direct append survives. Rust's compile error is pinned by
  a `compile_fail` doctest on `Tx<'static>` — `'static` deliberately, so
  it cannot pass for failing some unrelated `'static` bound — paired
  with a PASSING assertion that `SignalId` and `WidgetId` are `Send`,
  because a compile_fail that dies of an unrelated error pins nothing.
  PYTHON NEEDED ITS OWN SPELLING, added with the sweep: its ambient `_tx`
  is a module GLOBAL, not thread-local, so a background
  `with app.build():` would stamp records into the app thread's open
  transaction, silently interleaved. It has no handle to check, so it
  checks the THREAD — `_require_app_thread` raises and names `app.post`
  as the fix. Signal writes needed no new guard: outside a transaction
  they already raise.
  CLOSED 2026-07-31 for the remaining five, and the sweep found that
  the languages split in two rather than one rule fitting all:
  - **HANDLE bindings** hand the guest a transaction object, so a stale
    one can be refused. C# and Swift needed NO callsite changes at all —
    every write already went through one member (`Records.Add(...)` in
    C#, `tx.<verb>(...)` in Swift), so making that member a PROPERTY
    that checks liveness first guards all ~100 and ~90 of them, and
    guards the next one written. Java has no properties, so it took
    Go's shape: 109 direct appends routed through one private `emit`.
  - **AMBIENT bindings** keep the open transaction in a global, so
    there is no handle to invalidate — a background build would stamp
    into the app thread's transaction (OCaml) or race its IORefs
    (Haskell). Both check the THREAD at the build entry, which is
    exactly Python's `_require_app_thread`, so the three ambient
    bindings now spell the rule identically.
  THE GATE IS `tools/check-tx-liveness.sh`, in validate-mac: it pins
  that each guard exists, that each chokepoint is still the ONLY way in
  (exact counts, not "at most"), and that every message names the post
  as the way out. Five negative tests, and the first draft of the gate
  FAILED three of them — grepping a bare function name matched the
  definition as well as the call, so the ocaml and haskell clauses
  passed with the call deleted. Bounds that say "at most" hide the
  extra write they are meant to catch.
- ~~**DEFECT — the iPad menu lowering is wrong as of iPadOS 26**~~ —
  FIXED 2026-07-25, checked off 2026-07-27. As filed (2026-07-24): kaya
  routed the entire catalog into a trailing More overflow on every iOS
  host — `KayaPhoneMenuToolbar`, gated `#if os(iOS)` — so a full
  command catalog hid behind a phone affordance while iPadOS 26's own
  menu bar sat empty.
  WHAT ACTUALLY SHIPPED: `KayaPhoneMenuToolbar` is gone. The arm is
  chosen by `KayaMenuFormFactorChrome`, which reads the live horizontal
  SIZE CLASS — regular takes the system menu bar, compact the toolbar —
  and the bar itself is driven through `UIMenuBuilder`
  (`kayaBuildCatalogMenus`), not SwiftUI's `.commands`, because
  CommandsBuilder has no `buildArray` and cannot express an
  append-at-any-time number of top-level menus. The menus-swiftui-pad
  leg asserts `expect_menu_presentation "regular/bar"` and passes; that
  literal reports `regular/overflow` if the arm choice ever regresses,
  which is precisely the original defect.
  WHY IT SAT HERE TWO DAYS AFTER BEING FIXED, and the lesson: the entry
  below ("the iPad menu bar's gate is OWED") recorded the fix in
  passing — "the lowering LANDED and is confirmed working" — while THIS
  entry, the one titled DEFECT and sorted to the top of the file, was
  never touched. A fix recorded in a neighbouring entry is not recorded.
  Worse, on 2026-07-27 an audit of this very file repeated the stale
  claim into the form-factor entry below, because it trusted this text
  instead of grepping for the symbol it names. WHEN AN ENTRY NAMES A
  SYMBOL, GREP FOR IT — that is a two-second check and it is the whole
  audit.
  THE TRAP WORTH KEEPING: the ledger already carried an iPad item, but
  its trigger was "an artifact running on iPad with a keyboard", framed
  around `UIKeyCommand` HUD exposure — the pre-26 framing, when a
  keyboard was the only route to commands on iPad. That trigger can
  never fire for the thing that now matters (a plain iPad, no keyboard,
  with a menu bar). A trigger written against a platform's CURRENT
  shape expires when the platform moves; triggers naming a platform
  capability need a re-read date, not just an artifact.

- **The iPad menu bar's gate is OWED, and the accessibility milestone
  pays it** (2026-07-25). The lowering LANDED and is confirmed working
  — visually, on an iPad Pro simulator: swipe down and the kaya catalog
  is there in the system menu bar. What is missing is an automated
  observation, and the reason is structural, measured, not assumed:
  the iPadOS menu bar is built LAZILY. `buildMenu(with:)` runs exactly
  ONCE, at launch, with an empty catalog, and never again no matter how
  many times `UIMenuSystem.main.setNeedsRebuild()` is called (traced:
  10 rebuild requests, 1 build). UIKit defers the build until the bar
  is about to be PRESENTED, the bar stays hidden until a swipe or
  hover, and UIKit exposes NO way to present a menu programmatically
  — so a headless scene structurally cannot witness the build.
  CONSEQUENCE, recorded in the code too: on iOS-regular alone, the
  presentation half of `expect_menu_presentation` is ARM-DERIVED — it
  reports the lowering the window selected, not a reading of rendered
  chrome. Every other backend still reads its real chrome. So the verb
  can catch a regression in the ARM CHOICE (which is what the original
  defect was) but NOT one in the build.
  THE SCHEDULED FIX DOES NOT WORK — MEASURED 2026-07-25, after the
  accessibility milestone landed. This entry used to say "a menu bar is
  an accessibility element, so the AX-tree verb restores an independent
  read". It does not. Dumping the iPad's own accessibility tree from
  inside a running menus scene (61 nodes, on an iPad Pro simulator)
  finds the scene's widgets and a `UIKitNavigationBar` and NO menu-bar
  element of any kind. That is consistent with the laziness measured
  above rather than a separate surprise: `buildMenu` ran once at launch
  with an empty catalog, so there is nothing built for the tree to
  carry. The read machinery itself is fine — the same dump resolved a
  widget by its authored id in the same run.
  There is also a structural mismatch worth stating: `expect_ax`
  addresses a WIDGET target through its authored `a11y_id`, and the
  menu bar is not a widget in kaya's model, so even a tree containing
  it would want a different verb shape.
  `UIMainMenuSystem` WAS TRIED AND DOES NOT DELIVER — MEASURED
  2026-07-26, on an iPad Pro simulator, iOS 26.5 runtime and SDK. iOS
  26 added `UIMainMenuSystem.shared.setBuildConfiguration(_:buildHandler:)`
  specifically for this menu bar, and its header promises exactly what
  this entry wants: the handler is used "instead of calling
  `-buildMenuWithBuilder:`", and "setting this will invalidate and
  rebuild the main menu system". That reads like an on-demand build,
  which is the one thing the responder path cannot do. It is not what
  happens. Registered from
  `application(_:didFinishLaunchingWithOptions:)`, the trace from the
  menus-swiftui-pad leg reads:

      didFinishLaunching ran
      setBuildConfiguration returned      (no assert, iOS 26 available)
      buildMenu roots=0                   (the RESPONDER path, still)
      rebuild requested  x10              (and no build follows any)

  So the call succeeds, the handler is NEVER invoked — not on set, not
  on ten setNeedsRebuild calls — and it does not replace
  `buildMenu(with:)` as documented. DO NOT SWITCH THE LOWERING TO IT:
  the responder path is the one that actually builds the bar today, and
  adopting the documented-but-inert API would trade a working menu bar
  for a silent one.
  WHAT IS ACTUALLY LEFT: nothing automated, in-process or out. An
  out-of-process client (XCUITest) sees only what is presented, and
  UIKit exposes no way to present the bar programmatically — a human
  gesture is the only trigger. Independent corroboration: an Apple
  developer forum thread on UI-testing iPadOS 26 menu bar items reports
  the same absence, that menu items do not appear in the
  XCUIApplication element tree on iPadOS while the identical test works
  on macOS. So on iOS-regular the presentation half stays ARM-DERIVED,
  the bar's correctness rests on the visual confirmation recorded
  above, and this entry is a RE-READ ITEM, not a scheduled fix. The
  re-read trigger is now SHARPER than "when iPadOS exposes something":
  re-check when `setBuildConfiguration`'s documented invalidate-and-
  rebuild actually fires, since the API to make this work already
  exists and only its behavior is missing.
  `KAYA_MENU_TRACE=1` is left in the interpreter, env-gated — it is
  what proved the laziness and will be wanted again.

- ~~**GTK's collapsed list-detail pane has NO back affordance, and back
  pops anyway**~~ — FOUND AND FIXED 2026-07-27, by screenshotting the
  collapsed window. The split arm hid kaya's own header back button for
  the WHOLE presentation, on the stated belief that "collapsed,
  libadwaita draws its own inside the navigation view". It does not:
  libadwaita draws that button only inside a header bar IT owns (an
  `AdwHeaderBar` in the page, normally via `AdwToolbarView`), and
  kaya's `AdwNavigationPage`s wrap the raw scene root. `back` then
  activated `navigation.pop` on the split view directly, consulting no
  affordance, so it popped where the user had no button to press —
  the Compose divergence mirrored (that one popped past a DISABLED
  BackHandler, this one past an ABSENT button), and the same decision
  covers both.
  THE FIX: the split arm shows the button exactly when collapsed and
  the stack is non-empty, `back`'s split-view special case is gone so
  ONE path serves both arms, and a `notify::collapsed` handler
  re-drives visibility when the breakpoint flips — the shape WinUI
  needed for `ModeChanged`, for the same reason (the collapse settles
  during layout, not at the write that caused it). The two-pane rule
  now falls out of the same visibility test as everything else: two
  panes, no button, nothing to drive.
  WHAT MADE IT INVISIBLE, and the guard still owed: no verb asserts
  that an affordance is THERE. `split.steps` drove `back` at 360 and
  passed the whole time, because the verb was reaching past the screen
  to the widget. It now depends on the real button, so that assertion
  gates the affordance's presence — negative-tested: hide the button
  and the scene fails with `entries 1, wanted 0`. But that is a
  coincidence of this scene, not a rule. FOUR backends now implement
  "refuse where the affordance is absent" four times; an
  affordance-presence assertion (the `expect_ax` precedent — read the
  real tree, not a flag) would make it one. That is a protocol change,
  so it is filed rather than done.

- ~~**The phone lanes have no list-detail coverage**~~ — LANDED
  2026-07-27. The `listdetail` scene is the `split` scene's phone-safe
  sibling: no resize, no literal, just the BARE `expect_split`
  invariant, which is true at every width a lane can hand it. It runs
  on all five, and on two devices per phone lane, because a compact
  host satisfies the invariant vacuously and could only report that the
  stacked arm ran. The iPad leg it already had, and the Android lane
  now has a 1280dp `medium_tablet` beside its 320dp pool for the same
  reason and with the same scope: one device, one scene. Those two legs
  are the first and only ones in any lane to reach the SwiftUI and
  Compose split arms — the Compose one had never rendered under a test.
  THE DEVICE IS THE WIDTH, so it owes the rule a resize owes:
  run-emulator asserts each device's dp is outside the 400..840 band
  before running (the same tablet rotated to portrait is 800dp, and
  would fail the invariant for a reason that is not a bug).

- ~~**The list-detail arms use PLAIN containers, not the platforms'
  adaptive wrappers**~~ — LANDED 2026-07-27, all four. GTK's `Box`
  became `AdwNavigationSplitView`, WinUI's two-star-column `Grid`
  became `TwoPaneView`, Compose's `Row` became
  `ListDetailPaneScaffold`; SwiftUI already had `NavigationSplitView`.
  What that bought, itemized against what this entry said the plain
  containers cost: the collapse/expand ANIMATION, and each platform's
  own pane proportions and separators — `protocol::leading_pane_width`
  now has a single caller (WinUI, whose control defaults to the
  down-the-middle split no platform ships) instead of a Rust copy and a
  Kotlin one.
  THE INTEGRATION SUBTLETY resolved the way this entry predicted it
  had to: every wrapper is driven FROM the core stack and told the ONE
  fact it needs — is a detail open. `androidx...adaptive-navigation` is
  deliberately NOT a dependency, because its navigator would hold a
  destination history; `ListDetailPaneScaffold` takes a caller-supplied
  `ThreePaneScaffoldValue`, which is the whole reason it can be used
  without one.
  AND THE OBSERVATION MOVED WITH THE CONTAINER: `expect_split` now
  reads the wrapper's own arrangement on all three — `is_collapsed`,
  `TwoPaneView.Mode`, the scaffold's per-role adapted values — instead
  of a value the arm stamped about itself.

- ~~**Adaptive LAYOUT is the second form-factor surface, and it owns
  `resize_window`**~~ — LANDED 2026-07-26/27 as list-detail. `list_detail`
  is a window prop, all four backends lower it to their platform's own
  adaptive container, each decides where one pane becomes two,
  `resize_window` drives the real transition and `expect_split`
  re-asserts on the far side. The scene runs on three desktop lanes and
  its phone-safe sibling `listdetail` on all five, with a device per
  size class on the two that cannot resize.
  The REFRAMING this entry argued for is what happened, and is worth
  keeping: `resize_window` was originally filed as the menus
  milestone's gate, but a verb that drives a transition no code
  specializes gates nothing, so it shipped WITH the feature it gates.
  MULTI-COLUMN is the part of "adaptive layout" that did NOT land —
  this entry covered two surfaces and only list-detail is done. A
  regular window wanting several columns where a compact one wants
  one is still unbuilt, and it wants its own admission pass (the
  4/4 test list-detail passed is not automatic for a column grammar).
  Encouraging for admission: the adaptive split IS a 4/4 native
  intersection, unlike the DRAGGABLE splitter (2/4) it is easily
  confused with — SwiftUI `NavigationSplitView`, Compose's Material 3
  adaptive scaffolds (`ListDetailPaneScaffold`) driven by
  `WindowSizeClass`, libadwaita's `AdwBreakpoint` +
  `AdwNavigationSplitView`, and WinUI's `TwoPaneView` / NavigationView
  display modes and adaptive triggers. Every one is size-class-driven
  by design, which is exactly the axis now in place.
  (The presentation assertion this entry used to call open LANDED:
  `menus.steps:85` carries the bare `expect_menu_presentation`, the
  ASYMMETRIC INVARIANT — regular implies not overflow, true on every
  platform and exactly the original defect — with the reasoning in a
  comment beside it, and the iPad leg appends the exact
  `"regular/bar"` literal. What is still owed there is narrower and
  lives in the iPad entry above: on iOS-regular that assertion is
  ARM-DERIVED, so it catches an arm-choice regression and not a build
  one.)

- **Form factor as the adaptivity axis** (DESIGN's "Form factor and
  adaptivity", 2026-07-24). kaya keys adaptivity on PLATFORM —
  compile-time `#if os(iOS)`, and the compact-overflow rule written as
  desktop-vs-phone. The correct axis is the window's size class,
  resolved at runtime, per window. Every backend already has the
  concept and kaya uses none: SwiftUI's horizontal size class,
  Compose's `WindowSizeClass`, libadwaita's `AdwBreakpoint`, WinUI's
  adaptive triggers. Scope: a size-class notion in the core/window
  model, the four backend readings, re-keying the menus compact rule
  off `#if os(iOS)`, and the iPad `UIMenuBuilder` arm. The gate is
  already specified and already in this ledger — `resize_window` drives
  the size-class transition and re-asserts on the far side, which makes
  adaptivity a matrix fact instead of a claim. THE TWO ITEMS MERGE;
  do not schedule `resize_window` separately.
  THIS SCOPE IS SPENT — the item is DONE (corrected 2026-07-27, after
  the first pass got it wrong). Every backend reads its own size class;
  `resize_window` and both presentation assertions exist and run;
  list-detail is a second lowering obeying the axis, so "menus are the
  only one" stopped being true; and the menus rule is NO LONGER keyed
  on the platform — `KayaMenuFormFactorChrome` reads the horizontal
  size class, and the iPad `UIMenuBuilder` arm shipped with it. The
  first pass claimed the `#if os(iOS)` gate survived; it did not, and
  the claim came from reading the DEFECT entry above rather than the
  source.
  WHAT IS ACTUALLY LEFT is not this item at all: it is the OWED GATE in
  the iPad entry above — on iOS-regular the presentation half is
  ARM-DERIVED because the iPadOS bar cannot be observed headlessly.
  That is a re-read item, not scheduled work.

- **Window vocabulary** remainder (the rest LANDED through the
  window/panels/confirm/nav/sections scenes): presentation styles
  beyond the primary set (utility panels, always-on-top).
- **App-developer capability decisions** (raised 2026-07-23; each
  wants a design pass or an explicit v2 verdict, none is speculative
  protocol work):
  - **Styling tier 1 — the successor decision is MADE** (2026-07-24,
    DESIGN's "Brand identity and the styling ceiling"). The v1 stance
    stays zero *arbitrary* styling; what is admitted is two tiers.
    (a) SEMANTIC ROLES — destructive/prominent/plain on buttons,
    title/heading/body/caption on labels — the `role` grammar the
    menus milestone already built, reused verbatim. (b) A BRAND TIER
    of app-level slots (accent, typeface family, icon set), each of
    which every platform already exposes and expects apps to fill.
    Slots may take per-platform VALUES; the vocabulary stays uniform.
    What remains open under this heading, each a design pass:
    - The exact slot list and the four lowerings per slot. Carry the
      WinUI trap into the lowering: `SystemAccentColor` is NOT
      overridable (microsoft-ui-xaml#6394) — override the derived
      `AccentFillColorDefaultBrush` family in `ThemeDictionaries`.
      A lowering that sets `SystemAccentColor` compiles, runs, and is
      silently ignored, so this wants a gate, not a comment.
    - **Semantic icon names.** `icon` is a Blob today (sprop 2 /
      mprop 5), which is the wrong primitive for STANDARD icons: the
      platforms draw the same concept differently, and their symbol
      sets metric-match adjacent text while a blob cannot. Wants a
      small closed name set mapped per backend (SF Symbols / Material
      Symbols / Adwaita names / Fluent). The Blob stays for
      app-specific art. NOT a tinting problem — a single-color raster
      tints fine on all four.
    - **Vector/DPI story for the Blob** (separate from the above): all
      four decoders are raster-only today — `NSImage(data:)`,
      `BitmapFactory.decodeByteArray`, `gdk::Texture::from_bytes`
      (PNG/JPEG per its own comment), `BitmapImage::SetSource`. Android
      cannot be fixed by API choice: `VectorDrawable` needs a compiled
      resource, with no runtime inflate-from-bytes. A PNG shipped at one
      size is soft at 2x/3x and kaya has no multi-resolution story. The
      shape that fits kaya: rasterize SVG IN CORE with `resvg` — one
      renderer, byte-identical output on all five platforms, the same
      doctrine as the shared scene scripts, and it routes around the
      Android limit. Cost: core must learn the target scale factor,
      which it does not know today.
    - Typeface substitution must change the FAMILY only, never the
      scale (Dynamic Type / `sp` both break otherwise), which makes the
      role tier a precondition rather than an alternative.
  - ~~**Accessibility surfacing**~~ — LANDED 2026-07-25. Two universal
    props (`a11y_id`, `a11y_label`) in all 8 bindings plus the C
    floor, and `expect_ax`, which reads each platform's REAL tree
    (AXUIElement, UIKit's materialized elements, Compose's merged
    semantics, AT-SPI, UIA) over every widget kind on all five
    backends, byte-identical. See DESIGN's Accessibility section for
    the per-backend read table. The iPad menu bar's independent
    observation was expected to ride this verb and MEASURED NOT TO —
    see that entry, which is now a re-read item.
    THE HINT PROP LANDED 2026-07-25 (`a11y_hint`, spec prop 14): the
    activation kinds carry it — `.accessibilityHint()` on Apple, the
    click action's LABEL on Compose (measured: a label-only semantics
    node relabels a Material3 Button's action and KEEPS it), GTK's
    `Property::Description`, `AutomationProperties.HelpText` on WinUI —
    read back by its own verb `expect_ax_hint` and green on all five
    lanes. The root scopes it to button/checkbox/select/radio because a
    hint describes what ACTIVATING a control does and Android has
    nowhere to put one without an action; that domain is unit-tested
    both ways. Still open, trigger-gated: hints on the adjustable and
    editable kinds (slider, entry, textarea), whose Android route is a
    different action's label.
  - **Video widget**: unexamined — DESIGN has the surface-handle
    transport (the Canvas zero-copy arm) but no media-playback
    story. The wrap-native bet suggests a Video widget over each
    platform's native player (AVPlayerView / MediaPlayerElement /
    Media3 / GStreamer) before any frame-pushing pipeline.
    Trigger-gated on an artifact app.
  - Audio is NOT listed here: it is designed (core-owned RT callback
    + sample ring + node-graph vocabulary, DESIGN's Audio passage)
    and stays admission-gated on an app that needs it.
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
- ~~The suite runners screenshot AFTER teardown.~~ — CLOSED 2026-07-27
  by taking this entry's SECOND option: the ad-hoc per-leg captures are
  gone from run-emulator and run-sim, and the recording pipeline is the
  visual record (a still at every step, anchored to the harness
  transcript rather than to a guessed delay; `KAYA_RECORD=1`).
  The first option — move the capture earlier — was tried and measured
  three ways before giving up on it, which is the part worth keeping.
  On Android `am start -W` already blocks until the first frame
  (TotalTime ~420ms), the scene then reaches its verdict and exits
  ~300ms later, and screencap costs ~100ms of that: waiting 2s and 1s
  both produced wallpaper, and waiting 0s produced the launch SPLASH,
  before the scene had drawn. The real-UI window is narrower than the
  jitter around it. On iOS it was never a race at all —
  `simctl launch --console-pty` returns only when the guest EXITS, so
  every capture on that line was strictly post-teardown (50 of 51
  outputs were the home screen, 2.4MB each).
  IF THE SHOTS ARE EVER WANTED BACK, the deterministic hook is a
  linger: `record_linger` in harness.rs already holds the window 750ms
  after the last step under `KAYA_RECORD`/`KAYA_HARNESS_GATE`, and a
  third trigger would make a capture landable. That is core surface for
  a debug convenience, which is why it was not taken now.
- The C floor's grow/layout scenes, out on purpose: the floor
  documents the explicit wire; a separate exercise. (Map for the next
  layout prop, from grow's landing: native weights on WinUI — `Grid`
  star sizing — and Compose — `Modifier.weight`; constructed on GTK4
  — a custom `GtkLayoutManager` — and SwiftUI — a custom `Layout`.)
- **The versioned binding style guide** (DESIGN open question #1) —
  DEPRIORITIZED 2026-07-24 (Akhil): kaya maintains its own bindings, so
  cross-binding consistency comes from one set of hands plus the gates
  (check-sugar-surface, the abort checks, the emission checks), not
  from a document. A style guide is what you write when OUTSIDE
  contributors author bindings; revisit when the library is mature
  enough for that to be true. The per-family spellings stay ratified
  and in force (chains: Rust/Go/Java; named args:
  Swift/Python/C#/OCaml; config lists: Haskell — DESIGN's Binding
  conventions; OCaml's ambient-transaction spelling, 2026-07-22).
  Three items filed under it are NOT style and keep their own standing:
  - **Container scoping for layout props** — typed row/column contexts
    making an orphan `grow` a compile error. A safety guard (types over
    runtime checks), not ergonomics. The ambient languages' nullary
    container bodies cannot express a receiver without a redesign,
    which is why it waited.
  - **Derived-signal vocabulary beyond Python** (eq/ne/fmt) and
    **blob-signal parity** (Go has typed Signal[[]byte]; others wrap
    handles) — capability gaps between bindings, not spelling ones.
  - **Decision gate for deleting the probe/reflection selector floor**
    that the KayaGen generators superseded — debt with a real deletion
    behind it.
  The rest — per-language tiers, ambient-tx spellings for the remaining
  languages, optional static analyzers,
  multi-window ergonomics — waits for the guide, and the guide waits
  for maturity.
- STANDING CONSTRAINT — do not bump the flake SDK without preserving
  a compat-generation leg. The nix shell links every non-swift leg
  binary against its pinned SDK (audit 2026-07-21: python3/go/dotnet/
  ocaml/rust 14.4, zulu JDK 11.3), so those legs exercise SwiftUI 26's
  COMPATIBILITY design generation, while the swift mac guests compile
  against the system toolchain and exercise the modern generation —
  both covered on purpose. Vendor audit (2026-07-21, official
  binaries, LC_BUILD_VERSION sdk field): .NET host 10.0.10 = 15.5,
  .NET 11-preview.6 = 15.5, apphost stub = 15.5; zulu jre 21/25 =
  13.3, Temurin 21 = 14.2, Oracle JDK 25 = 14.5. No vendor ships a
  ≥26 stamp; nixpkgs' darwin `openjdk17` IS repackaged zulu (no
  source-built lever). The compat generation is where the Button
  measurement bug class lives and is a permanent first-class citizen;
  the native-kit button bridges are load-bearing indefinitely, not
  transitional.

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
  production wire.
  HALF OF THIS IS ALREADY PAID (noted 2026-07-27, on an audit of this
  file). The accessibility milestone landed the prop: `a11y_id` is
  spec prop 12, and it lowers to exactly the mappings proposed above —
  `accessibilityIdentifier` on the Apple backends, `Modifier.testTag`
  on Compose. So the expensive half of the original cost — a Prop in
  spec.rs, the hash moving, everything regenerating — is spent, and
  the framing question is settled rather than open. Do not plan it
  again.
  WHAT IS ACTUALLY LEFT is the ADDRESSING half: a name→widget map in
  the backends and both interpreters, `parse_target` accepting an
  authored key beside `kind#index`, and a steps migration. Every scene
  still targets positionally, so the payoff is untouched — containers
  freely addressable, no unique-by-convention discipline, check-steps'
  container lint retired, and the layout scene's rows assertable
  instead of observation-only. TRIGGER: the first scene that needs to
  assert on a container the uniqueness convention cannot name — the
  layout scene already qualifies whenever its rows deserve assertions.

- **Undo/redo and session restoration — core-owned, and cheap only
  here** (from the 2026-07-24 survey; TRIGGER SATISFIED by the text
  editor). Every other cross-platform framework bolts undo onto
  application state it does not own; macOS has `NSUndoManager` and the
  other three platforms have nothing portable. kaya owns all state at
  rest and every mutation already arrives as a transaction, so an undo
  stack is a log of objects core materializes anyway. The same
  machinery gives window/session restoration — serialize the core
  scene, not the app's state — which cmyr's ingredient list names and
  nobody enjoys writing. NOT free: the design pass has to answer which
  transactions are undoable, whether an undo re-runs handlers or simply
  applies the inverse transaction, and what happens to occurrences
  emitted during an undo. Do the design pass before any protocol work;
  the machinery being present is not the same as the semantics being
  obvious.
- **The system-integration floor** (from the survey; the editor
  triggers the first three). Four surfaces, native on every platform,
  none previously in this ledger, and collectively what separates a
  demo from an app. In the order real apps need them: **file dialogs**
  — NOT a widget, a presentation context returning a result. RATIFIED
  2026-07-27, see DESIGN's "File dialogs": the alert grammar holds, but
  the result is a LIST OF HANDLES redeemable for open DESCRIPTORS, not
  paths — Android and iOS have no path to give, and kaya hands over a
  capability rather than moving bytes. Open comes first, save second;
  **clipboard** — note it is SYNCHRONOUS on
  mac/Windows and ASYNCHRONOUS on Linux, so the API must be
  async-shaped or it is wrong on one platform, and it is also the
  unblocker for the deferred cut/copy/paste roles; **notifications** —
  the four platform models are close; **drag and drop** — the most
  divergent, and it interacts with window management on both mac and
  Windows. **Printing** sits behind all four and is not editor-forced.
- **Standard commands LANDED 2026-07-24** (the follow-up milestone to
  menus): a chord rides any window-anchored LEAF command rather than
  plain actions alone, the key floor admits eight named punctuation
  keys, and `role` names a standard command with `settings` as its one
  v1 value. DESIGN.md's "Standard commands" and the shortcut policy
  carry the rules; the `commands` scene proves all three in nine
  languages on every lane. Still open, trigger-gated: roles beyond
  `settings`, and punctuation keys beyond the admitted set.
- **Menus follow-ons.** The command vocabulary LANDED 2026-07-24 —
  both anchors, all four backends, all 8 bindings plus the C floor,
  and the menus scene green on every lane. DESIGN.md's "Menus and the
  command vocabulary" is the whole record — the design, the lowering
  per host, and the two platform limits under "Where a platform cannot
  say it". What stayed out is trigger-gated, each trigger
  stated in that section's "Deliberate cuts and admission triggers":
  shared command identity across anchors (the responder-chain/target
  problem), For-stamped items, `bind_field` labels on context items,
  merging authored items into native text-control menus, a GTK
  hamburger presentation hint, item removal, context-item shortcuts,
  role-based standard items (including native Settings placement),
  punctuation shortcut keys, and — only under artifact pressure — a
  toolbar grammar. One follow-on the section does not carry: iOS has
  no hardware-keyboard route to the catalog. The interpreter holds
  the shortcut table (the harness verb drives it, and the scene
  proves the dispatch), but nothing binds it to a real iPad keyboard
  or to the hold-Command HUD. NARROWER THAN IT READS (corrected
  2026-07-27): the `UIMenuBuilder` half SHIPPED — `kayaBuildCatalogMenus`
  runs on BOTH iOS form factors, and on iPhone it feeds the
  hardware-keyboard HUD; only the VISIBLE arm keys on size class. What
  is actually missing is the CHORD: the generated `UIAction`s carry no
  `input:`/`modifierFlags`, so nothing is bound to a key. (The macOS
  lowering is NSMenu rather than SwiftUI `.commands`, which is why
  neither side goes through CommandsBuilder.) TRIGGER (SUPERSEDED 2026-07-24 — see the iPad
  DEFECT entry at the top; iPadOS 26's menu bar is not keyboard-gated,
  so this trigger could never fire for the case that matters): an
  artifact running on iPad with a keyboard. Android's equivalent route
  IS live (each host Activity forwards `dispatchKeyShortcutEvent` into
  the same table).
- scrollTo + ref markers (per-instance handles): brings the first
  instance-addressed command (TemplateNodeId + key path target) and the
  silent vanished-target no-op (live-zone commands fail loudly; stamped
  copies legitimately vanish under rebuild). Wants a long-list scene —
  which pairs with row-window virtualization for For.
- Horizontal scroll axis: an axis enum prop — decide when a scene
  needs it (the scroll depth ledger's remaining item).
- Command completion observability (awaitable commands — the Compose
  scrollToItem precedent); command payloads (a set_text command awaits
  an autofill-shaped artifact). Admission policy: each verb needs a
  real artifact.
- Value::Record — waits for nested fields or field-level sum payloads.
- Nesting depth >2 validation; typed keys in collection schemas.
- Occurrence growth: subscription/filtering (every click emits today),
  suspension lifecycle (Android).
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
- Navigation sugar remainder from the nav breadth slice: (1)
  pop_to_root/pop(n) sugar + the binding stack mirrors it needs;
  (2) signal-bound entry titles have wire + scene + fan-out but no
  binding sugar.

### Swift reads its constants straight out of the C header, and the header is not namespaced

Swift is the ONE binding with no generated constants: every other
language's kaya-bindgen emitter walks `spec.enums` and writes them out,
while Swift imports kaya.h with `-import-objc-header` and names the C
symbols directly (`KAYA_PROP_ALIGN`, `KAYA_ALIGN_START`). That was
deliberate — Swift's C interop is free, so re-declaring would be pure
duplication.

The clipboard found the crack in it. Constants declared in
`crates/kaya/src/capi.rs` carry the `KAYA_` prefix in their Rust names
and reach the header prefixed; constants declared in
`crates/kaya/src/wire.rs` do not, and cbindgen exports them verbatim.
So the header defines `CLIP_TEXT`, not `KAYA_CLIP_TEXT` — and the
`KayaRepresentation` doc comment, written from the other side, promises
`KAYA_CLIP_*`. The Swift clipboard surface uses `CLIP_TEXT`, which is
what is actually there.

THE WIDER PROBLEM is not the clipboard's. kaya.h currently exports
about sixty unprefixed defines — every `REC_*`, every `TX_*`, every
`APPLY_*`, the `VALUE_*` types, the `PROP_*` and `WPROP_*` keys, the
`CLIP_*` masks, and `HEADER_SIZE`, which is a name no public header
should take. Any C or Swift consumer that includes kaya.h inherits all
of them.

WHY IT IS A SLICE AND NOT A RENAME. Fixing it means deciding how the
Swift binding should name what the header exposes at all — generated
constants like the other seven, a Swift enum wrapping them, or a
prefixed header it keeps reading — and each answer rewrites call sites
across the Swift binding, the SwiftUI interpreter, every Swift guest
and every C guest. Doing it inside a feature milestone would mix a
mechanical sweep into changes that need to be readable. Take it on its
own, with the C guests compiled and the whole matrix run after.

### The accessibility walk visits every window twice

`kayaAxKids` in swift/KayaSwiftUI.swift gathers an element's children
from three attributes and deduplicates only the third:

    var out = windows + children                 // no dedup
    for n in nav where !out.contains(where: { CFEqual($0, n) }) { ... }

An `AXApplication` publishes the same window under BOTH `AXWindows` and
`AXChildren`, so `out` holds it twice and every walk descends the whole
window subtree twice. Visible directly in a `KAYA_AX_TRACE=1` dump as
two identical `AXWindow id=main.KayaRoot-1-AppWindow-1` subtrees
(observed 2026-08-02 on the clipboard scene).

WHY IT IS WORTH FIXING rather than shrugging at: AX cost is this
subsystem's documented hazard, not a micro-optimisation. Announcing
`AXEnhancedUserInterface` makes AppKit rebuild its accessibility
hierarchy and drive a full layout pass, which on 2026-07-25 put legs
past their 120s timeout under the 8-wide pool while the same binary
passed standalone. Every `expect_ax` pays the walk, and halving it is
one line: extend the `CFEqual` dedup to cover `windows + children`.

WHY IT IS NOT DONE HERE: it changes the SwiftUI interpreter's shared
read path, which every accessibility assertion on mac and iOS depends
on, in the middle of a clipboard milestone. It wants its own slice with
the a11y scene and the full matrix behind it — and a before/after read
count, so the saving is measured rather than assumed.

## Testing / infrastructure

- ~~**Python's lifecycle handlers ran outside a transaction**~~ — FIXED
  2026-07-27, and GUARDED. The dispatch loop wrapped widget and menu
  handlers but called the six lifecycle handlers bare
  (close_requested, window_closed, entry_popped, section_selected,
  back_requested, alert_result), so `destroy_window` inside an
  on_close_requested raised "no ambient transaction" and DESIGN's
  ratified "a handler is a transaction" was false in Python alone. All
  seven sites now share one `App._dispatch`, which also gives the
  lifecycle paths the rollback-and-log discipline they never had.
  WHY NO GATE SAW IT: the scenes passed, because five guests each
  opened a transaction by hand. The workaround was the camouflage. The
  guard is therefore `tools/check-ambient-tx.sh`, which forbids a guest
  from opening one inside a handler — with nothing able to compensate,
  the existing scenes ARE the test.
  SCOPE, stated so nobody widens it carelessly: the defect needs an
  AMBIENT transaction. Go/Java/Swift/C# pass the tx as a parameter, so
  it is not expressible; Haskell opens one explicitly in every handler
  (idiom, uniform, not a workaround); OCaml is ambient and was already
  correct, but has no reliable textual discriminator — its guard, if
  ever wanted, is a behavioural check in the check-abort family.


- Reproducibility, the remainder after 2026-07-26. What landed: the
  container base pinned by digest, opam's rolling index pinned to a
  commit (with the direct packages version-pinned on top), `--locked`
  on every cargo invocation with a check-shell clause holding it,
  check-pins over the ecosystems that have no lockfile at all, and the
  build id — libkaya carries a marker naming the sources it was
  compiled from, every lane `--verify`s what it runs or ships, and
  check-build-id proves both halves live. What did NOT, each for a
  stated reason rather than for lack of time:
  - APT PACKAGE VERSIONS in the container. Freezing them means
    snapshot.debian.org, which is slow and periodically unavailable —
    that trades continuous small drift for an occasional inability to
    rebuild the image at all. trixie is stable, so the drift is point
    releases and security updates, and the security half is drift we
    want. Revisit if a Debian update ever breaks a lane; the fix would
    be to pin the snapshot only for the release that broke.
  - GRADLE DEPENDENCY LOCKING and NUGET packages.lock.json. Both
    ecosystems already name exact versions and resolve them from
    immutable repositories, so a lockfile adds regeneration ceremony
    without adding determinism. check-pins guards the property that
    actually matters (no dynamic version ever enters). Revisit if a
    transitive graph ever surprises us, or on the first supply-chain
    requirement — that is when VERIFICATION metadata (checksums), a
    different feature from locking, starts earning its cost.
  - CABAL FREEZE. The Haskell guests depend only on boot libraries
    (base, bytestring, containers), which ship with the compiler — and
    the two lanes use DIFFERENT compilers (nix's ghc on mac, apt's in
    the container), so a freeze file pinning boot-library versions
    would be wrong on one of them by construction.
  - (CLOSED 2026-07-26.) The build id now reaches all three compiled
    artifacts: libkaya (`core`), the SwiftUI interpreter (`swiftui`,
    both the mac dylib and the iOS one), and the Compose interpreter
    (`compose`, verified inside the apk — an apk is a zip, so the
    verifier reads its dex members, and which classes*.dex a string
    lands in is not stable). Each is keyed on its own sources plus the
    INTERFACE it compiles against, not on the core's implementation, so
    a backend edit does not invalidate an interpreter.
  - BIT-IDENTICAL OUTPUT is not claimed anywhere and is not the goal
    here. The id fingerprints INPUTS: a different id always means
    different sources, but one id does not promise two byte-identical
    binaries (build paths, timestamps, codegen nondeterminism). Real
    output determinism wants -Zremap-path-prefix and friends, and its
    payoff is a shared build cache, which is a packaging-milestone
    concern.
- ~~deploy-win.sh uses `sed` and `awk`~~ — LANDED 2026-07-27 (the
  rewrite and its gate both rode `d1a64fd`). check-shell now bans both
  in COMMAND POSITION across `tools/**/*.sh`, with a self-test that
  scores a real invocation against the word inside another word — the
  first draft flagged "used" in a comment. Heredoc bodies are dropped
  from the scan, because the scanner itself lives in one.
- ~~**`split` and `listdetail` are rust-only, and the per-language
  verdict is still owed**~~ — SWEPT 2026-07-27. Seven new guests
  (python, go, csharp, swift, ocaml, haskell, java), and the verdict
  is DO for all seven: `split` joined SCENES on the three desktop
  runners, `listdetail` rides the same guests on all five lanes, and
  DEPTH_SCENES is empty everywhere.
  SEVEN FILES, NOT FOURTEEN, because a scene selects a SCRIPT, never
  an app: `KAYA_SELFTEST` only names the `.steps` file the harness
  reads, so one guest per language serves both scenes. The one
  assertion that could not be shared is the window title (one app has
  one title), which is why `listdetail.steps` does not make it. Two
  places assumed scene-name == guest-name and had to be taught
  otherwise: the iOS swift loop now takes `scene:guest` entries
  (`listdetail:split`), and the Windows launchers name the guest
  explicitly.
  THE SWEEP PAID FOR ITSELF TWICE, which is the argument this entry
  previously got wrong — it reasoned these guests would "mostly
  re-test the generator". They did not, because the SUGAR is not
  generated:
  - **Python could not declare list-detail at all.** `wire.py` is
    generated from spec.rs and had `tx_set_window_list_detail`, but
    `__init__.py` — the hand-written sugar every Python app uses —
    never threaded the prop through `App.window()` or
    `create_window()`. Fixed. Nothing in eight languages of Rust-only
    scene coverage could have found this.
  - **A list-detail window with an EMPTY stack had no title**, on all
    three backends that build the pane pair themselves (SwiftUI, GTK,
    WinUI): the split arm titled the window from the top entry and
    fell back to the empty string. It read as correct for one reason —
    the only guest running the scene was an example binary named
    `split`, and the scene asserts the title `"split"`, so AppKit's
    process-name fallback matched by coincidence. The Python port
    reported `python3.14`. A NAMING COINCIDENCE HAD BEEN STANDING IN
    FOR THE FEATURE.
  Also learned: `TwoPaneView` is a pri-adjacency control like
  `ProgressBar` (its template needs the XamlControlsResources merge),
  so the Windows go/csharp launchers take the progress shape. With the
  plain shape both crashed at the first `expect_split` with
  0xc000027b, a stowed XAML exception.

- Scene-run coverage, the remaining half: check-steps' wired() now
  demands per-runner LEG SIGNATURES (run $scene- / run "$proto"
  $scene- / run_suite ${scene}_), so a scene absent from a runner
  fails the gate — but a grep signature proves WIRING, not execution.
  Nothing yet proves the exact scene × language × platform tuples
  that actually ran and produced verdicts (a runner can still skip
  legs at runtime); an executed-suite manifest compared against the
  expected tuple set is the missing gate.
  Packaging notes for whoever adds the next scene (walked end to end
  by menus, 2026-07-24): on iOS the swift guest rides
  IOS_SWIFT_SCENES — a bare name, or `scene:guest` where two scenes
  share one app, with bundle and leg derived — while a rust
  example needs its own build+bundle+queue_leg block; Android has one
  apk PER GUEST TIER, each a scene selector keyed on KAYA_SELFTEST —
  milestone2 (the Rust guest: a new scene needs a `mod` + match arm
  in guests/rust/milestone2_android.rs) and milestone2kt (the JVM
  guest: its MainActivity needs the matching arm) — plus a run_apk
  leg per tier; on Windows the name in deploy-win's SCENES derives
  the cross-build, the scp of exe/python/go sources, and the taskkill
  entries, leaving only a tools/guest/run_<scene>_<lang>.cmd per
  language and the run_suite block. A scene whose guests do not all
  exist yet must NOT join SCENES: the per-language surfaces glob for
  sources and must keep failing loudly for the scenes that do exist.
- Recording stills DRIFT across a long scene: the film and the
  harness transcript are anchored at ONE instant, and their clocks
  then run at different rates, so a step's still is progressively
  earlier than the step. Menus (38 steps, ~2.4s of transcript) is the
  first scene long enough to show it — measured 2026-07-24 on iOS:
  the leg's steps span 2.4s of harness time while the same run
  occupies ~1.3s of film, so `step-38` renders a state from before
  `click button#2`. The film itself is complete (t=31.0s of suite-1
  shows the true final frame: `shared`, Publish promoted, the removed
  row gone) — only the mapping is wrong. Same root cause as the
  "anchor implausible" failures on the busiest simulator, where the
  accumulated drift pushes a leg's span past the film's end and the
  extractor (correctly) refuses. Android has the weaker form: it
  anchors at stop time minus duration, and screenrecord drops its
  buffered tail. Fix direction: calibrate rate, not just offset — two
  fiducials per film, or a per-leg in-band fiducial — rather than
  trusting one anchor across a whole suite. Windows has a third
  variant: `KAYA_RECORD=1 deploy-win … menus_rust` passed the leg and
  then reported "the capturer produced no frames" — the WGC capturer
  never attached to a window that lives about two seconds.
- Per-binding EMISSION checks (kaya_app_checks.py-style — assert the
  records a construction emits) in Java and Haskell — Go, Swift, C#
  and OCaml already have one (run by tools/check-abort.sh), so this is
  two languages owed, not seven.
  The motivating miss: the Swift binding's containerOf ACCEPTED
  construction-time `spacing:` but never applied it (one commit's
  worth of silently dropped writes) — and no gate could see it,
  because the interpreter's render and its fills observation share
  the node state a wire-dropped write never reaches; recordings were
  the only gate for that class.
- The WinUI bindings have no regeneration gate:
  crates/kaya/src/winui/bindings.rs comes from tools/winui-bindgen, but
  unlike gen-header/gen-bindings/gen-guests there is no `--check`
  proving the checked-in file matches the generator — a hand edit (or a
  filter change without regeneration) goes unnoticed until the next
  regeneration clobbers it. COMPILABILITY is already covered on every
  mac run — `tools/check-targets.sh` cross-compiles the windows target,
  so a broken bindings.rs fails in seconds rather than on the VM. What
  is missing is PROVENANCE: nothing proves the checked-in file is what
  the generator would emit.
- Mount-transaction focus negative test: the Focus command now
  defers until the element is loaded/mapped on WinUI/GTK (the
  materialization class, traps.md), but no scene issues focus IN the
  mount tx — the entry scene focuses from the add fold, long after
  load. The class fix is structural; the missing gate is a scene (or
  an entry-scene opening step) that focuses at mount and asserts
  expect_focused, proving the deferral on all platforms.
- resize_window harness verb — the VERB LANDED with the form-factor
  milestone: `split.steps` drives three REAL resizes and re-asserts the
  presentation on the far side, on all three desktop lanes. WHAT IS
  STILL OWED is narrower than this entry used to claim (corrected
  2026-07-27): no scene re-asserts GEOMETRY across a resize —
  `expect_root_fills` / `expect_shares` / `expect_fills` appear nowhere
  in split.steps — so reflow-under-resize is not a matrix fact even
  though the transition is. Also still the place to watch WinUI's known
  interactive-resize flicker (platform-level; we already avoid the
  transparent-background worst case — keep WinAppSDK current).
- The macOS `back` verb drives the path binding (GTK/WinUI/Compose
  drive real chrome; mac needs a stable handle on NavigationStack's
  private toolbar button).
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
- bench-encode blob leg: register+reference throughput with an MB/s
  floor, so payload-path structural regressions trip at gate time.
  (Adding it means a second phase in each language's encode_bench
  program + floors in tools/bench-encode.sh — keep it separate from
  the existing rec/s floors, which would otherwise deflate.)
- Matrix speed, remaining (diminishing returns): a real swiftmodule
  for the Swift bindings; a Windows VM with more cores.
- Windows entry follow-ups: IME contract notes for mobile; the WinUI
  text-flyout-open path is untested.
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
- Swift guests on Linux and Windows. Upstream swift.org toolchains
  exist for both, but neither pinned world (docker image, VM) carries
  one, and the swift SURFACE is already fully proven — typecheck on
  two Apple targets plus 25 live mac legs and the iOS suite. The
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


## Retire the hand-edited shell and cmd scripts

Raised 2026-07-31, after file dialogs. The repo already bans sed and awk
for ad-hoc text work because BSD and GNU diverge; this is the same
argument one level up, about the scripts themselves.

The failure mode is not that shell is hard to write. It is that these
files are easy to CORRUPT and the corruption is invisible until a lane
runs. Measured in one session: tools/guest/*.cmd must keep CRLF or
cmd.exe reads a lone LF as part of the command, and two separate
attempts to edit one of them programmatically mangled it — once by
splitting on CRLF and rejoining wrong, once by a `\r\n` that did not
survive shell quoting into python. Neither showed up until a leg timed
out at 327 seconds. Around the same afternoon a slice edit to
tools/deploy-win.sh silently swallowed five `run_suite background_*`
lines; only check-steps caught it.

What to move, roughly in order of pain: tools/guest/*.cmd (CRLF, cmd
escaping, forty near-identical files), tools/deploy-win.sh (the longest
and the one whose leg ordering is load-bearing), then the rest of
tools/*.sh. Python is the obvious target — it is already the mandated
language for text processing here, it is in the dev shell, and it has
real data structures for things the shell fakes with string splicing.

Two things NOT to lose in the move: the dev-shell fingerprint check
every tools/ script starts with, and the `$?`-read-once discipline that
tools/check-shell.sh enforces (a rule that exists only because shell
makes it easy to get wrong — which is itself an argument for leaving).
See also the portsh work for the cases where one script must run on both
sides.

## MAYBE: read Windows accessibility client-side, like the other platforms

Raised 2026-07-31, NOT decided. Recorded so a green lane does not read
as a settled question.

The Windows `expect_ax` read is IN-PROCESS and PROVIDER-SIDE: it asks
XAML what it publishes, through FrameworkElementAutomationPeer. mac
(AXUIElement), linux (AT-SPI) and android (an accessibility service) all
read CLIENT-SIDE, from outside the app, which is the stronger form —
it observes what an assistive technology would actually receive rather
than what the app believes it exposes. The asymmetry predates the file
dialog work and nothing about it is newly broken.

WHY IT IS ONLY A MAYBE. The obvious fix — a Win32 UI Automation client
walking our own process — is now known to be the thing that cannot be
done here: attaching any UIA client makes the shell's DirectUI raise
automation events during message dispatch, which raises a NONCONTINUABLE
COM exception inside the guest that HotSpot reports as fatal
(docs/traps.md). It would have to run out of process, in the shape
iOS's tools/ios/simdrive uses, and it would have to be guaranteed not to
be attached while a file dialog is up. That is a lot of machinery for a
read that currently works.

The honest counter-argument is that a provider-side read cannot catch
the class of bug where XAML publishes something a client cannot see, and
that is exactly the class the a11y milestone was about. Decide on
evidence: if a real defect ever slips past the Windows a11y legs while
another platform's client-side read would have caught it, this stops
being a maybe.
