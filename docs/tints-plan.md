# Tints and the filled container — the design pass

Status: T1-T3 RULED 2026-09-25 (the maintainer: "i like the ability to
push styling as far as possible without making things too low-level. the
ui should flow and just work in a lot of cases, but styling/branding is
still important. if we can do it in a somewhat portable way, we should").
§3's details are RECOMMENDED and amendable. The chat app's bubble
(docs/chat-plan.md R3) is the first consumer. This AMENDS
docs/styling-plan.md §2's "no colors, radii, or padding on a widget":
colours enter as a closed vocabulary of platform tokens, never as values.
The platform facts are docs/probes/platform-tokens-2026-09-25.md, read
from each vendor's own source.

## §0 — What the platforms offer

Every platform can paint any colour. What they share is a small set of
NAMED colours that follow dark mode and the contrast settings, each fill
paired with a foreground that stays legible on it. A raw colour loses
that on every platform, and on Windows High Contrast a raw fill stays
exactly as it was while the text around it changes.

| tint | Apple | Material 3 (Compose) | libadwaita | WinUI |
|---|---|---|---|---|
| accent | `accentColor`, white text (convention; iOS has no public on-accent token) | `primary` / `onPrimary` | `accent_bg_color` / `accent_fg_color` | a pale accent step (`SystemAccentColorLight3` light, `Dark3` dark) + primary text, ruled 2026-09-25 (§3) |
| success | `systemGreen` | none in the scheme: a harmonized custom colour's `accent` / `onAccent` (material-color-utilities, already a dependency) | `success_bg_color` / `success_fg_color` | `SystemFillColorSuccessBackground` + primary text |
| warning | `systemOrange` | harmonized custom colour, as success | `warning_bg_color` / `warning_fg_color` | `SystemFillColorCautionBackground` + primary text |
| critical | `systemRed` | `error` / `onError` | `error_bg_color` / `error_fg_color` | `SystemFillColorCriticalBackground` + primary text |
| neutral | the fill family (`.fill.secondary`, macOS 14 / iOS 17; kaya's mac floor is 13) | `surfaceContainerHigh` / `onSurface` | `card_bg_color` / `card_fg_color` | `CardBackgroundFillColorDefault` + primary text |

Two things the table says that the design has to carry:
- The platforms do not agree on intensity. libadwaita's success fill is
  saturated with white text; Fluent's is the pale InfoBar background with
  ordinary text. The tint names what a surface MEANS; how loud it is
  belongs to the platform, as with every other role.
- Windows High Contrast collapses success, caution and critical to ONE
  colour, and the accent fill to the window's own. So a tint is never the
  only carrier of meaning (WCAG 1.4.1): a warning also says so in words
  or a symbol, and the scene checks the words.

## §1 — The rulings (RULED 2026-09-25)

- **T1 — a closed tint vocabulary:** `accent`, `success`, `warning`,
  `critical`, `neutral`. Kaya may grow it (styling-plan D5); an app
  cannot name a colour outside it.
- **T2 — a filled container role**, one general role that the chat bubble,
  a banner, a callout and a tag chip all use, with a `tint` prop that
  defaults to `neutral`. Kaya sets the fill, the corner radius and the
  foreground of everything inside it from the platform's pair. There is
  no chat-specific role: the bubble is `accent` for the user's messages
  and `neutral` for the peer's.
- **T3 — raw data colours wait for a consumer.** A colour that IS the
  content (a project's dot, an avatar, a calendar) is a separate tier, on
  small marks only and never on text or chrome, and it waits until an app
  needs it. The task manager's projects are the likely first. This is
  the canvas paint rule one surface over: roles first, literal RGB as the
  named escalation (crates/kaya/src/spec.rs's `paint` enum).

## §2 — What this pass does not do

- No tint on buttons. The button roles (`prominent`, `destructive`,
  `plain`) already cover what a platform's buttons express.
- No borders, shadows or elevation choice. Each platform's card is what it
  is: libadwaita's `.card` carries a soft shadow, Fluent's card is flat.
- No per-app corner radius.

## §3 — The details (RECOMMENDED)

- **The name: `filled`.** "card" means a specific look on each platform
  (a shadowed card on Adwaita, a Material Card component); a filled
  container is only the fill, the radius and the foreground. BUILT AS ONE
  PROP, not a role beside a `tint` prop (2026-09-25, the depth slice):
  `filled` on a row or column takes the tint as its value, so a tint can
  never be set on a container nothing fills — the silent no-op the
  a11y-empty-label entry paid for. The app writes `.filled(Tint::Accent)`.
- **The radius is the platform's.** libadwaita's card radius is 12px (a
  stylesheet constant, not readable), Fluent's `OverlayCornerRadius` is 8,
  Material's medium shape is 12dp. Apple has no token; 12pt continuous,
  which is the grouped list's own card, is the recommendation, measured
  against a Messages capture in the depth slice.
- **The inset.** A `filled` container with no `inset` of its own takes
  the platform's card padding, so a bubble looks right without the app
  choosing a number; an explicit `inset` still wins.
- **The foreground is inherited.** A label inside takes the pair's
  foreground unless it has a role of its own (`caption` stays secondary,
  resolved against the fill). A `link` label keeps the platform's link
  colour on neutral and the pair's foreground on the other tints.
- **Neutral on macOS 13.** The fill family needs macOS 14. The depth slice
  measures the pre-14 route (`.quaternary` as a fill, or the grouped
  list's own card colour) and records which matches on 14 byte for byte.
- **Windows draws the accent as a SURFACE, not a button** (the maintainer,
  2026-09-25). Fluent keeps saturated fills for small marks and the accent
  button; a surface that carries text is a pale tint with ordinary text,
  which is how Teams draws the user's own messages and how InfoBar draws
  severity. So Windows' `accent` is a pale step of the accent ramp
  (Light3 in light, Dark3 in dark) with primary text, beside the pale
  severity backgrounds, and the four other platforms keep their solid
  accent. Fluent has no brush for it, so the backend installs one per theme
  (`KayaAccentSurfaceBrush`).
- **Label tints come second.** Text in a tint (`success_color`,
  `systemGreen`, Fluent's `SystemFillColorSuccess`) is the same vocabulary
  on a second prop, a slice after the container.

## §4 — How a leg sees it

`expect_fill <target> <tint>`: the backend reads the pixel 4 units inside
the container's RIGHT edge at mid-height — a filled container's padding
band, clear of the rounded corners — and compares it, within the ink tolerance
(docs/canvas-plan.md §7.2), against the platform token for that tint
resolved at that moment. The verdict is the tint's NAME, never a colour,
so the scene is byte-identical on every lane. A reader that compared
against the prop instead of the pixels would pass with nothing drawn, so
check-universal-props holds each reader to its toolkit. The dark half
runs under `KAYA_APPEARANCE=dark` (the canvasdark legs' route).

## §4.1 — Measured in the depth slice (2026-09-25, mac and iOS)

- The mac reader's capture (`cacheDisplay` on the content view) carries NO
  window background where nothing was drawn, so a translucent fill and the
  bare ground both read as black until the capture is composited over the
  resolved ground. The reader does that now; the first run read
  `000000` for the neutral and plain rows.
- Apple's accent, green, orange and red read back within one unit of the
  resolved system colours in both appearances (`FF393C` drawn against
  `FF383C` resolved), and the neutral fill is `EBEBEB` over a white ground
  in light and `303030` over `1E1E1E` in dark.
- A probe 3 units inside the TOP edge read a blend on GTK (`C0D7F4`, the
  accent a third of the way over white; `273E5D` in dark), stable across
  every retry, while the capture showed the fill whole: the root snapshot
  put the probe on the edge's own blended row. The probe moved to the left
  edge at mid-height, and then to the RIGHT edge, since an UNFILLED row
  has no padding band and the left probe read the plain row's "P" (the
  windows lane and wayland dark alike): `expect_fill <row> none` is asserted
  on a row whose right edge is empty. GTK's blend was the toplevel snapshot
  sitting a few units off `compute_bounds` on x11 (the CSD shadow), so the
  GTK reader snapshots the container itself and composites over the ground.
- WinUI's accent text: a theme-dictionary override on the filled Grid
  (`TextFillColorPrimaryBrush` remapped to `TextOnAccentFillColorPrimaryBrush`,
  lightweight styling) left every label at its default foreground — black
  on the dark accent in light mode, white on the light accent in dark —
  while the fill read passed, since it reads fills and not text. Each label
  inside an accent fill now takes a style based on its role's own with the
  on-accent brush, applied when the fill is set, when a child joins and when
  a role restyles it; check-universal-props holds all three sites.
- Windows resolves each candidate through a detached Grid that requests the
  window's theme and reads its `{ThemeResource}` background back; on the
  lane that answered the drawn colours in both appearances.
- `window.tintColor` is nil on the simulator's key window; the accent the
  reader resolves is `UIColor.tintColor`.
- White text on the system green and orange is Apple's own convention and
  reads weakly (libadwaita uses dark text on its warning fill). A visual
  ruling for the maintainer, recorded on the review page.

## §5 — Sequencing

| stage | builds |
|---|---|
| depth | the spec (role + tint enum), the Rust binding, the SwiftUI arm on mac and iOS, a `tints` scene with one container per tint, `expect_fill` |
| breadth | GTK, WinUI, Compose; the other eight bindings; the scene on all five lanes, light and dark |
| consumer | the chat app's bubbles (docs/chat-plan.md C0) |
| second | label tints |
