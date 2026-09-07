# Task manager S2 — switches, the Today badge, a link in notes, the launch slot

Stage S2 of docs/tasks-plan.md §6: four small features the app needs next,
each forced by one thing the v0 surface cannot spell. The order below is
the order of the rulings; the build is depth on the mac, then breadth
across the four backends and the eight other bindings, then the matrix,
with tools/scenes/tasks.steps as the scene. Written 2026-09-07 from the
vendors' documentation and the tree; what must be measured before the
design is frozen is §7.

## §0 — What the platforms do

**A switch.** Every platform has one, and every HIG says the same thing
about when: a switch is for a setting that takes effect at once, a
checkbox for an item in a list or a form that is submitted.

| | the control | a11y reports it as |
|---|---|---|
| macOS | `NSSwitch`; SwiftUI `Toggle` with `.toggleStyle(.switch)` — Ventura's Settings app is switches throughout | `AXCheckBox` with subrole `AXSwitch` (VoiceOver says "switch") |
| iOS | `UISwitch`; SwiftUI `Toggle` IS a switch (UIKit has no checkbox, which is why kaya's iOS checkbox already draws one) | a button with the `switch button` trait |
| Android, Material 3 | `Switch` (the M3 thumb-and-track) | `Role.Switch` |
| GTK 4 | `GtkSwitch`; `GtkCheckButton` is the checkbox | in-process `get_accessible_role` says `switch`, but ON THE AT-SPI BUS GTK publishes `check box` for a GtkSwitch, the same role as the check button (measured 2026-09-07 building the arm; the atspi 0.30 crate's role enum ends at 129, below ATSPI_ROLE_SWITCH = 130), so the harness's `switch` on GTK comes from the widget kaya built, the `datetime` precedent; `GtkLinkButton` publishes `link` itself |
| WinUI 3 | `ToggleSwitch` (with on/off content); `CheckBox` is the checkbox | UIA `Button` with the Toggle pattern |

**A badge on a section.** The count on a tab or a sidebar row.

| | where | shape |
|---|---|---|
| macOS | SwiftUI `.badge(_:)` on a `List` row (sidebar) and on `TabView` tabs, macOS 12+; AppKit's `NSTableView` has none | a count or a short text, trailing, secondary colour |
| iOS | `.badge(_:)` on tab items and List rows, iOS 15+ (`UITabBarItem.badgeValue`) | a red pill with a number or text on the tab; a grey count on a row |
| Android, Material 3 | `BadgedBox` around a `NavigationBarItem` / `NavigationRailItem` icon; `Badge` alone as a dot | a small pill on the icon's corner; a dot when it has no content |
| GTK 4 | nothing native on `GtkStackSwitcher` or a sidebar `GtkListBox` row; libadwaita's `AdwViewSwitcher` has `needs-attention` (a dot), no count | a label styled as a pill is what apps do |
| WinUI 3 | `NavigationViewItem.InfoBadge` (numeric, icon or dot; Windows App SDK 1.0+) | the Fluent info badge, on the item's trailing edge or the icon's corner |

**A link.** Text that opens a URL.

| | the control | opens the URL |
|---|---|---|
| macOS / iOS | SwiftUI `Link(label, destination:)`; `Text` with Markdown `[label](url)` also links | the framework, through `openURL` (the default browser / the app registered for the scheme) |
| Android | `LinkAnnotation.Url` inside an `AnnotatedString` (Compose 1.7+); older `ClickableText` | `UriHandler.openUri` by default |
| GTK 4 | `GtkLinkButton`, or a `GtkLabel` with `<a href>` markup and `activate-link` | `gtk_show_uri` by default |
| WinUI 3 | `HyperlinkButton` with `NavigateUri`, or a `Hyperlink` inline in a `TextBlock` | the shell's default handler when `NavigateUri` is set |

**A launch slot.** What the platform shows between the tap and the first
frame; the app declares it, the platform draws it.

| | the slot | what it takes |
|---|---|---|
| macOS | none (the HIG says show the window) | — |
| iOS | `UILaunchScreen` in Info.plist (iOS 14+; no storyboard needed) | `UIColorName` (an asset colour) and `UIImageName` (an asset image), optionally `UIImageRespectsSafeAreaInsets` |
| Android | the SplashScreen API (Android 12+; `androidx.core:core-splashscreen` back to API 23) | `windowSplashScreenBackground`, `windowSplashScreenAnimatedIcon` (a drawable, 288dp with a 192dp safe zone), optional `windowSplashScreenIconBackgroundColor` |
| GTK 4 | none | — |
| WinUI 3 | packaged (MSIX) apps: `<uap:SplashScreen Image=… BackgroundColor=…>` in the manifest; unpackaged apps: none | an image and a colour |

## §1 — What kaya has, and what each feature needs

- A `checkbox` kind (wire 6) with `checked` (prop 2), the `toggled`
  occurrence, the `toggle` harness verb and `expect_checked`. The Settings
  column declares two of them (docs/tasks-plan.md §1). On iOS they are
  already switches (the finding of 2026-09-05, `fixedSize` on iOS).
- A role prop (16) on every kind, with `destructive`, `prominent`,
  `heading`, `caption` and `plain` in the vocabulary (crates/kaya/src/wire.rs
  `MENU_ROLES`), reaching all four backends through tools/check-roles.py
  and all nine bindings through tools/check-sugar-surface.py's role clause.
- Sections (the `sections` window prop, `sections_presentation`), each with
  `title`, `icon` and `symbol` through `set_section_prop` (wire 27, the
  SECTION_PROPS table). No badge. "3 today" is a label in Today's column.
- Labels with `text`, roles, and a11y props. No `href`; a URL in a note is
  text.
- guests/assets/identity.toml with `name` and `icon`, read by the iOS
  bundle and the APK at build time and by the running app onto the wire
  (tools/check-app-identity.py). No launch slot.

Three facts decide the rulings:

1. Every switch is a checkbox to the model: `checked`, `toggled`, the
   same verb, the same observable. Only the drawing and the a11y trait
   differ, which is the shape of a ROLE, and iOS already made the choice
   for one platform without anyone noticing.
2. A badge belongs to the switcher item, not to a widget: the platforms
   put it on the tab or the sidebar row, which kaya's sections own; a
   label with a "badge" look would be a second thing.
3. A link OPENS; the platforms agree on that and on doing it themselves.
   The app that wants to intercept (S7's rich text, a link that navigates
   inside the app) is a different feature with its own occurrence.

## §2 — The rulings (RULED 2026-09-07, as recommended: "I approve the rulings")

### T1 — A switch is a ROLE on checkbox: `switch` (RECOMMEND: role)

`checkbox` with `role switch` draws the platform's switch (`.switch`
style, `GtkSwitch`, `ToggleSwitch`, Material `Switch`) and reports the
platform's switch trait to a11y; everything else — `checked`, `toggled`,
`toggle`, `expect_checked`, the a11y label — is the checkbox's. iOS draws
the same control for both roles and says so in the lowering (no divergence
in semantics, one in look, stated). A kind was the alternative and is
refused: the model is identical, and a kind would need nine constructors
and a verb sweep for a drawing choice. The role joins `MENU_ROLES` and
both role sweeps (check-roles, check-sugar-surface's role clause).

### T2 — A badge is a SECTION prop, a count: `badge` (RECOMMEND: section prop, u32, 0 clears)

`set_section_prop(section, badge, count)`; the switcher draws the count
where its platform draws one (a trailing count on the mac sidebar row and
the iOS tab, an info badge on WinUI, a `BadgedBox` on Compose) and GTK,
which has no native badge, draws a pill label on the row — the one
lowering that is kaya's own drawing, stated. Zero clears. A text badge
("new") and a dot are refused for S2: the archetype's need is a count,
and a text badge on an iOS tab is red where a count is grey — two looks
to rule that nothing yet needs. Observable: `expect_badge section#i 3`,
read back from the platform's control where it exposes one.

### T3 — A link is a ROLE on label: `link`, with `href` (RECOMMEND: role plus one prop)

`label` with `role link` and `href` (a new Str prop) draws the platform's
link and OPENS the URL through the platform's opener when activated — the
framework's `openURL`, `gtk_show_uri`, the shell, `UriHandler`. No
occurrence in S2: the app has nothing to decide, and a handler would make
four platforms' default behaviour conditional on a round trip. The
harness reads `expect_href label#i "https://…"` back off the control and
`expect_ax` reads `link/<text>`; nothing in a scene activates a link,
since that would open a browser on five lanes. A link inside running text
is S7's (rich text), not this.

### T4 — The launch slot is a BUILD-TIME declaration in identity.toml (RECOMMEND: `[launch]` with `background` and the mark)

```toml
[launch]
background = "#1C1C1E"      # the colour behind the mark
image = "guests/assets/icons/kaya-mark.png"   # defaults to `icon`
```

The iOS bundle writes `UILaunchScreen` (the colour and image as assets),
the APK writes the SplashScreen theme attributes (through
`core-splashscreen` so the emulator's API and older devices agree), and
the desktops declare nothing, since macOS and GTK have no slot and WinUI's
is the MSIX manifest's (S11, packaging). One declaration, honoured where
the platform has a slot, absent where it does not — the carve-out stated
once. tools/check-app-identity.py gains the clause: the launch colour and
the image's bytes in both builds agree with the declaration. Nothing rides
the wire.

AS BUILT (2026-09-07): `background = "#1C1C1E"` (Apple's dark systemGray6;
all four quadrants of the mark read on it, measured on both phones). iOS:
`UIImageName` resolves a loose PNG in the bundle, but `UIColorName` has NO
loose-file route and a name nothing answers falls back to WHITE with no
error, so the lane compiles one colorset with `xcrun actool` into
`target/ios-launch/Assets.car` once per lane (~3s) and every bundle carries
it; the Info.plist template's `UILaunchScreen` dict names both. Android:
`androidx.core:core-splashscreen:1.0.1` (minSdk is 26; the bare attributes
start at API 31), `color/kaya_launch_background` and `Theme.Kaya.Launch`,
every host activity calling `installSplashScreen()` first — which
check-app-identity's C7 holds, beside the byte checks on the compiled
catalog and the APK (16 watched negatives, two of which caught the
clause's own first drafts). The mark needs no padded variant: the splash
icon is masked to a circle and the mark is a full-bleed square.

## §3 — The lowering, per backend

| | T1 switch | T2 badge | T3 link |
|---|---|---|---|
| SwiftUI (mac) | `Toggle(…).toggleStyle(.switch)`; a11y `.isToggle` | `.badge(count)` on the sidebar `List` row and the `TabView` tab; 0 → no modifier | `Link(destination:) { Text }`; a11y `.isLink` |
| SwiftUI (iOS) | the same `Toggle` (already a switch); the role changes nothing, stated in the arm | `.badge(count)` on the tab item and the More list row | as mac |
| GTK 4 | `gtk4::Switch` with `state-set`; the row's label beside it as the checkbox's | a `GtkLabel` with a `.badge` CSS class (pill, secondary colour) trailing in the sidebar row; the stack switcher has none | `gtk4::LinkButton` |
| WinUI 3 | `ToggleSwitch` (`OnContent`/`OffContent` empty, the label as the checkbox's) | `NavigationViewItem.InfoBadge` with `Value = count`; 0 → `null` | `HyperlinkButton` with `NavigateUri` |

WinUI, as built (2026-09-07): a role that changes the control CLASS
arrives after the widget is parented (every sugar emits AddChild right
after CreateWidget), so the two arms swap the native in place —
`swap_element` carries the identity props over and takes the old
control's seat — while the registries keep the inner control, so every
non-role widget's path is unchanged. Measured on the VM: a ToggleSwitch's
peer publishes `AutomationControlType::Button` with the Toggle pattern
(the pattern is the `switch` signal), a HyperlinkButton's publishes
`Hyperlink`, and UIA derives the link's name from its content. Three
classes joined tools/winui-bindgen's filter (ToggleSwitch,
HyperlinkButton, InfoBadge, plus Windows.Foundation.Uri) and bindings.rs
was regenerated, the route docs/search-plan.md §3 names.
| Compose | `Switch` with `Role.Switch` | `BadgedBox { Badge { Text(count) } }` around the item's icon; 0 → none | `Text(AnnotatedString with LinkAnnotation.Url)` (Compose 1.7) |

The bindings: `role switch` and `role link` ride the role prop every
binding already spells (`checkbox(..., role="switch")`, Rust's
`.role(Role::Switch)`, and the same for `link`); `href` is one new prop in
the generated tables and one sugar spelling in nine (`label(text,
href=…)` where the binding's idiom keys, a chained `.href(…)` where it
chains); the badge is `set_section_prop` in the section sugar every
binding has for `symbol`. check-sugar-surface's sweeps cover the role, the
prop and the section prop.

The bindings, as built (2026-09-07): all eight DO, no carve-out. Swift's
enum case is written `` `switch` `` because the word is reserved; Rust's
`.href(…)` chains the way `.placeholder(…)` does; Go and C# gained the
generated `SetHref` forwards; check-sugar-surface's str-prop row holds
`href` in all nine. Observed on the VM capture and left as polish: the
WinUI ToggleSwitch's label sits a few pixels above the control's centre
(the checkbox row centres its label on a CheckBox's box, and the
ToggleSwitch is taller) — on the ledger's S2 entry.

THE REVIEW'S FINDINGS, taken the same afternoon (the maintainer's, from
the S2 review page): the notes field carries a `Notes` placeholder,
asserted in tasks.steps on every lane — and the macOS textarea published
no AXPlaceholderValue for its drawn placeholder (KayaTextareaPlaceholder
is an overlay, not the NSTextView's), which `expect_placeholder` read as
"" on the mac; the representable sets it by hand now. On iOS the notes
field and the link share one inset card by D7.5's run rule
(docs/adaptive-layout-plan.md), the Reminders shape; the maintainer kept
the rule and queued the run card's two polish items as S2c
(docs/tasks-plan.md §6), with S2b the app-wide appearance switch.

## §4 — The wire

- `MENU_ROLES`: `switch` and `link` join (one line each; not in the spec
  hash; check-roles demands the arms).
- `PROPS`: `("href", 31, PropKind::Str)` — the spec hash moves.
- `SECTION_PROPS`: `("badge", 4, U32)` — the spec hash moves.
- Occurrences: none. Harness verbs: `expect_badge`, `expect_href`; the
  switch is exercised by `toggle` and `expect_checked` as today, plus
  `expect_ax` reading the switch trait.

## §5 — The scene and the sweep

tools/scenes/tasks.steps grows: the Settings column's two checkboxes carry
`role switch` and the scene toggles one and reads it back and reads its
a11y role; the Today section reads `expect_badge section@today 3` after the
list's count changes; a task's notes gain a label with `role link` whose
`expect_href` and `expect_ax link/…` are read. The switch was to join
tools/scenes/gallery.steps as the ninth control; that is DEFERRED (the
ledger's S2 entry says why) — the tasks scene carries the switch's a11y
read on every lane. tools/check-app-identity.py holds T4.

## §6 — Build order (RULED 2026-09-07; steps 1-3 built and captured on all five lanes the same day, step 4 in flight)

1. Spec: the two roles, `href`, the section prop; regenerate; the
   ledger entry with its KEY line.
2. Depth on the mac: the three SwiftUI arms, the Rust sugar, the scene,
   `expect_badge` and `expect_href` in harness.rs, check-verbs' arms.
3. Breadth: GTK, WinUI, Compose; the eight bindings' sugar; the two
   role sweeps and check-sugar-surface's new rows; check-app-identity's
   launch clause with the iOS and APK builds.
4. The matrix, the everyday run first.

## §7 — To be measured before the design is frozen

- ~~What GTK 4's `GtkSwitch` reports to AT-SPI on the lane's Ubuntu~~ —
  measured twice (§0): in-process `switch`, on the bus `check box`; the
  bus is what the harness reads, so `switch` on GTK is kaya's own word for
  the widget it built, and `link` is the platform's.
- ~~Whether `.badge(_:)` on a macOS `NavigationSplitView` sidebar row draws
  on macOS 26~~ — measured 2026-09-07: it draws, trailing the row's label
  (the S2 review page's mac capture).
- ~~WinUI: `HyperlinkButton` inside a `TextBlock` flow versus standalone~~ —
  built standalone (the notes' label is its own widget) and drawn on the VM
  capture; the in-flow shape is a question for a richer notes field.
- ~~Android: the SplashScreen icon's safe zone~~ — measured: no padded
  variant needed (§2 T4, as built).
- ~~iOS: `UILaunchScreen` with `UIImageName` needs an asset catalog~~ —
  measured: the IMAGE resolves loose, the COLOUR does not and fails white
  and silent, so the catalog is compiled for the colour (§2 T4, as built).
