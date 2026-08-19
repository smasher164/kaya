# undo-recon-platforms — platform-native undo machinery on the five backends

Recon for the undo design pass. READ-ONLY: nothing in the repo was
changed. Every claim about kaya carries `file:line`; every claim about a
platform carries a documentation URL.

Status: **IN PROGRESS** — sections fill in as the pass proceeds.

---

## 0. Why this recon exists (the collision, stated precisely)

kaya's text widgets are **native text widgets** on all five backends. On
four of the five the native widget ALREADY HAS AN UNDO STACK that the
user can reach with the platform chord, and kaya neither created it nor
knows about it. A kaya-owned unified undo (the ledger's "core-owned
undo", docs/deferred.md:719-733) therefore does not arrive on empty
ground: it arrives on top of a stack that is already bound to Cmd/Ctrl-Z
and, on Apple, already wired into the Edit menu by the OS.

The ledger states the design questions but not this collision:
docs/deferred.md:719-733 ("which transactions are undoable, whether an
undo re-runs handlers or simply applies the inverse transaction, and
what happens to occurrences emitted during an undo"). DESIGN.md mentions
undo **nowhere** — `grep -n "undo" DESIGN.md` returns no hits, so this
is greenfield in the design document and the fork below is unmade.

The closest solved precedent in the repo is the clipboard, ratified
2026-08-02 (DESIGN.md:1924-2051) and completed 2026-08-04
(docs/deferred.md:33-40). It solved *the same shape of collision* —
native widget already implements the gesture, platform chrome already
binds the chord — and its resolution is the template this pass should
argue with or against. See §1.

---

## 1. Our widgets, and the clipboard precedent that already solved this shape

### 1a. The five lowering sites (what the native widget actually is)

| backend | `entry` | `textarea` |
| --- | --- | --- |
| SwiftUI (mac + iOS) | `TextField` — swift/KayaSwiftUI.swift:7225 | `TextEditor` — swift/KayaSwiftUI.swift:7259 |
| GTK4 | `gtk4::Entry::new()` — crates/kaya/src/gtk.rs:2505 | `gtk4::TextView::new()` — crates/kaya/src/gtk.rs:2623 |
| WinUI 3 | `TextBox::new()` — crates/kaya/src/winui/mod.rs:3587 | `TextBox` + `SetAcceptsReturn(true)` — crates/kaya/src/winui/mod.rs:3780-3781 |
| Compose | Material3 `TextField(value:onValueChange:)` — android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt:4060 | same overload, `singleLine = false` — KayaCompose.kt:4031 |

Every one of them is the platform's real editing control. Nothing here
is a custom-drawn text engine, so whatever undo the platform ships is
already inside kaya's widget on four of the five (Compose is the
exception; see §6).

**All five are UNCONTROLLED toward the app, and that is the fact the
whole undo fork turns on.** The widget owns its text; each edit goes up
as an occurrence carrying the widget's identity tag; the app folds it
into its own model and kaya never reads it back:

- swift/KayaSwiftUI.swift:7218-7224 — "Uncontrolled toward the app: the
  node mirrors what the user types (SwiftUI needs the binding), and
  every edit is emitted with the entry's identity tag for the app to
  fold into its own model — nothing here is read back."
- crates/kaya/src/gtk.rs:2498-2504 — same sentence, plus the
  `apply_quiet` split that keeps programmatic writes from emitting.
- crates/kaya/src/winui/mod.rs:3571-3575 — same, with the swallow
  counter instead of a quiet flag.
- KayaCompose.kt:4051-4058 — same.

Consequence: **a native undo inside the widget is not invisible to
kaya.** It changes the widget's text, which fires the same change signal
a keystroke fires, which emits the same `text_changed` occurrence. On
every backend the native undo therefore already reaches the app through
the ordinary path. That is the decisive asymmetry with the clipboard
(where copy had no channel at all and *had* to become a command).

### 1b. The clipboard precedent, in one paragraph

DESIGN.md:1992-2005 ("Gestures are commands. Content is data.") settles
the identical collision for cut/copy/paste: kaya has no selection API,
so only the widget knows what is selected, so the gesture is a COMMAND
that kaya routes to the focused native widget and the widget performs
natively. Enablement is computed by kaya, never handed to the app
(DESIGN.md:1815-1822; swift/KayaSwiftUI.swift:5728-5733). The five
routing implementations are worth reading as the exact template an undo
role would reuse:

- macOS/iOS: send the standard selector down the responder chain —
  `kayaSendToFocusedResponder(#selector(NSText.cut(_:)))`,
  swift/KayaSwiftUI.swift:5919; helper at 5866-5904.
- GTK4: activate the widget's own action —
  `f.activate_action("clipboard.cut", None)` on the toplevel's focus
  widget, crates/kaya/src/gtk.rs:2236-2240.
- WinUI: call the control's own method — `CutSelectionToClipboard()` /
  `PasteFromClipboard()`, crates/kaya/src/winui/mod.rs:3512-3531.
- Compose: invoke the field's own semantics action —
  `SemanticsActions.CutText`, KayaCompose.kt:2072-2081, explicitly
  described there as "this host's responder chain".

Note what the Compose arm had to concede: kaya holds no caret and no
selection because the lowering hands Compose the `String` /
`onValueChange` overload (KayaCompose.kt:2054-2064). The same lowering
choice is what costs Compose its undo history — §6.

---

## 2. macOS (SwiftUI over AppKit)

### 2a. What our widgets already have

kaya's macOS `entry` is a SwiftUI `TextField` (KayaSwiftUI.swift:7225),
which AppKit backs with an `NSTextField` editing through the window's
**field editor** (a shared `NSTextView`). Apple's own statement of the
scope:

> "The default undo and redo behavior applies to text fields and text
> in cells as long as the field or cell is the first responder (that
> is, the focus of keyboard actions). Once the insertion point leaves
> the field or cell, prior operations cannot be undone."
> — [Using Undo in AppKit-Based Applications](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/AppKitUndo.html)

So on macOS the text field's undo stack is **real but focus-scoped and
discarded on blur**. That is a platform semantic kaya cannot change from
the SwiftUI layer, and it is exactly the semantic a kaya-owned undo
would contradict if it also claimed the same chord.

`TextEditor` (KayaSwiftUI.swift:7259) is backed by `NSTextView`, whose
undo is an opt-in the framework sets: "you must make sure that when you
create the text view either you select the appropriate check box in
Interface Builder, or send it `setAllowsUndo:` with an argument of
`YES`" (same Apple page). SwiftUI's `TextEditor` is widely reported to
arrive with undo already on and with typing coalescing, while `TextField`
does not coalesce the same way — but this is forum-level evidence
([Apple Developer Forums 814661](https://developer.apple.com/forums/thread/814661),
[788225](https://developer.apple.com/forums/thread/788225)), not
documentation, and SwiftUI exposes no `allowsUndo` to set. **PROBE
ITEM P1** in §8.

### 2b. How Edit > Undo finds its target

AppKit's mechanism is a responder-chain search for an *undo manager*,
not for a handler:

> "When the first responder of an application receives an `undo` or
> `redo` message, `NSResponder` goes up the responder chain looking for
> a next responder that returns an `NSUndoManager` object from
> `undoManager`."
> "If the `undoManager` message wends its way up the responder chain to
> the window, the `NSWindow` object queries its delegates with
> `windowWillReturnUndoManager:` ... If the delegate does not implement
> this method, the window creates an `NSUndoManager` object for the
> window and all its views."
> — [Using Undo in AppKit-Based Applications](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/AppKitUndo.html)

This is the single most useful fact on this platform: **macOS gives kaya
a documented insertion point that is not a key-handler race.** A window
delegate returning kaya's own `UndoManager` from
`windowWillReturnUndoManager:` takes over Edit > Undo for everything in
that window *except* what a nearer responder answers first — and the
focused text control IS a nearer responder. So the built-in text undo
wins while a field is focused, and kaya's wins otherwise, without either
side fighting for the key.

kaya's macOS app is a SwiftUI `App` with a `WindowGroup`
(swift/KayaSwiftUIEntry.swift:20-33), so the standard Edit menu with
Undo/Redo is present by default and is addressable through
`CommandGroup(replacing: .undoRedo)` if kaya ever wants to own the items
outright ([Apple, CommandGroupPlacement](https://developer.apple.com/documentation/swiftui/commandgroupplacement),
[SwiftUI menu-bar survey](https://danielsaidi.com/blog/2023/11/22/customizing-the-macos-menu-bar-in-swiftui)).
kaya already reaches into the same main menu for its own catalog —
`kayaSyncMacMenuBar()` inserts an owned NSMenu segment beside the dress
(swift/KayaSwiftUI.swift:6383-6420) and moves the `settings` role into
the application menu (6421-6439) — so a second dress-relocation for an
undo role would be a known move, not a new mechanism. Note
DESIGN.md:1914 currently says "About, Quit, and the standard Edit menu
remain dress meanwhile."

### 2c. Dynamic menu labels: macOS expects them

macOS is the platform that *names the action in the menu item*:

> "You can use the `NSUndoManager` method `setActionName:` to qualify
> the Undo and Redo command titles in the Edit menu. You pass the
> string you want appended to 'Undo' and 'Redo' ... After each action,
> the Undo menu item title is set to 'Undo Add Circle,' 'Undo Fill,'
> and 'Undo Delete' respectively."
> "`NSUndoManager` automatically localizes the 'Undo' and 'Redo'
> portion of the command titles, but merely appends the action name to
> them. You should localize the action names yourself."
> — [Setting Action Names](https://developer.apple.com/library/archive/documentation/cocoa/Conceptual/UndoArchitecture/Articles/SettingUndoNames.html)

The API surface: `undoMenuItemTitle` / `redoMenuItemTitle` ("Call
`undoMenuItemTitle` or `redoMenuItemTitle` to get the string for the
undo or redo menu item"), `undoActionName` / `redoActionName` (return
`@""` when there is nothing to undo or no names were registered), and
the overridable `undoMenuTitleForUndoActionName:` /
`redoMenuTitleForUndoActionName:`
([NSUndoManager.h](https://github.com/summerblue/ios-framework-comments/blob/master/Foundation.framework/NSUndoManager.h)).
"Undo Typing" is the title AppKit's text system produces by naming its
own group; the string is Apple's, not kaya's.

Two consequences for a uniform design:

1. If kaya owns the undo stack, the menu label becomes **kaya's
   responsibility and therefore a protocol question**: something has to
   name each undoable transaction, or every host shows a bare "Undo"
   and macOS silently loses a platform convention it has had since
   1988.
2. Whatever kaya names it, the string is a LOCALIZABLE APP STRING, and
   invariant 6 (scene scripts shared verbatim, CLAUDE.md:88-90) means
   the harness would compare that string byte-for-byte across
   platforms — so a per-platform title format ("Undo Typing" vs GTK's
   bare "Undo") is a scene-assertion problem before it is a UX problem.

### 2d. Keyboard: who eats Cmd-Z

The chord reaches the responder chain through the main menu's key
equivalent (the standard Edit > Undo item), and the first responder is
the field editor while a text control is focused, so the text control's
undo wins by responder proximity. kaya's own chord dispatch on macOS is
deliberately the same mechanism — "on macOS dispatch is the real
`NSMenu` key-equivalent walk and the NSMenuItems carry the chords"
(swift/KayaSwiftUI.swift:5706-5708), driven through
`NSApp.mainMenu?.performKeyEquivalent(with: event)`
(swift/KayaSwiftUI.swift:6651). A kaya undo item carrying Cmd-Z would
therefore be walking the SAME table that already holds the dress Edit
menu's Cmd-Z — two items, one chord, in one menu bar. That is a
first-match-wins ambiguity kaya would be creating for itself, and it is
avoidable only by either (a) replacing the dress item
(`CommandGroup(replacing: .undoRedo)`) or (b) not spelling the chord at
all and letting the dress item route to kaya's undo manager via
`windowWillReturnUndoManager:` (§2b).

</content>
</invoke>

---

## 3. iOS (SwiftUI over UIKit)

Same source file, same two widgets (KayaSwiftUI.swift:7225, 7259); the
`#if os(macOS)` splits in the clipboard arms (5744/5773, 5916/5947) show
how a per-platform undo arm would be spelled in the one file that serves
both.

### 3a. What our widgets already have

> "Some built-in views — in particular, those that involve text entry,
> UITextField and UITextView — implement Undo already."
> — [Programming iOS, ch. 39 (Undo)](https://www.apeth.com/iOSBook/ch39.html)

The mechanism is identical to macOS's:

> "When the application receives an undo event, `UIResponder` goes up
> the responder chain (starting with the first responder) looking for a
> responder that returns an `NSUndoManager` object from `undoManager`.
> The first undo manager that is found is used for the undo or redo
> operation."
> — [Using Undo on iPhone](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/iPhoneUndo.html)

### 3b. How the "menu item" finds its target — three routes, not one

iOS has no single Edit menu; it has three separate affordances, and
kaya's design has to answer all three or answer none.

1. **The iPad/Mac-Catalyst menu bar.** `UIMenu.Identifier.undoRedo` is
   a standard menu UIKit builds into the Edit menu, and
   `builder.remove(menu: .undoRedo)` removes it
   ([UIMenu.Identifier](https://developer.apple.com/documentation/uikit/uimenu/identifier),
   [UIMenuBuilder walkthrough](https://zachsim.one/blog/2019/8/4/customising-the-menu-bar-of-a-catalyst-app-using-uimenubuilder)).
   kaya already owns a `buildMenu(with:)` override — on the app
   delegate, subclassing `UIResponder` precisely so it gets asked
   (swift/KayaSwiftUIEntry.swift:47-56) — and today it only ADDS
   (`builder.insertSibling(menu, afterMenu: .view)`,
   swift/KayaSwiftUI.swift:6900). So the removal/replacement hook is
   already in kaya's hands and costs one line.
2. **Shake to undo.** Default-on, and it is an ALERT, not a menu:
   > "By default, users trigger an undo operation by shaking the
   > device." ... "UIKit automatically creates a suitable alert panel
   > for you based on the existence and state of the undo manager. If
   > the user chooses to perform an undo or redo operation, the undo
   > manager is sent an `undo` or `redo` message as appropriate."
   > — [Using Undo on iPhone](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/iPhoneUndo.html)

   Disabled with `application.applicationSupportsShakeToEdit = NO`
   (same page). This is the ONLY undo affordance on iPhone that does
   not need a hardware keyboard, and it is app-global — so on iOS the
   "which undo manager" question is answered by the responder chain at
   shake time, i.e. by what is focused.
3. **The three-finger editing gestures (iOS 13+).** Three-finger swipe
   left = undo, right = redo, three-finger double-tap = undo,
   three-finger tap-and-hold = a shortcut bar with Undo / Cut / Copy /
   Paste / Redo
   ([Macworld](https://www.macworld.com/article/233056/ios-13-and-ipados-13-how-to-use-the-new-gestures-for-cut-copy-paste-undo-and-redo.html),
   [iPhoneLife](https://www.iphonelife.com/content/how-to-use-three-finger-swipe-multi-touch-gesture-to-edit-text-your-iphone-new-ios-13)).
   These are attached to the editing interaction, not to the menu, and
   they are the reason iOS text undo cannot be reasoned about as
   "whatever the Edit menu does".

### 3c. Can it be disabled or intercepted, per widget?

**Yes, and this is iOS's best knob**: `UIResponder`'s
`editingInteractionConfiguration` returns `.none` to switch off the
system's undo/redo/copy/paste gestures wholesale
([hackingwithswift](https://www.hackingwithswift.com/example-code/uikit/how-to-disable-undo-redo-copy-and-paste-gestures-using-editinginteractionconfiguration) —
"override var editingInteractionConfiguration: UIEditingInteractionConfiguration { return .none }";
the property is on `UIResponder`, so it can be overridden at any level
of the chain). Caveat for kaya: our text widgets are SwiftUI
`TextField`/`TextEditor`, so there is no UIResponder subclass of ours to
override on — kaya would have to place the override on the app delegate
or a hosting controller, which makes it APP-WIDE rather than per-widget.
**PROBE ITEM P2.**

Shake is likewise app-global (`applicationSupportsShakeToEdit`). So on
iOS the honest reading is: **undo suppression is available at app
granularity, not widget granularity.**

### 3d. Dynamic labels

The iPad menu bar's Undo item is UIKit's and carries UIKit's title. The
shake alert's buttons are UIKit's too, built "based on the existence and
state of the undo manager". `NSUndoManager.setActionName:` is the same
Foundation API as on macOS, so a kaya-owned undo manager can name its
actions and both surfaces pick the name up — but note the reported
Catalyst defect where `setActionName:` is ignored
([Apple Developer Forums 719190](https://developer.apple.com/forums/thread/719190)).

### 3e. Keyboard

Cmd-Z reaches the focused text input first (hardware keyboard on
iPad/simulator). kaya's iOS chord dispatch is NOT the platform's — "on
iOS the `shortcut` verb traverses THIS table (the one a hardware key
event would feed)" (swift/KayaSwiftUI.swift:5704-5709,
`kayaShortcutItems`). That matters for the harness: on iOS a kaya undo
role would be *dispatched by kaya's own table*, so a scene asserting
"Cmd-Z undid the typing" would be asserting on kaya's dispatch, not on
UIKit's — a false green risk of exactly the kind CLAUDE.md invariant 4
names.

---

## 4. GTK4

### 4a. What our widgets already have — undo is ON BY DEFAULT, both kinds

This is the strongest finding in the whole recon, because it is
default-on and already shipping in kaya today.

- kaya's `entry` is `gtk4::Entry` (crates/kaya/src/gtk.rs:2505), which
  implements `GtkEditable` and delegates to an internal `GtkText`
  (kaya's own comment at gtk.rs:4943 already knows this: "A focused
  GtkEntry delegates to its internal GtkText"). `GtkEditable:enable-undo`
  is installed with **default TRUE**:
  ```c
  g_param_spec_boolean ("enable-undo", NULL, NULL, TRUE, ...)
  ```
  — [gtkeditable.c](https://gitlab.gnome.org/GNOME/gtk/-/raw/main/gtk/gtkeditable.c)
- kaya's `textarea` is `gtk4::TextView` (gtk.rs:2623) over a
  `GtkTextBuffer`, whose `enable-undo` property is documented "Default
  value: TRUE"
  ([GtkTextBuffer:enable-undo](https://docs.gtk.org/gtk4/property.TextBuffer.enable-undo.html)).

Both widgets document the chords themselves: "Ctrl+Z undoes the last
modification." / "Ctrl+Y or Ctrl+Shift+Z redoes the last undone
modification." — [Gtk.Text](https://docs.gtk.org/gtk4/class.Text.html)
and [Gtk.TextView](https://docs.gtk.org/gtk4/class.TextView.html).

Both also publish **actions**, which is the same routing surface kaya's
clipboard arm already drives: `text.undo` and `text.redo` alongside
`clipboard.copy` / `clipboard.cut` / `clipboard.paste` (both doc pages
above). kaya calls exactly this shape today —
`f.activate_action("clipboard.cut", None)` on the toplevel's focus
widget (gtk.rs:2236-2240) — so `f.activate_action("text.undo", None)` is
a two-word change, not a new mechanism.

One carve-out worth recording: "undo is forcefully disabled when
`GtkText:visibility` is set to FALSE"
([gtk_editable_set_enable_undo](https://docs.gtk.org/gtk4/method.Editable.set_enable_undo.html)) —
i.e. password-style entries have no undo on GTK by construction. kaya
has no password prop today, but the design should not promise uniform
undo on a field it may later mark secret.

### 4b. Menu routing: GTK has NO responder chain, and this is a real divergence

GTK4 resolves actions **upward**, never downward to the focus:

> "The action is looked up in the action groups associated with
> `widget` and its ancestors."
> — [gtk_widget_activate_action](https://docs.gtk.org/gtk4/method.Widget.activate_action.html)

A menubar item is a `GMenuModel` entry bound to an action resolved from
the *window/application* muxer, so a bar item named `text.undo` does not
find the focused entry's action. kaya's GTK menu shortcuts already ride
`app.set_accels_for_action` (gtk.rs:1777-1778) — application-level, not
focus-relative. **Therefore GTK cannot express "Edit > Undo, targeted at
whatever is focused" declaratively; kaya must find the focus widget and
activate the action on it by hand.** That is precisely what the
clipboard arm does (`focused_native()` walking toplevels for
`GtkWindowExt::focus`, gtk.rs:2220-2240), and the undo arm would reuse
it verbatim.

### 4c. Can it be disabled or intercepted, per widget?

**Yes, cleanly, per widget, on both kinds.** `gtk_editable_set_enable_undo(entry, FALSE)`
for the entry; `gtk_text_buffer_set_enable_undo(buffer, FALSE)` for the
textarea. Both are plain properties on the widget kaya already holds a
handle to (`core.entries`, gtk.rs:2514; `core.textareas`, gtk.rs:2636).
GTK is the only backend of the five that offers a documented,
per-widget, both-kinds off switch.

There is also a partial knob — `gtk_text_buffer_begin_irreversible_action()`,
which "Denotes the beginning of an action that may not be undone" and
"will cause any previous operations in the undo/redo queue to be
cleared" ([docs](https://docs.gtk.org/gtk4/method.TextBuffer.begin_irreversible_action.html)).
See §4e for why kaya wants it whether or not it owns undo.

### 4d. Dynamic labels

GTK does not do them. The GTK undo actions are `text.undo`/`text.redo`
with no action-name mechanism, and kaya's GTK menu items bind label
strings from the model (gtk.rs:1747-1778). If kaya ships dynamic labels
it would be kaya writing "Undo Typing" into a GTK item label, which is a
kaya convention on this platform, not a platform convention. DESIGN.md's
"Where a platform cannot say it" (1864-1891) is the existing home for
that kind of asymmetry.

### 4e. GTK already records KAYA'S OWN WRITES in the native undo stack

kaya's programmatic text writes go straight into the widget:

- `entry.set_text(&s)` / `view.buffer().set_text(&s)` on a `Prop::Text`
  write, guarded only by `apply_quiet` — and that guard is explicitly
  about occurrences, not undo: "Quiet: a property write is
  configuration, not a user edit (see apply_quiet)"
  (crates/kaya/src/gtk.rs:3481-3492).
- `CommandKind::Clear` does the same with the guard deliberately OFF
  (gtk.rs:3920-3931).

With `enable-undo` defaulting TRUE on both widgets, those writes are
undoable entries in the native stack. **So today, with no undo feature
at all, a user pressing Ctrl+Z in a kaya GTK app can revert a write the
APP made** — including a `clear` the app issued in response to a button.
Nothing in the repo suppresses this, and no scene asserts on it. This is
a live semantic that predates the undo milestone and belongs in the
design pass regardless of which fork is taken. **PROBE ITEM P3.**

---

## 5. WinUI 3

### 5a. What our widgets already have

Both kaya text kinds are `TextBox` (crates/kaya/src/winui/mod.rs:3587
and 3780). The undo surface is confirmed **in kaya's own generated
metadata bindings**, which is stronger evidence than the docs site:
`impl TextBox` (crates/kaya/src/winui/bindings.rs:106056) carries

- `CanUndo()` — bindings.rs:107776
- `CanRedo()` — bindings.rs:107787
- `Undo()` — bindings.rs:108045
- `Redo()` — bindings.rs:108054
- `ClearUndoRedoHistory()` — bindings.rs:108090

sitting immediately beside the clipboard methods kaya already calls
(`PasteFromClipboard` 108063, `CopySelectionToClipboard` 108072,
`CutSelectionToClipboard` 108081 — used at winui/mod.rs:3512-3531).
Microsoft's reference documents `CanUndo` ("Gets a value that indicates
whether the undo buffer contains an action that can be undone"),
`CanRedo`, and `ClearUndoRedoHistory()` ("Empties the undo and redo
buffers")
([TextBox class](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.textbox)).

**There is no `IsUndoEnabled` and no `UndoLimit` on the WinUI TextBox.**
Those are WPF's `TextBoxBase` members
([IsUndoEnabled](https://learn.microsoft.com/en-us/dotnet/api/system.windows.controls.primitives.textboxbase.isundoenabled),
[UndoLimit](https://learn.microsoft.com/en-us/dotnet/api/system.windows.controls.primitives.textboxbase.undolimit))
and do not exist here. Confirmed by absence in kaya's bindings: no
`SetIsUndoEnabled` / `SetUndoLimit` in `impl TextBox`.

### 5b. Where the undo affordance shows up

Windows has no OS-owned Edit menu. WinUI's affordance is the TextBox's
own **context menu**:

> | Command | Shown when... |
> | Undo | text has been changed. |
> — [Text box](https://learn.microsoft.com/en-us/windows/apps/design/controls/text-box), "Modify the context menu"

with `ContextMenuOpening` as the documented interception point (same
page). kaya's menu model on Windows is entirely app-owned: "The WINDOW
anchor is a real in-window MenuBar in its own Auto row of the window
shell Grid; the WIDGET/NODE anchor is a MenuFlyout set as the element's
ContextFlyout" (crates/kaya/src/winui/mod.rs:1569-1572). So on Windows
there is nothing to route TO — a kaya undo command would be a kaya menu
item calling `TextBox::Undo()` directly, exactly as
`perform_clipboard_role` calls `CutSelectionToClipboard()`.

**Open question specific to kaya's build:** kaya replaces the TextBox
style with a minimal template (`ENTRY_STYLE_XAML`,
crates/kaya/src/winui/mod.rs:521-536) because "everything else of the
default chrome is styling this unpackaged app cannot resource-resolve",
and the file records that the built-in template's deferred theme XAML is
what needs the metadata provider to resolve `TextCommandBarFlyout`
(winui/mod.rs:538-545). Whether kaya's TextBoxes still get the built-in
context menu (and therefore a native Undo item) is therefore
**UNVERIFIED**. **PROBE ITEM P4.**

### 5c. Can it be disabled or intercepted?

**Not disabled — only cleared.** With no `IsUndoEnabled`/`UndoLimit`,
the only lever is `ClearUndoRedoHistory()` (bindings.rs:108090), which
empties the buffers after the fact. A "suppress the native stack"
design would have to call it after every kaya-driven write, which is a
suppression by repeated erasure rather than a mode — worth stating
plainly because it is the one backend where the clean off-switch does
not exist.

### 5d. Dynamic labels

Not a Windows convention. The context-menu item is "Undo", flat. If
kaya ships dynamic labels, Windows is a platform where kaya would be
inventing the convention.

### 5e. Keyboard: the DOUBLE-FIRE hazard

This is the sharpest platform-specific trap of the five. WinUI
accelerators bubble from the focused element to the root, and
`Handled=true` stops them
([Keyboard accelerators](https://learn.microsoft.com/en-us/windows/apps/develop/input/keyboard-accelerators)).
But TextBox does its editing chords through its internal edit control,
not through accelerators:

> "It seems TextBoxes do not use keyboard accelerators." ... "when you
> Ctrl+V from a TextBox it does a paste of any clipboard text but will
> also raise any Ctrl+V keyboard accelerator in any parent control."
> — [microsoft-ui-xaml issue #1435](https://github.com/microsoft/microsoft-ui-xaml/issues/1435)

kaya attaches real `KeyboardAccelerator`s to its menu items
(`attach_accelerator`, crates/kaya/src/winui/mod.rs:2604-2654; the
dispatch note at 1573). **So a kaya menu item spelling Ctrl+Z would very
likely fire IN ADDITION to the focused TextBox's own undo — two undos
per keypress.** That is a mechanically different failure from macOS's
(where the nearer responder simply wins) and it is the reason a uniform
"kaya owns Ctrl+Z" design cannot be assumed portable. **PROBE ITEM P5.**

---

## 6. Compose (Android)

### 6a. What our widgets already have — and the version wall

kaya lowers both text kinds through the **legacy value/onValueChange
Material3 `TextField`** (KayaCompose.kt:4031 and 4060), which routes to
foundation's legacy `CoreTextField`. That path DOES have undo:

```kotlin
KeyCommand.UNDO -> {
    undoManager?.makeSnapshot(value)
    undoManager?.undo()?.let { this@TextFieldKeyInput.onValueChange(it) }
}
KeyCommand.REDO -> {
    undoManager?.redo()?.let { this@TextFieldKeyInput.onValueChange(it) }
}
```
— [TextFieldKeyInput.kt](https://raw.githubusercontent.com/androidx/androidx/androidx-main/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/text/TextFieldKeyInput.kt)

with the manager created per field (`val undoManager = remember { UndoManager() }`,
[CoreTextField.kt](https://raw.githubusercontent.com/androidx/androidx/androidx-main/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/text/CoreTextField.kt))
and the chords `Ctrl+Z` (UNDO), `Ctrl+Y` / `Ctrl+Shift+Z` (REDO)
([KeyMapping.kt](https://raw.githubusercontent.com/androidx/androidx/androidx-main/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/text/KeyMapping.kt)).

Two things follow, and they are both important:

1. **It is reachable only from a hardware keyboard.** Compose's
   `TextToolbar` — the floating selection toolbar — exposes only
   `onCopyRequested`, `onPasteRequested`, `onCutRequested`,
   `onSelectAllRequested`
   ([TextToolbar](https://developer.android.com/reference/kotlin/androidx/compose/ui/platform/TextToolbar)).
   No undo. Android has no menu bar. So on a phone, kaya's fields have
   **no reachable undo at all today**, and Compose's undo manager is
   effectively dead code on the emulator lane unless a hardware key
   event is synthesized.
2. **Undo round-trips through kaya's own change path.** The undo calls
   `onValueChange(it)`, which is kaya's lambda at KayaCompose.kt:4033
   / 4062 — it writes `node.text` and emits `emitTextChanged`. So on
   Compose, a native undo is already indistinguishable from typing, as
   far as the app is concerned. (The same is true in principle on the
   other four; Compose is where it is provable from source.)

**The version wall.** kaya pins `compose-bom:2024.10.01`
(android/kaya/build.gradle.kts:53), which maps to foundation **1.7.8**
and material3 **1.3.2**
([BOM mapping](https://developer.android.com/develop/ui/compose/bom/bom-mapping)).
So:

- `TextFieldState` + `undoState` (`undo()`, `redo()`, `canUndo`,
  `canRedo`, `clearHistory()`) EXIST in kaya's pinned foundation —
  they shipped with BasicTextField2 in foundation 1.7
  ([TextFieldState](https://composables.com/docs/androidx.compose.foundation/foundation/1.9.0-beta02/classes/TextFieldState),
  [Configure text fields](https://developer.android.com/develop/ui/compose/text/user-input)).
- but the **Material3** `TextField(state:)` overload that would let
  kaya keep its M3 dressing arrived in **Material 3 1.4.0**, which
  kaya's pin does not have.

So "use `TextFieldState.undoState`" is not a free change on Compose: it
is either a material3 version bump (touching check-pins,
tools/check-pins.sh per CLAUDE.md:172-176) or a move to
`BasicTextField` plus hand-rolled M3 decoration. Either way it is the
one backend where reaching the platform's *good* undo API costs a
dependency decision.

### 6b. Menu routing

None. Android has no OS Edit menu and no responder chain. kaya's own
catalog folds into the top app bar and the overflow (KayaCompose.kt:4095-4104,
"the catalog folds into the top app bar — promoted primaries as real bar
actions, everything in the overflow ⋮"). The Compose clipboard arm
already concedes this and calls the semantics action directly, calling
it "this host's responder chain" (KayaCompose.kt:2050-2064,
`kayaEditFocusedText`). An undo command would follow the same shape —
but note there is **no `SemanticsActions.Undo`** to invoke, so the
Compose arm would need a real handle on the field's state
(`TextFieldState.undoState`), not a semantics action. That is §6a's
version wall arriving as a design constraint rather than a preference.

### 6c. Can it be disabled or intercepted?

- Legacy path: **no**, there is no knob. The UndoManager is a private
  `remember`ed instance inside `CoreTextField` with no parameter and no
  exposure — a long-standing complaint
  ([compose-multiplatform#3891](https://github.com/JetBrains/compose-multiplatform/issues/3891),
  [#2958](https://github.com/JetBrains/compose-multiplatform/issues/2958)).
  The only interception is to eat the key event first with
  `onPreviewKeyEvent` before the field sees it.
- `TextFieldState` path: **yes** — `undoState.clearHistory()`, same
  erase-don't-disable shape as WinUI.

### 6d. Dynamic labels

Not applicable; there is no menu item to label.

### 6e. Keyboard

`Ctrl+Z` is consumed by the focused field's `TextFieldKeyInput` before
anything else sees it (it is a key-input modifier on the field itself).
kaya's Compose backend has no accelerator table competing for it. The
practical risk is the mirror image of Windows': on Android kaya would
have to steal the chord with `onPreviewKeyEvent` to own it, and on the
phone form factor the chord is not reachable at all.

---

## 7. The five questions, answered side by side

### Q1 — What undo do the native text widgets already have?

| backend | entry | textarea | on by default? | reachable how |
| --- | --- | --- | --- | --- |
| mac (AppKit) | field-editor undo, **discarded when focus leaves** | NSTextView undo (framework sets `allowsUndo`) | yes | Cmd-Z, Edit>Undo |
| iOS (UIKit) | UITextField undo | UITextView undo | yes | shake, 3-finger gestures, iPad Cmd-Z / Edit>Undo |
| GTK4 | `GtkEditable:enable-undo` **default TRUE** | `GtkTextBuffer:enable-undo` **default TRUE** | yes | Ctrl-Z / Ctrl-Y / Ctrl-Shift-Z |
| WinUI 3 | TextBox undo buffer | same (TextBox) | yes | Ctrl-Z, context-menu "Undo" |
| Compose | `CoreTextField` `UndoManager` (per field) | same | yes, but | **hardware Ctrl-Z only — no toolbar item, no menu** |

### Q2 — How does the platform's Edit>Undo menu item find its target?

- **mac**: responder chain, searching for an object that answers
  `undoManager`; falls back to the window, which asks its delegate via
  `windowWillReturnUndoManager:`. **kaya has a documented hook here.**
- **iOS**: same responder-chain search (`UIResponder.undoManager`), but
  the "menu item" is three different affordances (§3b) and one of them
  is an OS-built alert.
- **GTK4**: **no such routing exists.** Actions resolve UPWARD from the
  activating widget to its ancestors, never down to the focus, so a
  menubar item cannot target the focused entry declaratively. kaya must
  locate the focus widget and activate `text.undo` on it — the shape
  the clipboard arm already uses.
- **WinUI 3**: **no OS menu at all.** The affordance is the TextBox's
  own context menu; anything else is app-owned, and kaya's menu bar is
  a plain in-window `MenuBar` (winui/mod.rs:1569-1572).
- **Compose**: **no OS menu, no responder chain, no toolbar item.**

Two of five have real menu-to-focus routing (both Apple). Three of five
require kaya to find the focused widget itself. That asymmetry is
already priced into kaya's clipboard implementation, so it is a known
cost, not a new one.

### Q3 — Can the native widget undo be disabled or intercepted cleanly, per widget?

| backend | per-widget off switch | what exists instead |
| --- | --- | --- |
| GTK4 | **YES** — `gtk_editable_set_enable_undo(FALSE)`, `gtk_text_buffer_set_enable_undo(FALSE)` | also `begin/end_irreversible_action` to keep app writes out of the stack |
| Compose (TextFieldState path) | partial — `undoState.clearHistory()` | erase, not disable |
| WinUI 3 | **NO** — no `IsUndoEnabled`, no `UndoLimit` | `ClearUndoRedoHistory()` after every kaya write |
| iOS | app-wide only — `editingInteractionConfiguration = .none`, `applicationSupportsShakeToEdit = NO` | nothing per-widget through SwiftUI |
| mac | **NO knob through SwiftUI** | but you do not need one: kaya's manager sits at the window, the field's sits nearer, and proximity decides |
| Compose (legacy path kaya is on) | **NO** | only `onPreviewKeyEvent` stealing the chord |

**Verdict: "suppress the native stacks uniformly" is not purchasable.**
It is clean on exactly one backend (GTK), absent on two (WinUI legacy
knob missing; Compose legacy path), and app-granular on one (iOS).
Any design that requires uniform suppression is requiring a carve-out on
three of five platforms — which, by CLAUDE.md invariant 1, would have to
be stated uniformly as a limitation rather than papered over.

### Q4 — Dynamic menu labels ("Undo Typing")

- **macOS: expects them.** `NSUndoManager.setActionName:` "qualifies
  the Undo and Redo command titles in the Edit menu"; the titles come
  back through `undoMenuItemTitle`/`redoMenuItemTitle`, and Foundation
  localizes the "Undo"/"Redo" prefix but not the action name
  ([Setting Action Names](https://developer.apple.com/library/archive/documentation/cocoa/Conceptual/UndoArchitecture/Articles/SettingUndoNames.html)).
- **iOS: same Foundation API**, and both the iPad menu bar and the
  shake alert consume it — with a known Catalyst defect
  ([forums 719190](https://developer.apple.com/forums/thread/719190)).
- **GTK4: no.** Flat `text.undo`/`text.redo` actions, no action-name
  concept.
- **WinUI 3: no.** Flat "Undo" in the TextBox context menu.
- **Compose: not applicable.** No menu item exists.

So dynamic labels are an **Apple-only platform convention**, which puts
them squarely in DESIGN.md's existing "Where a platform cannot say it"
bucket (1864-1891). Two consequences worth flagging early:

1. If kaya owns undo, SOMETHING has to name each undoable transaction
   or macOS loses a convention it has had for decades. That is a
   protocol-surface question (a name per undo group), not a backend
   detail.
2. Invariant 6 (CLAUDE.md:88-90, scene scripts shared verbatim,
   byte-for-byte expected strings) means a per-platform title format
   becomes a scene-assertion problem: an `expect` on the Undo item's
   label cannot be one shared string if macOS says "Undo Typing" and
   GTK says "Undo".

### Q5 — Keyboard: who eats the chord when a text field is focused?

- **mac**: the focused field editor, by responder proximity — and the
  chord arrives via the main menu's key-equivalent walk, which is the
  SAME table kaya's own catalog dispatch uses
  (`NSApp.mainMenu?.performKeyEquivalent`, KayaSwiftUI.swift:6651). A
  kaya item spelling Cmd-Z would be a second item with the same chord
  in one menu bar.
- **iOS**: the focused text input eats Cmd-Z. kaya's iOS chord dispatch
  is its own table (`kayaShortcutItems`, KayaSwiftUI.swift:5704-5709),
  not UIKit's, so kaya's harness would be testing kaya's dispatch and
  not the platform's.
- **GTK4**: the focused `GtkText`/`GtkTextView` binds Ctrl-Z itself
  (both class docs). kaya's catalog chords are installed
  application-wide via `set_accels_for_action` (gtk.rs:1777-1778);
  which wins is a GTK shortcut-scope question and is **UNVERIFIED**
  (PROBE P6).
- **WinUI 3**: **BOTH fire.** "TextBoxes do not use keyboard
  accelerators", so the TextBox performs its own undo *and* the
  accelerator raises in an ancestor
  ([#1435](https://github.com/microsoft/microsoft-ui-xaml/issues/1435)).
  kaya attaches real accelerators (winui/mod.rs:2604-2654).
- **Compose**: the focused field's `TextFieldKeyInput` consumes it
  first; kaya has no competing table.

---

## 8. The design fork, stated in the terms this recon settles

The charge names the fork: kaya-owned unified undo must **either
suppress the native stacks or delegate text-field undo to them and only
own app-state undo**. What the evidence says about each:

**Fork A — kaya owns everything, native stacks suppressed.**
Costs a per-backend suppression that only GTK sells cleanly (§Q3). WinUI
would need `ClearUndoRedoHistory()` after every write; Compose's legacy
path has no knob at all; iOS can only switch off gestures app-wide; and
on macOS it means fighting the field editor for Cmd-Z. It also throws
away behaviour users already have (typing coalescing, per-keystroke
granularity, IME-aware grouping) and obliges kaya to re-implement it —
for TEXT specifically, which is the one domain where every platform
already invested heavily. Against it: nothing in kaya's existing doctrine
demands it. For it: it is the only fork where "Undo" means one thing.

**Fork B — delegate text undo to the widget, kaya owns app-state undo.**
This is the fork the CLIPBOARD PRECEDENT actually took (route the
gesture to the focused native widget; DESIGN.md:1992-2005), and it is
the fork the platforms are built for. It is also nearly free on macOS,
where the two stacks compose by responder proximity WITHOUT either side
disabling the other (§2b). Its cost is that "Undo" becomes
context-dependent: with a field focused it undoes typing, otherwise it
undoes the app's last transaction. That is exactly how every native app
on macOS/Windows/GNOME behaves, so it is not obviously a defect — but it
IS a divergence from "one observable semantics", and DESIGN.md would
have to say so out loud.

**What this recon adds to the fork that was not in the ledger:**

1. **The native stacks are not passive.** They already contain KAYA'S
   OWN programmatic writes (§4e, proven on GTK: `entry.set_text`,
   `buffer.set_text` and `CommandKind::Clear` all land in a stack whose
   `enable-undo` defaults TRUE; gtk.rs:3481-3492, 3920-3931). Whatever
   fork is chosen, **`begin_irreversible_action` (or its per-platform
   equivalent) is needed today**, because an app-driven `clear` is
   currently user-undoable and nothing says it should be.
2. **A native undo already reaches the app.** Because every kaya text
   widget is uncontrolled (§1a), the widget's own undo fires the change
   signal and emits the ordinary `text_changed` occurrence — provable
   from source on Compose, where undo literally calls
   `onValueChange` (§6a). So Fork B does not create a blind spot in the
   app's model; the app sees the undone text like any other edit.
3. **Compose is the odd one out and it costs a dependency decision**
   (§6a): the good API (`TextFieldState.undoState`) needs foundation
   1.7 (kaya HAS it) but the Material3 `TextField(state:)` dressing
   needs Material3 1.4 (kaya does NOT). Whichever fork is chosen,
   Compose's arm is the expensive one.
4. **Windows double-fires the chord** (§Q5) — so on Windows, Fork B
   with a kaya menu item carrying Ctrl-Z is actively wrong; the item
   must either carry no chord or the design must accept two undos per
   press.

---

## 9. Probe items (things this recon could NOT settle without running something)

Nothing was run. Each of these is a claim I would not want a design
ratified on top of without a measurement.

- **P1 — SwiftUI TextField vs TextEditor undo on macOS.** Whether
  kaya's `TextField` (KayaSwiftUI.swift:7225) actually undoes typing,
  and whether `TextEditor` (7259) coalesces. Documentation covers
  NSTextField/NSTextView, not SwiftUI's wrappers; the only evidence
  found is Apple Developer Forums threads
  ([814661](https://developer.apple.com/forums/thread/814661),
  [788225](https://developer.apple.com/forums/thread/788225)).
- **P2 — iOS granularity.** Whether
  `editingInteractionConfiguration`/`applicationSupportsShakeToEdit`
  can be scoped to one kaya widget at all, given our widgets are
  SwiftUI views with no UIResponder subclass of ours in the chain.
- **P3 — Do kaya's programmatic writes land in the native undo stack?**
  Proven-by-default on GTK (§4e). UNVERIFIED on WinUI (does the
  `Text` setter push an undo entry?), on SwiftUI (does a
  `Binding`-driven change register with the field editor?), and on
  Compose (`snapshotIfNeeded` runs in composition, so probably YES).
  **This is the highest-value probe**: it is a live semantic in
  today's shipped code, independent of the undo milestone.
- **P4 — Does kaya's WinUI TextBox still have its built-in context
  menu?** kaya replaces the whole Style with `ENTRY_STYLE_XAML`
  (winui/mod.rs:521-536) and the file records template-resolution
  trouble around `TextCommandBarFlyout` (538-545). If the flyout is
  gone, Windows users currently have NO undo affordance except Ctrl-Z.
- **P5 — WinUI double-fire.** Confirm that a kaya accelerator on Ctrl-Z
  fires alongside the TextBox's own undo (issue #1435 is a community
  report, not a Microsoft statement).
- **P6 — GTK shortcut precedence.** Whether an application-level accel
  installed by `set_accels_for_action` (gtk.rs:1777-1778) beats the
  focused `GtkText`'s own Ctrl-Z binding, or the reverse.

### A harness observability gap worth knowing before designing scenes

The `shortcut` harness verb **cannot press a chord at a native widget**.
On GTK it walks the application accel map and **panics** when no catalog
item owns the chord: "no catalog item owns this chord" (gtk.rs:4848-4855);
the interpreter backends do the same through `kayaShortcutItems`
(KayaSwiftUI.swift:5704-5709). So a scene cannot today assert "Ctrl-Z in
a focused entry undid the typing" — it can only assert on a kaya CATALOG
item. Any Fork-B design that leaves text undo to the platform therefore
has **no existing gate that can observe the delegated half**, which by
CLAUDE.md invariant 3 (failures become guards, on a path nobody can
avoid) is a gap the design pass should close deliberately rather than
discover later.

---

## 10. Sources

kaya code (read-only, all paths absolute under `/Users/akhilindurti/Projects/kaya`):
`CLAUDE.md`, `DESIGN.md` (§Menus 1608-1923, §Clipboard 1924-2051),
`docs/deferred.md` (14-40, 719-733), `swift/KayaSwiftUI.swift`,
`swift/KayaSwiftUIEntry.swift`, `crates/kaya/src/gtk.rs`,
`crates/kaya/src/winui/mod.rs`, `crates/kaya/src/winui/bindings.rs`,
`crates/kaya/src/spec.rs`,
`android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt`,
`android/kaya/build.gradle.kts`.

Platform documentation:

- [Using Undo in AppKit-Based Applications](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/AppKitUndo.html)
- [Setting Action Names (NSUndoManager)](https://developer.apple.com/library/archive/documentation/cocoa/Conceptual/UndoArchitecture/Articles/SettingUndoNames.html)
- [NSUndoManager.h header](https://github.com/summerblue/ios-framework-comments/blob/master/Foundation.framework/NSUndoManager.h)
- [Using Undo on iPhone](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/iPhoneUndo.html)
- [Programming iOS ch.39 — Undo](https://www.apeth.com/iOSBook/ch39.html)
- [UIMenu.Identifier](https://developer.apple.com/documentation/uikit/uimenu/identifier) / [undoRedo](https://developer.apple.com/documentation/uikit/uimenu/identifier/3281965-undoredo) / [UIMenuBuilder walkthrough](https://zachsim.one/blog/2019/8/4/customising-the-menu-bar-of-a-catalyst-app-using-uimenubuilder)
- [Disabling the three-finger editing gestures (editingInteractionConfiguration)](https://www.hackingwithswift.com/example-code/uikit/how-to-disable-undo-redo-copy-and-paste-gestures-using-editinginteractionconfiguration)
- [iOS 13 text-editing gestures](https://www.macworld.com/article/233056/ios-13-and-ipados-13-how-to-use-the-new-gestures-for-cut-copy-paste-undo-and-redo.html)
- [SwiftUI CommandGroupPlacement / macOS menu bar](https://danielsaidi.com/blog/2023/11/22/customizing-the-macos-menu-bar-in-swiftui)
- [Gtk.Text](https://docs.gtk.org/gtk4/class.Text.html) · [Gtk.TextView](https://docs.gtk.org/gtk4/class.TextView.html) · [GtkTextBuffer](https://docs.gtk.org/gtk4/class.TextBuffer.html)
- [GtkTextBuffer:enable-undo (default TRUE)](https://docs.gtk.org/gtk4/property.TextBuffer.enable-undo.html) · [gtk_editable_set_enable_undo](https://docs.gtk.org/gtk4/method.Editable.set_enable_undo.html) · [gtkeditable.c (default TRUE)](https://gitlab.gnome.org/GNOME/gtk/-/raw/main/gtk/gtkeditable.c)
- [gtk_text_buffer_begin_irreversible_action](https://docs.gtk.org/gtk4/method.TextBuffer.begin_irreversible_action.html) · [gtk_widget_activate_action](https://docs.gtk.org/gtk4/method.Widget.activate_action.html)
- [WinUI TextBox class](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.textbox) · [Text box (context menu table)](https://learn.microsoft.com/en-us/windows/apps/design/controls/text-box)
- [Keyboard accelerators (WinUI)](https://learn.microsoft.com/en-us/windows/apps/develop/input/keyboard-accelerators) · [microsoft-ui-xaml#1435 — TextBoxes do not use keyboard accelerators](https://github.com/microsoft/microsoft-ui-xaml/issues/1435)
- [WPF TextBoxBase.IsUndoEnabled](https://learn.microsoft.com/en-us/dotnet/api/system.windows.controls.primitives.textboxbase.isundoenabled) / [UndoLimit](https://learn.microsoft.com/en-us/dotnet/api/system.windows.controls.primitives.textboxbase.undolimit) (WPF only — cited to show what WinUI lacks)
- Compose foundation sources: [KeyMapping.kt](https://raw.githubusercontent.com/androidx/androidx/androidx-main/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/text/KeyMapping.kt) · [TextFieldKeyInput.kt](https://raw.githubusercontent.com/androidx/androidx/androidx-main/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/text/TextFieldKeyInput.kt) · [CoreTextField.kt](https://raw.githubusercontent.com/androidx/androidx/androidx-main/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/text/CoreTextField.kt)
- [TextFieldState / undoState](https://composables.com/docs/androidx.compose.foundation/foundation/1.9.0-beta02/classes/TextFieldState) · [Configure text fields](https://developer.android.com/develop/ui/compose/text/user-input) · [TextToolbar](https://developer.android.com/reference/kotlin/androidx/compose/ui/platform/TextToolbar)
- [Compose BOM to library version mapping](https://developer.android.com/develop/ui/compose/bom/bom-mapping)
- [compose-multiplatform#3891 — Expose UndoManager from CoreTextField](https://github.com/JetBrains/compose-multiplatform/issues/3891) · [#2958](https://github.com/JetBrains/compose-multiplatform/issues/2958)
