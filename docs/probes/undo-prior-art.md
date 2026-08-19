# Undo prior art — does anyone ship two undo stacks, and does the ordering hole bite?

Research for the kaya undo design review (docs/undo-plan.md §0 D1/D6). Every
claim carries a URL. Status: COMPLETE, 2026-08-04.

## The short version

1. **The hole is real and it is a named class.** Two stacks routed by focus is
   selective undo wearing a linear-undo costume; the literature calls the
   result a state "that has never existed before". VS Code ships kaya's exact
   model and has an open bug titled "Undo should be related only to the area
   on focus". Drupal Canvas ships it and reports "pressing undo in our UI now
   undoes the undo the user did".
2. **Nobody solves it — everyone buys it off, four different ways** (amnesia,
   unify, refuse, show the history). kaya's D6 currently takes a fifth option
   nobody documents: let it happen silently. Apple's own architect, asked
   about exactly this shape in 2012, said he knew of no app that shipped it
   and that it "may cause authors to create confusing UI".
3. **The cheapest fix is already half-built.** D7 clears a field's native
   history when kaya writes to it. Widen the trigger to "a core undo group was
   committed while this field had focus" and the ordering hole closes by
   construction — that is Apple's own mitigation, spelled in machinery kaya is
   already adding at call sites it is already touching.
4. **D1's rejection reason is partly wrong.** The suppression matrix cites
   WinUI's missing `IsUndoEnabled`; WPF has had exactly that property, with
   exactly D7's semantics, since 2006. The *right* argument against a unified
   stack is coalescing, and it is a strong one — Flutter concedes its typing
   cadence is "a best approximation" of four different platform behaviors.
5. **A third design exists that the plan has not costed:** own the stack,
   delegate only the trigger and the enablement to the native undo manager.
   Flutter ships it on iOS. It preserves total order AND buys iOS shake /
   three-finger swipe reaching app state, which §1.3 records as currently
   impossible.
6. **A protocol gap, independent of all the above:** a native-tier undo emits
   only `text_changed`, indistinguishable from typing. Nothing tells the app
   the other stack moved. That is the direct cause of the Canvas failure.

## The question under test

kaya's ratified design has two stacks:

- **native tier** — the platform text widget's own undo, for typing;
- **core tier** — a kaya-owned stack of named transaction groups, for app state;

with `Edit>Undo` routed *focused-text-first, else the core stack* (D6).

Two stacks admit no total order. The suspected hole:

```
type "a"   →  native stack: [a]
app action X →  core stack:   [X]
type "b"   →  native stack: [a, b]

Undo ×3 with focus in the field: b, a, X      (design)
Chronological truth would be:    b, X, a
```

The intermediate state after the second undo — "a" typed but X not yet
applied — is a state that **never existed**. That is the failure class:
not lost data, but a history that reports a lie.

---

## §A — Frameworks that face the same split

### A1. Apple / AppKit — NSUndoManager: the split is REAL, and Apple closes it by DESTROYING the field stack on focus change

This is the most directly relevant precedent, because kaya's mac arm
(undo-plan §1.2) is measured to sit exactly on this machinery.

**Resolution is the responder chain**, i.e. focused-first — which is what D6
generalizes:

> "When the first responder of an application receives an `undo` or `redo`
> message, `NSResponder` goes up the responder chain looking for a next
> responder that returns an `NSUndoManager` object from `undoManager`. Any
> returned undo manager is used for the undo or redo operation."
> — [Using Undo in AppKit-Based Applications](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/AppKitUndo.html)

And the window is the fallback tier:

> "If the `undoManager` message wends its way up the responder chain to the
> window, the `NSWindow` object queries its delegates with
> `windowWillReturnUndoManager:` … If the delegate does not implement this
> method, the window creates an `NSUndoManager` object for the window and all
> its views."
> — [same](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/AppKitUndo.html)

A text view can opt into a private manager, which is the two-stack situation
by construction:

> "If you want a text view to use its own undo manager (and not the window's),
> you provide a delegate for the text view; the delegate can then return an
> instance of `NSUndoManager` from the `undoManagerForTextView:` delegate
> method."
> — [same](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/AppKitUndo.html)

**THE MITIGATION, stated by Apple in one sentence:**

> "The default undo and redo behavior applies to text fields and text in cells
> as long as the field or cell is the first responder (that is, the focus of
> keyboard actions). **Once the insertion point leaves the field or cell, prior
> operations cannot be undone.**"
> — [same](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/AppKitUndo.html)

Read that as an ordering argument and it is decisive. The interleaving
`[type a] [app X] [type b]` requires the field stack to *survive* the app
action. On AppKit's field-editor path it does not: any focus departure
discards it. So the anomaly cannot be constructed via focus change — the
sequence degrades to "b, then X", with "a" simply gone rather than
mis-ordered. **Apple buys total order by making the text tier amnesiac.**
That is a deliberate trade of *recall* for *coherence*, and it is documented
as behavior, not as a bug.

(kaya's own mac probe, undo-plan §1.2, independently measured the same
lifetime: "an entry's history dies on a focus round trip".)

The hole is not fully closed, though — see §C for the case Apple's sentence
does not cover (an app action taken *without* leaving the field: a toolbar
click, a menu item, a keyboard shortcut, a timer, a network arrival).

### A2. Qt — the two stacks exist, Qt does NOT document their interaction, and the community answer is "proxy the widget into your stack"

`QUndoStack`/`QUndoCommand` is Qt's app-level undo framework
([QUndoStack, Qt 6](https://doc.qt.io/qt-6/qundostack.html)). `QLineEdit` and
`QTextEdit` carry their own internal undo, unreachable from the base class.

The canonical thread on the split:

> "I suppose my life would be infinitely easier if I could just disable
> internal undo/redo support for selective QLineEdit and QTextEdit's."
> — Will Stokes, [qt-interest, Jan 2010](https://lists.qt-project.org/pipermail/qt-interest-old/2010-January/017377.html)

The reply proposes a **proxy-command architecture**: watch `undoAvailable`,
push a `QUndoCommand` that stands for the widget's edit, so that
"when undo/redo is needed, the undostack is the definitive source"
([same thread](https://lists.qt-project.org/pipermail/qt-interest-old/2010-January/017377.html)).
Note the shape of that fix: it does **not** keep two stacks. It re-establishes
a single total order by making every text edit *also* an entry in the app
stack, with the widget's own undo used only as the mechanism for executing the
step. Qt's community, given kaya's exact problem, chose one stack with a
delegating executor.

The lighter alternative offered — "check if focus is on the QLineEdit when the
undo action is triggered and call `lineEdit->undo()` directly" — is precisely
kaya's D6, and it is offered as the *shortcut*, not the recommendation.

Qt's own documentation does not address the interaction at all: the
[Overview of Qt's Undo Framework](https://doc.qt.io/qt-6/qundo.html) discusses
multiple stacks only in the sense of one stack **per document** with a
`QUndoGroup` selecting the active one — a partition by document, where exactly
one stack is live at a time and no interleaving is possible. That is a
different and safe use of "multiple stacks", and it is worth being precise
that Qt never blesses two *simultaneously live* stacks over the same document.

### A3. Flutter — `UndoHistory` / `UndoHistoryController`: per-widget by construction, no cross-stack story documented

`TextField.undoController` accepts an `UndoHistoryController`; if null, the
field "will create its own `UndoHistoryController`"
([TextField.undoController](https://api.flutter.dev/flutter/material/TextField/undoController.html)).
`UndoHistory` itself is generic — it "provides undo/redo capabilities for a
`ValueNotifier`" and can wrap any app state
([UndoHistory](https://api.flutter.dev/flutter/widgets/UndoHistory-class.html)).

So Flutter hands you the *same two-tier situation* and takes no position on
it: the API docs are silent on multiple `UndoHistory` instances or on how a
field's history relates to an app's. There is no router, no responder chain,
no "which one answers Ctrl+Z" — the app wires the shortcut itself.

Coalescing detail worth noting for kaya's §4 question: Flutter's snapshot
cadence is explicitly a *port of native heuristics*, not a principled rule —
the saving cadence is "a best approximation of the native behaviors of a
number of hardware keyboard on Flutter's desktop platforms, as there are
subtle differences between each of the platforms"
([UndoHistory](https://api.flutter.dev/flutter/widgets/UndoHistory-class.html)).

---

## §B — The editor consensus: nobody rides native undo

This is the strongest signal in the report, and it is unanimous.

### B1. ProseMirror — native undo was investigated and rejected

The long-running thread
[Native Undo History](https://discuss.prosemirror.net/t/native-undo-history/1823)
is the primary document. The arguments that matter to kaya:

- **The native stack tracks only what the browser itself produced.** Marijn
  Haverbeke: "I noticed that you can't undo certain parts of the editor
  content when using native undo. I suspect that the native undo history only
  keeps track of the content that was created by the user."
  ([thread](https://discuss.prosemirror.net/t/native-undo-history/1823))
  — i.e. programmatic/model-driven changes are invisible to it, which is
  exactly kaya's D7 problem viewed from the other side.
- **A single global stack over unrelated UI is a bug, not a feature.** The
  discussion's objection to a global manager is that it "would also undo the
  content of the search string" — unrelated UI state landing in the document's
  history ([thread](https://discuss.prosemirror.net/t/native-undo-history/1823)).
  This cuts *for* kaya's separation instinct and *against* a naive single
  stack: one total order over everything is also wrong.
- **Desynchronization is user-visible.** Intercepting native undo leaves the
  browser stack empty, so the redo entry vanishes from the context menu —
  the platform's own affordances start lying about what is undoable
  ([thread](https://discuss.prosemirror.net/t/native-undo-history/1823)).
  kaya has the same exposure on Windows, where undo-plan §1.1 records that the
  minimal TextBox template shows Undo in its right-click menu.

### B2. CodeMirror 6 — history is an extension the editor owns; native is unusable

CodeMirror 6 ships no undo by default; `history()` is an extension
([codemirror/history](https://github.com/codemirror/history)). The structural
reason is that the browser's `historyUndo`/`historyRedo` `beforeinput` events
only fire when the browser's own stack is non-empty — and an editor that
handles input itself never puts anything there.

### B3. The W3C editing group has an open issue that states the trap exactly

[w3c/editing#509](https://github.com/w3c/editing/issues/509) (Nov 2025) is the
cleanest statement of the failure mode kaya should worry about, from the
author of an editor that owns its own model:

> "now i go to Edit > Undo in the browser nothing happens because the browser
> didn't get a history event, as there's nothing on the browser-native undo
> stack."
> — [w3c/editing#509](https://github.com/w3c/editing/issues/509)

and the note that this is why **Figma's native Edit > Undo does not work**;
users must use the app's own keybindings
([same](https://github.com/w3c/editing/issues/509)). The requested fixes are
either "always fire the event so the app can handle it" or
`document.addHistoryEntry()` so the app can **push its own steps into the
native stack to keep the orders merged** — the second is a direct admission
that two stacks need a merge point.

### B4. Monaco — native undo actively corrupts the model

Monaco keeps a hidden textarea for IME/input and applies changes to its own
model. When the browser's native undo fires on that textarea, the two diverge:

- [microsoft/monaco-editor#1782](https://github.com/microsoft/monaco-editor/issues/1782)
  — "Monaco's underlying textarea, and content, can get out of sync when
  native undo is used".
- [microsoft/monaco-editor#2346](https://github.com/microsoft/monaco-editor/issues/2346)
  — "Native browser undo/redo commands take incorrect effect to the editor
  content"; reported to duplicate text, in both Chrome and Firefox.

### B5. Quill, Slate — same verdict

Quill ships a `history` module as **core**, not optional, and documents the
reason as native unpredictability: the module exists because native undo/redo
handling is inconsistent, so Quill "bridges the gap by implementing its own
undo manager and exposing `undo()` and `redo()` as APIs"
([Quill History Module](https://quilljs.com/docs/modules/history)).
Slate's `withHistory` likewise "keeps track of the operation history of a
Slate editor as operations are applied to it"
([slate-history](https://docs.slatejs.org/libraries/slate-history)).

### B6. The count, from the W3C editing taskforce — this is the money quote

The taskforce polled seven JavaScript editor projects on whether the
browser's built-in undo was of any use. From
[w3c/editing#150](https://github.com/w3c/editing/issues/150):

> **All** responded that the browser's undo stack was either **"useless" or
> "harmful"**: CKEditor, ProseMirror, QuillJS, ContentTools, Substance.io,
> TinyMCE, Froala.

and separately, on shipping apps:

> Applications "were investigated and it was determined that they use their
> own undo stacks (a separate stack for each input field)": Medium.js, Gmail,
> Office 365, iCloud Pages, Google Docs, Facebook's input fields, Wikimedia
> VisualEditor.
> — [w3c/editing#150](https://github.com/w3c/editing/issues/150)

Two exceptions were found, and both prove the rule: Facebook's draft-js falls
through to native undo *only* for spell-checker fixes, and TypeIt.org is a
barebones keyboard helper
([same](https://github.com/w3c/editing/issues/150)).

**Verdict on §B for kaya:** the consensus is about *document editors* — the
class kaya's D8 explicitly defers ("an editor-grade text component with range
edits and a selection model"). It is not automatically a verdict on kaya's
form fields. But it is a hard ceiling: **the day kaya ships an editor artifact,
D1's native tier stops being viable for it**, and every project that tried the
other way came back. D8 already anticipates the escape hatch (per-widget
opt-out of the native tier); this research says that hatch is not optional
long-term, it is the eventual default for one widget class.

---

## §C — Windows and GTK: where the routing has no fall-through

### C1. WPF — the hole is WORSE than kaya's, because there is no fall-through at all

WPF's `ApplicationCommands.Undo` is a routed command. `TextBoxBase` handles it
internally and **marks it handled**, which stops it bubbling:

> "When the WPF TextBox and RichTextBox handle ApplicationCommands, they mark
> them as 'handled' to prevent them bubbling up to your code."
> — [Undo/Redo Redirection for WPF, CodeProject](https://www.codeproject.com/Tips/1180881/Redo-Undo-WPF)

The consequence, stated by the same author:

> "When a TextBox has focus, it completely blocks the Undo or Undo/Redo of
> other components because the TextBox has its own Undo/Redo handling."
> — [same](https://www.codeproject.com/Tips/1180881/Redo-Undo-WPF)

So WPF ships kaya's D6 routing *minus the fall-through*: focused text wins
unconditionally, and the app stack is unreachable while a field has focus.
The community workaround is to re-take the command with the
`AddHandler(..., handledEventsToo: true)` overload, or
`CommandManager.AddPreviewExecutedHandler`, and then — note the choice — the
recommendation is to **suppress the TextBox's undo entirely**:

> One approach is "to disable TextBox Undo/Redo handling completely, because
> it cannot be more valuable than the upper-level and application-specific
> Undo/Redo."
> — [same](https://www.codeproject.com/Tips/1180881/Redo-Undo-WPF)

Note that WPF *can* do this: `TextBoxBase.IsUndoEnabled` exists
([docs](https://learn.microsoft.com/en-us/dotnet/api/system.windows.controls.primitives.textboxbase.isundoenabled)),
along with `LockCurrentUndoUnit`
([docs](https://learn.microsoft.com/en-us/dotnet/api/system.windows.controls.primitives.textboxbase.lockcurrentundounit)).
The undo-plan's suppression-matrix finding — that WinUI's `TextBox` has no
`IsUndoEnabled` — is a **WinUI 3 / UWP regression relative to WPF**, not an
inherent Windows fact. WinUI keeps only the blunt instrument,
`ClearUndoRedoHistory()`, documented as "Empties the undo and redo buffers"
([TextBox.ClearUndoRedoHistory](https://learn.microsoft.com/en-us/uwp/api/windows.ui.xaml.controls.textbox.clearundoredohistory)).
Worth stating in the plan, because it changes the framing of D1's
"three platforms make it unwinnable": one of those three had the lever and
dropped it.

### C2. GTK — a per-widget switch and an irreversible-action bracket, but no app-level framework at all

GTK4 added native undo across editables:

> "GTK 4 now has native support for undo … You can now set the `enable-undo`
> properties to TRUE on `GtkTextView`, `GtkEditable` widgets like `GtkText` or
> `GtkEntry`."
> — [GtkSourceView Next, GNOME blog](https://blogs.gnome.org/chergert/2020/09/22/gtksourceview-next/)

and the escape hatch kaya's D7 names:

> "Developers may want some operations to not be undoable. To do this, wrap
> your changes in `gtk_text_buffer_begin_irreversible_action()` and
> `gtk_text_buffer_end_irreversible_action()`."
> — [Gtk.TextBuffer](https://docs.gtk.org/gtk4/class.TextBuffer.html)

Critically, **GTK ships no app-level undo framework** — no `QUndoStack`, no
`NSUndoManager`. There is nothing for the widget stack to be out of order
*with*, at the toolkit level; each app builds its own and decides. So GTK is
not a precedent either way; it is only the platform that gives kaya the
cleanest levers.

---

## §D — Ordering anomalies as a known class: yes, and they have shipped

### D1. VS Code ships kaya's design, DOCUMENTED, and users file bugs against it

This is the closest living analogue to kaya's D6, and it is instructive that
it is *documented as a feature* and *reported as a bug*.

The VS Code release notes state the model plainly:

> "Keep in mind that we have separate undo stacks for the editor and the File
> Explorer, and we choose which one to undo based on focus."
> — quoted in [microsoft/vscode#113653](https://github.com/microsoft/vscode/issues/113653)

That is D1+D6 exactly: two stacks, focus routes. The filed complaint against
it:

> the feature "was supposed to undo only actions related to where the focus is
> set but it's not working, it just automatically goes from one stack to
> another."
> — [microsoft/vscode#113653](https://github.com/microsoft/vscode/issues/113653)

The reported sequence — write code, rename the file, edit more, press Ctrl+Z
with focus in the editor, get prompted to undo the *rename* — is structurally
kaya's `[type a] [app X] [type b]` case. The user's model is a single
chronological history; the implementation's model is two stacks and a router;
the observable result is that Undo answers with something from the other tier
at a moment the user did not expect.

A second instance in the same product, from a widget rather than a pane:

> Expected: "This should undo the replace." Actual: "This is calling browser
> undo."
> — [microsoft/vscode#8350](https://github.com/Microsoft/vscode/issues/8350)

and the reported workaround for the search/replace case is literally
"change focus to the text buffer window and then press undo"
([microsoft/vscode#20026](https://github.com/microsoft/vscode/issues/20026)) —
i.e. the user is asked to manually select which stack answers, which is what
"routed by focus" means once it leaks.

### D2. Apple's own architect: multiple undo scopes per document are "dubious at best"

The strongest single statement against kaya's two-tier design comes from
Maciej Stachowiak (Apple/WebKit), arguing to drop scoped `UndoManager`s from
the web platform:

> "I am not sure that multiple independent UndoManagers per page is even a
> good feature. The use cases document gives a use case of a text editor with
> an embedded vector graphics editor. But for all the native apps I know of
> that have this feature, **they present a single unified undo queue per top
> level document**, at least on the Mac."
> — [Maciej Stachowiak, public-webapps, 2012-08-22](https://lists.w3.org/Archives/Public/public-webapps/2012JulSep/0561.html)

> "Ryosuke also raised the possibility of multiple text fields having separate
> UndoManagers. 'On Mac, most apps wipe the undo queue when you change text
> field focus. WebKit preserves a single undo queue across text fields, so
> that tabbing out does not kill your ability to undo.' **I don't know of any
> app where you get separate switchable persistent undo queues.** Things are
> similar on iOS."
> — [same](https://lists.w3.org/Archives/Public/public-webapps/2012JulSep/0561.html)

> "my feeling is that the use case for scoped UndoManagers is dubious at best,
> and **may cause authors to create confusing UI**."
> — [same](https://lists.w3.org/Archives/Public/public-webapps/2012JulSep/0561.html)

Read that middle quote carefully, because it names the two escape routes and
says the third does not exist in the wild:

| route | what it does | who does it |
|---|---|---|
| **wipe on focus change** | field stack dies when focus leaves; no interleaving possible | "most apps on Mac" — and it is Apple's documented AppKit behavior |
| **one unified queue** | text edits are entries in the app stack; total order by construction | WebKit; Word; the Qt proxy-command pattern |
| **separate switchable persistent queues** | two live stacks, routed by focus — kaya's D6 | *"I don't know of any app where you get [this]"* |

kaya's design is the third row. In 2012 an Apple architect could not name an
app that shipped it. VS Code shipped it in 2020 and got §D1.

Stachowiak's follow-up adds the cross-platform wrinkle that kaya, being an
8-language cross-platform toolkit, will feel: Mac apps tend to a shared stack,
Windows Firefox uses separate ones per input field, so "web apps that match
their developer's platform of choice … don't seem quite right elsewhere"
([2012-08-22](https://lists.w3.org/Archives/Public/public-webapps/2012JulSep/0568.html)).
kaya's invariant 1 (uniform semantics in all bindings) has a sibling problem
here: uniform semantics across *platforms*, where the platforms disagree about
what undo scope even means.

### D3. The academic name for the impossible state

The "state that never existed" is not a bug report, it is a defined property
of any non-linear undo. From the selective-undo literature:

> "selectively undoing some changes does not result in one of the previously
> visited nodes in the history tree. Rather, **it creates a new node that has
> never existed before**."
> — [Yoon & Myers, *Supporting Selective Undo in a Code Editor*, ICSE 2015 (Azurite)](http://www.cs.cmu.edu/~marmalade/papers/ICSE15-Azurite-v12-CameraReady.pdf)

The foundational treatment is Berlage's command-object model, which observes
that linear undo "provides an arbitrarily long history" but cannot "undo
isolated commands from the history without undoing all following commands" —
and that selective undo therefore has to resolve dependencies **semantically
rather than chronologically**
([Berlage, TOCHI 1(3), 1994](https://dl.acm.org/doi/10.1145/196699.196721)).

This is the precise diagnosis of kaya's hole. **Two stacks routed by focus is
selective undo wearing a linear-undo costume.** The user is offered a single
`Edit>Undo` — a linear-undo affordance, whose entire contract is "step
backwards through what happened" — and the implementation silently performs a
selective undo (skip over X, undo a). The literature says selective undo is
legitimate *when the dependencies are resolved semantically and the user can
see what they are choosing*. kaya offers neither: there is no dependency
analysis between the native tier and the core tier (there cannot be — the core
cannot see inside the native stack), and no UI that shows two histories.

D3 also tells you the mitigation the field actually uses: selective-undo
systems ship a **history visualization** (Azurite's timeline; Photoshop's
History panel) so the user picks a step rather than guessing what the single
button will do
([Azurite](http://www.cs.cmu.edu/~azurite/)).

### D4. IntelliJ — the third option: DETECT the conflict and REFUSE

JetBrains' IDEs run one project-wide undo but scope undo *requests* per
editor, and when the two disagree they neither silently reorder nor silently
skip. They stop:

> "Cannot undo. Following files affected by this action have already been
> changed."
> — reported across many years, e.g.
> [IJPL-31069](https://youtrack.jetbrains.com/projects/IJPL/issues/IJPL-31069/Better-experience-for-Undo-Following-files-affected-by-this-..-have-been-already-changed),
> [JetBrains support](https://intellij-support.jetbrains.com/hc/en-us/community/posts/206235519--Cannot-undo-Some-files-were-changed)

The rule is: an undo step whose effects were overtaken by a later change in
another scope is **refused**, loudly, rather than applied out of order. This
is not loved — it generates a steady stream of complaints and a standing
feature request for per-file undo — but it is a *third* design point kaya
should have on the table alongside "unify" and "route by focus": **detect the
interleave and refuse the older step**, which converts a silent wrong answer
into a visible dead end. It is also the design that most resembles kaya's own
doctrine of refusing loudly at apply (D4's non-invertible-op refusal).

### D5. Blender — separate undo systems, acknowledged as confusing

Blender historically ran separate undo stacks for object mode, edit mode, and
the text editor, and its own tracker acknowledged that
"separate undo systems might confuse users sometimes"
([Blender T27573](https://developer.blender.org/T27573) — the tracker now
403s to fetchers; the statement is quoted in secondary sources and the issue
title is "Undo stacks"). Blender's subsequent direction was to unify toward a
global undo with mode-aware steps. Treat as supporting, not primary.

---

## §E — Coalescing: how the field turns keystrokes into one step

Relevant because if kaya ever owns typing (the alternative to D1), it inherits
this. Four different mechanisms are in use, and **none of them agree**:

| system | mechanism | source |
|---|---|---|
| **AppKit / NSUndoManager** | run-loop pass grouping by default: "all registered blocks into 1 undoable action … for each pass of the RunLoop" | [Tietze](https://christiantietze.de/posts/2022/09/undoable-text-changes/) |
| **NSTextView** | explicit coalescing group for typing, broken on demand via `breakUndoCoalescing()`; the group is named via `setActionName:` → "Undo Typing" | [NSTextView](https://developer.apple.com/documentation/appkit/nstextview), [Setting Action Names](https://developer.apple.com/library/archive/documentation/cocoa/Conceptual/UndoArchitecture/Articles/SettingUndoNames.html) |
| **Quill** | fixed time window, `delay` default **1000 ms**: "with delay set to `0`, nearly every character is recorded as one change and so undo would undo one character at a time" | [Quill History](https://quilljs.com/docs/modules/history) |
| **Emacs** | command-count grouping: "Consecutive character insertion commands are usually grouped together into a single undo record, to make undoing less tedious" | [GNU Emacs Manual, Undo](https://www.gnu.org/software/emacs/manual/html_node/emacs/Undo.html) |
| **Qt** | explicit `mergeWith`/`id()` command compression + `beginMacro`/`endMacro` | [Qt Undo Framework](https://doc.qt.io/qt-6/qundo.html) |
| **Flutter** | ports per-platform heuristics: the cadence is "a best approximation of the native behaviors of a number of hardware keyboard on Flutter's desktop platforms, as there are subtle differences between each of the platforms" | [UndoHistory](https://api.flutter.dev/flutter/widgets/UndoHistory-class.html) |

Two things fall out for kaya:

1. **Flutter's sentence is the cost estimate.** A cross-platform toolkit that
   owns typing undo does not implement "a rule"; it implements four
   approximations of four platforms' rules and documents that they differ.
   That is a direct argument *for* D1's delegation, and it is the strongest
   one in this report.
2. **Quill's `userOnly` is the D7 question, solved in one flag.** Quill:
   "By default all changes, whether originating from user input or
   programmatically through the API, are treated the same … If `userOnly` is
   set to `true`, only user changes will be undone or redone"
   ([Quill History](https://quilljs.com/docs/modules/history)). kaya's D7
   ("a programmatic write resets the widget's native undo history") is the
   *destructive* answer to the same question, forced because the platforms
   expose no `userOnly`. Worth naming in the plan that the non-destructive
   answer exists and is one boolean when you own the stack — it is part of
   the price of delegating.

---

## §F — Does anyone ship exactly kaya's design, and what do users say?

Yes: **three systems ship it, and all three generate the same bug reports.**

### F1. AppKit — kaya's D6 is AppKit's default, complete with fall-through

kaya's own mac probe (undo-plan §1.2) found that `NSApp`'s `undo:` path
"already implements the ratified focused-text-first routing INCLUDING the
fall-through". That is real, and the mechanism is the responder chain plus
menu validation: the field editor's manager answers while it has content;
when its `canUndo` goes false the item stops validating there and the chain
continues to the window/document manager
([AppKit undo](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/AppKitUndo.html)).

So AppKit is the existence proof that the design *works*. It is also the place
to look for what it costs, and the costs are documented:

- **Apple pays for total order with amnesia.** "Once the insertion point
  leaves the field or cell, prior operations cannot be undone"
  ([same](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/AppKitUndo.html)).
  This is not incidental — it is the only reason the interleave is rare on
  macOS. Any app action reached by clicking a control that *takes* first
  responder wipes the field tier first.
- **The residue is the case where focus does NOT move.** A toolbar button, a
  menu item, a keyboard shortcut, a timer, or a network arrival changes app
  state without disturbing the field editor. That is exactly kaya's
  `[type a] [app X] [type b]` and AppKit does nothing about it.
- **Developers who hand-write the routing find it fragile.** From Apple's
  forums, a developer implementing `undo:`/`redo:` on a view controller to
  validate against a core-owned stack:

  > "if a text field is being edited in the window and I type to edit the text
  > field, my view controller gets sent validateUserInterfaceItem … and blocks
  > the field editor from getting undo: and redo:"
  > — [Apple Developer Forums 83248](https://developer.apple.com/forums/thread/83248)

  and the second-order damage:

  > "Another negative side effect of implementing undo: and redo: in a
  > responder I just noticed is that setActionName: no longer works. If you
  > set the action name on your undo manager it won't update the menu item
  > title in the menubar."
  > — [same](https://developer.apple.com/forums/thread/83248)

  Apple's DTS answer: "Yes, that's a known side effect of implementing undo:
  and redo: yourself." The developer's own verdict on their working fix:
  "This works, but is a bit ugly and not sure if it could come back to bite"
  ([same](https://developer.apple.com/forums/thread/83248)).

  **This is directly relevant to kaya's mac arm**: the plan says
  "kayaSendToFocusedResponder's existing shape travels it unchanged", i.e.
  kaya intends to ride Apple's routing rather than implement `undo:`. That is
  the right call and this thread is the evidence for *why* — the moment kaya
  implements `undo:` itself on mac, it inherits the validation-ordering bug
  and loses menu-title updating.

### F2. VS Code — two stacks, focus-routed, documented, and complained about

Covered in §D1. The one-line summary a designer should carry: **the only
mainstream product that documents kaya's exact model also has an open issue
whose title is "Undo should be related only to the area on focus"**
([microsoft/vscode#113653](https://github.com/microsoft/vscode/issues/113653)).

### F3. Drupal Canvas — the same design in a web app, with the desync spelled out

Canvas (Drupal's site builder) owns app state in Redux and lets the browser
own text inputs. The filed bug, titled "Browser's undo state causes weird
things with our undo history":

> When focus is in an input field and the user presses cmd+z, the browser's
> native undo runs instead of the Redux history. "The values in the input
> correct undo, however, the redo button remains in 'disabled' state" — and
> worse, "**pressing undo in our UI now undoes the undo the user did**."
> — [Drupal Canvas #3508317](https://git.drupalcode.org/project/canvas/-/work_items/3508317)

Two failures in one report, and kaya is exposed to both:

1. **Enablement desync.** The app's Undo/Redo affordance reports the *core*
   stack's state while the *native* stack is the one that moved. kaya's D6
   computes enablement live from "ask the focused widget first", which handles
   this — but only for the menu item. On Windows the TextBox's own right-click
   Undo (undo-plan §1.1, P4) is a second affordance kaya does not compute, and
   on iOS the shake gesture is a third (§1.3). Each one moves a stack without
   telling the other.
2. **Redo divergence.** After a native undo, the core stack's redo pointer is
   untouched, so the two tiers' redo positions describe different histories.
   The design doc's D5 says the app learns of core undos via an `undone`
   occurrence — but a *native* undo emits only `text_changed`, which is
   indistinguishable from typing. **There is no occurrence that says "the
   native tier moved."** That is the concrete protocol gap this report would
   flag hardest after the ordering hole itself.

### F4. The inverse design that also ships: Flutter on iOS

Worth knowing because it is the alternative kaya has not costed. Flutter does
**not** delegate the typing stack to iOS. It owns the stack in Dart
(`UndoHistory`) and delegates only the *trigger* and the *enablement*:

> Flutter's `UndoManager` is "a low-level interface to the system's undo
> manager"; when the platform triggers undo/redo the system notifies Flutter's
> `UndoManagerClient` via `handlePlatformUndo`. `setUndoState` "allows Flutter
> applications to inform the platform's undo manager about the current state
> by specifying whether undo and redo operations are available", keeping the
> native UI in sync.
> — [UndoManager (services)](https://api.flutter.dev/flutter/services/UndoManager-class.html)

The PR that added it is explicit that the channel is deliberately *not*
text-specific:

> "Since NSUndoManager itself is not specific to text editing, hypothetically
> this could be generic to any kind of undo/redo. In EditableText you would
> specifically use it for text editing."
> — reviewer, [flutter/flutter#98294](https://github.com/flutter/flutter/pull/98294)

This buys iOS's shake-to-undo, three-finger swipe and iPad keyboard undo
*routing into the app's single stack* — which is precisely the thing kaya's
§1.3 probe found it cannot get ("the core tier is invisible to shake").
**One stack, native triggers.** Total order preserved, native affordances
preserved.

And the bill is itemized in Flutter's own tracker:

- coalescing: "a simple time-based throttle" on every platform, with an open
  P2 to "Figure out what the exact algorithms are for coalescing text input on
  Windows, Mac, and Linux"
  ([flutter#99186](https://github.com/flutter/flutter/issues/99186));
- IME: undo is wrong for Japanese composition — "'あ' remains in
  textformfield and 'い' blinks when the undo button is pressed"
  ([flutter#134398](https://github.com/flutter/flutter/issues/134398));
- programmatic writes still clobber history on some backends
  ([flutter#100699](https://github.com/flutter/flutter/issues/100699)),
  and focus loss still kills it on web
  ([flutter#104082](https://github.com/flutter/flutter/issues/104082)).

That is the honest price of owning typing: three open bugs, one of them
per-platform-forever, one of them IME.

---

## §G — Findings that bear on the decision

### G1. The ordering hole is real, it is a known class, and no shipping system solves it — they all buy it off

The anomaly kaya suspects is not hypothetical and not exotic. It is what
[VS Code #113653](https://github.com/microsoft/vscode/issues/113653) reports,
what [Drupal Canvas #3508317](https://git.drupalcode.org/project/canvas/-/work_items/3508317)
reports, and what
[Yoon & Myers](http://www.cs.cmu.edu/~marmalade/papers/ICSE15-Azurite-v12-CameraReady.pdf)
name in the literature: a non-linear undo "creates a new node that has never
existed before". Two stacks routed by focus **is selective undo behind a
linear-undo button** — and the linear-undo button's entire contract is
chronological.

The field's four escapes, none of which kaya currently takes:

| escape | how | who |
|---|---|---|
| **A. Amnesia** — kill the field stack when it could interleave | field history dies on focus change | AppKit ([doc](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/AppKitUndo.html)); "most apps on Mac" ([Stachowiak](https://lists.w3.org/Archives/Public/public-webapps/2012JulSep/0561.html)) |
| **B. Unify** — text edits become entries in the one stack | proxy command; or own typing entirely | Qt community pattern ([thread](https://lists.qt-project.org/pipermail/qt-interest-old/2010-January/017377.html)); WebKit; Word; every JS editor ([w3c/editing#150](https://github.com/w3c/editing/issues/150)) |
| **C. Refuse** — detect the interleave and stop | "Cannot undo. Following files affected by this action have already been changed." | JetBrains ([IJPL-31069](https://youtrack.jetbrains.com/projects/IJPL/issues/IJPL-31069/Better-experience-for-Undo-Following-files-affected-by-this-..-have-been-already-changed)) |
| **D. Show the history** — let the user pick the step | history panel / timeline | Photoshop; Azurite ([tool](http://www.cs.cmu.edu/~azurite/)) |

kaya's D6 takes none of these. It takes the fifth option — *let it happen and
don't mention it* — which is the option nobody documents because nobody
defends it.

**The cheapest fix that fits kaya's existing doctrine is C, and D7 already
builds the machinery for A.** D7 clears the field's native history on a
programmatic write. Extend that trigger from *"kaya wrote to this field"* to
*"a core undo group was committed while this field had focus"* and the hole
closes by construction: the field tier can never contain a step older than the
newest core step. The cost is the same cost Apple already charges and mac
users already live with — typing history is lost when the app does something —
and it is one line at the same call site D7 already touches, on every backend.
It also makes kaya's semantics *uniform* (invariant 1) in a way D6 currently
is not: today the observable undo order depends on whether the platform's
field stack survives the app action, which the §1 probes show differs per
platform.

If A is judged too destructive, C is the doctrinally native answer: kaya
already refuses loudly at apply for non-invertible ops (D4) and for
one-dialog-per-process. "Refuse a core undo step that a live native tier has
overtaken" is the same shape of wall.

### G2. The two-stack design is defensible for form fields and INDEFENSIBLE for an editor — and D8 already knows it

The editor consensus is total and one-directional. Every JS editor project
polled by the W3C called the browser's native undo **"useless or harmful"**;
every mainstream editing app ships its own stack
([w3c/editing#150](https://github.com/w3c/editing/issues/150)). Monaco has
open bugs where native undo desynchronizes its model outright
([#1782](https://github.com/microsoft/monaco-editor/issues/1782),
[#2346](https://github.com/microsoft/monaco-editor/issues/2346)). ProseMirror's
thread is a decade of "we tried, it can't be made coherent"
([discuss](https://discuss.prosemirror.net/t/native-undo-history/1823)).

This does **not** refute D1 as written, because kaya's text widgets are
uncontrolled form fields, not documents — the class where delegation is the
normal choice and where Apple, GTK, WinUI and Compose all provide the stack
for free. It refutes D1 *as a permanent answer*. D8's "per-widget opt-out of
the native text-undo tier" is currently listed as an additive extension "not
built until an artifact demands it"; this research says **the artifact that
demands it is the text-editor artifact D8 itself names**, so the opt-out
should be designed now even if built later, and the plan should say that the
editor artifact will use it rather than leaving it open.

Second-order: the plan's premise that "three platforms make suppression
unwinnable" deserves one correction. WPF has had `IsUndoEnabled` since .NET
3.0, documented with exactly the semantics kaya's D7 wants — "Setting this
property to `false` clears the undo stack"
([TextBoxBase.IsUndoEnabled](https://learn.microsoft.com/en-us/dotnet/api/system.windows.controls.primitives.textboxbase.isundoenabled)).
WinUI 3's `TextBox` has `CanUndo`, `CanRedo`, `Undo()`, `Redo()` and
`ClearUndoRedoHistory()` but **no** `IsUndoEnabled`
([WinUI TextBox](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.textbox)).
So the Windows leg of the suppression matrix is a WinUI regression, not a
Windows fact — worth a sentence in §0 so a future session does not treat it as
immovable.

### G3. There is a third design nobody in the plan has costed: own the stack, delegate the TRIGGER

Flutter on iOS ships it: the app's single `UndoHistory` is authoritative, and
`NSUndoManager` is used only as a *transport* — the platform tells Flutter
"the user asked for undo", Flutter tells the platform "here is whether undo is
available" via `setUndoState`
([UndoManager](https://api.flutter.dev/flutter/services/UndoManager-class.html),
[PR #98294](https://github.com/flutter/flutter/pull/98294)).

For kaya this maps cleanly onto machinery that already exists or is planned:
`MenuRole::{Undo, Redo}` with live enablement (D6) is already the
"tell the platform what's available" half; the four backends' key-hook /
responder / accelerator paths are already the "platform tells kaya" half. It
would give kaya one stack, total order by construction, D5's `undone`
occurrence covering *every* undo including typing, and — the thing D1's
delegation cannot buy — **iOS shake and three-finger swipe reaching app
state**, which §1.3 records as currently impossible.

The price is exactly Flutter's open bug list: per-platform coalescing that is
an approximation forever ([#99186](https://github.com/flutter/flutter/issues/99186)),
IME composition ([#134398](https://github.com/flutter/flutter/issues/134398)),
and a `text_changed`-shaped write path that must not re-enter. That price is
real and the plan's D1 rejection of "one kaya-owned unified stack" is
defensible *on the coalescing argument alone* — Flutter's own docs concede
their cadence is "a best approximation … as there are subtle differences
between each of the platforms"
([UndoHistory](https://api.flutter.dev/flutter/widgets/UndoHistory-class.html)).

But the plan currently rejects the unified stack on the *suppression matrix*,
which G2 shows is partly wrong, rather than on the *coalescing* argument,
which is entirely right. Fixing that reasoning matters, because the
suppression argument would evaporate if WinUI ever restores `IsUndoEnabled`,
and the decision would then rest on nothing.

### G4. The protocol gap: nothing tells the app the native tier moved

D5 gives the app an `undone`/`redone` occurrence carrying the reverted values
for **core** undos. A native undo emits only `text_changed`, byte-identical to
typing. So:

- an app mirroring text into its own model cannot distinguish "user typed" from
  "user undid";
- an app rendering its own Undo affordance cannot know its enablement changed;
- redo positions in the two tiers diverge silently — the Canvas failure
  ("pressing undo in our UI now undoes the undo the user did",
  [#3508317](https://git.drupalcode.org/project/canvas/-/work_items/3508317)).

Whatever is decided about G1, this is worth closing on its own: either the
native tier gets its own occurrence, or D6's routing consumes the native undo
and *re-emits* it through the same channel as the core tier so there is one
observable event class for "something was undone".

---

## Appendix — every source used

- Apple, [Using Undo in AppKit-Based Applications](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/AppKitUndo.html)
- Apple, [Using Undo on iPhone](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/iPhoneUndo.html)
- Apple, [Setting Action Names](https://developer.apple.com/library/archive/documentation/cocoa/Conceptual/UndoArchitecture/Articles/SettingUndoNames.html)
- Apple, [NSTextView](https://developer.apple.com/documentation/appkit/nstextview) · [windowWillReturnUndoManager(_:)](https://developer.apple.com/documentation/appkit/nswindowdelegate/windowwillreturnundomanager(_:))
- Apple Developer Forums, [thread 83248 — NSUndoManager undo:/redo: validation](https://developer.apple.com/forums/thread/83248) · [thread 814661 — Can TextField handle undo?](https://developer.apple.com/forums/thread/814661)
- NSHipster, [NSUndoManager](https://nshipster.com/nsundomanager/)
- Christian Tietze, [How to Fix When Some Text Changes Don't Come with Automatic Undo?](https://christiantietze.de/posts/2022/09/undoable-text-changes/)
- Maciej Stachowiak, public-webapps [2012-08-22 (0561)](https://lists.w3.org/Archives/Public/public-webapps/2012JulSep/0561.html) · [(0568)](https://lists.w3.org/Archives/Public/public-webapps/2012JulSep/0568.html)
- Ryosuke Niwa, [public-webapps-github 2016-09](https://lists.w3.org/Archives/Public/public-webapps-github/2016Sep/1461.html)
- W3C, [Web Editing APIs/UndoManager Problem Descriptions](https://www.w3.org/wiki/Web_Editing_APIs/UndoManager_Problem_Descriptions)
- w3c/editing, [#150 Removal of browser built-in Undo stack from contenteditable](https://github.com/w3c/editing/issues/150) · [#509 historyUndo unusable for own-model editors](https://github.com/w3c/editing/issues/509)
- w3c/input-events, [#36 How to make undo/redo useful](https://github.com/w3c/input-events/issues/36)
- ProseMirror, [Native Undo History](https://discuss.prosemirror.net/t/native-undo-history/1823) · [prosemirror-history](https://github.com/ProseMirror/prosemirror-history)
- CodeMirror, [codemirror/history](https://github.com/codemirror/history) · [Managing undo history of multiple views](https://discuss.codemirror.net/t/managing-undo-history-of-multiple-views-with-a-single-root-state/9179)
- Monaco, [#1782](https://github.com/microsoft/monaco-editor/issues/1782) · [#2346](https://github.com/microsoft/monaco-editor/issues/2346)
- Quill, [History Module](https://quilljs.com/docs/modules/history)
- Slate, [slate-history](https://docs.slatejs.org/libraries/slate-history)
- Qt, [QUndoStack](https://doc.qt.io/qt-6/qundostack.html) · [Overview of Qt's Undo Framework](https://doc.qt.io/qt-6/qundo.html) · [qt-interest thread, 2010-01](https://lists.qt-project.org/pipermail/qt-interest-old/2010-January/017377.html)
- Flutter, [UndoHistory](https://api.flutter.dev/flutter/widgets/UndoHistory-class.html) · [UndoHistoryController](https://api.flutter.dev/flutter/widgets/UndoHistoryController-class.html) · [TextField.undoController](https://api.flutter.dev/flutter/material/TextField/undoController.html) · [services.UndoManager](https://api.flutter.dev/flutter/services/UndoManager-class.html) · [PR #98294](https://github.com/flutter/flutter/pull/98294) · [#99186](https://github.com/flutter/flutter/issues/99186) · [#100699](https://github.com/flutter/flutter/issues/100699) · [#104082](https://github.com/flutter/flutter/issues/104082) · [#134398](https://github.com/flutter/flutter/issues/134398)
- WPF, [TextBoxBase.IsUndoEnabled](https://learn.microsoft.com/en-us/dotnet/api/system.windows.controls.primitives.textboxbase.isundoenabled) · [LockCurrentUndoUnit](https://learn.microsoft.com/en-us/dotnet/api/system.windows.controls.primitives.textboxbase.lockcurrentundounit) · [Undo/Redo Redirection for WPF](https://www.codeproject.com/Tips/1180881/Redo-Undo-WPF)
- WinUI/UWP, [TextBox](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.textbox) · [TextBox.ClearUndoRedoHistory](https://learn.microsoft.com/en-us/uwp/api/windows.ui.xaml.controls.textbox.clearundoredohistory)
- GTK, [Gtk.TextBuffer](https://docs.gtk.org/gtk4/class.TextBuffer.html) · [GtkSourceView Next (GTK4 native undo)](https://blogs.gnome.org/chergert/2020/09/22/gtksourceview-next/)
- Compose, [UndoState API reference](https://developer.android.com/reference/kotlin/androidx/compose/foundation/text/input/UndoState) · [BasicTextField2: A TextField of Dreams (undoState walkthrough)](https://proandroiddev.com/basictextfield2-a-textfield-of-dreams-2-2-fdc7fbbf9ffb)
- VS Code, [#113653](https://github.com/microsoft/vscode/issues/113653) · [#8350](https://github.com/Microsoft/vscode/issues/8350) · [#20026](https://github.com/microsoft/vscode/issues/20026)
- JetBrains, [IJPL-31069](https://youtrack.jetbrains.com/projects/IJPL/issues/IJPL-31069/Better-experience-for-Undo-Following-files-affected-by-this-..-have-been-already-changed) · [support thread](https://intellij-support.jetbrains.com/hc/en-us/community/posts/206235519--Cannot-undo-Some-files-were-changed)
- Drupal Canvas, [#3508317](https://git.drupalcode.org/project/canvas/-/work_items/3508317)
- GNU, [Emacs Manual — Undo](https://www.gnu.org/software/emacs/manual/html_node/emacs/Undo.html)
- Berlage, [A selective undo mechanism for GUIs based on command objects, TOCHI 1994](https://dl.acm.org/doi/10.1145/196699.196721)
- Yoon & Myers, [Supporting Selective Undo in a Code Editor, ICSE 2015](http://www.cs.cmu.edu/~marmalade/papers/ICSE15-Azurite-v12-CameraReady.pdf) · [Azurite](http://www.cs.cmu.edu/~azurite/)
- Blender, [T27573 Undo stacks](https://developer.blender.org/T27573) (tracker now 403s to fetchers; title and gist via secondary sources)
