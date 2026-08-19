# Semantic icon names — the Material (Compose) column

Platform: Android / Compose, `androidx.compose.material.icons.Icons.*`.
Target artifact: **material-icons-core 1.7.8 + material-icons-extended
1.7.8** — the frozen final versions (§1).

Every row below is [VERIFIED]. Nothing here is from memory.

## §0 — how these were verified

Two independent sources; where they disagree the artifact wins.

1. **The artifact itself** (primary, and it is the exact artifact kaya
   would ship). Downloaded from Google Maven and enumerated
   class-by-class:
   - `material-icons-core-android-1.7.8.aar`
   - `material-icons-extended-android-1.7.8.aar`
   The aars and their extracted class trees (178 MB) were **deleted
   after enumeration**; the derived name lists they produced are kept
   next to this report and are listed in §5, along with the URLs to
   re-fetch the aars byte-for-byte. The enumeration counts
   every `*Kt.class` under `androidx/compose/material/icons/<theme>/`,
   which is exactly one class per public icon property. Deprecation was
   read out of each class's constant pool (`kotlin/Deprecated` plus the
   `ReplaceWith` string). Glyph identity between two names was decided
   by comparing the ordered `PathBuilder` calls and float constants in
   the bytecode, not by eyeballing a catalog page.
   Measured totals:
   - core: **49** filled + **7** auto-mirrored, per theme
   - extended: **2082** filled + **138** auto-mirrored, per theme
   - the two sets are **DISJOINT** (core ∩ extended = ∅, measured):
     extended does not re-ship the core icons, it depends on core. Full
     catalog = 2131 filled names, 145 auto-mirrored names.
   - all five themes (`filled`, `outlined`, `rounded`, `sharp`,
     `twotone`) carry identical name sets in both artifacts (measured:
     2082 each in extended, 49 each in core).
2. **Public documentation / catalog listings** (web), cited per claim in
   §1 and §4, plus the live Google Fonts icon-metadata endpoint and the
   Material Symbols variable-font codepoints file (§4.4).

## §1 — platform facts that constrain the column

- **`Icons.Default` IS `Icons.Filled`.** Measured from the artifact:
  `Icons.getDefault()` has return type `Icons$Filled` and returns the
  `Default` field directly. Same for `Icons.AutoMirrored.Default`, whose
  type is `Icons$AutoMirrored$Filled`. So `Icons.Default.X` and
  `Icons.Filled.X` are the same property, and
  `Icons.AutoMirrored.Default.X` = `Icons.AutoMirrored.Filled.X`. The
  table gives the `Default` spelling as asked, and the `AutoMirrored`
  rows are written `Icons.AutoMirrored.Filled.X` because that is the
  spelling the deprecation `ReplaceWith` blocks emit.
- **1.7.8 is the last version, and that is confirmed twice.** Google
  Maven's `maven-metadata.xml` for `material-icons-extended` ends at
  `1.7.8` with `<lastUpdated>20250212180149</lastUpdated>`; the Compose
  Material release notes date **Version 1.7.8 — February 12, 2025**.
  The two agree to the day. The androidx `material.icons` packages are
  not being published beyond this.
- **The auto-mirrored split arrived in 1.6.0-alpha05** (2023-09-06).
  Release-note text, quoted: *"Icons in the material-icons-core and
  material-icons-extended modules are now providing additional icon sets
  for supporting auto-mirroring when the icon allows it. The new sets
  are prefixed with `Icons.AutoMirrored.Filled...` etc. … The previously
  provided icon properties for those icons are now marked as
  deprecated, and provides a replacement-block suggestion to help with
  the migration."* Measured against the artifact: 7 deprecated filled
  properties in core, 138 in extended, each carrying a `ReplaceWith`
  pointing at its `Icons.AutoMirrored.Filled.*` twin.
- **There is NO OS version gate on any of this.** The icons are Kotlin
  `ImageVector` builders compiled into the app, not platform assets. The
  extended aar's manifest declares `minSdkVersion="21"`; kaya's Android
  floor is API 26, comfortably above. Nothing in this column needs an
  API-level check. The gating that exists is *library* version, and the
  library is frozen, so the whole column is stable by construction.
- **License: Apache-2.0** (`<licenses>` block of the 1.7.8 pom). This
  matters for the option in §5: the vectors may simply be copied into
  kaya's own Kotlin.
- **Google's own artifact metadata warns against depending on
  extended.** The 1.7.8 pom `<description>`, verbatim: *"Compose
  Material Design extended icons. This module contains all Material
  icons. It is a very large dependency and should not be included
  directly."* The aar is 35.7 MB (measured).
- **The repo does not depend on either module today.** Measured:
  `android/kaya/build.gradle.kts` names neither; the only icons artifact
  in the gradle cache is `material-icons-core-android` **1.7.5**, pulled
  transitively by `material3` via `compose-bom:2024.10.01`. Slice 2 must
  add an explicit dependency, and pinning it (check-pins) is the
  moment to write `1.7.8` down.

## §2 — the mapping table

`CORE` = ships in material-icons-core (already on the classpath
transitively). `EXT` = needs material-icons-extended added.

| kaya concept | Compose identifier | artifact | Material name | notes |
|---|---|---|---|---|
| add | `Icons.Default.Add` | CORE | `add` | plus sign. |
| remove | `Icons.Default.Remove` | **EXT** | `remove` | minus sign. |
| delete (trash) | `Icons.Default.Delete` | CORE | `delete` | trash can; catalog tags include bin/can/trash. Outline: `Icons.Outlined.Delete` (CORE) or `Icons.Default.DeleteOutline` (EXT). |
| edit (pencil) | `Icons.Default.Edit` | CORE | `edit` | **Measured: byte-identical path to `Icons.Default.Create`** (34/34 identical float constants) — Material spells one pencil under two names. Use `Edit`. |
| done (checkmark) | `Icons.Default.Done` | CORE | `done` | **Measured: same checkmark as `Icons.Default.Check`**, differing only in rounding (16.2 vs 16.17, 4.8 vs 4.83) and one extra closing `lineTo`. Material's split is semantic: `done` = action completed, `check` = selection/navigation. Google tags `done` `DISABLE_IOS` (§4.3). |
| close (x) | `Icons.Default.Close` | CORE | `close` | **Measured: byte-identical path to `Icons.Default.Clear`** (28/28 constants). |
| search (magnifier) | `Icons.Default.Search` | CORE | `search` | not RTL-mirrored, and correctly so — `search` is absent from Google's mirror list. |
| share | `Icons.Default.Share` | CORE | `share` | the Android three-node share glyph. `Icons.Default.IosShare` (EXT) is the Apple box-and-up-arrow — wrong for this column, useful to know the Apple column's shape has a Material twin. |
| settings (gear) | `Icons.Default.Settings` | CORE | `settings` | cog. NOT `Icons.Default.Build`, which is a wrench. |
| save | `Icons.Default.Save` | **EXT** | `save` | exists, but it is a **floppy disk** (catalog tags: `disk`, `floppy`). Idiomatically weak on Android — see §3.2. Alternatives: `Icons.Default.SaveAlt` (EXT, tray + down arrow), `Icons.Default.Download` (EXT). |
| open (folder) | `Icons.Default.FolderOpen` | **EXT** | `folder_open` | open folder. If the concept means "open a document", `Icons.Default.FileOpen` (EXT) is the page-with-arrow and reads better. Closed folder is `Icons.Default.Folder` (EXT). None of the three is in core. |
| refresh (arrows) | `Icons.Default.Refresh` | CORE | `refresh` | single circular arrow. Two-arrow loops, all EXT: `Sync`, `Autorenew`, `Cached`. |
| info | `Icons.Default.Info` | CORE | `info` | filled circle-i. **`InfoOutline` does not exist** (measured absent from both artifacts) — the outline is `Icons.Outlined.Info` (CORE). |
| warning | `Icons.Default.Warning` | CORE | `warning` | filled triangle-!. Outline: `Icons.Outlined.Warning` (CORE) or `Icons.Default.WarningAmber` (EXT). |
| error | `Icons.Default.Error` | **EXT** | `error` | filled circle-!. Note the asymmetry: info and warning are core, **error is not**. Outline: `Icons.Default.ErrorOutline` (EXT). |
| back (chevron) | `Icons.AutoMirrored.Filled.ArrowBack` | CORE | `arrow_back` | Android's back affordance is an **arrow**, not a chevron. Auto-mirrored, not deprecated. For a literal chevron that still flips in RTL: `Icons.AutoMirrored.Filled.KeyboardArrowLeft` (CORE) or `Icons.AutoMirrored.Filled.NavigateBefore` (EXT). **Do NOT use `Icons.Default.ChevronLeft`** — §3.1. `Icons.Filled.ArrowBack` (no `AutoMirrored`) is deprecated. |
| forward (chevron) | `Icons.AutoMirrored.Filled.ArrowForward` | CORE | `arrow_forward` | mirror image of the row above; same three alternatives (`KeyboardArrowRight` CORE, `NavigateNext` EXT), same warning about `Icons.Default.ChevronRight`. |
| menu (hamburger) | `Icons.Default.Menu` | CORE | `menu` | symmetric, so no mirroring needed and none offered; `menu` is correctly absent from Google's RTL list. |
| more (ellipsis) | `Icons.Default.MoreVert` | CORE | `more_vert` | vertical three dots — the Android overflow. Horizontal is `Icons.Default.MoreHoriz` (EXT). **`Icons.AutoMirrored.Filled.More` is a trap**: `more` is a different glyph (a tag/label shape), not an ellipsis button. Google tags both `more_vert` and `more_horiz` `DISABLE_IOS`. |
| copy | `Icons.Default.ContentCopy` | **EXT** | `content_copy` | two stacked pages. |
| paste | `Icons.Default.ContentPaste` | **EXT** | `content_paste` | clipboard. |
| star (favorite) | `Icons.Default.Star` | CORE | `star` | filled five-point star. **Measured: byte-identical path to `Icons.Default.Grade`** (EXT). Outline: `Icons.Outlined.Star` (CORE) or `Icons.Default.StarBorder` (EXT). **The concept name conflates two Material concepts** — see §3.3; if kaya means *favorite*, Material's answer is the heart `Icons.Default.Favorite` (CORE, outline `FavoriteBorder` CORE). |
| lock | `Icons.Default.Lock` | CORE | `lock` | closed padlock. Open: `Icons.Default.LockOpen` (EXT). |
| person | `Icons.Default.Person` | CORE | `person` | head-and-shoulders. In a circle: `Icons.Default.AccountCircle` (CORE). Outline: `Icons.Outlined.Person` (CORE) or `Icons.Default.PersonOutline` (EXT). |
| home | `Icons.Default.Home` | CORE | `home` | house with a door. `House` and `Cottage` (both EXT) are different, more literal buildings — not this concept. |

**Count: 25 concepts, 25 mapped, 0 with no native symbol.** Six of the
25 need material-icons-extended: **remove, save, open, error, copy,
paste** (eight if the chevron spelling of back/forward is chosen via
`NavigateBefore`/`NavigateNext`). The other nineteen are satisfied by
material-icons-core, which `material3` already puts on the classpath.

## §3 — where a concept does not land cleanly

Nothing in kaya's list is missing from Material. Three concepts land
imperfectly, and each is a decision for the cross-platform table rather
than a lookup failure.

### 3.1 — "back (chevron)" / "forward (chevron)": the chevron does not mirror

This is the one real defect in the column, and it is a defect in the
artifact, not in kaya's naming.

Google's own Material Icons documentation publishes the list of icons
that *should* be mirrored in RTL, and `chevron_left` / `chevron_right`
are **on it** (verbatim from the list of 68: *"…assignment_return,
backspace, battery_unknown, call_made, … call_split, chevron_left,
chevron_right, chrome_reader_mode, device_unknown, …"*).

androidx 1.7.8 ships **no** `Icons.AutoMirrored.*.ChevronLeft` or
`ChevronRight` — measured absent from all five auto-mirrored theme
packages. So `Icons.Default.ChevronLeft` renders a left-pointing chevron
in a right-to-left layout, contradicting Material's own spec, silently.

Diffing Google's 68-name RTL list against the artifact's 145
auto-mirrored names, **7 icons that Google says should mirror have no
auto-mirrored property** (the 8th, `label_outline`, does not exist in
the artifact under any spelling):

    chevron_left, chevron_right, device_unknown, first_page,
    flight_land, flight_takeoff, functions

Consequence for kaya: if the semantic name is spelled with a chevron
glyph on Android, it must be `KeyboardArrowLeft`/`KeyboardArrowRight`
(core, auto-mirrored) or `NavigateBefore`/`NavigateNext` (extended,
auto-mirrored) — never `ChevronLeft`/`ChevronRight`. And if the name is
"back" rather than "chevron", the Android-correct answer is the arrow,
`ArrowBack`, which is what every Material top app bar uses.

### 3.2 — "save": the glyph exists, the idiom does not

`Icons.Default.Save` is real and is a floppy disk (catalog tags include
`disk`, `floppy`). Android UX generally has no explicit save control —
changes commit as they are made — so this concept will look imported on
the Android column even though the identifier is valid. Worth flagging
before the closed set is frozen: `save` may be a name that only three of
the four platforms want.

### 3.3 — "star (favorite)": two Material concepts under one kaya name

Material keeps these separate and gives them separate names, categories
and tags: `star` (a five-point star, category `toggle`/`UI actions`,
tags `add to favorite`, `grade`, `rating`) and `favorite` (a **heart**,
tags `affection`, `like`, `save`). Both are in core (`Icons.Default.Star`,
`Icons.Default.Favorite`). kaya's parenthetical treats them as one
concept, which forces a per-platform coin-flip. Recommend picking one
meaning and one glyph family for the name, or admitting both names.

## §4 — traps and version notes for slice 2

### 4.1 — the deprecated non-mirrored spellings still compile

All 145 pre-split spellings (`Icons.Filled.ArrowBack`,
`Icons.Filled.KeyboardArrowLeft`, `Icons.Filled.NavigateNext`,
`Icons.Filled.More`, …) are still present and still resolve. They only
raise a deprecation warning. A generated mapping table that writes
`Icons.Default.ArrowBack` will compile, run, and be wrong in RTL — the
exact shape of failure kaya's doctrine wants a guard for. The guard is
cheap and structural: the mapping table is generated, so make the
generator refuse any name in the 145-element auto-mirrored set unless
the emitted path starts `Icons.AutoMirrored.`. The list is in this
directory (`ext-automirrored-filled.txt`, `core-automirrored-filled.txt`)
and is frozen forever, because the library is.

### 4.2 — core vs extended is a real dependency decision

Nineteen of the 25 concepts are already reachable with zero new
dependencies. The remaining six pull in a 35.7 MB aar that Google's own
pom describes as *"a very large dependency [that] should not be included
directly"*. Since kaya needs a **closed set** of about 25 vectors, the
proportionate options are:

1. Add `material-icons-extended:1.7.8` and let R8 strip the ~2075 unused
   icons. Each icon is its own class, so shrinking does apply, but the
   dependency is still 35.7 MB of build input and its own known
   size/obfuscation complaints exist upstream.
2. **Copy the six-to-eight needed vectors into kaya's own Kotlin.** The
   artifact is Apache-2.0 (verified in the pom), the vectors are a few
   dozen float constants each, and the set never changes because the
   upstream library is frozen at 1.7.8. This also removes the version
   pin from check-pins' surface entirely.

Option 2 looks right for a closed set, but it is a dependency decision,
so it is Akhil's call, not this report's.

### 4.3 — Google's catalog flags some of these as Android-only

The Google Fonts icon metadata tags `share`, `done`, `check`,
`more_vert` and `more_horiz` with `DISABLE_IOS` — Google's own marker
that the glyph is Android-idiomatic and should not be reused on Apple
platforms. This is direct support for the names-not-bytes design: the
same kaya concept genuinely wants different art per platform, and
Google says so in the catalog data.

### 4.4 — forward compatibility with Material Symbols

The androidx library is frozen; Google's live direction is Material
Symbols. Checked against the Material Symbols variable-font codepoints
file (`MaterialSymbolsOutlined[FILL,GRAD,opsz,wght].codepoints`, 4271
names, fetched from google/material-design-icons): **every** name this
column uses — including `done`, `create`, `navigate_before`,
`navigate_next`, `star_border`, `delete_outline` — is present in
Material Symbols. So a later migration off the frozen library is
name-stable for kaya's closed set.

One correction worth recording, because it nearly went into this report
as a false claim: the `fonts.google.com/metadata/icons` JSON lists many
names **twice** (1872 duplicate names across the legacy and Symbols
entries), and reading `unsupported_families` from whichever entry a
dict-build happens to keep reports `done`, `navigate_before`,
`navigate_next` and `star_border` as absent from Material Symbols. They
are not absent; the variable font ships them. When the two sources
disagreed the font file was treated as authoritative, since it is the
asset that actually ships.

### 4.5 — the linux SVG blocker from the styling plan is unrelated here

docs/styling-plan.md D6 notes the linux container lacks
`librsvg2-common` so no SVG icon renders on that lane. That does not
touch this column: Compose icons are compiled `ImageVector` code, never
SVG at runtime. The blocker is real for the GTK column, not this one.

## §5 — sources

Primary (artifacts downloaded from Google Maven, enumerated, then
deleted — re-fetchable at the URLs below):
- `material-icons-core-android-1.7.8.aar` —
  `https://dl.google.com/dl/android/maven2/androidx/compose/material/material-icons-core-android/1.7.8/`
- `material-icons-extended-android-1.7.8.aar` — same path, `extended`
- the 1.7.8 pom (license, description, dependency on core)
- `maven-metadata.xml` for `material-icons-extended` (version list ends
  at 1.7.8; `lastUpdated` 20250212180149)
- derived name lists kept alongside this report (220 KB total):
  `core-filled.txt` (49), `core-automirrored-filled.txt` (7),
  `ext-filled.txt` (2082), `ext-automirrored-filled.txt` (138),
  `deprecated-filled.json` (the 145 deprecated properties with their
  `ReplaceWith` targets), `msym.codepoints` (Material Symbols, 4271
  names), `msym-names.txt`

Disk: the working set peaked at 191 MB and is 13 MB after cleanup, of
which this report's own files are 220 KB. The 178 MB of aars and
extracted class trees are gone; nothing was written outside this
scratchpad, and nothing in the kaya tree was touched.

Documentation:
- Compose Material release notes —
  https://developer.android.com/jetpack/androidx/releases/compose-material
  (1.7.8 dated 2025-02-12; the 1.6.0-alpha05 auto-mirrored note)
- Material Icons guide, "Which icons should be mirrored for RTL?" —
  https://developers.google.com/fonts/docs/material_icons
- Google Fonts icon metadata — https://fonts.google.com/metadata/icons
  (categories, tags, `DISABLE_IOS` markers)
- Material Symbols codepoints —
  https://github.com/google/material-design-icons (variablefont/
  `MaterialSymbolsOutlined[FILL,GRAD,opsz,wght].codepoints`)
