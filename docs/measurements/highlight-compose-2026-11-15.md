# The highlight mark on Compose: drawn behind the field, under the selection, and on the accessibility node — measured 2026-11-15

For docs/highlight-plan.md §3 (H2's Compose item): with the mark drawn BEHIND
a `BasicTextField` (KayaHighlightLayer's route, `drawBehind` from the layout's
boxes), are the glyphs legible under the field's own selection wash, and what
does the accessibility node carry for a highlighted run.

**Method.** `highlight-compose-2026-11-15/` is a standalone app at kaya's own
pins (AGP 8.7.3, Kotlin 2.0.21, compileSdk 36, foundation 1.11.4, Material 3
from BOM 2024.10.01), built with the dev shell's gradle and driven by
`drive.py` on the pool's `emulator-5554` (API 35, 360x800): installed, started
light (`lightColorScheme`, white page, mark `#F7E8AF`) and dark
(`darkColorScheme`, `#1E1E1E` page, mark `#594C1A`), photographed with
`screencap`, uninstalled (`packages left: none`). Field one draws the mark in
`drawBehind` and holds the selection over the marked word; field two, the
control, gives the same word `SpanStyle(background)` through an
`OutputTransformation`. `pixels.py` reads the commonest colour inside the word
and the glyph colour (the pixel farthest from it) off each shot. The app also
walks the compose view's `AccessibilityNodeProvider` and logs every node
holding the word with every span on its text (`log-light.txt`, `log-dark.txt`).

**Under the selection** (Material 3's wash is `primary` at alpha 0x66: `#6750A4`
light, `#D0BCFF` dark):

| | ground read | glyph | contrast |
|---|---|---|---|
| light, mark selected | `BDABAB` | `1D1B20` | 7.79:1 |
| light, mark unselected (control) | `F7E8AF` | `1D1B20` | 13.92:1 |
| light, page selected (computed) | `C2B9DB` | `1D1B20` | 9.15:1 |
| dark, mark selected | `887976` | `E6E0E9` | **3.21:1** |
| dark, mark unselected (control) | `594C1A` | `E6E0E9` | 6.55:1 |
| dark, page selected (computed) | `655D78` | `E6E0E9` | 4.78:1 |

The selection composites OVER the mark (the measured ground equals the
computed blend of the wash over the mark, `897976`, within one step), so the
order find-over-mark-under-selection holds by construction. In the light
appearance the selected text stays well above the floor. In the dark one, the
wash over the dark mark is LIGHTER than the wash over the page, and selected
text reads 3.21:1, under 4.5:1, where selected text on the plain page reads
4.78:1.

**On the accessibility node.** Both fields publish an `EditText` whose text is
`plain MARKED plain` with NO spans at all, the control's
`SpanStyle(background)` included. So TalkBack is handed nothing about a
highlight on either route; the drawn mark is not a loss against the span.
(What TalkBack speaks was not recorded, only what it is given.)

**For the build.** Drawing behind the text is legible in the light appearance.
For the dark one the build has two answers within H3 A ("the selection paints
over everything"): accept 3.2:1 while a selection lasts, or skip the mark
under the selected bytes so a selection reads as it does on the page (GTK's
and RichEdit's own selections REPLACE a background rather than blend over it).
docs/highlight-plan.md records which was taken.
