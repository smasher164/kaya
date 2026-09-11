# Rich text editing — what the five platforms actually give us

Research report for the rich-text milestone. Repo HEAD at time of
writing: `main` @ 7a58125 (working tree clean). **No repo file edited.**

Every claim below is either QUOTED from a vendor document (URL given),
QUOTED from a kaya file (file:line given), or marked **[INFERENCE]**.
Nothing is stated from memory without a citation.

**The units this report speaks.** kaya has already ruled the offset
unit, and this survey uses it throughout:

> A range is a pair of UTF-8 byte offsets into the widget's current
> guest-visible text. Both endpoints must fall on a code-point
> boundary and inside the text; kaya refuses a range that does not…
> An endpoint may fall inside a grapheme cluster
> (`docs/ranges-units.md:51-57`, §VERDICT).

The core validates at one chokepoint and converts to each backend's
native unit before lowering, so no interpreter ever sees a byte offset
(`docs/ranges-units.md:19-37`, §VERDICT.1-2; §7 "WHERE"). The native
units are already measured:

| backend | native offset unit | source |
| --- | --- | --- |
| mac (NSTextView) | UTF-16 code units (`NSRange`) | `docs/ranges-units.md:131-133` |
| ios (UITextView) | UTF-16 code units | `docs/ranges-units.md:186-192` |
| linux (GtkTextView) | **code points**, + a CRLF correction | `docs/ranges-units.md:203-208`, `:240-248` |
| windows (RichEditBox/TOM) | UTF-16 code units ("cp") | `docs/ranges-units.md:252-262` |
| android (Compose) | UTF-16 code units | `docs/ranges-units.md:290-292` |

The controls kaya already owns, from the textarea foundation
(`docs/textarea-foundation-plan.md`, LANDED `4f40e59`): NSTextView via
NSViewRepresentable (`swift/KayaSwiftUI.swift:18920` `KayaMacTextarea`),
UITextView via UIViewRepresentable (`:19163`), GtkTextView in a
GtkScrolledWindow, RichEditBox **in plain-text mode**
(`crates/kaya/src/winui/mod.rs:9443` `fn pin_plain_text`), and Compose
`BasicTextField(state:)` with `TextFieldState`
(`android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt:11986`). That
plan's rule was **"Rich-capable CONTROL, plain-text CONTRACT"**
(`:16`) — this milestone spends that option.

---

## 1. macOS — NSTextView / TextKit, and SwiftUI's new attributed TextEditor

### 1a. The model: NSAttributedString over NSTextStorage

`NSTextStorage` is *"the fundamental storage mechanism of TextKit that
contains the text managed by the system"* and is *"a semi-concrete
subclass of NSMutableAttributedString that adds behavior for managing a
set of client NSLayoutManager objects. A text storage object notifies
its layout managers of changes to its characters or attributes"*
(https://developer.apple.com/documentation/uikit/nstextstorage).

So the mac model is exactly **string + attribute runs**, addressed by
`NSRange` in UTF-16 code units. That is the shape kaya's wire wants
(§7 below), one unit conversion away from the ruled byte offsets.

### 1b. SwiftUI gained real attributed editing in macOS 26 / iOS 26

`TextEditor` has a second initializer:

```swift
nonisolated init(text: Binding<AttributedString>,
                 selection: Binding<AttributedTextSelection>? = nil)
```

availability **iOS 26.0, iPadOS 26.0, Mac Catalyst 26.0, macOS 26.0,
visionOS 26.0**
(https://developer.apple.com/documentation/swiftui/texteditor/init(text:selection:)).

Two facts from its discussion matter to kaya. *"Other than `Text`, this
editor does not automatically translate UIKit or AppKit formatting
attributes into SwiftUI attributes. For importing RTF documents… use
`AttributedTextFormatting.Transferable`"* — the SwiftUI and AppKit
attribute scopes are **different vocabularies**, needing a bridge both
ways. And *"When binding the `selection`, always make sure it is
updated after you mutate the `text`. Otherwise, the editor resets the
selection to the end of the `text`."* — an app-owned-document design
(kaya's, and a CRDT's) must write text and selection together or lose
the caret.

`AttributedTextSelection` (iOS/macOS/tvOS/watchOS/visionOS **26.0+**,
https://developer.apple.com/documentation/swiftui/attributedtextselection)
is *"either an insertion point… or spans over a range of characters.
While that range is always visually contiguous, it may not be logically
contiguous in the text storage. Specifically, a single selection value
cannot represent multiple cursors."* Its members are the toolbar-state
answer for §4: `attributes(in:)` returns *"a lazy sequence of all
attribute values the selection has in a given text"*, and
`typingAttributes(in:) -> AttributeContainer`.

Apple's own bold-toggle sample on that page is the "is the selection
bold?" pattern: the getter is
`selection.typingAttributes(in: text).font`, resolved against
`\.fontResolutionContext` and asked `.isBold`; the setter is
`text.transformAttributes(in: &selection) { $0.font = ($0.font ?? .default).bold(isBold) }`.

`AttributedTextFormattingDefinition` (iOS/macOS **26.0+**,
https://developer.apple.com/documentation/swiftui/attributedtextformattingdefinition)
**closes the attribute vocabulary** — *"A formatting definition
consists of an attribute scope and a number of value constraints. It is
applied to a view hierarchy using the
`attributedTextFormattingDefinition(_:)` view modifier and affects
nested `Text` and `TextEditor` views when initialized with
`AttributedString`."* Attributes outside the scope *"are ignored"*, and
*"SwiftUI validates system formatting UI to ensure only compatible
controls are visible and enabled"*, so declaring kaya's vocabulary also
removes the system formatting controls kaya cannot honour. Constraints
are written `ValueConstraint(for: \.underlineStyle, values: [nil, .single], default: .single)`.

**[INFERENCE]** A very good fit for kaya's doctrine: the foundation plan
pinned rich opinions OFF one negative test at a time
(`docs/textarea-foundation-plan.md:20-24`), and a formatting definition
turns N pins into one declared scope. **But it is macOS 26 / iOS 26
only**, and kaya's iOS floor is iOS 16 (that plan's ios row: *"same
control the range probe proved affordable at the iOS 16 floor"*). On
the floor the attributed editor does not exist.

### 1c. The AppKit/Foundation vocabulary underneath (the iOS-16-floor path)

`NSAttributedString.Key`
(https://developer.apple.com/documentation/foundation/nsattributedstring/key)
has every inline attribute the milestone asks for: `font`
(bold/italic/monospace live in the font descriptor, not in separate
keys), `foregroundColor`, `backgroundColor`, `underlineStyle` +
`underlineColor`, `strikethroughStyle` + `strikethroughColor`, `link`
(*"The link for the text"*), `paragraphStyle`, plus `baselineOffset`,
`kern`, `shadow`, `attachment`.

Block structure is `NSParagraphStyle`, and **lists exist natively**:
`NSTextList` (iOS 7.0+ — *"A section of text that forms a single
list"*), whose overview says *"Text lists appear as attributes on
paragraphs, as part of the paragraph style. An `NSParagraphStyle` may
have an array of text lists, representing the nested lists containing
the paragraph, in order from outermost to innermost… Text lists are
used in HTML import and export."*
(https://developer.apple.com/documentation/uikit/nstextlist), carrying
`markerFormat`, `isOrdered`, `startingItemNumber`,
`marker(forItemNumber:)`. **Headings have no native key** — a heading
is font size/weight plus spacing, so it is a kaya-level semantic that
must be carried separately to round-trip. **[INFERENCE]**

Foundation also ships a **semantic** vocabulary that is not a rendering
vocabulary, and it is the one worth stealing for the wire (§7):

- `InlinePresentationIntent` (iOS 15.0+, macOS 12.0+; *"…presentation
  intent for runs of characters for traits like emphasis,
  strikethrough, and code voice"*): `emphasized`, `stronglyEmphasized`,
  `code`, `strikethrough`, `softBreak`, `lineBreak`, `inlineHTML`,
  `blockHTML`
  (https://developer.apple.com/documentation/foundation/inlinepresentationintent).
- `PresentationIntent` (iOS 15.0+, macOS 12.0+; *"…for blocks of
  characters like paragraphs, lists, block quotes, and tables"*),
  **Codable**, `Kind` = `paragraph`, `header(level: Int)`,
  `orderedList`, `unorderedList`, `listItem(ordinal: Int)`,
  `blockQuote`, `codeBlock(languageHint: String?)`, `thematicBreak`,
  `table(columns:)`, `tableRow(rowIndex:)`, `tableHeaderRow`,
  `tableCell(columnIndex:)`
  (https://developer.apple.com/documentation/foundation/presentationintent,
  .../presentationintent/kind).

That is *exactly* the block vocabulary the brief lists, already
Codable and already the output of `AttributedString(markdown:)`.
**[INFERENCE]** the strongest single prior art for kaya's block model.

`AttributedString` itself is *"A value type for a string with
associated attributes for portions of its text"*, conforms to
**Codable**, Equatable, Hashable, and exposes `runs` — *"An iterable
view into segments of the attributed string, each of which indicates
where a run of identical attributes begins or ends"*
(https://developer.apple.com/documentation/foundation/attributedstring).
`runs` is literally "a string plus attribute runs", the §7 shape.

### 1d. How macOS reports edits

Two layers, and kaya can have either or both.

**The delegate, pre-commit and vetoable:**

```swift
@MainActor optional func textView(
    _ textView: NSTextView,
    shouldChangeTextIn affectedCharRange: NSRange,
    replacementString: String?
) -> Bool
```

*"Sent when a text view needs to determine if text in a specified range
should be changed."* — and crucially, `replacementString` is
**optional**, `nil` *"if only text attributes are being changed"*
(https://developer.apple.com/documentation/appkit/nstextviewdelegate/textview(_:shouldchangetextin:replacementstring:)).
So on macOS the delegate sees attribute-only edits as a distinguishable
case. Note the multi-range replacement
`textView(_:shouldChangeTextInRanges:replacementStrings:)` **supersedes**
it: *"If a delegate implements the new method, then this one is
ignored."*

**The storage, post-commit and authoritative:**
`textStorage(_:willProcessEditing:range:changeInLength:)` and
`textStorage(_:didProcessEditing:range:changeInLength:)`, both
`(NSTextStorage, editedMask: NSTextStorage.EditActions,
range: NSRange, changeInLength: Int)`
(https://developer.apple.com/documentation/uikit/nstextstoragedelegate,
iOS 7.0+ / Mac Catalyst 13.1+ — shared with UIKit, which is why one
kaya Swift file can serve both arms). `NSTextStorage.EditActions` has
exactly two cases: `editedAttributes` (*"Attributes were added,
removed, or changed"*) and `editedCharacters` (*"Characters were added,
removed, or replaced"*)
(https://developer.apple.com/documentation/uikit/nstextstorage/editactions).

**This is a delta channel.** `editedRange` + `changeInLength` +
`editedMask` is (range replaced, length change, whether attributes or
characters moved), post-edit, per commit. **[INFERENCE]** With the
pre-edit string in hand (kaya's core already keeps
`field_text: HashMap<WidgetId, String>`, `crates/kaya/src/scene.rs:438`,
cited at `docs/ranges-units.md:28`), `editedRange` and `changeInLength`
give the replaced range *before* the edit as
`(editedRange.location, editedRange.length - changeInLength)` and the
inserted text as the substring at `editedRange` after — i.e. a
`{replace: [start,end), with: string, attrs}` delta without diffing.

### 1e. IME on macOS

kaya has already measured the macOS/iOS divergence and written it into
the interpreter: *"`compose`: leave MARKED, UNCOMMITTED text in the
control, so select_range must refuse to run over it. A MEASURED
DIVERGENCE FROM macOS — UITextView DOES notify its delegate for marked
text (2026-08-06) — but the guard on the push stays: a write
mid-composition drops `markedTextRange` silently."*
(`swift/KayaSwiftUI.swift:6318-6322`). **So macOS's NSTextView does NOT
notify the delegate for marked text and iOS's UITextView does** — a
measured, in-repo fact, and the single sharpest constraint on
per-keystroke delta publishing.

**[INFERENCE]** For a delta design: the *storage* layer still fires for
marked text on both (marked text really is in the storage); it is the
*delegate* veto hook that differs. A CRDT consuming storage deltas
would see composition churn and must either suppress while
`hasMarkedText()` is true or model the marked range as provisional.

---

## 2. iOS — UITextView

Same Foundation model, same `NSAttributedString`/`NSTextStorage`, same
`NSTextStorageDelegate` (the protocol page is a UIKit page:
iOS 7.0+). The differences that matter:

**The delegate signature is narrower than macOS's:**

```swift
optional func textView(_ textView: UITextView,
                       shouldChangeTextIn range: NSRange,
                       replacementText text: String) -> Bool
```

*"Asks the delegate whether to replace the specified text in the text
view… The text view calls this method whenever the user types a new
character or deletes an existing character."*
(https://developer.apple.com/documentation/uikit/uitextviewdelegate/textview(_:shouldchangetextin:replacementtext:)).
`replacementText` is a **non-optional `String`** — there is no `nil`
case, so **attribute-only edits are not reported through this hook on
iOS**, unlike macOS. Attribute-only edits must come from
`NSTextStorageDelegate`'s `editedAttributes` mask.

**Marked text IS reported to the delegate on iOS** (measured in-repo,
`swift/KayaSwiftUI.swift:6319-6321`) — the opposite of macOS.

**SwiftUI's attributed `TextEditor` is iOS 26.0+** and kaya's floor is
iOS 16 (`docs/textarea-foundation-plan.md`, the ios arm), so on iOS the
attributed editor is a *future* affordance, not a floor one.
**[INFERENCE]** kaya would use `UITextView` + `NSTextStorage` on the
floor and could adopt the SwiftUI editor as an upper-tier nicety only
if it were willing to carry two code paths — which the interpreter
already avoids elsewhere by owning the UIKit view directly.

---

## 3. Linux — GTK4 GtkTextView + GtkTextBuffer + GtkTextTag

### 3a. The model: named tags over a buffer, not attribute runs

GtkTextView *"Displays the contents of a GtkTextBuffer"*
(https://docs.gtk.org/gtk4/class.TextView.html). Styling is
`GtkTextTag` objects registered in a `GtkTextTagTable` and applied to
ranges via `apply_tag` / `remove_tag`. The tag vocabulary
(https://docs.gtk.org/gtk4/class.TextTag.html) covers:

`weight` (*"Font weight as an integer"*), `style` (*"Font style as a
PangoStyle, e.g. PANGO_STYLE_ITALIC"*), `underline`, `underline-rgba`,
`strikethrough`, `strikethrough-rgba`, `overline`, `family` (*"…Sans,
Helvetica, Times, Monospace"*), `font`, `scale` (*"Font size as a scale
factor relative to the default font size"*), `size`, `foreground`,
`background`, `paragraph-background`, `justification`, `indent`,
`left-margin`, `right-margin`, `pixels-above-lines`, `wrap-mode`.

**There is no link/hyperlink property** on GtkTextTag (verified against
the property list on that page). **[INFERENCE]** a link on GTK is a
kaya-level construct: a tag carrying the visual, a side table mapping
tag → URL, and click handling via
`gtk_text_view_get_iter_at_location` + `gtk_text_iter_get_tags` in a
gesture controller — the standard GTK idiom, but app code rather than a
widget feature.

**No lists.** Nothing in the tag vocabulary numbers or bullets a
paragraph. `indent` and `left-margin` are the raw material;
markers are characters the app inserts. **[INFERENCE]** so bullets and
numbering on GTK are *synthesized* — which also means the marker text
is in the buffer and therefore in kaya's offsets, unlike NSTextList
(where the marker is generated by the text system and is NOT in the
string) and unlike RichEdit's PARAFORMAT lists. **This is the single
biggest cross-platform divergence in the block vocabulary:** the same
document has different character offsets on GTK than on macOS if
markers are inline.

**GTK 4 REMOVED cross-process rich-text interchange.** The 3→4
migration guide, under "Replace GtkClipboard with GdkClipboard":
*"Support for rich text serialization across different processes for
`GtkTextBuffer` is not available any more."*
(https://docs.gtk.org/gtk4/migrating-3to4.html); confirmed from the
other side, the GtkTextBuffer class page lists **no** method whose name
contains serialize, deserialize or rich. **[INFERENCE]** kaya owns the
interchange format on Linux outright, and formatted paste arrives as
text/html or text/plain for kaya or the app to parse.

**libadwaita adds nothing here.** Its full class index
(https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/index.html)
contains `EntryRow`, `PasswordEntryRow` and `SpinRow` as its only
text-entry widgets; **there is no rich text editor, text view or
formatted-text widget.** (Checked against the class list on that page.)

### 3b. How GTK reports edits — the best delta channel of the five

```c
void insert_text (GtkTextBuffer* self, const GtkTextIter* location,
                  gchar* text, gint len, gpointer user_data)
```
*"Emitted to insert text in a GtkTextBuffer. Insertion actually occurs
in the default handler."* — G_SIGNAL_RUN_LAST, so *"the default handler
is called after handlers added via g_signal_connect()"*, and *"if your
handler runs before the default handler, you must not invalidate the
`location` iterator… The default signal handler revalidates it to point
to the end of the inserted text."*
(https://docs.gtk.org/gtk4/signal.TextBuffer.insert-text.html)

```c
void delete_range (GtkTextBuffer* self, const GtkTextIter* start,
                   const GtkTextIter* end, gpointer user_data)
```
*"Emitted to delete a range from a GtkTextBuffer."* … *"Handlers which
run after the default handler (see g_signal_connect_after()) do not
have access to the deleted text."*
(https://docs.gtk.org/gtk4/signal.TextBuffer.delete-range.html)

**This is a true per-edit delta with position and payload**: insert
gives (position, UTF-8 text, **byte length**) and delete gives
(start, end) with the old text still readable in a *before* handler.
**[INFERENCE]** Note `len` is documented as the byte length of UTF-8
`text` — GTK's edit signal is the one channel of the five that speaks
kaya's ruled unit natively on the payload side, while the position
iterator still counts code points (`docs/ranges-units.md:203-208`).

Attribute-only changes are reported too, on their own signals:
`apply-tag` (*"Emitted to apply a tag to a range of text"*) and
`remove-tag` (*"Emitted to remove all occurrences of tag from a
range"*). `changed` is the coarse "content changed" notification.
`begin-user-action` / `end-user-action` bracket *"a single user-visible
operation"* — the natural grouping boundary for a delta batch, and the
same bracket GTK's own undo uses.

**IME:** GtkTextView has `preedit-changed` (*"Emitted when preedit text
of the active IM changes"*) and routes keys through
`im_context_filter_keypress()`
(https://docs.gtk.org/gtk4/class.TextView.html). **[INFERENCE]** GTK's
preedit is drawn by the view and is NOT in the buffer, so unlike
AppKit's marked text it does not pollute `insert-text` — preedit
commits arrive as one `insert-text`. That makes GTK the *easiest*
delta platform and is a divergence worth measuring before designing.

### 3c. Reading attributes back on GTK

`gtk_text_iter_get_tags(const GtkTextIter*)` — *"Returns a list of tags
that apply to `iter`, in ascending order of priority. The
highest-priority tags are last."*
(https://docs.gtk.org/gtk4/method.TextIter.get_tags.html), with
`has_tag`, `get_toggled_tags` (*"tags that begin or end at this
iterator position"*), `starts_tag`, `ends_tag` alongside. So
"is the selection bold?" is a per-iterator tag query, not an attribute
read — kaya would ask at the selection start and, for a true answer,
walk the toggles across the range.

### 3d. Undo on GTK (a11y is in §9)

`GtkTextBuffer:enable-undo` is *"gboolean [read, write]"*, **default
TRUE**, *"Denotes if support for undoing and redoing changes to the
buffer is allowed"*
(https://docs.gtk.org/gtk4/property.TextBuffer.enable-undo.html) —
which is what kaya's undo plan already records
(`docs/undo-plan.md:29-31`). The buffer exposes `undo()`, `redo()`,
`get_can_undo()`, `get_can_redo()`, `begin_irreversible_action()` /
`end_irreversible_action()` (*"Denotes the beginning of an action that
may not be undone"*) and `begin_user_action()`/`end_user_action()`
(https://docs.gtk.org/gtk4/class.TextBuffer.html). kaya already uses
the irreversible bracket for D7 (`docs/undo-plan.md:319-321`:
"GTK irreversible-action bracketing").

**[INFERENCE, needs measuring]** GTK's documentation nowhere states
whether the undo stack records *tag* changes as well as text changes.
The signals are separate (`apply-tag` is not `insert-text`), which
suggests the undo history — built around insert/delete — does not cover
attribute-only edits. **This is a probe the milestone must run**: if
GTK's native undo cannot undo a bold toggle, then the native tier
(`docs/undo-plan.md` D1) is *incomplete for rich text on Linux* and
attribute edits must be core-tier there while typing stays native —
a split inside one widget that D6's routing has never had to express.

---

## 4. Windows — WinUI 3 RichEditBox + the Text Object Model

kaya already owns a `RichEditBox`, pinned to plain text
(`crates/kaya/src/winui/mod.rs:9443` `fn pin_plain_text`, and
`:9469` — *"kaya's textarea is a RichEditBox — a control that CAN carry
…"*). Its editing commands already route through `TextDocument()`
(`crates/kaya/src/winui/mod.rs:243-244`, and the `Editable::Textarea`
arms at `:296-367`). Unpinning it is the whole Windows arm.

### 4a. The model: TOM, cp offsets, a story, and formats

`ITextDocument` *"Provides access to the content of a document,
providing a way to load and save the document to a stream, retrieve
text ranges, get the active selection, set default formatting
attributes, and so on"*
(https://learn.microsoft.com/en-us/uwp/api/windows.ui.text.itextdocument):
`GetRange(Int32,Int32)`, `Selection`, `GetText(TextGetOptions, out String)`,
`SetText(TextSetOptions, String)`, `LoadFromStream` / `SaveToStream`,
`SetDefaultCharacterFormat` / `SetDefaultParagraphFormat`,
`BeginUndoGroup()` / `EndUndoGroup()`, `Undo()`/`Redo()`/`CanUndo()`/
`CanRedo()`, `UndoLimit`, `BatchDisplayUpdates()`/`ApplyDisplayUpdates()`.

`ITextRange` is *"a span of continuous text in a document"*
(https://learn.microsoft.com/en-us/uwp/api/windows.ui.text.itextrange)
with `StartPosition`, `EndPosition`, `Length`, `StoryLength`, `Text`,
`FormattedText`, **`CharacterFormat`**, **`ParagraphFormat`**, and the
one that matters most, **`Link`** — *"Gets or sets the URL text
associated with a text range."* Windows has first-class settable
hyperlinks on a range; GTK does not.

Offsets are UTF-16 "cp" and clamp rather than throw
(`docs/ranges-units.md:252-275`, quoting the ITextRange reference), and
*"all stories contain an undeletable final CR (0xD) character at the
end"* — already recorded at `docs/ranges-units.md:268-272`.

### 4b. Inline and block attributes

`ITextCharacterFormat` *"Defines the default character formatting
attributes of a document, or the current character formatting
attributes of a text range"*
(https://learn.microsoft.com/en-us/uwp/api/windows.ui.text.itextcharacterformat):
`Bold`, `Italic`, `Underline`, `Strikethrough`, `Name` (font name — the
monospace route), `Size`, `Weight`, `FontStyle`, `ForegroundColor`,
`BackgroundColor` (*"text background (highlight) color"*), `Subscript`,
`Superscript`, `AllCaps`, `SmallCaps`, `Hidden`, `Position`,
`Spacing`, `LanguageTag`, and `LinkType` (**get-only**: *"Gets the link
type of the text"* — setting a link is `ITextRange.Link`, not this).

`ITextParagraphFormat`
(https://learn.microsoft.com/en-us/uwp/api/windows.ui.text.itextparagraphformat)
gives the block half **including native lists**: `ListType` (*"Gets or
sets the kind of characters used to mark the item paragraphs in a
list"*), `ListStart` (*"the starting value or code of a list numbering
sequence"*), `ListLevelIndex`, `ListStyle`, `ListTab`, `ListAlignment`,
plus `Alignment`, `LeftIndent`, `RightIndent`, `FirstLineIndent`,
`SpaceBefore`, `SpaceAfter`, `Style`, `LineSpacing`, `SetIndents`.

**List markers are NOT in the text** — `TextGetOptions.IncludeNumbering`
(value 64) exists precisely to *"Include list numbers"*
(https://learn.microsoft.com/en-us/uwp/api/windows.ui.text.textgetoptions),
i.e. by default a `GetText` of a numbered list omits the numbers. Same
as NSTextList, opposite of GTK. **[INFERENCE]** this makes the marker
question a three-way split (mac/win generate markers, GTK does not,
Compose has neither) and it must be settled at the wire level, not per
backend, or offsets will not mean the same thing on five platforms —
exactly the class `docs/ranges-units.md:307-315` calls out.

**Headings: no native concept**, same as AppKit. `ParagraphFormat.Style`
takes a style index (RichEdit's `PARAFORMAT2.sStyle`) but WinUI exposes
no style sheet to define one. **[INFERENCE]** heading = font size +
weight + spacing, carried semantically by kaya.

### 4c. Interchange: RTF, in and out, for free

`TextGetOptions.FormatRtf` (8192) — *"Retrieve Rich Text Format (RTF)
instead of plain text… the RTF is returned as WCHARs (16-bit or UTF-16),
not bytes… When you call ITextRange.SetText with FormatRtf, the method
accepts a string containing either bytes or WCHARs, but other RTF
readers only understand bytes."* The same enum carries `AdjustCrlf` (1,
already used at `crates/kaya/src/winui/mod.rs:1577-1598`), `UseCrlf` (2),
`UseLf` (16777216, *"If both UseLf and UseCrLf are used an invalid
argument exception is thrown"*), `NoHidden` (32), `UseObjectText` (4),
and `AllowFinalEop` (8) — *"the final end-of-paragraph … exists in all
rich-text controls and cannot be deleted. It does not exist in
plain-text controls"*.

**[INFERENCE]** That last sentence is a live hazard for the unpinning:
kaya's *plain-text* RichEditBox has no final EOP, a rich one does, and
kaya's `r.End <= StoryLength - 1` arithmetic
(`docs/ranges-units.md:268-272`) was derived under the plain-text pin.

### 4d. How Windows reports edits — the WEAKEST channel of the five

`RichEditBox` has `TextChanging`, `TextChanged`,
`TextCompositionStarted`/`Changed`/`Ended`, `SelectionChanging`/
`SelectionChanged`, `Paste`, `CopyingToClipboard`, `CuttingToClipboard`
(https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.richeditbox).
And the event args are the finding:

`RichEditBoxTextChangingEventArgs` has **exactly one property** —
`IsContentChanging`, *"Gets a value that indicates whether the event
occured due to a change in the text content"*
(https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.richeditboxtextchangingeventargs).
**No range. No offset. No inserted string. No length delta.**
`TextChanged` carries a bare `RoutedEventArgs`.

**[INFERENCE, and this is the load-bearing finding of the report]**
Windows is the platform where per-keystroke deltas are NOT available
from the control. The options are (a) diff the whole story on every
`TextChanged` — what "string in, string out" already does, and what
kaya's `text_changed` occurrence is today: correct but lossy;
(b) sample `Selection.StartPosition` before and after and reconstruct
the edit from caret movement plus length delta, a heuristic that IME
and paste break; or (c) go under WinUI to ITextHost/ITextServices or
`ITextDocument2`, neither projected into WinRT.

`TextCompositionStarted`/`Changed`/`Ended` at least *bracket* IME
composition explicitly, which is more than macOS gives; a delta design
can suppress publishing between Started and Ended.

`DisabledFormattingAccelerators` is the knob kaya already needs for
the reverse reason — the foundation plan pinned rich opinions off
(`docs/textarea-foundation-plan.md:20-24`); unpinning means *choosing*
which of Ctrl+B/I/U the control may handle itself.

### 4e. Reading back and undo on Windows (a11y is in §9)

Reading back is `document.GetRange(a,b).CharacterFormat.Bold` etc.
Windows formats are **tri-state** (`FormatEffect` — On/Off/Undefined/
Toggle), so a mixed selection answers "Undefined" rather than lying.
**[INFERENCE]** that is the correct answer for a toolbar and a semantic
kaya should copy on the wire rather than reduce to a boolean.

Undo: `BeginUndoGroup()`/`EndUndoGroup()` is explicit grouping,
`UndoLimit` bounds the stack, and `CanUndo`/`Undo` are already wired
(`crates/kaya/src/winui/mod.rs:296-324`); the routing lives inside
`key_hook` because *"the HOOK steals Ctrl+Z from the TextBox"*
(`docs/undo-plan.md:236-252`). **[INFERENCE]** With a rich control,
`BeginUndoGroup`/`EndUndoGroup` is the obvious spelling for D2's named
group — the only backend offering explicit undo grouping publicly.

---

## 5. Android — Compose, and the first-party rich text that just arrived

kaya is on `BasicTextField(state:)` + `TextFieldState`
(`android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt:11986`, `:370`), at pins
**foundation 1.7.5 / material3 1.3.1 via BOM 2024.10.01**
(`docs/undo-plan.md:325-329`).

### 5a. The state model, and the news

`TextFieldState` *"Manages editable text, selection, and cursor state
for a text field"*; `public val text: CharSequence` — **not** an
`AnnotatedString` (androidx-main,
`compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/text/input/TextFieldState.kt`).
`BasicTextField(state:)` takes `textStyle: TextStyle` (uniform),
`inputTransformation`, `outputTransformation`, `decorator` — **no
AnnotatedString parameter** (`.../text/BasicTextField.kt`). And
`OutputTransformation` (`fun interface { fun TextFieldBuffer.transformOutput() }`)
is explicitly NOT a styling hook: *"A function that transforms the text
presented to a user by a [BasicTextField]"*, changing the *visual
representation* only, its changes *"discarded after presentation"*, and
*"Selection and cursor positions are managed internally by
[BasicTextField]"* so edits to them *"do not have any affect"*
(`.../text/input/OutputTransformation.kt`).

**BUT — and this is the report's second load-bearing finding —
androidx has shipped first-party styled editing on `TextFieldState`.**
`TextFieldBuffer` now carries, each `@OptIn(ExperimentalFoundationApi::class)`:

```kotlin
public fun addStyle(spanStyle: SpanStyle, start: Int, end: Int)
public fun addStyle(paragraphStyle: ParagraphStyle, start: Int, end: Int)
public fun addStyle(s: SpanStyle, range: TextRange, expandPolicy: ExpandPolicy): TrackedRange<SpanStyle>
public fun addStyle(p: ParagraphStyle, range: TextRange, expandPolicy: ExpandPolicy): TrackedRange<ParagraphStyle>
public fun getSpanStyles(range: TextRange): List<TrackedRange<SpanStyle>>
public fun getParagraphStyles(range: TextRange): List<TrackedRange<ParagraphStyle>>
public fun removeStyle(trackedRange: TrackedRange<*>): Boolean
```
*"Adds the given [spanStyle] to the text between [start] and [end] on
this buffer. Styles are applied in the order they are added to the
buffer. This order is preserved even as the text is edited and style
ranges are adjusted."*
(https://github.com/androidx/androidx/blob/androidx-main/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/text/input/TextFieldBuffer.kt),
with `TrackedRange<*>.textRange`, `.spanStyle`, `.paragraphStyle`,
`.expandPolicy`, `.isValid` as extension properties, and the read-only
sibling `TextFieldTextStyles` — *"Provides access to the styles applied
to the text within a `TextFieldState`… a style query API similar to
`TextFieldBuffer`, but returns immutable data"* —
`getSpanStyles(range)` / `getParagraphStyles(range)` →
`List<AnnotatedString.Range<SpanStyle>>`
(.../text/input/TextFieldTextStyles.kt in the same tree).

Dating it from the release notes
(https://developer.android.com/jetpack/androidx/releases/compose-foundation):
**1.12.0-beta01, June 17 2026** — *"Updated `getSpanStyles` and
`getParagraphStyles` to take a `TextRange` instead of separate start/end
indices. Relaxed bounds checking on style queries to no longer throw
exceptions, and prevented crashes when querying properties of
invalidated `TrackedRanges`."* (b/514404697); and **1.13.0-alpha01,
Aug 12 2026** — *"`TextFieldState` now saves and restores text style
information. `AnnotatedString.Annotation.Saver` is now public…"*
(b/135556699 — the long-standing "rich text editing in Compose" issue).
Latest stable **1.12.1 (Sept 9 2026)**; latest alpha **1.13.0-alpha03**.

**[INFERENCE]** So Compose is no longer a "synthesize it yourself"
platform for inline styling — but it costs kaya a **five-minor-version
pin bump** (1.7.5 → 1.12.x), the API is `@ExperimentalFoundationApi`,
and `ExpandPolicy` introduces a per-span question no other platform
makes explicit (what a span does when you type at its edge). kaya's
undo plan already recorded that the last such move "needs NO pin bump"
(`docs/undo-plan.md:325-329`); this one does.

### 5b. What Compose can express

`SpanStyle` carries fontWeight, fontStyle, fontFamily (monospace),
fontSize, color, background, textDecoration (underline / lineThrough),
baselineShift. `ParagraphStyle` carries textAlign, lineHeight,
textIndent, textDirection — **no lists, no headings, no block quote**.
Links are `AnnotatedString.Annotation`s, not styles:
`LinkAnnotation.Url(url, styles: TextLinkStyles?, linkInteractionListener)`
— *"An annotation that contains a [url] string. When clicking on the
text to which this annotation is attached, the app will try to open the
url using [UriHandler]"* — and `LinkAnnotation.Clickable(tag, …)`
(https://github.com/androidx/androidx/blob/androidx-main/compose/ui/ui-text/src/commonMain/kotlin/androidx/compose/ui/text/LinkAnnotation.kt).
**[INFERENCE, NEEDS MEASURING]** `TextFieldBuffer.addStyle` takes only
`SpanStyle`/`ParagraphStyle`, so it is not obvious that a
`LinkAnnotation` can be attached to *editable* field content at all;
1.13.0-alpha01's `AnnotatedString.Annotation.Saver` going public hints
that annotations are on the way. Until measured, **links inside an
editable field on Android are the gap**.

### 5c. How Compose reports edits — the BEST channel of the five

`TextFieldBuffer.changes` is *"The [ChangeList] … [that] represents the
changes made to this [TextFieldBuffer]"*, with `changeCount` (*"The
number of changes that have been performed"*), `getRange(changeIndex)`
(*"Returns the range in the [TextFieldBuffer] that was changed"*) and
`getOriginalRange(changeIndex)` (*"Returns the range in the original
text that was replaced"*), beside `originalText` (*"Original text
content of the buffer before any changes were applied"*)
(TextFieldBuffer.kt, cited above). **That is a complete delta** — new
range, the range it replaced, and both texts in hand — *n* per commit,
and `InputTransformation.transformInput` receives the buffer before the
edit commits, so it is both a veto hook and a delta hook.

Compose offsets are UTF-16, **throw on out-of-bounds** and **snap
outward on a surrogate split** (`docs/ranges-units.md:293-306`;
`TextFieldState.kt` still carries the KDoc verbatim: *"If the start or
end of TextRange fall inside surrogate pairs or other invalid runs, the
values will be adjusted to the nearest earlier and later characters,
respectively"*).

### 5d. The fallbacks, for the record

The View-tier fallback is `EditText` + `Spannable` (`StyleSpan`,
`UnderlineSpan`, `StrikethroughSpan`, `URLSpan`, `ForegroundColorSpan`,
`BackgroundColorSpan`, `TypefaceSpan`, `RelativeSizeSpan`, sub/sup,
`BulletSpan`, `QuoteSpan`, `AlignmentSpan`) — the richest *block*
vocabulary on Android, since `BulletSpan` and `QuoteSpan` exist there
and nowhere in Compose. **[INFERENCE]** kaya will not take it: it would
reintroduce the legacy-path undo defect the undo plan disqualified
(`docs/undo-plan.md:304-313`).

Third-party: **Compose Rich Editor** (MohamedRejeb), v1.1.0, *"A rich
text editor library for both Jetpack Compose and Compose Multiplatform"*
— bold/italic/underline/strikethrough, code spans, links, ordered and
unordered lists, code blocks, alignment, `setHtml`/`toHtml`,
`setMarkdown`/`toMarkdown`, and *"Built-in rich-text-aware undo/redo
(state.history) that respects formatting, overriding BasicTextField's
default"* (https://github.com/MohamedRejeb/compose-rich-editor).
**[INFERENCE]** It owns its own document model *and* its own undo — a
*third* authority beside kaya's core and the platform, which kaya's
two-tier undo design (`docs/undo-plan.md` D1) has no room for. Worth
reading, not worth depending on.

---

## 6. The capability table (§2 of the charge)

Sources are the per-platform sections above. `synth` = kaya must draw
or insert it; `n/a` = the control has no concept at all.

### Inline attributes

| | mac NSTextView | iOS UITextView | GTK4 TextTag | WinUI TOM | Compose TextFieldState |
| --- | --- | --- | --- | --- | --- |
| bold | `font` (descriptor) | `font` | `weight` | `CharacterFormat.Bold` | `SpanStyle.fontWeight` |
| italic | `font` | `font` | `style` (PangoStyle) | `Italic` / `FontStyle` | `SpanStyle.fontStyle` |
| underline | `underlineStyle` (+`underlineColor`) | same | `underline`, `underline-rgba` | `Underline` | `textDecoration` |
| strikethrough | `strikethroughStyle` (+ colour) | same | `strikethrough`, `strikethrough-rgba` | `Strikethrough` | `textDecoration` |
| code/monospace | `font` family | `font` family | `family` ("Monospace") | `Name` | `fontFamily` |
| link + URL | `link` key | `link` key | **none — synth** (tag + side table) | `ITextRange.Link` (get/set) | `LinkAnnotation.Url` on `AnnotatedString`; **unproven on an editable field** |
| foreground colour | `foregroundColor` | same | `foreground` | `ForegroundColor` | `SpanStyle.color` |
| background/highlight | `backgroundColor` | same | `background` | `BackgroundColor` | `SpanStyle.background` |

### Block structure

| | mac | iOS | GTK4 | WinUI | Compose |
| --- | --- | --- | --- | --- | --- |
| paragraph style | `NSParagraphStyle` | same | per-tag margins/justification | `ITextParagraphFormat` | `ParagraphStyle` |
| heading | **none — synth** (font size/weight) | same | **synth** | **synth** (`Style` index unusable from WinUI) | **synth** |
| bullet list | `NSTextList` (marker generated, **not in the string**) | same | **none — synth, marker IS in the buffer** | `ListType`/`ListStyle` (marker **not** in text; `TextGetOptions.IncludeNumbering` opts in) | **none — synth** |
| numbered list | `NSTextList` + `startingItemNumber` | same | **synth** | `ListStart`, `ListLevelIndex` | **synth** |
| block quote | **synth** (indent + rule) | **synth** | **synth** (`indent`, `left-margin`) | **synth** (`SetIndents`) | **synth** (`textIndent`) |
| code block | **synth** (font + background) | **synth** | **synth** | **synth** | **synth** |

**The marker question is the sharpest cross-platform hazard.** macOS and
Windows generate list markers *outside* the character stream; GTK has no
list concept, so a marker there is characters in the buffer and therefore
in kaya's offsets. Same document, different offsets. **[INFERENCE]** the
only consistent rule is *kaya's block model owns list semantics and NO
marker is ever in the guest-visible text* — which means the GTK arm must
draw markers GTK's own buffer never sees. Price that before ruling the
vocabulary.

---

## 7. How edits are reported (§3 of the charge) — the delta question

| | channel | granularity | replaced range? | inserted text? | attribute-only edits? | IME |
| --- | --- | --- | --- | --- | --- | --- |
| mac | `NSTextStorageDelegate` will/didProcessEditing | per commit | `editedRange` + `changeInLength` (derive pre-edit range) | substring after the edit | **yes** — `editedMask` = `.editedAttributes` | **marked text NOT reported to the NSTextView delegate** (measured in-repo, `swift/KayaSwiftUI.swift:6319-6321`); storage still moves |
| mac (veto) | `textView(_:shouldChangeTextIn:replacementString:)` | per keystroke | yes (`affectedCharRange`) | yes (`String?`) | **yes** — `nil` string means *"only text attributes are being changed"* | as above |
| ios | same `NSTextStorageDelegate` | per commit | same | same | yes | **marked text IS reported** (measured, same file) |
| ios (veto) | `textView(_:shouldChangeTextIn:replacementText:)` | per keystroke | yes | yes (**non-optional** `String`) | **no** | as above |
| linux | `insert-text(location, text, len)` / `delete-range(start, end)` | per edit | yes (delete: iters; before the default handler the old text is readable) | yes, **UTF-8 with a byte length** | separate `apply-tag` / `remove-tag` signals | preedit is drawn by the view, `preedit-changed`; **[INFERENCE]** not in the buffer |
| windows | `TextChanging` / `TextChanged` | per change | **NO** | **NO** | **NO** (`IsContentChanging` is the only field) | `TextCompositionStarted/Changed/Ended` brackets it |
| android | `TextFieldBuffer.changes` (`ChangeList`) via `InputTransformation` / `TextFieldState.edit` | per commit, *n* changes | **yes, both sides**: `getRange(i)` (new) and `getOriginalRange(i)` (old) | yes (`originalText` + buffer) | **[INFERENCE, unmeasured]** `addStyle`/`removeStyle` are buffer ops; whether they appear in `changes` is not documented | Compose routes IME into the same buffer |

**So: per-keystroke delta reporting with positions is available on four
of five platforms and NOT on Windows.** GTK and Compose give it
cleanly; mac/iOS give it from the storage layer with one subtraction;
WinUI gives a bare "something changed" and kaya must diff.

**[INFERENCE]** For the CRDT endpoint the honest design is: **the core
computes the delta uniformly by diffing its own `field_text` mirror
against the new text** (`scene.rs:438`), with the per-platform channels
used only as corroboration and as the IME-suppression signal. Anything
else makes the wire contract mean five different things — invariant 1's
problem statement, which `docs/ranges-units.md:307-315` already made for
offsets.

---

## 8. Reading attributes back (§4 of the charge)

| platform | read-back call | mixed-selection answer |
| --- | --- | --- |
| mac/iOS | `attributes(at:effectiveRange:)`, `enumerateAttributes(in:options:)`; SwiftUI 26: `selection.attributes(in:)` / `typingAttributes(in:)` | enumerate and fold yourself; SwiftUI's `Attributes` sequence is designed for it |
| linux | `gtk_text_iter_get_tags` (*"in ascending order of priority"*), `has_tag`, `get_toggled_tags`, `starts_tag`/`ends_tag` | walk toggles across the range |
| windows | `GetRange(a,b).CharacterFormat.Bold` etc.; `.ParagraphFormat.ListType`; `.Link` | **tri-state `FormatEffect`** — a mixed range answers *Undefined*, not a lie |
| android | `TextFieldTextStyles.getSpanStyles(range)` → `List<AnnotatedString.Range<SpanStyle>>`; in a buffer, `getSpanStyles` → `List<TrackedRange<SpanStyle>>` | a list of ranges; fold yourself |

**[INFERENCE]** Windows' tri-state is the right contract for the
toolbar and for `expect_*` harness verbs: a bold query over a mixed
range has three answers, and four platforms would otherwise each pick
their own reduction — the same divergence shape as the offset policies.

---

## 9. Accessibility of attributed text (§5)

- **mac/iOS.** `NSAttributedString.Key` carries a dedicated
  accessibility family — `accessibilityFont`, `accessibilityUnderline`,
  `accessibilityStrikethrough`, `accessibilitySuperscript`,
  `accessibilityForegroundColor`, `accessibilityLink`,
  `accessibilityLanguage` and more (same Key page as §1c).
  **[INFERENCE, UNMEASURED]** what VoiceOver *says* for each is
  documented nowhere I could cite; it must be measured.
- **linux.** `GtkAccessibleText`, since 4.14 — *"An interface for
  accessible objects containing formatted text"* — `get_attributes()`
  *"obtains text attributes at a given offset"*, plus
  `get_default_attributes()`, `get_contents_at()` with granularity
  (https://docs.gtk.org/gtk4/iface.AccessibleText.html). Attribute names
  cross as strings.
- **windows.** UI Automation's text attributes are the richest and are
  fully enumerated: `UIA_FontWeightAttributeId` (40007, LOGFONT scale
  100-900), `UIA_IsItalicAttributeId` (40014),
  `UIA_UnderlineStyleAttributeId` (40030),
  `UIA_StrikethroughStyleAttributeId` (40026),
  `UIA_BulletStyleAttributeId` (40002, *"the style of bullets used in
  the text range"*), `UIA_StyleIdAttributeId` (40034 — the Style
  Identifiers list is where headings live), `UIA_StyleNameAttributeId`,
  `UIA_ForegroundColorAttributeId`, `UIA_AnnotationTypesAttributeId`
  (https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-textattribute-ids).
  **Caution:** `UIA_LinkAttributeId` (40035) is *"the text range that is
  the target of an **internal** link in a document"* — NOT a URL
  attribute. **[INFERENCE]** mapping `ITextRange.Link` onto it would be
  wrong.
- **android.** Compose `LinkAnnotation` makes link text focusable and
  activatable through `UriHandler` (LinkAnnotation.kt, cited above).
  **[INFERENCE, UNMEASURED]** what TalkBack announces for a
  `SpanStyle.fontWeight` inside an editable field is undocumented.

**[INFERENCE]** kaya's existing rule applies unchanged: the AX word set
is closed and pinned by `tools/check-verbs.py` (CLAUDE.md, "THE AX WORD
SET IS CLOSED since 2026-09-07"), so any rich-text a11y assertion must
first mint words all three harnesses can answer — and four of the five
platforms above expose *different* attribute names for the same trait.

---

## 10. Undo (§6)

| platform | native undo covers attributes? | explicit grouping API |
| --- | --- | --- |
| mac | **[INFERENCE]** yes — `NSUndoManager` + NSTextView registers attribute changes made through the text system; kaya already uses `removeAllActions()` on the first responder's manager for D7 (`docs/undo-plan.md:262-271`). UNMEASURED for attribute-only edits. | `NSUndoManager` grouping |
| ios | private `_UITextUndoManager`; a programmatic write *"registers nothing AND clears the field's stack by itself"* (`docs/undo-plan.md:275-281`) | `NSUndoManager` grouping |
| linux | **UNKNOWN — must be probed.** The docs never say; `apply-tag` is a different signal from `insert-text`, which suggests the history (built on insert/delete) may not cover tags. `enable-undo` default TRUE (https://docs.gtk.org/gtk4/property.TextBuffer.enable-undo.html) | `begin_user_action`/`end_user_action`; `begin_irreversible_action` |
| windows | TOM's stack is the RichEdit stack and covers formatting | **`ITextDocument.BeginUndoGroup()`/`EndUndoGroup()`** — the only public explicit grouping of the five |
| android | `TextFieldState.undoState` / `TextUndoManager`; a programmatic write clears history (`docs/undo-plan.md:314-320`) | via `TextFieldState.edit` |

**Taking undo over for a CRDT.** kaya's undo design is already two-tier:
*"Text-local undo DELEGATES to the platform's native stacks… App-state
undo is CORE-OWNED"* with one visible Edit>Undo and D6 routing
(`docs/undo-plan.md:99-106`). **[INFERENCE]** An app-owned CRDT document
breaks that split, because *every* keystroke is now app state: the
widget is a view onto a document the app owns, so the native tier has
nothing legitimate to undo, and native undo must be *suppressed*, not
delegated to. The undo plan itself records why suppression is hard —
*"It cannot be uniformly suppressed"*, with WinUI's TextBox having no
`IsUndoEnabled` at all (`docs/undo-plan.md:33-40`) — but the RICH
controls are better off than the plain ones: `ITextDocument.UndoLimit`
can be set to 0 on Windows, `enable-undo` is `FALSE`-able on GTK, and
`NSTextView.allowsUndo` exists on mac. **This is the one place where
unpinning the rich controls makes an old carve-out smaller, and it
should be measured, per platform, before the CRDT slice is designed.**

---

## 11. Interchange models (§7)

| model | inline vocabulary | block vocabulary | lossless for the target set? | maps to "string + runs in one offset unit"? |
| --- | --- | --- | --- | --- |
| **Attributed runs** (NSAttributedString / AnnotatedString / `AttributedString.runs`) | anything you define | paragraph attributes only | **yes, by construction** | **it IS the shape** — one string, runs of `(range, attrs)` |
| **Apple `PresentationIntent` + `InlinePresentationIntent`** | `emphasized`, `stronglyEmphasized`, `code`, `strikethrough`, `softBreak`, `lineBreak` | `paragraph`, `header(level:)`, `orderedList`, `unorderedList`, `listItem(ordinal:)`, `blockQuote`, `codeBlock(languageHint:)`, `thematicBreak`, tables | **yes for the target set** except underline and link colour (link is a separate `link` key) | yes — both are attributes on runs; **Codable** already |
| **Quill Delta** | `attributes` on inserts (bold, italic, underline, strike, code, link, color) | block attributes on the newline (header, list, blockquote, code-block) | yes for the target set | **it is an EDIT format, not a document format** — `retain/insert/delete` counts are exactly kaya's delta; positions are implicit (cumulative retain) |
| **ProseMirror / TipTap JSON** | `marks` array per text node | nested node tree (heading, bulletList, listItem, blockquote, codeBlock) | yes, and more | **no** — it is a TREE; offsets are ProseMirror positions counting node boundaries, not characters |
| **Portable Text** | `marks` referencing `markDefs` (links get an id) | flat array of blocks with `style` and `listItem`/`level` | yes | **partially** — spans are contiguous children, not ranges; concatenating spans gives the string and the offsets |
| **Markdown** | emphasis, strong, code, link, (strikethrough via GFM); **no underline, no colour** | headings, lists, quotes, code blocks | **no** — underline and foreground colour are unrepresentable | round-trip through `AttributedString(markdown:)` is lossy in that direction |
| **HTML subset** | b/i/u/s/code/a/span-style | h1-h6, ul/ol/li, blockquote, pre | yes | tree again; needs a flattener |
| **Android `Html.fromHtml`/`toHtml`** | `StyleSpan`, `UnderlineSpan`, `StrikethroughSpan`, `URLSpan`, `ForegroundColorSpan`, `BackgroundColorSpan`, `TypefaceSpan`, `RelativeSizeSpan`, sub/sup | `BulletSpan`, `QuoteSpan`, `AlignmentSpan`; parses `<p> <div> <blockquote> <ul> <li> <h1>-<h6> <br>` | *"Not all HTML tags are supported"* — its own javadoc | yes, spans ARE runs — but the tag set is fixed and headings come back as size spans |
| **RTF** | everything | everything | yes | **no** — a stream format; WinUI gives it free (`TextGetOptions.FormatRtf`), mac gives it free, GTK and Compose give nothing |

**[INFERENCE] The reading.** Quill Delta and "string + attribute runs"
are the same idea seen from two sides: a Delta is a *diff* between two
attributed strings, and it is the only listed model whose primitive is
already an edit with positions, which is what the CRDT endpoint needs.
Apple's `PresentationIntent` is the best-designed *vocabulary* (and is
Codable and already the Markdown parser's output). The natural kaya
wire is therefore: **a string in UTF-8 byte offsets, plus runs of a
closed attribute vocabulary modelled on `InlinePresentationIntent` +
`PresentationIntent`, plus a delta form
`[{retain n} | {insert str, attrs} | {delete n} | {retain n, attrs}]`
in those same byte offsets** — Delta's four ops, kaya's ruled unit,
Apple's nouns. Nothing about that needs a tree, and every platform's
model above is reachable from it by one lowering.

---

## 12. The reading

**The smallest vocabulary all five platforms can both render and edit
natively is: bold, italic, underline, strikethrough, monospace/code,
foreground colour and background colour as inline runs, plus paragraph
alignment and indent as block properties — and nothing else.** Links
are one step out: macOS, iOS and Windows have a first-class settable
link on a range (`NSAttributedString.Key.link`, `ITextRange.Link`),
GTK has no link property on `GtkTextTag` at all, and Compose's
`LinkAnnotation` is proven on displayed `AnnotatedString` but not on
`TextFieldState`'s editable content — so links need a synthesized tier
on Linux and a measurement on Android. Every *block* structure beyond
alignment and indent needs synthesis somewhere: headings have no native
concept on any of the five (all four rich models express a heading as
font size plus weight), block quotes and code blocks have none anywhere,
and lists exist natively only on Apple (`NSTextList`) and Windows
(`ITextParagraphFormat.ListType`) — where the marker is *generated
outside the character stream* — while GTK and Compose have no list
concept at all, so a marker there would be characters inside the buffer
and the same document would have different offsets on different
platforms. That marker asymmetry, not the styling, is the thing that
will break kaya's byte-offset contract if it is not ruled centrally
first. Compose is no longer the outlier for inline styling that it was
a year ago — androidx shipped `TextFieldBuffer.addStyle` /
`removeStyle` / `getSpanStyles` / `TrackedRange` and the read-only
`TextFieldTextStyles` in foundation 1.12 (beta June 2026, stable 1.12.1
September 2026), behind `@ExperimentalFoundationApi` — but reaching it
costs kaya a pin bump from 1.7.5, and Compose still has no lists, no
headings and no proven editable links, so it is the platform most
likely to need a synthesized tier for block structure. **Per-keystroke
delta reporting with positions is available on four of the five, not
all five:** GTK's `insert-text(location, text, len)` / `delete-range`
and Compose's `ChangeList` (`getRange` in the new text *and*
`getOriginalRange` in the old) are complete deltas; macOS and iOS give
`editedRange` + `changeInLength` + `editedMask` from
`NSTextStorageDelegate`, which is a complete delta after one
subtraction against the pre-edit string; **WinUI gives nothing** — 
`RichEditBoxTextChangingEventArgs` carries the single boolean
`IsContentChanging` and `TextChanged` a bare `RoutedEventArgs`, with no
range, no offset and no inserted string. So a CRDT-backed app cannot be
promised native deltas uniformly; the uniform answer is for the core to
derive the delta by diffing its own `field_text` mirror
(`crates/kaya/src/scene.rs:438`) and to use each platform's native
channel only as corroboration and as the IME-suppression signal — which
matters because the IME story is itself already non-uniform in kaya's
own measurements: NSTextView does not report marked text to its
delegate and UITextView does (`swift/KayaSwiftUI.swift:6319-6321`),
WinUI brackets composition explicitly with
`TextCompositionStarted`/`Ended`, and GTK keeps preedit out of the
buffer entirely.

---

## Appendix — what this report did NOT establish, and must be measured

1. **GTK's undo scope.** No document says whether `GtkTextBuffer`'s
   undo history records `apply-tag`/`remove-tag`. If it does not, the
   native undo tier is incomplete for rich text on Linux (§10).
2. **Compose links in an editable field.** `addStyle` takes only
   `SpanStyle`/`ParagraphStyle`; whether a `LinkAnnotation` can be
   attached to `TextFieldState` content is unproven (§5b).
3. **Whether `addStyle`/`removeStyle` appear in `TextFieldBuffer.changes`**
   — i.e. whether Compose reports attribute-only edits as changes (§7).
4. **The RichEditBox final EOP after unpinning.** `AllowFinalEop`'s
   documentation says the undeletable end-of-paragraph *"does not exist
   in plain-text controls"*; kaya's `StoryLength - 1` arithmetic was
   derived under the plain-text pin (§4c).
5. **What each screen reader actually announces** for bold, a link and
   a heading on each of the five (§9). kaya's AX word set is closed and
   pinned, so this is a prerequisite, not a nicety.
6. **Whether SwiftUI's iOS-26/macOS-26 attributed `TextEditor` is worth
   a second code path** at an iOS 16 floor (§1b, §2).
