# Toolbar / chrome research — macOS (SwiftUI interpreter)

Platform owner: macOS arm64, the one Apple backend
(`swift/KayaSwiftUI.swift` + `swift/KayaSwiftUIEntry.swift`).
Evidence tiers as in docs/chrome-plan.md: **[DOC]** = vendor
documentation (URL + API + version), **[MEASURED]** = run on this host
by this session's probe, **[INFER]** = flagged inference.

## 0. Versions every answer below is pinned to

| thing | version | how read |
|---|---|---|
| host OS | macOS **26.5.2** (build 25F84), Darwin 25.5.0, arm64 (T6050) | `sw_vers`, `uname -a` **[MEASURED]** |
| Swift toolchain | Xcode **26.6.0**, `swift-driver 1.148.6`, Apple Swift **6.3.3**, default target `arm64-apple-macosx26.0` | `DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/... xcrun swiftc --version` **[MEASURED]** |
| macOS SDK the interpreter compiles against | **MacOSX26.5.sdk** (`--show-sdk-version` = 26.5) — `tools/lib/swift-toolchain.sh` prefers a full `/Applications/Xcode*.app` and this host has exactly one | **[MEASURED]** |
| SDK the built interpreter dylib records | `LC_BUILD_VERSION … sdk 26.0 / minos 26.0` on `target/swiftui/libkaya_swiftui.dylib` | `otool -l` **[MEASURED]** |
| SDK the GUEST (main executable) records | `sdk 14.4 / minos 14.0` on `target/go-guests/kaya-go` **and** on `target/debug/examples/a11y` — the nix dev shell's `apple-sdk-14.4` | `otool -l` **[MEASURED]** |

That last row is not trivia; see §Q3/Liquid Glass — on macOS the
"linked-on-or-after" appearance switches are read off the **main
executable**, and kaya's main executable is never the Swift dylib.

## 1. How a kaya macOS window is actually created (read before answering)

- `swift/KayaSwiftUIEntry.swift`: `@_cdecl("kaya_swiftui_run")` sets
  `KayaHost.api`, checks the spec hash, then calls `KayaApp.main()` on
  the caller's main thread. There is no app bundle and no `@main`: the
  guest process (Go/Rust/Python/…) `dlopen`s the interpreter and hands
  over its main thread. **[MEASURED: source]**
- `struct KayaApp: App` declares **two** `WindowGroup`s: an untitled
  `WindowGroup { KayaRoot() }` (surface id 0, the primary) and
  `WindowGroup(for: UInt64.self) { KayaAuxRoot(windowId:) }` for aux
  surfaces opened by `openWindow(value:)`. **No `.windowStyle`, no
  `.windowToolbarStyle`, no `.containerBackground`, no
  `.windowResizability` is applied to either scene** — grep for
  `windowToolbarStyle|windowStyle` in `swift/` returns nothing.
  **[MEASURED: source]**
- The AppKit `NSWindow` is reached, never created: `KayaWindowAccessor`
  (an `NSViewRepresentable` whose `AttachView` overrides
  `viewDidMoveToWindow`) registers `view.window` into `kayaNSWindows`
  and swaps in a delegate proxy. Every AppKit-side property kaya sets
  today (`setContentSize`, `isDocumentEdited`) is written through that
  registry. So an `NSWindow`-level toolbar knob has an existing,
  already-load-tested route. **[MEASURED: source]**
- Activation policy: `.accessory` under `KAYA_SELFTEST` (lanes),
  `.regular` only under `KAYA_ACTIVATE=1` (pixel proofs); an unbundled
  binary with neither is `.prohibited`. **[MEASURED: source comment +
  behaviour the file records]**
- Sections with `presentation = sidebar` already render
  `NavigationSplitView { List(...).listStyle(.sidebar) } detail: {...}`
  (`KayaSectionsView`, line ~12498). The stacked arm is
  `NavigationStack`; the list-detail arm is another
  `NavigationSplitView` (`KayaSplitRoot`). **[MEASURED: source]**
- `.toolbar` appears exactly once in the file today, inside
  `#if !os(macOS)` — `KayaMenuToolbar` puts promoted actions +
  a `More` menu in the iOS bar. macOS has **no** toolbar arm at all.
  **[MEASURED: source, line 11084 under the iOS `#if`]**

## 2. THE PROBE — what was built and what it measured

`/private/tmp/claude-501/-Users-akhilindurti-Projects-kaya/24aa5ebf-e439-4206-9ba0-de67540e4b06/scratchpad/chrome/probe-mac/ (gone)`
(`Probe.swift`, `main.c`, `build.sh`, `run.sh`). It imports **no** repo
code and reproduces kaya's window mechanism exactly:

* `Probe.swift` is compiled to **`libprobe.dylib`** by the full Xcode
  26.6 toolchain against **MacOSX26.5.sdk** — the same resolution
  `tools/lib/swift-toolchain.sh` performs — and exposes
  `@_cdecl("probe_run")` which calls `ProbeApp.main()`.
* `main.c` is compiled **twice**: `probe-main-sdk14` against the nix
  `apple-sdk-14.4` (`LC_BUILD_VERSION sdk 14.4`, byte-for-byte the
  situation of `target/go-guests/kaya-go`) and `probe-main-sdk26`
  against MacOSX26.5.sdk. Each `dlopen`s the dylib and calls
  `probe_run` on the process main thread — kaya's mechanism.
* `struct ProbeApp: App { WindowGroup { Root() } }`, untitled, with an
  `@NSApplicationDelegateAdaptor` setting `.regular` + `activate()`
  (kaya's `KAYA_ACTIVATE=1` shape, so the chrome renders active).
* The `NSWindow` is *reached*, not created — an `NSViewRepresentable`
  whose `AttachView` overrides `viewDidMoveToWindow`, i.e. kaya's
  `KayaWindowAccessor`.
* The window frame is pinned to **900x600** before every readback, so
  chrome height is comparable across arms.
* Arms: `none` (no `.toolbar` at all — kaya today), `toolbar`
  (`ToolbarItemGroup(placement: .primaryAction)` + N symbol `Button`s,
  **no style modifier anywhere**), `sidebar` / `sidebar-none`
  (`NavigationSplitView` + `List.listStyle(.sidebar)`, kaya's sectioned
  arm). `PROBE_SET_STYLE` additionally writes `window.toolbarStyle`
  after the fact.

### 2.1 The headline table — chrome height, 900x600 window, dark appearance

All rows: `probe-main-sdk14` (= a kaya guest), **no style vocabulary
used anywhere** unless the row says so. Chrome height =
`window.frame.height - window.contentLayoutRect.height`; the
`NSTitlebarView` frame is printed alongside and agrees to the pixel.

| arm | `window.toolbar` | `toolbarStyle` read back | CHROME HEIGHT | traffic-light y | shot |
|---|---|---|---|---|---|
| plain window, no `.toolbar` | **nil** | `automatic` (0) | **28.0** | 6 | `A1-sdk14-no-toolbar.png` |
| **`.toolbar` with 2 symbol items, nothing else** | NSToolbar, 2 items | **`automatic` (0)** | **52.0** | 18 | `A2-sdk14-toolbar-nostyle.png` |
| same + `window.toolbarStyle = .unified` | 2 items | `unified` (3) | **52.0** (unchanged) | 18 | — |
| same + `= .unifiedCompact` | 2 items | `unifiedCompact` (4) | 38.0 | 11 | — |
| same + `= .expanded` | 2 items | `expanded` (1) | 56.0 | 34 | — |
| same + `= .preference` | 2 items | `preference` (2) | 80.0 | 58 | — |
| `NavigationSplitView`, **no `.toolbar`** | **NSToolbar, 2 SwiftUI-injected items** | `automatic` (0) | **52.0** | 18 | `D1-sidebar-notoolbar.png` |
| `NavigationSplitView` + `.toolbar` 2 items | NSToolbar, 4 items | `automatic` (0) | **52.0** | 18 | `D2-sidebar-toolbar.png` |

**[MEASURED]** every cell. The two rows that decide the design question:

1. **Attaching a toolbar and setting NO style produces exactly the same
   52.0pt chrome as explicitly asking for `.unified`.** `.automatic`
   *resolves to* unified for a `WindowGroup`'s window shape.
   `windowToolbarStyle(.unified)` / `toolbarStyle = .unified` is a
   **measured no-op** on this window.
2. **A `NavigationSplitView` window already has a 52pt bar with no
   `.toolbar` modifier at all** — SwiftUI injects
   `com.apple.SwiftUI.navigationSplitView.toggleSidebar` and
   `com.apple.SwiftUI.splitViewSeparator-0` into a real NSToolbar. So
   *kaya's sectioned-sidebar windows and its `list_detail` windows are
   ALREADY in the tall unified geometry today*; only the plain stacked
   window sits at 28.

### 2.2 What the shots show

`A1` (no toolbar): thin band, **title centred**.
`A2` (toolbar, no style): tall band, **title moved to the leading edge**
beside the traffic lights, bold, with the two symbol buttons trailing —
the genre look, produced by nothing but the presence of the bar.
`D1`/`D2`: sidebar runs **full height** to the top of the window with
the traffic lights floating over it, the sidebar-toggle in the sidebar's
own top region, the window title at the leading edge of the *detail*
column's bar, promoted items trailing. That is the Mail/Notes/Xcode
shape, and `D1` reaches it with no `.toolbar` at all.

### 2.3 Overflow, enablement, labels — all measured

* **Overflow is automatic.** 14 promoted items in a 420pt-wide window:
  `toolbar.items = 14`, `toolbar.visibleItems = 3`, and the shot
  (`C3-items14-narrow.png`) shows the system's own `»` overflow chevron
  at the trailing edge. Nothing was configured. In a 900pt window the
  same 14 items give `visibleItems = 14`. **[MEASURED]**
* **`ToolbarItemGroup` + `ForEach` expands to N separate
  `NSToolbarItem`s** (14 buttons -> `items.count == 14`), so a promotion
  list can be a single dynamic group and still overflow per item.
  **[MEASURED]** (SwiftUI's `ForEach` would not resolve as
  `ToolbarContent` under Swift 6.3.3 — `cannot convert value of type
  '[Int]' to expected argument type 'Binding<C>'` — so the group is the
  spelling that compiles for a dynamic list.)
* **Item labels survive into AppKit.** `NSToolbarItem.label` reads back
  `"Save"`, `"Find"`, … — SwiftUI lifts the `Label(_:systemImage:)`
  title onto the real toolbar item. The SwiftUI-injected sidebar item's
  label is `"Hide Sidebar"`. **[MEASURED]** That is a real read for
  `expect_toolbar_item i "label"`.
* **Enablement propagates to the rendering, but NOT to
  `NSToolbarItem.isEnabled`.** With `.disabled(true)` on one promoted
  button, `NSToolbarItem.isEnabled` still reads `true` for every item —
  SwiftUI hosts the button in a `ToolbarItemHostingView` and never
  writes AppKit's flag. Rendering it out and measuring mean ink of each
  item's own pixels, with only the disable flag changed between two
  runs:

  | item | run A (index 1 disabled) | run B (nothing disabled) |
  |---|---|---|
  | Save | 0.2063 over 398 px | 0.2063 over 398 px |
  | **Find** | **0.1254 over 293 px** | **0.2114 over 316 px** |
  | New | 0.2443 over 154 px | 0.2443 over 154 px |
  | Delete | 0.2047 over 517 px | 0.2047 over 517 px |

  The three unchanged items are identical to four decimal places (the
  control); the disabled one dims by 41%. **[MEASURED]** Consequence for
  C2's observation: *`expect_toolbar_item_enabled` must not read
  `NSToolbarItem.isEnabled`* — it would report `true` for a visibly
  disabled button. The in-process `NSView` accessibility tree is also
  empty here (every descendant is `AXUnknown` with a nil label — SwiftUI
  publishes a synthetic element, not an `NSView`-backed one), so the
  read has to be the out-of-process AX route kaya's a11y verbs already
  use, or the pixels.

### 2.4 The scene-level modifier, with its negative control

The task asks specifically about `.windowToolbarStyle` on the hosting
configuration the interpreter uses. Two extra dylib flavours were built
from the same source (`-D SCENE_UNIFIED`, `-D SCENE_EXPANDED`) and run
through the same SDK-14 main:

| scene modifier on the `WindowGroup` | `toolbarStyle` read back | CHROME HEIGHT | traffic-light y |
|---|---|---|---|
| *(none — kaya today)* | `automatic` (0) | **52.0** | 18 |
| `.windowToolbarStyle(.unified)` | `unified` (3) | **52.0** | 18 |
| `.windowToolbarStyle(.expanded)` | `expanded` (1) | 56.0 | 34 |

**[MEASURED]** The `.expanded` row is the negative control and it is the
point of running it: the modifier demonstrably reaches the window (the
style reads back, the height and button positions move), so the
`.unified` row's "no change" is a real no-op and not a modifier that
silently failed to apply.

### 2.5 Title text — where it goes, and what hiding it costs

* With no toolbar: title **centred** in a 28pt band **[MEASURED, `A1`]**.
* With a toolbar, nothing set: title **inline at the leading edge**,
  bold, beside the traffic lights, in a 52pt band **[MEASURED, `A2`]**.
  That matches the SDK header: `NSWindowToolbarStyleUnified` — "The
  window title will appear inline with the toolbar when visible."
  **[DOC: MacOSX26.5.sdk `AppKit.framework/Headers/NSWindow.h`,
  `NSWindowToolbarStyle`, `API_AVAILABLE(macos(11.0))`]**
* `titleVisibility` stays `.visible` (raw 0) throughout — **the title
  text is never taken away by having a toolbar**.
* Setting `w.titleVisibility = .hidden` on the same window: chrome
  **52.0 -> 38.0**, traffic lights from y=18 to y=11 **[MEASURED, run
  `H1-title-hidden`]**. The header says why: `NSWindowTitleHidden`
  "hides the title and moves the toolbar up into the area previously
  occupied by the title" **[DOC, same header]**. So **C1b
  (`title_hidden`) is a GEOMETRY knob on macOS, not a cosmetic one** —
  it shrinks the tall bar back toward compact. Worth knowing before it
  is ever un-deferred.

### 2.6 Liquid Glass — kaya does NOT get it, and no toolbar knob can buy it

The host is macOS 26.5, and `NSGlassEffectView` resolves at runtime
**[MEASURED: `NSClassFromString("NSGlassEffectView") != nil`]** — the OS
has the new design. kaya's windows do not render in it.

Direct comparison on this host, same day, same dark appearance:
`F1-fontbook-liquidglass.png` is Font Book (`/System/Applications/Font
Book.app`, main executable `LC_BUILD_VERSION sdk 26.5` **[MEASURED:
otool]**). It shows the macOS 26 chrome: toolbar controls sitting in
**glass capsules**, **no hairline separator** under the bar, content
scrolling **under** the bar (the scroll-edge effect), title + subtitle
at the leading edge. The probe's shots (`A2`, `D2`, `E1`) show flat
glyphs with **no capsules**, a **hairline separator** under the bar, and
content that does not run under it — the compatibility rendering.

Cause, as far as this session established it:

* Apps compiled against the macOS 26 SDK adopt the new design
  automatically; `UIDesignRequiresCompatibility = YES` in Info.plist is
  the documented *opt-out* for apps that are so compiled **[DOC:
  https://www.donnywals.com/opting-your-app-out-of-the-liquid-glass-redesign-with-xcode-26/
  and https://developer.apple.com/forums/thread/799947 — Apple's own
  wording is that the key is ignored once you build against the 27
  SDKs]**. The switch is keyed on what the binary is *linked against*.
* kaya's SwiftUI dylib is `sdk 26.0`, but **the main executable — the
  guest — is `sdk 14.4`** (the nix `apple-sdk-14.4` in the dev shell):
  `target/go-guests/kaya-go` and `target/debug/examples/a11y` both
  **[MEASURED: otool]**. macOS's linked-on-or-after behaviour switches
  read the *program's* SDK, not a dylib's, so a 14.4 program stays on
  the old design however new the Swift dylib is. **[INFER — well
  supported, not proven here]**
* Bundling is **not** the cause: `E1-bundle-sdk14.png` (the same SDK-14
  main inside a real `.app` with an Info.plist and bundle id) is
  pixel-indistinguishable from the unbundled `A2` **[MEASURED]**.
* The complementary experiment did **not** complete: the SDK-26 main
  (`probe-main-sdk26`, bundled and unbundled, min 14.0 and min 26.0)
  **never presents a window at all** — `probe_run` is entered,
  `NSApplicationMain` runs its event loop, and `viewDidMoveToWindow`
  never fires (`sample` stack captured; log
  `log-B-probe-main-sdk26-*.txt`). Cause not established. **Flagged, not
  concluded** — and it is itself a warning for any future "just build
  the guests against a modern SDK" move.

**Design consequence:** the macOS 26 *material* is not something C1, C2
or any styling vocabulary can reach. It is a property of the toolchain
the guest binary is linked with. Adding a `chrome`/`toolbar_style` knob
would not move that pixel.

## 3. Answers

### Q1 — what the promotion list lowers to, and whether a tall variant exists

**Lowers to:** a real **`NSToolbar`** on the window SwiftUI already
created, reached through `.toolbar { ToolbarItemGroup(placement:
.primaryAction) { … } }` on the root view. Each promoted item becomes
one `NSToolbarItem` whose `.label` is the item's label and whose `view`
is a `ToolbarItemHostingView`. **[MEASURED]** kaya's registry
(`kayaNSWindows`) already holds that `NSWindow`, so the read-back side
needs no new machinery.

**Does a tall/extended variant exist?** Yes — `NSWindow.toolbarStyle`
(`macos(11.0)`) with `automatic | expanded | preference | unified |
unifiedCompact`, and SwiftUI's `Scene.windowToolbarStyle(_:)`
(`macOS 11.0`) with `AutomaticWindowToolbarStyle`,
`UnifiedWindowToolbarStyle(showsTitle:)`, `UnifiedCompactWindowToolbarStyle`,
`ExpandedWindowToolbarStyle` **[DOC: NSWindow.h in MacOSX26.5.sdk;
SwiftUI.swiftinterface, arm64e-apple-macos]**.

**Which category is the tall look?** **DEFAULT OF THE CONSTRUCT.**
`.automatic` is documented as "The default value. The style will be
determined by the window's given configuration" **[DOC]** and it
*resolves to the unified 52pt bar* for the window shape a
SwiftUI `WindowGroup` produces — identical geometry to asking for
`.unified` explicitly, verified against an `.expanded` control
**[MEASURED, §2.1/§2.4]**. It is not a window-level flag kaya must set:
`styleMask` never changes (32783 =
`titled|closable|miniaturizable|resizable|fullSizeContentView`) whether
the toolbar is present or not — note `fullSizeContentView` is **already
set by SwiftUI today** **[MEASURED]**, so half of C1's mac lowering is
in the tree already and unstated.

### Q2 — what comes automatically, what does not

**Automatic, from the list alone (all [MEASURED]):**

| behaviour | evidence |
|---|---|
| tall unified bar, 28 -> **52pt** | §2.1 |
| title relocates centre -> leading edge, stays visible | §2.5 |
| **overflow**: 14 items in a 420pt window -> `visibleItems = 3` + the system `»` chevron; widen and all 14 return | §2.3, `C3` |
| icon rendering from SF Symbol names | `displayMode = NSToolbarDisplayModeIconOnly` **[DOC: NSToolbar.h enum ordering]** |
| **enablement**: `.disabled` dims the button 41% in rendered ink, controls unchanged | §2.3 |
| labels reach AppKit (`NSToolbarItem.label`) — the accessible name and the overflow menu's text | §2.3 |
| composition with the sidebar: full-height sidebar, split bar, system sidebar-toggle item injected | §2.1, `D1`/`D2` |
| no customization palette: `allowsUserCustomization = false`, `autosavesConfiguration = false` — order is the app's, users cannot rearrange | §2.1 readback |

**NOT automatic:**

* **Icon + label together.** macOS shows **icon only**; there is no
  label under the glyph. An item with no icon renders its `Text`. If a
  promoted catalog item has no symbol, the mac bar shows words where the
  other platforms show a glyph — which is exactly why the plan's
  dependency "D6's icons come FIRST" is right.
* **`NSToolbarItem.isEnabled`.** Stays `true` for a visibly disabled
  button (§2.3). A harness verb reading it would report a false pass.
* **The macOS 26 material** (glass capsules, scroll-edge effect,
  separator-less bar): not reachable at all — §2.6.
* **Grouping / spacing of promoted items into glass clusters**: that is
  `ToolbarSpacer` and `sharedBackgroundVisibility(_:)`, both
  `macOS 26.0` **[DOC: SwiftUI.swiftinterface]**, and both moot while
  the program is SDK-14-linked.
* Nothing about a **document title/subtitle pair** (Font Book's "All
  Fonts / 365 typefaces"): kaya sets `navigationTitle` only.

### Q3 — is an 'extended' knob NEEDED?

**No. On macOS the tall/unified look is the default result of having the
bar.** The measured proof is the pair of rows in §2.1: no style set ->
52.0pt; `.unified` set -> 52.0pt; and the `.expanded` control moves to
56.0pt, so the comparison is real. Every byte of the genre geometry —
tall band, title inline at the leading edge, traffic lights lowered to
y=18, symbol buttons trailing, overflow chevron, full-height sidebar —
arrives from `.toolbar { … }` and nothing else.

Stronger, and slightly awkward for the draft's framing: **kaya's
sectioned-sidebar and `list_detail` windows are ALREADY in that
geometry** (52pt, full-height sidebar) because `NavigationSplitView`
installs its own NSToolbar with no `.toolbar` modifier at all
**[MEASURED, `D1`]**. The chrome the plan describes as "unreachable" is
in fact reachable today on those two arms; what is missing is *the app's
own actions in it*, which is precisely C2 and nothing else.

The one macOS thing a knob *would* buy is `unifiedCompact` (38pt) or
`expanded` (56pt) or `preference` (80pt) — i.e. *less* modern or
Settings-shaped, not more. None of those is the genre look.

### Q4 — can kaya reach the look with ZERO new styling vocabulary?

**On macOS: yes, entirely.** The needed additions are all *action*
vocabulary, not *styling* vocabulary:

1. C2's promotion list, lowered in `KayaSwiftUI.swift` as a macOS arm of
   the modifier that already exists for iOS (`KayaMenuToolbar`, line
   ~11078) — `#if os(macOS)` sibling emitting
   `ToolbarItemGroup(placement: .primaryAction)` over
   `kayaPromotedActions(window)`. Same catalog, same
   `kayaMenuEffectiveEnabled`, same `kayaSFSymbol` lookup the sidebar
   rows already use.
2. Nothing else. No `chrome` prop, no toolbar style, no
   `titlebarAppearsTransparent`, no `fullSizeContentView` (SwiftUI sets
   it already), no window-level flag.

**Knobs to eliminate, with the platform each is a no-op on:**

| proposed knob | macOS | why it should go |
|---|---|---|
| **C1 `chrome: standard \| extended`** | **redundant** — the toolbar produces the tall bar by itself, and `fullSizeContentView` is already in the styleMask **[MEASURED]** | already deferred; the mac column of its table was the argument for it, and that column is now empty. On iOS/Android the plan itself calls it a no-op "by construction" — a 5-platform knob that does nothing on 2 and duplicates C2 on 1 |
| **any `toolbar_style` / `unified` spelling** | **measured no-op** (§2.4) | GTK/WinUI/Compose have no comparable axis at all; it would be mac-only vocabulary that does nothing even on mac |
| `title_hidden` (C1b) | real, but it *shrinks* chrome 52->38 **[MEASURED]** | no-op on iOS/Android (no title bar); it trades the tall look for a shorter one, so it is not a step toward the genre look |
| toolbar item placement / centering | mac-only (`centeredItemIdentifiers`, `macos(13.0)`) | the plan already refuses it; the measurement supports the refusal |
| any material/translucency knob | **cannot work** — the material is gated by the guest binary's linked SDK (§2.6) | a knob that cannot move the pixel is worse than no knob |

**The one thing worth carrying forward that is not a knob:** if the
maintainer wants the actual macOS 26 material, the lever is the
**toolchain the guest binaries are linked with** (nix `apple-sdk-14.4`),
not the API surface. That belongs in the ledger as a build question, and
§2.6 records that a naive move to a 26 SDK main did not even open a
window in this probe.

### Observation notes for C2's verbs (macOS side)

* `expect_toolbar N` -> `kayaNSWindows[wid]?.toolbar?.items.count`, off
  the real bar. **[MEASURED as readable]** Careful on
  `NavigationSplitView` windows: SwiftUI injects
  `com.apple.SwiftUI.navigationSplitView.toggleSidebar` and
  `com.apple.SwiftUI.splitViewSeparator-0`, so the count is
  `promoted + 2` there. The verb should either count only items whose
  identifier is not `com.apple.SwiftUI.*`, or the scene must state the
  arm — the same "which arm rendered" discipline
  `expect_sections_presentation` already uses.
* `expect_toolbar_item i "label"` -> `toolbar.items[i].label`, which
  carries the SwiftUI `Label` title verbatim. **[MEASURED]**
* Enablement round-trip -> **not** `NSToolbarItem.isEnabled` (§2.3). Use
  the out-of-process AX read kaya's a11y verbs already do, or the pixel
  measurement; the in-process `NSView` AX tree under a toolbar item is
  all `AXUnknown` with nil labels. **[MEASURED]**
* Overflow -> `toolbar.visibleItems.count` vs `toolbar.items.count`
  gives a real, non-echoed read of clipping. **[MEASURED]**

## 4. Cross-check against kaya's OWN captures (not the probe)

The claim in Q3 — that kaya's sectioned-sidebar windows already sit in
the tall geometry — was verified against a capture of the real
interpreter, taken on this host by an earlier session:
`scratchpad/sect-sidebar-dark.png (gone)` (the `sections` scene, sidebar
presentation, 1080x660 = a 540x330pt window at 2x).

Method: convert to BMP with `sips`, walk a column at 75% width from the
top, and take the strongest luminance transition — the hairline under
the title bar. Points = pixel row / 2.

| capture | separator pixel row | **chrome, points** |
|---|---|---|
| **kaya `sections` scene, sidebar arm (repo capture)** | 104 | **52.0** |
| probe `D1` — `NavigationSplitView`, no `.toolbar` | 104 | **52.0** |
| probe `A2` — plain window + `.toolbar`, no style | 104 | **52.0** |
| probe `A1` — plain window, no toolbar | 56 | **28.0** |

**[MEASURED]** The pixel measurement and the `contentLayoutRect`
readback agree exactly, and kaya's shipped sidebar window is
pixel-identical in chrome height to a toolbar-carrying window. The tall
bar is not something kaya has to reach for; on two of its arms it is
already there, and on the third it arrives with the promotion list.

## 5. Version statement (what every claim above assumes)

macOS **26.5.2** (Darwin 25.5.0, arm64), Xcode **26.6.0** / Swift
**6.3.3**, SDK **MacOSX26.5** (`arm64-apple-macosx26.0`), AppKit and
SwiftUI as shipped in that SDK, guest binaries linked against the dev
shell's nix **apple-sdk-14.4**. `NSWindow.toolbarStyle` and
`Scene.windowToolbarStyle(_:)` are `macos(11.0)`;
`centeredItemIdentifiers` `macos(13.0)`; `ToolbarSpacer`,
`DefaultToolbarItem`, `sharedBackgroundVisibility`,
`scrollEdgeEffectStyle` are `macOS 26.0`.

## 6. Reproducing / cleanup

* Build: `probe-mac/build.sh` (prints the SDK of each output).
* Run: `probe-mac/run.sh <main> <mode> <shot-name> [PROBE_SET_STYLE]`,
  or `run2.sh <main> <dylib> <mode> <shot-name>` for the scene-style
  flavours. Env: `PROBE_ITEMS`, `PROBE_DISABLE`, `PROBE_WIDTH`,
  `PROBE_TITLE_HIDDEN`, `PROBE_HOLD_MS`.
* Every run kills its own process; Font Book was launched once for the
  Liquid Glass reference and quit (`osascript ... to quit`, verified 0
  processes).
