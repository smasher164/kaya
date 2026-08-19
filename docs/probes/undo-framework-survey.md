# Cross-toolkit undo survey, sorted by who owns the text widget

Written for the kaya undo/redo design review (docs/undo-plan.md §0 D1-D8, §1 measured
platform findings). Scope split with a sibling agent, who covers Flutter, Qt Quick, WPF,
GTK and Apple-native in depth, plus the web-editor consensus (ProseMirror, CodeMirror,
Monaco) and ordering-anomaly bug classes. **This report goes wide instead.** Every
toolkit is sorted onto one axis:

* **(A) Owns its rendering, wrote its own text widget.** One undo stack is *available*
  by construction. The problem is definitional (the framework decides what a step is),
  not accidental.
* **(B) Lowers to native widgets.** Inherits the platform's text undo whether it wants
  it or not, and so faces kaya's exact split: native typing undo in one stack, app-state
  undo in another, with no total order between them.

kaya is firmly (B), so (B) gets the depth and (A) is the control group.

Every claim carries a URL. Where a claim rests on kaya's own measurements, it is marked
"(kaya §1)" and not counted as external evidence.

---

## Four findings, up front

### F1. No framework in group (B) offers a unified app+typing undo history while still lowering the text widget. Not one.

Every framework that reached a single history did it by leaving group (B) for that
widget. The clean case is Eclipse: SWT's `StyledText`, the widget every real editor uses,
is custom-drawn and "simply doesn't support Undo-Redo as a built-in feature. This is a
fundamental limitation of the widget itself, not a bug"
([Eclipse Tiny Plugins](https://sourceforge.net/p/etinyplugins/blog/2013/02/add-undoredo-support-to-your-swt-styledtext-s/)),
so JFace installs its own manager on the viewer
([`ITextViewer.setUndoManager`](https://help.eclipse.org/latest/topic/org.eclipse.platform.doc.isv/reference/api/org/eclipse/jface/text/ITextViewer.html))
and typing undo and refactoring undo land in one operation history. The price of the
unified history was writing the text widget and its document model.

The (B) frameworks that kept the native widget (React Native, MAUI, Xamarin.Forms,
wxWidgets, plain SWT, Windows Forms, Electron, Tauri, Delphi VCL) either ship **no app
undo at all**, or ship an app stack documented as **completely independent** of the
control's, with the platform's key-chord dispatch silently deciding which one the user
gets.

### F2. Owning the rendering does not buy one stack either. It only buys the option, and most (A) frameworks declined it.

Qt draws its own `QLineEdit` and `QTextEdit` and still ships two disjoint stacks:
`QTextDocument`'s internal undo stack is inaccessible, non-virtual and "internally isn't
compatible with QUndoView"
([Qt Forum](https://forum.qt.io/topic/29922/how-can-i-show-the-qtextdocument-undo-stack-in-qundoview),
[Qt Forum](https://forum.qt.io/topic/157587/how-to-customize-undo-redo-for-qtextedit)),
sitting beside the app-level [`QUndoStack`](https://doc.qt.io/qt-6/qundostack.html). Qt's
own [Undo Framework overview](https://doc.qt.io/qt-6/qundo.html) never mentions text
widgets or `QTextDocument` at all. Godot is the same shape: a general
[`UndoRedo`](https://docs.godotengine.org/en/stable/classes/class_undoredo.html) for app
actions, with `TextEdit`/`LineEdit` keeping their own built-in histories.

Only **Swing** unified without qualification: `javax.swing.undo.UndoManager` is
documented as "a manager for providing an application's undo/redo functionality" of which
"typically an application will create only one single instance", and `JTextComponent`'s
`Document` feeds it through `addUndoableEditListener`
([javadoc](https://docs.oracle.com/javase/8/docs/api/javax/swing/undo/UndoManager.html)).

**So the two-stack split is not caused by native lowering.** Native lowering makes the
split *unfixable*; own-rendering frameworks mostly chose the same split anyway, because
typing undo and app undo want different coalescing, different granularity and different
lifetimes. kaya's D1 is the majority position among all toolkits, not a concession.

### F3. kaya's D7 (a programmatic write resets the widget's native undo history) is the convergent industry answer, reached independently by both groups.

* WPF clears the `TextBox` undo stack on a binding-driven change; **Avalonia copied it on
  purpose**: [PR #1450](https://github.com/AvaloniaUI/Avalonia/pull/1450), merged
  2018-04-08, "makes `TextBox` act like WPF's `TextBox` where the undo/redo stack is
  cleared when a change is made from non-user input such as from a binding", fixing
  [#336](https://github.com/AvaloniaUI/Avalonia/issues/336).
* Godot's `TextEdit` clears its undo buffer when the `text` property is assigned; the way
  to preserve history is `insert_text_at_caret`, and `clear_undo_history()` exists as the
  explicit lever ([class XML](https://github.com/godotengine/godot/blob/master/doc/classes/TextEdit.xml),
  [godot#20691 "Allow for undo after changing TextEdit's text in script"](https://github.com/godotengine/godot/issues/20691),
  [writeup](https://bugnet.io/blog/fix-godot-text-edit-undo-history-cleared-on-text-set)).
* Compose exposes the lever explicitly and tells you when to pull it:
  `TextFieldState.edit { }` no longer clears history, so "if you want to clear the undo
  stack after an edit call, use `TextFieldState.undoState.clearHistory()`"
  ([TextFieldState API](https://composables.com/jetpack-compose/androidx.compose.foundation/foundation/classes/TextFieldState/api)).
* Windows Forms shipped `TextBoxBase.ClearUndo()` for exactly this
  ([docs](https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.textboxbase.clearundo)).
* kaya measured WinUI, iOS and Compose-`TextFieldState` doing it for free (kaya §1).

The frameworks that did **not** decide this shipped the bug instead. React's controlled
inputs break the DOM undo stack because assigning `.value` programmatically bypasses the
browser's history ([react#17494](https://github.com/facebook/react/issues/17494), open
since 2019-11-30, still labeled "Needs Investigation"), and React Native inherited it on
iOS ([react-native#29572](https://github.com/facebook/react-native/issues/29572), opened
2020-08-06, **closed "not planned"**, with the reporter's diagnosis "the code that sends
the JS value to native ... in turn clears/updates the native input", plus UIKit crashes
during undo; still being re-reported at
[#43684](https://github.com/react/react-native/issues/43684)).

Deciding D7 explicitly puts kaya level with WPF and Avalonia and six years ahead of React
Native.

### F4. There is exactly one platform where a (B) framework could unify, macOS, and the mechanism is the one kaya measured and rejected.

AppKit is the only native toolkit that hands the app the text view's undo manager.
Apple documents the full chain: "When the first responder of an application receives an
`undo` or `redo` message, `NSResponder` goes up the responder chain looking for a next
responder that returns an `NSUndoManager` object from `undoManager`"; document-based apps
"often make their `NSDocument` objects the delegates of their windows and have them
respond to the `windowWillReturnUndoManager:` message by returning the undo manager used
for the document"; and conversely, "if you want a text view to use its own undo manager
(and not the window's), you provide a delegate ... `undoManagerForTextView:`"
([Using Undo in AppKit-Based Applications](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/AppKitUndo.html)).
That is a genuine unified history: in a Cocoa document app, typing and document edits sit
in one ordered stack.

kaya measured `windowWillReturnUndoManager:` and found it "buys nothing and merges
textarea typing with kaya registrations into one step" (kaya §1.2). The survey confirms
that reading is right *and* that the option does not generalize: **no other platform
offers the hook.** iOS in particular punishes the attempt. Overriding `UITextView`'s
`undoManager` with a custom one breaks the software keyboard's undo button auto-enabling
([Apple Developer Forums 715693](https://developer.apple.com/forums/thread/715693), no
Apple answer), which matches kaya's measurement that both iOS text kinds get a private
`_UITextUndoManager` that is never the window's (kaya §1.3). WinUI, GTK and Android
expose no equivalent at all.

So: a cross-platform (B) framework cannot buy unification uniformly, at any price short
of writing the text widget. That is the whole of F1 restated from the platform side.

---

## The table

"Two stacks?" means the user faces two undo histories with no total order between them.
"Edit>Undo routes to" is the question the review asked.

### Group (B): lowers to native widgets. kaya's group.

| Framework | Text widget lowers to | App-level undo API | Two stacks? | Edit>Undo routes to | Programmatic write vs the native stack |
|---|---|---|---|---|---|
| **React Native** (core) | `UITextField`/`UITextView`, `EditText` | **none** | only the native one exists | no menu bar anywhere; Cmd/Ctrl+Z reaches the native field directly | **breaks it.** Controlled `value` disrupts the native undo manager. [#29572](https://github.com/facebook/react-native/issues/29572) closed not-planned |
| **react-native-macos** | `NSTextField`/`NSTextView` | none | as above | AppKit responder chain, whatever menu the host app builds | same controlled-input hazard; separate reports of edit chords never reaching `TextInput` ([#2075](https://github.com/microsoft/react-native-macos/issues/2075)) |
| **react-native-windows** | XAML `TextBox` | none | as above | no framework menu; the TextBox handles Ctrl+Z itself | inherits WinUI behavior |
| **wxWidgets** | native `wxTextCtrl` (Win32 EDIT / GtkEntry / NSTextField) | **yes**, `wxCommandProcessor` + `wxCommand` | **YES, and both claim the same command id** | **unresolved collision.** `wxTextCtrl` "processes by default" `wxID_UNDO`/`wxID_REDO` ([textctrl.h](https://raw.githubusercontent.com/wxWidgets/wxWidgets/master/interface/wx/textctrl.h)); docview says the framework handles undo "so long as the `wxID_UNDO` and `wxID_REDO` menu items are defined in the view menu" ([docview.h](https://raw.githubusercontent.com/wxWidgets/wxWidgets/master/docs/doxygen/overviews/docview.h)) | undocumented |
| **.NET MAUI** | `UITextField`, `EditText`, WinUI `TextBox` | **none** | n/a | Mac Catalyst inherits Apple's default Edit menu through `UIMenuBuilder` and the responder chain, so it hits the focused field; Windows `MenuBarItem` has no undo role | undocumented |
| **Xamarin.Forms** | same | none | n/a | nowhere | undocumented |
| **SWT** (plain) | native `Text`; `StyledText` is custom-drawn with **no undo at all** | none | yes | nowhere in SWT | undocumented |
| **Eclipse JFace/Platform** | `StyledText` + JFace `IUndoManager` | **yes**, `IOperationHistory` | **NO. Unified**, and leaving the native widget is *why* | the app operation history | n/a, the app owns the document |
| **Electron** | webview `<input>`/`contenteditable`, browser's own undo | none built in | yes | `role: 'undo'` calls `webContents.undo()`, "Executes the editing command undo in the web page" ([webContents](https://www.electronjs.org/docs/latest/api/web-contents), [MenuItem roles](https://www.electronjs.org/docs/latest/api/menu-item)). **Focused widget, always; there is no app stack to route to** | React-style controlled inputs break it, same as the web |
| **Tauri** | webview (WKWebView / WebView2 / WebKitGTK) | none | yes | `PredefinedMenuItem::undo` ([Window Menu](https://v2.tauri.app/learn/window-menu/)), and only if you build a menu | same as web |
| **Windows Forms** | Win32 EDIT | **none** | n/a | nowhere; you wire it | `ClearUndo()` is the explicit lever ([docs](https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.textboxbase.clearundo)) |
| **Delphi VCL** | Win32 EDIT; `TMemo` is "a wrapper for a Windows multiline edit control" ([RAD Studio](https://docwiki.embarcadero.com/Libraries/Sydney/en/Vcl.StdCtrls.TMemo)), and `Undo`/`CanUndo` forward to `WM_UNDO`/`EM_UNDO` | none | n/a | nowhere | undocumented |
| **NativeScript** | `UITextField`, `EditText` | none found (weakest evidence in this table: absence of documentation, not a positive statement) | n/a | nowhere | undocumented |
| **Dioxus desktop** | wry webview ([docs](https://dioxuslabs.com/learn/0.7/guides/platforms/desktop/)) | none | yes | nothing built in | same as web |
| **Uno Platform**, native targets | native `TextBox` overlaid on a `TextBlock` | none | yes | nowhere | undocumented |

### Group (A): owns rendering, wrote its own text widget. The control group.

| Framework | Text undo API | App-level undo API | One unified history? | What owning it bought |
|---|---|---|---|---|
| **Swing** | `Document.addUndoableEditListener` | `javax.swing.undo.UndoManager` | **YES.** The only unambiguous case in the survey | one `UndoManager` per app absorbs text edits and app edits as `UndoableEdit`s |
| **Qt Widgets** | `QTextEdit::undoRedoEnabled`, `QTextDocument::undo()` | `QUndoStack` / `QUndoCommand` | **no**, two disjoint stacks | nothing: the document stack is not exposed, not replaceable, not `QUndoView`-compatible |
| **Godot** | `TextEdit`/`LineEdit` built-in, `begin_complex_operation()` grouping | `UndoRedo`, `EditorUndoRedoManager` | **no** | explicit grouping and a per-scene history model |
| **JavaFX** | `undo()`, `redo()`, `isUndoable()`, plus **observable** `undoableProperty()`/`redoableProperty()` ([javadoc](https://openjfx.io/javadoc/23/javafx.controls/javafx/scene/control/TextInputControl.html)) | none in the JDK | no | enablement that binds reactively instead of being polled |
| **Avalonia** | `TextBox` + internal `UndoRedoHelper<T>`, Ctrl+Z / Ctrl+Shift+Z with no app code | none in the framework | no | control of coalescing (snapshot before change, on selection change, every 7 typed chars) and of D7 |
| **Compose / Compose Multiplatform** | `TextFieldState.undoState`: `canUndo`, `canRedo`, `undo()`, `redo()`, `clearHistory()` | none | no | exactly the four levers kaya §1 needs. The legacy `CoreTextField` path hides an unreachable internal `UndoManager` |
| **Flutter** | `UndoHistory` + `UndoHistoryController` (sibling agent's territory) | none | no | a controller the app can drive; bridges to the platform undo manager on Apple targets |
| **Unity UI Toolkit** | **none.** `TextField` has no built-in undo | `Undo` class + `SerializedObject`/`SerializedProperty` | no, and the gap is a live defect (below) | data-level undo through serialization |
| **egui** | `TextEditState` + `Undoer<(CCursorRange, String)>`, whole-buffer snapshots | none | no | simplicity, at the cost that **redo still does not exist** ([#3447](https://github.com/emilk/egui/issues/3447)) |
| **Slint** | `TextInput` undo/redo, added in 1.5 (2024) | none | no | it took a rewrite of the text data structure to have any undo at all ([#1325](https://github.com/slint-ui/slint/issues/1325), [#474](https://github.com/slint-ui/slint/issues/474)) |
| **iced** | `text_editor::Action`; the app performs every edit action ([source](https://github.com/iced-rs/iced/blob/master/widget/src/text_editor.rs)) | none prebuilt | app's choice | the Elm answer: one event stream, so at most one history, but the app writes it |
| **Uno Platform**, Skia targets | Skia-drawn `TextBox` with undo/redo ([#9417](https://github.com/unoplatform/uno/issues/9417)) | none | no | undo/redo *at all*, which the native path did not have |
| **Kivy** | `TextInput.do_undo()`/`do_redo()`, on by default ([docs](https://kivy.org/doc/stable/api-kivy.uix.textinput.html)) | none | no | a reset method and Ctrl+Z/Ctrl+R wired for free |
| **Tk / Tkinter** | `Text` widget `-undo` option (**off by default**), `edit_undo`, `edit_redo`, `edit_separator`, `edit_reset` ([reference](https://anzeljg.github.io/rin2/book2/2405/docs/tkinter/text-undo-stack.html)) | none | no | `edit_separator`, an explicit "a step ends here" marker: the 1990s ancestor of kaya's D2 named group |
| **Delphi FireMonkey** | own-rendered controls | none | no | (parity with VCL, drawn rather than wrapped) |

---

## Group (B) in depth: the binding precedent

### React Native: the largest (B) framework in existence, and it has no app undo story at all

`TextInput` lowers to `UITextField`/`UITextView` and `EditText`, and RN documents it as a
controlled component: "the native value will be forced to match this `value` prop if
provided" ([TextInput docs](https://reactnative.dev/docs/textinput)). That one sentence
is the entire undo story, and it is a negative one.

* **No app-level undo API exists in React Native.** No manager, no command stack, no menu
  role. Every RN app that wants undo writes a reducer-history hook in JS, and that history
  has no relationship to the field's.
* **Cmd/Ctrl+Z reaches the native field.** RN ships no menu bar on any platform, so the
  chord is consumed by iOS's `_UITextUndoManager`, Android's `EditText`, or the macOS
  field editor. JS never sees it.
* **And the controlled model corrupts that native stack**
  ([#29572](https://github.com/facebook/react-native/issues/29572)): undo works exactly
  once and then stops; the ticket records UIKit crashes during undo; it was closed "not
  planned" and the only workaround is to go uncontrolled.

**Read for kaya:** the largest (B) framework declined to have an opinion, and the result
is that the platform's stack is the only stack *and* RN's own data flow breaks it. D5 and
D7 exist so kaya is not this.

### wxWidgets: the sharpest precedent, because wx has both stacks and never reconciled them

wxWidgets is the closest structural analogue to kaya: native controls plus a first-class
app command framework. The collision is visible in wx's own documentation.

* `wxTextCtrl`: "The following commands are processed by default event handlers in
  wxTextCtrl: `wxID_CUT`, `wxID_COPY`, `wxID_PASTE`, `wxID_UNDO`, `wxID_REDO`."
  ([interface/wx/textctrl.h](https://raw.githubusercontent.com/wxWidgets/wxWidgets/master/interface/wx/textctrl.h))
* Document/View overview: "If you wish to implement Undo/Redo, you need to derive your own
  class(es) from `wxCommand` and use `wxCommandProcessor::Submit` instead of directly
  executing code. The framework will take care of calling `Undo` and `Do` functions as
  appropriate, so long as the `wxID_UNDO` and `wxID_REDO` menu items are defined in the
  view menu."
  ([docs/doxygen/overviews/docview.h (gone)](https://raw.githubusercontent.com/wxWidgets/wxWidgets/master/docs/doxygen/overviews/docview.h))

Two subsystems, one command id, and **the docview overview never mentions text control
undo at all**. wx documents no precedence rule, no routing rule, and no way to ask "does
the focused control have something to undo". Whichever handler the event reaches first
wins, which depends on where the menu lives and what has focus. wx's own event overview
only says command events "are propagated by default to the parent window if they are not
processed in this window itself" and that "simple events such as menu commands are usually
processed at the level of a top-level window containing the menu"
([eventhandling.h](https://raw.githubusercontent.com/wxWidgets/wxWidgets/master/docs/doxygen/overviews/eventhandling.h)).

**And the chord-theft problem is in the forum, not the manual.** The thread
["Ctrl+Z accelerator and edit boxes"](https://forums.wxwidgets.org/viewtopic.php?t=419)
is a developer with app undo on Ctrl+Z discovering that the frame's accelerator table
stops the focused `wxTextCtrl` ever seeing the key. Every proposed fix is hand-written
routing: intercept the accelerator and test whether focus is a text box; use
`wxTextCtrl::MSWShouldPreMessage()` to let 'Z' and 'Y' through; push an extra
`wxEvtHandler` on the frame; override `wxApp::FilterEvent` and dispatch by hand.
Related threads confirm the ordering: key hook, then accelerator tables, then
`wxEVT_KEY_DOWN`, then `wxEVT_CHAR`
([forum](https://forums.wxwidgets.org/viewtopic.php?t=43492)).

**This is kaya's own measured Windows finding, reached independently by wxWidgets users
twenty years earlier and never fixed in the framework.** kaya §1.1: "the HOOK steals
Ctrl+Z from the TextBox ... So D6's routing on Windows lives INSIDE key_hook: ask the
focused editable's CanUndo, call its Undo(), consume." That is precisely the fix the wx
forum keeps re-deriving per app. kaya is about to put it in the framework.

### Electron and Tauri: the webview case, where the app cannot even see the text stack

Both host a webview whose `<input>`/`contenteditable` carries the browser's undo, an
implementation the app cannot enumerate, serialize or order against its own state.

Electron's answer is a menu **role**: `undo`, `redo`, `cut`, `copy`, `paste`,
`pasteAndMatchStyle`, `delete`, `selectAll`
([MenuItem docs](https://www.electronjs.org/docs/latest/api/menu-item)). `role: 'undo'`
resolves to `webContents.undo()`, "Executes the editing command undo in the web page"
([webContents docs](https://www.electronjs.org/docs/latest/api/web-contents)). Electron's
guidance is to prefer roles over click handlers "so the built-in role behavior will give
the best native experience". So **Electron's Edit>Undo routes to the focused widget,
always, because there is no app stack to route to.** Even that has a routing defect: role
commands go to `webContents.getFocusedWebContents()`, which "iterates through all existing
web contents and returns the first in the collection that is in a webview, otherwise the
first that returns true from `contents.isFocused()`", so with multiple windows the wrong
web contents can answer ([#6811](https://github.com/electron/electron/issues/6811)).

Tauri exposes the same idea as `PredefinedMenuItem::undo`
([Window Menu](https://v2.tauri.app/learn/window-menu/)), and its bug list reads as
routing that was inherited rather than designed: undo/redo shortcuts dead in editors on
macOS ([#10148](https://github.com/tauri-apps/tauri/issues/10148)), predefined undo/redo
items doing nothing when clicked on Windows
([#10694](https://github.com/tauri-apps/tauri/issues/10694)), and the broader macOS
lesson that **without a menu the native editing chords do not work at all**
([#2397](https://github.com/tauri-apps/tauri/issues/2397),
[#2398](https://github.com/tauri-apps/tauri/issues/2398)).

**Read for kaya:** every framework whose text widget is opaque converged on D1 plus D6:
delegate the text tier to whoever owns the widget, and expose one menu role that asks the
focused thing first. Electron is D1+D6 with the app tier simply missing.

### .NET MAUI and Xamarin.Forms: a (B) framework with neither kind of undo at the app level

`Entry` and `Editor` are documented as text input controls with no undo surface
([Entry](https://learn.microsoft.com/en-us/dotnet/maui/user-interface/controls/entry),
[Editor](https://learn.microsoft.com/en-us/dotnet/maui/user-interface/controls/editor)).
Every undo/redo capability in the MAUI ecosystem is third-party (Syncfusion's rich text
editor, image editor, PDF viewer). MAUI has **no application command or undo stack**.

The menu answer is entirely inherited. On Mac Catalyst, `MenuBar` maps to `UIMenuBuilder`,
`MenuBarItem` to `UIMenu`, `MenuFlyoutItem` to `UIAction`/`UICommand`
([docs](https://learn.microsoft.com/en-us/dotnet/maui/user-interface/menu-bar)), so Apple
populates the standard Edit menu including Undo and Redo, and the responder chain routes
it to the focused text field. MAUI apps that want the Edit menu gone must override
`BuildMenu` and remove it
([discussion #11672](https://github.com/dotnet/maui/discussions/11672),
[#7919](https://github.com/dotnet/maui/issues/7919)). Validating exactly those Undo/Redo
items across windows is a known Catalyst defect
([Apple forums](https://developer.apple.com/forums/thread/728086)).

**Read for kaya:** this is kaya §1.3 verbatim ("UIMenuBuilder already hands kaya an Edit
menu containing Undo/Redo"). MAUI receives the same gift and does nothing with it: the
item exists, works on text, and has no relationship to anything the app knows. kaya's D6
is the difference between MAUI's accident and a design.

### SWT and Eclipse: the one (B) stack that unified, by leaving (B)

* **SWT's native `Text`** inherits whatever the platform gives.
* **SWT's `StyledText`**, the widget every editor uses, is custom-drawn and has no undo,
  by design, not by oversight
  ([Eclipse Tiny Plugins](https://sourceforge.net/p/etinyplugins/blog/2013/02/add-undoredo-support-to-your-swt-styledtext-s/)).
* **JFace layers `IUndoManager` on the viewer** (`ITextViewer.setUndoManager`,
  [API](https://help.eclipse.org/latest/topic/org.eclipse.platform.doc.isv/reference/api/org/eclipse/jface/text/ITextViewer.html))
  and routes it into the workbench operation history, so typing undo and refactoring undo
  are one ordered history per context.

**Read for kaya:** this is the existence proof for a unified history, and its price is a
hand-written text widget with a document model, a selection model and range edits. That is
exactly the cost kaya's D8 names and defers ("an editor-grade text component with range
edits and a selection model, which no form-field textarea provides"). The survey confirms
the estimate: **nobody has ever bought a unified history for less.**

---

## Group (A) in depth enough to be a control group

* **Swing** is the unified case, and note what it gave up: no coalescing policy of its
  own, so every app writes `CompoundEdit` by hand and re-derives what a step is.
  ([javadoc](https://docs.oracle.com/javase/8/docs/api/javax/swing/undo/UndoManager.html))
* **Qt Widgets** owns rendering and ships two stacks anyway. The community answer to "can
  I merge them" is no. The blessed pattern is exactly kaya's D1: leave `undoRedoEnabled`
  true for typing, use `QUndoCommand`/`QUndoStack` for structural operations. Qt's undo
  framework does document the two features kaya's D2 needs, command *compression* ("in a
  text editor, the commands that insert individual characters into the document can be
  compressed into a single command that inserts whole sections of text") and *macros* ("a
  sequence of commands, all of which are undone or redone in one step")
  ([overview](https://doc.qt.io/qt-6/qundo.html)), and it applies neither to the text
  widget.
* **Godot**'s `begin_complex_operation()`/`end_complex_operation()` is the direct analogue
  of kaya's D2 named group, and "setting `text` clears the undo buffer" is the direct
  analogue of D7.
* **JavaFX** exposes `undoableProperty()`/`redoableProperty()` as observable properties.
  **Worth stealing for D6 enablement**, since kaya's design computes enablement live at
  activation, and JavaFX shows the reactive spelling of the same question.
* **Avalonia** publishes its coalescing policy (snapshot before change, on selection
  change, and every 7 typed characters) and copies WPF's clear-on-binding-change. It also
  went years with **no public way to invoke undo programmatically or query availability**
  ([#9433](https://github.com/AvaloniaUI/Avalonia/issues/9433)), which is a worse D6
  surface than WinUI's, in an (A) framework, because nobody asked for it.
* **Compose** is the clean before/after: the legacy `CoreTextField` path holds an internal
  `UndoManager` unreachable by type (kaya compile-proved this, §1.4), and the
  `TextFieldState` path exposes `canUndo`/`undo()`/`redo()`/`clearHistory()`. Owning the
  renderer let Google fix the surface; the old API is the (B)-shaped failure mode living
  inside an (A) framework.
* **egui** snapshots the whole buffer plus cursor, and still has no redo
  ([#3447](https://github.com/emilk/egui/issues/3447)). An immediate-mode framework can
  afford whole-state snapshots; kaya's core cannot, which is why D3's derived inverse is
  the right shape.
* **Slint** had no text undo until 1.5 (2024), and issue
  [#1325](https://github.com/slint-ui/slint/issues/1325) states the prerequisite plainly:
  a proper text editing data structure. Same lesson as Eclipse, from the other end.
* **iced** requires the app to `perform(action)` on every `text_editor::Action`, so text
  edits are already app-level messages. The Elm-architecture answer to the whole problem.
* **Tk** deserves a specific mention out of proportion to its relevance: `edit_separator`
  is an explicit "an undo step ends here" marker on the text widget, and undo is **off by
  default**. That is kaya's D2 (an explicitly declared undoable unit) and kaya's opt-in
  doctrine, both, from 1994.
* **Unity UI Toolkit** is the cautionary tale, quoted below.

---

## The question the review asked: does anyone in (B) unify, and how?

**No.** The complete list of mechanisms anyone has actually used, and what each costs:

| Mechanism | Who does it | Verdict |
|---|---|---|
| **Re-implement the text widget** | Eclipse/JFace (SWT `StyledText` + `IUndoManager` + `IOperationHistory`); Slint after #1325; every web editor (ProseMirror/CodeMirror/Monaco, sibling's territory) | **The only mechanism that works.** Cost: a document model, a selection model, range edits |
| **Take over the widget's undo manager** | AppKit only, via `windowWillReturnUndoManager:` | Works on macOS, exists nowhere else, and costs per-field granularity. kaya measured and rejected it (§1.2) |
| **Intercept the key chord and consume it** | JabRef on JavaFX: "We need to consume the key event to avoid the default behavior of undo/redo and enable JabRef's undo/redo" ([#11420](https://github.com/JabRef/jabref/issues/11420)) | Application-level hack. It suppresses typing undo rather than unifying it: the user loses per-keystroke undo inside the field entirely. JabRef reached it *after* the dual systems collided and JavaFX's internal undo state went null |
| **Suppress native undo per widget** | GTK (`enable-undo`), SwiftUI (`undoManager?.disableUndoRegistration()`) | Available on some platforms. kaya already established the suppression matrix fails on WinUI, iOS and legacy Compose (§0) |
| **Do nothing and let the two stacks coexist** | React Native, MAUI, Xamarin.Forms, Windows Forms, Delphi VCL, NativeScript, wxWidgets in practice, Qt in practice, Godot in practice | The overwhelming majority |

And here is what "do nothing" costs, in a shipped product, stated by the vendor. Unity UI
Toolkit's `TextField` has no built-in undo, so Ctrl+Z inside a text field falls through to
the editor's asset-level `Undo`, and "this undo operation actually undoes some previous
modification to an asset, **which the user may not even notice**"
([Unity Discussions](https://discussions.unity.com/t/undo-support-for-the-textfield/948708)).
That is the ordering anomaly in its purest form: the chord silently reverted something
else. Unity's own moderators then state kaya's D4 almost word for word: "The UI is only a
view of your data and cannot generally handle undo. Undo needs to be handled in your data
to ensure consistency."

---

## What this means for the decision in front of you

### 1. D1 (two tiers, one surface) should stand. The survey found no toolkit that beat it without writing a text widget, and most (A) toolkits chose it voluntarily.

The strongest possible attack on D1 was "kaya is only doing this because it lowers to
native; a better-architected framework would have one stack." That attack fails. Qt owns
its text widgets and chose two stacks. Godot owns its text widgets and chose two stacks.
Avalonia, JavaFX, Compose, Flutter, egui, Slint and Kivy all own their text widgets and
ship a text-local undo with no app-level history to unify with. The only unified designs
in the survey are Swing (one process, one language, one widget set, and every app writes
its own coalescing) and Eclipse (which paid for a text widget). D1 is the norm, not the
compromise.

### 2. D6 (focused-text-first routing) is the piece with the most precedent and the least written down. Document it as a rule, because nobody else did, and that is why their users get hurt.

Every (B) framework surveyed has the routing question and none answers it in its
documentation:

* wxWidgets has two subsystems claiming `wxID_UNDO` and a doc page for each that never
  mentions the other.
* Electron routes to focus and then gets focus wrong across windows.
* MAUI inherits Apple's Edit menu and never mentions it.
* Unity lets the chord fall through to a different subsystem entirely and calls the result
  a documentation issue.
* JabRef had to consume the key event after JavaFX's internal undo state was corrupted by
  double handling.

AppKit is the only place the rule is written down, and kaya §1.2 confirms `NSApp`'s
`undo:` path already implements focused-text-first *with fall-through*. **kaya's D6 is
the generalization of the one platform that got it right, applied to four backends.**
The specific thing to preserve, and to state as normative in DESIGN.md rather than leave
implicit, is the **fall-through**: mid-typing Cmd+Z means the typing, and the *second*
Cmd+Z means the app action. iOS's `sendAction(undo:)` never falls through (kaya §1.3), so
kaya writes it by hand there; that is the clause most likely to diverge across backends
and the one that deserves the byte-compared scene.

### 3. D7 is not a defect fix, it is the industry's rule. Say so, and take the free strictness.

WPF, Avalonia, Godot, Compose and Windows Forms all arrived at "an app write invalidates
the field's edit history", by four independent routes. kaya's D7 has better evidence
behind it than any other decision in §0. Two consequences worth acting on:

* **The rule is worth stating positively in the guest-facing docs**, not as a caveat.
  "An app overwrite invalidates the field's edit history" is what a WPF, Avalonia or
  Compose developer already expects.
* **The counterexample is the one to guard against.** React Native's #29572 is what
  happens when a framework pushes app state into a native field on every change *without*
  deciding this: undo works once and then silently stops. kaya's uncontrolled-toward-the-app
  text widgets plus D7 avoid it structurally, but the negative test kaya §1.2 already
  specifies (type, keep focus, write, assert `canUndo == false`) is exactly the test RN
  never had.

### 4. Two scoping statements the survey says kaya should make explicit, since they cost nothing today and a lot later.

* **Say out loud that a unified history requires an editor-grade text component, and that
  kaya has not bought one.** D8 already defers this; the survey turns the deferral into a
  citable fact rather than a judgment call. Eclipse, Slint and every web editor paid the
  same bill. Anyone who later asks kaya for "one undo history including typing" is asking
  for a text widget, and it is cheaper to have written that sentence down now.
* **Say that the core tier is opt-in and that the native tier is per-widget opt-out-able
  in principle.** D8 already names the per-widget opt-out as an extension point. The
  survey supplies the concrete artifact that will demand it: any app whose document lives
  in an app-owned model (CRDT or not) hits the JabRef failure, where two undo systems
  process the same chord and one of them corrupts its own state. JabRef's fix, consuming
  the key event, is exactly what a per-widget opt-out would provide as a supported
  feature.

### Nothing in this survey argues for replacing the design. One thing argues for a small addition.

JavaFX's `undoableProperty()` and Avalonia's missing programmatic surface together make
one point: **the enablement question must be a first-class, cheap, live query, not a
side effect of the menu refresh.** kaya's D6 computes it "live at activation exactly as
paste's offer∩accepts is", which is right; the survey's warning is Avalonia's, where the
query existed internally for years but was never exposed, so nothing outside the widget
could ask. kaya has four backends and a menu-role filter that D6 already flags as four
silent-failure sites. Making "can the focused widget undo?" a named, testable core-side
query, rather than a per-backend expression inside each enablement refresh, is the cheap
guard that matches invariant 3.

---

## Sources

React Native / React
[TextInput docs](https://reactnative.dev/docs/textinput) ·
[react-native#29572](https://github.com/facebook/react-native/issues/29572) ·
[react-native#43684](https://github.com/react/react-native/issues/43684) ·
[react#17494](https://github.com/facebook/react/issues/17494) ·
[react-native-macos#2075](https://github.com/microsoft/react-native-macos/issues/2075)

wxWidgets
[interface/wx/textctrl.h](https://raw.githubusercontent.com/wxWidgets/wxWidgets/master/interface/wx/textctrl.h) ·
[docs/doxygen/overviews/docview.h (gone)](https://raw.githubusercontent.com/wxWidgets/wxWidgets/master/docs/doxygen/overviews/docview.h) ·
[eventhandling.h](https://raw.githubusercontent.com/wxWidgets/wxWidgets/master/docs/doxygen/overviews/eventhandling.h) ·
[wxCommandProcessor](https://docs.wxwidgets.org/3.2/classwx_command_processor.html) ·
[forum: Ctrl+Z accelerator and edit boxes](https://forums.wxwidgets.org/viewtopic.php?t=419) ·
[forum: intercepting accelerators inside TextCtrl](https://forums.wxwidgets.org/viewtopic.php?t=43492)

MAUI / Xamarin / WinForms / WPF
[Entry](https://learn.microsoft.com/en-us/dotnet/maui/user-interface/controls/entry) ·
[Editor](https://learn.microsoft.com/en-us/dotnet/maui/user-interface/controls/editor) ·
[menu bar](https://learn.microsoft.com/en-us/dotnet/maui/user-interface/menu-bar) ·
[maui#11672](https://github.com/dotnet/maui/discussions/11672) ·
[maui#7919](https://github.com/dotnet/maui/issues/7919) ·
[TextBoxBase.ClearUndo](https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.textboxbase.clearundo) ·
[TextBoxBase.CanUndo](https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.textboxbase.canundo)

SWT / Eclipse / Swing / JavaFX
[StyledText has no undo](https://sourceforge.net/p/etinyplugins/blog/2013/02/add-undoredo-support-to-your-swt-styledtext-s/) ·
[ITextViewer](https://help.eclipse.org/latest/topic/org.eclipse.platform.doc.isv/reference/api/org/eclipse/jface/text/ITextViewer.html) ·
[javax.swing.undo.UndoManager](https://docs.oracle.com/javase/8/docs/api/javax/swing/undo/UndoManager.html) ·
[JavaFX TextInputControl](https://openjfx.io/javadoc/23/javafx.controls/javafx/scene/control/TextInputControl.html) ·
[JabRef#11420](https://github.com/JabRef/jabref/issues/11420)

Electron / Tauri / Dioxus
[MenuItem roles](https://www.electronjs.org/docs/latest/api/menu-item) ·
[webContents](https://www.electronjs.org/docs/latest/api/web-contents) ·
[electron#6811](https://github.com/electron/electron/issues/6811) ·
[Tauri window menu](https://v2.tauri.app/learn/window-menu/) ·
[tauri#10148](https://github.com/tauri-apps/tauri/issues/10148) ·
[tauri#10694](https://github.com/tauri-apps/tauri/issues/10694) ·
[tauri#2397](https://github.com/tauri-apps/tauri/issues/2397) ·
[tauri#2398](https://github.com/tauri-apps/tauri/issues/2398) ·
[Dioxus desktop](https://dioxuslabs.com/learn/0.7/guides/platforms/desktop/)

Qt / Godot / Unity
[QUndoStack](https://doc.qt.io/qt-6/qundostack.html) ·
[Qt undo framework](https://doc.qt.io/qt-6/qundo.html) ·
[QTextDocument stack inaccessible](https://forum.qt.io/topic/29922/how-can-i-show-the-qtextdocument-undo-stack-in-qundoview) ·
[customizing QTextEdit undo](https://forum.qt.io/topic/157587/how-to-customize-undo-redo-for-qtextedit) ·
[Godot UndoRedo](https://docs.godotengine.org/en/stable/classes/class_undoredo.html) ·
[Godot EditorUndoRedoManager](https://docs.godotengine.org/en/stable/classes/class_editorundoredomanager.html) ·
[Godot TextEdit clears on set](https://bugnet.io/blog/fix-godot-text-edit-undo-history-cleared-on-text-set) ·
[Unity UI Toolkit TextField undo](https://discussions.unity.com/t/undo-support-for-the-textfield/948708)

Avalonia / Compose / Flutter / egui / Slint / iced / Uno / Kivy / Tk / Delphi
[Avalonia PR#1450](https://github.com/AvaloniaUI/Avalonia/pull/1450) ·
[Avalonia#336](https://github.com/AvaloniaUI/Avalonia/issues/336) ·
[Avalonia#9433](https://github.com/AvaloniaUI/Avalonia/issues/9433) ·
[Avalonia#5795](https://github.com/AvaloniaUI/Avalonia/issues/5795) ·
[TextFieldState API](https://composables.com/jetpack-compose/androidx.compose.foundation/foundation/classes/TextFieldState/api) ·
[egui#3447](https://github.com/emilk/egui/issues/3447) ·
[slint#474](https://github.com/slint-ui/slint/issues/474) ·
[slint#1325](https://github.com/slint-ui/slint/issues/1325) ·
[iced text_editor](https://github.com/iced-rs/iced/blob/master/widget/src/text_editor.rs) ·
[uno#9417](https://github.com/unoplatform/uno/issues/9417) ·
[Kivy TextInput](https://kivy.org/doc/stable/api-kivy.uix.textinput.html) ·
[Tk Text undo stack](https://anzeljg.github.io/rin2/book2/2405/docs/tkinter/text-undo-stack.html) ·
[Vcl.StdCtrls.TMemo](https://docwiki.embarcadero.com/Libraries/Sydney/en/Vcl.StdCtrls.TMemo)

Apple
[Using Undo in AppKit-Based Applications](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/AppKitUndo.html) ·
[UITextView custom NSUndoManager breaks keyboard undo button](https://developer.apple.com/forums/thread/715693) ·
[Catalyst menu validation](https://developer.apple.com/forums/thread/728086)
