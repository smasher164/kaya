# Drag and drop — the design pass (2026-09-02)

The maintainer picked drag and drop as the next milestone on 2026-09-02.
This is the design pass that precedes any arm: what the five platforms
settle, the decisions the design turns on, each stated as a mechanism
first and a recommendation second, the probes that must run before an
arm is written, and the order the build takes. Rulings are marked. The
research behind it is three platform notes written the same morning
(Apple; GTK and WinUI; Android and eight other toolkits); the facts
below carry the platform that established them.

## §0 — What the research settled

**A drag is three acts, all on the platform's UI thread.** The PICKUP:
the source is asked what it hands over, and answers a bag of
representations keyed by type. The HOVER: as the pointer moves, the
destination is asked, over and over, "would you take this, and as
what?" — and it answers from the TYPES on offer, never the bytes. The
DROP: the destination is told to take it, and then the SOURCE is told
what happened, which is where a "move" source deletes its original.

**The hover verdict is synchronous on every platform and cannot be
deferred anywhere.** AppKit's `draggingUpdated`, SwiftUI's
`dropUpdated`, UIKit's `sessionDidUpdate`, GTK's `enter`/`motion`,
WinUI's `DragOver` and Android's `ACTION_DRAG_STARTED` are all plain
value returns with no async variant. Two platforms go further: Android
does not give the destination the data before the drop at all, and a
sandboxed mac that reads a dragged file's URL during the hover can
lose the drop's sandbox extension and fail the drop it was about to
accept. So DESIGN.md's rule that hover is answered from a PRE-PUSHED
vocabulary of accepted types is not a kaya convenience; it is the only
implementable design, and Apple's newest API says so in its own
documentation ("the configuration closure is called frequently for
different drop locations — avoid expensive calculations").

**The drop verdict splits the platforms.** GTK (`GtkDropTargetAsync` +
`gdk_drop_finish`) and WinUI (`DragEventArgs.GetDeferral`) can answer
LATER without blocking anything. Apple cannot: `performDragOperation`
and `performDrop` run inside the platform's own tracking loop on the
main thread, and parking them parks the app. Android cannot either —
`onDrop` returns one boolean synchronously — but Android's window
manager implements DESIGN's bounded wait itself: an unanswered drop
times out at 5,000 ms, ends "not consumed", and the drag surface
animates back to its origin over 195–375 ms. Apple's snap-back is also
the platform's (`animatesToStartingPositionsOnCancelOrFail`, on by
default). Nothing kaya draws.

**The payload is the clipboard's grammar, on all five, with no second
model.** GTK's drag payload IS a `GdkContentProvider`, the object
gtk.rs's copy arm already builds. Android's is a `ClipData`, the
clipboard's own class, and `View.onDragEvent`'s default routes a drop
into `performReceiveContent` tagged `SOURCE_DRAG_AND_DROP` — "paste
and drop are the same event" is the framework's implementation, not an
analogy. Apple's `NSItemProvider` registers a representation under a
raw type-identifier string, so kaya's MIME-shaped custom id rides
verbatim, and kaya's descending clip value (custom, files, image,
html, text) is Apple's preference order. Windows is the exception that
costs: XAML drag is `DataPackage`, the WinRT API the clipboard
milestone deliberately avoided, and the custom-format write bridge
from WinRT to Win32 is documented only in the read direction.

**Operations diverge more than anything else.** The four desktop
toolkits negotiate a source mask against a target choice with copy,
move and link (GTK adds "ask"). iOS has copy, move, forbidden, cancel.
Android has NONE — the whole verdict is one boolean. .NET MAUI, the
only other toolkit shipping kaya's five platforms, shrank its
vocabulary to None and Copy for exactly this reason.

**The source learns the outcome on every platform** (GTK `drag-end`
with `delete_data`, WinUI `DropCompleted.DropResult`, Apple's
session-ended operation, Android's `ACTION_DRAG_ENDED` result), and a
design without that signal makes move unimplementable.

**Reorder inside a list is a different API from data transfer on two
platforms.** Compose reorders with a long-press gesture over the list
state, never with its drag-and-drop modifiers; SwiftUI's `List.onMove`
is index-based, which DESIGN refuses ("keys, never indices"). GTK and
WinUI can reorder through their drag frameworks, but WinUI's built-in
`CanReorderItems` mutates the app's collection itself, which kaya's
model forbids. Apple's 2025 `reorderDestination` is key-shaped — the
same choice `collection_move` made.

**Files arrive as references, not bytes**, on every platform: file URLs
on Apple, `GdkFileList` or `text/uri-list` on GTK, storage items or
`CF_HDROP` on Windows, content URIs on Android. That is the currency
the file dialogs already ruled on (a handle redeemed through
`kaya_open_picked`, never a path), and iOS forces it: a dropped file's
bytes are readable only inside a coordinated read that ends when the
callback returns.

**Driving a drag is the hard half, and it is per lane.** Every kaya
`click` today is programmatic (a signal, an automation peer, a model
emit). A drag on the desktops needs REAL input: Windows' UIA drag
pattern is read-only ("you can automate drag operations by sending
mouse input"), and OLE's modal loop reads real mouse messages. What
each lane has:

| Lane | Real input for a drag | State |
|---|---|---|
| mac | CGEvent posting is refused by the repo (it types at whatever is frontmost and charges the accessibility permission); `NSApp.sendEvent` can start a session but AppKit's tracking then follows the real cursor | In-process instead: `NSDraggingInfo` is a PROTOCOL a test double can conform to, so the real `NSDraggingDestination` arms can be driven against a real `NSPasteboard` — but only if kaya's destination is an AppKit view, because SwiftUI's `DropInfo` has no public initializer |
| linux, X11 | `xdotool mousedown / mousemove … / mouseup` through XTEST, which GDK4 reads as real input; the image has it and the `type` verb uses it | Available today |
| linux, Wayland | `wl_data_device.start_drag` needs an implicit pointer grab from a real button press; the image had only a virtual keyboard (`wtype`) and a capability-less seat | AVAILABLE since 2026-09-02: tools/linux/wlpointer is a vendored `zwlr_virtual_pointer_v1` client (sway's own `seat cursor press` succeeds on the deviceless seat and delivers nothing, docs/traps.md), the lane boots one sway per pool slot so a seat's pointer disturbs nobody, and tools/linux/dragprobe.py proves a real drag lands at every lane start |
| windows | `SetCursorPos` + `mouse_event`/`SendInput`, which the caption-centre probe and the undo probe already do in the guest session | Available today; `StartDragAsync` is documented unsupported when elevated and the lane runs every leg `/rl highest`, so real input is the route |
| android | `adb shell input draganddrop x1 y1 x2 y2 [ms]`: a real long-press swipe through the real window manager | Available today; needs a coordinate, which the harness can derive from a testTag's `boundsInWindow` |
| iOS | The resident XCUITest driver (tools/ios/xcuidrive, 2026-09-02) delivers real touches: a tap changed kaya's model and a press-drag scrolled a system app (proven standalone). A synthetic PAN does not move kaya's SwiftUI ScrollView (docs/traps.md). Since 2026-09-02 that driver is the lane's ONE set of hands (docs/xcuidrive-plan.md): it serves the picker, prompt and pasteboard verbs too, so a drag leg needs no sequencing apart from the dialog legs | AVAILABLE, resident on every pool device; the drag arm proves its gesture reaches the drop interaction when it lands |

**Cross-app is where every platform hedges.** Explorer-to-WinUI-3 file
drops are a known-broken path (microsoft-ui-xaml #10119, still a
duplicate of #8108), while the same Microsoft page says drag "works in
all directions"; the fallback is the OLE `RegisterDragDrop` route on
the HWND, which reuses the `parse_dropfiles` the clipboard already
ships. Wayland has no `wl-drag` counterpart to `wl-copy`. Android needs
`DRAG_FLAG_GLOBAL` plus URI-permission flags and a second visible
window, so on a phone it is same-app in practice. And the clipboard
milestone's own argument transfers: a test where kaya drops onto kaya
cannot catch a malformed lowering, so each desktop needs a foreign
witness (a stock reader or writer in the runner's process).

**Two internal contradictions to resolve.** DESIGN's drag paragraph
places a bounded wait on "the drop verdict" and expects pasteboard
promises on the source; the clipboard ruled lazy rendering OUT, and the
Apple platforms cannot park the drop at all. Both are ruled below.

## §1 — The decisions

Each decision states the mechanism, then the recommendation, then what
it costs. RULING marks the ones the maintainer owes; the rest follow
from the record and are stated so they can be overruled.

### D1 — The model: two declarations, two occurrences (RULING)

A widget that can be dragged DECLARES its payload and the operations
it allows; a widget that can receive DECLARES what it accepts and
which operations it will perform. The core answers every hover from
those two declarations with no app round trip. A drop delivers ONE
occurrence to the app — `dropped` — carrying the destination widget's
tag, the drop point, the chosen operation, and the payload as the
clipboard's `Representation` sum; and the source receives a second
occurrence — `drag_ended` — carrying the operation the drop settled
on, or `none`. The app's transaction after `dropped` is the visible
effect, and for a move the source app's own removal of the original
rides `drag_ended`.

- The source declaration is a clip RECORD (the copy record's shape,
  offered in descending clip value) plus an operation set. It is
  app-updated state, so a widget whose payload changes re-declares.
- The destination declaration is the existing `accepts` list (kinds
  by name plus custom ids, already per widget for paste) plus an
  operation set defaulting to copy.
- `dropped` is `pasted`'s layout plus three fields (point, operation,
  and the reorder anchor of D8). Same blob table, same nine-binding
  spelling of the representation sum.

Why not `on_paste` with a flag: a drop has a position and can be
refused; a paste has neither. The payload model is shared; the
occurrence kind is its own, so a handler that only wants pastes never
sees drops.

### D2 — No bounded wait anywhere; the operation is chosen at declaration (RULING, amends DESIGN.md)

DESIGN.md's drag paragraph put a bounded wait on the drop verdict so
that an app could refuse a drop after seeing it. The research says
that wait cannot be honoured on Apple (it parks the main thread inside
the tracking loop) and is a UI-thread block on Android, while GTK and
WinUI could honour it. Rather than a semantics that two platforms fake,
the recommendation removes the wait: the hover and the drop are BOTH
answered from the declarations, synchronously, by the core. What the
app decides, it decides in the transaction after `dropped`, exactly as
it does after `pasted` — and a drop the app does not want shows as
"nothing changed", the same as an unhandled paste.

The one place the doctrine bites — "accepting a move causes the source
to delete the original" — is handled by scoping, not by waiting:

- SAME-APP drops (source and destination both in this kaya process):
  the app owns both ends, so `dropped(move)` and the removal of the
  original are one app transaction. No platform-side deletion occurs.
- CROSS-APP drops INTO kaya: the core answers the platform `copy`,
  always, so no foreign source ever deletes on kaya's behalf; the app
  still sees the operation its declaration allowed. A destination that
  declared move alone shows the copy badge to a foreign source.
- kaya drags OUT to a foreign app: the foreign destination decides; the
  source app learns it through `drag_ended` and removes the original
  itself if the answer was move.

DESIGN.md's degradation row "drop verdict misses its deadline" is
struck by this decision; "stale hover policy → wrong badge (cosmetic)"
stays. This also lifts the wait from Android's 5,000 ms system ceiling
and the "ANR the drag-receiving app" TODO sitting over it.

### D3 — The operation vocabulary is copy and move (RULING)

`copy`, `move`, and `none` for the outcome. `link` is refused: GTK
documents it as "not supported on all platforms", iOS and Android have
no such operation, and no archetype app kaya has named needs it. GTK's
`ask` is refused for the same reason (no Windows analogue). Android's
lowering carries the operation inside the `ClipData` as a kaya-private
entry for same-app drags and treats every cross-app drag as copy,
which D2 already makes uniform.

### D4 — Payloads are eager; laziness rides file references

The clipboard ruled lazy rendering out because a promise is a callback
the platform can block on at a moment kaya does not control. Drag adds
no reason to reverse it: GTK's `for_bytes` providers, Android's
content URIs and Windows' `DataPackage` setters all take materialised
bytes, and `files` carries references by construction. The one Apple
promise API with a completion handler (`NSFilePromiseProvider`, "drag
a file that does not exist yet") is a deliberate cut with its trigger
stated: an app that exports a document by dragging.

### D5 — One item per drag

The clipboard's ruling holds. A multi-file drag is one item whose
`files` representation is a list; iOS's second-finger
`itemsForAddingTo` is refused; a foreign drag carrying several
heterogeneous items collapses to the richest single representation
kaya understands.

### D6 — Dropped files are picked files

A dropped `files` representation registers into the picked table and
the guest redeems it through `kaya_open_picked`, as a pasted file
already does. No new vocabulary; iOS's coordinated read is why it
cannot be a path. MEASURED 2026-09-03 (probe 5): on iOS the provider
dies about 3 s after `performDrop` returns, so the arm copies the file
into the app's container inside the callback and registers the copy —
what the picker's iOS arm already does for a security-scoped URL.

### D7 — The mac destination is an AppKit view, not a SwiftUI DropDelegate (RULING, visual and testability)

SwiftUI's `DropDelegate` cannot be driven in-process (`DropInfo` has no
public initializer), while `NSDraggingInfo` is a protocol a test double
conforms to. Lowering the destination through an `NSViewRepresentable`
that registers for dragged types lets a mac-only gate run the real
AppKit arms against a real pasteboard, the shape `check-pane-ladder`
already uses. It also gives the full operation MASK, where SwiftUI's
proposal carries one operation. The cost is that the representable's
hit-testing must agree with SwiftUI's layout, which the table tier's
native `NSTableView` already pays.

### D8 — Reorder is a drop whose destination is a row of the same For (RULING)

One feature, two lowerings. A `reorderable` For makes each stamped row
a drag source whose payload is the row's key (a kaya-private custom
representation), and a destination that accepts only its own
collection's rows. The `dropped` occurrence's anchor is the key of the
row the drop landed on plus a before/onto bit; the app confirms with
the existing `collection_move`, the core reorders, `move_child` runs.
Nothing new on the apply side.

- GTK and WinUI lower it through their drag frameworks with a per-row
  source and target; WinUI's `CanReorderItems` is declined because it
  writes the model (and its insertion indicator and auto-scroll with
  it, which kaya then draws itself — the cost of this ruling).
- Compose lowers it as a long-press gesture over the list state, the
  platform's own idiom; SwiftUI's synthesized tier the same way, and
  the native `NSTableView` tier through its row-drag delegate methods.
- `List.onMove` is refused (index-shaped).
- Long press starts a drag on the phones, press-and-move on the
  desktops: the affordance is uniform, the gesture is the platform's.

### D9 — Cross-app is in scope, proven by foreign witnesses, gated by probes

Same-app drags are testable on every lane today (with the two lane
gaps in D10). Cross-app is part of the feature, not a later stage, and
its proof is the clipboard milestone's: a foreign witness per desktop
(a stock GTK reader for X11, a stock Win32 reader on the VM, `pbpaste`
has no drag twin so the mac witness is an AppKit probe) plus the
Windows Explorer question, SETTLED by probes 1 and 2 (§2): the WinUI arm
is XAML `AllowDrop` for WinRT sources AND `RegisterDragDrop` on the
island HWND for Explorer and every Win32 source, the two coexisting in
one window, with custom formats written as streams. Phones: same-app
only, stated.

### D10 — The harness verb drives real input where the lane has it (RULING)

One shared verb, `drag <source> to <destination> [at <row key> before|onto]`,
addressed by kind and id like every other verb. Per lane:

- X11: `xdotool` through XTEST, from the source's centre through
  intermediate moves past GTK's drag threshold to the destination's
  centre.
- Windows: `SendInput` from the leg's own launcher, the caption probe's
  proven shape.
- Android: `adb shell input draganddrop` between two testTags' centres.
- mac: the in-process AppKit route — a real `NSPasteboard` built from
  the source's declaration and the real `NSDraggingDestination` arms
  called in order on the main thread — because real input is refused
  and AppKit's tracking loop cannot be driven synthetically.
- iOS: the same in-process route through UIKit's `UIDropInteraction`
  delegate methods with a session double, stated as "the gesture
  recognizer is not exercised", with the XCUITest driver named as the
  trigger for a real touch.
- Wayland: per-leg sway plus a pointer injector is a lane slice that
  precedes the wayland legs; until it lands the wayland drag legs are
  declared off with the reason, the pattern the mobile lanes used for
  the portfolio.

Assertions are byte-identical because they read the occurrence and the
model, never the platform: the `dropped` payload as a frozen string,
`expect_order` after a reorder, a label the guest writes on
`drag_ended`. Badges, previews and animations are cosmetic by DESIGN's
own table and get gates, not legs.

### D11 — Deliberate cuts, each with its trigger

Spring loading (separate opt-in on Apple, no analogue elsewhere; an app
that navigates by hovering). File promises (D4). Per-representation
visibility (Apple's `.ownProcess`; an app with a private format). A
custom drag preview (the platform's default preview of the source is
what every backend draws; an app whose row preview must differ). Link
and ask operations (D3). A failure reason on cancel (GTK has three,
WinUI none; the diagnostics rule forbids a sentence that discriminates
on one platform).

## §2 — Probes before arms

The clipboard milestone measured the platform before writing each arm
and overturned an assumption on every one. The same discipline, ranked
by what a wrong assumption costs:

1. **Windows: does `custom(id, bytes)` cross a process boundary through
   `DataPackage.SetData`?** Microsoft records the WinRT-to-Win32 bridge
   as asymmetric. A `dragprobe` beside tools/win/undoprobe, run in the interactive session,
   one side `SetData("dev.kaya/note", …)`, the other a stock reader.
2. **Windows: does an Explorer file drop reach a WinUI 3 window on the
   VM**, elevated and not? Decides XAML versus the OLE route for the
   single most-wanted scenario.
   MEASURED 2026-09-03, probes 1 and 2 together
   (docs/probes/dnd-probe-windows-2026-09-03.md, the probe under
   tools/win/dragprobe — a WinUI 3 app pair plus a stock Win32 OLE reader,
   driven by SendInput in the interactive session, 13 scenarios). PROBE 1:
   `DataPackage.SetData("dev.kaya/note", …)` crosses into a Win32 OLE
   reader in another process with the id (registered clipboard format)
   and bytes intact — as `TYMED_ISTREAM` only, seeked to its end, ONE tymed
   per `GetData` (an OR is refused E_INVALIDARG); the string flavour
   arrives UTF-16 with a NUL and the `IRandomAccessStream` flavour
   byte-exact, so kaya writes `custom(id, bytes)` as a stream. The REVERSE
   into XAML `AllowDrop` gets nothing — a census proved `AllowDrop`
   registers no OLE drop target on any of the WinUI window's four HWNDs —
   while the same Win32 source lands intact on `RegisterDragDrop` on the
   island HWND (`Microsoft.UI.Content.DesktopChildSiteBridge`, after
   `OleInitialize` on the XAML thread); and XAML does receive a
   cross-process drag when the source is WinRT, so kaya-to-kaya works
   through XAML. PROBE 2: Explorer to XAML NO, three runs including
   `/rl highest`; Explorer to OLE on the WinUI HWND YES, `CF_HDROP` with
   the real path, `parse_dropfiles`' own shape. THE TWO ROUTES COEXIST in
   one window: both armed, an Explorer drop goes to OLE and a WinRT drag
   to XAML. So the WinUI arm carries both. Elevation could not be measured:
   the VM runs `EnableLUA=0`, every process reads the high integrity
   level, and turning UAC on needs a reboot the probe did not take.
3. **mac: does a MIME-shaped custom id survive a drag from an UNBUNDLED
   binary?** One report says SwiftUI drag needs `UTExportedTypeDeclarations`
   in an Info.plist the lane guests do not have. Probe bundled and
   unbundled, as `tools/mac/clipprobe` did.
   MEASURED 2026-09-03 (docs/probes/dnd-probe-mac-2026-09-03.md, the
   probe under tools/mac/dragprobe): the plist is a red herring, and the
   real fact is sharper — `dev.kaya/note` is NOT A UTI. Every route a
   drag source naturally takes drops it silently with the console's
   "'dev.kaya/note' is not a valid UTI string": `NSPasteboardItem.setData`
   returns false, a custom `NSPasteboardWriting`'s `writableTypes` is
   refused, and a real `beginDraggingSession` composes a drag pasteboard
   without it. It survives verbatim and cross-process ONLY through the
   board-level `declareTypes`/`addTypes` + `setData` path — which also
   works added onto a live session's own drag pasteboard — and bundling
   changes nothing, because `UTExportedTypeDeclarations` cannot declare a
   MIME-shaped string as a UTI at all (with the plist registered
   system-wide, `UTType("dev.kaya/note")` is still nil and all seven
   routes behave byte-identically). So the mac arm writes the drag
   pasteboard at board level, the clipboard arm's own route; the plist
   matters only for cross-app discovery under a reverse-DNS id. The one
   premise a real drag still has to settle: the board-level add during a
   live session.
4. **Wayland: does `swaymsg 'seat - cursor press button1'` give a GDK
   client a serial `start_drag` accepts**, and does a seat pointer
   disturb the pooled legs the way the keyboard did? Decides whether
   the per-leg-sway slice is a prerequisite.
   MEASURED 2026-09-02: NO — every `seat - cursor` command answers
   success and delivers nothing, because the seat (`capabilities: 0`,
   `devices: []`) has no pointer for a client to bind. A
   `zwlr_virtual_pointer_v1` device (tools/linux/wlpointer) delivers
   the whole gesture — prepare, drag-begin, enter, drop, drag-end — on
   GTK 4.18, and since a device on a shared seat is the keyboard's
   2026-08-03 regression one device over, the per-leg slice WAS the
   prerequisite and is built (§5 step 0). The x11 twin lands through
   xdotool's XTEST pointer the same way.
5. **iOS: does a drop from another app raise the iOS 16 paste prompt?**
   Reasoned no (the user's own gesture is the consent); measure it.
   MEASURED 2026-09-03 (docs/probes/dnd-probe-ios-2026-09-03.md, the probe
   under tools/ios/dragprobe, on an iPad-class pool device under iOS
   26.5): NO PROMPT. A foreign drag from the stock Files app and from a
   second bundle both reached a `UIDropInteraction` with
   `session.localDragSession == nil`, and `performDrop` handed over the
   foreign bytes in 60 ms and 4 ms with no prompt — against a positive
   control minutes earlier where `UIPasteboard.general.string` raised
   "would like to paste from" and parked the read for 26.5 s. Two
   findings sharpen the plan: D6's premise is STRONGER than written — about
   3 s after `performDrop` returns the whole `NSItemProvider` is dead
   (`Code=-1000 "Cannot load representation"` for data, custom id and
   file alike, the temp copy gone), so the iOS arm reads or copies a
   dropped file INSIDE the callback and registers what it kept, never a
   lazy handle; and D10's iOS row loses its "session double" caveat but
   needs one driver verb: the lane's `drag` (`press(forDuration:thenDragTo:)`)
   lost to a stock app's long-press context menu at all seven holds tried,
   while `press(forDuration:thenDragTo:withVelocity:thenHoldForDuration:)`
   lifted it every time.

## §3 — The spec, in the record grammar

Transaction records: `set_drag_source(widget, present, file_count,
custom_count, operations, reps)` — the copy record's body plus an
operation mask, live and template zones; `set_drop_target(widget,
operations)` beside the existing `accepts`; `set_reorderable(for_id)`.
Occurrences: `dropped(id, path_len, keys…, point x y, operation, anchor
key, before, clip, value)` and `drag_ended(id, path_len, keys…,
operation)`. The operation enum is `none=0, copy=1, move=2`. The spec
hash moves once, everything regenerates in lockstep.

## §4 — The bindings sweep

Every binding spells three things in its own idiom, one semantics:
`draggable(clip…, operations)` on a widget or template node (Python and
JS keyword arguments; Rust, Go, Java chained; C#, Swift, OCaml named
arguments; Haskell an attr); `drop_target(accepts…, operations,
on_drop=handler)` where the handler receives the `dropped` occurrence's
fields with the representation sum `on_paste` already delivers; and
`on_drag_ended`. `reorderable(on_move=handler)` on a collection's rows,
the handler receiving (key, anchor, before) and answering with the
existing move sugar. The C floor is the records. check-sugar-surface
gains the receiver-keyed rows; the sweep is assessed per language with
a do/can't/defer verdict before the fan-out.

## §5 — Build order

RULED 2026-09-02 (maintainer): THE TEST INFRASTRUCTURE COMES FIRST —
"whether it's the XCUI test driver for iOS or the Wayland
infrastructure. I think that would pay off later on." So the two lane
gaps in D10 are slices of their own, ahead of every arm below: the
wayland lane's per-leg compositor with a pointer injector (the exit
docs/deferred.md's session-architecture entry names), and the resident
XCUITest driver for the iOS simulator (the exit its pan chore names).
Wayland first, because its recipe is measured and it also unserialises
the wayland clipboard legs; then iOS.

0. The two infrastructure slices above, each proven by a real gesture
   reaching a real widget on its lane before any drag arm exists.
   WAYLAND DONE 2026-09-02: tools/linux/run-suites.sh's wayland pool,
   tools/linux/wlpointer, and tools/linux/dragprobe.py driving a real
   drag through both protocols' injectors before the first leg. iOS BUILT +
   PROVEN STANDALONE 2026-09-02: tools/ios/xcuidrive, a resident XCUITest
   driver (a real tap changed kaya's model, a real drag scrolled a system
   app), wired OPT-IN behind KAYA_IOS_XCUIDRIVE with an isolated
   post-admission proof (run-sim.py, xcuidrive_selfcheck). Then, the
   same day, docs/xcuidrive-plan.md's subsumption: the driver is resident
   on every pool device from boot and serves the picker, prompt and
   pasteboard verbs as well (simdrive and clipctl are gone), so nothing
   on the device competes with it. ONE NOTE for the iOS drag arm below:
   a synthetic pan does not move kaya's SwiftUI ScrollView, so drive the
   drop interaction with `drag` and verify the gesture landed, not
   scroll.
1. The five probes (§2), each written down with its number.
2. Spec and core: the records, the two occurrences, the hover answer
   computed from the two declarations, `dropped` routed like `pasted`,
   the picked-table registration for files.
3. mac depth: the AppKit-floor destination and source in the SwiftUI
   interpreter, the in-process drag verb, and the gate that drives the
   real AppKit arms.
4. Rust binding and the scene: a `dnd` scene under tools/scenes — a text drop
   between two widgets, a custom-id drop, a files drop redeemed through
   the picked table, a refused type, and a reorder asserted with
   `expect_order`; green on the mac lane.
5. Breadth: GTK (`GtkDropTargetAsync` for every target, the X11 verb),
   WinUI (the bindgen filter's new types, `DataPackage`, the SendInput
   verb, the OLE route if probe 2 says so), Compose (the two modifiers,
   the `input draganddrop` verb), iOS (the in-process route). The
   wayland legs declared off until the pointer slice.
6. The eight other bindings, then the matrix.
7. Cross-app witnesses per desktop, and the reorder affordance's own
   insertion indicator on the two backends that must draw it.
