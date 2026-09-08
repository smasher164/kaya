# Task manager S2b — an app-wide appearance switch (design pass, 2026-09-07)

Queued by the maintainer from the S2 review: "an app-wide toggle/switch
that determines whether light or dark mode is enabled. In general, dark
mode should be something programmatically toggleable, because users
often just want to select one of those things. They may not want it to
default to the system's setting. Think about how nobody uses Discord's
light mode." The rulings below are proposals until ratified; §6 is the
build order once they are.

## §0 — What the platforms do

Every platform lets ONE APP adopt an appearance regardless of the
system's, through a supported override, and kaya already installs each
of them for the harness's `KAYA_APPEARANCE=light|dark` (docs/canvas-plan.md
§6; tools/check-appearance.py holds the sites):

| platform | the override | scope | changes at runtime? |
|---|---|---|---|
| macOS | `NSApp.appearance = NSAppearance(named:)` | the whole app | yes, every window redraws |
| iOS | `window.overrideUserInterfaceStyle` | per window; kaya has one | yes |
| GTK 4 | `adw::StyleManager::set_color_scheme(ForceLight/ForceDark/Default)` | the whole app | yes |
| WinUI 3 | `FrameworkElement.RequestedTheme` on each window's root (the Application-scope property throws once the app runs) | per root; kaya sets every window's | yes |
| Android | the window background from the `-night` theme plus `LocalConfiguration` forced night bits (NOT `UiModeManager.setApplicationNightMode`, which relaunches the activity — docs/traps.md) | the activity | to be measured: the env path installs at mount |

What the apps people use do: Discord offers Light / Dark / "Sync with
computer"; Slack the same three; Apple's Settings offers Light / Dark /
Auto. None offers a two-state switch alone — "follow the system" is
always the third value, and it is the default everywhere.

## §1 — What kaya has, and what the feature needs

- The four install sites above, each guarded so that with the variable
  UNSET nothing moves (the "inert unless asked for" clause), and each
  platform's reporter reading its TOOLKIT back rather than the variable
  (`kayaCanvasAppearance`, the "honest when asked" clause). Both are
  tools/check-appearance.py's rules, with thirteen watched negatives.
- Window props (crates/kaya/src/spec.rs WINDOW_PROPS): `title`, `width`,
  `height`, `veto_close`, `sections_presentation` (an enum), the
  multicolumn ceiling. An enum prop has a spelling in all nine bindings
  held by check-sugar-surface's window-prop sweep.
- App-wide things already ride the DEFAULT window: the menu bar is
  declared on window 0 and is the app's on macOS.
- The observable: `expect_ink`'s dark half proves a dark WINDOW on the
  canvas scene; the task manager has no canvas, so the switch needs a
  cheap read-back of its own.

What the feature needs: one declared value an app can set and change at
runtime; each backend applying it through the site it already has; a
harness verb that reads the platform back; and the switch in the task
manager's Settings driving it.

## §2 — The rulings (RULED 2026-09-07 as recommended: "i'm okay with these rulings")

### R1 — Scope: the whole app, not a window (RECOMMEND: app-wide)

Every platform's own setting is app-wide, three of the four overrides
are app-scope by construction, and no product offers per-window dark
mode. The value is declared once and every window the app opens wears
it. The carve-out is stated once: WinUI applies it per window root and
iOS per window, which kaya hides by applying to every window it owns.

### R2 — Spelling: a window prop on the default window (RECOMMEND)

`appearance`, a WINDOW prop with three values — `system` (the default),
`light`, `dark` — declared on `DEFAULT_WINDOW` and applied process-wide,
the menu bar's precedent. The alternative is a new "app prop" family for
one value: new wire, new sugar in nine bindings, new gate rows, for a
thing the default window already carries. Refused for now; if a second
app-wide value ever appears, the family question reopens with two
examples instead of one.

The sugar rides the window builder every binding has:
`tx.window(DEFAULT_WINDOW).appearance(Appearance::Dark)` in Rust,
`window(..., appearance="dark")` where the binding keys, and the
handler-time write is `set_window_prop`, which exists in all nine. The
enum's spelling per binding follows `sections_presentation`.

### R3 — Precedence over the harness knob (RECOMMEND: the app's choice wins)

`KAYA_APPEARANCE` is the harness's per-process knob and stays. When an
app declares `light` or `dark`, the app wins — that is the user's
explicit choice and the thing the scene is testing. `system` defers to
the knob when set and to the OS when not, so the `canvasdark-*` legs
are unchanged (the canvas scene declares nothing). One function per
backend answers "what appearance is asked for" — prop, then knob, then
none — and every install site is dominated by it; check-appearance's
"inert unless asked for" clause moves from the variable to that
function, and its negatives with it.

### R4 — The observable: `expect_appearance light|dark|system` reads the toolkit (RECOMMEND)

AMENDED 2026-09-08: the reporter answers `<mode> <source>`, the source being the
toolkit's override slot read back (`system` when empty, `override` when filled),
and a scene that chose System asks for `system` — the lane host is not always
light (docs/traps.md, "The lane host is dark at night").

A harness verb whose observation is the platform's OWN answer, never
the prop: `NSApp.effectiveAppearance` on the mac, the window's
`traitCollection.userInterfaceStyle` on iOS, `StyleManager.is_dark()`
on GTK, the root's `ActualTheme` on WinUI, `isSystemInDarkTheme()`
inside the composition on Android. check-appearance's "honest when
asked" clause extends to the new readers by name. The observation is
the byte-compared `appearance "dark"` on all three harnesses
(check-verbs' spelling census).

### R5 — The control in the task manager: a three-way choice (RECOMMEND: `select`, not a switch)

The maintainer said "toggle/switch". A two-state switch cannot say
"follow the system", which every product offers and defaults to. So
Settings gets `Appearance` as a `select` with System / Light / Dark,
the Discord and Slack shape, and its `on_change` writes the prop. If
the maintainer wants a switch anyway, the honest two-switch shape is
`Dark mode` plus `Use system appearance` (the second greying the first),
which is two rows for one choice; the select is one row.

### R6 — Persistence: none in this slice (RECOMMEND)

The choice lives for the process. S4 (the preferences store) is where
it survives a relaunch; declaring it there is one line then. Saying so
here keeps S2b from growing a store of its own.

## §3 — The lowering, per backend

As built (2026-09-07): every backend's install is dominated by ONE asked
function — `appearance_asked()` in the core for GTK and WinUI,
`kayaAppearanceAsked()` in the SwiftUI interpreter, `appearanceAsked()` in
KayaCompose — answering the prop first, the knob second, nothing third;
nothing asked puts the platform's default back (libadwaita `Default`,
WinUI `ElementTheme::Default`, `NSApp.appearance = nil`, iOS
`.unspecified`, Compose's background from the activity's own
configuration). The eight non-Rust bindings spell `appearance` as
`sections_presentation` is spelled in each — a raw integer plus the
generated constants, no per-language enum, since Rust alone has one and
minting eight would make `appearance` the only enum window prop spelled
differently from every other; a typed sweep over both enum props is a
ruling of its own if the maintainer wants it.

| backend | the arm | at runtime |
|---|---|---|
| SwiftUI (macOS) | `NSApp.appearance` from the prop; `nil` for `system` (then the knob, then the OS) | immediate, app-wide |
| SwiftUI (iOS) | `overrideUserInterfaceStyle` on every `UIWindow` kaya owns; `.unspecified` for `system` | immediate |
| GTK 4 | `StyleManager::default().set_color_scheme(...)`; `Default` for `system` | immediate |
| WinUI 3 | `SetRequestedTheme` on every window's root element; `Default` for `system` — AND THE GROUND AND THE CAPTION, found by the first dark capture (2026-09-07): element-scope theming recolours the controls but a root that paints nothing shows the XAML host's white, which is where the caption buttons seemed to lose their contrast. The menu shell carries `ApplicationPageBackgroundThemeBrush` as a `{ThemeResource}` so the ground follows the root; with the ground dark, WinUI recolours the system-drawn caption buttons from the root's theme by itself (measured on the second capture — no AppWindowTitleBar colours needed, which is fortunate since the bindings cannot box an IReference<Color> without windows-implement). A window with no menu shell still paints the host's white under a dark theme — the themed host for every window's content is a follow-up on the ledger. AND THE SECONDARY TEXT, the maintainer's second finding on the review page: `theme_resource::<Brush>("TextFillColorSecondaryBrush")` hands back the CURRENT theme's SolidColorBrush, a static object, so caption-role labels and the settings footer kept the light theme's grey on the dark window (dark on dark); a role's colour is applied as a Style whose setter says `{ThemeResource …}`, which re-resolves against the element's ActualTheme — the same mechanism the shell background uses | immediate |
| Compose | THE COMPOSE-STATE ROUTE (ruled 2026-09-07: "if android users are okay with the compose route, i'm alright with that" — the route Compose-first apps and Google's Now in Android sample take): the choice is composition state, `LocalConfiguration`'s night bits are re-provided from it and the window background repainted, no configuration change and no activity recreation; surfaces other processes own (the document picker, toasts, the share sheet) follow the SYSTEM's mode, as they do for every Android app | immediate; the re-provision measured in the depth build (§7) |

THE REVIEW'S TWO CHROME FINDINGS, taken the same evening: GTK's sidebar
pane read as one sheet with the content — the S2 rewrite carried
libadwaita's row class alone — so the pane wears `sidebar-pane` (the tint
the split views give it) and a vertical separator stands between it and
the content; and WinUI's NavigationView opened at its 320 default,
Settings' width for a pane with a search box, a third of the window
where the mac declares an ideal of 220 and GTK sizes to content — the
pane opens at 240 now, the mac's ideal plus this platform's row padding
(the maintainer's call, offered as the default).

## §4 — The wire

- WINDOW_PROPS gains `("appearance", <next id>, PropKind::Enum("appearance"))`
  with the enum `system=0, light=1, dark=2`; the spec hash moves;
  everything regenerates.
- No new TX record: `set_window_prop` carries it.
- The harness: `expect_appearance <mode>` in harness.rs, the SwiftUI
  and Compose interpreters; the Stage trait gains `fn appearance(&self)
  -> String` answered by the toolkit read-back.

## §5 — The scene and the gates

- tasks.steps: open Settings, `choose select@appearance "Dark"`,
  `expect_appearance "dark"`, back to `"System"`, `expect_appearance`
  reading the host's own (the lanes are light: `"light"`).
- check-appearance: the dominating function renamed and its negatives
  re-pointed; a new clause holds each backend's `expect_appearance`
  reader to a toolkit read (no `KAYA_APPEARANCE`, no prop) — the
  reporter rule one verb over.
- check-sugar-surface: the window-prop row for `appearance` in nine.
- check-verbs: the verb in three harnesses, the observation's spelling.

## §6 — Build order (rulings taken 2026-09-07; steps 1-3 built the same afternoon, step 4 in flight)

1. Spec + regenerate; the ledger entry with its KEY line.
2. Depth on the mac: the arm, the verb, Rust's sugar, the tasks
   Settings row, the scene.
3. Breadth: iOS, GTK, WinUI, Compose (after §7's measurement), the
   eight bindings' spellings; the gate rows.
4. The everyday matrix, then the plain one.

## §7 — To be measured before the design is frozen

The maintainer's frame for every arm (2026-09-07): "do what people on those
platforms expect from those apps in light/dark mode."

- ~~Compose: re-providing `LocalConfiguration` with new night bits at
  runtime recomposes the tree with the right colours WITHOUT an activity
  recreation, and the window background repaints~~ — MEASURED 2026-09-07
  on emulator-5554: choose-to-recomposed 183ms both ways, `wm_on_create_called`
  1 and `wm_relaunch_activity` 0 for the process, the whole window dark
  (status band, bars, empty ground) and light again; the next-screen
  carve-out is not needed.
- WinUI: `SetRequestedTheme` on a root while a ContentDialog or flyout
  is open.
- macOS: the sidebar's vibrancy under `NSApp.appearance` set at runtime
  (the material follows the app, not the desk).
