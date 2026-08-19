# Find-in-document across general-purpose UI frameworks

Research arm for kaya's *find* milestone. Question served: which of three layers
belongs in a framework — (0) text-range primitives, (1) a core-owned search
engine, (2) a ready-made find bar.

Method: primary sources only — framework reference docs, upstream source trees,
and SDK headers read off this machine. Every claim carries a URL. "Ships" means
the framework's own distributed API; "apps build" means the ecosystem convention.

**A distinction this survey enforces throughout:** *document-find* (find inside
the text the user is editing/reading, with next/previous/replace over ranges) is
NOT the same as an *app-search component* (a search field that filters a list or
queries a backend — Material's `SearchBar`/`SearchAnchor`, WinUI's
`AutoSuggestBox`, UIKit's `UISearchController`). Frameworks ship the second one
constantly and the first one rarely. Conflating them is the known trap; each
section below flags it explicitly.

---

## Apple — AppKit (macOS)

**Verdict: find UI SHIPPED, engine SHIPPED, range primitives SHIPPED.** The most
complete precedent found in this arm, and the one whose architecture is most
directly relevant to kaya.

Read verbatim from the SDK on this machine:
`/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk/System/Library/Frameworks/AppKit.framework/Versions/C/Headers/NSTextFinder.h`
(© 2003–2024 Apple). Public docs mirror:
<https://developer.apple.com/documentation/appkit/nstextfinder>

### The find UI

`NSTextView` gets a find bar from a single Boolean:

```objc
@property BOOL usesFindPanel;                               // NSTextView.h:478
@property BOOL usesFindBar API_AVAILABLE(macos(10.7));      // NSTextView.h:480
- (void)performFindPanelAction:(nullable id)sender;         // NSTextView.h:155
```

`usesFindBar` is documented as "A Boolean value that indicates whether to use the
find bar for this text view… A text view can use either a find panel or a find
bar. If `usesFindBar` is set to `true`, `usesFindPanel` is set to `false` and vice
versa." macOS 10.7+.
(<https://developer.apple.com/documentation/appkit/nstextview/usesfindbar>)

So on AppKit the whole feature is **one property on the widget** for the common
case. That is the strongest possible evidence for layer 2 being framework work.

### The engine, decoupled from the widget

`NSTextFinder` is a standalone object, not a text-view method. It drives 13
actions:

```objc
typedef NS_ENUM(NSInteger, NSTextFinderAction) {
    NSTextFinderActionShowFindInterface = 1,
    NSTextFinderActionNextMatch = 2,
    NSTextFinderActionPreviousMatch = 3,
    NSTextFinderActionReplaceAll = 4,
    NSTextFinderActionReplace = 5,
    NSTextFinderActionReplaceAndFind = 6,
    NSTextFinderActionSetSearchString = 7,
    NSTextFinderActionReplaceAllInSelection = 8,
    NSTextFinderActionSelectAll = 9,
    NSTextFinderActionSelectAllInSelection = 10,
    NSTextFinderActionHideFindInterface = 11,
    NSTextFinderActionShowReplaceInterface = 12,
    NSTextFinderActionHideReplaceInterface = 13
};
```

**The matching dialect ships no regex.** The complete option surface is:

```objc
APPKIT_EXTERN NSPasteboardTypeTextFinderOptionKey const NSTextFinderCaseInsensitiveKey;  // BOOL
typedef NS_ENUM(NSInteger, NSTextFinderMatchingType) {
    NSTextFinderMatchingTypeContains = 0,
    NSTextFinderMatchingTypeStartsWith = 1,
    NSTextFinderMatchingTypeFullWord = 2,
    NSTextFinderMatchingTypeEndsWith = 3
};
```

Case-insensitivity plus four positional matching modes. No regex, no
backreferences, no lookaround anywhere in the API. Apple's shipped find bar for
the entire macOS text stack is a *literal* matcher with a whole-word mode.

### The client protocol — the range-primitive contract

This is the part worth copying. `NSTextFinder` does not know what a text view is.
It talks to `NSTextFinderClient`, whose required surface is essentially "give me
the string, tell me the selection, and move ranges around":

```objc
@property (readonly, strong) NSString *string;
- (NSString *)stringAtIndex:(NSUInteger)characterIndex
             effectiveRange:(NSRangePointer)outRange
     endsWithSearchBoundary:(BOOL *)outFlag;
- (NSUInteger)stringLength;
@property (readonly) NSRange firstSelectedRange;
@property (copy) NSArray<NSValue *> *selectedRanges;
- (void)scrollRangeToVisible:(NSRange)range;
- (nullable NSArray<NSValue *> *)rectsForCharacterRange:(NSRange)range;
@property (readonly, copy) NSArray<NSValue *> *visibleCharacterRanges;
- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)string;
- (BOOL)shouldReplaceCharactersInRanges:(NSArray<NSValue *> *)ranges
                            withStrings:(NSArray<NSString *> *)strings;
```

That list *is* kaya's layer 0, almost item for item: a range-addressable string,
a settable set of selected ranges, and scroll-to-range. Apple's engine is written
against exactly those primitives and nothing else, which is direct evidence that
layer 0 is the right cut line and that layer 1 can be built on it without the
engine knowing anything about widget internals.

Two more pieces confirm the layering:

- **Engine without UI.** `incrementalMatchRanges` is a KVO-observable
  `NSArray<NSValue *>` of match ranges, updated on the main queue from a
  background search. With `incrementalSearchingShouldDimContentView = NO` the app
  draws its own highlights (`+drawIncrementalMatchHighlightInRect:` is provided
  for that). So the framework exposes match *sets*, not just a cursor.
- **The bar is a slot, not a hardcode.** `NSTextFinderBarContainer` requires
  `findBarView` / `findBarVisible` / `findBarViewDidChangeHeight`, and the header
  notes "NSScrollView already implements NSTextFinderBarContainer." The engine
  builds the bar view; the container decides where it lives.

Range primitives on the view itself: `- (void)showFindIndicatorForRange:(NSRange)charRange`
(NSTextView.h:405, macOS 10.5+) — the yellow "found it" flash — plus
`scrollRangeToVisible:` and `selectedRanges`.

**Real app:** TextEdit.app and Xcode's single-file find both ride `NSTextFinder`;
Apple's own docs point third-party views at the same protocol. Chromium/WebKit
implement `NSTextFinderClient` to put the native find bar on web content
(<https://developer.apple.com/documentation/appkit/nstextfinderclient>).

---

## Apple — UIKit (iOS 16+)

**Verdict: find UI SHIPPED, engine SHIPPED (with a regex escape hatch), range
primitives SHIPPED.**

`UIFindInteraction` — "An interaction that provides text finding and replacing
operations using a system find panel", `@MainActor class UIFindInteraction`,
iOS/iPadOS/Mac Catalyst 16.0+, visionOS 1.0+.
(<https://developer.apple.com/documentation/uikit/uifindinteraction>)

Surface: `presentFindNavigator(showingReplace:)`, `dismissFindNavigator()`,
`findNext()`, `findPrevious()`, `isFindNavigatorVisible`, `searchText`,
`replacementText`, `optionsMenuProvider`, `activeFindSession`,
`updateResultCount()`.

Built-in adopters: `UITextView` (`isFindInteractionEnabled = true`), `WKWebView`,
`PDFView`. Again: **one Boolean on the widget** for the common case.

The engine is reachable without the panel through the `UITextSearching` protocol
and `UITextSearchOptions`
(<https://developer.apple.com/documentation/uikit/uitextsearchoptions>):

- `wordMatchMethod: UITextSearchOptions.WordMatchMethod` — cases `contains`,
  `startsWith`, `fullWord`
  (<https://developer.apple.com/documentation/uikit/uitextsearchoptions/wordmatchmethod>)
- `stringCompareOptions: NSString.CompareOptions`

The second one matters for kaya's dialect question: `NSString.CompareOptions`
includes `.regularExpression`, so an app *can* hand iOS a regex — but the shipped
find panel's own UI exposes only the word-match modes and case/diacritic
toggles. Regex is an app-supplied capability through a general string-comparison
bitmask, not a first-class find feature.

---

## Apple — SwiftUI

**Verdict: find UI SHIPPED (recent, and platform-skewed), engine ABSENT, range
primitives ABSENT/PARTIAL.**

```swift
nonisolated func findNavigator(isPresented: Binding<Bool>) -> some View
```

Availability: **iOS 16.0+, iPadOS 16.0+, Mac Catalyst 16.0+, macOS 26.0+,
visionOS 1.0+**
(<https://developer.apple.com/documentation/swiftui/view/findnavigator(ispresented:)>).

Note the four-year macOS gap: SwiftUI shipped find on iOS in 2022 and on macOS
only in the 26 cycle. A SwiftUI-only app targeting macOS before 26 had *no*
framework find at all and had to drop down to `NSTextFinder` via
`NSViewRepresentable`. Directly relevant to kaya, whose mac and iOS arms are the
same SwiftUI interpreter.

Companions: `findDisabled()` and `replaceDisabled()`. Documented gotcha: they
must be applied *before* `findNavigator`, and `findDisabled()` makes the
`isPresented` binding inert.

The modifier attaches to a `TextEditor` "or to a view hierarchy that contains at
least one text editor"; with several editors, which one gets the interface is
documented as **nondeterministic**. That is a real design warning for a
declarative framework adding find: presentation-by-ambient-lookup is ambiguous as
soon as there are two candidates.

SwiftUI ships no match-range API, no programmatic next/previous, and no
arbitrary-range highlight on `TextEditor`. It is find-UI-only: a bar you can show
and hide, with no engine you can drive.

---

## Qt — Widgets (`QTextEdit` / `QPlainTextEdit` / `QTextDocument`)

**Verdict: find UI ABSENT, engine SHIPPED, range primitives SHIPPED.** The
rumored precedent checks out, and its dialect is almost exactly kaya's candidate
layer 1.

Widget-level (moves the cursor as a side effect, returns a bool):

```cpp
bool find(const QString &exp, QTextDocument::FindFlags options = QTextDocument::FindFlags())
bool find(const QRegularExpression &exp, QTextDocument::FindFlags options = QTextDocument::FindFlags())
```

Both on `QTextEdit` (<https://doc.qt.io/qt-6/qtextedit.html>) and
`QPlainTextEdit` (<https://doc.qt.io/qt-6/qplaintextedit.html>): "Returns `true`
if `exp` was found and changes the cursor to select the match; otherwise returns
`false`."

Document-level (pure — returns a cursor, mutates nothing), four overloads
(<https://doc.qt.io/qt-6/qtextdocument.html>):

```cpp
QTextCursor find(const QString &subString, int position = 0, FindFlags options = FindFlags()) const
QTextCursor find(const QString &subString, const QTextCursor &cursor, FindFlags options = FindFlags()) const
QTextCursor find(const QRegularExpression &expr, int from = 0, FindFlags options = FindFlags()) const
QTextCursor find(const QRegularExpression &expr, const QTextCursor &cursor, FindFlags options = FindFlags()) const
```

Returns a **null cursor** on no match. The paired shape — a mutating convenience
on the widget, a pure query on the document — is worth noting for kaya's API
shape question.

The entire flag surface:

| Flag | Value | Meaning (Qt's words) |
| --- | --- | --- |
| `FindBackward` | 0x00001 | "Search backwards instead of forwards" |
| `FindCaseSensitively` | 0x00002 | default is case-insensitive; this enables case-sensitive matching |
| `FindWholeWords` | 0x00004 | "Makes find match only complete words" |

Three flags — direction, case, whole-word — plus a regex overload. That is
literal / case / whole-word / regex, which is the *exact* menu kaya is
considering for layer 1. Qt's regex is `QRegularExpression` (PCRE2), so Qt does
ship backreferences and lookaround; kaya's ruling them out is a narrowing of
Qt's dialect, not a departure from its structure.

Range primitives, all present:
`setExtraSelections(const QList<QTextEdit::ExtraSelection> &)` / `extraSelections()`
for temporary multi-range coloring (the standard way to paint all matches),
`textCursor()` / `setTextCursor()` / `moveCursor()` for selection,
`ensureCursorVisible()` and `QPlainTextEdit::centerCursor()` for reveal.

No find bar or find dialog anywhere in the widget library.

**Real app:** Qt Creator builds its own find infrastructure
(`src/plugins/coreplugin/find/` — `FindToolBar`, `IFindFilter`, `IFindSupport`)
rather than getting one from Qt; it is a plugin of the IDE, not part of the
framework (<https://github.com/qt-creator/qt-creator/tree/master/src/plugins/coreplugin/find>).

---

## Qt — QML / Qt Quick

**Verdict: find UI ABSENT, engine ABSENT from QML (reachable from C++),
range primitives SHIPPED.**

`TextEdit` in QML has **no find or search method**
(<https://doc.qt.io/qt-6/qml-qtquick-textedit.html>). Selection and geometry
primitives are all there: `select(start, end)`, `selectWord()`,
`selectionStart` / `selectionEnd`, `selectedText`, `cursorPosition`,
`positionAt(x, y)`, `positionToRectangle(position)`, `cursorRectangle`.

The escape hatch is `TextEdit.textDocument`, a `QQuickTextDocument`. Since Qt 6.7
it supports file load/save from QML and "can be used in C++ as a means of
accessing the underlying `QTextDocument` instance" — i.e. to search a QML text
editor you drop to C++ and call `QTextDocument::find`. No find bar in Qt Quick
Controls.

This is the clearest case in the survey of a *declarative* Qt layer losing the
engine its imperative sibling ships. Worth weighing for kaya: a declarative
surface does not inherit find for free.

---

## WPF

**Verdict: find UI SHIPPED (document viewers only), engine SHIPPED BUT INTERNAL,
range primitives SHIPPED.** The most instructive negative example in the survey.

### The UI exists, and is on by default

`FlowDocumentReader.IsFindEnabled` — "Gets or sets a value that indicates whether
the `Find` routed command is enabled… **The default is `true`.**" The remarks are
explicit: "Default `FlowDocumentReader` user interface (UI) includes a **Find**
button that toggles the Find dialog… When `IsFindEnabled` is `false`, the Find
button does not appear."
(<https://learn.microsoft.com/en-us/dotnet/api/system.windows.controls.flowdocumentreader.isfindenabled>)

```csharp
public bool IsFindEnabled { get; set; }
```

A public `Find()` method accompanies it. `FlowDocumentPageViewer`,
`FlowDocumentScrollViewer` and `DocumentViewer` carry the same pattern, all
driven by the `ApplicationCommands.Find` routed command.

**But `TextBox` and `RichTextBox` get nothing.** WPF's find UI is bound to the
read-only *document viewer* controls, not to the editable text controls. An app
that wants find in a `RichTextBox` builds it.

### The engine exists and is walled off

`internal static class TextFindEngine` in
`PresentationFramework/System/Windows/Documents/TextFindEngine.cs`:

```csharp
public static ITextRange Find(
    ITextPointer findContainerStartPosition,
    ITextPointer findContainerEndPosition,
    string findPattern,
    FindFlags flags,
    CultureInfo cultureInfo)
```

(<https://github.com/dotnet/wpf/blob/main/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Documents/TextFindEngine.cs>)

`FindFlags`: `MatchCase`, `FindInReverse`, `FindWholeWordsOnly`,
`MatchDiacritics`, `MatchKashida`, `MatchAlefHamza`. Culture-aware literal
matching via `CompareInfo`. **No wildcards, no regex.**

The toolbar is walled off the same way — `internal partial class FindToolBar`
in `PresentationUI/MS/Internal/Documents/FindToolBar.xaml.cs`, exposing
`SearchUp`, `MatchCase`, `MatchWholeWord`, `MatchDiacritic`, `MatchKashida`,
`MatchAlefHamza` (verified by code search over `dotnet/wpf`; the type also
appears in `cycle-breakers/PresentationUI/PresentationUI.internals.cs`).

So Microsoft wrote a complete, correct, culture-aware find engine and a complete
find toolbar, and shipped **neither** as public API. Every WPF app that wants
find in an editable control reimplements a worse version of code already sitting
in the assembly it loaded. That is a strong argument for kaya exposing layer 1
publicly rather than hiding it inside a widget.

Range primitives: `TextPointer` / `TextRange`, `TextBox.Select(start, length)`,
`Selection`, `TextRange.ApplyPropertyValue(TextElement.BackgroundProperty, …)`
for highlighting, `BringIntoView()` / `ScrollToLine` for reveal.

**Real app:** Visual Studio's editor is not WPF's text controls — it is a custom
editor with its own find. Notepad-class WPF apps roll their own loop over
`TextBox.Text` with `IndexOf`.

---

## WinUI 3 / Windows App SDK

**Verdict: find UI ABSENT, engine SHIPPED (RichEditBox only), range primitives
SHIPPED.**

No find bar or find dialog anywhere in WinUI 3. **Distinction flag:**
`AutoSuggestBox` is WinUI's search-shaped control and is an *app-search* widget
(suggestions over a data source), not document find.

The engine hook lives on the text object model:

```csharp
public int FindText(string value, int scanLength, FindOptions options);
```

"Searches for a particular text string in a range and, if found, selects the
string." Returns "the length of the matching text string, or zero if no matching
string is found."
(<https://learn.microsoft.com/en-us/uwp/api/windows.ui.text.itextrange.findtext>)

Reached from `RichEditBox.Document`, typed `Microsoft.UI.Text.RichEditTextDocument`
in the Windows App SDK
(<https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.richeditbox.document>),
via `GetRange(start, end)`.

The entire option surface (`Microsoft.UI.Text.FindOptions`, a `[Flags]` enum —
<https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.text.findoptions>):

| Member | Value | Description (Microsoft's words) |
| --- | --- | --- |
| `None` | 0 | "use case-independent, arbitrary character boundaries" |
| `Word` | 2 | "Match whole words." |
| `Case` | 4 | "Match case; that is, a case-sensitive search." |

Case + whole word. Note the shape: find is a **method on a range** that mutates
the range to become the match — neither a widget method (Qt) nor a separate engine
object (AppKit). Plain `TextBox` has no equivalent; it offers only
`Select(start, length)`, `SelectionStart` / `SelectionLength`.

`scanLength` encodes direction as well as bound, which the WinRT page leaves as a
truncated table. The Win32 Text Object Model reference — the same API underneath —
spells it out
(<https://learn.microsoft.com/en-us/windows/win32/api/tom/nf-tom-itextrange-findtext>):

| `Count` | Meaning (verbatim) |
| --- | --- |
| `tomForward` | "Searches to the end of the story. This is the default value." |
| *n* > 0 | "Searches forward for *n* chars, starting from *cpFirst*." |
| *n* < 0 | "Searches backward for *n* chars, starting from *cpLim*." |
| 0, degenerate range | "Search begins after the range." |
| 0, nondegenerate range | "Search is limited to the range." |

**And here is the finding worth flagging: WinRT narrowed the dialect on the way
up.** The Win32 TOM flags are `tomMatchWord` (2), `tomMatchCase` (4), and
**`tomMatchPattern` (8) — "Matches regular expressions."** The WinRT/WinUI
`FindOptions` enum reproduces 2 and 4 and **drops 8**. Microsoft had a working
regex find in the RichEdit engine and chose not to project it into the modern API,
keeping literal + case + whole word. A framework designing this surface fresh
made the same cut kaya is considering — and made it *deliberately*, against an
implementation that already had regex sitting there.

(TOM's find also supports Word-style `^p`-class special characters, another
capability WinRT dropped.)

**Real app:** Windows Notepad (WinUI 3 since 2022) has find/replace built by the
Notepad team, not obtained from WinUI.

---

## GTK4 (plain, no GtkSourceView)

**Verdict: find UI ABSENT, engine SHIPPED (thin), range primitives SHIPPED.**

The engine hook is on the iterator, not the widget or the buffer:

```c
gboolean gtk_text_iter_forward_search (
  const GtkTextIter* iter,
  const char* str,
  GtkTextSearchFlags flags,
  GtkTextIter* match_start,
  GtkTextIter* match_end,
  const GtkTextIter* limit
)
```

with a `gtk_text_iter_backward_search` counterpart
(<https://docs.gtk.org/gtk4/method.TextIter.forward_search.html>).

The complete flag set (<https://docs.gtk.org/gtk4/flags.TextSearchFlags.html>):

| Flag | Meaning (GTK's words) |
| --- | --- |
| `GTK_TEXT_SEARCH_VISIBLE_ONLY` | "Search only visible data. A search match may have invisible text interspersed." |
| `GTK_TEXT_SEARCH_TEXT_ONLY` | "Search only text. A match may have paintables or child widgets mixed inside the matched range." |
| `GTK_TEXT_SEARCH_CASE_INSENSITIVE` | "The text will be matched regardless of what case it is in." |

**Thinner than every other engine here: no whole-word flag and no regex.** An app
wanting whole-word must test boundaries itself with
`gtk_text_iter_starts_word` / `ends_word`. This is the one framework whose shipped
engine is *below* kaya's proposed layer-1 floor.

Range primitives are strong: `GtkTextMark` and `GtkTextIter` for stable
positions, `gtk_text_buffer_create_tag` + `gtk_text_buffer_apply_tag` for
arbitrary-range highlight (the standard way to paint matches),
`gtk_text_buffer_select_range`, and
`gtk_text_view_scroll_to_iter` / `scroll_to_mark` for reveal.

**Distinction flag — this is GTK's version of the known confusion:**
`GtkSearchBar` and `GtkSearchEntry` look like find UI and are not. GTK4 describes
`GtkSearchBar` in one line — "Reveals a search entry when search is started" — and
it is purely container and chrome: reveal animation, Escape to dismiss,
key-capture. It performs **no matching of any kind**, and it attaches to a
`GtkEditable` through `gtk_search_bar_connect_entry()`; there is **no
`GtkTextView` integration whatsoever**
(<https://docs.gtk.org/gtk4/class.SearchBar.html>). A GTK search bar is an empty
frame the app fills with its own logic. Calling it a find bar would be exactly
the error this survey is asked to flag.

**Real app:** GNOME Text Editor implements find itself over
`GtkSourceSearchContext` / `GtkSourceSearchSettings` — which is **GtkSourceView**,
a separate library, out of scope here but telling: GNOME's answer to "plain GTK
has no find" was to put the engine in the *source-editing* library, where it
gained regex, whole-word and occurrence counting
(<https://gitlab.gnome.org/GNOME/gnome-text-editor>).

---

## Jetpack Compose

**Verdict: find UI ABSENT, engine ABSENT, range primitives SHIPPED.**

Checked against the authoritative artifact rather than prose: androidx publishes
its committed public API as signature files. Downloaded from
`androidx-main` and searched:

- `compose/foundation/foundation/api/current.txt` (3195 lines) — **zero**
  `find`-named API. The only `Search` hits are `KeyboardActions.onSearch` and
  `ImeAction.Search` (keyboard button labels).
- `compose/ui/ui-text/api/current.txt` (2177 lines) — **zero** `find` API; the
  only `Search` hits are `ImeAction.Search`.
- `compose/material3/material3/api/current.txt` (5276 lines) — **zero** `find`
  API, and **93** `Search` hits.

(<https://github.com/androidx/androidx/blob/androidx-main/compose/foundation/foundation/api/current.txt>,
<https://github.com/androidx/androidx/blob/androidx-main/compose/material3/material3/api/current.txt>)

**Distinction flag, with hard numbers.** Those 93 Material3 `Search` hits are
`SearchBar`, `SearchBarColors`, `SearchBarDefaults`, `DockedSearchBar`,
`ExpandedFullScreenSearchBar`, `AppBarWithSearch`, `SearchBarScrollBehavior` and
friends. Every one is *app search* — a query field over a data source, with
suggestion surfaces and scroll behavior. Not one of them searches a text widget's
content. Compose has the richest search-*chrome* vocabulary in this survey and no
document find at all. Anyone auditing Compose by keyword will conclude the
opposite of the truth; this is the confusion in its purest form.

Range primitives are complete and are the layer Compose actually ships:

- `TextRange` — an immutable inline value class (`ui-text`), the range type.
- `TextFieldState.selection: TextRange` — settable selection on the modern
  text-field state object.
- `AnnotatedString` + `SpanStyle` — arbitrary-range styling, the mechanism for
  painting matches in read-only text.
- `OutputTransformation` (a `fun interface` on `BasicTextField`) — restyle a
  field's rendered output without changing its stored value; the supported way to
  highlight matches *inside an editable field*.
- `TextLayoutResult.getBoundingBox(offset)` / `getLineForOffset(offset)` —
  geometry for match rectangles.
- `BringIntoViewSpec` / `bringIntoViewRequester` — reveal.

**Real app:** none of the Compose-first Google apps expose document find through
Compose; where Android does ship a find engine it is on `WebView` (below).

### Sidebar — the Android platform's own find, and its retreat

`android.widget.TextView` / `EditText` ship no find of any kind. `WebView` does,
and its history is the single most pointed piece of evidence in this survey.
Read from AOSP `core/java/android/webkit/WebView.java`
(<https://github.com/aosp-mirror/platform_frameworks_base/blob/main/core/java/android/webkit/WebView.java>):

```java
public void findAllAsync(@NonNull String find)        // line 1615
public void findNext(boolean forward)                 // line 1586
public void clearMatches()                            // line 1705
public void setFindListener(@Nullable FindListener l) // line 1570

public interface FindListener {                       // line 169
    public void onFindResultReceived(int activeMatchOrdinal, int numberOfMatches,
        boolean isDoneCounting);
}
```

`findAllAsync` "Finds all instances of find on the page and highlights them,
asynchronously… Successive calls to this will cancel any pending searches."
`findNext` wraps "around page boundaries as necessary." The listener streams
partial counts — `isDoneCounting` marks the final tally.

**Note the option surface: there is none.** `findAllAsync` takes a bare string.
No case flag, no whole-word flag, no regex. Android's shipped find engine is
literal-only.

And the UI was withdrawn:

```java
@Deprecated
public boolean showFindDialog(@Nullable String text, boolean showIme)   // line 1635
```

with the reason stated in the source: *"This method does not work reliably on all
Android versions; implementing a custom find dialog using WebView.findAllAsync()
provides a more robust solution."* (lines 1630–1632)

A platform that shipped both layers deprecated the **bar** and kept the
**engine**, telling every app to build its own bar against the engine. That is a
framework explicitly ruling on kaya's layer-2 question — and ruling against it.
The counter-reading is available too: it withdrew the bar because *that
implementation* was unreliable across versions, not because bars are the app's
job in principle.

---

## React Native

**Verdict: find UI ABSENT, engine ABSENT, range primitives PARTIAL (and absent
for read-only text).** The weakest of every framework surveyed.

Checked the same way as Compose, against the shipped type declarations from
`facebook/react-native` `main`:

- `Libraries/Components/TextInput/TextInput.d.ts` (1050 lines) — **no** find API.
  The seven `search` hits are all keyboard configuration: `'web-search'` keyboard
  type, `inputMode: 'search'`, `ReturnKeyType: 'search'`, `EnterKeyHintType:
  'search'`. Keyboard *button labels*, nothing more.
- `Libraries/Text/Text.d.ts` (217 lines) — **no** find API and, more strikingly,
  no range API at all.

(<https://github.com/facebook/react-native/blob/main/packages/react-native/Libraries/Components/TextInput/TextInput.d.ts>,
<https://github.com/facebook/react-native/blob/main/packages/react-native/Libraries/Text/Text.d.ts>)

`TextInput` has exactly two range affordances:

```ts
/**
 * The start and end of the text input's selection. Set start and end to
 * the same value to position the cursor.
 */
selection?: {start: number; end?: number | undefined} | undefined;   // line 936

/**
 * Sets the start and end positions of text selection.
 */
setSelection: (start: number, end: number) => void;                  // line 1049
```

`<Text>` has **only** `selectable?: boolean` and `selectionColor` — no
programmatic selection, no range addressing, no scroll-to-range, no
arbitrary-range highlight. The only way to color a sub-range of RN text is to
split it into nested `<Text>` children with different styles, i.e. to rebuild the
string as a component tree.

**Real app:** the ecosystem's answer is a userland package —
`react-native-highlight-words` (a wrapper over the `highlight-words-core`
tokenizer) splits a string into matched/unmatched chunks and renders nested
`<Text>` runs (<https://github.com/clauderic/react-native-highlight-words>). That
is the whole find story in React Native: a string-splitting helper in npm, no
framework participation.

---

## Flutter

**Verdict: find UI ABSENT, engine ABSENT, range primitives PARTIAL.**

Flutter ships the range *type* and the selection state, but no matching and no
find surface.

`TextRange` (`dart:ui`) — `start`, `end`, `isValid`, `isCollapsed`,
`isNormalized`, plus `textInside()` / `textBefore()` / `textAfter()`;
`TextSelection` implements it
(<https://api.flutter.dev/flutter/dart-ui/TextRange-class.html>). No find or
search method on either. `TextEditingController.selection` carries the live
selection.

Arbitrary-range highlight has one hook, and it is an override rather than an API:

```dart
TextSpan buildTextSpan({
  required BuildContext context,
  TextStyle? style,
  required bool withComposing,
})
```

"Builds TextSpan from current editing value. By default makes text in composing
range appear as underlined. **Descendants can override this method to customize
appearance of text.**"
(<https://api.flutter.dev/flutter/widgets/TextEditingController/buildTextSpan.html>)

Note what that is: to highlight matches in a Flutter text field you **subclass the
controller** and re-emit the whole document as a styled `TextSpan` tree. There is
no "highlight this range" call. The framework's own documented use of the hook is
the IME composing underline; match highlighting is an unsanctioned reuse that
happens to work.

**The gap is acknowledged and unfunded.** flutter/flutter#65504, "Ctrl+F support,
finding text on a page (even when scrolled off screen)", opened **9 September
2020**, still **open**, labelled `P3`, `c: new feature`, `framework`,
`team-framework`, `triaged-framework` — **no assignee, no milestone**, after five
years (<https://github.com/flutter/flutter/issues/65504>). Related open issues
show the same hole on the web renderer, where Flutter's canvas text is invisible
to the *browser's* find bar (flutter/flutter#72274,
<https://github.com/flutter/flutter/issues/72274>).

**Real app:** Flutter DevTools — itself a Flutter app — implements its own search
infrastructure (a `SearchControllerMixin` with match lists, active-match index and
auto-scroll) inside `devtools_app` rather than getting anything from the framework
(<https://github.com/flutter/devtools>).

---

## Web platform (textarea / contentEditable)

**Verdict: find UI SHIPPED BY THE BROWSER but it does not reach editable fields;
engine ABSENT (non-standard leftover only); range primitives SHIPPED and
excellent.** The most nuanced entry, and the most useful.

### The browser's find bar has a hole exactly where text editing happens

Every browser ships Ctrl+F over rendered DOM text. **It does not search inside
`<textarea>` or `<input>` values.** This is uniform across engines and long
understood: Mozilla bug 58305, "Find in page ignores text fields — does not
search form textarea" (<https://bugzilla.mozilla.org/show_bug.cgi?id=58305>), and
bug 1627643, "searching the page with Ctrl+F can not find value of inputs"
(<https://bugzilla.mozilla.org/show_bug.cgi?id=1627643>).

The stated technical reason matters for kaya, because it is a *structural* reason
rather than an oversight: find-in-page selects matches using `Range` objects over
DOM text nodes; a `<textarea>`'s live content is not in a text node at all — the
node holds only the initial value and is never updated as the user types, only
`textarea.value` changes. Ranges therefore cannot address it, so textareas are
skipped wholesale.

Consequence: **on the web, the platform find bar covers reading and not editing.**
Any web app with a real editor ships its own find no matter what the browser
does. That is the same shape as kaya's situation, and it is the reason the two
dominant web editors both replaced the textarea entirely (below).

### Engine: only a non-standard leftover

```js
find(string, caseSensitive, backwards, wrapAround, wholeWord, searchInFrames, showDialog)
```

`window.find()` exists in every browser and is **not part of the platform**. MDN's
banner, verbatim: *"**Non-standard:** This feature is not standardized. We do not
recommend using non-standard features in production, as they have limited browser
support, and may change or be removed."* Plus a Gecko note that support "might
change in future versions"
(<https://developer.mozilla.org/en-US/docs/Web/API/Window/find>).

Its parameter list is nonetheless a useful data point on dialect: case, backwards,
wrap-around, whole word. No regex. The web's actual search engine is
`String.prototype.indexOf` and `RegExp` — the *language*, not the framework.

### Range primitives: the strongest in the survey

- `Range` / `Selection`, `document.createRange()`,
  `Range.getBoundingClientRect()`, `Element.scrollIntoView()`.
- **CSS Custom Highlight API** — `new Highlight(...ranges)`, the `CSS.highlights`
  registry, and the `::highlight(name)` pseudo-element. It styles arbitrary ranges
  **without modifying the DOM**, which is precisely kaya's layer 0. Status:
  *Baseline 2025 — newly available*, across current browsers since June 2025.

  MDN's canonical example for the whole API **is search highlighting**
  (<https://developer.mozilla.org/en-US/docs/Web/API/CSS_Custom_Highlight_API>):

  ```css
  ::highlight(search-results) {
    background-color: #ff0066;
    color: white;
  }
  ```

  That the platform's newest text feature is a range-highlight primitive whose
  headline use case is find — with no engine and no bar attached — is the single
  cleanest statement in this survey of where a platform draws the line.

- Inside a `<textarea>` the primitives shrink to `setSelectionRange(start, end)`,
  `selectionStart` / `selectionEnd`, and `scrollTop`. **No arbitrary-range
  highlight is possible**, for the same reason find-in-page skips it: a `Range`
  cannot address a form control's value.

  Both halves of that limitation are live, open standards issues, not folklore:
  whatwg/dom#1375, "Make it possible to wrap [parts of] the contents of a
  `<textarea>` or `<input>` in a Range"
  (<https://github.com/whatwg/dom/issues/1375>), and w3c/csswg-drafts#9971,
  "[css-highlight-api] Allow Custom Highlights on `textarea`/`input[type=text]`"
  (<https://github.com/w3c/csswg-drafts/issues/9971>). The web platform knows it
  has this hole and has not closed it.

**Real apps:** CodeMirror and Monaco both abandon `<textarea>` for a
contentEditable/overlay rendering — that substitution is *what buys them* range
highlighting — and both ship their own complete find.

---

## The reference implementation: CodeMirror 6's `@codemirror/search`

Not a general-purpose UI framework, so it is not a row in the table. It earns a
section because it is the one system in this survey that ships **all three
layers** deliberately and separably, and its layer-1 dialect is a near-exact match
for kaya's proposal. Read from source
(<https://github.com/codemirror/search/blob/main/src/search.ts>).

The query object, `search.ts` lines 83–142:

```ts
export class SearchQuery {
  readonly search: string          // The search string (or regular expression).
  readonly caseSensitive: boolean  // Indicates whether the search is case-sensitive.
  readonly literal: boolean        // disables \n \r \t escape expansion in the query
  readonly regexp: boolean         // When true, the search string is interpreted as a regular expression.
  readonly replace: string         // The replace text, or the empty string
  readonly valid: boolean          // non-empty and, for regexp, syntactically valid
  readonly wholeWord: boolean      // matches containing words are ignored when there are further word characters around them
  readonly test: ((match, state, from, to) => boolean) | undefined  // optional filter
}
```

Two details worth carrying into kaya's design:

- `valid` is a *field on the query*, computed once: "non-empty and, in case of a
  regular expression search, syntactically valid." An invalid regex is a
  first-class, inspectable state of the query rather than an exception at search
  time. Any core-owned engine with a regex mode needs this, and it is easy to
  forget until the find bar has to grey something out.
- `literal` is not what it sounds like. It does not mean "not regex" — `regexp` is
  the separate flag. `literal: true` disables expanding `\n` / `\r` / `\t` in the
  query into real control characters. So plain string search *still* has an
  escape layer by default. A cross-language framework that byte-compares expected
  strings has to decide this explicitly, in one place, or eight bindings will
  decide it eight ways.

The command surface, all exported separately from the panel:
`findNext`, `findPrevious`, `selectMatches`, `selectSelectionMatches`,
`replaceNext`, `replaceAll`, `openSearchPanel`, `closeSearchPanel`, plus
`setSearchQuery` / `getSearchQuery` / `searchPanelOpen` and a `searchKeymap`.

And the layer-2 answer — **ship a bar, but make it replaceable**
(`interface SearchConfig`, lines 16–58):

```ts
top?: boolean            // panel at top or bottom
caseSensitive?: boolean  // defaults for the query the panel opens with
literal?: boolean
wholeWord?: boolean
regexp?: boolean
createPanel?: (view: EditorView) => Panel      // "override the way the search panel is implemented"
scrollToMatch?: (range: SelectionRange, view: EditorView) => StateEffect<unknown>
```

`createPanel` lets an app substitute its own bar while keeping the engine,
commands and state; the contract for a replacement panel is spelled out in the
doc comment (show the current query, update it via `setSearchQuery`, react to
external query changes, run the commands, and tag the initial-focus field with
`main-field=true`). `scrollToMatch` overrides reveal. This is the design that
answers "framework or app?" with *both*, at a defined boundary — the most
directly applicable precedent in the report.

---

## Dialect comparison: what shipped engines actually match on

Every framework in this survey that ships a matching engine, side by side. This is
the evidence bearing on kaya's layer-1 dialect and on the maintainer's ruling out
of backreferences and lookaround.

| Engine | Case | Whole word | Direction | Regex | Other |
| --- | --- | --- | --- | --- | --- |
| AppKit `NSTextFinder` | yes (`NSTextFinderCaseInsensitiveKey`) | yes (`MatchingTypeFullWord`) | via actions | **no** | `StartsWith`, `EndsWith`, `Contains` |
| UIKit `UITextSearchOptions` | via `NSString.CompareOptions` | yes (`WordMatchMethod`) | via `findNext`/`findPrevious` | **yes, incidentally** — `.regularExpression` is a bit in the general compare-options mask | diacritic-insensitive etc. from the same mask |
| Qt `QTextDocument::FindFlags` | yes (`FindCaseSensitively`) | yes (`FindWholeWords`) | yes (`FindBackward`) | **yes** (`QRegularExpression`, PCRE2 — so backrefs and lookaround) | — |
| WPF `TextFindEngine` (internal) | yes (`MatchCase`) | yes (`FindWholeWordsOnly`) | yes (`FindInReverse`) | **no** | `MatchDiacritics`, `MatchKashida`, `MatchAlefHamza` |
| Win32 TOM `ITextRange::FindText` (the layer underneath WinUI) | yes (`tomMatchCase`) | yes (`tomMatchWord`) | yes (negative `Count`) | **yes** (`tomMatchPattern`) | Word-style `^p` special characters |
| WinUI `Microsoft.UI.Text.FindOptions` | yes (`Case`) | yes (`Word`) | yes (negative `scanLength`) | **no — `tomMatchPattern` deliberately not projected** | — |
| GTK4 `GtkTextSearchFlags` | yes (`CASE_INSENSITIVE`) | **no** | separate `backward_search` | **no** | `VISIBLE_ONLY`, `TEXT_ONLY` |
| Android `WebView.findAllAsync` | **no** | **no** | `findNext(forward)` | **no** | nothing — bare string |
| `window.find()` (non-standard) | yes | yes | yes | **no** | wrap-around, frames |
| CodeMirror `SearchQuery` | yes | yes | via commands | **yes** (JS `RegExp` — backrefs and lookahead) | `literal`, `replace`, `test` filter |

Readings that bear on the decision:

1. **Case and whole-word are the universal floor.** Seven of nine have both; the
   two that lack whole-word (GTK, Android) are the two thinnest engines in the
   set, and GTK's omission is why every GTK editor of consequence uses
   GtkSourceView instead.
2. **Regex is the dividing line, and it splits by lineage.** The engines that
   ship it are the ones built on a general regex library the framework already
   carried (Qt/PCRE2, CodeMirror/JS `RegExp`), plus one exposing it as a bit in a
   general string-comparison mask (UIKit), plus the 1990s-era Win32 TOM.
   **Every engine written from scratch as a find engine — AppKit, WPF, WinUI,
   GTK, Android — ships literal matching only.** No shipped find *UI* in this
   survey exposes a regex toggle.
3. **The clearest single data point is Microsoft's, and it cuts toward
   restriction.** The Win32 TOM has had `tomMatchPattern` — "Matches regular
   expressions" — since the RichEdit era. When Microsoft projected that same API
   into WinRT for modern Windows apps, it kept `Word` and `Case` and **dropped the
   regex flag**. That is a framework team, holding a working regex find engine,
   deciding a modern find surface should not expose it. Nothing else in this
   survey is that direct a precedent for narrowing.
4. **But nobody ships a *restricted* regex.** Relevant to the specific ruling
   against backreferences and lookaround: there is no precedent here for a
   deliberately-limited dialect. Frameworks either hand over a complete engine
   (PCRE2, `RegExp`, `tomMatchPattern`) or offer none at all. kaya's position —
   regex present, backreferences and lookaround excluded — is novel among these
   systems. That is not an argument against it: a linear-time-guaranteed dialect
   is a well-understood engineering choice, and the requirement that eight
   language bindings agree on every match is a far stronger reason to want one
   than any single-language framework here ever had. It does mean the dialect
   **cannot be borrowed** — it has to be specified in kaya's own spec and
   conformance-tested per binding, because no existing engine implements exactly
   it and no two host regex libraries agree once you leave the common subset.

---

## Summary table

| Framework | Find UI | Engine hook | Range primitives |
| --- | --- | --- | --- |
| **AppKit** (NSTextView / NSTextFinder) | **shipped** — `usesFindBar` / `usesFindPanel`, one Bool | **shipped** — `NSTextFinder` + 13 actions, literal only | **shipped** — `NSTextFinderClient`: `selectedRanges`, `scrollRangeToVisible:`, `rectsForCharacterRange:`, `showFindIndicatorForRange:` |
| **UIKit** (iOS 16+) | **shipped** — `UIFindInteraction`, `isFindInteractionEnabled` | **shipped** — `UITextSearching` + `UITextSearchOptions` | **shipped** — search-session range protocol |
| **SwiftUI** | **shipped, partial** — `findNavigator(isPresented:)`; iOS 16 but macOS **26** | **absent** — no programmatic match access | **absent** on `TextEditor` |
| **Qt Widgets** | **absent** | **shipped** — `find()` on widget + 4 `QTextDocument::find` overloads; case / whole-word / backward / `QRegularExpression` | **shipped** — `ExtraSelection`, `QTextCursor`, `ensureCursorVisible`, `centerCursor` |
| **Qt QML** | **absent** | **absent from QML** (reachable in C++ via `textDocument`) | **shipped** — `select()`, `selectionStart/End`, `positionAt`, `positionToRectangle` |
| **WPF** | **partial** — `FlowDocumentReader.IsFindEnabled` (default `true`) and the viewers; **nothing for TextBox/RichTextBox** | **internal only** — `internal static class TextFindEngine`; complete and public to nobody | **shipped** — `TextPointer`/`TextRange`, `Select`, `ApplyPropertyValue`, `BringIntoView` |
| **WinUI 3** | **absent** (`AutoSuggestBox` is app search) | **shipped, narrow** — `ITextRange.FindText(value, scanLength, options)`; `None`/`Word`/`Case`; **RichEditBox only** | **shipped** — `GetRange`, `ScrollIntoView`; plain `TextBox` only `Select` |
| **GTK4** (no GtkSourceView) | **absent** (`GtkSearchBar` is chrome, no matching, no `GtkTextView` link) | **shipped, thinnest** — `gtk_text_iter_forward/backward_search`; case-insensitive only, **no whole-word**, no regex | **shipped** — `GtkTextMark`/`Iter`, `apply_tag`, `select_range`, `scroll_to_iter` |
| **Jetpack Compose** | **absent** — 0 find API; 93 Material3 `Search*` symbols are all app search | **absent** | **shipped** — `TextRange`, `TextFieldState.selection`, `AnnotatedString`+`SpanStyle`, `OutputTransformation`, `TextLayoutResult.getBoundingBox`, `BringIntoView` |
| *(Android platform sidebar:* `WebView`*)* | *withdrawn — `showFindDialog` deprecated* | *shipped — `findAllAsync` / `findNext` / `FindListener`; bare string, no options* | *engine-internal highlighting only* |
| **React Native** | **absent** | **absent** | **partial** — `TextInput.selection` / `setSelection` only; `<Text>` has **none** |
| **Flutter** | **absent** — #65504 open since 2020, P3, unassigned | **absent** | **partial** — `TextRange`/`TextSelection` yes; highlight only by overriding `buildTextSpan` |
| **Web platform** | **shipped by the browser, but blind to `<textarea>`/`<input>` values** | **absent** — only non-standard `window.find()` | **shipped, best-in-class** — `Range`, `Selection`, `scrollIntoView`, CSS Custom Highlight API (Baseline 2025); **but none of it reaches inside a `<textarea>`** |
| *(reference: CodeMirror 6)* | *shipped **and** replaceable via `createPanel`* | *shipped — `SearchQuery`: case / wholeWord / regexp / literal / replace / test* | *shipped, incl. `scrollToMatch` override* |

---

## Verdict

**Layer 0 (range primitives) — universal. Not a decision.** Every framework
surveyed ships range addressing, and it is the *only* layer all of them ship.
Where it is weak the whole story collapses: React Native's `<Text>` has no range
API and its find story is an npm string-splitter; a `<textarea>` cannot be
range-highlighted and so every serious web editor threw the textarea away. The
platform's newest text API — CSS Custom Highlight, Baseline 2025 — is exactly
this layer and nothing more, with find as its documented headline use case. The
prior agreement that layer 0 is necessary is the best-supported conclusion in
this report.

**Layer 1 (core-owned engine) — the majority position, with a specific warning
about dialect.** Six of nine general-purpose frameworks ship a matching engine:
AppKit, UIKit, Qt (twice over), WPF (internally), WinUI, GTK, plus Android's
WebView. The four that ship nothing — SwiftUI, Compose, React Native, Flutter —
are, without exception, the *declarative* frameworks, and it costs them: Flutter's
request has sat open and unassigned for five years, and Qt's own declarative layer
lost the engine its widget layer ships. If kaya wants find to work the same way in
eight languages, an engine in the core is the only way that invariant survives —
`String.indexOf` and each host's regex library will not agree, and per-binding
implementations are exactly the divergence kaya's uniform-semantics rule exists to
prevent.

On dialect the evidence is friendlier to the maintainer's ruling than expected.
Literal / case / whole-word is a floor everyone converges on. Regex is not: every
purpose-built find engine here ships without it, and Microsoft — holding a regex
find that already worked (`tomMatchPattern`) — deliberately declined to project it
into the modern WinRT surface. Omitting or restricting regex is a mainstream
choice, not a compromise.

The narrow warning is that **no surveyed system ships a *restricted* regex
dialect**. Everyone either hands over a complete engine or offers none. Excluding
backreferences and lookaround is defensible on its own merits, but it cannot be
borrowed from anyone here — it has to be specified in kaya's spec and
conformance-tested per binding, or the eight bindings will disagree at the edges
of whatever each host's regex library happens to do. Two concrete details worth
stealing from CodeMirror regardless: make query *validity* an inspectable field
rather than a throw, and decide escape-expansion (`\n`, `\t` in a literal query)
once, in the spec, not eight times.

**Layer 2 (ready-made find bar) — genuinely contested, and the survey does not
settle it.** The split is real and it is not random:

- *For shipping a bar:* AppKit and UIKit reduce the entire feature to one Boolean
  on the widget, which is a quality bar no app-built solution reaches. WPF turns
  find on **by default** (`IsFindEnabled` defaults to `true`) for its document
  viewers. Browsers ship find without asking.
- *Against:* Android shipped a find dialog and **deprecated it**, in-source, in
  favor of "implementing a custom find dialog using `WebView.findAllAsync()`".
  Qt, WinUI, GTK and Compose ship engines or primitives and no bar at all.
- *The distinction that must not be muddled:* Compose's 93 `Search*` symbols,
  WinUI's `AutoSuggestBox` and GTK's `GtkSearchBar` are **app search**, not
  document find. GTK's search bar performs no matching whatsoever and cannot even
  attach to a `GtkTextView`. Any survey done by keyword will read these as find
  bars and conclude the opposite of the truth.

The resolution the evidence actually points at is CodeMirror's, and secondarily
AppKit's: **ship the bar, but do not weld it on.** CodeMirror ships a default
panel plus `createPanel` to replace it and `scrollToMatch` to override reveal,
with the engine, commands and query state all exported independently. AppKit
reaches the same place differently — the bar is built by the finder but *hosted*
by whatever implements `NSTextFinderBarContainer`. Both let the 90% case be one
flag and the 10% case be the app's own chrome, without forking the engine. Given
kaya's shared-scene-scripts and byte-compared-output constraints, a default bar
is also the only way the *strings* stay identical across eight languages — an app-built
bar per language is eight chances to diverge on "3 of 17" versus "3/17".

One last caution from the SwiftUI row, since kaya's mac and iOS arms are one
SwiftUI interpreter: SwiftUI's `findNavigator` is iOS 16 but **macOS 26**, and its
target when several editors are present is documented as *nondeterministic*. A
declarative find bar addressed by ambient lookup is ambiguous the moment there are
two text widgets on screen. Whatever kaya ships at layer 2 should name its target
explicitly rather than inferring it from the view tree.

---

## Sources

All URLs cited inline above. The load-bearing primary sources:

- `NSTextFinder.h`, macOS 26.5 SDK, read locally at
  `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk/System/Library/Frameworks/AppKit.framework/Versions/C/Headers/NSTextFinder.h`
  (public mirror: <https://developer.apple.com/documentation/appkit/nstextfinder>)
- <https://developer.apple.com/documentation/appkit/nstextview/usesfindbar>
- <https://developer.apple.com/documentation/uikit/uifindinteraction>
- <https://developer.apple.com/documentation/uikit/uitextsearchoptions>
- <https://developer.apple.com/documentation/swiftui/view/findnavigator(ispresented:)>
- <https://doc.qt.io/qt-6/qtextdocument.html>, <https://doc.qt.io/qt-6/qtextedit.html>,
  <https://doc.qt.io/qt-6/qplaintextedit.html>, <https://doc.qt.io/qt-6/qml-qtquick-textedit.html>
- <https://learn.microsoft.com/en-us/dotnet/api/system.windows.controls.flowdocumentreader.isfindenabled>
- <https://github.com/dotnet/wpf/blob/main/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Documents/TextFindEngine.cs>
  (and `PresentationUI/MS/Internal/Documents/FindToolBar.xaml.cs`, located by code search)
- <https://learn.microsoft.com/en-us/uwp/api/windows.ui.text.itextrange.findtext>,
  <https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.text.findoptions>,
  <https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.richeditbox.document>,
  <https://learn.microsoft.com/en-us/windows/win32/api/tom/nf-tom-itextrange-findtext> (the `tomMatchPattern` comparison)
- <https://docs.gtk.org/gtk4/method.TextIter.forward_search.html>,
  <https://docs.gtk.org/gtk4/flags.TextSearchFlags.html>,
  <https://docs.gtk.org/gtk4/class.SearchBar.html>
- androidx API signature files on `androidx-main`:
  `compose/foundation/foundation/api/current.txt`,
  `compose/material3/material3/api/current.txt`,
  `compose/ui/ui-text/api/current.txt`
- <https://github.com/aosp-mirror/platform_frameworks_base/blob/main/core/java/android/webkit/WebView.java>
- `facebook/react-native` `Libraries/Components/TextInput/TextInput.d.ts`,
  `Libraries/Text/Text.d.ts`
- <https://api.flutter.dev/flutter/dart-ui/TextRange-class.html>,
  <https://api.flutter.dev/flutter/widgets/TextEditingController/buildTextSpan.html>,
  <https://github.com/flutter/flutter/issues/65504>
- <https://developer.mozilla.org/en-US/docs/Web/API/CSS_Custom_Highlight_API>,
  <https://developer.mozilla.org/en-US/docs/Web/API/Window/find>,
  <https://bugzilla.mozilla.org/show_bug.cgi?id=58305>,
  <https://github.com/whatwg/dom/issues/1375>,
  <https://github.com/w3c/csswg-drafts/issues/9971>
- <https://github.com/codemirror/search/blob/main/src/search.ts>
