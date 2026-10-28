# Formatting on the phones, and a Bold that toggles

Status: BUILT 2026-10-27 (§5's selection menu is a ruling for the maintainer) (the maintainer, 2026-10-27: "yes you understood
me correctly on the iphone proposal"). Two asks from the editor's review
(docs/editor-plan.md §2b): on a phone the Format menu sits below the fold of
the overflow while the keyboard is up, and every Format command only turns a
style on.

## §1 — What phone editors do

| app | above the keyboard | in the selection menu |
|---|---|---|
| Apple Notes (iOS) | a bar: the Aa formatting panel, checklist, table, attach | Format ▸ Bold, Italic, Underline, Strikethrough |
| Pages (iOS) | the shortcut bar: paragraph style, B I U, alignment | Style ▸ (copy, paste style) |
| Google Docs (Android, iOS) | a formatting bar: B I U, text colour, lists, the A panel | Cut, Copy, Paste, Comment |
| Samsung Notes | a toolbar above the keyboard | Cut, Copy, Paste |

Every one of them puts formatting on a bar above the keyboard; only Apple's
own apps add it to the selection menu as well. UIKit's surface is
`UIResponder.inputAccessoryView` (a view the keyboard carries above itself,
there whenever the text view is first responder); Android has no system
surface for it, and an app draws a row inside the window's `ime` insets,
which is what Docs does. The selection menus are `UITextViewDelegate`'s
`textView(_:editMenuForTextIn:suggestedActions:)` on iOS and Compose
foundation's `Modifier.appendTextContextMenuComponents` (1.9 on; kaya pins
1.11.4) on Android.

## §2 — The declaration: `keyboard_bar` on a menu (built)

A top-level `menu` of a window's catalog may declare `keyboard_bar: true`.
It is a placement hint in the shape of `primary` and `role`: one uniform bit,
lowered per platform, inert where it does not apply. The menu stays where
the catalog puts it on every host (the menu bar, the overflow), and

- **where there is a software keyboard** (iOS, Android), the platform's bar
  above it carries the menu's items whenever a textarea of that window is
  being edited: an action is a button, a toggle a button that shows its
  `checked` state the way the platform shows a selected tool, a nested menu
  one button that opens its items, a separator a gap. Each item is the SAME
  item: one handler, one enablement, one occurrence, as with promotion;
- **where there is none** (macOS, Windows, Linux), nothing moves: the menu
  bar is already beside the text and the items' chords reach it.

Const-only, a top-level `menu` only (the core refuses it on a leaf, a nested
menu, a radio group or a context catalog). More than one marked menu: their
items in catalog order, a gap between menus. An item's `symbol` is what the
bar draws, its label where it has none; four symbols join the vocabulary for
the editor's tools: `bold`, `italic`, `underline`, `strikethrough`.

The app does not branch on platform: it marks the menu it already has.

## §3 — The selection's formatting: `text_selected` (built)

The core already knows a `rich` textarea's selection (every arm reports it,
docs/rich-text-plan.md R5) and its runs and pending typing attributes, so it
is the one place the answer can be computed uniformly. A new occurrence,
`text_selected { id, start, stop, attrs }`, carries the selection in UTF-8
bytes and the attributes that hold over ALL of it:

- over a range, an inline attribute is in `attrs` when every byte of the
  range that is not a newline carries it (Word's and Pages' rule: a mixed
  selection is not bold, and Bold on it bolds all of it);
- at a caret, the attributes the next typed character would take: the
  byte before it (a link excepted) with the pending attributes armed at
  that caret applied, exactly `typed_runs`' rule;
- `block` is in `attrs` when every paragraph the selection touches has the
  same kind (body is no `block`, as everywhere).

It is sent whenever the pair (selection, attrs) changes, for any reason: a
user's selection, an edit, a format act, the app's own `select_range` or
format. The echo doctrine is not broken: the app wrote neither the
selection the platform settled on nor the pending state, and
`text_formatted` already answers the app's own acts. `rich` textareas only
(a plain one has no runs), live zone only (as `rich` is).

Every binding surfaces it as the textarea's `on_selection` handler with a
`Selection` value (the range, `has(name)`, `block`). The editor's Format
items become toggles bound to signals the handler writes, so the platform
draws its own check mark, and a toggle's new state picks the act:

```go
boldOn := tx.Signal(false)
format.Toggle("Bold").BindChecked(boldOn).OnToggle(func(tx *kaya.Tx, on bool) {
	if on { tx.Bold(buffer) } else { tx.Unformat(buffer, "bold") }
})
buffer.OnSelection(func(tx *kaya.Tx, s kaya.Selection) { tx.Write(boldOn, s.Has("bold")) })
```

The paragraph styles are toggles too (Heading 1 checked on a heading-1
paragraph, Body where no block is), which is the check mark Pages and Word
show beside the current style; a radio group cannot say "mixed", a toggle
per style can (none checked).

## §4 — How a leg sees it

- `expect_keyboard_bar "<items>"`: the bar on screen above the keyboard,
  read off the platform's tree: `|`-joined labels in order, `label on` for a
  checked toggle, `label>` for a nested menu, `-` for a gap; `none` when no
  bar is up. `keyboard_bar_press "<label>"` presses one of its buttons the
  way a finger does (the platform's own action route).
- The phones run `tools/scenes/editorkeyboard.steps` (the autofillkeyboard
  precedent: the desktops have no software keyboard, docs/safe-area-plan.md
  A13), which focuses the buffer, reads the bar, presses Bold and Paragraph
  Style items and reads the checks and the runs.
- `tools/scenes/editor.steps` reads the check marks on every lane with
  `expect_menu "Format>Bold" checked on|off` (the real chrome) after the
  chord, after the chord again (the toggle), and on a selection that is half
  bold.

## §5 — Not built, and why

- **The selection menu.** Apple's own apps add Format to the edit menu;
  Google's do not. DESIGN.md's deliberate cut ("merging authored items into
  native text-control menus waits for an app that needs both its own command
  and the native editing commands on one control") is the trigger, and the
  editor is now that app. RECOMMENDATION (a ruling, the maintainer's): build
  it as a second slice on all five hosts at once (NSTextView's `menu(for:)`,
  UIKit's edit menu, GTK's `extra-menu`, WinUI's `SelectionFlyout`, Compose's
  `appendTextContextMenuComponents`), declared by the same `keyboard_bar`
  menu or by its own bit; the keyboard bar covers the phones' reachability
  problem without it.

## §6 — Guards

- The scene core refuses `keyboard_bar` anywhere but a top-level window
  menu, and `#[should_panic]` tests hold each refusal.
- `text_selected`'s computation is unit-tested in scene.rs (range, mixed,
  caret with pending, block over paragraphs) and read on every lane through
  the editor's check marks.
- check-sugar-surface demands `keyboard_bar` and `on_selection` in all nine
  bindings; check-verbs demands both verbs in both interpreters.
