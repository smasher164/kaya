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

BUILT 2026-09-03 (§5 step 5, iOS): `kayaReadDropValue`'s files branch is
that shape — `loadFileRepresentation(forTypeIdentifier: "public.item")`
STARTED inside `performDrop`, the temp copy copied again under the app's
own `NSTemporaryDirectory()`, and that URL registered in
`kayaPickedURLs`, which is the table `kaya_swiftui_open_picked` reads.
EXERCISED SINCE 2026-09-03 by `drag_file "<path>" to <destination>`,
the harness verb for a FOREIGN file drop: the guest writes
$TMP/kaya-dnd-$PID/dropped.txt (the picker and clipboard scenes' own
convention), the mac verb builds a named pasteboard carrying the file
URL and calls the destination's real arms with a nil draggingSource
(AppKit's own spelling of foreign), the reader registers the URL in the
picked table, and the guest reads `dropped.txt dropped bytes` back
through `PickedFile::open`. The other desktops deliver the same drop
in-process to their own arms — the WinUI arm through the classic OLE
target it registers, which is the route a real file drop takes there, so
the verb exercises the arms and not a stand-in; a phone cuts the step
(D9); the REAL foreign gesture is step 7's witness, and step 7 measures it impossible to drive without a human on
the mac (docs/probes/dnd-witness-mac-2026-09-03.md).

iOS TOOK THE SAME VERB 2026-09-03, and it is the first leg anywhere that
ever exercised the files branch. The guest writes the file under the
directory `$TMP` names on that platform (`~/Documents`, the picker's own
root — guests/rust/dnd.rs' `scene_root`), the verb hands a real
`NSItemProvider(contentsOf:)` to a `KayaDropSessionDouble` whose
`localDragSession` is NIL — UIKit's own spelling of foreign — and the
verdict answers `local: false`, so the drop is a copy and the picked-table
redemption is what the guest reads back. TWO DEFECTS IN THE FILES BRANCH
CAME OUT WITH IT, both in docs/traps.md: the FILES bit was keyed on
`public.file-url`, which a real foreign drop does not offer at all, and the
NAME was read off `loadFileRepresentation`'s temp copy, which is named
after the TYPE. Both now go through `kayaProviderIsFile` and
`suggestedName`.

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

AMENDED 2026-09-03, on the mac arm: the landing's IDENTITY is the For
container the app registered `on_drop` on — set_reorderable's apply
twin carries the container's tag for it — the moved row's key rides as
the clip's custom representation under `dev.kaya/row`, and the anchor
is the landed row's own create tag. Which is why EVERY stamped copy now
carries its (template node, keys) tag whatever its kind: a label row had
no identity, and the keyed `label@row[c]` target had never resolved
either (crates/kaya/src/scene.rs run_body; the test
`a_stamped_copy_is_tagged_wherever_a_live_one_is`).

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

THE CUSTOM ID NEEDS NO PHONE MAPPING, measured 2026-09-03 with the iOS
arm (§5 step 5). `NSItemProvider.registerDataRepresentation(forTypeIdentifier:
"dev.kaya/note", …)` keeps a MIME-shaped id verbatim in
`registeredTypeIdentifiers` — same-app inside kaya's OWN bundle, which
declares no `UTExportedTypeDeclarations` for it, and cross-process per
probe 5 — where macOS refuses that same string at ITEM level and the mac
arm therefore writes the board directly (probe 3, docs/traps.md). So both
Apple arms present ONE id vocabulary and read a foreign kaya id exactly
as they read a local one; D2's "a foreign source is answered copy" is
what keeps that safe. A per-id private UTI was considered and refused:
it would have made a foreign custom drop invisible on iOS and visible on
the mac, which is a semantics divergence rather than a spelling one.

ANDROID'S PROCESS-LOCAL CHANNEL IS THE PLATFORM'S OWN, settled while the
Compose arm was written: a `ClipData` cannot carry custom or image BYTES
to another process here, so those representations ride
`DragAndDropTransferData(clipData, localState, flags)` — the object
Android hands back through `DragEvent.getLocalState()` inside the process
that started the drag and nowhere else. It is both the payload table and
the discriminator that says a source is local, so the arm needs no id of
its own in the ClipData. A FOREIGN drag therefore offers neither image
nor custom: they are NOT ON OFFER rather than offered and empty.

AND NO FOREIGN SOURCE REACHES A PHONE APP AT ALL, which is what the
android lane does with `drag_file` (D6's harness verb): the step is CUT,
not faked. tools/lib/lanes/android.py's MODS drops it together with the
one assertion it feeds — `expect label#4 "files target got dropped.txt
dropped bytes (copy)"` — and the runner prints both as NOT RUN naming
the reason, while every drag between the app's own widgets runs. The
Kotlin `drag_file` arm keeps its depth sentence, so a lane that ever
wires the step reads why instead of passing on nothing. Faking one was
refused: a drop this app synthesized for itself would exercise the local
path the other drags already cover and would assert the redemption of a
file no foreign process handed over.

### D10 — The harness verb drives real input where the lane has it (RULING)

One shared verb, `drag <source> to <destination> [at <row key> before|onto]`,
addressed by kind and id like every other verb. Per lane:

- X11: `xdotool` through XTEST, from the source's centre through
  intermediate moves past GTK's drag threshold to the destination's
  centre.
- Windows: `SendInput` from the leg's own launcher, the caption probe's
  proven shape.
- Android: `adb shell input draganddrop` between two testTags' centres.
  BUILT 2026-09-03 as a REQUEST/ACK channel, because the harness runs
  inside the app and no app may inject a system drag. The verb computes
  both surfaces' centres in SCREEN PIXELS (each one's own
  `boundsInWindow` plus the decor view's `getLocationOnScreen`; a reorder
  aims at the landed row's upper or lower QUARTER) and logs
  `KAYA_REQUEST: draganddrop <seq> x1 y1 x2 y2 <ms>` on the tag the
  per-leg poll in tools/android/run-emulator.py already reads; that poll
  runs `adb -s <serial> shell input draganddrop …` on the leg's own
  device. The verb then waits for the platform's own ACTION_DRAG_ENDED
  and logs `KAYA_ACK: draganddrop <seq>`; a request served but not acked
  is re-injected, three tries 2s apart, since a REFUSED drop acks too and
  a missing ack means no gesture reached the app at all. Its expiry
  sentence carries the four counters it measured. The point delivered to
  the app is in the destination's own top-left space, in DP. `drag_file`
  has NO android route — the platform hands a phone app no foreign drag
  — so the lane cuts that step and the assertion it feeds (D9).
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

### THE SWEEP, DONE 2026-09-03 — nine DO, the C floor the records alone

AMENDED AT THE SPELLING, not the semantics: this section's sketch put
`on_drop` inside `drop_target(...)` and gave `reorderable` an
`on_move(key, anchor, before)` of its own. The RUST ARM shipped first
(step 4) and its shape is what the other eight mirror, because invariant
1 is one observable semantics and the reference is the one that runs:
`reorderable` is a DECLARATION, and a reorder's landing arrives through
`on_drop` ON THE FOR'S OWN CONTAINER — the moved row's key in the clip,
the row it landed on as the anchor, before/onto beside it (D8 amended) —
so the app confirms with the move sugar it already has. One handler
family, not two.

| language | verdict | draggable | drop_target | reorderable | on_drop / on_drag_ended |
| --- | --- | --- | --- | --- | --- |
| Rust | do | `tx.draggable(w).text(..).custom(id, b).allow(Op::Move).declare()` | `.accepts(&[..]).drop_target(&[Op::Copy])` | `tx.reorderable(list, true)` | `msgs.on_drop(w, ..)` / `msgs.on_drag_ended(w, ..)` |
| Python | do | `w.draggable(text=.., custom={..}, operations=(OP_COPY,))` | `w.accepts("text").drop_target(OP_COPY)` | `items.rows(reorderable=True, on_drop=fn)` | `w.on_drop(fn)` / `w.on_drag_ended(fn)` |
| Go | do | `tx.Draggable(w).Text(..).Custom(..).Allow(OpMove).Declare()` | `w.Accepts(..).DropTarget(OpCopy)`, `tx.SetDropTarget` | `tx.SetReorderable(c, true)`, `rows.Reorderable(true)` | `app.OnDrop(w, ..)` / `app.OnDragEnded(w, ..)` |
| C# | do | `tx.Draggable(w).Text(..).Custom(..).Allow(Op.Move).Declare()` | `tx.SetAccepts(w, ..); tx.SetDropTarget(w, Op.Copy)` | `tx.SetReorderable(c, true)` | `tx.OnDrop(w, ..)` / `tx.OnDragEnded(w, ..)` |
| Java | do | `tx.draggable(w).text(..).custom(..).allow(Op.MOVE).declare()` | `tx.setAccepts(w, ..); tx.setDropTarget(w, Op.COPY)` | `tx.setReorderable(c, true)` | `app.onDrop(w, ..)` / `app.onDragEnded(w, ..)` |
| Swift | do | `tx.draggable(w).text(..).custom(..).allow(.move).declare()` | `tx.setAccepts(w, ..); tx.setDropTarget(w, [.copy])` | `tx.setReorderable(c, true)` | `tx.onDrop(w) { .. }` / `tx.onDragEnded(w) { .. }` |
| OCaml | do | `draggable ~text ~custom ~operations:[Op.Copy] w ()` | `set_accepts w [..]; set_drop_target w [Op.Copy]` | `set_reorderable w true` | `on_drop app w fn` / `on_drag_ended app w fn` |
| Haskell | do | the `Draggable Clip [Op]` attr, `setDragSource w clip ops` | the `DropTarget [Op]` attr, `setDropTarget w ops` | `setReorderable w True` | `onDrop app w fn` / `onDragEnded app w fn` |
| JS | do | `w.draggable({ text, custom, operations: [OP_COPY] })` | `w.accepts("text").dropTarget(OP_COPY)` | `items.rows({ reorderable: true, onDrop: fn })` | `w.onDrop(fn)` / `w.onDragEnded(fn)` |
| C floor | records only | the generated `kaya_tx_set_drag_source` packer | `kaya_tx_set_drop_target` | `kaya_tx_set_reorderable` | the occurrence bytes; no decoder, as for `pasted` |

AND THE TEMPLATE ZONE'S OWN SPELLINGS, landed in all nine 2026-09-03 —
the DECLARATION in the For's body, the KEYED record after the row's
insert, and the two node handlers. Seven bindings tell the zones apart by
the receiver's TYPE and so reuse the live name; Python's and JS's one
handle serves both zones, so their declaration and handlers ARE the live
spellings and only the keyed verbs are new:

| language | template declaration | keyed per copy | node handlers | bound payload | verdict |
| --- | --- | --- | --- | --- | --- |
| Rust | `row.draggable(node).text(..).declare()`, `row.drop_target(node, &[Op::Copy])` | `tx.draggable_at(node, &keys)`, `tx.drop_target_at(node, &keys, &[Op::Copy])` | `msgs.on_drop_node(n, ..)` / `msgs.on_drag_ended_node(n, ..)` | `row.draggable(n).text(Item::title())` | do |
| Python | `node.draggable(text=..)`, `node.drop_target(OP_COPY)` — the live chain, on a Node | `node.draggable_at(*keys, text=..)`, `node.drop_target_at(*keys, operations=(OP_COPY,))` | `node.on_drop(fn)` / `node.on_drag_ended(fn)`, `fn(*keys, ..)` | `node.draggable(text=row.title)` | do |
| Go | `row.Draggable(n).Text(..).Declare()`, `row.SetDropTarget(n, kaya.OpCopy)` (`Tpl` under it, `SumCase` beside it) | `tx.DraggableAt(n, keys)`, `tx.SetDropTargetAt(n, keys, kaya.OpCopy)` | `app.OnDropNode(n, ..)` / `app.OnDragEndedNode(n, ..)` | `row.Draggable(n).Text(row.Title())` (`TplDragRef`) | do |
| C# | `row.Draggable(n).Text(..).Declare()`, `row.SetDropTarget(n, Op.Copy)` | `tx.DraggableAt(n, keys)`, `tx.SetDropTargetAt(n, keys, Op.Copy)` | `tx.OnDrop(Node, ..)` / `tx.OnDragEnded(Node, ..)`, overloads | `row.Draggable(n).Text(row.Title)` (`TplDragRef`) | do |
| Java | `row.draggable(n).text(..).declare()`, `row.setDropTarget(n, Op.COPY)` | `tx.draggableAt(n, keys..)`, `tx.setDropTargetAt(n, keys, Op.COPY)` | `app.onDrop(Node, DropHandler)` / `app.onDragEnded(Node, DragEndedHandler)` | `row.draggable(n).text(row.title)` (`TplDragRef`) | do |
| Swift | `row.t.draggable(n).text(..).declare()`, `row.t.setDropTarget(n, [.copy])` | `tx.draggableAt(n, at: keys)`, `tx.setDropTargetAt(n, at: keys, [.copy])` | `tx.onDrop(_ n:) { .. }` / `tx.onDragEnded(_ n:) { .. }`, overloads | `row.t.draggable(n).text(row.title)` (`KayaTplDragRef`) | do |
| OCaml | `Tpl.draggable ~text ~operations n ()`, `Tpl.set_drop_target n [Op.Copy]` (the sugar tier, not `Tpl.Floor`) | `draggable_at ~text n ~keys ()`, `set_drop_target_at n ~keys [Op.Copy]` | `on_drop_node app n fn` / `on_drag_ended_node app n fn` | `Tpl.draggable ~text_field:item_title n ()` | do |
| Haskell | the `TplDraggable TplClip [Op]` and `TplDropTarget [Op]` attrs; `setNodeDragSource` / `setNodeDropTarget` dynamic | `setDragSourceAt n keys clip ops`, `setDropTargetAt n keys ops` | `onDrop app (Node ..)` / `onDragEnded app (Node ..)` through `HandlerTarget` | `TplDraggable emptyTplClip {tplClipText = Just (TplField (field @"title" @Item))}` | do |
| JS | `node.draggable({ text })`, `node.dropTarget(OP_COPY)` — the live chain, on a template node | `node.draggableAt(keys, { text })`, `node.dropTargetAt(keys, OP_COPY)` | `node.onDrop(fn)` / `node.onDragEnded(fn)`, `fn(row, ..)` | `node.draggable({ text: row.title })` | do |
| C floor | records only | the same packers with a non-zero `path_len` | the occurrence bytes; no decoder | the same packers with a non-zero `bound` mask | records only |

THE ELEMENT-BOUND PAYLOAD, ruled 2026-09-03 ("churn is free") and in all
nine the same day: inside a For's body a representation IS THE ROW'S OWN
FIELD, spelled the way that binding's template `label` already takes one —
Rust's and Go's field tokens, Python's and JS's field objects, the
generated accessors in C#, Java and Swift, OCaml's `~text_field` beside
its `~bind_field`, Haskell's `TplField (field @"title" @Item)`. The
binding computes each bound slot's canonical index (custom id and bytes
per pair, then files, image, html, text), ORs the `bound` mask and packs
`level << 32 | field` into that slot; the core resolves it per stamped
copy and re-declares when the field changes (crates/kaya/src/scene.rs's
`resolve_bound_clip` / `refresh_drag_binds`). A FILE NEVER BINDS — a
picked handle is not a field — and the LIVE chain and the KEYED `_at`
form stay constant-only: refused BY TYPE in the seven bindings whose
template zone has its own chain (Rust's and Go's `TplDragRef`, C#'s and
Java's `TplDragRef`, Swift's `KayaTplDragRef`, OCaml's labelled argument,
Haskell's `TplClip`) and BY NAME in Python and JS, whose one handle
serves both zones. A SIGNAL is refused by name everywhere it can be
handed one: a payload is app-updated state, re-declared when it changes.
The scene's proof is the rename — `click button#0` moves y's title to
`yy`, and the next drag of `label@item[y]` hands over `yy`.

THE KEYED FORM IS `_at`-SUFFIXED EVERYWHERE, mirroring the Rust
reference rather than putting the keys first on the live verb: Python and
JS spell the live `drop_target(*operations)` with POSITIONAL operations,
so leading keys are unspellable there, and a distinct verb keeps one name
per semantics in all nine while leaving the live chain untouched. It
takes a TEMPLATE NODE and refuses a live widget — by TYPE in the seven,
and in one byte-frozen sentence in Python and JS ("names ONE STAMPED
COPY").

The C floor gets no `dnd` guest and no decoder in this slice, which is
this section's own ruling ("The C floor is the records") and the shape
`pasted` already has there: the packers ride the generator, the
occurrence side is undecoded, and the mac lane's `dnd` roster excludes
`c` for that reason.

THE OPERATION VOCABULARY IS THE BINDING'S OWN SPELLING of one closed
set: an enum where a language has them (Rust `Op`, Go's `Op` uint32 with
`OpNone` for the refused outcome, C#'s `Op?`, Java's nullable `Op`,
Swift's `KayaOp?`, OCaml's `Op.t option` — a MODULE because the menu
role type already owns the constructor `Copy` — and Haskell's `Maybe
Op`), and a named STRING in the two whose accept list is already strings
(Python's and JS's `OP_COPY`/`OP_MOVE`, refused by name when a guest
writes anything else). `none` is never spelled by a guest; it is what a
cancelled or refused drag hands the source.

THE TEMPLATE ZONE LANDED 2026-09-03 IN ALL NINE (core + Rust first, the
eight others in the sweep that followed), in TWO SHAPES the spec already
carried. A declaration in the For's body — `row.draggable(node)
.text(..).allow(..).declare()` and `row.drop_target(node, &[Op])` beside
the template's own `accepts` — reaches every stamped copy with a
CONSTANT payload and the copy's own identity tag, and a KEYED per-copy
record — `tx.draggable_at(node, &keys)` / `tx.drop_target_at(node,
&keys, ops)` after the row's insert — overrides it for one copy and
follows that copy through a re-stamp, exactly as set_column_headers'
keyed form does (crates/kaya/src/scene.rs: node_instances, the two
override maps, the two TplOps). The landing and the drag's end reach the
app with the copy's keys first: `on_drop_node` and `on_drag_ended_node`,
which is also the registration a reorderable row's own drag_ended had
lacked. The scene's column#2 is the proof: `label@item[y]` drags its
per-copy text into the live target and reports `item y drag ended
copy`, the live source drops onto `label@item[x]` and the stamped
target reports `item x got text hello (copy)`, and each reorder ends
with `row c drag ended move`. AN ELEMENT-BOUND PAYLOAD — `.text(Item::
title())` in the body, the way a label binds a field — was NOT spelled
here at first: the reps rode the record as plain Values with no source
discriminator. RULED AND BUILT 2026-09-03 (record 49's `bound` mask, the
table above): the keyed form is no longer how a row's data reaches its
payload, it is the per-copy OVERRIDE. Before this the zone was refused in all nine;
tools/check-sugar-surface.py's DND SURFACE clause is the FLIP of that
refusal now — the template declaration, the two keyed verbs and the two
node handlers, nine bindings each, read out of the block that owns them
where the live and template spellings are one word. Its watched
negatives: a fake name per spelling refused 9/9, the two ambient files'
keyed-refusal sentence perturbed once each with the count printed, and
the OLD live-zone sentence spliced back into each of them, which must
redden the zone-open clause. Both were watched firing against the real
files (a renamed `Tpl.Draggable` in Go, the live-zone refusal restored in
Python).

~~A STAMPED COPY'S OWN OUTCOME HAS NO REGISTRATION SURFACE~~ — CLOSED
2026-09-03 by the node handlers above. It was found by Go's own
`TestEveryLiveDispatchArmHasATemplateNodeSibling`, which refuses a live
dispatch arm with no template-node sibling: a reorderable For's rows ARE
stamped copies, so `drag_ended` for a row drag arrives keyed (the mac arm
hands the occurrence the SOURCE's tag) while every binding registered a
drag handler by WIDGET id alone, and the keyed occurrence matched no
registration. All nine now split their drop and drag_ended dispatch on
the key path exactly as their paste dispatch does, and the scene's `row c
drag ended move` is the observation. THE REGISTRY ITSELF was the other
half: a map from id to ONE closure loses the first of two registrations,
which is what the Rust binding did until this slice (docs/traps.md, "A
binding's handler registry held ONE closure per id"). The other eight
were read one by one and none has that shape — each keys a SEPARATE table
per occurrence kind — and the two check surfaces (bindings/python's and
bindings/js's kaya_app_checks, Go's tplzone_test.go) now assert that a
drop handler and a drag_ended handler coexist on one id.

WHAT THE OCCURRENCE SIDE COST: the tx records reached every binding
through the generator, but `dropped` and `drag_ended` were in no
binding's `parse_occurrence` — every one of the eight listed the two
kinds and then fell through the click-tag tail, handing the app a drop
with NO payload. tools/kaya-bindgen grew two DERIVED families for them
(`dropped_occurrence_names` off the `anchor_len` field,
`drag_outcome_occurrence_names` off the five-field shape) plus a
`parse_representation` helper per language, since a drop's clip KIND
sits four words and a point earlier than its values.

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
   DONE 2026-09-03: `KayaDragDropView` (NSDraggingSource and
   destination in one NSView behind any node that declares a payload,
   an operation mask, or is a row of a reorderable For), the pasteboard
   written at board level (probe 3), `kayaDriveDrag` behind the `drag`
   verb calling draggingEntered/Updated/performDragOperation with a
   real named NSPasteboard and a KayaDragInfo whose source is non-nil
   (local). THE GATE IS THE LEG: the verb drives the same arms a
   session does; the source's real gesture is step 7's hand witness.
   Found on the way: `accepts` widened to every kind (a drop target is
   any widget); the apply twins' tags read into `identityTag`; the
   blob prefetch made generic (`kaya_blob_count`, docs/traps.md: A BLOB
   HANDLE DIES WITH ITS BATCH) after the custom payload arrived as no
   bytes; and tools/run-leg.py building the Rust guest every run, since
   the example links the core statically.
4. Rust binding and the scene: a `dnd` scene under tools/scenes — a text drop
   between two widgets, a custom-id drop, a files drop redeemed through
   the picked table, a refused type, and a reorder asserted with
   `expect_order`; green on the mac lane.
   DONE 2026-09-03 but for the files drop: `Tx::draggable(w)` builder
   (text/html/image/file/custom/allow/declare), `Tx::drop_target(w,
   ops)`, `Tx::reorderable(container, on)`, `Msgs::on_drop` handing a
   `Dropped { point, operation, anchor, before, clip }`, `Msgs::on_drag_ended`
   handing `Option<Op>`; guests/rust/dnd.rs and tools/scenes/dnd.steps,
   wired as the mac lane's dnd-rust leg (alone between drains).
   THE FILES DROP JOINED 2026-09-03 through `drag_file` (D6's note),
   green on the mac; the row's own drag_ended and the template zone's
   two shapes joined the scene the same day (§4).
5. Breadth: GTK (`GtkDropTargetAsync` for every target, the X11 verb),
   GTK DONE 2026-09-03: a GtkDragSource over the declared payload and a
   GtkDropTargetAsync over the accept list per declared widget; the
   reorder's source and destination on the For's CONTAINER, with the row
   under the pointer found by hit test, because a For's rows churn on
   every collection delta and every windowing scroll while the container
   does not; the drop's bytes read asynchronously and the occurrence
   emitted when they arrive, which is what D2's no-wait ruling buys on
   this toolkit; and the `drag` verb as REAL POINTER INPUT on BOTH pools
   — tools/linux/dragdrive.py now holds the window-origin read and the
   press-walk-release the pointer proof already used, so the probe and
   the verb share one copy. tools/scenes/dnd.steps is the dnd-rust leg
   on x11 and wayland. Found on the way, all three in docs/traps.md: a
   Step's SECOND Target was never normalized (the mac lane cannot see
   it, since that interpreter parses the script itself), the x11
   toplevel X window is bigger than its content by the CSD shadow while
   sway reports the other side of it, and a widget's box is the one the
   last frame gave it.

   WinUI (the bindgen filter's new types, `DataPackage`, the SendInput
   verb, the OLE route if probe 2 says so), Compose (the two modifiers,
   the `input draganddrop` verb), iOS (the in-process route). The
   wayland legs declared off until the pointer slice.
   iOS DONE 2026-09-03: `KayaDragDropView` again, this time a `UIView`
   carrying a `UIDragInteraction` behind any node that declares a payload
   or is a row of a reorderable For and a `UIDropInteraction` behind any
   node that declares operations or is such a row — `itemsForBeginning`
   answering one `UIDragItem` whose provider carries the payload's
   representations (D5), `sessionDidUpdate` answering the core's verdict as
   a `UIDropProposal`, `performDrop` starting every load inside the callback
   (probe 5). `kayaDragSurfaces`, `kayaDragOpMask` and `kayaDriveDrag` take
   the mac's own names, so `KayaRender.kayaDragDrop` and the `drag` verb
   arm carry ONE condition and two backgrounds rather than two arms. The
   verb's route is D10's: real `NSItemProvider`s built from the source's
   declaration, a `KayaDragSessionDouble` behind `localDragSession` (which
   also carries the source's declared operation MASK, since iOS reduces it
   to one `allowsMoveOperation` bool that cannot spell move-without-copy),
   and the destination's real `canHandle` -> `sessionDidUpdate` ->
   `performDrop` in UIKit's order — the same three arms the mac verb
   drives. The gesture recognizer is exercised by nothing here; probe 5
   drove a real touch through the resident driver into a real
   `UIDropInteraction`, and the lane leg is the arms' proof. The swiftui/ios
   depth stub is struck and dnd rides the ios lane's rust-swiftui suite.

   COMPOSE DONE 2026-09-03: `kayaDragAndDropSurface` behind any node that
   declares a payload, an operation mask, or is a row of a reorderable For
   — `Modifier.dragAndDropSource` (Compose 1.9's `transferData` overload,
   whose default start detector IS the long press) plus
   `Modifier.dragAndDropTarget`, wrapped the way the file already wraps a
   context catalog so a node that declares nothing composes as it did.
   Three natives on `KayaPresent` (emitDropped, emitDragEnded,
   dragVerdict) and the `drag` verb as a RUNNER CHANNEL (D10's Android
   bullet). tools/scenes/dnd.steps green as the lane's `dnd-compose` leg.
   FOUR FINDINGS ON THE WAY, all in docs/traps.md: the compose BOM does
   not decide the compose version here (adaptive 1.2.0 pulls 1.9.0, so the
   1.7 API spelling does not compile); `input draganddrop` holds no long
   press while Compose's detector waits 500ms from the DOWN, which decides
   the injection's duration; an injected touch in a leg's first ~400ms is
   lost to the launch transition and the splash window, which is what the
   ack and its bounded re-injection are for; and a `drag` aimed the frame
   before the layout lands drops a row onto itself. AND ONE DEFECT THAT
   WAS NOT DND'S: these apps target SDK 35, where Android 15 forces edge
   to edge, so kaya's first row drew under the status bar and its last
   under the gesture bar — and that strip is the status bar's own
   TOUCHABLE region, which is why a reorder aimed at the first row could
   not reach the app. `KayaRoot` consumes `safeDrawingPadding()` now. No
   lane could see it: every click on that backend is programmatic and this
   is the first injected system touch it has ever taken.

   COMPOSE TAKES THE TEMPLATE ZONE WITH NO NEW KOTLIN, measured
   2026-09-03: the whole depth-2 scene minus the cut below ran green the
   first time the leg saw it, seven injections all served on try 1,
   `dnd-compose: PASS (16s)` inside a compose suite ALL PASS at 46 legs
   / 100s. That is a property of the contract rather than luck, and it
   is why the zone cost this backend nothing — a stamped copy's
   declaration arrives as the SAME apply op as a live one, carrying the
   copy's tag, and both arms resolve `KayaSceneModel.nodes[id]`; the
   copy's own outcome rides `identityTag`, which falls back to the
   CREATE tag that every stamped copy now carries (D8 amended), so a
   reorderable row's `drag_ended` needed no emit site of its own; a
   template `accepts` is an ordinary per-node SetProp; and the keyed
   target `label@item[y]` resolves through `tableStamp(node.tag)`, the
   arm the 2026-09-01 keyed-target slice already gave every tagged kind.
   THE FOREIGN FILE DROP IS CUT HERE, honestly (D9): the lane drops
   `drag_file` and the one assertion it feeds through
   tools/lib/lanes/android.py's MODS, and the Kotlin arm keeps its depth
   sentence. The runner's `drop` grammar grew for it — a drop is now a
   contiguous BLOCK named by step specs, each spec a leading run of
   words matching exactly one step (the verb alone where the scene has
   one, the whole line where the discriminator is the quoted text) —
   because the old (verb, target) form could name one step and this cut
   is a step plus the `expect label#4` it feeds, one of six. Its
   refusals run as five watched negatives at every launch, count
   printed.

   WINUI DONE 2026-09-03: both routes, as probes 1 and 2 measured them.
   XAML carries every WinRT drag — `CanDrag` + `DragStarting` filling a
   `DataPackage` (custom ids as `SetData(id, IRandomAccessStream)` over a
   memory `IStream`, files through `StorageFile.GetFileFromPathAsync`
   behind the starting deferral), `AllowDrop` + `DragEnter`/`DragOver`
   answering `wire::drop_verdict` through `AcceptedOperation`, `Drop`
   reading the chosen representation asynchronously, `DropCompleted`
   giving the source its outcome — and a kaya-private format whose NAME
   carries the pid answers local-versus-foreign from the format LIST,
   since the hover verdict is synchronous and cannot afford a read. The
   OLE route is armed beside it on the top-level HWND and on the island
   (`Microsoft.UI.Content.DesktopChildSiteBridge`, after `OleInitialize`),
   hit-testing by screen rect and reading HGLOBAL then ISTREAM one tymed
   per `GetData`; it registers on every dnd leg and prints the census, and
   its own drags are step 7's foreign witness. The `drag` verb is REAL
   INPUT in drive.ps1's measured shape, and the leg runs alone between
   drains because the mouse is OS-global. Three findings on the way, all
   in docs/traps.md: a deferred drop finished OFF the UI thread emits
   nothing (CORE is a thread_local) and reports `none` to the source; a
   withdrawn source must keep its identity, since the app withdraws it
   inside the `dropped` handler and `DropCompleted` comes after; and
   `Step::targets_mut` normalized only a drag's SOURCE, so every
   `kind@id[keys]` destination reached a rust-native backend as index 0.
6. The eight other bindings, then the matrix.
   DONE 2026-09-03: the §4 table carries every spelling; guests/<lang>/dnd
   in all nine languages, green on the mac lane first and then on every
   lane's roster (linux nine legs on both pools, windows six alone-legs
   since the verb moves the real mouse, android's compose/jvm/go
   families, iOS's rust-swiftui/swift/go suites). The occurrence side
   (`dropped`/`drag_ended`) had never been generated in any binding and
   grew its kaya-bindgen families; a stamped row's own `drag_ended` still
   reaches no registration (the ledger's open item).
7. Cross-app witnesses per desktop, and the reorder affordance's own
   insertion indicator on the two backends that must draw it.
   THE MAC HALF, MEASURED 2026-09-03
   (docs/probes/dnd-witness-mac-2026-09-03.md, tools/mac/dragwitness): a
   real cross-process drag CANNOT BE DRIVEN on this host. Every premise
   holds — the accessibility grant is given, a posted CGEvent moves the
   cursor exactly where told, the left button reads down on both event
   source state ids, and the press and its drags reach a real NSView's
   own `mouseDown`/`mouseDragged` — and
   `beginDraggingSession(with:event:source:)` still enters AppKit's nested
   tracking loop, never returns and never calls
   `draggingSession(_:willBeginAt:)`, so no pasteboard is composed and no
   destination in any process is ever asked. Held with a third process
   posting the pointer, with movement deltas, bundled, and at `.regular`
   activation policy. So the two mac lane legs this step asks for are NOT
   wired: a human at the machine is the only driver AppKit accepts, and
   the honest substitute a gate could still run — the interpreter's own
   `KayaDragDropView` compiled with a probe, driven against a pasteboard a
   FOREIGN process wrote and its composed payload read back by one — is
   named in the probe and not built.
   WHAT THE ATTEMPT DID BUY: the cross-process byte exchange is proven
   (`run.py --board` composes kaya's payload grammar in one process and
   reads all three representations, the MIME-shaped custom id included,
   in another), and it found a SHIPPED DEFECT in kaya's mac drag source —
   an empty `NSPasteboardItem` is zero pasteboard items, and on the one
   route `beginDraggingSession` returns from here it aborts the process.
   No lane could see it: the `drag` verb never calls
   `beginDraggingSession` at all (fixed; docs/traps.md carries the
   measurement AND its limit; `run.py --selftest` is the watched
   negative).


   LINUX DONE 2026-09-03, both pools. THE WITNESS is
   tools/linux/dragwitness.py, a stock PyGObject GTK4 client with nothing
   of kaya in it: a `GtkDragSource` offering text and a file, and a
   `GtkDropTarget` that says what arrived, both reporting on stdout.
   tools/linux/dragwitness-leg.py runs it beside the guest on the leg's own
   session and walks a REAL pointer between the two windows with
   tools/linux/dragdrive.py's own gesture — `dndwitness-out` drags kaya's
   declared source into the witness (which prints `got text hello`) and
   `dndwitness-in` drags the witness's file into kaya's files target, which
   is the one route through the real `GtkDropTargetAsync` with `local:
   false` that the in-process `drag_file` verb cannot exercise; kaya's
   guest reads it back out of the picked table as
   `files target got witness.txt witness bytes (copy)`, and the witness is
   told `copy` (D2's foreign rule). BOTH ENDS ARE READ ON EVERY LEG. Two
   findings, both in docs/traps.md: AT-SPI cannot say where a widget is
   (SCREEN extents are 0,0 on both protocols and WINDOW extents are 26px
   off), so the leg takes its geometry from the harness's own
   `KAYA_DIAG dragdrive` line; and `Gdk.ContentProvider.new_typed` is not
   introspectable, with the AttributeError swallowed inside `prepare` so
   the drag silently offers nothing.

   THE INSERTION INDICATOR on GTK: during a row drag over a reorderable
   For, a 3px accent line at the landing edge of the row under the pointer
   — its top for `before`, its bottom for `onto` — put up on enter and
   motion and taken down on leave, on drop and when the drag ends. It is
   `background-image: linear-gradient(..., @accent_bg_color 3px,
   transparent 3px)` on the row: a line rather than a shadow, and no
   layout, since a border would grow the row and displace every row under
   it in the middle of the drag. NO SCENE CAN SEE IT — every reorder
   observable answers identically with it gone — so tools/check-verbs.py
   holds the ten links (six call sites inside install_reorder, the two
   rules, the sheet's load and the provider that carries it to the
   display), each watched being cut. Measured once by hand on the x11
   pool, by filming the dnd-rust leg and reading the frames: the resting
   state is the container's 1px focus outline and the indicator is three
   more pixels at a row's edge, present through the drag and gone on the
   frame after the drop.

   THE `drag_file` VERB'S GTK ARM landed with it (D6): `GdkDrop` is
   abstract and has no constructor, so the platform's drop signal cannot be
   entered with a drag nobody started. The destination's own arms are
   factored out instead — `deliver_drop`, which the platform's `connect_drop`
   and the verb both call, over a `ClipOffer::Foreign` the verdict answers
   `local: false` for; `materialize` is what registers the file in the
   picked table, so a dropped file is redeemed exactly as a pasted one is.


   WINDOWS DONE 2026-09-03, both directions as lane legs plus the
   indicator. THE WITNESS IS THE STOCK OLE APP THE PROBES WERE MEASURED
   AGAINST (tools/win/dragprobe/stock, one copy, staged and built by
   tools/deploy-win.py where the probe's own run.py stages it), driven by
   tools/guest/dnd-witness.ps1 in the interactive session — a drag is real
   mouse input and OLE's modal loop reads the real message queue.
   BOTH LEGS ASSERT THROUGH KAYA'S OWN MODEL, read back out of the running
   app over UI Automation: the guest's status label is what the app wrote
   when the occurrence arrived, so a green witness is kaya having taken a
   foreign payload rather than a log line about one.
   `dndwitness_rust` (kaya SOURCE -> the foreign reader): the foreign
   process enumerated `dev.kaya/note(cf=49573,TYMED_ISTREAM)`,
   `CF_UNICODETEXT(cf=13,HGLOBAL)` and `dev.kaya/local.<pid>` and read
   `utf8="note!"` and `"hello"` back, and kaya's source learned `drag
   ended copy` through `DropCompleted` — probe 1's forward measurement,
   now on the real app, with the pid-named local marker proved VISIBLE to
   a foreign reader (which is what makes local-versus-foreign answerable
   from the format list at all).
   `dndforeign_rust` (a Win32 OLE source and Explorer -> kaya): THE
   CLASSIC ROUTE'S FIRST REAL DROP. `RegisterDragDrop` was armed on
   2026-09-03 and nothing had ever sent it a drag, so its arming census
   was the whole of its record; the leg drops text and a FILE from
   `DoDragDrop` into kaya's declared destinations and the guest reports
   `text target got text kaya stock text (copy)` and `files target got
   note.txt foreign bytes (copy)` — D6 end to end from a foreign source,
   CF_HDROP through `parse_dropfiles` and `picked_register` to the
   guest's own `PickedFile::open`. AND EXPLORER ITSELF, the third phase
   and probe 2's own question, with its own file so the label it produces
   cannot be the previous drop's: a real drag out of a File Explorer
   window's list item reads `files target got explorer.txt explorer bytes
   (copy)`. What made that phase work was rewriting its DIAGNOSTIC to
   discriminate — `[]` cannot tell "no window" from "a window UIA will not
   bind" from "a window with no items", and the per-round census that
   replaced it named the cause on its first run (docs/traps.md).
   Both legs run ALONE between drains (check-steps' menu_serial reads the
   `dnd*` prefix without its underscore now) and both sweep their
   processes at the end.
   THE INSERTION INDICATOR is kaya's own, because D8 declines
   `CanReorderItems`: while a row drag hovers a reorderable For's row, a
   2-DIP line at the LANDING EDGE — the row's top for `before`, its
   bottom for `onto`, the same half `drop_identity` reads — shown from the
   `DragOver` arm and cleared on `DragLeave`, on `Drop` and on
   `DropCompleted`. A POPUP AND NOT A CHILD: WinUI has no adorner layer,
   and a line added to the For's own panel would be a child every
   `child_order` index counts. Its colour is
   `{ThemeResource AccentFillColorDefaultBrush}`, the platform's own
   token, the rule the table card already carries. NO SCENE CAN SEE IT —
   `expect_order`, the drop's anchor and its before bit all answer
   identically with it gone — so tools/check-verbs.py byte-freezes the
   four arms with a watched negative each, and the picture is a hand
   measurement: driven over a real reorder drag on the VM 2026-09-03, the
   line is `#0067C0` (Windows 11's light `AccentFillColorDefaultBrush`),
   exactly 2 rows tall, straddling row a's top edge at the `before` hold
   and its bottom edge at the `onto` hold, and gone the frame after the
   release.
   AND `drag_file` (D6) IS THE OLE ROUTE'S OWN IN-PROCESS EXERCISE: the
   verb hands kaya's registered `IDropTarget` a CF_HDROP-only
   `IDataObject` at the destination's screen point, so the hit test, the
   verdict, the picked-table registration and the `dropped` emission are
   the arms a real Explorer drag takes. The data object is hand-rolled
   for `ole_get_data`'s own reason — STGMEDIUM's generated declaration is
   gated on `Win32_Graphics_Gdi` (crates/kaya/Cargo.toml), so neither
   `#[implement(IDataObject)]` nor the generated `SetData` exists in this
   feature set.
