# THE MARK MOVES TO THE FAR LEFT OF A PROMOTED CAPTION

Progressive report. Tree at start: **4577da9**, clean. MY FILES:
`crates/kaya/src/winui/**`. VM `akhil@192.168.64.2`.

The ruling (maintainer, 2026-08-18, precedent-verified against VS Code /
Visual Studio / Windows Terminal and the Win95-lineage convention): on a
PROMOTED window the identity mark goes BEFORE the menu, at the caption's
far left — composed INTO `LeftHeader` ahead of the `MenuBar`, not through
`TitleBar.IconSource`, which the control lays out AFTER `LeftHeader`.

Evidence tags: [MEASURED] I ran it, output shown - [REPO] read from this
tree - [DOC] platform documentation/source - [INFER] reasoning from those.

---

## 0. WHAT THE TREE DOES TODAY, READ BEFORE TOUCHING IT

- `apply_identity_to_window` (mod.rs:11465) writes two sinks: the window
  icon (`AppWindow.SetIconWithIconId`) for every window, and
  `titlebar.SetIconSource(...)` for a window that has a `TitleBar`. [REPO]
- A `TitleBar` is minted by the FIRST PROMOTION and by nothing else
  (`refresh_toolbar`, mod.rs:3969). So `IconSource` is reachable ONLY on
  promoted windows — the very windows where it lands wrong. An unpromoted
  window has no `TitleBar` at all; its mark is drawn by the SYSTEM caption
  from the window icon, at the far left, which is already the convention.
  [REPO]
- The control's template puts `PART_Icon` in **column 5** and
  `PART_LeftHeaderPresenter` in **column 3**
  (`TitleBar-v220.xaml:213-230`), which is the whole finding: kaya's menu
  is the LeftHeader, so the icon lays out after it. [DOC]
- The control's own icon metrics, to be reproduced by a hand-placed mark:
  a `Viewbox`, `MaxWidth`/`MaxHeight` = `TitleBarIconMaxWidth`/`Height` =
  **16**, `Margin` = `TitleBarIconMargin` = **0,0,16,0**,
  `VerticalAlignment=Center`. `TitleBarLeftHeaderVerticalAlignment` is
  also Center. [DOC: v220-TitleBar_themeresources.xaml:88-96]

## 1. THE BASELINE, MEASURED BEFORE ANYTHING WAS TOUCHED

`ip/icon-probe.sh` + `icon-probe.ps1` (this arm's scratch driver, the
title-centre-probe pattern: two `schtasks /it` tasks, the identity scene
copied to a scratch `KAYA_SCENES_DIR` with a trailing settle, the shipped
scene never written). Tree at 4577da9, the shipped `IconSource` arm.

The promoted window's caption band, off UIA, whole subtree — the mark is
the unnamed `Image`:

```
MARK  TitleBar   ""        rect  86,79 480x48
MARK    MenuBar  ""        rect  86,83  49x40
MARK      MenuItem "File"  rect  90,87  41x32
MARK    Image    ""        rect 149,95  16x16      <- the mark
MARK    Text     "identity" rect 265,95 42x16      <- the title
```

**`File`, then the mark, then the title** — the ledger's finding, now with
numbers: the menu ends at 135 and the mark starts at 149, which is the
menu's right edge plus `TitleBarLeftHeaderPaddingWidth` (14). [MEASURED]

Three more things this run settles:

- **UIA publishes the mark with NO NAME** (`auto=""`, `Name=""`), so it is
  findable only by control type. That is the read side of the same gap as
  §5: nothing in the tree names the mark to an assistive client either.
- **The window's system menu is real and populated**: `GetSystemMenu` →
  7 items, `&Restore &Move &Size Mi&nimize Ma&ximize <sep> &Close`, with
  `SC_CLOSE` = 0xf060; the system's double-click interval is 500 ms.
  [MEASURED]
- **`WM_SYSCOMMAND`/`SC_KEYMENU` opens it on this window**: posted from
  outside the process, a `#32768` popup appeared at 34,56 and ESC
  dismissed it with the window alive. So `DefWindowProc` still owns the
  window menu on a WinUI 3 window with a custom caption. [MEASURED]

## 2. THE DECISION: `LeftHeader` FOR BOTH, `IconSource` DROPPED

`IconSource` is not kept for unpromoted windows, and the reason is that
there are none to keep it for: a `TitleBar` is minted by the FIRST
PROMOTION and by nothing else (`refresh_toolbar`), so the property is
reachable *only* on promoted windows — exactly the windows where the
control lays it out after `LeftHeader`. A window that promotes nothing has
no `TitleBar` at all and its mark is drawn by the SYSTEM caption from the
window icon, at the far left, which is already the convention. [REPO +
MEASURED: `captures/caption-1.png` from the identity slice shows it.]

So one path serves both, and the second sink is now: **the app's mark is
an `Image` in the first column of a container kaya owns, which IS
`LeftHeader`, with the `MenuBar` in the second column.**

The container is a two-Auto-column `Grid`, minted with the band itself in
`mint_caption_titlebar`. An Auto column with no child measures zero, so
every window in every scene that declares no identity is arranged exactly
as before — the claim the caption-centre lane phase re-measures in §4.

## 3. THE BAND AFTER THE MOVE, MEASURED THE SAME WAY

Same probe, same scene, same window, this tree:

```
MARK  TitleBar  ""              rect  86,79 480x48
MARK    Image   "Aurora Notes"  rect  86,95  16x16     <- the mark, FIRST
MARK    MenuBar ""              rect 118,83  49x40     <- 86 + 16 + 16
MARK      MenuItem "File"       rect 122,87  41x32
MARK    Text    "identity"      rect 265,95  42x16     <- unmoved: 265 before, 265 after
```

The caption-metrics discipline, at 946 wide, against the system cluster:

| element | rect | centre-y |
|---|---|---|
| system Minimize/Maximize/Close | 886/934/982, 78, 48x48 | **102** |
| promoted Save / More options | 782/830, 79, 48x48 | **103** |
| menu `File` | 122, 87, 41x32 | **103** |
| **the mark** | **86, 95, 16x16** | **103** |
| the title | 537, 95, 42x16 | **103** |

The mark is on the band's one centre line with everything else in it, at
the box the control gives its own icon (16), one pixel of client offset
from the system cluster — the same 1 px every other caption-hosted control
in this band has carried since the one-band revision. Its left edge is
x=86 against a visible frame starting at 85: the mark is the first thing
in the band, flush with the client's left edge, which is where the SYSTEM
caption draws it on every window that has no custom one.

**The mark is also NAMED to UIA now** (`Image "Aurora Notes"`, the declared
identity name) where before it was an unnamed `Image` the control built.
That is what lets an outside observer assert its presence at all — see §5.

## 4. THE AFFORDANCE: MEASURED, NOT WIRED — and here is the obstacle

The question was what a hand-placed caption icon can reach: click → the
window's system menu, double-click → close, the Win95-lineage convention.

**What IS there.** The window's system menu is real and populated —
`GetSystemMenu` answers a live `HMENU` with 7 items (`&Restore &Move
&Size Mi&nimize Ma&ximize` — separator — `&Close  Alt+F4`, `SC_CLOSE` =
0xf060), and `WM_SYSCOMMAND`/`SC_KEYMENU` posted from outside the process
opens it on this very window, at the client's top-left, dismissable with
ESC, window alive afterwards. So `DefWindowProc` still owns the window
menu on a WinUI 3 window with a custom caption. [MEASURED]

**What kaya can answer.** The tree already subclasses every window's
`WNDPROC` (`subclass`/`kaya_wndproc`, the close grammar), so an experiment
was cheap and I ran it: publish the mark's arranged rect (converted DIP →
physical through `RasterizationScale`, screen → client through
`ScreenToClient`) and answer `WM_NCHITTEST` with **`HTSYSMENU`** inside it.
That is the platform's own wiring for the whole convention — `DefWindowProc`
does the menu, the modal loop, the keyboard navigation, the placement AND
the double-click-to-close, with the user's own double-click interval.

**It answers correctly and IS NEVER ASKED.** Both halves measured on the
guest, in one run:

```
SYSMENU hittest caption-left at 93,94 -> 3      <- HTSYSMENU, from a direct SendMessage
SYSMENU hittest band-middle  at 326,94 -> 2     <- HTCAPTION

AFFORD hittest: (a) one click on the mark
AFFORD mark-click popups=0                      <- and ZERO hit tests reached the guest
AFFORD hittest: (b) one click on the band's drag surface at 133,46
AFFORD band-click popups=0                      <- but FIVE hit tests reached the guest:
    kaya: winui caption mark hit-test: client 99,20 against 0,16..16,32 -> not the mark   (x5)
AFFORD hittest: (c) a double click on the mark
AFFORD mark-doubleclick popups=0
AFFORD hittest: kaya windows after=2 window-alive=True
```

The discrimination is exact, and it is the point: **real pointer input over
the caption's DRAG surface does run the window's non-client hit test, and
real pointer input over the mark does not.** The mark rides in
`TitleBar.LeftHeader`, and the control publishes that whole presenter to
`InputNonClientPointerSource` as a **passthrough** region on every
recompute (`TitleBar.cpp:849-858` — the same behaviour kaya relies on to
keep the caption-hosted MENU clickable). Inside a passthrough region the
input system hands the pointer to the XAML content island; the top-level
window's `WM_NCHITTEST` is never consulted, so no answer kaya gives it can
be reached from where the ruling puts the mark. The dead arm was removed.

**What would work, and why it is not in this arm.** The platform's own
answer is to publish the mark's rect with the region kind that MEANS the
caption's icon:
`InputNonClientPointerSource.GetForWindowId(id).SetRegionRects(NonClientRegionKind.Icon, [rect])`.
`NonClientRegionKind` carries an `Icon` member — [MEASURED] by walking the
PINNED winmd, not from memory:

```
$ monodis --fields third_party/winappsdk/…/Microsoft.UI.winmd
308: valuetype Microsoft.UI.Input.NonClientRegionKind Close: public static literal
309: … Maximize    310: … Minimize    311: … Icon
312: … Caption     313-316: … borders  317: … Passthrough
```

and `IInputNonClientPointerSource` carries `SetRegionRects` /
`ClearRegionRects` / `GetRegionRects`. **It is absent from the generated
bindings** because `tools/winui-bindgen`'s filter never names
`Microsoft.UI.Input.InputNonClientPointerSource` or `NonClientRegionKind`
— and that file is outside this arm's file list, which is why this is a
finding and not a patch. Two entries and a regenerate.

One honest caveat to carry with it: the control re-publishes its own
passthrough rect for that presenter on every `RecomputeDragRegions`, so
whether an `Icon` rect kaya registers inside it wins is a question about
the input system's precedence that **cannot be measured until the binding
exists**. The estimate is one filter change plus one measurement, not one
filter change.

**The current behaviour, stated plainly:** clicking the mark does nothing,
double-clicking it does nothing, and the window's system menu is still
reachable the two ways it always was — Alt+Space and a right-click on the
caption's drag surface.

## 5. THE BUG THIS ARM FOUND ON THE WAY, AND ITS DIAGNOSIS

The first build of the reposition made every identity leg fail like this:

```
KAYA_SELFTEST: OK (identity, app icon E01B24/33D17A/1C71D8/F6D32D, …)
EXIT=-1073740791
identity_rust: FAIL (4s)
```

**The scene passed every step and the leg failed on the exit code alone,
with nothing printed anywhere.** Two hypotheses were wrong before the
evidence was fetched (a layout callback returning `Err`; the mark's own
`Image` — a bisect switch proved the abort survived with the mark turned
off). The answer came from the guest's Windows event log:

```
Faulting application name: identity.exe … Faulting module name: ucrtbase.dll
Exception code: 0xc0000409     BEX64  P9: 0000000000000007
```

`0xc0000409` with subcode **7** is `FAST_FAIL_FATAL_APP_EXIT` — the CRT's
own `abort`, in `ucrtbase`, not a XAML re-parenting fail-fast. And this
file already documents exactly that hazard, twenty lines from where the
fix belongs: after `Application::Start` returns, "XAML has torn down its
apartment… releasing XAML COM objects into the dead apartment is an access
violation", which is why `CORE` is `mem::forget`-ed there. `APP_ICON_BITMAP`
is a `BitmapImage` — a XAML object — in a thread-local, and its TLS
destructor runs after that line. It is now leaked beside the core, with
the measurement written next to it. `identity_rust: PASS`, `EXIT=0`.

Worth stating for the ledger: the pre-existing `APP_ICON_SOURCE` was the
same shape and did not abort, so this class of failure is latent in any
thread-local holding a XAML object in this backend. The rule is the file's
own and it is now written where the next one would be added.

## 6. THE CENTRING RE-PROOF: THE CLAMP DOES NOT MOVE, AND HERE IS WHY

The identity scene's own window, swept 1100 → 400 by real `SetWindowPos`
resizes, **the same probe run twice**: once against HEAD's `IconSource`
arm (`ip/old.log`) and once against this tree (`ip/new2.log`). DRIFT is
the title's centre-x minus the visible frame's centre-x, both read.

| window | OLD drift | NEW drift | OLD clamped | NEW clamped |
|---|---|---|---|---|
| 1100 | **0** | **0** | no | no |
| 900 | **0** | **0** | no | no |
| 800 | **0** | **0** | no | no |
| 700 | **0** | **0** | no | no |
| 640 | **0** | **0** | no | no |
| 600 | **0** | **0** | no | no |
| 560 | −1 | −1 | no | no |
| 520 | −21 | −21 | **clamped** | **clamped** |
| 480 | −41 | −41 | clamped | clamped |
| 440 | −61 | −61 | clamped | clamped |
| 400 | −81 | −81 | clamped | clamped |

**Identical at every width, drift for drift, and the clamp onset sits
between 560 and 520 in both.** The brief expected a shift of about the
icon's width; the measurement says zero, and the template says why: the
control's own icon column is **5** and `LeftHeader` is column **3**, and
both are LEFT of the content slot in column 8. Moving 16 DIP of mark plus
its 16 DIP margin out of one and into the other leaves the slot's left
edge exactly where it was, so `center_caption_title`'s `span0` — the max
of the slot's edge and the menu's right edge plus the gap — never moves.
The same fact read off the glass: the title's band-relative x at 946 is
**452 before and 452 after** (485−33 old, 537−85 new), and its rect at the
launch width is byte-identical, `265,95 42x16`, in both tree dumps.

What DID move is only what the ruling asked to move: the mark from
band-relative x=64 (after the menu) to **x=1** (before it), and the menu
from x=5 to x=37.

## 7. THE WATCHED NEGATIVES (both fired; restored from a saved copy)

Perturb-restore from a COPY with `shasum -a 256 -c` verifying the restore,
never `git checkout` (docs/traps.md, 2026-08-16). Each perturbation
printed and asserted its substitution count, so an unchanged file would
have been a failed test rather than a passed one.

**(a) The mark is never composed.** `substitutions: 1` — the one
`children.Append` in `refresh_caption_mark` removed. The wall fired, and
it named what it MEASURED rather than what it assumed:

```
thread 'main' (4024) panicked at crates/kaya/src/winui/mod.rs:3072:9:
kaya: winui: window 0 declared an app identity with a picture, and its promoted
caption's far-left container holds 1 element(s), none of which is the Image that
carries the mark (a MenuBar was found among them). …
identity_rust: FAIL (3s)
```

**(b) THE READ GAP, PROVED RATHER THAN CLAIMED.** Same perturbation plus
the wall's call disabled (`substitutions: 1`, `&& assert_caption_mark_geometry(…)?`
→ `&& true`). The leg **PASSED**, with a verdict byte-identical to the
healthy one:

```
KAYA_SELFTEST: OK (identity, app icon E01B24/33D17A/1C71D8/F6D32D, toolbar,
toolbar item Save done, title "identity", window#1 title "Aurora Notes",
clicked hi, app icon E01B24/33D17A/1C71D8/F6D32D)
EXIT=0        identity_rust: PASS (1s)
```

So the answer to the charge's question is measured: **`expect_app_icon`
reads only the WINDOW's icon** (`WM_GETICON`, with the window CLASS as its
documented fallback) and is blind to the caption mark — a promoted window
with no mark at all passes the identity scene twice over.

**How the gap is closed, and why there.** The mark's presence in the real
caption is now assertable in two places, neither of them kaya's model:

1. **In-process, on a path nobody can avoid** — `assert_caption_mark_geometry`,
   fired from the caption's own `LayoutUpdated` on every promoted window
   that declared an identity, measuring the ARRANGEMENT: the mark is in
   the container, it is arranged at the band's own icon box, its centre is
   the band's centre line, and it ENDS BEFORE THE MENU BEGINS. That is the
   same wall shape, in the same file, as `rehost_menubar`'s — and for the
   same stated reason: "where does this window's mark live in its caption"
   has no answer on the other four backends, which draw their own bands,
   so no shared harness verb could ask it uniformly.
2. **From outside the process** — the mark now carries the declared
   identity NAME as its `AutomationProperties.Name`, so UIA publishes
   `Image "Aurora Notes"` where it published an unnamed `Image` before.
   A screen reader gets the app's name; the probe gets an assertable
   element.

The alternative — extending `expect_app_icon`'s string — was not taken and
the reason is a rule, not a preference: `tools/scenes/*.steps` are compared
byte-for-byte across every language and platform, the other four backends
stub identity, and both that file and `crates/kaya/src/harness.rs` are
outside this arm's file list. **FOR THE MAINTAINER:** if the caption mark
should be scene-visible, the shape that fits is a second verb
(`expect_caption_mark`) with the same do/can't/defer sweep the identity
slice's depth stubs already carry — not a wider `app_icon` string.

## 8. THE CORNER MIRROR (maintainer's criterion, 2026-08-18)

> "ensure the icon on the toolbar is inset somewhat so that the top and
> left spacing is equal, so it mirrors how the X looks on the right. this
> is how vscode's icon looks."

**It composes cleanly with the caption-metrics rule, and the number is
derived rather than chosen.** A 16 DIP box vertically centred in the 48 DIP
band sits 16 DIP below the band's top — that is what centring means — so
the SAME 16 to its left makes the two insets equal by construction:

```rust
const CAPTION_BAND_HEIGHT: f64 = 48.0;                                  // TitleBarExpandedHeight
const CAPTION_MARK_LEAD: f64 = (CAPTION_BAND_HEIGHT - CAPTION_MARK_BOX) / 2.0;   // = 16
```

Nothing was invented and nothing was traded away: the centre line is still
the band's, because a symmetric horizontal margin cannot move it.

**Measured off UIA**, promoted window, band `86,79 480x48`:

| | rect | inset from the band's LEFT | inset from the band's TOP |
|---|---|---|---|
| the mark | `102,95 16x16` | **16** | **16** |

**Measured off the GLASS** (`ip/cornerscan.py`, ink boxes in the native-scale
capture; the mark by its four-quadrant signature, the X by its dark ink):

| corner | ink box | horizontal inset from the frame | vertical inset from the band's top |
|---|---|---|---|
| **the mark**, left | 16x16 at (16,16) | **16** | **16** |
| **the system X**, right | 10x10 at (730,19) | **20** | **19** |

The two corners now carry the same air on both axes — 16/16 against 20/19,
the 4 DIP difference being that the platform's Close GLYPH is 10 DIP inside
a 48 DIP cell while an app's icon is 16 DIP at the size the platform gives
icons (`TitleBarIconMaxHeight`). The mark's cell is now 16 + 16 + 16 = **48
DIP wide: one caption cell**, the same cell minimize/maximize/close and
kaya's own promoted commands occupy, so the band's left end starts on the
same rhythm its right end ends on.

For contrast, the same scan of the UNPROMOTED window, where the SYSTEM
draws the caption in its 32 DIP band: mark ink 16x16 at (8,6) — 8 left, 6
top — and the X's ink 19 right, 10 top. The system's own caption is not
symmetric either; the promoted band is now closer to the criterion than
the platform's own.

**The wall holds it.** `assert_caption_mark_geometry` measures both insets
off the arrangement and fails if they part, which is also what catches a
band that stopped being `CAPTION_BAND_HEIGHT` tall:

> …is arranged 16 DIP from the band's left edge and 16 DIP from its top,
> and those two have to be the same number: the mark mirrors the system's
> Close cell in the opposite corner…

**What the extra 16 DIP costs, measured rather than assumed.** The centring
sweep, re-run on the identity scene with the inset in (`ip/inset.log`):

| window | drift, mark flush | drift, mark inset | clamped |
|---|---|---|---|
| 1100 / 900 / 800 / 700 / 640 / 600 | 0 | **0** | no |
| 560 | −1 | −1 | no |
| 520 / 480 / 440 | −21 / −41 / −61 | −21 / −41 / −61 | clamped |
| 400 | −81 | **−74**, title ellipsized to 26 of 42 | clamped |

The centring clamp's ONSET is unmoved — still between 560 and 520, as it
was before the mark moved at all. What the 16 DIP does move is the
ELLIPSIS floor: at 400 DIP the span between the headers is finally 16 DIP
tighter than the title wants, so the title shortens instead of sliding
further left. That is the clamp doing its documented job at the one width
where the band is genuinely full, and it is the only number in the whole
sweep that the inset changed.

## 9. THE CAPTURES, LOOKED AT, AND MY OWN VERDICT

Native scale (the VM runs at 96 dpi — the 48 DIP caption cells measure 48
px), GDI `CopyFromScreen` of the composed desktop cropped to each window's
visible frame plus 2 px, each window brought to the FRONT before its own
shot (cropping two overlapping windows out of one desktop shot gives
whichever is on top, which is a crop that looks like a capture and is not).

- `captures/icon-promoted-2.png` — the PROMOTED window, 760 DIP wide:
  **the mark, `File`, `identity` centred, ✓ Save, "…", then — □ ✕.**
- `captures/icon-unpromoted-2.png` — the UNPROMOTED window: the SYSTEM
  caption, drawing the same mark from the window icon, beside the identity
  NAME filling a window that has no title of its own.
- `captures/icon-sysmenu-altspace.png` — the window menu the mark cannot
  open from where it lives, opened the way it still can be (Alt+Space):
  Restore/Move/Size/Minimize/Maximize/**Close Alt+F4**. It is in the report
  because §4's finding deserves a picture of what is being left on the
  table, and its placement — dropping from the caption's left corner,
  under the mark — is exactly where the convention would put it.

**My verdict, against VS Code's icon placement, on the symmetry
specifically: YES.** In `-2.png` the mark's corner and the close button's
corner now read as a matched pair — the mark is 16 in and 16 down, the X's
ink is 20 in and 19 down, and at a glance the two ends of the band have the
same amount of air around their glyphs. Before the inset the mark was
jammed against the window's border (1 DIP in, 16 down) and the left corner
looked crowded next to a right corner that was not; VS Code's icon has
exactly the breathing room this now has. The rest of the band is unchanged
and still reads as one row: one centre line (103) through the mark, `File`,
the title and both promoted commands, against the system cluster's 102.

Two things I would flag rather than have noticed:

1. **The mark is 16 DIP and the system's caption glyphs are 10.** That is
   the platform's own pair of sizes (`TitleBarIconMaxHeight` is 16; the
   caption buttons draw a 10 DIP glyph in a 48 DIP cell), the same
   observation the one-band arm ended on, and it is why the two corners
   measure 16/16 and 20/19 rather than the same number twice.
2. **The unpromoted window is the SYSTEM's caption and does not follow this
   rule** — its icon is 8 in and 6 down in a 32 DIP band. kaya cannot move
   it and should not want to: that band is Windows' own.

## 10. THE SUITES, THE UNIT TESTS AND THE GATES (final tree)

```
tools/deploy-win.py akhil@192.168.64.2 all
    rc=0   legs: 171 {'PASS': 171}   FAILs: []
    deploy-win: 4/4 unit tests passed on the guest (capi::picked_tests)
    deploy-win: 8/8 unit tests passed on the guest (winui::tests)
    deploy-win: caption title aimed at the window's centre — 11 widths
                measured, 6 unclamped, all at DRIFT 0
```

**THE VERDICTS, BYTE-COMPARED programmatically** against the pre-change
lane at 4577da9 (`chrome/.lane-full.log`), pids normalised, by a comparator
that REFUSES A VERDICT rather than reporting agreement if it read no
verdicts on either side:

```
verdicts shared=171  identical=166  different=5
different: stall_csharp, stall_go, stall_java, stall_python, stall_rust
```

and those five differ only in the milliseconds their own verdicts measure
(`stalled 1010ms` against `stalled 1006ms`) — the legs whose text embeds a
measured duration. **The twelve focus legs are byte-identical:**
`identity_rust`, `toolbar_{rust,python,go,csharp,java}`,
`menus_{rust,python,go,csharp,java}`, `editor_go`.

The caption-centre lane phase's own clamp table, beside the one
`winui-title-center.md` §4d recorded when the rule landed:

| toolbar scene | 640 | 600 | 560 | 520 | 480 |
|---|---|---|---|---|---|
| drift then | −8 | −28 | −48 | −64.5 | (below the floor) |
| drift now | **−8** | **−28** | **−48** | **−64.5** | absent (the floor) |

Identical — which is the point: the toolbar scene declares no identity, so
its caption has no mark, and an empty Auto column measures zero.

```
cargo test -p kaya --features harness --locked   366 + 3 + 13 passed, 0 failed
tools/gates.py    declared 34, ran 34, passed 33
                  the one FAIL is check-sugar-surface, and it is the
                  STANDING designed red of the identity slice: the same 7
                  bindings still owe `app_identity` sugar (python, go,
                  csharp, java, swift, haskell, ocaml). Untouched by this
                  arm; it goes green when the fan-out lands.
tools/check-targets.py   native / ios / android / windows / go-android
                         ALL OK, BOTH feature configurations
```

## 11. THE ALL-BINDINGS SWEEP (invariant 2)

No binding surface, no protocol surface, no spec movement, no generated
file, no scene: one backend file.

| language | verdict |
|---|---|
| Rust, Python, Go, C#, Java | **DO** — every promoted window on this backend gets the repositioned mark; all 171 lane legs pass with byte-identical verdicts. Only `identity_rust` DECLARES an identity today, so it is the only leg whose caption carries a mark — the others exercise the empty-column path |
| Swift, OCaml, Haskell | **DEFER on this lane only** — no toolchain on the VM; their guests run the identical scenes on the mac/iOS/linux runners, none of which this touches |
| C floor | **DEFER** — no `guests/c/toolbar.c (gone)` exists; there is no leg to write |

Invariant 1 has nothing to say here: WHERE a backend draws the app's mark
inside its own caption is a lowering-fidelity fact, not a behaviour an app
can observe. The other four backends draw their own bands and three of them
still carry the identity depth stubs the previous slice logged.

## 12. WHAT THE COORDINATOR MUST CARRY FORWARD

1. **The caption-icon affordance is two bindgen filter entries plus a
   measurement away** (§4): `Microsoft.UI.Input.InputNonClientPointerSource`
   and `NonClientRegionKind` in `tools/winui-bindgen`'s filter, then
   `SetRegionRects(NonClientRegionKind.Icon, [rect])` on every layout pass,
   then a measurement of whether an `Icon` rect registered INSIDE the
   control's own passthrough rect wins. Until then, clicking the mark does
   nothing, which is stated rather than hidden.
2. **The read gap is closed by a wall, not by a scene** (§7). If the
   maintainer wants it scene-visible, the shape is a new harness verb, not
   a wider `expect_app_icon` string.
3. **Any thread-local holding a XAML object in this backend needs the
   leak-at-shutdown rule** (§5) — `APP_ICON_BITMAP` now has it; the older
   `APP` slot does not and has not bitten yet.
4. Still outstanding from earlier arms, unchanged: the `tools/` census that
   `TitleBar::new()` appears only inside `mint_caption_titlebar` — which
   this arm makes more valuable, since that function now also mints the
   only thing that may ever be `LeftHeader`.

## 13. CLEANUP, PROVEN

- **VM scheduled tasks**: `schtasks /query /fo list` grepped for
  `kaya_ip|kaya_tcp` → **`<none>`**. (The ~190 `kaya_<leg>` tasks that
  remain are `deploy-win.py`'s own per-leg launchers and predate this
  session.)
- **VM scratch**: `C:\Users\akhil\kaya-ip`, `C:\Users\akhil\kaya-tc-probe`
  and the `evt.ps1`/`cleanup.ps1` helpers I pushed → all **ABSENT** after
  removal, checked by `Test-Path` and `dir` (`File Not Found`).
- **VM processes**: `Get-Process` filtered for
  identity/toolbar/menus/editor/record-win/wscript/python/java/dotnet/go →
  **`<none running>`**.
- **VM temp**: `%TEMP%` directories matching `kaya-` swept; count after
  the sweep **0**.
- **The shipped scenes were never written**: `C:\kaya\scenes\`'s
  `identity.steps`, `toolbar.steps`, `menus.steps` and `editor.steps` hash
  EQUAL to `tools/scenes/`'s copies (SHA-256, first 16 hex digits compared
  on both sides: DE1D40E2…, DCFFEF0E…, D52F4635…, C14543DF…). Every
  scratch scene rode `KAYA_SCENES_DIR`.
- **Host processes**: `ps -Ao pid,etime,pcpu,command` grepped for
  deploy-win / record-win / icon-probe / ffmpeg / ffprobe / `192.168.64.2`
  → **none**; the one ssh control-master socket was closed explicitly
  (`ssh -O exit`) and the grep now counts **0**. Top-CPU shows only macOS
  Spotlight and the Android emulator, both weeks old and predating this
  session.
- **Disk**: this arm's scratch (`scratchpad/chrome/ip (gone)`) is **3.0 MB**;
  session scratchpad **135 MB**; host free **414 GB**.
- **Repo**: `git status` shows exactly one path,
  `crates/kaya/src/winui/mod.rs`. Nothing committed; nothing pushed.

## 14. FILES

Changed: `/Users/akhilindurti/Projects/kaya/crates/kaya/src/winui/mod.rs`
(+352 / −40).

Captures:
`scratchpad/chrome/captures/icon-promoted-2.png (gone)`,
`icon-unpromoted-2.png`, `icon-sysmenu-altspace.png`.

This arm's instruments (scratch, not the tree):
`scratchpad/chrome/ip/icon-probe.{sh,ps1} (gone)` (the driver and the probe:
tree dump, band metrics, system-menu facts, the hit-test discrimination,
the width sweep, the captures), `ip/marklocate.py`, `ip/cornerscan.py`,
`ip/inkscan.py` (a dependency-free PNG reader), and the run logs
`ip/{base2, new2, hit, old, inset, lane, lane2, gates, gates2, neg-a, neg-b}.log`.
