# The `submitted` occurrence: the design pass (2026-09-24)

Status: PICKED 2026-09-24 (the maintainer: "the submitted occurrence
makes sense next. let's have the chat app be the ultimate goal"), off
the roadmap page's menu (https://claude.ai/artifact/Lg1PBcYNgpdpnWWwpfX92K,
piece #2). The ledger entry that carried it since the search pass is
docs/deferred.md's `submitted` entry (recorded 2026-09-06, the search
pass's S4 amendment); the chat app is its named consumer and the goal
the next slices walk toward (§8). The search pass (docs/search-plan.md)
and the slider pass (docs/slider-plan.md) are the precedents for the
shape: the search pass recorded the occurrence's layout and the gate's
shape the day it refused to build it, and the slider pass built the
"per-movement is not the commit" rule this one mirrors. Nothing below is
measured yet; §7 lists what is measured before an arm is written.

## §0 — What the platforms do

Read from the vendors' documentation. The ONE fact every platform agrees
on: a single-line text field has a Return action and a multi-line one
does not — Return in a text view inserts a newline, and a "send" gesture
is either a modifier chord the app wires itself (Return with the field
told to submit, Shift+Return for the newline) or the phone keyboard's
action key relabelled Send.

| | single-line field, Return | multi-line view, Return | the phone keyboard's action key | reports |
|---|---|---|---|---|
| macOS / SwiftUI | `TextField` fires `.onSubmit`; AppKit's `NSTextField` sends its action on Return | `TextEditor` inserts a newline; no `onSubmit`. `TextField(axis: .vertical)` (macOS 13+) is a GROWING single-line field: it wraps AND fires `.onSubmit` on Return | none | `.onSubmit`, `.onKeyPress(.return)` (macOS 14+) with `modifiers` |
| iOS / SwiftUI | `TextField` fires `.onSubmit`; the keyboard's return key wears `.submitLabel(.send / .search / .done / .go)` | `TextEditor` inserts a newline and shows Return; `.submitLabel` has no effect on it | `TextField(axis: .vertical)` shows the label and fires `.onSubmit`; Return then does NOT insert a newline (the field has no newline gesture at all when a submit label is set) | `.onSubmit` |
| Android / Compose | `TextField(singleLine = true)` with `keyboardOptions.imeAction` and `keyboardActions.onSend / onSearch / onDone` | a multi-line field with an `imeAction` other than Default shows that action on the key and fires it; the newline is then unreachable from the soft keyboard (Return IS the action) — hardware keyboards still deliver Enter as a key event | `ImeAction.Send` labels the key Send | `KeyboardActions`; `onPreviewKeyEvent` for a hardware Enter |
| Linux / GTK4 | `GtkEntry` and `GtkSearchEntry` emit `activate` on Return | `GtkTextView` inserts a newline; a `GtkEventControllerKey` on the view sees Return and its modifiers first | none | `activate`; the key controller |
| Windows / WinUI 3 | `TextBox` with `AcceptsReturn = false`: Enter is a `KeyDown` the app reads (`VirtualKey.Enter`); `AutoSuggestBox` fires `QuerySubmitted` | `TextBox` with `AcceptsReturn = true`: Enter inserts a newline unless the app handles `KeyDown` first | none | `KeyDown`; `QuerySubmitted` |

Two conventions from the shipped chat clients: on a desktop, Return SENDS
and Shift+Return inserts the newline (Slack, Discord, Messages on the
mac, Telegram Desktop); on a phone, the keyboard's action key sends and
Return inserts the newline where the app allows one (Messages, WhatsApp,
Signal all show a Send BUTTON beside the field, and their fields' return
key is a newline). So the phones and the desktops disagree on what Return
does in a compose field, and the app usually gives the phone a button.

## §1 — What kaya has, and what a compose field needs

- Three text kinds: `entry` (single line), `search` (single line, the
  search pass's kind 19) and `textarea` (multi-line, with `rich` since
  docs/rich-text-plan.md). One occurrence for all three: `text_changed`
  (kind 2), the entry's new text on every user edit. Rich textareas add
  `text_edited` (29) and `text_formatted` (30).
- The search field already relabels the phone keyboard's key: Search on
  iOS (`.submitLabel(.search)`) and Android (`ImeAction.Search`), and
  pressing it dismisses the keyboard and nothing else (S4's refusal; the
  SwiftUI arm's `.onSubmit { focused = false }`, KayaCompose's
  `imeAction = ImeAction.Search` with no action wired).
- The harness types with `type <text>` (the platform's own key events
  into the focused field) and asserts text with `expect`; no verb presses
  Return as a gesture, and `type` refuses a newline in its argument
  (`check_typing`).
- The Return key today: an entry on SwiftUI does whatever `TextField`
  does with no `.onSubmit` (nothing visible); GTK's `activate` is
  unconnected; WinUI's `KeyDown` arm reads Escape only; Compose's
  `KeyboardOptions.Default` shows Done or Return and does nothing.
- Occurrence kinds run to 32 (`dismiss_requested`), so the search pass's
  "occurrence 27" is stale: 27 became `notification_result` on
  2026-09-08. `submitted` is kind 33.

What a chat compose field needs, read off the clients above: a field that
grows with the draft, sends on the platform's send gesture, keeps the
draft on the way (a send that clears is the app's write), and tells the
app WHAT was sent without the app diffing `text_changed`. A search that
asks a server on Return and a form whose last field submits are the same
event on a single-line field.

## §2 — The rulings (RECOMMENDED; built on the recommendation, amendable)

### S1 — One occurrence, `submitted`, kind 33, carrying the text (RECOMMEND: yes)

`submitted` has `text_changed`'s layout: id, path_len, reserved, then the
field's text as one Str. It is the FIELD's text at the moment of the
gesture, so the handler needs no model read. It publishes on the
platform's submit gesture ONLY, never from an edit: a field that emitted
it on every keystroke would pass a scene that typed and pressed Return
(the slider's "per-movement is not the commit" shape, S6 holds it). The
user-only stance is `text_changed`'s: a programmatic `set_text` never
submits.

### S2 — Which kinds publish it, and on what (RECOMMEND: entry and search on Return always; textarea when it says `submits`)

- `entry` and `search`: Return publishes `submitted`, on every backend,
  with no prop to set. A search that filters on every keystroke gets an
  occurrence it may ignore (the task manager's search ignores it); one
  that asks a server acts on it. Nothing the search pass built moves: the
  phone keyboard still says Search, and the key still dismisses the
  keyboard.
- `textarea`: Return inserts a newline, as it does today, UNLESS the
  textarea carries the new Bool prop `submits`. With `submits` on: on a
  desktop Return publishes `submitted` and Shift+Return inserts the
  newline (the chat convention above); on a phone the keyboard's action
  key is relabelled Send and publishes, and Return on the soft keyboard
  is that same key (the platforms leave no newline gesture once the key
  is Send, §0); a hardware keyboard on a phone follows the desktop rule.
  A plain textarea (`submits` off) publishes nothing on any key.
- Why a prop and not a fourth kind: a compose field IS a textarea (it
  wraps, it scrolls, it can be rich) that sends. A `compose` kind would
  duplicate every textarea arm for one gesture.
- Why not Return-sends on every textarea: notes, the editor and every
  form's comment box would lose their newline. The default stays the
  platform's.

### S3 — The submit does not clear or blur the field (BUILT, with the phones' own Return)

A send that empties the field is the APP's `set_text ""` in its handler,
which is one line and lets a failed send keep the draft. Focus stays
where the platform leaves it, and that is not the same place on every
platform: on iOS the platform's Return on a SINGLE-LINE field ends
editing (SwiftUI's TextField resigns on Return, measured on all three
iOS suites 2026-09-24, §7.1), so the entry publishes and the keyboard
goes with the focus, exactly as the search field's Search key already
did; the iOS lane drops the entry's post-Return focus step
(tools/lib/lanes/ios.py MODS). A submitting TEXTAREA keeps its focus on
every platform, since its Send goes through `shouldChangeTextIn` and
inserts nothing — the compose case, which the shared scene asserts on
all five lanes. The occurrence publishes even when the text is empty;
the app decides what an empty send means (Slack ignores it; a form does
not).

### S4 — The phone keyboard's key label (RECOMMEND: derived, not a prop)

`search` shows Search (shipped), a textarea with `submits` shows Send,
an `entry` shows the platform's default (Return on iOS, Done on
Android). A `submit_label` prop (go / done / next / send) is ledgered
until a form asks for it; a chat app needs only Send.

### S5 — The harness drives the GESTURE, not the event (BUILT: the existing `press return`, no new verb)

The scene focuses the target with `click` and presses Return with the
verb every lane already has: `press return` types a newline at the
focus through each harness's own key path (the SwiftUI interpreter's
`kayaTypeAtFocus("\n")`, the Rust harness's `type_text("\n")`, the
Compose runner's key event), which is the platform's own submit on a
desktop field and the keyboard's Return on the phones — so a textarea
with `submits` sends and one without inserts a newline and the scene
sees no occurrence. The plan's first draft asked for a `submit <target>`
verb; it was not built, because a verb whose whole body is `press
return` is a second spelling of one gesture, and the scene reads the
difference (a label moved, a newline in the text) exactly as it would
have. `expect_submitted` is not needed: the scene reads what the app did
with the text, which is how every other occurrence is asserted.

### S6 — The gate: per-keystroke is not the submit (RECOMMEND: check-slider-commit's shape)

tools/check-submit.py reads each backend's arm and holds: the
`submitted` emit sits in the Return / action / `activate` /
`QuerySubmitted` path and never in the text-change path (a copy that
emits from `text_changed`'s handler is watched red on every run); the
textarea's emit is dominated by a read of the `submits` prop; the
desktop textarea arm names the Shift modifier as the newline's; the
phone arms relabel the key from the same prop. The table grows by itself:
a backend still stubbing `submits` through `depth_stub("submit")` has no
row, and the row is demanded the moment the stub goes.

### S7 — Bindings: `on_submit` where `on_change` is, in both zones (RECOMMEND: yes)

Rust `on_submit(w, |text| ...)` and `on_submit_node(n, |path, text| ...)`
beside `on_change`; Go `OnSubmitted` / `OnSubmittedNode`; C# `OnSubmitted`;
Java `onSubmitted`; Swift `onSubmitted` and the `onSubmit:` argument on
the constructors that take `onChange:`; Python and JS `on_submit=` on
`entry`, `search` and `textarea`; OCaml `~on_submit`; Haskell an
`OnSubmit` handler beside `OnChange`. The `submits` prop rides every
binding's textarea constructor the way `rich` does (chained on the
five, a keyword on Python's, a labelled argument on OCaml's, an option
on JS's, an attribute on Haskell's). check-sugar-surface takes a row for
the prop and one for the handler, read out of each binding's own file,
watched red by a fake name.

## §3 — The lowering, per backend

| backend | entry / search | textarea with `submits` | the key's label |
|---|---|---|---|
| SwiftUI (mac, iOS) | `.onSubmit { emit }` on the TextField (the iOS search arm's `.onSubmit` also drops the focus, S4's dismissal kept) | the textarea's own text views, not a `TextField(axis: .vertical)` (which would have replaced the rich arm): the mac `NSTextViewDelegate`'s `doCommandBy` answers `insertNewline:` with the emit and `insertLineBreak:` (AppKit's own Shift+Return) by inserting the newline itself; the iOS `UITextViewDelegate`'s `shouldChangeTextIn` answers a `"\n"` replacement with the emit and `false`, which is the Send key and a hardware Return alike | `returnKeyType = .send` on the UITextView, keyed on the prop at creation and on update (with `reloadInputViews`) |
| Compose | `BasicTextField`'s `onKeyboardAction`: a single-line field emits and then performs the default (the search key still dismisses) | `KeyboardOptions(imeAction = ImeAction.Send)`; `onKeyboardAction` emits and performs nothing; `onPreviewKeyEvent` for Enter or NumPadEnter without Shift on a hardware keyboard emits and consumes (Shift+Enter falls through to the newline) | `ImeAction.Send` |
| GTK4 | `connect_activate` on the entry and the search entry | a CAPTURE-phase `GtkEventControllerKey` on the text view, reading the core's `submits` set: Return or KP_Enter without Shift emits and stops the event; Shift+Return inserts the newline at the cursor itself and stops | none |
| WinUI 3 | one `submit_on_enter` door on the field's `KeyDown` with `VirtualKey::Enter`, wired ungated on the entry and the search arm (the search kind is a TextBox, so there is no `QuerySubmitted`) | the same door gated on the textarea's own id in the `SUBMITS` set: Enter without Shift (`GetKeyState(VK_SHIFT)`) emits and sets Handled, which inserts nothing; Shift+Enter falls through to the document | none (WinUI has no key label) |

Every arm emits through one new C door, `kaya_emit_submitted(tag, text)`,
the twin of `kaya_emit_text`, so the ring record and the occurrence
decode are one path for the two interpreters and the two Rust backends.

## §4 — The wire

- Occurrence kind 33, `submitted`: `id: U64, path_len: U32, reserved:
  U32`, payload Str. Live and stamped forms decode as `Submitted { id,
  text }` and `InstanceSubmitted { node, path, text }`.
- Prop `submits` (Bool) on `textarea`; `check_prop` refuses it on every
  other kind; `prop_value_type` says Bool. The core's row default is off.
- The spec hash moves; the nine wire files, kaya.h and both interpreters'
  hash copies follow (docs/HACKING.md's regeneration workflow).

## §5 — The scene and the sweep

tools/scenes/submit.steps, a Rust guest first: an entry, a search field,
a plain textarea and a submitting textarea, each with a label the app
sets to "sent: <text>" from its `on_submit`. The steps: type into the
entry, `submit` it, expect the label; the same on the search field; type
into the plain textarea, `submit`, expect the label UNCHANGED and the
textarea's text to carry the newline (`expect textarea@plain "a\nb"`);
type into the submitting textarea, `submit`, expect the label. A stamped
row with an entry inside a For, `submit` through the keyed target, the
row's own label. The scene runs on all five lanes; the phones press the
action key through their drivers.

## §6 — Build order

Depth: spec + protocol + wire + capi + ring + scene.rs (kind 33, the
prop), the Rust binding's `on_submit` in both zones and `submits` on the
textarea, the SwiftUI arm for the three kinds, the scene driven by the
existing `press return` (S5) and the Rust guest, green on the mac and
iOS by hand. Then breadth: the GTK, WinUI and Compose arms, the eight
bindings' sugar, check-submit and the check-sugar-surface rows, the
scene on all five lanes, the matrix. Then the chat app's plan (§8).
BUILT 2026-09-24 in that order, the four arms and the eight bindings
together in the breadth step.

## §7 — Measured while the arms were built (2026-09-24)

1. iOS: the textarea kept its own UITextView, so the Send key and a
   hardware Return are ONE path, `shouldChangeTextIn` with a "\n"
   replacement, answered false with the emit; the keyboard stays. A
   single-line TextField's Return fires `.onSubmit` AND resigns the
   focus on all three iOS suites (the filtered matrix's first run,
   `entry@name does not hold focus` after `sent: milk` passed), which
   is S3's phone carve-out and the iOS lane's drop.
2. macOS: no `TextField(axis: .vertical)`; the NSTextView delegate's
   `doCommandBy` sees `insertNewline:` for Return and `insertLineBreak:`
   for Shift+Return (AppKit's own binding), and the arm inserts the
   newline itself on the second, since insertLineBreak: inserts a line
   separator by default.
3. Compose: the soft keyboard's Send is `onKeyboardAction`; a hardware
   Enter is a key event that reaches `onPreviewKeyEvent` BEFORE the
   field inserts, and it NEVER reaches onKeyboardAction — the first
   filtered run had the single-line arm on the keyboard action alone
   and `press return` in an entry published nothing on all three
   Android suites — so the one preview arm serves every text kind.
4. WinUI: a TextBox with `AcceptsReturn = true` handles Enter itself
   before the bubbling `KeyDown`, which then never fires (all six
   Windows legs read "hello\n" with no submit on the first filtered
   run); the door is the tunnelling `PreviewKeyDown`, whose Handled
   stops the insert. The entry and the search field, which never handle
   Enter, publish from either.
5. GTK: the capture-phase key controller on the GtkTextView stops the
   buffer's insert when it claims the event; Shift+Return is inserted by
   the arm itself, since the claimed event no longer reaches the view.
6. The drivers: `press return` is the xcui driver's typed "\n" on iOS
   (the keyboard's Return, which on a submitting textarea is the Send
   key's path through shouldChangeTextIn) and a KEYCODE_ENTER key event
   on Android (the preview arm above), so no driver presses a Send
   BUTTON; the soft keyboard's own action key is the half no lane drives,
   which is why check-submit holds the relabel and the action arms
   statically.

## §8 — The chat app, the ultimate goal

The maintainer named the chat app the goal this slice serves. What it
will force, read against the roadmap page's demo-app table and the
needs survey's A2 row: the `submitted` occurrence (this pass); scroll-to
(open at the bottom, jump to the first unread); filtering rows for
message search (optional for v1); and, all shipped, notifications,
badges, rich text with links, the search field, RTL mirroring, sheets,
image display, clipboard with images, file dialogs and drag and drop.
Its own design pass follows this slice and scroll-to, as
docs/chat-plan.md, on the task manager's model: what is ratified, the
screens, the scene, the sequencing. A detail the compose field decides
here: a chat app on a phone shows a Send BUTTON beside the field as well
as the key, since a user with a hardware keyboard or a dictation flow may
never see the action key; the button is an ordinary `button` whose
handler reads the field's text through the model the `text_changed`
occurrences keep — kaya has that today.
