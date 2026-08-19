# THE CAPTION BAND'S TWO SUSPECTED CLIPS: the dots and the hover box

Progressive report. Tree at start: **ba33458**, clean.
MY FILES: `crates/kaya/src/winui/**`, `tools/deploy-win.sh` (the carry-item),
scratchpad. VM `akhil@192.168.64.2`.

The maintainer's report (2026-08-18, verbatim): *"is it just me or are the
three horizontal dots cut off? and the grey box on hover of the command
buttons (like the search button) is also cut off."*

Two suspected CLIP defects. Ground truth at NATIVE scale first — he may be
seeing the artifact page render at less than 1x.

(Sections appended as the work happens.)

---

## 1. GROUND TRUTH AT NATIVE SCALE — both defects are real, and I looked

The rig: `scratchpad/chrome/clip/run.sh` + `clip-probe.ps1`. The guest runs
the SHIPPED toolbar scene with a trailing `settle` appended through
`KAYA_SCENES_DIR` (the shipped file is never written); `record-win.exe`
(WGC — every GDI-family read returns a blank client area for a
`WS_EX_NOREDIRECTIONBITMAP` window) films the whole settle at 250 ms; the
probe measures UIA and then PARKS the pointer on each command in turn.
Each stage stamps the VM epoch clock, which is the same clock record-win
names its frames with, so every frame is attributable to a stage.

**Scale is 1:1 and that is read, not assumed:** `dpi=96`, visible frame
946x536, captured frames 946x536. Nothing here is a less-than-1x artefact.

**THE POINTER MUST BE MOVED THROUGH THE INPUT QUEUE.** The first run parked
the cursor with `SetCursorPos` and every captured frame came back
BYTE-IDENTICAL to the neutral one — cursor on the button, no hover visual
anywhere. `mouse_event(MOVE|ABSOLUTE|VIRTUALDESK)`, two hops so the move is
a move, is what raises the pointer-entered XAML listens to.

### THE HOVER BOX — clipped? No. SHORT, and it slices its own icon.

Pixel-measured off the hover frames (frame-local, band = y 1..49):

```
Find/Save (AppBarButton)  hover rect x 699..742  y  7..26   44 x 20
                          icon                   y 17..33   16 x 16
More options (MoreButton) hover rect x 747..786  y  7..42   40 x 36
```

The Find box's edge profile is symmetric top and bottom
(255,254,249,247,246 at BOTH y=7 and y=26), so it is a COMPLETE rounded
rect — not a clipped one. It is 16 DIP short and top-aligned, and its
bottom edge cuts across the magnifier at y=26 with 6 rows of glyph drawn
below it on bare white. The "…" cell's box beside it is the right shape
(40x36, centred on the band), which is exactly why the eye catches it.

### THE DOTS — clipped, by one row, and proved by making it stop

```
BEFORE  y=24  238 149 189 | 163 163 | 189 149 238     <- anti-aliased top
        y=25  105  27  27 | ...                       <- full
        y=26  105  27  27 | ...                       <- full, IDENTICAL to y=25
        y=27  (pure 255)                              <- nothing
```

Row 25 and row 26 are byte-identical and row 27 is pure white: a font never
draws a dot with an anti-aliased top and a razor-flat bottom. With the box
opened up (§2) the same glyph renders FOUR rows, and the new bottom row is
the exact mirror of the top (`238 149 189 / 163 163 / 189 149 238`). **One
anti-aliased row of every dot was being cut off**, and the glyph also sat
half a pixel low; it now centres on the band like every other icon.

## 2. THE OWNERS, READ OUT OF THE RUNNING PROCESS

A temporary instrument walked the live visual tree under the caption with
`VisualTreeHelper` and printed each element's arranged geometry, plus the
theme resources the templates read. Both owners are platform numbers
written for a place that is not this band.

```
CLIPRES AppBarThemeCompactHeight         = 48    the closed CommandBar's row
CLIPRES AppBarThemeMinHeight             = 64    what an AppBarButton asks for
CLIPRES AppBarExpandButtonCircleDiameter = 3     the "…" FontIcon's Height
```

**THE HOVER BOX.** `AppBarButton`'s template puts its pointer-over visual in
`AppBarButtonInnerBorder`, and the closed CommandBar puts every primary
button in the `Compact` visual state, which sets that border's margin to
`AppBarButtonInnerBorderCompactMargin` = **2,6,2,22**
(`AppBarButton_themeresources.xaml:119,150`). Those 22 DIP are the collapsed
label's row: on a **64**-tall button (`AppBarThemeMinHeight`) the border is
y 6..42 — 36 tall, centre 24 — and `ContentViewbox`'s
`AppBarButtonContentViewboxCollapsedMargin` = 0,16,0,2 puts the 16 DIP icon
at y 16..32, centre 24. **Concentric. That is the geometry the numbers were
written for.**

kaya's band caps the CommandBar at 48 (`PART_RightHeaderPresenter` is
944x**48**, the `TitleBar` control's expanded row), so the button's `Root`
is arranged 48 instead of 64 while the margins stay absolute:
`48 - 6 - 22 = 20`, top-aligned at 6. Measured, before any fix:

```
Root                    at=(648,0) actual=48.0x48.0
AppBarButtonInnerBorder at=(650,6) actual=44.0x20.0  margin=[2,6,2,22]
ContentRoot             at=(648,0) actual=48.0x64.0   <- still asking for 64
ContentViewbox          at=(664,16) actual=16.0x16.0  margin=[0,16,0,2]
```

`ContentRoot` is still 64: the button never stopped wanting 64, it was
measured against a 48 constraint. **Owner: the 48-DIP caption row meeting
`AppBarThemeMinHeight`=64 — a squeeze, not a clip.** The `MoreButton` is
untouched by it because `EllipsisButton` is written for 48 outright
(`MinHeight` = `AppBarThemeCompactHeight`, margin `2,6,6,6` → 40x36 centred).

**THE DOTS.** `CommandBar`'s template
(`v220-CommandBar_themeresources.xaml:839`):

```xml
<FontIcon x:Name="EllipsisIcon" FontSize="20" Glyph="&#xE712;"
          Height="{ThemeResource AppBarExpandButtonCircleDiameter}" />
```

and that resource is **3**. A 20 DIP glyph in a 3 DIP box. Measured:

```
EllipsisIcon at=(756,23) actual=20.0x3.0 desired=20.0x3.0
  (its own TextBlock)  at=(756,15) actual=20.0x20.0
```

The FontIcon is arranged 20x3, its TextBlock is 20x20 centred on that and
overflowing 8.5 DIP each way, and only what falls inside the 3-DIP box is
painted. **Owner: `AppBarExpandButtonCircleDiameter`** — a key whose name is
one dot's diameter being used as the whole icon's height. It is a
`{ThemeResource}`, so the app-level override route this backend already
uses for `TitleBarMinDragRegionWidth` reaches it.

## 3. THE FIX — two writes, both of platform numbers, no template surgery

**THE DOTS: `apply_caption_ellipsis_box()`**, welded into `mint_caption_titlebar`
beside `apply_caption_drag_strip` — the same `Application.Resources` route
under the platform's own key, with the same timing rule (a
`{ThemeResource}` is resolved when the template is applied, so it has to be
in the dictionary before the `CommandBar` exists). It writes
`AppBarExpandButtonCircleDiameter` = **20**, which is the glyph's own
`FontSize`, three lines up in the same element. Nothing else about the
MoreButton is touched.

**THE HOVER BOX: `button.SetHeight(caption_command_button_box()?)`** beside
the existing `SetWidth(CAPTION_COMMAND_CELL)`. `caption_command_button_box`
reads `AppBarThemeMinHeight` out of the dictionary — 64 — rather than
writing a number here, and panics naming the key if it is absent. The
button is then as tall as its own template assumes, the compact margins
land where they were designed, and **the CommandBar's own clip takes the
empty label row back off**: `LayoutRoot`'s `Grid.Clip` is
`TemplateSettings.ClipRect`, the closed bar's compact height. That is
measured rather than hoped — after the fix `Root` is 48x64 while UIA still
publishes each button as 48x48, which is the clip seen from outside, and
the clip governs hit-testing as well as rendering.

The route NOT taken, and why: `AppBarButtonInnerBorderCompactMargin` is
referenced by a `{StaticResource}` inside a VisualState Setter, resolved at
template-parse time from the dictionary that DEFINES it, so an app-level
override would never be consulted. Restoring the height the margins were
written for is the platform's own arrangement; patching the margin would
not be.

## 4. THE WALL — `assert_caption_command_geometry`

Both failures are SILENT and no scene can see either. Every harness read
goes through the button objects; a hover visual 16 DIP above its icon and
an overflow glyph with a row shaved off answer identically. Both writes
also fail quietly: a `{ThemeResource}` written after the template is
applied is ignored, and a height that stops being written leaves a button
that still measures 48x48 to UIA.

So the wall measures the ARRANGEMENT, on the path every promoted window
runs: `refresh_toolbar` ARMS it, the caption's own `LayoutUpdated` fires it
on the first pass that has something arranged (an unarranged pass leaves it
armed rather than passing vacuously), and it asserts (a) the overflow
glyph's box is the size kaya wrote, and (b) every promoted command's
`AppBarButtonInnerBorder` is concentric with its `ContentViewbox` and
inside the band. A bar with children in it and nothing measured returns
"not yet" rather than "fine" — the census that read nothing and agreed with
everything.

### Both reds watched (perturb-restore from a saved COPY, `shasum -c`, never git)

**(a) the button height, `substitutions: 2`** (`CAPTION_ELLIPSIS_ICON_BOX`
back to the library's 3, `SetHeight` back to the 48 cell):

```
thread 'main' (20160) panicked at crates/kaya/src/winui/mod.rs:3146:21:
kaya: winui: a promoted command's hover visual is not on its own icon. The
AppBarButtonInnerBorder ... is arranged 20 DIP tall from y 6, centre 16; the
ContentViewbox holding the icon is 16 DIP tall from y 16, centre 24; the
caption band is 48 DIP. ...
toolbar_rust: FAIL (3s)
```

**(b) the ellipsis box, `substitutions: 1`** — the WRITE alone removed
(`apply_caption_ellipsis_box()?;` deleted from `mint_caption_titlebar`), so
the constant still says 20 and only the dictionary moved. This is the
perturbation (a) could not make: (a) moved both sides of that comparison at
once, which is why it needed its own:

```
thread 'main' (18440) panicked at crates/kaya/src/winui/mod.rs:3097:5:
kaya: winui: the caption CommandBar's overflow glyph is arranged in a box 3
DIP tall; kaya wrote 20 into the application dictionary under
AppBarExpandButtonCircleDiameter ... A box of the library's size means the
write did not reach the control — the usual cause is ordering ...
toolbar_rust: FAIL (3s)
```

Restored both times: `crates/kaya/src/winui/mod.rs: OK`.

**And the PIXEL measurement reds on the reverted rendering**, which is the
`before` run in §1 and §5 — 20-tall hover boxes with 5 rows of icon outside
them, and 3-row dots.

## 5. ACCEPTANCE — pixel-measured, and the band is otherwise untouched

`scratchpad/chrome/clip/measure.py`, which reads the button rects out of
each run's OWN probe (nothing is a constant carried between runs) and
refuses a verdict rather than reporting agreement when it found no ink:

```
== run before
   ellipsis ink rows 24..26 (3 rows), cell y 1..49, cell centre 25.0, ink centre 25.5
   hover Find          rows 7..26 (20 tall) cols 699..742 (44 wide)
        icon ink rows 7..31; rows OUTSIDE the hover box: 5 [27, 28, 29, 30, 31]
   hover Save          rows 7..26 (20 tall) cols 651..694 (44 wide)
        icon ink rows 7..29; rows OUTSIDE the hover box: 3 [27, 28, 29]
   hover More options  rows 7..42 (36 tall) cols 747..786 (40 wide)
        icon ink rows 7..42; rows OUTSIDE the hover box: 0 []

== run after
   ellipsis ink rows 23..26 (4 rows), cell y 1..49, cell centre 25.0, ink centre 25.0
   hover Find          rows 7..42 (36 tall) cols 699..742 (44 wide)   0 icon rows outside
   hover Save          rows 7..42 (36 tall) cols 651..694 (44 wide)   0 icon rows outside
   hover More options  rows 7..42 (36 tall) cols 747..786 (40 wide)   0 icon rows outside
```

Every hover rect is now 36 tall — the same 36 the "…" cell always had —
rounded on all four corners, fully inside the 48 band, with its own icon
entirely inside it. The ellipsis gained its missing row and its ink centre
moved from 25.5 to 25.0, the cell's own centre.

**MY OWN EYE, on the magnified crops and at 1:1.** Before: the grey box is a
squat rectangle whose flat lower edge cuts the magnifier in half, with the
glyph's bottom drawn on bare white below it, and the three dots are hard
flat-topped, flat-bottomed stubs. After: the box is a proper rounded square
with the magnifier centred in it, and the dots are round dots. Both defects
were real, both are gone, and both were visible at NATIVE scale — this was
not a less-than-1x artefact.

**NOTHING ELSE IN THE BAND MOVED** (`clip/proofs.sh input`, same UIA reads
the one-band arm used):

```
MEAS system-cluster centre-y=154 height=48
MEAS command Save/Find/More options  48x48  cy=155
RHY system  pitch 48 gap 0     RHY command pitch 48 gap 0
RHY menu    item pitch 49/52 gap 8
RHY commands|system gap = 8
```

**The title's aim, re-measured through the lane's own new phase** — the six
unclamped widths, all DRIFT 0, the same numbers as before the fix:

```
AIMPLAN 11   AIMFLOOR w=480
AIMV launch drift=0  | after-drag 0 | w=1100 0 | w=900 0 | w=800 0 | w=700 0
AIMV w=640 -8 clamped | w=600 -28 clamped | w=560 -48 clamped | w=520 -64.5 clamped
AIMV w=480 drift=absent clamped=true absent=true
deploy-win: caption title aimed at the window's centre — 11 widths measured,
            6 unclamped, all at DRIFT 0
```

**The proofs, each a synthesized real input whose consequence the GUEST
asserts** (`found` is written by `Msg::Find` and by nothing else, `exported`
by `Msg::Export`):

```
PROVE: grab 275,77 -> moved dx=120 dy=60 wanted dx=120 dy=60  DRAG-OK  size-unchanged=True
PROVE: click-find at 900,137
KAYA_SELFTEST: OK (..., menu "File>Save" enabled, found)
PROVE: click-File at 162,155 (rect 142,139 41x32) -> flyout open, Export rect 147,209
PROVE: click-Export at 216,224
KAYA_SELFTEST: OK (..., menu "File>Save" enabled, exported)
PROVE: close via uia rect 956,52 48x48 -> winui-windows-after-close=0 (was 1)  CLOSE-OK
```

**Eleven legs, byte-identical verdicts** against the same eleven at ba33458
(`clip/verdicts.py`, which refuses a verdict when it read none on either
side):

```
toolbar_{rust,python,go,csharp,java}   PASS  verdicts=1  IDENTICAL=True
menus_{rust,python,go,csharp,java}     PASS  verdicts=1  IDENTICAL=True
editor_go                              PASS  verdicts=1  IDENTICAL=True
```

## 6. THE CARRY-ITEM — the probe now runs in the lane

`crates/kaya/src/winui/title-centre-probe.sh` had no home
(`winui-title-center.md` §11.1). It has one now, and the driver is REUSED
rather than copied: `tools/deploy-win.sh` gained a `caption_centre_probe`
phase that calls it with `KAYA_TCP_NO_DEPLOY=1` (the lane has just built and
shipped what it would rebuild). It runs FIRST in the `all` arm, alone,
before anything is submitted to the suite pool — the probe drives a real
border drag and a width sweep on the one window it finds by class, so it
needs the desktop to itself, the same reason the menus legs sit between
drains. `tools/deploy-win.sh <host> caption-centre` runs it alone.

**The count rules, so the phase cannot pass having measured nothing:**

- the probe prints `AIMPLAN <n>` BEFORE it runs any of it, and exactly `n`
  `AIMV` rows must come back — a sweep that stopped early reports no drift,
  which is the same output as a sweep that found none;
- `AIMFLOOR w=<n>` names the one width at which a VANISHED title is correct;
  an `absent=true` row anywhere else fails, so a title that stopped existing
  cannot hide inside the clamp;
- at least 6 rows must be UNCLAMPED (a clamped row's drift is the rule
  working, so a run where everything clamped would satisfy the drift rule
  having proved nothing), and every unclamped row's drift must be 0;
- no row may report the title OVERLAPPING a header, at any width.

**And a second census clause in deploy-win.sh**, because the existing one
audits `run_suite` legs and cannot see a PHASE: every function the `all`
arm calls as `name || status=1` must also be callable from an arm of its
own. It carries the same regret the leg census was written for — a phase you
can only reach by running the whole lane is a phase nobody re-runs while
fixing what it found — and it has its own self-test with a composed fixture.

**THE LANE-LEVEL RED, WATCHED.** Perturbation `substitutions: 2` (the bias
write in `center_caption_title` disabled AND its in-process wall, so the
PHASE's red is what is seen rather than the app aborting first):

```
LANE rc=1
AIMV launch drift=-63 clamped=false absent=false      (and -63 at every unclamped width)
deploy-win: the caption title is not on the window's centre at launch (drift -63),
after-drag (drift -63), w=1100 (drift -63), w=900 (drift -63), w=800 (drift -63),
w=700 (drift -63). ... a non-zero drift on an UNCLAMPED row means
center_caption_title's bias is not reaching the TextBlock — the historic value is
-63, the leftover slot's own centre.
```

Restored from the saved copy, `shasum -c`: `crates/kaya/src/winui/mod.rs: OK`.

## 7. THE ALL-BINDINGS SWEEP (invariant 2)

No binding surface, no protocol surface, no spec movement, no generated
file: one backend file, two probe scripts beside it, one lane script.

| language | verdict |
|---|---|
| Rust, Python, Go, C#, Java | **DO** — each carries windows `toolbar_*`/`menus_*` legs; all eleven run above with byte-identical verdicts, and every one of those windows now draws its promoted commands' hover visual on its own icon and its "…" whole |
| Swift, OCaml, Haskell | **DEFER on this lane only** — no toolchain on the VM; their guests run the identical scenes on the mac/iOS/linux runners, none of which this touches |
| C floor | **DEFER** — no `guests/c/toolbar.c` exists; there is no leg to write |

Invariant 1 has nothing to say here: how a host paints a command's
pointer-over background, and how tall a box it draws its own overflow glyph
in, are lowering-fidelity facts inside one backend, not behaviour an app can
observe. `AppBarExpandButtonCircleDiameter` and `AppBarThemeMinHeight` are
WinUI theme keys with no counterpart in SwiftUI, Compose or GTK, each of
which draws its own band.

## 8. THE GATES AND THE LADDER

```
cargo test -p kaya --features harness --locked   360 + 3 + 13 passed, 0 failed
tools/gates.sh                                   declared 34, ran 34, passed 34 — OK
tools/check-targets.sh                           ALL OK (native/ios/android/windows/
                                                 go-android, BOTH feature configurations)
tools/deploy-win.sh <host> caption-centre        OK (11 widths, 6 unclamped, DRIFT 0)
11 windows legs                                  PASS, verdicts byte-identical to ba33458
```

## 9. CAPTURES

Deliverables, native scale (1:1, dpi 96) and x10 nearest-neighbour crops:

```
scratchpad/chrome/ob/clip-dots-before.png     clip-dots-before-x10.png
scratchpad/chrome/ob/clip-dots-after.png      clip-dots-after-x10.png
scratchpad/chrome/ob/clip-hover-before.png    clip-hover-before-x10.png
scratchpad/chrome/ob/clip-hover-after.png     clip-hover-after-x10.png
```

The `-hover-` pair carries a LIVE pointer-over on the Find button; the
`-dots-` pair is the neutral band. Also `clip/crops/`: the "…" cell hovered
in both trees, and the band at x5.

## 10. CLEANUP, PROVEN

- **VM scheduled tasks**: the four this arm created (`kaya_clip_g`,
  `kaya_clip_r`, `kaya_clip_p`, `kaya_clip_park`) — `schtasks /delete` then
  `schtasks /query` both answering `ERROR: The system cannot find the file
  specified.`, then a full `schtasks /query /fo list` grepped for
  `kaya_clip|kaya_tcp|kaya_ob|kaya_tc_|kaya_gap` returning only
  `kaya_clipboard_*` (deploy-win's own per-leg launchers) and
  `kaya_clipprobe`, which last ran 8/3/2026 and belongs to
  `tools/win/clipprobe`. Neither is mine.
- **VM processes**: `record-win.exe`, `toolbar.exe`, `menus.exe`,
  `editor_go.exe`, `wscript.exe`, `powershell.exe`, `python.exe`,
  `java.exe`, `dotnet.exe`, `go.exe` each `INFO: No tasks are running which
  match the specified criteria.`, and a full `tasklist` grepped for
  record-win/toolbar/menus/commands/todos/clipboard/undo/styling/editor/
  wscript/python/java/dotnet/go/powershell returns **NOTHING**.
- **VM scratch**: `C:\Users\akhil\kaya-clip`, `kaya-ob`, `kaya-tc-probe`,
  `kaya-park` all `rmdir /s /q` then `dir` → **`File Not Found`**.
- **VM temp**: `%TEMP%\kaya-editor-4052` (the editor_go leg's) removed,
  `dir %TEMP%\kaya-editor-*` → `File Not Found`.
- **The shipped scenes were never written**: `C:\kaya\scenes\`'s
  `toolbar.steps`, `menus.steps` and `editor.steps` hash EQUAL to the repo's
  `tools/scenes/` copies (`dcffef0e…`, `d52f4635…`, `c14543df…`). Every
  scratch scene rode `KAYA_SCENES_DIR`.
- **The pointer, parked back neutrally, and READ where it matters**: an ssh
  session has its own window station, so `Cursor::Position` over ssh always
  answers 0,0 and says nothing about the desktop. Measured through an
  interactive scheduled task instead: `screen 1280x800 before 980,76 after
  640,400` — it was still on the Close button where the last proof left it,
  and is now at the desktop centre. That task and its directory are both
  gone (`cannot find` / `File Not Found`).
- **Host processes**: `ps -Ao pid,etime,pcpu,command` grepped for
  deploy-win / record-win / title-centre / suites.sh / run.sh / proofs.sh /
  ffmpeg / ffprobe / `192.168.64.2` → **none**. Top-CPU shows only the two
  Android emulator qemu processes at 21–22 days of elapsed time, which
  predate this session.
- **Disk**: this arm's scratch (`scratchpad/chrome/clip`) is **6.7 MB**;
  session scratchpad **94 MB**; host free **417 GB**.
- **Repo**: `git status` shows exactly four paths —
  `crates/kaya/src/winui/mod.rs`, `crates/kaya/src/winui/title-centre-probe.ps1`,
  `crates/kaya/src/winui/title-centre-probe.sh`, `tools/deploy-win.sh`
  (+584 / −20). The temporary in-process instrument used for §2 is gone;
  `mod.rs` was restored from a saved COPY and `shasum -c`'d each time,
  never `git checkout`. Nothing committed; nothing pushed.
