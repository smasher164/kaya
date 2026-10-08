# The content type: the design pass and the depth slice (2026-10-07)

Status: BUILT on all five platforms and in all nine bindings (b7ad7af0); every ruling in §2 RULED 2026-10-08.
The DEPTH SLICE is built as recommended (§6 step 1): prop 56 `content_type`,
the core's wall, the Rust binding in both zones, the SwiftUI arm on macOS and
iOS, the harness's `expect_content_type`, and tools/scenes/autofill.steps
green on the mac for Rust. The breadth (§6 step 2) has built the GTK and
WinUI arms, green on the linux and windows lanes in every language they run;
what remains is on the ledger (docs/deferred.md, the content type's BUILD
entry).
Every ruling A1-A10 RULED 2026-10-08 (A8 as reuse of [links] hosts; the rest as built: "i'm cool with your rulings").

The maintainer asked for it on 2026-10-07: "prioritize ... the auto-fill hints
from a password manager or the messages app". A text field says what it holds
(a username, a password, a new password, a one-time code, an email address, a
phone number) so the platform can offer a saved credential from its password
manager, suggest a strong new password, and fill a code that just arrived by
text message. The secure field's plan deferred it (docs/secure-entry-plan.md
P8) with "a `content` prop with those three words" as the likely shape. The
search field's plan (docs/search-plan.md) is the shape of this one.

## §0 — What the platforms offer

Read from the SDKs on this machine (macOS 26.5 and iOS 26.5 headers and Swift
interfaces, compose-ui 1.11.4's classes in the gradle cache, the Windows App
SDK 2.2.1 metadata) and from the vendors' documentation. The macOS rows marked
MEASURED were measured on this slice's legs (§7).

| | the property | its words | what fills from it | saving a credential | keyboard |
|---|---|---|---|---|---|
| macOS | `NSTextField.contentType` (NSTextContent, macOS 11); SwiftUI's `.textContentType(_:)` sets it on the TextField's and the SecureField's NSTextField (MEASURED) | username, password, oneTimeCode (macOS 11); newPassword, emailAddress, telephoneNumber and about forty more (macOS 14); kaya's floor is macOS 13 | Password AutoFill from the Passwords app and credential provider extensions, offered on the focused field of a key window; one-time codes from Messages | the app's associated domains entitlement with `webcredentials:<host>`, and the domain serving apple-app-site-association naming the app | none |
| iOS | `UITextField.textContentType` (UITextInputTraits); the same SwiftUI modifier | username (11), password (11), newPassword (12), oneTimeCode (12), emailAddress, telephoneNumber (10), and the address, name and card families | the QuickType bar: matching credentials and the key button, a strong password on a newPassword field, "From Messages" (and Mail since iOS 17) on a oneTimeCode field; a code needs no associated domain, a domain-bound code (`@host #123456`) is offered only to that domain's apps | as macOS; strong-password suggestions also need the associated domain. `passwordRules` (UITextInputPasswordRules, iOS 12) describes the site's rules, and SwiftUI has no modifier for it | `.keyboardType` is separate; `.emailAddress` and `.phonePad` are the ones these words ask for, `.numberPad` the usual one for a code |
| Android, Compose | the semantics property `contentType` (androidx.compose.ui.autofill.ContentType, compose-ui 1.8+; the pinned foundation 1.11.4 brings ui 1.11.4, which has no flag left to turn semantic autofill off) | Username, NewUsername, Password, NewPassword, EmailAddress, PhoneNumber, SmsOtpCode and the address, name, card and birth-date families; each carries the Android autofill hint strings | the autofill framework (API 26+) and the user's autofill service (Google's, or a password manager's); Gboard shows a code from Messages in its suggestion strip | the service offers to save after the form goes; matching the app to a site needs a Digital Asset Links `get_login_creds` relation the domain serves | `KeyboardType.Email`, `Phone`, `NumberPassword`, `Number` are separate |
| GTK 4 | `GtkText:input-purpose` and `:input-hints` (a GtkPasswordEntry's inner GtkText; GtkEntry forwards both) | purposes FREE_FORM, ALPHA, DIGITS, NUMBER, PHONE, URL, EMAIL, NAME, PASSWORD, PIN, TERMINAL; hints such as NO_SPELLCHECK, NO_EMOJI, PRIVATE, LOWERCASE | nothing: no autofill service reaches a GTK app (libsecret stores secrets for the app; it fills no field) | the app's own business | the input method and an on-screen keyboard read the purpose and hints |
| WinUI 3 | `TextBox.InputScope` / `PasswordBox.InputScope` (InputScopeNameValue), and `TextBox.IsSpellCheckEnabled` / `IsTextPredictionEnabled` | EmailSmtpAddress, EmailNameOrAddress, TelephoneNumber, Digits, NumericPin, AlphanumericPin, NumericPassword, Password, NameOrPhoneNumber, ...; NO one-time code value and NO username value; a PasswordBox takes Password and NumericPin only | nothing: no system password manager fills a desktop app's box | the app's own business | the touch keyboard reads the scope |

Four facts decide the design:

1. **The three platforms with a password manager (macOS, iOS, Android) all
   take a closed word from a field and do the rest themselves.** Each has a
   constant for every word the maintainer named. The app never draws the
   suggestion, the key button or the code chip; the platform does.
2. **The two desktops without one (GTK and WinUI) have only a keyboard and
   input-method hint**, and it cannot tell every word apart: both toolkits
   give `password` and `new_password` the one password purpose, because
   neither has a password generator to offer.
3. **Matching a credential to the app needs a domain the app claims**, on
   every platform that saves credentials: Apple's `webcredentials:` entry in
   the associated domains entitlement and Android's `get_login_creds` asset
   link, each verified against a file the domain serves. Since A8's ruling
   (2026-10-07) every `[links] hosts` entry is claimed for both web links
   and saved logins (docs/app-links-plan.md L1). Until then nothing had
   generated the web half at all, whatever the ledger said.
4. **A one-time code from a text message needs no domain** on iOS and
   Android: the field's word is enough for the platform to offer the code.

## §1 — What kaya has

- The entry (kind 4) and the secure field (kind 24, docs/secure-entry-plan.md)
  share the text contract: `text_changed`, `submitted`, `placeholder`, the
  `clear` and `focus` commands.
- Enum-valued props exist as one I64 slot checked at the root against the
  spec enum (`fit`, `axis`, `symbol`, `filled`), and every binding reaches a
  new one through its generated wire file.
- The identity manifest (guests/assets/identity.toml) declares `[links]
  hosts`. Before A8 nothing read the list: no entitlement, no autoVerify
  filter, no site file.
- The SwiftUI secure field already turns off capitalization and
  autocorrection on iOS (secure P7); the entry sets no keyboard at all.

## §2 — The rulings (RULED 2026-10-08)

### A1 — A prop, `content_type`, on the entry and the secure field, in both zones (RULED 2026-10-07 as built: "i'm cool with your rulings")

A word on the field, not a kind: no platform changes the control's class for
it (an NSTextField stays an NSTextField, a TextBox a TextBox), and a kind per
word would multiply the text kinds by six. The NAME is the field's own term:
Apple's `textContentType`, Compose's `contentType`; P8's shorter `content`
says less about what it is. Legal on the two single-line credential kinds
and nowhere else: a search field holds a query, a number field a number, a
textarea prose, and a password manager fills none of them. The template zone
carries it too (a stamped account row's code field), as every prop on these
kinds does.

### A2 — The vocabulary: none, username, password, new_password, one_time_code, email, phone (RULED 2026-10-07 as built: "i'm cool with your rulings")

A closed spec enum, `none` (0, the default and the way back) and six words:
the maintainer's three (a saved username and password, a new password, a
code from a text message) and the two that ride the same mechanism on every
platform that has one (an email address and a phone number). Left out until
an app asks: the name, address, card and birth-date families (each is one
enum row and one table row per backend), and Compose's NewUsername, which
Apple has no word for. Adding a word later moves the spec hash and nothing
else.

### A3 — Which word fits which kind (RULED 2026-10-07 as built: "i'm cool with your rulings")

`password` and `new_password` on the secure field only; `username`, `email`
and `phone` on the entry only; `one_time_code` and `none` on either. A
password in an entry would be drawn in the clear and printed by every
transcript the secure field keeps it out of, and a username in a secure
field is a masked name nobody can check. Codes are commonly shown (iOS and
Android fill a plain field) and some apps mask them. The root refuses any
other pairing in one sentence naming the rule (scene.rs
`check_content_type`, watched in its unit test).

### A4 — Every backend accepts every word; the effect is the platform's (RULED 2026-10-07 as built: "i'm cool with your rulings")

One semantics (invariant 1): the word states what the field holds, and each
backend hands the platform its own word for it. What the platform then does
differs, and that difference is the platform's, not kaya's: macOS, iOS and
Android offer saved credentials, strong passwords and codes; GTK and WinUI
tell the input method and the on-screen keyboard. The table is §3. No
backend refuses a word and no backend draws anything of its own.

### A5 — The phone keyboard follows the word (RULED 2026-10-07 as built: "i'm cool with your rulings")

`email` takes the platform's email keyboard, `phone` the phone pad,
`one_time_code` the number pad (iOS `.numberPad`, Compose
`KeyboardType.Number` on an entry and `NumberPassword` on a secure field,
GTK DIGITS or PIN, WinUI Digits or NumericPin), and `username`, `email` and
`one_time_code` turn off capitalization and autocorrection, the
secure field's P7 rule. A code with letters in it is an entry with no word,
said so in the binding docs. There is no separate keyboard prop in kaya, and
pairing the two is what Apple's and Google's own samples do.

### A6 — The observation: `expect_content_type <target> <word>`, read off the platform's own property (RULED 2026-10-07 as built: "i'm cool with your rulings")

The verb answers `content_type <word>` where the word is what the PLATFORM's
own property says, mapped back through the one table that applied it (§3),
never kaya's model: a backend that accepts the word and applies nothing reads
`none` and fails the scene (watched on the mac, §7). The answers are the class
every platform's property tells apart: none, username, password,
one_time_code, email, phone. `new_password` reads as `password`, because GTK
and WinUI have one password purpose (§0 fact 2), and the parser refuses
`new_password` as an expectation in one sentence held in both harnesses. A
swapped row (`.newPassword` written as `.password`, `.emailAddress` as
`.telephoneNumber`) would read back through the same swapped table and pass,
so the rows are pinned statically against the platforms' documented
constants (tools/lib/content_type_routes.py, run by check-verbs, seven
watched negatives). A secure field with no word reads `none` on the Apple
platforms and `password` on GTK and WinUI, whose password control carries
the password purpose by default; the shared scene asserts no such field.

### A7 — No password rules in this slice (RULED 2026-10-07 as built: "i'm cool with your rulings")

Only iOS takes password rules (UITextInputPasswordRules), SwiftUI has no
modifier for them, and macOS, Android, GTK and WinUI have nothing to pass
them to. iOS's strong passwords default to 20 characters with upper, lower
and digits, which most services accept. Ledgered for the first app whose
service refuses them.

### A8 — Saving and matching credentials: RULED 2026-10-07, reuse `[links] hosts`

Without a claimed domain, macOS and iOS still offer the Passwords key and
every saved login for the user to search, and Android's service still offers
its suggestions; what a domain adds is matching the right login first and
offering to save a new one. THE MAINTAINER RULED (2026-10-07) that no new
declaration is added: every host in `[links] hosts` is claimed for saved
logins as well as web links. BUILT the same day:

- Apple: `webcredentials:<host>` beside `applinks:<host>` in the
  `com.apple.developer.associated-domains` entitlement
  (tools/lib/packaging/identity.py `associated_domains`). The mac arm writes
  it BESIDE the bundle as `<name>.entitlements` for a team-identity re-sign,
  because an ad-hoc bundle carrying it is killed at exec (docs/traps.md).
- Android: the APK side of `get_login_creds` is an `asset_statements`
  meta-data on `<application>` naming a string that includes each host's
  assetlinks.json (Google's credential-sharing setup calls it required).
  tools/lib/packaging/android.py writes the string and a manifest overlay
  carrying it and the autoVerify https filter; android/build.gradle.kts
  lays the overlay over every host APK.
- The site files: `tools/package.py site --team-id T --package P
  --cert-sha256 F` writes each host's `apple-app-site-association`
  (applinks and webcredentials) and `assetlinks.json` (`handle_all_urls`
  and `get_login_creds` for the app, `get_login_creds` for the site).

Held by check-app-identity's C15 (tools/lib/web_claims.py, seven watched
negatives) and, on every APK the android lane builds, by run-emulator's
`web_declaration`. NO LANE CAN VERIFY A CREDENTIAL MATCH: it needs a served
domain, the same limit as web links (docs/deferred.md, the web links
entry).

### A9 — The reveal toggle stays out of this slice (RULED 2026-10-07 as built: "i'm cool with your rulings")

The secure field's ledger entry paired the two. They share nothing: the
toggle is a visible affordance with a different control on every platform
(WinUI's eye button, GTK's peek icon, Compose's Visible mode, a SecureField
swapped for a TextField on the Apple platforms) and a harness question of its
own (what may a transcript print once the text is shown). It keeps its
ledger entry and its trigger.

### A10 — No SMS Retriever, no app-side code reading (RULED 2026-10-07 as built: "i'm cool with your rulings")

Android's SMS Retriever and SMS User Consent APIs let an app read the code
itself; they need Google Play services, a hash of the app's signing key in
the message or a consent prompt, and code in the app. The platform's own
route (the autofill hint and the keyboard's suggestion) needs none of that
and is the same act the user sees on iOS. kaya adds nothing on top.

## §3 — The lowering, per backend

| word | macOS (SwiftUI) | iOS (SwiftUI) | Compose | GTK (purpose, hints) | WinUI |
|---|---|---|---|---|---|
| none | no content type | none, default keyboard | no contentType | FREE_FORM (entry), PASSWORD (secure field) | Default (entry), Password (box) |
| username | `.username` | `.username`, no caps, no autocorrect | `ContentType.Username` | FREE_FORM, NO_SPELLCHECK, NO_EMOJI | Default, spell check and text prediction off |
| password | `.password` | `.password` | `ContentType.Password` | PASSWORD | Password |
| new_password | `.newPassword` (macOS 14+) | `.newPassword` | `ContentType.NewPassword` | PASSWORD | Password |
| one_time_code | `.oneTimeCode` | `.oneTimeCode`, number pad, no caps | `ContentType.SmsOtpCode`, number keyboard | DIGITS, PRIVATE (entry); PIN (secure field) | Digits (entry); NumericPin (box) |
| email | `.emailAddress` (macOS 14+) | `.emailAddress`, email keyboard, no caps | `ContentType.EmailAddress`, `KeyboardType.Email` | EMAIL, NO_SPELLCHECK | EmailSmtpAddress |
| phone | `.telephoneNumber` (macOS 14+) | `.telephoneNumber`, phone pad | `ContentType.PhoneNumber`, `KeyboardType.Phone` | PHONE | TelephoneNumber |

The read, per backend, is the same table backwards over the platform's own
property:

| backend | where the read looks | built |
|---|---|---|
| SwiftUI, macOS | the one NSTextField under the accessibility element the field's a11y_id names; its `contentType` | yes |
| SwiftUI, iOS | the UITextField at the element the a11y_id names; its `textContentType` | yes |
| Compose | the unmerged semantics node carrying the field's node id, its `ContentType` compared with the table's constants (the hint strings are internal to compose-ui 1.11.4) | yes |
| GTK | the field's delegate GtkText's `input-purpose` and `input-hints`, through gtk.rs's `content_hints()` | yes |
| WinUI | the box's `InputScope` (exactly one name), and for a TextBox its spell check and text prediction, through winui's `content_scopes()` | yes |

macOS 13 (kaya's floor) has no constant for new_password, email or phone, so
those three words apply nothing there and read `none`; every lane host runs
macOS 26.

## §4 — The wire

- PROPS 56 `content_type`, `PropKind::Enum("content_type")`; the spec enum
  `content_type` none 0, username 1, password 2, new_password 3,
  one_time_code 4, email 5, phone 6. The spec hash moved 0x904824951724780f
  -> 0x000c0323f11ef52f; the nine wire files, kaya.h (KAYA_PROP_CONTENT_TYPE,
  KAYA_CONTENT_TYPE_*) and the two hand-copied interpreter hashes moved with
  it.
- The root: legal on Entry and SecureField (check_prop), I64 (prop_value_type),
  the word-to-kind wall `check_content_type` (A3).
- Harness (not on the wire): `expect_content_type`, an observation answering
  `content_type <word>`; `Stage::content_type` has no default.

## §5 — The scene and the sweep

tools/scenes/autofill.steps, a new scene rather than more lines in
secure.steps: secure.steps is wired on five lanes in nine languages, so
extending it would redden every one of those legs until the breadth, where a
new scene rides the depth stub and the unwired declaration like every depth
slice before it. It reads a sign-in form (username, password), a sign-up form
(email, new password read as password), a code field, a phone field and a
field with no word; the app's own write turning the username into an email
address and back on a live field; and a stamped secure field carrying its
template's `one_time_code`.

Gates that grew: check-verbs (tools/lib/content_type_routes.py: the SwiftUI
table's twelve pinned rows, the apply on both views, the read reaching the
platform's property and not the model, the harness's three sentences equal,
and a backend whose stub goes owing a row; seven watched negatives),
check-sugar-surface (the live zone in all nine, with a fake-name census) and
tpl-surfaces (`content_type` in PROP_MEMBERS), scene-features
(`expect_content_type` keys the `autofill` feature), check-stubs (the
ledger's DEPTH STUB lines). check-sugar-surface is red by design until the
eight bindings take the prop: 15 findings, all `content_type`.

What no lane can test is the platform's autofill UI itself: the Passwords
key, a saved login, a strong password, a code from Messages. Those need a
real account, a real message and, for a match, a served domain. The review
page shows what each platform draws for a focused field: the mac window (no
affordance appears while the window is not key, §7), and at breadth the
iOS simulator's QuickType bar and the Android emulator's autofill and
keyboard strip, where each shows one without credentials.

## §6 — Build order

1. DONE 2026-10-07, the depth: spec, core, harness, the Rust binding in both
   zones, the SwiftUI arm on both Apple platforms, the Rust guest and the
   scene green on the mac.
2. Breadth (docs/deferred.md, the content type's BUILD entry): GTK, WinUI and
   Compose per §3, each replacing `depth_stub("autofill")` and taking its
   row in content_type_routes.py's BACKENDS; the iOS legs and a QuickType
   capture; the eight bindings in both zones, an autofill guest each.
3. The matrix once, then the review page with every lane's capture.
4. A8 BUILT 2026-10-07 on `[links] hosts` (above); its verification waits
   on a served domain with the web links'.

## §7 — Measured, and to be measured

- MEASURED 2026-10-07 (macOS 26, the autofill leg): SwiftUI does not put the
  a11y_id on the NSTextField (a walk for an NSTextField carrying it found
  none for any field), so the read finds the one NSTextField under the
  accessibility element's centre. `.textContentType` reaches that field's
  `contentType` on a TextField, a SecureField and a stamped copy: the leg
  reads all twelve observations green.
- MEASURED 2026-10-07: with KayaContentHint's macOS body cut to `content`, the
  leg reads `content_type none, wanted username` and every other word red.
- MEASURED 2026-10-07: with the field focused in the model, macOS drew no
  AutoFill affordance and opened no new window. The lane's guest runs as an
  accessory app and its window was not key, which is where AppKit offers
  AutoFill; making it key would take the keyboard from the person at the
  machine, so no capture shows the key button yet.
- MEASURED 2026-10-07 (linux lane, Debian forky, GTK 4.24.0): the GtkText's
  `input-purpose` and `input-hints` read back exactly as §3's GTK column
  applied them, on x11 and wayland, the stamped secure field's PIN included;
  the autofill legs are green in all eight languages, and with the two
  setters cut the rust leg read `content_type none, wanted username`. The window draws nothing for any word: no
  autofill service exists on that desktop, and the hint reaches only an input
  method or on-screen keyboard, neither of which the lane runs.
- MEASURED 2026-10-07 (iOS 26.5 simulator, autofill-swiftui green): the
  username field's QuickType bar shows the key and "Passwords" with no saved
  credential; the code field shows the number pad and no chip, since no
  message has arrived; the new-password field offers no strong password,
  which needs the associated domain (A8).
- MEASURED 2026-10-07 (Android emulator, autofill-compose green): Gboard
  shows its text keyboard on the username field and its number pad on the
  code field. The framework opens a request to Google's autofill service for
  the focused field (dumpsys autofill), which offers nothing with no saved
  credential. With the hint cut, Compose still reports email, phone and
  password from the keyboard type alone, and username and the code read
  `none`, so the leg goes red; a secure field with no word reads `password`
  here, as on GTK and WinUI.
- MEASURED 2026-10-07 (windows lane VM, WinUI 2.2.1): a TextBox or
  PasswordBox nothing names carries NO InputScope (the read is null), so
  creation applies `none`'s scope; without it every `none` read failed with
  "the box carries no InputScope". A fresh TextBox's spell check and text
  prediction both read true, the `none` row's value. The six autofill legs
  are green.
- To measure: whether a key window on macOS shows the Passwords key with an empty
  Passwords app.
