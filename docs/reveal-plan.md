# The reveal toggle: the design pass and the depth slice (2026-10-08)

Status: DEPTH BUILT 2026-10-08 on the mac, every ruling RECOMMENDED and built as
recommended, awaiting the maintainer. Props 57 `revealed` and 58 `revealable`
on the secure field in both zones, the core's wall, the Rust binding, the
SwiftUI arm on macOS and iOS (compiled for both, run on macOS), the harness's
`expect_unmasked` and the secure field's arm of `toggle`, and
tools/scenes/reveal.steps green on the mac for Rust. GTK, WinUI and Compose are
depth stubs, the iOS legs unwired and the eight other bindings the breadth
(docs/deferred.md, the reveal toggle's BUILD entry).
RULED 2026-10-08 (the maintainer: "im fine with everything except ... the keyboard navigation"): V1-V9 as built, and the platform divergences accepted save one: the eye must be reachable with Tab on every platform ("it makes it more accessible"), built in the keyboard-reach slice.
KEYBOARD REACH RULED 2026-10-08 (V10): Tab reaches the eye and Space flips it on GTK, WinUI and Android; on macOS and iOS the eye follows Apple's keyboard convention like every other button there (the maintainer: "im okay with your recommendation on the apple keyboard").

The maintainer asked for it on 2026-10-08: "maybe we do show password now? i
want to finish password entry before moving onto the next feature". The secure
field's plan left it out on purpose (docs/secure-entry-plan.md P3: no reveal
affordance on any platform) and the autofill pass kept it out
(docs/autofill-plan.md A9). The search field's plan (docs/search-plan.md) is
the shape of this one.

## §0 — What the platforms offer

The macOS rows marked MEASURED were measured on this slice's legs (§7). GTK's
rows are read from GTK 4.20.3's own source (gtkpasswordentry.c, gtktext.c),
Compose's from foundation 1.11.4's bytecode in the gradle cache, WinUI's from
the Windows App SDK 2.2.1 generic.xaml under third_party/winappsdk; the rest
from the vendors' documentation. The breadth measures what is marked so.

| | how the text is shown | the platform's own toggle | copy and cut while shown | what assistive technology reads while shown |
|---|---|---|---|---|
| macOS | nothing: SecureField, NSSecureTextField and NSSecureTextFieldCell have no reveal (only `echosBullets`); the common answer is a plain field over the same text | none | a SwiftUI TextField's editor offers Cut, Copy, Look Up, Translate, Search with Google, Share, Writing Tools and Speech over the shown text, and keeps an undo stack (MEASURED); NSSecureTextView's menu is Cut and Copy disabled, Paste, Delete, Select All (MEASURED) | a plain field: AXTextField with no AXSecureTextField subrole, AXValue the text, AXNumberOfCharacters set (MEASURED) |
| iOS | nothing: SecureField has none; UIKit's answer is `isSecureTextEntry = false` on the same UITextField, which apps know for clearing the text on the next edit after it is turned back on; SwiftUI's is a TextField swapped in | none | a plain UITextField's edit menu offers Cut, Copy, Share, Look Up, Translate, Writing Tools | a plain text field: the accessibilityValue is the text (MEASURED) |
| GTK 4 | `gtk_text_set_visibility(TRUE)` on the GtkPasswordEntry's own GtkText: the same control, caret and selection kept | `show-peek-icon`: a GtkImage (`view-reveal-symbolic` / `view-conceal-symbolic`, tooltip "Show Text" / "Hide Text") whose click gesture toggles on RELEASE; it is an image with a gesture, not a button, so no keyboard reaches it; turning the icon off also hides the text | GtkText's copy and cut refuse with an error bell only while `visibility` is false; shown, both work; undo history is enabled while shown unless `enable-undo` is off (kaya's arm turns it off) | kaya's subtype answers AT-SPI with its GtkText's display text, which while shown is the text; the role stays password text (MEASURED, GTK 4.24) |
| WinUI 3 | `PasswordRevealMode`: `Peek` (the default) shows the reveal button while the box has text and focus, and shows the text only while it is HELD; `Visible` shows it; `Hidden` never | the template's `RevealButton`, a ToggleButton (glyph U+F78D, 30px wide, collapsed outside the ButtonVisible state); press-and-hold, never a toggle, and nothing tells the app | a PasswordBox has no copy or cut in any mode | UIA: an Edit with `IsPassword`, no Value pattern (measured at the secure field's breadth); in `Visible` the peer still says IsPassword with no Value pattern, so UIA reads none of the shown text (MEASURED) |
| Android, Compose | `TextObfuscationMode.Visible` on BasicSecureTextField: the same field, no codepoint transformation | none in foundation; Material's guidance is a trailing icon button (Icons.Filled.Visibility / VisibilityOff, both in material-icons-extended, already a dependency) the app draws | refused in every mode: BasicSecureTextField wraps its content in `DisableCutCopy` unconditionally (bytecode, 1.11.4) | the `password()` semantics stays; kaya overrides EditableText with U+2022 per character (docs/traps.md) only while masked; shown, the node info's text is the text, `isPassword` true, no copy or cut action (MEASURED) |

Four facts decide the design:

1. **Three platforms can show the text in place (GTK, WinUI, Compose) and the
   two Apple ones cannot**, so on Apple the shown field is a different view over
   the same text. Focus, caret and the content type have to survive that swap,
   and a stock plain field brings its whole text-services menu with it.
2. **Only GTK has a toggle the user can flip and the app can hear**
   (`notify::visibility`). WinUI's button is press-and-hold and silent; Compose
   and the Apple platforms have none. A uniform toggle is therefore drawn by kaya
   on four of five, from each platform's own glyph and idiom, as the search
   field's clear affordance already is on SwiftUI.
3. **Copy while shown disagrees by default**: GTK and a plain Apple field copy,
   WinUI and Compose refuse. Only refusal is reachable on all five, since a
   PasswordBox cannot copy at all.
4. **Every platform's assistive reader reads a shown password**, since what is
   shown is plain text to it. The masked count the harness reads (secure P6)
   has an exact opposite: a count of characters shown unmasked.

## §1 — What kaya has

- The secure field (kind 24, docs/secure-entry-plan.md): the entry's text
  contract, the platform's mask, copy and cut refused, no undo banked, the
  `masked N` read, `type_secret`, and the secure scan of every mac leg's
  transcripts (tools/lib/secure_scan.py).
- The content type on it (docs/autofill-plan.md), read off the platform's own
  property.
- The checkbox's `checked` prop and `toggled` record: a Bool the app writes
  as configuration and the user's flip reports, never echoed (spec record 3).
- The harness's `toggle <target> on|off`, an action verb with both waits.

## §2 — The rulings (RECOMMENDED 2026-10-08, built as recommended)

### V1 — Two props on the secure field, `revealed` and `revealable`, both zones (RULED 2026-10-08)

`revealed` (Bool, PROPS 57): the field shows its text. The app writes it as
configuration; a write never echoes. `revealable` (Bool, PROPS 58): the field
carries its own show/hide toggle, which flips `revealed` and tells the app.
Both default false, so a secure field with neither is P3's field exactly.

Two props because the state and the affordance are separate choices on every
platform: an app with its own "Show password" checkbox (the macOS and Windows
settings idiom) wants the state and no eye, an app with the eye (the Material
and GTK idiom) wants both, and an app that reveals on a long press of a key
icon wants the state alone. Legal on the secure field only, in both zones (a
stamped account row's PIN). The names are the state's adjective and its
capability, not a platform's word (GTK's "peek", WinUI's "reveal mode").

### V2 — The user's toggle reaches the app as `toggled`, the checkbox's record (RULED 2026-10-08)

The secure field's toggle IS a boolean the user flips, with the checkbox's
ownership and stance: the field owns the state, the user's flip reports with
the new value, the app's write never echoes. So no new record: `toggled`
(record 3) carries the field's new `revealed` state, and every binding's
existing toggle handler on the field's handle is the API (`on_toggle` in Rust,
`on_toggle_node` for a stamped copy). An app that keeps its own model writes
`revealed` back, which is idempotent.

### V3 — Revealed, the platform shows plain text; kaya adds no mask of its own (RULED 2026-10-08)

Each backend uses its platform's own way to show the text (§3): GTK's
visibility, WinUI's `Visible` mode, Compose's `Visible` obfuscation, and on
the Apple platforms a plain field over the same text. Hidden again, the
platform's masking returns, the phones' last-character flash included (P3 and
P7 unchanged).

### V4 — The assistive reader reads the text while shown; the harness reads a count (RULED 2026-10-08)

A shown password is plain text to the platform's assistive reader, which is
what a sighted user is shown, so no backend masks the accessibility value of a
shown field (Compose's EditableText override follows the reveal). The a11y
verdict stays `field`.

The harness never prints the text (secure P6 holds unchanged): `expect_unmasked
secure_field@x N` answers `unmasked N`, how many characters the platform
presents with none of them as its mask, through the opposite of `mask_count`'s
rule (`harness::unmasked_count`, `kayaUnmaskedCount`). A field the platform
still masks reads "the platform masks N of the revealed secure field's
characters"; `expect_masked` on a shown field reads secure P6's "presents N
... unmasked". Both read the platform's presentation, never kaya's model, so a
backend that ignores the prop fails the scene (watched, §7). The user's toggle
is driven by `toggle secure_field@x on|off`, the checkbox's verb, which first
requires the platform to publish the toggle inside the field's frame and then
flips it through the one door the toggle's own action takes; it is an action
verb, so its answer is the app's `toggled`. Every `type_secret` in the scene is
still scanned for in the leg's transcripts, with the text shown on screen.

### V5 — Copy and cut stay refused while shown; so do the text services and the undo stack (RULED 2026-10-08)

The masked field refuses copy and cut on every platform (secure P4); showing
the text is about the user's eyes, not the clipboard, and §0 fact 3 makes
refusal the one semantics all five can express. A clipboard manager or a
synced pasteboard would otherwise keep a password the user only meant to
check. On the mac the shown field's editor refuses what NSSecureTextView
refuses, item for item: Cut and Copy disabled, the context menu NSSecureTextView's
own (Paste, Delete, Select All, MEASURED identical), no Services, no Writing
Tools, no drag out and no undo stack. The iOS field allows Paste,
Select All and Delete alone (`canPerformAction`, the masked field's menu, MEASURED),
with no undo manager and Writing Tools off. GTK's arm blocks the GtkText's copy and cut
while shown; WinUI and Compose refuse natively. Paste keeps working (a password
manager pastes).

### V6 — Focus, caret and the content type survive the toggle (RULED 2026-10-08)

The toggle never moves the focus: a field that held it holds it after, and the
caret stays where it was. Three platforms keep both by construction (the same
control). On the Apple platforms the swap carries them: one door
(`kayaRevealSwap`) records the caret and marks the swap, the leaving view's
focus loss is the swap's and not the user's, and the arriving view takes the
focus and puts the caret back. The harness's `toggle` returns only once the
arriving field's editor holds the window's focus, or says it never came back.
The shown field carries the same content type as the masked one, so Password
AutoFill still offers on it.

### V7 — The eye: the platform's glyph, at the field's trailing edge, labelled by what it will do (RULED 2026-10-08)

GTK's own peek icon (`view-reveal-symbolic`, `view-conceal-symbolic`); WinUI's
reveal glyph U+F78D in the template's own ToggleButton style; Compose's
Material trailing IconButton with Icons.Filled.Visibility and VisibilityOff;
SwiftUI's SF Symbols `eye` and `eye.slash`. Each shows the open eye while the
text is hidden and the struck eye while it is shown (GTK's and Material's
convention). Its spoken name is "Show password" or "Hide password", English on
SwiftUI and Compose as the search field's "Clear text" is; GTK's tooltip is its
own translated "Show Text" / "Hide Text". GTK's peek icon is not
keyboard-reachable (an image with a gesture), so V10 replaces it with a button.

### V8 — The phones' last-character flash is unchanged (RULED 2026-10-08)

Hidden, iOS and Compose keep their platform's flash of the last typed
character (P3); shown, there is nothing to flash. Nothing new.

### V9 — A new scene, not more lines in secure.steps (RULED 2026-10-08)

secure.steps runs on five lanes in nine languages, so extending it would
redden every one of those legs until the breadth; a new scene rides the depth
stubs and iOS's unwired declaration like every depth slice before it (§5).

### V10 — The eye takes the keyboard as the platform's buttons do (RULED 2026-10-08)

The maintainer's one exception to the accepted divergences, and his ruling on
the Apple half ("im okay with your recommendation on the apple keyboard"):
the eye is reached from the keyboard exactly as the platform reaches its
other buttons. Where that is Tab (GTK, WinUI, Android), with the field
focused Tab moves the keyboard focus to the eye, Space flips the reveal, the
app hears `toggled`, and the focus stays on the eye. On macOS and iOS a
button joins the keyboard's loop only under the system's keyboard setting
(Keyboard navigation, Full Keyboard Access), and the eye follows it. A
pointer click on the eye still leaves the focus in the field (V6). Per
platform:

- macOS: a SwiftUI Button is not a key view: with the system's Keyboard
  navigation setting off (the default), Tab from the field skipped it, and
  `.focusable(interactions: .activate)` changed nothing (MEASURED). The eye
  is `KayaRevealEyeButton`, an NSButton whose key-view membership AppKit
  decides as for every NSButton (`canBecomeKeyView` not overridden), and
  which refuses the first responder on a mouse-down. With the setting off a
  plain NSButton answers `canBecomeKeyView` false and the field's
  `nextValidKeyView` skips it, and on the lane Tab from the field left the
  eye unfocused (MEASURED, §7). The on-state is not measured, since the
  setting is the host's and no per-process switch reaches AppKit's rule
  (§7); it rests on the eye being a stock NSButton, which the setting puts
  in the loop as it does every mac button. SwiftUI makes a new eye at every
  masked/shown swap (MEASURED), so an eye that held the focus hands it to its
  successor.
- GTK: the peek icon is never shown; the eye is a GtkButton with the peek
  icon's glyphs and GTK's own "Show Text" / "Hide Text" as its label and
  tooltip, `focus-on-click` off. GtkPasswordEntry allocates only the children
  it knows (gtkpasswordentry.c), so kaya's subtype allocates the eye in the
  trailing slot after the theme's 6px spacing.
- WinUI: the template's RevealButton is made a tab stop. A key at the focused
  button reached the PasswordBox around it and typed into the password
  (MEASURED), so the button handles its own characters and takes Space through
  its own Toggle.
- Android: the eye is focusable (Compose's `clickable` focuses only outside
  touch mode). The harness's Tab and Space go through the system's input
  (`input keyevent`), since a key the app dispatches itself never leaves
  touch mode (MEASURED).
- iOS: a hardware Tab moves between text fields only; the SwiftUI eye, with
  or without `.focusable()`, is skipped (MEASURED on the simulator). The eye
  is a plain SwiftUI Button with its spoken name and no `.focusable`,
  `.focusEffectDisabled` or `.accessibilityHidden`, so Full Keyboard Access
  reaches it as it reaches every iOS button (iOS's documented behaviour, not
  measured: turning it on would change the simulator pool's settings).

THE CARVE-OUT, uniform on both Apple lanes: neither lane can turn the
system's keyboard setting on, so both cut reveal.steps at `press tab`
(tools/lib/lanes/mac.py's CUTS, tools/lib/lanes/ios.py's MODS, both held by
check-steps' cut census, which refuses a stale cut). What they still assert
above the cut: every `toggle secure_field@...` finds the eye as exactly one
button inside the field's frame named "Show password" or "Hide password" in
the platform's own accessibility tree. That the eye is neither forced into
nor out of the keyboard's loop is held statically by
tools/lib/reveal_routes.py (five watched negatives: `canBecomeKeyView`
forced, `refusesFirstResponder`, `.focusable()`, `.focusable(false)`,
`.accessibilityHidden(true)`).

## §3 — The lowering, per backend

| backend | revealed | revealable | the user's flip | unmasked read | copy and cut while shown |
|---|---|---|---|---|---|
| SwiftUI, macOS (BUILT) | SecureField swapped for `KayaRevealedField`, an NSTextField whose cell's field editor is `KayaRevealEditor` | an overlay NSButton (`KayaRevealEyeButton`, V10) at the trailing edge, SF `eye` / `eye.slash` | the button calls `kayaRevealToggle`, which swaps and emits `toggled` | AXValue of the field's element through `kayaUnmaskedCount` | refused by KayaRevealEditor (validation, `cut:`/`copy:`, menu, pasteboard types, Services, Writing Tools, undo) |
| SwiftUI, iOS (BUILT) | SecureField swapped for `KayaRevealUITextField` in a UIViewRepresentable | as macOS | as macOS | the element's accessibilityValue, zero when `hasText` is false | `canPerformAction` allows paste, selectAll and delete alone, the masked field's menu (MEASURED); no `undoManager`; Writing Tools off |
| GTK 4 (BUILT) | `gtk_text_set_visibility` on the delegate GtkText, under the quiet guard | kaya's eye button (V10), the peek icon never shown | `notify::visibility` outside the quiet guard emits `toggled`; the harness emits the eye's own `clicked` | the AT-SPI text through `harness::unmasked_count` | `copy-clipboard` and `cut-clipboard` stopped while shown, the PRIMARY selection's value refused for a shown field, a shown selection collapsed before a press can drag it (docs/traps.md) |
| WinUI 3 (BUILT) | `PasswordRevealMode::Visible` / `Hidden`, never Peek | the template's `RevealButton`, given a local Visible while `revealable`, its IsChecked mirroring the mode, a tab stop (V10) | the button's Checked/Unchecked, taken as a flip only when it disagrees with the box's mode (docs/traps.md, the echo); the harness takes the button peer's Toggle | the box's own `PasswordRevealMode` must be Visible, then its Password length (no Value pattern); `expect_masked` refuses a Visible box | refused natively |
| Compose (BUILT) | `TextObfuscationMode.Visible`, else RevealLastTyped; kaya's EditableText override only while masked | Material trailing IconButton (Visibility / VisibilityOff) in the decorator, focusable from the keyboard (V10) | the button's onClick takes `kayaRevealToggle`, which emits `toggled`; the harness's `toggle` invokes the eye's own click action | the node info's text through the unmasked rule | refused natively (`DisableCutCopy`) |

The Rust Stage methods are `unmasked_len(target) -> Result<usize, MaskRead>`
and `toggle_reveal(target, on)`, both without defaults; `MaskRead::Masked`
is the new fixed sentence.

## §4 — The wire

- PROPS 57 `revealed` and 58 `revealable`, both `PropKind::Bool`, legal on
  `SecureField` alone (scene.rs `check_prop`, `prop_value_type`; watched in
  `reveal_props_belong_to_the_secure_field`). The spec hash moved
  0x000c0323f11ef52f -> 0xad557b5075ff50eb; the nine wire files, kaya.h
  (KAYA_PROP_REVEALED, KAYA_PROP_REVEALABLE) and the two hand-copied
  interpreter hashes moved with it.
- No new record: `toggled` (record 3) carries the field's new state; its spec
  doc says so.
- Harness (not on the wire): `expect_unmasked` (an observation, `unmasked N`)
  and the secure field's arm of `toggle` (an action verb, both waits).

## §5 — The scene and the sweep

tools/scenes/reveal.steps: the content type read masked; typing six
characters masked (`masked 6`); the field's own toggle (`toggle ... on`), the
app hearing it (`heard: shown`), the text shown (`unmasked 6`), the focus kept,
the a11y verdict and the content type unchanged; six more characters landing
after the first six (`unmasked 12`, the app's label matching the guest's
password, which proves the order); Return submitting; the toggle off
(`masked 12`); the app's own Show and Hide (`unmasked 12`, `masked 12`) with
`heard:` unmoved, since an app write never echoes; Clear while shown
(`unmasked 0`); and a stamped copy that starts shown from its row's field and
whose toggle names its row; and last, V10's keyboard block: `press tab`
from the field, `expect_focused secure_field@password eye`, `press space`
twice with the state, the eye's focus and `heard: shown` read between. Both
Apple lanes cut at `press tab` (V10).

Gates that grew: check-verbs (tools/lib/reveal_routes.py: the one door and its
callers, the unmasked read reaching the platform and not the model, the mac
editor's and the iOS field's refusals, the content type on the shown view, the
sentence in both harnesses, a backend whose stub goes owing a row; thirteen
watched negatives), check-sugar-surface (the live zone in all nine, a
fake-name census and two Rust cuts) and tpl-surfaces (`revealed`,
`revealable` in PROP_MEMBERS), scene-features (`expect_unmasked` keys the
`reveal` feature), check-stubs (the ledger's DEPTH STUB lines),
content_type_routes (the secure field's hint negative follows the new view).
check-sugar-surface is red by design until the eight bindings take the props:
23 findings, all `revealed`/`revealable`.

## §6 — Build order

1. DONE 2026-10-08, the depth: spec, core, harness, the Rust binding in both
   zones, the SwiftUI arm on both Apple platforms (iOS compiled, not run), the
   Rust guest and the scene green on the mac.
2. Breadth (docs/deferred.md, the reveal toggle's BUILD entry): GTK, WinUI and
   Compose per §3, each replacing `depth_stub("reveal")` and taking its row in
   reveal_routes.py's BACKENDS; the iOS legs; the eight bindings in both zones,
   a `reveal` guest each; the secure scan already runs on every lane.
3. The matrix once, then the review page with every lane's capture, masked and
   shown.

## §7 — Measured, and to be measured

- MEASURED 2026-10-08 (macOS 26.5, the reveal leg): one `@FocusState` across
  the SecureField/TextField swap coalesces the leaving view's drop with the
  arriving view's take, so on about half the runs nothing held the focus after
  the swap (the window was its own first responder) and the next `type_secret`
  "reached no window". One focus state per view and a retried take fixed it:
  five runs of five green (docs/traps.md).
- MEASURED 2026-10-08: the stock SwiftUI TextField's editor
  (`_SystemTextFieldFieldEditor`) offers Cut and Copy enabled over a
  selection, Look Up and Translate naming the selected text, Search with
  Google, Share, Writing Tools and Speech, with `allowsUndo` true; the secure
  view's NSSecureTextView offers Cut and Copy disabled, Paste, Delete and
  Select All. KayaRevealEditor's menu and validation then read identical to
  NSSecureTextView's, `writeSelection` false and no Services requestor
  (docs/traps.md).
- MEASURED 2026-10-08: revealed, the element is AXTextField with no subrole and
  AXValue the text; masked, AXSecureTextField with AXValue the mask. `field/Password`
  reads the same in both.
- MEASURED 2026-10-08: NSSecureTextView's `allowsUndo` is true while a masked
  field is focused, so the masked mac field keeps a native undo stack the
  other four backends do not (docs/deferred.md, the reveal entry's note).
- MEASURED 2026-10-08: Secure Event Input reads off (`IsSecureEventInputEnabled`)
  for both views in the lane's guest, whose window is never key; whether a key
  window's revealed field should keep it on is to be measured with a key window.
- WATCHED 2026-10-08: the mac read doctored to print the platform's value
  (1 substitution) turned the leg red and the secure scan refused all three
  secrets in the leg log and the verb trace; the shown view cut (`if false`, 1
  substitution) read "the platform masks 6 of the revealed secure field's
  characters". Both restored from saved copies, sha256 checked.
- MEASURED 2026-10-08 (GTK 4.24, the linux lane, x11 and wayland): shown, the
  node's role stays password text (`field/Password`) and its Text interface
  answers the text (`unmasked 6`, `unmasked 12`); with the shown arm's
  `set_visibility` cut (1 substitution) the leg read "the platform masks 12
  of the revealed secure field's characters" on both protocols. Shown, GTK
  hands the password to PRIMARY, Ctrl+C and Ctrl+X; with kaya's guards all
  three read back empty (docs/traps.md).
- MEASURED 2026-10-08 (WinUI, the lane VM): a `Visible` PasswordBox's peer
  says IsPassword, control type Edit, no Value pattern; the box moves its own
  RevealButton's IsChecked when its mode changes (docs/traps.md, the echo).
- MEASURED 2026-10-08 (Compose foundation 1.11.4, API 35): shown, the node
  info keeps `isPassword`, carries the text (an empty field's is empty) and no
  copy or cut action; the override kept while shown (1 substitution) read "the
  platform masks 6 of the revealed secure field's characters" (docs/traps.md).
- MEASURED 2026-10-08 (iOS 26.5 simulator): the eye was reached twice by the
  toggle walk until it deduped by frame; the masked field's menu is Paste and
  Select All with an undo stack, and the shown field now answers the same with
  none; XCTest logs a plain element's typed text, so a shown field's
  `type_secret` keys go in-process (watched: the driver's plain route made the
  secure scan refuse two secrets); one keyboard at the first typing after the
  swap (docs/traps.md).
- MEASURED 2026-10-08 (V10): the mac with Keyboard navigation off sent Tab
  from the SecureField to the next text field past a SwiftUI Button, with or
  without `.focusable(interactions: .activate)`; a volatile
  `AppleKeyboardUIMode=2` in the argument domain left
  `isFullKeyboardAccessEnabled` false. GtkPasswordEntry never allocated a
  child it did not create. WinUI's tab-stop RevealButton passed a typed
  character to the PasswordBox. Compose's eye stayed out of the Tab order
  under an app-dispatched key (touch mode). The iPhone simulator's hardware
  Tab moved between text fields only. WATCHED: the mac eye's
  `canBecomeKeyView` cut to false (1 substitution, tools/mac/scene-negative.py)
  turned reveal-rust red with "secure_field@password eye does not hold focus",
  restored with its sha256 compared (docs/traps.md).
- MEASURED 2026-10-08 (V10's ruling, macOS 26.5, the host's Keyboard
  navigation off: `AppleKeyboardUIMode` absent from the global domain): a
  stock borderless NSButton between two NSTextFields answers
  `canBecomeKeyView` false with `acceptsFirstResponder` true, and the first
  field's `nextValidKeyView` is the second field. An NSApplication subclass
  answering `isFullKeyboardAccessEnabled` true left `canBecomeKeyView` false,
  as did `-AppleKeyboardUIMode 2` in the argument domain, so AppKit's rule
  reads neither and a test-only switch could only force the eye, which is
  the state the ruling removed. With `canBecomeKeyView` no longer overridden,
  the full reveal.steps on the mac read "secure_field@password eye does not
  hold focus (the window's first responder is KayaRevealEditor)" after
  `press tab`; with the cut, reveal green in all nine languages on the mac
  and 3/3 on iOS (docs/traps.md).
