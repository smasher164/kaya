# App identity (icon + name) on macOS, for an UNBUNDLED process

Arm of the chrome/identity design brief. Evidence tiers: **[DOC]** vendor
documentation (URL or the SDK header on this host), **[MEASURED]** run on
this host by this session's probe (command + output shown), **[REPO]**
read from this tree, **[INFER]** flagged inference needing confirmation.

## 0. Host and toolchain every measurement below is pinned to

| thing | value | how read |
|---|---|---|
| host OS | macOS **26.5.2** (build **25F84**) | `sw_vers` **[MEASURED]** |
| kernel/arch | Darwin 25.5.0, arm64 (T6050) | `uname -a` **[MEASURED]** |
| Swift toolchain | Xcode **26.6.0**, swift-driver 1.148.6, Apple Swift **6.3.3**, default target `arm64-apple-macosx26.0` | `xcrun swiftc --version` **[MEASURED]** |
| SDK the probe dylib compiles against | `MacOSX26.5.sdk`; dylib records `sdk 26.0 / minos 26.0` | `otool -l` **[MEASURED]** |
| SDK the probe MAIN records | `sdk 14.4 / minos 14.0` (nix `apple-sdk-14.4`) — byte-for-byte what every kaya guest binary is | `otool -l` **[MEASURED]** |
| display / Dock | 1728x1117 pt, Dock at the bottom, `tilesize` 62, `autohide` 0 | `defaults read com.apple.dock`, CGWindowList **[MEASURED]** |

**The probe** lives at
`/private/tmp/claude-501/-Users-akhilindurti-Projects-kaya/24aa5ebf-e439-4206-9ba0-de67540e4b06/scratchpad/chrome/identitymac/ (gone)`
(`Identity.swift` -> `libidentity.dylib`, `main.c` -> `probe-main-sdk14`,
`reader.swift` -> `reader`, `cmdtab.swift` -> `cmdtab`, `build.sh`,
`run*.sh`, `mkpng.py`). It imports **no repo code** and reproduces kaya's
mechanism exactly: a C main `dlopen`s the Swift dylib and calls
`@_cdecl("probe_run")` on the process main thread, which runs a
`struct IdentityApp: App` whose `@NSApplicationDelegateAdaptor` sets the
activation policy in `applicationWillFinishLaunching` — the shape of
`swift/KayaSwiftUIEntry.swift`. The icons are two 512x512 PNGs written by
`mkpng.py` (solid magenta with a white cross; solid green with a black
cross) so a Dock tile carrying one is unmistakable in a screenshot.
`reader` is a **separate process**, so cross-process reads are real ones.

---

## 1. kaya's mac guests really are unbundled [REPO]

- `swift/KayaSwiftUIEntry.swift` has **no `@main` and no bundle**: the
  guest process (Go/Rust/Python/…) `dlopen`s the interpreter and calls
  `@_cdecl("kaya_swiftui_run")`, which calls `KayaApp.main()` on the
  caller's main thread.
- `tools/validate-mac.py` launches guests as **bare executables** staged
  into `target/rust-guests/`. Its own comment (lines 74-102) proves it
  knows they are unbundled: *"Launching a bare (unbundled) executable on
  macOS registers it with LaunchServices, and `_LSApplicationCheckIn`
  reads the executable's CONTAINING DIRECTORY as if it were a bundle:
  `_CFBundleReadDirectory` enumerates every sibling"* — the 7.7s-per-leg
  bug. **No `.app` is constructed anywhere on the mac lane.**
- `.app` bundles exist in this tree ONLY for one-off probes
  (`tools/mac/clipprobe/build.sh`, `tools/mac/undoprobe/build*.sh`,
  `tools/ios/*/build.sh`) — never for a guest, never for a lane leg.
- Activation policy today (`swift/KayaSwiftUIEntry.swift:39-67`):
  `.regular` under `KAYA_ACTIVATE=1` (pixel proofs only), `.accessory`
  under `KAYA_SELFTEST` (every lane leg), and the file records that an
  unbundled binary setting **neither** lands on `.prohibited`.
- What earlier probes in this same directory already found:
  `toolbar-mac.md` §Q3 — bundling is NOT what selects the macOS 26
  design; the *main executable's* linked SDK is, and kaya's is 14.4.
  `film-mac.md` — guests run `.accessory` and never `activate()`.
  `CLAUDE.md` invariant 3 / `check-diagnostics.py` — `.accessory` means
  `NSApp.isActive` is **always false**, the `kayaOpenPanelWhyNot` bug.

## 2. What an unbundled process IS, measured

Identical in every unbundled arm:

```
PROBE: preNSApp bundlePath=/…/scratchpad/chrome/identitymac (gone)   <- the DIRECTORY
PROBE: preNSApp id=nil
PROBE: preNSApp infoDictionary keys=[]                        <- EMPTY, not partial
PROBE: preNSApp processName=probe-main-sdk14 arg0=/…/probe-main-sdk14
```

`Bundle.main` is not absent — it is a **directory bundle with an empty
info dictionary**: `bundleIdentifier` nil, `infoDictionary` present with
**zero keys**. **[MEASURED]** That is the whole identity macOS has, which
is why every surface below falls back to the executable's file name.

The bundled control (§6) prints, for contrast:

```
PROBE: preNSApp bundlePath=/…/Aurora.app id=dev.kaya.identityprobe
PROBE: preNSApp infoDictionary keys=[CFBundleExecutable,CFBundleIconFile,
       CFBundleIdentifier,CFBundleName,CFBundleNumericVersion,
       CFBundlePackageType,CFBundleShortVersionString,CFBundleVersion]
```

---

## 3. Q1 — the DOCK and CMD-TAB icon, at runtime, unbundled

### 3a. Under `.accessory` there is no tile to change **[MEASURED]**

Arm `A1b`: `PROBE_POLICY=accessory PROBE_ICON=icon-magenta.png`.

```
PROBE: willFinishLaunching: requested=accessory actual=1
PROBE: ICON after set: size=512x512 … tiff=ae8b2a30c049051e/8393446B
dock shot rc=0 rect=0,1010,1728,107 -> shot-A1b-accessory-icon-dock.png
```

`shot-A1b-accessory-icon-dock.png` is **the same 13-tile Dock as the
pre-probe baseline** (`baseline-dockstrip.png`) — Finder, Messages,
Notes, Settings, Discord, Firefox, VS Code, Terminal, Spotify, UTM,
Docker, Preview, Downloads, Trash — **no magenta tile anywhere**. The
setter returned without error and the readback shows a 512x512 image
installed. The Dock shows nothing, because an accessory app has no tile.

**[DOC — SDK header on this host,**
`MacOSX26.5.sdk/…/AppKit.framework/Headers/NSRunningApplication.h`**]**:

```
/* The application does not appear in the Dock and does not have a menu bar,
   but it may be activated programmatically or by clicking on one of its
   windows.  This corresponds to LSUIElement=1 in the Info.plist. */
NSApplicationActivationPolicyAccessory,

/* The application does not appear in the Dock and may not create windows or
   be activated.  This corresponds to LSBackgroundOnly=1 in the Info.plist.
   This is also the default for unbundled executables that do not have
   Info.plists. */
NSApplicationActivationPolicyProhibited
```

(Also https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy
and https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement.)

> ### THE BEHAVIOUR CHANGE THE BRIEF MUST NAME
> An unbundled kaya guest today is `.accessory` on every lane leg, and
> `.prohibited` if nobody sets a policy at all. **A Dock icon requires
> `.regular`.** So "declare an app identity" is not a pure add — on
> macOS it forces an activation-policy decision, and the reason kaya
> chose `.accessory` is still true: `KayaSwiftUIEntry.swift:46-48` says
> a suite's windows must not steal the human's keyboard, and going
> `.regular` puts a tile in the Dock and an entry in Cmd-Tab for **every
> leg of every mac run**. Lane legs and shipping apps cannot share one
> answer here; this is a carve-out-shaped decision and belongs to Akhil.

### 3b. Under `.regular`, unbundled, the tile exists and is generic **[MEASURED]**

Arm `A2` (`PROBE_POLICY=regular`, no icon): a **14th tile appears — the
black generic `exec` icon** (`shot-A2-regular-noicon-dock.png`).

### 3c. `applicationIconImage` DOES change that tile **[MEASURED]**

Arm `A3` (`PROBE_POLICY=regular PROBE_ICON=icon-magenta.png`):
`shot-A3-regular-icon-dock.png` — the 14th tile is **the magenta square
with the white cross**, the probe's PNG. Same Dock, same position, only
that tile changed. The setter took a plain `NSImage(data: pngData)`; no
`.icns`, no representation set, no `setName:`.

**[DOC]** `NSApplication.h` (MacOSX26.5.sdk):
`@property (null_resettable, strong) NSImage *applicationIconImage;` —
`null_resettable` is the documented "assign nil to go back to the
bundle's icon" spelling.

### 3d. The Cmd-Tab switcher DOES follow it **[MEASURED]**

Arm `B1` drove a real Cmd-Tab with synthetic CGEvents (`cmdtab`,
`AXIsProcessTrusted=true`) and screenshotted the switcher while Command
was held. `shot-B1-switcher-magenta.png`: the **first switcher tile is
the magenta cross**. So the switcher reads the same runtime icon.

### 3e. It survives, and it is re-settable live **[MEASURED]**

`B1` installed the magenta icon at launch and the **green** one at
+9000 ms. `shot-B1-dock-green.png` shows the tile is now the green cross;
`shot-B1-switcher-green.png` shows the switcher tile green too. Nothing
reverted it: the poller read the same installed image at +3 s and +6 s in
every arm (`POLL@3000ms … iconTiff=ae8b2a30c049051e`,
`POLL@6000ms … iconTiff=ae8b2a30c049051e`).

### 3f. The runtime image is NOT masked **[MEASURED]**

Every runtime-set tile is a **hard-edged square** — no squircle, no
rounding, no shadow — sitting next to thirteen rounded system icons. The
bundled control (§6) with the same art in an `.icns` **is** rounded.
So a runtime blob is responsible for its own icon *shape*.
**[INFER on the mechanism: LaunchServices renders a bundle icon through
the system app-icon shape while AppKit hands `applicationIconImage`
straight to the Dock — plausible and consistent with both screenshots,
not proven here.]**

---

## 4. Q2 — what ONLY an `.app` bundle can do

### 4a. The icon before launch — MEASURED, not just documented

`reader fileicon` calls `NSWorkspace.shared.icon(forFile:)`, which is
the Finder/Spotlight/Launchpad/Open-panel icon, read from a **separate
process with nothing running**:

```
$ ./reader fileicon …/Aurora.app                 # bundle, CFBundleIconFile=AppIcon
FILEICON tiff=f7305c7a5b452e0d/73949448B
FILEICON px(64,64) rgb=241,89,249 a=1.00         <- MAGENTA: the .icns
FILEICON px(20,20) rgb=0,0,0 a=0.00              <- masked corner

$ ./reader fileicon …/probe-main-sdk14           # bare executable
FILEICON tiff=1895a135da461833/73949448B
FILEICON px(64,64) rgb=59,59,60  a=1.00          <- the generic exec icon
```

**[MEASURED]** A runtime blob cannot touch this at all: it is read off
disk when the process is not running. This is the single hardest line
between "runtime identity" and "bundle identity".

### 4b. The bundle-only list [DOC]

| capability | key / mechanism | why runtime cannot |
|---|---|---|
| icon in Finder, Spotlight, Launchpad, the Dock **before launch**, and the Dock's persistent (kept-in-Dock) tile | `CFBundleIconFile` (String, macOS 10.0+, "The file containing the bundle's icon") / `CFBundleIconName` (macOS 10.13+, "The name of the asset that represents the app icon") | read from disk with no process running — **[MEASURED 4a]** |
| a bundle identifier | `CFBundleIdentifier` | measured nil for every unbundled arm; `NSRunningApplication.bundleIdentifier` = nil |
| user-defaults domain, Keychain ACLs, TCC (privacy) grants, Notification Center registration, App Groups, `NSUserActivity`/Handoff | all keyed on the bundle identifier | no identifier exists |
| window restoration identity (`NSQuitAlwaysKeepsWindows`, saved-state directory) | keyed on bundle id | ditto |
| "default app" for a file type / URL scheme | `CFBundleDocumentTypes`, `UTExportedTypeDeclarations`, `CFBundleURLTypes` — LaunchServices scans **bundles** | LS has no bundle to scan |
| declaring the activation policy without code | `LSUIElement` / `LSBackgroundOnly`; a bundle with neither defaults to **regular** — **[MEASURED §6]** | unbundled default is **prohibited** (SDK header, §3a) |
| code signing / notarization / hardened runtime / Gatekeeper, and therefore distribution | signature over the bundle | — |
| a Dock tile that persists after quit, or a Dock-tile plug-in | `NSDockTilePlugIn` key in Info.plist (`NSDockTile.h`) | needs an Info.plist |
| the design-generation opt-out (`UIDesignRequiresCompatibility`) | Info.plist | (and see `toolbar-mac.md` §Q3 — the *main executable's* SDK is what actually selects the generation, so this one is not a bundle win for kaya anyway) |

Doc URLs:
https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleiconfile ,
https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleiconname ,
https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundlename ,
https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement .

---

## 5. Q3 — where the NAME lands, and what can move it

Baseline, unbundled, nothing injected: **every** name surface reads the
executable's file name, `probe-main-sdk14`. **[MEASURED]**

```
PROBE: MENU appMenuTitle=probe-main-sdk14 topLevel=[probe-main-sdk14|File|Edit|View|Window|Help]
PROBE: MENU appMenuItems=[About probe-main-sdk14||Services||Hide probe-main-sdk14|…|Quit probe-main-sdk14]
RA localizedName=probe-main-sdk14
AX tile subrole=AXApplicationDockItem title=probe-main-sdk14   (the Dock's own AX tree)
```
plus, in the screenshots: the menu-bar app title, the **window title bar**
(SwiftUI's untitled `WindowGroup` falls back to the app name), and the
**Cmd-Tab switcher label**.

**[REPO]** kaya does not set any of this today. `swift/KayaSwiftUI.swift`
builds only its own **segment** of `NSApp.mainMenu`
(`kayaSyncMacMenuBar`, ~11536): it inserts kaya's catalog menus after the
Edit dress and relocates a `settings`-role item into the application
menu. It never touches `mainMenu.items.first` (the app menu holder) and
never sets a process name. Grep confirms no `CFBundle*` and no
`processName` write anywhere in `swift/`.

### The four routes, measured

| route | when applied | NSMenuItem title (API read) | **RENDERED menu bar** | window title | `NSRunningApplication.localizedName` (cross-process) | Cmd-Tab label / Dock AX title |
|---|---|---|---|---|---|---|
| **A** mutate `Bundle.main`'s info dictionary, `CFBundleName` | **before** `NSApplication.shared` exists | `Aurora Notes` | **`Aurora Notes`** | **`Aurora Notes`** | `probe-main-sdk14` | `probe-main-sdk14` |
| same, applied **after** launch | in `didFinishLaunching` | `probe-main-sdk14` | `probe-main-sdk14` | — | `probe-main-sdk14` | — |
| **B** `ProcessInfo.processInfo.processName = …` | before `NSApp` exists | `AuroraTwo` | **`probe-main-sdk14`** ← LIES | — | `probe-main-sdk14` | — |
| **C** write `NSApp.mainMenu.items.first.title` | after launch | `AuroraThree` | **`AuroraThree`** | — | — | — |
| **D** private `_LSSetApplicationInformationItem(_kLSDisplayNameKey)` | after LS check-in | `probe-main-sdk14` | **`AuroraFive`** | — | **`AuroraFive`** | `probe-main-sdk14` |
| same, applied **before** check-in | in `probe_run` | — | — | — | — | `rc=-600` (procNotFound) — **fails** |

Screenshots: `shot-C1-inject-menubar.png` (**"AuroraOne"**),
`shot-C2c-procname-only-menubar-8s.png` (**"probe-main-sdk14"** while the
API said `AuroraTwo`), `shot-C2b-…-menubar-8s.png` (**"AuroraThree"**),
`shot-C3b-lsname-late-menubar-8s.png` (**"AuroraFive"**),
`shot-D1-inject-only-switcher.png` (menu bar + window title both
**"Aurora Notes"**, switcher label still **"probe-main-sdk14"**).

### 5a. Is `CFBundleName` injectable at runtime? YES — measured

```
PROBE: INJECT: infoDictionary class=__NSDictionaryM respondsToSetObjectForKey=true
PROBE: INJECT: after mutation objectForInfoDictionaryKey(CFBundleName)=Optional(Aurora Notes)
PROBE: MENU appMenuTitle=Aurora Notes topLevel=[Aurora Notes|File|Edit|View|Window|Help]
```

The info dictionary CoreFoundation synthesizes for an unbundled main
bundle is a genuine **`__NSDictionaryM`** and answers
`setObject:forKey:`. Reached in Swift via
`(Bundle.main as AnyObject).perform(NSSelectorFromString("infoDictionary"))`
— **not** `Bundle.main.infoDictionary`, which bridges to a Swift
`Dictionary` **copy** and silently loses the mutation. Setting
`CFBundleName` and `CFBundleDisplayName` there, *before the first touch
of `NSApplication.shared`*, gives the menu bar and the window title the
declared name. **[MEASURED on macOS 26.5.2]**

**How load-bearing / how unsupported.** This is squarely undocumented
behaviour, and it should be treated as such:
* `-[NSBundle infoDictionary]` is documented as returning
  `NSDictionary`. Nothing promises the returned object is mutable, that
  it is the bundle's live backing store rather than a copy, or that
  AppKit re-reads it. All three happen to hold here.
* The **ordering constraint is the fragile part**: it must run before
  AppKit builds the main menu. Injecting in `didFinishLaunching` changed
  nothing (`C1b`: menu still `probe-main-sdk14`). In kaya that means
  before `KayaApp.main()` inside `kaya_swiftui_run` — i.e. before the
  wire is even open, so **an identity that arrives over the blob channel
  during the build closure is already too late for this route.**
* Its blast radius is the whole info dictionary — the same dictionary
  that would carry `LSUIElement`, `CFBundleIdentifier`, `CFBundleVersion`
  if they existed.
* It does **not** move the cross-process name (`localizedName` stayed
  `probe-main-sdk14`), so it is a *cosmetic, in-process* name.

**Route C (`NSApp.mainMenu.items.first.title = …`) is the supported
alternative** and it has no ordering constraint: it renders correctly
when applied 1.5 s after launch (`C2b`). It reaches only the menu-bar
title, not the About/Hide/Quit item texts, not the window title. kaya
already owns a `NSApp.mainMenu` mutation path
(`kayaSyncMacMenuBar`), so this is the route that fits the existing
machinery — and it is the one that works with a name that arrives late.

### 5b. `ProcessInfo.processName` is a trap — DO NOT USE IT

`processName = "AuroraTwo"` made `NSApp.mainMenu.items.first.title` read
`AuroraTwo` (confirmed at +3 s and +6 s), while the **screen** kept
saying `probe-main-sdk14` — captured twice, at 4 s and 8 s. An in-process
assertion on the menu title would have gone green on a menu bar that
never changed. **[MEASURED — `shot-C2-procname-menubar.png`,
`shot-C2c-procname-only-menubar-{4s,8s}.png`]**

**[DOC]** Apple's own warning:
*"User defaults and other aspects of the environment might depend on the
process name, so be very careful if you change it. Setting the process
name in this manner is not thread safe."*
https://developer.apple.com/documentation/foundation/processinfo/processname

### 5c. The switcher label is not reachable at all

Neither route moved the Cmd-Tab label or the Dock's AX tile title, even
when `localizedName` itself had changed to `Aurora Notes` via the private
LS call (`D3`: `RA localizedName=Aurora Notes`, switcher still
`probe-main-sdk14`). **[MEASURED]** **[INFER: the Dock caches the tile's
name at LaunchServices check-in and does not refresh it; the pre-check-in
LS call that could set it fails with -600. Not proven.]**

---

## 6. The bundled control, for comparison **[MEASURED]**

A real `Aurora.app` wrapping **the same `probe-main-sdk14` binary**, with
`CFBundleName=Aurora Notes`, `CFBundleIconFile=AppIcon`,
`CFBundleIdentifier=dev.kaya.identityprobe`, launched with
`PROBE_POLICY=none` (**no `setActivationPolicy` call at all**):

```
PROBE: willFinishLaunching: requested=none actual=0        <- REGULAR for free
PROBE: MENU appMenuTitle=Aurora Notes topLevel=[Aurora Notes|File|Edit|View|Window|Help]
RA localizedName=Aurora Notes                              <- cross-process, for free
RA bundleIdentifier=dev.kaya.identityprobe
AX tile subrole=AXApplicationDockItem title=Aurora         <- the .app FILE name
```

and `shot-F1-bundle-dock.png` shows the magenta tile **rounded** with the
system app-icon shape. The bundle buys, with no code: the pre-launch
icon, `.regular` by default, a bundle identifier, the cross-process name,
and the system icon mask. It does not buy the Dock AX / switcher label
from `CFBundleName` — that follows the `.app`'s **file name**
(`Aurora.app` -> `Aurora`), which is the real reason shipped apps name
the bundle after the product.

---

## 7. Q4 — what the harness could HONESTLY read back on mac

The repo's rule (CLAUDE.md invariant 3, `check-verbs.py`'s
stamped-observation clause, `docs/traps.md`): a verdict must be a
measurement, not an echo. Graded honestly:

### A REAL read, with a named limit — `NSApp.applicationIconImage`

It is **not** an echo of the object handed in:

```
PROBE: ICON constructed:  … obj=96582 reps=[NSBitmapImageRep(512x512)]   tiff=a83579c0f985c2d9/789838B
PROBE: ICON after set:    … obj=95145 reps=[NSCGImageSnapshotRep(1024x1024)] tiff=ae8b2a30c049051e/8393446B
PROBE: ICON identity: readback === requested -> false
```

AppKit stores a re-rendered 1024x1024 snapshot; the readback is that,
not the input. And it is **content-sensitive and deterministic**:

```
$ grep -h "ICON after set:" log-*.txt | grep -o "tiff=[a-f0-9]*" | sort | uniq -c
  15 tiff=ae8b2a30c049051e          <- magenta, identical across 15 runs
$ grep -h "ICON2" …                  1 tiff=7539916d1b479d6d   <- green, different
```

So `sha256(NSApp.applicationIconImage.tiffRepresentation)` is a stable
per-input fingerprint that a harness could pin. **What it cannot tell
you is whether anything is on screen**: in arm `A1b` this exact readback
reported a 512x512 image installed, `tiff=ae8b2a30c049051e`, while the
Dock had **no tile at all**. Any verb that reports "icon applied" from
this read alone would have passed the accessory arm — and accessory is
every lane leg. **A read that cannot distinguish "stored" from "shown"
must say so, and this one cannot.**

### An ECHO — `NSApp.mainMenu.items.first.title` for the app-menu name

Measured lying: route B (§5b) made it read `AuroraTwo` while the rendered
bar said `probe-main-sdk14`. It is a faithful read of *the NSMenuItem*,
but the app-menu title is the one item whose rendered text is not
guaranteed to be that item's title. As a proof of "the app is named X"
it is an echo of what was written into a different place than the one
that draws. (For **route C** it happens to agree — but a check that is
right for one route and wrong for another is not a check.)

### NOT a read at all — `NSRunningApplication.current.icon`

Unchanged before and after every `applicationIconImage` assignment:
`tiff=816bf92dc3086c7f` in both, in every unbundled arm. It reports the
**LaunchServices** icon, so it would report the generic executable icon
forever no matter what the app installs. **[MEASURED]**

### Nothing reads the Dock tile's pixels

`NSDockTile` (`NSDockTile.h`, MacOSX26.5.sdk) exposes `size`,
`contentView`, `badgeLabel`, `owner`, `display` — **no image property**.
`NSApp.dockTile.contentView` is non-nil but is our own hosting view, not
the drawn tile. **[DOC + MEASURED]**

### The two honest reads available, and their costs

1. **The Dock's own accessibility tree** — a genuine cross-process read
   of the process that draws the tile:
   ```
   $ ./reader dock
   AX dock child role=AXList items=16
   AX tile subrole=AXApplicationDockItem title=Finder
   …
   AX tile subrole=AXApplicationDockItem title=probe-main-sdk14   <- the probe, present
   ```
   It proves **a tile exists** (which is exactly what the accessory arm
   lacked) and gives the Dock's **name** for it. It gives **no image**.
   It is also the only read here that would have caught the `A1b`
   false positive. Requires the harness to be accessibility-trusted.
2. **Screenshot the tile and check its pixels.** The only thing that
   proves the *image* arrived. Needs screen-recording permission, the
   Dock's geometry, and it is exactly the sort of pixel proof kaya
   already runs under `KAYA_ACTIVATE=1` — which is `.regular`, which is
   the only policy where a tile exists anyway. Convenient: a Dock-tile
   pixel check and the Dock tile existing have the same precondition.

**Recommended shape of a mac read-back verb**, if one is wanted: report
the fingerprint of the stored image AND the Dock's AX tile presence AND
the policy, as three separate observations, and let the verdict name
which of them it actually saw. A single boolean "icon applied" cannot be
honest here — the accessory arm proves it.

---

## 8. Verdict

**A runtime blob buys a real Dock tile and a real Cmd-Tab tile on macOS,
unbundled — but only for a `.regular` process, and it buys almost none
of the name.** `NSApplication.shared.applicationIconImage = NSImage(data:)`
is a supported, public, non-hacky API; it changes the Dock tile and the
Cmd-Tab switcher tile immediately, it can be re-set live, nothing reverts
it, and no `.icns` or bundle is involved. That is genuinely worth having,
and it is the same one-blob-per-platform shape the brief wants. The three
costs are real and must be stated: the process must be **`.regular`**,
which today it deliberately is not on any lane leg; the image is drawn
**unmasked**, so the blob carries its own shape; and the icon exists only
while the process runs — quit it and there is nothing.

**The name is where unbundled runs out.** The menu bar and window title
are reachable, by two different routes with different costs: the
**supported** one (`NSApp.mainMenu.items.first.title`) moves the menu-bar
title only, and fits kaya's existing `kayaSyncMacMenuBar` path; the
**undocumented** one (mutating `Bundle.main`'s `__NSDictionaryM` info
dictionary with `CFBundleName`) additionally gives About/Hide/Quit and
the window title, but must run before `KayaApp.main()` — i.e. before the
wire opens, which means an identity arriving over the blob channel cannot
use it without a launch-time side channel. `ProcessInfo.processName` must
not be used: it is measured to change what the API reports and not what
the screen shows. And the Cmd-Tab label, the Dock's tile name and the
cross-process `localizedName` were not reachable by any supported route.

**So: is the honest answer "mac needs a bundle for this to mean
anything"?** Partly, and the split is clean rather than a judgement call:

* For **the running app's icon** — no. A blob is enough, and it reaches
  both surfaces that matter while the app is up (Dock, Cmd-Tab), given
  `.regular`.
* For **the name** — a bundle is the only route to a *consistent* one.
  Unbundled, you can make the menu bar say "Aurora Notes" while the
  Cmd-Tab label under a magenta tile still says `kaya-go`. That
  half-renamed state is worse than not renaming, and it is what shipping
  the runtime route alone produces.
* For **identity when the app is not running** — Finder, Spotlight,
  Launchpad, "open with", the kept-in-Dock tile — a bundle is required,
  measured, with no runtime substitute (§4a).

The design consequence I would carry into the brief: keep ONE declared
identity in the protocol, lower it on mac to **icon-by-blob at runtime
(honest, cheap, real)** and **name-by-menu-title (supported, partial,
and labelled as partial)**, and record that full macOS identity — the
pre-launch icon, the switcher label, the bundle id — is a **packaging**
concern that a future `.app` wrapper resolves for all eight guests at
once, not a protocol one. The activation-policy question (`.accessory`
on lane legs vs `.regular` for a Dock tile) is the one item here that
needs Akhil before anything is built: it changes observable behaviour on
every mac leg, and a per-run split (legs stay accessory, shipped apps go
regular) means the identity lowering is **never exercised by the
matrix** unless a leg is deliberately made regular.

---

## 9. Artifacts, side effects, cleanup

**Evidence screenshots** (all in `chrome/identitymac/`):
`baseline-dockstrip.png`, `shot-A1b-accessory-icon-dock.png`,
`shot-A2-regular-noicon-dock.png`, `shot-A3-regular-icon-dock.png`,
`shot-B1-switcher-magenta.png`, `shot-B1-dock-green.png`,
`shot-B1-switcher-green.png`, `shot-C1-inject-menubar.png`,
`shot-C2-procname-menubar.png`,
`shot-C2b-procname-settitle-menubar-{4s,8s}.png`,
`shot-C2c-procname-only-menubar-{4s,8s}.png`,
`shot-C3b-lsname-late-menubar-{4s,8s}.png`,
`shot-D1-inject-only-switcher.png`, `shot-D2-switcherlabel-switcher.png`,
`shot-D3-inject-plus-ls-switcher.png`, `shot-F1-bundle-dock.png`.
Raw probe logs: `log-*.txt`.

**Side effects taken and undone.**
* Every probe run was killed and proven dead — `ps -Ao pid,etime,pcpu,command
  | grep -E 'probe-main-sdk14|cmdtab|Aurora'` returns nothing.
* `cmdtab` posts a real Command-key down/up pair. Checked after:
  `CGEventSource.flagsState(.combinedSessionState).rawValue = 0` — no
  stuck modifier.
* `Aurora.app` was registered with LaunchServices by being launched. It
  was unregistered (`lsregister -u`) and deleted.
* The Dock is back to its 12 `AXApplicationDockItem` baseline — `reader
  dock` finds no `probe`/`aurora` tile.
* **No file in the kaya repo was created, edited or deleted by this
  probe.** (The working tree does show modifications to `AGENTS.md`,
  `CLAUDE.md`, `guests/…` and an untracked `docs/app-identity-plan.md` —
  those are a CONCURRENT session's, visible in the screenshots above;
  none of them came from here.)

**Disk:** `chrome/identitymac/` is **30 MB**, essentially all evidence
PNGs (full-screen retina captures at ~2.5 MB each). The whole session
scratchpad is **130 MB**. No cargo/target scratch was created.
