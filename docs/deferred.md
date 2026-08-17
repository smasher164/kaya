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

- ~~**Clipboard**~~ — COMPLETE 2026-08-04: all five backends, all
  eight bindings, every lane green in the full matrix (mac 232, linux
  426, windows 145, ios 46, android 50; three consecutive ALL PASS
  runs plus a confirming exit-0). The measured record is
  docs/clipboard-plan.md §0-§9; the fan-out's defect harvest (most of
  it pre-existing) is in docs/traps.md and this file's checked-off
  entries. Editor prerequisites remaining after this: undo/redo,
  dirty-state window titles, find.

- **Saving a file** — IN FLIGHT 2026-08-09. The design is ratified and
  written down: docs/save-plan.md D1-D5, off five probe reports. One new
  request record (`show_save_dialog { window, dialog, suggested_name,
  filters }`) answering on the PICKER'S result grammar with one locator,
  and one decision with semantics in it: a save result registers a source
  whose open CREATES, so "open the destination for write" yields an empty
  file on all five platforms — Android and iOS hand back a document that
  exists, macOS/GTK/Windows hand back a name for a file nobody has made
  (measured; macOS does not truncate on Replace either). A fourth
  `FILE_MODE_CREATE` is the named rejection: creation belongs to the
  destination the dialog promised, not to the caller's intent. DEPTH
  LANDED: spec + the core's `SaveDestination` + the Rust surface
  (`tx.save_file(name)`, `msgs.on_saved`) + the SwiftUI mac arm + the
  `save` scene. What is still open:
  - ~~**DEPTH STUB: save on swiftui/ios**~~ — LANDED 2026-08-09.
    `UIDocumentPickerViewController(forExporting:asCopy:)`, whose every
    initializer takes a URL that ALREADY EXISTS, so the backend stages a
    ZERO-BYTE file carrying the suggested name and exports that — the
    emptiness is D1 itself, since the export copies what it is given and
    that is what an untouched destination would read back. The answer
    arrives through the picker's own `didPickDocumentsAt` delegate, so
    there is no new result path; the destination is retained as an
    ordinary picked URL and redeemed through `kaya_swiftui_open_picked`.
    D4's text entry landed as four simdrive verbs
    (`savestate`/`savename`/`savepress`/`savecancel`): the name is set
    and READ BACK over accessibility, and `savepress` matches the
    navigation strip's `Save` EXACTLY because `press Save` falsely
    succeeds on this sheet — it matches the static text "Save as" by
    containment and the sheet stays up. `save-swiftui` runs in
    tools/ios/run-sim.sh.
  - ~~**DEPTH STUB: save on gtk**~~ — LANDED 2026-08-09.
    `gtk::FileDialog` asked to `save()` rather than `open()`, so the live
    slot, the retire path, the result occurrence, the armed directory and
    the DISMISSED-to-empty cancel are all the picker's already; the two
    differences are `set_initial_name` and registering the answer as
    `protocol::SaveDestination` rather than `PathSource`. The three
    `Stage` methods read and drive the real panel over the AT-SPI walk
    the picker already uses, telling the two dialogs apart by the
    `EditableText` name field the save panel alone publishes.
    `save-rust` runs on both protocols in tools/linux/run-suites.sh.
  - **DEPTH STUB: save on winui** — `IFileSaveDialog` (NOT
    `FileSavePicker`, whose start location is an enum and which needs an
    owner HWND unpackaged), driven through the UIA machinery deploy-win
    already has. The windows runner wires no `save` legs meanwhile.
  - **DEPTH STUB: save on compose** — `ACTION_CREATE_DOCUMENT`, which
    hands back a content locator to a document that ALREADY EXISTS, so
    the core's create is a no-op there and the uniform behaviour is free.
  - **The seven other bindings** — the save request and its result in
    Python, Go, C#, Java, Swift, OCaml, Haskell, plus the C floor's
    explicit spelling. check-sugar-surface and check-verbs hold this
    open.
  - **Java's picked handle is read-only in every mode, on every
    platform** (`bindings/java/dev/kaya/KayaApp.java:581-589` returns a
    `FileInputStream` for write and read-write alike). A Java app cannot
    write to a picked file anywhere — found by the save probes, fixed in
    this milestone's breadth per docs/save-plan.md D3.
  - **The Swift interpreter matches file-mode NUMBERS as bare literals**
    (`swift/KayaSwiftUI.swift`, the iOS opener) while Rust pins them by
    test, with nothing checking the two agree. D3 wants a gate, watched
    failing.
  - **The save-over-an-existing-file path is undriven.** macOS answers a
    Save onto an existing name with a SECOND, UNNAMED `AXSheet` whose
    buttons carry stable identifiers (`action-button-1` = Replace,
    `action-button-2` = Cancel) and localized titles; the completion does
    not fire until one is pressed. The shared scene cannot drive it,
    because Android's `ACTION_CREATE_DOCUMENT` and iOS's export never
    prompt at all — they rename to `name (1)` — so a `file_save replace`
    step would be unsatisfiable on two of five platforms. If it is ever
    wanted it is a mac/linux/windows-only leg, not a line in
    `save.steps`. Measurements: scratchpad/save-probe-mac.md.
  - **`filters` on a save request is exercised at the wire level only.**
    The `save` scene sends none, deliberately: with `allowedContentTypes`
    set, NSSavePanel appends the first allowed extension to a name that
    has none and publishes the STEM in its name field when the user's
    Finder preference hides extensions — a machine-wide setting deciding
    a byte-frozen assertion. A scene that wants filters must name files
    whose extension is already in the filter.
  - **THE THREE SAVE `Stage` METHODS CARRY DEFAULT BODIES**
    (`save_dialog_state`, `set_save_name`, `confirm_save` in
    crates/kaya/src/harness.rs). Every other observation there is
    no-default so a backend that forgets fails to COMPILE;
    these panic instead, only because the slice landed depth-first and
    gtk.rs/winui/mod.rs are the breadth arms' files. When all four
    backends implement them, DELETE the bodies and end the signatures
    with `;` — tools/lib/stage-coverage.py then holds them like the rest.

- **Dirty state** — IN FLIGHT 2026-08-06. The design is ratified and
  written down: docs/dirty-plan.md D1-D6, off five probe reports. One
  `dirty` bool beside `title` and `veto_close`; the app declares state
  and each backend spells its own chrome (the close-button dot on
  macOS, a leading `*` in the rendered caption on Windows, a bullet in
  the GTK header bar, nothing on the phones, which have none). The
  title string is untouched everywhere — Qt's `[*]` template is the
  named rejection. It arms nothing: the "unsaved changes, close
  anyway?" flow stays composed from `veto_close` plus the dialog
  machinery. DEPTH LANDED: spec + Rust surface + the SwiftUI mac arm +
  the `dirty` scene. What is still open, each held by a gate that is
  RED BY DESIGN until it lands:
  - ~~**DEPTH STUB: dirty on gtk** — the GTK arm (a bullet label beside
    the header-bar title, the living GNOME convention) and its AT-SPI
    read. `Stage::window_dirty` refuses loudly meanwhile; the linux
    runner wires no `dirty` legs.~~ LANDED 2026-08-06: every kaya window
    now carries the marker in its header bar (GNOME Text Editor's
    CenterBox shape, so the title does not move when the mark goes up),
    with an accessible label that is what makes it readable at all;
    `Stage::window_dirty` walks AT-SPI for that node inside the frame
    the window publishes, and reports UNREADABLE as its own failure
    rather than as `false`. The linux runner wires the scene for every
    guest this lane carries — the seven non-Swift bindings plus the C
    floor — on both protocols, each through `a11y-leg.sh`, which is what
    makes GTK publish a tree at all.
  - ~~**DEPTH STUB: dirty on winui** — the WinUI arm (a leading `*`
    composed into the rendered caption, the measured Notepad
    convention) and its caption read. Same shape; the windows runner
    wires no `dirty` legs.~~ LANDED 2026-08-06: the marker composes in
    `refresh_caption`, the one caption writer this backend now has
    (five `SetTitle` sites collapsed into it, and `deploy-win.sh`
    refuses a sixth); `Stage::window_dirty` reads the real OS caption;
    `run_suite dirty_rust` is a live leg.
  - ~~**DEPTH STUB: dirty on compose**~~ — LANDED 2026-08-06. All four
    interpreter layers in KayaCompose.kt (constant, apply arm, model
    field, verb arm); the lowering is deliberately EMPTY, which is D4,
    and `expect_dirty` reads the applied prop back — watched failing
    with the apply arm dropping the value, and again with a lowering
    that sets but never clears. The chrome-close tail is answered the
    way the iOS lane answered it, on purpose: `dirty-compose` runs the
    shared scene's phone-expressible PREFIX (the mark up, down on save,
    up again), cut at `close_window` and guarded on the `expect_dirty`
    verb, with the declined steps printed. One android-only claim rides
    on top — `expect_title "dirty"` while the mark is UP, which is the
    observable form of "no chrome" and fails the moment anything
    composes a marker into the task label.
  - ~~**DEPTH STUB: dirty on swiftui/ios**~~ — LANDED 2026-08-06.
    `expect_dirty` reads the applied prop back off the window model
    (D5's iOS row); the lowering stays empty, which is D4. The question
    this entry held open — the scene drives a chrome CLOSE, which no
    phone has — was answered with NEITHER of the two options it named:
    not an all-or-nothing carve-out (D4's arm would then be applied and
    asserted by nobody) and not a sibling scene (every runner would owe
    it legs, a cross-lane obligation minted mid-fan-out). The iOS leg
    runs the shared scene's PHONE-EXPRESSIBLE PREFIX — everything above
    `close_window`, which is the mark going up, coming down on save,
    and going up again — with the cut declared by VERB and guarded
    both ways in tools/ios/run-sim.sh. The Compose arm faces the same
    tail and can lift the same shape; if it does, the two belong in one
    helper rather than two spellings.
  - The seven other bindings' sugar spelling of the window prop
    (check-sugar-surface's window-prop sweep holds it open) and the
    scene's guests, at which point `dirty` graduates out of
    DEPTH_SCENES.

- **Text ranges** — IN FLIGHT 2026-08-06. The design is ratified
  (docs/ranges-plan.md D1-D6) off five probe reports and a units
  ruling: three primitives on the TEXTAREA — `highlight_ranges` (a
  declared set), `select_range` (one range) and `reveal_range` (scroll
  into view) — app-declared in UTF-8 byte offsets, validated at one
  core chokepoint, converted to each backend's own unit before
  lowering, and NEVER tracked across an edit. kaya ships no find
  engine, find bar or regex dialect: those belong to the editor, which
  is what this unblocks. DEPTH LANDED: spec + core + Rust surface + the
  SwiftUI **mac** arm + the `ranges` scene, with every negative test
  watched failing. What is still open, each held by a gate that is RED
  BY DESIGN until it lands:
  - ~~**DEPTH STUB: ranges on gtk**~~ — LANDED 2026-08-06. `GtkTextTag`
    for the highlight, `gtk_text_buffer_select_range` for the selection,
    and `scroll_to_mark` (not `scroll_to_iter`: GTK computes line
    heights on an idle and documents the mark form as the one that
    finishes after line validation) through the GtkScrolledWindow the
    textarea foundation gave it. Both linux-only obligations met and
    both watched failing: offsets lower in CODE POINTS, and the CRLF
    correction is now in all three lowerings and in the reads, since the
    buffer keeps a `\r` that `lf()` never showed the guest. The reads
    are AT-SPI (attribute runs, `GetSelection`, `GetRangeExtents` against
    the node's own extents). `compose` needed an input method, because
    GTK has no other way to make marked text: kaya registers a
    `GtkIMContext` on GTK's own `gtk-im-module` extension point, at the
    lowest priority so it is only ever reached by name.
  - ~~**DEPTH STUB: ranges on winui**~~ — LANDED 2026-08-06. The WinUI
    arm on the RichEditBox the foundation switched to:
    `CharacterFormat.BackgroundColor` over `ITextRange` for the set,
    `Selection.SetRange` for the selection, `ScrollIntoView` for reveal,
    all three batched behind `BatchDisplayUpdates`. The planned readback
    was not available: **WinUI publishes no Text pattern on an
    in-process automation peer**, so `GetAttributeValue(BackgroundColor)`
    / `GetSelection` / `GetVisibleRanges` have no provider to answer them
    in this process (`RichEditBoxAutomationPeer` declares one interface
    in the SDK metadata where `ButtonAutomationPeer` declares
    `IInvokeProvider` beside its own, and live reflection agrees), and
    the only route that does publish them is an out-of-process UIA
    CLIENT — the file-dialog era's crash class, barred at the
    Cargo.toml. The reads therefore go one layer down, to Rich Edit's
    own document model: a per-character background scan for the set,
    `Selection.StartPosition/EndPosition` for the selection, and
    `ITextRange::GetRect(ClientCoordinates|AllowOffClient)` against the
    control's own bounds for the viewport. **This is the one lane whose
    highlight assertion does not go through the accessibility tree**,
    and closing that gap needs either a WinUI peer that publishes the
    pattern or a sanctioned way to run a UIA client here; recorded
    below as its own item.
  - ~~**DEPTH STUB: ranges on compose**~~ — LANDED 2026-08-06. Not by
    the route this entry guessed: `BasicTextField(state=)` has NO
    styling hook at kaya's pins (compile-proven — no
    `visualTransformation`, `OutputTransformation` can only edit text,
    `TextHighlightType` is internal and means stylus preview), and the
    `AnnotatedString` route COMPILES CLEAN, stores a plain String and
    paints nothing. The arm draws the ranges instead, onto the
    platform's own `TextLayoutResult.getPathForRange`, inside the
    field's decorator; the selection is `TextFieldState.edit {}` with
    D4's refusal asking `TextFieldState.composition`; reveal computes
    from the field's own layout and drives its own `ScrollState`. The
    textarea gained a bounded viewport in the process (Compose's was
    the one backend whose textarea GREW, so reveal had nothing to
    scroll). The surrogate-pair question this entry raised is answered
    on the READ side, where the only offset arithmetic lives: a
    `substring` across a pair yields a lone surrogate that UTF-8
    encodes as a single `?`, so both conversions refuse a split
    endpoint rather than rounding.
  - ~~**DEPTH STUB: ranges on swiftui/ios**~~ — LANDED 2026-08-06. The
    iOS half of KayaSwiftUI.swift, on the `UITextView` the textarea
    foundation gave it: `NSTextStorage`'s `.backgroundColor` for the set
    (the mac arm's mechanism, chosen over TextKit 2 rendering attributes
    because those paint NOTHING until someone calls `setNeedsDisplay()`
    and nothing on the SwiftUI update path does — green harness, blank
    screen), `selectedRange` for the selection, and
    `scrollRangeToVisible` wrapped in `performWithoutAnimation` for
    reveal, which is ANIMATED on this platform and reads as a no-op at
    the call site. The reads are the live control's storage, selection
    and `textViewportLayoutController.viewportRange` — the iOS sibling of
    the `AXVisibleCharacterRange` mac reads. The two NOT-MEASURED
    questions are answered: `UITextView.selectedRange` does NOT snap
    (both endpoints kept verbatim, unlike AppKit, which snaps the start)
    and CLAMPS an out-of-range selection to a caret at the end; and
    `UITextInput.offset(from:to:)` counts UTF-16 code units, as does
    `NSTextContentManager.offset(from:to:)`, so there is no second unit
    inside the file.
  - **DEFERRED — one iOS guard has no leg that can fail for it.** The
    text push refuses to run while `markedTextRange` is non-nil, and the
    destruction it prevents is measured on the platform (a programmatic
    `view.text =` during a composition drops the marked text and fires no
    delegate callback at all). The `ranges` scene cannot falsify it:
    UITextView NOTIFIES its delegate for marked text, so kaya's model
    never lags the view during a composition kaya provoked and the
    guard's condition is never reached — removing it leaves the leg
    green, watched. Making it a leg needs a scene in which the APP writes
    text while the user is composing, which is a cross-lane obligation
    rather than one backend's.
  - **DEFERRED — the windows highlight read is not the accessibility
    tree.** Every other lane asserts its decorated ranges through the
    surface an assistive client sees (mac's `AXAttributedStringForRange`,
    linux's AT-SPI text attributes); windows asserts them through Rich
    Edit's own document model, because WinUI's in-process automation
    peer for a text control publishes no Text pattern at all (measured
    twice — SDK metadata and live reflection). The consequence is
    narrow and worth stating: the windows lane proves the platform is
    RENDERING the decoration, not that a screen reader can HEAR it. The
    exits are a WinUI peer that hands out `ITextProvider` (nothing kaya
    controls) or a sanctioned out-of-process UIA client for this one
    read, which needs the file-dialog fatality re-measured with a client
    attached before anyone relies on it.
  - **A SWEEP ITEM EVERY BACKEND OWES, measured on mac and open
    everywhere else**: does a programmatic text write during an IME
    composition destroy the composition? On macOS it did, silently, and
    told the app the user had typed nothing — `setMarkedText` notifies
    no delegate, so kaya's model never learns a composition is running
    and the next update pass assigns over it. Fixed on mac by not
    pushing while `hasMarkedText()`. **UIKit: ANSWERED 2026-08-06, same
    verdict, different precondition** — a programmatic write during a
    composition drops the marked text and fires no delegate callback, so
    the same guard is in force on iOS; but `setMarkedText` DOES notify
    the delegate there, so kaya's model never silently lags the view and
    the mac defect's own mechanism does not arise. The question has still
    not been put to GTK, WinUI or Compose, and the answer must be
    MEASURED rather than inherited.
  - The seven other bindings' sugar (`highlight_ranges`,
    `select_range`, `reveal_range`, and `set_text`, which this
    milestone added as sugar over the generic prop setter so an app can
    open a document into an editor) plus the C floor, at which point
    `ranges` graduates out of DEPTH_SCENES. `check-sugar-surface` does
    not police widget props today, so nothing structural holds this
    open — `check-verbs` does, through the Compose interpreter's four
    missing verbs and three missing constants.
  - **The scene is pure ASCII and that is a constraint, not a
    preference.** A `.steps` file travels through three step
    interpreters, a shell and an environment variable, and only the
    Rust reader is proven to decode it as UTF-8 (`check-steps`'s own
    python lint opens it with the LOCALE's encoding). The unit
    assertion is bought instead by putting a CJK word in the GUEST's
    source, which every language's compiler guarantees is UTF-8, so
    every match sits six bytes further along than it sits in UTF-16.
    Proving the `.steps` path end to end is its own piece of work
    (scratchpad/ranges-units.md §8.7 asked for it) and belongs where it
    can be proven on all five lanes.

- **DEFERRED — wayland lane session architecture (researched
  2026-08-03, no trigger yet).** The GTK clipboard work pinned two
  session-level constraints and researched their exits
  (docs/clipboard-plan.md §5b, "researched escapes", has the detail
  and the source-level citations):
  - A persistent seat keyboard and pooled focus assertions are
    mutually exclusive (keyboard focus is per-seat-exclusive; a
    session holder broke three legs the day it was tried).
  - GDK pins `gdk_display_get_clipboard` to the FIRST seat, so
    multi-seat can solve FOCUS exclusivity (with a ~20-line wtype
    seat flag or a vendored micro-client, plus swaymsg per-seat
    focus steering) but can NEVER partition clipboards between GDK
    apps in one session.
  THE EXIT THAT COVERS EVERYTHING: per-leg sway instances — measured
  55ms to socket, the same cost class as the per-leg Xvfb the x11
  half already uses. One session per leg dissolves focus
  exclusivity, makes session keyboards safe, and gives each leg a
  private clipboard (the wayland clipboard legs could then
  unserialise). TRIGGERS: the first feature needing a persistent
  seat keyboard (IME, key repeat, compositor-level shortcut
  injection), or wayland lane time budget pressure from the
  serialised clipboard block. Do it as its own slice — it is a
  compositor-session change, and §0e records what the last one cost
  to re-prove.

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

- **No app can control the margin around its window content** (found by
  the editor, 2026-08-10; the maintainer chose to ship v1 with the
  margin rather than fix it now). The SwiftUI interpreter insets window
  content by a hard-coded `.padding(16)` (swift/KayaSwiftUI.swift, five
  sites) and the spec has NO padding property anywhere: containers can
  SPACE their children apart, but nothing controls the space AROUND
  content. So a full-bleed layout — a Sublime-shaped editor, a canvas,
  a photo view — is inexpressible.
  Two shapes were costed when it came up:
  (a) a WINDOW content-padding prop beside title/size/dirty, defaulting
      to today's 16 so no existing scene moves; the app asks for 0.
      Additive, spec-first, the dirty-state milestone's shape.
  (b) padding as a property of any CONTAINER, with the interpreter no
      longer padding the root. More correct and useful to every app,
      but it moves how every existing scene lays out, so all nine
      guests and their byte-frozen strings need re-examining.
  Whoever picks this up: (b) is the better framework answer and (a) is
  the cheaper one; the editor only needs (a).
  **HOME: the styling/branding pass** (Akhil, 2026-08-10), which is
  ALREADY DESIGNED in DESIGN.md (brand slots, semantic emphasis via the
  role grammar, symbol sets, and the WinUI accent trap) — this entry
  should be read against that section, not as a fresh idea.
  AND NOTE THE TENSION, because it is the actual decision: that section
  explicitly REFUSES arbitrary per-widget appearance and names "a
  padding override" as an example of what the dressed floor exists to
  refuse. So the question is not "add padding"; it is whether the
  WINDOW CONTENT INSET is (i) part of the platform-flowing bet and
  therefore correct as-is, with full-bleed layouts simply unsupported,
  or (ii) a LAYOUT fact rather than an appearance one — like grow and
  spacing, which the design already admits — and therefore the one knob
  that belongs. Decide that first; the two costings above only matter
  if the answer is (ii).


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

- **A GUARD THAT ABORTS THE PROCESS IS THE WRONG SHAPE, and this is the
  second instance.** Measured 2026-08-10 on mac: under an environmental
  slowdown the file picker missed the step budget, the scene proceeded
  and requested a second dialog, and the one-dialog-per-process guard
  (crates/kaya/src/capi.rs:1732) panicked in a non-unwinding context —
  so the leg died with `fatal runtime error: failed to initiate panic`
  and no verdict list, rather than reporting the steps that failed. The
  Windows IME-refusal abort (recorded above, 2026-08-09) is the same
  class from a different direction.
  The rule worth adopting: a guard that catches an APP MISUSE should
  redden the leg with its sentence intact; only a genuinely
  unrecoverable state should abort. Both instances converted a legible
  failure into a bare exit code, and in both the surviving message named
  a cause three removes from the real one. Fix candidates: make these
  panics unwind-safe at the FFI boundary so the harness can collect
  them, or have the harness treat an abort as a leg failure carrying
  the last steps it saw.


- **DEFECT (rare, Windows) — the IME refusal path can ABORT the
  process.** Measured 2026-08-09 in the ranges scene on WinUI: the
  scene starts a composition, asks for a selection, and the core
  CORRECTLY refuses it (`select_range refused: ime_composition`, the
  ratified D4 rule) — and then the NEXT apply op into the RichEditBox
  fails with `HRESULT(0x8000FFFF) "Catastrophic failure"`, which
  panics at crates/kaya/src/winui/mod.rs:830 inside a function that
  cannot unwind, so the process aborts (exit 0xC0000409) rather than
  failing the leg. Frequency: 1 abort in 5 observed runs of that leg
  (2 passes before, 2 passes on demand after). Not caused by the Go
  work — that milestone touches no Rust and no WinUI, and the leg
  passed on this lane before and after.
  The refusal is right; what follows it is not safe. Two things to
  establish when this is picked up: whether the refusal leaves the
  rich edit control in a state the next op cannot survive (and if so,
  the refusal should restore it), and whether ANY apply failure on
  that path should abort — an op that fails should redden a leg, not
  kill the process, and the non-unwinding panic is what converts one
  into the other.


- **stall-compose is timing-sensitive and fails ~1 run in 11** (measured
  2026-08-07: 10 passes, 1 failure, then 2 more passes on demand; the
  failure arrived the same run the android lane grew 55 -> 77 legs with
  the Go suite). The scene deliberately makes the app thread fall
  behind and asserts the stall watchdog notices; when the emulator has
  a fast pass the thread KEEPS UP and the leg fails saying exactly
  that. So the leg is a race against the machine rather than a check of
  the code, and it can also PASS for the wrong reason — a genuinely
  broken watchdog would look identical to a slow pass. Worth reshaping
  so the stall is forced rather than hoped for (make the guest block
  deterministically, or assert the watchdog's report rather than its
  timing), which would also make the failure legible.


- **The Swift iOS bundle is not self-contained** (measured 2026-08-07
  while landing Go on iOS, by a negative test aimed at something else).
  The Go arm proved that linking `-L … -lkaya` instead of naming the
  archive by path still BUILDS, and `otool -L` then shows the binary
  naming an absolute build-machine path to `…/deps/libkaya.dylib` —
  which is what the SWIFT iOS leg ships today. It works only because
  the lane builds and runs on one machine. Fix: name the archive by
  path as the Go arm does; the cheap guard already exists — a
  `build-id.sh --verify` per built binary, since the id only reaches
  the executable if the archive was really linked in.
- **guests/go/filedialog/filedialog.go computes its scene directory from a
  bare `os.TempDir()`** — the same defect the Go clipboard guest had on
  iOS, where the harness expands `$TMP` to the app's Documents rather
  than a private container (Rust and Swift both carve this out). It
  cannot fail today because filedialog is rust-only on the iOS runner;
  it becomes a real failure the moment that leg is added.


- **DEFECT — the handle bindings' transaction liveness check tests
  `closed` but not the THREAD** (bindings/go/app.go,
  bindings/csharp/KayaApp.cs; found 2026-08-07 by the mobile-threading
  research, not by a gate). tools/check-tx-liveness.sh's own doctrine
  says the HANDLE bindings refuse a closed transaction at a write
  chokepoint while the AMBIENT ones check the thread instead — but a
  handle binding used from the wrong thread with an OPEN transaction
  passes the check. A C# `async` handler resuming on a pool thread
  walks straight into it. This is a desktop defect today, not a mobile
  one. Fix: the handle bindings check both; guard: extend
  check-tx-liveness with the wrong-thread clause and watch it fail.
- Two smaller findings from the same research: CPython's
  `PyGILState_Ensure`-during-finalization hang would compound the known
  exit hang at crates/kaya/src/harness.rs:1832-1854 if Python ever runs
  on mobile; and signal-handler ordering (Rust std's stack guard, a
  guest runtime's handlers, the host crash reporter) is a three-way
  negotiation nobody currently owns — it becomes real the moment a
  second runtime lives in the process.


- **A todos-c leg hung for 180s once on linux/x11 (2026-08-07) and has
  not reproduced.** It died at the FIRST assertion — the guest never
  came up at all — inside a full matrix; the leg then passed in the
  record matrix minutes earlier and in five consecutive targeted runs
  afterwards (10 legs, 1-2s each). Recorded so the second occurrence
  starts from here rather than from scratch: what to capture next time
  is the guest's state while it hangs (is the process alive? did it
  reach the GTK main loop? does the harness handshake show?), because
  a 180s stop at step one is a startup deadlock, not a slow scene.


- **Undo follow-ups carried out of the depth slice (2026-08-04).**
  CLOSED 2026-08-05 by the completion pass, which took all of them in
  one slice rather than accumulating stages. One is a ratification the
  maintainer owns and is stated as a proposal, not a change; the rest
  are done or answered from evidence. Commit forthcoming; the working
  record is scratchpad/undo-completion.md.
  - ~~**A fully-undone episode is not redoable.**~~ **FIXED.** A walk
    that reaches the run's start now CLOSES the episode and pushes it
    onto the redo side (`Scene::note_native_undo`), so it redoes through
    the same machinery a coarsely-undone episode already used — its
    after-image written by the core, named by the same `redone`
    occurrence. No wire moved and no backend was touched: every arm asks
    the core for the route first, so `route_redo` answering `Core` where
    it answered `Nothing` changes behaviour on all five.
    The parenthetical in the old entry was wrong and is worth keeping
    for the correction: the native tier's own redo does NOT cover for
    it while the field keeps focus — kaya's Edit>Redo consumes the
    command and, unbanked, routes it to `Nothing`.
    Pinned by two unit tests beside the ledger tests and by
    tools/scenes/undo.steps, which reads the ENABLEMENT before
    activating (unbanked, the first failure is `menu "Edit>Redo" reads
    "disabled", wanted "enabled"` — watched, with the banking reverted
    and the tree rebuilt).
  - **A stamped copy's typing is not banked** — MEASURED, and it is a
    RATIFICATION the maintainer owns, so the tree is unchanged on it.
    The deciding fact: the `undone`/`redone` payload's `texts` run is
    fixed-arity PAIRS (`I64 widget id, Str` — spec.rs, wire.rs's one
    encoder), while `entries`/`orders` are arity-first GROUPS that can
    carry an instance path. A stamped copy's identity on that channel is
    `(template node, key path)`, so an instance field is NOT addressable
    on the existing wire.
    The core half alone is cheap — `run_body` already builds the
    template-node-to-copy map while stamping and discards it — but
    building only that would restore the widget while handing the app a
    pair naming an id it cannot resolve, which breaks D5's "this record
    is the ONLY thing the app hears" silently. The options (A: make
    `texts` arity-first, hash moves, no backend cost; B: ratify
    native-tier-only for stamped fields, with the reactive doctrine's
    own answer — bind the row's text to a record field and the `entries`
    run already carries it; C: carry the internal id, named only so it
    is not rediscovered) are written out with their bills in
    scratchpad/undo-completion.md §ITEM 2.
    **RULED 2026-08-06, option A (the maintainer): `texts` becomes an
    arity-first group like its two siblings, instance paths join the
    channel, the spec hash moves, the eight bindings' delta decode and
    the folding guests move with it, and no backend moves (measured,
    not assumed). Stamped-row typing then joins the ledger with the
    same guarantees as everything else — the reactive doctrine's own
    answer, since text is app state everywhere else in the design.
    Ships as the final undo slice, immediately after this one.**
  - ~~**note_native_undo has no redo twin.**~~ **RESOLVED BY EVIDENCE.**
    The item said "revisit with the first arm whose platform
    distinguishes them"; all five do, and every one already feeds the
    distinct query into `route_redo`, which is where the distinction is
    consumed. The sample's third argument is not "can this walk go on" —
    it is the EXHAUSTED-BACKWARD-WALK test, and a `canRedo` there would
    read false at the end of a forward walk and send the core backwards.
    Three arms say so independently at their own call sites
    (KayaSwiftUI.swift, KayaCompose.kt, gtk.rs — which further refuses
    to report a redo that moved nothing). The forward analogue is
    unreachable for A1's reason: the platform's redo stack is created by
    the backward walk and reaches exactly as far as it came back.
  - ~~**The interpreter now writes a node's text on a routed native
    undo.**~~ **ANSWERED BY THE FAN-OUT.** The "second look when another
    arm needs the same move" happened: no other arm needs it, and each
    measured why. iOS deliberately does NOT write the node (UIKit's undo
    is an ordinary text replacement, so the binding setter already ran);
    Compose does not either (the undo moves the shared TextFieldState);
    GTK and WinUI own raw controls. The mac write is §3a's rule where
    §3a's premise fails — a declarative layer between the widget and the
    model — and it is now paired with a gate
    (tools/check-native-undo.sh) rather than with a note.

  From the fresh-key breadth arms (2026-08-05), a doctrine question
  for the maintainer — RULED same day, option B: the entry/milestone2
  carve-out covers the event-receiving mechanism only (DESIGN.md,
  Binding conventions, has the ratified scope); construction and
  collection idioms graduate to sugar. Entry graduates first,
  milestone2 rides the next slice, and the gate clause extends to it
  then.
  - **What tier does the entry scene sit at, per language — and why is
    the tree split?** DESIGN.md sanctions entry and milestone2 as "the
    documented floor" for the raw occurrence loop, and four entry
    guests (rust, swift, ocaml, haskell) are spelled at the explicit
    widget floor with hand-counted keys — but python's is
    sugar-constructed, and go/csharp/java sit in between. The
    fresh-key slice ruled conservatively: entry keeps hand-spelled
    keys in ALL EIGHT languages (uniform spelling for a documentation
    scene; four arms' adoptions were reverted unrun). The open call:
    either the entry guests all migrate to the construction floor
    (making the demonstration uniform), or the "documented floor"
    carve-out is narrowed to the occurrence loop alone and the
    construction/collection spelling graduates to sugar everywhere.
    Whichever way, the carve-out should be stated per DESIGN.md's
    Binding-conventions rule, and a gate clause should pin the chosen
    tier so the split cannot silently re-open.

  From the milestone2 graduation (2026-08-05):
  - **CLOSED 2026-08-07 — GUARD GAP: the harness resolves widgets by
    registry, so a leg cannot see a widget that never got parented.**
    Proven by the defect it hid: Swift's milestone2 window rendered TWO
    widgets (the step button and status label) instead of its full UI
    for milestones, with every leg green, because `kind#index` targets
    resolve against per-kind registries populated at create/stamp time
    (KayaSwiftUI.swift:410-431) — never by walking the mounted tree.
    An unparented widget answers reads, produces expected strings, and
    displays nothing.

    The entry asked for a HARNESS-level assertion in both
    interpreters. It was built one layer lower instead, and the reason
    is the reason it is now free: `Scene::apply` is the funnel for all
    five backends (gtk.rs:1079/:6412, winui/mod.rs:829, capi.rs:2335
    for the two interpreters), so ONE implementation covers nine guest
    languages, fires at BUILD time rather than read time — which
    catches an orphan no scene happens to name — and fires in a real
    app that never runs the harness, which a harness-side wall never
    could. The rule the core now enforces:

    > A widget created in a transaction must be reachable from a
    > mounted root by the end of that transaction.

    `crates/kaya/src/scene.rs`: `parent_of` (child -> parent, live
    zone), `mounted_windows` widened from a set to surface -> its root
    widget, and `first_unreachable` at the barrier beside the menu
    domain check. Batch-scoped, not a global sweep, because the core
    never prunes `self.widgets` — DestroyWindow and PopEntry drop the
    surface and leave the ids (that leak is real and still open; see
    the entry below). 14 tests, 4 perturbations watched failing
    (barrier off -> 6 negatives fail; the perturbation helper neutered
    -> the two shipped-defect negatives fail on their substitution
    count rather than passing vacuously; DestroyWindow keeping its dead
    root -> 1 fails; the cycle refusal off -> 1 fails and the bounded
    walk still terminates).

    WHAT IT DOES NOT COVER, so nobody reads it as total: an orphan made
    by a BACKEND — one that receives `ApplyOp::AddChild` and fails to
    reparent — is invisible to the core, which sees the op and not the
    toolkit's tree. Only GTK's `WidgetExt::root()`, WinUI's `XamlRoot`
    and the interpreters' `parents` maps can see that one. No such
    defect is on record; all three recorded instances were made above
    the core, in a binding. That tier stays open below.
  - **The sibling suspicion was right, and a THIRD instance was still
    live at HEAD.** `guests/swift/menus.swift` was fixed by eye in
    aadbe9e. `guests/swift/feed.swift:29-65` was not: `promote`,
    `status` and `list` were built at ambient parent 0 and only
    MENTIONED inside `tx.row { }`, whose result builder discards a bare
    expression — so the mounted row had no children at all and
    `feed-swift-swiftui` passed every leg against an invisible window
    for two weeks. The wall's first run named it in one line, with no
    debugging: the whole mac lane came back 257 PASS / 1 FAIL and the
    one failure printed which widget and why.

    OPEN — the fix is one guest file, and the wall arm does not own
    guests/. The correction is aadbe9e's: declare each child WHERE IT
    STANDS, inside `tx.row { }`, instead of building it outside and
    naming it within. Proven green in scratch before this was written
    (the doctored guest ran the real `feed.steps` to
    `KAYA_SELFTEST: OK`), so it needs applying and re-running, not
    designing.
  - **STILL OPEN — the core never prunes `self.widgets`.**
    `DestroyWindow` (scene.rs) removes the window, its nav stacks, its
    sections and its shortcuts, and touches `self.widgets` not at all;
    `PopEntry` is the same. A destroyed tree's live widget ids stay in
    the map forever. Harmless today and deliberately routed around (the
    reachability barrier is batch-scoped for exactly this reason, and a
    test pins that a destroyed window's widgets are not re-accused),
    but it is a leak in a long-running app that opens and closes
    windows.
  - The Swift binding's template zone never pushed a parenting frame
    for forEach/when bodies (fixed 2026-08-05 in the graduation: an
    inTemplateBody frame at all four combinators, matching Java's
    always-present barrier). Kept here as the failure-class record:
    the defect survived because NO Swift guest had ever declared a For
    inside a template container — first-use-of-a-combination holes are
    what the scene matrix's breadth is for.

  From the fresh-key depth arm (2026-08-05):
  - ~~**DEFECT — a derived signal is not recomputed after an undo.**~~
    **RETRACTED 2026-08-06, ratified by the maintainer — a false alarm
    from call-graph reading, and the record stays because the next
    reader will make the same inference.** The claim was: absorb_undo
    never calls recompute_derived, therefore a derived label goes
    stale when undo restores or removes entries. The claim's premise
    is true and its conclusion is false: a derived write is an
    ordinary WriteSignal batched into the SAME transaction as its
    mutation (recompute_derived pushes unconditionally — no cache, no
    skip), and Scene::bank_group banks EVERY dirty signal into both
    directions of the step, so undo restores the derived value
    together with the collection it derives from. They cannot
    disagree. The C# and Swift absorb comments said this all along;
    the resolution slice propagates that comment to the six bindings
    that skip silently, and the todos scene gains an undoable step so
    the correct behavior is pinned by the matrix, not trusted.
    ONE RESIDUAL, real but unconstructible today: a derive declared
    AFTER a step was banked is absent from that step's signal set, so
    undoing past its declaration leaves it inconsistent until the
    next mutation. Every guest declares derives in the opening build;
    if a scene ever declares one late, this line is the warning.
  - **Residual, taken deliberately: the toolkit's child order after an
    undo restore is asserted at the app's mirror (the keys label), not
    at the toolkit.** `expect_order` would need the For's container to
    be the only column (the reorder root-as-row trick) across all 8
    guests. Core-side, an undo's re-insert and re-order travel the
    same `apply_delta` path the reorder scene already exercises at the
    toolkit.

  Two more carried out of the fan-out (2026-08-04), both gate gaps
  rather than behavior, both CLOSED:
  - ~~**check-steps is blind to the C floor.**~~ **FIXED 2026-08-05**
    (`sweep_c_floor` in tools/check-steps.sh). Not a row in the existing
    per-language sweep, and the gate says why: that sweep demands a MAC
    leg for every scene in mac's SCENES whose guest file exists, and the
    C floor deliberately carries a different scene set per lane — a `c`
    row there would demand ten mac legs nobody intended. It is swept
    instead from the two declarations the floor actually has: every
    scene guests/c/Makefile builds must be RUN by some lane (keyed on
    the binary path `c-guests/<scene>`, the one signature all three leg
    spellings share), a runner that NAMES the C scenes it builds must
    run each of them, and a leg pointing at a binary the Makefile never
    builds is refused. Watched failing three ways — the mac undo leg
    deleted (both clauses fire), the linux todos leg deleted, a leg
    re-pointed at a typo — each restored by sha256.
  - ~~**The shared scene's stated D5 text-run proof cannot fail.**~~
    **FIXED 2026-08-05 by the fresh-key depth arm**, which reshaped
    tools/scenes/undo.steps exactly as this entry asked: the add's
    empty-draft refusal now reads the app's own draft at the one moment
    the app's copy and the widget's disagree. Watched failing three ways
    on the mac leg (the whole `delta.texts` fold deleted, the undone
    half alone, the redone half alone), so both directions of the run
    are independently load-bearing.



- ~~**DEFECT — filedialog_java is a coin flip on windows**~~ — FIXED
  2026-08-03, and GUARDED. The per-dialog STA thread ran
  `CoUninitialize()` the moment `Show()` returned, which "forces all
  RPC connections on the thread to close" while the Shell's own
  workers still held proxies into that apartment, so RPCRT4 raised
  RPC_E_DISCONNECTED (0x80010108) on a comdlg32 worker. Only the JVM
  turned that into a fatal error. There is now ONE dialog apartment
  per process, started at the first pick, pumping, never uninitialized
  — `dialog_apartment` in crates/kaya/src/winui/mod.rs carries the
  numbers. The measured grace period (the other candidate remedy) is
  recorded there too, and rejected: 5ms still failed 2 of 15.
  THE GUARD IS THE SCENE ITSELF. A vectored handler counts
  first-chance RPC_E_DISCONNECTED for every harness build, and the
  WinUI `Stage::finish` fails the scene on a non-zero count in every
  language. Watched failing: with the defect put back, the RUST leg —
  which passed 10/10 on that same defect before the guard existed —
  went 6/12 red, each naming the mechanism. 145/145 with it armed, so
  its false-positive rate on this lane is zero.
  READ THE TRAP BEFORE RE-MEASURING ANYTHING LIKE THIS
  (docs/traps.md, §"A windows race can stop reproducing"): the defect
  reproduced 8/10 at 20:00 and 0/10 on the SAME BUILD an hour later.
  It comes back under load.

- **The step-failed line exists in ONE of the three harnesses
  (2026-08-03).** A step's final failure text is now printed the moment
  it becomes final — `KAYA_HARNESS: step-failed <text>`, in
  swift/KayaSwiftUI.swift's bounded-retry wrapper — so evidence survives
  an abort that runs before the verdict line. It was bought by the iOS
  picker session, where a scene-designed panic
  (crates/kaya/src/capi.rs's one-dialog-per-process guard) destroyed the
  failure list carrying the host driver's self-diagnosing sentence, and
  the log showed only a panic and a timeout.
  The same wrapper shape, and the same exposure, exist in
  android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt and in
  crates/kaya/src/harness.rs (which serves GTK and WinUI): any panic
  before the verdict loses the list the same way. Mirroring is a
  four-line edit in each; both were left out of that session only
  because each carries its own gate to re-run (check-compose +
  check-detekt for Kotlin, the harness unit tests for Rust) and the lane
  under repair was iOS. Do them together, and keep the spelling
  byte-identical — the three harnesses are compared by eye far more
  often than by tool.

- **Follow-ups from the WinUI chord-drop fix (2026-08-03).** The race:
  chords were dispatched over TWO routes split by leaf kind (79dcd1d),
  and the XAML-accelerator route PERMANENTLY DROPS a chord arriving
  within ~45ms of the previous chord's activation — measured 42% per
  commands leg, language-independent, fixed by dispatching every
  catalog chord from the thread key hook against core.menu_shortcuts
  (the same table that gates the harness verb), 0/46 after. Left open,
  in priority order:
  - A text gate pinning the one-route rule: key_hook's dispatch names
    all three of MenuItemKind::{Action,Toggle,RadioOption} and no
    consume path is conditional on kind. Cheap check-verbs-style
    clause; the compile-time exhaustive match guards NEW kinds but not
    a deliberate re-split.
  - The echo premise (a programmatic IsChecked set must not raise
    Click) is now load-bearing for radios too and is checked only by
    menu_probe behind KAYA_WINUI_MENU_PROBE. Promote canary 1 out of
    the flag gate, the way assert_chord_premise is unflagged.
  - No scene presses a chord on a DISABLED item; the fixed route makes
    that fully inert (consumed, no stamp, no emit) — believed right,
    unverified live.
  - The same two-route shape exists on GTK (GtkShortcutController),
    SwiftUI (.keyboardShortcut) and Compose. Those lanes are green but
    nobody has measured whether their pass sits on the same
    tens-of-milliseconds gap. One timing probe each (press a chord
    ~20ms after the previous chord's occurrence) before assuming WinUI
    was special.
  - Unexplained: the lane was recorded 145/145 at the WinUI clipboard
    slice, which a stable 42% per-leg rate makes essentially
    impossible. Either that run was an outlier or the VM's timing
    distribution shifted around the ~45ms boundary. The experiment if
    anyone wants it closed: rebuild the exact 48cfbad tree and loop
    commands_rust there.

- **GAP — an `#if os(iOS)` branch in a SWIFT GUEST is invisible to
  every fast gate.** Found 2026-08-03 while wiring the iOS clipboard
  legs: tools/swift-typecheck.sh's guest loop compiles the guests for
  macOS only, so the iOS scene_root branch guests/swift/clipboard.swift
  needed (the §7.6 android trap's cousin — the guest and the
  interpreter must agree on $TMP) typechecks nowhere until
  run-sim.sh's own build loop compiles it on a booted pool. The
  interpreter's iOS half earned its typecheck pass for exactly this
  class; the guests deserve the same — an iphonesimulator -typecheck
  loop over guests/swift/*.swift in swift-typecheck.sh, gated the
  same way (skip with the loud note when no simulator SDK exists).
  Cheap; nobody has been burned yet; write it before someone is.

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
## MAYBE: the WinUI seed writes once too, on a board with a relay on it

Raised 2026-08-04, alongside the mac seed's fix (docs/traps.md,
docs/clipboard-plan.md §9). The macOS seed was measured LOSING its
write, silently, whenever another process touched the pasteboard inside
`osascript`'s clear-then-put window — 12 of 12 writes gone against a
competitor writing every 10ms, rc=0 and no stderr each time. Its remedy
is a bounded re-issue: the seed is idempotent, and a write that was
refused cannot be waited into existence.

`crates/kaya/src/winui/mod.rs`'s `clipboard_seed` has the same SHAPE —
`Set-Clipboard`, then poll `Contains*` for 5s, then fail — on a board
that has the same second principal available to it: the Windows guest's
clipboard is relayed to and from the host by SPICE's vdagent whenever
UTM's clipboard sharing is on, which it is on this machine. Nothing has
been observed failing there; the windows lane's five clipboard legs
pass. So this is recorded, not scheduled.

WHAT WOULD DECIDE IT. A windows clipboard leg failing with
`KAYA_SEED_LOST` or `never appeared on the clipboard` is this exact
class, and the fix is the mac one transliterated: re-issue the write
inside the poll instead of polling harder. Do not go looking before
then — the arm was settled 2026-08-03 and a speculative rewrite of a
green lane's seed buys nothing.

## MAYBE: the other three backends say nothing when a standard command is inert

Raised 2026-08-04 with the mac paste fix (docs/traps.md, "A standard
clipboard command that is DISABLED does nothing"). A role item works out
its own enablement — what the clipboard offers intersected with what the
focused widget accepts — and a disabled item is inert on every backend,
which is right and matches native chrome. What only the SwiftUI
interpreter now does is SAY SO: `kayaRoleInertNote` prints the
intersection that came up empty, plus whether the board has changed
since kaya wrote it, when a harness `menu_activate` lands on a command
that cannot act.

The verdicts, one per backend (invariant 2):

- SwiftUI mac and iOS — DONE, one body, the defect's own platform.
- GTK / linux — DEFER. The failure needs a second principal writing the
  one clipboard, and each lane run owns a private compositor inside its
  container; there is nobody else to write it. Copy the shape if a real
  desktop session ever runs these legs.
- WinUI / windows — DEFER, and the strongest candidate of the three: its
  board has the same SPICE relay on the other side as the mac one (see
  the seed MAYBE above). A windows clipboard leg failing on a stale
  label after a `menu_activate "Edit>Paste"` is this class. The arm was
  settled 2026-08-03 and this session was not to touch it.
- Compose / android — DEFER. One clipboard per device, the emulator's
  host bridge severed both ways (docs/clipboard-plan.md §7 finding 4),
  so again no second principal.

Cheap when it comes: the note needs the focused node's accept list, the
board's type list, and the changeCount the backend last wrote — all
three already exist in every backend's clipboard arm.

## SOLVED: template-node props (was "grow, the a11y pair, accepts, on_paste")

Raised 2026-08-10 by the sugar pass; CLOSED 2026-08-11 by the props
slice (docs/tpl-props-plan.md). A template node now carries the a11y
trio (source-taking — a stamped row announces its OWN name), a const
accept list, grow, and a working paste hook, in all eight bindings,
gated receiver-keyed in check-sugar-surface with negatives watched.

What the closure taught, kept here because the entry predicted wrong:
the paste hook was not "unreachable for want of a registrar" — seven of
eight bindings HAD the registrar and the dispatch, and the hook still
could never fire, because every backend gates the paste occurrence on
the focused widget's accept list and no template node could declare
one. A silent REGISTRAR, not a silent drop. The keystone was `accepts`.
The a11yrows scene (stamped a11y read from the real tree) and the
clipboard scene's stamped paste target are the legs that watched both
arms fire for the first time.

Still open from the entry, deliberately: spacing and align stay
floor-only on template containers, uniformly, in every binding alike.

## SOLVED: the floor tier is repo-wide (was "a guest at the FLOOR fails no gate unless its scene is in the tables")

Raised 2026-08-10; CLOSED 2026-08-11. tools/guest-floor.py now carries
the whole per-language floor vocabulary over every sugar guest:
absolute patterns for every spelling with no legitimate use, a
paren-balanced >=2-argument scan that tells kaya's For (collection
first) from every stdlib forEach (body alone), Swift's trailing-closure
distinction, the labelled-argument boundary that keeps OCaml's sugar
out of its floor family, and generated files exempt by their own
marker. Every rule carries a fire line and a quiet line run through the
real engine on every invocation.

The "floor IN A SCENE THAT HAS SUGAR FOR IT" distinction the entry
called a real piece of design dissolved instead of being built: the one
irreducibly contextual family (SetText, the verb/floor name collision
in six languages) was retired by giving those six Rust's two-name split
— the template prop write is hidden or renamed, so the verb keeps its
name and the floor spelling became sweepable or unspeakable. The
receiver's type was the discriminator no regex could see, so the type
system was made to hold the wall instead.

The census that drove it: 44 patterns x 284 guest files = 36 hits — 11
floor (all converted), 21 legitimate, 4 sugar gaps (each closed:
Tpl.each in OCaml and Haskell, Haskell's live bound slider, the
scalar-element token). Sweep result today: zero hits, zero exemptions.

## SOLVED: the rust guests cost ~11s to START (macOS walked their build directory)

Measured and FIXED 2026-08-10, while diagnosing two matrix failures
during the template-zone sugar pass. Kept because the mechanism
generalises and the wrong first answer is instructive.

Per-language leg times for one scene, mac lane, machine quiet
(tools/validate-mac.sh, `split`):

    rust 38s   ocaml 16s   haskell 10s   swift 9s
    python 1s  go 0s       csharp 0s     java 1s

**The wrong answer, written down first:** that a Rust example links the
whole crate statically and pays a dyld pass over a big binary. It is
tidy, it fits the language split, and it is false. The binary is 4.8 MB,
and the other compiled guests (ocaml, haskell, swift) were not slow for
that reason either. It survived long enough to reach this file.

**The real one, from `sample` on the live process** — which is what the
lane's own timeout diagnostic tells you to do, and it named this in one
shot. The whole stack sat in:

    NSApplication init -> _NSInitializeAppContext -> _isMenuBarVisible
      -> GetCurrentProcess -> _RegisterApplication -> _LSApplicationCheckIn
         -> CFBundleGetValueForInfoDictionaryKey -> _CFBundleReadDirectory

macOS registers every UNBUNDLED executable with LaunchServices at
launch, and CoreFoundation reads the executable's CONTAINING DIRECTORY
as if it were a bundle — enumerating every sibling.
`target/debug/examples` is a build directory that accumulates a hashed
binary, a `.d` and a `.dSYM` per example per build. On this machine it
had reached **776,613 entries and 3.8 GB**.

Same binary, back to back:

    target/debug/examples/split   7.7s
    a two-entry directory         0.13s

Fifty-nine times. Across 32 legs that was 979s of the mac lane's 2020s
of leg time — 48% — and it is the entire gap between rust (mean 30.6s)
and go/python/csharp/java (mean ~1.2s). The staged binary is as fast as
any of them; nothing about Rust was ever involved.

It is also what made the parallel matrix a coin flip: contention
stretched those legs ~3x and `split-rust` at 38s crossed the 120s
per-leg timeout. Two consecutive matrix runs failed on different lanes
with nothing wrong in the tree.

**The fix:** validate-mac stages the built examples into
`target/rust-guests` (list derived from `$SCENES`, so a new scene cannot
be built and then left running out of the build directory) and asserts
that directory stays small. `tools/check-shell.sh` refuses any `run`
line that execs out of `target/{debug,release}/{examples,deps}`, with a
self-test, watched failing.

**Nothing is left, and the measured result is bigger than the diagnosis
predicted.** Per-language leg totals across the whole mac lane, before
and after:

    rust   979s -> 50s      ocaml   348s -> 35s
    haskell 272s -> 41s     swift   252s -> 48s
    go       53s -> 50s     python   40s -> 41s
    java     40s -> 38s     csharp   36s -> 40s

    total leg-seconds 2020 -> 343; lane wall 547s -> 223s

The prediction was that rust alone would collapse. Ocaml, haskell and
swift collapsed with it — from 10.9s, 8.5s and 7.9s means to 1.1s, 1.3s
and 1.5s — and that is the part worth keeping. They were never slow for
their own reasons: they ran CONCURRENTLY with 32 rust legs, each walking
a 776,613-entry directory through a single LaunchServices XPC service,
and they were starved by the contention. All eight languages now sit
between 1.1s and 1.6s.

So a per-leg cost paid by ONE language showed up as every language being
slow, which is why the per-language table at the top of this entry read
as a language story and was not one. When a whole lane is slow, the
shape to look for is a shared serialising service, not a per-language
trait.

## Live-zone a11y props take only constants — except in Python

Opened 2026-08-11 by the props slice, which noticed it while landing the
TEMPLATE zone's sourced a11y: Python's shared handle base gives its LIVE
widgets signal-sourced a11y (one surface serves both zones there), while
the other seven bindings' live `a11y_label` takes a constant string
only. So the eight disagree — and the direction of the disagreement is
odd on its face: a STAMPED copy's label can follow a signal in all
eight, a LIVE widget's can in one.

A dynamic live label is real accessibility (a play/pause button's
spoken name flips with its state), so the likely resolution is widening
the seven, as a sweep with a gate clause — never one binding at a time
(the template-grow lesson, written where that clause lives). Python is
left wide meanwhile: narrowing it would need an artificial wall in the
one binding whose design makes the uniform width free.

## tools/tpl-surfaces.py sees constructors, not props — three follow-ups

Opened 2026-08-11. The census's zone readers match constructor
signatures, so the props slice's surfaces are held by check-sugar-surface
clauses and per-binding tests instead. Three specific gaps the fan-out
reports named:

- **Go**: the reader's pattern sees neither a digit in a method name
  (`SetA11yID`) nor a generic method (`BindA11yID[`). The surface
  pairing lives in bindings/go/tplzone_test.go meanwhile; the two
  should agree or one should go.
- **Java**: `Tpl` and `RowSurface` want the level-holding clause Rust's
  Tpl/Row pair has — a prop on one and not the other is reachable
  through `tx.forEach` and not `for (var row : ...)`.
- **C#**: the generated `<Rec>Row` façade wants the same; a tested
  implementation was offered at the fan-out
  (scratchpad/csprobe/facade-parity.py, watched failing against HEAD's
  11 missing forwards including a year-old SetGrow drift).

## The styling scene's depth stubs (slice 1 mid-flight, expected to close with the fan-out)

Three backends hold `depth_stub("styling")` while the SwiftUI
interpreter carries slice 1's one real brand lowering
(docs/styling-plan.md §3 — depth then breadth, the standing pattern):

- ~~**DEPTH STUB: styling on gtk** — the accent lowering is the
  `--accent-bg-color`/`--accent-fg-color`/standalone override route,
  measured working in kaya's container by the styling research, plus
  the adw feature bump v1_4 → v1_7 it needs. Fan-out work; the inset
  arm is already live there.~~ LANDED 2026-08-12: the three custom
  properties per appearance, re-written when the session flips, plus
  `.destructive-action`/`.suggested-action`/`.heading` + the AT-SPI
  heading role. NO adw bump was needed — the override is CSS the
  runtime library reads (1.6+, and the image ships 1.7.6), while the
  Rust surface it uses (`StyleManager::dark`) is 1.0-era; measured by
  building and painting at `v1_4`.
- ~~**DEPTH STUB: styling on winui**~~ — LANDED 2026-08-12. The brand
  accent and the two button roles were already real (the six
  `SystemAccentColor*` stops in Light+Dark ThemeDictionaries, crossed
  the way Fluent reads them, never `SystemAccentColor` itself and never
  a HighContrast entry; `AccentButtonStyle` for prominent,
  `SystemFillColorCriticalBrush` on the caption for destructive —
  Fluent ships no destructive button); the stub survived on HEADING
  alone, blocked by one missing line in tools/winui-bindgen's filter.
  `Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel` is now
  filtered in, and regenerating turned the four `usize` vtable pads
  into real methods — `AutomationProperties::SetHeadingLevel` (the
  setter) plus `GetHeadingLevel` on `AutomationPeer` and its subclasses
  (the read). The role arm is SetHeadingLevel(`Level2`) +
  `SubtitleTextBlockStyle`, and `WinUiStage::ax` consults HeadingLevel
  BEFORE the control-type ladder, because UIA has no heading control
  type — a heading TextBlock reports `Text`, so a type-first ladder
  answers `label/Sections` where the scene froze `heading/Sections`.
  That ordering is pinned by `ax_role`'s unit tests, watched failing.
  The enum's members are `None`, `Level1`..`Level9`; the docs'
  `HeadingLevel1` spelling is the UWP one and does not exist here. NOT
  PROVEN HERE: no leg ran — the windows lane needs its styling legs
  wired in tools/deploy-win.sh, and the pixels are the captures'
  business. (The inset arm was already live.)
- ~~**DEPTH STUB: styling on compose**~~ — LANDED 2026-08-12. The
  seed-derived scheme goes through the MaterialTheme root the foundation
  landed, the contrast level is read from UiModeManager and re-read
  through a ContrastChangeListener (a scheme that samples it once is the
  MDC #3524 no-op rebuilt one layer up), and the appearance is unpinned:
  the three app manifests now name kaya's own DayNight theme, the theme
  root paints the scheme's background and content colour, and the lane
  was run 82/82 in BOTH notnight and night with the mode read back
  before and after. Roles lower to M3's own emphasis ladder (outlined
  floor -> filled prominent, error-role container for destructive,
  `heading()` semantics + titleLarge for headings, which the published
  AccessibilityNodeInfo reports as `heading/` and which was watched
  falling back to `label/` with the lowering perturbed out). WHAT IS NOT
  DERIVED and is now its own open question below: the secondary,
  tertiary and neutral palettes stay Material's baseline, because
  deriving them needs HCT chroma clamping and that is a dependency
  decision rather than a coding one.
- **THE FULL M3 SCHEME FROM A SEED NEEDS A DEPENDENCY DECISION** (open,
  Akhil's; measured 2026-08-12 while landing the entry above). The
  Compose brand lowering derives the PRIMARY family from the seed —
  Material's own tone→role table, its own contrast curves, and its own
  tone function (CIELab lightness) with a gamut loop that keeps the tone
  and gives up chroma. What it cannot do without HCT is the other four
  palettes, whose whole content is chroma clamping: secondary is the
  seed's hue at chroma 16, tertiary at hue+60, the neutrals at chroma 4
  and 8. Visible consequence today: under a brand, a NavigationBar's
  selected-item indicator (secondaryContainer) and the page's surfaces
  keep Material's baseline lavender hint. The four routes, priced:
  (a) vendor Google's Java sources (Apache-2.0, a few thousand lines in
  the tree, nothing to pin — the styling research's own first choice);
  (b) `com.materialkolor:material-color-utilities`, a third-party KMP
  port of the same code, one pinned line; (c) MDC-Android 1.12.0, which
  bundles the utilities but marks every class `@RestrictTo` and drags
  appcompat and a dozen more artifacts behind it (measured: 46 classes
  under its `color/utilities` package, all restricted);
  (d) leave it — the accent family is what every other backend brands
  too. Nothing here is urgent and (d) is a real answer.

## The typeface scene's depth stubs (Slice 2b mid-flight, expected to close with the fan-out)

The depth landed 2026-08-16: spec (`set_brand_typeface` / `set_typeface`,
the `platform` enum) + the SwiftUI mac arm + the Rust binding
(`brand_typeface` / `brand_typeface_with`) + the `typeface` scene, mac
only. Four backends decode the record and refuse through the depth-stub
helper, which is what holds the other lanes' legs off in check-steps and
check-stubs (docs/styling-plan.md Slice 2b — depth then breadth, the
standing pattern):

- **DEPTH STUB: typeface on swiftui/ios** — the APPLY side is already
  live on iOS (the same fresh-descriptor route, plus UIFontMetrics for
  Dynamic Type and the Bold Text weight step the probe measured a
  substituted family dropping). What is not proven is the OBSERVATION:
  `expect_typeface`'s read has been measured on a real macOS window and
  never on a device, so the iOS runner wires no typeface legs. Closing
  it is the same UITextView/UITextField walk run in the simulator, with
  the presence gate's negative watched there too.
- ~~**DEPTH STUB: typeface on gtk**~~ — LANDED 2026-08-16. `:root {
  font-family }` in kaya's own provider at APPLICATION priority (never
  `*`, which would take the monospace slot the editor lives in), the
  resolved-family read through `ctx.load_font(...).describe().family()`,
  and the font-BYTES form through `pango_font_map_add_font_file`. Green
  on BOTH display legs, hand-run, with the fallback negative watched
  going red. TWO findings the probe did not have:
  fontconfig's `FcConfigAppFontAddFile` — the documented app-font route —
  RETURNS SUCCESS AND DOES NOTHING once GTK has initialised, which is
  every position a kaya apply can occupy (measured three ways); and
  `Georgia` is not an unmatched name on that image but an ALIASED one,
  which fontconfig resolves to DejaVu Serif rather than to the default
  sans. The trap the probe DID measure stands and is why the read is the
  only observation: a genuinely unmatched family renders byte-identically
  to the unbranded window.
  The LEG is closed too, 2026-08-16: the blocker was that no INSTALLED
  family resolves to one byte-frozen string on every lane (mac/windows
  resolved `Georgia`, linux `DejaVu Serif`, android `Noto Serif`), and
  the vendored font answers it — the guests ship the OFL Sora bytes
  through the blob channel and every lane resolves `Sora`. So
  `tools/linux/run-suites.sh` now wires seven `typeface` legs on both
  display protocols, styling's roster minus the C floor (which has no
  typeface guest), each through `a11y-leg.sh` for the closing
  `expect_ax`. No `KAYA_FONT_FILE` is set there: the guests' default path
  is repo-relative and the container runs from `/work`, the mount. See
  the styling plan's Slice 2b and
  scratchpad/styling/typeface-gtk-arm.md §"the one blocker".
- ~~**DEPTH STUB: typeface on winui**~~ — LANDED 2026-08-16, green on the
  Windows VM. TWO writes, because the platform has two kinds of text: an
  app-level dictionary redefining `ContentControlThemeFontFamily` (+ the
  KeyTip/Pivot keys, never `SymbolThemeFontFamily`) for the 58 CONTROL
  styles, and a local family on every `TextBlock` AT CONSTRUCTION. The
  second is where the probe's proposal was improved on: a local value
  outranks a Style setter in XAML's precedence whatever order they
  arrive, so setting the family in a `text_block()` factory makes "a ramp
  style applied without the family write" — the `XamlAutoFontFamily`
  literal trap — unrepresentable, instead of pairing the two calls at
  each site. `expect_typeface` cannot read a name on this platform (UIA's
  Text pattern is absent in-process and an out-of-process client is
  barred at Cargo.toml), so it reads XAML's own laid-out WIDTH and
  BASELINE for a pinned string and names the fallback through
  DirectWrite. Findings the probe did not have, all measured on the lane:
  **the VM was never down** — Windows drops ICMP, so the probe's `ping`
  test read a healthy guest as powered off (tools/probe-env.sh:31 already
  said so); **XAML's family lookup disagrees with DirectWrite's** (`Segoe
  UI Variable`, this SDK's `Control.FontFamily` default, is not in the
  system collection and XAML still lays it out as its `Text` sibling), so
  DirectWrite PROPOSES the fallback name and XAML's width confirms it;
  **an unresolved family gets a synthetic 0.9em baseline** while its
  glyphs still come from the fallback face, which is why the fallback is
  confirmed on width alone; and **the blob route is `ms-appx:///`, not a
  path** — an absolute filesystem path, a `file://` URI and
  `AddFontResourceExW` (private AND session-wide, return value 1) all
  render the fallback with no error, while a file under the app root
  works. scratchpad/styling/typeface-winui-arm.md.
  What is NOT closed is the LEG WIRING: `tools/deploy-win.sh` needs
  `typeface` in its depth list plus `run_suite typeface_rust` and a
  checked-in `tools/guest/run_typeface_rust.cmd`, which this arm was
  scoped out of touching — check-steps is RED until they land, and says
  so. Windows is the second lane (after mac) where the scene's
  byte-frozen `Georgia` resolves, so no per-platform row is needed here.
  Two limits of the blob route are unmeasured because no guest ships font
  bytes: the app directory must be writable (an install under Program
  Files is not), and for a DLL-hosted guest `current_exe` is the host
  interpreter's binary, so the app root is its directory and not kaya's.
- ~~**DEPTH STUB: typeface on compose**~~ — LANDED 2026-08-16. TWO
  writes, as the probe measured: `MaterialTheme(typography = …)` for
  Material's own components and `LocalTextStyle provides
  ambient.copy(fontFamily = …)` for kaya's labels and fields, family
  only, so the ambient size stays Unspecified. `expect_typeface` reads
  the SHAPED glyph run's font file and names it out of that file's
  OpenType `name` table, one sample per route, sites required to agree —
  the two obvious reads on this platform (`layoutInput.style.fontFamily`,
  `Typeface.getSystemFontFamilyName()`) both echo the request. The bytes
  form goes to an app-private file, validated with `Typeface.Builder`
  before Compose sees it (Compose's own `Font(File)` throws INSIDE
  composition for a bad blob), and a family this device lacks leaves the
  platform ramp standing and says so, detected at apply time with a
  two-sentinel probe. Both directions of the two-write trap watched going
  red on the lane; scratchpad/styling/typeface-compose-arm.md.
  What is NOT closed is the LEG, the same blocker the GTK arm names one
  bullet up: `Georgia` is absent on the emulator image (and Android's
  family lookup is case-SENSITIVE, so no capitalisation of it hits), the
  request falls back to Roboto and the arm says so — so
  `tools/android/run-emulator.sh` wires no `typeface` legs and
  check-steps says so. Android's row in a per-platform scene would be
  `serif` (→ `Noto Serif`, metric-matched to Roboto so no line box
  moves); a shared BLOB is the other way out, and it is the only one that
  keeps the scene's expected family one byte-frozen string on every lane.
- **The seven other bindings** — `brand_typeface`/`brand_typeface_with`
  in Python, Go, C#, Java, Swift, OCaml, Haskell, plus the C floor's
  explicit spelling, and the `typeface` scene's guest in each.
  check-steps holds the scene rust-only until they arrive.
- **No font FILE ships in the tree yet**, so the `typeface` scene
  exercises the NAME form only. The bytes form is implemented and
  reachable (`brand_typeface_with(.., font: Some(bytes))` →
  CTFontManager, in-process scope, family name read back off the
  registered descriptor) but nothing asserts it end to end: there is no
  font asset in the repo and no license decision about adding one.
  Closing it is one bundled open-licensed face plus a second scene (the
  slot is set once per process, so the two forms cannot share a run).

## Styling follow-ups the fan-out surfaced (2026-08-12, none blocking)

- **~~Font-FILE bundling waits for the asset pipeline~~ REVERSED
  same day (maintainer, 2026-08-16): font bytes ride the existing wire
  blob channel, IN the typeface slice.** The asset pipeline offers
  fonts nothing the blob channel lacks — its real customers are raster
  density variants and OS packaging (the vector-app-art entry's
  future). Register-then-resolve: the blob registers via the
  platform's app-font API, the family name is extracted, and the
  name-based machinery takes over unchanged. The WinUI registration
  route (path#family vs DWrite in-memory loader) is measured at depth,
  not assumed.

- **Sections carry symbols with no harness assertion** (2026-08-16).
  expect_menu_symbol reads menu items' icons from the real tree, but
  nothing asserts a SECTION row's symbol — which is exactly how the
  SwiftUI decode read the I64 at +20 (alignment padding) instead of
  +24 and rendered NO icon while every lane stayed green; a capture
  caught it, not a gate. The fix shape: a section-symbol read through
  the sections ax/real-tree machinery, asserted in the sections
  scene's desktop tail beside the presentation row. Until then the
  captures are the only witness on every backend.

- **The window chrome knob is DEFERRED (maintainer, 2026-08-16)** —
  docs/chrome-plan.md C1/C1b, drafted and held before ratification.
  `chrome: extended` (content under a transparent title bar) is the
  one piece of the modern-mac look that is HARD to extend across
  platforms and easy to break apps with: the content's top band slides
  under the traffic lights (every current scene puts real content
  there), the drag region fights the top row's clicks (WinUI requires
  an explicit drag region or the window cannot be moved), and a
  default flip would change every app's geometry overnight. The safe
  cases ALREADY auto-extend: a sidebar window gets the full-height
  treatment from the platform today, and a toolbar-carrying window
  would get the tall unified bar with the toolbar itself. What the
  knob alone buys is extended-without-chrome (the Zed-shaped editor),
  which only the app can promise its top edge tolerates. REOPENS when
  an app actually wants that shape; the cleaner rule to consider then:
  extended is DERIVED (toolbar or sidebar present), and the knob
  exists only for the chrome-less case. The toolbar construct (C2, the
  promotion list over the command catalog) is a separate question and
  stays in the draft awaiting its own ratification.

- **GTK's and WinUI's window resolvers panic on a not-yet-materialized
  aux window** (gtk.rs `gtk_window` "harness targeted an unknown
  window"; winui/mod.rs "scene validated the window id" — the comment's
  assumption is exactly the bug: the scene DID validate the id, but
  materialization is async, so a harness read racing the apply dies
  instead of polling). Measured 2026-08-16: the sidebar tail's
  click-then-expect_title killed five language legs on linux and two on
  windows while rust/go squeaked by on timing. The sections scene now
  carries an `expect_windows 2` barrier (its count read is panic-free
  and reads the same map, so the panic path is unreachable there), but
  the landmine holds for any future scene that asserts on an aux window
  without a count barrier. Fix shape: the resolvers return Option, the
  Stage reads map None to a pollable "window N not materialized yet"
  miss, and the APPLY-side callers keep the panic (same-batch ordering
  really does validate those).

- **The per-platform accent VALUE map is spelled in no binding, and
  cannot be until the core carries a platform id.** D1's grammar admits
  `{<platform>: Accent}` resolved binding-side at runtime; all eight
  arms skipped it independently and said so in their doc comments
  (uniform absence is uniform). The java arm found the real blocker:
  the only platform signal a JVM binding has is `os.name`, which
  reports `Linux` on Android — an app's android value would silently
  resolve to its linux one — and `kaya_capabilities()` carries one bit
  (aux-windows), no platform id. So this is a SPEC question first: a
  platform id the core answers, then eight resolver spellings, then
  the sugar-surface clause. Until then a brand book with per-platform
  values writes per-platform guests, which is exactly what the map
  exists to prevent.
- **The template zone has no `role`.** A stamped "Delete" button inside
  a For cannot be declared destructive in any language — the reference
  sugar (`Tx`/`Tpl`) carries role on the live zone only, and every
  binding matched it (checked during the fan-out, uniform). If a
  collection scene ever wants per-row destructive actions, the
  reference grows `Tpl` role first and the eight spellings follow —
  two lines each per the java arm's estimate — plus a
  tpl-surfaces/tools clause. Deliberately absent today, not forgotten.
- **The template zone has no `inset` either — and the editor's find bar
  is the live case.** The container inset landed 2026-08-12 (the prop
  the full-bleed editor forced: its status row insets while the buffer
  runs to the edge), but the find bar's row is a STAMPED node, and the
  template zone carries exactly one layout prop (grow, which scroll
  forced). So the bar still sits flush while the status row does not —
  visible in the editor captures. Same closure shape as role above:
  the reference grows the `Tpl` spelling first, eight bindings follow,
  and the tpl-surfaces census holds it. Worth doing together with
  template `role` if either is admitted, since the walls, sweeps and
  gates are the same set twice.
- **The brand mask bits deserve generated constants.** The
  `set_brand_accent` record's mask (bit 0 = light override, bit 1 =
  dark) has no spec-emitted name, so five bindings and both
  interpreters hand-write `1` and `2` at their pack/decode sites — the
  check-file-modes shape one record over: renumber the bits and every
  generated surface holds while the literals drift, and the failure is
  a dark override painting the light appearance with no error
  anywhere. The fan-out measured the bits correct everywhere (each arm
  decoded the core's derived words per bit); a `BRAND_MASK_LIGHT`/
  `BRAND_MASK_DARK` pair in the spec moves the agreement from measured
  to structural. Spec-hash move + regeneration + seven callsite edits.
