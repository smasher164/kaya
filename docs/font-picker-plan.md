# The font picker: a family and a face, native where the platform has one

Status: RULED 2026-10-29 (§10: "I agree with most of your recommendations",
with Q2 changed); built on all five lanes and in all nine bindings with the
editor's Font… (docs/deferred.md, the font picker entry). The maintainer, 2026-10-29, agreed to build a font picker: native
on the Mac (NSFontPanel), iOS (UIFontPickerViewController) and GNOME
(GtkFontDialog); kaya-drawn on Windows (a ContentDialog with a search field,
not Win32 ChooseFont) and Android (a bottom sheet with search), built from
`list_font_families`. The app asks to choose, optionally among code fonts
only, and hears the choice or a cancel. On style: "I don't want to punt the
font style thing down the road if it forces us to confront issues right now.
Factor in how they would work with the picker now." So the face (weight,
slope, width) is in this plan. This plan replaces docs/code-surface-plan.md
M5, which was an agent's recommendation and never ruled.

Every claim below is MEASURED on 2026-10-29 unless it says otherwise; the
probe record is §11, and the review page with every capture is
https://claude.ai/artifact/UUHFkH91WC5csgyDRBHtYV.

Terms. A FAMILY is a named group of fonts designed together ("Menlo", "IBM
Plex Sans"). A FACE is one member of a family: one weight, one slope, one
width ("IBM Plex Sans Light Italic"). WEIGHT is the stroke thickness on the
OpenType scale `usWeightClass`, 1 to 1000, where 400 is regular and 700 bold
(CSS `font-weight` uses the same numbers). SLOPE is upright or slanted; a
slanted face is either a true ITALIC (redrawn letterforms) or an OBLIQUE (the
upright shapes sheared). WIDTH (CSS `font-stretch`, OpenType `usWidthClass`)
is how condensed or expanded the face is, nine steps from 1 (ultra-condensed)
through 5 (normal) to 9 (ultra-expanded). A VARIABLE FONT is one file whose
weight, width or slant is a continuous axis (`wght`, `wdth`, `slnt`, `ital`);
its NAMED INSTANCES are the faces it advertises. SYNTHESIS is the toolkit
faking a face the family lacks: a sheared oblique for italic, a thickened
outline for bold.

## §1 What each platform has, measured

| | the picker | can be modal | code fonts only | what it hands back | cancel |
|---|---|---|---|---|---|
| macOS 26.6 | NSFontPanel, redesigned on 26: a collections popup in the toolbar, size, a B/I/U effects popup, typography, search; families grouped by letter; a faces list (`mac-standard-panel.png`) | yes, as a sheet on the window or under `runModal(for:)`; the user can still pick in both (`mac-sheetacc.png`, `mac-modal-picked.png`) | a kaya collection made with the PUBLIC `NSFontCollection.show(_:withName:visibility: .process)` appears in the collections popup; SELECTING it has no API: driving the toolbar popup's menu item filters the list to the 13 fixed-pitch families (`mac-collection-picked.png`), and with the popup then hidden by the mode mask the user cannot leave it (`mac-codelock-picked.png`) | `changeFont:` on every click, live; `NSFontManager.selectedFont` follows the pick: an `NSFont` with family, PostScript name, face name, and the OS/2 table (weight class, width class, italic bit) readable through `CTFontCopyTable` | none built in: the panel only closes; an accessory view carries kaya's own Cancel and Choose (`mac-accessory-panel.png`) |
| iOS 26.5 | UIFontPickerViewController, a REMOTE view (the app's tree holds only `_UISceneHostingViewController`) | always a sheet | `filteredTraits = .traitMonoSpace`: Courier New and Menlo on the simulator, plus the picker's own "Manage Fonts" row (`ios-pickermono-1.png`) | `includeFaces = false`: a descriptor holding the family only (`NSFontFamilyAttribute=Menlo`); `true`: a row drills into "Choose Style" and the descriptor holds the face's PostScript name (`CourierNewPS-BoldItalicMT`, weight 700, italic). The picker STAYS PRESENTED after the pick; the app dismisses it | the close button: `fontPickerViewControllerDidCancel` |
| GTK 4.24 | GtkFontDialog, which is a GtkFontChooserDialog inside: search, list, preview line, Cancel and Select | always modal | `set_filter` with a GtkCustomFilter on `PangoFontFamily.is_monospace()`: DejaVu Sans Mono, the `Monospace` alias, and Noto Color Emoji (Pango calls the emoji font monospace) (`gtk-familymono-open.png`) | `choose_family`: a PangoFontFamily. `choose_face`: one family's faces only, a PangoFontFace (`Light Italic`, weight 300). `choose_font`: family, face and a SIZE row (`gtk-font-picked.png`), a PangoFontDescription (`IBM Plex Sans Semi-Bold Italic 15`) | `GError` "Dismissed by user" |
| WinUI 3 | none; kaya draws a ContentDialog | modal | kaya's filter | kaya's own | kaya's own |
| Android 15 | none; kaya draws a ModalBottomSheet | modal | kaya's filter | kaya's own | kaya's own |

How far the Mac panel bends (the maintainer's question):

- MODALLY, yes, two ways, with a cost. As a sheet on the window, `changeFont:`
  still arrives on each click and `endSheet` ends it (`mac-sheetacc.txt`).
  Under `NSApp.runModal(for: panel)` the user can pick but `changeFont:` is
  NEVER delivered, to a view or to a plain object target; the choice is read
  at the end from `NSFontManager.selectedFont`, which did follow the pick
  (`mac-panel2.txt`). Closing the panel does not end the modal session by
  itself; kaya ends it from the panel's `willClose`. The cost: in a sheet or a
  modal session the mode mask does not take effect, so the size field and the
  B/I/U popup stay visible even after the panel was asked for its modes five
  times (`mac-sheetkey.png`, `mac-modalkey-picked.png`).
- THE MODE MASK (`validModesForFontPanel(_:)`) works on the floating,
  non-modal panel, but only once the panel BECOMES KEY: `orderFront` and
  `orderFrontFontPanel` keep the previous modes, `makeKeyAndOrderFront` on the
  panel applies them (`mac-trigger-1.png`). `[.face, .collection]` hides size
  and effects; `[.collection, .size]` hides the faces list; `[.face]` hides
  the collections popup too; `[]` leaves the family list, typography and
  search (`mac-nosize-after-query.png`, `mac-noface-after-query.png`,
  `mac-facenocoll-after-query.png`, `mac-familyonly-after-query.png`).
- CODE FONTS ONLY: half public. The deprecated `fontManager:willIncludeFont:`
  delegate (deprecated 10.11, "Use NSFontCollection") is never asked. A
  process-visible NSFontCollection is public and appears in the popup; making
  it the SELECTED collection goes through the toolbar item
  `NSFontPanelCollectionsToolbarItem`, an undocumented identifier, or through
  private selectors (`_chooseCollection:`, `_updateForCollection:`,
  `_setSelectedFamilyName:`). The toolbar exists only on the macOS 26 panel;
  kaya's floor is macOS 13, whose panel has a collections COLUMN instead
  (unmeasured: no host older than 26 here).
- WHAT IT HANDS BACK: an NSFont. Family `Menlo`, face `Bold Italic`, OS/2
  weight 700, width 5, italic bit set; Core Text's weight trait 0.4; AppKit's
  own 0-15 weight 9. The panel carries the face across families: picking
  Menlo after Helvetica Neue Bold Italic answered Menlo Bold Italic.

## §2 Style, portably

### 2.1 Why not face names

Face names are labels, not values, and they disagree everywhere: Avenir
Next's `Demi Bold` (Mac), IBM Plex Sans' `SemiBold` (fontconfig) and
`Semi-Bold` (Pango's description of the same face), DejaVu's `Book` for
regular, Cascadia's and Segoe UI's `350` (Windows names a variable instance
by its number), Plex's `Text` face which Pango describes only as `weight=450`.
Names are also localized. And some platforms list faces AS FAMILIES: Android's
fonts.xml has `sans-serif-light` (an alias for sans-serif at weight 300),
`sans-serif-medium`, `source-sans-pro-semi-bold`; Windows lists Segoe UI
Variable as three families by optical size (Display, Small, Text).

### 2.2 The portable face

A face is three values, read from the font's own tables on every platform:

- `weight`: 1 to 1000, the OpenType weight class. Every lane exposes it:
  the OS/2 table on Apple (measured readable; Core Text's -1..1 trait is a
  lossy mapping of it), Pango's weight (measured 100..900 and 450), DirectWrite
  and WPF's OpenType weight (measured 200..900 and 350), Android's `Font.getStyle().getWeight()` (read from the docs; fonts.xml's entries carry 100..900).
- `italic`: upright or slanted. ONE flag, not three states: italic and
  oblique are two ways of drawing the same request, and the platforms already
  treat them so (Pango answered `DejaVu Sans Mono Oblique` to an italic
  request; Roboto Flex's italic entries are `slnt -10`; Courier's slanted face
  is named `Oblique` and carries the italic trait on iOS).
- `width`: 1 to 9, the OpenType width class (5 normal). Measured in use:
  Bahnschrift's Condensed (3) and SemiCondensed (4), Helvetica Neue's
  Condensed Bold and Black, Skia's Condensed and Extended, Android's
  `sans-serif-condensed` (Roboto at `wdth 75`). Pango's and DirectWrite's
  stretch are the same nine steps; Core Text's width trait and Android's
  `wdth` axis map onto them.

A VARIABLE font's faces are its named instances (measured: Skia's ten
members, Roboto's eighteen fonts.xml entries over one file, Segoe UI
Variable's 300/350/400/600/700, Cascadia's 200 to 700), so the pickers list
named instances, and the face props accept any weight in 1..1000 and set the
`wght` axis exactly where the font is variable. Optical size, grade and other
axes are out of scope (§9).

### 2.3 How the app sets it

Three new props on the label, the entry and the textarea, beside `family`
(71), and in the template zone with it:

- `font_weight` (73, U16): 1 to 1000; unset is the role's own weight (a
  heading stays bold, a body is regular). The root refuses 0 and anything
  above 1000.
- `font_italic` (74, Bool).
- `font_width` (75, U8): 1 to 9; unset is 5.

They apply to whatever family the widget resolves to: `family`, else the
`monospaced` role face, else the app's face. `width` is already the name of
the layout width, hence the prefix. `family` itself stays one name (M2).

### 2.4 When the face is missing

The family is checked for presence first (M2's rule, unchanged). Then the
face is MATCHED, by the CSS Fonts 4 font matching algorithm (§5.2), the one
rule every browser applies to the same problem, so kaya does not invent one:

1. width first: the nearest available width, narrower first when the
   request is 5 or below, wider first above it;
2. then slope: italic, else oblique, else upright;
3. then weight: for 400 to 500, the weights from the request up to 500, then
   below the request descending, then above 500 ascending; below 400,
   descending first, then ascending; above 500, ascending first, then
   descending.

Then SYNTHESIS, the same on all five: a slant the family lacks is drawn as an
oblique sheared by 0.2 (about 11 degrees), and a bold the family lacks (the
matched face is below 600 for a request of 600 or more) is drawn emboldened.
Today GTK synthesizes both through fontconfig (measured: DejaVu Sans, which
has no italic, came back `Oblique`, matrix `[1 0.2; 0 1]`), Android and
DirectWrite synthesize by their own rules (from the docs, unmeasured here),
and Apple synthesizes NOTHING: `NSFontManager.convert(_:toHaveTrait:)` and
iOS's symbolic traits return the same font for Monaco, Andale Mono and PT Mono
(measured). So the Apple arm draws the oblique itself (a shear matrix on the
CTFont) and the bold itself (a negative stroke width), and reports both as
synthesized. Q4 asks whether to synthesize at all.

### 2.5 How a leg reads it

`expect_face <target> face <weight> <upright|italic> <width> [synthesized]`
grows on the M4 verb: the backend reads the RESOLVED font off the real view,
never the props, and answers its weight class, slope and width, plus whether
the slope or the bold was synthesized: the OS/2 table of the NSFont or
UIFont (synthesis from kaya's own matrix and stroke), Pango's resolved
`PangoFont` description (`style=oblique` with no face for a synthesized one,
measured), DirectWrite's IDWriteFont weight, style, stretch and
`GetSimulations()`, Android's resolved Typeface `getWeight()` and
`isItalic()` (API 28) with the paint's fake-bold and skew flags. Watched
negatives: a backend that echoes the prop (perturb: report the requested
weight), a matcher that rounds the wrong way (perturb the descending branch:
650 on a 600/700 family must read 700), and synthesis that does not happen
(perturb: drop the shear on Apple; italic on Monaco must read `synthesized`).
On the Mac a label's weight, slope and width come from the font its
accessibility element names, and its shear and second bold pass from what
kaya's label modifier last drew, since accessibility carries neither.

A scene cannot know another lane's faces, so (as M4's `named`) the GUEST asks:
`list_font_faces(family)` (§5.4) answers the family's faces, the guest picks
one with three or more weights, sets an exact face, a between-weights face
(the matcher), and an italic on a family with none (the synthesis), and labels
what it asked; the steps hold the resolved face to the label.

## §3 How it composes with rich text formatting

What Bold, Italic and Code do today, read in the code and measured where a
probe could reach it:

| | Bold | Italic | a Code run |
|---|---|---|---|
| Mac (`kayaRestyle`) | `NSFontManager.convert(toHaveTrait: .boldFontMask)`: UltraLight, Light, Regular, Medium all become the family's Bold (700); Avenir Next DemiBold (600) STAYS 600, since AppKit counts it as bold already; no bold for Monaco | `convert(toHaveTrait: .italicFontMask)`: Light becomes Light Italic (weight kept); no italic for Monaco, Andale Mono, PT Mono (same font returned) | `monospacedSystemFont` at regular or bold: ignores `family` and any face |
| iOS (`kayaWithTrait`) | symbolic `.traitBold`: Light, UltraLight, Medium become Bold (700); DemiBold stays 600 | symbolic `.traitItalic`: Light becomes plain ITALIC (400), the Light weight LOST; DemiBold becomes BOLD Italic (700), the weight raised. A defect today | `monospacedSystemFont` |
| GTK (`label_rich_attrs`) | `Weight::Bold`, absolute 700: Thin, Light, Medium, SemiBold all become Bold | `Style::Italic`: weight kept (Light Italic, Medium Italic); synthesized oblique where none | family `monospace` |
| WinUI (`label_restyle`) | `FontWeights::Bold`, absolute 700 (code reading) | `FontStyle::Italic` (code reading) | `RICH_MONOSPACE` |
| Compose | `FontWeight.Bold`, absolute 700 (code reading) | `FontStyle.Italic` (code reading) | `FontFamily.Monospace`, DroidSansMono, ONE face (400 upright): its bold and italic are synthesized |

So kaya's Bold already means "weight 700" on three lanes and "the family's
bold" on two, which differ only for a face that is already 600 or more.
Proposed, uniform, and held by `expect_face` on rich runs:

- BOLD sets the run's weight to max(the face's weight, 700). Over Light it is
  700 (what every lane does today); over SemiBold it is 700 (Apple changes);
  over Black it stays 900. The alternative is CSS's relative `bolder`
  (below 350 becomes 400, 350 to 549 becomes 700, 550 to 899 becomes 900),
  which makes Bold over Light read as merely Regular. Q3.
- ITALIC keeps the run's weight and width and slants it, by the family's
  slanted face or by synthesis (§2.4). iOS's lost weight is fixed by matching
  the face (§2.4) instead of asking for a symbolic trait.
- CODE draws in the platform's monospaced face (M1) at the run's resolved
  weight and slope, matched by §2.4 against that face's own faces. In a
  widget that is already `monospaced` with a user `family` (the editor's
  document), a Code run uses that family too: code inside code stays in the
  user's code font.

## §4 The picker

### 4.1 The one semantics

ONE REQUEST, ONE ANSWER. The app asks; the user chooses or cancels; the app
hears exactly one answer: a family and a face, or cancel. Nothing is applied
by kaya, so cancel has nothing to restore. That fits four of five lanes as
they are (GTK, iOS, and the two kaya-drawn ones are modal and end once). The
Mac's panel is live: it sends `changeFont:` on every click and has no Cancel.
kaya gives it Cancel and Choose in the panel's accessory view (measured to
work, in a sheet and floating), keeps the clicks to itself, and answers once:
Choose answers `NSFontManager.selectedFont`, Cancel, Escape and the panel's
close button answer cancel.

The other design is the colour picker's (docs/color-picker-plan.md §3 rule 2):
a settled choice commits, and how many commits one visit makes is the
platform's, so the Mac would report every click and the app would preview
live. It is closer to the Mac's idiom, but it needs a "restore" on cancel
that four lanes cannot have (their dialogs report nothing until the end), so
the app would see two shapes of answer. Q1.

### 4.2 The request and the answer

- `show_font_dialog(dialog: U64, window: U64, initial_family: Str,
  initial_weight: U16, initial_italic: Bool, initial_width: U8, code_only:
  Bool, faces: Bool)`: the file dialog's shape (`show_file_dialog`). `faces`
  false asks for a family only; true for a family and a face. `code_only`
  lists monospaced families only.
- `font_dialog_result(dialog: U64, family: Str, weight: U16, italic: Bool,
  width: U8)`: the one answer; an EMPTY family is cancel, `file_dialog_result`'s
  "cancel is count zero" precedent. With `faces` false the face fields are
  the family's regular face (400, upright, 5) as the platform resolves it.
- One dialog at a time per app; a second request while one is open is
  refused at the root with a sentence, as two file dialogs are.

### 4.3 Each lowering

| backend | mechanism |
|---|---|
| Mac | `NSFontManager.shared.fontPanel(true)`, the initial font through `setSelectedFont`, an accessory view with Cancel (Escape) and Choose (Return); the mask `[.face]` (or `[]` when `faces` is false) answered by kaya's agent as the application's next responder, since the panel asks the responder chain and never NSFontManager's target (docs/traps.md, the font panel's mode mask); for `code_only`, a process collection of fixed-pitch descriptors (the Mac's "Fixed Width" collection and the descriptor match agree: 13 families) selected per Q2. The answer is read from `selectedFont`: family, then OS/2 weight, italic bit and width class. Floating or a sheet: Q1b |
| iOS | `UIFontPickerViewController` with `includeFaces = faces`, `filteredTraits = .traitMonoSpace` when `code_only`, presented as a sheet; `didPickFont` resolves the descriptor to a UIFont and reads its OS/2 table, then kaya dismisses; `didCancel` answers cancel. This is also the one door to fonts a user installed through a font app (docs/deferred.md, the iOS family list entry), which the picker lists and `UIFont.familyNames` does not (from Apple's documentation; nothing is installed on the simulator) |
| GTK | `GtkFontDialog` with a monospace `GtkCustomFilter` when `code_only` (which must also drop the emoji family, measured passing Pango's test); `faces` false is `choose_family`; `faces` true is `choose_font`, whose SIZE row is shown and ignored (GtkFontDialog has no family-and-face call without size; `choose_face` shows one family's faces only, and two dialogs in a row is not a picker). The PangoFontDescription's weight, style and stretch are the answer; "Dismissed by user" is cancel |
| WinUI | a ContentDialog: a search box, a ListView of families each drawn in itself, a faces list, a preview line, Cancel and Choose. Families from DirectWrite's system collection (the same list as `list_font_families`, so a pick always names a listed family); faces from each IDWriteFontFamily's fonts with SIMULATED ones dropped (WPF lists a simulated Oblique beside every real face, measured; DirectWrite flags them with `GetSimulations`); `code_only` by `IDWriteFont1::IsMonospacedFont` (an advance-width test caught Webdings and CJK fonts, measured, so it is not used) |
| Compose | a ModalBottomSheet: a search field, a LazyColumn of families each drawn in itself, the chosen family's faces as chips, a preview, Cancel and Choose. Faces from `SystemFonts.getAvailableFonts()` grouped by the family the M3 reader already derives, each Font's weight and slant (and a variable font's named entries, as fonts.xml declares them); fonts.xml's weight aliases (`sans-serif-light` and the rest) fold into their family as faces instead of being families. Monospace by comparing advances of `i` and `M` with emoji and symbol fonts excluded; Android has no monospace flag |

Both kaya-drawn pickers are built from the same core facts as the list: the
core sorts families and faces once (by weight, then upright before italic,
then width), so the two read the same.

THE CODE-ONLY RULE (2026-10-29, from the review captures): `code_only` lists
the INSTALLED families whose regular face is fixed pitch by the platform's own
test, whatever script they are for, and no generic alias. The Mac's Fixed
Width collection (Q2) lists Lantinghei TC, Osaka and PCMyungjo, CJK families
whose Latin is fixed pitch; DirectWrite's `IsMonospacedFont` and Pango's
`is_monospace` are the same per-face test, so every platform counts them, and
they stay. fonts.xml's `monospace` and `serif-monospace` and fontconfig's
`Monospace` are the platform's role face under a family's name: `list_font_families`
keeps them (M3: an app may name them in `family`), but a picker's answer is
kept as the user's family, and `monospaced` already gives the role face, so
the Android sheet and the GNOME filter leave them out. `expect_font_dialog
code_only` fails on a listed alias. Leaving the CJK families out would need a
kaya collection on the Mac in place of Fixed Width, which is a ruling, not
taken.

### 4.4 Listing faces without the picker

`list_font_faces(family)` answered by `font_faces(family, [weight, italic,
width, display name])`: what the kaya-drawn pickers need internally, what the
scenes need (§2.5), and what lets an app build its own style menu next to the
short family list. The display name is the platform's, for showing only; the
three values are what the app stores.

## §5 The surface

Rust: `.font_weight(300)`, `.font_italic(true)`, `.font_width(5)` on Label,
Entry and Textarea beside `.family(..)`; `tx.show_font_dialog(FontDialog {
initial: Some(face), code_only: true, faces: true })` with
`Messages::on_font_dialog(|answer| ...)` where `answer` is
`Option<FontChoice { family, weight, italic, width }>`, and the future form
`let choice = tx.show_font_dialog(..).await` (docs/async-dialogs-plan.md: Rust,
Swift, C# and Java await; Python, Haskell, OCaml and Go keep the callback);
`tx.list_font_faces(family)` with `on_font_faces`. Go: `FontWeight(300)`,
`FontItalic(true)`, `FontWidth(5)`, `ShowFontDialog(kaya.FontDialog{...},
func(c *kaya.FontChoice) {...})` (nil is cancel), `ListFontFaces`,
`OnFontFaces`. C#, Java, Swift, OCaml, Haskell, Python and JS follow their
dialog spellings; the C floor gets the generated setters, the request and the
records. Invariant 2's verdict: DO in all nine and the floor; nothing a
language cannot express.

## §6 The editor

RULED 2026-10-29 (the maintainer: "I think we can drop the short list"): View
carries one item, "Font…", in place of the Font radio group of code fonts; it
opens the picker with `code_only` on and `faces` on (a "Show all fonts"
checkbox is not offered: the editor is a code editor, and `code_only` false is
one argument away for an app that wants it). The chosen family and face apply
to the document and are remembered in the app's preferences, and the window
shows nothing else: the family is the document's `family`, the face its
`font_weight`, `font_italic` and `font_width`. Format > Bold and Italic
compose over it by §3, so Bold over a Light document reads 700 and Italic
keeps Light. Cancel changes nothing. The editor is Go, so its slice is a Go
guest change plus its scene's steps.

## §7 The harness and the scene

- `pick_font "<family>" <weight> <upright|italic> <width>` and `pick_font
  cancel` drive the open picker the way each lane can: on the Mac the
  harness selects the family and face rows of the panel in process and
  presses Choose (measured: in-process row selection fires the panel's own
  actions; harness-only, the doctabs precedent for a named private view in the
  harness file alone); on GTK it sets the chooser's font and answers its
  response (measured, `set_font` plus `response(OK)`); on iOS the resident
  XCUITest driver taps the rows (measured: the remote picker's tree is
  readable and a tap at a row's centre picks it); on WinUI and Compose the
  harness drives kaya's own controls.
- `pick_font first <weight> <upright|italic> <width>` picks that face of the
  first family the open picker lists: no code family is installed on all five
  platforms, so a shared script (the editor's) cannot name one. It follows an
  `expect_font_dialog code_only`, which waits for the Mac panel's collection.
- `expect_font_dialog open|closed`, and `expect_font_dialog code_only` which
  reads the families the open picker lists (the Mac panel's family table, the
  GTK list model, iOS's remote tree, kaya's own lists) and fails on one that
  is not monospaced.
- A `fontpick` scene, every lane, every language: the guest lists
  families and faces and labels a family with three or more weights; it opens
  the picker with `code_only`, the steps check the listing, pick a face,
  and `expect_face` holds a label the app set from the answer; then a cancel,
  which leaves the label as it was; then the face props' matching and
  synthesis cases (§2.5); then rich text: Bold over a Light run, Italic over
  a Light run, a Code run, each read with `expect_face` on the run.
- check-verbs holds the new verbs in both interpreters; check-sugar-surface
  the three props, the request and the two handlers in all nine bindings.

## §8 Cost and order

Depth then breadth, one agent in the core at a time.

| Slice | What | Size |
|---|---|---|
| F1 | Spec: the three props, `show_font_dialog`, `font_dialog_result`, `list_font_faces` and `font_faces`; core: the walls (ranges, one dialog at a time), the face sorter; the Rust surface | S to M |
| F2 | Mac: face matching and Apple's synthesis on the three kinds, `expect_face face`, the rich-text composition change, `list_font_faces`, the panel with Cancel and Choose, the code-only route per Q2, `pick_font`; the Rust scene green on the Mac with every negative watched | M to L |
| B1 | GTK: the dialog, matching (fontconfig does most), the emoji filter fix, the reads | S to M |
| B2 | iOS: the picker, the trait fix in rich text, the XCUITest `pick_font` | M |
| B3 | WinUI: the ContentDialog picker, DirectWrite faces, the reads | M to L |
| B4 | Compose: the bottom sheet, the faces reader over SystemFonts, synthesis flags | M |
| B5 | Python, Go, C#, Java, Swift, OCaml, Haskell, JS; the C floor | S each |
| E | The editor's Other Font… and its scene steps | S |
| V | `validate-all --only fontpick,codesurface,richtext,editor`, then one matrix; the review page: the picker open on every lane, a pick, a cancel, Bold and Italic over Light | |

About L together, the colour picker's size plus the face matching.

Guards, each a wall someone walks into: the root refuses an out-of-range
weight or width and a second open dialog (unit tests); `expect_face face`
reads the toolkit's resolved font, with the three watched negatives of §2.5;
`expect_font_dialog code_only` fails on a proportional family in the list
(perturbed by dropping the filter on each lane); check-verbs and
check-sugar-surface as above. This plan's own commit is docs only;
tools/check-doc-refs.py holds every path it names.

## §9 Not in this plan

Optical size and other variable axes beyond weight, width and slant; font
features (ligatures, stylistic sets: GTK's `choose_font_and_features` offers
them, the others do not); the font SIZE in the picker (S1 ruled the size a
relative scale, `text_scale`, so the pickers' size fields are hidden on the
Mac floating panel and ignored elsewhere); installing or bundling fonts
beyond `set_brand_typeface`.

## §10 Questions for the maintainer

Each had a recommendation; the explanations start from zero. All seven are
RULED (2026-10-29).

**Q1. Does the picker answer once, or every time the user clicks?** On a Mac
the font panel is "live": every click in it changes the selected text at once,
and the panel never says "done"; you just close it. Every other platform's
picker is a dialog that answers once, when you press Select or Cancel. (a) ONE
ANSWER everywhere: kaya adds Cancel and Choose buttons to the Mac panel
(measured working) and tells the app only at the end. Simple for the app and
identical on five platforms. (b) LIVE on the Mac: the app hears each click and
can preview the font in the document as the user browses; on cancel the app
puts the old font back; the other four still answer once. RULED 2026-10-29: (a).
Sub-question Q1b, the Mac's form: a FLOATING panel (the user can still type in
the window while it is open, the size and B/I/U controls are hidden as kaya
asks, and the code-fonts-only lock works) or a SHEET on the window (the window
is blocked until Choose or Cancel, like every other platform, but macOS
ignores kaya's request to hide the size field and the B/I/U popup inside a
sheet, measured, and the code-only lock cannot hide the collections popup).
RULED 2026-10-29: floating, with Cancel and Choose.

**Q2. How does the Mac show code fonts only?** kaya can publicly add a "Code"
collection (all fixed-width fonts, 13 on this Mac) to the panel's collections
menu. What has no public API is choosing it for the user: on macOS 26 that is
done by pressing the collections menu item in the panel's toolbar, which kaya
can reach only through an undocumented toolbar identifier, and kaya's macOS
13 to 15 floor has an older panel whose collections are a column (unmeasured).
(a) Select it through the toolbar item on 26 and the column on older macOS,
both outside public API, with a check that fails loudly when Apple renames
them. (b) Public only: add the "Code" collection but leave the panel on All
Fonts; the user picks "Code" themselves. (c) When the app asks for code fonts
only, draw the kaya picker on the Mac too, as on Windows. RULED 2026-10-29,
changed from the recommendation (the maintainer: "I don't mind using the
undocumented code list control thing"): the Mac's BUILT-IN "Fixed Width"
collection (the probe found the same 13 families), selected through
`NSFontPanelCollectionsToolbarItem` on macOS 26, with a loud check (a
diagnostic naming what was missing, and `expect_font_dialog code_only` failing
when the panel did not end on Fixed Width); when the item is missing the native
panel opens unfiltered with Fixed Width one click away. Nothing is built for the
column on macOS 13 to 15, which is unmeasured (docs/deferred.md, the font panel
before macOS 26).

**Q3. What does Bold do on a font that is already thin or already heavy?**
A face has a weight number (300 is Light, 400 Regular, 600 SemiBold, 700
Bold). (a) Bold means "at least 700": Light becomes 700, SemiBold becomes 700,
Black (900) stays. This is what GTK, Windows and Android do today and what
the Mac and iOS do except on 600 faces. (b) CSS's relative "bolder": one
step heavier, so Light becomes Regular (400), Regular becomes Bold, SemiBold
becomes Black. Word processors and editors use (a); (b) makes Bold over a
Light document look unbolded. RULED 2026-10-29: (a), at least 700.

**Q4. Should kaya fake a slant or a bold the font does not have?** Some fonts
have no italic (Monaco, PT Mono, DejaVu Sans) or no bold (Monaco, Android's
monospace). Linux, Windows and Android fake them (a sheared or thickened
copy); the Mac and iOS do not, so today Italic on Monaco does nothing on a
Mac and slants on Linux. (a) Fake them on all five, drawn by kaya on Apple,
and say so in `expect_face`. (b) Never fake; Italic on a font without italic
does nothing anywhere, which needs the three lanes' faking turned off. (c)
Leave each platform's habit, a stated divergence. RULED 2026-10-29: (a),
synthesized on all five, drawn by kaya on Apple, reported by `expect_face`.

**Q5. Is "oblique" its own choice?** Some fonts call their slanted face
Italic, some Oblique, and a few have both. (a) One switch, `font_italic`: the
font's slanted face, whatever it is called. (b) Three states, upright,
italic, oblique. Only a typography tool needs (b). RULED 2026-10-29: (a).

**Q6. With `faces` on, GNOME shows a size slider kaya will ignore.**
GtkFontDialog has no "family and face but no size" form: its family-and-face
dialog also shows a size row. (a) Use it and ignore the size (the size stays
the app's `text_scale`). (b) Ask the family first, then a second dialog for
the face. (c) Draw kaya's own picker on GNOME too. RULED 2026-10-29: (a),
GNOME's family-and-face dialog with its size ignored.

**Q7. May the app read a family's faces without a picker?** The kaya-drawn
pickers need the list internally and the scenes need it to test portably.
Exposing it as `list_font_faces` also lets an app build its own style menu.
RULED 2026-10-29: yes, `list_font_faces`, the same shape as `list_font_families`.

## §11 The probe record

Probes and outputs live in the session scratchpad's `fontpick/` folder (not
in the tree); captures in `fontpick/caps/`, all on the review page.

- Mac (macOS 26.6.2, an AppKit probe compiled through
  tools/lib/swift-toolchain.sh): `mac-faces.txt` (members, Bold and Italic
  over each face, collections, private selectors); `mac-panel*.txt`,
  `mac-sheetacc.txt`. Captures: `mac-standard-panel`, `mac-standard-picked`,
  `mac-nosize-after-query`, `mac-noeffects-after-query`,
  `mac-noface-after-query`, `mac-familyonly-after-query`,
  `mac-facenocoll-after-query`, `mac-trigger-1` to `-5`, `mac-collection-picked`,
  `mac-codelock-panel`, `mac-codelock-picked`, `mac-accessory-panel`,
  `mac-sheet-host`, `mac-sheetpick`, `mac-sheetacc`, `mac-sheetkey`,
  `mac-modal-panel`, `mac-modal-picked`, `mac-modalcancel-picked`,
  `mac-modalobj-picked`, `mac-modalkey-panel`, `mac-modalkey-picked`.
- iOS (iOS 26.5 simulator "iPhone 17", not a pool device; booted for the
  probe and shut down; picks through a copy of the lane's XCUITest driver):
  `ios-probe.txt`, `ios-pickermono-tree.txt`, `ios-pickermonofaces-tree.txt`,
  `ios-pickermonofaces-drill-tree.txt`. Captures: `ios-picker-1`,
  `ios-pickerfaces-1`, `ios-pickermono-1`, `ios-pickermonofaces-1`,
  `ios-pickermonofaces-drill`.
- GTK (the kaya-linux image, GTK 4.24.0, Pango 1.58, under Xvfb):
  `gtk-probe.txt`. Captures: `gtk-familymono-open`, `gtk-familymono-picked`,
  `gtk-face-open`, `gtk-face-picked`, `gtk-font-open`, `gtk-font-picked`,
  `gtk-fontcancel-open`.
- Windows (the VM, build 26200, WPF's typeface list over ssh; DirectWrite
  itself not called): `win-faces.txt`.
- Android (emulator-5554, Android 15, API 35): `android-fonts.xml` (the
  device's /system/etc/fonts.xml), `android-fonts.txt`.
- Unmeasured and marked so above: the Mac panel on macOS 13 to 15; iOS with
  user-installed fonts; DirectWrite's own enumeration and
  `IsMonospacedFont`; Android's `SystemFonts` Font objects; Bold and Italic
  over a Light face on WinUI and Compose (code reading only).
