# Windows app identity (icon + name) for kaya's UNPACKAGED WinUI 3 app

Evidence tags: [DOC] cited URL · [MEASURED] I ran/inspected it (command + output shown)
· [REPO] read from this tree · [INFER] my reasoning from the above.

STATUS: COMPLETE. Sections 0-6 plus a verdict. One question is left explicitly
open and named as such (does `AppWindow.SetIcon` route through `WM_SETICON`) —
see §6's "THE ONE LINK I COULD NOT VERIFY".

---

## 0. The pinned SDK

[REPO] `tools/fetch-winappsdk.sh:86-95` pins the component packages by exact
version (comment on line 23-24: the component versions come from the
`Microsoft.WindowsAppSDK` 2.2.0 meta-package's nuspec):

    fetch Microsoft.WindowsAppSDK.Base                   2.0.4
    fetch Microsoft.WindowsAppSDK.Foundation             2.1.0
    fetch Microsoft.WindowsAppSDK.InteractiveExperiences 2.0.15
    fetch Microsoft.WindowsAppSDK.WinUI                  2.2.1
    fetch Microsoft.WindowsAppSDK.Runtime                2.2.0

So: **Windows App SDK 2.2.0**, WinUI component 2.2.1.

[REPO] `tools/winui-bindgen/src/main.rs:14-28` names the exact winmd inputs the
Rust bindings are generated from. [MEASURED] all of them are present on this
machine, cached under `third_party/winappsdk/` (gitignored, 108 MB runtime
installer alongside).

### How I inspected the winmd

[MEASURED] I wrote a minimal ECMA-335 reader (PE → CLI header → `#~`/`#Strings`/
`#Blob` streams → tables, with a signature-blob type decoder) at
`<scratchpad>/winmd.py` + `<scratchpad>/sig.py` and ran it against the pinned
files. This is a REAL table walk, not a string scan — property names come out of
the `Property` table via `PropertyMap`, and property types are decoded from the
`#Blob` signature. Sanity output for `Microsoft.UI.Xaml.winmd`:

    runtime WindowsRuntime 1.4
    streams {'#~': ('0x2c4', 1146824), '#Strings': ('0x11828c', 262728),
             '#US': ..., '#GUID': ..., '#Blob': ('0x1584ec', 212668)}
    TypeDef rows 3079   Property rows 9641

(A plain string scan agreed and is reported where it adds nothing: `TitleBar` ×31,
`IconSource` ×67, `ImageIconSource` ×7, `BitmapIconSource` ×7,
`SoftwareBitmapSource` ×3 in that file.)

---

## 1. Is `TitleBar.IconSource` in the pinned winmd? YES.

[MEASURED] `third_party/winappsdk/Microsoft.WindowsAppSDK.WinUI-2.2.1/extracted/metadata/Microsoft.UI.Xaml.winmd`,
TypeDef row 1909 `Microsoft.UI.Xaml.Controls.TitleBar`:

    prop  Title                        : string
    prop  Subtitle                     : string
    prop  RightHeader                  : Microsoft.UI.Xaml.UIElement
    prop  LeftHeader                   : Microsoft.UI.Xaml.UIElement
    prop  IsPaneToggleButtonVisible    : bool
    prop  IsBackButtonVisible          : bool
    prop  IsBackButtonEnabled          : bool
    prop  IconSource                   : Microsoft.UI.Xaml.Controls.IconSource   <<<<
    prop  Content                      : Microsoft.UI.Xaml.UIElement
    prop  TemplateSettings             : Microsoft.UI.Xaml.Controls.TitleBarTemplateSettings
    prop  AutoRefreshDragRegions       : bool
    …plus the DependencyProperty statics, including IconSourceProperty

**Exact type name:** `Microsoft.UI.Xaml.Controls.TitleBar.IconSource`.
**Property type:** `Microsoft.UI.Xaml.Controls.IconSource` — the abstract
`IconSource` base (NOT `ImageSource`, and NOT `IconElement`). It is a
DependencyProperty (`IconSourceProperty` is present).

[MEASURED] It sits on `ITitleBar` — the *first* version of the interface, not
`ITitleBar2`. `ITitleBar` carries `Content, IconSource, IsBackButtonEnabled,
IsBackButtonVisible, IsPaneToggleButtonVisible, LeftHeader, RightHeader,
Subtitle, TemplateSettings, Title`; `ITitleBar2` adds only
`AutoRefreshDragRegions`. [INFER] So `IconSource` was on `TitleBar` from the
control's first stable shape — it is not a later addition that a downlevel
runtime might lack.

### THE TRAP: kaya's own generated bindings ELIDE it

[MEASURED] `crates/kaya/src/winui/bindings.rs:68170-68171` — the `ITitleBar`
vtable in kaya's committed bindings:

                    pub SetSubtitle: unsafe extern "system" fn(…)
                    IconSource: usize,
                    SetIconSource: usize,
                    pub LeftHeader: unsafe extern "system" fn(…)

`usize` is windows-bindgen's placeholder for "vtable slot reserved, method NOT
projected" — it elides any method whose parameter type is outside the `--filter`
set, keeping the slot so the vtable layout stays right.
[REPO] `tools/winui-bindgen/src/main.rs`'s filter list contains
`Microsoft.UI.Xaml.Controls.IconElement`, `SymbolIcon`, `FontIcon`,
`Microsoft.UI.Xaml.Controls.TitleBar`, `Microsoft.UI.Xaml.Media.ImageSource`,
`Microsoft.UI.Xaml.Media.Imaging.BitmapImage`, `Microsoft.UI.Xaml.Controls.Image`
— but **no `IconSource` type at all** ([MEASURED] `ImageIconSource` and
`BitmapIconSource` appear 0 times in the 181,935-line bindings.rs).

[INFER] So step one of any implementation is a bindgen-filter change plus a
regenerate — the metadata has the property, kaya's projection does not yet.

---

## 2. Feeding `IconSource` from RUNTIME BYTES (no file, no packaged resource)

[MEASURED] Complete `IconSource` hierarchy in the pinned `Microsoft.UI.Xaml.winmd`
(walked by `Extends`, transitively):

| type | the slot that carries the picture | takes bytes? |
|---|---|---|
| `Microsoft.UI.Xaml.Controls.IconSource` (abstract) | `Foreground : Brush` only | — |
| `AnimatedIconSource` | `Source : IAnimatedVisualSource2`, `FallbackIconSource : IconSource` | no (codegen'd Lottie type) |
| `BitmapIconSource` | **`UriSource : Windows.Foundation.Uri`** | **NO — URI only** |
| `FontIconSource` | `Glyph : string`, `FontFamily : FontFamily`, … | no (glyph) |
| **`ImageIconSource`** | **`ImageSource : Microsoft.UI.Xaml.Media.ImageSource`** | **YES, transitively** |
| `PathIconSource` | `Data : Geometry` | no (vector path) |
| `SymbolIconSource` | `Symbol : Symbol` | no (enum) |

So the question reduces to: which `ImageSource` accepts an in-memory stream?
[MEASURED] the `ImageSource` hierarchy, same file:

    Microsoft.UI.Xaml.Media.ImageSource                     (abstract, no members)
    ├─ Microsoft.UI.Xaml.Media.Imaging.BitmapSource
    │     meth SetSource       (Windows.Storage.Streams.IRandomAccessStream) -> void
    │     meth SetSourceAsync  (Windows.Storage.Streams.IRandomAccessStream) -> IAsyncAction
    │     ├─ BitmapImage       prop UriSource : Windows.Foundation.Uri; ctor(); ctor(Uri)
    │     └─ WriteableBitmap   prop PixelBuffer : IBuffer; ctor(i4,i4)
    ├─ SoftwareBitmapSource    meth SetBitmapAsync(Windows.Graphics.Imaging.SoftwareBitmap) -> IAsyncAction
    ├─ SvgImageSource          prop UriSource : Uri; meth SetSourceAsync(IRandomAccessStream)
    ├─ RenderTargetBitmap      meth RenderAsync(UIElement)
    └─ SurfaceImageSource / VirtualSurfaceImageSource

**Precise answer:**

- `BitmapIconSource` — **demands a URI**. Its only picture slot is
  `UriSource : Windows.Foundation.Uri`. There is no stream setter anywhere on it
  ([MEASURED] its full member list is `UriSource`, `ShowAsMonochrome`, plus the
  two `DependencyProperty` statics). Bytes would have to become a file (or a
  registered `ms-appx:`/custom URI scheme) first. **Not the route.**
- `ImageIconSource` + `BitmapImage` — **accepts an in-memory stream.**
  `BitmapImage` inherits `SetSource(IRandomAccessStream)` and
  `SetSourceAsync(IRandomAccessStream)` from `BitmapSource`. Feed an
  `InMemoryRandomAccessStream`, no disk, no URI. **This is the route.**
- `SoftwareBitmapSource` — accepts a `SoftwareBitmap`, i.e. **decoded** pixels,
  not encoded PNG bytes. You would have to run the PNG through
  `Windows.Graphics.Imaging.BitmapDecoder` yourself first. It IS a no-file path,
  but it is a longer one than `BitmapImage` and its type is not in kaya's
  bindings at all ([MEASURED] `SoftwareBitmapSource` occurs 0× in bindings.rs).
- `SvgImageSource` — also has `SetSourceAsync(IRandomAccessStream)`, so an SVG
  blob is equally viable if kaya ever wants vector identity.

### kaya ALREADY DOES EXACTLY THIS, one layer over

[REPO] `crates/kaya/src/winui/mod.rs:8376-8398` — the `Image` widget's
`Prop::Source` arm with a `Value::Blob`:

    let stream = InMemoryRandomAccessStream::new()?;
    let writer = DataWriter::CreateDataWriter(&stream)?;
    writer.WriteBytes(&blob.0)?;
    writer.StoreAsync()?.join()?;
    writer.DetachStream()?;
    stream.Seek(0)?;
    let source = BitmapImage::new()?;
    source.SetSource(&stream)?;
    image.SetSource(&source)?;

and the comment above it already states the reasoning ("SetSource is the
synchronously-callable path on the UI thread; the one async hop is
DataWriter.StoreAsync, blocked on .join()"). [REPO] the imports are at
`mod.rs:92` (`BitmapImage`) and `mod.rs:94` (`DataWriter`,
`InMemoryRandomAccessStream`).

[INFER] So the caption-icon lowering is that same block with two lines changed at
the end:

    let icon = ImageIconSource::new()?;   // NEW type — needs the bindgen filter
    icon.SetImageSource(&source)?;
    titlebar.SetIconSource(&icon)?;       // NEW slot — currently elided as usize

Everything before `let source = BitmapImage::new()` is already written, already
shipped, and already runs on the Windows lane.

---

(sections 3-6 and the verdict follow)

---

## 1b. When was `TitleBar.IconSource` introduced?

[DOC] https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.titlebar.iconsource
— the page's moniker list is exactly:

    monikers: windows-app-sdk-1.7, windows-app-sdk-1.8,
              windows-app-sdk-2.0-experimental, windows-app-sdk-2.0

so **Windows App SDK 1.7** is the first stable version with it (the `TitleBar`
control itself was experimental in 1.6). Description: *"Gets or sets the icon
image to show in the title bar."* Signature: `public IconSource IconSource
{ get; set; }`, property value `IconSource`, default `null`. The pinned SDK is
2.2.0, well past 1.7. [INFER] no version risk.

---

## 3. TASKBAR and ALT-TAB: the WINDOW's icon, not the control

### 3a. What is in the pinned metadata

[MEASURED] `Microsoft.WindowsAppSDK.InteractiveExperiences-2.0.15/extracted/metadata/10.0.18362.0/Microsoft.UI.winmd`,
`Microsoft.UI.Windowing.AppWindow` — the icon-setting methods, verbatim from the
`MethodDef` table:

    meth SetIcon          (string)             -> void
    meth SetIcon          (Microsoft.UI.IconId) -> void
    meth SetTaskbarIcon   (string)             -> void
    meth SetTaskbarIcon   (Microsoft.UI.IconId) -> void
    meth SetTitleBarIcon  (string)             -> void
    meth SetTitleBarIcon  (Microsoft.UI.IconId) -> void

(identical in the 10.0.17763.0 metadata flavour in the same package.)
`Microsoft.UI.IconId` is a `System.ValueType` struct — a WinRT struct, so it is
just a wrapped handle value, not a COM object.

**Answer to "does `AppWindow.SetIcon` exist in the pinned SDK": yes, with BOTH
overloads, plus two later siblings that split the surfaces.**

[DOC] https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.windowing.appwindow.seticon
— `SetIcon` applies to windows-app-sdk 1.0 through 2.0. Remarks on the string
overload: *"The `SetIcon(String)` method works only with .ico files… The string
you pass to this method is the fully qualified path to the .ico file."*
So **the string overload is a FILE PATH and cannot take bytes.**

[DOC] https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.windowing.appwindow.settaskbaricon
— `SetTaskbarIcon` monikers are 1.7, 1.8, 2.0-exp, 2.0, i.e. **new in Windows
App SDK 1.7**, same as `TitleBar.IconSource`. Remarks: *"For more information
about setting the icon, see SetIcon. This method works the same way, but lets
you set the taskbar icon **independently of the title bar icon**."*
[INFER] Before 1.7 you had one knob for both; 1.7 split it. Both halves are in
the pinned SDK.

### 3b. Getting an `IconId` from BYTES — the exact chain

[DOC] `SetIcon(IconId)` remarks: *"If you already have a handle to an icon
(`HICON`) from one of the Icon functions like `CreateIcon` or `LoadImage`, you
can use the **`GetIconIdFromIcon`** interop API to get an `IconId`. You can then
pass the `IconId` to the `SetIcon(IconId)` method to set your window icon."*
The docs' own C# sample is
`IconId iconID = Microsoft.UI.Win32Interop.GetIconIdFromIcon(hIcon);`

**The exact interop function** —
[DOC] https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/win32/microsoft.ui.interop/nf-microsoft-ui-interop-geticonidfromicon

    HRESULT GetIconIdFromIcon(
      HICON                        hicon,
      ::ABI::Microsoft::UI::IconId *iconId
    ) noexcept;

header `microsoft.ui.interop.h`; min client Windows 10 1809 with Windows App SDK
1.0 or later. C# name: `Microsoft.UI.Win32Interop.GetIconIdFromIcon`.

[MEASURED] **It is NOT a WinRT method** — I confirmed this in the pinned metadata:
`Microsoft.UI.Win32Interop` does not exist as a TypeDef in either
`Microsoft.UI.winmd` flavour, and a byte grep for the string `Win32Interop` over
every `.winmd` in `third_party/winappsdk/` returns **no hits at all**. It is a
flat C function in a header. [MEASURED] The pinned header
`third_party/winappsdk/Microsoft.WindowsAppSDK.InteractiveExperiences-2.0.15/extracted/include/Microsoft.UI.Interop.h`
shows how it resolves at runtime (lines 28-93):

    typedef HRESULT (STDAPICALLTYPE *PfnGetIconIdFromIcon)(_In_ HICON hicon, _Out_ ABI::Microsoft::UI::IconId* iconId);
    …
    HMODULE hmod = ::GetModuleHandle(TEXT("Microsoft.Internal.FrameworkUdk.dll"));
    if (hmod == nullptr) { hmod = ::LoadLibrary(TEXT("Microsoft.Internal.FrameworkUdk.dll")); }
    *reinterpret_cast<FARPROC*>(&s_impl.pfnGetIconIdFromIcon) = ::GetProcAddress(hmod, "Windowing_GetIconIdFromIcon");

with the header's own comment (line 51-53):
*"Load the FrameworkUdk library if needed and store pointers to the handle
conversion functions. We need this approach because third-party apps cannot link
to the FrameworkUdk directly. **Note that in unpackaged apps this will only work
after a call to MddBootstrapInitialize().**"*

[INFER] For kaya's Rust backend that means: a `LoadLibraryW("Microsoft.Internal.FrameworkUdk.dll")`
+ `GetProcAddress("Windowing_GetIconIdFromIcon")` pair — a hand-written
`define_interface!`-style shim exactly like the `IWindowNative` one already at
`crates/kaya/src/winui/mod.rs:8856-8867`. kaya already runs the bootstrapper
(it ships `Microsoft.WindowsAppRuntime.Bootstrap.dll`,
[REPO] `tools/deploy-win.py:131`), so the ordering precondition is already met.
The sibling `Windowing_GetWindowIdFromWindow` is available through the same
shim, which is how you get a `WindowId`/`AppWindow` from an HWND if you ever need
the non-XAML route.

### 3c. Making an HICON from an in-memory PNG — YES, with no file

[DOC] https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-createiconfromresourceex

    HICON CreateIconFromResourceEx(
      [in] PBYTE presbits, [in] DWORD dwResSize, [in] BOOL fIcon,
      [in] DWORD dwVer, [in] int cxDesired, [in] int cyDesired, [in] UINT Flags);

`presbits` is *"The DWORD-aligned buffer pointer containing the icon (RT_ICON) or
cursor (RT_CURSOR) resource bits"*; `dwVer` *"generally set to 0x00030000"*;
*"You should call `DestroyIcon` for icons … created with `CreateIconFromResourceEx`."*
It takes a POINTER TO MEMORY — there is no file anywhere in the signature.

The buffer must be **one icon image** (an `RT_ICON` entry), NOT a whole `.ico`
file (which is `ICONDIR` + `ICONDIRENTRY[]` + images). Two ways to satisfy that
from a runtime blob:

1. **PNG straight through.** [DOC] Raymond Chen, *"The format of icon resources,
   revisited"* (https://devblogs.microsoft.com/oldnewthing/20231025-00/?p=108925):
   *"And a third possibility (starting in Windows Vista) is a PNG-compressed
   image."* and *"The fact that the icon image source data can take the form of a
   PNG image gives you a sneaky way to load a PNG image as an icon: Load the PNG
   image into memory and pass it directly to `CreateIconFromResourceEx`!"*
   So a kaya wire blob that IS a PNG can go to `CreateIconFromResourceEx`
   unmodified. [INFER] This is the shortest possible path from blob to HICON:
   one call, no decoding, no temp file.
2. **Decode and build an ICONIMAGE / `CreateIconIndirect`.** Decode to BGRA
   (`Windows.Graphics.Imaging.BitmapDecoder`, or a Rust `png` crate), then either
   assemble a 32-bpp `BITMAPINFOHEADER` + XOR + AND buffer for
   `CreateIconFromResourceEx`, or make two HBITMAPs and call
   `CreateIconIndirect(ICONINFO{ fIcon = TRUE, hbmColor, hbmMask })`. More code,
   no advantage over (1) for a PNG blob. Worth knowing only because
   `CreateIconIndirect` is the route if the blob is ever not a PNG.

**So the chain is: wire blob (PNG bytes) → `CreateIconFromResourceEx` → HICON →
`Windowing_GetIconIdFromIcon` → `IconId` → `AppWindow.SetTaskbarIcon(IconId)` /
`SetIcon(IconId)`. Nothing on disk, nothing packaged.**

### 3d. THE TRAP AGAIN: kaya's bindings elide the IconId overloads

[MEASURED] `crates/kaya/src/winui/bindings.rs:5038-5042` (the `IAppWindow` vtable)
and `:5124-5138` (the `IAppWindow4` vtable):

    pub SetIcon: unsafe extern "system" fn(*mut c_void, *mut c_void) -> HRESULT,
    SetIconWithIconId: usize,
    …
    pub struct IAppWindow4_Vtbl {
        pub base__: windows_core::IInspectable_Vtbl,
        pub SetTaskbarIcon: unsafe extern "system" fn(*mut c_void, *mut c_void) -> HRESULT,
        SetTaskbarIconWithIconId: usize,
        pub SetTitleBarIcon: unsafe extern "system" fn(*mut c_void, *mut c_void) -> HRESULT,
        SetTitleBarIconWithIconId: usize,
    }

Every **string/path** overload is projected; every **IconId** overload is a
`usize` stub, because `Microsoft.UI.IconId` is not in the bindgen `--filter`
list. [MEASURED] `IconId` appears 3× in the whole 181,935-line file, all of them
inside those elided-name identifiers. [INFER] Adding `Microsoft.UI.IconId` to
`tools/winui-bindgen/src/main.rs`'s filter and regenerating is what unlocks the
byte route; without it the ONLY reachable overload is the one that demands a
.ico path on disk.

### 3e. AND kaya's windows have no icon at all today

[MEASURED] a tree-wide census found **no icon resource of any kind**: no
`winres`, no `embed-resource`, no `.rc`, no `RT_GROUP_ICON`, and zero `*.ico`
files outside `third_party/`. [REPO] `crates/kaya/Cargo.toml` and
`crates/kaya/build.rs` mention none.

[DOC] https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-geticon —
*"A window that has no icon explicitly set (with WM_SETICON) uses the icon for
the registered window class, and in this case DefWindowProc will return 0 for a
WM_GETICON message. If sending a WM_GETICON message to a window returns 0, next
try calling the GetClassLongPtr function for the window. If that returns 0 then
try the LoadIcon function."*

[DOC] The unpackaged case is a known sore spot:
microsoft/microsoft-ui-xaml#10417 reports that the `.csproj` `ApplicationIcon`
property does not reach an unpackaged WinUI 3 app's taskbar or title bar without
a runtime `AppWindow.SetIcon()` call, and
https://dev.duracellko.net/posts/2025/04/window-icon-in-winui3 says plainly
*"Running the application would still display the system icon in Windows
taskbar"* until `AppWindow.SetIcon` is called; its recipe loads the exe's own
embedded icon resource (id 32512) with `LoadIcon`, converts with
`GetIconIdFromIcon`, and calls `SetIcon`.

[INFER] **This is the strongest argument for the runtime-blob design on this
platform.** kaya's Windows guests do not run one executable: [REPO]
`tools/deploy-win.py:622-629` kills `<scene>.exe` (Rust), `<scene>_go.exe` (Go),
`python.exe`, `dotnet.exe`, `kaya-guests.exe`, `java.exe`. The fallback chain
above ends at *the host process's* icon — so with no runtime call the Python
guest wears the Python icon, the Java guest the JVM's, and the Rust guest
whatever a resourceless Rust exe gets. A build-time `.ico` embedded in kaya's
own artifacts cannot fix that, because kaya is a **library** loaded into someone
else's process in 6 of 8 languages. A runtime call from libkaya reaches all of
them identically, which is exactly what invariant 1 asks for.

---

## 4. AppUserModelID: what it actually controls (and what it does NOT)

[DOC] https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-setcurrentprocessexplicitappusermodelid

    SHSTDAPI SetCurrentProcessExplicitAppUserModelID([in] PCWSTR AppID);

Description: *"Specifies a unique application-defined Application User Model ID
(AppUserModelID) that identifies the current process **to the taskbar**. This
identifier allows an application to **group its associated processes and windows
under a single taskbar button**."*
Remarks: *"This method must be called during an application's initial startup
routine **before the application presents any UI** or makes any manipulation of
its Jump Lists."*

[DOC] https://learn.microsoft.com/en-us/windows/win32/shell/appids — what an
AUMID is FOR, from the concept page:

- **Taskbar grouping** — *"group its otherwise disparate windows under a single
  taskbar button"*. A window-level AUMID (via `SHGetPropertyStoreForWindow` +
  `PKEY_AppUserModel_ID`) overrides the process-level one.
- **Jump List identity** — the ID used with `ICustomDestinationList`,
  `IApplicationDocumentLists`, `IApplicationDestinations`, `SHAddToRecentDocs`.
- **Pinning identity** — *"This allows the taskbar to identify the proper
  shortcut to pin"*, and *"any use of an explicit AppUserModelID overrides the
  NoStartPage entry. If an explicit AppUserModelID is applied to a shortcut,
  process, or window, it becomes pinnable."*
- **Notification / toast identity** — [INFER, adjacent doc] unpackaged toast
  senders are keyed by AUMID; this page does not itself say so, so I mark it
  inferred rather than cite it here.

**Does it control the ICON? NO — not by itself.** The word "icon" appears in
this page in exactly one place, and it is a DIFFERENT mechanism: when an AUMID
is set **at the window level**, the app *"can provide the specifics of its
relaunch command for its taskbar button"* using
`System.AppUserModel.RelaunchCommand`,
**`System.AppUserModel.RelaunchDisplayNameResource`** and
**`System.AppUserModel.RelaunchIconResource`** — and the page immediately adds
*"If a shortcut exists to launch the application, an application should apply the
AppUserModelID as a property of the shortcut instead of using the relaunch
properties. In that case, the command line, **icon**, and text of the shortcut
are used to supply the same information as the relaunch properties."*

[INFER] So the honest statement is:

- `SetCurrentProcessExplicitAppUserModelID` alone: **grouping + jump-list +
  pinning identity. It changes no pixel.** The taskbar button still draws the
  window icon.
- The icon and display name that travel WITH an AUMID are
  `System.AppUserModel.RelaunchIconResource` and `RelaunchDisplayNameResource`,
  and both are **`"path,-resourceId"` strings pointing at a resource inside a
  file on disk** — a module + negative resource index. That is a FILE, not
  bytes. This is precisely the place where the "runtime blob" model runs out on
  Windows.
- The common overstatement — "set an AUMID and your taskbar icon is fixed" — is
  wrong. What is true is that a WRONG or ABSENT AUMID makes the shell's identity
  heuristics group your windows under the host executable (which for kaya's
  Python/Java/dotnet guests is exactly the wrong bucket), and that is a real
  problem for kaya — just not an *icon* problem.

---

## 5. Where does the identity NAME land on Windows?

Four distinct surfaces, and only the first is a runtime string:

| surface | fed by | file/registry needed? |
|---|---|---|
| **window caption text** | `GetWindowText` / `Window.Title` / `AppWindow.Title` | no |
| **taskbar button tooltip / thumbnail label** | the same window text | no |
| **ALT-TAB label** | the same window text | no |
| **AUMID display name** (pin label, jump-list header, Start MFU) | the shortcut's name, or `System.AppUserModel.RelaunchDisplayNameResource` = `"path,-id"` | **yes — a .lnk or a resource in a file** |

[DOC] `AppWindow.Title` — *"Gets or sets the displayed title of the app window…
The default is an empty string."*
[DOC] WM_GETICON page states the pairing for icons in the same breath: *"The
system displays the large icon in the ALT+TAB dialog, and the small icon in the
window caption."* [INFER] the label alongside those comes from the window text;
the shell has no other per-window name to read.

**Which of those does kaya already set?** [REPO] The window caption — and
deliberately, through exactly one writer. `crates/kaya/src/winui/mod.rs:1835-1843`:

    fn refresh_caption(core: &CoreState, window: u64) -> windows_core::Result<()> {
        let caption = HSTRING::from(window_caption(core, window));
        let target = winui_window(core, window)?;
        target.SetTitle(&caption)?;
        if let Some(text) = core.window_caption_texts.get(&window) { text.SetText(&caption)?; }
        Ok(())
    }

The doc comment above it is worth reading before touching identity here: it is
called **THE ONE CAPTION WRITER**, it composes the dirty marker into the string,
and it explicitly leaves `TitleBar.Title` EMPTY because
`TitleBar::UpdateTitle` does `appWindow.Title(titleText)` and would become a
second caption writer, silently clobbering the dirty marker
(mod.rs:2178-2188). **Any identity work that wants to set `TitleBar.Title` or
`TitleBar.Subtitle` collides with that decision head-on.** The identity NAME on
Windows should go through `refresh_caption`'s composition, not into the control.

[INFER] So on Windows the name is nearly free: kaya already owns the one string
that drives caption, taskbar tooltip and alt-tab. What an app-identity NAME buys
beyond today is (a) a default when a window has no title of its own, and (b) the
AUMID, which is a different, file-backed thing.

---

## 6. What a HARNESS can honestly READ BACK on Windows

kaya's rule here is already written down: [REPO] mod.rs:13328-13340,
`window_dirty` — *"THE REAL OS CAPTION, not core.window_dirty (D5). The failure
under test is a lowering that never reached the window, and a read of the flag
this backend just stored would agree with itself and prove nothing."* — with the
provenance that the channel was MEASURED (an external process rewrote the HWND
caption with `SetWindowTextW` and the in-guest harness read the new string back).
Identity reads have to clear the same bar. Three candidate reads, graded:

### (a) `TitleBar.IconSource` — an ECHO. Do not assert on it.
Reading the property back hands you the same `ImageIconSource` object kaya just
stored. Nothing decoded it, nothing drew it. A blob of sixteen zero bytes would
read back identically to a real PNG.

### (b) `ImageIconSource.ImageSource` → `BitmapImage.PixelWidth/PixelHeight` — REAL.
[REPO] kaya already does exactly this for the `Image` widget,
mod.rs:12982-13003 (`image_size`):

    let size = core.images[i].Source().ok()
        .and_then(|source| source.cast::<BitmapImage>().ok())
        .and_then(|bitmap| Some((bitmap.PixelWidth().ok()?, bitmap.PixelHeight().ok()?)));

with the comment *"The stored BitmapImage's decoded pixel size; no source (or a
source that never decoded) is the placeholder class, 0x0."* The number comes out
of the XAML **decoder**, not from kaya: a blob that is not a decodable image
reads `0x0`. So `"16x16"` proves *these bytes reached a decoder and decoded*.
It does NOT prove the icon is painted in the caption band — a real read of a
real fact, but a fact one layer short of the pixel.

### (c) `WM_GETICON` on the HWND — REAL, and it is what the shell reads.
[DOC] WM_GETICON: `ICON_SMALL`=0 (window caption), `ICON_BIG`=1 (ALT+TAB
dialog), `ICON_SMALL2`=2 (*"the small icon provided by the application. If the
application does not provide one, the system uses the system-generated icon"*).
`DefWindowProc` answers it out of USER32's own per-window state, so the value is
the system's, not a kaya-side cache — the same class of channel as the caption
read `window_dirty` already trusts. [REPO] kaya has the HWND already: the
`IWindowNative` shim at mod.rs:11050-11062 (`window_handle()`).
[INFER] `WM_GETICON` → `GetIconInfo` → `GetObject(BITMAP)` gives width/height/bpp
of the icon the shell will draw. Zero means *no window icon* and the doc names
the fallbacks to check next (`GetClassLongPtr`, then `LoadIcon`), so a
diagnostic here can discriminate rather than guess — which is what invariant 3
demands of a why-not.

### THE ONE LINK I COULD NOT VERIFY, stated as such
No document I found says whether `AppWindow.SetIcon`/`SetTaskbarIcon` writes
through `WM_SETICON` on the HWND. If it does, (c) reads it back honestly. If it
writes somewhere else in the windowing layer, `WM_GETICON` could stay 0 while
the taskbar shows the new icon — and a harness assertion on `WM_GETICON` would
then be a false RED, not a false green. **This needs one measurement on the VM
before any gate is written against it.**

[MEASURED — attempted, not completed] I wrote that probe: it starts the already
deployed `toolbar.exe` under `KAYA_SELFTEST=toolbar` with an appended
`settle 60000` (the exact pattern of
`crates/kaya/src/winui/title-centre-probe.sh`), then from the interactive session
reads `WM_GETICON` ×3, `GCLP_HICON`/`GCLP_HICONSM`, and finally round-trips a
synthesized in-memory 16×16 PNG through
`CreateIconFromResourceEx` → `WM_SETICON` → `WM_GETICON`. It lives at
`<scratchpad>/iconprobe/` (`icon-probe.ps1`, `guest.cmd`, `probe.cmd`,
`hidden.vbs`, `red16.png`, `scenes/toolbar.steps`).
**It did not run**: the harness's permission classifier refused the scp +
`schtasks` step. It would still need one more arm — a guest that actually calls
`AppWindow.SetIcon` — to close the question above.

**VM state, proven rather than asserted.** Nothing of mine was created:

    $ ssh akhil@192.168.64.2 'cmd /c "if exist C:\Users\akhil\kaya-icon-probe (echo DIR-EXISTS) else (echo DIR-ABSENT)"'
    DIR-ABSENT
    $ ssh akhil@192.168.64.2 'schtasks /query /fo csv /nh' | grep -ci "kaya_icon"
    0

The only commands that reached the VM were reads (`nc -z` reachability,
`dir C:\kaya /b`, `type C:\kaya\probe.cmd`, the two checks above). No process
was started, no file written, no task created, and the VM was never
power-cycled.

---

## VERDICT — what a runtime blob buys, per surface

**Caption (the XAML `TitleBar` band): FULLY, from bytes, today's SDK, and kaya is
one small step away.**
`TitleBar.IconSource` is in the pinned winmd (WinUI 2.2.1), typed
`Microsoft.UI.Xaml.Controls.IconSource`, present since Windows App SDK 1.7. The
subclass that takes bytes is `ImageIconSource`, whose `ImageSource` slot accepts
a `BitmapImage` fed by `SetSource(InMemoryRandomAccessStream)` — no URI, no
file, no packaged resource. `BitmapIconSource` is the trap: its only picture slot
is `UriSource : Windows.Foundation.Uri` and it would force a temp file. kaya
already writes this exact code for the `Image` widget's `Prop::Source` blob arm
(mod.rs:10438-10467), so the caption arm is that block plus
`ImageIconSource::new()` / `SetImageSource` / `SetIconSource`. The only real work
is the bindgen filter: `IconSource`/`ImageIconSource` are absent from
`tools/winui-bindgen/src/main.rs`, so `ITitleBar`'s vtable currently reads
`IconSource: usize, SetIconSource: usize`.
Caveat kaya-specific: the XAML `TitleBar` only exists while the window's caption
is promoted (`extended = holds > 0`, mod.rs:4076), so a caption icon delivered
this way appears only on windows that promoted commands. On the un-promoted
windows the SYSTEM caption is showing, and its icon is the AppWindow one below.

**Taskbar and ALT-TAB: FULLY, from bytes — but through Win32, not through XAML.**
Neither surface is the `TitleBar` control. Both are the WINDOW's icon.
`AppWindow.SetIcon(IconId)` and, since 1.7, `SetTaskbarIcon(IconId)` /
`SetTitleBarIcon(IconId)` all exist in the pinned metadata. An `IconId` comes
from an `HICON` via `Windowing_GetIconIdFromIcon` (flat export of
`Microsoft.Internal.FrameworkUdk.dll`, valid after `MddBootstrapInitialize`,
which kaya already calls), and an `HICON` comes from raw PNG bytes via
`CreateIconFromResourceEx` with no file at all — PNG-encoded icon images have
been legal since Vista and Chen's post says outright that you can hand the PNG
straight to that function. Two changes are needed: add `Microsoft.UI.IconId` to
the bindgen filter (every `…WithIconId` overload is currently elided to `usize`,
leaving only the .ico-path overloads reachable), and add a FrameworkUdk
`GetProcAddress` shim next to the existing `IWindowNative` one.
This is also the surface with the most to gain, because kaya today ships **no
icon resource anywhere** and is a library inside python.exe / java.exe /
dotnet.exe for six of its eight languages — a build-time `.ico` cannot reach
those hosts, and a runtime call reaches all of them the same way.

**What still needs a file on disk or a package — be honest about these three:**
1. `AppWindow.SetIcon(String)` / `SetTaskbarIcon(String)` — .ico path only. Not
   a route for bytes; the `IconId` overload is the route.
2. **The AUMID's icon and display name.** `System.AppUserModel.RelaunchIconResource`
   and `RelaunchDisplayNameResource` are `"path,-resourceId"` strings naming a
   resource inside a file. This is the pinned-to-taskbar / jump-list-header
   identity, and no in-memory blob can supply it. `SetCurrentProcessExplicitAppUserModelID`
   by itself buys grouping, jump-list identity and pinnability — **it draws
   nothing** — and calling it is still worth doing so kaya's windows stop
   grouping under `python.exe`.
3. Anything that must survive the process: Start-menu tile, installed-app
   listing, file-association icon. Those are shortcut/package territory.

**The name is nearly free.** Caption text, taskbar tooltip and ALT-TAB label are
all the one window-text string, and kaya already owns it through
`refresh_caption` — the single caption writer that also composes the dirty
marker. An identity name should feed THAT function, and must NOT be written into
`TitleBar.Title`: mod.rs:2178-2188 records that the control writes
`appWindow.Title(...)` itself and would silently become a rival author of the
dirty marker. Only the AUMID display name lands anywhere else, and that one is
file-backed (item 2).

**The one open question before any gate is written:** whether
`AppWindow.SetIcon`/`SetTaskbarIcon` routes through `WM_SETICON`, i.e. whether
`WM_GETICON` is an honest read-back of what the shell will draw. The probe is
written and sitting in the scratchpad; it needs a run on the VM plus a guest arm
that actually calls `SetIcon`. Until that is measured, the safe harness read is
the decoded-pixel-size one (`ImageIconSource → BitmapImage.PixelWidth`), which is
real but stops one layer short of the caption pixel, and `TitleBar.IconSource`
itself must not be asserted on at all — it is a pure echo.
