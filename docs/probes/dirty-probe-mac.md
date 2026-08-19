# dirty-state probe — mac arm

Probe, not a design. Nothing here ships; docs/ untouched. Repo HEAD 1d2cf95,
macOS 26.5.2 (build 25F84), SDK macosx26.5 (CommandLineTools; no Xcode.app on
this machine), swiftc from /usr/bin.

Probe sources and logs: `dirtyprobe-mac/` beside this file (`probe.swift`,
`build.sh`, `imgdiff.swift`, `ax-regular.log`, `ax-accessory.log`,
`close.log`, `aux.log`). NOTE for whoever reads this next: the arms of this
milestone share one scratchpad, and the linux arm also uses a directory called
`dirtyprobe/` — the mac arm's is `dirtyprobe-mac/`.

## Verdict in one paragraph

macOS charges almost nothing for this. `NSWindow.isDocumentEdited = true` is a
single property write (measured 0.5-1.3 ms including the main-thread hop), it
survives SwiftUI re-renders and title writes, and it renders as the dot inside
the close button — 88 backing pixels, and NOTHING ELSE in the whole window
changes. SwiftUI itself offers no API for it (zero hits for "Edited" in the
SDK 26.5 module interface), so it must go through the NSWindow bridge kaya
already has for window size. The system attaches NO behavior to the flag: a
real Cmd+W on an edited window calls `windowShouldClose` once and closes, with
no sheet, no modal, no interception — confirmation is entirely app-side, so
kaya's existing `veto_close` + `close_requested` grammar is the whole story.
Observability is real and cheap: the AX close-button element publishes
`AXEdited` as an NSNumber tracking the property, readable in-process through
the client API the a11y verbs already use, WITHOUT the assistive-client
announcement, while the app is an inactive `.accessory` (which is what the mac
lane runs as), and synchronously — no settle needed.

## Status

- [x] static: where the SwiftUI interpreter bridges a window prop to NSWindow
- [x] static: what SwiftUI itself publishes (SDK interface grep)
- [x] static: what the AX headers name for "is it dirty"
- [x] runtime: isDocumentEdited -> chrome (dot, title, close behavior)
- [x] runtime: AX readback, incl. aux windows and .accessory policy
- [x] cleanup proof

## 1. Static findings (before any window opened)

### 1.1 The NSWindow bridge already exists, and where

kaya's macOS windows are SwiftUI `WindowGroup`-hosted. The interpreter reaches
the hosting `NSWindow` through a registry filled by an `NSViewRepresentable`
that hooks AppKit's attachment signal:

- `swift/KayaSwiftUI.swift:1916` — `var kayaNSWindows: [UInt64: NSWindow]`,
  the surface-id -> NSWindow registry (macOS only).
- `swift/KayaSwiftUI.swift:1938` — `private struct KayaWindowAccessor:
  NSViewRepresentable`, whose `AttachView.viewDidMoveToWindow` (`:1943`) fires
  `register(_:)` (`:1961`). Registration installs the close-veto delegate proxy
  and then calls `kayaApplyWindowSize(windowId)` (`:1979`).
- `swift/KayaSwiftUI.swift:2244` — `kayaApplyWindowSize(_:)`, the archetype of
  a window prop lowered THROUGH the bridge: it reads the model and calls
  `window.setContentSize(...)` on the real NSWindow.
- `swift/KayaSwiftUI.swift:3448` — `kayaTitleWindow(_:)`, and `:3436`
  `kayaAwaitWindow(_:timeoutMs:)`, the event-driven wait for materialization
  the harness verbs use.
- The apply arm for window props: `swift/KayaSwiftUI.swift:2294`
  (`case applySetWindowProp`), with `(wpropTitle, valueStr)` at `:2305`,
  `wpropWidth`/`wpropHeight` at `:2318`/`:2322` (both call
  `kayaApplyWindowSize`), `wpropVetoClose` at `:2326`.

Note the asymmetry a `dirty` prop inherits: **title does NOT go through the
bridge**. On macOS the title is applied declaratively, `.navigationTitle(...)`
at `swift/KayaSwiftUI.swift:8291`, `:8301`, `:8340`, `:8362`, `:8601` — the
model is the source and SwiftUI pushes it into the window. Only size (and the
close veto, via the delegate) touch NSWindow directly.

Second inherited trap, already solved once for size: a window prop can be set
while the surface is still hidden, so the value must be RE-APPLIED at
registration. That is exactly why `register()` ends with
`kayaApplyWindowSize(windowId)` (`:1976-1979`). Anything that lowers to an
NSWindow property needs the same second application, or a scene that sets the
prop before showing the window loses it.

### 1.2 SwiftUI publishes no document-edited API

Grepped the public module interface of the SDK being compiled against:

```
/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/
  SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface
```

(25517 lines, SDK version 26.5)

| pattern | hits |
|---|---|
| `Edited` (case-insensitive) | **0** |
| `dirty` | 0 |
| `navigationDocument` | 6 |
| `windowResizability` | 5 |
| `DocumentGroup` | 29 |
| `windowStyle` | 19 |

The negatives are meaningful because the positives prove the interface covers
scene/window modifiers. Same result on the nix SDK 14.4 interface. So: no
scene modifier, no view modifier, no environment key for "this window is
dirty" in SwiftUI on macOS 26.5. `DocumentGroup` gets the behavior for free
because it is backed by `NSDocument`, which sets `NSWindow.isDocumentEdited`
itself — not a route open to a `WindowGroup` app like kaya's.

**Therefore the mac arm must use the NSWindow bridge.** `NSWindow.h:434`:

```objc
@property (getter=isDocumentEdited) BOOL documentEdited;
```

### 1.3 What the AX layer names it

`AppKit/NSAccessibilityConstants.h:59` (SDK 26.5):

```objc
APPKIT_EXTERN NSAccessibilityAttributeName const NSAccessibilityEditedAttribute;  //(NSNumber *) - (boolValue) is it dirty?
```

and the server-side hook, `NSAccessibilityProtocols.h:377-378`:

```objc
// Invokes when clients request NSAccessibilityEditedAttribute
@property (getter = isAccessibilityEdited) BOOL accessibilityEdited API_AVAILABLE(macos(10.10));
```

So an AX attribute for exactly this concept exists in the headers. Whether the
SwiftUI-hosted window actually publishes it, and whether it tracks
`isDocumentEdited`, is measured below (section 2) — headers are not behavior.

### 1.4 How the harness would do the read

kaya's macOS accessibility read is IN-PROCESS but through the CLIENT API
(`AXUIElementCreateApplication(getpid())`), run inside
`DispatchQueue.main.sync`:

- `swift/KayaSwiftUI.swift:3034` `kayaAxRead(_:)` — awaits the window, then
  `DispatchQueue.main.sync { kayaAxReadOnMain(identifier) }`.
- `swift/KayaSwiftUI.swift:3064` `kayaAxReadOnMain(_:)` — announces
  `AXEnhancedUserInterface` + `AXManualAccessibility` once per process
  (the tree is lazy: docs/traps.md "macOS builds the accessibility tree
  lazily"), sets a 2s messaging timeout, then walks.
- `swift/KayaSwiftUI.swift:3126` `kayaAxHintRead(_:)` — same shape for AXHelp.
- The walk helper `kayaAxKids` (`:3001`) already merges `kAXWindowsAttribute`,
  so window elements are reachable from the application element.

Two live doc bugs worth flagging to the coordinator (not mine to fix here):
the comment above `expect_ax` at `swift/KayaSwiftUI.swift:4629-4637` still
says the AX read "runs on the harness thread ON PURPOSE", which the code at
`:3061` contradicts and docs/traps.md:1039 records as the deadlock that cost a
day. Same stale claim is not in `expect_ax_hint`.

## 2. What the platform charges (measured)

Probe shape, so the numbers are trustworthy: a real SwiftUI `App` with a
`WindowGroup` (plus a `WindowGroup(for: UInt64.self)` aux scene, mirroring
`swift/KayaSwiftUIEntry.swift:22-33`), reaching its NSWindow through a copy of
`KayaWindowAccessor` — the same `viewDidMoveToWindow` registration kaya uses.
A hand-made NSWindow + NSHostingView would not have answered whether SwiftUI
clobbers the flag. ONE MODE PER PROCESS (the undoprobe lesson: modes run back
to back in one process differ by launch order, not by the thing under test).

### 2.1 The write

```
PROBE set isDocumentEdited=true in 0.510ms      (ax-regular, .regular, key window)
PROBE set isDocumentEdited=true in 1.313ms      (ax-accessory, .accessory, not key)
```

That is the whole cost, including the `DispatchQueue.main.sync` hop from the
probe thread. No layout pass, no relaunch, no NSDocument.

### 2.2 The chrome: the dot, and only the dot

Two independent captures per state — an in-process `cacheDisplay` of the
window's frame view (no screen-recording permission involved) and the system's
own `screencapture -l<windowNumber>`. Diffed with a throwaway pixel-differ
(`dirtyprobe-mac/imgdiff.swift`) that reports the bounding box of every pixel
that moved:

| capture | differing pixels | bbox (backing px, 1800x900 image) |
|---|---|---|
| in-process frame render, `.regular` | 88 | x=27 y=27 w=10 h=10 |
| `screencapture -l`, `.regular` | 88 | x=27 y=27 w=10 h=10 |
| in-process frame render, `.accessory` | 88 | x=27 y=27 w=10 h=10 |
| `screencapture -l`, `.accessory` | 88 | x=27 y=27 w=10 h=10 |

10x10 backing pixels = 5x5 points, centred in the close button (AX reports the
close button at 16x16 points). Both capture routes agree exactly, which also
says the in-process render is a faithful stand-in for the composited chrome.

- ACTIVE window: a dark dot inside the red close button.
  (`out/diff-screen-a.png` clean vs `out/diff-screen-b.png` dirty)
- INACTIVE window under `.accessory` (the mac lane's policy): the traffic
  lights are gray, and the dot renders LIGHT gray inside the gray circle —
  still 88 pixels, still visible. (`out/diff-acc-screen-b.png`)

**The title does not change.** Measured directly:

```
PROBE after dirty: window.title="DirtyProbe" isDocumentEdited=true
PROBE F/dirty/after-title:   AXTitle = "DirtyProbe2"     (after an explicit rename)
```

No "— Edited" suffix, no asterisk, no bullet in the title string — macOS puts
the whole signal in the close button. So on mac a title-string read is NOT an
observability channel for dirty, and `expect_title`'s expected strings are
unaffected by a window going dirty (relevant to invariant 6: the shared
`.steps` files compare titles byte-for-byte).

Nothing else in the chrome moves: no proxy icon appears (the window has no
`representedURL`), the toolbar is untouched, the Dock tile is untouched.

### 2.3 The flag survives SwiftUI

```
PROBE after SwiftUI re-render (tick=1): isDocumentEdited=true
PROBE after title write: title="DirtyProbe2" isDocumentEdited=true
```

An `@Published` change that re-renders the hosted view does not reset it, and
neither does writing `window.title` (kaya pushes the title declaratively via
`.navigationTitle`, so that push is a SwiftUI write to the same window).

The one thing that WILL lose it is a new NSWindow: the flag lives on the
AppKit object, so an aux surface that is dismissed and re-opened comes back
clean. That is the same hazard `kayaApplyWindowSize` already handles by being
called from `register()` (`swift/KayaSwiftUI.swift:1976-1979`), and a `dirty`
prop needs the identical re-application — a scene that sets the prop before
the surface materializes otherwise loses it silently.

### 2.4 The close attempt: the system does nothing

`mode=close`, `.regular`, app activated, window key, `isDocumentEdited = true`,
then a real key equivalent dispatched through `NSApp.mainMenu`:

```
PROBE pre-close: key=true active=true edited=true
PROBE menu File > "Close" keyEquivalent=w mods=1048576 action=performClose: enabled=true
PROBE menu File > "Close All" keyEquivalent=w mods=1572864 action=closeAll: enabled=true
PROBE cmd-W handled=true calls=["windowShouldClose(edited=true) -> true", "windowWillClose"]
      visible=false sheet=none modal=none appWindows=[AppKitWindow:vis=false]
PROBE terminate: about to NSApp.terminate with an edited window
PROBE applicationShouldTerminate (edited windows: 1)
```

Read that carefully, because it is the answer to "does the system alter
anything on Cmd+W":

- The menu item is unchanged — still "Close", still `performClose:`, still
  enabled. AppKit does not retitle or disable it for an edited window.
- `windowShouldClose` is called EXACTLY ONCE, and the window closes when the
  delegate says yes. No save sheet, no "Do you want to save?" alert:
  `sheet=none modal=none`, and the window went `visible=false`.
- Quitting with an edited window prompts nothing either: the process
  terminated immediately (the 3-second watchdog line never printed).

The "Do you want to save the changes?" sheet everyone remembers belongs to
`NSDocument`, not to `NSWindow.isDocumentEdited`. So on mac the flag is a
DISPLAY signal with no behavior attached, and any confirmation is kaya's own —
which the existing `veto_close` prop plus the `close_requested` event
(`swift/KayaSwiftUI.swift:1993-2013`) already expresses. Nothing about `dirty`
needs to change that grammar, and `dirty` and `veto_close` are orthogonal:
either can be set without the other.

### 2.5 Per-window, including aux surfaces

`mode=aux` opened a second `WindowGroup` surface through the same
`openWindow(value:)` path kaya uses (`swift/KayaSwiftUI.swift:8631`) and set
dirty on the AUX one only:

```
PROBE aux num=96761 title="Aux1" edited=true primary edited=false
PROBE AX sees 2 windows
PROBE   AXwin[0] title="Aux1"    ident="SwiftUI.PresentedWindowContent<Swift.UInt64, Swift.Optional<main.ProbeAuxRoot>>-2-AppWindow-1" close.AXEdited=NSNumber(1) bool=true
PROBE   AXwin[1] title="Primary" ident="main.ProbeRoot-1-AppWindow-1"                                                                close.AXEdited=NSNumber(0) bool=false
```

Per-window, as expected, and the aux window's registration path works
identically.

## 3. Observability — how a harness leg reads it back

### 3.1 The attribute, quoted

`AppKit/NSAccessibilityConstants.h:59` declares
`NSAccessibilityEditedAttribute` — "(NSNumber *) - (boolValue) is it dirty?".
Its raw value, printed at runtime, is **`AXEdited`**:

```
PROBE window ... AXEditedRaw=AXEdited trusted=true
```

**It is NOT on the window element.** Measured, in every pass, in both
activation policies:

```
PROBE B/announced/clean:   AXEdited = <absent>
PROBE B/announced/clean:   AXDocumentEdited = <absent>
PROBE B/announced/clean:   AXModified = <absent>
PROBE B/announced/clean:   AXDocument = <absent>
PROBE B/announced/clean:   AXEdited settable=false err=-25205        (kAXErrorAttributeUnsupported)
```

The AXWindow's 29 attributes are:
`AXActivationPoint, AXCancelButton, AXChildren, AXChildrenInNavigationOrder,
AXCloseButton, AXDefaultButton, AXDocument, AXFocused, AXFrame, AXFullScreen,
AXFullScreenButton, AXGrowArea, AXIdentifier, AXMain, AXMinimizeButton,
AXMinimized, AXModal, AXParent, AXPosition, AXProxy, AXRole,
AXRoleDescription, AXSections, AXSize, AXSubrole, AXTitle, AXTitleUIElement,
AXToolbarButton, AXZoomButton` — no AXEdited. (`AXDocument` is listed but
reads nil: it is the represented URL, which a kaya window does not have.)

**It IS on the close button.** `AXUIElementCopyAttributeValue(window,
kAXCloseButtonAttribute)` returns the button element (subrole
`AXCloseButton`), whose 14 attributes include `AXEdited`:

```
close attrs=[AXEdited,AXEnabled,AXFocused,AXFrame,AXHelp,AXParent,AXPosition,
             AXRole,AXRoleDescription,AXSize,AXSubrole,AXTitle,
             AXTopLevelUIElement,AXWindow]
clean: close.AXEdited = NSNumber(0) bool=false
dirty: close.AXEdited = NSNumber(1) bool=true
close.frame = 422.0,314.0 16.0x16.0
```

That is the read a harness leg makes: window element -> `AXCloseButton` ->
`AXEdited` -> `boolValue`.

### 3.2 Four properties of that read that make it usable in the lane

1. **No announcement needed.** Pass A ran BEFORE setting
   `AXEnhancedUserInterface`/`AXManualAccessibility` and read the correct
   value. This is AppKit chrome, not the lazily-built SwiftUI subtree
   (docs/traps.md, "macOS builds the accessibility tree lazily"). It costs
   nothing that kaya announces once per process anyway.
2. **Works under `.accessory`, on a window that is neither key nor active** —
   exactly the mac lane's condition, since `KAYA_SELFTEST` sets `.accessory`
   (`swift/KayaSwiftUIEntry.swift:39-43`). Measured: `key=false active=false
   policy=1`, `close.AXEdited = NSNumber(1)`.
3. **Synchronous.** The pass labelled `C/dirty/immediate` read the AX value
   with no settle between the property write and the read, and already saw
   `NSNumber(1)`. No polling loop, no `settle`, no flake window.
4. **Read-only from the client side.** `AXUIElementIsAttributeSettable` says
   `settable=false` on the window and the attribute is unsupported there, so a
   test cannot fake the state through AX — the assertion can only pass because
   the backend really set it.

Thread discipline is the existing one and is NOT optional: same-process AX
reads run AppKit code inline on the calling thread, so the read goes inside
`DispatchQueue.main.sync` like `kayaAxRead` (`swift/KayaSwiftUI.swift:3061`)
after `kayaAwaitWindow`. The probe followed that shape and never hung across
four runs.

### 3.3 Which window? — the one wrinkle

kaya's harness names surfaces by id, but AX has no public window-id. Routes
measured:

- **By title** — what `expect_title` effectively already does through
  `kayaTitleWindow`. Works (the aux run found "Aux1" and "Primary"), but two
  windows with the same title are indistinguishable.
- **By AXIdentifier** — SwiftUI publishes one, but it is derived from the root
  view TYPE, not the kaya window id:
  `main.ProbeRoot-1-AppWindow-1` and
  `SwiftUI.PresentedWindowContent<Swift.UInt64, Swift.Optional<main.ProbeAuxRoot>>-2-AppWindow-1`.
  Every aux surface shares the same generic type, so this does not key a
  window either.
- **By frame** — ambiguous in practice: both probe windows reported the same
  AX frame (414,306 900x450) because SwiftUI stacked them exactly.

So the honest reading strategy has two layers, and kaya already has the
precedent for both:

1. `kayaNSWindows[wid]?.isDocumentEdited` — the REAL materialized property of
   the REAL window, indexed by surface id with no matching problem. This is
   exactly the rung `expect_title` sits on today: it reads `window.title` off
   the platform object and falls back to the model only where no window
   exists (`swift/KayaSwiftUI.swift:3958-3990`).
2. `AXEdited` off that window's close button, for the stronger claim that the
   CHROME published it. Reachable without the identity problem by walking
   `kAXWindows` and matching the AX frame/title against the NSWindow kaya
   already holds; simplest robust version is title-matching, same as today.

A verb doing (1) is uniform with the rest of the harness; a verb doing (1)+(2)
is what the a11y scene's standard would ask for. Either is cheap. Note that
(2) hangs off the close button: a window without one publishes no channel. I
tried to measure that by removing `.closable` from the style mask and the
button stayed present and still reported AXEdited (SwiftUI appears to
re-assert the mask), so treat it as untested rather than proven — kaya has no
prop that makes a window non-closable today.

## 4. Consequences for the design (not decisions — inputs)

- The mac arm CAN implement `dirty` and can assert it. No carve-out.
- It lowers through the NSWindow bridge, not through SwiftUI: a new
  `(wpropDirty, valueBool)` arm in `applySetWindowProp`
  (`swift/KayaSwiftUI.swift:2294`) writing `kayaNSWindows[wid]?
  .isDocumentEdited`, plus re-application from `register()` next to
  `kayaApplyWindowSize(windowId)` (`:1979`) so a prop set before
  materialization is not lost. iOS compiles the same arm to nothing (no
  titlebar) — the mobile arm's call.
- The observable is a dot in the close button and NOTHING else. Any scene
  wording like "the title shows unsaved" would be false on mac.
- The system attaches no behavior, so `dirty` must not be specified as
  implying close confirmation. `veto_close` remains the mechanism; `dirty` is
  presentation only. Uniformity note for the sweep: if another platform's
  dirty marker DOES alter close behavior, that divergence has to be stated
  in the carve-out, not absorbed.
- A new harness verb (say `expect_dirty <window> <true|false>`) has to land in
  BOTH interpreter backends or `tools/check-verbs.sh` fails — and it must fail
  loudly, not silently, when a backend lacks the feature: that is what
  `depth_stub("<scene>")` is for, cross-checked by `tools/check-stubs.sh` and
  `tools/check-steps.sh`.

## 5. Reproducing this

```
scratchpad/dirtyprobe-mac/build.sh ax-regular     # AX + captures, active window
scratchpad/dirtyprobe-mac/build.sh ax-accessory   # same, .accessory + inactive
scratchpad/dirtyprobe-mac/build.sh close          # Cmd+W on an edited window
scratchpad/dirtyprobe-mac/build.sh aux            # a second WindowGroup surface
```

Run each under `nix develop -c` and under the GUI lock. Two traps the probe
itself hit, worth knowing for any successor:

- **`Killed: 9` with an empty log.** Overwriting the executable inside an app
  bundle that has already been launched invalidates the cached ad-hoc
  signature and the next launch is SIGKILLed. build.sh now stamps a fresh
  bundle per run and re-signs; that is why undoprobe had build/build2/build3.
- **`sips --cropOffset` is ignored** on this macOS — `sips -c h w` crops
  CENTRED, so a "top-left crop" silently returns the middle of the image, and
  two crops that differ at the corner come out byte-identical. That nearly
  produced a false "the chrome does not change". `imgdiff.swift` (bounding box
  of differing pixels) replaced it and is the reason the 88-pixel claim is
  exact rather than an eyeball.

## 6. Cleanup

- **Processes**: every probe run terminated itself (`NSApp.terminate` at the
  end of each mode). Verified after the last run:
  `ps -Ao pid,etime,pcpu,command | grep -i DirtyProbe` -> NONE, and the list of
  GUI applications with windows (System Events) contains no probe.
- **Windows**: none left open; the `close` run closed its window as part of
  the measurement, the others closed at terminate.
- **GUI lock**: `scratchpad/leg.lock` released on every path (checked absent).
- **Repo**: untouched. `git status --porcelain` shows only
  `M tools/guest/record-win/Program.cs`, which is ANOTHER arm's edit — this arm
  wrote nothing inside /Users/akhilindurti/Projects/kaya, and no commits.
- **Disk**: probe directory was 2.2 MB (three app bundles, four Swift
  binaries, 14 full-size PNG captures). Deleted; **final size of
  `scratchpad/dirtyprobe-mac/` is 80 KB** — sources, four logs, and 16 KB of
  evidence crops under `evidence/` (`diff-screen-{a,b}.png` active window,
  `diff-acc-screen-{a,b}.png` inactive/.accessory). Session scratchpad total
  107 MB (105 MB before this arm started; the difference is mostly the other
  arms running concurrently). Volume free: 490 GB of 927 GB.
