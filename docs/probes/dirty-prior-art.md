# Dirty-state window chrome: prior art survey

PROBE arm — prior art. Nothing here ships; no repo file was touched. Measurements
are from primary sources: framework source trees fetched from upstream, and SDK
headers on this machine. Secondary sources are cited only where no primary source
exists.

Method: fetched upstream sources with `curl` into the scratchpad and grepped them
with python; read the macOS 14.4 SDK headers out of the nix store
(`/nix/store/mxzgf8zlr2mbxrqp1ami2ixqsqpskv0w-apple-sdk-14.4`). Where a claim
rests on a doc page rather than source, the URL is given inline.

Every section answers three questions:
1. **API shape** — what does the app author write?
2. **Per-platform lowering** — what does each backend actually do with it?
3. **Platforms with no convention** — what did they choose there?
plus **observability** — could a harness leg read the result back?

---

## 1. Qt — `setWindowModified()` + the `[*]` title placeholder

The closest thing in existence to what kaya is proposing: one declarative boolean
on the window, lowered per platform, with a defined fallback.

### API shape

```cpp
// QWidget
Q_PROPERTY(bool windowModified READ isWindowModified WRITE setWindowModified)
w->setWindowTitle("document1.txt[*] - Text Editor");
w->setWindowModified(true);
```

Two coupled properties: a boolean, and a **title template** that says where the
marker goes. From `qwidget.cpp` (property docs, verbatim):

> A modified window is a window whose content has changed but has not been saved
> to disk. This flag will have different effects varied by the platform. On
> \macos the close button will have a modified look; on other platforms, the
> window title will have an '*' (asterisk).
>
> The window title must contain a "[*]" placeholder, which indicates where the
> '*' should appear. Normally, it should appear right after the file name (e.g.,
> "document1.txt[*] - Text Editor"). If the window isn't modified, the
> placeholder is simply removed.

### Per-platform lowering — the mechanism is a *fallback*, not a switch

`QWidgetPrivate::setWindowModified_helper()` (qtbase `src/widgets/kernel/qwidget.cpp`):

```cpp
    bool on = q->testAttribute(Qt::WA_WindowModified);
    if (!platformWindow->setWindowModified(on)) {
        if (Q_UNLIKELY(on && !q->windowTitle().contains("[*]"_L1)))
            qWarning("QWidget::setWindowModified: The window title does not contain a '[*]' placeholder");
        setWindowTitle_helper(q->windowTitle());
        setWindowIconText_helper(q->windowIconText());
    }
```

`QPlatformWindow::setWindowModified()` returns **bool = "the native window
handled it"** (`src/gui/kernel/qplatformwindow.cpp`):

```cpp
/*!
    Reimplement to be able to let Qt indicate that the window has been
    modified. Return true if the native window supports setting the modified
    flag, false otherwise.
*/
bool QPlatformWindow::setWindowModified(bool modified)
{
    Q_UNUSED(modified);
    return false;
}
```

Measured, by grepping each platform plugin on `qtbase/dev`:

| QPA plugin | implements `setWindowModified`? | result |
|---|---|---|
| cocoa (`qcocoawindow.mm`) | yes | `m_view.window.documentEdited = modified; return true;` — native dot in the close button, title untouched |
| windows (`qwindowswindow.cpp`) | **no** (0 hits) | base returns false → Qt rewrites the title string |
| xcb (`qxcbwindow.cpp`) | **no** (0 hits) | base returns false → Qt rewrites the title string |

So: **native where a convention exists, synthesized title marker everywhere
else**, decided by a virtual that reports its own capability. The app writes one
boolean and one title template; it never branches on platform.

Two further details worth stealing or rejecting:

- **The fallback is style-gated.** The substitution in
  `qt_setWindowTitle_helperHelper()` only inserts `*` if
  `QStyle::SH_TitleBar_ModifyNotification` is true. `QCommonStyle` returns
  `true`; `QMacStyle` returns `false` (`qmacstyle_mac.mm`). So even the fallback
  is a per-look-and-feel decision, not a hard-coded one.
- **The placeholder has an escape.** `[*][*]` is a literal `[*]`; an odd run of
  placeholders substitutes the last one. The helper's own comment: "This
  function assumes that `[*]` can be quoted by another `[*]`". A title-template
  design has to answer escaping, and Qt's answer is doubling.

Missing placeholder is a **runtime warning, not a compile error** — the C++
compiler cannot see the title string. This is a well-known papercut (e.g.
[orange3#3267](https://github.com/biolab/orange3/issues/3267),
[Qt forum](https://forum.qt.io/topic/2070/solved-qwidget-setwindowmodified-the-window-title-does-not-contain-a-placeholder)).
For kaya this is the interesting failure: a template-based design puts a
constraint on a *string* that no type system sees. Qt's own answer is a warning
that fires only when the window is dirty AND the platform has no native support —
i.e. the worst possible discoverability.

Also: `setWindowModified_helper()` is re-invoked at native-window creation time
(`qwidget.cpp` `create_sys`), so the flag survives window recreation. Any kaya
backend that owns a native handle has the same obligation.

`windowModified` is **QWidget-only**. There is no `QWindow::windowModified`,
hence none in Qt Quick / QML — a QML app has to reach the C++ side or hand-roll
the title. The property also propagates *up* the widget parent chain when set
true (but not when cleared), a widget-tree quirk with no analogue in kaya.

### Observability

`QWidget::setWindowModified()` sends `QEvent::ModifiedChange` to the widget, so
in-process observation is available. Externally: on Windows/X11 the state **is**
the title string, so any window-title read sees it; on macOS the state is in the
NSWindow and not in the title, so a title read sees nothing. Qt gives an external
harness no uniform read path — the same asymmetry kaya will hit.

---

## 2. Electron — `setDocumentEdited()`, macOS-only, silent elsewhere

### API shape

```js
win.setDocumentEdited(true)   // macOS
win.isDocumentEdited()        // macOS
win.setRepresentedFilename('/path/to/file')  // macOS
```

Docs annotate all three "macOS"
([BrowserWindow](https://www.electronjs.org/docs/latest/api/browser-window),
[Representing Files in a BrowserWindow](https://www.electronjs.org/docs/latest/tutorial/represented-file)):
"Sets whether the window's document has been edited, and the icon in title bar
will become gray when set to `true`."

### Per-platform lowering — silent no-op, and the API is still callable

Measured in the Electron tree (`main`):

- `shell/browser/api/electron_api_base_window.cc` registers the methods
  **unconditionally**, on every platform:
  `.SetMethod("setDocumentEdited", &BaseWindow::SetDocumentEdited)`.
- `shell/browser/native_window.h` gives the base class an empty body:
  `virtual void SetDocumentEdited(bool edited) {}`
- `shell/browser/native_window.cc`: `bool NativeWindow::IsDocumentEdited() const { return false; }`
- `shell/browser/native_window_mac.mm`:
  ```objc
  void NativeWindowMac::SetDocumentEdited(bool edited) {
    [window_ setDocumentEdited:edited];
    if (buttons_proxy_) [buttons_proxy_ redraw];
  }
  bool NativeWindowMac::IsDocumentEdited() const { return [window_ isDocumentEdited]; }
  ```

So Electron's answer for Windows/Linux is: **accept the call, do nothing, and
report clean**. Round-tripping is broken by construction on those platforms —
`setDocumentEdited(true)` then `isDocumentEdited()` returns `false`. (A widely
repeated claim that "on Linux the setter is a no-op but the getter returns true"
is wrong; the source above says `return false`. That claim is attached to
`setMinimizable` in the Electron docs, not to this API.)

Note the contrast with Qt: same underlying native call on macOS, but Electron
does **not** synthesize a title marker anywhere. Apps do that themselves.

### What Electron apps actually do on Windows/Linux — VS Code

VS Code exposes the marker as a **user-configurable title template** with a
`${dirty}` variable:
`"window.title": "${dirty}${activeEditorShort}${separator}${rootName}${separator}${appName}"`
— documented as "a dirty indicator if the active editor is dirty"
([Custom Layout](https://code.visualstudio.com/docs/configure/custom-layout),
[Variables reference](https://code.visualstudio.com/docs/reference/variables-reference)).
This is Qt's `[*]` design pushed all the way out to end-user configuration: the
app does not choose *where* the marker goes; the user's template does.

### Observability

macOS: `isDocumentEdited()` round-trips in-process. Windows/Linux: nothing at the
window level; the marker lives in the title string if the app put it there.

---

## 3. wxWidgets — name the platform in the API

### API shape

From `interface/wx/toplevel.h` (upstream `master`), verbatim:

```
    /**
        This function sets the wxTopLevelWindow's modified state on macOS,
        which currently draws a black dot in the wxTopLevelWindow's close button.
        On other platforms, this method does nothing.

        @see OSXIsModified()
    */
    virtual void OSXSetModified(bool modified);

    /**
        Returns the current modified state of the wxTopLevelWindow on macOS.
        On other platforms, this method does nothing.

        @see OSXSetModified()
    */
    virtual bool OSXIsModified() const;
```

### Per-platform lowering

macOS only, and **the API name says so** — `OSXSetModified`, not `SetModified`.
wxWidgets, a cross-platform toolkit, declined to give this a cross-platform
spelling. Its sibling `SetRepresentedFilename()` took the opposite choice —
platform-neutral name, macOS-only effect, with an explicit forward-looking
promise: "Under other platforms it currently doesn't do anything but it is
harmless to call it now and it might be implemented to do something useful in
the future so you're encouraged to use it for any window representing a
file-based document."

So one library contains **both** answers to the no-convention question, and the
difference is visible in the name. Worth noting for kaya: a platform-named prop
is an admission that the semantics are not uniform, which invariant 1 forbids.

---

## 4. Java — AWT/Swing has a macOS-only client property; JavaFX has nothing

### API shape (Swing)

```java
frame.getRootPane().putClientProperty("Window.documentModified", Boolean.TRUE);
```

Measured in OpenJDK `master`:

- `src/java.desktop/macosx/classes/sun/lwawt/macosx/CPlatformWindow.java`:
  ```java
  public static final String WINDOW_DOCUMENT_MODIFIED = "Window.documentModified";
  ...
  static final int DOCUMENT_MODIFIED = 1 << 21;
  ...
  new Property<CPlatformWindow>(WINDOW_DOCUMENT_MODIFIED) { public void applyProperty(final CPlatformWindow c, final Object value) {
      c.setStyleBits(DOCUMENT_MODIFIED, value == null ? false : Boolean.parseBoolean(value.toString()));
  }},
  ```
- `src/java.desktop/macosx/native/libawt_lwawt/awt/AWTWindow.m`:
  ```objc
  if (IS(mask, DOCUMENT_MODIFIED)) {
      [self.nsWindow setDocumentEdited:IS(bits, DOCUMENT_MODIFIED)];
  }
  ```

The whole feature lives in the **macosx** source directory. On Windows and Linux
the client property is an untyped string key that nothing reads — a silent no-op
with no compile-time or runtime signal at all. This is the weakest form of the
Electron answer: no cross-platform API surface, only a stringly-typed key that
happens to be honored by one port. Note also `"Window.documentFile"` next to it,
the represented-file sibling.

JavaFX (`javafx.stage.Stage`) has no modified/edited property in any released
version — the public API is `title`, `icons`, `resizable`, `fullScreen`, etc.
JavaFX apps do the asterisk in the title by hand.

---

## 5. Tk — the state is a window attribute, and it is honest about scope

```tcl
wm attributes .top -modified 1
wm attributes .top -titlepath /path/to/file
```

From the Tk `wm` man page ([tcl9.0](https://www.tcl-lang.org/man/tcl9.0/TkCmd/wm.html)),
under the macOS-specific attribute list, verbatim:

> **-modified** — Specifies the modification state of the window (determines
> whether the window close widget contains the modification indicator and
> whether the proxy icon is draggable).

`-modified` is listed only for macOS; Windows gets `-disabled`, `-toolwindow`,
`-transparentcolor`. Tk's answer to the no-convention platforms is the
Electron/Java answer (nothing), but the *shape* is different and interesting for
kaya: the flag is a **window attribute in a uniform namespace**, queried the same
way it is set (`wm attributes .top -modified` returns the value), rather than a
method. Tk also documents the second effect nobody else mentions: on macOS the
modified state also **disables dragging of the proxy icon**.

---

## 6. Apple — the three layers, and what each one adds

macOS is the only platform in kaya's set with a real OS-level convention, and it
has three separable layers.

### Layer 1: `NSWindow.isDocumentEdited` (raw chrome)

SDK header `AppKit.framework/Headers/NSWindow.h`:

```objc
@property (getter=isDocumentEdited) BOOL documentEdited;
```

A plain settable boolean on the window. Effect: the dot in the close button (and
per Tk's docs, proxy-icon drag behavior). No dialog, no save flow, no title
change. This is what Qt/Electron/wx/AWT/Tk all reach for.

### Layer 2: `NSDocument` change count (the document machinery)

`AppKit.framework/Headers/NSDocument.h`:

```objc
@property (getter=isDocumentEdited, readonly) BOOL documentEdited;
- (void)updateChangeCount:(NSDocumentChangeType)change;   // NSChangeDone / Undone / Redone / Cleared / Autosaved / ReadOtherContents, | NSChangeDiscardable
@property (readonly) BOOL hasUnautosavedChanges;
```

The header states the wiring to layer 1 explicitly: `updateChangeCount:`'s
"default implementation of this method also sends all of the document's window
controllers `-setDocumentEdited:` messages when appropriate", and
`NSWindowController.h`: "NSDocument calls this method for its window controllers
whenever the document is made dirty or clean. By default this calls
`-setDocumentEdited:` on the controller's window (if any)."

What the document layer adds over the raw boolean:

- **Dirty is derived, not asserted.** "NSDocument's built-in undo support uses
  this whenever a document receives an `NSUndoManagerWillCloseUndoGroupNotification`"
  — the change count is driven by the undo manager, and undoing back past the
  save point clears it. An app only calls `updateChangeCount:` by hand "if it is
  not taking advantage of NSDocument's built-in undo support."
- **The close flow.** `canCloseDocumentWithDelegate:shouldCloseSelector:contextInfo:`
  is the built-in confirm sheet, and the header is explicit that it has **two
  behaviors**:

  > If `[[self class] autosavesInPlace]` returns YES and `[self fileURL]`
  > returns non-nil then it simply invokes
  > `[self autosaveWithImplicitCancellability:NO completionHandler:...]` ...
  > Otherwise it presents a panel giving the user the choice of canceling,
  > discarding changes, or saving.

  So on modern (autosaving) documents there is **no confirm dialog at all** —
  closing just saves. The "Do you want to save the changes?" sheet is the legacy
  path. This matters for kaya: "dirty" on macOS does not imply a confirm dialog;
  Apple's own machinery deliberately removes it when the document autosaves.
- **Two distinct dirty bits.** `isDocumentEdited` (unsaved vs the file) and
  `hasUnautosavedChanges` (unsaved vs the autosave snapshot). A single boolean
  prop is a simplification Apple explicitly did not make.
- `NSChangeDiscardable` — a change that dirties the document but may be thrown
  away rather than prompting. A third state hiding inside the boolean.

### Layer 3: SwiftUI — no dirty API at all

Measured against the shipped SwiftUI interface in the macOS 14.4 SDK
(`SwiftUI.framework/.../arm64e-apple-macos.swiftinterface`, 28,953 lines):

| pattern | hits |
|---|---|
| `documentEdited` | **0** |
| case-insensitive `\bedited\b` | **0** |
| `isModified` | **0** |
| `navigationDocument` | 6 (represented file / share preview only) |
| `DocumentGroup`, `FileDocument`, `ReferenceFileDocument` | present |

`FileDocumentConfiguration` exposes exactly `document` (a `Binding`), `fileURL`,
`isEditable`. `ReferenceFileDocumentConfiguration` exposes `document` (an
`ObservedObject`), `fileURL`, `isEditable`. Neither has a modified flag.

SwiftUI's design: **dirty is implicit and inferred**. Mutating the document
binding (value type) or registering an undo (reference type) moves the underlying
`NSDocument` change count, which drives the close-button dot and the save flow
with no app-visible boolean. There is no supported way to say "this window is
dirty" for a plain `WindowGroup` scene — which is exactly kaya's shape. A kaya
SwiftUI backend cannot express this in SwiftUI vocabulary; it has to reach the
`NSWindow` and set `isDocumentEdited`, i.e. do what Qt/Electron/AWT/Tk do. (What
that costs is the macOS probe arm's measurement, not mine.)

### Observability on macOS — there is a real AX attribute

This is the strongest observability finding in the survey. From
`AppKit.framework/Headers/NSAccessibilityConstants.h`, line 59, verbatim
including the comment:

```objc
APPKIT_EXTERN NSAccessibilityAttributeName const NSAccessibilityEditedAttribute;		//(NSNumber *) - (boolValue) is it dirty?
```

and `NSAccessibilityProtocols.h` lines 377-378:

```objc
// Invokes when clients request NSAccessibilityEditedAttribute
@property (getter = isAccessibilityEdited) BOOL accessibilityEdited API_AVAILABLE(macos(10.10));
```

The matching Carbon-era constant is in
`HIServices.framework/Headers/AXAttributeConstants.h`:

```c
#define kAXEditedAttribute				CFSTR("AXEdited")
```

(listed under "miscellaneous or role-specific attributes"; unlike its neighbours
it carries no documentation block in the header).

So `AXEdited` is a defined, standard AX attribute whose documented meaning is
literally "is it dirty?", and it is overridable per element. **Whether AppKit
populates it automatically on an `NSWindow` from `isDocumentEdited`, or whether
the backend must implement `isAccessibilityEdited` itself, is a measurement for
the macOS probe arm** — the API surface exists either way, so a harness leg on
macOS has a candidate read path that does not involve the title string.

---

## 7. Linux — nothing exists at any layer (measured)

Three layers checked, all upstream `main`:

| layer | file | `modif`/`dirty`/`edited` hits |
|---|---|---|
| Wayland protocol | `wayland-protocols` `stable/xdg-shell/xdg-shell.xml` | 0 (the single `modify` hit is the MIT licence text) |
| GDK4 toplevel | `gtk/gdk/gdktoplevel.c` | 0 |
| GTK4 window | `gtk/gtk/gtkwindow.c` | 0 (`modified` appears only in the 1997 copyright header and an unrelated comment) |

`xdg_toplevel`'s complete request list is `destroy, set_parent, set_title,
set_app_id, show_window_menu, move, resize, set_max_size, set_min_size,
set_maximized, unset_maximized, set_fullscreen, unset_fullscreen, set_minimized`
— and its state enum is `maximized, fullscreen, resizing, activated, tiled_*,
suspended, constrained_*`. No modified state exists to set.

`GdkToplevel`'s complete property list: `state, title, startup-id,
transient-for, modal, icon-list, decorated, deletable, fullscreen-mode,
shortcuts-inhibited, capabilities, gravity`. No modified property.

So on Linux the title string is the only channel, full stop. Any backend that
wants to show dirty **must** synthesize it into the title.

### What Linux apps chose

- **GNOME HIG 2.2.1** (the old one) was prescriptive: "When a document has
  pending changes, insert an asterisk (\*) at the **beginning** of the window
  title. For example, `*Unsaved Drawing`, `*AnnualReport`." Note this is the
  opposite end of the string from Qt's convention (right after the file name).
  It also specified the confirm alert: "Save changes to document `Document Name`
  before closing?" with "If you close without saving, changes from the last
  `Time Period` will be discarded."
- **The current GNOME HIG** (developer.gnome.org/hig) says **nothing** about
  unsaved-change indicators. The windows pattern page covers primary/secondary
  windows and size restoration; the dialogs page only says destructive actions
  need a confirmation or an undo. The prescription was dropped, not replaced.
- **GNOME Text Editor** (the current GNOME editor) took the Apple-2011 route
  instead of a marker: it keeps an `is-modified` property whose documentation
  reads "The editor always saves modified files, however they are stored as
  **drafts** until the user chooses to save them to disk"
  (`src/editor-page.c`), and shows the word `Draft` in the title/subtitle
  (`_("Draft")`). No asterisk, no close-confirm dialog — the state is named in
  words, and the data is never at risk.

### Observability on Linux

AT-SPI2's state set (`atspi/atspi-constants.h`, upstream `main`) has 45 states.
The only match for edit-related words is `ATSPI_STATE_EDITABLE`, which means
"the user can edit this", not "this has unsaved edits". There is no
`ATSPI_STATE_MODIFIED`. A harness leg on Linux can only read the accessible
name/title string — so on Linux, "assert the chrome" and "assert the title
string" are the same assertion.

---

## 8. Windows — no OS convention, no API, and no accessibility property

- No Win32 or Windows App SDK API for document-modified state. WinUI 3's
  `AppWindow.Title` / `TitleBar.Title` are plain strings; the current
  [TitleBar control guidance](https://learn.microsoft.com/en-us/windows/apps/design/controls/title-bar)
  never mentions unsaved changes. Its one adjacent suggestion is to put **state
  words** in the title area: the title bar "can include other relevant
  information, such as a document title or the current state (e.g., 'Editing,'
  'Viewing,' etc.)".
- The de-facto convention is an asterisk, applied by apps, usually as a
  **prefix**. Notepad has done `*Untitled - Notepad` since Windows 10 1903
  ([Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/3233071/asterisk-in-title-of-untitled-notepad-file)).
  Not everyone participates: Word and Excel show nothing in the title.
- Qt's fallback (`*` at the `[*]` position) and VS Code's `${dirty}` template are
  what cross-platform toolkits ship here.

### Observability on Windows

The UI Automation Window control pattern's complete required member list is
`InteractionState, IsModal, IsTopmost, Maximizable, Minimizable, VisualState`
plus `Close`, `SetVisualState`, `WaitForInputIdle` and the open/close events
([Microsoft Learn](https://learn.microsoft.com/en-us/dotnet/framework/ui-automation/implementing-the-ui-automation-window-control-pattern)).
There is no modified/edited/dirty property. As on Linux: the title string is the
only external read path.

---

## 9. Mobile — there is no chrome to lower onto

kaya has iOS and Android backends, and this is where every desktop convention
runs out.

- **iOS/iPadOS**: no window title bar. The document machinery still exists —
  `UIDocument.hasUnsavedChanges` / `updateChangeCount(_:)` — but it drives
  *saving*, not chrome ([Change Tracking and Undo Operations](https://developer.apple.com/library/ios/documentation/DataManagement/Conceptual/DocumentBasedAppPGiOS/ChangeTrackingUndo/ChangeTrackingUndo.html)).
  SwiftUI's `DocumentGroup` is available on iOS and, like on macOS, exposes no
  edited flag at all (measured above: 0 hits for `edited` in the whole SwiftUI
  interface). The platform answer is autosave: there is nothing to mark because
  nothing is at risk.
- **Android**: no window chrome, and no system surface that carries per-window
  document state. Compose/Android apps show dirty in their own UI (a disabled
  Save button, a "Draft" label) and, if they confirm on exit, do it with an
  `OnBackPressedCallback` and a dialog they own.
- **Compose Multiplatform on desktop** is Swing-backed: `FrameWindowScope`
  exposes the `ComposeWindow` (a `JFrame`), so the OpenJDK
  `"Window.documentModified"` client property from §4 is reachable —
  Compose itself adds no dirty API
  ([Top-level windows management](https://kotlinlang.org/docs/multiplatform/compose-desktop-top-level-windows-management.html)).
  Not kaya's configuration (kaya's Compose backend is Android), but it shows
  the ceiling: even on desktop, Compose has nothing of its own.

---

## 10. Flutter — not in the framework, macOS-only in a plugin

Flutter has no window-chrome dirty API. The community plugin
[`macos_window_utils`](https://github.com/macosui/macos_window_utils.dart)
advertises "Methods to mark a window as 'document edited'" and implements them
as a method channel onto `NSWindow` (`lib/window_manipulator.dart`):

```dart
  /// Sets the document to be edited.
  ///
  /// This changes the appearance of the close button on the titlebar:
  static Future<void> setDocumentEdited() async { ... }

  /// Sets the document to be unedited.
  static Future<void> setDocumentUnedited() async { ... }

  /// Sets the represented file of the window.
  static Future<void> setRepresentedFilename(String filename) async { ... }
```

Two things to note. The package name states the platform, like wxWidgets'
`OSXSetModified` — no pretence of uniformity. And the API is **two verbs rather
than one boolean**, which loses the "declare the state, don't command the
transition" shape that a declarative prop wants.

---

## 11. The web — the opposite trade: confirm flow, no chrome

Worth including because it is the only mainstream platform that chose the
*other* half of the feature. From
[MDN `beforeunload`](https://developer.mozilla.org/en-US/docs/Web/API/Window/beforeunload_event):
a page signals unsaved work by calling `event.preventDefault()` in a
`beforeunload` handler; browsers then show a **browser-generated** confirmation
dialog. "Only show a generic browser-specified string in the displayed dialog.
This cannot be controlled by the webpage code." Modern browsers additionally
require sticky activation (the user must have interacted with the page) before
the dialog is allowed at all.

Nothing marks the tab or window chrome. The web's dirty state is invisible until
you try to leave — the inverse of Qt/AppKit, which mark the chrome and leave the
close flow to the app.

---

## 12. Cross-cutting summary

| framework | API shape | macOS | Windows | Linux | mobile | no-convention answer |
|---|---|---|---|---|---|---|
| Qt (widgets) | `setWindowModified(bool)` + `[*]` in title | native `documentEdited` | `*` substituted into title | `*` substituted into title | n/a | **synthesize a title marker**, position chosen by the app's template |
| Electron | `setDocumentEdited(bool)` | native | no-op | no-op | n/a | **silent no-op**; getter reports `false` |
| VS Code (on Electron) | user setting `window.title` with `${dirty}` | native + template | template | template | n/a | user-configurable template |
| wxWidgets | `OSXSetModified(bool)` | native | nothing | nothing | n/a | **name the platform in the API** |
| Swing/AWT | `rootPane.putClientProperty("Window.documentModified", …)` | native | nothing | nothing | n/a | silent no-op, stringly-typed key |
| JavaFX | none | — | — | — | — | no feature |
| Tk | `wm attributes -modified` | native | not offered | not offered | n/a | attribute exists only on the platform that has it |
| AppKit raw | `NSWindow.isDocumentEdited` | native | — | — | — | — |
| AppKit `NSDocument` | change count, derived from undo | native + close flow + autosave | — | — | — | — |
| SwiftUI | **no API**; dirty inferred from document mutation | implicit | — | — | implicit (autosave) | no feature |
| Flutter (+plugin) | `setDocumentEdited()` / `setDocumentUnedited()` | native | nothing | nothing | nothing | platform-named package |
| GTK4 / GNOME | **no API at any layer** | — | — | app writes the title (HIG 2.2.1: `*` prefix; current HIG: silent) | — | app's problem |
| Web | `beforeunload` | — | — | — | — | confirm dialog only, no chrome |

Three clusters:

1. **Native-only, silent elsewhere** — Electron, wx, AWT, Tk, Flutter plugins.
   Cheap, honest about capability, but the prop means different things on
   different platforms and nothing catches it.
2. **Native, with a synthesized fallback** — Qt alone, via a virtual that reports
   whether the platform took the call. The only design in the survey with a
   defined answer for every platform.
3. **Don't model dirty at all; model the document** — AppKit `NSDocument`,
   SwiftUI, GNOME Text Editor. Dirty is derived from an undo stack or a buffer,
   and the platform decides the chrome, the autosave and the close flow. No app
   ever writes a boolean.

---

## 13. The questions prior art does not agree on

Stated as questions, with the disagreement that makes each one a question. No
recommendation here — that is the design's job, not the probe's.

### Q1. Is the title a template the app writes, or a string kaya composes?

The disagreement is total:

- **App-supplied template with an explicit slot** — Qt's `[*]`: the author writes
  `"report.txt[*] - kaya"` and controls where the marker lands. Escaping is by
  doubling. A missing slot is a *runtime warning* on the platforms that need it.
- **User-supplied template** — VS Code's `${dirty}` in `window.title`: not even
  the app decides.
- **Fixed position chosen by the platform convention** — GNOME HIG 2.2.1
  (`*` prefix), Notepad (`*` prefix), against Qt's own advice (right after the
  file name, i.e. mid-string).
- **No marker at all** — Electron, wx, AWT, Tk, Flutter plugins: the title is
  never touched, and dirty simply does not exist off macOS.
- **A word instead of a glyph** — GNOME Text Editor shows `Draft`; Microsoft's
  title-bar guidance suggests state words such as "Editing"/"Viewing". Nobody in
  this survey uses `•`, though GNOME apps have drifted that way in tabs.

Three sub-questions ride on this, and kaya's invariants pull on all of them:

- A template puts a **constraint on a string that no type system checks**. Qt's
  answer is a warning that fires only when the window is dirty *and* the platform
  lacks native support — the guard you only meet on the platform you were not
  testing. If kaya takes the template route, the "structural guard on a path
  nobody can avoid" question is: what fails, at build time, when a window
  declares `dirty` and its title has no slot?
- If kaya composes the marker instead, it must pick the glyph and the position,
  and those become part of the **byte-compared expected strings** that scene
  scripts share across platforms. A marker on Windows/Linux and a dot in the
  close button on macOS means the same scene's title assertion differs per
  platform — which is exactly what shared `.steps` files are built to prevent.
- Does the composed marker also apply on macOS, on top of the native dot? Qt
  says no, and expresses "no" as a *style hint* (`SH_TitleBar_ModifyNotification`
  false in `QMacStyle`) rather than a platform check.

### Q2. Chrome only, or does `dirty` own the close flow?

- **Chrome only**: Qt, Electron, wx, AWT, Tk, Flutter plugins. The flag changes
  pixels; confirming on close is entirely the app's code.
- **Flow only**: the web. `beforeunload` produces a confirm dialog whose wording
  the page cannot control, and marks no chrome at all.
- **Both, coupled**: AppKit `NSDocument`. And note the coupling is *conditional* —
  the header states that when the document autosaves in place and has a file URL,
  `canCloseDocumentWithDelegate:` shows **no panel** and simply autosaves;
  the save/discard/cancel sheet is the non-autosaving path. So on Apple's own
  platform, "dirty" does not imply "ask before closing".
- **Neither**: GNOME Text Editor — autosave to drafts, no marker, no dialog.

For kaya this decides whether `dirty` is a lowering (a prop with a per-backend
chrome effect and nothing else) or a behavior (a close-request path that must be
uniform across 8 bindings and 5 backends, with its own scene legs, its own
handler scoped to the window that declares it, and its own answer for Android's
back gesture). Prior art has shipped every one of the four combinations.

### Q3. What does `dirty` mean where there is no chrome — and may it be silent?

Every platform in kaya's set except macOS lacks a convention, and two of them
(iOS, Android) lack a title bar entirely.

- **Silent no-op** is the majority answer (Electron, AWT, Tk, Flutter plugins) —
  and Electron's is worse than silent: `isDocumentEdited()` returns `false` after
  a successful `setDocumentEdited(true)`, so the round trip lies rather than
  refuses.
- **Synthesize something** is Qt's answer, and it only works where a title bar
  exists. On a phone there is no string to decorate.
- **Name the platform in the API** is wx's and the Flutter plugin's answer
  (`OSXSetModified`, `macos_window_utils`) — an explicit refusal to promise
  uniformity, which kaya's first invariant does not permit.
- **Model the document instead of the chrome, and autosave** is Apple's and
  GNOME Text Editor's answer: with autosave there is nothing to warn about, so
  the absence of a marker is not a gap.

So kaya's question is not "what does the GTK arm draw" but "what is the declared
observable semantics of `dirty` on a backend with no chrome": a stated carve-out
(and then a scene leg that asserts *nothing happened*, uniformly), an in-app
affordance kaya renders itself (which no toolkit in this survey does), or the
prop being unavailable on those backends (which the sweep-all-bindings rule
would have to state explicitly rather than silently).

### Observability, per platform — the input to whatever Q1–Q3 decide

| platform | external read path for dirty | status |
|---|---|---|
| macOS | `AXEdited` / `NSAccessibilityEditedAttribute` — a defined AX attribute whose header comment is literally "is it dirty?"; `isAccessibilityEdited` is overridable per element | **exists**; whether AppKit populates it from `NSWindow.isDocumentEdited` automatically is the macOS probe arm's measurement |
| Windows | none in the UIA Window pattern (`InteractionState, IsModal, IsTopmost, Maximizable, Minimizable, VisualState`) → title string only | measured absence |
| Linux | none in AT-SPI2's 45 states (`EDITABLE` means "can be edited") → accessible name/title only | measured absence |
| iOS / Android | nothing — no chrome to read; only whatever the app itself renders | measured absence |

This is the fork the harness design inherits: a `dirty` read verb either reads
**four different things** and normalizes to one boolean (heterogeneous sources,
uniform verdict, and a per-backend chance to be wrong), or reads **the title
string everywhere** (one source, one byte-comparison — but it forces a
synthesized marker onto macOS too, against the platform's own convention and
against what every toolkit here does).

### Secondary: one boolean, or a derived state?

Everyone in the chrome tier takes a boolean the app asserts. The document tier
does not: `NSDocument` derives dirty from the undo manager
("NSDocument's built-in undo support uses this whenever a document receives an
`NSUndoManagerWillCloseUndoGroupNotification`"), splits it into `isDocumentEdited`
vs `hasUnautosavedChanges`, and has a third value, `NSChangeDiscardable`, for
changes that dirty the document but need not be saved. SwiftUI removes the
boolean entirely. GNOME Text Editor keeps `is-modified` but separates it from
`draft`. If kaya's prop is a declared boolean, the counter-argument on record is
that an app can forget to clear it and an undo stack cannot.

---

## Sources

Primary source trees (fetched to the scratchpad and grepped; all upstream default
branches, fetched 2026-08-05):

- Qt: `qt/qtbase` — `src/widgets/kernel/qwidget.cpp`, `src/gui/kernel/qplatformwindow.{h,cpp}`,
  `src/plugins/platforms/cocoa/qcocoawindow.mm`, `src/plugins/platforms/windows/qwindowswindow.cpp`,
  `src/plugins/platforms/xcb/qxcbwindow.cpp`, `src/widgets/styles/qcommonstyle.cpp`,
  `src/plugins/styles/mac/qmacstyle_mac.mm` — https://github.com/qt/qtbase
- Electron: `shell/browser/api/electron_api_base_window.cc`, `shell/browser/native_window.{h,cc}`,
  `shell/browser/native_window_mac.mm` — https://github.com/electron/electron
- wxWidgets: `interface/wx/toplevel.h` — https://github.com/wxWidgets/wxWidgets
- OpenJDK: `src/java.desktop/macosx/classes/sun/lwawt/macosx/CPlatformWindow.java`,
  `src/java.desktop/macosx/native/libawt_lwawt/awt/AWTWindow.m` — https://github.com/openjdk/jdk
- GTK: `gtk/gtkwindow.c`, `gdk/gdktoplevel.c` — https://gitlab.gnome.org/GNOME/gtk
- GNOME Text Editor: `src/editor-page.c` — https://gitlab.gnome.org/GNOME/gnome-text-editor
- at-spi2-core: `atspi/atspi-constants.h` — https://gitlab.gnome.org/GNOME/at-spi2-core
- wayland-protocols: `stable/xdg-shell/xdg-shell.xml` — https://gitlab.freedesktop.org/wayland/wayland-protocols
- macos_window_utils: `lib/window_manipulator.dart`, `README.md` — https://github.com/macosui/macos_window_utils.dart

SDK headers read from the nix store
(`/nix/store/mxzgf8zlr2mbxrqp1ami2ixqsqpskv0w-apple-sdk-14.4/.../MacOSX14.4.sdk`):
`AppKit.framework/Headers/{NSWindow.h,NSDocument.h,NSWindowController.h,NSAccessibilityConstants.h,NSAccessibilityProtocols.h}`,
`ApplicationServices.framework/Frameworks/HIServices.framework/Headers/AXAttributeConstants.h`,
`SwiftUI.framework/Versions/A/Modules/SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface`.

Documentation:

- Qt QWidget (`windowModified`, `windowTitle`): https://doc.qt.io/qt-6/qwidget.html
- Electron BrowserWindow: https://www.electronjs.org/docs/latest/api/browser-window
- Electron represented file: https://www.electronjs.org/docs/latest/tutorial/represented-file
- wxTopLevelWindow: https://docs.wxwidgets.org/latest/classwx_top_level_window.html
- Tk `wm` (attributes `-modified`, `-titlepath`): https://www.tcl-lang.org/man/tcl9.0/TkCmd/wm.html
- VS Code `window.title` / `${dirty}`: https://code.visualstudio.com/docs/configure/custom-layout and https://code.visualstudio.com/docs/reference/variables-reference
- GNOME HIG 2.2.1 (asterisk prefix rule, save-confirm alert): https://p.janouch.name/files/gnome-hig-2.2.1/
- GNOME HIG current (windows pattern; silent on unsaved state): https://developer.gnome.org/hig/patterns/containers/windows.html
- GNOME HIG current (dialogs; destructive actions only): https://developer.gnome.org/hig/patterns/feedback/dialogs.html
- WinUI 3 TitleBar control: https://learn.microsoft.com/en-us/windows/apps/design/controls/title-bar
- UIA Window control pattern member list: https://learn.microsoft.com/en-us/dotnet/framework/ui-automation/implementing-the-ui-automation-window-control-pattern
- Notepad's asterisk: https://learn.microsoft.com/en-us/answers/questions/3233071/asterisk-in-title-of-untitled-notepad-file
- MDN `beforeunload`: https://developer.mozilla.org/en-US/docs/Web/API/Window/beforeunload_event
- iOS change tracking (`UIDocument.updateChangeCount`): https://developer.apple.com/library/ios/documentation/DataManagement/Conceptual/DocumentBasedAppPGiOS/ChangeTrackingUndo/ChangeTrackingUndo.html
- Apple, Build better document-based apps (WWDC23): https://developer.apple.com/videos/play/wwdc2023/10056/
- Compose Multiplatform top-level windows (`FrameWindowScope`/`ComposeWindow`): https://kotlinlang.org/docs/multiplatform/compose-desktop-top-level-windows-management.html
- Qt `[*]` papercut in the wild: https://github.com/biolab/orange3/issues/3267 and https://forum.qt.io/topic/2070/solved-qwidget-setwindowmodified-the-window-title-does-not-contain-a-placeholder
