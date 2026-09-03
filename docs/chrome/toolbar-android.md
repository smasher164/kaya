# Toolbar / chrome research — ANDROID (Jetpack Compose, Material 3)

Evidence tiers: **[DOC]** = primary platform documentation or the
library's own published source, with URL + version. **[MEASURED]** =
read out of this repo / this machine (file, cache, artifact) — stated
with the path. **[INFER]** = inference, flagged, needing a depth probe.

Report is written progressively; sections below are appended as the
research lands.

---

## 0. The versions every answer here assumes

All **[MEASURED]** from the tree and this machine's gradle cache.

| thing | pinned value | where |
|---|---|---|
| compileSdk | **35** | `android/kaya/build.gradle.kts:9`, `android/rusthost/build.gradle.kts:9` |
| targetSdk (the apps) | **35** | `android/rusthost/build.gradle.kts:15` |
| minSdk | **26** | `android/kaya/build.gradle.kts:19` |
| Compose BOM | **2024.10.01** | `android/kaya/build.gradle.kts:53` |
| → material3 resolved | **1.3.1** | `~/.gradle/caches/modules-2/files-2.1/androidx.compose.material3/material3-android/1.3.1/` |
| → compose-ui resolved | **1.7.5** | `~/.gradle/caches/.../androidx.compose.ui/ui-android/1.7.5/` |
| material3-adaptive | **1.0.0** (adaptive + adaptive-layout) | `android/kaya/build.gradle.kts:65-66` |
| material-icons core/extended | **1.7.8** (frozen; last release) | `android/kaya/build.gradle.kts:96-97 (gone)` |
| activity-compose | **1.9.3** | `android/kaya/build.gradle.kts:52` |
| AGP / Kotlin | **8.7.3 / 2.0.21** | `android/build.gradle.kts` |
| emulator system image | **`system-images;android-35;google_apis;arm64-v8a`** (Android 15) | `tools/android/run-emulator.py:114` |
| manifest theme | `@android:style/Theme.Material[.Light][.NoActionBar]`, day/night pair — **platform theme, not AppCompat, not a Material Components theme** | `android/kaya/src/main/res/values/themes.xml`, `values-night/themes.xml` |

The three validation apps differ: the Rust guest app uses
`Theme.Kaya.NoActionBar`, the JVM and Go guest apps use `Theme.Kaya`
(platform ActionBar present above the Compose surface)
**[MEASURED: the three AndroidManifest.xml files]**.

`targetSdk = 35` on an API-35 device is the edge-to-edge enforcement
combination; §Q2 covers what that does to the bar.

---

## 1. What the interpreter does TODAY (read before answering anything)

All **[MEASURED]** from
`android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt` (9266 lines).

**There is already a promotion list on this platform, and it is already
driven by the catalog.** `MPROP_PRIMARY` (spec `MENU_PROPS`, wire prop
6) is the bit; `kayaPromotedActions()` (line 9022) walks the catalog in
preorder and takes the first `MENU_PROMOTED_CAPACITY` = **2** primary
actions; `KayaMenuTopBar()` (line 8768) renders them in the M3
`TopAppBar`'s `actions` slot, then `KayaOverflowMenu()` as the third
child. The overflow's row runs are handed `promoted = promotedIds` and
skip those items, so an action is in exactly one place (line 8843,
8953).

Concretely, today:

- **The bar composable is `TopAppBar`** — the small one. Not
  `CenterAlignedTopAppBar`, not `MediumTopAppBar`, not
  `LargeTopAppBar` (KayaCompose.kt:112 is the only material3 app-bar
  import).
- **No `Scaffold`.** `KayaRoot()` (line 8430) is
  `Box(fillMaxSize().imePadding())` → `Column(fillMaxSize)` →
  `KayaMenuTopBar()` then `Box(weight(1f)) { KayaSurface() }`
  (lines 8453-8472). The bar is a sibling in a Column, so all of
  Scaffold's inset/padding plumbing is absent by construction.
- **No `scrollBehavior` argument is passed.** The `TopAppBar(...)` call
  passes `title` and `actions` and nothing else (8769-8811).
- **No bar at all when the catalog is empty** — `menuPresentation =
  "none"`, `KayaSurface()` alone (8454-8458). The bar's existence is
  the catalog's existence.
- **The overflow is fully synthesized by the interpreter**: a `Box`
  holding an `IconButton` whose content is `Text("⋮")` and a sibling
  `DropdownMenu` whose expansion is interpreter state
  (`menuOverflowOpen`), with a hand-written drill-in
  (`menuOverflowDrilled` + a `‹ label` back row) because
  `DropdownMenu` has no cascading submenu (8822-8896). **Nothing in M3
  did any of this.**
- **Enablement is one helper for every affordance**:
  `kayaMenuEffectivelyEnabled(item)` (9044) — the item AND every
  ancestor grouping node, AND `kayaRoleEnabled(role)` for standard
  commands — and it is passed to `IconButton(enabled = …)` /
  `TextButton(enabled = …)` in the bar and `DropdownMenuItem(enabled =
  …)` in the overflow. The bar button's disabled look is M3's
  (`LocalContentColor` → the disabled content alpha), not kaya's.
- **The bar's title is the nav stack's top title, else the window
  title** (8771) — kaya, not Material.
- **Sections lower to a bottom `NavigationBar`** (`KayaSectionsScaffold`,
  9188), stamped `sectionsRendered = "bar"` — `Column { Box(weight 1f)
  {…} NavigationBar{…} }`, also not a `Scaffold`. It is nested INSIDE
  `KayaSurface()` (8617-8622), so a sectioned window that also declares
  a catalog already gets kaya's `TopAppBar` above it and the M3
  `NavigationBar` below it: the promotion list has a real bar to land in
  on the sections arm too, with no new work. (A sectioned window with an
  empty catalog has no top bar, same rule as everywhere else.)

`DESIGN.md` (Compact overflow and `primary`) states the existing
contract in the maintainer's own words: *"`primary` is inert in a
regular window. It does not create a desktop toolbar, and no toolbar
materialization is planned. This one bit is an adaptive menu hint, not
the seed of a toolbar grammar."* **[MEASURED: DESIGN.md:1872 region]**
C2 is a change to that sentence, not to Android's code.

---

## 2. Q1 — what an ordered promotion list lowers to, and whether a
##    tall/extended variant exists

### The construct

An ordered promotion list lowers to the `actions` slot of
`androidx.compose.material3.TopAppBar` — which in the pinned build is a
`Function3<RowScope, Composer, Int, Unit>`, i.e. **a plain
`RowScope.() -> Unit`**. **[MEASURED: `javap` of
`androidx/compose/material3/AppBarKt.class` in
material3-android **1.3.1**; the actions parameter's erased type is
`kotlin.jvm.functions.Function3<RowScope, Composer, Integer, Unit>`]**

The row it lands in is
`Row(horizontalArrangement = Arrangement.End, verticalAlignment =
Alignment.CenterVertically)` and nothing else — no overflow, no
measurement policy of its own, no maxItems.
**[MEASURED: `javap -c` of
`AppBarKt$SingleRowTopAppBar$actionsRow$1.class`, which calls
`Arrangement.getEnd()`, `Alignment.getCenterVertically()` and
`RowKt.rowMeasurePolicy`]**

### The four variants in the pinned version, and their heights

**[MEASURED: `javap -c -constants` of the `tokens` classes inside
material3-android 1.3.1's `classes.jar` — the `double` pushed just
before `putstatic ContainerHeight`]**

| composable | token class | container height |
|---|---|---|
| `TopAppBar` | `TopAppBarSmallTokens` | **64.0 dp** |
| `CenterAlignedTopAppBar` | `TopAppBarSmallCenteredTokens` | **64.0 dp** |
| `MediumTopAppBar` | `TopAppBarMediumTokens` | **112.0 dp** |
| `LargeTopAppBar` | `TopAppBarLargeTokens` | **152.0 dp** |

All four carry `ContainerColor = ColorSchemeKeyTokens.Surface` and
`ContainerElevation = ElevationTokens.Level0` **[MEASURED: same
decompilation]** — so the bar is flat and painted `surface` by default,
with no shadow to distinguish it from the page.

`TopAppBarDefaults` exposes `MediumAppBarCollapsedHeight` and
`LargeAppBarCollapsedHeight`, and both are initialized from
**`TopAppBarSmallTokens.ContainerHeight`** — i.e. 64 dp. **[MEASURED:
`javap -c` of `TopAppBarDefaults.class`'s `static {}`]** Medium and
Large are `TwoRowsTopAppBar` under the hood: a 64 dp collapsed row plus
a second row holding the headline, which collapses to nothing.

### So: which of the four bins does the "tall variant" fall into?

**Programmatic style — but a style over the TITLE, not over the
actions, and it is NOT what the modern Android look is.** Specifically:

- It is **not the construct's default**. `TopAppBar` (small, 64 dp) is
  the default and is what Google's own guidance names for
  "screens that don't require a lot of navigation or actions"
  **[DOC: developer.android.com "App bars" Compose guide,
  https://developer.android.com/develop/ui/compose/components/app-bars —
  small: *"For screens that don't require a lot of navigation or
  actions"*; medium: *"For screens that require a moderate amount of
  navigation and actions"*; large: *"For screens that require a lot of
  navigation and actions"*]**.
- It is **not a window-level flag**. There is no Android window
  attribute that makes an app bar taller; the bar is a composable the
  app draws, and its height is a parameter (`expandedHeight: Dp`, the
  extra `float` in the `TopAppBar-GHTll3U` overload) **[MEASURED: the
  `javap` signature list]**.
- It **is a separate composable**: swapping `TopAppBar` for
  `MediumTopAppBar`/`LargeTopAppBar` is the entire mechanism.

And the important part: **Medium/Large are a headline treatment tied to
scroll collapse, not a promoted-actions treatment.** The actions slot
is identical in all four (same `Function3<RowScope,…>`); what changes
is that the title moves to a second row and the bar collapses back to
64 dp as the user scrolls. Used WITHOUT a `scrollBehavior` — which is
kaya's situation today — a `LargeTopAppBar` is simply a permanently
152 dp band with the title at the bottom of it and no collapse. That is
not "the modern Android chrome"; it is a screen that has given up 88 dp
of content to a headline it can never reclaim.

**There is no Android analogue of macOS's unified/tall toolbar at
all.** The mac tall bar exists because the title bar and the toolbar
merge into one band; Android has no title bar to merge with. What the
platform's own "modern" chrome consists of is: the 64 dp `TopAppBar`,
drawn `surface`-coloured, sitting under a transparent status bar with
the status-bar inset absorbed into its own height. Which is exactly
what kaya draws today.

---

## 3. Q2 — what comes automatically from the list alone, and what
##    does not

### Comes for free (the platform/library does it)

1. **Layout and alignment of the action row.** `Arrangement.End`,
   vertically centred, in the bar's content area, with the title
   inset kept clear (`TopAppBarTitleInset`, a private constant in
   `AppBarKt`). **[MEASURED: `javap` of `AppBarKt`]**
2. **Container colour + shape + content colour.** `TopAppBar` composes
   a `SurfaceKt.Surface(...)`, so the bar paints `colorScheme.surface`
   at elevation Level0 and provides the matching content colour to
   everything in it, including the action icons. **[MEASURED: the
   `SurfaceKt."Surface-T9BRK9s"` reference inside `SingleRowTopAppBar`]**
3. **The status-bar inset.**
   `TopAppBarDefaults.windowInsets` = `WindowInsets.systemBars.only(
   WindowInsetsSides.Horizontal + WindowInsetsSides.Top)`.
   **[MEASURED: `javap -c` of `TopAppBarDefaults.getWindowInsets`,
   which calls `SystemBarsDefaultInsets_androidKt
   .getSystemBarsForVisualComponents` (itself just
   `WindowInsets.systemBars` **[MEASURED: `javap` of that class]**)
   then `WindowInsetsSides.Horizontal + Top` then `WindowInsets.only`]**
   This is the whole "the bar gets taller and the content sits below
   the status bar" behaviour, and kaya gets it without asking, because
   the default argument is used.
4. **Disabled rendering of an action.** `IconButton(enabled = false)`
   drops the content colour to the disabled alpha and stops the click
   — standard M3.
5. **The icon's accessible description** — because kaya passes one
   (`Icon(contentDescription = symbolName(symbol))`,
   KayaCompose.kt:8726). Material provides the plumbing, kaya provides
   the string.
6. **Ripple / touch target / min size** on each `IconButton`.

### Does NOT come automatically (someone must write it)

1. **OVERFLOW. There is none, at this version.** Confirmed twice over:
   - `AppBarRow`, `AppBarColumn`, `AppBarOverflowIndicator` and
     `AppBarMenuState` are **absent from material3 1.3.1's
     `classes.jar`** — a `unzip -l | grep -iE
     'AppBarRow|AppBarColumn|AppBarOverflow|AppBarMenuState'` returns
     nothing. **[MEASURED]**
   - They were added during the 1.4.0-alpha series: *"An `AppBarRow`
     composable was added, handling overflow of items that would fit
     outside its bounds"*, with `maxItemCount` added later *"which is
     necessary to correctly implement the material spec for top app
     bars"*, and `AppBarColumn` after that. **[DOC: androidx
     compose-material3 release notes,
     https://developer.android.com/jetpack/androidx/releases/compose-material3
     — reported as 1.4.0-alpha13 for `AppBarRow`; treat the exact alpha
     number as [INFER] and the "1.4.0-alpha series, not 1.3.x" as
     [DOC]]**
   - `AppBarRow`'s signature is
     `AppBarRow(modifier, overflowIndicator: @Composable
     (AppBarMenuState) -> Unit = { AppBarOverflowIndicator(it) },
     maxItemCount: Int = Int.MAX_VALUE, content: AppBarRowScope.() ->
     Unit)`. **[DOC: composables.com's generated API page for
     AppBarRow, https://composables.com/docs/androidx.compose.material3/material3/components/AppBarRow]**

   So on the pinned version, if the actions row is too wide, it is a
   `Row` with `Arrangement.End` and no wrap — the leading children get
   squeezed or pushed out of the bar's bounds. Nothing collects them
   into a menu. **The interpreter must synthesize the ⋮ menu itself,
   and it already does** (`KayaOverflowMenu`, KayaCompose.kt:8822 —
   an `IconButton` + a `DropdownMenu` + hand-written drill-in
   navigation, because `DropdownMenu` has no cascading submenus
   either). **[MEASURED: KayaCompose.kt]**
   This is the same shape as the iOS arm's synthesized More menu; the
   two platforms differ in spelling, not in who does the work.

2. **Enablement PROPAGATION.** There is no catalog object in Compose
   and therefore nothing to propagate from. Every `IconButton` is
   handed `enabled = kayaMenuEffectivelyEnabled(item)` by the
   interpreter (KayaCompose.kt:8780). One source of truth is a kaya
   property, held by kaya's one helper; C2's *"for free, on every
   platform"* is true of kaya's model and false of the platform.

3. **Any geometry change from having promoted actions.** The bar is
   64 dp with zero actions and 64 dp with three. Height on Android is a
   function of the variant and the status-bar inset, never of the
   action count. **[MEASURED: the token heights; the actions row is
   laid out inside the fixed container height]**

4. **Scroll-edge / on-scroll colour change.** Present in M3, but ONLY
   when a `scrollBehavior` is supplied. In the pinned source the
   colour crossfade is driven by
   `colorTransitionFraction = scrollBehavior?.state?.overlappedFraction
   ?: 0f`, then `if (fraction > 0.01f) 1f else 0f`.
   **[MEASURED: `javap -c` of
   `AppBarKt$SingleRowTopAppBar$colorTransitionFraction$2$1.invoke()`
   — the bytecode is literally `ifnull → fconst_0`, then
   `ldc 0.01f; fcmpl`]**
   kaya passes no `scrollBehavior` (KayaCompose.kt:8769-8811), so the
   fraction is pinned at 0 and the bar's container colour never moves.
   The pinning/collapse behaviours (`pinnedScrollBehavior`,
   `enterAlwaysScrollBehavior`, `exitUntilCollapsedScrollBehavior`) are
   likewise all app-declared, and each additionally requires the app to
   hang `Modifier.nestedScroll(scrollBehavior.nestedScrollConnection)`
   on an ancestor of the scrolling content. **[DOC: the Compose app
   bars guide, same URL as above, shows exactly that `Scaffold(modifier
   = Modifier.nestedScroll(scrollBehavior.nestedScrollConnection))`
   line]** **[MEASURED: `TopAppBarDefaults` exposes the three
   behaviours and nothing installs them for you]**

5. **Icon + LABEL on a bar action.** M3's small top app bar has no
   icon-with-caption idiom; a trailing element is an icon button, a
   button, or an avatar. kaya's arm reflects this by choosing
   *either* an `IconButton` *or* a `TextButton`, never both
   (KayaCompose.kt:8783-8807). NSToolbar's icon+label mode has no
   counterpart here.

6. **A long-press tooltip naming the action.** The View system's
   `ActionMenuItemView` shows the title on long press; Compose's
   `IconButton` does not — `IconButtonKt` in the pinned aar contains
   **zero** references to tooltip **[MEASURED: `javap -c … | grep -ic
   tooltip` → 0]**. Reaching it needs `TooltipBox`, written by hand.

7. **Content padding for the bar's height.** kaya sidesteps this by
   putting the bar and the content in a `Column` rather than using
   `Scaffold` (KayaCompose.kt:8468-8471). Worth stating because it is
   the one place M3 would otherwise "do it for you": *"App bars are
   generally passed to the `Scaffold` composable"*, which supplies
   `innerPadding` accounting for the bar **[DOC: the Compose app bars
   guide]**.

### The edge-to-edge interplay, on the exact level the tree pins

`targetSdk = 35` **[MEASURED: android/rusthost/build.gradle.kts:15]**
running on `system-images;android-35` **[MEASURED:
tools/android/run-emulator.py:114]** is precisely the enforcement
combination: *"Apps are edge-to-edge by default on devices running
Android 15 if the app is targeting Android 15 (API level 35)"*, the
status bar is transparent, *"the top offset is disabled so content
draws behind the status bar unless insets are applied"*, and
`setStatusBarColor` / `R.attr#statusBarColor` are deprecated and inert.
**[DOC: https://developer.android.com/about/versions/15/behavior-changes-15]**
A per-app opt-out attribute `R.attr#windowOptOutEdgeToEdgeEnforcement`
exists on Android 15 and is deprecated-and-disabled for apps targeting
API 36. **[DOC: https://developer.android.com/about/versions/16/behavior-changes-16]**
kaya does not set it **[MEASURED: neither themes.xml declares it]**.

The consequence is the good one: **the modern Android chrome is the
zero-knob path.** Because kaya draws a `TopAppBar` with its default
`windowInsets`, the bar absorbs the status-bar inset, paints
`colorScheme.surface` up to the physical top of the screen, and the
system's status-bar glyphs sit over kaya's own bar. That is the genre
look, produced by the bar's default arguments plus the platform's
enforcement — no chrome prop, no style enum, nothing declared.

Two open items a depth probe should confirm, flagged rather than
asserted:

- **[INFER]** The two validation apps that use `Theme.Kaya` (with the
  platform ActionBar — the JVM and Go guests **[MEASURED: their
  manifests]**) put a framework ActionBar above the Compose surface, so
  that leg shows the platform bar AND kaya's `TopAppBar`. Whether
  Compose then still sees a non-zero top inset (the ActionBar may have
  consumed it in the decor's dispatch) decides whether kaya's bar is
  64 dp or 64+status there. Not measured; needs the emulator.
- **[INFER]** Nothing in kaya applies the BOTTOM system-bar inset
  (`KayaRoot` applies only `imePadding()`, KayaCompose.kt:8453), so
  under enforced edge-to-edge the gesture/3-button nav bar overlaps the
  bottom of the content — and specifically the sections
  `NavigationBar` (KayaCompose.kt:9203), which has its own default
  `windowInsets` in M3 and probably handles itself, while a plain
  scene's last row does not. This is a pre-existing chrome bug
  independent of C2; docs/layout-survey.md:138 already ledgered "a
  future edge-to-edge/insets pass".

---

## 4. How many actions fit, and what M3 says

**[DOC: M3 guidelines, https://m3.material.io/components/app-bars/guidelines
— NOTE ON RETRIEVAL: that page renders its body from JavaScript and a
direct fetch returns only the `<title>`; the sentences below came back
through search extraction of the same URL. Treat the wording as [DOC]
and the exactness of the punctuation as [INFER].]**

> "You can place up to three trailing elements on mobile and up to four
> elements on tablet on the right side of the app bar."

> "Use an overflow menu if there are more than three icon buttons on
> mobile and four icon buttons on tablet."

> Trailing icons "can be action icons, buttons, and an overflow menu or
> a profile, and should be arranged in order of importance from left to
> right."

kaya's `MENU_PROMOTED_CAPACITY = 2` plus the ⋮ anchor is exactly three
trailing elements on a phone, which is the guidance's ceiling — and the
comment at KayaCompose.kt:1018-1025 already says so in those words.
**[MEASURED]**

The tablet number (four) is the one thing the current arm leaves on the
table: `MENU_PROMOTED_CAPACITY` is a `const val`, not a function of
`KayaSceneModel.formFactor` (which the interpreter already computes at
KayaCompose.kt:8438 from the 600 dp boundary). If the maintainer wants
promotion to be adaptive on Android, that is a two-line change *inside
the interpreter*, needing nothing from the protocol — the capacity is
"this platform's own idiom" by DESIGN.md's own rule, and a platform is
allowed to make its idiom depend on its own size class. Recording it
here so it is a deliberate choice rather than an oversight.
**[INFER: no scene asserts a promoted count today, so nothing breaks
either way.]**

---

## 5. Q3 — is an 'extended' knob NEEDED to reach the genre look?

**No. On Android the genre look is the default result of having the
bar, and an `extended` knob would be actively wrong.**

The argument, in three measured steps:

1. **The modern Android chrome IS the 64 dp `TopAppBar`.** Google's own
   guidance sends "screens that don't require a lot of navigation or
   actions" to the small bar **[DOC: the Compose app bars guide]**, and
   a window whose chrome is "a title and two promoted actions" is that
   screen by definition. Medium and Large exist to give a page a large
   HEADLINE, which is a typographic decision about the title — a thing
   C1 explicitly refuses to let apps control ("title fonts" are in the
   refused list, chrome-plan.md:67-69).

2. **The tall look mac gets from a toolbar has no Android
   counterpart.** macOS's `.unified` NSToolbar merges with the title
   bar; Android has no title bar. There is no "unified" mode, no
   `fullSizeContentView`, no window-level flag of any kind. The height
   is a composable's parameter and nothing else.
   **[MEASURED: the `TopAppBar-GHTll3U` signature — the height is a
   `float` argument]**

3. **The one genuinely modern thing — content running to the physical
   top edge under a transparent status bar — kaya already has, for
   free, and could not switch off if it wanted to.** `targetSdk 35` on
   API 35 enforces edge-to-edge **[DOC: Android 15 behaviour changes]**
   and `TopAppBarDefaults.windowInsets` absorbs the status bar into the
   bar **[MEASURED: the bytecode]**. So Android's answer to C1's
   `chrome: extended` is not "no-op because phones have no title bar"
   (chrome-plan.md:48) but something stronger and worth writing down:
   **Android is already in the extended state, permanently, by platform
   mandate.** A `chrome` prop on this platform would be a knob whose
   `standard` value is unreachable.

What an `extended` knob WOULD buy on Android if it were wired to
Medium/Large, and why it is a bad trade: 48 dp (medium) or 88 dp
(large) of content surrendered to a bigger copy of the title, which
only pays for itself if the bar also collapses on scroll — which needs
a `scrollBehavior`, which needs `Modifier.nestedScroll` on an ancestor
of the scrolling content, which is a behaviour kaya would then own and
have to keep true across `KIND_SCROLL` (`Modifier.verticalScroll`,
KayaCompose.kt:6989 — it does participate in nested scroll, so this is
buildable, just not free) plus `KIND_TEXTAREA` plus
`ListDetailPaneScaffold`'s panes. A styling knob that drags a scroll
contract behind it is not a styling knob.

---

## 6. Q4 — can kaya reach the look with ZERO new styling vocabulary?

**On Android: yes, and it already has, since before this plan was
written.** Nothing in C2 requires a new Android styling word. What C2
changes on this platform is which SIGNAL selects the promoted set:

| | today | under C2 |
|---|---|---|
| what promotes | `primary: true` on a catalog item (`MPROP_PRIMARY`) | the window's ordered promotion list |
| order | catalog preorder, platform-chosen | the app's list order |
| how many | `MENU_PROMOTED_CAPACITY = 2`, platform-chosen | still platform-chosen (the list must be clamped) |
| where the rest goes | the synthesized ⋮ | unchanged |
| enablement / label / icon / handler | the item's own | unchanged |
| the lowering | `TopAppBar` `actions` slot | **identical** |

So the Android arm's diff for C2 is roughly: replace
`kayaPromotedActions()`'s "walk the catalog, take primaries" body with
"read the window's promotion list, resolve ids, take the first k" —
maybe fifteen lines — and delete nothing else. **[INFER, but a
well-supported one: the render, the overflow exclusion, the enablement
helper and the activation route all key on `KayaMenuItem`, not on how
the item got promoted.]**

### Riding constructs kaya already has

- **The promotion list itself** carries the entire Android
  materialization. Label, symbol, enabled signal and handler are the
  item's; the bar is `TopAppBar`; the remainder is the ⋮.
- **The sectioned-sidebar presentation** needs nothing: sections lower
  to a bottom `NavigationBar` nested inside `KayaSurface`, with the top
  bar above it, so promotion and sections compose without a rule.
- **The command catalog** is the whole action model; "no second action
  system" is already true on Android and is the reason this arm is
  cheap.

### Knobs that would be NO-OPS on Android — the maintainer's list

1. **`chrome: standard | extended` (C1) — a no-op, and worse than a
   no-op: `standard` is unreachable.** Android has no title bar to run
   content under, and edge-to-edge is already mandatory at
   targetSdk 35. Marking it "no-op — phones have no title bar"
   (chrome-plan.md:48) understates it; the honest row is "the platform
   is permanently in the state this prop's non-default value asks
   for". **[DOC + MEASURED as above]**
2. **`title_hidden` (C1b) — a no-op with a twist.** There is no title
   bar to hide, and the app switcher's label comes from the manifest's
   `android:label`, never from `windowTitle`. But kaya's `TopAppBar`
   DOES draw a title (KayaCompose.kt:8771), so a `title_hidden` prop
   would have a visible effect here that has nothing to do with what it
   means on macOS. A knob that means "hide the window's chrome title"
   on one platform and "empty the app bar's title slot" on another is
   two features wearing one name.
3. **Any bar-height / bar-style enum (`toolbar_style: unified | expanded
   | compact`, or `extended` on the toolbar itself)** — reachable on
   Android only by swapping in Medium/Large, which is a title
   treatment, and which is dead weight without scroll collapse (§5).
   Refuse.
4. **A scroll-edge / material / translucency knob** — M3 has the
   behaviour (`scrolledContainerColor` driven by
   `overlappedFraction`), but it is a *behaviour* the app opts into by
   supplying a `scrollBehavior` and wiring nested scroll, not a look
   the app declares. If kaya ever wants it, the right shape is "kaya
   always wires the platform's own scroll-edge behaviour, on every
   backend that has one" — a lowering decision with no app-facing
   vocabulary at all — not a prop.
5. **Per-item placement / free-form widgets in the bar** — already
   refused in the draft (chrome-plan.md:112-117), and Android agrees:
   the actions slot is a plain `Row` with no leading/trailing sections
   and no overflow, so any placement grammar would be kaya
   re-implementing layout the platform does not offer.

### The one thing C2's OBSERVATION section gets wrong for Android

`expect_toolbar_item i "label"` is specified as *"the platform's own
accessibility name for the button"* (chrome-plan.md:108-109). On
Android today that name is **the symbol's semantic name, not the item's
label**: the bar button is
`IconButton { KayaSymbolIcon(item.symbol) }` and `KayaSymbolIcon`
passes `contentDescription = symbolName(symbol)` — so a promoted
`File>Save` whose symbol is `done` reads back as **`"done"`**, not
`"Save"`. **[MEASURED: KayaCompose.kt:8783-8790 and 8724-8727]** The
`TextButton` fallback (item with neither symbol nor icon blob) reads
back as the label; the icon-blob arm reads back as the label
(`Image(contentDescription = item.label)`, 8797). Three arms, three
different accessible names.

Given invariant 6 (scene scripts shared verbatim, expected strings
compared byte-for-byte), this must be settled BEFORE the verb is
written.

**And the obvious fix is a trap — I checked, and it would turn an
existing green assertion red.** "Just put the label on the button"
breaks `expect_menu_symbol`, which is already asserted against a
PROMOTED item today: `kayaMenuSymbolRead` (KayaCompose.kt:4411) reads
`SemanticsProperties.ContentDescription` off the merged node carrying
`kaya:menu#<id>`, `joinToString(" ")`s it, and REJECTS anything that is
not one of the twenty symbol names; `kayaPresentMenuRow` (4443)
short-circuits for promoted items precisely because *"a promoted
primary is a real bar action — composed whenever the bar is"*. The
menus scene promotes `File>Share`, then moves the hint to
`Document>Publish` and asserts `expect_menu_symbol "Document>Publish"
"copy"` on the bar button **[MEASURED: tools/scenes/menus.steps:73
("the primary hint moves from Share to Publish") and :79, plus the
KayaCompose sources above]**. Since a merged node has ONE
content-description list, adding "Save" alongside "done" yields
`"Save done"`, which that reader rejects by design.

So the recommendation for the verb is different, and I think better:
**`expect_toolbar_item i "<catalog path>"`, not `i "<label>"`.** Give
the verb the same path the rest of the menu verbs take
(`"File>Save"`), resolve it to an item id, and assert that the i-th
tagged affordance in the REAL bar subtree is that item's tag. It reads
the composed tree (not the promotion list echoed back), it is
byte-identical in a shared scene because the argument is the catalog
path rather than any rendered string, and it survives the fact that
the three platforms legitimately give the same button three different
spoken names. Spoken names stay covered where they already are:
`expect_menu_symbol` for symbol-bearing items, and the a11y verbs for
the rest.

Separately, and independent of the verb: a TalkBack user on a promoted
icon-only action hears **"done"** rather than **"Save"** today. That is
a real accessibility question for the maintainer — it is the glyph's
name, not the command's — but fixing it means moving the symbol
observation onto a different surface first, so it is a decision, not a
one-liner. **[MEASURED, and flagged rather than recommended.]**

---

## 7. The four answers, short

**Q1 — construct + tall variant.** An ordered promotion list lowers to
the `actions` slot of M3 `TopAppBar`, which is a plain
`RowScope.() -> Unit` **[MEASURED: material3 1.3.1 bytecode]**. A
tall variant exists as a **separate composable** — `MediumTopAppBar`
(112 dp) / `LargeTopAppBar` (152 dp) against small's 64 dp
**[MEASURED: the token constants]** — i.e. a *programmatic style*, and
neither a construct default nor a window flag. But it is a treatment of
the TITLE (a second row holding a headline, collapsing back to 64 dp on
scroll), not of the promoted actions, and Android has **no** analogue
of the mac unified/tall toolbar, because there is no title bar to
unify with. Nearest honest bin for "the mac tall bar": **nonexistent**.

**Q2 — automatic vs not.** Free: the End-aligned action row; the
`surface` container colour, shape and content colour via `Surface`;
the **status-bar inset** (`TopAppBarDefaults.windowInsets =
systemBars.only(Horizontal + Top)`) which is the whole edge-to-edge
story; disabled rendering of an `IconButton`; ripple and touch
targets. Not free: **overflow — there is none in 1.3.1 at all**
(`AppBarRow`/`AppBarColumn`/`AppBarOverflowIndicator` are absent from
the pinned aar and arrived in the 1.4.0-alpha series), so the
interpreter synthesizes the ⋮ menu and already does; enablement
propagation (kaya's helper, not the platform's); any geometry change
from the action count (there is none — 64 dp with 0 actions and with
3); scroll-edge colour change and pinning/collapse, all of which need
an app-supplied `scrollBehavior` plus `Modifier.nestedScroll`; icon+label
on one bar button (no such M3 idiom); a long-press tooltip naming the
action (`IconButton` has zero tooltip code); and content padding for
the bar's height (kaya uses a `Column`, not `Scaffold`).

**Q3 — is an 'extended' knob needed?** No, and it should be refused.
The genre look on Android is the small bar under a transparent status
bar, which is what having the bar gives you; `targetSdk 35` on API 35
makes edge-to-edge mandatory, so **Android is permanently in the state
C1's `extended` asks for and cannot express `standard` at all**.
Wiring `extended` to Medium/Large would trade 48-88 dp of content for
a bigger title and would only make sense with a scroll-collapse
contract kaya does not have.

**Q4 — zero new vocabulary?** Yes. Android needs nothing new: the
promotion list replaces the `primary` bit as the selection signal, the
lowering is byte-for-byte the same `TopAppBar` actions slot, and the
sections arm already composes under the same top bar. The knobs to
eliminate, from this platform's side: **`chrome: standard | extended`**
(no-op, and its `standard` value is unreachable here),
**`title_hidden`** (no title bar; and it would mean something different
here than on mac), **any toolbar height/style enum** (only reachable
via Medium/Large, which is a title treatment), and **any scroll-edge /
material / translucency prop** (a lowering decision on every backend
that has one, never an app-facing word).

---

## 8. What a depth slice on Android must actually probe

Small list, because most of this arm already exists.

1. **The `Theme.Kaya` (ActionBar) legs.** Do the JVM and Go validation
   apps show a framework ActionBar above kaya's `TopAppBar`, and does
   Compose still see a non-zero top inset there? **[INFER today]**
   Either answer is fine for C2, but a two-bar screenshot is a bad
   look for the chrome pass and the fix is a manifest line.
2. **The bottom inset.** Under enforced edge-to-edge nothing in
   `KayaRoot` applies the navigation-bar inset (only `imePadding()`).
   Pre-existing, ledgered at docs/layout-survey.md:138, and the chrome
   pass is the natural moment.
3. **Promotion capacity on a tablet.** `MENU_PROMOTED_CAPACITY` is a
   `const val 2`; M3 allows four trailing elements on a tablet and the
   interpreter already computes `formFactor`. Decide deliberately.
4. **The observation's identity read** (§6): `expect_toolbar_item i
   "<catalog path>"` against the real bar subtree's tag order, rather
   than a spoken-name string that cannot be uniform across platforms.
5. **Order.** If the promotion list is ordered, the Android arm must
   render it in the app's order, not preorder — trivial, but it is the
   ONE behaviour change C2 makes to this platform, so the scene should
   assert an order that differs from catalog preorder or the change is
   untested.
