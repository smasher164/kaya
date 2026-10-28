# Native window tabs: what the platforms give, what other toolkits expose, and how much of it kaya should want

Status: STUDY, 2026-10-28. Nothing is built; the questions at the end are the
maintainer's. The maintainer, 2026-10-28: "what is the extent to which you can
style a native macos tab? what is the extent to which we want control over
native tabs in the first place for a gui toolkit that provides
platform-specific features? i feel like if someone sees native tabs, they're
more likely to think 'wow that's definitely a native app', which might help
our case." The trigger was the menu merge (c4adb7fe), which drops AppKit's
Show Tab Bar and Show All Tabs from the merged View menu (docs/traps.md, the
menu merge entry). The roadmap entry this study serves is `doctabs` in
docs/roadmap/features.toml.

The probe captures sit beside each finding on the review page:
https://claude.ai/artifact/JQ9wdLJjP4sAvNCFw3aJi1

Terms. A WINDOW TAB is macOS's NSWindow tabbing: each tab is a whole NSWindow,
and AppKit draws the strip. A DOCUMENT TAB is a tab the user opens, closes,
reorders and drags out (a browser's or an editor's). A SECTION TAB is one of a
fixed, app-declared set of destinations (kaya's sections, a phone's tab bar).
These three are different things, and most of the confusion in this area comes
from treating them as one.

## §1 macOS: what a public-API app can do with a native tab (measured)

Every line here was measured on macOS 26.6.2 (25G83) with AppKit probes built
by `kaya_swiftc` (the probe source is not in the tree; §6 says how to rebuild
it), each opening its own windows, tabbing them from code and photographing
only its own window by id (`screencapture -l`). "Active" captures were taken
with the host idle for at least 20 s and the probe activated.

**The surface is two classes and a handful of NSWindow members.** The macOS
26.6 SDK's NSWindowTab.h has four properties (`title`, `attributedTitle`,
`toolTip`, `accessoryView`); NSWindowTabGroup.h has `identifier`, `windows`
(KVO-compliant, in visual order), `overviewVisible`, `tabBarVisible`
(read-only), `selectedWindow`, `addWindow:`, `insertWindow:atIndex:`,
`removeWindow:`. NSWindow adds `tabbingIdentifier`, `tabbingMode`,
`allowsAutomaticWindowTabbing` (class), `userTabbingPreference` (class,
read-only), `addTabbedWindow:ordered:`, `tabbedWindows`, and the actions
`selectNextTab:`, `selectPreviousTab:`, `moveTabToNewWindow:`,
`mergeAllWindows:`, `toggleTabBar:`, `toggleTabOverview:`. The "+" button is
NSResponder's `newWindowForTab:`. There is no delegate method or notification
for a tab event; an app learns of a user's reorder, drag-out or merge only by
observing `tabGroup.windows`.

What each piece does, measured:

| Piece | Result |
|---|---|
| Geometry | The strip (private class NSTabBar) is 28 pt tall in every style tried: titled with no toolbar, unified, unifiedCompact, expanded, fullSizeContentView. It is a titlebar accessory: it sits in NSTitlebarAccessoryClipView under the toolbar. Tahoe draws it as a Liquid Glass capsule with a separate round "+". |
| `tab.title` | Defaults to `window.title` and follows it; can be set separately (read back). |
| `tab.toolTip` | Defaults to the title; settable. |
| `tab.attributedTitle` | Font (bold 15 pt), foreground colour (systemRed) and an SF Symbol text attachment are all drawn. The colour is full on the selected tab of the key window and washed out on other tabs and on an inactive window. |
| `tab.accessoryView` | Any NSView, drawn at the trailing end of the tab: an orange dot, an NSImageView, an NSButton. A real click on an NSButton accessory fired its action without selecting that tab. Only one, only trailing. |
| `isDocumentEdited` | Shows only as the dot in the window's close button, never on the tab. A dirty marker on a tab has to be an accessoryView. |
| The "+" | Drawn if and only if the responder chain answers `newWindowForTab:` (probe with `responds(to:)` false: no button). |
| Close | The title bar's close button and Close Tab close that one window; the right neighbour becomes selected. A tab's close "x" appears on hover at the tab's leading edge. |
| Order and selection from code | `removeWindow`, `insertWindow(at: 0)`, `moveTabToNewWindow`, `mergeAllWindows` (appends at the end), `selectedWindow =`, `selectNextTab` all work. `addWindow` and `addTabbedWindow` do not select the added tab. |
| Grouping rules | `addTabbedWindow` grouped windows with tabbingMode `.disallowed`, with `allowsAutomaticWindowTabbing = false`, with DIFFERENT tabbingIdentifiers, and even an NSPanel. Those switches govern only AUTOMATIC tabbing. `.preferred` auto-tabbed a second window of the same identifier on `orderFront`. |
| User's preference | `userTabbingPreference` read 2 ("in full screen", the default for System Settings' "Prefer tabs when opening documents"). Under it, three SwiftUI windows opened by `openWindow` were NOT tabbed until the app called `addTabbedWindow`. |
| One window | No strip until `toggleTabBar:`; then a one-tab strip with "+". The shown/hidden state PERSISTS across launches: the next run of the same probe started with the strip showing, and a torn-out window inherits whichever state is current. |
| Overflow | 30 tabs in a 720 pt window: no wrapping, no overflow menu. Tabs keep a minimum width (about 120 pt here), the strip scrolls, tabs between the visible ones squash to slivers, and the selected tab stays visible. |
| Overview | `isOverviewVisible = true` draws a grid of live thumbnails inside the same window (one CG window), with a "+" tile. |
| Context menu | Right-click on a tab: Close Tab, Close Other Tabs, Move Tab to New Window, Show All Tabs. No public API adds to it (Ghostty patches it through a private notification, §3). No Pin. |
| Drag out | A real drag of a tab 270 pt down turned it into its own window; the group shrank; the app was told nothing. |
| Menus | AppKit inserts Show Tab Bar, Show All Tabs and the Window menu's tab items as the menu OPENS; a programmatic read of the menu never sees them (docs/traps.md, the menu merge entry). |

**Styling: what moves the strip's look.** Nothing styles the strip directly.
`window.backgroundColor` (purple) changed the content area only; the strip
stayed system grey. `appearance = darkAqua` gives the dark strip. The one
public route to colour is indirect: with `fullSizeContentView` and a
transparent title bar, the glass strip shows the content behind it, so a
purple or teal content view tints the strip, the "+" and the traffic lights.
There is no API for the strip's background, height, material, separator,
close button, the "+" image, pinned tabs, a leading icon, or tab colours.
Titlebar accessories are per window, that is per tab: each tab owns its own
toolbar and accessories, which AppKit swaps on selection.

**What Safari and Finder do that public API cannot.** Safari's tab bar is not
NSWindow tabbing: its Compact layout (tabs in the toolbar), pinned tabs and
Tab Groups have no public spelling (support.apple.com/guide/safari/tabs-ibrw1045/mac).
Finder, TextEdit, Mail, Maps, Preview and iWork use the system tabs that
shipped in Sierra (macworld.com/article/228274); Xcode uses system window tabs
plus its own document tabs inside each.

**SwiftUI, kaya's Mac backend.** The macOS 26.6 SDK's SwiftUI and SwiftUICore
interfaces contain no symbol with "tabbing" in it; Apple's SwiftUI
documentation index has none either (7,242 paths walked); `.windowTabbingMode`
does not exist. A WindowGroup's window (class AppKitWindow) has tabbingMode
automatic and tabbingIdentifier `SwiftUI-WindowGroup-<module>.<View>-1`.
SwiftUI answers `newWindowForTab:`, so its windows draw the "+": a real click
opened a new window of the FIRST WindowGroup, and AppKit appended it to the
group. The same action sent through the responder chain without a click
opened an untabbed window, so the grouping is AppKit's "+" path. Everything
in the table above works on a SwiftUI window through `NSApp.windows`. Apple
DTS's own advice is the same split: SwiftUI windows "will open in a tab if
that is set to 'always' in the user preferences, otherwise it will be a
separate window" (developer.apple.com/forums/thread/782548).

**What this means for kaya today.** kaya's SwiftUI interpreter contains no
tabbing code, so every kaya Mac app has AppKit's automatic tabbing on: a user
with "Prefer tabs: Always" may see kaya windows tab together, with the tab
context menu, while the merged View menu no longer offers Show Tab Bar.
UNMEASURED: which of kaya's two WindowGroups' windows tab with which (they
carry different identifiers).

**Not measured:** a tab's look under VoiceOver and its accessibility tree;
tabs with native full screen and with Stage Manager; window restoration of a
tab group; the hover close "x" on an edited tab.

## §2 The other platforms (sourced)

**Windows.** No OS-level window tabbing exists. Sets was the attempt: build
17063 (December 2017) to build 17704 (June 2018), then cancelled
(bleepingcomputer.com, "microsoft-pulls-windows-10-sets-from-redstone-5-builds";
techradar.com, "microsoft-has-abandoned-tabbed-sets-for-windows-10"). Every
tabbed app draws its own strip, usually WinUI's TabView: a TabViewItem is a
ContentControl INSIDE one window, with an arbitrary `Header`, `IconSource`,
`IsClosable`, `TabWidthMode`, `CanReorderTabs`, `IsAddTabButtonVisible` and
`AddTabButtonClick`, and close is app work (`TabCloseRequested`). Tear-out is
`CanTearOutTabs` since Windows App SDK 1.6, and the app still creates the new
window (`TabTearOutWindowRequested`) and moves the item
(learn.microsoft.com/en-us/windows/apps/design/controls/tab-view;
blogs.windows.com, 2024-09-04). Tabs in the title bar are app layout
(`ExtendsContentIntoTitleBar` plus `SetTitleBar` on the strip's footer).
Windows Terminal uses the WinUI 2 TabView in a XAML Island
(github.com/microsoft/terminal, TabRowControl.xaml); whether File Explorer's
strip is the public TabView class is unsourced. No pinned, loading or
needs-attention state on TabViewItem.

**GNOME.** libadwaita has the strongest native document-tab set: AdwTabView
(pages, no visible switcher), AdwTabBar, AdwTabOverview (1.3, thumbnails with
search) and AdwTabButton. A page has `title`, `tooltip`, `icon`,
`indicator-icon`, `loading`, `needs-attention`, `pinned`, `live-thumbnail`,
`keyword`, but its header is not arbitrary content. Drag between windows of
the process is built in (`transfer_page`; `create-window` when a tab is
dropped outside), reorder and detach cannot be disabled, and close is
two-phase (`close-page`, then `close_page_finish`, possibly after a save
dialog). Shortcuts Ctrl+Tab, Ctrl+Page Up/Down, Alt+1..9 are built in; Ctrl+T
and Ctrl+W are app actions
(gnome.pages.gitlab.gnome.org/libadwaita/doc/main/class.TabView.html, TabPage,
TabBar, TabOverview, signal.TabView.close-page,
flags.TabViewShortcuts). Files, Web, Text Editor, Console and Builder (through
libpanel) all use it (their source trees on gitlab.gnome.org). The GNOME HIG
asks for a per-tab menu with Move to New Window and Close
(developer.gnome.org/hig/patterns/nav/tabs.html). GtkNotebook is plain GTK's
fallback (detachable tabs between notebooks of one group-name, arbitrary tab
label widget). Per-tab colours are impossible on libadwaita (Ghostty issue
2509, after asking the libadwaita room).

**iPadOS and iOS.** No public document-tab control. `UITab`, `UITabGroup`
and SwiftUI's `TabView` (iPadOS 18's tab bar and sidebar) are section tabs;
the HIG says a tab bar navigates "among different sections of an app"
(developer.apple.com/design/human-interface-guidelines/tab-bars). iPad windows
are scenes; iPadOS 26 windowing adds resizable windows, a menu bar and New
Window, but no window tabbing (support.apple.com/en-us/125309; the absence is
not stated by Apple). Safari's iPad strip is private. Mac Catalyst is the one
Apple case of the macOS model: a multi-scene Catalyst app gets automatic
window tabbing, off with `UIApplicationSupportsTabbedSceneCollection`.

**Android.** Material 3 tabs (`PrimaryTabRow`, `SecondaryTabRow` and their
scrollable forms; `TabRow` is deprecated) are section tabs: no close, no "+",
no drag (developer.android.com/develop/ui/compose/components/tabs). Chrome's
tablet strip is its own compositor code (StripLayoutHelper). Android 16's
desktop windowing gives multiple windows per app and a drag that starts a new
instance when a tab is dropped on empty space, with Chrome as the guide's own
example, but no grouping of windows into tabs
(developer.android.com/develop/ui/compose/layouts/adaptive/support-desktop-windowing).

**Coherence.** Two models exist, and they invert ownership.

- A TAB IS A WINDOW (macOS, Mac Catalyst). AppKit owns the strip, the
  grouping, the overview and the drag-out; the app owns N windows, each with
  its own title, toolbar, menu target and close path. Moving a tab changes
  which group a window is in; nothing is re-parented. The user can turn the
  grouping off (the System Settings preference, Move Tab to New Window).
- A TAB IS A VIEW IN ONE WINDOW (WinUI TabView, AdwTabView, GtkNotebook,
  Chrome on Android). The app owns one window with one title bar and toolbar
  and a strip control; each tab is a child view. Tear-out re-parents a live
  view between two windows of the process (WinUI, libadwaita), or on Android
  serializes the tab and rebuilds it in a new task.

| Concern | macOS | WinUI 3 | libadwaita | iPad | Android |
|---|---|---|---|---|---|
| Unit of a tab | a window | a TabViewItem in one window | an AdwTabPage in one window | none (a scene per document) | none (app-drawn) |
| Per-tab toolbar | yes, each tab-window's own | no, one per window | no, one per window | per scene | per task |
| Tab header | title, attributed title, tooltip, one trailing accessory | arbitrary content, icon | title, icon, indicator, loading, attention, pinned | n/a | app |
| Close tab | close that window | TabCloseRequested, app removes | close-page then close_page_finish | close the scene | app |
| Close window | closes one tab | closes all tabs | closes all tabs | n/a | n/a |
| "+" | iff `newWindowForTab:` answers | IsAddTabButtonVisible | an action widget on AdwTabBar | none | app |
| Drag out | system | CanTearOutTabs, app makes the window | built in, app returns the window | n/a | Intent on drop |
| Overview | Show All Tabs | none | AdwTabOverview | App Exposé | none |
| Merge all windows | system | none | none | none | none |
| User can turn tabs off | yes | no | no | n/a | n/a |

A single kaya concept can lower to both models only if a document's state
(title, dirty mark, toolbar, undo) lives in a kaya object that is neither a
window nor a widget, so that the Mac hosts it as a window and the others host
it as a page. kaya already has that object: surfaces share one id space with
windows and navigation entries, and `mount` targets any of them (DESIGN.md,
Sections). The per-document toolbar then has two spellings to reconcile: the
Mac duplicates it into each tab-window; WinUI and GNOME rebind the one window
toolbar on selection.

## §3 Other toolkits and apps (sourced)

| Toolkit or app | macOS window tabs | How | Elsewhere |
|---|---|---|---|
| Electron | yes, the broadest | `tabbingIdentifier`, `addTabbedWindow`, select next/previous, merge, move to new window, toggle bar, overview, the `new-window-for-tab` event (the "+"), menu roles; no NSWindowTab | HTML |
| Tauri / tao | identifier only | `tabbing_identifier`; tabbing disabled when unset, after "Show Tab Bar" appeared in every app's View menu (tauri#2804, PR #5399) | webview |
| winit | partial | identifier, select next/previous/index, tab count | none |
| iced, wxWidgets | on/off | `allow_automatic_tabbing`, `OSXEnableAutomaticTabbing` | own-drawn; wxNotebook |
| Qt | forced OFF on every window since 5.15 | QTBUG-61707 (the injected Show Tab Bar broke app UIs); the cost is QTBUG-110782, unresolved | QTabBar documentMode, style-drawn |
| Avalonia, SWT, Blender | forced off | `NSWindowTabbingModeDisallowed` / `allowsAutomaticWindowTabbing = NO` | own-drawn |
| JDK AWT/Swing | off by default | `jdk.allowMacOSTabbedWindows`; JDK-8256465 (frames froze in full screen with Prefer Tabs) | JTabbedPane |
| Flutter, React Native macOS | nothing | no window API for it | own-drawn |
| .NET MAUI | nothing | dotnet/maui#7451, Backlog, 30 upvotes | Shell tabs (phone style) |
| Mac Catalyst | automatic only | plist switch | n/a |
| SwiftUI | automatic only | no modifier; AppKit for the rest | TabView (section tabs) |
| VS Code | opt-in, off by default | `window.nativeTabs`; forces the native title bar ("Native tabs and the custom title bar are incompatible", vscode#157393) | HTML editor tabs |
| Ghostty | yes, the default | NSWindow tabs on the Mac; AdwTabView, AdwTabBar, AdwTabOverview on GTK | GTK native |
| Zed | opt-in hybrid | NSWindow grouping, the native strip HIDDEN, its own strip drawn (zed PR #33334) | GPUI-drawn |
| Sublime Text | opt-in | `native_tabs`; turns off its themed title bar | own-drawn file tabs |
| Alacritty | yes | through winit, macOS only | no tabs |
| iTerm2 | no | PSMTabBarControl with a hand-tuned Tahoe style (2,639 lines) that keeps pins, colours, progress | macOS only |
| WezTerm, Kitty | refused | "does not and will not support macOS native tabs" (wezterm#4381); kitty#2946 | own-drawn everywhere |

No toolkit wraps NSWindowTab. Most that touched tabbing did so to turn it
OFF, because automatic tabbing put menu items and a strip into apps that
never designed for them, or froze them.

**Ghostty is the precedent that matches the maintainer's instinct.** Mitchell
Hashimoto counts native tabs as part of being native: "Kitty is kind of not
native because tabs use a non-native widget"
(mitchellh.com/writing/ghostty-and-useful-zig-patterns); "Ghostty has native
tabs, splits, right-click menus ... (and really _is_) a native application on
both platforms" (mitchellh.com/writing/ghostty-is-coming). It uses NSWindow
tabs on the Mac and libadwaita's tab set on GTK. What it costs them, from
their source (ghostty-org/ghostty main, macos/Sources) and issues:

- The plain native strip (`macos-titlebar-style = native` or `transparent`)
  costs little: "a recompile gets us the new style tabs" on Tahoe (#7557).
  The public pieces they use are `tab.accessoryView` (tab colour, key
  equivalent, a reset-zoom button) and `tab.attributedTitle`.
- Everything beyond public API is private view surgery, marked in their code
  "Native tabbing private API usage. :(": the `tabs` style that merges tabs
  into the title bar, recolouring the "+", the tab context menu's extra item
  ("there doesn't seem to be an official API for customizing native tab bar
  menus"), inline rename over the private NSTabButton. Tahoe rebuilt the strip
  "based on SwiftUI ... extremely deep view hierarchies" (#7563), and macOS 27
  renamed the private container classes and broke it again (#13001, #13070,
  #14411).
- Structural costs that hit every style: each tab is a window to tiling
  window managers and to screen sharing (#692, #2006, ghostty.org/docs/help/macos-tiling-wms);
  tab groups restore as separate windows without a timing workaround (#7941);
  AppKit throws NSExceptions from tab-picker and full-screen tab flows, which
  they catch. Their own maintainers have said a custom tab bar is the only way
  out of the window-per-tab costs.

## §4 How much control kaya should want

**Is "looks native" real?** For the Mac, yes, with a limit. The plain system
strip is what Finder, TextEdit, Preview, Mail and Xcode show, and it moves
with each macOS release for free (a recompile carried it into Liquid Glass);
an own-drawn strip has to be redrawn by hand for each release, which is
iTerm2's 2,639-line Tahoe file. On GNOME the native strip is AdwTabBar, which
Files, Text Editor and Web use; on Windows "native" means WinUI's TabView in
the title bar, the way Terminal, Explorer and Notepad look. On the phones
there is no native document tab to look like.

**What the look cannot be.** A native Mac tab cannot carry kaya's skin: its
colour comes only from the content behind a full-size glass title bar, its
height and shape are Apple's, and its header is text plus one trailing view.
Anything more (Safari's compact layout, pinned tabs, a coloured tab, a leading
icon, an always-visible strip) is private API, which this study rules out for
kaya: it breaks every macOS release, as Ghostty's issue list shows.

**So the control worth wanting is semantic, not visual:** the document's
title, its dirty mark (on the Mac an accessory dot, since `isDocumentEdited`
never reaches the tab), a tooltip, the "+" as a request, close as a veto the
app answers, and reading the order and selection the user made. That is the
intersection of the three native controls, and it is enough for an editor.

## §5 Options

**A. None, and turn automatic tabbing off.** Set
`allowsAutomaticWindowTabbing = false` in the SwiftUI interpreter, as Qt,
Avalonia, SWT and the JDK do. Cost: one line on the Mac, nothing elsewhere.
Apps that want tabs draw them in-app. The "may not branch on platform"
invariant is untouched. It gives up the native Mac look entirely and closes
the current half-state (tabbing on, its menu items gone).

**B. A window-tab capability.** A window prop naming a tab group (and the
per-window tab title, tooltip and dirty dot), a "new tab" occurrence for the
"+", reads of the group's order. Advertised in the handshake like
`aux_windows` (DESIGN.md, Windows): honoured on the Mac, and on hosts without
window tabbing the windows simply stay separate windows. Mac cost: about one
slice (the probes above are most of the arm). Elsewhere: nothing to build.
The app does not branch, but its result differs by platform in kind: on GNOME
and Windows a tabbed editor becomes N windows, which is not what users there
expect from Text Editor or Notepad. That is a semantic divergence invariant 1
asks to be stated, and it would need the maintainer's carve-out.

**C. A document-tabs presentation over surfaces (the `doctabs` roadmap
entry, lowered natively per platform).** A window declares a document group;
each document is a surface (the sections precedent: surfaces, `mount`,
handlers bound at declaration), but the set is dynamic and closable. The app
says what documents exist and answers close requests; it never says how they
are drawn. Lowerings:
- macOS: each document is an NSWindow in one tab group (the model in §1),
  with the window toolbar duplicated per document window. Public API only.
- GTK: AdwTabView + AdwTabBar (+ AdwTabOverview), close through
  `close_page_finish`, tear-out through `create-window`.
- Windows: WinUI TabView in the title bar, `CanTearOutTabs`.
- iPad: a scene per document is the platform's idiom but needs the scene
  work kaya has not done; until then the phone arm.
- Phones: no strip; a switcher list or an overview grid (Chrome's and
  Safari's switchers, AdwTabOverview's shape).
Cost: L to XL across the five backends and nine bindings (the roadmap prices
it M, which this study finds too low because of the Mac's inverted
ownership). The invariant holds: one semantics (a set of documents, one
selected, each closable with a veto, reorderable, movable to a new window
where windows exist), with the presentation advisory as `sections_presentation`
already is.

**C without the Mac lowering** (draw the strip in SwiftUI on the Mac) is the
cheaper variant of C, and Zed's hybrid (native grouping, own strip) sits
between; both give up the native Mac look the maintainer asked about, so they
are listed for completeness, not recommended.

## Recommendation

C, with the Mac arm on NSWindow tabbing through public API only, built when
the editor app needs documents in tabs (the forcing app; docs/editor-plan.md).
Until then, A's one line: turn AppKit's automatic tabbing off, so that no kaya
app shows half of a feature (the tab strip and its context menu without the
menu items that control them). Never private API on the strip.

## Questions for the maintainer

1. Do you want native window tabs on the Mac, knowing that the strip itself
   cannot be skinned (colour only through the content behind a full-size
   title bar; text, a tooltip and one small trailing view per tab, and
   nothing else)?
2. If yes: one document-tabs concept that is native everywhere (C: Mac
   window tabs, GNOME's AdwTabView, WinUI's TabView, a switcher on phones),
   or a Mac-only window-tab capability that leaves other platforms with
   separate windows (B)?
3. Until either exists, should kaya turn AppKit's automatic tabbing off now
   (A)? Today a user whose Mac is set to "Prefer tabs: Always" can get kaya
   windows tabbed together, while the menu merge has already removed Show
   Tab Bar.
4. On a phone, what should a document-tabs app show: a list of open
   documents, or an overview grid of thumbnails?

## §6 Re-running the probes

The probes were single Swift files compiled with `kaya_swiftc` (the Hand
tools route in docs/HACKING.md; the SwiftUI one with `-parse-as-library`).
The AppKit probe makes NSWindows with a unified toolbar and a coloured
content view, groups them with `tabGroup.addWindow`, sets the NSWindowTab
properties, and captures `screencapture -x -o -l <windowNumber>`; the
pointer scenarios (context menu, drag out, the accessory click, SwiftUI's
"+") post CGEvents at the tab bar's frame, found by its private class name
NSTabBar for READING geometry only, and run only when `HIDIdleTime` is at
least 20 s. GOTCHA: an unbundled SwiftUI App given a bare first argument
opens no window, since AppKit takes argv as files to open; pass probe
settings in the environment.
