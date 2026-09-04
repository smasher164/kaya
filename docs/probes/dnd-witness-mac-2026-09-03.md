# mac drag witness — can a real cross-process drag be DRIVEN? (2026-09-03)

docs/dnd-plan.md §5 step 7, D9. Run on this mac (macOS 26). COMPLETE.

## VERDICT

**No. A real cross-process `NSDraggingSession` cannot be driven without a
human on this host, and the reason is sharper than "real input is
refused".** Posting CGEvents works: the pointer moves exactly where it is
told, the left button reads down on both event-source state ids, and a
posted press and drag reach a real `NSView`'s `mouseDown`/`mouseDragged`.
And still `beginDraggingSession(with:event:source:)` never composes the
session — it enters AppKit's own nested tracking loop, never returns,
never calls `draggingSession(_:willBeginAt:)`, and no destination in any
process is ever asked.

What CAN be witnessed across processes, and is: the drag payload itself.
A drag's payload is a real system pasteboard with a name, so one process
composes kaya's grammar on it and another opens it by name and reads all
three representations back — the MIME-shaped custom id included.

**And the attempt found a shipped defect in kaya's own mac drag source**
that aborts the process, which no lane could ever have seen (§4).

## The tool

`tools/mac/dragwitness/witness.swift`, driven by
`tools/mac/dragwitness/run.py`. Four modes, each its own process:

- `catch --at x,y,w,h --report P` — a window that is a real
  `NSDraggingDestination`; writes what it received.
- `throw --at x,y,w,h [--file F] --report P` — a window whose view starts a
  real `NSDraggingSession` on its first `mouseDragged`, carrying kaya's own
  payload grammar (text, `dev.kaya/note`, a file URL) written at BOARD
  level.
- `drive --press x,y --to x,y` — the pointer and nothing else.
- `--board <name>` on either of the two above — compose or read a NAMED
  system pasteboard and exit, with no window and no gesture.

`run.py --pair` is the feasibility measurement, `--board` the cross-process
byte exchange, `--selftest` the watched negative of §4.

## Measurement 1 — the pointer moves, and the button is really down

`AXIsProcessTrusted()` is true for this repo's shell.

    mouse before = (772.47, 448.95)
    mouse after warp = (775.0, 1077.0)
    mouse after posted move = (781.47, 1057.0) wanted (781.47, 60.0 top-left)

`CGEvent(mouseEventSource:mouseType:.mouseMoved …).post(tap: .cghidEventTap)`
put the cursor exactly where asked (the two figures are the same point, one
counted from the top and one from the bottom of a 1117-point display).

With a posted `.leftMouseDown` held:

    button hid=true combined=true pressed=1

`CGEventSource.buttonState` on both `.hidSystemState` and
`.combinedSessionState`, and `NSEvent.pressedMouseButtons`, all agree the
left button is down. So this is not a permission problem and not a
"the events never arrived" problem.

## Measurement 2 — two things a posted press needs before it is a press

**A view that does not override `mouseDown` never receives the drag.**
NSResponder's default passes the press up the responder chain and every
later `mouseDragged` goes with it. The witness's first draft printed
nothing at all; with an empty `override func mouseDown` it printed the
press and then every drag. kaya's own `KayaDragDropView` already overrides
it.

**The activating click is separate from the press.** An inactive window's
first click is not delivered to the view (`acceptsFirstMouse` is false by
default), and a press posted within the double-click interval after it
arrives as `clickCount 2`. The driver posts a click, waits 700 ms — past
the interval — and then presses.

## Measurement 3 — `beginDraggingSession` never composes the session

From a real `mouseDragged` on a real view, with the button genuinely down:

    press at (150.0, 100.0)
    first drag at (152.8, 97.2)
    item ready
    main queue serviced during the session      <- a DispatchQueue.main.asyncAfter(1s)
                                                   scheduled just before the call
    (no "session began", ever)

`beginDraggingSession` does not return. It is a nested RUN LOOP, not a
deadlock — the main queue block scheduled immediately before the call still
fired. `draggingSession(_:willBeginAt:)` is never called, so the session's
pasteboard is never written, and the `catch` process in every run printed
nothing: no `entered`, no drop.

Held under every variable tried:

| variable | tried | result |
|---|---|---|
| who posts the pointer | the source itself; a THIRD process | same |
| movement deltas | absent; `kCGMouseEventDeltaX/Y` set per step | same |
| bundling | bare binary; `.app` with Info.plist and CFBundleIdentifier | same |
| activation policy | `.accessory`; `.regular` | same |

This refines docs/dnd-plan.md §0's lane table, which said CGEvent posting
was refused because it "types at whatever is frontmost and charges the
accessibility permission". Both of those are avoidable here — the windows
are placed and the permission is granted. The blocker is lower down: AppKit
will not start a drag session for a synthesized gesture at all.

## Measurement 4 — THE SHIPPED DEFECT the attempt found

    *** Terminating app due to uncaught exception 'NSGenericException',
        reason: 'There are 0 items on the pasteboard, but 1 drag images.
        There must be 1 draggingItem per pasteboardItem.'
        … -[NSDraggingSession(NSInternal) _initWithPasteboard:draggingItems:…]
          -[NSView(NSDrag) beginDraggingSessionWithItems:event:source:]

The witness's constructed-event route reproduced this with the SHIPPED
shape of kaya's mac drag source:

    let item = NSDraggingItem(pasteboardWriter: NSPasteboardItem())
    item.setDraggingFrame(bounds, contents: nil)
    beginDraggingSession(with: [item], event: event, source: self)

An `NSPasteboardItem` with no types written on it contributes ZERO items to
the session's pasteboard, and AppKit throws before the drag starts. kaya
writes its payload at BOARD level in `willBeginAt` — which AppKit calls only
once the drag really begins, long after this count is taken.

NO LANE COULD SEE IT. The `drag` verb drives the destination arms against a
pasteboard it builds itself (docs/dnd-plan.md D10's mac route) and never
calls `beginDraggingSession`, so the source's own AppKit entry point had
never executed in this repo's history.

THE LIMIT OF THIS MEASUREMENT, stated because the fix would otherwise be
sold on more than was seen: the throw is on the CONSTRUCTED-event route,
which is the only route `beginDraggingSession` returns from here — under a
synthesized real gesture it wedges (§3) before either answer is visible, and
in that state the same empty writer did NOT abort. So what a REAL gesture
meets at `_initWithPasteboard:draggingItems:` was not measured and cannot be
without a human. What is measured is that the shipped shape aborts wherever
that init is reached, and a writer carrying one type does not.

Fixed the same day: the writer carries the payload's text (or an empty
string) so it is one item, and `willBeginAt` still writes the whole payload
at board level. `run.py --selftest` runs both shapes and demands the
refusal:

    --- writer=empty exit -6 threw=True
    --- writer=1 exit 0 threw=False

## Measurement 5 — what a foreign process CAN witness today

`run.py --board`: one process composes, a SECOND opens the same named
system pasteboard and reads it.

    wrote dev.kaya.witness
    text kaya-foreign-text
    custom dev.kaya/note 8 bytes
    file witness.txt

All three representations cross the process boundary, the MIME-shaped
custom id verbatim — which is the id vocabulary D9 rules on, and the thing
macOS refuses at `NSPasteboardItem` level (probe 3,
docs/probes/dnd-probe-mac-2026-09-03.md).

## What is left, and for whom

The two mac lane legs §5 step 7 asks for — kaya's source dragged OUT into a
foreign window, and a foreign source dragged INTO kaya's targets, both as
real gestures — cannot be wired on this host by any route measured here.
A human moving the mouse is the only driver AppKit accepts. The options,
none of them taken:

- **A hand run with a person at the machine**, once, recorded here. It
  would exercise `willBeginAt`, the tracking loop and the destination's own
  arms, and is the only thing that can.
- **A gate in the check-pane-ladder family** — the interpreter's own
  `KayaDragDropView` compiled with a probe and driven against a pasteboard a
  FOREIGN process wrote, and its composed payload read back by a foreign
  process. That proves both directions' BYTES cross a process boundary and
  both of kaya's arms run, with the window server's tracking loop the one
  thing still absent. It needs no gesture.

## MEASURED AGAIN, the same evening — the verdict above was drawn too early

The maintainer asked for the reasoning and a re-measurement. `run.py
--pair`, run TEN times after Measurement 4's fix (the writer carrying one
type), landed NINE: `session began`, `drag ended copy`, and the catch
process reading `entered local false`, `text kaya-foreign-text`, `custom
dev.kaya/note 8 bytes`, `file witness.txt` — a real cross-process drag,
composed by AppKit from posted CGEvents, in a foreign window. The one
miss read `drag ended none` with the session begun. Measurement 3 was
taken with the EMPTY writer in place: the session never composed because
there were zero pasteboard items, and the fix that followed was never
re-measured against the gesture it had been blamed on. THE RULE THIS
LEAVES: A FIX INVALIDATES THE MEASUREMENTS TAKEN BEFORE IT; re-run the
one that motivated the verdict.

Against kaya itself (tools/mac/dragwitness-leg.py, the same shape as the
linux legs): kaya's own `KayaDragDropView` took the posted press and
first drag, called `beginDraggingSession`, and its `endedAt` fired — the
source composes and completes under a synthesized gesture too. What did
not land was the AIM on the maintainer's desktop: the witness window
placed beside kaya's was not where the pointer released (the maintainer
watched the drag end in the terminal), so the automated legs stay
unwired until they aim on an unattended desktop, and the mac half of §5
step 7 is `run.py --hand`: kaya and the witness on this desktop, a person
at the mouse, both directions' bytes verified by the tool.

## Files

- `tools/mac/dragwitness/witness.swift`, `tools/mac/dragwitness/run.py`
- build products under `target/mac-dragwitness` (not tracked)
