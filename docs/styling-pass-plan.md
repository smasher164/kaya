# The styling pass toward an app-skinned look: the design pass (2026-10-14)

Status: RULED 2026-10-15 (the maintainer: "accept all"), Y1-Y11 as recommended
(§8). DEPTH BUILT 2026-10-16 on the mac and iOS with the Rust binding
(docs/deferred.md's styling pass BUILD entry); BREADTH BUILT 2026-10-16 on GTK, WinUI and
Compose with the eight other bindings and the C floor; the demo (§6 step 4) is open. The roadmap card (docs/roadmap/editorial.toml,
"A styling pass toward an app-skinned look") carries his ask of 2026-10-08,
after seeing a Spotify client written in egui: "push kaya as far as possible
towards being able to style it like that." The same day he described what he
saw: a gradient header, a round avatar, art thumbnails in a track table, a
docked now-playing bar, chip filters. The card names five candidate
capabilities: gradient and image surface backgrounds; image shapes (a round
avatar, rounded art); card surfaces with hover and selection; image and
two-line cells in a table; a bar docked under the panes. His standing
preferences frame every answer here: styling portable as far as possible;
semantic tokens over raw values wherever the platforms share one; native
controls kept; churn is free; no staged splits once the unknowns are gone;
every capability a ruling of his.

This pass amends DESIGN.md's "Brand identity and the styling ceiling" a second
time, as docs/tints-plan.md did on 2026-09-25. docs/safe-area-plan.md and
docs/network-images-plan.md are the shape of this document; docs/styling-plan.md
(the brand tier), docs/tints-plan.md (the filled container) and
docs/tables-plan.md (cells and the pinned header) are what it builds on;
docs/media-plan.md is the player it serves.

Words used in this file, each as the field uses it:

- A GROUND is what is painted behind a container's children: a flat fill, a
  gradient, a picture. Apple says background, Material says surface, GTK says
  background, Fluent says fill; this file says ground for all of them, as
  docs/safe-area-plan.md A2 already does.
- A TOKEN is a named value a platform owns and resolves for the app: a colour
  such as libadwaita's `card_bg_color`, a shape such as Material's medium
  corner, a type size such as the caption tier. A token follows dark mode and
  the user's contrast settings; a RAW VALUE (a hex colour, a number of points)
  does not.
- A DATA COLOUR is a colour that is the app's content rather than its
  decoration: an album's dominant colour, a project's dot. docs/tints-plan.md
  T3 held this tier back until an app needed it; the gradient header is that
  app.
- A STATE LAYER is Material's term for the translucent wash a platform paints
  over a surface to show hover, focus or press; Fluent calls them the
  PointerOver and Pressed brushes, libadwaita paints them from `:hover` and
  `:active` rules. All three are tokens.
- The RELATIVE LUMINANCE of a colour is its brightness on a 0 to 1 scale as
  WCAG defines it; the CONTRAST RATIO of two colours is derived from their
  luminances, and 4.5:1 is the AA threshold for ordinary text. L* is CIELAB
  lightness, 0 to 100, the perceptual scale the brand derivation already
  clamps on (docs/styling-plan.md D1).
- A SURFACE in kaya's grammar is a mount target: a window, a pushed entry, a
  section, a sheet (DESIGN.md, Presentation contexts). This file adds one.

## §0: What the platforms offer, and what kaya does today

### The reference look

The screenshot is a music client in the shape of Spotify's desktop app, which
is the shape every streaming client has converged on. Its anatomy, left to
right and top to bottom, with the capability each part needs:

1. A SIDEBAR down the left: a short list of destinations (Home, Search, Your
   Library) with symbols, then a long list of playlists, each a row with a
   small rounded square of art, a title and a second grey line (the owner or
   the count). The row under the pointer lightens; the playlist being viewed
   is held in a selected state. Needs: rounded images, two-line rows, hover
   and selection on rows.
2. A HEADER at the top of the content pane: a large square of art (or a round
   avatar on an artist page), the title in a large bold face, metadata in a
   smaller grey line, all over a ground that starts in the art's dominant
   colour and fades downward into the page's dark ground. Needs: a gradient
   ground whose colour is data, a round or rounded image, the heading and
   caption roles (shipped).
3. A ROW OF CHIPS under the header or at the top of Home (All, Music,
   Podcasts): the segmented control (shipped 2026-10-08).
4. A CARD GRID on Home ("Made for you", "Recently played"): each card a
   rounded surface slightly lighter than the page, holding rounded art, a
   title and a grey second line; the card under the pointer lightens and shows
   a play button. Needs: card surfaces that take a click as a whole, hover.
5. A TRACK TABLE: columns for the index, the title, the album, the date added
   and the duration; the title cell is art plus two lines (the track's name,
   then the artist in grey); the row under the pointer lightens; the playing
   track's name is in the accent colour. Needs: an image cell and a two-line
   cell at a row height the table honours, hover on rows, a tinted label.
6. A PLAYER BAR docked across the bottom of the window under the sidebar and
   the content: the playing track's art and two lines on the left; shuffle,
   previous, play, next and repeat buttons with a progress slider under them
   in the centre; volume, queue and device buttons on the right. On a phone
   the same bar sits just above the tab bar and expands into a full-screen
   player when tapped. Needs: a window slot under the panes, the slider in
   the brand accent (shipped), the media session (shipped), a sheet (shipped).
7. The whole thing DARK: a near-black page (Spotify's is #121212), grey
   secondary text, one accent (Spotify's green #1DB954).

What the egui client shows is that this look is a dozen flat surfaces, a
handful of clipped pictures, one gradient, two hover states and a bar; it is
not a new widget set. egui reaches it by drawing every pixel itself, which is
also why its slider, scrollbar, text field and title bar are egui's rather than
the platform's. Spotify's own desktop app is a web page inside CEF (Chromium
Embedded Framework): it skins because it owns every pixel, and that is the
Electron class kaya's bet is against. The question this pass answers is how
much of (1) to (7) a toolkit of native controls can reach with tokens, where
it needs a data colour, and where it should stop.

### What kaya does today

Read from the tree at b4a99a48:

- THE BRAND TIER (docs/styling-plan.md, DESIGN.md): one accent, derived per
  appearance by the core's clamp; a typeface family; twenty-five semantic
  symbols; the app's identity. Set once before the first mount.
- THE ROLES (styling-plan D4, since grown): `destructive`, `prominent`,
  `heading`, `caption`, `plain`, `switch`, `link`, `composer`. The composer
  role is already a SHAPE on a container: Compose paints a row with that
  role as a 24dp pill (`KAYA_COMPOSER_SHAPE`), the other backends likewise.
- THE FILLED CONTAINER (docs/tints-plan.md): `filled` on a row or column
  takes one of five tints (`accent`, `success`, `warning`, `critical`,
  `neutral`), the platform's own fill and foreground pair, the platform's card
  radius and padding; `expect_fill` reads the drawn pixel against the token.
  The egui client's cards and sidebar rows are `neutral` fills in all but
  their behaviour.
- THE APPEARANCE: `appearance` (window prop 9) is `system`, `light` or `dark`,
  applied process-wide, with `KAYA_APPEARANCE` for the lanes. A dark-forced
  app exists today: the demo can declare it in one word. The platforms' dark
  grounds are already near the reference's: macOS `windowBackgroundColor`
  reads #1E1E1E in dark (docs/tints-plan.md §4.1), Material 3's baseline dark
  surface is #141218, Fluent's dark window is #202020, Adwaita's `window_bg`
  is #242424; Spotify's is #121212. All five hold white text above 15:1
  (§7). No window-ground knob is needed for the look.
- IMAGES: an image takes `source`, `max_width`/`max_height`, `fit`, `bleed`
  and `phase` (docs/network-images-plan.md, built 2026-10-13, with a decoded
  cache in every backend and a loading and a failed look). It has no shape:
  every backend draws a rectangle (SwiftUI `Image.resizable()` under
  `aspectRatio`, Compose `ContentScale`, GTK `GtkPicture`'s content fit,
  WinUI `Stretch`).
- TABLES (docs/tables-plan.md): a For whose row template's root is a Row of
  N cells, headers declared on the For, sort as a request, the header pinned
  since 2026-10-14. A cell is any widget: tools/scenes/netimage.steps already
  puts a 20pt image in a cell. The height is the obstacle: the macOS NATIVE
  tier's rows taller than NSTableView's 24pt floor run past the window
  (docs/deferred.md's OPEN entry, which is why that scene's art is 20pt), so
  art-plus-two-lines, about 56pt on every platform's own list, is not
  reachable on the mac table today.
- CLICKS: only a button emits (`button_clicked`, through `on_click` in the
  live zone and `on_click_node` in the template zone). A row or card cannot
  take a click as a whole; the task manager puts a "details" button in each
  row. Nothing in the vocabulary is hovered or selected: the four backends
  each have one internal hover or motion site (a tooltip's, a slider's) and
  none an app can see.
- SURFACES: a window, its entries, its sections (`bar`, `sidebar`, `auto`), a
  sheet over any of them with detents. A window has a top (the menu bar, the
  toolbar promotion, the title) and the section bar at a phone's bottom; it
  has no slot of its own under the panes.
- THE HARNESS: `expect_ink` samples a canvas or a colour picker at named
  points in both appearances; `expect_fill` reads a container's fill against
  the platform token; `expect_image_size` and `expect_image_phase` read an
  image's box and look; `expect_ax` reads roles and states off each
  platform's accessibility tree. There is no hover verb, no shape reading, no
  ground reading, and `expect_selection` is the textarea's text selection.

### What each platform offers, per capability

The columns are kaya's five backends; the rows are the card's capabilities,
with a sixth (the tinted label) that the track table needs and
docs/tints-plan.md §3 promised as its second slice. Versions are the lanes':
macOS 13 floor (the fill family needs 14), iOS 17 floor with the pool on
26.5, Compose BOM 2024.10.01 (Material 3 1.3), libadwaita 1.9 on GTK 4.24,
Windows App SDK 2.2 (WinUI 3).

| capability | SwiftUI (macOS, iOS) | Compose / Material 3 | GTK 4 / libadwaita | WinUI 3 / Fluent |
|---|---|---|---|---|
| gradient ground | `LinearGradient` as a `.background`; interpolates in the display's space; `.containerBackground` for a whole scene (macOS 14) | `Modifier.background(Brush.verticalGradient(...), shape)`; interpolates in sRGB | CSS `linear-gradient()` on any widget through a provider (kaya installs three already); GTK 4.16 lets a gradient name its interpolation space | `LinearGradientBrush` with `ColorInterpolationMode` (sRGB or linear scRGB) |
| image ground | `.background(Image(...).resizable().scaledToFill())`; text over it is the app's problem, Apple's answer being a material (`.ultraThinMaterial`, macOS 12) or vibrancy | `Modifier.paint(painter, contentScale = Crop)`; Material's `scrim` role (32% is its own use) over media | a `GtkPicture` under an overlay (`GtkOverlay`); the `.osd` style class is GNOME's dark translucent panel over media with light text | `ImageBrush` with `Stretch.UniformToFill`; `SmokeFillColorDefaultBrush` and `AcrylicBrush` are Fluent's panels over media; `Mica`/`DesktopAcrylic` are window backdrops, not surfaces |
| image shape | `.clipShape(Circle())` / `RoundedRectangle(cornerRadius:, style: .continuous)`; no platform radius token, the grouped list's 12pt continuous is the convention kaya adopted for the filled container | `Modifier.clip(CircleShape)` / `MaterialTheme.shapes.medium` (12dp); `ContentScale.Crop` inside | no radius on `GtkPicture`; a wrapper with CSS `border-radius` and `gtk_widget_set_overflow(HIDDEN)` clips its child; `AdwAvatar` is the round one, with initials as its fallback; `.card` radius 12px | `Image` has no corner clip; the documented route is an `Ellipse` or a `Rectangle` with `RadiusX`/`RadiusY` filled by an `ImageBrush` (what `PersonPicture` does); `OverlayCornerRadius` 8 |
| a card that takes a click | a `Button` with a plain style around the content, or `.onTapGesture`; `.onHover` on macOS (10.15); `.hoverEffect` is the iPad pointer's; AppKit has no hover highlight idiom for arbitrary tiles, Safari's start page tiles being the one system example that lightens | `Modifier.clickable` with an `indication`: Material's state layers (hover 8% of `onSurface`, press 10%) and ripple; `Card(onClick:)` is this packaged | `.card.activatable` (hover and active states from the stylesheet); `GtkListBoxRow` with `activatable` and its `row-activated` signal; `:hover` on any widget through CSS | `ItemContainer` / `ListViewItem`'s `PointerOver` brushes (`SubtleFillColorSecondaryBrush`) and `Pressed`; a `Button` with a subtle style around content |
| selection on a row or card | `List` selection on both platforms; AppKit's `selectedContentBackgroundColor` (accent-derived) with `alternateSelectedControlTextColor`; `NSTableView` rows select natively; `AXSelected` in the tree | `Modifier.selectable(selected, onClick)` sets the `selected` semantics; Material's selected list and navigation items are `secondaryContainer` / `onSecondaryContainer` | `GtkListBoxRow`'s `:selected` (the accent fill), `GTK_ACCESSIBLE_STATE_SELECTED`; `.navigation-sidebar` rows | `ListViewItem` selection: `SubtleFillColorSecondary` plus the accent selection indicator pill; UIA `SelectionItem.IsSelected` |
| two-line and image cells | `Table` cells are any view; the native `NSTableView` needs its row height set from the content | a cell is any composable; `ListItem(leadingContent, headlineContent, supportingContent)` is Material's two-line row | any widget in a cell; `AdwActionRow` is the two-line row with a prefix | any element in a cell |
| a bar docked under the panes | `.safeAreaInset(edge: .bottom)` on the `NavigationSplitView` spans the window under every column (macOS 12, iOS 15); iOS 26 adds `tabViewBottomAccessory`, the Music app's own mini player above the tab bar, which collapses into the bar on scroll | `Scaffold(bottomBar = { Column(dock, NavigationBar) })`: the mini player above the navigation bar, YouTube Music's layout | `AdwToolbarView.add_bottom_bar` (1.4); `AdwBottomSheet` (1.6) has a `bottom-bar` child that opens into a sheet, and its documentation names music players as the case | a `Grid` row under the `NavigationView`, Windows Media Player's own layout; the bar wears `LayerFillColorDefault` or the window's Mica |
| a tinted label | `.foregroundStyle(Color.accentColor)`, `systemGreen` and siblings | `MaterialTheme.colorScheme.primary` / `error`, the harmonized custom roles kaya already derives for success and warning | `accent_color`, `success_color`, `warning_color`, `error_color`: libadwaita's STANDALONE colours, distinct from its fills by design | `AccentTextFillColorPrimaryBrush`, `SystemFillColorSuccessBrush` and siblings |
| reduced transparency and contrast | `accessibilityReduceTransparency` turns materials opaque (the system does it for its own materials); `accessibilityDifferentiateWithoutColor`; Increase Contrast moves every system colour | Android 14's contrast slider moves the dynamic scheme; a static scheme ignores it (styling-plan §0); no transparency setting | the high-contrast variant replaces `.card`'s shadow with a 1px border; no transparency setting | `UISettings.AdvancedEffectsEnabled` is the Transparency effects switch (Acrylic falls back to solid by itself); High Contrast rebinds every brush to the system colours and collapses the severity fills to one (docs/probes/platform-tokens-2026-09-25.md §4) |

Three readings of the table that carry the design:

- Every row but one is a TOKEN on every platform. The gradient's colour is
  the exception: it is the album's, and no platform has a token for it. So
  this pass admits exactly one data colour, in one place, under one clamp
  (Y2), and nothing else raw.
- The hover state is the weakest row and it is weakest on the mac. Material,
  Fluent and libadwaita each paint a hover layer from a token; AppKit has no
  convention for an arbitrary tile, and SwiftUI's `.hoverEffect` is the
  iPad's pointer, not the Mac's. Whatever the mac draws on hover is kaya's
  choice rather than the platform's (Y4 names it and asks).
- The bar under the panes is the one capability that is a GRAMMAR change
  rather than a prop: a new slot in the window, which the platforms all have
  (`safeAreaInset`, `bottomBar`, `add_bottom_bar`, a Grid row) and kaya's
  window grammar does not.

### How other toolkits answer the same ask

- Flutter: `ThemeData` with `ColorScheme.fromSeed`, `ThemeExtension` for an
  app's own tokens, `BoxDecoration(gradient:)`, `ClipRRect` and
  `CircleAvatar`, `InkWell` with `hoverColor`, `ListTile`
  (leading/title/subtitle), `NavigationBar` and a `bottomNavigationBar`
  slot. Everything is Flutter's own paint, so it has no ceiling and no native
  controls; it is the no-ceiling case docs/styling-plan.md §2 records
  refusing, and it shows what the complete vocabulary looks like: a theme
  object plus per-widget decoration.
- SwiftUI itself: no theme object; an app sets `.tint`, an asset catalog, and
  styles per view with `.background`, `.clipShape`, `.foregroundStyle` and
  materials. Apple's own Music app is a native app that reaches the reference
  look (sidebar, rounded art, mini player) with these alone.
- Compose: `MaterialTheme` with a `ColorScheme`, `Shapes` and `Typography`;
  the surface and its tonal elevation; `Card`; `Brush` for gradients; the
  state layers are automatic on `clickable`. One theme object, tokens inside
  it, decoration per modifier.
- GTK: CSS on named colours and style classes; libadwaita exposes thirty-odd
  named colours and says an app may override the accent; `.card`, `.osd`,
  `.navigation-sidebar` and `.boxed-list` are the sanctioned skins.
- WinUI: resource dictionaries of brushes keyed by name, overridden per app
  and per theme; `CornerRadius` resources; Acrylic and Mica as materials.
  Lightweight styling (override the keyed brush) is the sanctioned route.
- egui: an immediate-mode `Visuals` struct (dark or light) and per-frame
  `Frame` fills, rounding and strokes; every control is egui's. It is the
  reference's medium and the opposite bet.

The pattern across the four native toolkits is the one docs/styling-plan.md §0
found in 2026: a small set of named colours and shapes the app FILLS, plus
per-container decoration drawn from them, with raw values legal but
discouraged. kaya's vocabulary is the same shape with the raw values left out
and the names made uniform, and this pass keeps that shape: it adds grounds,
a shape, two states, a tinted label and a slot, each a closed enum lowered to
the platform's own token, plus one data colour behind one clamp.

## §1: How kaya's model meets the problem: what a "theme" is here

The maintainer's deeper questions, answered before the rulings so the rulings
can be short.

**What is a kaya theme?** RECOMMEND: there is no theme object. An app's skin
is the sum of what it already declares once (the accent, the typeface, the
symbols, its identity, the window's appearance) and the per-container
vocabulary this pass adds (a ground, a shape, an activatable surface with its
states, a tinted label, a docked slot), each lowered to the platform's own
token. Nothing is a set of values an app hands kaya to override the
platform's: not the window ground, not a radius, not a surface colour. The
reference look needs none of those once the appearance is dark and the accent
is the brand's: the platforms' own dark grounds sit within four L* of
Spotify's (§7), and every other surface in the screenshot is the platform's
card or the platform's state layer.

Why not a theme object (a token set the app declares): the two toolkits
that have one (Flutter, Compose) draw everything themselves, so their token
set is complete and consistent by construction. A token set over four native
toolkits is a mapping table from kaya's names to theirs, which is exactly what
the closed enums already are, with one difference: an enum is lowered by kaya
and verified by a gate per platform, while a value handed by the app is
honoured where the platform can and dropped where it cannot, which is the
invariant-1 divergence the styling plan refused in 2026-08 (docs/styling-plan.md
D1's three rules). Per-window token sets are refused on the same ground, and
because no platform in the roster themes one window differently from the next.

**How do app-skinned and platform-native coexist in one app?** RECOMMEND the
rule Y1 states: kaya may paint GROUNDS and clip PICTURES and show the
platform's STATES on surfaces an app makes activatable; it never paints
CONTROLS. A button, slider, text field, picker, tab bar, menu, scrollbar,
title bar or sheet keeps its platform's chrome, and the brand reaches it only
through the accent and the typeface, as today. In the reference look that
line falls exactly where a user would draw it: the sidebar, header, cards,
table and player bar are grounds and pictures (kaya's), while the play button,
the progress slider and the volume slider are controls (the platform's, in
Spotify green). The egui client draws its own slider; kaya's demo will have
the platform's slider on a kaya ground, and that is the point rather than a
compromise.

**Accessibility.** Tokens carry dark mode and the contrast settings by
themselves, which is the argument for them (docs/tints-plan.md §0). The two
things this pass adds that tokens do not cover are handled structurally:
- A data colour under text. The gradient's top stop is clamped in the core so
  the appearance's text colour passes 4.5:1 against it (Y2; the numbers are
  §7), and the bottom stop is the platform's own ground. A picture under text
  has no clamp possible, so a label whose nearest ground is an image and that
  sits in no filled container between is REFUSED at the root (Y3): text over
  art goes inside an `overlay` fill, the platform's own panel-over-media, or
  does not go there.
- Windows High Contrast and Reduce Transparency. In High Contrast Fluent
  rebinds every brush, so the gradient and the hover layer must be resolved
  through `{ThemeResource}` and never a `SolidColorBrush` literal; the
  gradient ground becomes the window colour there (Y2's HC arm). Reduce
  Transparency on Apple and Transparency effects on Windows turn the
  platforms' materials opaque by themselves; kaya uses those materials rather
  than its own alpha, so nothing more is needed, and a gate holds that no arm
  spells its own alpha for the `overlay` tint.
- Selection and activation are accessibility facts first: `selected` is a
  state every platform's tree has (`AXSelected`, Compose's `selected`
  semantics, AT-SPI `selected`, UIA `SelectionItem`), and an activatable card
  is a button to assistive technology. Y4 reads selection off the tree, the
  heading role's precedent, and gives an activatable container the button
  role.

**Where is the line that keeps kaya a native-widget toolkit?** Three places,
each a refusal a gate can hold: no raw value except the one data colour under
its clamp; no ground, shape or state prop on a control kind (the root refuses,
`check_prop`'s shape); no kaya-drawn hover or selection where the platform
has a token for it. The one place kaya draws something the platform has no
idiom for is the mac's hover (Y4), and that is named as a choice for the
maintainer rather than slipped in.

## §2: The rulings (RULED 2026-10-15, as recommended)

### Y1: The line: grounds, pictures and states are the app's skin; controls stay the platform's (RULED 2026-10-15)

RECOMMEND that the vocabulary this pass adds (a ground, a shape, `on_activate`
with `selected`, a tinted label, a dock) be legal only on the kinds it names:
`ground` on row and column; `shape` on image; `on_activate` and `selected` on
row and column; `tint` on label; the dock on a window. The root refuses each
on any other kind at declare time, in its own words, before a backend sees
it. No control kind (button, entry, slider, select, segmented, checkbox,
pickers, fields, the video view) takes any of them. Brand reaches controls
through the accent and the typeface alone, as today.

Why: §1's coexistence rule needs a wall, and the kinds are the wall. A
gradient on a button or a shape on a slider is the arbitrary per-widget
appearance DESIGN.md's ceiling exists to refuse, and admitting it makes each
platform stop flowing like itself. The reference look never needs it: its
controls are plain controls in the accent.

Refused: a `style`/`class` prop, a stylesheet, per-widget radius or padding
overrides (docs/styling-plan.md §2 stands), a native-view escape hatch.

### Y2: A gradient ground on a container, from one data colour, fading into the platform's ground (RULED 2026-10-15)

RECOMMEND a new container prop `ground`, an enum (`none` 0, `gradient` 1,
`image` 2), legal on row and column in both zones, beside `filled`; a
container has one or the other, a gradient on a filled container refused at
the root. A `gradient` ground takes its colour from the existing `color` prop
(44, `PropKind::Color`, the colour picker's), made legal on row and column
when `ground` is `gradient`, and refused without it. The gradient is vertical,
top to bottom, always: the TOP stop is the given colour CLAMPED by the core,
the BOTTOM stop is the platform's window ground as the backend resolves it at
that moment (`windowBackgroundColor`, `scheme.background`, `window_bg_color`,
`ApplicationPageBackgroundThemeBrush`), so the surface melts into the page the
way the reference's header does. The clamp, one function in the core beside
the brand derivation (docs/styling-plan.md D1): in the dark appearance the top
stop keeps its hue and chroma and its L* is clamped to at most 48, where white
text passes 4.5:1 (§7: 4.82:1 at 48, 4.48:1 at 50); in the light appearance
its L* is clamped to at least 75, where black text passes above 10:1, so a
light header is a pale wash of the album's hue, Windows' pale accent surface
one surface over (docs/tints-plan.md §3). The foreground inside a gradient
ground is the appearance's primary text colour, and the mid-stops hold the
ratio because the sRGB decode is convex: a mix's luminance never exceeds the
linear interpolation of its ends, measured 11.6:1 to 15.2:1 along a clamped
purple fading to the mac's dark ground (§7). Backends receive the two stops as
values and interpolate in their own space; the probes read the stops (§5).

The data colour's source: RECOMMEND a core function `kaya_image_dominant`
over an image's bytes (the decoder the canvas's `load_image` already carries,
docs/media-plan.md §8 ruling 3): the colour of the largest bin of a coarse
histogram over the decoded pixels after dropping near-greys, returned as a
`Color`, once per content id and memoized beside the cache's id. Nine bindings
reach one implementation through the C ABI; no binding carries its own, since
nine quantizers would disagree on the same art. The clamp is applied by the
core when the prop is set, so a guest may hand the raw dominant colour and
every backend draws the clamped one.

In Windows High Contrast the gradient ground is the window colour, flat, and
every stop is resolved as a `{ThemeResource}`; the gate reads the arm.

Why: the header's gradient is the one part of the reference that no token
reaches, and docs/tints-plan.md T3 held the data-colour tier for its first
consumer: this is it. One colour, one direction, one clamp and a bottom stop
kaya does not choose keeps it portable: the app says which album, kaya says
how loud, the platform says what the page is. A gradient between two app
colours, an angle, a radial form, or a gradient as a window ground were weighed
and refused: each is a raw-value surface with no token behind it, and none
appears in the reference.

Refused: a gradient on a control; a horizontal or angled gradient; two app
colours; a gradient window ground; a data colour anywhere else (a label, a
fill, a chrome element), which stays the T3 tier's own future ruling.

### Y3: An image ground on a container, with text allowed only inside an `overlay` fill (RULED 2026-10-15)

RECOMMEND that `ground` may be `image`, taking the existing `source` prop (6,
Blob) made legal on row and column when `ground` is `image`, drawn to cover
the container (`fit` fixed at cover, cropping centred), in both zones. The
tint vocabulary grows by `overlay` (6): the platform's own panel over media
with its light foreground (SwiftUI `.regularMaterial` over a dark tint on the
mac and iOS, Material's `scrim` at the platform's opacity with `inverseOnSurface`
text, libadwaita's `.osd` class, Fluent's `SmokeFillColorDefaultBrush` with
`AcrylicBrush` where effects are on). The root REFUSES a label, a rich label
or a text control whose nearest ground above it is an image and which sits in
no `filled` container between: text over art lives inside an `overlay` fill
(the artist page's name at the foot of its picture) or a tinted fill, never
bare. Images, buttons, symbols and canvases may sit on an image ground bare,
since a button carries its own chrome and the others carry no text.

Why: the artist header and the "now playing" full screen in the reference are
art with text over a dark scrim at the bottom; the scrim is a platform panel
on all four. Text bare on a picture has no contrast anyone can promise and no
platform draws it, so the refusal is the only structural guard available, and
it is on the path nobody can avoid: the scene dies at declare time naming the
label. Reduce Transparency and Transparency effects turn the materials opaque
by the platform's own hand, which is why the tint is a platform material and
not kaya's alpha.

Refused: text bare on an image ground; a repeating or positioned image; a
blur radius or scrim opacity knob; a video as a ground.

### Y4: A container that takes a click as a whole, with the platform's hover and selection (RULED 2026-10-15)

RECOMMEND an `on_activate` handler on row and column in both zones, where
each binding spells a button's click (chained in Rust, Go, Python's keyword,
OCaml's labelled argument; app-registered on C#, Java, Swift, Haskell; the C
floor matches the occurrence head), emitting a new `activated` occurrence
carrying the widget, or the template node and the copy's key path
(`button_clicked`'s shape with `on_click_node`'s encoding). A container with a
handler is ACTIVATABLE: it is a button to assistive technology (the button
role with the container's accessible name, read by `expect_ax`), it takes the
platform's press feedback, and on a platform with a pointer it takes the
platform's HOVER state layer: libadwaita's `.card.activatable` hover, Fluent's
`SubtleFillColorSecondaryBrush`, Material's 8% `onSurface` layer; on the mac,
where AppKit has no tile-hover idiom, RECOMMEND the quaternary fill
(`.fill.quaternary` on macOS 14, `quaternaryLabelColor` as a fill on 13) over
the container, which is what Safari's start-page tiles do, and the
maintainer's visual ruling (§8). The phones show no hover and the pointer on
an iPad takes `.hoverEffect(.highlight)`, the platform's.

Beside it a `selected` Bool prop, legal on an activatable row or column only
(refused without `on_activate`, the silent-no-op rule docs/tints-plan.md §3
applied), a signal in the live zone and a row field in the template zone. A
selected container wears the platform's own selected surface: AppKit's
`selectedContentBackgroundColor` with `alternateSelectedControlTextColor`,
iOS's `systemFill` pair in a grouped list, Material's `secondaryContainer` /
`onSecondaryContainer`, libadwaita's `:selected` row, Fluent's
`ListViewItemBackgroundSelected` with the accent indicator pill. Its
foreground is inherited by the labels inside as `filled`'s is. The platform's
tree carries the selected state. Selection is the APP's, as sort is: the
`activated` occurrence says what was pressed and the app writes `selected`
where it wants it; kaya never toggles it, so a single-selection list and a
multi-selection grid are the same vocabulary.

On the macOS native table tier (an `NSTableView`), `on_activate` on the row
template is the table's own double-click action and `selected` is the table's
own selection, bound both ways; kaya paints nothing over a native row.

AMENDED 2026-10-17 (the maintainer, "im okay with your recommendations"): on
the macOS native table a user's click, and the arrow keys, move the table's
own selection as any Mac table does, and the app is TOLD through a new
selection-changed occurrence naming the row; the app's `selected` writes still
set it. Return and a double-click activate the selected row. The first build
(f188caba) refused a user's click so the table showed only the app's
selection, which left a single click and the arrows doing nothing; that is
replaced. The occurrence is a spec change, so it is swept across the nine
bindings and the other tiers decide whether a press there also reports it.
KEY: selection_changed, native table selection, doubleAction.

Why: the sidebar rows, the cards and the track rows are all "a surface that
takes a click and shows I am over it or on it", and today the only clickable
thing is a button, which is why the task manager carries a details button in
every row. Platform state layers are tokens on three of four; the mac's gap is
real and stated. Reading `selected` off the accessibility tree is the heading
role's shape: the one observable every platform's tree has.

Refused: a kaya-drawn hover where the platform has its own; a `hovered`
signal the app can read (hover is presentation, not state; no platform hands
it to the model); a double-click or long-press occurrence (the context menu
and swipe actions cover the second gesture); selection kaya manages.

### Y5: An image cell and a two-line cell at a row height every tier honours (RULED 2026-10-15)

RECOMMEND no new kind: a table cell is any widget, as docs/tables-plan.md
decision 4 already allows, so an image cell is an `image` with a `shape`
(Y6) and a two-line cell is a `column` of a label and a `caption` label,
`spacing` 0. What the ruling adds is the HEIGHT: every tier sets the table's
row height from the tallest stamped cell, and the macOS native tier sets
`NSTableView.rowHeight` from the template's measured height (or
`usesAutomaticRowHeights`, measured at the depth for which keeps the pinned
header and the virtualization band honest), closing docs/deferred.md's OPEN
entry on rows past the 24pt floor. A row's cells stay centred on the row's
cross axis (the row's `align = center` default, docs/tasks-plan.md R5).
`expect_rows` reads a nested cell's labels joined by `/` (`"Blue in Green/Miles
Davis"`), so the scene's verdict is one string on every lane.

Why: the track table is the reference's centre and it is one measured number
away on four tiers and one blocker away on the fifth. A dedicated "track
cell" kind would spell on the wire what two existing kinds already say.

Refused: a `subtitle` prop on a label; a `list_item` kind; a per-column width.

### Y6: Image shapes: rect, rounded, circle, in both zones, on every look (RULED 2026-10-15)

RECOMMEND a new image prop `shape`, an enum (`rect` 0, `rounded` 1, `circle`
2), legal on the image in both zones. `rounded` is the platform's own medium
corner, the one the filled container already wears (12pt continuous on Apple,
Material's `shapes.medium` 12dp, libadwaita's card 12px, Fluent's
`OverlayCornerRadius` 8); `circle` is the inscribed circle, and the root sets
`fit` to cover for it unless the app chose otherwise, since a circle of a
non-square picture must crop. The loading and failed looks
(docs/network-images-plan.md N4) take the same shape, so a round avatar is
round while it loads. Lowering: SwiftUI `.clipShape`; Compose
`Modifier.clip`; GTK a wrapper box with CSS `border-radius` and
`gtk_widget_set_overflow(HIDDEN)` for both shapes (not `AdwAvatar`, whose
initials fallback and single size are a person's avatar's, not a picture's);
WinUI an `Ellipse` or `Rectangle` with `RadiusX`/`RadiusY` filled by an
`ImageBrush` (`PersonPicture`'s own route), the plain `Image` kept for `rect`.

Why: rounded art and round avatars are in every list of the reference and
every platform clips a picture to a shape in one call; the radius is the
platform's token, so the vocabulary adds a name and no number.

Refused: a radius value; a `squircle`/continuous knob (Apple's continuous
corner is what `rounded` means there); shapes on the video view (its box is
the player's, docs/media-plan.md §3) or the canvas.

### Y7: A tinted label (RULED 2026-10-15)

RECOMMEND a new label prop `tint`, the existing `tint` enum, legal on label
and rich label: the platform's STANDALONE colour for that tint (Apple's
`accentColor` / `systemGreen` and siblings as text, Material's `primary`,
`error` and the harmonized custom roles kaya already derives, libadwaita's
`accent_color` / `success_color` / `warning_color` / `error_color`, Fluent's
`AccentTextFillColorPrimaryBrush` / `SystemFillColorSuccessBrush` and
siblings), a different number from the fill by every platform's own design
(docs/styling-plan.md D1's `standalone`). Inside a `filled` container the
label keeps the pair's foreground and the tint is ignored, since a tinted word
on a tinted fill has no pair anyone defined; `neutral` and `overlay` are
refused on a label, having no standalone colour. docs/tints-plan.md §3 named
this slice second; the playing track's title is its consumer.

Why: the one coloured word in the reference. A token on all four.

Refused: a raw colour on text (the T3 tier, which Y2 opens for the gradient
alone); a tint on a control's caption.

### Y8: A dock: one surface per window, under the panes, above a phone's tab bar (RULED 2026-10-15)

RECOMMEND a new surface, the DOCK: `attach_dock(window, dock)` declares it
once per window (a second refused at the root, as a second live sheet is),
`dock` a guest-allocated id in the surface namespace windows, entries,
sections and sheets share, and `mount(dock, root)` fills it. It is a root
like any surface: kaya's inset applies inside it, a `filled` or plain ground,
any widgets. Its PLACE is the platform's own: on macOS a bottom inset of the
window spanning every pane (`.safeAreaInset(edge: .bottom)` on the
`NavigationSplitView` or the content root); on iOS 26 the tab bar's
`tabViewBottomAccessory` when the window has sections, the Music app's own
mini player with its collapse into the bar, and a bottom inset of the tab's
content below 26 and without sections; on Compose the `bottomBar` slot above
the `NavigationBar` (YouTube Music's layout); on GTK `AdwToolbarView`'s
bottom bar, with `AdwBottomSheet`'s bottom-bar presentation weighed at the
depth for the phone-shaped expand; on WinUI a Grid row under the
`NavigationView` spanning the window, Windows Media Player's layout. The
dock's GROUND follows docs/safe-area-plan.md A2: the platform's bar surface
(the toolbar material on Apple, `surfaceContainer` on Material, Adwaita's
toolbar style, Fluent's `LayerFillColorDefault`) runs to the screen's edge
under the home indicator, and the dock's content stays inside the safe area.
A dock hides and shows through `hidden` on its mounted root (collapsed
everywhere, DESIGN.md's normalization), so a player with nothing playing has
no bar. On the phones a tap on the dock is the app's `on_activate` on its
root, and the full player is the sheet the app already has (`present_sheet`
with detents). The desktop full player, if any, is a pane or an entry.

Why: the player bar is the reference's defining element and the one piece
that is grammar rather than paint: every platform has a slot for it and
kaya's window has none. A surface rather than a window prop, because it holds
a root (the sheet's shape); one per window, because no platform stacks two;
attached rather than created, because it has no destruction grammar (the
sections' precedent). The alternative, a `column` at the window root with a
grown pane region above and the bar below, was weighed and refused: it puts
the bar inside the panes' presentation, under the sidebar's material on the
mac and above the tab bar's own slot on iOS, and it cannot reach the
platform's bar surface or the iOS 26 accessory.

Refused: a dock per pane or per section; a top dock (the toolbar and the menu
promotion are the top); a dock that pushes or presents on its own.

### Y9: The harness reads every one of these off the screen or the tree, never the model (RULED 2026-10-15)

RECOMMEND the readings §5 lists, each against the platform's resolved token
or its accessibility tree, with the verdict a NAME that is byte-identical on
every lane: `expect_ground` (the two stops read off the pixels, the bottom
one against the window ground the backend resolves), `expect_shape` (three
pixel probes whose pattern tells rect from rounded from circle, §5),
`expect_fill`'s vocabulary grown by `hovered`, `selected` and `overlay`,
`expect_selected` off the tree, `expect_tint` on a label against the
standalone token, `expect_dock`, and `hover` as a desktop verb. A reader that
answered from the node's own prop is refused by the gate, as `expect_fill`'s
is today (tools/check-universal-props.py).

Why: docs/styling-plan.md §0's rule, read-backs lie on every platform; the
styling scenes assert pixels or real tokens.

### Y10: All nine bindings and the C floor, both zones where the prop lives there (RULED 2026-10-15)

RECOMMEND the sweep in §4: every ruling above reaches all nine bindings and
the C floor in the same slice, with no language scoped out. The template zone
takes `shape`, `ground` with its colour or source bound to a row field,
`on_activate`, `selected` bound to a row field, and `tint`; the dock is a
window-construct declaration and so lives in the live zone alone.

Why: invariant 2; and the demo's library rows, cards and track rows are all
stamped.

### Y11: The first home: the media player demo, screen by screen (RULED 2026-10-15)

RECOMMEND that the demo decide the build's order (the card's own words): the
library sidebar and the Home card grid first (Y4, Y6), the playlist screen's
table second (Y5, Y6, Y7), its gradient header third (Y2), the dock fourth
(Y8), the artist page's image header last (Y3). The demo declares
`appearance: dark` only if the maintainer wants a dark-only app (§8); the
recommendation is `system`, with the review page showing both.

### Deferred, for the ledger at the depth

- Y2's data-colour tier for anything but the gradient (a project's dot, a
  calendar's colour): T3's own future ruling; KEY: data colour, dominant
  colour, raw colour tier.
- A skinned expander (docs/deferred.md's DEFER entry stands).
- Window backdrops (Mica, DesktopAcrylic, the Liquid Glass of macOS and iOS
  26): a window-level material is a platform choice kaya makes per backend,
  not a prop; measured at the depth for whether the dock and the sidebar
  should wear it; KEY: backdrop, Mica, glassEffect.
- A `hovered` reading for the app: refused above; recorded so nobody
  re-proposes it as a gap.
- Dynamic colour while branded (docs/styling-plan.md §2) is untouched.

## §3: The lowering, per backend

| backend | gradient ground (Y2) | image ground and `overlay` (Y3) | activatable, hover, selected (Y4) | shape (Y6) | tinted label (Y7) | dock (Y8) |
|---|---|---|---|---|---|---|
| SwiftUI, macOS | `.background(LinearGradient(colors: [top, ground], startPoint: .top, endPoint: .bottom))`, the ground `Color(nsColor: .windowBackgroundColor)` | `.background(Image.resizable().scaledToFill().clipped())`; `overlay` is `.regularMaterial` under a 40% black tint with `.white` foreground; the root's refusal of bare text | a `Button` with a plain style around the content for the press and the AX role; `.onHover` toggling a `.fill.quaternary` overlay (13: `quaternaryLabelColor`); `selected` paints `selectedContentBackgroundColor` with `alternateSelectedControlTextColor` inherited; `.accessibilityAddTraits(.isSelected)`; on the native table tier the `NSTableView`'s own selection and `doubleAction` | `.clipShape(Circle())` / `RoundedRectangle(cornerRadius: 12, style: .continuous)`, on the picture and on the loading and failed looks | `.foregroundStyle(Color.accentColor)`, `.green`, `.orange`, `.red` (the standalone system colours) | `.safeAreaInset(edge: .bottom)` on the window's content root, the bar's ground `.bar` material to the edge |
| SwiftUI, iOS | as macOS, the ground `Color(uiColor: .systemBackground)` | as macOS, `overlay` the `.regularMaterial` | the `Button` for press and role; no hover; `.hoverEffect(.highlight)` for an iPad pointer; `selected` the grouped list's `systemFill` pair, `.isSelected` trait | as macOS | as macOS | iOS 26: `.tabViewBottomAccessory` when the window has sections; otherwise `.safeAreaInset(edge: .bottom)` on the content, above the tab bar; the ground to the home indicator (A2) |
| Compose | `Modifier.background(Brush.verticalGradient(listOf(top, scheme.background)), shape)` | `Modifier.paint(painter, contentScale = Crop)`; `overlay` is `scheme.scrim` at 60% with `inverseOnSurface` text | `Modifier.clickable(indication = ripple())` so the 8% hover layer and the ripple come from Material; `Modifier.selectable(selected)` for the semantics, the surface `secondaryContainer` / `onSecondaryContainer` through the same `LocalKayaOnFill` the filled container uses; `Role.Button` | `Modifier.clip(CircleShape)` / `MaterialTheme.shapes.medium`, `ContentScale.Crop` for the circle | `scheme.primary`, `scheme.error`, `kayaCustomPair(...)`'s fill colour as text | `Scaffold(bottomBar = { Column { dock; NavigationBar } })`; the dock's ground `surfaceContainer` consuming `navigationBars` insets when there is no bar |
| GTK | a per-container CSS rule `background-image: linear-gradient(to bottom, <top>, var(--window-bg-color))` through the container-inset provider's sibling | `GtkOverlay` with a `GtkPicture` (`ContentFit::Cover`) under the children; `overlay` is the `.osd` class on the filled box | a `GtkListBoxRow`-shaped activatable: `.card.activatable` for a card (its own `:hover`/`:active`), `row-activated` for the occurrence; `selected` through `GtkListBoxRow:selected` where the container is a row of a For, the `.card` `:checked` state otherwise, `GTK_ACCESSIBLE_STATE_SELECTED` | a wrapper `GtkBox` with `border-radius: 12px` or `9999px` and `gtk_widget_set_overflow(GTK_OVERFLOW_HIDDEN)`, measured at the depth that the clip reaches the `GtkPicture`'s paintable | the `accent`, `success`, `warning`, `error` style classes (libadwaita's standalone colours) | `AdwToolbarView` with the dock as a bottom bar; `AdwBottomSheet`'s bottom-bar form weighed at the depth |
| WinUI | a `LinearGradientBrush` from `(0,0)` to `(0,1)` with the top stop and `{ThemeResource ApplicationPageBackgroundThemeBrush}`'s colour, installed per theme dictionary, the HC dictionary mapping it to `SystemColorWindowColor` | an `ImageBrush` (`UniformToFill`) as the Grid's background; `overlay` is `SmokeFillColorDefaultBrush` with `AcrylicBrush` when `UISettings.AdvancedEffectsEnabled`, `TextOnAccentFillColorPrimaryBrush` text | a `Button` with a subtle style around the content for press, hover (`SubtleFillColorSecondaryBrush` on PointerOver) and the UIA role; `selected` paints `ListViewItemBackgroundSelected` and the accent indicator pill, `SelectionItemPattern` exposed | an `Ellipse` or a `Rectangle` with `RadiusX`/`RadiusY` 8 filled by an `ImageBrush`; the plain `Image` for rect; the loading `Border` and the failed glyph clipped the same way | `AccentTextFillColorPrimaryBrush`, `SystemFillColorSuccessBrush`, `SystemFillColorCautionBrush`, `SystemFillColorCriticalBrush` | a Grid row under the `NavigationView` spanning the window, ground `LayerFillColorDefaultBrush` |

Three things every arm must hold, since no scene can see them: the gradient's
stops resolved from tokens and the data colour only (never a literal brush);
the hover and selection colours from the platform's tokens (never kaya's
numbers, the mac's quaternary fill being the one named exception); the
`overlay` tint from the platform's material (never kaya's alpha).

## §4: The wire and the sweep

- PROPS: `ground` (Enum("ground"): `none` 0, `gradient` 1, `image` 2) on row
  and column; `color` (44) and `source` (6) made legal on row and column when
  `ground` is `gradient` or `image` respectively, refused otherwise and
  refused together; `shape` (Enum("shape"): `rect` 0, `rounded` 1, `circle`
  2) on image; `selected` (Bool) on row and column; `tint` (Enum("tint")) on
  label. The numbers are the build's, append-only.
- ENUMS: `tint` grows `overlay` (6); `ground` and `shape` are new.
- TX: `attach_dock(window, dock)`; `mount` already targets any surface.
- OCCURRENCE: `activated` with the widget, or the template node and the key
  path; `on_activate` registered as `on_click` is in each family.
- CORE: the gradient clamp (pure, property-tested) and `kaya_image_dominant`
  over the decoder the canvas uses; the root's refusals (Y1's kinds, Y2's
  prop pairs, Y3's bare text, Y4's `selected` without a handler, Y7's two
  refused tints).
- HARNESS (not on the wire): `expect_ground`, `expect_shape`,
  `expect_selected`, `expect_tint`, `expect_dock`, `hover`; `expect_fill`'s
  vocabulary grown by `hovered`, `selected`, `overlay`; `expect_rows` reading
  nested cells.
- The spec hash moves; the nine wire files, kaya.h and both interpreters'
  hand-copied hashes move with it.

The sweep (invariant 2), one row per binding, DO unless stated:

| binding | `ground` + colour/source | `shape` | `on_activate` / `activated` | `selected` | `tint` on a label | dock | `image_dominant` |
|---|---|---|---|---|---|---|---|
| Rust | DO: `.ground(Ground::Gradient(color))` / `.ground(Ground::Image(blob))`, both zones, the field form in the template zone | DO: `.shape(Shape::Circle)` | DO: chained `.on_activate(&msgs, Msg::Open)`, `on_activate_node` in the template zone | DO: `.selected(sig)` / `.selected(Field)` | DO: `.tint(Tint::Accent)` | DO: `tx.window(0).dock(|d| ...)` returning its value (the body rule) | DO: `kaya::image_dominant(&bytes) -> Color` |
| Python | DO: keyword `ground=gradient(color)` / `ground=image(blob)` | DO: `shape="circle"` as the enum's spelling | DO: `on_activate=` keyword, the row's handler receiving its row | DO: `selected=` a signal or a field | DO: `tint="accent"` | DO: `with tx.window(0).dock() as d:` | DO |
| Go | DO: `.Ground(kaya.Gradient(c))`, both zones | DO: `.Shape(kaya.Circle)` | DO: chained on the handle (the Go handler rule) | DO | DO | DO: a method on the window construct | DO |
| C# | DO: constructor arguments, `Ground.Gradient(c)` | DO | DO: app-registered, the registry family | DO | DO | DO: `T Dock<T>(...)` returning the body's value | DO |
| Java | DO | DO | DO: app-registered | DO | DO | DO: `Built<R>` | DO |
| Swift | DO, under `KayaAppActor`'s rules | DO | DO: app-registered | DO | DO | DO: `dock<R>` | DO |
| OCaml | DO: labelled `~ground`, a `Ground` module beside `Tint` | DO: `~shape:\`Circle` as the enum's variant | DO: labelled `~on_activate` | DO | DO: `~tint` | DO: `when_`'s pair shape | DO |
| Haskell | DO: `Ground (Gradient c)` and a `Bound` twin | DO | DO: a Build action, the App-registered handler | DO: `Selected`/`SelectedBound` | DO | DO | DO |
| JS | DO: an options object, desktop only by ruling | DO | DO: on the declaration, the row Proxy handing the row | DO | DO | DO: `dock<T = void>` | DO |
| C floor | DO as the floor: `set_prop` with the enum's integers, `attach_dock`, a match on the `activated` head; the explicit form on purpose (invariant 5) | DO | DO | DO | DO | DO | DO: `kaya_image_dominant(bytes, len, &rgb)` |

No CAN'T and no DEFER: every piece is a prop, a handler in each family's own
spelling, or a window-construct declaration, all of which every binding has
spelled before.

## §5: The scenes and the gates

Five scenes, one per capability, the tints scene's shape (one guest, every
reading a name), plus two additions to existing scenes. Every verdict is a
NAME or a size, byte-identical on every lane; the desktops' hover lines are
cut on the phones through check-steps' phone cut.

1. `grounds.steps`: a column with `ground gradient` from a saturated colour,
   `expect_ground column@header gradient` (the pixel 4 units inside the top
   edge at mid-width is the clamped stop the backend resolves, the one 4
   units inside the bottom edge is the window ground, the two differ by more
   than the ink tolerance, and the midpoint's contrast against the appearance's
   text passes 4.5:1, computed by the reader from its own pixel); a label
   inside, `expect_ax` and a contrast reading on its pixels; the same in dark
   under `KAYA_APPEARANCE=dark`. A column with `ground image` over the
   generated album art, `expect_ground column@hero image` (the top probe
   matches the art's known colour at that point, the generated art carrying
   four unmistakable quadrant colours as the app icon does), a child row
   `filled overlay` with the artist's name, `expect_fill row@scrim overlay`.
   The negative is the refusal: a guest with a bare label on the image
   ground dies at declare time naming the label, forced to print once per
   run (`check-steps`' eight-cuts shape).
2. `shapes.steps`: three images of the same art, `rect`, `rounded`, `circle`,
   48 units square, over the plain ground; `expect_shape image#0 rect`
   (the probe 1 unit inside the top-left corner reads the art, the probe 6
   units in reads the art), `expect_shape image#1 rounded` (1 unit: the
   ground; 6 units: the art), `expect_shape image#2 circle` (1 unit: the
   ground; 6 units: the ground; the centre: the art). The three probes are the
   geometry: at 48 units a 12-unit corner leaves (1,1) outside the arc and
   (6,6) inside it, while a circle of radius 24 leaves (6,6) outside. A
   stamped row's art in `circle` while `loading` (`expect_image_phase
   loading`, the loading box's corner reading the ground). A `circle` on a
   non-square picture, `expect_image_size` the square.
3. `cards.steps`: a grid of filled columns with `on_activate`; `click
   column@card1`, the label reads the occurrence's key; `expect_ax
   column@card1 "button/Daily Mix 1"`; on the desktops `hover column@card2`
   then `expect_fill column@card2 hovered` and `expect_fill column@card1
   neutral`; a For of rows with `selected` bound to a field, the app setting
   it on activation: `click row@lib[p2]`, `expect_selected row@lib[p2] on`,
   `expect_selected row@lib[p1] off`, `expect_fill row@lib[p2] selected`.
4. `dock.steps`: a window with `panes 3` on the desktops and sections on the
   phones, a dock holding art, two labels, a slider and three buttons;
   `expect_dock window#0 shown` (the dock's frame read from the real tree
   lies at the window's bottom edge spanning its width, and every pane's
   frame ends above it; on iOS 26 the accessory's own frame); `expect_safe`
   on its slider (docs/safe-area-plan.md A9); `expect_fills slider@progress`;
   the root hidden, `expect_dock window#0 hidden`; on the phones `click
   row@dock_root`, `expect_sheets 1`.
5. `tracks.steps`: a table whose title cell is a `rounded` 40-unit image
   beside a column of a label and a caption; `expect_rows table#0
   "1,Blue in Green/Miles Davis,Kind of Blue|2,..."`, `expect_height_fits`
   on a row, `expect_header_shown` after a deep scroll (the pinned header at
   the taller row), `expect_image_size` on a stamped art; the playing row's
   title `tint accent`, `expect_tint label@playing[t3] accent`, and the
   non-playing title `none`; `hover row@t2` on the desktops, `expect_fill
   row@t2 hovered`; on the mac the native tier's own selection on `click`.
6. Additions: tints.steps gains `expect_fill row@t_overlay overlay`;
   netimage.steps' table art moves to 40 units and takes `rounded`, which is
   the mac native tier's height fix made visible on a scene already on every
   lane.

The desktop `hover` verb: on GTK and WinUI the pointer is the lane's
(wtype on the leg's own wayland session, xdotool on x11, `SendInput` on the
VM); on the mac the interpreter first tries an in-process `mouseMoved` through
`NSApp.sendEvent` (the click verb's route) and, if SwiftUI's tracking areas
ignore it (measured at the depth, §7), the mac hover legs join the lane's
EXCLUSIVE set and wait for an idle host (tools/lib/exclusive.py's idle_admit),
since moving the real pointer while the maintainer is at the machine is
refused by standing rule. Compose cuts the lines.

Every negative is a watched red (CLAUDE.md invariant 3), each with its
substitution count printed: the clamp removed (grounds red on the dark leg's
contrast reading), the bottom stop replaced by a literal (`expect_ground`
red), the refusal of bare text cut (the guest mounts and the scene's own
refusal check fires), the clip cut on one backend (`expect_shape` red on
`rounded` and `circle`), the hover layer replaced by a kaya colour
(`expect_fill hovered` red), `selected` painted without the AX state
(`expect_selected` red), the mac table's row height left at the floor
(`expect_height_fits` red), the dock placed inside the pane region
(`expect_dock` red on the pane frames), a `SolidColorBrush` literal in the
WinUI gradient (the HC gate red).

Gates that grow:

- check-sugar-surface: `ground` with `color`/`source`, `shape`, `on_activate`
  (each family's spelling, Go's on the handle), `selected`, `tint` on a label
  and the dock in the window construct, all nine, both zones where the prop
  lives there, fake-name and rename-in-a-copy negatives; the `activated`
  occurrence through the generated surfaces; `image_dominant` in all nine.
- tpl-surfaces: the five template-zone props in its census.
- check-universal-props: a `skin_routes.py` beside tools/lib/safearea_routes.py
  holding, per backend, the gradient's two stops from a token and the data
  colour only, the hover and selected colours from tokens (the mac's one named
  exception), the `overlay` material (no literal alpha), the shape applied to
  the picture AND the loading and failed looks, the dock's ground to the edge
  (A2), the refusal of bare text on an image ground, and every new reader
  answering from pixels or the tree (the `expect_fill` reader clause's shape);
  the macOS native table's row height from the template; cuts watched.
- check-verbs: the new verbs and the grown vocabularies in both interpreters;
  the WinUI gradient's brush spelled `{ThemeResource}` with an HC dictionary
  entry; the mac hover's route.
- check-table-card: the native tier's height beside the pinned header; the
  phone tiers' row height at the two-line cell.
- check-empty-child: the shaped loading and failed views keep one node per
  widget.
- check-steps: the phone cut on `hover`; the refusal forced to print once per
  run.
- check-exclusive: the mac hover legs in EXCLUSIVE if the in-process route
  fails, derived from the scenes as the file-panel legs are.
- check-roles' shape for the `ground` and `shape` enums: every variant reaches
  every backend's arm, red by design across the fan-out.
- unit tests in the core: the clamp (a property test over random colours:
  the top stop in dark passes 4.5:1 against white and in light against black,
  hue preserved), `image_dominant` on the generated art (the dominant colour
  of a picture that is 70% one colour is that colour; a grey picture answers
  a grey rather than nothing), the root's six refusals, each watched failing
  with its line cut.
- check-a11y's shape, one clause: no arm names `hovered` on the wire or in a
  binding (Y4's refusal of a hovered signal).

## §6: Build order

1. The measurements §7 lists as the depth's, before any arm: the mac hover
   route and look; `NSTableView`'s row height against the pinned header and
   the band; GTK's rounded clip reaching the picture; the WinUI `ImageBrush`
   route beside the failed glyph; the gradient's interpolation per platform
   against the midpoint probe; `image_dominant`'s cost on the 600-pixel art;
   iOS 26's accessory on the pool and its frame reader; whether the
   `overlay` material reads back opaque under Reduce Transparency.
2. The depth: spec (`ground`, `shape`, `selected`, `tint`, `overlay`, the
   `activated` occurrence, `attach_dock`, the refusals), the core (the clamp
   and `image_dominant` with their tests), the harness verbs, the SwiftUI arms
   on the mac and iOS (iOS compiled and run on the pool for shapes, cards and
   the dock), the Rust binding, the five Rust guests and `grounds`, `shapes`,
   `cards`, `dock` and `tracks` green on the mac; GTK, WinUI and Compose depth
   stubs (`depth_stub("skin")`); the BUILD and DEFERRED ledger entries with
   KEY lines; the mac native table's row height, which closes the OPEN entry.
3. The breadth: GTK, WinUI and Compose per §3; the eight other bindings and
   the C floor; the iOS and Android legs; `skin_routes.py` complete.
4. The demo's screens in Y11's order, each screen a review capture on every
   lane as it lands.
5. The matrix once, then the review page: every lane's capture of the Home
   grid with a card hovered (desktops) and one selected, the playlist screen's
   gradient header in light and dark, the track table with its art and
   two-line cells and the playing row's tinted title, the artist page's image
   header with its overlay, and the dock on the desktops and above the tab bar
   on the phones, with the phone's sheet open.

## §7: Measured, and to be measured

- COMPUTED 2026-10-14 (WCAG relative luminance, CIELAB L*; the python is in
  the session scratchpad): the platforms' dark grounds and the reference's:
  Spotify #121212 L* 5.5, macOS `windowBackgroundColor` (dark, as
  docs/tints-plan.md §4.1 read it) #1E1E1E L* 11.3, Material 3's baseline
  dark surface #141218 L* 5.8, Fluent's dark window #202020 L* 12.3,
  Adwaita's `window_bg_color` #242424 L* 14.2; white text on each is between
  15.5:1 and 18.7:1. The look's dark page is the platform's own.
- COMPUTED 2026-10-14: Spotify's green #1DB954 is L* 66.2; white text on it
  is 2.59:1 (fails AA), black text 8.12:1, which is why Spotify's own play
  button is black on green and why the brand derivation's `on_fill` rule
  (L* < 60 gives white, else black; docs/styling-plan.md D1) answers black
  for it. The accent as a fill needs no new rule.
- COMPUTED 2026-10-14, Y2's thresholds: white text passes 4.5:1 against a
  ground of L* 48 (4.82:1) and fails at 50 (4.48:1); black text passes from
  L* 49 (4.52:1). The dark clamp is L* at most 48; the light clamp at least
  75 (black text 10.7:1), clear of D1's 60 to 76 danger band on both sides.
- COMPUTED 2026-10-14, the mid-stops: a clamped purple #5B2A86 (L* 28.4,
  white 9.9:1) mixed toward #1E1E1E in sRGB at 25%, 50% and 75% gives
  #4C276C, #3C2452, #2D2138 at 11.6:1, 13.4:1 and 15.2:1; the ratio rises
  monotonically because the sRGB decode is convex, so a mix's luminance is at
  most the linear interpolation of its ends. In light, #E6D3F5 (L* 87) toward
  #ECECEC at 50% gives #E9E0F0 at 16.4:1 for black text. A platform that
  interpolates in linear light lands between the ends; one that interpolates
  in sRGB lands at or below them; neither can breach the clamp's ratio with
  the appearance's text. The midpoint probe in `grounds.steps` holds it on
  every lane anyway.
- READ FROM THE TREE 2026-10-14: `appearance` is a window prop (9) applied
  process-wide; `filled` is prop 38 with the five-tint enum; images have
  `source`, `max_width`, `max_height`, `fit`, `bleed`, `phase` and no shape;
  a table cell may be any widget and netimage.steps' art is 20pt because the
  mac native tier's rows past 24pt run past the window (docs/deferred.md's
  OPEN entry); only buttons emit clicks; each backend has one internal hover
  site and none app-visible; the window grammar has no bottom slot; the
  harness has no hover verb, no shape or ground reading; `expect_ink` reads
  canvases and colour pickers only; the Compose composer role already paints
  a 24dp pill on a row (`KAYA_COMPOSER_SHAPE`), the one shape on a container
  today; PropKind::Color exists (the colour picker's `color`, 44).
- READ FROM THE VENDORS 2026-10-14 (docs/probes/platform-tokens-2026-09-25.md
  and the vendors' documentation): libadwaita 1.6's `AdwBottomSheet` has a
  `bottom-bar` child and its documentation names music players as the case,
  1.7 lets the bar hide; `AdwToolbarView.add_bottom_bar` since 1.4; iOS 26's
  `tabViewBottomAccessory` is the Music app's mini player above the tab bar,
  collapsing into it on scroll (kaya's iOS floor is 17, so the arm is
  availability-gated and the inset form serves below); WinUI's `PersonPicture`
  clips through an `Ellipse` with an `ImageBrush`; Fluent's HC dictionary
  rebinds every fill to `SystemColorWindowColor`; Material 3's hover state
  layer is 8% of `onSurface`; `UISettings.AdvancedEffectsEnabled` is Windows'
  Transparency effects switch.
- CAPTURED 2026-10-14 (the mac, the built Rust guests at b4a99a48, each
  scene run through tools/run-leg.py with its own script plus a `settle 9000`
  where the photograph goes, docs/HACKING.md's hold recipe; the guest's own
  window shot by pid; the host idle 424 s before launch, the driver refusing
  under 60 s; both legs OK, no guest left running):
  https://claude.ai/artifact/Rg91ui9NdmkuvPuyyzjW3Z. The tints scene shows
  the whole of today's per-container colour vocabulary, five filled rows at
  the 12pt continuous radius with the platform's paired text. The netimage
  scene shows the macOS native table with its 20pt art beside one-line titles
  at NSTableView's 24pt floor, nothing rounded, nothing hovered, nothing
  selected, the stripes AppKit's own: the state Y4, Y5 and Y6 start from.
- MEASURED AT THE DEPTH 2026-10-16 (the mac, cards.steps): a synthetic
  mouse-moved event through `NSApp.sendEvent`, and `mouseMoved(with:)` sent to
  the one view with a tracking area, never fire SwiftUI's `.onHover`; an enter
  event (`NSEvent.enterExitEvent`, its tracking number the `NSTrackingArea`'s
  own pointer) sent to the tracking area's owner under the point does. So
  `hover` stays in process and the mac hover legs are not EXCLUSIVE. The
  macOS native table's tall rows never ran past the window: a scroll to the
  last of 60 parked the clip at the end of the floor's presumed document, and
  the clip moves AppKit made as the rows were measured reached the driver as
  user scrolls and dropped the anchor (document 2583 to 2895 points, clip held
  at 2129), which closed docs/deferred.md's tall-rows entry once only the
  user's own events drop it. The dark material under the 40% black reads 361C17 over the red
  cover in both appearances: dark, but carrying the art's hue, so
  `expect_fill overlay` reads the panel against the picture behind it.
- MEASURED AT THE BREADTH 2026-10-16 (GTK 4.24.0, libadwaita 1.9.2, the linux
  lane's image, x11 and wayland alike): libadwaita's own rules, read out of its
  gresource, are `.card.activatable:hover` currentColor 3% (`:active` 8%),
  `row.activatable:hover` 4% (`:active` 8%), `row:selected` the accent at 25%
  and `.osd` black at 70%; a GtkBox matches no `row` rule, so the GTK arm spells
  the row values on its own class and a card takes libadwaita's. `overflow:
  hidden` with a border-radius clips a GtkPicture's own paintable, but a table
  cell stretches the picture to its column (netimage's art cell 361x40), so a
  boxed picture is clipped where its paintable draws; a whole-window render of
  tracks' 60 rounded rows takes 1-2 ms. GTK's gradient interpolates in sRGB:
  the dark header's middle reads 4B4A46 between 747166 and 222226, white text
  8.9:1; the light one F7F4E9, black text 11.6:1. On headless sway a virtual
  pointer leaves the seat when its client exits and GTK ends the hover, so the
  wayland `hover` holds its injector as the guest's child. libadwaita's `.osd`
  over a white picture reads luminance 0.073, so the GTK overlay reading's
  ceiling is 0.08 where SwiftUI's material holds 0.06.
- Still to measure at the breadth: the quaternary fill's read-back on macOS
  13 (the depth ran on 14 and later); ~~that GTK's rounded clip on a wrapper
  reaches the `GtkPicture`'s paintable on x11 and wayland, and its cost at 60
  rows~~ (measured above: GTK's half of the gradient's space too); the WinUI `ImageBrush` route's decode
  sharing with the cache (N10's shared `BitmapImage`); the gradient's
  interpolation space per platform against the midpoint probe; `image_dominant`
  on the 600-pixel art (a coarse histogram over the decoded pixels should be
  under a millisecond beside N10's 1.2 ms decode); iOS 26's accessory frame
  as read by the dock verb and its collapse on scroll; whether a `.regularMaterial`
  overlay reads opaque under Reduce Transparency through the window's pixels;
  Windows High Contrast on the VM by hand for the gradient and the hover (no
  lane knob exists; a hand capture on the review page).

## §8: What the maintainer is asked

RULED 2026-10-15 (the maintainer: "accept all"): Y1-Y11 as recommended, and
every choice below as its recommendation: the one data colour clamped (Y2),
image grounds with text only inside an `overlay` fill (Y3), the mac hover as
the quaternary fill (Y4, shown on the review page beside the alternative),
selection as the app's state (Y4), `rounded` as the platform's medium corner
with no radius and GTK through CSS (Y6), the dock as one surface per window
with iOS 26's accessory where available (Y8), the demo following the system
appearance (Y11), both lane-time costs accepted, and `overlay` joining the
tint vocabulary.

Every ruling above is his. Nine need something only he can supply:

1. Y1, the line: grounds, pictures and states on containers and images;
   controls untouched by anything but the accent and typeface. This is the
   architectural ruling the others rest on.
2. Y2, the one data colour: a vertical gradient from one clamped colour into
   the platform's ground, the colour computed by the core from the art
   (`image_dominant`), or the gradient refused and the header left a flat
   `neutral` fill.
3. Y3, image grounds with text refused unless inside an `overlay` fill, or
   image grounds refused altogether (the artist page then keeps its picture
   as an image in a row).
4. Y4, the mac hover: the quaternary fill (recommended, Safari's tiles), or
   nothing on the mac (AppKit's own silence), or a lightened `neutral` fill.
   A visual ruling, to be shown on the review page both ways.
5. Y4, selection as the app's state (recommended) rather than kaya toggling
   it on activation.
6. Y6, `rounded` as the platform's medium corner with no radius knob
   (recommended), and the GTK route through CSS rather than `AdwAvatar`.
7. Y8, the dock as a surface attached once per window (recommended), and
   iOS 26's accessory as its phone form where available.
8. Y11, the demo's appearance: `system` (recommended, both shown on the
   review page) or `dark` as the reference is.
9. The two readings that cost lane time: the mac hover legs in EXCLUSIVE if
   the in-process route fails (a bounded idle wait per leg), and the midpoint
   contrast probe in `grounds.steps` (one more pixel per leg).

And one smaller one: whether the `overlay` tint joins the tint vocabulary
(recommended) or stays a ground-only word.
