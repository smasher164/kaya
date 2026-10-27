# The code surface: a line-number gutter, the text's face and size, and whether kaya can carry a minimap

Status: DESIGNED 2026-10-27; the depth (spec, core, SwiftUI on the mac, the
Rust binding, the scene) is being built, the breadth follows it. The
maintainer, 2026-10-27: "We should definitely have a line number gutter";
"I think it'd be good to know that we could support something like the
mini-map, especially since we're doing a lot of native controls"; on the code
font, that the guest chooses it and kaya supplies the means; "a typical text
editor lets the user set the font they want to see. Is that possible?"; and on
the size, RULED (b) below ("I lean towards b as well"). The research behind
every table, source by source, is
docs/measurements/code-surface-research-2026-10-27.md.

Before this plan a kaya app had one typeface for the whole app (the brand
typeface, `set_brand_typeface`, docs/styling-plan.md D6) and nothing else: no
per-widget face, no size other than the platform's, and no line numbers. The
text editor demo (docs/editor-plan.md) is the consumer.

## §1: The gutter (G)

**G1. The prop.** `line_numbers` (prop 69, Bool) on a textarea. On, the
textarea draws a column of line numbers on its leading side; off or unset,
the textarea is what it was. Legal on the textarea alone.

**G2. What is numbered.** Logical lines: the text between two newlines. A line
the textarea wraps onto several rows carries its number on its FIRST row and
leaves its continuation rows blank. This is what every editor surveyed does
(VS Code, Zed, Sublime, Xcode, GtkSourceView, AvalonEdit, Scintilla,
CodeEdit, STTextView, sora-editor): VS Code's `_getLineRenderLineNumber`
returns an empty string for a view line that does not start its model line,
Zed numbers only a buffer row's first display row, GtkSourceView aligns to
the first display line (`ALIGNMENT_MODE_FIRST`). The empty line after a final
newline is a line and is numbered. Numbers start at 1.

**G3. How it looks.** The platform's secondary text colour, tabular digits
(every surveyed gutter uses fixed-width digits so the column does not jitter),
right-aligned, vertically centred on the first row of its line, at 0.9 of the
textarea's own size so it follows the textarea's face and `text_scale` (and
the platform's text-size setting with it; a custom-drawn gutter does not get
Dynamic Type, Android's sp or Windows' TextScaleFactor for free, so each
lowering takes its size from the textarea's resolved font). The column is at
least two digits wide and grows with the digit count of the last line, the
GtkSourceView and AvalonEdit minimum. It stays put horizontally and scrolls
vertically with the text. The current line's number is NOT tinted in this
slice (most editors tint it; it is a later refinement, recorded in the
ledger's entry for this plan).

**G4. Accessibility.** The gutter is decorative and hidden from the
accessibility tree on every lane: no surveyed gutter publishes its numbers,
and the screen readers read the current line from the text control itself
(AXInsertionPointLineNumber on the mac, UIAccessibilityReadingContent on iOS,
GtkAccessibleText, the RichEdit UIA text pattern, TalkBack's own line
reading).

**G5. How a leg sees it.** `expect_gutter <textarea> on|off|shows N|hides N|wraps N`.
The backend answers, for the line fragments of the text whose vertical centre
is inside the viewport,
top to bottom, which logical line each belongs to, whether it begins that
line, and which number the gutter DREW beside it (read from the gutter's last
drawing pass). The fragments are read from a source independent of the
gutter's own drawing where the platform has one (the mac reads AppKit's
accessibility lines of the text view, not the TextKit enumeration the ruler
draws from). The harness pairs them and every reading but `off` holds the
whole column: a line's first fragment carries its own number and a
continuation carries none, or the step fails printing the column with each
disagreement marked (`3!4` drew 4 beside line 3; `·!4` drew 4 beside a
continuation; `3!-` drew nothing beside line 3). `shows N` adds that line N
starts inside the viewport, `hides N` that no row of line N is inside it,
`wraps N` that line N has a first row and a continuation inside it.

**G6. The lowerings.**

| backend | mechanism |
|---|---|
| SwiftUI, macOS | an `NSRulerView` subclass as the textarea's scroll view's `verticalRulerView`, drawing in `drawHashMarksAndLabels(in:)` from the TextKit 2 layout fragments in the visible rect (`enumerateTextLayoutFragments` from the fragment at the viewport's top; a paragraph is a layout fragment, its first `textLineFragment` the numbered row). Never `.layoutManager`, which drops the view to TextKit 1 for good (mjtsai.com 2026-02-09). `clipsToBounds` on, since macOS 14 a ruler that does not clip paints over the text (Apple forums thread 767825). Redrawn on the clip view's bounds change and the text's change. |
| SwiftUI, iOS | a gutter view inside the UITextView (a scroll view, so a subview at a content y scrolls with the text), `textContainerInset.left` reserving its width, drawn from the same TextKit 2 enumeration, redrawn from `scrollViewDidScroll` and the text's change; `isAccessibilityElement = false`. Runestone and STTextView's UIKit gutter are the prior art. |
| GTK | `gtk_text_view_set_gutter(view, GTK_TEXT_WINDOW_LEFT, area)` with a drawing area that sizes itself to the digit count and draws from `gtk_text_view_get_visible_rect`, `get_line_at_y`, `get_line_yrange` and the first display line's height, the GtkSourceGutter recipe; redrawn on the vadjustment's `value-changed` and the buffer's `changed`. Accessible role presentation. |
| WinUI | the RichEditBox in a two-column Grid with a Canvas of TextBlocks to its left, placed from the TOM object model: `Document.GetRange(0,0).Expand(TextRangeUnit.Window)` for the visible span, stepped by `TextRangeUnit.Paragraph`, `GetRect(PointOptions.ClientCoordinates)` for each paragraph's first row; redrawn on the template's `ContentElement` ScrollViewer's `ViewChanged`, `TextChanged` and `SizeChanged`. `AccessibilityView = Raw`. The weakest lane: the scroller is a template part, not an API. |
| Compose | inside the text field's `decorator`, a Row whose leading child draws the numbers with `drawBehind` from the field's `TextLayoutResult` (`getLineStart`, `getLineTop`, `getLineBottom`; a row starts a logical line when the character before it is a newline) offset by the field's own `scrollState.value`, read in the draw lambda so a scroll redraws without recomposing. No semantics. |

## §2: The face (M)

**M1. The role.** `monospaced` (prop 70, Bool) on a label, an entry or a
textarea: the widget draws in the PLATFORM'S OWN monospaced face. The family
and never the size, the brand typeface's rule: the size stays what the
platform gives the widget (and `text_scale`, §3). Unset or off, the widget
draws in the app's face (the brand typeface, else the platform's).

| backend | face |
|---|---|
| SwiftUI (mac, iOS) | `monospacedSystemFont(ofSize:weight:)`, SF Mono, at the ramp's size and weight (on iOS scaled through UIFontMetrics so Dynamic Type still applies). Never bundled: Apple flags embedded system fonts (ITMS-91182). |
| GTK | fontconfig's `monospace` alias in a per-widget CSS rule, which leaves the size alone. Not the `.monospace` style class: libadwaita 1.7+ maps it to the user's `monospace-font-name` FAMILY AND SIZE (Adwaita Mono 11 since GNOME 48), and M1 takes the family alone; the user's GNOME monospace choice still reaches the widget through fontconfig's alias. |
| WinUI | `FontFamily("Cascadia Mono, Consolas")`: Windows 11 ships Cascadia Mono (Windows Terminal's default), Consolas is the fallback Microsoft's typography page names; WinUI has no monospace theme resource. |
| Compose | `FontFamily.Monospace` (Droid Sans Mono on AOSP). |

**M2. A named family.** `family` (prop 71, Str) on the same three kinds: the
widget draws in an INSTALLED family by its name, the one the app's user
picked from the list M3 hands the app. ONE name, never a toolkit fallback list
(the root refuses a comma, a semicolon, a quote, a newline and padding). A
family the platform does not have falls back to the ROLE: the platform's
monospaced face when `monospaced` is also on, else the app's face. That makes
the editor's pair `monospaced(true)` plus the user's `family` correct on any
device: a font named in settings that is gone on this machine reads as code,
not as prose. Each backend checks presence first, since a missing name is
silently replaced on most lanes (fontconfig always returns a font, Android's
`Typeface.create` returns DEFAULT, `UIFont(descriptor:size:)` hands back
Helvetica): CoreText's matching descriptor on Apple, Pango's family list on
GTK, DirectWrite's `FindFamilyName` on Windows, the system font list on
Android.

**M3. Listing the families.** `list_font_families` (tx 88, apply 76),
answered once by the occurrence `font_families` (60): every installed family
an app may name in `family`. The core normalises what each backend hands it
(`kaya_font_families`, the names `\n`-joined): empty names and the platform's
private ones (Apple's `.`-led) dropped, unique, in code-point order, so the
list reads the same way everywhere.

| backend | source |
|---|---|
| macOS | `NSFontManager.shared.availableFontFamilies` |
| iOS | `UIFont.familyNames`: the system's families and the fonts this app registered. User-installed fonts reach an app only through the system picker or `CTFontManagerRequestFonts` (Apple's UIFontPickerViewController page), so on iOS the list is the system's; recorded, not hidden. |
| GTK | `pango_context_list_families` on the widget's Pango context |
| WinUI | DirectWrite `GetSystemFontCollection`, each family's name in the user's locale, else en-us |
| Compose | `SystemFonts.getAvailableFonts()` (API 29+, kaya's floor) gives font FILES; the family is read from each file's name table, and the fonts.xml generic families (`monospace`, `serif`, `sans-serif`, ...) are listed as themselves since `Typeface.create` resolves them |

**M4. How a leg sees it.** `expect_face <target> monospaced|proportional|named`
reads the font the toolkit RESOLVED for the widget (the NSTextView's font,
the accessibility attributed string's AXFont for a SwiftUI label or field,
the UITextView's or UILabel's font, Pango's resolved font description, the
TextBlock's or RichEditBox's resolved FontFamily through DirectWrite, the
Compose text layout's resolved typeface) and answers `monospaced <family>` or
`proportional <family>` from the font's own fixed-pitch trait. `named` holds
the resolved family to the one the app asked for in `family`. A family the
scene cannot know in advance is named by the app: the scene's guest lists the
families and asks for the first one, so `named` is portable.

**M5. A native font picker is not worth a kaya kind.** macOS has
NSFontPanel, iOS UIFontPickerViewController and GTK GtkFontDialog (4.10+);
WinUI and Android have none, and neither do Qt (native only on macOS), MAUI,
Avalonia or Flutter. Two of five lanes would be a synthesised picker, and the
three native ones differ in what they return (a font with size and traits,
a descriptor, a Pango description). An app builds its own settings field from
M3's list on every lane, which is what WinUI apps and VS Code do; the editor
demo's Font submenu is that. If a picker kind is wanted later, the iOS one is
the only way to reach user-installed fonts there, and that is its trigger.

## §3: The size (S)

**S1. RULED 2026-10-27, option (b).** The maintainer chose among three:
(a) keep the size the platform's, (b) a per-widget RELATIVE scale that
composes with the platform's text-size setting, (c) absolute points. (b):
`text_scale` (prop 72, F64) on a label, an entry or a textarea: the widget
draws at that multiple of the size the platform gives it NOW, so a user with
Large Text or a 200% font scale who zooms the editor to 1.5 gets 1.5 of their
larger size, and WCAG 1.4.4's 200% is never undone by the app. 0.5 to 3 (the
root refuses anything else, and anything not finite); 1, the default, is the
platform's size. (c) was set aside because an absolute size overrides Dynamic
Type, Android's sp and Windows' TextScaleFactor (the HIG, the Android 14 font
scaling notes and Microsoft's text-scaling page all say to keep text on the
system's scale), and (a) because every editor surveyed lets its user change
the size (VS Code `editor.fontSize` and zoom, Zed `buffer_font_size`, Xcode's
themes, GNOME Text Editor's custom font).

**S2. The lowerings.** The multiple is applied AFTER the platform's own
scaling, so it composes exactly: on iOS the font is the UIFontMetrics-scaled
size times the multiple; on Android the multiple multiplies the field's `sp`
size; on Windows the multiple multiplies the control's FontSize and
IsTextScaleFactorEnabled stays on; GTK takes the widget's resolved Pango size
times the multiple through a per-widget CSS `font-size`; the mac has no
text-size setting (macOS has no Dynamic Type, per the HIG), so the multiple is
of the ramp's size. The gutter (G3) follows its textarea's.

**S3. How a leg sees it.** `expect_scaled <target> <multiple>` reads the
resolved size of the widget's font and the size the platform gives that kind
and role now, and holds their ratio to the multiple within 2%. The scene runs
twice, at the lane's own text size and under `KAYA_TEXT_SCALE=2` on the lanes
that can set one (iOS, Android, Windows, GTK), with `expect_text_scale 2`
proving the second setting took.

## §4: The surface

Every binding spells the four where its text kinds' options live, and the
list as a request and a handler, the capture device list's shape: Rust
`.line_numbers(true)`, `.monospaced(true)`, `.family(name)`,
`.text_scale(1.5)`, `tx.list_font_families()` and
`Messages::on_font_families(|families| ...)`; Go `LineNumbers`, `Monospaced`,
`Family`, `TextScale`, `ListFontFamilies`, `OnFontFamilies`; and so on through
C#, Java, Swift, OCaml, Haskell, Python and JS. The C floor has the generated
setters and records. The template zone carries `monospaced`, `family` and
`text_scale` (a stamped label in code, a stamped entry); `line_numbers`
belongs to the live zone's textarea, as the document prop belongs to the
stamped one.

## §5: The scene

`tools/scenes/codesurface.steps`, every lane, every language: a textarea of
forty numbered code lines whose third line is long enough to wrap at the
narrowest lane's width, with line numbers on; a plain textarea beside it; a
monospaced label and entry; a label asking for a family that is not
installed, with `monospaced`; a label scaled 2. It reads the gutter at the
top (`on`, `shows 1`, `wraps 3`, `hides 40`), after the app reveals the end
(`shows 40`, `hides 1`), after typing a new line at the end (`shows 41`), and
`off` on the plain one; the faces (`monospaced`, `proportional`, and the
fallback); the list (the app's label says the list came back non-empty,
unique and sorted, and `named` holds a label set to the first family); and
the scale (`expect_scaled` 2 and 1). `codesurfacebig` is the same guest
under `KAYA_TEXT_SCALE=2`.

## §6: The minimap (a study; nothing built)

**What a minimap needs.** A zoomed-out drawing of the document beside the
text, a box over it showing the viewport, and the two kept in step: the
text's scroll position and visible range as they change, the document's
lines (or its laid-out rows) at a small scale, and a way for a click or a
drag on the minimap to set the text's scroll. Editors build it two ways: a
SECOND VIEW of the same text at a 1-2 pt font (Zed shares the buffer and the
display map at 2 px; GtkSourceView's GtkSourceMap is a GtkSourceView at
"Monospace 1"; CodeEdit lays its own fragments 2-3 px tall), or a RASTER of
downsampled glyphs or blocks (VS Code, 1x2 px a character from a char sheet).

**What the platforms offer.** None of the five native text controls has a
minimap; GtkSourceMap is the only one any toolkit ships, and it needs
GtkSourceView. Every lane exposes what one needs: the viewport offset and
size (NSScrollView's `documentVisibleRect`, UITextView's `contentOffset`,
GtkAdjustment, the RichEditBox's inner ScrollViewer, Compose's ScrollState),
a scroll notification (bounds change, `scrollViewDidScroll`,
`value-changed`, `ViewChanged`, a snapshot read), the content height, and a
way to set the scroll (`scroll(to:)`, `setContentOffset`,
`gtk_adjustment_set_value`, `ChangeView`, `scrollTo`). A second view over
the SAME text storage exists on Apple (a second NSTextLayoutManager on the
content manager) and GTK (a second GtkTextView on the buffer); WinUI and
Compose would mirror a copy.

**What kaya already has.** The canvas kind draws anything the app computes
at any size, rasterised by the core (docs/canvas-plan.md); `reveal_range`
scrolls the textarea to a range; `expect_revealed` reads containment. What it
lacks is the other direction: the app is never told where the textarea is
scrolled, and cannot scroll it to a fraction.

**What it would take.** As a kaya FEATURE (the backend draws it): a
`minimap` prop on the textarea, each backend drawing a second view or a
raster and keeping it in step. Cost per backend: mac and iOS low-to-medium (a
second layout manager on the shared storage, a box view, two observers), GTK
low (a second GtkTextView on the buffer at a 1 pt font, the GtkSourceMap
recipe without GtkSourceView), Compose medium (a tiny read-only text of the
same state, its scroll mapped), WinUI high (no shared document: a read-only
copy re-set on every change, the scroller a template part), plus a reader per
lane for the box and the click. As an APP-BUILT minimap over the canvas, kaya
would need two small additions: a `scrolled` occurrence from the textarea
(the first visible line and the visible line count, or offsets) and a
`scroll_to_line` (or a fraction) request; the app draws the lines as blocks
on a canvas beside the textarea and moves the box on each report. Each
backend already holds both facts (the table above), so the two additions are
small everywhere, WinUI included.

**Verdict.** Yes, kaya can carry a minimap, and the cheaper path is the
second: two textarea additions (a scroll report and a scroll request) that
every lane can lower from APIs it already uses, and the minimap itself drawn
by the app on the canvas it already has, which also makes it portable
pixel-for-pixel. A native second-view minimap is reachable on four lanes and
costly on WinUI; it is the better-looking one (real glyphs at 1-2 pt) and the
trigger for it would be a ruling that the app-drawn blocks do not look native
enough.

## §7: Guards

- check-verbs holds `expect_gutter`, `expect_face` and `expect_scaled` in both
  interpreters and the harness; check-sugar-surface holds the four props and
  the list in every binding; tpl-surfaces' census holds the template zone's
  three.
- The root refuses `line_numbers` off a textarea, the face props off the three
  text kinds, a family that is a list, and a scale outside 0.5 to 3 (unit
  tests in scene.rs).
- codesurface.steps on every lane: a gutter that numbers a continuation, does
  not scroll, or stops at the first screen fails `expect_gutter`'s column
  check; a face that does not swap fails `expect_face`; a scale applied before
  the platform's (or not at all) fails `expect_scaled` under
  `KAYA_TEXT_SCALE=2`. Each watched red per backend.
