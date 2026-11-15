# The highlighter pen: a named background colour on document text (RD6's slice)

Status: RULED 2026-11-15, H1 to H8 A as recommended, and both assumptions in
§6's "Beyond these" as the plan assumes them (the maintainer: "i accept your
rulings there as given"). §5 steps 0 and 1 are built (2026-11-15: the
measurements under docs/measurements/highlight-*-2026-11-15.md and the root).
H1's hexes RULED 2026-11-15 on the review page (the maintainer: "im okay with
your recommendations"): recipe A as built, A' not taken; and with them the
selection rule in H3 below.

The maintainer, 2026-11-15: "yes, let's do the highlighter pen." This plan is
the design pass for RD6 of docs/rich-document-plan.md, which RULED A on
2026-11-11: a highlight comes later, "as a closed palette of names with
designed light and dark values (Notes' five; Word's `w:highlight` is a palette
for the same reason)", because "a free background under free text has no
contrast answer". It sits on that plan's §2 (the model: one text, inline marks
with an expand rule, paragraph attributes), §5 and §11 (the `color` mark and
`brand::ink_for_dark`), and on docs/rich-text-plan.md §18 (the one WinUI
background slot shared by find, a code run's ground and a quote's tint). The
code it reads is crates/kaya/src/richdoc.rs, richdoc/kdoc.rs, richdoc/clip.rs,
crates/kaya/src/brand.rs and the `highlight_ranges` records of
crates/kaya/src/spec.rs.

## §0. The mechanism, from zero

**What a highlight is, to the document.** The rich document is one string plus
RUNS, each run one attribute over one byte range (`bold`, `color=#DD1F24`,
`link=https://…`). A HIGHLIGHT is one more inline mark, `highlight`, whose
value is the NAME of a colour from a short fixed list (`yellow`, `blue`, …).
It is saved in the `.kdoc` like bold, copied to the clipboard like bold, and
typed over like bold: text typed at the end of a highlighted word is
highlighted (the mark's EXPAND RULE, RD7, is "grows at its end, not at its
start", the row §2 of the rich document plan already reserved for it).

**What it is not.** kaya already has `highlight_ranges`: the APP declares a
set of byte ranges on a textarea and the backend paints them yellow until the
text changes (the find bar's matches). That set is the app's, transient, never
saved, never on the clipboard, dropped by the first keystroke, and it is not a
mark in the document at all. This plan calls that set FIND'S HIGHLIGHT and the
new mark THE HIGHLIGHT MARK (or the pen), and §4 says which wins where they
overlap. The verb that reads find's set, `expect_highlights`, must keep
reading only find's set after this slice (§7).

**Why a palette and not a colour picker.** A text colour has one thing behind
it, the page, and RD5 solved its dark appearance with one function: move the
colour's lightness until its contrast against the dark page equals what it had
against the light page, never below 4.5:1 (`brand::ink_for_dark`). A
BACKGROUND has text on top of it, and that text is either the page's own ink
(black in the light appearance, white in the dark one) or a `color` run the
user chose. A background the user picks freely can defeat every one of those:
a dark blue highlight under black text is unreadable in the light appearance,
and whatever a dark page does to it, the white ink on top has its own needs.
No product has an algorithm for this; the ones that let you pick freely
(Pages' character fill, Google Docs' custom colour, Word's `w:shd`) simply let
you make unreadable text, and the ones that care about the dark appearance
(Notes since iOS 18, Notion) give you NAMES and design each name's value
twice, once per appearance. A closed palette is the design that has a contrast
answer, and it is also what the maintainer's ruling asked for.

**Terms.** CONTRAST RATIO is WCAG's number for two colours, from 1:1 (the
same) to 21:1 (black on white); 4.5:1 is the floor for body text and the one
`brand.rs` already enforces. OKLCH is a colour space whose three numbers are
perceived lightness L (0 to 1), chroma C (how far from grey) and hue h (an
angle); moving L keeps the colour's identity, which is why RD5 works in it.
THE GROUND is this repository's word for the fill drawn behind a run (a code
run's grey, a quote's tint, find's yellow); the highlight mark is a ground the
document owns.

## §1. What the products do (the research)

| product | the palette | custom colour | dark appearance | storage and exchange |
|---|---|---|---|---|
| Apple Notes, iOS 18 and macOS 15 | FIVE names: purple, pink, orange, mint, blue | no ("there is no option for custom colors") | designed per appearance (the names are the storage) | protobuf `AttributeRun.emphasis_style`, an `int32` (field 14), in the note's gzipped blob; applying a highlight also tints the TEXT the same hue ("Both the text and the background turn the selected color") |
| Word (`w:highlight`) | SEVENTEEN values, sixteen colours plus `none`: black, blue, cyan, darkBlue, darkCyan, darkGray, darkGreen, darkMagenta, darkRed, darkYellow, green, lightGray, magenta, red, white, yellow, each with a fixed RGB in the spec (yellow FFFF00, cyan 00FFFF, darkBlue 000080, …) | not through highlight; `w:shd` is the free shading | the colours are fixed; Word's dark mode shifts the page and "mutes" colours by an unpublished map | RTF `\highlightN`, an index into the colour table |
| Google Docs | the toolbar's Highlight color shows the same preset grid the text colour uses, plus "create a custom color" by hex or RGB | yes | the phones' dark theme adjusts colours by an unpublished map | HTML `<span style="background-color:…">` on the clipboard |
| Notion | NINE background names: gray, brown, orange, yellow, green, blue, purple, pink, red (and `default`) | no | each name has a value per theme; the public reimplementation react-notion-x carries them, for example yellow `rgb(251,243,219)` light and `rgb(89,86,59)` dark | the API returns the NAME (`yellow_background`), never a value |
| Pages | the Font section's Text Background: the template's swatches, or the colour wheel ("choose any color") | yes | the canvas stays white | character fill; the separate review Highlight is a comment that "don't appear in printed documents" |
| HTML (the browsers) | `<mark>` draws `background: yellow; color: black` by the WHATWG user-agent stylesheet; CSS Color 4 adds the system colours `Mark` and `MarkText` so a theme can override both | n/a | the system colours follow the theme; a literal `background-color` does not | `<mark>` or `background-color` in `style` |

Sources: https://www.macrumors.com/2024/06/11/ios-18-notes-app-colors/ ,
https://github.com/threeplanetssoftware/apple_cloud_notes_parser (proto/notestore.proto),
https://webapp.docx4java.org/OnlineDemo/ecma376/WordML/ST_HighlightColor.html ,
https://support.google.com/docs/answer/13267978 ,
https://developers.notion.com/reference/rich-text ,
https://github.com/NotionX/react-notion-x (packages/react-notion-x/src/styles.css),
https://support.apple.com/guide/pages/add-a-highlight-effect-to-text-taned4110e43/mac ,
https://html.spec.whatwg.org/multipage/rendering.html ,
docs/rich-document-plan.md §1.6, §1.7 and §1.10 (Word's and Docs' dark
appearance, Notion's per-theme names).

**RTF has three spellings for a background**, and no two writers agree. The
specification (RTF 1.5 text at https://www.biblioscape.com/rtf15_spec.htm ;
1.9.1 unchanged) defines `\cbN` "Background color (the default is 0)",
`\highlightN` "Highlights the specified text. N specifies the color" (a colour
table index) and the character shading pair `\chshdngN` plus `\chcbpatN` ("the
fill color, specified as an index into the document's color table"). Measured
on this Mac today (macOS 26.6.2, `textutil`): Cocoa WRITES a run's
`.backgroundColor` as `\cbN`, with the colour in `\colortbl` and its sRGB (and
alpha, as a fourth `\c` when translucent) in `{\*\expandedcolortbl}`; and Cocoa
READS `\cbN` only: a run marked `\highlight1` and one marked
`\chshdng0\chcbpat2` both came back with no background, while `\cb1` came back
`background-color: #ffeb3b`. Word is reported to go the other way, writing
`\highlightN` for its highlighter and `\chcbpatN` for shading and ignoring
`\cb` (secondhand: the RTF Pocket Guide as quoted at
https://kiwix.lema.org/stackoverflow.com_en_all_2023-11/questions/19422580/cb-not-working-for-rtf
and https://www.trichview.com/forums/viewtopic.php?p=12293 ; the build measures
it on the Windows guest with WordPad, §8 step 0). So kaya's RTF must READ all
three and WRITE two (`\highlightN\cbN`, one colour table entry), which Cocoa
and Word each read as one background.

## §2. What kaya has today, and what the pen must fit

- **The `color` mark and its dark map** (rich document plan §11): a run's
  stored colour is drawn as it is on the light page and as `ink_for_dark` of
  it on the dark page, through one door (`kaya_ink_for_dark`) every arm calls:
  the Mac and iOS through a dynamic colour whose provider calls it
  (`kayaDocumentInk`), GTK on `notify::dark` (`rich_ink`), Compose when its
  palette re-resolves (`kayaDocumentInk`), WinUI after `ActualThemeChanged`
  (`drawn_color`, re-derived a turn later because a theme switch rewrites every
  run's foreground, microsoft-ui-xaml #6908). The Format menu's eight presets
  read at 4.6:1 to 4.9:1 on both pages.
- **Find's highlight** (`highlight_ranges`, spec kinds 38 and 28): paints
  `NSTextStorage.backgroundColor` systemYellow at 55% on the Mac and iOS (the
  one of three macOS mechanisms accessibility can see,
  docs/probes/range-probe-mac.md), the `kaya-highlight` GtkTextTag `#ffe066`
  with `background-full-height` on GTK, `KAYA_HIGHLIGHT_COLOR` `0x8CFFEB3B`
  drawn in `KayaHighlightLayer`'s `drawBehind` from the layout's boxes on
  Compose, and `HIGHLIGHT_BACKGROUND` `#FFF18F` (the 55% yellow flattened)
  through `ITextCharacterFormat.BackgroundColor` on WinUI.
- **The grounds the document already draws** (rich-text plan §18): a code
  run's ground and a quote's tint. On the Mac and iOS they are NOT
  `.backgroundColor`: `KayaRichFragment` paints them from kaya's own attribute
  keys (`kaya.draw.ground`, `kaya.draw.rule`) and then calls `super.draw`, so
  find's storage attribute lands on top, and a ground in `.backgroundColor`
  would be wiped by `applyRanges`' clear and read back as a highlight
  (measured 2026-09-15). On GTK the code ground is the tag's
  `background-rgba` and the quote's tint `paragraph-background-rgba`; the
  highlights read keys on `bg-full-height` ALONE, which only find's tag carries,
  after a code ground read as a find match. On WinUI there is ONE
  `BackgroundColor` per character and `rich_ground` states the order (find over
  code over quote), `rich_repaint_highlights` puts find back after every
  restyle, and the highlights read `painted_runs` compares to
  `HIGHLIGHT_BACKGROUND` exactly. On Compose the code ground is
  `SpanStyle(background = palette.code)`, drawn by the text itself, which sits
  ABOVE anything `KayaHighlightLayer` draws behind.
- **The reads a scene has**: `expect_runs` (the core's document), `expect_text_ink
  <target> <start:end> "light RRGGBB dark RRGGBB"` (the run's glyph colour off
  the window's own pixels, the pixel farthest from the commonest colour inside
  the run's cells, in both appearances), `expect_highlights` (find's set, per
  platform's own tree or pixels).

## §3. The proposal

**The mark.** `highlight`, an inline mark whose value is one of the palette's
names; `rich_attr` grows `highlight` 14 and the spec gains the enum
`highlight_color` (`none` 0, then the names), so every binding spells the names
from one table (invariant 7; `canonical_value` answers `none` as the mark's
absence, like `body` and `start`, and refuses any other spelling naming the
vocabulary). It grows at its end and not at its start (`expands_at_end`, RD7's
table). It is legal on any paragraph kind and on a rich label. The `.kdoc`
writes it as `{"highlight": "yellow"}` in a span's marks, after `color` in the
inline order (bold, italic, underline, strike, code, link, color, highlight,
then extensions). A reader older than this slice meets a dotless mark it does
not know and opens the file READ-ONLY naming it (RD8, already built), which is
the right answer: nothing is lost and nothing is silently kept wrong.

**The palette (H1).** Six names, each with a light value and a dark value
designed in OKLCH and held by a test, not by eye: `yellow`, `orange`, `pink`,
`purple`, `blue`, `green`. That is Notes' five with `mint` called `green`, plus
`yellow`, the pen everybody owns and the colour `<mark>` and Word's default
mean. The recipe: the light value is L 0.93 at the name's hue with chroma as
far as sRGB allows up to 0.075; the dark value L 0.42, chroma up to 0.07.
Every light value under black reads above 16:1 and every dark value under
white above 8:1; the inks that matter are the platforms' label colours (near
black and near white), so black and white are the bounds. The table (computed
with a Python port of `brand.rs`'s functions, checked against the three
`ink_for_dark` values richdoc.steps measured):

| name | hue | light value | contrast under #000000 | against the white page | dark value | contrast under #FFFFFF | against the #1E1E1E page |
|---|---|---|---|---|---|---|---|
| yellow | 95 | `#F7E8AF` | 17.1:1 | 1.23:1 | `#594C1A` | 8.5:1 | 1.96:1 |
| orange | 60 | `#FFE2CB` | 17.0:1 | 1.24:1 | `#694323` | 8.7:1 | 1.93:1 |
| pink | 350 | `#FFDDEC` | 16.8:1 | 1.25:1 | `#6A3C52` | 8.8:1 | 1.89:1 |
| purple | 305 | `#EEE1FF` | 16.9:1 | 1.25:1 | `#56436C` | 8.7:1 | 1.92:1 |
| blue | 245 | `#D5EBFF` | 17.2:1 | 1.22:1 | `#295171` | 8.4:1 | 1.99:1 |
| green | 160 | `#BDF8D7` | 17.6:1 | 1.20:1 | `#255940` | 8.1:1 | 2.05:1 |

For scale: find's `#FFF18F` reads 1.15:1 against the white page, Notion's dark
yellow `#59563B` 2.24:1 against `#1E1E1E`. At L 0.93 sRGB clips orange, pink,
purple and blue at chroma 0.036 to 0.044, so those four are the most saturated
pastels the gamut has; yellow and green reach the cap. A second recipe for the
review page: chroma up to 0.11 gives yellow `#FFE891` and green `#A4FFCF` and
leaves the other four as they are. The hex values are what the build's review
page shows the maintainer first; the guard holds the floors (every light value
at 7:1 or better under black, every dark value at 7:1 or better under white,
every pair distinct from its page by 1.15:1 or more), not the hexes.

**A `color` run under a highlight (H4).** Without a second map the eight
presets read at 3.7:1 to 4.1:1 on the light values and 2.3:1 to 2.6:1 on the
dark ones, all under the floor: the presets were designed against the pages,
and any visible tint lowers them. The recommended answer generalises RD5: the
core draws a `color` run at `contrast_matched(stored, ground, max(contrast on
the white page, 4.5))` where `ground` is the page, or the highlight's value for
this appearance when the run is highlighted. That is `ink_for_dark` with the
page made a parameter (`brand::ink_on(rgb, ground)`), one door
(`kaya_ink_on`), and it moves the ink a little rather than the highlight: red
`#DD1F24` draws `#C90015` on light yellow and `#FFB1A7` on dark yellow, both at
4.9:1, the same contrast it has on the pages. Every preset under every name
then reads at 4.6:1 to 4.9:1 in both appearances (computed; the brand.rs test
holds it over the full sweep).

**How each platform draws it (H2).**

| platform | the mark's ground | the appearance switch |
|---|---|---|
| macOS, iOS (TextKit 2) | a second kaya key, `kaya.draw.mark`, painted by `KayaRichFragment` exactly as the code ground is (a rect over the line fragment's height, square corners, no inset), BEFORE `super.draw`, so find's `.backgroundColor` lands on top; NEVER `.backgroundColor` (§2: the clear wipes it and accessibility reads it as find's). The rich LABEL merges it into `.backgroundColor` as the code ground is merged (`kayaMergeGround`), since a label declares no find set | the value is a dynamic colour (`NSColor(name:nil){…}`, `UIColor{traits}`) whose provider picks the light or dark value, the way `kayaDocumentInk` does, so an appearance change redraws by itself |
| GTK 4 | a valued rich tag `kaya-rich-v-highlight=<name>` (the `color` tag's shape) with `background-rgba` and `background-full-height` FALSE, so the accessibility bus carries a `bg-color` run and the highlights read, keyed on `bg-full-height` alone, does not see it; the tag's priority is set BELOW the `kaya-highlight` tag's, so find paints over it where they overlap, and ABOVE the code tag's | `restyle_rich_grounds` on `notify::dark` re-derives the tag's colour from the name, the route the code ground already takes |
| WinUI 3 | the one `BackgroundColor` slot, with `rich_ground`'s order grown to FOUR claimants: find's `HIGHLIGHT_BACKGROUND` over the mark over the code ground over the quote tint; `rich_paint_grounds` and `rich_repaint_highlights` keep it after every restyle and clear. `painted_runs` compares to `HIGHLIGHT_BACKGROUND` exactly, and no palette value equals `#FFF18F`, so the mark never reads as find's. The rich label's `TextHighlighter` per colour takes the mark's value from `rich_ground` too, so the label and the textarea cannot drift | `redraw_later` after `ActualThemeChanged`, which already re-derives the whole display |
| Compose | NOT `SpanStyle(background)`: the text draws that above `KayaHighlightLayer`'s `drawBehind`, so a span background would cover find's paint. The mark is drawn in `KayaHighlightLayer` from the layout's boxes, BEFORE find's paint in the same `drawBehind`, so one function states the order (the code ground stays a span background, under both) | the palette's `dark` flag, which re-resolves the layer's colours on recomposition |

What the build must MEASURE before any arm (§8 step 0): on the Mac, that a
dynamic colour's `cgColor` inside `KayaRichFragment.draw` resolves to the
view's effective appearance (the code ground's `quaternaryLabelColor` already
takes this path, so this is a confirmation); on GTK, that two
`background-rgba` tags over one range paint by priority (GTK documents it;
unmeasured here); on WinUI, that `SetBackgroundColor` with a palette value
survives a theme switch through `redraw_later` and that a run holding the mark
AND a find range reads as find's in `painted_runs` (the record says the compare
is exact; the build watches it); on Compose, that drawing the mark behind the
text leaves the glyphs legible under the field's selection wash, and what
TalkBack says of a highlighted run (expected: nothing).

**Where things overlap (H3).** Stated once for five platforms: the platform's
SELECTION paints over everything (every toolkit's own rule, kaya does not
touch it); FIND'S HIGHLIGHT paints over the mark (the user is looking for a
match, and find's yellow at 55% over a pastel still reads); the MARK paints
over a code run's ground and a quote's tint (the user put it there); a CODE
run inside a highlight keeps its font and loses its grey; a QUOTE keeps its
rule or indent and loses its tint under the highlighted bytes only. The
mechanism is each row of H2's table.

**The wire, the file and the clipboard (H5, H6).** `format_text` carries
`highlight`/`<name>` like any mark, `removed` 1 takes it off; `text_formatted`
echoes it; `set_rich_text` and `apply_edit` carry it in their runs; the core
validates the name at the one chokepoint (`canonical_value`). The `.kdoc`
spelling is above. The clipboard: COPY writes RTF `\highlightN\cbN` with the
LIGHT value in `\colortbl` and `\cssrgb` in the expanded table, plus HTML
`<mark data-kaya-highlight="yellow" style="background-color:#F7E8AF">` (the
`data-` attribute carries the name for a kaya reader; the colour is for
everyone else; `<mark>` rather than `<span>` so a reader with no style sheet
still shows a highlight). PASTE reads RTF `\highlightN`, `\cbN` and
`\chcbpatN` (0 clears each), the expanded table's sRGB preferred, and HTML
`<mark>` (a bare one is `yellow`), `data-kaya-highlight` when present, and any
`background-color` or `background` on a span, font or mark. A colour that is
not a kaya value maps to the NEAREST NAME BY OKLCH HUE when its chroma is
0.012 or more, and is DROPPED below that (a grey, white or black shading is not
a highlighter pen; Word's `lightGray`, `darkGray`, `black`, `white` and
Notion's `gray` and `brown` backgrounds fall there). Computed on the
references: Word's yellow, green, blue, darkBlue, darkYellow map to their
names, cyan and darkCyan to `green`, magenta and darkMagenta to `pink`, red and
darkRed to `orange`; Notion's yellow, orange, pink, purple and blue to their
names, teal to `green`, red to `pink`; a bare `<mark>`, Cocoa's `#ffea2e` and
kaya's own find yellow to `yellow`. The map is one function in the core
(`richdoc::nearest_highlight`) with those cases as its unit test.

**The guest surface (H7).** The sweep's verdict is DO in all nine and the C
floor. Each binding gains, in the spelling its `color` sugar already uses
(check-sugar-surface's richdoc rows): the enum `HighlightColor` from the spec
(the generated vocabulary, like `ListKind`); a Document builder
`highlight(range, HighlightColor)`; an act on the transaction
`highlight(widget, HighlightColor)`, with removal through the existing
`unformat(widget, "highlight")`, exactly as Text Colour's Automatic is
`unformat(widget, "color")`; and a Selection read `highlight()` answering the
name or none. Spellings: Rust `pub fn highlight(&mut self, widget: WidgetId,
color: HighlightColor)` and `Document::highlight(self, range, color)`; Python
`def highlight(self, color: HighlightColor) -> Widget` on the handle and
`Document.highlight(span, color)`; Go `(tx *Tx) Highlight(w Widget, c
HighlightColor)` and `(d Document) Highlight(start, end int, c)`; C# `Highlight(Widget
w, HighlightColor c)`; Java `highlight(Widget w, HighlightColor c)`; Swift
`highlight(_ w: KayaWidget, _ c: KayaHighlightColor)`; Haskell `highlight ::
Widget -> HighlightColor -> Build ()` and the builder `highlightRun` (the
suffix the builder family took, rich-text plan §18); OCaml `let highlight
widget color` with the vocabulary in a module `Highlight_color` (`Op`'s
precedent); JS `highlight(color: HighlightColorName): this` on the handle and
`Document.highlight(span, color)`. No picker surface and no `command`: a closed
palette is a menu, not a dialog. The C floor needs nothing beyond the generated
`KAYA_RICH_ATTR_HIGHLIGHT` and `KAYA_HIGHLIGHT_COLOR_*` constants in kaya.h:
its format record (`KAYA_TX_FORMAT_TEXT`) already carries name and value as
strings, and the C guests keep the explicit floor (invariant 5).

**The editor** (guests/go/editor/editor.go, the Format menu, which the phones
carry on the bar above the keyboard): a Highlight submenu beside Text Colour:
`None` (`tx.Unformat(buffer, "highlight")`), then the six names, each
`tx.Highlight(buffer, kaya.HighlightYellow)`; enabled on a rich tab only.

**What a screen reader is told.** Nothing new: Notes, Word and Notion announce
nothing for a highlight either, and VoiceOver on the Mac reads
`AXBackgroundColor` only from a storage attribute kaya must not write (§2). The
Mac's `accessibilityAttributedString(for:)` override (RD19) could add
`AXBackgroundColor` for the mark's bytes without storing it; that is listed in
§9 for the maintainer, not recommended, since no product does it and no scene
could read it on the other four platforms.

## §4. The guards (invariant 3), each on a path a session walks into

- `cargo build`: the spec enum moves the hash; a stale generator fails the
  build naming the fix (crates/kaya/build.rs); the spec's vocabulary pin test
  (spec.rs, `RICH_ATTRS` with 14 in its outside set today) moves to 15.
- The core's unit tests: `canonical_value("highlight", …)` accepts the six,
  answers `none` as absence, refuses `#FFFF00` and `Yellow` naming the
  vocabulary; `expands_at_end("highlight")`; a kdoc round trip with a highlight
  in the inline order; an unknown name in a file refused in one sentence; the
  clipboard both ways (Cocoa's `\cb` text from today's measurement, Word's
  `\highlight`, a `\chcbpat` run, HTML `<mark>` bare and styled, a Google Docs
  `background-color` span) and `nearest_highlight` over the reference table,
  including the four dropped greys.
- brand.rs: every palette value passes the floors in §3 and is distinct from
  its page; `ink_on` of every preset against every palette value in both
  appearances reads at 4.5:1 or better and round-trips through the sweep as
  `ink_for_dark` does; `ink_on(rgb, INK_LIGHT_PAGE)` is `rgb` and `ink_on(rgb,
  INK_DARK_PAGE)` is `ink_for_dark(rgb)`, so the old door is the new one at
  the pages.
- check-sugar-surface: four rows (`HighlightColor`, `Document.highlight`,
  `highlight`, `Selection.highlight`) with the fake-name negatives the richdoc
  census already runs (nine fired per shape).
- check-verbs: a clause per arm at the draw site, the way the code ground's
  are held today: the Mac fragment's `kaya.draw.mark` enumeration before
  `super.draw`; GTK's `highlight` arm in `style_rich_tag` with
  `background_full_height(false)` and the priority call; WinUI's `rich_ground`
  naming four claimants in order; Compose's `KayaHighlightLayer` drawing the
  mark before `KAYA_HIGHLIGHT_COLOR`; and both interpreters' constants, apply
  arm, model and step-verb arm for `highlight`.
- The scene, tools/scenes/richdoc.steps (nine languages, five lanes): a
  `format … highlight=yellow` act over a run, `expect_runs` reading
  `highlight=yellow`, typing at its end read as highlighted (RD7), `unformat`
  reading it gone, save and reopen reading it back; a `color` run highlighted,
  with `expect_text_ink` reading the RE-MAPPED ink in both appearances (the
  read's "pixel farthest from the commonest colour" already treats the
  highlight as the ground); a new read `expect_text_ground <target>
  <start:end> "light RRGGBB dark RRGGBB"`, the commonest pixel inside the
  run's cells, built from `text_ink`'s route on all five, so the drawn value
  is asserted per appearance where no attribute can be read; and the
  STRUCTURAL guard the GTK lesson demands: find declared over a highlighted
  run, `expect_highlights` naming find's set alone, then cleared, naming none,
  on all five lanes (a mark that reads as find's is this slice's first defect).
- The clipboard scene (tools/scenes/clipboard.steps or richdoc.steps' copy
  step): a highlighted run copied and pasted back reads `highlight=yellow`
  through each lane's own board.
- The review page: captures of the six names in both appearances on every
  lane, a `color` run under each, and find over a mark, each viewed before it
  is published.

## §5. The build, depth then breadth

0. **Measure first**: the four items under H2's table (half a day; records
   under docs/measurements), and WordPad's reading of `\cb` against
   `\highlight` on the Windows guest.
1. **The root**: the spec enum and `rich_attr` 14 (the hash moves),
   `canonical_value`, `expands_at_end`, `brand::ink_on` and its tests, the
   kdoc order, the clipboard both ways and `nearest_highlight`, the Rust
   sugar; the review page's palette swatches rendered from the core in both
   appearances, VIEWED, and H1's hexes settled with the maintainer there.
2. **Depth on the Mac**: `kaya.draw.mark` in the fragment, the dynamic
   colour, the label merge, `expect_text_ground`, richdoc.steps' new steps
   with the Rust guest, the editor's Highlight submenu.
3. **Breadth**: iOS (the same fragment), GTK, WinUI, Compose; the eight other
   bindings' sugar; the census rows; check-verbs' clauses; the matrix.
4. **The review page** with every capture above.

## §6. The rulings

Each is the maintainer's; the mechanism is in §0 to §3 and the short version
is repeated so a ruling reads on its own.

### H1. The palette: six names, designed in OKLCH, two values each

The question: how many names, which, and their values.

- A. Six: `yellow`, `orange`, `pink`, `purple`, `blue`, `green` (Notes' five,
  mint as green, plus yellow), light L 0.93 and dark L 0.42 at each hue,
  chroma as far as sRGB allows up to 0.075 (§3's table); the floors held by a
  test, the hexes settled on the review page.
- A'. As A with chroma up to 0.11 (yellow `#FFE891`, green `#A4FFCF`, the
  other four unchanged by the gamut).
- B. Notion's nine (A plus `gray`, `brown`, `red`), so a Notion or Word grey
  paste keeps a mark instead of dropping it.
- C. Word's sixteen, as fixed values. Pure `#0000FF` reads 2.4:1 under black
  and `#000080` 1.3:1, so C has no contrast answer in the light appearance,
  let alone the dark one.

RECOMMEND A. Six is the smallest set that covers the pens people own and
Notes' five, every value reads under both inks with room to spare, and the
hexes are a design choice the review page settles rather than this document.
B adds three names whose grey and brown values are hard to tell from a code
ground and a quote tint at a glance; Word's red is `orange` under A's map,
which is the one visible loss.

### H2. How each platform draws it: a kaya-owned ground, never the find slot where the two can be told apart

- A. §3's table: the Mac and iOS fragment under `kaya.draw.mark`, a GTK tag
  without `background-full-height` and below find's priority, WinUI's one slot
  with four ordered claimants, Compose's mark drawn in `KayaHighlightLayer`
  before find.
- B. The platform's "natural" attribute everywhere (`.backgroundColor`,
  `SpanStyle(background)`), accepting that on the Mac the mark is wiped by
  find's clear and reads as a find match, and that on Compose it covers find.

RECOMMEND A. B is the 2026-09-15 defect twice over, and A reuses the exact
routes the code ground proved on each platform.

### H3. Which ground wins where they overlap

- A. Selection (the platform's) over find's highlight over the mark over a
  code run's ground over a quote's tint, on all five.
- B. The mark over find (the document's own formatting outranks a transient
  decoration).

RULED 2026-11-15, with the hexes (the maintainer: "im okay with your
recommendations"): where kaya draws the mark itself (the Mac's and iOS's
fragment, Compose's layer) it is NOT drawn under selected text, so a selection
reads as it does on the page, matching GTK and RichEdit, whose selections
replace a background. Measured first: Compose's selection wash over the dark
mark read 3.21:1 (docs/measurements/highlight-compose-2026-11-15.md).

RECOMMEND A. The user who declared a find set is looking for the match, and
find's 55% yellow over a pastel still reads; B would hide a match inside a
highlighted sentence, and on WinUI's one slot it would also take the find
read's colour away from find.

### H4. What a `color` run does under a highlight

- A. The core re-maps the ink against the highlight: `brand::ink_on(stored,
  ground)`, RD5's function with the page made a parameter; the presets read
  4.6:1 to 4.9:1 under every name in both appearances; at the pages it is
  `ink_for_dark` exactly.
- B. Nothing: the stored colour (light) or `ink_for_dark` (dark) is drawn as
  it is, and the presets read 3.7:1 to 4.1:1 light, 2.3:1 to 2.6:1 dark.
- C. Refuse a `color` run and a highlight on the same bytes (the format act
  takes the colour off, or the highlight).
- D. Notes' answer: the highlight also tints the text its own hue (a `color`
  run and a highlight cannot coexist; the pen owns both).

RECOMMEND A. It keeps RD5's promise (every run readable on whatever is behind
it) with the same function and one more parameter; B ships text under the
floor on purpose; C refuses something Word and Docs allow; D takes the user's
text colour away. The cost of A is real: every arm's ink derivation must know
the run's highlight, which the Mac does through the attribute at the same
byte, GTK through the tag pair, WinUI in `drawn_color`, Compose in
`kayaRichSpanStyle`.

### H5. The wire and the file

- A. `rich_attr` `highlight` 14; spec enum `highlight_color` with `none` 0 and
  the six names; `canonical_value` answers `none` as absence; grows at its
  end; `.kdoc` key `highlight` with the name as a string after `color`; an
  older reader opens read-only naming the mark (RD8 as built).
- B. The value as `#RRGGBB` in the file, the name only in the API.

RECOMMEND A. The name IS the design (two values per name, chosen later if the
maintainer re-tunes them); a hex in the file would freeze today's value into
every document and make the dark value underivable.

### H6. The clipboard

- A. Write `\highlightN\cbN` with one colour table entry holding the light
  value, and `<mark data-kaya-highlight="…" style="background-color:…">`;
  read `\highlight`, `\cb`, `\chcbpat`, `<mark>`, `data-kaya-highlight` and
  CSS backgrounds; an unknown colour maps to the nearest name by OKLCH hue at
  chroma 0.012 or more and is dropped below that.
- B. Write `\cbN` only (Cocoa's spelling), read all three.
- C. As A, but an unknown colour is dropped rather than mapped.

RECOMMEND A. Measured today, Cocoa reads only `\cb` and Word is reported to
read only `\highlight`, so writing one loses one reader; a paste from Word of
its yellow highlighter should arrive as a highlight, which C refuses.

### H7. The guest surface and the editor

- A. All nine bindings and the C floor's constants: `HighlightColor`,
  `Document.highlight(range, color)`, `highlight(widget, color)`, removal
  through `unformat(widget, "highlight")`, `Selection.highlight()`; the
  editor's Format > Highlight submenu with None and the six names.
- B. As A with a dedicated `unhighlight(widget)` act.

RECOMMEND A. Text Colour's Automatic is `unformat(…, "color")` today, and one
removal spelling for every mark is invariant 1's shape; B adds a name whose
only job is to spell the general act.

### H8. What assistive technology hears

- A. Nothing beyond the platform's own, as Notes, Word and Notion do; the
  plan records that the mark is invisible to VoiceOver, Orca, Narrator and
  TalkBack by design.
- B. The Mac adds `AXBackgroundColor` for the mark's bytes in
  `accessibilityAttributedString(for:)` (RD19's override), with no counterpart
  on the other four.

RECOMMEND A. B states a carve-out invariant 1 would have to carry for four
platforms, for an attribute VoiceOver reads only at its highest verbosity.

### Beyond these, for the maintainer

- Whether the highlight act with a COLLAPSED selection arms the typing
  attribute (every other mark does; the plan assumes yes, by the general rule).
- Whether the editor shows the caret's highlight as a checked item in the
  submenu (Text Colour shows none today; the plan assumes none, for symmetry).
- The exact hexes of H1 once viewed on the review page, and whether `green`
  should be called `mint` after Notes.
