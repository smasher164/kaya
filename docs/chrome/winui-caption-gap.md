# THE CAPTION GAP: who owns the 48px, and what the cousin actually does

Progressive report. Tree at start: **7c2bb39**, clean except `docs/deferred.md`
(the coordinator's, untouched here). MY FILES: `crates/kaya/src/winui/**`,
scratchpad. VM `akhil@192.168.64.2`.

The subject: the 48 DIP between the promoted commands (`TitleBar.RightHeader`)
and the system minimize/maximize/close. The maintainer's observation: VS Code,
the nearest structural cousin, keeps barely any gap there.

---

## 1. THE GAP'S OWNER, READ OFF THE TEMPLATE

`TitleBar`'s control template (`docs/chrome/TitleBar-v220.xaml:168-193`)
is a 12-column Grid. The three columns that matter here:

```
 9: Right Header Presenter   Width="Auto"
10: Min Drag Region          Width="{ThemeResource TitleBarMinDragRegionWidth}"
11: RightPaddingColumn       Width="{ThemeResource TitleBarRightPaddingWidth}"   (0 in the dictionary)
```

- **Column 9** hosts `PART_RightHeaderPresenter` and carries **no Margin and
  no Padding** in the template (`:274-281` — Content, both alignments, nothing
  else). kaya writes none either: `refresh_toolbar` does
  `titlebar.SetRightHeader(&bar.cast::<UIElement>()?)` and never touches the
  bar's margin (`crates/kaya/src/winui/mod.rs:2572`).
- **Column 11** is NOT 0 at runtime. `TitleBar::UpdatePadding`
  (`TitleBar.cpp:466-478`) overwrites it every layout with
  `appTitleBar.RightInset()` — the width the system's own caption buttons
  occupy. That is why the cluster sits where it does; it is not part of the
  gap.
- **Column 10** is therefore the whole gap, and it holds nothing at all: no
  template child is in `Grid.Column="10"`.

`TitleBarMinDragRegionWidth` is `48` (`TitleBar_themeresources.xaml:85`).

**The previous arm's own numbers close it arithmetically.** From
`winui-one-band.md` §4: rightmost command ("More options") `x=868 w=48` →
right edge **916**; leftmost system button (Minimize) `x=964`. 964 − 916 =
**48**, exactly the resource, to the pixel. If RightHeader carried any margin
the gap would exceed 48; it does not. **Owner: `TitleBarMinDragRegionWidth`,
100%, nothing else contributes.**

## 2. WHY THE STRIP IS BELT-AND-SUSPENDERS (also read off the source)

`TitleBar::UpdateInteractableElementsList` (`TitleBar.cpp:753-811`) decides
what is punched OUT of the non-client area (i.e. what is NOT draggable):

- `LeftHeader` → the presenter is pushed **whole** (`:777-785`).
- `RightHeader` → the presenter is pushed **whole** (`:798-806`).
- `Content` → **not** whole. It recurses with `FindInteractableElements`
  (`:967-1050`), which pushes only elements that `try_as<Control>()`
  **succeeds** on and that are enabled (`:1028-1038`).

kaya's Content is a bare `TextBlock` (`mod.rs:3030-3032`). `TextBlock` derives
from `FrameworkElement`, **not** from `Control`, so it is never pushed. The
whole of column 8 — `Width="*"`, i.e. every pixel between the menu and the
commands — stays drag surface. That is a several-hundred-pixel drag region,
and the previous arm's drag proof grabbed inside it
(`PROVE: grab 301,103`, `DRAG-OK`).

So column 10's residual job is not "make the window draggable". It is
separation between an app command and the destructive system button next to
it.

(Sections appended as the work happens.)

## 3. THE COUSIN, AND WHAT I COULD AND COULD NOT MEASURE

The maintainer's premise is VS Code, which is **not installed on this VM**,
so I did not measure it and I am not going to report a number I did not read.
What I could measure is the other app the one-band design names as its shape.

**Windows Terminal, probed by UIA on this machine at this DPI**
(`scratchpad/chrome/gap/wt.ps1 (gone)`, result `gap/wt-result.txt`): its caption band
holds a tab strip, a `Close Tab` button and a `New Tab` split button, and then
**nothing at all until the caption buttons** — everything Terminal puts in its
caption is left-aligned. So Terminal has no commands-to-caption-buttons gap to
measure, and the probe said so rather than inventing one
(`WT: no caption buttons published; cannot compute a gap` — its caption buttons
are not in the window's UIA tree either).

The one number it did give, between two adjacent caption-hosted controls of its
own: `Close Tab` ends at x=396, `New Tab` starts at x=407 — **11**.

The numbers I could read in kaya's own band, on the same run as the 48:

| gap | value | where it comes from |
|---|---|---|
| between two `MenuBar` items in `LeftHeader` | **8** | `MenuBarItemMargin` 4,4,4,4 (`MenuBar_themeresources.xaml:44-46`), measured `RHY menu ... gap 8` |
| after the control's own title | **8** | `TitleBarTitleMargin` = 0,0,8,0 (`TitleBar_themeresources.xaml:93`) |
| Terminal, between two of its caption controls | **11** | measured above |
| column 10, before this change | **48** | `TitleBarMinDragRegionWidth` |

**THE VALUE I CHOSE: 8.** It is the smallest of these, it is at the bottom of
the 8-12 range the maintainer gave for the cousin, and — the part that decided
it — **it is not a new number in this band**: it is the element-to-element gap
the band already draws twice, between the menu items and after the title. The
one place still reserving a whole caption button's width was column 10.

What I will not claim is that 8 DIP is the window's drag affordance. It is
**separation**, so that a reach for the overflow "..." is not one rounding
error away from Close. The drag affordance is column 8, and §2 above says why
structurally; §5 drags by it.

## 4. THE OVERRIDE ROUTE, AND ITS VERDICT: IT TAKES

`crates/kaya/src/winui/mod.rs`, `apply_caption_drag_strip()` — one direct entry
in `Application.Resources` under the control's own key, written at the caption
mint immediately before `TitleBar::new()`. Direct rather than another merged
dictionary, because a dictionary's own keys are searched before any of its
merged ones, so it wins whatever `apply_brand` appends later. The value is a
boxed `f64`, which is what the library's `<x:Double>` is at runtime.

Timing is load-bearing and is the reason it sits at the mint: a resource value
changed after a tree is built does not re-flow it (`apply_brand`'s doc comment
records the same rule).

**MEASURED, same rig, same scene, same window size (946x536), UIA rects:**

```
BEFORE   Save 668  Find 716  More options 764 (w=48)   right edge 812
         Minimize 860   Maximize 908   Close 956 (48x48)
         RHY commands|system gap = 48

AFTER    Save 786  Find 834  More options 882 (w=48)   right edge 930
         Minimize 938   Maximize 986   Close 1034 (48x48)
         RHY commands|system gap = 8
         RHY override: app dictionary asks for 8; column 10 measures 8; TAKEN=True
```

**48 -> 8, and nothing else moved**: both runs still pitch 48 gap 0, all six
caption-hosted controls still 1 px off the system cluster's centre line (155 vs
154 - the client area starts one pixel below the frame), command cells still
48x48, menu items still 32 tall.

One thing did improve on its own: the title's centre was 83 px left of the
window's centre and is now **63** - column 8 gained the 40 the strip gave up,
so its own centre moved 20 px right. Still the slot's centre, still not
compensated for by kaya.

## 5. THE DRAG PROOF, RE-RUN AGAINST AN 8 DIP STRIP

`scratchpad/chrome/gap/prove.ps1 (gone)` phase `strip`, in the interactive session.
The strip's own edges are READ from UIA (right edge of the last command, left
edge of Minimize) and the grab point is that measured rect's middle - the
script does not believe a number about where the strip is.

**Grabbed by the 8 px strip:**

```
PROVE: strip x=852..860 width=8 (right edge of the last command .. left edge of Minimize)
PROVE: strip  frame-before 59,52 946x536
PROVE: strip  grab 856,77
PROVE: strip  frame-after  179,100 946x536
PROVE: strip  moved dx=120 dy=48 wanted dx=120 dy=48  size-unchanged=True
PROVE: strip  DRAG-OK
```

**Grabbed by the title centre, same run, dragged back:**

```
PROVE: title rect 569,117 40x16
PROVE: centre frame-before 179,100 946x536
PROVE: centre grab 589,125
PROVE: centre frame-after  59,52 946x536
PROVE: centre moved dx=-120 dy=-48 wanted dx=-120 dy=-48  size-unchanged=True
PROVE: centre DRAG-OK
```

Both exact, both moved and neither resized, and the window ends where it
started.

**The commands still hit-test** - same run, rect re-read after the two drags,
and the sentence is the GUEST's:

```
PROVE: click-find at 780,77 (rect 756,53 48x48)
KAYA_SELFTEST: OK (..., menu "File>Save" enabled, found)
```

`found` is written by `Msg::Find` and by nothing else.

**The system buttons still hit-test** - its own run, because the close ends the
guest:

```
PROVE: close via uia rect 1034,130 48x48
PROVE: winui-windows-after-close=0 (was 1)     CLOSE-OK      EXIT=0
```

**And the menu in the caption still opens and fires**, re-proved because
`RecomputeDragRegions` runs on the same rebuild:

```
PROVE: click-File at 84,77 (rect 64,61 41x32)
PROVE: flyout open, Export rect 69,131 137x29
PROVE: click-Export at 138,146
KAYA_SELFTEST: OK (..., menu "File>Save" enabled, exported)
```

## 6. THE CAPTURE, AND MY OWN VERDICT

`scratchpad/chrome/ob/cap-one-band-c.png (gone)` - WGC (`record-win.exe`, 23 frames
over the trailing settle; every GDI-family read returns a blank client area for
a `WS_EX_NOREDIRECTIONBITMAP` window), midpoint frame, 946x536, same scene and
same window size as `cap-one-band-b.png`. The guest's verdict for that run is
the shipped one.

I looked at b and c side by side. Then I measured them, because "looks closer"
is not a verdict: a column-ink scan of the band rows in both PNGs, run
positions in window coordinates.

```
                      ink runs right of x=550 (start..end)
cap-one-band-b.png    625-640  674-687  719-734        820-829  868-877  916-925
                        (Save)   (Find)    (...)          (min)    (max)  (close)
cap-one-band-c.png    665-680  714-727  759-774        820-829  868-877  916-925

white space between adjacent ink:
  b:  33  31  |  85  |  38  38
  c:  33  31  |  45  |  38  38
```

**The one interruption in the run went from 85 px of white to 45**, against 33
and 31 inside the command run and 38 inside the system run. Before, the void
was more than twice either neighbour's rhythm and the three commands read as a
separate cluster parked near the caption buttons. Now it is 45 against 38 -
seven pixels wider than the system cluster's own internal spacing.

**My verdict: yes, this is right, and it is better than b.** Six cells, one
pitch, one centre line, with a small deliberate breath before the destructive
button. What I would flag rather than have noticed: 45 px of white is still
visibly more than 38, and that is NOT the 8 - it is the two cells' own padding
(a 48 px cell with a 16 px glyph gives 16 either side, and the system's 10 px
glyph gives 19). Closing that last 7 px would mean narrowing the command cell
below the system cell, which would break the one thing the previous revision
was for. So 45 is the floor that keeps the cells matched, and the structural
gap underneath it is now 8 - the same 8 the menu items already use.

## 7. THE GUARD, AND THE HALF OF IT I COULD NOT BUILD

The failure class this change introduces is **silent**, and it is the same
shape as the one the previous revision measured for a menu that never reached
the caption. A `{ThemeResource}` is resolved when the template is applied.
Write the override afterwards and the control keeps the library's 48, the band
gets its dead space back, and **nothing fails**: no harness verb reads a
template column's width (there is no such concept on the other four backends,
so there is no uniform read to add), both scenes pass unchanged, and the only
witness is a screenshot somebody has to think to take.

Two adjacent statements whose order matters is not a guard - a refactor
reorders them without reading either comment. So the ordering is welded into
one function instead:

```rust
fn mint_caption_titlebar() -> windows_core::Result<TitleBar> {
    apply_caption_drag_strip()?;
    TitleBar::new()
}
```

`refresh_toolbar` now calls that and nothing else constructs a `TitleBar`
(`grep 'TitleBar::new()' crates/kaya/src/winui/mod.rs` -> one hit, inside this
function, plus the doc comment that names it).

`apply_caption_drag_strip` also reads the value BACK through the same `Lookup`
the module uses elsewhere and asserts it, because `Insert` returns "did I
replace a key", which is not "did the value arrive". That assertion's message
says plainly what it does and does not prove - the dictionary answers; whether
the CONTROL consumed it is a layout fact, and is measured on the lane.

**WHAT WOULD FINISH THE WALL, and is not in this arm's file list** (`tools/` is
not mine): a census gate that `TitleBar::new()` appears in `winui/mod.rs` only
inside `mint_caption_titlebar`. That is the clause which survives someone
adding a second caption site later. Flagged here rather than left to memory.

## 8. THE ALL-BINDINGS SWEEP (invariant 2)

No binding surface, no protocol surface, no spec movement, no generated file:
one backend file, two functions and one constant.

| language | verdict |
|---|---|
| Rust, Python, Go, C#, Java | **DO** - each carries windows `toolbar_*` and `menus_*` legs; all ten run below, and every one of those windows now wears the 8 DIP strip |
| Swift, OCaml, Haskell | **DEFER on this lane only** - no toolchain on the VM; their guests run the identical scenes on the mac/iOS/linux runners, none of which this touches |
| C floor | **DEFER** - no `guests/c/toolbar.c (gone)` exists; there is no leg to write |

The other four backends are untouched: `TitleBarMinDragRegionWidth` is a WinUI
theme key and has no counterpart in SwiftUI, Compose or GTK, all three of which
draw their own band. This is a lowering-fidelity number inside one backend, not
a binding-level behaviour, so invariant 1 has nothing to say about it.

## 9. WHAT THE COORDINATOR MUST CARRY FORWARD

`docs/chrome-plan.md`'s C2 WinUI row was already wrong in three places before
this arm (the previous report's §12 lists them and supplies replacement text).
**That replacement text is now wrong in one place of its own** - it ends
"separated by the control's own 48px `TitleBarMinDragRegionWidth`". Corrected
tail, ready to paste in its place:

> ... both runs pitch 48 gap 0, separated by an **8 DIP** strip:
> `TitleBarMinDragRegionWidth` is 48 in the library's dictionary and kaya
> overrides it to 8 through a direct entry in `Application.Resources`, the
> platform's own lightweight-styling route, written at the caption mint before
> the control exists (`mint_caption_titlebar`). 48 reserves a whole caption
> button for a drag region the band does not need - the control's Content slot
> is `Width="*"` and holds only a `TextBlock`, which
> `FindInteractableElements` never punches out, so several hundred pixels of
> the band are already drag surface. 8 is the gap the band's own `MenuBar`
> items already sit at. Measured before/after on the lane: gap 48 -> 8, both
> drags exact (by the 8 px strip AND by the title centre), Find still fires,
> Close still closes.

Also outstanding, and named in §7: a `tools/` census that `TitleBar::new()`
appears only inside `mint_caption_titlebar`.

## 10. THE SUITES, AND THE GATES

**Eleven legs, on the final tree**, each run through the lane's own runner
(`tools/deploy-win.py akhil@192.168.64.2 <leg>`; logs in
`scratchpad/chrome/gap/suites/ (gone)`):

```
toolbar_{rust,python,go,csharp,java}   PASS
menus_{rust,python,go,csharp,java}     PASS
editor_go                              PASS
```

**Byte-identical verdicts**, compared programmatically against the pre-change
lane (`scratchpad/chrome/ob/lane2.log (gone)`, the 170-leg run at 7c2bb39) by
`scratchpad/chrome/gap/verdicts.py (gone)`, which REFUSES A VERDICT rather than
reporting agreement when it read no verdict on either side - two empty reads
compare equal and would print green:

```
toolbar_rust     PASS=True  verdicts=1  IDENTICAL=True
toolbar_python   PASS=True  verdicts=1  IDENTICAL=True
toolbar_go       PASS=True  verdicts=1  IDENTICAL=True
toolbar_csharp   PASS=True  verdicts=1  IDENTICAL=True
toolbar_java     PASS=True  verdicts=1  IDENTICAL=True
menus_rust       PASS=True  verdicts=1  IDENTICAL=True
menus_python     PASS=True  verdicts=1  IDENTICAL=True
menus_go         PASS=True  verdicts=1  IDENTICAL=True
menus_csharp     PASS=True  verdicts=1  IDENTICAL=True
menus_java       PASS=True  verdicts=1  IDENTICAL=True
editor_go        PASS=True  verdicts=1  IDENTICAL=True

all 11 legs PASS with byte-identical verdicts against lane2.log
```

**Gates, on the final tree:**

```
tools/check-targets.py      ALL OK  (native/ios/android/windows/go-android, BOTH feature configurations)
tools/check-verbs.py        OK
tools/check-shell.py        OK
tools/check-steps.py        OK
tools/check-stubs.py        OK
tools/check-diagnostics.py  OK
```

**One honest note about sequencing.** I edited `mod.rs` (the
`mint_caption_titlebar` refactor) while a first pass of these legs was in
flight, and the five legs that started after the edit failed to compile
mid-run. That was my mistake, not a defect: the whole set was re-run from
scratch on the finished tree and it is that re-run which is reported above.
The capture was re-taken for the same reason, against the shipped binary
(`C:\kaya\toolbar.exe` SHA-256 `23e43f37...`), and its pixel measurement came
out identical to the pre-refactor one - which is the refactor's own proof of
being behaviour-preserving.

## 11. CLEANUP, PROVEN

- **VM scheduled tasks**: the five this arm created (`kaya_gap_g`,
  `kaya_gap_p`, `kaya_gap_rec`, `kaya_gap_wt`, `kaya_gap_wtp`) are gone - five
  `schtasks /delete` answering `ERROR: The system cannot find the file
  specified.`, then five `schtasks /query` answering the same, then a full
  `schtasks /query` grepped for `kaya_gap` returning nothing. (The ~190
  `kaya_<leg>` tasks that remain are `deploy-win.py`'s own per-leg launchers
  and predate this session; deleting them would make the next lane
  re-provision.)
- **VM processes**: `record-win.exe`, `toolbar.exe`, `menus.exe`,
  `editor_go.exe`, `wscript.exe`, `WindowsTerminal.exe`, `python.exe`,
  `java.exe`, `dotnet.exe`, `go.exe` each `INFO: No tasks are running which
  match the specified criteria.`, and a full `tasklist` grepped for
  record-win/toolbar/menus/commands/todos/clipboard/undo/styling/editor/
  wscript/python/java/dotnet/go/Terminal/OpenConsole returns NOTHING. The
  Windows Terminal I launched for the cousin probe was killed explicitly
  (three PIDs, `SUCCESS`) - its probe exited before its own close, which I
  noticed and cleaned rather than assumed.
- **VM scratch**: `C:\Users\akhil\kaya-gap` `rmdir /s /q` then `dir` ->
  **`File Not Found`**. `kaya-ob` and `kaya-film` (the previous arm's) also
  `File Not Found`.
- **VM temp**: the two `%TEMP%\kaya-editor-<pid>` directories the editor legs
  created are removed (`dir` -> `File Not Found`).
- **The shipped scenes were never written**: `C:\kaya\scenes\`'s
  `toolbar.steps`, `menus.steps` and `editor.steps` all hash EQUAL to the
  repo's `tools/scenes/` copies. Every scratch scene rode `KAYA_SCENES_DIR`.
- **Host processes**: `ps -Ao pid,etime,pcpu,command` grepped for
  deploy-win / record-win / ffmpeg / ffprobe / `192.168.64.2` / this arm's own
  scripts -> **NONE**. Top-CPU check for leaked load shows only the Android
  emulator's qemu processes, at 21-22 days of elapsed time, which predate this
  session.
- **Disk**: this arm's scratch (`scratchpad/chrome/gap (gone)`) is **1.1 MB**. Session
  scratchpad **89 MB**. Host free **417 GB**.
- **Repo**: `git status` shows `crates/kaya/src/winui/mod.rs` (mine, +167 lines)
  and `docs/deferred.md` (the coordinator's, untouched by me). Nothing
  committed; nothing pushed.
