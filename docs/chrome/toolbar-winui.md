# Toolbar / chrome research — the WinUI 3 arm

Platform owner: WinUI 3 backend (`crates/kaya/src/winui/mod.rs`).
Question set: C2's promotion list, and whether a "modern/tall/extended"
knob is needed on Windows at all.

Evidence tiers, same convention as docs/chrome-plan.md:
**[DOC]** = primary platform documentation (URL + API + version),
**[MEASURED]** = read out of this repo (source, pinned winmd metadata,
generated bindings) or run here, **[INFER]** = inference, flagged.

STATUS: in progress — written as the work happens.

---

## 0. The versions every answer below is pinned to

All **[MEASURED]**, read from the tree on 2026-08-16:

| thing | version | where it is written |
|---|---|---|
| Windows App SDK (meta) | **2.2.0** | `tools/fetch-winappsdk.sh:95` (Runtime), header comment "component versions come from its nuspec (2.2.0)" |
| WASDK **WinUI** component (the XAML framework + `Microsoft.UI.Xaml.winmd`) | **2.2.1** | `tools/fetch-winappsdk.sh:92`, `tools/winui-bindgen/src/main.rs` (`Microsoft.WindowsAppSDK.WinUI-2.2.1/.../Microsoft.UI.Xaml.winmd`) |
| WASDK Foundation | 2.1.0 | `tools/fetch-winappsdk.sh:88` |
| WASDK InteractiveExperiences (`Microsoft.UI.winmd`) | 2.0.15 | `tools/fetch-winappsdk.sh:90` |
| WASDK Base | 2.0.4 | `tools/fetch-winappsdk.sh:86` |
| `windows` / `windows-core` crates | **0.62** | `crates/kaya/Cargo.toml:22,52` |
| `windows-collections` / `-numerics` / `-future` | 0.3 | `crates/kaya/Cargo.toml:66-66` |
| `windows-bindgen` | 0.62 (`.1` in the cargo cache) | `tools/winui-bindgen/Cargo.toml` |
| guest OS | Windows 11 arm64 in UTM (`tools/deploy-win.py akhil@192.168.64.2`) | CLAUDE.md ladder rung 4 |

The metadata itself is on this disk —
`third_party/winappsdk/Microsoft.WindowsAppSDK.WinUI-2.2.1/extracted/metadata/Microsoft.UI.Xaml.winmd`
— so the API claims below are read off the *pinned* winmd, not off a doc
page describing some other version. That is what makes them **[MEASURED]**.

---

## 1. What the WinUI backend has TODAY (the starting point)

**[MEASURED]**, `crates/kaya/src/winui/mod.rs` (12933 lines) and
`tools/winui-bindgen/src/main.rs`:

- **The window shell is a two-row Grid.** `ensure_menu_shell` (mod.rs:2588)
  builds `Grid { RowDefinition Auto; RowDefinition Star }`, puts a real
  `MenuBar` in row 0 and a `Grid` content slot in row 1, and calls
  `Window::SetContent` with it. Every later content swap goes through
  `set_window_content`, which fills the slot when the window carries a
  bar and writes the Window directly otherwise. **A toolbar row is a
  third RowDefinition in a Grid this backend already owns** — no new
  window plumbing.
- **The command catalog is already one source of truth.**
  `menu_effective_enabled` (mod.rs:2539) is the AND of the item's own
  flag and every grouping ancestor's, and the module comment states the
  echo doctrine: "ONE dispatch path — chrome clicks, the
  KeyboardAccelerator route, and harness verbs all land in
  `menu_user_activate` and emit". A toolbar button is another chrome
  view onto that same model, so C2's "disabling the menu item disables
  its toolbar button" is a rebuild-from-mirror away, not new machinery.
- **Menu items already carry the icon.** `MENU_PROPS` (spec.rs:342)
  has `symbol` at id 9, and this backend constructs it: `symbol_icon()`
  (mod.rs:1009) returns an `IconElement` via `SymbolIcon` (17 of the 20
  concepts) or `FontIcon` (info/warning/lock, no `Symbol` member).
  D6's icon dependency in chrome-plan §"Dependencies" **is already
  satisfied on this platform** — the toolbar's `AppBarButton.Icon`
  takes exactly the `IconElement` that function already returns.
- **The window is a standard titled window.** Nothing in mod.rs sets
  `ExtendsContentIntoTitleBar` or calls `SetTitleBar`; the only Win32
  interop is `IWindowNative::WindowHandle` for recording-mode placement
  (mod.rs:9291-9320), whose comment says outright: "The generated
  bindings do not project AppWindow".
- **The sections presentation is a `NavigationView`** (`refresh_sections`,
  mod.rs:2279) with `PaneDisplayMode = Left` for `sidebar`, `Top` for
  `bar`, `IsSettingsVisible=false`, `IsBackButtonVisible=Collapsed`.

## 2. Q1 — what an ordered promotion list lowers to, and whether a tall variant exists

### 2a. The lowering: `CommandBar` + `AppBarButton`, and it exists in the pinned SDK

**[MEASURED]** — I generated bindings from the repo's own pinned winmd
(`third_party/winappsdk/Microsoft.WindowsAppSDK.WinUI-2.2.1/extracted/metadata/Microsoft.UI.Xaml.winmd`)
with a scratch copy of `tools/winui-bindgen` (helper:
`scratchpad/chrome/probe-bindgen/ (gone)`, output `probe-out-cb2.rs`).
Everything C2's Windows row needs is present in WinUI **2.2.1**:

    CommandBar         PrimaryCommands, SecondaryCommands,
                       IsDynamicOverflowEnabled / Set…,
                       DefaultLabelPosition / Set…,
                       OverflowButtonVisibility / Set…,
                       ClosedDisplayMode / Set… (from AppBar),
                       Content / SetContent, IsOpen, IsSticky
    AppBarButton       Label / SetLabel, Icon / SetIcon (IconElement),
                       LabelPosition, IsCompact, IsInOverflow,
                       DynamicOverflowOrder, Click, IsEnabled
    AppBarToggleButton same + IsChecked (the `toggle` menu kind — but
                       see the nullable-bool note below)
    AppBarSeparator    (the `separator` menu kind)
    AppBarElementContainer  wrapper for non-ICommandBarElement content
    enum CommandBarDefaultLabelPosition   Bottom=0, Right=1, Collapsed=2
    enum CommandBarOverflowButtonVisibility Auto=0, Visible=1, Collapsed=2
    enum AppBarClosedDisplayMode          Compact=0, Minimal=1, Hidden=2
    enum CommandBarLabelPosition          Default=0, Collapsed=1

**Binding cost, and a trap that will bite exactly once [MEASURED]:** a
filter of `CommandBar` ALONE produces a `CommandBar` with **no
`PrimaryCommands` and no `SecondaryCommands`** — I ran it
(`probe-out-commandbar.rs`, 176 methods, neither one present). They
return `IObservableVector<ICommandBarElement>`, and windows-bindgen
drops any method whose type is unfiltered (docs/traps.md, "windows-bindgen
type filters do not pull referenced types transitively"; the same trap
the D6 icon entries document). Adding `Microsoft.UI.Xaml.Controls.ICommandBarElement`
to the filter is what makes the two collections appear. Same for
`AppBarButton.Icon`, which needs the already-present `IconElement`.
Also **[MEASURED]**: `ICommandBarElement2` and
`CommandBarDynamicOverflowItemsChangingEventArgs` do NOT exist in this
metadata — windows-bindgen panics `type not found` on them, which makes
the generator a usable existence oracle.

**The same trap a third time, and this one is NOT a copy of the menu
arm [MEASURED]:** with `AppBarToggleButton` + `ToggleButton` +
`IconElement` filtered, there is still **no `IsChecked`**
(`probe-out-toggle.rs` — only `RemoveChecked` and `OnToggle` survive).
It appears the moment `Windows.Foundation.IReference` joins the filter
(`probe-out-toggle2.rs` → `IsChecked`, `SetIsChecked`). The reason is a
real semantic difference, not a bindgen quirk: `ToggleButton.IsChecked`
is a **nullable bool** (the three-state property), whereas the
`ToggleMenuFlyoutItem.IsChecked` kaya writes today is a plain `bool`
(mod.rs:4071, `item.SetIsChecked(checked)`). So the toolbar's `toggle`
arm has to decide what `null` means and never produce it — an
indeterminate toolbar button is not a state kaya's menu vocabulary has.

### 2b. Is there a tall/extended variant? Yes — but it is a WINDOW flag, not a toolbar style

This is the load-bearing answer for the maintainer's question. On
Windows the genre look is **not** reachable from the command surface at
all. Three separate facts:

1. **`CommandBar` has no tall/extended/prominent style.** There is no
   such enum in the metadata **[MEASURED, the surface above]**. Its
   three size-ish knobs are `ClosedDisplayMode` (Compact / Minimal /
   Hidden — *smaller*, never taller) and `DefaultLabelPosition`
   (Bottom / Right / Collapsed), which changes where a label sits, not
   the genre. It is a bar inside the client area, under whatever title
   bar the window has.
2. **The "Files-app look" is `ExtendsContentIntoTitleBar` + a title-bar
   element.** **[DOC]** `Window.SetTitleBar` remarks: "To specify a
   custom title bar, you must first set `ExtendsContentIntoTitleBar` to
   `true` to hide the system title bar… If `ExtendsContentIntoTitleBar`
   is `false`, the call to `SetTitleBar` does not have any effect."
   (learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.window.settitlebar,
   moniker windows-app-sdk-2.0). That is exactly C1, which kaya
   deferred.
3. **The literal word "Tall" is a window property, and it THROWS
   without C1.** **[DOC]** Title bar customization, §"Tall title bar
   support for custom title bars": "The
   `AppWindowTitleBar.PreferredHeightOption` property gives you the
   option of increasing your title bar height from the standard height,
   which is the default, to a taller height. When you select `Tall`
   title bar mode, the caption buttons … are rendered taller with their
   min/max/close glyphs centered." and the Caution: "The
   `AppWindowTitleBar.ExtendsContentIntoTitleBar` property must be
   `true` before you set the `PreferredHeightOption` property. If you
   attempt to set `PreferredHeightOption` while
   `ExtendsContentIntoTitleBar` is `false`, an exception is thrown."
   (learn.microsoft.com/en-us/windows/apps/develop/title-bar). The
   sample there is guarded `if (ExtendsContentIntoTitleBar == true)`.

**Verdict for Q1: the tall variant is a WINDOW-LEVEL FLAG on Windows
(C1), not a default of the toolbar construct and not a style enum on
it.** A `CommandBar` under a standard title bar is the honest lowering
of C2 alone.

### 2c. The third construct nobody has named yet: `Microsoft.UI.Xaml.Controls.TitleBar`

**[MEASURED] it is in the pinned metadata** (probe:
`probe-out-titlebar2.rs`) with this surface:

    TitleBar : Control
      Title, Subtitle, IconSource
      LeftHeader, Content, RightHeader        (UIElement slots)
      IsBackButtonVisible / IsBackButtonEnabled / BackRequested
      IsPaneToggleButtonVisible / PaneToggleRequested
      AutoRefreshDragRegions, RecomputeDragRegions()
      TemplateSettings

**[DOC]** it arrived in Windows App SDK **1.7** — the API reference
carries monikers `windows-app-sdk-1.7 / 1.8 / 2.0-experimental / 2.0`
(learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.titlebar),
and `Window.SetTitleBar`'s remarks say: "Starting in Windows App SDK
1.7, you can use the XAML `TitleBar` control to create a custom title
bar… Only a single element can be specified as the title bar. We
recommend the XAML `TitleBar` control for this."

**And here is the sentence the maintainer's question is really about
[DOC, source]** — `TitleBar::UpdateHeight()`, read at the
`winui3/release/2.2.0` tag of microsoft/microsoft-ui-xaml
(`src/controls/dev/TitleBar/TitleBar.cpp:493`; the pinned WinUI is
2.2.1, one patch along the same line):

```cpp
GoToState((Content() == nullptr && LeftHeader() == nullptr && RightHeader() == nullptr) ?
    s_compactHeightVisualStateName : s_expandedHeightVisualStateName, false);
```

with `src/controls/dev/TitleBar/TitleBar_themeresources.xaml:77-78`:

```xml
<x:Double x:Key="TitleBarCompactHeight">32</x:Double>
<x:Double x:Key="TitleBarExpandedHeight">48</x:Double>
```

**The tall bar is the automatic consequence of putting something in
it.** Empty TitleBar → 32px. A TitleBar with any of Content /
LeftHeader / RightHeader → 48px. There is no `Tall` property on the
control and no style enum; the state is derived from whether the slots
are occupied. That is precisely "the look falls out of having the bar",
for the *control*.

Two caveats, both **[MEASURED]** at the same tag:

- `TitleBar.cpp` contains **zero** occurrences of `PreferredHeightOption`
  or `Tall` (`grep -c` = 0). The control's 48px expanded state does NOT
  move the window's caption buttons, which stay in the 32px standard
  band unless the app separately sets
  `AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall`.
  That mismatch is a live upstream bug report — microsoft/microsoft-ui-xaml
  issue **#9863**, "TitleBar doesn't respect
  AppWindow.TitleBar.PreferredHeightOption", opened 2024-07-31, still
  **open** as of this read.
- `AutoRefreshDragRegions` **defaults to `false`**
  (`TitleBar.idl:50`, `[MUX_DEFAULT_VALUE("false")]`). The control does
  compute passthrough regions itself — `UpdateDragRegion()` calls
  `InputNonClientPointerSource.SetRegionRects(NonClientRegionKind::Passthrough, …)`
  after walking `FindInteractableElements` — but with the default
  `false` it only recomputes on its own property changes, and an app
  whose bar content changes size must call `RecomputeDragRegions()` or
  opt into the auto mode. chrome-plan's C1 worry ("a window nobody can
  drag is the failure mode") is therefore **largely handled by this
  control** and NOT handled if kaya hand-rolls a Grid as the title bar.

## 3. Q2 — what comes for free from the list alone, and what does not

Lowering assumed: `CommandBar` in a new Auto row of the shell Grid,
one `AppBarButton` (or `AppBarToggleButton` / `AppBarSeparator`) per
promoted catalog item, in list order, in `PrimaryCommands`.

### Automatic (kaya writes nothing)

| behavior | evidence |
|---|---|
| **Overflow, and it is dynamic.** "When the command bar width changes, such as when users resize their app window, primary commands dynamically move between the command bar and the overflow menu at breakpoints." Default on; `IsDynamicOverflowEnabled` only turns it OFF. | **[DOC]** command-bar |
| **The "…" affordance and its menu.** "The 'see more' […] button is shown on the right of the bar… reveals primary command labels and opens the overflow menu if there are secondary commands." | **[DOC]** command-bar |
| **Icon+label rendering, with the right sizes in both places.** "The size of the icons when shown in the primary command area is 20x20px; in the overflow menu, icons are displayed at 16x16px. If you use SymbolIcon, FontIcon, or PathIcon, the icon will automatically scale to the correct size with no loss of fidelity when the command enters the secondary command area." kaya's `symbol_icon()` returns exactly SymbolIcon/FontIcon. | **[DOC]** + **[MEASURED]** mod.rs:1009 |
| **Label visibility follows the bar's state.** "The AppBarButton IsCompact property determines whether the label is shown. In a CommandBar control, the command bar overwrites the button's IsCompact property automatically as the command bar is opened and closed." So closed = icons only, no knob. | **[DOC]** command-bar |
| **Overflow items re-lay themselves out.** "In overflow menus, labels are positioned to the right of icons by default, and LabelPosition is ignored." An item that overflows becomes a menu row by itself. | **[DOC]** command-bar |
| **Enablement.** `AppBarButton.IsEnabled` is the ordinary `Control` property **[MEASURED, surface list]**, and the button object is the same object whether it sits in the bar or in the overflow, so one write covers both. | **[MEASURED]** + **[INFER]** for the overflow claim |
| **Geometry.** Closed bar height = `AppBarThemeCompactHeight` = **48** (`ContentRoot` carries `MinHeight="{ThemeResource AppBarThemeCompactHeight}"`); `AppBarThemeMinHeight` = 64 is the open height floor. | **[DOC, source]** `src/controls/dev/CommonStyles/CommandBar_themeresources.xaml:71-72,795` @2.2.0 |
| **A flat, chrome-less look.** `CommandBarBackground` = `ControlFillColorTransparentBrush` in the default theme — the closed bar is TRANSPARENT and takes the window's own surface. `AppBarButtonBackground` = `SubtleFillColorTransparentBrush`. Only the OPEN state uses `AcrylicInAppFillColorDefaultBrush`. | **[DOC, source]** CommandBar_themeresources.xaml:9-10, AppBarButton_themeresources.xaml:5 @2.2.0 |
| **Right alignment.** The template's `PrimaryItemsControl` is `HorizontalAlignment="Right"`; the `Content` slot is the left column. Commands sit at the RIGHT end of the bar on Windows, unlike mac/GTK's leading-edge toolbars. | **[DOC, source]** CommandBar_themeresources.xaml:821 @2.2.0 |
| **Light dismiss / open-close animation / access keys / keytips.** All template behavior. | **[DOC]** command-bar |

### NOT automatic (kaya must decide, or accept the default)

1. **Nothing tall.** No `CommandBar` knob raises the window's chrome; see §2b. 48px is the whole story inside the client area.
2. **No scroll-edge effect.** WinUI has no `NSScrollView`-linked title-bar material and no M3 `scrolledContainerColor` analog. A `CommandBar` looks the same at scroll offset 0 and 4000. There is no API for it in the metadata **[MEASURED]** and none in the docs **[DOC, absence]**.
3. **No material comes with the bar.** Mica is a WINDOW backdrop (`Window.SystemBackdrop`), not a bar property — and **[MEASURED]** `IWindow2`'s `SystemBackdrop` / `SetSystemBackdrop` / `AppWindow` are all `usize` **vtable pads** in kaya's generated bindings (bindings.rs:8640-8642), i.e. present in the metadata, unprojected because the types are unfiltered. Three filter lines away, but not free today.
4. **The accelerator text.** `AppBarButton` has `KeyboardAcceleratorTextOverride` **[MEASURED]**. kaya must use THAT and must NOT attach a second `KeyboardAccelerator` to the toolbar button — `attach_accelerator` already installs the chord on the MenuFlyoutItem (mod.rs:4059,4078), and a duplicate chord on a second element is a second handler for the same key.
5. **Tooltips.** The docs' own samples spell `ToolTipService.ToolTip="Copy"` by hand beside `Label="Copy"`; the label is not automatically a tooltip in the closed bar **[DOC]** command-bar SplitButton sample.
6. **The overflow's CONTENT is kaya's choice.** C2 says "secondary commands = the catalog's remainder". Nothing automatic produces that: `SecondaryCommands` is a second collection the backend must fill. Note the interaction — dynamic overflow pushes primary commands into the SAME menu, so the remainder and the demoted primaries interleave by construction.

## 4. Q3 — is an "extended" knob NEEDED to reach the genre look on Windows?

Split the question, because Windows answers the two halves differently.

**(a) "A modern-looking Windows 11 command surface" — NO KNOB. It is the
default of having the bar.** A closed `CommandBar` is a 48px strip with
a **transparent** background (`ControlFillColorTransparentBrush`),
20x20 icons, subtle-transparent buttons, right-aligned, with an
automatic dynamic overflow. Nothing about it says "UWP tablet bar"
unless you ask for that by setting `ClosedDisplayMode` or opening it.
The genre look on this platform is what you get for writing
`PrimaryCommands.Append(button)` and nothing else. **[DOC, source]**
for every value; **[INFER]** only for the aesthetic judgement.

**(b) "Commands in a tall unified title bar" (the Files-app look) — YES,
and the knob is a WINDOW knob that already has a name in this plan: C1.**
It is unreachable from any toolbar API. It needs, in order:
`Window.ExtendsContentIntoTitleBar = true` → `Window.SetTitleBar(el)` →
(for the caption buttons to match) `AppWindow.TitleBar.PreferredHeightOption
= TitleBarHeightOption.Tall`, which **throws** if the first step was
skipped **[DOC]**. Given C1, the height of the bar itself then needs no
knob at all, because `TitleBar` derives it from whether its slots are
occupied **[MEASURED, `UpdateHeight`]**.

So: **on Windows an "extended TOOLBAR" is meaningless. There is exactly
one place the tallness decision can live, and it is the window.** If
chrome-plan keeps C1 deferred, the Windows arm of C2 is complete and
honest as a `CommandBar` under a standard title bar, and nothing is
missing that a toolbar-level knob could supply.

## 5. Q4 — riding existing constructs, and the knobs to delete

### The zero-vocabulary path, in full

| kaya construct that already exists | Windows lowering | new vocabulary |
|---|---|---|
| the promotion list `toolbar(&[ids])` | `CommandBar.PrimaryCommands`, one `AppBarButton` per id, list order | none |
| catalog remainder | `CommandBar.SecondaryCommands` | none |
| item `label` | `AppBarButton.Label` (+ `KeyboardAcceleratorTextOverride` from `shortcut`) | none |
| item `symbol` (D6, shipped) | `AppBarButton.Icon` ← the `IconElement` `symbol_icon()` already builds | none |
| item `enabled` (with the ancestor AND) | `AppBarButton.IsEnabled` | none |
| item kind `toggle` / `separator` | `AppBarToggleButton` / `AppBarSeparator` | none |
| window shell Grid (mod.rs:2599) | a third `RowDefinition Auto` for the bar | none |
| `sections_presentation` = `sidebar` | `NavigationView PaneDisplayMode=Left` — unchanged | none |
| **[only if C1 lands]** `chrome = extended` | mount the SAME `CommandBar` in `TitleBar.Content` instead of the shell row, + `ExtendsContentIntoTitleBar` + `PreferredHeightOption=Tall` | none beyond C1's own enum |

The last row is the interesting one and it is the answer to "is there
another toolbar styling construct we can sneak it into?" **On Windows
the genre is decided by the bar's PARENT, not by a style on the bar.**
The same `CommandBar` object, moved from row 0 of the shell Grid into
`TitleBar.Content`, becomes the Files-app look — and the TitleBar goes
32→48px *because* its Content slot is now occupied **[MEASURED]**. That
is a mount-point decision, and kaya already has the prop that would
carry it (C1's `chrome`). No second knob.

Bonus, same zero-vocabulary rule **[DOC]** (title-bar control page,
§"Integration with NavigationView"): "The Navigation view has a built-in
back button and pane toggle button. Fluent Design guidance recommends
that these controls be placed in the title bar when a custom title bar
is used." kaya's sectioned windows already build a `NavigationView`
with `IsBackButtonVisible=Collapsed` **[MEASURED, mod.rs:2288]**, so if
C1 ever lands, the sidebar presentation can hand its pane toggle to
`TitleBar.IsPaneToggleButtonVisible` and get the Settings/Files shell
shape as a DERIVED consequence of two props the app already set.

### Knobs that would be no-ops (or near-no-ops) elsewhere — delete these

The maintainer asked for these by name. Each is a real WinUI property
I confirmed in the pinned metadata; each is the wrong thing to put in
kaya's vocabulary.

| candidate knob | the WinUI property behind it | why it must not exist in kaya |
|---|---|---|
| `toolbar_style: standard \| extended \| prominent \| tall` | **none — there is no such property** | Pure no-op on Windows. The tall decision is a window decision (§4b); a toolbar-level spelling would have to be silently forwarded to the window on Windows and would mean something different on every other platform. |
| `label_position: bottom \| right \| collapsed` | `CommandBar.DefaultLabelPosition` **[MEASURED]** | Windows-only spelling. Android's `TopAppBar` actions carry no labels at all; GTK header buttons are icon-only by convention; only mac has a partial analog (`NSToolbar.displayMode`). Not the 4/4 intersection C2's own refusal list demands. Take the default: closed bar = icons, labels in the overflow — which is ALSO what Android and GTK do. |
| `overflow: auto \| never` | `CommandBar.IsDynamicOverflowEnabled`, `OverflowButtonVisibility` **[MEASURED]** | Turning overflow OFF is expressible on Windows and roughly nowhere else (a GTK headerbar has no overflow mechanism to disable). A knob only one backend can honor is a per-platform styling thing by definition. |
| `bar_display: compact \| minimal \| hidden` | `AppBar.ClosedDisplayMode` **[MEASURED]** | Pure Windows. Also actively harmful: `Minimal`/`Hidden` are the retro tablet shapes. |
| toolbar background / material / translucency | `CommandBar.Background`, `Window.SystemBackdrop` | Already refused by C1's refusal list, and on Windows the bar is transparent by default and takes the window's surface — a color knob would fight the platform's own answer. |
| per-item placement (leading/trailing/center) | position in `PrimaryCommands` only | Windows right-aligns primary commands wholesale (`PrimaryItemsControl HorizontalAlignment="Right"` **[DOC, source]**); there is no leading/trailing split to honor. C2 already refuses this — the refusal is correct and Windows is the reason it stays correct. |

**The one thing that is NOT a styling knob and IS needed:** the split
between promoted (primary) and remainder (secondary). That is the
promotion list itself, which C2 already has.

## 6. Repo hazards a Windows toolbar arm walks into

### 6a. `XamlControlsResources` — the failure this backend has already paid for twice

**[MEASURED]** mod.rs:1496-1583 and docs/traps.md:690-710. A code-only
WinUI app has no App.xaml, so `outer_on_launched` merges
`XamlControlsResources` by hand. That merge loads through **ms-appx,
which in an unpackaged process resolves against the directory of the
EXECUTABLE** — not the dll, not the CWD. Rust and Go scene exes sit
beside `C:\kaya\resources.pri` and work; `python.exe`, `java.exe` and
`dotnet.exe` do not, so `deploy-win.py` arranges the minimal pri beside
each host exe per leg (deploy-win.py:732,760,810 and the comment at
1560-1569).

When the merge fails, kaya logs and continues — correct, because most
templates resolve locally — and `require_control_resources(surface)`
(mod.rs:1520) is the wall that turns the *later* death into a sentence.
Its docstring records the cost of not having it: `MenuBarItem`
realization fail-fasting with `0xc000027b` on a layout tick, six
harness steps after the menu was declared, blamed on the wrong step,
costing "a dump and a controlled substitution".

**The controls known to need the merge are growing** — ProgressBar
first, then ComboBox, RadioButtons, MenuBar/MenuFlyout
(deploy-win.py:1560-1593). `CommandBar`, `AppBarButton` and
`AppBarSeparator` are the same shape of control: MUX types whose default
styles live in the same framework dictionary
(`src/controls/dev/CommonStyles/CommandBar_themeresources.xaml`,
`AppBarButton_themeresources.xaml`) as everything already on that list
**[MEASURED, the file paths; [INFER] that the runtime dependency
follows — but it is the way to bet]**.

**Concrete guard, cheap because the wall exists:** the toolbar's
`ensure_*` function calls
`require_control_resources("this window declares a toolbar")` as its
first statement, exactly as `ensure_menu_shell` (mod.rs:2597) and
`ensure_context_flyout` (mod.rs:3837) do. The toolbar legs then also
need the pri-adjacency arrangement in `deploy-win.py`, or the
dll-hosted guests (python/java/dotnet) die at first layout.

### 6b. The bindgen transitivity trap, which WILL produce a false "WinUI has no X"

**[MEASURED, §2a]** filtering `CommandBar` alone yields a `CommandBar`
with no `PrimaryCommands`. Reading the generated file at that point
says "WinUI's CommandBar has no command collections", which is false —
the same disguise the D6 icon comment describes at
`tools/winui-bindgen/src/main.rs:297-313`. The filter needs, at minimum:

    Microsoft.UI.Xaml.Controls.CommandBar
    Microsoft.UI.Xaml.Controls.AppBar                  (ClosedDisplayMode)
    Microsoft.UI.Xaml.Controls.ICommandBarElement      ← the one that unlocks the collections
    Microsoft.UI.Xaml.Controls.AppBarButton
    Microsoft.UI.Xaml.Controls.AppBarToggleButton
    Microsoft.UI.Xaml.Controls.Primitives.ToggleButton  ┐ both needed, or
    Windows.Foundation.IReference                       ┘ IsChecked vanishes
    Microsoft.UI.Xaml.Controls.AppBarSeparator
    Microsoft.UI.Xaml.Controls.CommandBarDefaultLabelPosition   (only if a knob survives — it should not)
    Microsoft.UI.Xaml.Controls.CommandBarOverflowButtonVisibility (same)

and, only if C1 is ever ratified, `Microsoft.UI.Xaml.Controls.TitleBar`,
`Microsoft.UI.Xaml.Controls.IconSource`, plus
`Microsoft.UI.Windowing.AppWindow` / `AppWindowTitleBar` /
`TitleBarHeightOption` — the last three because **[MEASURED]**
`IWindow2`'s `SystemBackdrop`, `SetSystemBackdrop` and `AppWindow` are
all `usize` vtable pads in the committed bindings today
(bindings.rs:8640-8642). `Window.ExtendsContentIntoTitleBar` and
`Window.SetTitleBar` are ALREADY projected (bindings.rs:11400,11502),
so the C1 half kaya can reach today is the XAML-Window half; the
caption-button height needs the AppWindow filter entries.

### 6c. Smaller ones

- **A window would carry BOTH a `MenuBar` and a `CommandBar`.** kaya's
  shell puts the menubar in row 0; the toolbar would be row 1 and the
  content row 2. Two stacked command surfaces is not a Windows 11 idiom
  **[INFER]**; worth a maintainer decision, not a silent lowering.
- **The HWND subclass.** kaya replaces the WNDPROC per window for
  `WM_CLOSE`/`WM_CLIPBOARDUPDATE` (mod.rs:9322-9330). With a custom
  title bar, hit-testing moves to `InputNonClientPointerSource`; the
  existing subclass forwards everything else, so **[INFER]** no
  conflict — but it is a C1 depth-slice question, not a C2 one.
- **A `Control` inside `TitleBar.Content` becomes a passthrough region
  WHOLE.** `FindInteractableElements` (TitleBar.cpp:1058 @2.2.0) adds
  any enabled `Control` and stops recursing. A stretched `CommandBar`
  would therefore make the entire content area non-draggable. Size the
  bar to its content (the primary items are right-aligned anyway) or
  set the `TitleBar.IsDragRegion` attached property explicitly — it is
  in the pinned metadata as a pad (`probe-out-titlebar2.rs:6078`).
- **`AutoRefreshDragRegions` defaults to false** **[MEASURED,
  TitleBar.idl:50]** — a toolbar whose buttons change (enablement
  churn, overflow moves) needs `RecomputeDragRegions()` or the opt-in.

### 6d. The harness read (`expect_toolbar`, `expect_toolbar_item`)

C2 asks for "the platform's own accessibility name for the button".
This backend already reads real chrome that way (`menu_state`,
mod.rs:10581; `menu_count`-style reads off the live `MenuBar`,
mod.rs:10570). For a toolbar the equivalent is
`CommandBar.PrimaryCommands` size and each `AppBarButton`'s UIA name.
**[INFER]**: `AppBarButton`'s automation name comes from `Label` when
`Content` is null — this is NOT verifiable from the open sources
(AppBarButton lives in the closed dxaml half of the framework; only its
theme resources are public), so the depth slice must READ IT rather
than assume it, and if it turns out to come from `Content` the arm sets
`AutomationProperties.Name` explicitly. Note the discipline that
applies: an observation that can only ever answer one way is not an
observation (CLAUDE.md invariant 3 / `tools/check-diagnostics.py`).

## 7. Answers in one place

- **Q1.** Promotion list → `CommandBar` with one `AppBarButton` /
  `AppBarToggleButton` / `AppBarSeparator` per item in
  `PrimaryCommands`, remainder in `SecondaryCommands`. All present in
  the pinned WinUI **2.2.1** metadata **[MEASURED]**. A tall/extended
  variant **exists on Windows but not on this construct**: it is
  `Window.ExtendsContentIntoTitleBar` plus
  `AppWindowTitleBar.PreferredHeightOption = Tall`, both **window-level
  flags**, the second throwing without the first **[DOC]**. So the
  answer to the four-way question is **window-flag**, not
  default-of-construct and not programmatic-style.
- **Q2.** Free: dynamic overflow with breakpoints, the "…" affordance
  and its menu, 20px→16px icon rescaling, label hiding in the closed
  bar, overflow rows re-laid as icon+label, `IsEnabled` on the one
  button object wherever it sits, 48px height, a transparent background
  that takes the window's surface, right alignment, light dismiss,
  access keys. Not free: anything tall, any scroll-edge effect (WinUI
  has none), any material (Mica is a window backdrop and is an
  unprojected vtable pad in kaya today), accelerator text
  (`KeyboardAcceleratorTextOverride`, and kaya must NOT attach a second
  `KeyboardAccelerator`), tooltips, and the primary/secondary split.
- **Q3.** For the Windows 11 command-surface look: **no knob — it is
  the default of having the bar**. For the Files-app tall unified look:
  a knob is needed, it is a WINDOW knob, and it is C1 exactly.
- **Q4.** Yes, zero new styling vocabulary. The promotion list plus the
  catalog is the whole Windows arm. The only thing that changes the
  genre is the bar's MOUNT POINT (shell row vs `TitleBar.Content`),
  which is C1's `chrome` prop and not a toolbar prop. Delete before
  they are proposed: `toolbar_style/extended/prominent`,
  `label_position`, `overflow: never`, `ClosedDisplayMode`, toolbar
  background/material, per-item placement. Every one of them is a
  Windows-only or near-Windows-only spelling, and the first is a
  literal no-op here.

## 8. What a Windows depth slice must MEASURE (nothing below is settled by reading)

1. Does a `CommandBar` realize without the `XamlControlsResources`
   merge, or does it join ProgressBar/ComboBox/RadioButtons/MenuBar on
   the pri-adjacency list? (Run one leg from a host exe with no
   adjacent pri and watch it fail-fast, then add the wall.)
2. `AppBarButton`'s UIA name with `Label` set and `Content` null.
3. Whether the "…" button appears when every promoted item has a label
   and there are no secondary commands — the doc sentence ("will not be
   visible when no primary command labels or secondary labels are
   present") and `EffectiveOverflowButtonVisibility` are computed in the
   closed half of the framework, so this is a run-it question.
4. (C1 only) Whether `PreferredHeightOption = Tall` plus a `TitleBar`
   with occupied Content actually line the caption buttons up with the
   48px bar, given upstream issue #9863 is still open.

## Sources

- [Command bar (Windows App SDK docs)](https://learn.microsoft.com/en-us/windows/apps/design/controls/command-bar)
- [Title bar control (Windows App SDK docs)](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/title-bar)
- [Title bar customization — incl. "Tall title bar support"](https://learn.microsoft.com/en-us/windows/apps/develop/title-bar)
- [Window.SetTitleBar method](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.window.settitlebar)
- [TitleBar class reference (monikers 1.7 → 2.0)](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.titlebar)
- [AppWindowTitleBar.PreferredHeightOption](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.windowing.appwindowtitlebar.preferredheightoption)
- [microsoft-ui-xaml @ winui3/release/2.2.0 — TitleBar.cpp / TitleBar.idl / TitleBar_themeresources.xaml / CommonStyles/CommandBar_themeresources.xaml](https://github.com/microsoft/microsoft-ui-xaml/tree/winui3/release/2.2.0)
- [microsoft-ui-xaml issue #9863 — TitleBar doesn't respect PreferredHeightOption](https://github.com/microsoft/microsoft-ui-xaml/issues/9863)

Scratch artifacts backing the [MEASURED] claims (all outside the repo):
`scratchpad/chrome/probe-bindgen/ (gone)` (the generator),
`probe-out-commandbar.rs` (CommandBar alone — no PrimaryCommands),
`probe-out-cb2.rs` (the full command surface),
`probe-out-titlebar2.rs` (TitleBar with slots),
`v220-*.cpp/.idl/.xaml` (WinUI 2.2.0 release sources).
