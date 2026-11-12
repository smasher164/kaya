# The rich document: the design pass (2026-11-05, rulings TAKEN 2026-11-11)

Status: RULED 2026-11-11; the build began 2026-11-11 and §11 records it. RD9 RULED A and the safe save
through a picked file (§4.1) RULED; every other ruling (RD1-RD8, RD10, RD11,
RD13-RD16) RULED as recommended; RD17 RULED A and RD18 RULED B on
2026-11-12 ("I like all the recommendations except rd12") and BUILT the same
day, RD18 on GTK and Compose; RD19 (the Mac, iOS and WinUI half of RD18) and
RD20 (a Document kept in a model field) RULED A and B respectively on 2026-11-12 and BUILT
the same day, RD21 (WinUI's field text read) ASKED 2026-11-12; RD12 RULED as amended: no Markdown and no DOCX, the clipboard's RTF
and HTML in the first build (the maintainer: "why do we even have markdown
import and export?" and "i feel like that's out of scope for our rich text
editor"). The review page is
https://claude.ai/artifact/8PxsiUURHiARrkG5tgxMXq.

The maintainer's ask, 2026-11-05: the editor's Writing Mode should look like
a traditional rich document (Apple Notes, a rich text editor), not Markdown
drawn styled. In their words: "i feel like those features like indentation
and coloring of text should be inherent in our rich text support"; "free
color picker if that can be lowered to each platform, cause it's a rich text
document. i think B for the file, though that might be a pandoras box in
terms of formats. im inclined to make this extendable to that crdt idea i
had in the past, so the way that automerge, json-crdt, peritext, notes, rtf,
docx, etc… work might be useful to understand". "B" is Writing Mode saving
its own rich document format rather than round-tripping `.md` files. And,
later the same day, about the container: "yeah it'd be nice if we
repurposed sqlite but that's just a thought". That is a thought, not a
ruling; RD9 weighs it.

This plan sits on docs/rich-text-plan.md (R1-R10, the addressed-edit
protocol, its §16 notes demo with automerge behind the widget and its §6
automerge benchmark), docs/styling-pass-plan.md (Y7's refusal of raw colour
on text), docs/tints-plan.md (T3, the data-colour tier), docs/editor-plan.md
(E8, Writing Mode as built) and docs/design-rules.md (Writing Mode's
Markdown drawn styled, ruled 2026-11-04, which RD11 would replace). The
research behind every claim was gathered the same day by four agents; their
notes are summarised in §1 with the primary sources cited inline.

## §0. The mechanism, from zero

**What a rich document is, to a program.** A rich document is text plus
formatting. Every system that edits one, from Apple Notes to Word to the
collaborative editors, stores it in one of two shapes.

- The FLAT shape: the whole text is one string, the formatting is a list of
  INLINE MARKS (a MARK is one attribute over one range of the text: "bytes
  12 to 20 are bold", "this range is a link to that URL"), and each
  PARAGRAPH carries its own attributes ("this paragraph is a heading", "this
  one is a list item, indented twice"). A paragraph is the text between two
  line breaks. Apple Notes, Quill, Portable Text, RTF, Word's `w:p`/`w:r`,
  Automerge and json-joy are all this shape underneath.
- The TREE shape: the document is nested nodes (a list node holding item
  nodes holding paragraph nodes), the way HTML is. ProseMirror's default
  schema, Lexical and Markdown are this shape.

kaya's rich textarea is already flat: the text, plus RUNS (kaya's word for a
mark as the wire carries it: start, end, name, value, in UTF-8 bytes), with
one paragraph attribute, `block`, carried as a run that must cover whole
paragraphs (docs/rich-text-plan.md §2). This plan keeps that shape and grows
it.

**What a mark does at its edges.** When the user types at the end of a bold
word, should the new letters be bold? For bold, yes; for a link, no (nobody
wants the next word to become part of the link). That choice is the mark's
EXPAND RULE: whether a mark grows to take text inserted at its start, at its
end, at both or at neither. The Peritext paper names it and Automerge spells
it per mark (`ExpandMark::Before | After | Both | None`).

**What a list is, in a flat document.** A list item is a paragraph with a
list attribute (bullet, numbered, checklist) and a LEVEL (how far it is
indented). The marker, "•" or "3.", is not in the text: the toolkit draws
it, and the number is worked out from position (the third numbered item at
level 0 in a row draws "3."). Notes, Word, RTF, Quill and Portable Text all
work this way. kaya ruled the marker rule in 2026-09 (R3): "kaya's block
model owns list semantics and no marker is ever in the guest-visible text".

**What colour means in a document.** A coloured word stores a colour. A word
with no colour is AUTOMATIC: it takes the page's own ink, black on a light
page and white on a dark one. Word calls this `auto`, RTF colour 0, Cocoa an
absent attribute, Notion `default`. The hard part is the dark appearance: a
dark blue chosen on a white page is unreadable on a black one, and every
product answers that differently (§1.6).

**What a CRDT is, and why the format cares.** A CRDT (a conflict-free
replicated data type) is a data structure that two people can edit at the
same time on two machines, exchange edits in any order, and end with the
same document without a server deciding. Automerge is one; its rich text is
the Peritext design. kaya's widget already speaks in edits, not whole
strings, so a CRDT can sit behind it (the notes demo, docs/rich-text-plan.md
§16). The maintainer wants the document format to be one that a CRDT can
carry later WITHOUT changing the format: every paragraph attribute and
every mark kaya defines must have a home in Automerge's model, and the merge
of two people's edits must mean something sensible for each.

**What a container is.** The format is the model (paragraphs, marks,
attributes); the CONTAINER is the bytes on disk that hold it: a JSON text
file, Automerge's own binary, a SQLite database, a zip of files. They can
be chosen apart, and RD9 does.

## §1. What the formats do (the research)

### §1.1 Automerge's rich text (2.2 and later, unchanged in 3.x)

Sources: https://automerge.org/docs/reference/documents/rich-text/ ,
https://automerge.org/docs/reference/under-the-hood/rich-text-schema/ ,
https://automerge.org/blog/rich-text/ , the Rust source at
https://github.com/automerge/automerge (`marks.rs`, `transaction/inner.rs`,
`text_diff.rs`, `automerge-wasm/src/lib.rs`) and
https://github.com/automerge/automerge-prosemirror .

- Rich text is "plain text annotated with spans and blocks", not a tree. The
  authors argue trees merge badly: a concurrent "add a list item" and "turn
  the list into paragraphs" forces a tree editor to drop one; Automerge keeps
  both.
- A paragraph boundary is a BLOCK MARKER: a small map object inserted into
  the text sequence as one element (`splitBlock` inserts it, `joinBlock`
  deletes it). Its keys are `type`, `parents` (the enclosing block types, so
  `["blockquote"]` puts a paragraph in a quote), `attrs` and `isEmbed`.
  Text after a marker belongs to it until the next marker.
- Lists are block types `ordered-list-item` and `unordered-list-item`.
  There is NO level number: nesting is the `parents` path, and indenting an
  item inserts a parent. No start number and no checklist type in the
  standard schema.
- A mark is a name and a scalar value, written as a begin op and an end op
  anchored to character identities (not to offsets), with `ExpandMark`
  `Before | After | Both | None`; the Rust default is `After`.
  automerge-prosemirror maps ProseMirror's `inclusive` flag to `both` or
  `none`, and links are `none`. One position holds one value per mark name:
  two people setting different values on overlapping ranges get "a
  consistent (but arbitrary) value".
- Standard names: `strong`, `em`, `link` (a JSON string with `href`),
  block types `paragraph`, `heading` (`attrs.level`), `code-block`,
  `blockquote`, `image` (an embed). App names must start with `__ext__`.
  Unknown marks and unknown block attributes "MUST be round-tripped".
- A merge trap found in the source: the wasm `updateBlock` deletes the old
  marker and inserts a new one, so two people changing one paragraph's kind
  at once may leave two markers (an extra empty paragraph; inferred, not
  measured). `updateSpans` instead edits the existing marker key by key,
  which merges per key. A bridge must use the second.
- The binary format (https://automerge.org/automerge-binary-format-spec/)
  is a sequence of self-checksummed chunks, so a `save()` followed by
  appended `save_incremental()` bytes is itself a valid file, and the 0.11
  crate kaya pins loads a torn tail with `OnPartialLoad::Ignore`. The
  260,000-keystroke editing trace is 107,121 bytes of text and 129,062 bytes
  as a document with full history (https://automerge.org/blog/automerge-2/).

### §1.2 Peritext (Litt, Lim, Kleppmann, van Hardenberg, CSCW 2022)

Source: https://www.inkandswitch.com/peritext/ (DOI 10.1145/3555644),
reference code at https://github.com/inkandswitch/peritext .

- "A formatting change always occurs in the 'gap' between two characters":
  each mark edge is anchored before or after a character's identity, which
  is how the expand rule is expressed. Bold ends "in the gap immediately
  before" the next character, so it grows; a link ends "on the last
  character of the span", so it does not.
- The rules in prose: "a bold or italic span grows to include text inserted
  at the end of the span"; "a link or comment span does not grow"; at the
  start of a paragraph a character takes the formatting of the character
  after it.
- Conflicts: bold and unbold over the same text resolve last writer wins
  by operation id; a colour or a link URL is an exclusive value and one
  writer's value is chosen deterministically; comments are many-valued and
  coexist.
- It fixes three anomalies: Markdown's `**` interleaving under concurrent
  edits, Yjs-style start and end control items closing a mark early, and
  duplicated text from formatting stored as a JSON span list.
- Out of scope, stated: "headings, bullet points, block quotes, and tables"
  are future work. Automerge's block markers (§1.1) are Ink & Switch's later
  answer; no paper on them was found.

### §1.3 json-joy's JSON CRDT and its Peritext

Source: https://github.com/streamich/json-joy (`json-crdt-extensions/peritext/`),
https://jsonjoy.com/specs/json-crdt .

- One RGA string holds all the text; an array of SLICES holds every
  annotation. A slice is `[header, x1, x2, type, data]`, each edge anchored
  before or after a character, which gives each slice its own expand rule.
- The STACKING kind decides merges: `One` replaces (bold, italic, colour),
  `Many` stacks (links, comments), `Erase` removes earlier ones (unbold),
  `Marker` is a block split, `Atomic` an island the caret cannot enter.
- A block boundary is a real `"\n"` in the text plus a `Marker` slice on it
  carrying the block's path (`['ul','li','p']`, with per-step data such as
  `{indent: 2}`). Colour is a built-in `col` slice with data, and a
  background colour `bg`.
- Its "sidecar" codec stores the plain JSON view apart from the CRDT
  metadata, which is the shape RD9 recommends for kaya's later step.

### §1.4 Yjs, briefly

Sources: https://docs.yjs.dev/api/shared-types/y.text , source at
https://github.com/yjs/yjs/blob/v13.6.33/src/types/YText.js ,
https://github.com/yjs/y-prosemirror/blob/v1.3.7/src/plugins/sync-plugin.js .

- `Y.Text` is Quill's Delta model: formatting is stored as format items in
  the sequence (a start item and a negating end item), the model Peritext
  shows closing a mark too early under concurrency. Text inserted at an
  index takes the attributes on its left, so every mark expands at its end
  unless the editor passes explicit attributes; there is no per-mark rule.
- Paragraph formatting is attributes on the `"\n"` that ends the line,
  lists are `list` plus an integer `indent`.
- `Y.XmlFragment` with y-prosemirror is the tree form: lists are nested
  elements, so the tree-merge problem of §1.1 applies.

### §1.5 Apple Notes (public reverse engineering; Apple publishes nothing)

Sources: https://github.com/threeplanetssoftware/apple_cloud_notes_parser
(`proto/notestore.proto`, `lib/AppleNote.rb`, `lib/ProtoPatches.rb`),
https://www.ciofecaforensics.com/2020/09/18/apple-notes-revisited-protobuf/ ,
https://www.ciofecaforensics.com/2024/12/10/ios18-notes/ ,
https://github.com/dunhamsteve/notesutils/blob/master/notes.md ,
https://news.ycombinator.com/item?id=17744375 ,
https://github.com/ericmigi/Notes-Of-Fruit .

- The library is `NoteStore.sqlite`; each note's body is ONE gzipped
  protobuf blob in a row (`ZICNOTEDATA.ZDATA`). SQLite is the index of
  notes, never a log of edits.
- The body is one string plus ATTRIBUTE RUNS that "are in order, disjoint,
  and their length sums to the length of string" (the NSAttributedString
  shape). A run carries `paragraph_style`, font, weight hints (bold,
  italic), underline, strikethrough, superscript, `link`, `color` (RGBA
  floats, so ARBITRARY text colour, set on the Mac through Format > Font >
  Show Colors), `attachment_info` (on a U+FFFC placeholder character) and,
  since iOS 18, `emphasis_style`: a highlight from a NAMED palette of five
  (purple, pink, orange, mint, blue), not RGBA.
- `ParagraphStyle` holds `style_type` (title, heading, subheading,
  monospaced, dotted, dashed and numbered lists, checklist), `alignment`,
  `indent_amount` (an integer level), `checklist` (each item its own UUID
  and a done flag) and `block_quote`. A list item is a paragraph of a list
  style; nesting is `indent_amount`; NO number is stored, numbering is
  counted from neighbours.
- The CRDT, which Apple calls topotext, is an RGA-like list of characters
  with Lamport clocks and tombstones and a per-character last-writer-wins
  clock for attributes. Formatting is serialised positionally. Tables are a
  CRDT of their own (rows and columns as ordered UUID sets).

### §1.6 RTF (Microsoft's RTF 1.9.1, 2008, the last version)

Source: the specification, archived at
https://web.archive.org/web/20190708132914/http://www.kleinlercher.at/tools/Windows_Protocols/Word2007RTFSpec9.pdf
(Microsoft's own copy:
http://download.microsoft.com/download/2/f/5/2f599e18-07ee-4ec5-a1e7-f4e6a9423592/Word2007RTFSpec9.doc);
https://www.loc.gov/preservation/digital/formats/fdd/fdd000473.shtml .

- A state machine over a stack of groups: `{` saves the formatting state,
  `}` restores it; `\par` ends a paragraph, `\pard` resets its attributes.
  Runs come out flat whatever the braces look like.
- Colour is a table, `{\colortbl;\red0\green0\blue0;…}`, and text refers to
  an index (`\cfN`). Entry 0 left empty is "the 'auto' color", so `\cf0` is
  automatic, distinct from an explicit black. Word 2007 theme colours ride
  with an RGB fallback "so that theme-unaware applications can read what the
  given color evaluates to".
- Lists are a document-level `\listtable` plus `\listoverridetable`, and a
  paragraph carries `\lsN` (which list) and `\ilvlN` (its level, 0 to 8):
  flat paragraphs with a level, exactly Notes' shape. Each item also carries
  its rendered number as plain `{\listtext …}` so an old reader shows it.
- Extensibility has two idioms: an unknown `{\* …}` group is skipped
  whole, and a writer pre-renders a fallback for readers that do not know a
  feature (`\listtext`, `\shppict`/`\nonshppict`, `\fldinst`/`\fldrslt`).
  The version has been `\rtf1` since 1987.
- Apple's dialect (measured on this Mac, macOS 26.6.2, NSAttributedString
  with `.rtf`): a parallel, undocumented `{\*\expandedcolortbl …}` writes
  each colour's space, components and alpha, and a system colour by NAME
  (`\cname labelColor`, `textColor`, `systemRedColor`); reading back restores
  the appearance-following colour, while a non-Cocoa reader sees only the
  light RGB. A run with no colour is written `\cf0` and reads back with no
  colour. Lists are written with `\listtable` plus an extra `{\*\levelmarker
  \{disc\}}` per level. Apple documents its other extensions at
  https://developer.apple.com/library/mac/documentation/Cocoa/Conceptual/AttributedStrings/Tasks/RTFAndAttrStrings.html .
- RTF matters to kaya as the CLIPBOARD's rich flavour: TextEdit, Pages,
  Mail and WordPad exchange formatted text through it (RD12).

### §1.7 DOCX, WordprocessingML (ECMA-376)

Sources: https://ecma-international.org/publications-and-standards/standards/ecma-376/ ;
the Open XML SDK pages for `Color`
(https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.wordprocessing.color?view=openxml-3.0.1),
`NumberingProperties`, `AbstractNum` and `LevelText`; the ECMA-376 mirror at
https://webapp.docx4java.org/OnlineDemo/ecma376/WordML/color_1.html ,
`ST_HexColor.html`, `highlight.html`; Microsoft's Dark Mode in Word page
https://support.microsoft.com/en-us/office/dark-mode-in-word-e17b79a3-762f-4280-a81c-a15a859a693a .

- A tree of XML whose leaves are flat anyway: `w:body` holds `w:p`
  paragraphs (properties in `w:pPr`) holding `w:r` runs (properties in
  `w:rPr`); a run never holds a run. Properties resolve through a style
  hierarchy.
- Lists: a paragraph's `w:numPr` names a numbering instance (`w:numId`) and a
  level (`w:ilvl`, 0 to 8); `numbering.xml` defines per level the start, the
  format (`decimal`, `bullet`, letters, Roman) and the marker text (`%1.`).
  No number is stored in the paragraph; a reader counts, which is "the
  hardest part of list fidelity".
- `w:color w:val="auto"` (or the element absent everywhere in the style
  hierarchy) lets "the consumer … automatically choose an appropriate color
  based on the background color behind the run's content"; theme colours
  (`w:themeColor`) carry an RGB fallback. `w:highlight` is a CLOSED palette
  of 17 named colours; arbitrary backgrounds are `w:shd`.
- Extensibility is Markup Compatibility (ECMA-376 Part 3): `mc:Ignorable`
  namespaces are dropped when not understood, `mc:ProcessContent` unwraps,
  `mc:MustUnderstand` makes the reader refuse, and `mc:AlternateContent`
  offers a choice with a fallback. RD8 borrows the three verdicts.
- A faithful reader is hard: Part 1 runs to thousands of pages, and real
  readers (LibreOffice, pandoc, mammoth) each implement a subset.

### §1.8 For contrast: Quill Delta, Portable Text, Lexical, ProseMirror

Sources: https://quilljs.com/docs/delta , https://quilljs.com/docs/formats ,
Quill's `formats/list.ts` and `formats/indent.ts`;
https://github.com/portabletext/portabletext ,
https://github.com/portabletext/react-portabletext ;
https://github.com/facebook/lexical (`LexicalNode.ts`, `LexicalConstants.ts`,
`lexical-list`, `LexicalUpdates.ts`); https://prosemirror.net/docs/guide/ ,
https://github.com/ProseMirror/prosemirror-model ,
https://github.com/ProseMirror/prosemirror-schema-list ,
https://github.com/ocavue/prosemirror-flat-list .

| | inline marks | paragraph and list model | colour | unknown content | version |
|---|---|---|---|---|---|
| Quill Delta | attribute sets on inserts | attributes on the line's `"\n"`; `list` plus `indent` 1-8 | raw CSS strings | dropped on load | none |
| Portable Text | decorators by name, annotations by key into `markDefs` | flat blocks with `style`, `listItem` and `level` | none in the core | kept; rendering falls back with a warning | none |
| Lexical | a bitmask on text nodes; links are containers | a tree; lists nest | a raw CSS `style` string | parse FAILS on an unknown node | a per-node `version` it now calls dead: "Nothing reads it" |
| ProseMirror | marks on text nodes, `inclusive` and `excludes` per mark | a schema-checked tree; prosemirror-flat-list makes lists flat | an app mark | an unknown node or mark THROWS; unknown attributes are dropped | none; the schema is the version |

What the comparison says for kaya: every format flattens inline formatting
into runs; the flat formats (and both office formats) model a list item as a
paragraph with a list attribute and a level, and prosemirror-flat-list moved
ProseMirror's own ecosystem toward that shape for "indent/dedent that moves
only the selected part"; and the editors that refuse unknown content at
parse time are the ones that cannot carry an extension.

### §1.9 Markdown as an export target

Sources: https://spec.commonmark.org/0.31.2/ , https://github.github.com/gfm/ ,
https://github.com/github/markup , pandoc's MANUAL.

CommonMark and GFM carry headings, quotes, bullet and ordered lists (with a
start number), task list items, code, emphasis, strong, strikethrough and
links. They cannot carry text colour, a highlight, underline, alignment,
indentation outside a list or quote, or a list level that jumps by more
than one. Inline HTML is the escape (`<u>`, `<span style="color:…">`), but
GitHub's sanitizer strips inline styles, so colour does not survive there.

### §1.10 Colour in the dark appearance, product by product

Sources: §1.7's Word page and
https://techcommunity.microsoft.com/t5/microsoft-365-insider-blog/try-dark-mode-in-word/ba-p/4211941 ;
https://support.google.com/docs/answer/9955476 ;
https://developers.notion.com/reference/rich-text ,
https://www.notion.com/help/appearance-settings ;
https://support.apple.com/en-gb/guide/textedit/txtee6663a0e/1.20/mac/15.0 ,
https://eclecticlight.co/2018/12/10/rendering-rich-text-in-dark-mode/ ;
https://discussions.apple.com/thread/256110138 ;
https://support.apple.com/en-nz/guide/notes/apd97da26aed/4.7/mac ;
the macOS 26 SDK header `NSTextView.h`.

| product | what it stores | what a dark page shows | escape |
|---|---|---|---|
| Word | RGB, or `auto` | the page goes dark and colours are "shifted slightly to mute the overall effect of the color palette"; the mapping is unpublished | Switch Modes, or "Never change the document page color" |
| Google Docs (phones) | RGB | "automatically adjusts your documents … to fit the theme"; unpublished | View in light theme |
| Notion | a NAME from ten (`default`, gray, brown, orange, yellow, green, blue, purple, pink, red) and ten backgrounds | each name has a designed value per theme | none needed |
| TextEdit (NSTextView adaptive mapping) | the light colour | brightness inverted; Apple's header: it "does not retain the round-trip fidelity … may not be suitable for rich text authoring" | Use Dark Background for Windows, off |
| Apple Notes | RGBA as picked | automatic text follows the theme; a picked colour stays FIXED, so white text picked on a dark iPad is "faint and hard to read" on a light Mac | Note backgrounds: light |
| Pages | RGB | the canvas stays white (user reports only) | n/a |

The pattern: every product keeps the STORED colour independent of the
appearance and decides at drawing time, and every one treats automatic text
as following the theme. The disagreement is only in what a dark page does
to an explicit colour: keep it (Notes, and unreadable both ways), invert it
(TextEdit, lossy), shift it (Word, Docs), or have designed per-theme values
for a closed palette (Notion).

### §1.11 What each platform's rich text widget does with colour and lists

Sources: Apple's pages for `TextEditor`
(https://developer.apple.com/documentation/swiftui/texteditor), NSTextView's
`changeColor(_:)`, `NSTextList`
(https://developer.apple.com/documentation/uikit/nstextlist), WWDC22 10090
and WWDC25 280; the macOS 26 SDK headers `NSTextList.h` and
`NSAttributedString.h`; https://developer.apple.com/forums/thread/763800 ;
https://developer.android.com/reference/kotlin/androidx/compose/foundation/text/input/TextFieldBuffer ,
https://developer.android.com/reference/kotlin/androidx/compose/ui/text/Bullet ;
https://docs.gtk.org/gtk4/class.TextTag.html ,
https://docs.gtk.org/gtk4/vfunc.TextView.snapshot_layer.html ,
https://docs.gtk.org/gtk4/class.ColorDialog.html ;
https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.text.itextparagraphformat ,
`TextGetOptions`, `TextConstants.AutoColor`,
https://github.com/microsoft/microsoft-ui-xaml/issues/5893 and
https://github.com/microsoft/microsoft-ui-xaml/issues/6908 .

| platform | a run's colour, set and read | the platform's picker | automatic ink in the dark | an explicit colour in the dark | lists |
|---|---|---|---|---|---|
| macOS NSTextView (TextKit 2) | `.foregroundColor` in the storage, read with `attribute(_:at:)` | NSColorPanel drives `changeColor:` on the selection with no app code, so the arm must catch it | only if the run carries the dynamic `NSColor.textColor` (an absent attribute draws black; kaya already writes `textColor`) | fixed, unless `usesAdaptiveColorMappingForDarkAppearance` (off by default) inverts it | NATIVE: `NSParagraphStyle.textLists`, the marker drawn by TextKit 2 and absent from the string; measured drawing "1" and "2" offscreen on 26.6.2 with no marker characters; BROKEN on macOS 14 and 15 (FB15162186, "That seems to be a regression") |
| iOS UITextView (TextKit 2) | the same key, `UIColor` | `UIColorPickerViewController`; iOS 18's format panel has a `textColor` component | `UIColor.label` | fixed; UIKit has no adaptive mapping | native since iOS 16 (forum reports; kaya has not measured) |
| SwiftUI TextEditor (26) | `AttributedString.foregroundColor` | its own colour control | nil follows the environment | literal RGB fixed | none in SwiftUI's scope; kaya does not use this editor (rich-text plan §5) |
| GTK 4 GtkTextView | a tag's `foreground-rgba`, read back by the tag's name | `GtkColorDialog` (4.10), the app applies the tag | untagged text follows CSS | fixed `GdkRGBA`; the arm recomputes on `notify::dark` | NONE: a margin tag plus a marker drawn in `snapshot_layer`, the way kaya already draws the quote rule; a paintable would be a U+FFFC character in the buffer and is refused |
| Compose BasicTextField | `SpanStyle(color)` through the output transformation (display only on 1.11.4; kaya's mirror is the truth) | none first-party; kaya's colour picker synthesizes a Material sheet (docs/color-picker-plan.md §6) | `Color.Unspecified` takes the field's colour | fixed ARGB; the arm re-resolves | NONE in the editable field (`Bullet` is for read-only text and has no numbers): a `TextIndent` paragraph style plus a marker painted in `drawBehind` from the layout, as the quote rule is |
| WinUI RichEditBox | `ITextRange.CharacterFormat.ForegroundColor`, read per range (tri-state on a mixed one) | `ColorPicker` in a flyout, the app applies it | `TextConstants.AutoColor` | NOT reliably kept: a theme switch pushes the control's Foreground into the document (#5893; #6908 "RTF colors are lost on theme change", closed not planned), so the arm re-applies its runs after `ActualThemeChanged` | NATIVE: `ParagraphFormat.ListType`, `ListStart`, `ListLevelIndex`; numbers appear in `GetText` only with `IncludeNumbering`; whether a list paragraph moves TOM offsets is unmeasured |

## §2. The proposed model

One document, the flat shape kaya already has, grown in three places.

**The text.** Unchanged: one string, paragraphs separated by `"\n"`, UTF-8
bytes on kaya's wire (R2). No marker, number or placeholder is ever in it.

**Paragraph attributes** (RD1), each a run that must cover whole
paragraphs, validated where `block` is validated today:

| name | values | default | notes |
|---|---|---|---|
| `block` | `body`, `heading1`-`heading3`, `quote`, `code_block` | `body` (no run) | as today (R3, R10) |
| `list` | `bullet`, `numbered`, `check` | none | RD2; legal on `body` and `quote` paragraphs, refused on a heading or a code block |
| `indent` | `1` to `8` | `0` (no run) | RD3; the level, for list items and for plain paragraphs alike |
| `checked` | `true` | unchecked (no run) | RD2; legal only on a `check` paragraph |
| `start` | a positive integer | counted | RD2; on the first item of a numbered run, from a pasted list's start |
| `align` | `center`, `end`, `justify` | `start` (no run) | native on all five (the 2026-09-11 survey); no consumer asked, so it is in RD1 for the maintainer to keep or drop |

**Inline marks**, the R3 vocabulary plus one (RD4), each with the expand
rule RD7 makes part of its definition:

| name | value | grows at its end | grows at its start |
|---|---|---|---|
| `bold`, `italic`, `underline`, `strike` | flag | yes | no |
| `color` | `#RRGGBB`, sRGB, opaque | yes | no |
| `code` | flag | no | no |
| `link` | the URL | no | no |
| (later) `highlight` | a palette name (RD6) | yes | no |

**Automatic ink** is the absence of a `color` mark. There is no `auto`
value and no black that means automatic; a run that says `#000000` is
black in both appearances' terms (RD5 then decides how it is drawn).

**Numbering** is derived, never stored, by one function in the core that
all five arms read: a numbered item's number is one more than the previous
numbered item at the same level in the same unbroken run of list paragraphs,
or its `start`; a paragraph that is not a list item ends every run; an item
at a shallower level ends the deeper levels' counts. Markers per level, the
same on five platforms: bullets `•`, `◦`, `▪` and round again; numbers `1.`,
`a.`, `i.` and round again. A checklist item draws the platform's own
checkbox glyph state (checked or not), from the `checked` attribute.

**The extension point** (RD8): any mark or paragraph attribute name outside
kaya's vocabulary that carries an app's reverse-DNS prefix
(`com.example.comment`) is preserved verbatim by every kaya reader, writer,
merge and edit, and drawn as nothing. Names without a dot are kaya's alone.
A document may list in `requires` the extensions a reader must understand
to EDIT it; a reader that lacks one opens it read-only and says which name
it lacks (OOXML's `MustUnderstand`, made per document). Embedded objects
(images, tables) are reserved for a later slice: the shape is a paragraph
attribute `embed` with an id into a document-level `embeds` table, so an
embed is a paragraph of its own and the text never holds a placeholder
character (Automerge's `isEmbed` block marker, not Notes' U+FFFC).

What this model does not have, on purpose: fonts, sizes, line spacing,
superscript, tables, footnotes, comments, tracked changes, page setup. Each
is a later name under the same extension rules.

## §3. How it maps onto Automerge (RD10)

The mapping a collaborative app would use, so that the format never changes
when one does:

| kaya | Automerge |
|---|---|
| the text | the `Text` object; kaya's UTF-8 bytes are Automerge's `Utf8CodeUnit` (measured identity, rich-text plan §6) |
| a paragraph boundary `"\n"` | a block marker (`splitBlock`); the document's first paragraph is a marker at index 0 that has no `"\n"` in kaya's text, so the bridge adds one to every offset and turns each `"\n"` into a marker one for one |
| `block` | the marker's `type`: `paragraph`, `heading` with `attrs.level`, `code-block`; `quote` is `parents: ["blockquote"]` |
| `list` | `type` `unordered-list-item` or `ordered-list-item`; `check` is `unordered-list-item` with `attrs.__ext__kaya.check` |
| `indent` n | the list type repeated n times in `parents` (Automerge's own nesting); a plain paragraph's indent is `attrs.__ext__kaya.indent` |
| `checked`, `start`, `align` | `attrs.__ext__kaya.checked`, `attrs.__ext__kaya.start`, `attrs.__ext__kaya.align` |
| `bold`, `italic`, `link` | `strong`, `em`, `link` (as the JSON string Automerge's schema uses), so other Automerge rich text tools read them |
| `underline`, `strike`, `code`, `color` | `__ext__kaya.underline` and so on, each with the expand rule of §2's table |
| an app extension `com.example.x` | `__ext__com.example.x`, round-tripped as Automerge's schema requires |

Merge semantics this gives, each named because a user will meet it:
- Two people pressing Return in one paragraph at once get three paragraphs
  (two markers survive).
- Two people setting one paragraph's kind at once: one wins, per key, by
  Automerge's map rule, provided the bridge writes markers through the
  per-key path (`updateSpans`), never `updateBlock` (§1.1's trap).
- Two people colouring overlapping text differently: each character takes
  one of the two, the same choice on both machines (Peritext's exclusive
  value).
- One person bolds a word while another types inside it: the typing is bold
  (Peritext's intent preservation; the notes demo measured the same rule at
  a mark's edge, rich-text plan §16 and §17).
- Two people indenting the same item: the `parents` array is one value, so
  one indent wins rather than both adding up.

The notes demo (guests/rust/notes.rs) maps kaya's `block` runs to Automerge
marks today; RD10's mapping moves it to block markers, which is the demo's
own change and its scene's.

## §4. On disk (RD9)

The recommended container is a JSON text file, extension `.kdoc`, media
type `application/vnd.kaya.document+json`, holding the document as
paragraphs of spans:

```json
{
  "kaya": "document",
  "version": 1,
  "requires": [],
  "paragraphs": [
    { "block": "heading1", "spans": [["Notes on walking"]] },
    { "spans": [["A good walk has "], ["no plan", {"italic": true}],
                [" beyond the first turning."]] },
    { "list": "bullet", "spans": [["a map you can fold with one hand"]] },
    { "list": "bullet", "indent": 1,
      "spans": [["water, and "], ["more", {"color": "#C4554D"}],
                [" than you think"]] },
    { "list": "check", "checked": true, "spans": [["something to read"]] }
  ]
}
```

- SPANS, not offsets: each paragraph's text is the concatenation of its
  spans, each span a string with an optional object of marks, so the file
  carries no offset unit for another language to get wrong (JavaScript
  counts UTF-16, Python code points, kaya bytes). A mark across two
  paragraphs is two spans. Defaults are omitted, so a plain paragraph is
  `{"spans": [["text"]]}`.
- `version` is the format's MAJOR number. A reader refuses a higher major
  version in one sentence naming both numbers. Everything else grows by
  NAMES, not by version (Lexical's per-node version is the lesson: "Nothing
  reads it").
- Unknown keys at any level are preserved on a round trip (RD8), and an
  unknown name in `requires` opens the document read-only.
- The codec is in the core (RD13), so nine bindings write the same bytes.
- The app writes its own files. Where it holds a path (the desktops'
  picked files, and `app_data_dir()` on every platform, S4) it writes a
  temporary file and renames it over the old one itself; kaya adds nothing
  there. Through a picked file on a phone there is no path to rename into,
  and the safe save is kaya's (§4.1).
- A later collaborative app keeps its Automerge history BESIDE the file, in
  its own library (below), and a `.kdoc` stays the shareable snapshot. If a
  file must carry history, an optional `history` member holds an Automerge
  `save()` in base64 with the heads it matches, and a reader that edits the
  paragraphs without understanding it drops it (json-joy's sidecar shape).
  Carrying history in a file the user emails has a cost the plan names: every
  deleted word is still in it.

**Where SQLite fits.** The research (the four-way comparison in RD9's table)
puts SQLite at its best as an app's LIBRARY of many documents in the app's
own storage, which is what Apple Notes, Bear and Things do and what kaya's
DESIGN.md already rules for app data (`app_data_dir`, the task manager's
`tasks.sqlite` through rusqlite). A notes app over this format would keep
one row per note holding the `.kdoc` JSON (or its Automerge chunks: one
snapshot row and incremental rows, the automerge-repo storage pattern,
compacted in one transaction), a plain-text column for full-text search, and
attachments as blobs. As a USER-PICKED FILE, SQLite meets three walls the
research documents: its rollback journal is a sibling file, and a sandboxed
iOS app has no way to create one beside a document picked in Files
(https://developer.apple.com/forums/thread/729369), while Android's picker
hands kaya a `content://` URI with no sibling at all (kaya's own picker,
android/kaya/src/main/kotlin/dev/kaya/KayaPresent.kt); Apple's document
architecture is write-new-then-replace, which an in-place commit bypasses
(NSPersistentDocument gives up async saving and save-to,
https://developer.apple.com/documentation/appkit/nspersistentdocument); and
a few kilobytes of text costs an 8 to 30 KB file (measured, 4096-byte
pages). One more fact, which is not a criterion the maintainer set: a
sync client copying an open SQLite file can corrupt it (Anki: "can lead to
database corruption when files are synced while in use",
https://docs.ankiweb.net/files.html; SQLite's own
https://sqlite.org/howtocorrupt.html §1.2 and §1.4). Its strengths (atomic
incremental writes, attachments, `application_id` and `user_version` for
identity and migration,
https://sqlite.org/appfileformat.html) matter for a library and barely for
one document. rusqlite 0.40.2 with `bundled` is already built on all five
lanes for the task manager, phones included (docs/tasks-s4-plan.md §2 item
5), as a dev-dependency; libkaya links no SQLite, and the notes app would
not change that, since the app owns its library (the rich-text plan §5's
rule that no CRDT or store appears in kaya's API).

### §4.1 Safe save through a picked file (RULED 2026-11-11)

The maintainer, 2026-11-11: "i think your suggestions are fine as well as
the idea to look into the truncation bug". The suggestions were these: a
safe save through a picked file is kaya's job, because a guest holds only a
raw handle; on Android, back up, overwrite, verify, delete the backup, and
restore or offer a leftover backup at the next launch; on iOS, Apple's
coordinated safe save; on the desktops, the guest's own temporary file and
rename, with nothing from kaya. Nothing here is built; it waits for the rich
document rulings and its own slice. RD14 to RD16 hold what is still open.

**The problem, from zero.** A SAFE SAVE is a save that, if the app crashes
or the power goes halfway through, leaves either the old document or the new
one, never half of each. With a path it is easy: write the new bytes to a
temporary file beside the old one, flush it to the disk (`fsync`, the call
that returns only once the bytes are on the storage device), then RENAME it
over the old name. A rename within one directory is atomic: any reader sees
the old file or the new file. A picked file on a phone has no path to do
that with. On Android the picker answers a `content://` URI, a name that only
the providing app can resolve; kaya opens it with
`ContentResolver.openFileDescriptor` and hands the guest a descriptor, and
there is no directory to put a temporary file in and no rename (the
document API's `renameDocument` changes the display name only, and says
nothing about a name already taken). On iOS the picker answers a
security-scoped URL whose path is usable only while kaya holds the scope
(DESIGN.md, File dialogs, measurements 1 to 4), and `kaya_open_picked`
releases the scope before it returns. So the guest cannot do the rename, and
kaya must.

**The truncation finding (measured 2026-11-11, docs/traps.md).** Before any
of this: overwriting a longer document with a shorter one must not leave the
old tail. Every writable provider on the API 35 emulator honours `wt`
(ExternalStorageProvider, DownloadStorageProvider's `msf:` and `raw:` ids,
MediaDocumentsProvider) and none honours a bare `w`; `ftruncate` on the
returned descriptor works on all of them. Google Drive, the provider the
reports name, could not be measured (no account on the emulator). kaya now
truncates a seekable Write descriptor itself after the `wt` open, and
save.steps writes a save-back shorter than the draft it opened. iOS, GTK,
WinUI and the Mac open Write with `O_TRUNC` (or `TRUNCATE_EXISTING`) on a
real path, which the kernel honours, so they have no such gap.

**How it lowers.**

- **Android**, inside one blocking call:
  1. Take a persistable grant on the URI
     (`takePersistableUriPermission`), so a restore at the next launch does
     not depend on the picker's grant, which ends with the activity. kaya
     takes none today.
  2. Copy the current contents through an `r` open into the app's private
     storage (`<files dir>/kaya-safesave/<n>/old`), beside a small record:
     the URI, the display name, the old length and hash, and the NEW length
     and hash. `fsync` the copy, the record and their directory.
  3. Open the URI `wt`, truncate (the hardening above), write, `fsync`,
     close. A provider that answered a pipe cannot `fsync` (`EINVAL`); its
     close is its commit, and the record says the pipe was seen.
  4. Read the document back through a fresh `r` open and compare it with
     the new bytes (RD16 decides the comparison).
  5. Delete the backup and its record, `fsync` the directory, and release
     the persistable grant unless the app already held one.
  If step 3 or 4 fails inside the call, kaya writes the backup back over the
  document before returning the error, and keeps the backup if that write
  fails too.
- **iOS**: start the security scope; coordinate a write with
  `NSFileCoordinator.coordinate(writingItemAt:options: .forReplacing)`;
  inside it, write the bytes to a file in
  `FileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
  appropriateFor: url, create: true)` (a directory on the document's own
  volume), `fsync` it, and `FileManager.replaceItemAt(url, withItemAt:)`;
  stop the scope. This is what `UIDocument` does for its own saves, and the
  coordinator is how a File Provider (iCloud Drive, a third-party cloud)
  learns the item changed. What the slice must measure first: that
  `replaceItemAt` on a picked URL in On My iPhone and in iCloud Drive keeps
  the item's identity rather than reading to the provider as a delete and a
  create.
- **Mac, GTK, WinUI**: the picked file has a re-openable path
  (`local_path`), so the safe save is a temporary file in the same directory,
  `fsync`, and a rename over the name (`rename(2)`; on Windows
  `MoveFileExW` with `MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH`,
  or `ReplaceFileW`, which keeps the old file's attributes). A guest can do
  this itself; RD14 asks whether kaya's call covers the desktops anyway, so
  that a guest writes one save for every platform.

**What the guest sees.** One semantics in nine bindings (invariant 1): a
picked file gains a save that takes the whole new contents as bytes, blocks,
is safe from any thread (like `open`), and either returns success, after
which the document holds exactly those bytes, or fails, after which it
holds the old contents. On Android only, a failure kaya could not undo
leaves a backup that the next launch reports (below); that carve-out is
stated the same way in every binding, since a rename cannot leave one. The
spelling follows each language's existing `open`: `PickedFile::save(&self,
bytes: &[u8]) -> io::Result<()>` in Rust, an exception where the binding's
`open` raises one, an error value where it returns one. The C floor is one
call, `kaya_save_picked(handle, bytes, len)`, answering an errno like
`kaya_open_picked`. The sweep's verdict is do in Rust, Python, Go, C#, Java,
Swift, OCaml, Haskell and JS, and the C floor. A save-dialog destination is
a picked file too, so the same save writes a new document.

**After a crash: the next launch.** Only Android can leave a backup behind
(step 2 to step 5 span several calls, and a process can die between any
two). When the app next starts, kaya reads `kaya-safesave/` before the app's
first build and classifies each record by reading the document's current
length and hash:

- it holds the OLD bytes: the save never began to write; the backup is
  deleted, nothing is reported;
- it holds the NEW bytes: the save finished but for the cleanup; the backup
  is deleted, nothing is reported;
- it holds NEITHER: the write was torn, or another app changed the document
  since. kaya cannot tell those two apart, so overwriting silently could
  destroy another app's edit; RD15 decides what happens;
- the URI no longer opens (the document was deleted, or the grant was
  revoked): the backup is the only copy of the old contents; RD15 decides
  this too.

What the user or app is told depends on RD15. Whatever it decides, kaya
never deletes a backup it could not prove redundant without the app's
answer.

**The guards the slice needs** (invariant 3, each on a path a session walks
into):

- The core's state machine as a unit test with a fault-injecting source: a
  failure after each of the five steps, then the next launch's
  classification, every branch made to print (invariant 3's diagnostics
  rule: the sentence for "neither" must say kaya cannot tell a torn write
  from another app's edit, because it cannot).
- A scene on every lane: save long over short and short over long through
  the new call, and read the exact bytes back (save.steps' shape). On the
  desktops the directory listing `expect_file_dialog` reads shows no
  temporary file left behind.
- An Android second act: a fault knob kills the process between step 3 and
  step 5, the relaunch (the scene runner's second act) reads the report, and
  the restore reads the old bytes back.
- A code-shape gate over each arm: `fsync` before the rename or the backup
  delete, the iOS arm inside `coordinate(writingItemAt:options:
  .forReplacing)`, the Android arm's persistable grant taken before the copy.
- check-sugar-surface's row for the save in all nine bindings.

## §5. Colour (RD4, RD5, RD6)

**The value.** `color` is `#RRGGBB` in sRGB, opaque, the same sRGB the
colour picker kind commits (docs/color-picker-plan.md §2, `0xRRGGBBAA`); a
colour picked with alpha is refused at the format act naming the alpha,
since translucent text on a page has no reading anyone designs for.

**How the user picks one.** The editor's Format menu grows a Text Colour
submenu: Automatic, a row of presets (eight, chosen to pass contrast on both
pages under RD5's mapping), and Other…, which presents the platform's own
picker surface (NSColorPanel, UIColorPickerViewController, GtkColorDialog,
WinUI's ColorPicker flyout, kaya's Material sheet on Android) WITHOUT a
swatch, through a new present act beside the colour picker kind (its
surface, opened from a menu item the way the file pickers open from one).
Its answer becomes `tx.FormatColor(widget, color)`, a format act like Bold.
On the Mac, Format > Font > Show Colors reaching `changeColor:` on the text
view is caught by the arm and reported as the same act, so AppKit never
writes `.foregroundColor` behind kaya's run table; a native act is another
door to the same act, as WinUI's Ctrl+B is for Bold.

**The dark appearance** (RD5, recommended B). The stored colour is always
the colour as it appears on a LIGHT page. On a dark page the core draws a
MAPPED colour: in OKLCH (a perceptual colour space whose L is lightness and
whose hue does not drift as L moves), keep the hue, keep the chroma as far
as sRGB allows, and move the lightness so the colour's contrast against the
dark page equals its contrast against the light page, never below 4.5:1
(WCAG's text minimum, the clamp Y2 already computes in
crates/kaya/src/brand.rs's `contrast_ratio`). A colour that already reads on
both pages within a small tolerance is drawn unchanged, so most mid-tone
reds, greens and blues look identical in both. The lightness map is
monotonic, so it has an inverse: a colour picked while the page is dark is
stored as the light colour that maps to it, and the user sees what they
picked. One function in the core, called by every arm when it derives its
display (on Apple through a dynamic colour whose provider calls it, so an
appearance change redraws by itself; GTK on `notify::dark`; Compose when its
palette re-resolves; WinUI after `ActualThemeChanged`, where the arm must
re-apply its runs anyway because of #6908), so five platforms draw one
colour for one run.

**Highlight** (RD6, recommended later, named): a background colour is a
second slice, and when it comes it is a closed palette of names with
designed light and dark values (Notes' five, Notion's ten, Word's
`w:highlight`), because a free background under free text has no contrast
answer, and WinUI's single `BackgroundColor` is already shared between
find's highlight, a code run's ground and a quote's tint (rich-text plan
§18).

**Why this is not Y7.** Y7 (docs/styling-pass-plan.md) refuses a raw colour
on a LABEL because an app's chrome in a raw colour loses dark mode and the
contrast settings, which is the app skinning the platform. A colour inside
a rich document is the USER's content, the T3 tier's "a colour that IS the
content" (docs/tints-plan.md), and RD5's mapping gives it the dark answer a
token would. RD4 asks the maintainer to say so: Y7 stands for labels and
captions, and a document's `color` mark is the stated exception.

## §6. Lists (RD2, RD3)

**What the user does.** Format > List: Bulleted (primary+shift+8), Numbered (primary+shift+7) and Checklist
(primary+shift+9), Google Docs' chords; Format > Indent (primary+]) and Outdent
(primary+[), Notes' and Pages' chords; Tab and Shift+Tab in a list item
indent and outdent it (the platforms' editors agree; in a plain paragraph
Tab stays a tab character); Return in an empty list item ends the list (the
item becomes a body paragraph), as Notes, Word and Google Docs do; Return in
a non-empty item starts the next item at the same level (a paragraph
attribute that continues, R10's rule for quotes); Backspace at the start of
an item takes the list attribute off before it joins paragraphs. A click on
a checklist item's box toggles `checked`.

**How each platform draws the marker, holding R3** (nothing ever enters the
text):

| platform | the marker | the indent |
|---|---|---|
| macOS | NATIVE `NSTextList` where it draws on kaya's floor; DRAWN by `KayaRichFragment` (the TextKit 2 fragment that already paints the quote rule) where it does not, which the measurements say includes macOS 14 and 15 | the paragraph style's head indent |
| iOS | the same choice, measured on iOS 16 to 26 | the same |
| GTK | DRAWN in `snapshot_layer`, at each item's first line from `gtk_text_view_get_line_yrange` (the quote rule's route) | a `left-margin` paragraph tag per level |
| WinUI | DRAWN on an overlay in the control's template, with a real CheckBox for a checklist item (built 2026-11-11: TOM's native list paragraphs move no offsets, but its Bullet draws one glyph at every level and a custom bullet character counts up across items, so kaya's markers cannot be spelled natively; docs/measurements/richdoc-winui-2026-11-11.md) | a TOM paragraph indent per level |
| Compose | DRAWN in `drawBehind` from the field's `TextLayoutResult` (the quote rule's route) | a `TextIndent` paragraph style per level |

The marker formats are §2's on every platform, native or drawn. The
measurements before any arm: NSTextList inside kaya's own layout delegate in
a window on macOS 13, 14, 15 and 26 (FB15162186), the caret at an item's
start, and iOS; whether a TOM list paragraph moves RichEditBox offsets (the
way a TOM link's hidden field did, R3's amendment); and what a screen reader
says for a drawn marker on GTK and Compose, where AT-SPI and TalkBack see
none unless the arm exposes the item's position.

## §7. Exchange with other apps (RD12, RULED 2026-11-11 as amended)

- No Markdown import or export, and no DOCX: the `.kdoc` is the only file
  format. A plain text file made rich becomes body paragraphs as written
  (TextEdit's Make Rich Text interprets nothing). Either can be added later
  if a need appears; nothing in the format is in the way. §1.7 and §1.9 stay
  as research.
- IN THE FIRST BUILD: RTF (and HTML) on the CLIPBOARD, both ways. Copy writes RTF beside
  the plain text, with `\cf0` for automatic ink, a `\colortbl` for colours,
  `\listtable` plus `\listtext` for lists; paste reads RTF or HTML through
  one normaliser in the core that keeps only kaya's vocabulary (today every
  paste is plain by design, rich-text plan §7). This is what makes copying
  to and from Mail, Pages, Word and Notes work; each platform's clipboard
  flavour is its own measurement in §9's step 0. RTF as a FILE format is
  not proposed.

## §8. Writing Mode in the editor (RD11)

Today (docs/editor-plan.md E8, docs/design-rules.md): View > Writing Mode is
an app-wide preference; on, every tab wears the platform's text face a zoom
step up at a 480-point measure, and a Markdown file's marks are drawn
styled (`markdownRuns` in guests/go/editor/editor.go) while staying in the
text; saving writes the plain text.

Proposed (RD11, recommended B, TextEdit's model): a tab is either a PLAIN
document (a text file: the coding face, the gutter, the plain text saved) or
a RICH document (a `.kdoc`: the reading face and measure, real formatting,
lists and colours, saved as the document). Opening a `.kdoc` opens a rich
tab; opening anything else opens a plain one. Format > Make Rich Text turns
a plain tab rich (its text becomes body paragraphs as written), and its next Save asks for a `.kdoc`
name, since the file type changed; Format > Make Plain Text asks first when
formatting would be lost ("Converting this document to plain text will lose
its formatting", TextEdit's question). View > Writing Mode keeps its name as the look a rich tab wears, and the
app preference becomes "new documents are rich". The formatting acts (the
Format menu, the phone's keyboard bar) are enabled only on a rich tab. The
Markdown-drawn-styled rule of 2026-11-04 is superseded: in a rich tab there
are no Markdown marks to draw.

The scene, tools/scenes/editor.steps, grows a rich tab: make rich over the
walking journal (body paragraphs read with `expect_runs`), a list, an
indent, a colour from a preset, the numbering read, Return in an empty item,
save as `.kdoc`, close, reopen, and the runs and text read again byte for
byte on five lanes.

## §9. The build, depth then breadth

0. **Measure first** (half a day each, records under docs/measurements):
   the Apple list markers (§6) on macOS 13 to 26 and iOS; WinUI's colour
   survival across a theme switch and a list paragraph's offsets; GTK's
   drawn marker and its AT-SPI exposure; Compose's drawn marker; the
   colour mapping prototype in the core, its eight presets and twenty
   arbitrary colours rendered on both pages and VIEWED on a review page
   before anything ships.
1. **The root**, spec-first (invariant 7): the paragraph attribute names and
   their scope rule in spec.rs (the hash moves), the `color` mark and its
   value check, the expand table driving `typed_runs`, numbering, the
   colour mapping, the `.kdoc` codec and the clipboard's RTF and HTML
   writer and normaliser, with unit tests
   (a round trip of every attribute, an unknown name kept, a higher major
   version refused, a `requires` name opening read-only, RTF and HTML
   both ways); the Rust sugar and `Document`'s file pair.
2. **Depth on the Mac**: the NSTextView arm (lists, indent, colour through
   the dynamic provider, `changeColor:` caught), a `richdoc.steps` scene with
   a Rust guest, `expect_runs` over the new names, `expect_markers` (the
   markers the arm drew or the native list reports, read from the arm, since
   no marker is text), and the drawn colour read off the window's pixels in
   both appearances (`expect_ink`'s route).
3. **The editor on the Mac**: the Go sugar, Make Rich Text, the menus, the
   `.kdoc` save and open, copy and paste with formatting, editor.steps'
   rich tab.
4. **Breadth**: iOS, GTK, WinUI and Compose arms; the seven other bindings'
   sugar (the sweep's verdict is do in all nine, RD13); check-sugar-surface
   rows; check-verbs for both interpreters; the matrix.
5. **The review page** with captures of a rich tab on every lane, light and
   dark, each viewed before it is published.
6. Then, each its own slice: the
   highlight (RD6), the notes app over a SQLite library with Automerge
   behind it (RD9, RD10), and the safe save through a picked file (§4.1,
   RD14 to RD16).

Every guard this plan's build needs is named where it is built: the
corroboration wall (`expect_runs` fails when an arm's own runs disagree with
the core), a scene read of the drawn markers and the drawn ink, the codec's
negatives, and check-verbs' clauses for each arm's marker and colour paths.

## §11. The build as designed (2026-11-11)

What the build settled while implementing the rulings, so every arm and
binding follows one account. Code: crates/kaya/src/richdoc.rs (the model),
richdoc/kdoc.rs (the file), richdoc/clip.rs (RTF and HTML), the colour map in
crates/kaya/src/brand.rs, and the mirror in crates/kaya/src/scene.rs.

**The vocabulary on the wire.** `rich_attr` grows `list` 8, `indent` 9,
`checked` 10, `start` 11, `align` 12 and `color` 13; the spec enums
`list_kind` (`none`, `bullet`, `numbered`, `check`) and `paragraph_align`
(`start`, `center`, `end`, `justify`) give the values; the `command` enum
grows `text_color` 4. Every value has ONE spelling and the core answers it
(`richdoc::canonical_value`): `#c4554d` is stored `#C4554D`, and `body`,
`none`, `0` and `start` are the attribute's absence, never a run. A name with
a dot is an app's extension (RD8): carried through every edit and drawn as
nothing; it grows at neither edge.

**Paragraph attributes and the newline.** A paragraph is its text bytes plus
its terminator, the newline after it. Its attributes are read from its first
text byte; an EMPTY paragraph's from its terminator; the EMPTY FINAL
paragraph's from the newline before it (that newline is the final
paragraph's carrier, `richdoc::final_state`), or from the pending arm when the
text is empty. A non-empty paragraph's terminator carries nothing that
matters except as that carrier.

**Typing (RD7 and R10, generalized).** Inline marks come from the byte before
the insertion by each mark's expand rule: bold, italic, underline, strike and
color grow at their end; code, link and extensions never. Paragraph
attributes come from the paragraph the text lands in. From the inserted
text's first newline on, a Return at a paragraph's END carries what
CONTINUES (`richdoc::continuing`: a heading ends, `checked` and `start` do
not carry; a list, an indent, an alignment, a quote and a code block do), and
a Return inside a paragraph splits it with both halves keeping everything but
`start`.

**The core resolves paragraph acts.** `format_text` over the SELECTION for
`list`, `indent` (a level, or `+1`/`-1`), `checked`, `start` and `align` never
reaches the arm as a selection act: the core finds the selection's paragraphs
in its mirror, moves the mirror, sends the arm one RANGED act per change and
publishes `text_formatted` per change itself. A list replaces a heading or a
code block (one style per paragraph, as Notes keeps it) and drops a `checked`
or `start` its kind cannot carry; a heading or code block act reported by the
arm drops the list the same way. A ranged act (`format_range`) names a level,
never `+1`, and is refused when it breaks RD2's scope. `block` keeps its arm
path.

**Keys.** The arm offers Return, Backspace, Tab, Shift+Tab and a click on a
checklist box to the core before the platform acts
(`kaya_text_key(widget, key, start, end)`, the selection in bytes, read when
the key arrives); 1 means the core took it and the arm swallows the key.
Return in an EMPTY list item ends the list (list, checked, start and indent
off); Backspace at an item's first byte takes the list off; Tab and Shift+Tab
step the level when every selected paragraph is a list item (a plain
paragraph's Tab stays a tab character); the box click toggles `checked`.

**The repair after a user edit.** Every paragraph a user edit touched is made
uniform from its first byte, which is AppKit's own paragraph-style rule, so a
join takes the first paragraph's attributes. The repair reaches the arm as
ranged acts and the app as `text_formatted` after the `text_edited`. The
app's own `apply_edit` is its write and is not repaired.

**Ranged acts the core makes outside a transaction** (a key, the repair) wait
in `Scene::take_rich_ops`; the capi paths queue them for the pump, the Rust
backends apply them, after sending the edit's own occurrences.

**Markers.** One numbering in the core (`richdoc::markers`), read by every arm
through `kaya_text_markers` as `start:level marker|…` (start in bytes): a
numbered item counts from the previous numbered item at its level in the
same unbroken run of list paragraphs, or from its `start`; a non-list
paragraph ends every run; a shallower item ends the deeper counts. Bullets
`•`, `◦`, `▪` and numbers `1.`, `a.`, `i.` by level, round again; a checklist
item is `[ ]` or `[x]`, drawn as the platform's own box. `expect_markers`
reads the ARM's record of what it drew and fails, naming both, when it
disagrees with the core's.

**What a screen reader is told (RD18 B, built 2026-11-12).** One function in
the core (`richdoc::item_speech`) says what each list item tells beyond its
text: the marker (`bullet`, the number as drawn, `checked` or `not checked`),
its place among its siblings (the items of one kind at one level in one
unbroken run of list paragraphs: a deeper item does not part them, a
shallower one or another kind at their level does), and its level past the
first: `bullet, 1 of 2`, `2., 2 of 2`, `not checked, 2 of 2, level 2`. The
arms read the caret's item through `kaya_text_item_speech`. GTK publishes it
as the text view's accessible DESCRIPTION, set as the caret moves and the
markers change, unset outside a list item. Compose cannot put it on the field:
compose-ui 1.11.4's accessibility delegate REPLACES the state description of
any node with editable text by its own (`Empty`, or nothing), measured in its
bytecode, so the caret's item is a node of its own beside the text, a 1 dp
polite live region TalkBack speaks when it changes (`KayaRichItemLive`). And
the field's accessibility text is the real text (`editableText`), so the
U+200B the display draws at a paragraph style's boundary never reaches
TalkBack. The guard is `tools/scenes/richdocax.steps` (the richdoc guest) with
two verbs read off each platform's own tree: `expect_ax_item` (the caret's
item, `<none>` outside one) and `expect_ax_text` (the field's accessible
text), on GTK (x11 and wayland) and Compose.

**The Mac, iOS and WinUI (RD19 A, built 2026-11-12).** The core also answers
each item's place as numbers (`richdoc::item_places`: position, size and
level from 1). The Mac's text view puts AppKit's list item text attributes on
each item's first character in `accessibilityAttributedString(for:)`:
`AXListItemPrefix` the core's string, `AXListItemIndex` and
`AXListItemLevel` from 0, as NSAccessibilityConstants.h defines them
(measured: AppKit's own NSTextView publishes none of the three, even for an
NSTextList paragraph, in TextKit 1 or 2). An EMPTY item has no character to
carry them, so the view posts an announcement as the caret enters one, and
the read reports what it announced. iOS has no list item attribute: the
caret's item is the text view's accessibility hint (an app's own hint after
it), announced as it changes. WinUI names each drawn marker element with the
core's string and sets its PositionInSet, SizeOfSet and Level, so Narrator
meets "bullet, 2 of 3" where it met "•"; the read checks all four against the
core. `richdocax.steps` runs on the Mac, iOS, GTK and Compose; WinUI's field
text cannot be read in process (RD21), so the scene is parked there while
all nine of its item reads were measured green.

**Colour (RD5) as built.** `brand::ink_for_dark` maps a stored colour (as it
reads on the light reference page `#FFFFFF`) to the dark reference page
`#1E1E1E` at the same WCAG contrast it had, never below 4.5:1: Oklab
lightness moves, the hue stays, chroma is kept as far as sRGB allows.
`ink_from_dark` is its inverse for a colour picked while the page is dark:
a pick that reads at 4.5:1 there draws back within one unit per channel
(measured: `#A86AFF` stores `#8D4DE0` and draws `#A86BFF`), and the forward
map is many-to-one where the gamut clips chroma, so a light colour does not
come back exactly from the dark side. ONE CORRECTION TO §5: §5 also
said a colour that already reads on both pages within a small tolerance is
drawn unchanged. No colour can: 4.5:1 against both pages needs a relative
luminance at most 0.183 for the white page and at least 0.233 for the dark
one. So the floor wins and every colour moves; mid-tones move by a few
lightness points. The Format menu's eight presets (red `#DD1F24`, orange
`#BA5600`, brown `#976814`, green `#0D8501`, teal `#097E7E`, blue `#016FEF`,
purple `#8F4BE4`, pink `#D12387`; `richdoc::COLOR_PRESETS`) read at 4.6:1 to
4.9:1 on the white page and at the same on the dark one through the map.
Every arm draws `ink_for_dark` of the stored colour on a dark page, through
`kaya_ink_for_dark`.

**The file.** `richdoc::kdoc` writes §4's layout byte for byte (one paragraph
per line, paragraph keys in the order block, list, indent, checked, start,
align; marks in the order bold, italic, underline, strike, code, link, color,
then extensions by name) and reads it back into the canonical runs: a newline
between two paragraphs carries a paragraph attribute both hold, or the empty
final paragraph's; an inline mark the bytes on both sides hold. An
extension's value is its JSON (a string stays a string). The binding door is
the C pair `kaya_kdoc_read` and `kaya_kdoc_write` (values lists; the
document in a document field's encoding), and Rust's `Document::from_kdoc`
answers a `Kdoc { document, read_only }`.

**Unknown keys (RD17 A, built 2026-11-12).** A paragraph key this kaya does
not know, dotted or not (`com.example.pinned`, a newer kaya's `embed`), reads
as a run named `para:` plus the key (`richdoc::is_para_key`: the key is not
empty, not `spans` and not one of kaya's six paragraph attributes). The core
treats it as a paragraph attribute everywhere one is decided: it covers whole
paragraphs, a Return carries it (it is neither a heading nor `checked` nor
`start`), a join takes the first paragraph's, and every arm's own copy of the
typing rule (the Mac and iOS interpreter, Compose) names it with the same
predicate. The top level's unknown members ride one more field on every
binding's Document, `extra`: one JSON object's text, compact with sorted keys,
`""` when there are none; `history` is still dropped. The writer puts the
members back after `requires`, one per line, and refuses an `extra` that is
not an object or that names one of the file's own keys. The C pair carries it
first: `kaya_kdoc_read` answers refusal, read-only reason, extra, then the
document; `kaya_kdoc_write` takes extra, then the document (the same
signature, so the JNI and N-API doors did not move; the old input is refused
loudly). A kept value is its JSON, and a string whose text would itself read
as JSON (`"7"`, `"true"`) keeps its quotes in the run's value, so it goes back
out a string. A Document carries `extra` through the binding's own fold
(set_document seeds it; edits move text and runs only), so a document read
from a file, edited and read back with `document()` still holds it. The file
opens READ-ONLY only when it `requires` anything or a span carries an unknown
mark without a dot (RD8); both name what they lack. Guards: the core's
`unknown_paragraph_and_document_keys_survive_an_edit` and the kdoc tests,
richdoc.steps' tail in nine languages (open, Return, type, save, read back),
the sugar census row for `Document.extra`. Two faults the build found on the
way: Return at the end of an item that is NOT the last paragraph made a plain
paragraph (the new empty paragraph's carrier is the old terminator, outside
the inserted text; `Scene::carry_into_new_empty` now gives it what the
inserted newline carries), and typing into an empty paragraph left a newline
that broke §11's canonical form (the repair now always canonicalises).

**The clipboard (RD12 as amended).** Copy puts RTF and HTML beside the plain
text, written from the core's mirror (`kaya_text_copy`); paste reads RTF
first, then HTML, through one normaliser (`kaya_text_paste`), which arms the
runs for the edit the arm reports next and answers the plain text the arm
inserts as a paste. Explicit black and Apple's text colours read as
automatic ink; a link's own colour and underline are dropped; a quote and a
code block ride RTF as a `{\*\kayablock}` group other readers skip; a
heading is `\outlinelevel` (and its bold is the heading's, not a mark).
Measured on this Mac (macOS 26.6.2, textutil): Cocoa ends paragraphs with a
backslash-newline, writes lists through `\listtable` with `\listtext`, and
keeps a colour's sRGB in `{\*\expandedcolortbl}` (`\cssrgb`) beside a
calibrated `\colortbl` entry; the reader prefers the expanded entry. Cocoa
reads kaya's RTF back with its lists, nesting, colour and link
(richdoc/clip.rs holds both directions as unit tests).

**The text colour picker.** `pick_text_color` is the widget command
`text_color`: the arm presents its platform's picker over the selection, and
each colour the user commits is the widget's own `color` act, reported as
`text_formatted` like a Bold. A colour picked while the page is dark is stored
through `kaya_ink_from_dark`. On the Mac the picker is NSColorPanel and
`changeColor:` on the text view is that act, so AppKit never writes
`.foregroundColor` behind the run table.

## §10. The rulings

Each is the maintainer's. The mechanism of each was explained in §0 to §8;
the short version is repeated so a ruling reads on its own.

### RD1. The document stays flat: one text, inline marks, attributes per paragraph

The question: keep kaya's flat model (a string plus runs, paragraph
attributes as runs that cover whole paragraphs) and grow it with `list`,
`indent`, `checked`, `start` and `align`, or move to a tree of nodes (a list
node holding items holding paragraphs).

- A. Flat, with the five new paragraph attributes. (Notes, Word's
  paragraphs, RTF, Quill, Portable Text, Automerge.)
- A'. Flat, without `align` (no app has asked for it).
- B. A tree.

RECOMMEND A. The wire, the core's mirror, nine bindings' `Document` and the
corroboration wall are already flat; a list item as a paragraph with a level
is how Notes and Word store one; Automerge chose flat because trees merge
badly. `align` costs one name, is native on all five, and a rich document
without centring reads as unfinished.

### RD2. Lists: flat items with a level, numbers derived, checklists included

- A. Bulleted, numbered and checklist items, each a paragraph with `list`
  and an `indent` level; numbers counted by the core from neighbours, with
  an optional `start` on the first item; marker formats fixed per level on
  every platform (•, ◦, ▪; 1., a., i.).
- B. As A without checklists.
- C. As A plus a list identity (Word's `numId`), so two adjacent numbered
  lists number separately and a list resumes after an interrupting
  paragraph.

RECOMMEND A. Notes, Google Docs and Notion all have checklists, and a notes
app without one would be asked for it first. C's identity is what Word needs
for legal documents and is an extension name away when an app needs it; no
consumer does.

### RD3. Indentation is a level, shared by lists and plain paragraphs

- A. `indent` 0 to 8, a level; each platform draws one level as its own
  list indent step; Indent and Outdent in the Format menu, Tab and Shift+Tab
  in a list item.
- B. An indent in points (Word's twips, RTF's `\li`).

RECOMMEND A. A level means the same on five platforms whose list indents
differ, merges as one small number, and is what Notes (`indent_amount`) and
Quill (`indent`) store. Points would make kaya choose a number for each
platform's look.

### RD4. A user-chosen colour on document text, the stated exception to Y7

The question: allow a free colour on text inside a rich document. Y7
refuses a raw colour on text because chrome in a raw colour loses dark mode
and contrast; a colour the user puts in their document is their content.

- A. A `color` mark, `#RRGGBB` sRGB, opaque; automatic ink is no mark;
  picked from presets or from the platform's own picker surface through a
  new present act, and the Mac's Show Colors caught as the same format act.
  Y7 stands for labels and captions; this is the exception, stated in Y7.
- B. A closed palette of names only (Notion's model).
- C. No colour.

RECOMMEND A, with RD5's mapping. It is what the maintainer asked for ("free
color picker if that can be lowered to each platform"), every platform's
rich text control carries a run colour, and every platform has a picker
kaya already presents (Android through kaya's own sheet).

### RD5. What a dark page does to a colour the user chose

- A. Keep it exactly (Notes). Dark blue on a black page is unreadable, and
  white chosen on a dark page vanishes on a light one.
- B. Map it in the core: keep hue and chroma, move OKLCH lightness so the
  contrast against the dark page equals the contrast it had on the light
  page, never below 4.5:1, colours that already read on both unchanged;
  stored as the light colour, invertible so a colour picked in the dark is
  what the user sees.
- C. Invert brightness (TextEdit, AppKit's adaptive mapping). Apple's own
  header says it is lossy and "may not be suitable for rich text
  authoring".
- D. Keep the page light in the dark appearance (Pages, Word's "Never
  change the document page color").

RECOMMEND B. It is Word's and Google Docs' answer with the algorithm
written down: the colour keeps its identity (a red stays that red's hue),
every run stays readable on both pages, and one function in the core keeps
five platforms drawing the same colour. D stays possible later as a View
option, as Word and Notes offer it.

### RD6. Highlight (a background colour) waits, and comes as named colours

- A. Later, as a closed palette of names with designed light and dark
  values (Notes' five; Word's `w:highlight` is a palette for the same
  reason).
- B. Now, as a free colour.
- C. Now, as named colours.

RECOMMEND A. A free background under free text has no contrast answer; WinUI
has one background slot already shared three ways (find, code, quote); and
nothing in the ask names it.

### RD7. Each mark's expand rule is part of kaya's vocabulary

The question: today the core's typed text inherits attributes by one rule
(R10, and §12's positional pending rule), and the rich-text plan left the expand rule "the CRDT's
and the app's". With a document format, the rule belongs to the mark.

- A. §2's table: bold, italic, underline, strike and colour grow at their
  end; code and link grow at neither; the core's `typed_runs` follows the
  table, and the Automerge mapping passes the same rule on every mark.
- B. Leave it to the app per edit, as today.

RECOMMEND A. A user typing after a link should not extend the link on one
platform and not another, and the CRDT must be told one rule per mark or two
machines disagree about the same keystroke. A is Peritext's own table, and
Automerge's and ProseMirror's defaults.

### RD8. Unknown names are kept, and a document can say what it needs

- A. Every reader keeps unknown marks, paragraph attributes and keys
  verbatim and draws nothing for them; app names carry a reverse-DNS prefix;
  `requires` lists extensions needed to EDIT, and a reader without one opens
  the document read-only and names what it lacks; one major `version`,
  refused when higher.
- B. Refuse unknown content (ProseMirror, Lexical).
- C. Drop unknown content silently (Quill).

RECOMMEND A. It is OOXML's three verdicts made simple and Automerge's own
schema rule ("MUST be round-tripped"); an app that adds comments can share
files with one that does not, and nothing a newer kaya writes is destroyed
by an older one.

### RD9. The container: a JSON file now, SQLite for an app's library later

RULED A, 2026-11-11 ("i think your suggestions are fine"), with two
corrections the maintainer made the same day: sync folders are not a
criterion he set, so they left the weighing; and kaya provides no save for
ordinary paths, since the guest writes its own files (`app_data_dir()`, S4)
and `kaya_open_picked` already exists. The picked-file safe save is §4.1.

The maintainer's "repurposed sqlite" thought, weighed:

| | A. JSON `.kdoc` | B. Automerge binary | C. SQLite file | D. a zip package |
|---|---|---|---|---|
| atomic save | the app's temporary file and rename; on a picked file on a phone, kaya's safe save (§4.1) | the same | a transaction, in place | the same as A |
| incremental writes | rewrite (documents are small) | append a chunk | native | rewrite |
| a few KB of text costs | the text and some keys | about 30% over the text, with all history | 8 to 30 KB (measured) | the zip's overhead |
| history | none (it lives in the app's library) | all of it, deleted text included | as the app stores it | as stored |
| user-picked files on iOS and Android | fine | fine | its journal has no sibling to live in | fine |
| other tools can open it | any text editor, any language | Automerge only (no OCaml, Haskell or full Go binding) | sqlite3, but the text is a blob | unzip, then JSON |
| attachments | later, as a package | inside | a table | natural |
| identity and migration | `version` and `requires` | Automerge's chunk magic plus kaya's keys | `application_id`, `user_version` | a manifest |

- A. A JSON `.kdoc` for documents the user opens and saves; and when a
  notes app comes, its LIBRARY is SQLite in the app's storage (one row per
  note, Automerge's snapshot and incremental chunks, full-text search,
  attachments), the Apple Notes and automerge-repo shape.
- B. The file is an Automerge document.
- C. The file is a SQLite database.
- D. A zip of JSON and media (Sketch's move away from SQLite, DOCX's shape).

RECOMMEND A. SQLite is the right store exactly where the research found it
used well, an app's library; as a picked file it breaks on both phones'
pickers. Automerge-as-the-file puts every deleted word
in every emailed file and makes the format unreadable without one library.
D becomes the answer the day documents carry images; A's `embeds` table
(§2) is shaped so the move is additive.

### RD10. The CRDT mapping uses Automerge's block markers

- A. Paragraphs are Automerge block markers, kaya's attributes their `type`,
  `parents` and `attrs` (§3's table), written through the per-key path.
- B. Paragraph attributes stay marks over the paragraph inside the CRDT (the
  notes demo's mapping today).

RECOMMEND A. Block markers are Automerge's own answer to Peritext's open
problem; with B, a paragraph joined to the next under concurrency leaves its
kind half covering the result, and other Automerge rich text tools would not
read kaya's paragraphs. The notes demo moves to A in its next slice.

### RD11. Writing Mode becomes the rich document (TextEdit's model)

- A. Writing Mode stays a view over any file; a `.md` file is shown with
  real formatting and saved back as Markdown, dropping what Markdown cannot
  carry (colour, underline, alignment).
- B. A tab is plain or rich by its file: a `.kdoc` opens rich, other files
  plain; Make Rich Text and Make Plain Text convert (a Markdown file's marks
  imported; plain asking before it loses formatting); Writing Mode is the
  look a rich tab wears; the preference becomes "new documents are rich".
- C. A separate rich document app beside the code editor.

RECOMMEND B. It is the maintainer's "B for the file", and TextEdit's
long-standing answer to the same two kinds of document; A would let a user
colour a word and lose it on save without being told. C splits the forcing
artifact the editor already is. B supersedes design-rules' "Writing Mode's
Markdown drawn styled" of 2026-11-04.

### RD12. RULED 2026-11-11 as amended: no Markdown, no DOCX; the clipboard's RTF and HTML in the first build

As asked:

- A. Markdown import and export now (pulldown-cmark, in the core); RTF and
  HTML on the clipboard as the next slice; DOCX export later, DOCX import
  after it.
- B. Markdown only.
- C. Markdown and DOCX now.

RECOMMEND A. Markdown is what the editor opens today and Make Rich Text
needs it; the clipboard is where users meet other apps' rich text every day
(Mail, Pages, Word, Notes all paste RTF), and it is cheaper than DOCX, whose
reader is the hardest piece in this survey.

RULED 2026-11-11, amended: the maintainer asked "why do we even have markdown
import and export?" (Markdown was a leftover of Writing Mode's 2026-11-04
design, where `.md` files were the documents) and, of DOCX, "i feel like
that's out of scope for our rich text editor". So no Markdown and no DOCX;
copy and paste with formatting, through RTF and HTML on the clipboard, is in
the first build, since a rich document whose copy drops its formatting reads
as broken. Word still takes kaya's formatting through a paste.

### RD13. The codec lives in the core, and all nine bindings reach it

- A. The `.kdoc` codec and the clipboard's RTF and HTML codec are Rust in the core behind one C pair,
  and each binding's `Document` gains a file pair spelled in its idiom
  (`Document::from_kdoc(bytes)` / `to_kdoc()` in Rust; the others on the
  review page before they ship), so nine languages write identical bytes.
  The sweep: do in Rust, Python, Go, C#, Java, Swift, OCaml, Haskell and JS,
  and the C floor.
- B. Each binding writes JSON itself.

RECOMMEND A. Invariant 1: one observable semantics. Nine hand-written JSON
writers would disagree about key order, number formats and unknown keys
within a month; one codec with nine thin doors cannot.

### RD14. Whether the picked file's save covers the desktops too

§4.1's mechanism, short: on a phone kaya must do the safe save, since the
guest has no path. On the Mac, GTK and WinUI the picked file has a path, and
the ruling of 2026-11-11 says the guest's own temporary file and rename is
enough there. The question is the guest's code, not the mechanism: a guest
that saves the same document on every platform either calls one save, or
asks whether `local_path` is empty and writes two saves.

- A. One call on every platform. On the desktops kaya's arm is the temporary
  file and rename the guest would have written (about twenty lines over
  `std::fs`, `MoveFileExW` on Windows); a guest may still do its own.
- B. The call exists only where there is no path (iOS, Android); a desktop
  guest does its own rename, and the call refuses there in one sentence
  naming `local_path`.

RECOMMEND A. Invariant 1 asks for one observable semantics, and B makes
every portable guest branch on the platform to save a file. A adds no
mechanism the ruling refused: kaya does not provide a save for ordinary
paths, only for the handle its own picker answered.

### RD15. What happens to a backup the next launch cannot prove redundant

§4.1's mechanism, short: on Android only, a crash between the overwrite and
the cleanup leaves a copy of the old contents in the app's private storage.
At the next launch kaya deletes it silently when the document holds exactly
the old bytes or exactly the new ones. Two cases remain: the document holds
neither (a torn write, or another app edited it since, which kaya cannot
tell apart), or the document no longer opens.

- A. Silent: kaya writes the backup back over the document, then deletes
  it. (A torn write is repaired; another app's edit is lost without a word.)
- B. Tell the app: kaya delivers one occurrence per leftover backup before
  the app's first build is shown, carrying the document's name, a readable
  handle on the backup, a handle on the document when it still opens, and
  what kaya measured ("holds neither the old nor the new contents"). The app
  answers restore or discard, or asks its user in its own words; a backup
  nobody answered stays for the next launch.
- C. kaya asks the user itself with a system alert ("<name> was not saved
  completely. Restore the last saved version?").

RECOMMEND B. Only the app knows whether its user should be asked, and A
destroys another app's edit in exactly the case kaya cannot detect. C puts
kaya's words in every app's mouth. Under B the occurrence never fires on
iOS or the desktops, since a rename cannot leave a backup, and every
binding says so the same way.

### RD16. How the Android save checks what it wrote

§4.1's mechanism, short: after the overwrite, kaya reads the document back
through a fresh open before it deletes the backup.

- A. Length and a hash (SHA-256) of the bytes read back against those of
  the bytes written.
- B. Length only.

RECOMMEND A. Documents are small, the read is needed for the length anyway,
and a length check passes a provider that wrote the right number of wrong
bytes. The hash is kaya's own and never leaves the device.

### RD17. How a reader keeps unknown paragraph and document keys through an edit (RULED 2026-11-12: A)

RULED A as recommended (the maintainer, 2026-11-12: "i agree with your
recommendations"). BUILT 2026-11-12 (§11, Unknown keys).

The mechanism, short: RD8 says every kaya reader keeps names it does not
know. An unknown MARK with an app's dotted name is easy: it is a run like any
other, the widget carries it through every edit, and the `.kdoc` writes it
back (built, §11). Two other places a file can carry a name have no home in
kaya's run model: a key on a PARAGRAPH (`{"com.example.pinned": true,
"spans": …}`, or a newer kaya's paragraph key), and a key at the DOCUMENT's
top level (a newer kaya's `embeds` table, an app's own settings). A run
cannot say "this belongs to the paragraph", because a mark that happens to
cover a whole paragraph looks the same, and the Document every binding holds
is only text and runs. The first build opens such a file READ-ONLY with a
sentence naming each key, so nothing is lost and nothing is silently kept
wrong.

- A. Paragraph keys become runs under a reserved prefix, `para:` before the
  key (`para:com.example.pinned`), which the core treats as a paragraph
  attribute (whole paragraphs, continuing across Return); document keys ride
  one more field on every binding's Document, `extra`, the unknown top-level
  members as JSON text the writer puts back.
- B. Every binding's Document grows a per-paragraph side table and a
  document table, kept in step through edits by the binding's fold.
- C. Keep the interim: such a file opens read-only.

RECOMMEND A. It keeps the Document's shape (text and runs, plus one string)
in nine bindings, it reuses the paragraph machinery the core already has, and
the prefix makes the run's scope its spelling, so a mark that covers a whole
paragraph and a paragraph key never collide. B is nine folds of a second
structure; C makes a newer kaya's file uneditable in an older one, which RD8
ruled against.

### RD18. What a screen reader hears of a drawn list marker (RULED 2026-11-12: B)

RULED B as recommended (the maintainer, 2026-11-12: "i agree with your
recommendations"). BUILT 2026-11-12 on GTK and Compose (§11, What a screen
reader is told); the Mac, iOS and WinUI are RD19.

The mechanism, short: R3 rules that no marker is ever in the text, so the
platforms that have no editable list (GTK and Compose) DRAW the "•", "2." or
checkbox beside the item, and the Mac and iOS draw it too (§11). A screen
reader reads the text and the attributes the control exposes, not the
pixels. Measured on the build: GTK's AT-SPI exposes nothing of a drawn
marker (no list kind, number or checked state), and neither does Compose to
TalkBack. Compose adds a second cost: foundation 1.11.4 draws an empty line
wherever a paragraph style starts or ends at a newline, which made every
list item double-spaced, so the arm draws that newline as a zero-width space
(U+200B, the same length, so offsets do not move); TalkBack then reads every
word and line but loses the paragraph breaks between styled paragraphs. Two
other repairs were measured and failed (a tiny font on the newline did not
shrink the line).

- A. Expose each list item's position through the accessibility tree the
  platform offers beside the text: an accessible description per item on
  GTK ("bullet", "2 of 3", "checked") and a custom accessibility action or
  state on Compose, from the core's markers; keep the U+200B repair.
- B. As A, and replace the U+200B repair with an accessibility-only text
  that keeps the newlines (Compose's semantics override), so TalkBack hears
  the breaks while the drawn text stays single-spaced.
- C. Leave both as built and record the gap.

RECOMMEND B. A list a sighted user sees as a numbered checklist should not
reach a TalkBack or Orca user as run-on text with no numbers or states; both
halves read kaya's own model, so no platform guesswork is involved. It is a
slice of its own, after this build.

### RD19. What VoiceOver and Narrator are told of a drawn list marker (RULED 2026-11-12: A)

RULED A as recommended (the maintainer, 2026-11-12: "i agree with your
recommendations"). BUILT 2026-11-12 (§11, The Mac, iOS and WinUI); WinUI's
text read is RD21.

The mechanism, short: RD18 put what a list item tells beyond its text
(`bullet, 2 of 3`, `checked, 1 of 2`) on GTK, as the text view's accessible
description, and on Compose, as a polite live region beside the field, both
read off the core's one numbering for the item holding the caret. The Mac,
iOS and WinUI draw their markers too (§11), and RD18 ruled only GTK and
Compose. What their screen readers are told today, read with the same verbs
(`expect_ax_item`, `expect_ax_text`) through each platform's own tree:

- The Mac (VoiceOver): the text view's accessible value is the real text,
  newlines and all, and the caret's paragraph carries no list item attribute
  (no AXListItemPrefix, index or level): VoiceOver reads "Apples" where a
  sighted user sees "• Apples", and a checklist item's state not at all.
- iOS (VoiceOver): the same: the text view's accessibility value is the real
  text, and nothing beside it names the caret's item (its hint is empty and
  the drawn markers are no accessibility element).
- WinUI (Narrator): the field's own peer tells nothing (no help text, full
  description or item status), and each drawn marker is a SEPARATE element of
  the tree beside the field: a bullet is a text element named "•" or "◦", a
  number one named "2.", a checklist box a checkbox whose state is checked or
  unchecked. Narrator meets them as loose elements in the window, with no
  position and no tie to the item's text. The field's accessible text could
  not be read in process (WinUI's in-process peer for a RichEditBox publishes
  no Text pattern, and an out-of-process UIA client is barred).

- A. The same account on all five. The Mac puts the core's string on the
  item's first character as the list item attributes AppKit's accessibility
  reads before a line (AXListItemPrefix, with index and level), iOS gives it
  to VoiceOver as the text view's accessibility value's custom attribute or a
  live announcement as the caret moves, and WinUI names each marker element
  with it (AutomationProperties.Name, PositionInSet, SizeOfSet, Level), so
  Narrator hears "bullet, 2 of 3" where it now hears "•". richdocax.steps
  then runs on every lane.
- B. Leave the three as built and record the gap.

RECOMMEND A. Invariant 1 (one observable semantics), and on WinUI the
elements already exist and only lack their names.

### RD20. Whether a Document kept in a model field keeps its extra (RULED 2026-11-12: B)

RULED B as recommended (the maintainer, 2026-11-12: "i agree with your
recommendations"). BUILT 2026-11-12: `spec::DOCUMENT_FIELD` fingerprints the
field's layout (extra, text, then four values per run; the spec hash moved),
and it is also the `.kdoc` pair's document, so `kaya_kdoc_write` takes a
document field's bytes as they are. The core and nine bindings pack and read
it; the interpreters read no document field (the core turns it into
`set_rich_text`), so "both interpreters' row decoders" below had nothing to
change. The C floor packs the bytes itself and kaya.h names the layout.
Measured on the way: OCaml keeps rows encoded and its row fold decoded and
re-encoded the field, so a copy's edit dropped `extra` there too. Guards: the
frozen reference bytes in nine bindings' checks, and richrows.steps' "save b"
(a row patched from a file with an unknown member, restored by a redo, saved
and read back) in nine languages.

The mechanism, short: RD17 put a file's unknown top-level members on every
binding's Document as `extra`, and the binding's own fold keeps it while the
document sits in a rich textarea. A Document can also live in an app's MODEL,
as a document field of a row (docs/rich-text-plan.md §19, the rich rows). That
field's wire encoding is the text and the runs only, so a Document that goes
into a row and comes back has lost its `extra`, and an app that saves it with
`to_kdoc` writes the file without the members it read. Nothing refuses it.

- A. Leave it: a model field holds what a widget holds, text and runs; an app
  that keeps a file's unknown top level keeps the Document `from_kdoc` gave it.
- B. The document field's encoding grows `extra` (a spec change: the field's
  codec in the core and nine bindings, and both interpreters' row decoders),
  so a Document round-trips through a row whole.
- C. As A, and the field codec refuses a Document whose `extra` is not empty,
  naming the field, so the loss is never silent.

RECOMMEND B. RD8's promise is that nothing a newer kaya writes is destroyed by
an older one, and a notes app that keeps its documents in rows is the first
consumer the rich document was built for. C is the cheap honest floor if B
waits.

### RD21. What WinUI's screen-reader scene reads of the field's text (RULED 2026-11-12: A)

RULED A (the maintainer, 2026-11-12: "A, but ledger C as an option, cause i
didn't realize we stopped using the accessibility reader on windows"). C is
kept on docs/deferred.md as an option, not a plan.

The mechanism, short: `richdocax.steps` reads the field's accessible text
(`expect_ax_text`) because Compose once drew a U+200B where a newline was, and
TalkBack read what was drawn (RD18). On WinUI the text Narrator reads comes
from the RichEdit control's own UI Automation provider, which lives in the
native control, not in the XAML tree. Measured 2026-11-12: the field's
in-process peer answers `GetPattern(Text)` with null, and the one other way to
read it, a UI Automation client, is barred in kaya's Cargo.toml (a client
crashed a guest reading the Shell's file dialog, docs/traps.md). kaya does
not change the field's text on WinUI (no repair like Compose's), and every
item read of the scene passed there.

- A. The WinUI lane cuts `expect_ax_text` from the scene and says why in one
  sentence, the carve-out stated as invariant 1 asks; the item reads run.
- B. WinUI's read answers the TOM story through `Editable::text`, stated as
  the text the RichEdit provider serves (an inference, not a reading of the
  provider).
- C. Lift the Cargo wall for an in-process UI Automation read of the app's
  own window only.

RECOMMEND A. It reports what can be measured and nothing else; B would print
a sentence nobody measured, and C reopens a wall built after a crash.
