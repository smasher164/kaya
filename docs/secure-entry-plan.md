# The secure field: the design pass and the build (2026-10-07)

Status: BUILT 2026-10-07 on all five platforms and in all nine bindings
(76f87836 depth, c1c25d0c breadth; full matrix on c1c25d0c: every secure and
gallery leg green, one unrelated media leg red once; review page
https://claude.ai/artifact/NzHtTqPdSgUPsAZVVm23He). Every ruling in §2 is
RECOMMENDED, built as recommended, awaiting the maintainer's ruling; so are
the GTK 4.14 minimum and the WinUI reading (§7).

The roadmap card (docs/roadmap/features.toml, `secure_entry`) asks for it:
every login screen needs one, all four of MAUI, egui, iced and Slint ship
one, and it is first-party in ten of ten full toolkits. The card spelled it
"one boolean prop" on the entry; the search pass's S2 ruling
(docs/search-plan.md) had already named `secure` as an entry variant that
is a KIND "when it comes", and §2 P1 follows that ruling. The search field
(kind 19) and the number field (kind 20) are the precedents for the shape.

## §0 — What the platforms offer

Read from the vendors' documentation and the libraries' sources, except
the macOS accessibility row, which was measured on this slice's first run
(§7). The breadth measures the rest before an arm is written.

| | the control | copy and cut | reveal | what assistive technology reads | autofill and content hints | phone keyboard |
|---|---|---|---|---|---|---|
| macOS | SwiftUI `SecureField`, an `NSSecureTextField` underneath | refused by the control; paste works | none | AXTextField, subrole AXSecureTextField; AXValue one U+F79A per character (MEASURED), no AXNumberOfCharacters | `.textContentType(.password)` / `.newPassword` asks the system's password autofill | n/a; while the field has focus macOS turns on Secure Event Input, so other processes cannot read the keystrokes, and input methods other than Roman are off |
| iOS | SwiftUI `SecureField`, a `UITextField` with `isSecureTextEntry` | refused; paste works | none, but the last typed character shows for a moment (the platform's convention, not switchable on UITextField) | the secure-text trait; accessibilityValue masked | `.textContentType(.password / .newPassword / .oneTimeCode)` drives Password AutoFill and strong-password suggestions; saving needs associated domains | autocorrection, prediction and dictation are off for secure entry; capitalization follows `.textInputAutocapitalization`; the field's content is left out of screen recordings |
| GTK 4 | `GtkPasswordEntry` | refused (a GtkText with `visibility` false refuses copy and cut); paste works | `show-peek-icon`, default off; a caps-lock warning icon is built in | GTK publishes the password-text role; the text is the invisible characters (U+25CF by default) from 4.20, and the REAL text on 4.18 for a plain entry (measured, §7) | `input-purpose` PASSWORD or PIN, which tells input methods not to learn the text | n/a |
| WinUI 3 | `PasswordBox` | refused; paste works | `PasswordRevealMode`, default `Peek`: an eye button while the box has text and focus; `Hidden` removes it | UIA Edit control with `IsPassword` true; ValuePattern's value is withheld | `InputScope` Password; no system password manager reaches a desktop app's box | n/a |
| Android, Compose | at the pinned foundation 1.11.4, `BasicSecureTextField` (material3 1.3.1 has no `SecureTextField`); the older form is a text field with `PasswordVisualTransformation` | refused by BasicSecureTextField; a field with PasswordVisualTransformation also withholds copy and cut | `TextObfuscationMode`: `RevealLastTyped` (default, honours the system's "show passwords" setting), `Hidden`, `Visible` | the `password()` semantics property; TalkBack reads characters only when the user turned spoken passwords on | `ContentType.Password` semantics for the autofill framework (compose-ui 1.8+) | `KeyboardType.Password`: no suggestions, no learning; `KeyboardCapitalization.None` |

Three facts decide the design:

1. **Every platform has a first-party control, and every one masks, refuses
   copy and cut, and still pastes.** kaya's arm on each is the platform's
   own control; no backend draws a mask of its own.
2. **The reveal affordance is the one place the platforms disagree by
   default**: WinUI shows an eye button unless told not to, GTK hides its
   peek icon unless told to, the Apple platforms have none, and the phones
   flash the last typed character as a platform convention.
3. **The assistive value is masked on every platform, with a different
   glyph on each** (U+F79A measured on macOS, U+25CF on GTK and WinUI by
   default, U+2022 on Android), so a shared scene can compare a COUNT of
   masked characters and nothing more specific.

## §1 — What kaya has

- The entry's text contract: `text_changed` on every user edit and on the
  `clear` command, `submitted` on Return (docs/submit-plan.md), the
  `clear`, `focus` and `emoji_picker` commands, `placeholder`
  (docs/search-plan.md S3), the a11y props, `grow` and `fill`.
- The core's undo ledger banks every editable kind's typing as episodes
  (`Scene::note_text_changed`) and keeps a copy of each editable field's
  text (`field_text`) so a programmatic write can close an episode.
- The harness reads a text kind's text back (`expect entry@x "..."`) and
  echoes every step verbatim into the step log, the verb trace, the
  watchdog's sentence and, on a red leg, the flight recorder's bundle.

Two of those are wrong for a password: an undo step that brings back a
cleared password, and a transcript that carries one.

## §2 — The rulings (RECOMMENDED, built as recommended, awaiting the maintainer)

### P1 — A KIND, `secure_field` (wire 24), not a prop on the entry (RECOMMEND: kind)

The search pass ruled this already in principle (S2: "the entry variants
the parity survey found missing, `secure` ... and `number`: they are kinds
too, when they come"), and S2's reasons hold one feature over: the control
IS a different class on every platform (NSSecureTextField,
GtkPasswordEntry, PasswordBox, BasicSecureTextField); a kind is addressable
in the harness, so the refusals in P6 are PARSE-TIME refusals keyed on the
target kind rather than runtime checks of a flag on every entry verb; and a
kind joins every kind census in nine bindings and both zones, so a binding
that forgot it is red rather than silently plain. The roadmap card's "one
boolean prop" is superseded by S2's precedent.

The NAME follows `number_field`: `secure_field`, SwiftUI's own word, and
broader than `password` (a PIN, an API key, a recovery code).

### P2 — The entry's contract, minus the undo ledger and the emoji picker (RECOMMEND: yes)

The kind takes the entry's text contract whole: `text_changed` carries the
REAL text to the app on every edit, `submitted` carries it on Return, the
`clear` and `focus` commands apply, `placeholder` is legal, as are the
a11y props, `grow`, `fill` and the R10 fill-the-column rule. The app needs
the text to verify or send it; a `Secret` string type in the nine bindings
was considered and is not proposed (ledger, if ever wanted).

Two differences, both built: the core's undo ledger never banks a secure
field's typing and the core keeps no copy of its text
(`Scene::is_secure_field`, live and stamped; Cmd+Z must never bring back a
password the user cleared), and the `emoji_picker` command is refused on
it. Context menus are refused as on every editable kind.

### P3 — No reveal affordance on any platform (RECOMMEND: none)

One observable semantics (invariant 1): no eye button anywhere. WinUI sets
`PasswordRevealMode = Hidden`, GTK leaves `show-peek-icon` off, the Apple
platforms have none. The phones keep their platform's last-character flash
(Compose's `RevealLastTyped`, which follows the user's system setting; iOS
cannot turn it off), since that is the platform's own convention and not an
affordance. An app-declared `reveal` toggle is ledgered for the day an app
asks for one.

### P4 — Copy and cut refused natively, paste allowed (RECOMMEND: yes)

Every platform's control already refuses copy and cut and accepts paste (a
password manager pastes). kaya adds nothing but keeps its own Edit menu
honest: the SwiftUI arm's cut and copy enablement lists name the entry,
textarea, search and number field and NOT the secure field, so Edit>Copy is
disabled while one has focus. The breadth holds the same on every arm.

### P5 — The a11y verdict is `field`; the platform's identity is kept (RECOMMEND: yes)

`expect_ax secure_field@password` reads `field/Password` by the
normalize-down rule (S7's reasoning): UIA has no secure control type, only
an `IsPassword` flag on an Edit. Each backend gives its assistive reader
the platform's own identity: AXSecureTextField (measured), GTK's password
text, UIA's IsPassword, Compose's `password()`. The VALUE is never exposed:
every platform masks it, and P6's read asserts that mask.

### P6 — What the harness may print: a count of masked characters, never the text (RECOMMEND: the count, read off the platform's mask)

The text must reach no verdict, observation, step log, verb trace,
watchdog sentence or flight-recorder bundle. Built:

- `type_secret "<text>"` types at the focus exactly as `type` does, and
  refuses unless a secure field holds the focus. Its argument is a
  `harness::Secret` (Rust) or `KayaSecret` (Swift), whose Debug,
  description and mirror name the length alone (`<secret: 6 chars>`); the
  Swift runner takes the argument out of the statement BEFORE the step is
  printed, traced or handed to the watchdog (`kayaSecretOut`).
- `type` refuses while a secure field holds the focus, `expect` and
  `set_text` on a `secure_field` target are parse refusals, each with one
  sentence held in both harnesses.
- `expect_masked secure_field@x N` answers `masked N`: how many characters
  the PLATFORM presents to assistive technology, each as its mask. The
  rule is one function (`harness::mask_count`, `kayaMaskCount`): a
  character `type_secret` could have typed (printable ASCII) is UNMASKED by
  definition, and the mask is one glyph. A platform that presented the
  text would read "the platform presents 6 of the secure field's characters
  unmasked" (watched: the SwiftUI arm drawing a plain TextField).

Why a count and not a masked string: the glyph differs per platform (§0
fact 3) and observations are byte-compared across lanes. Why not the
text's length from the model: that reads the text, and proves nothing
about masking.

THE GUARD, ON A PATH NOBODY CAN AVOID: every mac leg's transcripts (its log
and, on a red leg, its verb trace) are scanned after the leg for every
`type_secret` argument in its script, and a hit fails the leg
(tools/lib/secure_scan.py, run by `MacRecorder.watched_leg`, the one wiring
the pool and the hand run share). An argument too weak to scan for (under
six characters, or lacking an upper-case letter, a lower-case letter or a
digit) fails the leg too. check-steps holds the scene's arguments, the
scan's three answers and its wiring. The other four lanes owe the same
scan before their legs are wired (§6).

### P7 — Placeholder, submit and phone keyboards (RECOMMEND: as the entry, with no capitalization and no autocorrection on phones)

`placeholder` is legal on the kind (PROPS 30, which the search pass made a
text-kind prop). Return publishes `submitted` with the text, as on an
entry. iOS: `.textInputAutocapitalization(.never)` and
`.autocorrectionDisabled()` (built); the return key keeps the entry's
default. Compose: `KeyboardType.Password`, no capitalization, the entry's
IME action.

### P8 — The autofill hint is deferred to the ledger (RECOMMEND: defer)

Not free: iOS distinguishes `password`, `newPassword` and `oneTimeCode`,
and saving a credential needs associated domains, which is the packaging
milestone's territory; Android's autofill framework needs the content type
and a service; GTK and WinUI have no system password manager that reaches
an app. A `content` prop with those three words is the likely shape; its
trigger is the password-manager archetype or the first app with a login
screen (docs/deferred.md).

### P9 — Stamped secure fields exist (RECOMMEND: both zones, as every kind)

The template zone has `secure_field()` and `secure_field_bound()`, as the
search field has. A stamped copy is never banked either. Its masked read is
not asserted in the shared scene: copies share one a11y_id, so the mac's
identifier lookup is ambiguous; the scene asserts a copy through the app's
own label instead.

## §3 — The lowering, per backend

| backend | control | reveal | text_changed | submitted | expect_masked reads | secure_focused |
|---|---|---|---|---|---|---|
| SwiftUI, macOS (BUILT) | `SecureField(placeholder, text:)`, rounded border, KayaEntry's width and focus binding | none | the binding's setter, a no-op set refused | `.onSubmit` | AXValue by the field's a11y_id (U+F79A each) | the model's focusedId in `secureFields` |
| SwiftUI, iOS (BUILT) | the same view, no capitalization, no autocorrection; `type_secret` through the driver's `type_secure_b64` | none | as macOS | `.onSubmit` | the element's accessibilityValue, zero when the control's `hasText` is false (an empty field's value is its placeholder, measured) | as macOS |
| GTK 4 | kaya's `GtkPasswordEntry` subtype (crates/kaya/src/gtk/secure_text.rs), `show-peek-icon` false, `input-purpose` PASSWORD | none | `changed` under the quiet guard | `activate`, check-submit's GTK row | the AT-SPI text through `harness::mask_count` | the window's focus widget is a PasswordEntry |
| WinUI 3 | `PasswordBox`, `PasswordRevealMode::Hidden` (the class joins tools/winui-bindgen's filter) | none | `PasswordChanged` under the quiet guard | the `submit_on_enter` KeyDown door | UIA withholds the value, so the box's own `Password` length, computed in Rust and returned as a number | FocusManager's element is a PasswordBox |
| Compose (BUILT) | `BasicSecureTextField` (foundation 1.11.4), `TextObfuscationMode.RevealLastTyped`, `KeyboardType.Password`, capitalization None, autocorrect off | none | the state's text flow | the keyboard action and a hardware Return, as the entry | the node info's `isPassword` required, then its text, which kaya masks by overriding EditableText (Compose hands the real text otherwise, measured; §7) | the model's focusedId in `secureFields` |

The Rust Stage methods are `masked_len(target) -> Result<usize, MaskRead>`
and `secure_focused() -> bool`, both without defaults; `MaskRead`'s
refusals are fixed sentences, so nothing read off a field can ride one.

## §4 — The wire

- `kind` 24 `secure_field`. The spec hash moved 0xb28d4a0fddd60b2b ->
  0x904824951724780f; the nine wire files, kaya.h and the two hand-copied
  interpreter hashes moved with it.
- No new prop, occurrence or command. `placeholder`, `text`,
  `text_changed`, `submitted`, `clear` and `focus` serve; `emoji_picker`
  is refused on the kind.
- Harness (not on the wire): `type_secret` (an action verb, in
  check-verbs' ACTION_VERBS with its two waits) and `expect_masked` (an
  observation, `masked N`).

## §5 — The scene and the sweep

tools/scenes/secure.steps: the placeholder; focus by click; two
`type_secret` halves with `expect_masked` 6 and 12 and the app's label
reading the length and whether the text matches the guest's password (the
proof the app received the real text, which no label ever prints);
Return publishing `submitted` ("sent: 12 characters, match");
`expect_ax ... "field/Password"`; the app's `clear` command reaching the
field (`masked 0`, "empty"); a stamped copy's typing reaching the app with
its row key. Rust only on the mac lane until the bindings arrive
(tools/lib/lanes/mac.py DEPTH_SCENES and ORDER); declared unwired on iOS.

Gates that grew: check-steps (TARGET_KINDS; the secure scan's arguments,
three answers and wiring), tpl-surfaces (DEFAULT_KINDS), check-verbs
(`type_secret` in ACTION_VERBS; the Compose depth stub's refusal row),
scene-features (`type_secret` and `expect_masked` key the `secure`
feature), check-stubs (the ledger entry for the three stubbed backends).
check-sugar-surface is red by design until the eight bindings take the
kind (14 findings, all `secure_field`).

## §6 — Build order

1. DONE 2026-10-07, the depth: spec, core (P2's two exclusions), harness
   (P6), the Rust binding in both zones, the SwiftUI arm on both
   platforms, the Rust guest and the scene green on the mac.
2. Breadth (docs/deferred.md, the secure field's BUILD entry): GTK, WinUI
   and Compose per §3, each replacing `depth_stub("secure")` and its
   `secure_focused` answer; the iOS legs after measuring the masked read
   and showing the XCUITest driver's transcript does not record
   `type_b64`'s argument; the eight bindings in both zones, rusthost, the
   gallery scene and its ten guests; the secure scan on the linux,
   windows, iOS and android runners; per-backend identity clauses (P5) and
   a copy/cut-enablement clause (P4) in check-universal-props' shape.
3. The matrix, once; then the review page.

## §7 — Measured, and to be measured

- MEASURED 2026-10-07 (macOS 26, the secure leg): the SwiftUI SecureField's
  element is AXTextField / AXSecureTextField, AXValue is one U+F79A per
  character and never equals the text, and no AXNumberOfCharacters is
  published (docs/traps.md). The in-process typing route (NSApp.sendEvent)
  reaches a secure field under Secure Event Input.
- To measure at breadth: what AT-SPI publishes for GtkPasswordEntry's text
  and role; whether UIA's ValuePattern on a PasswordBox answers empty or
  refuses; Compose's EditableText under each obfuscation mode; iOS's
  accessibilityValue for a secure field and what a screen recording shows
  of it (the review page's iOS capture depends on it); whether any arm's
  native undo can bring back secure text.
- MEASURED 2026-10-07 (GTK 4.18.6, the linux lane): the node's role is
  password text and a plain GtkPasswordEntry's Text interface answers the
  REAL password (4.20 and later answer the invisible character). kaya's
  field is a GtkPasswordEntry subtype implementing GtkAccessibleText by
  its GtkText's display text, so the read is `masked N` on 4.18 too
  (docs/traps.md; docs/deferred.md's struck GTK 4.18 GAP and the lane's
  GTK version ruling). GTK keeps no undo history for invisible text, and
  the arm turns it off as well.
- MEASURED 2026-10-07 (WinUI, the lane VM): a PasswordBox's peer
  implements no Value pattern at all, so the read requires IsPassword and
  counts the box's own text; PasswordChanged is raised after SetPassword
  returns (docs/traps.md).
- MEASURED 2026-10-07 (Compose foundation 1.11.4, API 35 emulators): the
  secure field's AccessibilityNodeInfo carries the REAL text beside
  `isPassword` true, because the semantics EditableText is the
  untransformed text; only the drawn layout is masked. kaya overrides
  EditableText with one U+2022 per character in the field's own modifier,
  and the read counts the node info's text as every other backend does:
  `masked 6` after, "presents 6 ... unmasked" before (docs/traps.md).
- MEASURED 2026-10-07 (iOS 26.5, Xcode 26.6): an empty SecureField's
  accessibilityValue is its placeholder, so the read takes zero from the
  control's `hasText`; `XCUIApplication.typeText` logs its text in the
  driver's xcodebuild log, and the focused secure text field element's
  `typeText` logs `<redacted>` (docs/traps.md).
