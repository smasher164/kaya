# An emoji button beside a text field — the design pass

Status: BUILT 2026-09-26 on all five lanes and in all nine bindings (R1
and R2 ruled 2026-09-25 as recommended). tools/scenes/emoji.steps (Rust)
picks through each platform's picker; the chat app shows its emoji button
where `emoji_picker` is set. What the build measured is in §6. The chat app's C5
(docs/chat-plan.md). Researched 2026-09-25 with sources; the mac, Windows
and iOS points marked unmeasured are probed before any arm is built.

## §1 — The semantics

`show_emoji_picker(field)`, a command on an entry, a search field or a
textarea: it focuses the field and opens the platform's own emoji picker.
An emoji the user chooses replaces the selection at the caret as if typed,
and reaches the app only through the field's `text_changed`, like a typed
character. A capability bit, `emoji_picker`, says whether the command
opens anything on this platform.

## §2 — What each platform offers

| platform | route | notes |
|---|---|---|
| macOS | `NSApp.orderFrontCharacterPalette`, the Emoji & Symbols palette | an input method that inserts into the ACTIVE app's first responder; kaya's lane guests run `.accessory` and are not active, so the arm activates the app and makes the field first responder first (unmeasured, the main risk); the palette's window is visible to a test by its owner, `com.apple.CharacterPaletteIM` |
| Windows | `CoreInputView.GetForCurrentView().TryShow(CoreInputViewKind.Emoji)`, the Win+. panel | documented for desktop apps without a CoreWindow; needs the app in the foreground and the TextBox focused, which on the lane's VM means the foreground dance the notification host already fights |
| Linux | `gtk_widget_activate_action(field, "misc.insert-emoji")`, GtkEmojiChooser | on an entry the action lives on its inner GtkText (`gtk_editable_get_delegate`); inserts at the field's own cursor; hides every emoji no installed font draws, so the lane image needs a pinned colour emoji font or the chooser opens empty |
| Android | none from the system: no app can open the keyboard's emoji panel | see R1 |
| iOS | none from the system: no call presents an emoji picker | see R2 |

## §3 — R1 RULED 2026-09-25: androidx's picker on Android (a)

No app can open the keyboard's emoji panel, and Google Messages and
WhatsApp both answer with their own panel in the compose bar.

- **(a) RULED: androidx's `EmojiPickerView`**, Google's Jetpack
  picker (recents, skin tones, and it hides emoji the device cannot draw),
  shown by the command as a panel under the field. It ships inside the app
  rather than being a system surface, which is the idiom on this platform.
- **(b) the bit false**: the command focuses the field and opens nothing;
  the user reaches emoji through the keyboard.

## §4 — R2 RULED 2026-09-25: no picker on iOS, the bit false (a)

iOS has no picker call, and Messages and WhatsApp have no emoji button:
the keyboard's own emoji key is the idiom.

- **(a) RULED: the bit false**, and the command focuses the field.
  An app checks the bit and leaves the button out, as Messages does.
- **(b) switch the keyboard to emoji** by overriding the text view's
  `textInputMode` to the mode whose `primaryLanguage` is `"emoji"`. Every
  symbol is public, the `"emoji"` string is not documented, and it does
  nothing if the user removed the Emoji keyboard.

## §5 — How a leg sees it

A `pick_emoji <field> <emoji>` verb opens the picker through the command's
own path and chooses one: the in-app picker on Android, GtkEmojiChooser's
own grid on Linux, and on macOS and Windows the out-of-process palette
through accessibility (unmeasured on both). The field's text is the
observation.

## §6 — What the build measured (2026-09-26)

- macOS: the palette, opened a turn after the field takes focus with the
  app activated, inserts into the field; the leg reads it on screen by its
  own process (`com.apple.CharacterPaletteIM`) and closes with the guest.
  The leg waits for an idle host (the mac lane's HOST_UI_SCENES).
- Windows: `CoreInputView.TryShow(Emoji)` answered true with the guest in
  the foreground and opened nothing for a WinUI TextBox, though it opened
  the panel for a Win32 edit. The command sends the user's own shortcut,
  Win+period, which does. The panel's grid is not reachable through UI
  Automation from another process, and no window property tells open from
  shut (visible, cloaked, rect and keyboard focus all the same), so the
  pick types the emoji's Unicode name (the system ICU's) into the panel's
  own search and presses Return, after the second the panel takes to
  appear, and fails naming the field if the keys reached it instead.
- Linux: `misc.insert-emoji` opens GtkEmojiChooser; the pick emits its
  own `emoji-picked`. A GtkText's `grab_focus` selects the whole text, so
  the command uses `grab_focus_without_selecting` (the first leg's emoji
  replaced "Hi "). The lane image carries fonts-noto-color-emoji, without
  which the chooser hides every emoji.
- Android: androidx's EmojiPickerView in a Material sheet; the pick calls
  the picker's own listener.
- iOS: the command focuses the field; the lane drops the pick.

