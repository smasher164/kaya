# mac drag probe — does a MIME-shaped custom type id survive an AppKit drag? (2026-09-03)

docs/dnd-plan.md §2 probe 3, run on this mac, 2026-09-03. COMPLETE.

## VERDICT

**NO on the item path, YES on the board path, and the Info.plist is a red
herring.** `dev.kaya/note` is dropped by every route an AppKit or SwiftUI
drag source naturally takes — `NSPasteboardItem.setData` returns false, a
custom `NSPasteboardWriting`'s `writableTypes` is refused, and a REAL
`beginDraggingSession` composes a pasteboard with no trace of it — each with
a console log saying "is not a valid UTI string". It survives verbatim,
readable by a second process, only through the BOARD-level
`declareTypes`/`addTypes` + `setData` path, which is the same path
swift/KayaSwiftUI.swift's copy arm already takes for the same reason.
BUNDLING CHANGES NOTHING: with `UTExportedTypeDeclarations` registered
system-wide, `UTType("dev.kaya/note")` is still nil (a MIME-shaped string
cannot be a UTI, so the declaration for it is ignored), and every route
behaves byte-identically to the unbundled run. The plist matters for one
thing only — cross-app DISCOVERY by MIME type — and only via a reverse-DNS
identifier carrying a `public.mime-type` tag. The gesture itself was not
driven.

## The question, restated from what the tree already knows

docs/clipboard-plan.md §5b finding 4 (2026-08-02) measured a charge macOS
puts on kaya's custom id grammar: `NSPasteboardItem.setData(forType:)`
VALIDATES its type string as a UTI, a slash is not legal in one, and the
data is DROPPED with only a console log; the board-level
`declareTypes` + `setData` path takes the string verbatim. That is why
swift/KayaSwiftUI.swift's copy arm writes item 0 at BOARD level
(the comment at line 1000 says so).

AppKit drag is built on the ITEM path — `NSDraggingItem(pasteboardWriter:)`
takes an `NSPasteboardWriting`, and the canonical writer is
`NSPasteboardItem`. So probe 3's question is sharper than the report that
prompted it: the report claims SwiftUI drag needs `UTExportedTypeDeclarations`
in an Info.plist; the tree's own record suggests the item path may refuse a
MIME-shaped id regardless of any plist, because a MIME-shaped string is not
a legal UTI and cannot be declared as one either.

Measurements below: which write route puts `dev.kaya/note` on the DRAG
pasteboard, what a second process reads back from it, what an
`NSDraggingDestination` registered for that type enumerates, and whether a
bundle with `UTExportedTypeDeclarations` changes any of it.

## What was NOT driven

The gesture. Real input is refused in this repo (docs/dnd-plan.md §0's lane
table: CGEvent posting types at whatever is frontmost and charges the
accessibility permission), and the maintainer was not available to drag by
hand. So this probe measures (a) what each source route WRITES to
`NSPasteboard(name: .drag)`, (b) what a SEPARATE PROCESS reads back from that
same system pasteboard, and (c) the real `NSDraggingDestination` arms driven
in process against a real pasteboard through an `NSDraggingInfo` double —
the plan's D10 mac route. No pointer was moved and no tracking loop ran.

## What was built

`tools/mac/dragprobe/` — three files, the clipprobe precedent's shape
(`run.py` drives, build products under `target/mac-dragprobe`, nothing
beside the sources):

- `src.swift` — the SOURCE process. One write route per run:
  - `board` — `NSPasteboard(name: .drag)` + `declareTypes` + `setData`,
    which is swift/KayaSwiftUI.swift's copy arm's own path.
  - `item` — `NSPasteboardItem.setData(forType:)` + `writeObjects`, which
    is what an AppKit drag source hands to `NSDraggingItem`.
  - `writer` — a hand-written `NSPasteboardWriting` returning the
    MIME-shaped id from `writableTypes(for:)`, the one route that could
    name a raw type string without going through `NSPasteboardItem`.
  - `provider` — `NSItemProvider.registerDataRepresentation(forTypeIdentifier:)`,
    SwiftUI `.onDrag`'s currency, with its pasteboard bridge measured.
  - `session` / `session-writer` — THE REAL THING minus the pointer:
    `view.beginDraggingSession(with:event:source:)` with a CONSTRUCTED
    (never posted) `NSEvent`, and the board AppKit itself composed read
    straight back off the returned session. One session per process.
  - `session-board` — the candidate workaround: begin a real session, then
    `addTypes` + `setData` the MIME-shaped id onto the session's own drag
    pasteboard at BOARD level.
- `recv.swift` — the RECEIVER, a SEPARATE process: an `NSView` registered
  for both ids plus text, reading `NSPasteboard(name: .drag)` after the
  source exited, and then the real `draggingEntered` / `draggingUpdated` /
  `prepareForDragOperation` / `performDragOperation` arms driven through an
  `NSDraggingInfo` DOUBLE (D10's mac route) — once over the system drag
  board, once over a PRIVATE named pasteboard.
- `run.py` — builds both, makes two `.app` bundles whose `Info.plist`
  carries `UTExportedTypeDeclarations`, and runs every route in both
  shapes, capturing stdout AND stderr (the UTI complaint is a console log,
  not a return value).

Every route carries TWO ids so the MIME shape is isolated as the cause:
`dev.kaya/note` (kaya's ruled grammar) and `dev.kaya.note` (a reverse-DNS
control — the only shape a `UTExportedTypeDeclarations` entry can legally
declare). The bundles declare BOTH, including a deliberately illegal
`UTTypeIdentifier` of `dev.kaya/note`, because that is the report's claim
taken literally.

Two full passes were run: **A** with no declaration registered with
LaunchServices, **B** with it registered (running the bundle registers it,
system-wide and asynchronously; run A caught the crossover mid-pass).

## The matrix

| write route | `dev.kaya/note` on the drag board | bytes readable in the OTHER process | console log |
|---|---|---|---|
| `board` (declareTypes + setData) | YES, verbatim | YES — 6 bytes `note=1` | none |
| `item` (NSPasteboardItem) | NO — dropped | no | `'dev.kaya/note' is not a valid UTI string.  Cannot set data for an invalid UTI.` |
| `writer` (own NSPasteboardWriting) | NO — dropped | no | `'dev.kaya/note' is not a valid UTI string.  Cannot use an invalid UTI as a type returned from -writeableTypesForPasteboard: in class main.KayaWriter.` |
| `provider` (NSItemProvider) | NO — the provider is not an `NSPasteboardWriting` at all on macOS | no | (its fallback item logs the same sentence) |
| `session` — REAL `beginDraggingSession` with an NSPasteboardItem | NO — dropped | no | same "Cannot set data" sentence |
| `session-writer` — REAL session with the custom writer | NO — dropped | no | same "-writeableTypesForPasteboard" sentence |
| `session-board` — REAL session, then `addTypes`+`setData` at board level | YES, verbatim, alongside the session's own item data | YES — 6 bytes `note=1` | none |

The reverse-DNS control `dev.kaya.note` survived EVERY route, bundled or
not, declared or not.

**Bundled vs unbundled changed nothing.** Normalising counters, pids and
timestamps, run A and run B differ in exactly 249 lines and every one of
them is a `UTType(...)` resolution line: what lands on the pasteboard, what
the second process reads, and what the destination arms enumerate are
byte-identical with the declaration registered and without it, and
identical again between the bare binary and the `.app`.

## The eight findings

**1. The report's premise does not survive contact. `UTExportedTypeDeclarations`
is irrelevant to a MIME-shaped id, because a MIME-shaped string cannot be a
UTI at all.** With the bundle registered, `UTType("dev.kaya.note")` resolves
(`declared=true dynamic=false`) — so the plist DID take effect — while
`UTType("dev.kaya/note")` is still `<nil>`. The plist dict declaring
`dev.kaya/note` as a `UTTypeIdentifier` was silently ignored. Adding an
Info.plist to the lane guests would buy nothing for kaya's custom ids.

**2. The item path refuses the slash, and the item path is what drag uses.**
`NSPasteboardItem.setData` returns `false` for `dev.kaya/note` and logs
`'dev.kaya/note' is not a valid UTI string.  Cannot set data for an invalid
UTI.` — docs/clipboard-plan.md §5b finding 4, reproduced on the DRAG board
16 months of milestones later. A REAL `beginDraggingSession` composes its
pasteboard from exactly that path, and the board it produced carried
`["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]` and no
`dev.kaya/note`.

**3. A hand-written `NSPasteboardWriting` cannot smuggle it either.** This
was the open possibility, and it is closed: AppKit validates the strings
returned from `writableTypes(for:)` too, with its own sentence naming the
class. So there is no `NSDraggingItem`-shaped route to a slashed type.

**4. `NSItemProvider` — SwiftUI's currency — keeps the id in process and has
no public pasteboard bridge.** `registeredTypeIdentifiers` came back as
`["dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text"]`,
`hasItemConformingToTypeIdentifier("dev.kaya/note")` is `true`, and
`loadDataRepresentation` returned the 6 bytes. But `provider is
NSPasteboardWriting` is **false** on macOS: whatever SwiftUI's `.onDrag`
uses to reach the drag pasteboard is not public, and the only public
conversions land back on `NSPasteboardItem`, which finding 2 covers.

**5. The board-level write survives a real session, which is the arm's way out.**
`session-board` began a real dragging session and then called `addTypes` +
`setData` on `session.draggingPasteboard`: `setData` returned `true`, the
board's types became `[dev.kaya.note, public.utf8-plain-text,
NSStringPboardType, dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df, dev.kaya/note]`,
the session's own item data was untouched, and the receiving PROCESS read
`data[dev.kaya/note] = 6 bytes note=1` back after the source exited.
CAVEAT, stated because it is the one thing this probe cannot settle: the
read happened immediately after the session began, with no tracking loop
running and no drop. Whether AppKit re-composes the board from the dragging
items once tracking starts is NOT measured — it needs a real gesture.

**6. What the receiving side enumerates, exactly.** After the `board` route:
`["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "dev.kaya.note",
"public.utf8-plain-text", "NSStringPboardType"]`. Three things to read off it:

- macOS synthesizes a DYNAMIC UTI wrapper for the raw string. Resolving it
  gives `dyn.ah62… dynamic=true mime=<none> tags=[com.apple.nspboard-type:
  ["dev.kaya/note"]]` — the raw id is recoverable from the tag.
- ITEM-level enumeration does not show the raw string:
  `pasteboardItems[0].types` is `[dyn.ah62…, dev.kaya.note,
  public.utf8-plain-text]`. A destination that walks ITEMS sees the `dyn.`
  form; a destination that walks the BOARD sees both.
- The UTI-conformance readers are the trap. `canReadItem(withDataConformingToTypes:
  ["dev.kaya/note"])` is **false** even while the bytes are right there;
  `availableType(from:)` and `data(forType:)`, which match raw strings,
  both answer. A mac arm must use the string-matching readers.

**7. The dynamic UTI a MIME lookup gives is a DIFFERENT string from the one on
the board.** Undeclared, `UTType(mimeType: "dev.kaya/note")` is
`dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df` while the board carries
`dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df` (`gq` against `gu` — a different tag
class). Declared, `UTType(mimeType:)` answers `dev.kaya.note`. So a foreign
app that goes looking for kaya's type BY MIME finds a different identifier
than the one on the wire unless a reverse-DNS UTI with a `public.mime-type`
tag is declared and registered. That is what an Info.plist would actually be
for — cross-app discovery, not kaya's own transfer.

**8. D10's in-process route works on a PRIVATE pasteboard.** The same
`NSDraggingInfo` double over `NSPasteboard(name: "dev.kaya.dragprobe.scratch")`
drove all four destination arms and read `data[dev.kaya/note] = 9 bytes
scratch=1`. A mac gate does not need to touch `NSPasteboard(name: .drag)` —
and should not, since a gate that writes it stamps on whatever drag the
person at the machine is in the middle of.

## What this means for docs/dnd-plan.md D7/D10 and the mac arm

**D7 is confirmed and gains a second reason.** The ruling put the mac
destination on an AppKit view for testability and for the full operation
mask; the measurement adds a third: the SOURCE cannot be a SwiftUI
`.onDrag` at all if kaya's custom representation is to travel, because
`NSItemProvider` has no public route to the drag pasteboard and every
public route that exists (`NSPasteboardItem`, a custom
`NSPasteboardWriting`) drops the MIME-shaped id with a console log and a
`false` return. The mac arm's source must be AppKit too, and specifically
it must be a `beginDraggingSession` whose custom representation is added to
`session.draggingPasteboard` at BOARD level after the session starts —
`addTypes` + `setData`, never through the dragging item's writer. That is
the same two-path dance kayaCopyToPasteboard already documents at
swift/KayaSwiftUI.swift:1000, and the drag arm should carry the same comment
pointing at the same finding.

D7's cost line should also gain the note that the source, not just the
destination, is AppKit-floor: an `NSViewRepresentable` that both registers
dragged types and begins sessions, one representable serving both ends.

**D10's mac row is confirmed as written, with one sharpening.** The
in-process route drove all four destination arms against a real pasteboard
through a protocol double, and it did so on a PRIVATE named pasteboard —
so the mac drag verb and the gate that backs it should build their own
board rather than `NSPasteboard(name: .drag)`, which is shared with the
logged-in human. The gate has check-pane-ladder's shape available: compile
the interpreter's own source with a probe main and drive the real arms.

**One premise stays open and it is the arm's, not the plan's.** Finding 5's
board-level add was read immediately after `beginDraggingSession` with no
tracking loop running. Whether the custom type is still on the board when a
real destination reads it mid-drag is unmeasured here, and no in-process
route can measure it — it needs a real gesture, which on this lane means
the maintainer dragging by hand once, or a foreign witness on a lane that
has real input. Until that is done, the mac arm should treat "the custom
representation survives a real drag" as a WATCH with an instrument at the
chokepoint (the destination's own `draggingEntered` logging the types it was
offered), not as a fact. If it turns out AppKit re-composes the board at
tracking time, the fallback is already visible in the data: ship the payload
under the reverse-DNS spelling as well, since `dev.kaya.note` survived every
single route.

**A grammar question for the maintainer, not for this probe.** kaya ruled
the custom id MIME-shaped because GDK refuses a slashless one
(docs/clipboard-plan.md, RATIFIED 2026-08-02) and macOS's board-level write
takes it verbatim. Drag does not overturn that — the board-level route still
works — but it narrows the mac arm to exactly one write path on a platform
where the natural drag API is the other one. The alternative nobody has
costed is a per-platform SPELLING of one logical id (`dev.kaya/note` on GTK,
Windows and Android, `dev.kaya.note` declared with a `public.mime-type` tag
on Apple), which would also make cross-app discovery work on the mac
(finding 7) at the price of a divergence invariant 1 would have to bless.
Stated so it can be ruled on, not proposed.

## Raw logs

Run A: no UTI declaration registered when the pass began (the crossover to
"registered" happens inside the BUNDLED half, visible in the `UTType` lines
from `BUNDLED route=session` onward). Run B: the same pass with the
declaration registered throughout. Normalised for pids, timestamps, change
counts and sequence numbers, the two differ ONLY in `UTType(...)` resolution
lines — 249 lines, no behavioural difference anywhere.

### Run A, in full

```
warning: Git tree '/Users/akhilindurti/Projects/kaya' is dirty

======== UNBUNDLED route=board ========
--- UNBUNDLED source board (exit 0)
SRC ==== route=board bundle=<none> macOS Version 26.6.2 (Build 25G83)
SRC UTType("dev.kaya/note") = <nil>
SRC UTType("dev.kaya.note") = <nil>
SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
SRC UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
SRC UTType(tag: "dev.kaya/note", .mimeType) = dyn.agq80k3p0f3z0c8pbf71g87df
SRC UTType("dev.kaya.note").tags = [:]
SRC board declareTypes=73 setData(mime)=true setData(rdns)=true setString=true
SRC board board.changeCount=73
SRC board board.types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
SRC board data[dev.kaya/note] = 6 bytes note=1
SRC board data[dev.kaya.note] = 6 bytes rdns=1
SRC board data[public.utf8-plain-text] = 9 bytes note text
SRC board items=1
SRC board item[0].types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya.note", "public.utf8-plain-text"]
SRC ==== end route=board
--- UNBUNDLED receiver after board (exit 0)
RCV ==== bundle=<none>
RCV UTType("dev.kaya/note") = <nil>
RCV UTType("dev.kaya.note") = <nil>
RCV UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
RCV registeredDraggedTypes=["dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text"]
RCV drag board changeCount=73
RCV drag board types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV drag board items=1
RCV drag board item[0].types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya.note", "public.utf8-plain-text"]
RCV drag board data[dev.kaya/note] = 6 bytes note=1
RCV drag board data[dev.kaya.note] = 6 bytes rdns=1
RCV drag board data[public.utf8-plain-text] = 9 bytes note text
RCV drag board type dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df -> UTType dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df dynamic=true mime=<none> tags=[com.apple.nspboard-type: ["dev.kaya/note"]]
RCV drag board type dev.kaya/note -> UTType <nil, not a UTI>
RCV drag board type dev.kaya.note -> UTType <nil, not a UTI>
RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[com.apple.ostype: ["utf8"], public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.nspboard-type: ["NSStringPboardType"]]
RCV drag board type NSStringPboardType -> UTType <nil, not a UTI>
RCV drag board canReadItem(mime)=false
RCV drag board availableType(mime,rdns,string)=dev.kaya/note
RCV arm draggingEntered types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV arm draggingEntered sourceMask=copy|move (raw 17)
RCV arm draggingEntered location=(42.0, 17.0)
RCV arm draggingEntered accepts-because=dev.kaya/note
RCV arm draggingUpdated mask=copy|move (raw 17)
RCV arm prepareForDragOperation
RCV arm performDragOperation types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV arm performDragOperation data[dev.kaya/note] = 6 bytes note=1
RCV arm performDragOperation data[dev.kaya.note] = 6 bytes rdns=1
RCV arm performDragOperation data[public.utf8-plain-text] = 9 bytes note text
RCV arm performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya.note", "public.utf8-plain-text"]]
RCV arm concludeDragOperation
RCV arm RESULT entered=copy (raw 1) updated=copy (raw 1) prepared=true performed=true
RCV scratch draggingEntered types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch draggingEntered sourceMask=copy (raw 1)
RCV scratch draggingEntered location=(42.0, 17.0)
RCV scratch draggingEntered accepts-because=dev.kaya/note
RCV scratch performDragOperation types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch performDragOperation data[dev.kaya/note] = 9 bytes scratch=1
RCV scratch performDragOperation data[dev.kaya.note] = <nil>
RCV scratch performDragOperation data[public.utf8-plain-text] = 12 bytes scratch text
RCV scratch performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "public.utf8-plain-text"]]
RCV scratch RESULT entered=copy (raw 1) performed=true
RCV ==== end

======== UNBUNDLED route=item ========
--- UNBUNDLED source item (exit 0)
SRC ==== route=item bundle=<none> macOS Version 26.6.2 (Build 25G83)
SRC UTType("dev.kaya/note") = <nil>
SRC UTType("dev.kaya.note") = <nil>
SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
SRC UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
SRC UTType(tag: "dev.kaya/note", .mimeType) = dyn.agq80k3p0f3z0c8pbf71g87df
SRC UTType("dev.kaya.note").tags = [:]
SRC item setData(mime)=false setData(rdns)=true setString=true
SRC item.types (before write) = ["dev.kaya.note", "public.utf8-plain-text"]
SRC item writeObjects=true
SRC item board.changeCount=74
SRC item board.types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
SRC item data[dev.kaya/note] = <nil>
SRC item data[dev.kaya.note] = 6 bytes rdns=1
SRC item data[public.utf8-plain-text] = 9 bytes note text
SRC item items=1
SRC item item[0].types=["dev.kaya.note", "public.utf8-plain-text"]
SRC ==== end route=item
    stderr| 2026-09-03 09:26:30.917 dragprobe-src[57325:59106631] 'dev.kaya/note' is not a valid UTI string.  Cannot set data for an invalid UTI.
--- UNBUNDLED receiver after item (exit 0)
RCV ==== bundle=<none>
RCV UTType("dev.kaya/note") = <nil>
RCV UTType("dev.kaya.note") = <nil>
RCV UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
RCV registeredDraggedTypes=["dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text"]
RCV drag board changeCount=74
RCV drag board types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV drag board items=1
RCV drag board item[0].types=["dev.kaya.note", "public.utf8-plain-text"]
RCV drag board data[dev.kaya/note] = <nil>
RCV drag board data[dev.kaya.note] = 6 bytes rdns=1
RCV drag board data[public.utf8-plain-text] = 9 bytes note text
RCV drag board type dev.kaya.note -> UTType <nil, not a UTI>
RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[com.apple.nspboard-type: ["NSStringPboardType"], com.apple.ostype: ["utf8"], public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""]]
RCV drag board type NSStringPboardType -> UTType <nil, not a UTI>
RCV drag board canReadItem(mime)=false
RCV drag board availableType(mime,rdns,string)=dev.kaya.note
RCV arm draggingEntered types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV arm draggingEntered sourceMask=copy|move (raw 17)
RCV arm draggingEntered location=(42.0, 17.0)
RCV arm draggingEntered accepts-because=dev.kaya.note
RCV arm draggingUpdated mask=copy|move (raw 17)
RCV arm prepareForDragOperation
RCV arm performDragOperation types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV arm performDragOperation data[dev.kaya/note] = <nil>
RCV arm performDragOperation data[dev.kaya.note] = 6 bytes rdns=1
RCV arm performDragOperation data[public.utf8-plain-text] = 9 bytes note text
RCV arm performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dev.kaya.note", "public.utf8-plain-text"]]
RCV arm concludeDragOperation
RCV arm RESULT entered=copy (raw 1) updated=copy (raw 1) prepared=true performed=true
RCV scratch draggingEntered types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch draggingEntered sourceMask=copy (raw 1)
RCV scratch draggingEntered location=(42.0, 17.0)
RCV scratch draggingEntered accepts-because=dev.kaya/note
RCV scratch performDragOperation types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch performDragOperation data[dev.kaya/note] = 9 bytes scratch=1
RCV scratch performDragOperation data[dev.kaya.note] = <nil>
RCV scratch performDragOperation data[public.utf8-plain-text] = 12 bytes scratch text
RCV scratch performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "public.utf8-plain-text"]]
RCV scratch RESULT entered=copy (raw 1) performed=true
RCV ==== end

======== UNBUNDLED route=writer ========
--- UNBUNDLED source writer (exit 0)
SRC ==== route=writer bundle=<none> macOS Version 26.6.2 (Build 25G83)
SRC UTType("dev.kaya/note") = <nil>
SRC UTType("dev.kaya.note") = <nil>
SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
SRC UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
SRC UTType(tag: "dev.kaya/note", .mimeType) = dyn.agq80k3p0f3z0c8pbf71g87df
SRC UTType("dev.kaya.note").tags = [:]
SRC writer writableTypes=["dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text"]
SRC writer writeObjects=true
SRC writer board.changeCount=75
SRC writer board.types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
SRC writer data[dev.kaya/note] = <nil>
SRC writer data[dev.kaya.note] = 6 bytes rdns=1
SRC writer data[public.utf8-plain-text] = 9 bytes note text
SRC writer items=1
SRC writer item[0].types=["dev.kaya.note", "public.utf8-plain-text"]
SRC ==== end route=writer
    stderr| 2026-09-03 09:26:30.941 dragprobe-src[57327:59106641] 'dev.kaya/note' is not a valid UTI string.  Cannot use an invalid UTI as a type returned from -writeableTypesForPasteboard: in class main.KayaWriter.
--- UNBUNDLED receiver after writer (exit 0)
RCV ==== bundle=<none>
RCV UTType("dev.kaya/note") = <nil>
RCV UTType("dev.kaya.note") = <nil>
RCV UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
RCV registeredDraggedTypes=["dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text"]
RCV drag board changeCount=75
RCV drag board types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV drag board items=1
RCV drag board item[0].types=["dev.kaya.note", "public.utf8-plain-text"]
RCV drag board data[dev.kaya/note] = <nil>
RCV drag board data[dev.kaya.note] = 6 bytes rdns=1
RCV drag board data[public.utf8-plain-text] = 9 bytes note text
RCV drag board type dev.kaya.note -> UTType <nil, not a UTI>
RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[com.apple.ostype: ["utf8"], public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.nspboard-type: ["NSStringPboardType"]]
RCV drag board type NSStringPboardType -> UTType <nil, not a UTI>
RCV drag board canReadItem(mime)=false
RCV drag board availableType(mime,rdns,string)=dev.kaya.note
RCV arm draggingEntered types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV arm draggingEntered sourceMask=copy|move (raw 17)
RCV arm draggingEntered location=(42.0, 17.0)
RCV arm draggingEntered accepts-because=dev.kaya.note
RCV arm draggingUpdated mask=copy|move (raw 17)
RCV arm prepareForDragOperation
RCV arm performDragOperation types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV arm performDragOperation data[dev.kaya/note] = <nil>
RCV arm performDragOperation data[dev.kaya.note] = 6 bytes rdns=1
RCV arm performDragOperation data[public.utf8-plain-text] = 9 bytes note text
RCV arm performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dev.kaya.note", "public.utf8-plain-text"]]
RCV arm concludeDragOperation
RCV arm RESULT entered=copy (raw 1) updated=copy (raw 1) prepared=true performed=true
RCV scratch draggingEntered types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch draggingEntered sourceMask=copy (raw 1)
RCV scratch draggingEntered location=(42.0, 17.0)
RCV scratch draggingEntered accepts-because=dev.kaya/note
RCV scratch performDragOperation types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch performDragOperation data[dev.kaya/note] = 9 bytes scratch=1
RCV scratch performDragOperation data[dev.kaya.note] = <nil>
RCV scratch performDragOperation data[public.utf8-plain-text] = 12 bytes scratch text
RCV scratch performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "public.utf8-plain-text"]]
RCV scratch RESULT entered=copy (raw 1) performed=true
RCV ==== end

======== UNBUNDLED route=provider ========
--- UNBUNDLED source provider (exit 0)
SRC ==== route=provider bundle=<none> macOS Version 26.6.2 (Build 25G83)
SRC UTType("dev.kaya/note") = <nil>
SRC UTType("dev.kaya.note") = <nil>
SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
SRC UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
SRC UTType(tag: "dev.kaya/note", .mimeType) = dyn.agq80k3p0f3z0c8pbf71g87df
SRC UTType("dev.kaya.note").tags = [:]
SRC provider registeredTypeIdentifiers=["dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text"]
SRC provider hasItemConformingToTypeIdentifier(mime)=true
SRC provider loadDataRepresentation(dev.kaya/note) -> 6 bytes note=1
SRC provider loadDataRepresentation(dev.kaya.note) -> 6 bytes rdns=1
SRC provider is NSPasteboardWriting = false
SRC provider not writable directly; writing NSPasteboardItem from its bytes
SRC fallback item writeObjects=true
SRC provider board.changeCount=76
SRC provider board.types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
SRC provider data[dev.kaya/note] = <nil>
SRC provider data[dev.kaya.note] = 6 bytes rdns=1
SRC provider data[public.utf8-plain-text] = 9 bytes note text
SRC provider items=1
SRC provider item[0].types=["dev.kaya.note", "public.utf8-plain-text"]
SRC ==== end route=provider
    stderr| 2026-09-03 09:26:30.961 dragprobe-src[57329:59106653] 'dev.kaya/note' is not a valid UTI string.  Cannot set data for an invalid UTI.
--- UNBUNDLED receiver after provider (exit 0)
RCV ==== bundle=<none>
RCV UTType("dev.kaya/note") = <nil>
RCV UTType("dev.kaya.note") = <nil>
RCV UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
RCV registeredDraggedTypes=["dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text"]
RCV drag board changeCount=76
RCV drag board types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV drag board items=1
RCV drag board item[0].types=["dev.kaya.note", "public.utf8-plain-text"]
RCV drag board data[dev.kaya/note] = <nil>
RCV drag board data[dev.kaya.note] = 6 bytes rdns=1
RCV drag board data[public.utf8-plain-text] = 9 bytes note text
RCV drag board type dev.kaya.note -> UTType <nil, not a UTI>
RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[com.apple.nspboard-type: ["NSStringPboardType"], com.apple.ostype: ["utf8"], public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""]]
RCV drag board type NSStringPboardType -> UTType <nil, not a UTI>
RCV drag board canReadItem(mime)=false
RCV drag board availableType(mime,rdns,string)=dev.kaya.note
RCV arm draggingEntered types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV arm draggingEntered sourceMask=copy|move (raw 17)
RCV arm draggingEntered location=(42.0, 17.0)
RCV arm draggingEntered accepts-because=dev.kaya.note
RCV arm draggingUpdated mask=copy|move (raw 17)
RCV arm prepareForDragOperation
RCV arm performDragOperation types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV arm performDragOperation data[dev.kaya/note] = <nil>
RCV arm performDragOperation data[dev.kaya.note] = 6 bytes rdns=1
RCV arm performDragOperation data[public.utf8-plain-text] = 9 bytes note text
RCV arm performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dev.kaya.note", "public.utf8-plain-text"]]
RCV arm concludeDragOperation
RCV arm RESULT entered=copy (raw 1) updated=copy (raw 1) prepared=true performed=true
RCV scratch draggingEntered types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch draggingEntered sourceMask=copy (raw 1)
RCV scratch draggingEntered location=(42.0, 17.0)
RCV scratch draggingEntered accepts-because=dev.kaya/note
RCV scratch performDragOperation types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch performDragOperation data[dev.kaya/note] = 9 bytes scratch=1
RCV scratch performDragOperation data[dev.kaya.note] = <nil>
RCV scratch performDragOperation data[public.utf8-plain-text] = 12 bytes scratch text
RCV scratch performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "public.utf8-plain-text"]]
RCV scratch RESULT entered=copy (raw 1) performed=true
RCV ==== end

======== UNBUNDLED route=session ========
--- UNBUNDLED source session (exit 0)
SRC ==== route=session bundle=<none> macOS Version 26.6.2 (Build 25G83)
SRC UTType("dev.kaya/note") = <nil>
SRC UTType("dev.kaya.note") = <nil>
SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
SRC UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
SRC UTType(tag: "dev.kaya/note", .mimeType) = dyn.agq80k3p0f3z0c8pbf71g87df
SRC UTType("dev.kaya.note").tags = [:]
SRC session[item] pasteboard.name=Apple CFPasteboard drag
SRC session[item] types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
SRC session[item] data[dev.kaya/note] = <nil>
SRC session[item] data[dev.kaya.note] = 6 bytes rdns=1
SRC session[item] data[public.utf8-plain-text] = 9 bytes note text
SRC session[item] sequence=41
SRC session-after board.changeCount=77
SRC session-after board.types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
SRC session-after data[dev.kaya/note] = <nil>
SRC session-after data[dev.kaya.note] = 6 bytes rdns=1
SRC session-after data[public.utf8-plain-text] = 9 bytes note text
SRC session-after items=1
SRC session-after item[0].types=["dev.kaya.note", "public.utf8-plain-text"]
SRC ==== end route=session
    stderr| 2026-09-03 09:26:31.030 dragprobe-src[57331:59106664] 'dev.kaya/note' is not a valid UTI string.  Cannot set data for an invalid UTI.
--- UNBUNDLED receiver after session (exit 0)
RCV ==== bundle=<none>
RCV UTType("dev.kaya/note") = <nil>
RCV UTType("dev.kaya.note") = <nil>
RCV UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
RCV registeredDraggedTypes=["dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text"]
RCV drag board changeCount=77
RCV drag board types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV drag board items=1
RCV drag board item[0].types=["dev.kaya.note", "public.utf8-plain-text"]
RCV drag board data[dev.kaya/note] = <nil>
RCV drag board data[dev.kaya.note] = 6 bytes rdns=1
RCV drag board data[public.utf8-plain-text] = 9 bytes note text
RCV drag board type dev.kaya.note -> UTType <nil, not a UTI>
RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.ostype: ["utf8"], com.apple.nspboard-type: ["NSStringPboardType"]]
RCV drag board type NSStringPboardType -> UTType <nil, not a UTI>
RCV drag board canReadItem(mime)=false
RCV drag board availableType(mime,rdns,string)=dev.kaya.note
RCV arm draggingEntered types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV arm draggingEntered sourceMask=copy|move (raw 17)
RCV arm draggingEntered location=(42.0, 17.0)
RCV arm draggingEntered accepts-because=dev.kaya.note
RCV arm draggingUpdated mask=copy|move (raw 17)
RCV arm prepareForDragOperation
RCV arm performDragOperation types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV arm performDragOperation data[dev.kaya/note] = <nil>
RCV arm performDragOperation data[dev.kaya.note] = 6 bytes rdns=1
RCV arm performDragOperation data[public.utf8-plain-text] = 9 bytes note text
RCV arm performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dev.kaya.note", "public.utf8-plain-text"]]
RCV arm concludeDragOperation
RCV arm RESULT entered=copy (raw 1) updated=copy (raw 1) prepared=true performed=true
RCV scratch draggingEntered types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch draggingEntered sourceMask=copy (raw 1)
RCV scratch draggingEntered location=(42.0, 17.0)
RCV scratch draggingEntered accepts-because=dev.kaya/note
RCV scratch performDragOperation types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch performDragOperation data[dev.kaya/note] = 9 bytes scratch=1
RCV scratch performDragOperation data[dev.kaya.note] = <nil>
RCV scratch performDragOperation data[public.utf8-plain-text] = 12 bytes scratch text
RCV scratch performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "public.utf8-plain-text"]]
RCV scratch RESULT entered=copy (raw 1) performed=true
RCV ==== end

======== UNBUNDLED route=session-writer ========
--- UNBUNDLED source session-writer (exit 0)
SRC ==== route=session-writer bundle=<none> macOS Version 26.6.2 (Build 25G83)
SRC UTType("dev.kaya/note") = <nil>
SRC UTType("dev.kaya.note") = <nil>
SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
SRC UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
SRC UTType(tag: "dev.kaya/note", .mimeType) = dyn.agq80k3p0f3z0c8pbf71g87df
SRC UTType("dev.kaya.note").tags = [:]
SRC session[writer] pasteboard.name=Apple CFPasteboard drag
SRC session[writer] types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
SRC session[writer] data[dev.kaya/note] = <nil>
SRC session[writer] data[dev.kaya.note] = 6 bytes rdns=1
SRC session[writer] data[public.utf8-plain-text] = 9 bytes note text
SRC session[writer] sequence=42
SRC session-after board.changeCount=78
SRC session-after board.types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
SRC session-after data[dev.kaya/note] = <nil>
SRC session-after data[dev.kaya.note] = 6 bytes rdns=1
SRC session-after data[public.utf8-plain-text] = 9 bytes note text
SRC session-after items=1
SRC session-after item[0].types=["dev.kaya.note", "public.utf8-plain-text"]
SRC ==== end route=session-writer
    stderr| 2026-09-03 09:26:31.098 dragprobe-src[57333:59106690] 'dev.kaya/note' is not a valid UTI string.  Cannot use an invalid UTI as a type returned from -writeableTypesForPasteboard: in class main.KayaWriter.
--- UNBUNDLED receiver after session-writer (exit 0)
RCV ==== bundle=<none>
RCV UTType("dev.kaya/note") = <nil>
RCV UTType("dev.kaya.note") = <nil>
RCV UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
RCV registeredDraggedTypes=["dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text"]
RCV drag board changeCount=78
RCV drag board types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV drag board items=1
RCV drag board item[0].types=["dev.kaya.note", "public.utf8-plain-text"]
RCV drag board data[dev.kaya/note] = <nil>
RCV drag board data[dev.kaya.note] = 6 bytes rdns=1
RCV drag board data[public.utf8-plain-text] = 9 bytes note text
RCV drag board type dev.kaya.note -> UTType <nil, not a UTI>
RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[com.apple.nspboard-type: ["NSStringPboardType"], com.apple.ostype: ["utf8"], public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""]]
RCV drag board type NSStringPboardType -> UTType <nil, not a UTI>
RCV drag board canReadItem(mime)=false
RCV drag board availableType(mime,rdns,string)=dev.kaya.note
RCV arm draggingEntered types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV arm draggingEntered sourceMask=copy|move (raw 17)
RCV arm draggingEntered location=(42.0, 17.0)
RCV arm draggingEntered accepts-because=dev.kaya.note
RCV arm draggingUpdated mask=copy|move (raw 17)
RCV arm prepareForDragOperation
RCV arm performDragOperation types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV arm performDragOperation data[dev.kaya/note] = <nil>
RCV arm performDragOperation data[dev.kaya.note] = 6 bytes rdns=1
RCV arm performDragOperation data[public.utf8-plain-text] = 9 bytes note text
RCV arm performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dev.kaya.note", "public.utf8-plain-text"]]
RCV arm concludeDragOperation
RCV arm RESULT entered=copy (raw 1) updated=copy (raw 1) prepared=true performed=true
RCV scratch draggingEntered types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch draggingEntered sourceMask=copy (raw 1)
RCV scratch draggingEntered location=(42.0, 17.0)
RCV scratch draggingEntered accepts-because=dev.kaya/note
RCV scratch performDragOperation types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch performDragOperation data[dev.kaya/note] = 9 bytes scratch=1
RCV scratch performDragOperation data[dev.kaya.note] = <nil>
RCV scratch performDragOperation data[public.utf8-plain-text] = 12 bytes scratch text
RCV scratch performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "public.utf8-plain-text"]]
RCV scratch RESULT entered=copy (raw 1) performed=true
RCV ==== end

======== UNBUNDLED route=session-board ========
--- UNBUNDLED source session-board (exit 0)
SRC ==== route=session-board bundle=<none> macOS Version 26.6.2 (Build 25G83)
SRC UTType("dev.kaya/note") = <nil>
SRC UTType("dev.kaya.note") = <nil>
SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
SRC UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
SRC UTType(tag: "dev.kaya/note", .mimeType) = dyn.agq80k3p0f3z0c8pbf71g87df
SRC UTType("dev.kaya.note").tags = [:]
SRC session-board before types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
SRC session-board addTypes=79 setData(mime)=true
SRC session-board after types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType", "dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note"]
SRC session-board data[dev.kaya/note] = 6 bytes note=1
SRC session-board data[dev.kaya.note] = 6 bytes rdns=1
SRC session-board data[public.utf8-plain-text] = 9 bytes note text
SRC session-board items=1
SRC session-board item[0].types=["dev.kaya.note", "public.utf8-plain-text", "dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df"]
SRC session-board-drag board.changeCount=79
SRC session-board-drag board.types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType", "dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note"]
SRC session-board-drag data[dev.kaya/note] = 6 bytes note=1
SRC session-board-drag data[dev.kaya.note] = 6 bytes rdns=1
SRC session-board-drag data[public.utf8-plain-text] = 9 bytes note text
SRC session-board-drag items=1
SRC session-board-drag item[0].types=["dev.kaya.note", "public.utf8-plain-text", "dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df"]
SRC ==== end route=session-board
--- UNBUNDLED receiver after session-board (exit 0)
RCV ==== bundle=<none>
RCV UTType("dev.kaya/note") = <nil>
RCV UTType("dev.kaya.note") = <nil>
RCV UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
RCV registeredDraggedTypes=["dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text"]
RCV drag board changeCount=79
RCV drag board types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType", "dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note"]
RCV drag board items=1
RCV drag board item[0].types=["dev.kaya.note", "public.utf8-plain-text", "dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df"]
RCV drag board data[dev.kaya/note] = 6 bytes note=1
RCV drag board data[dev.kaya.note] = 6 bytes rdns=1
RCV drag board data[public.utf8-plain-text] = 9 bytes note text
RCV drag board type dev.kaya.note -> UTType <nil, not a UTI>
RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[com.apple.ostype: ["utf8"], public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.nspboard-type: ["NSStringPboardType"]]
RCV drag board type NSStringPboardType -> UTType <nil, not a UTI>
RCV drag board type dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df -> UTType dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df dynamic=true mime=<none> tags=[com.apple.nspboard-type: ["dev.kaya/note"]]
RCV drag board type dev.kaya/note -> UTType <nil, not a UTI>
RCV drag board canReadItem(mime)=false
RCV drag board availableType(mime,rdns,string)=dev.kaya/note
RCV arm draggingEntered types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType", "dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note"]
RCV arm draggingEntered sourceMask=copy|move (raw 17)
RCV arm draggingEntered location=(42.0, 17.0)
RCV arm draggingEntered accepts-because=dev.kaya/note
RCV arm draggingUpdated mask=copy|move (raw 17)
RCV arm prepareForDragOperation
RCV arm performDragOperation types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType", "dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note"]
RCV arm performDragOperation data[dev.kaya/note] = 6 bytes note=1
RCV arm performDragOperation data[dev.kaya.note] = 6 bytes rdns=1
RCV arm performDragOperation data[public.utf8-plain-text] = 9 bytes note text
RCV arm performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dev.kaya.note", "public.utf8-plain-text", "dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df"]]
RCV arm concludeDragOperation
RCV arm RESULT entered=copy (raw 1) updated=copy (raw 1) prepared=true performed=true
RCV scratch draggingEntered types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch draggingEntered sourceMask=copy (raw 1)
RCV scratch draggingEntered location=(42.0, 17.0)
RCV scratch draggingEntered accepts-because=dev.kaya/note
RCV scratch performDragOperation types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch performDragOperation data[dev.kaya/note] = 9 bytes scratch=1
RCV scratch performDragOperation data[dev.kaya.note] = <nil>
RCV scratch performDragOperation data[public.utf8-plain-text] = 12 bytes scratch text
RCV scratch performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "public.utf8-plain-text"]]
RCV scratch RESULT entered=copy (raw 1) performed=true
RCV ==== end

======== BUNDLED route=board ========
--- BUNDLED source board (exit 0)
SRC ==== route=board bundle=dev.kaya.dragprobe.src macOS Version 26.6.2 (Build 25G83)
SRC UTType("dev.kaya/note") = <nil>
SRC UTType("dev.kaya.note") = <nil>
SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
SRC UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
SRC UTType(tag: "dev.kaya/note", .mimeType) = dyn.agq80k3p0f3z0c8pbf71g87df
SRC UTType("dev.kaya.note").tags = [:]
SRC board declareTypes=81 setData(mime)=true setData(rdns)=true setString=true
SRC board board.changeCount=81
SRC board board.types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
SRC board data[dev.kaya/note] = 6 bytes note=1
SRC board data[dev.kaya.note] = 6 bytes rdns=1
SRC board data[public.utf8-plain-text] = 9 bytes note text
SRC board items=1
SRC board item[0].types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya.note", "public.utf8-plain-text"]
SRC ==== end route=board
--- BUNDLED receiver after board (exit 0)
RCV ==== bundle=dev.kaya.dragprobe.recv
RCV UTType("dev.kaya/note") = <nil>
RCV UTType("dev.kaya.note") = <nil>
RCV UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
RCV registeredDraggedTypes=["dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text"]
RCV drag board changeCount=81
RCV drag board types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV drag board items=1
RCV drag board item[0].types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya.note", "public.utf8-plain-text"]
RCV drag board data[dev.kaya/note] = 6 bytes note=1
RCV drag board data[dev.kaya.note] = 6 bytes rdns=1
RCV drag board data[public.utf8-plain-text] = 9 bytes note text
RCV drag board type dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df -> UTType dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df dynamic=true mime=<none> tags=[com.apple.nspboard-type: ["dev.kaya/note"]]
RCV drag board type dev.kaya/note -> UTType <nil, not a UTI>
RCV drag board type dev.kaya.note -> UTType <nil, not a UTI>
RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[com.apple.ostype: ["utf8"], public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.nspboard-type: ["NSStringPboardType"]]
RCV drag board type NSStringPboardType -> UTType <nil, not a UTI>
RCV drag board canReadItem(mime)=false
RCV drag board availableType(mime,rdns,string)=dev.kaya/note
RCV arm draggingEntered types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV arm draggingEntered sourceMask=copy|move (raw 17)
RCV arm draggingEntered location=(42.0, 17.0)
RCV arm draggingEntered accepts-because=dev.kaya/note
RCV arm draggingUpdated mask=copy|move (raw 17)
RCV arm prepareForDragOperation
RCV arm performDragOperation types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV arm performDragOperation data[dev.kaya/note] = 6 bytes note=1
RCV arm performDragOperation data[dev.kaya.note] = 6 bytes rdns=1
RCV arm performDragOperation data[public.utf8-plain-text] = 9 bytes note text
RCV arm performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya.note", "public.utf8-plain-text"]]
RCV arm concludeDragOperation
RCV arm RESULT entered=copy (raw 1) updated=copy (raw 1) prepared=true performed=true
RCV scratch draggingEntered types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch draggingEntered sourceMask=copy (raw 1)
RCV scratch draggingEntered location=(42.0, 17.0)
RCV scratch draggingEntered accepts-because=dev.kaya/note
RCV scratch performDragOperation types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch performDragOperation data[dev.kaya/note] = 9 bytes scratch=1
RCV scratch performDragOperation data[dev.kaya.note] = <nil>
RCV scratch performDragOperation data[public.utf8-plain-text] = 12 bytes scratch text
RCV scratch performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "public.utf8-plain-text"]]
RCV scratch RESULT entered=copy (raw 1) performed=true
RCV ==== end

======== BUNDLED route=item ========
--- BUNDLED source item (exit 0)
SRC ==== route=item bundle=dev.kaya.dragprobe.src macOS Version 26.6.2 (Build 25G83)
SRC UTType("dev.kaya/note") = <nil>
SRC UTType("dev.kaya.note") = <nil>
SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
SRC UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
SRC UTType(tag: "dev.kaya/note", .mimeType) = dyn.agq80k3p0f3z0c8pbf71g87df
SRC UTType("dev.kaya.note").tags = [:]
SRC item setData(mime)=false setData(rdns)=true setString=true
SRC item.types (before write) = ["dev.kaya.note", "public.utf8-plain-text"]
SRC item writeObjects=true
SRC item board.changeCount=82
SRC item board.types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
SRC item data[dev.kaya/note] = <nil>
SRC item data[dev.kaya.note] = 6 bytes rdns=1
SRC item data[public.utf8-plain-text] = 9 bytes note text
SRC item items=1
SRC item item[0].types=["dev.kaya.note", "public.utf8-plain-text"]
SRC ==== end route=item
    stderr| 2026-09-03 09:26:31.218 DragProbeSrc[57339:59106732] 'dev.kaya/note' is not a valid UTI string.  Cannot set data for an invalid UTI.
--- BUNDLED receiver after item (exit 0)
RCV ==== bundle=dev.kaya.dragprobe.recv
RCV UTType("dev.kaya/note") = <nil>
RCV UTType("dev.kaya.note") = <nil>
RCV UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
RCV registeredDraggedTypes=["dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text"]
RCV drag board changeCount=82
RCV drag board types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV drag board items=1
RCV drag board item[0].types=["dev.kaya.note", "public.utf8-plain-text"]
RCV drag board data[dev.kaya/note] = <nil>
RCV drag board data[dev.kaya.note] = 6 bytes rdns=1
RCV drag board data[public.utf8-plain-text] = 9 bytes note text
RCV drag board type dev.kaya.note -> UTType <nil, not a UTI>
RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[com.apple.nspboard-type: ["NSStringPboardType"], public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.ostype: ["utf8"]]
RCV drag board type NSStringPboardType -> UTType <nil, not a UTI>
RCV drag board canReadItem(mime)=false
RCV drag board availableType(mime,rdns,string)=dev.kaya.note
RCV arm draggingEntered types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV arm draggingEntered sourceMask=copy|move (raw 17)
RCV arm draggingEntered location=(42.0, 17.0)
RCV arm draggingEntered accepts-because=dev.kaya.note
RCV arm draggingUpdated mask=copy|move (raw 17)
RCV arm prepareForDragOperation
RCV arm performDragOperation types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV arm performDragOperation data[dev.kaya/note] = <nil>
RCV arm performDragOperation data[dev.kaya.note] = 6 bytes rdns=1
RCV arm performDragOperation data[public.utf8-plain-text] = 9 bytes note text
RCV arm performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dev.kaya.note", "public.utf8-plain-text"]]
RCV arm concludeDragOperation
RCV arm RESULT entered=copy (raw 1) updated=copy (raw 1) prepared=true performed=true
RCV scratch draggingEntered types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch draggingEntered sourceMask=copy (raw 1)
RCV scratch draggingEntered location=(42.0, 17.0)
RCV scratch draggingEntered accepts-because=dev.kaya/note
RCV scratch performDragOperation types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch performDragOperation data[dev.kaya/note] = 9 bytes scratch=1
RCV scratch performDragOperation data[dev.kaya.note] = <nil>
RCV scratch performDragOperation data[public.utf8-plain-text] = 12 bytes scratch text
RCV scratch performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "public.utf8-plain-text"]]
RCV scratch RESULT entered=copy (raw 1) performed=true
RCV ==== end

======== BUNDLED route=writer ========
--- BUNDLED source writer (exit 0)
SRC ==== route=writer bundle=dev.kaya.dragprobe.src macOS Version 26.6.2 (Build 25G83)
SRC UTType("dev.kaya/note") = <nil>
SRC UTType("dev.kaya.note") = <nil>
SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
SRC UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
SRC UTType(tag: "dev.kaya/note", .mimeType) = dyn.agq80k3p0f3z0c8pbf71g87df
SRC UTType("dev.kaya.note").tags = [:]
SRC writer writableTypes=["dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text"]
SRC writer writeObjects=true
SRC writer board.changeCount=83
SRC writer board.types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
SRC writer data[dev.kaya/note] = <nil>
SRC writer data[dev.kaya.note] = 6 bytes rdns=1
SRC writer data[public.utf8-plain-text] = 9 bytes note text
SRC writer items=1
SRC writer item[0].types=["dev.kaya.note", "public.utf8-plain-text"]
SRC ==== end route=writer
    stderr| 2026-09-03 09:26:31.237 DragProbeSrc[57341:59106743] 'dev.kaya/note' is not a valid UTI string.  Cannot use an invalid UTI as a type returned from -writeableTypesForPasteboard: in class main.KayaWriter.
--- BUNDLED receiver after writer (exit 0)
RCV ==== bundle=dev.kaya.dragprobe.recv
RCV UTType("dev.kaya/note") = <nil>
RCV UTType("dev.kaya.note") = <nil>
RCV UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
RCV registeredDraggedTypes=["dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text"]
RCV drag board changeCount=83
RCV drag board types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV drag board items=1
RCV drag board item[0].types=["dev.kaya.note", "public.utf8-plain-text"]
RCV drag board data[dev.kaya/note] = <nil>
RCV drag board data[dev.kaya.note] = 6 bytes rdns=1
RCV drag board data[public.utf8-plain-text] = 9 bytes note text
RCV drag board type dev.kaya.note -> UTType <nil, not a UTI>
RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.nspboard-type: ["NSStringPboardType"], com.apple.ostype: ["utf8"]]
RCV drag board type NSStringPboardType -> UTType <nil, not a UTI>
RCV drag board canReadItem(mime)=false
RCV drag board availableType(mime,rdns,string)=dev.kaya.note
RCV arm draggingEntered types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV arm draggingEntered sourceMask=copy|move (raw 17)
RCV arm draggingEntered location=(42.0, 17.0)
RCV arm draggingEntered accepts-because=dev.kaya.note
RCV arm draggingUpdated mask=copy|move (raw 17)
RCV arm prepareForDragOperation
RCV arm performDragOperation types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV arm performDragOperation data[dev.kaya/note] = <nil>
RCV arm performDragOperation data[dev.kaya.note] = 6 bytes rdns=1
RCV arm performDragOperation data[public.utf8-plain-text] = 9 bytes note text
RCV arm performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dev.kaya.note", "public.utf8-plain-text"]]
RCV arm concludeDragOperation
RCV arm RESULT entered=copy (raw 1) updated=copy (raw 1) prepared=true performed=true
RCV scratch draggingEntered types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch draggingEntered sourceMask=copy (raw 1)
RCV scratch draggingEntered location=(42.0, 17.0)
RCV scratch draggingEntered accepts-because=dev.kaya/note
RCV scratch performDragOperation types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch performDragOperation data[dev.kaya/note] = 9 bytes scratch=1
RCV scratch performDragOperation data[dev.kaya.note] = <nil>
RCV scratch performDragOperation data[public.utf8-plain-text] = 12 bytes scratch text
RCV scratch performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "public.utf8-plain-text"]]
RCV scratch RESULT entered=copy (raw 1) performed=true
RCV ==== end

======== BUNDLED route=provider ========
--- BUNDLED source provider (exit 0)
SRC ==== route=provider bundle=dev.kaya.dragprobe.src macOS Version 26.6.2 (Build 25G83)
SRC UTType("dev.kaya/note") = <nil>
SRC UTType("dev.kaya.note") = <nil>
SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
SRC UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
SRC UTType(tag: "dev.kaya/note", .mimeType) = dyn.agq80k3p0f3z0c8pbf71g87df
SRC UTType("dev.kaya.note").tags = [:]
SRC provider registeredTypeIdentifiers=["dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text"]
SRC provider hasItemConformingToTypeIdentifier(mime)=true
SRC provider loadDataRepresentation(dev.kaya/note) -> 6 bytes note=1
SRC provider loadDataRepresentation(dev.kaya.note) -> 6 bytes rdns=1
SRC provider is NSPasteboardWriting = false
SRC provider not writable directly; writing NSPasteboardItem from its bytes
SRC fallback item writeObjects=true
SRC provider board.changeCount=84
SRC provider board.types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
SRC provider data[dev.kaya/note] = <nil>
SRC provider data[dev.kaya.note] = 6 bytes rdns=1
SRC provider data[public.utf8-plain-text] = 9 bytes note text
SRC provider items=1
SRC provider item[0].types=["dev.kaya.note", "public.utf8-plain-text"]
SRC ==== end route=provider
    stderr| 2026-09-03 09:26:31.256 DragProbeSrc[57343:59106753] 'dev.kaya/note' is not a valid UTI string.  Cannot set data for an invalid UTI.
--- BUNDLED receiver after provider (exit 0)
RCV ==== bundle=dev.kaya.dragprobe.recv
RCV UTType("dev.kaya/note") = <nil>
RCV UTType("dev.kaya.note") = <nil>
RCV UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
RCV registeredDraggedTypes=["dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text"]
RCV drag board changeCount=84
RCV drag board types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV drag board items=1
RCV drag board item[0].types=["dev.kaya.note", "public.utf8-plain-text"]
RCV drag board data[dev.kaya/note] = <nil>
RCV drag board data[dev.kaya.note] = 6 bytes rdns=1
RCV drag board data[public.utf8-plain-text] = 9 bytes note text
RCV drag board type dev.kaya.note -> UTType <nil, not a UTI>
RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.ostype: ["utf8"], com.apple.nspboard-type: ["NSStringPboardType"]]
RCV drag board type NSStringPboardType -> UTType <nil, not a UTI>
RCV drag board canReadItem(mime)=false
RCV drag board availableType(mime,rdns,string)=dev.kaya.note
RCV arm draggingEntered types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV arm draggingEntered sourceMask=copy|move (raw 17)
RCV arm draggingEntered location=(42.0, 17.0)
RCV arm draggingEntered accepts-because=dev.kaya.note
RCV arm draggingUpdated mask=copy|move (raw 17)
RCV arm prepareForDragOperation
RCV arm performDragOperation types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV arm performDragOperation data[dev.kaya/note] = <nil>
RCV arm performDragOperation data[dev.kaya.note] = 6 bytes rdns=1
RCV arm performDragOperation data[public.utf8-plain-text] = 9 bytes note text
RCV arm performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dev.kaya.note", "public.utf8-plain-text"]]
RCV arm concludeDragOperation
RCV arm RESULT entered=copy (raw 1) updated=copy (raw 1) prepared=true performed=true
RCV scratch draggingEntered types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch draggingEntered sourceMask=copy (raw 1)
RCV scratch draggingEntered location=(42.0, 17.0)
RCV scratch draggingEntered accepts-because=dev.kaya/note
RCV scratch performDragOperation types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch performDragOperation data[dev.kaya/note] = 9 bytes scratch=1
RCV scratch performDragOperation data[dev.kaya.note] = <nil>
RCV scratch performDragOperation data[public.utf8-plain-text] = 12 bytes scratch text
RCV scratch performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "public.utf8-plain-text"]]
RCV scratch RESULT entered=copy (raw 1) performed=true
RCV ==== end

======== BUNDLED route=session ========
--- BUNDLED source session (exit 0)
SRC ==== route=session bundle=dev.kaya.dragprobe.src macOS Version 26.6.2 (Build 25G83)
SRC UTType("dev.kaya/note") = <nil>
SRC UTType("dev.kaya.note") = <nil>
SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
SRC UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
SRC UTType(tag: "dev.kaya/note", .mimeType) = dyn.agq80k3p0f3z0c8pbf71g87df
SRC UTType("dev.kaya.note").tags = [:]
SRC session[item] pasteboard.name=Apple CFPasteboard drag
SRC session[item] types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
SRC session[item] data[dev.kaya/note] = <nil>
SRC session[item] data[dev.kaya.note] = 6 bytes rdns=1
SRC session[item] data[public.utf8-plain-text] = 9 bytes note text
SRC session[item] sequence=44
SRC session-after board.changeCount=85
SRC session-after board.types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
SRC session-after data[dev.kaya/note] = <nil>
SRC session-after data[dev.kaya.note] = 6 bytes rdns=1
SRC session-after data[public.utf8-plain-text] = 9 bytes note text
SRC session-after items=1
SRC session-after item[0].types=["dev.kaya.note", "public.utf8-plain-text"]
SRC ==== end route=session
    stderr| 2026-09-03 09:26:31.324 DragProbeSrc[57345:59106763] 'dev.kaya/note' is not a valid UTI string.  Cannot set data for an invalid UTI.
--- BUNDLED receiver after session (exit 0)
RCV ==== bundle=dev.kaya.dragprobe.recv
RCV UTType("dev.kaya/note") = <nil>
RCV UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
RCV UTType(mimeType: "dev.kaya/note") = dev.kaya.note
RCV registeredDraggedTypes=["dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text"]
RCV drag board changeCount=85
RCV drag board types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV drag board items=1
RCV drag board item[0].types=["dev.kaya.note", "public.utf8-plain-text"]
RCV drag board data[dev.kaya/note] = <nil>
RCV drag board data[dev.kaya.note] = 6 bytes rdns=1
RCV drag board data[public.utf8-plain-text] = 9 bytes note text
RCV drag board type dev.kaya.note -> UTType dev.kaya.note dynamic=false mime=dev.kaya/note tags=[public.mime-type: ["dev.kaya/note"]]
RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.nspboard-type: ["NSStringPboardType"], com.apple.ostype: ["utf8"]]
RCV drag board type NSStringPboardType -> UTType <nil, not a UTI>
RCV drag board canReadItem(mime)=false
RCV drag board availableType(mime,rdns,string)=dev.kaya.note
RCV arm draggingEntered types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV arm draggingEntered sourceMask=copy|move (raw 17)
RCV arm draggingEntered location=(42.0, 17.0)
RCV arm draggingEntered accepts-because=dev.kaya.note
RCV arm draggingUpdated mask=copy|move (raw 17)
RCV arm prepareForDragOperation
RCV arm performDragOperation types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV arm performDragOperation data[dev.kaya/note] = <nil>
RCV arm performDragOperation data[dev.kaya.note] = 6 bytes rdns=1
RCV arm performDragOperation data[public.utf8-plain-text] = 9 bytes note text
RCV arm performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dev.kaya.note", "public.utf8-plain-text"]]
RCV arm concludeDragOperation
RCV arm RESULT entered=copy (raw 1) updated=copy (raw 1) prepared=true performed=true
RCV scratch draggingEntered types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch draggingEntered sourceMask=copy (raw 1)
RCV scratch draggingEntered location=(42.0, 17.0)
RCV scratch draggingEntered accepts-because=dev.kaya/note
RCV scratch performDragOperation types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch performDragOperation data[dev.kaya/note] = 9 bytes scratch=1
RCV scratch performDragOperation data[dev.kaya.note] = <nil>
RCV scratch performDragOperation data[public.utf8-plain-text] = 12 bytes scratch text
RCV scratch performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "public.utf8-plain-text"]]
RCV scratch RESULT entered=copy (raw 1) performed=true
RCV ==== end

======== BUNDLED route=session-writer ========
--- BUNDLED source session-writer (exit 0)
SRC ==== route=session-writer bundle=dev.kaya.dragprobe.src macOS Version 26.6.2 (Build 25G83)
SRC UTType("dev.kaya/note") = <nil>
SRC UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
SRC UTType(mimeType: "dev.kaya/note") = dev.kaya.note
SRC UTType(tag: "dev.kaya/note", .mimeType) = dev.kaya.note
SRC UTType("dev.kaya.note").tags = [public.mime-type: ["dev.kaya/note"]]
SRC session[writer] pasteboard.name=Apple CFPasteboard drag
SRC session[writer] types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
SRC session[writer] data[dev.kaya/note] = <nil>
SRC session[writer] data[dev.kaya.note] = 6 bytes rdns=1
SRC session[writer] data[public.utf8-plain-text] = 9 bytes note text
SRC session[writer] sequence=45
SRC session-after board.changeCount=86
SRC session-after board.types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
SRC session-after data[dev.kaya/note] = <nil>
SRC session-after data[dev.kaya.note] = 6 bytes rdns=1
SRC session-after data[public.utf8-plain-text] = 9 bytes note text
SRC session-after items=1
SRC session-after item[0].types=["dev.kaya.note", "public.utf8-plain-text"]
SRC ==== end route=session-writer
    stderr| 2026-09-03 09:26:31.400 DragProbeSrc[57347:59106779] 'dev.kaya/note' is not a valid UTI string.  Cannot use an invalid UTI as a type returned from -writeableTypesForPasteboard: in class main.KayaWriter.
--- BUNDLED receiver after session-writer (exit 0)
RCV ==== bundle=dev.kaya.dragprobe.recv
RCV UTType("dev.kaya/note") = <nil>
RCV UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
RCV UTType(mimeType: "dev.kaya/note") = dev.kaya.note
RCV registeredDraggedTypes=["dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text"]
RCV drag board changeCount=86
RCV drag board types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV drag board items=1
RCV drag board item[0].types=["dev.kaya.note", "public.utf8-plain-text"]
RCV drag board data[dev.kaya/note] = <nil>
RCV drag board data[dev.kaya.note] = 6 bytes rdns=1
RCV drag board data[public.utf8-plain-text] = 9 bytes note text
RCV drag board type dev.kaya.note -> UTType dev.kaya.note dynamic=false mime=dev.kaya/note tags=[public.mime-type: ["dev.kaya/note"]]
RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[com.apple.ostype: ["utf8"], com.apple.nspboard-type: ["NSStringPboardType"], public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""]]
RCV drag board type NSStringPboardType -> UTType <nil, not a UTI>
RCV drag board canReadItem(mime)=false
RCV drag board availableType(mime,rdns,string)=dev.kaya.note
RCV arm draggingEntered types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV arm draggingEntered sourceMask=copy|move (raw 17)
RCV arm draggingEntered location=(42.0, 17.0)
RCV arm draggingEntered accepts-because=dev.kaya.note
RCV arm draggingUpdated mask=copy|move (raw 17)
RCV arm prepareForDragOperation
RCV arm performDragOperation types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
RCV arm performDragOperation data[dev.kaya/note] = <nil>
RCV arm performDragOperation data[dev.kaya.note] = 6 bytes rdns=1
RCV arm performDragOperation data[public.utf8-plain-text] = 9 bytes note text
RCV arm performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dev.kaya.note", "public.utf8-plain-text"]]
RCV arm concludeDragOperation
RCV arm RESULT entered=copy (raw 1) updated=copy (raw 1) prepared=true performed=true
RCV scratch draggingEntered types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch draggingEntered sourceMask=copy (raw 1)
RCV scratch draggingEntered location=(42.0, 17.0)
RCV scratch draggingEntered accepts-because=dev.kaya/note
RCV scratch performDragOperation types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch performDragOperation data[dev.kaya/note] = 9 bytes scratch=1
RCV scratch performDragOperation data[dev.kaya.note] = <nil>
RCV scratch performDragOperation data[public.utf8-plain-text] = 12 bytes scratch text
RCV scratch performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "public.utf8-plain-text"]]
RCV scratch RESULT entered=copy (raw 1) performed=true
RCV ==== end

======== BUNDLED route=session-board ========
--- BUNDLED source session-board (exit 0)
SRC ==== route=session-board bundle=dev.kaya.dragprobe.src macOS Version 26.6.2 (Build 25G83)
SRC UTType("dev.kaya/note") = <nil>
SRC UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
SRC UTType(mimeType: "dev.kaya/note") = dev.kaya.note
SRC UTType(tag: "dev.kaya/note", .mimeType) = dev.kaya.note
SRC UTType("dev.kaya.note").tags = [public.mime-type: ["dev.kaya/note"]]
SRC session-board before types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType"]
SRC session-board addTypes=87 setData(mime)=true
SRC session-board after types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType", "dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note"]
SRC session-board data[dev.kaya/note] = 6 bytes note=1
SRC session-board data[dev.kaya.note] = 6 bytes rdns=1
SRC session-board data[public.utf8-plain-text] = 9 bytes note text
SRC session-board items=1
SRC session-board item[0].types=["dev.kaya.note", "public.utf8-plain-text", "dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df"]
SRC session-board-drag board.changeCount=87
SRC session-board-drag board.types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType", "dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note"]
SRC session-board-drag data[dev.kaya/note] = 6 bytes note=1
SRC session-board-drag data[dev.kaya.note] = 6 bytes rdns=1
SRC session-board-drag data[public.utf8-plain-text] = 9 bytes note text
SRC session-board-drag items=1
SRC session-board-drag item[0].types=["dev.kaya.note", "public.utf8-plain-text", "dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df"]
SRC ==== end route=session-board
--- BUNDLED receiver after session-board (exit 0)
RCV ==== bundle=dev.kaya.dragprobe.recv
RCV UTType("dev.kaya/note") = <nil>
RCV UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
RCV UTType(mimeType: "dev.kaya/note") = dev.kaya.note
RCV registeredDraggedTypes=["dev.kaya/note", "dev.kaya.note", "public.utf8-plain-text"]
RCV drag board changeCount=87
RCV drag board types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType", "dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note"]
RCV drag board items=1
RCV drag board item[0].types=["dev.kaya.note", "public.utf8-plain-text", "dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df"]
RCV drag board data[dev.kaya/note] = 6 bytes note=1
RCV drag board data[dev.kaya.note] = 6 bytes rdns=1
RCV drag board data[public.utf8-plain-text] = 9 bytes note text
RCV drag board type dev.kaya.note -> UTType dev.kaya.note dynamic=false mime=dev.kaya/note tags=[public.mime-type: ["dev.kaya/note"]]
RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.ostype: ["utf8"], com.apple.nspboard-type: ["NSStringPboardType"]]
RCV drag board type NSStringPboardType -> UTType <nil, not a UTI>
RCV drag board type dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df -> UTType dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df dynamic=true mime=<none> tags=[com.apple.nspboard-type: ["dev.kaya/note"]]
RCV drag board type dev.kaya/note -> UTType <nil, not a UTI>
RCV drag board canReadItem(mime)=false
RCV drag board availableType(mime,rdns,string)=dev.kaya/note
RCV arm draggingEntered types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType", "dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note"]
RCV arm draggingEntered sourceMask=copy|move (raw 17)
RCV arm draggingEntered location=(42.0, 17.0)
RCV arm draggingEntered accepts-because=dev.kaya/note
RCV arm draggingUpdated mask=copy|move (raw 17)
RCV arm prepareForDragOperation
RCV arm performDragOperation types=["dev.kaya.note", "public.utf8-plain-text", "NSStringPboardType", "dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note"]
RCV arm performDragOperation data[dev.kaya/note] = 6 bytes note=1
RCV arm performDragOperation data[dev.kaya.note] = 6 bytes rdns=1
RCV arm performDragOperation data[public.utf8-plain-text] = 9 bytes note text
RCV arm performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dev.kaya.note", "public.utf8-plain-text", "dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df"]]
RCV arm concludeDragOperation
RCV arm RESULT entered=copy (raw 1) updated=copy (raw 1) prepared=true performed=true
RCV scratch draggingEntered types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch draggingEntered sourceMask=copy (raw 1)
RCV scratch draggingEntered location=(42.0, 17.0)
RCV scratch draggingEntered accepts-because=dev.kaya/note
RCV scratch performDragOperation types=["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "dev.kaya/note", "public.utf8-plain-text", "NSStringPboardType"]
RCV scratch performDragOperation data[dev.kaya/note] = 9 bytes scratch=1
RCV scratch performDragOperation data[dev.kaya.note] = <nil>
RCV scratch performDragOperation data[public.utf8-plain-text] = 12 bytes scratch text
RCV scratch performDragOperation readObjects(NSPasteboardItem) count=1 types=[["dyn.ah62d4rv4gu80k3p0f3z0c8pbf71g87df", "public.utf8-plain-text"]]
RCV scratch RESULT entered=copy (raw 1) performed=true
RCV ==== end
```

### Run B against run A — the whole difference

Unified diff of the two passes with pids, timestamps, change counts and
sequence numbers normalised. Every hunk is a UTI-resolution line.

```
--- runA-normalised
+++ runB-normalised
@@ -7,5 +7,5 @@
-SRC UTType("dev.kaya.note") = <nil>
-SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
-SRC UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
-SRC UTType(tag: "dev.kaya/note", .mimeType) = dyn.agq80k3p0f3z0c8pbf71g87df
-SRC UTType("dev.kaya.note").tags = [:]
+SRC UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
+SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
+SRC UTType(mimeType: "dev.kaya/note") = dev.kaya.note
+SRC UTType(tag: "dev.kaya/note", .mimeType) = dev.kaya.note
+SRC UTType("dev.kaya.note").tags = [public.mime-type: ["dev.kaya/note"]]
@@ -24,2 +24,2 @@
-RCV UTType("dev.kaya.note") = <nil>
-RCV UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
+RCV UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
+RCV UTType(mimeType: "dev.kaya/note") = dev.kaya.note
@@ -36,2 +36,2 @@
-RCV drag board type dev.kaya.note -> UTType <nil, not a UTI>
-RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[com.apple.ostype: ["utf8"], public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.nspboard-type: ["NSStringPboardType"]]
+RCV drag board type dev.kaya.note -> UTType dev.kaya.note dynamic=false mime=dev.kaya/note tags=[public.mime-type: ["dev.kaya/note"]]
+RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.ostype: ["utf8"], com.apple.nspboard-type: ["NSStringPboardType"]]
@@ -70,5 +70,5 @@
-SRC UTType("dev.kaya.note") = <nil>
-SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
-SRC UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
-SRC UTType(tag: "dev.kaya/note", .mimeType) = dyn.agq80k3p0f3z0c8pbf71g87df
-SRC UTType("dev.kaya.note").tags = [:]
+SRC UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
+SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
+SRC UTType(mimeType: "dev.kaya/note") = dev.kaya.note
+SRC UTType(tag: "dev.kaya/note", .mimeType) = dev.kaya.note
+SRC UTType("dev.kaya.note").tags = [public.mime-type: ["dev.kaya/note"]]
@@ -90,2 +90,2 @@
-RCV UTType("dev.kaya.note") = <nil>
-RCV UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
+RCV UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
+RCV UTType(mimeType: "dev.kaya/note") = dev.kaya.note
@@ -100,2 +100,2 @@
-RCV drag board type dev.kaya.note -> UTType <nil, not a UTI>
-RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[com.apple.nspboard-type: ["NSStringPboardType"], com.apple.ostype: ["utf8"], public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""]]
+RCV drag board type dev.kaya.note -> UTType dev.kaya.note dynamic=false mime=dev.kaya/note tags=[public.mime-type: ["dev.kaya/note"]]
+RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.ostype: ["utf8"], com.apple.nspboard-type: ["NSStringPboardType"]]
@@ -134,5 +134,5 @@
-SRC UTType("dev.kaya.note") = <nil>
-SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
-SRC UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
-SRC UTType(tag: "dev.kaya/note", .mimeType) = dyn.agq80k3p0f3z0c8pbf71g87df
-SRC UTType("dev.kaya.note").tags = [:]
+SRC UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
+SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
+SRC UTType(mimeType: "dev.kaya/note") = dev.kaya.note
+SRC UTType(tag: "dev.kaya/note", .mimeType) = dev.kaya.note
+SRC UTType("dev.kaya.note").tags = [public.mime-type: ["dev.kaya/note"]]
@@ -153,2 +153,2 @@
-RCV UTType("dev.kaya.note") = <nil>
-RCV UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
+RCV UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
+RCV UTType(mimeType: "dev.kaya/note") = dev.kaya.note
@@ -163,2 +163,2 @@
-RCV drag board type dev.kaya.note -> UTType <nil, not a UTI>
-RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[com.apple.ostype: ["utf8"], public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.nspboard-type: ["NSStringPboardType"]]
+RCV drag board type dev.kaya.note -> UTType dev.kaya.note dynamic=false mime=dev.kaya/note tags=[public.mime-type: ["dev.kaya/note"]]
+RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.nspboard-type: ["NSStringPboardType"], com.apple.ostype: ["utf8"]]
@@ -197,5 +197,5 @@
-SRC UTType("dev.kaya.note") = <nil>
-SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
-SRC UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
-SRC UTType(tag: "dev.kaya/note", .mimeType) = dyn.agq80k3p0f3z0c8pbf71g87df
-SRC UTType("dev.kaya.note").tags = [:]
+SRC UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
+SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
+SRC UTType(mimeType: "dev.kaya/note") = dev.kaya.note
+SRC UTType(tag: "dev.kaya/note", .mimeType) = dev.kaya.note
+SRC UTType("dev.kaya.note").tags = [public.mime-type: ["dev.kaya/note"]]
@@ -221,2 +221,2 @@
-RCV UTType("dev.kaya.note") = <nil>
-RCV UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
+RCV UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
+RCV UTType(mimeType: "dev.kaya/note") = dev.kaya.note
@@ -231,2 +231,2 @@
-RCV drag board type dev.kaya.note -> UTType <nil, not a UTI>
-RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[com.apple.nspboard-type: ["NSStringPboardType"], com.apple.ostype: ["utf8"], public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""]]
+RCV drag board type dev.kaya.note -> UTType dev.kaya.note dynamic=false mime=dev.kaya/note tags=[public.mime-type: ["dev.kaya/note"]]
+RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[com.apple.ostype: ["utf8"], public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.nspboard-type: ["NSStringPboardType"]]
@@ -265,5 +265,5 @@
-SRC UTType("dev.kaya.note") = <nil>
-SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
-SRC UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
-SRC UTType(tag: "dev.kaya/note", .mimeType) = dyn.agq80k3p0f3z0c8pbf71g87df
-SRC UTType("dev.kaya.note").tags = [:]
+SRC UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
+SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
+SRC UTType(mimeType: "dev.kaya/note") = dev.kaya.note
+SRC UTType(tag: "dev.kaya/note", .mimeType) = dev.kaya.note
+SRC UTType("dev.kaya.note").tags = [public.mime-type: ["dev.kaya/note"]]
@@ -288,2 +288,2 @@
-RCV UTType("dev.kaya.note") = <nil>
-RCV UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
+RCV UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
+RCV UTType(mimeType: "dev.kaya/note") = dev.kaya.note
@@ -298,2 +298,2 @@
-RCV drag board type dev.kaya.note -> UTType <nil, not a UTI>
-RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.ostype: ["utf8"], com.apple.nspboard-type: ["NSStringPboardType"]]
+RCV drag board type dev.kaya.note -> UTType dev.kaya.note dynamic=false mime=dev.kaya/note tags=[public.mime-type: ["dev.kaya/note"]]
+RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[com.apple.ostype: ["utf8"], public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.nspboard-type: ["NSStringPboardType"]]
@@ -332,5 +332,5 @@
-SRC UTType("dev.kaya.note") = <nil>
-SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
-SRC UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
-SRC UTType(tag: "dev.kaya/note", .mimeType) = dyn.agq80k3p0f3z0c8pbf71g87df
-SRC UTType("dev.kaya.note").tags = [:]
+SRC UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
+SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
+SRC UTType(mimeType: "dev.kaya/note") = dev.kaya.note
+SRC UTType(tag: "dev.kaya/note", .mimeType) = dev.kaya.note
+SRC UTType("dev.kaya.note").tags = [public.mime-type: ["dev.kaya/note"]]
@@ -355,2 +355,2 @@
-RCV UTType("dev.kaya.note") = <nil>
-RCV UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
+RCV UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
+RCV UTType(mimeType: "dev.kaya/note") = dev.kaya.note
@@ -365 +365 @@
-RCV drag board type dev.kaya.note -> UTType <nil, not a UTI>
+RCV drag board type dev.kaya.note -> UTType dev.kaya.note dynamic=false mime=dev.kaya/note tags=[public.mime-type: ["dev.kaya/note"]]
@@ -399,5 +399,5 @@
-SRC UTType("dev.kaya.note") = <nil>
-SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
-SRC UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
-SRC UTType(tag: "dev.kaya/note", .mimeType) = dyn.agq80k3p0f3z0c8pbf71g87df
-SRC UTType("dev.kaya.note").tags = [:]
+SRC UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
+SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
+SRC UTType(mimeType: "dev.kaya/note") = dev.kaya.note
+SRC UTType(tag: "dev.kaya/note", .mimeType) = dev.kaya.note
+SRC UTType("dev.kaya.note").tags = [public.mime-type: ["dev.kaya/note"]]
@@ -423,2 +423,2 @@
-RCV UTType("dev.kaya.note") = <nil>
-RCV UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
+RCV UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
+RCV UTType(mimeType: "dev.kaya/note") = dev.kaya.note
@@ -433,2 +433,2 @@
-RCV drag board type dev.kaya.note -> UTType <nil, not a UTI>
-RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[com.apple.ostype: ["utf8"], public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.nspboard-type: ["NSStringPboardType"]]
+RCV drag board type dev.kaya.note -> UTType dev.kaya.note dynamic=false mime=dev.kaya/note tags=[public.mime-type: ["dev.kaya/note"]]
+RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[com.apple.ostype: ["utf8"], com.apple.nspboard-type: ["NSStringPboardType"], public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""]]
@@ -469,5 +469,5 @@
-SRC UTType("dev.kaya.note") = <nil>
-SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
-SRC UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
-SRC UTType(tag: "dev.kaya/note", .mimeType) = dyn.agq80k3p0f3z0c8pbf71g87df
-SRC UTType("dev.kaya.note").tags = [:]
+SRC UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
+SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
+SRC UTType(mimeType: "dev.kaya/note") = dev.kaya.note
+SRC UTType(tag: "dev.kaya/note", .mimeType) = dev.kaya.note
+SRC UTType("dev.kaya.note").tags = [public.mime-type: ["dev.kaya/note"]]
@@ -486,2 +486,2 @@
-RCV UTType("dev.kaya.note") = <nil>
-RCV UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
+RCV UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
+RCV UTType(mimeType: "dev.kaya/note") = dev.kaya.note
@@ -498,2 +498,2 @@
-RCV drag board type dev.kaya.note -> UTType <nil, not a UTI>
-RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[com.apple.ostype: ["utf8"], public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.nspboard-type: ["NSStringPboardType"]]
+RCV drag board type dev.kaya.note -> UTType dev.kaya.note dynamic=false mime=dev.kaya/note tags=[public.mime-type: ["dev.kaya/note"]]
+RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.nspboard-type: ["NSStringPboardType"], com.apple.ostype: ["utf8"]]
@@ -532,5 +532,5 @@
-SRC UTType("dev.kaya.note") = <nil>
-SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
-SRC UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
-SRC UTType(tag: "dev.kaya/note", .mimeType) = dyn.agq80k3p0f3z0c8pbf71g87df
-SRC UTType("dev.kaya.note").tags = [:]
+SRC UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
+SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
+SRC UTType(mimeType: "dev.kaya/note") = dev.kaya.note
+SRC UTType(tag: "dev.kaya/note", .mimeType) = dev.kaya.note
+SRC UTType("dev.kaya.note").tags = [public.mime-type: ["dev.kaya/note"]]
@@ -552,2 +552,2 @@
-RCV UTType("dev.kaya.note") = <nil>
-RCV UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
+RCV UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
+RCV UTType(mimeType: "dev.kaya/note") = dev.kaya.note
@@ -562 +562 @@
-RCV drag board type dev.kaya.note -> UTType <nil, not a UTI>
+RCV drag board type dev.kaya.note -> UTType dev.kaya.note dynamic=false mime=dev.kaya/note tags=[public.mime-type: ["dev.kaya/note"]]
@@ -596,5 +596,5 @@
-SRC UTType("dev.kaya.note") = <nil>
-SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
-SRC UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
-SRC UTType(tag: "dev.kaya/note", .mimeType) = dyn.agq80k3p0f3z0c8pbf71g87df
-SRC UTType("dev.kaya.note").tags = [:]
+SRC UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
+SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
+SRC UTType(mimeType: "dev.kaya/note") = dev.kaya.note
+SRC UTType(tag: "dev.kaya/note", .mimeType) = dev.kaya.note
+SRC UTType("dev.kaya.note").tags = [public.mime-type: ["dev.kaya/note"]]
@@ -615,2 +615,2 @@
-RCV UTType("dev.kaya.note") = <nil>
-RCV UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
+RCV UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
+RCV UTType(mimeType: "dev.kaya/note") = dev.kaya.note
@@ -625,2 +625,2 @@
-RCV drag board type dev.kaya.note -> UTType <nil, not a UTI>
-RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.nspboard-type: ["NSStringPboardType"], com.apple.ostype: ["utf8"]]
+RCV drag board type dev.kaya.note -> UTType dev.kaya.note dynamic=false mime=dev.kaya/note tags=[public.mime-type: ["dev.kaya/note"]]
+RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[com.apple.ostype: ["utf8"], public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.nspboard-type: ["NSStringPboardType"]]
@@ -659,5 +659,5 @@
-SRC UTType("dev.kaya.note") = <nil>
-SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
-SRC UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
-SRC UTType(tag: "dev.kaya/note", .mimeType) = dyn.agq80k3p0f3z0c8pbf71g87df
-SRC UTType("dev.kaya.note").tags = [:]
+SRC UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
+SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
+SRC UTType(mimeType: "dev.kaya/note") = dev.kaya.note
+SRC UTType(tag: "dev.kaya/note", .mimeType) = dev.kaya.note
+SRC UTType("dev.kaya.note").tags = [public.mime-type: ["dev.kaya/note"]]
@@ -683,2 +683,2 @@
-RCV UTType("dev.kaya.note") = <nil>
-RCV UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
+RCV UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
+RCV UTType(mimeType: "dev.kaya/note") = dev.kaya.note
@@ -693,2 +693,2 @@
-RCV drag board type dev.kaya.note -> UTType <nil, not a UTI>
-RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.ostype: ["utf8"], com.apple.nspboard-type: ["NSStringPboardType"]]
+RCV drag board type dev.kaya.note -> UTType dev.kaya.note dynamic=false mime=dev.kaya/note tags=[public.mime-type: ["dev.kaya/note"]]
+RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[com.apple.ostype: ["utf8"], com.apple.nspboard-type: ["NSStringPboardType"], public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""]]
@@ -727,5 +727,5 @@
-SRC UTType("dev.kaya.note") = <nil>
-SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
-SRC UTType(mimeType: "dev.kaya/note") = dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df
-SRC UTType(tag: "dev.kaya/note", .mimeType) = dyn.agq80k3p0f3z0c8pbf71g87df
-SRC UTType("dev.kaya.note").tags = [:]
+SRC UTType("dev.kaya.note") = dev.kaya.note declared=true dynamic=false
+SRC UTType("public.utf8-plain-text") = public.utf8-plain-text declared=true dynamic=false
+SRC UTType(mimeType: "dev.kaya/note") = dev.kaya.note
+SRC UTType(tag: "dev.kaya/note", .mimeType) = dev.kaya.note
+SRC UTType("dev.kaya.note").tags = [public.mime-type: ["dev.kaya/note"]]
@@ -761 +761 @@
-RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.nspboard-type: ["NSStringPboardType"], com.apple.ostype: ["utf8"]]
+RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[com.apple.ostype: ["utf8"], public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.nspboard-type: ["NSStringPboardType"]]
@@ -828 +828 @@
-RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[com.apple.ostype: ["utf8"], com.apple.nspboard-type: ["NSStringPboardType"], public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""]]
+RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[com.apple.ostype: ["utf8"], public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.nspboard-type: ["NSStringPboardType"]]
@@ -896 +896 @@
-RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.ostype: ["utf8"], com.apple.nspboard-type: ["NSStringPboardType"]]
+RCV drag board type public.utf8-plain-text -> UTType public.utf8-plain-text dynamic=false mime=text/plain;charset=utf-8 tags=[com.apple.nspboard-type: ["NSStringPboardType"], public.mime-type: ["text/plain;charset=utf-8", "text/plain;charset=\"utf-8\""], com.apple.ostype: ["utf8"]]
```

## Reproduction and cleanup

Re-run: `nix develop -c python3 tools/mac/dragprobe/run.py` (all routes,
both shapes) or `… run.py board item session-board` for a subset. Build
products land in `target/mac-dragprobe` and nothing else is written.
`… run.py` never runs the `clear` route; run
`target/mac-dragprobe/dragprobe-src clear` last, which is what hands the
system drag pasteboard back.

Host state this probe touched, and gave back:

- **LaunchServices.** Launching the `.app` bundles registers their
  `UTExportedTypeDeclarations` SYSTEM-WIDE and asynchronously, which is why
  the unbundled binary saw `dev.kaya.note` as declared after a bundled run —
  the declaration is not per-process. Both bundles were unregistered with
  `lsregister -u` at the end and `UTType("dev.kaya.note")` reads `<nil>`
  again, with `UTType(mimeType: "dev.kaya/note")` back to the dynamic
  `dyn.ah62d4rv4gq80k3p0f3z0c8pbf71g87df` it answered before the probe ran.
  ANY future session running this probe inherits that same asynchronous
  registration: measure the undeclared case FIRST, unbundled, before a
  bundle has ever been launched.
- **The system drag pasteboard.** Cleared (`clear board.changeCount=104
  types=[]`).
- **Build products.** `target/mac-dragprobe` was 544K; deleted.
  `du -sh tools/mac/dragprobe` = 36K (three source files, no artifacts).
- **Processes.** `pgrep -fl 'dragprobe-src|dragprobe-recv|DragProbeSrc|DragProbeRecv|mac-dragprobe'`
  matches nothing (rc=1). A bare `pgrep -fl dragprobe` is NOT empty on this
  host, and the two matches are not this probe's: pid 56129 is an
  `xcodebuild test-without-building` against `target/ios-dragprobe` and pid
  56159 is a `DragProbe.app` inside an iOS simulator — a concurrent iOS drag
  probe this session did not start and did not touch.
