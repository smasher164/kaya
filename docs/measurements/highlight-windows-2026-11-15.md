# The highlight mark on WinUI 3 and RichEdit's RTF reader — measured 2026-11-15

For docs/highlight-plan.md §3 (H2's WinUI item) and §1 (which RTF spelling a
Windows reader takes). The guest: Windows 11 build 26200.9974 on the UTM VM.

**WordPad is not there.** `where wordpad` finds nothing and `C:\Program
Files\Windows NT\Accessories` does not exist: WordPad was removed in Windows 11
24H2. WordPad was a RichEdit host, and so is WinUI's `RichEditBox` (its RTF
writer names itself `Riched20 12.6.0005`), so the probe reads RichEdit
directly; Word itself is not on the guest, and its reading stays secondhand.

**Method.** `highlight-windows-2026-11-15/` (Program.cs, a WinUI 3 app with one
`RichEditBox`, built on the guest with WindowsAppSDK 2.2.0 and run through
`run.py`, a one-shot `/it` scheduled task deleted afterwards). R1 loads five
RTF texts with `SetText(FormatRtf)` (colour table entry 1 is `#FFEB3B`) and
reads each character's `CharacterFormat.BackgroundColor`, then
`GetText(FormatRtf)` to see what RichEdit writes. S1 writes the mark's value
`#F7E8AF` over a word and find's `#FFF18F` over half of it. T1 switches the
root's `RequestedTheme` to Dark and back. Output: `highlight-windows-2026-11-15/log.txt`.

**R1, RichEdit's RTF reader.**

| loaded | read back | RichEdit writes |
|---|---|---|
| `\highlight1` | `FFFFEB3B` on the run | `\highlight1 … \highlight0` |
| `\cb1` | nothing (automatic `00000001`), and the colour table is dropped | no background |
| `\chshdng0\chcbpat1` | `FFFFEB3B` | `\highlight1` |
| `\highlight1\cb1` | `FFFFEB3B`, once | `\highlight1` |
| `\highlight1 MA\highlight0 RKED` | the first two characters only | (as loaded) |

So RichEdit is Cocoa's mirror image: it reads `\highlight` and `\chcbpat` and
IGNORES `\cb`, where Cocoa (docs/highlight-plan.md §1, textutil) reads `\cb`
only. Writing `\highlightN\cbN` (H6 A) is read once by each; `\highlight0`
clears.

**S1, the one slot.** Each write replaces the character's `BackgroundColor`
exactly, with no blend: after the mark and then find over half, the word reads
`FFF7E8AF` then `FFFFF18F`. A run carrying both reads as find's, which is what
`painted_runs`' exact compare needs.

**T1, a theme switch.** The BACKGROUND survives a switch untouched in both
directions (`FFF7E8AF` and `FFFFF18F` after Dark and after Light). The
FOREGROUND does not: every character's automatic `00000001` becomes an
explicit `FFFFFFFF` after Dark and `FF000000` after Light, the rewrite of
microsoft-ui-xaml #6908 that `drawn_color` already answers. So the control
never moves the mark's colour by itself: the dark value is kaya's to write,
and `redraw_later` after `ActualThemeChanged` must rewrite the slot (it
already re-derives the whole display, find's colour included).
