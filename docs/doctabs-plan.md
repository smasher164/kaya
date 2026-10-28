# Document tabs: one concept, native on every platform

Status: RULED 2026-10-28 (the maintainer): every §9 question as recommended
except Q3, which he revised to put shared regions in v1 (§1.7). The
maintainer, 2026-10-28: "so i guess we should add tabbing support to the text
editor". The rulings this plan builds on are docs/native-tabs-study.md's four
(all RULED 2026-10-28: option C, Mac NSWindow tabbing through public API only,
a list of open documents on phones) and the `doctabs` entry in
docs/roadmap/features.toml.

Terms, as the study uses them. A DOCUMENT TAB is one the user opens, closes,
reorders and drags out. A SECTION is one of a fixed, app-declared set of
destinations (DESIGN.md, Sections), which this is not. A NATIVE WINDOW is one
NSWindow, GtkWindow or WinUI Window; a KAYA WINDOW is a surface id the app
created (window 0 or `create_window`). Today one kaya window is exactly one
native window; §1.2 is the place that changes.

## §1 The rule, from zero

### 1.1 What a document is

A document is a SURFACE, exactly as a section or a navigation entry is: its id
comes from the app's surface namespace, `mount` puts a root into it, and the
root is retained while another document is in front. What it adds over a
section is lifecycle: the set is dynamic (the app adds documents at any time),
each one closes (with a veto the app may arm), the user reorders them, and on
the desktops the user moves one into a window of its own.

So the semantics are one sentence, the same on all five platforms: a window
holds an ordered set of documents, one of them is the ACTIVE document, each
closes through a veto the app may arm, the user may reorder them, and where
windows exist the user may move one to a new window. How the set is drawn is
the platform's (a tab strip, a list), and the app never says which, as
`sections_presentation` already works.

### 1.2 One kaya window, one or more native windows

The Mac decides the shape. On the Mac each tab IS a native window, and AppKit
lets the user tear a tab out into its own window, or merge windows back,
without telling the app first (the study's §1: "the app was told nothing").
GTK and WinUI also let a tab be dragged out, and both ask the app for the new
window synchronously, inside the drag.

The proposal (question Q1): a kaya window that holds documents is a
DECLARATION, presented as one or more native windows. Tearing a tab out makes
another native window of the SAME kaya window. Every native window of it shows
the same shared chrome, the kaya window's (its menu catalog, its toolbar, its
title rule), because that chrome is the kaya window's and there is only one of
it. This is SwiftUI's WindowGroup, and it is the only shape in which the Mac's
post-fact tear-out needs no new id, no new handlers and no new catalog from
the app: the menu items stay one command identity each (DESIGN.md, "One menu
item is one command identity"), and a handler that acts on "the active
document" acts on whichever native window the user is in.

Each native window shows a STRIP: its own ordered run of the kaya window's
documents. The ACTIVE document is the one the user is working in: the selected
tab of the native window that has focus. On the Mac that is literally the key
window, since each tab is one.

### 1.3 Shared chrome and per-document content

| Part | Whose | Mac (a tab is a window) | GTK, WinUI (a tab is a view) | Phones |
|---|---|---|---|---|
| Menu catalog | the kaya window | the menu bar follows the key NSWindow, and every tab window of the kaya window maps to its catalog | one menu bar per native window, built from the one catalog | the overflow, as today |
| Toolbar (promoted `primary` actions) | the kaya window | an NSToolbar per tab window, each built from the one catalog, so they agree by construction | one per native window | the top bar, as today |
| Title shown in chrome | the active document's | each tab window's own title is its document's title | the header bar or caption shows the active document's title | the top bar shows the active document's title |
| Unsaved mark | each document's | a dot on its tab, and the close-button dot on its window | a mark on its tab, and the window-level mark follows the active document | a mark on its row in the list (Q4) |
| The body | each document's surface | that tab window's content | the tab view's page | the screen, under the top bar |
| Undo, focus, selection | each document's | per window, natively | per page | per document |

Shared regions (§1.7) are the one part of the body the documents share.

### 1.4 What the window's own props mean in a window with documents

- `title`: shown only while the window holds no documents (the phones' empty
  state, §1.6). Otherwise the chrome shows the active document's title.
- `dirty`: refused at the root on a window that has documents. The documents
  carry the marks, and the window-level chrome (the Mac's close-button dot,
  WinUI's caption asterisk, GTK's header bullet) follows the active document.
  Two sources for one mark would be two truths.
- `veto_close`: unchanged meaning, but a documents window rarely needs it,
  because the documents carry the veto (§1.5).
- `sections_presentation`, `panes` and `push_entry` into the window: a window
  with documents refuses sections and a window stack in v1 (Q8).

### 1.5 Close, in both of its forms

There are two different user acts, and every desktop has both:

- CLOSE A DOCUMENT: the tab's own close button, the platform's Close Tab
  command, a phone row's close. If the document arms `intercept_close`, kaya
  emits `document_close_requested(document)` and nothing closes; the app
  answers with `close_document` if it agrees (the close-veto class, as
  `intercept_back` and `intercept_dismiss` already are). Unarmed, it closes and
  `document_closed(document)` reports it after the fact.
- CLOSE A NATIVE WINDOW: the title bar's close button, Alt+F4, Close Window.
  It closes the documents that native window shows. If any of them arms
  `intercept_close`, nothing closes and kaya emits ONE
  `documents_close_requested(window, [documents])` listing all of them, so the
  app can ask about them one dialog at a time (kaya allows one alert per
  process, so a burst of per-document requests would be a trap). The app closes
  each one it agrees to. Unarmed, they all close, each with `document_closed`.

On the Mac the red close button of a tab window is AppKit's close for that one
tab (the study measured it), so there it is the first form; Close Window, with
several tabs, is the second. That is the chrome's meaning differing by
platform, which kaya does not override: the app hears exactly which documents
are asked about, on every platform.

A native window with no documents left closes. When that is the kaya window's
last native window, the kaya window closes by the existing rule (an auxiliary
window reports `window_closed`; the primary ends the process). This also gives
an app a way to AGREE to quit, which today it cannot (docs/traps.md, "An app
can VETO a close but cannot AGREE to one"): it closes its last document. Q2 is
the question of whether that is the right default.

### 1.6 Phones

No phone has a document tab, and the ruling is a list (study Q4). The window's
body shows the active document. A button in the top bar opens the list of open
documents (question Q4 places it): each row shows the document's title and its
unsaved mark, the active row is checked, tapping a row makes it active and
closes the list, each row has a close button (and on iOS the platform's swipe
as well), and a "+" in the list's header asks for a new document when the
window arms it. Moving to a new window does not exist there, because the
window does not; this is the ruling's own "where windows exist", and since the
move is always the user's act and never the app's, no app can observe its
absence except by never hearing it.

A phone cannot close its one window. Under Q2's recommendation the last
document's close leaves the phone showing the window's own mounted root, the
empty state; the desktops close the window instead. That is a stated
divergence, granted by the maintainer as Q2's ruling (2026-10-28), and it goes
into DESIGN.md's "Stated platform divergences" when it is built.

iPad (regular width) uses the phone arm in v1. A scene per document is iPadOS's
idiom, and needs the multi-scene work kaya has not done (the study's §2).

### 1.7 Shared regions: a sidebar beside the documents (Q3, revised)

The maintainer, 2026-10-28: "I'd ideally like a solution where a sidebar could
be implemented in the same way it would on gnome and windows, but you still use
the native macos tabs. Basically, the copying/restoring stuff is handled by
kaya, but the user can still implement the sidebar."

**The declaration.** A window with documents may declare SHARED REGIONS: a
region is a surface (the shared namespace again), added to the window at an
EDGE, `leading`, `trailing` or `bottom`, and filled by `mount` with any widgets
the app likes. There is no sidebar kind; a region is a place, and what goes in
it is ordinary kaya. The same calls on every platform, and no Mac branch in
the app. At most one region per edge. Its width (or, at the bottom, its height)
comes from its root's own layout; a user-draggable divider is not in v1.

**GTK and WinUI** draw the region once per native window, beside the tab view:
a horizontal GtkBox (vertical for `bottom`) around the AdwTabView inside the
window's toolbar view, and the matching Grid column or row around the TabView.
All three edges are the same few lines there.

**The Mac moves one view instead of copying it.** Only the selected tab window
of a strip is ever on screen, so kaya hosts the region in ONE view per strip
and, on each selection change (`windowDidBecomeKey` among the kaya window's
NSWindows, and the strip's `selectedWindow`), moves that view into the newly
selected tab window. All three edges come free, since the move does not care
where in the window the view goes. MEASURED 2026-10-28 (an AppKit probe built
with `kaya_swiftc`, two NSWindows tabbed by `addTabbedWindow`, one
NSHostingView holding a SwiftUI List, a ScrollView, a TextField and an
`@StateObject` model, moved with `removeFromSuperview` and `addSubview` on each
`tabGroup.selectedWindow` change; the probe is in the doctabs agent's
scratchpad, rebuilt from this description):

| What | After the move |
|---|---|
| The List's and the ScrollView's scroll offsets (500 and 300) | kept, read back from their NSScrollViews' clip views |
| The List's selection and the model's state | kept |
| The TextField's text, half typed | kept |
| Focus and the caret | LOST: the old window's first responder resigns, and the new window's first responder is the window itself |
| Focus and the caret, restored by kaya | kept: kaya records the first responder and the field editor's `selectedRange` before the move, and one runloop turn after it calls `makeFirstResponder` and sets the range again (read back `{6, 0}`, editing). Done in the same turn as the move, `makeFirstResponder` does not take. |
| SwiftUI's lifecycle | the region's `onDisappear` and `onAppear` fire on every move. The interpreter must not read either as the region leaving the scene (§3). |
| Where it sits | under the tab strip, which spans the full window width above it; the strip belongs to the title bar's accessories, so a full-height leading sidebar starts below the strip on the Mac, where on GNOME and Windows the tab bar sits beside the sidebar over the documents only. That is the platforms' own geometry and is accepted. |

So the fallback (copies plus kaya-side mirroring of scroll, selection, focus,
text and caret) is not needed.

UNMEASURED, and accepted in advance as the coordinator proposed: Show All Tabs
draws a live thumbnail of every tab window, and every one but the selected one
has no region in it at that moment, so their thumbnails will show an empty
slot. The probe's overview did not open in an inactive accessory app, and the
host was in use, so the photograph waits for an idle host in the depth slice.

**A second strip gets a second instance.** A torn-out tab is on screen at the
same time as its old strip, and per Q1 it is still the same kaya window, so it
needs the region too. Each strip (on the Mac a tab group, on GTK and WinUI a
native window) shows ITS OWN INSTANCE of every region, built from the same
mounted tree: everything the app drives (signals, props, its commands) reaches
every instance, and the widget-local state of a new instance (scroll, focus,
half-typed text) starts fresh. That is what GNOME's `create-window` and
WinUI's `TabTearOutWindowRequested` do anyway, since the new window is built
anew there. Occurrences carry no instance: the app sees one widget, and the
harness reads the instance in the active strip.

**Phones.** No phone has room beside a document. A `bottom` region sits under
the document, above the keyboard's inset, as a status bar would. A `leading` or
`trailing` region is shown in the open-documents sheet, above the list, which
is the one place a phone already shows window-level content beside the
documents. This placement is the plan's proposal and is in the message that
carries the probe's result.

**The editor** keeps its status line and find bar PER DOCUMENT: each describes
one buffer (the find bar's matches, the status line's "saved, 15 bytes"), and
that is where GNOME Text Editor and Sublime Text keep them. It declares no
region; the conformance scene exercises one (§5).

## §2 The app-facing API

### 2.1 The protocol

Spec-first (invariant 7). A fourth typed surface table, the SECTION_PROPS
stance:

| `DOCUMENT_PROPS` | Kind | Meaning |
|---|---|---|
| `title` | Str | The tab's label, the list row's text, and the chrome title while active. |
| `tooltip` | Str | The tab's tooltip (Mac `tab.toolTip`, AdwTabPage `tooltip`, WinUI `ToolTipService`); a full path, typically. Phones show none. |
| `dirty` | Bool | Unsaved work: the tab's mark (§3), and the window-level mark while active. Arms nothing. |
| `intercept_close` | Bool | The veto: the tab's close emits `document_close_requested` and nothing closes until `close_document`. |

The region needs no props of its own in v1. One window prop: `new_document` (Bool, default false). True draws the
platform's "+" (Mac: answering `newWindowForTab:`; AdwTabBar's action button;
WinUI `IsAddTabButtonVisible`; the phone list's header), and pressing it emits
`new_document_requested(window)`. The binding sets it when the app registers
the handler, so no app spells it by hand.

Records (TX and APPLY, in the add_section family):

| Record | Fields | Meaning |
|---|---|---|
| `add_document` | window, document | Append to the active native window's strip (the Mac's "+" appends there too). The first document added becomes active. Does not make it active otherwise: `select_document` in the same transaction does (the sugar offers `.select()`). |
| `select_document` | document | Make it active: select its tab and bring its native window forward. Configuration, never echoes. |
| `close_document` | document | Close it and forget its mounted tree, as `pop_entry` forgets an entry. Also the answer that agrees to a close request. Never echoes `document_closed`. |
| `set_document_prop` | document, prop, source | The `set_section_prop` shape. |
| `add_region` | window, region, edge | A shared region (§1.7) at a `REGION_EDGE` (`leading`, `trailing`, `bottom`); `mount` fills it. Only on a window with documents, one per edge, never removed (the sections' append-only stance). |

Occurrences, every one post-fact or a request, every one the user's act only
(the echo doctrine):

| Occurrence | Fields | When |
|---|---|---|
| `document_selected` | window, document | The active document changed: a tab click, a key-window change between tab windows or torn-out windows, a phone row. |
| `document_close_requested` | document | An armed document's own close. |
| `documents_close_requested` | window, documents | A native window's close, listing what it shows, when any of them is armed. |
| `document_closed` | document | An unarmed document closed through the user's act. |
| `new_document_requested` | window | The "+". |
| `document_moved` | document, strip, index | The user reordered, tore out, or merged. `strip` is the native window's position among the kaya window's native windows in the order they opened (0 is the first), and `index` is the document's place in that strip afterwards. Informational; no app has to read it. |

No programmatic reorder or tear-out in v1: no forcing app asks for one.

### 2.2 Rust

Handlers scope to their creator: the document's handlers ride
`add_document`, the "+" rides the window, as `on_close_requested` does today.

```rust
#[derive(Clone)]
enum Msg { New, AskClose(WindowId), Closed(WindowId), Active(WindowId) }

let msgs = kaya::Messages::new();
ctx.apply(|tx| {
    tx.window(kaya::DEFAULT_WINDOW).title("notes");
    msgs.on_new_document(kaya::DEFAULT_WINDOW, Msg::New); // draws the "+"
    let doc = tx
        .add_document(next_doc())
        .title("draft")
        .tooltip("/Users/me/draft")
        .intercept_close(true)
        .select()
        .id();
    msgs.on_document_selected(doc, Msg::Active(doc));
    msgs.on_document_close_requested(doc, Msg::AskClose(doc));
    msgs.on_document_closed(doc, Msg::Closed(doc));
    let root = tx.column(|tx| { tx.textarea_plain(); }).id();
    tx.mount_in(doc, root);
});
// later, from a handler:
ctx.apply(|tx| {
    tx.set_document_prop(doc, kaya::DocumentProp::Dirty, true);
    tx.close_document(doc); // the answer that agrees
});
```

`documents_close_requested` registers on the window
(`msgs.on_documents_close_requested(window, |docs| Msg::AskMany(docs))`), and
`document_moved` on the document.

### 2.3 Go (the editor's binding)

```go
win := tx.Window(0).Title("editor").OnNewDocument(func(tx *kaya.Tx) { openDoc(tx, nil, "") })
win.OnDocumentsCloseRequested(func(tx *kaya.Tx, docs []kaya.DocumentRef) { askEach(tx, docs) })

d := tx.AddDocument(nextID()).Title("untitled").InterceptClose(true).Select().
    OnSelected(func(tx *kaya.Tx) { active = doc }).
    OnCloseRequested(func(tx *kaya.Tx) { ask(tx, doc, func(tx *kaya.Tx) { tx.CloseDocument(doc.id) }) }).
    OnClosed(func(tx *kaya.Tx) { forget(doc) })
tx.MountIn(d.Id(), tx.Column(func() { /* this document's buffer, find bar, status */ }))
d.Dirty(true) // DocumentRef setters write set_document_prop
```

The other seven bindings follow their own sugar for sections (Python keyword
arguments and decorators, C# and Java chains, Swift trailing closures, OCaml
labelled arguments, Haskell config lists, JS option objects); the C floor
spells each record. tools/check-sugar-surface.py holds the fan-out open by
itself once DOCUMENT_PROPS exists.

### 2.4 What the core walls (each a `#[should_panic]` test)

A document added twice or to two windows; `select_document`, `close_document`
or a prop on an unknown or closed id (ids are never reused); sections, a
window stack or `panes` above 1 on a window with documents, and documents on a
window with sections (Q8); `dirty` on a window with documents (§1.4); a second
window with documents in one app (Q1's sub-question); a region on a window
without documents, a second region at one edge, or a region id reused as a
document.

## §3 Each backend's lowering

**macOS (SwiftUI interpreter, AppKit through the existing bridge).** Each
document is an NSWindow hosting its surface's root, in one `NSWindowTabGroup`
per strip, grouped with `addTabbedWindow(_:ordered:)` relative to the strip's
last window. Public API only, the ruling. Per tab: `tab.title` follows the
window title (the document's), `tab.toolTip`, and the unsaved mark as
`tab.accessoryView` (a dot; `isDocumentEdited` never reaches the tab, the
study measured, so it is set as well for the close-button dot). The "+" is
kaya answering `newWindowForTab:`, only while `new_document` is true. Close:
the existing `windowShouldClose` path, now routed to the document grammar.
Selection: `windowDidBecomeKey` between a kaya window's NSWindows emits
`document_selected`. Reorder, tear-out and merge: AppKit tells nobody, so the
arm observes `tabGroup.windows` (KVO-compliant, visual order) and each
window's `tabGroup`, and reports `document_moved`. The menu bar follows the key
window already; the NSWindow-to-kaya-window map grows a document column. The
toolbar is built per NSWindow from the one catalog. Each region is one
NSHostingView per strip, moved into the selected tab window on every selection
change, with the first responder and caret recorded before and restored one
runloop turn after (§1.7's measurement); the region's SwiftUI `onAppear` and
`onDisappear` are not lifecycle there. With one document the strip
follows AppKit's own state (Q7), and a documents window brings back the tab
items the menu merge drops (Show Tab Bar, Show All Tabs) since they now mean
something.

Two unknowns, measured first in the depth slice: (1) SwiftUI's WindowGroup
windows answer `newWindowForTab:` themselves and open a window of the FIRST
WindowGroup (study §1); if kaya cannot own that action on them, document
windows are made by the interpreter as NSWindows hosting an
`NSHostingController` rather than through WindowGroup. (2) Whether AppKit
still inserts the tab menu items into a window whose app has
`allowsAutomaticWindowTabbing = false`, which option A set.

**GTK (libadwaita).** The linux image has libadwaita: tools/linux/Dockerfile
installs `libadwaita-1-dev` and crates/kaya/Cargo.toml already depends on the
`libadwaita` crate 0.9.2 with `v1_7`, for AdwNavigationSplitView. Each native
window: the existing header bar (its title the active document's), an
AdwTabBar below it (GNOME Text Editor's arrangement; `autohide` per Q7), and an
AdwTabView as the body, one AdwTabPage per document, `title`, `tooltip`, and
the mark as the page's `indicator-icon` or a title bullet, whichever GNOME
Text Editor uses (read from its source before building, as dirty-plan.md did).
The "+" in the header bar's start, as GNOME Text Editor and Console place it.
Close is two-phase: `close-page` answers `close_page_finish(page, false)` at
once for an armed page and emits; `close_document` later removes it. Tear-out
is `create-window`, which returns the AdwTabView of a new native window of the
same kaya window; `page-reordered`, `page-attached` and `page-detached` feed
`document_moved`; `notify::selected-page` (user acts only) and window focus
feed `document_selected`. The per-tab menu (AdwTabBar's `menu-model`) carries
Move to New Window and Close, as GNOME's HIG asks. AdwTabView's own shortcuts
(Ctrl+Tab, Ctrl+Page Up/Down, Alt+1..9) come free.

**WinUI.** A TabView in each native window. kaya's WinUI windows already
replace the caption with a TitleBar control (crates/kaya/src/winui/mod.rs,
the promoted CommandBar in its RightHeader), so the tabs go in the title bar,
where Notepad, Terminal and File Explorer put them (Q9), with the MenuBar
below. TabViewItem per document: `Header` is the title plus a dot element when
dirty (Notepad's visible mark), `IsClosable` true, tooltip through
ToolTipService. `TabCloseRequested`, `AddTabButtonClick` (with
`IsAddTabButtonVisible` from `new_document`), `SelectionChanged`,
`TabDragCompleted` and `TabItemsChanged` for order, and `CanTearOutTabs` with
`TabTearOutWindowRequested` and `TabTearOutRequested` for tear-out (Windows App
SDK 1.6 on; kaya pins WinUI 2.2.1). A ContextFlyout per tab carries Move to
New Window and Close, so the move has a keyboard and harness path that is not a
drag. The WinUI types are generated: tools/winui-bindgen grows TabView,
TabViewItem and their event args, and tools/check-winui-bindings.py holds the
regenerated file.

**iOS.** The top bar's documents button opens a `.sheet` with medium and large
detents holding a List; rows as §1.6, `.swipeActions` for close, `.onMove` for
reorder in edit mode. The navigation title is the active document's.

**Android (Compose).** The top app bar's documents action opens a
ModalBottomSheet with a LazyColumn of the same rows and a close IconButton per
row. Reorder has no Material component; it is a long-press drag in the list,
written by hand (Q5).

## §4 The harness

Y9 (docs/styling-pass-plan.md): every read comes off the screen or the toolkit
tree, never kaya's model. All verbs in both interpreters' four layers
(tools/check-verbs.py), and a Stage arm on GTK and WinUI.

| Verb | Mac | GTK | WinUI | Phones |
|---|---|---|---|---|
| `expect_documents "a\|b\|c"` (the active strip's titles, in order) | `tabGroup.windows` of the key window, each `tab.title` | the AdwTabBar's page tabs through AT-SPI | the TabView's TabItem children through UIA | the list's rows off the screen tree (the verb opens the list through its real button, reads, and closes it; stated, since there the list is not on screen otherwise) |
| `expect_document "b"` (the active one) | the key window's tab | the tab whose AT-SPI state is selected | SelectionItem.IsSelected | the top bar's title, and the checked row |
| `expect_document_dirty "b" true` | the tab's accessory view, present and visible | the page's mark | the header's dot element (an automation name) | the row's mark (Q4) |
| `select_document "b"` | the tab, pressed through AX | AT-SPI action on the tab | SelectionItem.Select | tap the row |
| `close_document "b"` | that tab window's `performClose` (what the red button and Close Tab send) | the tab's close button | the tab's close button through UIA | the row's close button |
| `new_document` | the "+" through AX | the "+" | the add-tab button | the list's "+" |
| `move_to_new_window "b"` | `moveTabToNewWindow:` on that tab window (the tab menu's own action) | the tab menu's Move to New Window | the tab's flyout item | refused: no windows (the phone prefix cuts at it, the dirty scene's precedent) |
| `close_native_window` | Close Window on the key window | the native window's close | the native window's close | refused |

Region widgets are read by the existing verbs (`expect`, `expect_scrolled`,
`expect_focused` and the rest) against the instance in the active strip; the
SwiftUI interpreter's registry maps a region widget to that strip's view.

A reorder by drag is real pointer input and goes in the EXCLUSIVE set beside
the drag legs; how each lane drives it is measured in the depth slice.

Close-veto behaviour is read through the verbs above: `close_document` on an
armed document, then `expect_alert` (the app's own dialog) and an unchanged
`expect_documents`; cancel, then the same; agree, then the document gone.

Watched negatives, one per read, each perturbation counted and restored from a
saved copy: drop the accessory view (expect_document_dirty true must fail);
draw titles in reverse (expect_documents must fail); select without bringing
the window forward (expect_document must fail); swallow the veto (a close of
an armed document must fail the scene).

## §5 The scene and the editor

**A conformance scene, `doctabs` (its steps file beside editor.steps),** guests in all nine
languages and the C floor, Rust first. Three documents, `a`, `b` and `c`, each
a column with a label and an entry; `b` arms `intercept_close`. The script:
the strip reads `a|b|c` with `a` active; type into `c` while it is covered and
see it after selecting it (retention); mark `b` dirty and read the mark on its
tab and, while active, on the window; `new_document` adds `untitled 1` at the
strip's end; close `c` (unarmed, gone, `document_closed` heard); close `b`
(armed: the dialog, cancel, still there; again, agree, gone); a programmatic
`select_document` that does not echo; on the desktops, move `a` into a new
window and read both strips; then close the native windows' documents until
the window closes, which ends the desktop legs; the phones end on the empty
state. A leading region holds a list of a dozen rows and an entry: type into
the entry and scroll the list, switch documents, and read the half-typed text,
the caret's focus and the scroll back (on the Mac this is the move of §1.7, on
the others it is trivially true); after `move_to_new_window` the new strip's
region reads fresh while the old one keeps its text.

**The editor (guests/go/editor) grows tabs.** Each document carries its own
buffer, find bar, status line, destination, saved text and Format state. File >
New opens a tab (nothing is discarded any more, so it no longer asks). Open…
opens one tab per chosen file (the Go picker is multi-select by default) and
reuses a pristine untitled tab the way VS Code and TextEdit do. File > Close
Tab (primary+w) closes the active document, asking first when it is unsaved.
Each document's `dirty` is `text != saved`, and `intercept_close` is armed
while it is dirty, so a clean tab just closes. Closing the window asks about
each unsaved document in turn, from `documents_close_requested`, one alert at a
time; closing the last document ends the app, which replaces the `os.Exit`
workaround. The Format, Edit and View menus act on the active document: the
app keeps `active` from `document_selected` and its own `select_document`
calls, and re-derives the Format check marks from the active buffer's last
selection on every switch. The Edit roles already act on the focused widget,
which is in the active document. editor.steps grows a stretch: open both
fixture files into two tabs, read the strip, switch, edit one, read its mark
and not the other's, Close Tab on the dirty one through the dialog. Its
`label#N` and `textarea#0` indices are per-registry, so the script moves to the
`@id` selectors where a second document makes an index ambiguous.
docs/editor-plan.md's "No tabs, no panes (2026-08-10)" is struck with the
maintainer's 2026-10-28 request when this ships.

## §6 Cost and order

Depth then breadth, CLAUDE.md's pattern, one agent in the core at a time.

| Slice | What | Size |
|---|---|---|
| D1 | Spec (DOCUMENT_PROPS, the window prop, four records, six occurrences), regenerate; core: per-window arrangement of strips, the walls in §2.4 with their tests, tree forgetting on close; the Rust surface | M |
| D2 | SwiftUI on the Mac: the two unknowns in §3 first, then the arm, the moving regions and the eight verbs; the Rust `doctabs` guest and scene green on the Mac with every negative watched | L: the inverted ownership, a native window per document, the key-window map, the close routing, the tear-out observer |
| B1 | GTK arm and its AT-SPI reads; tools/check-gtk.py | M |
| B2 | WinUI arm, winui-bindgen growth, UIA reads, tabs in the TitleBar | M to L |
| B3 | iOS list sheet and the reads | S to M |
| B4 | Compose list sheet, the hand-written reorder, the reads | M |
| B5 | Python, Go, C#, Java, Swift, OCaml, Haskell, JS guests and sugar; the C floor | S each, about 1.5 days together |
| E | The editor's tabs and its scene stretch | M |
| V | `validate-all --only doctabs,editor`, then one full matrix; the review page: the strip on every lane, the unsaved mark, the close dialog, the phone list, every capture viewed and stamped | |

The study priced the whole L to XL; this agrees.

## §7 Guards

- The ruling "public API only" becomes a wall: a new clause (a new gate,
  a check-doctabs gate, or a clause in an existing one, decided in D2) that
  fails if the Mac arm names a private AppKit tab class (`NSTabBar`,
  `NSTabButton`, `NSTitlebarAccessoryClipView`) or sends a private selector,
  with its negative watched. The study's probes read NSTabBar's frame for
  pointer geometry only; the harness may need the same, which the clause
  allows by name in the harness file and nowhere else.
- Option A stays: `expect_menu_bar` keeps failing while
  `allowsAutomaticWindowTabbing` reads true, so the documents arm groups
  windows itself and never reopens automatic tabbing.
- tools/check-verbs.py for the eight verbs in both interpreters;
  tools/check-sugar-surface.py for DOCUMENT_PROPS and the handlers in all nine
  bindings; the root walls' `#[should_panic]` tests; the watched negatives in
  §4.
- This plan's own commit is docs only; tools/check-doc-refs.py holds every
  path it names.

## §8 Not in v1

A draggable divider on a region; programmatic reorder and tear-out; pinned tabs and
per-tab icons (the Mac cannot draw a leading icon through public API, the
study's §1); the overview grids (Show All Tabs is AppKit's own and stays,
AdwTabOverview waits); a scene per document on iPad; restoring open documents
across launches (Q6); documents with sections or a stack in one window (Q8).

## §9 Questions for the maintainer

Each has a recommendation; the explanations start from zero.

**Q1. When the user drags a tab out into its own window, is that still the
same kaya window?** On a Mac every tab is already a separate window that
AppKit merely draws together, and the user can pull one out (or merge windows
back) without asking the app. Two designs: (a) the kaya window is a
declaration that can appear as several native windows; a torn-out tab is a new
native window of the same kaya window, with the same menus, toolbar and
handlers, which the app never has to build again; (b) a torn-out tab becomes a
new kaya window, which the app must then furnish with its own menu catalog and
handlers, after the fact on the Mac, so its menu bar is empty until the app
answers. RULED 2026-10-28 (the maintainer), as recommended: (a). It is SwiftUI's WindowGroup, it needs nothing from
the app, and it is the only one of the two that the Mac's after-the-fact
tear-out fits. Its cost is the idea of a strip (`document_moved` reports which
native window a document is in). Sub-question: in v1, at most one window with
documents per app (so AppKit's Merge All Windows can never mix two kaya
windows' documents)? RULED 2026-10-28 (the maintainer), as recommended: yes, ledgered until an app wants two.

**Q2. What happens when the last document closes?** (a) The window closes, as
TextEdit, Notepad and GNOME Text Editor do and as AppKit does on its own when
a window's last tab closes; for the primary window that ends the process,
which also gives the editor the "yes, quit" it lacks today. A phone cannot
close its window, so there the window shows its own mounted root as an empty
state: a stated divergence, like `aux_windows`, which needs your carve-out.
(b) An empty window everywhere, as Sublime Text and VS Code do: one semantics,
no carve-out, but then nothing lets an app agree to close the primary, and the
Mac must keep a window AppKit would close. RULED 2026-10-28 (the maintainer), as recommended: (a), and the phones'
empty state is the maintainer's carve-out.

**Q3. Is anything in the window's body shared across tabs?** "Shared chrome"
here means the parts every tab shows the same: the menus, the toolbar.
RECOMMENDED: in v1 only the window's chrome is shared and the body is all
per-document; the editor's status line and find bar move inside each
document. A shared sidebar or status bar beside the documents waits for an
app that needs one, because on the Mac it would be drawn once per tab window,
and a text field drawn twice has two texts (§1.3). REVISED 2026-10-28 (the
maintainer: "I'd ideally like a solution where a sidebar could be implemented
in the same way it would on gnome and windows, but you still use the native
macos tabs. Basically, the copying/restoring stuff is handled by kaya, but the
user can still implement the sidebar"): shared regions are in v1, §1.7.

**Q4. On a phone, where does the list of open documents open, and does a row
show the unsaved mark?** RULED 2026-10-28 (the maintainer), as recommended: a button in the top bar (iOS: Safari's
two-squares symbol; Android: Chrome's square with the count) opening a sheet
from the bottom (iOS `.sheet`, Android ModalBottomSheet), rows with the title,
a dot when unsaved, a check on the active one and a close button, and a "+" in
the sheet's header. The dot: the dirty ruling (docs/dirty-plan.md D4) gave
phones no unsaved mark because their window chrome has none; this list is
kaya's own drawing, not platform chrome, so a mark there invents nothing.

**Q5. May the user reorder documents on a phone?** iOS's List has reorder
built in; Compose has none, so Android needs a long-press drag written by hand
(about the size of a dnd arm). RULED 2026-10-28 (the maintainer), as recommended: build both, so reordering means
the same everywhere; the alternative is a stated divergence.

**Q6. Do open documents come back after a relaunch?** RULED 2026-10-28 (the maintainer), as recommended: not by
kaya. The app knows its documents (their files) and can store the list in its
own preferences; kaya keeps restoring the window frame as today. AppKit's own
restoration of a tab group stays off (Ghostty's maintainers found it restores
tabs as separate windows, the study's §3).

**Q7. With a single document, is the tab strip shown?** Platforms differ: a
Mac shows no strip for one tab unless the user chose Show Tab Bar (and that
choice persists); GNOME's AdwTabBar hides itself with one tab by default;
WinUI always shows it, as Notepad does. RULED 2026-10-28 (the maintainer), as recommended: each platform's default,
since presentation is advisory, with Show Tab Bar and Show All Tabs back in
the Mac's View menu for a documents window so the user can choose.

**Q8. Can one window have documents and sections, or documents and a
navigation stack?** RULED 2026-10-28 (the maintainer), as recommended: not in v1, refused at the root with a
message saying so, and ledgered. Each is a different way of filling the same
body; no app asks for both yet.

**Q9. On Windows, do the tabs go in the title bar?** Notepad, Terminal and
File Explorer put them there; kaya's WinUI windows already draw their own
title bar, so it costs little. RULED 2026-10-28 (the maintainer), as recommended: yes, with the menu bar below.
