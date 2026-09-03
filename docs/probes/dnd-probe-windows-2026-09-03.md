# Windows drag probes 1 and 2 (docs/dnd-plan.md §2) — measurements on the VM

Written progressively while the probes ran, 2026-09-03. The VM is
akhil@192.168.64.2 (Windows 11 build 10.0.26200.9168, arm64, one display
that the interactive session reports as 1280x800 at dpi 96, .NET SDK
10.0.301, Windows App Runtime 2.2.0 installed by tools/deploy-win.py).

## Setup — what was built, and why in this shape

Two probe apps under `tools/win/dragprobe`, both C#, both built ON THE
GUEST with `dotnet build` (the VM already builds the C# guest tier that
way, tools/deploy-win.py):

- `winui/` — **a real WinUI 3 desktop app**, unpackaged
  (`WindowsPackageType=None`, the shape kaya's own backend runs in).
  WinUI did NOT prove too heavy: with `DISABLE_XAML_GENERATED_MAIN` and a
  code-built visual tree there is no XAML markup and no XAML compiler in
  the picture, and `dotnet build` restored Microsoft.WindowsAppSDK 2.2.0
  and produced an arm64 exe in 25 seconds. The window has two zones: a
  **XAML drag source** (`CanDrag=true`, `DragStarting` fills a
  `DataPackage`) and a **drop zone** served either by XAML
  (`AllowDrop` + `DragEnter`/`DragOver`/`Drop`) or, with
  `KAYA_DP_MODE=ole`, by classic OLE (`RevokeDragDrop` on the window's own
  HWND, then `RegisterDragDrop` with the probe's `IDropTarget`).
- `stock/` — a plain Win32 witness in another process: a WinForms window
  whose drop target is `RegisterDragDrop` + `IDropTarget` (it enumerates
  the `IDataObject`'s `FORMATETC` and reads the bytes) and whose source is
  `DoDragDrop` over a hand-rolled `IDataObject` offering a registered
  clipboard format by name. No WinRT in that process at all.

The source side offers the custom id two ways, because Microsoft
documents `DataPackage.SetData` per flavour:

- `SetData("dev.kaya/note", "kaya-note-from-winrt")` — a plain string
- `SetData("dev.kaya/note.stream", <InMemoryRandomAccessStream>)` — the
  RandomAccessStream the reference page names

Both are what kaya's `custom(id, bytes)` would have to ride.

Driving: real input in the guest's interactive session, the caption
probe's proven shape (`mouse_event` absolute moves, press, a stepped path,
release) from `drive.ps1`, scheduled with `schtasks /it` (an ssh session
has its own window station — docs/traps.md). `run.py` on the mac ships,
schedules, polls and reads the logs back.

### Two facts about the VM that bound what could be measured

1. **The interactive session's screen is 1280x800 at dpi 96, scale 1.**
   (`DRIVE scenario ... begins (screen 1280x800 ...)`, `winui READY ...
   dpi=96 scale=1`.) An ssh session reports 1024x768; the probe's windows
   are placed from inside the interactive session.
2. **UAC IS DISABLED on this VM** — `HKLM\...\Policies\System\EnableLUA =
   0x0`. Every process, Explorer included, runs with the full
   administrator token, so a scheduled task WITHOUT `/rl highest` already
   reports `elevated=True`:

   ```
   09:37:11.343 DRIVE scenario c-same-process begins (screen 1280x800, elevated=True)
   ```

   This is decisive for the elevation half of probe 2 and is discussed
   under measurement 6.

A probe artifact worth writing down, since it will bite the next person
who stands a WinUI app up this way: `XamlControlsResources` could not be
merged in this unpackaged, code-only app —

```
09:37:12.090 winui XamlControlsResources FAILED: COMException: Unspecified error
Cannot find a resource with the given key: AcrylicBackgroundFillColorDefaultBrush.
```

— which is exactly the tiered failure `crates/kaya/src/winui/mod.rs`'s
`require_control_resources` describes (ms-appx resolves against the EXE's
directory). Nothing in this probe needs a themed control: Grid, Border and
TextBlock render without default styles, and every drag event below fired
normally. It is noted so no one reads it as a drag finding.

## Measurement 1 (control) — XAML source to XAML destination, same process

`run.py akhil@192.168.64.2 c-same-process`. This is the control for
everything after it: if a real-input drag cannot be driven at all, every
red below would be the driver's fault.

```
09:37:13.679 winui READY mode=xaml hwnd=0x123063e client-origin=8,31 dpi=96 scale=1
09:37:13.682 winui ZONE source x=16 y=39 w=468 h=315 centre=250,196
09:37:13.683 winui ZONE drop x=16 y=370 w=468 h=314 centre=250,527
09:37:13.936 DRIVE drag 250,196 -> 250,527 in 30 steps
09:37:15.012 winui DragStarting: SetText + SetData("dev.kaya/note", string) + SetData("dev.kaya/note.stream", IRandomAccessStream); requested=Copy, Move
09:37:16.438 winui XAML DragEnter: formats=[Preferred DropEffect, Text, dev.kaya/note, dev.kaya/note.stream] storageitems=False at 242,342
09:37:18.175 winui XAML Drop on zone: formats=[Preferred DropEffect, Text, dev.kaya/note, dev.kaya/note.stream] storageitems=False text=True
09:37:18.179 winui XAML Drop: "dev.kaya/note" -> string "kaya-note-from-winrt"
09:37:18.181 winui XAML Drop: "dev.kaya/note.stream" -> IRandomAccessStream size=22 len=22 hex=6b6179612d6e6f74652d73747265616d2d6279746573 utf8="kaya-note-stream-bytes"
09:37:18.186 winui XAML Drop: text="kaya drag text"
09:37:18.192 winui DropCompleted: result=Copy
```

**Result: a synthesized mouse drag drives a real WinUI 3 XAML drag end to
end**, `DragStarting` through `DragOver` through `Drop` through
`DropCompleted` — so D10's "Windows: SendInput from the leg's own
launcher, the caption probe's proven shape" is measured, not assumed. Both
custom-id flavours survive in-process, and the source learns the outcome
(`DropCompleted: result=Copy`), which is the `drag_ended` occurrence D1
needs.

## PROBE 1, forward — WinRT `DataPackage.SetData` to a Win32 OLE reader in another process

`run.py akhil@192.168.64.2 a-winrt-to-win32`. The WinUI window (left) is
dragged from its XAML source zone into the stock Win32 window (right),
whose OLE `IDropTarget` enumerates the `IDataObject` and reads the bytes.

```
09:40:14.995 stock READY mode=target hwnd=0x44e02b2 rect=540,40,1000,640 dpi=96
09:40:15.012 stock RegisterDragDrop hr=0x00000000
09:40:19.320 stock OLE DragEnter at 545,278 keys=1 allowed=3
09:40:19.328 stock OLE DragEnter: formats=[Preferred DropEffect(cf=49258,tymed=TYMED_HGLOBAL,aspect=DVASPECT_CONTENT), CF_UNICODETEXT(cf=13,tymed=TYMED_HGLOBAL,aspect=DVASPECT_CONTENT), dev.kaya/note(cf=49573,tymed=TYMED_ISTREAM,aspect=DVASPECT_CONTENT), dev.kaya/note.stream(cf=49624,tymed=TYMED_ISTREAM,aspect=DVASPECT_CONTENT), DropDescription(cf=49310,tymed=TYMED_HGLOBAL,aspect=DVASPECT_CONTENT)]
09:40:21.019 stock OLE Drop at 772,341
09:40:21.029       (ISTREAM Stat cbSize=42, read 42 bytes)
09:40:21.030 stock OLE custom "dev.kaya/note" (cf=49573): len=42 hex=6b006100790061002d006e006f00740065002d0066007200.. utf8="k.a.y.a.-.n.o.t.e.-.f.r.o.m.-.w.i.n.r.t..."
09:40:21.031       (ISTREAM Stat cbSize=22, read 22 bytes)
09:40:21.031 stock OLE custom "dev.kaya/note.stream" (cf=49624): len=22 hex=6b6179612d6e6f74652d73747265616d2d6279746573 utf8="kaya-note-stream-bytes"
09:40:21.032 stock OLE CF_UNICODETEXT: "kaya drag text"
09:40:21.033 stock OLE CF_HDROP: ABSENT (QueryGetData=0x8004006a)
09:40:21.034 stock OLE Drop done
09:40:21.040 winui DropCompleted: result=Copy
```

**VERDICT: YES — a custom clipboard format written through
`DataPackage.SetData` DOES cross the process boundary through a WinRT
drag, name intact and bytes intact.** The documented asymmetry did not
bite in this direction on Windows 11 26200 with Windows App SDK 2.2. Four
mechanism facts the arm has to carry, each of which cost a wrong reading
before it was measured:

1. **The id becomes a registered clipboard format under its exact
   string.** `RegisterClipboardFormatW("dev.kaya/note")` in the receiving
   process returns the same 49573 the enumeration reports. kaya's
   MIME-shaped ids ride verbatim, no mangling, no case change.
2. **The custom formats arrive as `TYMED_ISTREAM`, and ONLY that.** Text
   arrives as `TYMED_HGLOBAL`, custom does not. A Win32 reader that asks
   for HGLOBAL alone finds nothing; that is the shape most hand-written
   Win32 readers have, and it is what kaya's own Win32 side would have
   been written as. (`crates/kaya/src/winui/mod.rs`'s clipboard arm reads
   `GlobalLock` handles.)
3. **Ask for one TYMED per `GetData` call.** `TYMED_HGLOBAL |
   TYMED_ISTREAM` in one FORMATETC was refused by the WinRT-side data
   object with `E_INVALIDARG` — *for every format including
   CF_UNICODETEXT* — which the probe's first run misread as "the custom
   format is absent". A reader that ORs its tymeds cannot tell a refused
   request from an absent format.
4. **The delivered stream arrives seeked to its end.** The probe's second
   run read 0 bytes from a stream whose `Stat` says 42; a `Seek(0)` before
   reading is mandatory. Again a false "absent" if unhandled.

And the flavours differ in what the bytes ARE:

| what the source called | what the Win32 reader gets |
|---|---|
| `SetData("dev.kaya/note", "kaya-note-from-winrt")` (a string) | 42 bytes = the string as **UTF-16LE with its NUL** |
| `SetData("dev.kaya/note.stream", <InMemoryRandomAccessStream>)` | 22 bytes = **exactly the bytes written**, no header, no terminator |

For kaya's `custom(id, bytes)` — a byte payload, not a string — the
stream flavour is the one that is byte-exact and the one the arm must use.

## PROBE 1, reverse — a Win32 OLE source with a registered custom format, read by WinRT

`run.py akhil@192.168.64.2 b-win32-to-winrt`. The stock window (left) is an
OLE drag source offering `RegisterClipboardFormatW("dev.kaya/note")` as an
HGLOBAL plus CF_UNICODETEXT; the WinUI window (right) has `AllowDrop=true`
on both its drop zone and its root Grid.

```
09:41:15.311 winui ZONE source x=536 y=39 w=468 h=315 centre=770,196
09:41:15.312 winui ZONE drop  x=536 y=370 w=468 h=314 centre=770,527
09:41:15.396 DRIVE drag 240,340 -> 770,527 in 30 steps
09:41:15.993 stock DoDragDrop begin: custom "dev.kaya/note" cf=49573 len=24 hex=6b6179612d6e6f74652d66726f6d2d77696e33322d6f6c65 utf8="kaya-note-from-win32-ole" + CF_UNICODETEXT
09:41:19.605 src IDropSource: button up -> drop
09:41:19.607 stock DoDragDrop returned hr=0x00040100 effect=0
```

and the WinUI log for that run ends at its READY/ZONE lines: **not one
`DragEnter`, `DragOver` or `Drop` fired.** `effect=0` is
`DROPEFFECT_NONE` — nobody took it.

**VERDICT: NO — `GetDataAsync("dev.kaya/note")` never gets the chance.
XAML's `AllowDrop` does not see a cross-process drag at all**, so the
question "does the custom id survive Win32 -> WinRT" cannot even be put to
it through XAML. This is `UIElement.AllowDrop`'s own Remarks ("A UI
element can't be a drop target for any drag-drop action that begins from
outside the current app") behaving exactly as written, and it is
microsoft-ui-xaml #10119 reproduced on Windows 11 26200 with Windows App
SDK 2.2.

### The control that makes that a finding rather than a broken driver

`run.py akhil@192.168.64.2 g-win32-to-win32` — the SAME source, into a
plain Win32 OLE target in a third process:

```
09:42:16.016 stock OLE DragEnter: formats=[dev.kaya/note(cf=49573,tymed=TYMED_HGLOBAL,aspect=DVASPECT_CONTENT), CF_UNICODETEXT(cf=13,tymed=TYMED_HGLOBAL,aspect=DVASPECT_CONTENT)]
09:42:17.720 stock OLE custom "dev.kaya/note" (cf=49573): len=24 hex=6b6179612d6e6f74652d66726f6d2d77696e33322d6f6c65 utf8="kaya-note-from-win32-ole"
09:42:17.721 stock OLE CF_UNICODETEXT: "kaya stock text"
09:42:17.741 stock DoDragDrop returned hr=0x00040100 effect=1
```

The source is sound and the drive is sound; the XAML receiver is the
finding.

## PROBE 1, reverse, through the OLE fallback — and WHICH HWND has to carry it

`run.py akhil@192.168.64.2 h-win32-to-ole-winui`. Same Win32 source; the
WinUI window runs with `KAYA_DP_MODE=ole`, which registers kaya's own
`IDropTarget` on the window's HWNDs instead of using `AllowDrop`.

```
09:46:12.959 winui OLE route: OleInitialize hr=0x00000000
09:46:12.975 winui OLE route: hwnd=0xaa4034a class=Microsoft.UI.Content.DesktopChildSiteBridge RevokeDragDrop hr=0x80040100 RegisterDragDrop hr=0x00000000
09:46:12.978 winui OLE route: hwnd=0xd3900c6 class=WinUIDesktopWin32WindowClass  RevokeDragDrop hr=0x80040100 RegisterDragDrop hr=0x00000000
09:46:19.365 winui[WinUIDesktopWin32WindowClass] OLE DragEnter at 523,440 keys=1 allowed=3
09:46:19.424 winui[WinUIDesktopWin32WindowClass] OLE DragLeave (after 2 DragOver)
09:46:19.429 winui[Microsoft.UI.Content.DesktopChildSiteBridge] OLE DragEnter at 540,446 keys=1 allowed=3
09:46:21.512 winui[Microsoft.UI.Content.DesktopChildSiteBridge] OLE Drop at 772,528
09:46:21.523 winui[Microsoft.UI.Content.DesktopChildSiteBridge] OLE custom "dev.kaya/note" (cf=49573): len=24 hex=6b6179612d6e6f74652d66726f6d2d77696e33322d6f6c65 utf8="kaya-note-from-win32-ole"
09:46:21.528 winui[Microsoft.UI.Content.DesktopChildSiteBridge] OLE CF_UNICODETEXT: "kaya stock text"
09:46:21.530 stock DoDragDrop returned hr=0x00040100 effect=1
```

**VERDICT: YES through OLE.** The custom id crosses Win32 -> WinUI 3
intact, and the source learns the outcome (`effect=1`, copy). Three
mechanism facts:

1. **The drop lands on the CHILD island window, class
   `Microsoft.UI.Content.DesktopChildSiteBridge`, not on the top-level
   `WinUIDesktopWin32WindowClass`.** The top-level target saw only the
   window frame's few pixels and then a `DragLeave`. A fallback registered
   on the top-level HWND alone would look like it worked in a corner and
   fail everywhere the content is. OLE does not walk up the parent chain
   for you.
2. **`OleInitialize` first.** `RegisterDragDrop` on the XAML UI thread
   answered `0x8007000e` (E_OUTOFMEMORY) until `OleInitialize` was called
   on it: XAML's thread has only `CoInitializeEx`. That HRESULT names
   nothing about the real cause, so it is written down here.
3. **XAML has no drop target of its own to displace.** `RevokeDragDrop`
   answered `0x80040100` (DRAGDROP_E_NOTREGISTERED) on BOTH windows in
   this mode. See the registration census below for what `AllowDrop=true`
   changes.

## The other half of the reverse question — XAML DOES receive a cross-process drag, if the SOURCE is WinRT

`run.py akhil@192.168.64.2 k-winrt-to-winrt`. Two copies of the WinUI
probe, in two processes: the left one's XAML source dragged into the right
one's `AllowDrop` zone. This is kaya-window-to-kaya-window.

```
09:55:04.455 winui  DragStarting: SetText + SetData("dev.kaya/note", string) + SetData("dev.kaya/note.stream", IRandomAccessStream); requested=Copy, Move
09:55:05.904 winui2 XAML DragEnter: formats=[Preferred DropEffect, Text, dev.kaya/note, dev.kaya/note.stream] storageitems=False at 17,353
09:55:07.603 winui2 XAML Drop on zone: formats=[Preferred DropEffect, Text, dev.kaya/note, dev.kaya/note.stream] storageitems=False text=True
09:55:07.629 winui2 XAML Drop: "dev.kaya/note" -> string "kaya-note-from-winrt"
09:55:07.644 winui2 XAML Drop: "dev.kaya/note.stream" -> IRandomAccessStream size=22 len=22 hex=6b6179612d6e6f74652d73747265616d2d6279746573 utf8="kaya-note-stream-bytes"
09:55:07.646 winui2 XAML Drop: text="kaya drag text"
09:55:07.666 winui  DropCompleted: result=Copy
```

(The two processes write separate logs, `log-winui.txt` and
`log-winui2.txt`; the `winui2` tag above marks the second one's lines.)

**So `AllowDrop`'s "can't be a drop target for any drag that begins
outside the current app" is not what the platform does — the real rule is
narrower and it is the one that matters:** a XAML drop target receives
drags from the WinRT world, in-process or cross-process, and receives
nothing from the classic OLE world (Explorer, and every Win32 app). Both
custom-id flavours survive the process boundary intact in the WinRT-to-
WinRT case, and the source still learns the outcome.

## The mechanism, measured: what `AllowDrop=true` actually registers

`run.py akhil@192.168.64.2 i-xaml-registration-census`. No drag at all —
the app enumerates its own window tree and asks each HWND whether a drop
target is registered, non-destructively (`RegisterDragDrop` answers
`DRAGDROP_E_ALREADYREGISTERED` when one is; where it succeeds the probe
revokes its own again, leaving the window as it was found). The window has
`AllowDrop=true` on the drop Border AND on the root Grid.

```
09:59:48.730 winui CENSUS window tree: 4 window(s)
09:59:48.735 winui CENSUS hwnd=0xb0a034a class=WinUIDesktopWin32WindowClass          RegisterDragDrop hr=0x00000000 -> NO target was registered here
09:59:48.736 winui CENSUS hwnd=0x3c205ac class=InputNonClientPointerSource           RegisterDragDrop hr=0x00000000 -> NO target was registered here
09:59:48.738 winui CENSUS hwnd=0x30905de class=Microsoft.UI.Content.DesktopChildSiteBridge RegisterDragDrop hr=0x00000000 -> NO target was registered here
09:59:48.738 winui CENSUS hwnd=0x4e2055c class=InputSiteWindowClass                  RegisterDragDrop hr=0x00000000 -> NO target was registered here
```

**`AllowDrop` registers NO OLE drop target on ANY of the four windows a
WinUI 3 desktop window is made of.** That is the whole explanation for
#10119 and for measurements B and D: XAML's drop side lives in the WinRT
`CoreDragDropManager` world attached to the content island, and a classic
OLE drag — which is what Explorer and every Win32 app send — has nothing
to arrive at. It is not a bug in the hit-testing; there is no door.

## PROBE 2 — an Explorer file drop onto a WinUI 3 window

### 2a. Through XAML `AllowDrop`: NO

`run.py akhil@192.168.64.2 d-explorer-to-xaml` (twice, plus once
`--elevated`). Explorer is opened on `C:\kaya\dragprobe\files`, the item is
found by UI Automation, and the drag is driven from its centre into the
XAML drop zone:

```
09:53:23.543 DRIVE   item 'note.txt' rect=182,167,598,24
09:53:23.552 DRIVE dragging explorer item 'note.txt'
09:53:23.555 DRIVE drag 481,179 -> 770,527 in 40 steps
09:53:28.519 DRIVE released at 770,527
```

and the WinUI log for that run ends at

```
09:53:18.350 winui ZONE source x=536 y=39 w=468 h=315 centre=770,196
09:53:18.351 winui ZONE drop x=536 y=370 w=468 h=314 centre=770,527
```

**No `DragEnter`, no `DragOver`, no `Drop`, in any of the three runs
(twice unelevated-by-flag, once `/rl highest`).** microsoft-ui-xaml
#10119 reproduced on Windows 11 26200 with Windows App SDK 2.2.

### 2b. Through OLE `RegisterDragDrop` on the window's own HWND: YES

`run.py akhil@192.168.64.2 e-explorer-to-ole` (twice, plus once
`--elevated`):

```
09:52:11.235 winui[Microsoft.UI.Content.DesktopChildSiteBridge] OLE DragEnter at 532,240 keys=1 allowed=7
09:52:11.236 winui[...DesktopChildSiteBridge] OLE DragOver #1 at 532,240 keys=1
09:52:13.929 winui[...DesktopChildSiteBridge] OLE DragOver #90 at 770,527 keys=1
09:52:14.436 winui[...DesktopChildSiteBridge] OLE Drop at 772,528
09:52:14.437 winui[...DesktopChildSiteBridge] OLE Drop: formats=[Shell IDList Array(cf=49288,…), UsingDefaultDragImage(…), DragImageBits(…), DragContext(…), DragSourceHelperFlags(…), InShellDragLoop(…), CF_HDROP(cf=15,tymed=TYMED_HGLOBAL,…), FileName(cf=49158,…), FileContents(cf=49274,tymed=TYMED_ISTREAM,…), FileNameW(cf=49159,…), FileGroupDescriptorW(cf=49292,…), ZoneIdentifier(cf=49314,…)]
09:52:14.449 winui[...DesktopChildSiteBridge] OLE CF_HDROP: 1 path(s): C:\kaya\dragprobe\files\note.txt
```

**The file arrives, as `CF_HDROP`, with its real path** — the exact shape
`crates/kaya/src/winui/mod.rs`'s `parse_dropfiles` already reads for the
clipboard. `allowed=7` is COPY|MOVE|LINK offered by the shell.

The control that makes this a WinUI finding rather than a lucky drive:
`f-explorer-to-stock` drove the identical Explorer drag into a plain Win32
window and got the identical format list and
`CF_HDROP: 1 path(s): C:\kaya\dragprobe\files\note.txt`.

One flake worth recording: the FIRST `e-explorer-to-ole` run ended in
`OLE DragLeave after 40 DragOver` with the pointer still inside the window
and no drop. The next two runs (one of them `--elevated`) completed
normally, and the instrument that would name a cause — the cursor position
at the leave — was added after it, so the cause is unmeasured. It is
recorded because a drag leg that flakes once in three would be a lane
problem, and this is the only sighting.

### 2c. Both routes at once: they coexist

The design question the two above raise is whether kaya must CHOOSE. It
does not. `KAYA_DP_MODE=both` sets `AllowDrop=true` AND registers kaya's
own `IDropTarget` on the island HWND:

- `l-winrt-to-both` — a WinRT drag from a SECOND WinUI process:
  `winui XAML DragEnter` … `winui XAML Drop: "dev.kaya/note" -> string
  "kaya-note-from-winrt"`. XAML took it; the registered OLE target on the
  island never fired.
- `m-explorer-to-both` — an Explorer file drag into the same window:
  `winui[Microsoft.UI.Content.DesktopChildSiteBridge] OLE CF_HDROP: 1
  path(s): C:\kaya\dragprobe\files\note.txt`. The OLE target took it; XAML
  never fired.

**Each world's drags go to its own receiver, in one window, at the same
time.**

### 2d. The elevation half: NOT MEASURABLE ON THIS VM, and here is the proof

`HKLM\...\Policies\System\EnableLUA = 0x0`. Every process on the VM runs at
the same integrity level, measured rather than assumed — the driver reads
the token of itself, of Explorer, and of each probe it starts:

```
10:00:07.993 DRIVE driver integrity: S-1-16-12288 (high)
10:00:08.007 DRIVE explorer.exe (pid 6012) integrity: S-1-16-12288 (high)
10:00:08.571 DRIVE started …\KayaDragProbe.exe (pid 18180) …; integrity S-1-16-12288 (high)
```

So `schtasks /it` and `schtasks /it /rl highest` produce the SAME token,
and both `d` and `e` were run both ways with identical outcomes. There is
no UIPI barrier to cross on this machine, and therefore nothing this probe
can say about a genuinely non-elevated app receiving a drop from an
elevated one or the reverse.

An attempt to manufacture the asymmetry without touching the VM's
configuration — `j-medium-source-to-ole`, which launches the OLE source
under a SAFER restricted token (`runas /trustlevel:0x20000`) — did not
produce one either:

```
09:57:11.118 DRIVE restricted source pid 11716 integrity: S-1-16-12288 (high)
09:57:16.414 winui[...DesktopChildSiteBridge] OLE custom "dev.kaya/note" (cf=49573): len=24 … utf8="kaya-note-from-win32-ole"
```

A SAFER "basic user" token drops privileges and the Administrators SID but
NOT the integrity label when UAC is off, so the drop simply succeeded.
Measuring UIPI here means setting `EnableLUA=1` and rebooting the VM,
which this probe deliberately did not do: the VM is shared with the
windows lane, and rebooting it over ssh is forbidden (docs/traps.md).

## What this means for docs/dnd-plan.md D9/D10 and the WinUI arm

**The route, direction by direction.** The WinUI arm is not a choice
between XAML and OLE; it is both, each on the side the measurement gives
it:

| direction | route that works | what was measured |
|---|---|---|
| kaya source -> foreign Win32/Explorer-world app | **XAML** `CanDrag` + `DragStarting` + `DataPackage` | measurement A: a stock OLE `IDropTarget` in another process enumerated `dev.kaya/note` and read its bytes; `DropCompleted: result=Copy` came back to the source |
| kaya source -> another kaya (WinUI) window, same or other process | **XAML** both ends | measurements 1 and K |
| foreign Win32 app or Explorer -> kaya destination | **OLE** `RegisterDragDrop` on the ISLAND HWND | measurements E, H, M; XAML gets nothing (B, D, and the census) |
| another kaya (WinUI) window -> kaya destination | **XAML** `AllowDrop` | measurement K, and L proves it still wins when OLE is also armed |

So D9's "a stock Win32 reader on the VM" as the Windows foreign witness is
buildable exactly as written for the OUTBOUND half, and the INBOUND half
needs the OLE fallback D9 already names as the alternative — not as a
fallback, but as the only route, and the plan can say so now instead of
hedging.

**Six mechanism facts the arm has to carry.**

1. **Register on `Microsoft.UI.Content.DesktopChildSiteBridge`, the child
   island window — not on the top-level `WinUIDesktopWin32WindowClass`.**
   Registering on the top-level alone gets DragEnter for the frame border
   and a DragLeave the moment the pointer reaches the content. Register on
   both (the probe does) and the island's target is the one that drops.
   The window tree is four HWNDs: top-level,
   `InputNonClientPointerSource`, `DesktopChildSiteBridge`,
   `InputSiteWindowClass`.
2. **`OleInitialize` on the XAML UI thread first.** Without it
   `RegisterDragDrop` answers `0x8007000e` (E_OUTOFMEMORY), which names
   nothing about the cause. XAML's thread calls only `CoInitializeEx`.
3. **kaya's `custom(id, bytes)` must ride `SetData(id,
   IRandomAccessStream)`, not `SetData(id, string)`.** The string flavour
   crosses as UTF-16 with a NUL; the stream flavour crosses byte-exact.
4. **On the reading side, custom formats arrive as `TYMED_ISTREAM`.** kaya's
   existing Win32 clipboard reader is HGLOBAL-shaped
   (`GlobalLock`/`GlobalSize`); the drop reader needs the ISTREAM arm, must
   ask for ONE tymed per `GetData` (an OR was refused `E_INVALIDARG` by the
   WinRT-side data object), and must `Seek(0)` before reading — the stream
   arrives at its end.
5. **A drop from Explorer is `CF_HDROP` with real paths**, so D6's "dropped
   files are picked files" lands on `parse_dropfiles`, which the clipboard
   arm already ships, and the paths go into the same picked table
   `kaya_open_picked` redeems. The shell also offers `Shell IDList Array`,
   `FileNameW`, `FileGroupDescriptorW` and `FileContents`; none is needed.
6. **Both routes coexist in one window**, so the arm arms both
   unconditionally rather than switching on anything.

**For D10 (the harness verb).** The Windows half of "drive real input" is
measured, not assumed: `mouse_event` absolute moves with a press, a
stepped path and a release, from a `schtasks /it` task, drove a real XAML
`CanDrag` source through `DragStarting`, `DragOver`, `Drop` and
`DropCompleted` (measurement 1), drove a real OLE `DoDragDrop` source
(measurement G), and drove a real Explorer file drag (measurement F). The
shape that worked: 500ms settle, `LEFTDOWN`, 300ms, six small moves inside
the source to pass the drag threshold, then 30-40 steps at 60ms, a 400ms
pause on the target, one 2px nudge, `LEFTUP`. A drag verb can be a port of
`drive.ps1`'s `Drag` function.

Two cautions for the leg: an Explorer-sourced drag flaked once in three
with a `DragLeave` and no drop (§2b), and the drop point must be inside
the ISLAND (the frame border belongs to the top-level window and produces
DragEnter/DragLeave without a drop).

**What is still unmeasured.** (a) UIPI/elevation, for the reason in §2d —
this needs a VM with `EnableLUA=1`, i.e. a reboot the probe was forbidden
to take. (b) Whether XAML's `DragEventArgs.GetDeferral` can hold a drop
open (the plan's §3 bounded-wait shape); the probe takes a deferral and
completes it immediately, so the deadline behaviour is untested. (c) The
`DragUI`/badge surface, deliberately (D11 calls it cosmetic).

## Reproducing this

```
tools/win/dragprobe/run.py akhil@192.168.64.2 <scenario> [--build] [--elevated]
```

| scenario | what it measures |
|---|---|
| `c-same-process` | control: XAML source -> XAML destination, one process |
| `a-winrt-to-win32` | PROBE 1 forward: DataPackage custom id -> stock OLE reader |
| `b-win32-to-winrt` | PROBE 1 reverse through XAML: nothing arrives |
| `g-win32-to-win32` | control for the above: the same OLE source into a Win32 target |
| `h-win32-to-ole-winui` | PROBE 1 reverse through the OLE route on the WinUI HWND |
| `i-xaml-registration-census` | what `AllowDrop` registers (nothing) |
| `d-explorer-to-xaml` | PROBE 2 through XAML: nothing arrives |
| `e-explorer-to-ole` | PROBE 2 through OLE: CF_HDROP arrives |
| `f-explorer-to-stock` | control for PROBE 2: the same drag into a plain Win32 window |
| `k-winrt-to-winrt` | XAML -> XAML across processes: works |
| `l-winrt-to-both` | with both routes armed, a WinRT drag goes to XAML |
| `m-explorer-to-both` | with both routes armed, an Explorer drop goes to OLE |
| `j-medium-source-to-ole` | the UIPI attempt; produced no integrity asymmetry |

Files: `tools/win/dragprobe/{run.py, drive.ps1, winui/, stock/, shared/}`.
The two apps build on the guest with `dotnet build`; nothing is built on
the mac.

## Cleanup, proven

Everything this probe started is stopped and everything it staged is
gone. After the last run:

```
$ ssh akhil@192.168.64.2 'tasklist /fi "IMAGENAME eq KayaDragProbe.exe" & tasklist /fi "IMAGENAME eq StockOle.exe"'
INFO: No tasks are running which match the specified criteria.
INFO: No tasks are running which match the specified criteria.

$ ssh akhil@192.168.64.2 'tasklist | findstr /i "KayaDragProbe StockOle dotnet runas"'
(no output)

$ ssh akhil@192.168.64.2 'schtasks /query /fo table /nh | findstr /i kaya_dp'
(no output)

$ ssh akhil@192.168.64.2 'dir /b C:\kaya\dragprobe'
File Not Found
```

The staging directory (41,693,204 bytes of build output) was removed with
`rmdir /s /q C:\kaya\dragprobe`; nothing else under `C:\kaya` was touched.
The driver closes the Explorer windows it opens at the end of every
scenario, and a window census run in the interactive session afterwards
lists only the desktop:

```
visible windows in the interactive session:
  Xaml_WindowedPopupClass | PopupHost
  Progman | Program Manager
CHECKDONE
```

— no `CabinetWClass` (Explorer) window, no probe window. That census's own
task and files were deleted after it ran. The VM was never rebooted and
its configuration was never changed (in particular UAC was left disabled,
as found).
