# The rich document on WinUI: TOM lists and a run's colour, measured

The plan's §9 step 0 for the WinUI arm (docs/rich-document-plan.md §6, the
WinUI row). A C# WinUI 3 probe (`richdoc-winui-2026-11-11/Program.cs`, rounds
2 and 3; round 1 is `Program-round1.cs`), copied from the 2026-09-11 rich text
probe, run on the lane's Windows 11 arm64 VM (`akhil@192.168.64.2`, Windows
App SDK 2.2.0) as a `/it` scheduled task, its staged directory and its task
deleted after each run. One RichEditBox carrying kaya's plain-text pins
(`pin_plain_text`), the seed `Apples\rGreen ones\rBread\rWash\rSlice\rMilk\rEggs\rTail`.

## 1. A TOM list paragraph moves no offset (the charge's question 1)

Setting `ListType`, `ListStart`, `ListLevelIndex` and `ListStyle` on
paragraphs leaves `StoryLength` at 50, `GetText(AdjustCrlf | NoHidden)`
byte-identical, every paragraph's first character at the same cp, and a caret
`SetRange(n, n)` at `n` (log-run1.txt, L2). The marker text appears only with
`IncludeNumbering`, as `<marker>\t` before the paragraph: `"⦁\tApples"`,
`"1.\tWash"`. So a native list is not the hidden-field trap a TOM link is.

## 2. What the native markers can and cannot say

- `MarkerType.Bullet` draws U+2981 (⦁) at EVERY level (levels 1 to 3 read the
  same, `marker-types.png`), and IGNORES `ListStart` as a bullet character
  (`bullet-start-ignored.png`, left: `ListStart` 0x2022, 0x25E6, 0x25AA all
  draw ⦁, and `IncludeNumbering` then reads no marker at all).
- `MarkerType.UnicodeSequence` with `ListStart` = a character draws that
  character (◦, ▪ exactly), but it IS a sequence: consecutive items with the
  same `ListStart` at the same level count up (`•`, `‣`, `․`, `‥`; log-run2.txt
  B1), the count runs on across a deeper item between (B1 para 5), and
  alternating `ListTab` does not break it (B2). Raw `MarkerStyle` values
  outside the enum throw "Value does not fall within the expected range" (B3).
- Numbers: an item restarts at its own `ListStart` when it differs from the
  previous item's at its level, and continues the count when it is equal
  (`list-start.png`: 1, 5, 9 read `1. 5. 9.`; 1, 1, 1 read `1. 2. 3.`).
- The marker wears the PARAGRAPH MARK's character format: its font (U+2610
  draws only when the mark is in Segoe UI Symbol, `indents-and-mark-font.png`
  rows 1 to 3) and its colour (`bullet-start-ignored.png`, middle: a red mark
  draws a red `3.`).
- `ListLevelIndex` moves nothing on screen; the indent is the paragraph's own
  `SetIndents(first, left, right)`, the marker drawn at `left + first`
  (hanging) and the text at `left` (`indents-and-mark-font.png` rows 5 to 7).

So kaya's marker vocabulary (§2: `•`, `◦`, `▪` by level, every item the same
bullet; `[ ]` and `[x]` as the platform's own box) has no native spelling on
this control: the bullet that varies by level counts up, and the bullet that
repeats cannot vary. THE WINUI ARM DRAWS ITS MARKERS (a correction to the
plan's §6 table, which says NATIVE): the indent is native (`SetIndents`), the
marker is a XAML overlay laid on the RichEditBox's template from the core's
`richdoc::markers`, and a checklist item's box is a real `CheckBox`.

## 3. Keys on an unformatted RichEditBox (real keybd_event)

`PreviewKeyDown` sees Tab, Shift (then Tab), Back and Enter, unhandled, before
the control acts (log-run1.txt, K). An unhandled Tab inserted NOTHING, in a
plain paragraph or at a list item's start, and the focus stayed (Keyboard);
Shift+Tab changed nothing; Back at a list item's first character took the
list off natively with the text unchanged; Return at a paragraph's end added
an empty paragraph.

## 4. Copy (for the clipboard flavours)

`ITextSelection.Copy` and Ctrl+C raise `CopyingToClipboard`; `ITextRange.Copy`
does not (log-run1.txt, C). So the menu's copy (`perform_clipboard_role`,
which copies through a range) and the control's own copy are two doors.

## 5. A run's colour across a theme switch (the charge's question 2)

microsoft-ui-xaml #6908 reproduces: a run set to `#016FEF` under the Light
theme reads `#FFFFFFFF` after the root's `RequestedTheme` goes Dark, and
`#FF000000` after it comes back to Light; every run is rewritten to the
theme's text colour (`theme-switch.png`: blue, then white, then black). The
arm re-derives every run's format after `ActualThemeChanged`.

## 6. A coloured run is drawn at the focused text brush's alpha

Measured on the lane after the arm was built: a `color` run of `#016FEF`
read `#1C7EF1` off the window (`#DD1F24` read `#E1373B`, `#8D4DE0` read
`#9960E3`), every channel `255 - (255 - c) * 0.894`, and the probe's own
`theme-switch.png` (row 1, the bare control) draws the same `#1C7EF1` plateau
for `#016FEF`, while automatic black text draws `#000000`. 0.894 is 0xE4/0xFF:
the RichEditBox template's Focused state draws text through
`TextControlForegroundFocused`, `#E4000000` under Light, and a run's own colour
takes that brush's alpha. The arm gives a rich textarea its own opaque
`TextControlForeground`, `...PointerOver` and `...Focused` (`#FF1B1B1B` under
Light, which is what `#E4000000` composites to; `#FFFFFFFF` under Dark), set
before the template is applied. Setting `Foreground` instead rewrote every
run's colour to the brush's, as a theme switch does (§5), and so does the
template's first load, so the arm derives the display again a dispatcher turn
after `Loaded`.
