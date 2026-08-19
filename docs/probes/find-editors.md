# Where full find/replace actually lives — editor-component survey

Research arm for kaya's find milestone. Question served: what belongs in the
framework — (0) text-range primitives on the text widgets, (1) a core-owned
search engine, (2) a ready-made find bar — vs what apps build. Evidence only;
the decision is not mine.

Every claim below is cited. Where a summary came from a rendered doc page
rather than source, I say so; where I read the source directly, the line
numbers are real.

---

## 0. Verdict up front

**Find UI is almost never a framework feature. It is an editor-component
feature, and even there the engine and the bar are separate layers.**

Of the nine things surveyed, exactly two ship a find bar you can turn on with
one call (AvalonEdit's `SearchPanel.Install`, CodeMirror's `search()`), and one
of those two ships it *without replace*. Everything else ships an engine and
lets the app draw the bar — including Electron, which is what most desktop
"apps with a find bar" actually are. Apple is the sole framework-integrated
case, and its design is the most interesting one for kaya: **the framework owns
the bar and the app owns the matching** (`UIFindInteraction` + `UITextSearching`).

The dialect question has a decisive exhibit. VS Code runs two regex engines —
JavaScript `RegExp` in the editor, Rust `regex` via ripgrep across files — and
had to define its supported dialect as the *intersection of the two* and say so
in release notes. That is the failure kaya's "one dialect everywhere" rule
exists to prevent, observed in the wild at Microsoft scale.

Replace-all as one undo step is universal and unanimous, and it comes with a
second half nobody advertises: **you must also suspend the engine's own
change-tracking for the duration**, or it re-scans per edit. Monaco and
GtkSourceView arrived at that independently.

---

## 1. Comparison table

| Component | Ships find UI? | Ships engine? | API shape | Regex dialect / engine | Replace? | Replace-all = one undo step? |
|---|---|---|---|---|---|---|
| **Monaco / VS Code** | Yes, as a separable `contrib` | Yes, on the document model | **Methods on `ITextModel`** — `findMatches(...)`, `findNextMatch`, `findPreviousMatch`. No search object. | JavaScript `RegExp` in the editor; **Rust `regex` (ripgrep) across files**, opt-in PCRE2 | Yes, incl. `preserveCase` and `$1` templates | **Yes, explicitly** — `pushUndoStop()` … `executeCommand` … `pushUndoStop()` |
| **CodeMirror 6** | Yes, `@codemirror/search`, panel replaceable via `createPanel` | Yes, same package, usable alone | **Query value object + commands + cursors** — `SearchQuery`, `findNext`, `replaceAll`, `SearchCursor`/`RegExpCursor` | JavaScript `RegExp` | Yes | **Yes** — one `view.dispatch({changes, …})` |
| **Scintilla** | **No UI at all** | Yes, minimal | **Flat message API over a "target" range** — `SCI_SETTARGETRANGE` / `SCI_SEARCHINTARGET` / `SCI_REPLACETARGET(RE)` | Own tiny engine, single-line only; **`SCFIND_CXX11REGEX` switches to C++11 `<regex>`** — a dialect switch as a search flag | Yes, `\1`–`\9` in the replacement | Host's job: `SCI_BEGINUNDOACTION` / `SCI_ENDUNDOACTION`, nestable |
| **GtkSourceView 4/5** | **No UI** (gedit, Builder each draw their own) | Yes, async, buffer-scoped | **Two objects** — a detachable `SearchSettings` property bag + a `SearchContext(buffer, settings)` | **PCRE2**, linked directly via GtkSourceView's own `ImplRegex`, keeping GRegex's flag names | Yes, backreferences in the template | **Yes** — `begin_user_action` … loop … `end_user_action` |
| **AvalonEdit (WPF)** | **Yes** — `SearchPanel.Install(editor)`, lives in the adorner layer | Yes, swappable behind `ISearchStrategy` | **One-line install on the widget** + dependency properties `SearchPattern`, `MatchCase`, `UseRegex`, `WholeWords` | .NET `System.Text.RegularExpressions`, `Compiled \| Multiline` | **No — the shipped panel has no replace** | N/A (`UndoStack.StartUndoGroup()` / `EndUndoGroup()` exist for the app) |
| **AppKit `NSTextView` + `NSTextFinder`** | **Yes — the framework's own find bar** | Yes (opaque) | **Controller + client protocol** — `NSTextFinder` drives, `NSTextFinderClient` supplies content; menu items send `performTextFinderAction(_:)` | Not exposed. Literal matching. | Yes (`.replace`, `.replaceAll`, `.replaceAllInSelection`) | Not documented at the API surface |
| **SwiftUI `TextEditor`** | **Yes, built in** | Yes (opaque) | **View modifiers** — `.findNavigator(isPresented:)`, `.findDisabled()`, `.replaceDisabled()`; `@Environment(\.findContext)` for custom views | Not exposed | Yes | Not documented |
| **UIKit `UITextView` + `UIFindInteraction`** | **Yes — one property, `isFindInteractionEnabled`** | **No — the app supplies it** via `UITextSearching` | **Interaction object + searchable-content protocol.** Framework owns the bar, app owns `performTextSearch(queryString:options:resultAggregator:)` | **No regex.** `UITextSearchOptions` = `wordMatchMethod` (`.contains`/`.startsWith`/`.fullWord`) + `NSString.CompareOptions` | Yes — `supportsTextReplacement`, `replaceAll(queryString:options:withText:)` | App's job (it performs the edits) |
| **Electron / Chromium `webContents`** | **No UI** — VS Code, Slack, Discord each draw one | Yes, async page-level service | **Request + event on the page object**, not on any widget: `findInPage(text, opts)` → `'found-in-page'` | **No regex, no whole-word.** `matchCase` only. | **No replace** | N/A |

---

## 2. Per-component detail

### 2.1 GtkSourceView 4/5 — `GtkSourceSearchContext` + `GtkSourceSearchSettings`

**Engine only, no UI.** Plain GTK `GtkTextView` has no find at all.

API shape: **two objects, settings separated from execution.**

- `GtkSourceSearchSettings` — a property bag with no buffer attached:
  `search-text`, `case-sensitive`, `at-word-boundaries`, `wrap-around`,
  `regex-enabled`, `visible-only` (5.12+).
  <https://gnome.pages.gitlab.gnome.org/gtksourceview/gtksourceview5/class.SearchSettings.html>
- `GtkSourceSearchContext` — binds one settings object to one buffer:
  `new(buffer, settings)`, `forward()` / `forward_async()` / `forward_finish()`,
  `backward()` / …, `replace()`, `replace_all()`, `get_occurrences_count()`,
  `get_occurrence_position()`, `get_regex_error()`, `set_highlight()`,
  `set_match_style()`.
  <https://gnome.pages.gitlab.gnome.org/gtksourceview/gtksourceview5/class.SearchContext.html>

Three choices worth stealing or rejecting deliberately:

1. Settings are detachable, so one settings bag can drive several buffers — the
   multi-document case falls out of the shape rather than being bolted on.
2. Search is modelled as a **background job, not a call**. "The buffer is
   scanned asynchronously, so it doesn't block the user interface. For each
   search, the buffer is scanned at most once." `occurrences-count` reads `-1`
   until the scan finishes.
3. **Match highlighting belongs to the engine**, not the app —
   `set_highlight()`, `set_match_style()`.

Dialect: **PCRE2, linked directly.** GtkSourceView 5 wraps it in its own
`ImplRegex` (`implregex.c` lines 48–49: `#define PCRE2_CODE_UNIT_WIDTH 8` /
`#include <pcre2.h>`) while keeping GRegex's flag vocabulary as the API
(`G_REGEX_CASELESS` → `PCRE2_CASELESS`, etc.). So backreferences and lookaround
are IN — the two things kaya has ruled out.
Search compiles with `G_REGEX_MULTILINE` (+ `G_REGEX_CASELESS` when not
case-sensitive) and matches with `G_REGEX_MATCH_NOTEMPTY`
(`gtksourcesearchcontext.c` lines 2381–2399).

**Whole-word in regex mode is textual pattern surgery**, and it is a trap:

```c
pattern = g_strdup_printf ("\\b%s\\b", search_text);   /* line 2393 */
```

The user's pattern is not parenthesized, so `at-word-boundaries` + the pattern
`foo|bar` compiles to `\bfoo|bar\b`, which is not what anyone means. kaya should
decide this deliberately rather than inherit it.

**Replace-all is one undo step, and does four other things** —
`gtksourcesearchcontext.c` lines 3783–3829:

```c
g_signal_handlers_block_by_func (search->buffer, insert_text_before_cb, search);
g_signal_handlers_block_by_func (search->buffer, insert_text_after_cb,  search);
g_signal_handlers_block_by_func (search->buffer, delete_range_before_cb, search);
g_signal_handlers_block_by_func (search->buffer, delete_range_after_cb,  search);
…
gtk_source_buffer_set_highlight_matching_brackets (…, FALSE);
_gtk_source_buffer_save_and_clear_selection (…);
gtk_text_buffer_begin_user_action (search->buffer);
while (smart_forward_search (search, &iter, &match_start, &match_end)) { … }
gtk_text_buffer_end_user_action (search->buffer);
_gtk_source_buffer_restore_selection (…);
```

So: one undo group, **its own change-tracking signals blocked**, bracket
highlighting off, selection saved and restored. Also note `has_regex_references`
— `g_regex_check_replacement()` is called once up front, and each match takes
the cheap `delete`+`insert` path unless the template actually has backreferences
(lines 3772–3813). Same instinct as Monaco's `captureMatches`.

Source read directly:
<https://gitlab.gnome.org/GNOME/gtksourceview/-/blob/master/gtksourceview/gtksourcesearchcontext.c>,
<https://gitlab.gnome.org/GNOME/gtksourceview/-/blob/master/gtksourceview/implregex.c>

### 2.2 Monaco / VS Code — engine on `ITextModel`, UI in a contrib

**Both, in separate layers.** The engine is on the document model; the find
widget is `src/vs/editor/contrib/find/browser/` and can be dropped from a
custom build.

```ts
findMatches(searchString: string, searchScope: IRange | IRange[],
            isRegex: boolean, matchCase: boolean,
            wordSeparators: string | null, captureMatches: boolean,
            limitResultCount?: number): FindMatch[]
findNextMatch(…) / findPreviousMatch(…)
```

<https://github.com/microsoft/vscode/blob/main/src/vs/monaco.d.ts>

Shape details kaya should notice:

- **Whole-word is not a boolean.** It is `wordSeparators: string | null` — the
  caller passes the separator set, `null` means "don't restrict". Word-ness is
  the caller's decision. `findModel.ts:512` passes
  `this._state.wholeWord ? this._editor.getOption(EditorOption.wordSeparators) : null`.
- **`captureMatches` is opt-in per call**, and only requested when the
  replacement template needs groups (`findModel.ts:575`).
- **`limitResultCount` is in the signature.** `MATCHES_LIMIT = 19999`
  (`findModel.ts:81`) caps both the decoration set and the "regular" replace
  path; above it, replace-all switches to a whole-document `String.replace`
  (`_largeReplaceAll`). `RESEARCH_DELAY = 240` ms debounces re-search after an
  edit.

**Replace-all undo grouping, verbatim** (`findModel.ts:610–619`):

```ts
private _executeEditorCommand(source: string, command: ICommand): void {
    try {
        this._ignoreModelContentChanged = true;
        this._editor.pushUndoStop();
        this._editor.executeCommand(source, command);
        this._editor.pushUndoStop();
    } finally {
        this._ignoreModelContentChanged = false;
    }
}
```

Two `pushUndoStop()` calls — one **before** and one **after** — so the batch is
fenced on both sides and adjacent typing cannot merge into it. Plus
`_ignoreModelContentChanged`, the same "suspend my own reaction" move
GtkSourceView makes with signal blocking. The edits themselves are one
`ReplaceAllCommand` carrying every range and every replacement string
(`findModel.ts:582`); selection preservation is a named concern
(`ReplaceCommandThatPreservesSelection`, line 568).

**The dialect-divergence exhibit.** VS Code runs two engines and it is
user-visible:

- Editor find: JavaScript `RegExp`.
- Search across files: ripgrep, whose default is the Rust `regex` crate, which
  "lacks several features that are not known how to implement efficiently. This
  includes, but is not limited to, look-around and backreferences", in exchange
  for worst-case `O(m*n)`. <https://docs.rs/regex/latest/regex/>
- VS Code 1.29 added `"search.usePCRE2": true` to get backreferences and
  lookahead — with the caveat, quoted from the release notes: "we only support
  regex expressions that are still valid in JavaScript, because open editors are
  still searched using the editor's JavaScript-based search."
  <https://code.visualstudio.com/updates/v1_29>

Microsoft, one product, two engines, ended up defining the supported dialect as
the **intersection** and documenting it in release notes. That is the whole
argument for kaya owning one matcher.

### 2.3 CodeMirror 6 — `@codemirror/search`

**Both**, as one optional package. `search()` installs the panel; the engine is
usable without it. <https://codemirror.net/docs/ref/>

`SearchQuery` is a value object with doc-commented fields (`search.ts:83–142`):
`search`, `caseSensitive`, `literal`, `regexp`, `replace`, `wholeWord`, `valid`,
plus a `test` predicate for custom filtering. Note `valid`: "Whether this query
is non-empty and, in case of a regular expression search, syntactically valid" —
pattern validity is a **property of the query**, computed once, not an exception
thrown at search time.

The `literal` flag documents a subtlety kaya will hit:

> "By default, string search will replace `\n`, `\r`, and `\t` in the query with
> newline, return, and tab characters. When this is set to true, that behavior
> is disabled."

So "literal search" has three tiers in practice — raw literal,
escape-processed literal, and regex.

**Replace-all is one transaction** (`search.ts:536–550`):

```ts
export const replaceAll = searchCommand((view, {query}) => {
  if (view.state.readOnly) return false
  let changes = query.matchAll(view.state, 1e9)!.map(match => {
    let {from, to} = match
    return {from, to, insert: query.getReplacement(match)}
  })
  if (!changes.length) return false
  let announceText = view.state.phrase("replaced $ matches", changes.length) + "."
  view.dispatch({ changes, effects: EditorView.announce.of(announceText),
                  userEvent: "input.replace.all" })
  return true
})
```

One `dispatch` = one transaction = one undo step. Two things beyond that:

- **Accessibility is the bar's job.** `EditorView.announce.of("replaced N
  matches")` on replace-all, and `announceMatch(view, next)` on every
  find-next, which slices out the surrounding text and announces it
  (`search.ts:766–780`). An app-built bar routinely forgets this; kaya has an
  a11y milestone already landed and would inherit the obligation.
- **`userEvent: "input.replace.all"` vs `"input.replace"`** — the transaction is
  tagged with what caused it, which is how other extensions decide whether to
  react.

The panel is replaceable, not just present: `search({createPanel, scrollToMatch,
top, caseSensitive, literal, wholeWord})`. Both the bar *and* the reveal
behaviour are injection points.

### 2.4 Scintilla — engine only, deliberately small

**No UI whatsoever.** SciTE, Notepad++ and every other host build their own
dialog. <https://www.scintilla.org/ScintillaDoc.html>

API shape: **flat message API over a mutable "target" range** — the closest
analogue in this survey to a C floor.
`SCI_SETTARGETRANGE` / `SCI_SEARCHINTARGET` (returns position or −1) /
`SCI_REPLACETARGET` / `SCI_REPLACETARGETRE`, plus stateless `SCI_FINDTEXT` and
anchored `SCI_SEARCHANCHOR` + `SCI_SEARCHNEXT` / `SCI_SEARCHPREV`.
Flags: `SCFIND_MATCHCASE`, `SCFIND_WHOLEWORD`, `SCFIND_WORDSTART`,
`SCFIND_REGEXP`, `SCFIND_POSIX`, `SCFIND_CXX11REGEX`.

Scintilla is the one that admits the dialect problem out loud:

> "The base regular expression support is limited and should only be used for
> simple cases and initial development. The C++ runtime `<regex>` library may be
> used by setting the `SCFIND_CXX11REGEX` search flag. … A different regular
> expression library can be integrated into Scintilla or can be called from the
> container using direct access to the buffer contents through
> `SCI_GETCHARACTERPOINTER`."

and

> "Regular expressions will only match ranges within a single line, never
> matching over multiple lines. When using `SCFIND_CXX11REGEX` more features are
> available, generally similar to regular expression support in JavaScript."

**A dialect switch exposed as a search flag** — the same query string means two
different things depending on a bit. This is precisely the shape kaya is trying
to avoid across five platforms; Scintilla shows it happening inside one
component.

Undo grouping is generic and nestable:

> "Sequences of actions can be combined into transactions that are undone as a
> unit. These sequences occur between `SCI_BEGINUNDOACTION` and
> `SCI_ENDUNDOACTION` messages. These transactions can be nested and only the
> top-level sequences are undone as units."

The nesting rule answers a question kaya will hit: what happens if something
inside a replace-all opens its own group.

### 2.5 AvalonEdit (WPF) — ships a bar, and it has no replace

**Find UI + a pluggable engine. No replace.** Verified against the tree:
`ICSharpCode.AvalonEdit/Search/` contains `SearchPanel.cs`, `SearchPanel.xaml`,
`ISearchStrategy.cs`, `RegexSearchStrategy.cs`, `SearchStrategyFactory.cs`,
`SearchCommands.cs`, `SearchResultBackgroundRenderer.cs`, `DropDownButton.*`,
`Localization.cs`.
<https://github.com/icsharpcode/AvalonEdit/tree/master/ICSharpCode.AvalonEdit/Search>

`SearchPanel`'s public methods are `Install(TextEditor)`, `Install(TextArea)`,
`RegisterCommands`, `Uninstall`, `OnApplyTemplate`, `Reactivate`, `FindNext`,
`FindPrevious`, `Close`, `Open`, `OnSearchOptionsChanged`. The strings
"Replace", "ReplaceAll", "UndoStack" and "BeginUndoGroup" appear **nowhere** in
the file. ILSpy and SharpDevelop build replace themselves; AvaloniaEdit added it
downstream.

API shape: **one-line installation on the widget** — `SearchPanel.Install(editor)`
— after which the panel lives in the WPF **adorner layer** over the text area,
driven by dependency properties `SearchPattern`, `MatchCase`, `UseRegex`,
`WholeWords`. This is the closest thing in the survey to "turn the framework's
find bar on with one property", which is roughly kaya's candidate layer 2.

Engine swappable behind `ISearchStrategy`:
`FindAll(ITextSource document, int offset, int length) -> IEnumerable<ISearchResult>`
and `FindNext(…) -> ISearchResult`.

`SearchStrategyFactory.Create(pattern, ignoreCase, matchWholeWords, mode)`
compiles **all three modes down to one engine**, .NET
`System.Text.RegularExpressions` with `RegexOptions.Compiled | RegexOptions.Multiline`
(plus `IgnoreCase`): `SearchMode.Normal` escapes with `Regex.Escape`,
`SearchMode.Wildcard` rewrites `?` → `.` and `*` → `.*`, `RegEx` passes through.
One code path, three user-facing modes.
<https://github.com/icsharpcode/AvalonEdit/blob/master/ICSharpCode.AvalonEdit/Search/SearchStrategyFactory.cs>

**Whole-word is not `\b`.** `RegexSearchStrategy` filters candidate matches
through `IsWordBorder()`, which calls
`TextUtilities.GetNextCaretPosition(…, CaretPositioningMode.WordBorder)` — word
boundaries come from the *document's own caret-movement rules*, so find agrees
with double-click-to-select-word. Same instinct as Monaco's `wordSeparators`,
opposite implementation, and a third answer versus GtkSourceView's `\b…\b` wrap.
<https://github.com/icsharpcode/AvalonEdit/blob/master/ICSharpCode.AvalonEdit/Search/RegexSearchStrategy.cs>

For the record, the grouping primitive an app would use here is
`UndoStack.StartUndoGroup()` / `StartUndoGroup(object groupDescriptor)` /
`StartContinuedUndoGroup(...)` / `EndUndoGroup()`
(`ICSharpCode.AvalonEdit/Document/UndoStack.cs`, lines 182–226).

### 2.6 Electron / Chromium — `webContents.findInPage`, the page-level service

**Engine as an asynchronous page-level service; the UI is the app's.** Electron
ships no find bar — VS Code, Slack and Discord each draw one.

```js
const id = contents.findInPage(text, { forward, findNext, matchCase })
contents.stopFindInPage('clearSelection' | 'keepSelection' | 'activateSelection')
contents.on('found-in-page', (event, result) => …)
// result: { requestId, activeMatchOrdinal, matches, selectionArea, finalUpdate }
```

<https://www.electronjs.org/docs/latest/api/web-contents>

Four things kaya should read off this:

- **No regex, no whole-word, no replace.** `matchCase` is the only matching
  knob. This is what "find" reduces to when the content is a rendered document
  rather than an editable buffer — which is what most kaya scenes are.
- The result is **asynchronous and incremental**: `found-in-page` fires
  repeatedly with `finalUpdate: false` until the count settles. Same shape as
  GtkSourceView's `occurrences-count: -1`.
- `activeMatchOrdinal` + `matches` is exactly the "3 of 17" the bar shows, and
  it comes **from the engine**, not from the app counting.
- **Teardown is a first-class call with a policy argument.** Closing the bar
  must say what happens to the highlighted match — clear it, demote it to a
  normal selection, or activate it. `stopFindInPage` is not optional cleanup.
  kaya's find bar needs the same three-way decision at dismiss.

---

## 3. Apple — the one framework-integrated case, and how to suppress it

### 3.1 What Apple ships

**macOS / AppKit.** `NSTextFinder` is "an optional search-and-replace find
interface inside a view, usually a scroll view" — a controller for the standard
Cocoa find bar. It "interacts heavily with a `client` object which supports the
`NSTextFinderClient` protocol. The client object provides access to the content
being searched and provides visual feedback for a search operation."
`NSTextFinder.Action` covers `nextMatch`, `previousMatch`, `replace`,
`replaceAndFind`, `replaceAll`, `replaceAllInSelection`, `setSearchString`,
`selectAll`, `selectAllInSelection`. Menu items use `performTextFinderAction(_:)`,
"sent down the responder chain in the standard method".
<https://developer.apple.com/documentation/appkit/nstextfinder>

**iOS / UIKit is the shape kaya should study hardest.** `UIFindInteraction`
provides the *panel*; the app provides the *matching* by conforming its content
object to `UITextSearching` and wrapping it in a `UITextSearchingFindSession`:

```swift
let findInteraction = UIFindInteraction(sessionDelegate: self)
interactionView.addInteraction(findInteraction)

func findInteraction(_ interaction: UIFindInteraction, sessionFor view: UIView) -> UIFindSession? {
    UITextSearchingFindSession(searchableObject: document)
}
```

`UITextSearching` requires `performTextSearch(queryString:options:resultAggregator:)`,
`decorate(foundTextRange:document:usingStyle:)`, `clearAllDecoratedFoundText()`,
`compare(_:toRange:document:)`, `scrollRangeToVisible(_:inDocument:)`,
`selectedTextRange`, plus for replace `supportsTextReplacement`,
`replace(foundTextRange:document:withText:)`,
`replaceAll(queryString:options:withText:)`,
`shouldReplace(foundTextRange:document:withText:)`.
<https://developer.apple.com/documentation/uikit/uitextsearching>
<https://developer.apple.com/documentation/uikit/uifindinteraction>

**Apple's own query model has no regex.** `UITextSearchOptions` is
`wordMatchMethod: .contains | .startsWith | .fullWord` plus
`stringCompareOptions: NSString.CompareOptions`. Literal matching with compare
flags, and word-match as a three-way enum rather than a boolean.
<https://developer.apple.com/documentation/uikit/uitextsearchoptions>

Note the asymmetry with the rest of Apple's stack: `NSRegularExpression`
"conforms to the International Components for Unicode (ICU) specification for
regular expressions" and does have `\n` backreferences and all four lookaround
forms — so an ICU dialect was available and Apple's find UI deliberately does
not use it.
<https://developer.apple.com/documentation/foundation/nsregularexpression>

**SwiftUI** exposes it as modifiers: `.findNavigator(isPresented:)`,
`.findDisabled(_:)`, `.replaceDisabled(_:)`. And as of the 26 SDKs there is
`FindContext`, read from the environment, explicitly so that **custom** text
views can present their own bar driven by the *same* modifiers:

> "Views which support text editing can use this information to implement a find
> navigator that is controlled using the modifiers used for controlling the find
> navigator throughout the rest of SwiftUI."

`FindContext` carries `isPresented: Binding<Bool>?` ("or nil if no binding has
been provided via the `findNavigator(isPresented:)` modifier") and
`supportsReplace: Bool`. Available iOS/iPadOS/macOS/visionOS **26.0+**.
<https://developer.apple.com/documentation/swiftui/findcontext>

### 3.2 Suppressing the native find UI — API names, not speculation

**macOS, AppKit `NSTextView`:**

- `textView.usesFindBar = false` — "A Boolean value that indicates whether to
  use the find bar for this text view." macOS 10.7+. "A text view can use either
  a find panel or a find bar. If `usesFindBar` is set to `true`, `usesFindPanel`
  is set to `false` and vice versa."
  <https://developer.apple.com/documentation/appkit/nstextview/usesfindbar>
- `textView.usesFindPanel = false` — the other half of that pair; both must go
  to `false`.
  <https://developer.apple.com/documentation/appkit/nstextview/usesfindpanel>
- `textView.isIncrementalSearchingEnabled` — already off: "It is disabled by
  default … because incremental searching requires the find bar, `usesFindBar`
  must be set to `true` for incremental searching to occur." (NSTextFinder page.)
- **Menu-item validation is the documented lever.** From the NSTextFinder page:
  "The responder should implement `validateUserInterfaceItem(_:)` and, when the
  item's action is the `performTextFinderAction(_:)` method, it should pass the
  item's tag to [`validateAction(_:)`] and return the result." So overriding
  `validateUserInterfaceItem(_:)` to return `false` for
  `performTextFinderAction(_:)` and the legacy `performFindPanelAction(_:)`
  greys the Find items out. `performFindPanelAction(_:)` is documented as "the
  generic action method for the find menu and find panel, and **can be
  overridden to implement a custom find panel**" — i.e. Apple documents
  overriding it as the supported route to your own bar.
  <https://developer.apple.com/documentation/appkit/nstextview/performfindpanelaction(_:)>
  - *Caveat, flagged as such:* that `NSTextView` itself gates its find-action
    validation on `usesFindPanel` is not stated in Apple's docs. GNUstep's
    open reimplementation does exactly that gate
    (<https://github.com/gnustep/libs-gui/blob/master/Source/NSTextView.m>),
    which is corroborating but not authoritative. Verify on device rather than
    assuming.
- **The cleanest macOS route is upstream of all of this:** on macOS the Find
  menu is app-owned. If kaya builds the menu bar, it can simply not install the
  standard Find items and bind ⌘F to its own command. There is then no
  `performTextFinderAction:` to intercept.
- **Interop kaya will break if it ignores it:** `NSPasteboard.Name.find` —
  "The pasteboard that holds information about the current state of the active
  application's find panel" (macOS 10.13+). ⌘E (use-selection-for-find) writes
  it and ⌘G reads it, across applications. A custom bar that never touches the
  find pasteboard silently breaks the system-wide ⌘E → switch app → ⌘G flow.
  <https://developer.apple.com/documentation/appkit/nspasteboard/name-swift.struct/find>

**iOS / iPadOS / Mac Catalyst, UIKit:**

- `UITextView.isFindInteractionEnabled` (16.0+) is the on-switch, and
  `findInteraction` "returns `nil` when the interaction isn't enabled" — so
  leaving it false means the text view has no system find UI. Same property on
  `WKWebView` and `PDFView`.
  <https://developer.apple.com/documentation/uikit/uitextview/findinteraction>
- **The keyboard shortcuts ride on the interaction**: "Standard system shortcuts
  (Command+F for find, Command+G for find next, Command+Shift+G for find
  previous) automatically trigger the interaction. On macOS, these commands are
  added to the menu bar when your view becomes first responder." No interaction
  → no shortcut from that path. (UIFindInteraction overview.)
- **The menu route is separate and must be handled separately.**
  `UIResponderStandardEditActions` declares `find(_:)`, `findNext(_:)`,
  `findPrevious(_:)`, `findAndReplace(_:)`, `useSelectionForFind(_:)`, and
  "UIKit searches the responder chain for an object that implements the
  appropriate method, calling the method on the first object that implements
  it." To *take over* ⌘F, implement `find(_:)` on kaya's responder and open
  kaya's bar. To remove the menu entirely, `builder.remove(menu: .find)` in
  `buildMenu(with:)` — `UIMenu.Identifier.find` (13.0+), with finer-grained
  `.findPanel` ("Find, Find and Replace, Find Next, Find Previous") and
  `.replace` also available.
  <https://developer.apple.com/documentation/uikit/uiresponderstandardeditactions>
  <https://developer.apple.com/documentation/uikit/uimenu/identifier-swift.struct/find>

**SwiftUI:**

- `.findDisabled(_:)` — "Prevents find and replace operations in a text editor."
  "When you disable find, you implicitly disable replace as well." Placement
  matters: it "also prevents programmatic find/replace presentation via
  `findNavigator(isPresented:)`", but **only if placed closer to the text editor
  than the `findNavigator` modifier**, and when applied at several levels the
  one nearest the editor wins.
  <https://developer.apple.com/documentation/swiftui/view/finddisabled(_:)>
- **Availability trap:** `.findDisabled(_:)` and `.findNavigator(isPresented:)`
  are **iOS 16.0+ but macOS 26.0+**. `FindContext` is 26.0+ everywhere. Below
  macOS 26 there is no SwiftUI-level suppression knob at all, so kaya's mac
  backend has to reach the underlying `NSTextView` (representable /
  introspection) to set `usesFindBar` / `usesFindPanel`.
  **Open empirical question, not asserted here:** whether a SwiftUI `TextEditor`
  on macOS < 26 responds to a standard Edit ▸ Find menu item at all, given the
  AppKit text view underneath. Worth a five-minute probe on a real machine
  before designing around either answer.

---

## 4. The industry pattern, in one paragraph

Find is not a framework feature; it is an editor-component feature, and inside
the components the engine and the bar are almost always separate layers that
ship at different times. The GUI toolkits themselves ship nothing: GTK's
`GtkTextView` has no find, and neither Electron nor Scintilla — the substrates
under most desktop apps with find bars — ships any UI, only an engine, so VS
Code, Slack, Notepad++ and SciTE each drew their own. Where a component does
ship a bar it ships it as an opt-in add-on (`SearchPanel.Install(editor)`,
`search()` in the CodeMirror extension list, a `find` contrib in Monaco), and
one of those bars still has no replace after fifteen years. The engines, where
they exist, converge on the same four knobs — literal / case / whole-word /
regex — plus replace with `$1`-style templates, and they diverge sharply on the
regex dialect, because each simply exposed whatever engine its platform already
had: PCRE2 in GtkSourceView, .NET `Regex` in AvalonEdit, JavaScript `RegExp` in
Monaco and CodeMirror, C++11 `<regex>` behind a *flag* in Scintilla. Apple is
the one genuine framework-integrated case and it splits the layer differently
from everyone else — `UIFindInteraction` gives you the bar, the keyboard
shortcuts and the menu integration, while `UITextSearching` makes the *app*
supply the matching, and Apple's own query model is deliberately literal, with
no regex at all. Two behaviours are unanimous wherever replace exists:
replace-all is one undo step (`pushUndoStop` … `pushUndoStop`,
`begin_user_action` … `end_user_action`, one CodeMirror transaction,
`SCI_BEGINUNDOACTION`), and the engine's own change-tracking is suspended for
the duration of the batch.

---

## 5. What the evidence does not settle — kaya's scoping questions

**Q1. Does kaya's engine search a buffer, or does the app answer queries?**
Every engine surveyed searches a buffer the component *owns* — Monaco's
`ITextModel`, a `GtkTextBuffer`, Scintilla's document, CodeMirror's
`EditorState`. kaya has no such buffer: its text lives in app state and the
widgets are declarative, so "search the document" has no owner yet. Apple is the
only surveyed case that faced the same problem, and answered it the other way:
the framework ships the bar and the app implements
`performTextSearch(queryString:options:resultAggregator:)`. Which side kaya
picks decides whether a core-owned engine (layer 1) is even implementable once
in Rust, or has to become a callback protocol the guest implements in eight
languages. It also decides who owns the highlight set — GtkSourceView and Monaco
both make the *engine* own highlighting (`set_highlight()` / `set_match_style()`;
decorations capped at 19999), whereas kaya's agreed layer 0 puts the highlight
set on the widget as an app-driven prop.

**Q2. Given backreferences and lookaround are out, what enforces the dialect —
kaya's own matcher, or a validator over five native ones?** The native engines
behind kaya's five backends all *have* the excluded features: PCRE2 under GTK
(confirmed in `implregex.c`), ICU under Apple (`NSRegularExpression` "conforms
to the ICU specification", with `\n` backreferences and all four lookaround
forms), .NET `Regex` on Windows, `java.util.regex` on Android, and whatever the
core links. So "one dialect everywhere" cannot come from delegating to the
platform. Rust's `regex` crate matches kaya's ruling exactly — it documents
lacking "look-around and backreferences" in exchange for `O(m*n)` — which makes
a core-owned matcher the obvious candidate, but the survey does not tell kaya
whether the cost of shipping Rust matching to every backend beats validating
patterns and rejecting the excluded constructs at the boundary. VS Code's
intersection-dialect release note is a warning about the second option, not a
proof against it. **Sub-question the evidence actively muddies: what "whole
word" means.** Three components, three incompatible answers — Monaco's
caller-supplied `wordSeparators` string, AvalonEdit's document caret-word rules
(so find agrees with double-click), GtkSourceView's textual `\b…\b` wrap (which
mis-parses `foo|bar`), and Apple's three-way `.contains / .startsWith /
.fullWord` enum. kaya's byte-for-byte cross-platform scene comparison will
expose any divergence here immediately.

**Q3. Where does replace-all's undo group come from, and what else must the
batch suspend?** Every component that ships replace does *two* things, not one:
fences the batch as a single undo unit, and suspends its own change-reaction
while it applies — Monaco's `pushUndoStop()` … `pushUndoStop()` plus
`_ignoreModelContentChanged`; GtkSourceView's `begin_user_action` …
`end_user_action` plus blocking four buffer signal handlers, disabling bracket
highlighting, and saving/restoring the selection. kaya already has transactions
as its write mechanism, but the survey cannot say whether one kaya transaction
maps to one undo step on all five backends (SwiftUI/Compose/GTK/WinUI each have
their own undo manager), who saves and restores selection across the batch, or
what suspends kaya's own reactive machinery. Scintilla's rule — nested
transactions collapse, only the top-level is one undo unit — is the one piece of
prior art on what happens when a handler inside a replace-all opens its own
group.

*Ancillary, cheap, and worth deciding early:* dismissing the bar needs a policy
argument. Electron's `stopFindInPage('clearSelection' | 'keepSelection' |
'activateSelection')` is the only surveyed API that makes it explicit, and the
three answers are all defensible.

---

## Sources

- <https://gnome.pages.gitlab.gnome.org/gtksourceview/gtksourceview5/class.SearchContext.html>
- <https://gnome.pages.gitlab.gnome.org/gtksourceview/gtksourceview5/class.SearchSettings.html>
- <https://gnome.pages.gitlab.gnome.org/gtksourceview/gtksourceview5/method.SearchContext.replace_all.html>
- <https://gitlab.gnome.org/GNOME/gtksourceview/-/blob/master/gtksourceview/gtksourcesearchcontext.c>
- <https://gitlab.gnome.org/GNOME/gtksourceview/-/blob/master/gtksourceview/implregex.c>
- <https://github.com/microsoft/vscode/blob/main/src/vs/monaco.d.ts>
- <https://github.com/microsoft/vscode/blob/main/src/vs/editor/contrib/find/browser/findModel.ts>
- <https://code.visualstudio.com/updates/v1_29>
- <https://docs.rs/regex/latest/regex/>
- <https://codemirror.net/docs/ref/>
- <https://github.com/codemirror/search/blob/main/src/search.ts>
- <https://www.scintilla.org/ScintillaDoc.html>
- <https://github.com/icsharpcode/AvalonEdit/tree/master/ICSharpCode.AvalonEdit/Search>
- <https://github.com/icsharpcode/AvalonEdit/blob/master/ICSharpCode.AvalonEdit/Search/SearchStrategyFactory.cs>
- <https://github.com/icsharpcode/AvalonEdit/blob/master/ICSharpCode.AvalonEdit/Search/RegexSearchStrategy.cs>
- <https://www.electronjs.org/docs/latest/api/web-contents>
- <https://developer.apple.com/documentation/appkit/nstextfinder>
- <https://developer.apple.com/documentation/appkit/nstextview/usesfindbar>
- <https://developer.apple.com/documentation/appkit/nstextview/usesfindpanel>
- <https://developer.apple.com/documentation/appkit/nstextview/performfindpanelaction(_:)>
- <https://developer.apple.com/documentation/appkit/nspasteboard/name-swift.struct/find>
- <https://developer.apple.com/documentation/uikit/uifindinteraction>
- <https://developer.apple.com/documentation/uikit/uitextsearching>
- <https://developer.apple.com/documentation/uikit/uitextsearchoptions>
- <https://developer.apple.com/documentation/uikit/uitextview/isfindinteractionenabled>
- <https://developer.apple.com/documentation/uikit/uitextview/findinteraction>
- <https://developer.apple.com/documentation/uikit/uiresponderstandardeditactions>
- <https://developer.apple.com/documentation/uikit/uimenu/identifier-swift.struct/find>
- <https://developer.apple.com/documentation/swiftui/view/finddisabled(_:)>
- <https://developer.apple.com/documentation/swiftui/view/findnavigator(ispresented:)>
- <https://developer.apple.com/documentation/swiftui/findcontext>
- <https://developer.apple.com/documentation/foundation/nsregularexpression>
- <https://github.com/gnustep/libs-gui/blob/master/Source/NSTextView.m> (corroborating reimplementation only)
