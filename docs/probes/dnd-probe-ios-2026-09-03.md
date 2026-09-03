# iOS drop probe — does a cross-app drop raise the paste prompt?

docs/dnd-plan.md §2 probe 5. Started 2026-09-03.

- Host: macOS, Xcode 26.6.0, iOS 26.5 simulator runtime.
- Pool as found (never erased, rebooted or CoreSimulator-restarted):
  - kaya-sim-0 8F0680C5-7FD8-4C3B-977E-79CE84F150FA  iPhone 11 Pro   Booted
  - kaya-sim-1 45F06B45-D094-4BB9-8B7D-E3572FF334E1  iPhone 11 Pro   Booted
  - kaya-sim-2 3CD1C302-C686-4EC4-A10E-EE94FFE7C3A2  iPhone 11 Pro   Booted
  - kaya-sim-pad 13A39E1D-3A6A-47E8-BDF4-C96AC9F4A967  iPad Pro 13-inch (M5) Booted
- THE POOL HAS AN iPAD, so the cross-app question is reachable: multitasking
  drag needs two visible apps, which a phone cannot give.
- Host load at start: 2.55 / 5.05 / 14.12; no lane running.

## Log

### Build

- `tools/ios/dragprobe/main.swift` — the probe app (`dev.kaya.dragprobe`).
  Two `UIDropInteraction` destinations in one window: **strict**, whose
  `sessionDidUpdate` accepts exactly `public.utf8-plain-text` and
  `dev.kaya/note`, and **wide**, accepting `public.item` (a file drop needs
  it). A `DRAG ME` chip is a `UIDragInteraction` source registering both
  types, so the same receiver can be driven locally. `PASTE` reads
  `UIPasteboard.general.string`; `TYPES` reads the board's types.
  `UIDeviceFamily` is `[1,2]`, `UIFileSharingEnabled` is on (so the app's
  Documents are browsable from the stock Files app — the foreign FILE
  source), and `dev.kaya/note` is declared in `UTExportedTypeDeclarations`.
- `tools/ios/dragprobe/build.sh` — build+install, pickerprobe's shape.
- `tools/ios/dragprobe/drive.py` — a standalone launcher for the LANE'S OWN
  driver source (`tools/ios/xcuidrive/KayaDrive.swift`, not a copy). It
  exists because `tools/ios/run-sim.py` has no `__main__` guard: importing
  it runs the whole lane. Build 3s, `ready in 3s` on the pad.
- `tools/ios/dragprobe/gesture.py` — sends one driver verb while filming the
  device with `simctl io screenshot` every ~200ms, because a prompt may
  live only for the duration of the verb.

The pool was NOT erased, rebooted or restarted; the only device touched is
kaya-sim-pad, and the only app installed is `dev.kaya.dragprobe`.

## Measurement 1 — the POSITIVE CONTROL: the prompt does fire on this device

Without this the whole probe is unfalsifiable: "no prompt appeared" cannot
be told from "nothing happened".

1. `pb_write text` from the resident driver → the board's last writer is
   `KayaDrive-Runner`, a foreign principal.
2. Tap `PASTE` in DragProbe → `UIPasteboard.general.string` on a background
   queue.

```
DRAGPROBE 1788452748.872 Q7 paste: asking UIPasteboard.general.string (changeCount=22)
   [26.5 seconds of nothing — the read is PARKED]
DRAGPROBE 1788452775.359 Q7 paste returned: "foreign-clip-from-driver"
```

The screenshot taken while it was parked:
`/Users/akhilindurti/.claude/jobs/87aed9b4/tmp/shots/CONTROL-paste-prompt.png`

> **"DragProbe" would like to paste from "KayaDrive-Runner"**
> Do you want to allow this? — [Don't Allow Paste] [Allow Paste]

The read returned only after `press Allow Paste`. So: **iOS 26.5, this
simulator, this app, this minute — the iOS 16 paste prompt is live.**

## Measurement 2 — SAME-APP drag, driven by the resident driver's `drag`

`drag 88 950 516 300 1200` — a real long-press-and-move touch from the
chip's centre into the strict receiver, 3.82s.

Raw: `/Users/akhilindurti/.claude/jobs/87aed9b4/tmp/log-phase1-localdrag.log`
(106 lines; ~90 of them `sessionDidUpdate`, one per pointer move).

- The gesture DOES start a real `UIDragInteraction` session: `Q0
  itemsForBeginning` fired, and the drag crossed the wide view
  (`sessionDidEnter` … `sessionDidExit`) before entering the strict one.
- `sessionDidUpdate` was called ~90 times, every 16ms, each with a fresh
  location — the hover really is a per-move synchronous verdict.
- `local=true` throughout (`session.localDragSession != nil`).
- `allowsMove=true`, `isRestrictedToDraggingApplication=false`.
- The custom MIME-shaped id survives verbatim:
  `item[0].types=["public.utf8-plain-text", "dev.kaya/note"]`.

```
Q3 strict performDrop items=1 local=true canLoadNSString=true … hasNote=true
Q4 strict in-callback loadData item=0 type=public.utf8-plain-text bytes=15 err=- head="kaya-local-note"
Q4 strict in-callback loadData item=0 type=dev.kaya/note bytes=26 err=- head="{"note":"kaya-local-note"}"
Q6 strict loadFileRepresentation item=0 url=…/tmp/TemporaryItems/.com.apple.Foundation.NSItemProvider.5unw3Q/local.txt existsInCallback=true bytesInCallback=15
Q0b drag session ended operation=2      (2 = .copy)
Q3b strict concludeDrop
Q3c strict sessionDidEnd local=true
```

**D6's premise, measured and STRONGER than stated.** Three seconds after
`performDrop` returned, with the very same `NSItemProvider` objects held
alive by the probe:

```
Q6b strict 3s after the completion returned: exists=false bytes=-1 path=…/local.txt
Q5 strict deferred loadData item=0 type=public.utf8-plain-text bytes=-1
   err=NSItemProviderErrorDomain Code=-1000 "Cannot load representation of type public.utf8-plain-text"
       NSUnderlyingError=PBErrorDomain Code=0 same sentence
Q5 strict deferred loadData item=0 type=dev.kaya/note bytes=-1  … Code=-1000 …
Q5b strict deferred loadFileRepresentation item=0 url=nil … Code=-1000 …
```

It is not only the file's temp copy that dies with the callback (it does —
`exists=false`): the PROVIDER ITSELF stops answering once the drop session
ends. Every representation, data and file alike, must be *started* inside
`performDrop`.

## Measurement 3 — CROSS-APP: the stock Files app into the probe

### Getting two apps on screen

iPadOS 26.5's simulator boots the pad in the NEW **windowed** multitasking
mode, not Split View: each app is a free-floating window with traffic
lights (`window-controls:<bundle>`, Close/Minimize/Zoom) and a
`resize-grabber`. That is what the harness has to drive. What worked:

1. `simctl launch com.apple.DocumentsApp`, then drag its `resize-grabber`
   inward — the app leaves full screen and becomes a window.
2. `simctl launch dev.kaya.dragprobe`, drag ITS grabber, then drag the
   window by its top chrome strip to a clear position.
3. Both windows then live in SpringBoard's tree as
   `card:<bundle>:sceneID:<…>` with real frames, which is how the probe
   read where to aim.

Two traps worth writing down:

- **Driver coordinates are SCREEN coordinates**, not the attached app's
  window origin — `a.coordinate(withNormalizedOffset: .zero)` is the screen
  origin even when `a.frame` reports the window's size. A dock tap
  "corrected" by the window origin missed by exactly that origin.
- **A non-active window's `debugDescription` gives STALE geometry.**
  `describe2` (a read of the second app without activating it) reported
  the drop views 665pt wide when they were 954pt. Two of the failed
  attempts below were aimed with those numbers and landed outside the
  window; nothing was wrong with the platform. Aim from the ACTIVE read,
  or from SpringBoard's card frame.

### The gesture: the lane driver's `drag` CANNOT lift a stock app's item

`press(forDuration:thenDragTo:)` — the resident driver's `drag` — loses the
race with the long-press CONTEXT MENU on a Files cell. Measured at holds of
250, 350, 400, 500, 700, 1200 and 1500ms: the Copy/Move/Share menu opened
every time and no drag session was ever lifted
(`/Users/akhilindurti/.claude/jobs/87aed9b4/tmp/shots/GESTURE-lane-drag-opens-context-menu.png`,
`…/shots/GESTURE-lane-drag-hold700-context-menu.png`).

What lifts it is the four-argument form UIKit provides for exactly this,
`press(forDuration:thenDragTo:withVelocity:thenHoldForDuration:)` — added as
`xdrag X1 Y1 X2 Y2 LIFT_MS VELOCITY HOLD_MS` in a probe-local driver
(`tools/ios/dragprobe/DragDrive.swift`, same request/response protocol).
`xdrag … 800 200 1500` — lift 800ms, 200 pt/s, hold 1500ms over the
destination — lifted the item first try and every try after.

### The drop

`xdrag 516 384 180 980 800 200 1500`: from the `dragsource, txt` cell in
Files to the WIDE receiver in DragProbe. 6.19s.

```
Q1 wide canHandle items=1 local=false canLoadNSString=true canLoadNSURL=false
   hasText=false hasNote=false hasFileURL=false allowsMove=false
   restrictedToDraggingApplication=false
   item[0].types=["com.apple.DocumentManager.FINode.File", "public.plain-text"]
   item[0].suggestedName=dragsource.txt item[0].localObject=-
Q2a wide sessionDidEnter
Q3  wide performDrop items=1 local=false …
Q4  wide in-callback loadData item=0 type=com.apple.DocumentManager.FINode.File bytes=1845 head="bplist00…"
Q6  wide loadFileRepresentation item=0 url=…/tmp/TemporaryItems/.com.apple.Foundation.NSItemProvider.9GibbL/dragsource.txt existsInCallback=true bytesInCallback=26
Q4  wide in-callback loadData item=0 type=public.plain-text bytes=26 err=- head="kaya-foreign-file-payload\n"
Q3b wide concludeDrop
Q3c wide sessionDidEnd local=false
Q6b wide 3s after the completion returned: exists=false bytes=-1
Q5  wide deferred loadData … Code=-1000 "Cannot load representation of type public.plain-text"
Q5b wide deferred loadFileRepresentation url=nil … Code=-1000
```

**NO PROMPT.** `performDrop` at t=219.389, the foreign file's bytes in hand
at t=219.449 — **60 milliseconds**, where the paste control on the same
device parked for 26 seconds waiting for a human. Every screenshot taken
across the 6.19s gesture and the 8s after it shows the two windows and
nothing else:
`/Users/akhilindurti/.claude/jobs/87aed9b4/tmp/shots/CROSSAPP-drop-no-prompt.png`
(the WIDE band has gone purple — `performDrop` ran), and the 51 frames in
`…/shots/xd4/`.

Raw: `/Users/akhilindurti/.claude/jobs/87aed9b4/tmp/log-phase3-crossapp-files.log`

Three more things the foreign session said:

- `local=false` — `session.localDragSession` is nil, which is the ONLY
  reliable "this came from another app" signal a receiver has.
- `allowsMove=false` on a foreign session where the local one said true:
  the source app decides, and Files did not offer move.
- Files registers `com.apple.DocumentManager.FINode.File` and
  `public.plain-text` — and **no `public.file-url`**. A receiver that
  hunts for `public.file-url` sees nothing; `loadFileRepresentation` on
  `public.item` is what produces a file, and it produces a COPY in the
  receiver's own `tmp/TemporaryItems`, which is deleted when the
  completion handler returns.
- The STRICT receiver (the kaya-shaped vocabulary) answered
  `proposal=1` (`.forbidden`) to this session, correctly: it accepts
  `public.utf8-plain-text` and Files offers `public.plain-text`, which
  does not conform to it (the conformance runs the other way).

## Measurement 4 — the decisive one: a FOREIGN app offering kaya's own types

The Files app can only offer what Files offers, so it cannot answer two of
probe 5's questions: does a MIME-shaped custom id survive a cross-PROCESS
drag, and does a foreign TEXT drop reach a receiver that accepts exactly
kaya's vocabulary. So a second bundle —
`tools/ios/dragprobe/notesource.swift`, `dev.kaya.notesource`, a separate
principal — whose `UIDragInteraction` registers `public.utf8-plain-text` and
`dev.kaya/note` and nothing else.

Three windows on the pad: NoteSource (right), Files (middle), DragProbe
(left). `xdrag 982 341 180 780 800 200 1500` — the FOREIGN NOTE chip into
the STRICT receiver.

```
Q1  strict canHandle items=1 local=false canLoadNSString=true
    hasText=true hasNote=true hasFileURL=false allowsMove=false
    item[0].types=["public.utf8-plain-text", "dev.kaya/note"]
    item[0].suggestedName=foreign.txt item[0].localObject=-
Q2a strict sessionDidEnter
Q3  strict performDrop items=1 local=false …                        t=432.705
Q4  strict in-callback loadData item=0 type=public.utf8-plain-text bytes=25 head="kaya-foreign-text-payload"   t=432.709
Q4  strict in-callback loadData item=0 type=dev.kaya/note bytes=48 head="{"note":"kaya-foreign-note","from":"notesource"}"  t=432.709
Q6  strict loadFileRepresentation item=0 url=…/tmp/TemporaryItems/.com.apple.Foundation.NSItemProvider.z6r7GE/foreign.txt existsInCallback=true bytesInCallback=25
Q3b strict concludeDrop
Q3c strict sessionDidEnd local=false
Q5  strict deferred loadData … Code=-1000 (both types)
Q6b strict 3s after the completion returned: exists=false
```

**FOUR MILLISECONDS from `performDrop` to the foreign app's bytes in hand,
with no prompt of any kind.** Screenshots through the whole gesture:
`…/shots/CROSSAPP-text-midflight.png` (the chip in flight over the highlighted
STRICT band) and `…/shots/CROSSAPP-text-dropped.png` (both bands purple).
64 frames in `…/shots/xd5/`.

Raw: `/Users/akhilindurti/.claude/jobs/87aed9b4/tmp/log-phase4-crossapp-notesource.log`

And the side answer: **the MIME-shaped custom id crosses a process boundary
intact.** `dev.kaya/note` arrives in `registeredTypeIdentifiers` verbatim
and `hasItemsConforming(toTypeIdentifiers: ["dev.kaya/note"])` is true in
the receiving process. (The source bundle declared no
`UTExportedTypeDeclarations` at all; the receiver declared one. Whether the
declaration is load-bearing was not isolated — but a drag with neither side
declaring more than the receiver did works.)

## VERDICT

**No. A drop from another app does NOT raise the iOS paste prompt.** The
plan's reasoning holds and is now measured: the user's own drag gesture is
the consent, and `NSItemProvider` reads inside `performDrop` are not
pasteboard reads.

The measurement is falsifiable because the same app, on the same device, in
the same session, DID raise the prompt on `UIPasteboard.general.string` and
parked for 26 seconds until a human pressed Allow.

| route | foreign data | prompt | time to bytes |
|---|---|---|---|
| `UIPasteboard.general.string` | yes (driver's `pb_write`) | **YES** | 26.5s (blocked on the human) |
| drop from Files (`public.plain-text` + file) | yes | no | 60ms |
| drop from NoteSource (`utf8-plain-text` + `dev.kaya/note`) | yes | no | 4ms |
| drop from the same app | no | no | 2ms |

## What this means for docs/dnd-plan.md D6/D10 and the iOS arm

**D6 (dropped files are picked files) is right, and its premise is
stronger than the plan states.** The plan says "iOS's coordinated read is
why it cannot be a path". Measured, the constraint is not only about the
file: **the whole `NSItemProvider` dies when the drop session ends.** Three
seconds after `performDrop` returned, holding the provider objects alive
myself, every `loadDataRepresentation` — plain text, custom id, file
representation alike — failed with `NSItemProviderErrorDomain Code=-1000
"Cannot load representation of type …"` wrapping a `PBErrorDomain`, and the
file copy in `tmp/TemporaryItems/` was gone. So the iOS lowering cannot
register a dropped item into the picked table as a LAZY handle to be
redeemed later: by the time the guest calls `kaya_open_picked`, there is
nothing to open. The iOS arm must **read the bytes (or copy the file to a
location it owns) inside `performDrop`**, and register THAT. Which is what
`loadFileRepresentation` already implies — it hands you a temp copy, not the
original — and it is the same shape the file-dialog milestone settled on.
Beside it: the platform gives no `public.file-url` from Files at all, so an
arm that looks for one finds nothing; `loadFileRepresentation(forTypeIdentifier:
"public.item")` is the route.

**D10's iOS row can be upgraded, with one caveat.** The row today says the
iOS drag is "the in-process route through UIKit's `UIDropInteraction`
delegate methods with a session double, stated as 'the gesture recognizer is
not exercised', with the XCUITest driver named as the trigger for a real
touch." That trigger has fired: a real touch through the resident driver
drives a real `UIDragInteraction` → real `UIDropInteraction`, same-app and
cross-app, and the cross-app case even reaches a stock system app. A session
double is not needed on iOS. The caveat is the gesture:

- **The lane driver's `drag` is not enough.** `press(forDuration:thenDragTo:)`
  lifts kaya's own draggable (no context menu competing) but loses to the
  long-press context menu on any stock app's cell — 7 hold values tried, the
  menu every time. The drag arm should add
  `press(forDuration:thenDragTo:withVelocity:thenHoldForDuration:)` to
  `tools/ios/xcuidrive/KayaDrive.swift` — one more verb beside `drag`,
  `lift 800ms / 200 pt/s / hold 1500ms` measured working — otherwise the
  cross-app leg is undrivable and the same-app leg is at the mercy of
  whatever long-press affordance kaya's rows grow later (D8's reorder is
  exactly a long-press).
- **Cross-app on the phones stays off, as D9 says**, but the PAD is in the
  pool and cross-app IS reachable there, which is a foreign witness the
  plan did not think it had on iOS. It costs three window-placement drags
  (iPadOS 26 boots the pad in the new WINDOWED mode, so it is
  `resize-grabber` and a chrome drag, not Split View).
- **Two harness traps, both cheap to hit:** driver coordinates are SCREEN
  coordinates even when `a.frame` reports the window's size; and a
  background app's `debugDescription` returns STALE geometry, so a drop
  point must be aimed from the ACTIVE read or from SpringBoard's
  `card:<bundle>` frame. Both cost a run here.
- **A backgrounded probe app answered no drag at all** until it had a
  1-second repeating timer keeping it awake. Not isolated to a cause
  (suspension is the obvious candidate) and not a kaya problem — a kaya leg's
  app is the active window — but a cross-app leg that backgrounds the
  receiver should expect it.

**Nothing here touches D1–D5 or D7.** The hover verdict was observed to be
exactly what §0 says it is: ~90 synchronous `sessionDidUpdate` calls, one
per pointer move at 16ms, each answered from the TYPES with no bytes read —
and `session.allowsMoveOperation` came back **false** on both foreign
sessions and **true** on the local one, which is the source's choice, so
D3's copy/move vocabulary is negotiated per session on iOS and a receiver
must not assume move is available.

## Files and cleanup

Written (all inside `tools/ios/dragprobe/`, 72K, nothing else in the repo
touched):

- `main.swift` — the probe app, two `UIDropInteraction` receivers, a drag
  source, the paste control, the Q-labelled log.
- `notesource.swift` — the foreign drag source registering kaya's own types.
- `build.sh` — builds and installs both on a booted simulator.
- `drive.py` — a standalone launcher for the LANE'S driver source
  (`build lane`, the default) or the probe-local one (`build probe`), plus
  `start` / `send` / `stop` / `ps`.
- `DragDrive.swift` — the probe-local driver, adding `xdrag` (the
  press/velocity/hold form) and `attach2`/`describe2`.
- `gesture.py` — one verb with the device filmed throughout.

Evidence in `/Users/akhilindurti/.claude/jobs/87aed9b4/tmp/`:

- `probe-ios-drop.md` (this file)
- `log-phase1-localdrag.log`, `log-phase2-paste.log`,
  `log-phase3-crossapp-files.log`, `log-phase4-crossapp-notesource.log`
- `shots/CONTROL-paste-prompt.png` — the prompt, on the route that raises it
- `shots/CROSSAPP-drop-no-prompt.png`, `shots/CROSSAPP-text-midflight.png`,
  `shots/CROSSAPP-text-dropped.png`
- `shots/GESTURE-lane-drag-opens-context-menu.png`,
  `shots/GESTURE-lane-drag-hold700-context-menu.png`
- `shots/xd4/` (51 frames) and `shots/xd5/` (64 frames) — the two cross-app
  drops filmed end to end, which is where "no prompt appeared" is checkable
- `shots/00-*` … `shots/12-*` — the windowed-mode setup, step by step
- `shots/99-after-cleanup.png` — the pad back at its home screen

Cleanup, proven above:

- `dev.kaya.dragprobe` and `dev.kaya.notesource` uninstalled; `simctl
  listapps` lists neither. The three pre-existing `dev.kaya.*` guest apps
  from an earlier lane are left alone.
- `dev.kayalane.drive.runner` uninstalled too — the copy on the device at
  the end was THIS probe's build (DragDrive.swift), not the lane's, and
  `run-sim.py`'s `xcuidrive_start` reinstalls its own on the next run.
- No host processes left: `ps -Ao pid,etime,pcpu,command | grep -iE
  "xcodebuild|KayaDrive|dragprobe|notesource"` matches only another
  agent's `tools/win/dragprobe/run.py` (the Windows probe, not this one).
- The pool is as found: all four devices still `Booted`, none erased,
  rebooted, or reseeded; CoreSimulator never restarted.
- Build products: `target/ios-dragprobe` was 22M and is deleted.
  `du -sh tools/ios/dragprobe` = **72K**.
