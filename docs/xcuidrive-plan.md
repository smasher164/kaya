# XCUITest as the iOS lane's one driver — subsuming simdrive and clipctl

Asked by the maintainer 2026-09-02 ("consider if XCUITest can end up
subsuming simdrive"). This is the measured answer and the conversion
plan. The conversion is BUILT (2026-09-02, the same day): §5 records each
step's state; §1 is what was measured before it.

## §0 — What the lane has today, and why it is two tools

- **tools/ios/simdrive (gone)** (Swift, host-side, one process per verb): reads
  the simulator's accessibility tree and delivers HID taps through
  SimulatorKit's PRIVATE frameworks (`SimDeviceLegacyHIDClient`, Indigo
  messages hand-packed from idb's header). It exists because the
  document picker is a remote view controller in another process, which
  the in-app harness cannot read, and because the paste-permission alert
  belongs to SpringBoard. Its verbs: `state`, `choose`, `cancel`,
  `describe`, `navstrip`, `savestate`, `savename`, `savepress`,
  `savecancel`, `press`, `swipe`. Its own comments record the cost of the
  route: taps dropped under load with no error, so `choose` and
  `savepress` walk and re-tap in rounds of six; `savename` sets AXValue
  and reads it back because a set that routes nowhere is silent; a
  private class "may have moved again in this Xcode"; and no pan reaches
  the content at all (the 2026-08-30 chore).
- **tools/ios/clipctl (gone)** (Swift, run INSIDE the simulator by `simctl
  spawn`): the foreign clipboard principal — writes seeds, reads the
  board, and is HELD ALIVE after a write because the pasteboard daemon
  fetches item data from the setter lazily (a writer that exits leaves a
  reader empty 1-in-5). Its foreign reads raise the paste prompt, which
  the host answers through simdrive's `press Allow Paste`. Holding and
  releasing those writers has its own machinery in run-sim.py
  (`clip_seed`, `clip_release_holder`, a census at the verdict), born of
  a process-group kill that wedged the pasteboard daemon.
- The two meet the guest through ONE file protocol (`KayaSimdrive.ask`
  in the interpreter, `simdrive_watch` on the host): a request file, a
  response file whose first line is ok/err.

## §1 — What XCUITest was measured to do (2026-09-02, iOS 26.5 sim, Xcode 26.6)

The resident driver (tools/ios/xcuidrive, docs/traps.md's build recipe)
attached to the LocalStorage export probe with its Files save sheet up,
and to SpringBoard, and did each of these first try:

| simdrive / clipctl today | XCUITest, measured |
|---|---|
| `describe` / `navstrip`: walk the picker's tree through the private AX bridge, per-attribute round trips | `app.debugDescription`: the whole remote picker in ONE snapshot — `FullDocumentManagerViewControllerNavigationBar`, the `Save` button, `More`, the back button `On My iPhone`, the `Search` field, `DOC.browsingRoot … Title: On My iPhone`, the `Browse View (Picker)` container. 121 lines. |
| `savestate`: the name field's value | `find DOCPicker.filenameTextField` → its frame; `value` → `kaya-export-xcui-2`. The field has a stable identifier. |
| `savename`: set AXValue, read back, retry the set up to five times | tap the field (it takes keyboard focus), `type` the name: the typing REPLACED the suggested value, and `value` read back exactly what was typed. No retry. |
| `savepress`: find Save in the strip, tap, poll for the sheet gone, six rounds | `find Save` → tap its centre → the sheet left (`find Save` then fails) and the export probe wrote its result file. One tap. |
| `press Allow Paste` on SpringBoard's pid (run-sim's `clip_press`) | `sb_find Allow Paste` on `XCUIApplication(bundleIdentifier: "com.apple.springboard")` → frame 44,462 288×48 → `sb_tap` → a parked clipctl read returned its content. |
| clipctl `write` + a held writer process | `pb_write` from the driver: clipctl's `types` then reports `public.utf8-plain-text`. The driver IS a held writer — it never exits — so the seed/hold/release/census machinery has nothing to hold. |
| clipctl `read` (parked on the prompt until the host presses Allow) | `pb_read`: the content read on a background queue with the main runloop pumped, the driver pressing `Allow Paste` on SpringBoard itself when it appears → `foreign-from-clipctl` (types `public.utf8-plain-text,dev.kaya/staged`); an own-content read returns with no prompt. |
| `swipe` (no pan reaches the content) | `press(forDuration:thenDragTo:)` scrolled Settings 317pt. kaya's own SwiftUI ScrollView still ignores a synthetic pan (docs/traps.md) — the same on both routes. |
| a tap on the app's own widget | `tap` at the `step` button's centre: kaya's handler ran (`step 1`, `Work` inserted). |

Two things measured on the way, both in docs/traps.md: a per-element
walk asking `isHittable` is a snapshot per element and wedged the driver
(`debugDescription` is one snapshot); and a pasteboard content read on
the test thread, or behind a semaphore, deadlocks because the reply
rides the runner's main runloop.

Latency, standalone on a calm host, from XCUITest's own action log: an
existence check or `find` 20–50ms; a `tap` ~1.1s and a `drag` ~1.5s
(XCUITest waits for the app to go idle after each touch); `attach`
1–3s. A dialog verb that makes a few finds and one tap is therefore
~1.5s; simdrive's is ~100ms when a tap lands and ~18–48s when it spends
its six rounds.

Measured since, by the conversion itself: the OPEN picker's `state`/
`choose`/`cancel` (the filedialog legs, all four suites, green; the rows
and the cancel are in docs/traps.md), and the lane under a five-lane
matrix — 365s for 114 legs (matrix 25) against 416s and 431s for 113
with simdrive and clipctl (matrices 24 and 23), admission 11–14s a
phone and each cancel 3–6s. Scrolling: the driver's pan DOES scroll
kaya's ScrollView when it starts inside the scroll's frame; the earlier
"no pan" was kaya's iOS scroll being only as wide as its content — ruled
the same day: a scroll spans its parent's cross axis on every backend
(DESIGN.md), held by `expect_breadth scroll#0` on all five lanes and by
the `xcuidrive-pan` leg, a real pan at the window's middle. The `type` verb's iOS route is the driver's since the same day: the
interpreter keeps the caret-to-end and the settle and asks the host for
the KEYS (`type_b64`, real presses through the simulator's keyboard);
`insertText`, the in-process stand-in the arm used while the platform
had no key route, is deleted. Measured first by hand on the undo guest
(tap the entry, keyboard up, `type milk`, the field reads `milk`), then
the undo and ranges legs green with each `type` answered in ~350ms.

## §2 — The design

ONE resident XCUITest driver per pool simulator, started at boot before
admission and stopped at the end, the only accessibility client on the
device — which is what dissolves the conflict the opt-in exists for
(docs/traps.md: an XCUITest session and simdrive cannot share the
bridge). It serves the SAME file protocol the guest already speaks:
`simdrive_watch` routes each request to the device's driver instead of
spawning simdrive, and `KayaSimdrive.ask` in the interpreter does not
change. The verbs keep their names and their answer shapes (`state`
prints the directory then one row per line; `savestate` the directory
then the name; a failure names what the picker DID offer), so
check-steps and the scenes are untouched.

The clipboard crossings move into the driver too: `clip_seed` becomes a
`pb_write` (the driver is the foreign principal AND the held writer),
`clip_read` a `pb_read` that answers its own prompt, `clip_press`
`sb_tap Allow Paste`, `types` the driver's. The design's foreignness is
preserved: the runner is not the app, so the app's own reads still
prompt and the seed is still attributed to another principal. What
goes: clipctl, its build, `simctl spawn` per crossing, the holder
processes and their census.

## §3 — What it buys

- No private frameworks: SimulatorKit's HID client and its hand-packed
  Indigo messages, the class that "may have moved again", the AX bridge
  round trips — all replaced by a supported API that Apple keeps working
  across Xcode releases.
- One driver, one session, no coexistence rule; the drag arm's real
  touches and the dialog legs' taps come from the same hands.
- Fewer rounds: the Save flow that needed six-round re-tap loops landed
  once. (Under the matrix that may not hold; the rounds can stay as a
  guard with a count that reads 1 when healthy.)
- The pasteboard machinery collapses to three verbs in a process that
  never exits.

## §4 — Risks and what to measure

- Latency under load: every find is an accessibility snapshot; the
  dialog legs make tens per verb. Measure the leg times before and after
  on the swift suite standalone and under the matrix.
- The runner is a foreground app at start and after each guest exits;
  a guest launched by `simctl launch` came forward over it every time
  measured, but a leg that reads "the frontmost app" must never be one
  the runner wins.
- Memory: four resident runners (≈ a UIKit app each).
- `type` semantics: XCUITest's typing goes through the keyboard, with
  autocorrect; the picker's field took a hyphenated name verbatim, but
  a kaya text field under the `type` verb must be measured the same way.
- Device recovery: a lane that erases and reboots one device mid-run
  must restart that device's driver (the opt-in code has no such path).

## §5 — Conversion order, each step validated by its legs then a matrix

0. DONE 657d5ae: the opt-in driver, the checkpoint this plan built on.
1. DONE 2026-09-02: resident from boot, one per device (the pad too),
   started before admission and waited on by each device's
   preparation; the export probe's sheet driven by `attach`/`savename`/
   `savepress`; the opt-in flag gone.
2. DONE: the save legs' four verbs routed by `simdrive_watch` (the name
   kept, since the guest's protocol is unchanged) to the driver.
3. DONE: `state`/`choose`/`cancel`. Measured on the way (docs/traps.md):
   a row is a Cell whose identifier splits the extension with a comma;
   kaya's picker at depth offers no Cancel and the `Other` labelled
   Cancel under More opens a MENU that takes the whole picker out of
   the snapshot, so cancel walks back to a Cancel as simdrive did and
   "gone" is three consecutive absent reads.
4. DONE: `clip_press` → the driver's `press Allow Paste` on SpringBoard;
   `clip_seed`/`clip_read`/`types` → `pb_write`/`pb_read`/`pb_types`;
   the holder processes, release files and census retired — the
   driver is the held writer; check-steps' clause now holds the
   driver's discipline (seed through the driver, census gates the
   verdict, quit before kill, no group kill, the stage marker).
5. DONE: tools/ios/simdrive (gone) and tools/ios/clipctl (gone)
   deleted with their build steps; swift-typecheck compiles the driver
   against the platform's XCTest instead; the docs swept.
6. DONE, the robustness pass the maintainer asked for the same evening:
   a device reseed restarts its driver — EXERCISED by fault injection,
   `KAYA_IOS_RESEED_TEST=<udid> tools/ios/run-sim.sh swift` puts a
   healthy phone through erase, boot, driver restart (ready in 9s), warm
   and probe (admission 56s with the erase inside it), and the suite
   passed with every driver alive at the verdict; the `type` verb's iOS
   keys come from the driver (above); and the driver's pan scrolls
   kaya's ScrollView inside the scroll's frame, which turned up the
   content-width viewport (the ledger WATCH). NEXT: the drag arm
   (docs/dnd-plan.md §5) uses `drag` on the one driver.
