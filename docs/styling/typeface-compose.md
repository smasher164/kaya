# Typeface probe — Android / Compose (Material 3)

Measure-first probe for docs/styling-plan.md Slice 2b. Everything below
was measured on the lane's own emulator image; the few READ items are
marked. No repo file changes: the probe is a standalone gradle project in
the session scratchpad (`styling/typeprobe/`), deleted at the end.

## 0 — the bench

| fact | value |
| --- | --- |
| lane image | `system-images;android-35;google_apis;arm64-v8a` (tools/android/run-emulator.sh:70) |
| device | `emulator-5558`, one of the warm phone pool; API 35 / Android 15, arm64-v8a, 320x640 @ 160dpi |
| compose | BOM 2024.10.01 → ui/foundation 1.7.5, material3 1.3.1 (the versions kaya ships) |
| kaya's theme root | `KayaCompose.kt:7736 KayaTheme()`, landed in slice 1 — the typeface has a place to go |
| probe string | `Handgloves 0123`, measured at 100px in `Paint`, and as laid out on screen |
| pool | 4 emulators were ALREADY running (uptime 20d) before this probe; not started by me, not stopped by me |

---

## 1 — THE APPLY ROUTE

### The mechanism

`MaterialTheme(typography = …)` with every rung of the ramp copied
through `TextStyle.copy(fontFamily = f)`. `copy` touches one field, so
`fontSize`, `lineHeight`, `fontWeight` and `letterSpacing` stay exactly
what Material set — that is the whole of "swap the family, keep the
platform's ramp", and it is checked in §1.3 rather than asserted.

```kotlin
fun Typography.withFamily(f: FontFamily) = Typography(
    displayLarge = displayLarge.copy(fontFamily = f),
    … all 15 rungs …
    labelSmall = labelSmall.copy(fontFamily = f),
)
```

### 1.1 ONE LINE IS NOT ENOUGH — kaya needs TWO, and the measurement says why

`KayaTheme` deliberately holds `LocalTextStyle` at its PRE-theme value
(KayaCompose.kt:7739/7745) so that Material's `bodyLarge` cannot resize
every label. That decision has a consequence nobody has had to think
about until now: **the typography ramp is not what kaya's own labels
read.** Exactly one site in the interpreter reads `MaterialTheme.typography`
— KayaCompose.kt:7039, the `heading` role's `titleLarge`. Plain labels
(`KIND_LABEL -> Text(node.text, …)`) and the text field
(KayaCompose.kt:7255, `textStyle = LocalTextStyle.current.copy(color = …)`)
read `LocalTextStyle` and nothing else.

Measured, cold process per leg, family `serif`:

| reach mode | plain label | titleLarge | headlineSmall | Button label |
| --- | --- | --- | --- | --- |
| no brand (control) | 109px **Roboto** | 169px Roboto | 185px Roboto | 45px Roboto |
| `typography` only | 109px **Roboto** | 178px Noto Serif | 193px Noto Serif | 47px Noto Serif |
| `typography` + ambient family | 115px **Noto Serif** | 178px Noto Serif | 193px Noto Serif | 47px Noto Serif |

The middle row is the trap: a lowering that sets only `typography=` brands
Material's own components (buttons get it because M3's `Button` does its
own `ProvideTextStyle(labelLarge)` internally; dialog titles, list items
and the `heading` role likewise) and leaves **every kaya label and every
text field on the platform face**. Half-branded, and the scene would still
show a font change, so a coarse observation would call it applied.

**The Android arm is therefore two lines**, and the second one carries the
size restraint explicitly:

```kotlin
MaterialTheme(colorScheme = scheme, typography = base.withFamily(f)) {
    // family ONLY: fontSize stays Unspecified, so KayaTheme's whole
    // reason for holding this local survives the typeface slice.
    CompositionLocalProvider(LocalTextStyle provides ambientTextStyle.copy(fontFamily = f)) {
```

Verified, not assumed: under the swap the label's `fontSize` reads
Unspecified in every leg (`fontSize_sp: null`), identical to the control.
Only the family field moved.

### 1.2 The two ways to spell the name resolve identically

`FontFamily.Serif` (Compose's generic) and
`FontFamily(Font(DeviceFontFamilyName("serif")))` (the name route)
produced the same widths (115/178/193/47) and the same resolved file
(`/system/fonts/NotoSerif-Regular.ttf`) on every surface. Since the wire
carries an arbitrary NAME, the lowering can use `DeviceFontFamilyName`
uniformly and needs no generic-name special case — but mapping the four
generic spellings to `FontFamily.SansSerif/Serif/Monospace/Cursive` costs
nothing and is measurably equivalent.

### 1.3 The ramp does not move (this is the claim the design depends on)

`sp`, `lineHeight`, `weight` and `letterSpacing` for every sampled rung,
control vs `serif` vs `cursive` — byte-identical across all three:

| role | all three legs |
| --- | --- |
| displayLarge | 57sp / 64 lh / w400 / ls −0.2 |
| headlineSmall | 24sp / 32 lh / w400 / ls 0 |
| titleLarge | 22sp / 28 lh / w400 / ls 0 |
| bodyLarge | 16sp / 24 lh / w400 / ls 0.5 |
| bodyMedium | 14sp / 20 lh / w400 / ls 0.2 |
| labelLarge | 14sp / 20 lh / w500 / ls 0.1 |
| labelSmall | 11sp / 16 lh / w500 / ls 0.5 |

**The vertical rhythm holds too**, which is a stronger result than the
table above. Rendered line-box height / first baseline:

| leg | titleLarge | headlineSmall | label | Button |
| --- | --- | --- | --- | --- |
| control | 28/21 | 32/24 | 16/13 | 20/15 |
| serif | 28/21 | 32/24 | 16/13 | 20/15 |
| monospace | 28/21 | 32/24 | 16/13 | 20/15 |
| cursive | 28/21 | 32/**23** | **17**/13 | 20/**14** |

Because M3 pins `lineHeight` in sp, the line box is set by the ramp and
not by the face. Only the label — whose ambient style has NO specified
lineHeight, so it takes the font's intrinsic metrics — moved, and only
under Dancing Script, and only by 1px. Roboto and Noto Serif even report
identical paint metrics (ascent −92.773, descent 24.414 at 100px): they
are metric-matched.

### 1.4 Android's font scaling survives the swap

The Apple analogue of this question is "a custom family loses Bold Text
and Dynamic Type". On Android it costs nothing. With the system
`font_scale` moved 1.0 → 1.3 (read first, restored after, restore
verified):

| | 22sp titleLarge | 24sp headlineSmall | 14sp labelLarge |
| --- | --- | --- | --- |
| control @1.0 | 22px | 24px | 14px |
| serif @1.0 | 22px | 24px | 14px |
| control @1.3 | 25px | 26.4px | 18.8px |
| serif @1.3 | 25px | 26.4px | 18.8px |

Identical px for control and swapped family at both scales (the numbers
are Android 14's nonlinear scaling curve, not ×1.3 — which is exactly
why kaya must not compute sizes itself). **Family swap and font scaling
are independent on Android.** Record it as a stated non-cost.

One related fact worth carrying into the wire's semantics: **Compose
normalizes the weight**, so a weight-carrying alias cannot smuggle a
ramp change through the family name. `sans-serif-medium` measures 783px
via `Typeface.create(…, NORMAL)` but **774px** (plain regular) through
Compose's resolver at `FontWeight.Normal`. The family name cannot move
the weight; only the ramp can.

---

## 2 — THE HONEST READ

### 2.1 What NOT to use (both would have looked right)

**`TextLayoutResult.layoutInput.style.fontFamily` is the request.** It
reads back `FontListFontFamily(fonts=[Font(familyName="DeviceFontFamilyName(name=KayaNoSuchFamily-9x)"…)])`
for a family that does not exist. Pure echo.

**`Typeface.getSystemFontFamilyName()` (API 31) is ALSO a request echo**,
and this one is dangerous because it looks like a resolved-face read and
has the right type. Measured:

| requested | `getSystemFontFamilyName()` | the face that actually shaped |
| --- | --- | --- |
| `serif` | `serif` | Noto Serif |
| `georgia` | **`georgia`** | **Noto Serif** |
| `arial` | **`arial`** | **Roboto** |
| `courier new` | **`courier new`** | **Cutive Mono** |
| `KayaNoSuchFamily-9x` | `sans-serif` | Roboto |

It returns the key the Typeface was created with. For the seven alias
names on this image it names a family that does not exist as a face at
all. It is the read someone reaches for first, and `expect_typeface` must
not be built on it. (Its one honest use is §3.2's miss detector, where
only hit-vs-miss is being asked.)

### 2.2 The read that measures

Take the resolved `android.graphics.Typeface` from the composition's own
`LocalFontFamilyResolver` — the same resolver instance the render used —
shape the probe string with it, and ask the resulting glyph run which
font file it came from. Then read the family out of that file's OpenType
`name` table. Nothing in that chain can carry the requested string.

```kotlin
val tf = LocalFontFamilyResolver.current
    .resolve(style.fontFamily, FontWeight.Normal, FontStyle.Normal).value as Typeface
val paint = Paint().apply { typeface = tf; textSize = 100f }
val glyphs = TextRunShaper.shapeTextRun(PROBE, 0, n, 0, n, 0f, 0f, false, paint) // API 31
val font = glyphs.getFont(0)          // android.graphics.fonts.Font
font.file           // /system/fonts/NotoSerif-Regular.ttf
font.axes           // wdth=100.0 …  (the variable-font instance)
NameTable.read(font.buffer, font.ttcIndex).family   // "Noto Serif"
```

Measured, good request `serif`:
`Noto Serif` / `NotoSerif-Regular.ttf` / postScript `NotoSerif` /
advance 811px / ttcIndex 0 / no axes. It agrees with the render: every
surface whose measured width changed reported the changed family, and
every surface that did not, did not.

**Two limits, stated rather than discovered later.**

1. `TextRunShaper` is **API 31+**. The lane image is API 35 so an
   `expect_typeface` observation is fine, but kaya's `minSdk` is 26.
   Below 31 there is no supported way to ask which font a run used; the
   honest fallback is advance-width fingerprinting against
   `SystemFonts.getAvailableFonts()` (API 29), and below 29 the honest
   answer is "cannot tell". If the observation is harness-only this
   never bites; if it is ever a shipped app-visible read, it must say so.
2. **The family name does not always discriminate.** Android 15 ships
   Roboto as a variable font, so `sans-serif`, `sans-serif-condensed` and
   `sans-serif-medium` are all `Roboto` in the SAME FILE — they differ
   only by axes (`wdth=100` vs `wdth=75`) and advance (774 / 684 / 774).
   An `expect_typeface` that compares family names alone cannot tell
   `sans-serif` from `sans-serif-condensed`. Report the axes beside the
   name, or pick scene families that are different FILES.

### 2.3 Pixels are a supporting witness, not the primary one

Screenshots of the same state one second apart are not always
byte-identical on this image (measured: 2 of 3 matched). The stable
observable is the laid-out width from `onTextLayout`, which was
bit-reproducible across cold restarts. Use widths for the scene, pixels
for the human-facing proof.

---

## 3 — THE FALLBACK (the negative every lowering gets tested with)

### 3.1 What `KayaNoSuchFamily-9x` resolves to

```
requested             : KayaNoSuchFamily-9x
shaped family         : Roboto
subfamily             : Regular
postScript            : Roboto-Regular
file                  : /system/fonts/Roboto-Regular.ttf   ttcIndex 0
variation axes        : wdth=100.0
advance (100px probe) : 774.0      ascent -92.773   descent 24.414
getSystemFontFamilyName(): sans-serif
Typeface.create(...) === Typeface.DEFAULT : true
```

**It is pixel-identical to declaring no brand at all.** The screenshots
of `no brand`, `KayaNoSuchFamily-9x` and `Roboto` share one md5
(`8ac8a979…`), and every measured width matches to the pixel
(109/169/185/45). Compose never threw, never logged, and never
degraded — the fallback is total and silent, exactly as the plan
predicted.

### 3.2 THE MISS IS DETECTABLE AT APPLY TIME — two ways, and the obvious one fails

| candidate | verdict |
| --- | --- |
| `FontFamily.Resolver.preload(family)` | **USELESS.** Returned `ok` for every name including `KayaNoSuchFamily-9x`. The API that documents itself as throwing on a font that cannot load does not throw for a missing device family. |
| **sentinel probe** | **WORKS, exactly.** Resolve `FontFamily(Font(DeviceFontFamilyName(name)), Font(DeviceFontFamilyName("cursive")))`. Compose's `DeviceFontFamilyName` loader returns null on a miss and the family falls through, so landing on the sentinel IS the miss. True for `Roboto`, `Noto Serif`, `SERIF`, `Inter`, `KayaNoSuchFamily-9x`; false for `sans-serif`, `serif`, `monospace`, `cursive`, `arial`, `georgia`. No false positives, no false negatives on 11 names. |
| `getSystemFontFamilyName() == requested` | Works on the same 11 names, but it is a string comparison against the request and it is API 31+. Fine as a cross-check, not as the mechanism. |

This is the finding that should shape the Android arm: **the lowering can
know, at the moment it applies the family, that the family does not
exist.** That is a wall on the path nobody can avoid (invariant 3),
not one more thing to assert in a scene. Whether a bad name should be a
loud failure or a reported fallback is Akhil's call and needs to be one
rule in all four backends — but Android can implement either.

### 3.3 The deceptive cases, worth the wire's attention

- **`Roboto` is a MISS.** Android's own system face is not in the family
  map; the name is `sans-serif`. It resolves to Roboto anyway, because
  the FALLBACK is Roboto. Right pixels, wrong reason, and the day the
  fallback changes the app silently changes with it. `Noto Serif`,
  `Noto Sans`, `Roboto Flex` and `Inter` are misses in the same way.
- **Lookup is case-SENSITIVE.** `serif` hits, `Serif` and `SERIF` both
  miss and fall back to Roboto. If the wire ever normalizes case, it
  must not — or must do so per-platform, since this is an Android fact.
- **Aliases hit but rename.** `arial`/`helvetica`/`tahoma`/`verdana` →
  Roboto; `georgia`/`times`/`palatino` → Noto Serif; `courier new` →
  Cutive Mono. An app asking for `helvetica` gets Roboto, honestly
  reported.

---

## 4 — FAMILY NAMES SAFELY PRESENT ON THE LANE IMAGE

`/system/etc/fonts.xml` declares 10 named families and 24 aliases — the
entire universe `Typeface.create(name, …)` can hit. All 10 verified
resolving to distinct files:

| name | resolves to | file | advance | note |
| --- | --- | --- | --- | --- |
| `sans-serif` | Roboto | Roboto-Regular.ttf | 774 | the default; identical to no brand |
| `serif` | Noto Serif | NotoSerif-Regular.ttf | 811 | **recommended for the demo** |
| `monospace` | Droid Sans Mono | DroidSansMono.ttf | 900 | unmistakable, still legible as UI |
| `sans-serif-condensed` | Roboto @ wdth=75 | Roboto-Regular.ttf | 684 | same FILE as sans-serif |
| `serif-monospace` | Cutive Mono | CutiveMono.ttf | 915 | |
| `sans-serif-smallcaps` | Carrois Gothic SC | CarroisGothicSC-Regular.ttf | 795 | |
| `casual` | Coming Soon | ComingSoon.ttf | 741 | |
| `cursive` | Dancing Script | DancingScript-Regular.ttf | 640 | dramatic; the one face that moved the vertical metrics |
| `source-sans-pro` | Source Sans Pro | SourceSansPro-Regular.ttf | 715 | |
| `roboto-flex` | Roboto Flex | RobotoFlex-Regular.ttf | 771 | |

Aliases also verified hitting: `arial`, `helvetica`, `tahoma`, `verdana`,
`georgia`, `times`, `times new roman`, `palatino`, `baskerville`, `goudy`,
`fantasy`, `courier`, `courier new`, `monaco`, `sans-serif-thin/light/
medium/black`, `sans-serif-condensed-light/medium`, `serif-bold`,
`sans-serif-monospace`, `source-sans-pro-semi-bold`, `ITC Stone Serif`.

**Android's row in a cross-platform demo: `serif`.** It moves every
measured width, it is metric-matched to Roboto so no line box moves
(§1.3), and it reads as a deliberate brand rather than a broken render.
`monospace` is the second choice if the demo wants the change to be
unmissable. READ, not measured here: `sans-serif`/`serif`/`monospace`/
`cursive` are the AOSP-baseline names, where `source-sans-pro` and
`roboto-flex` are extras this google_apis image happens to carry — so the
first four are the ones to build a scene on.

**Confirmed on BOTH lane AVDs**, not one device: the phone pool
(`emulator-5558`, 320x640) and the tablet (`emulator-5560`, 2560x1600)
agree exactly — `serif`→Noto Serif, `monospace`→Droid Sans Mono,
`cursive`→Dancing Script all hit; `Roboto` and `KayaNoSuchFamily-9x` both
MISS and both resolve to Roboto.

CAVEAT, and it is the reason the wire's per-platform values are right:
**Android guarantees nothing beyond the generic names on arbitrary
devices.** The table above is this image. `sans-serif`, `serif`,
`monospace` and `cursive` are the four that are safe to assume anywhere.

A real cross-platform family would need the **downloadable-fonts
provider**, which IS on this image
(`com.google.android.gms/.fonts.provider.FontsProvider`, authority
`com.google.android.gms.fonts`) and would let Compose fetch e.g. a Google
Font by name. NOT measured, and it should stay out of the lane: it needs
network, adds a first-render async state, and the whole point of §3.2 is
that kaya wants a synchronous yes/no at apply time.

---

## 5 — WHAT THE ANDROID ARM SHOULD DO (from the measurements)

1. **Apply in two places, not one**: `MaterialTheme(typography = …)` for
   Material's own components, and `LocalTextStyle provides
   ambientTextStyle.copy(fontFamily = f)` for kaya's labels and fields.
   Family only on the second — the Unspecified fontSize must survive.
2. **`DeviceFontFamilyName` for the name**, with the four generic
   spellings optionally mapped to `FontFamily.SansSerif/Serif/Monospace/
   Cursive` (measured equivalent).
3. **Detect the miss at apply time** with the sentinel probe (§3.2). Do
   not use `preload`. Do not use `getSystemFontFamilyName()` as the
   resolved-family read.
4. **`expect_typeface` reads the shaped font**, family name from the
   OpenType `name` table, and should carry the variation axes beside it
   so `sans-serif` and `sans-serif-condensed` are distinguishable.
5. **The watched negative**: request `KayaNoSuchFamily-9x`, expect the
   observation to report `Roboto` (NOT the request), and expect the
   apply-time detector to say MISS. **The negative leg is VACUOUS on its
   own** and this is measured, not feared: delete the whole lowering and
   the nonsense leg still reports `Roboto`, because that is also what an
   unbranded app reports. The leg that goes red when the lowering is
   removed is the POSITIVE one (`serif` → `Noto Serif`), so the scene
   needs both and the perturbation must be watched on the positive.
6. **Ledger it**: `Roboto` and every capitalized spelling are misses.
   Whatever the scene's Android family is, it is a lowercase name from
   §4's table.
7. **Both wire forms converge on the `FontFamily` object**, not on a
   name — Android has no font registration (§6.2). Catch the bytes
   route's `IllegalStateException` at the lowering so a bad blob does not
   crash the composition while a bad name merely falls back (§6.3).

---

## 6 — THE FONT-BYTES ROUTE (plan revised mid-probe, so this was measured too)

docs/styling-plan.md grew a second form while this probe was running:
font bytes ride the wire blob channel, "the blob registers with the
platform's app-font API at startup, its family name is extracted, and
the name machinery takes over unchanged". Measured on Compose, using
`/system/fonts/NotoSerif-Regular.ttf`'s bytes — chosen because its
family name `Noto Serif` is a MEASURED MISS by name on this image (§3.3),
so a hit can only have come from the bytes.

### 6.1 It works, and it works well

Bytes → app-private file → `FontFamily(Font(File))`:

```
blob                : 246 740 bytes → /data/user/0/…/files/blob.ttf
family from the BYTES (OpenType name table, no platform call) : "Noto Serif"
Typeface.Builder(file).build()  → shaped Noto Serif from blob.ttf, advance 811
Compose Font(File), via the render's own resolver
                                → shaped Noto Serif from blob.ttf, advance 811
```

On a real surface (`setbytes`), every rung moved: label 115px,
titleLarge 178px, Button 47px, all reporting
`shaped_file = …/files/blob.ttf`. Identical widths to the `serif` NAME
route — same face — but a different file, which the honest read shows.

### 6.2 "The name machinery takes over" DOES NOT HOLD ON ANDROID

There is no app-font registry on Android. After the bytes are loaded and
in use, the extracted name still misses, both ways:

| after loading the blob | result |
| --- | --- |
| `Typeface.create("Noto Serif", NORMAL)` | Roboto, `/system/fonts/Roboto-Regular.ttf` |
| Compose `Font(DeviceFontFamilyName("Noto Serif"))` | Roboto, `/system/fonts/Roboto-Regular.ttf` |

Nothing on this platform corresponds to CTFontManager's registration.
The consequence for the design is small but must be written down: on
Android the two forms converge at the **`FontFamily` object the theme
holds**, not at a name. The lowering keeps the `FontFamily` (name-built
or file-built) and applies it identically; the extracted family name is
for the OBSERVATION only. One resolution point, one observation, one
fallback negative — still true, just one layer lower than the plan's
sentence assumes.

Second-order: `Typeface.getSystemFontFamilyName()` returns **null** for a
bytes-loaded typeface. The read that §2.1 already ruled out fails hardest
on exactly the case the new grammar adds.

### 6.3 Bad BYTES are loud where a bad NAME is silent

| | Compose | platform |
| --- | --- | --- |
| unknown family NAME | silent fallback to Roboto | silent fallback to Roboto |
| corrupt font BYTES (4 KB of junk) | **throws** `IllegalStateException: Could not load font` at resolve | `Typeface.Builder(file).build()` returns **null** |

Two things follow. First, the bytes route needs no silent-fallback
detector — it already fails loudly, and `Typeface.Builder` returning null
gives a non-throwing check for a lowering that wants to decide the
policy itself. Second, that exception fires during **resolve, inside
composition**, so an unguarded bad blob takes the app down rather than
degrading. Whatever the uniform rule is (refuse at declare time / fall
back with a reported miss), Android must catch it at the lowering, and
the two forms should not end up with different failure semantics — bad
name silent, bad bytes fatal — by accident.

### 6.4 What `expect_typeface` must carry, restated for both forms

Family name alone cannot distinguish the bytes route from the name route
when they carry the same face: `serif` and the Noto Serif blob both
report `Noto Serif` at identical widths. The observation should carry
the **shaped file** (or at least a bytes/system discriminator) beside the
family name, or the scene's bytes leg proves nothing the name leg does
not already prove.

---

## 7 — cleanup, proven

- **Probe app removed from all four devices.** `pm list packages | grep
  typeprobe` returns empty on emulator-5554/5556/5558/5560.
- **Device state restored and verified.** The only setting touched was
  `font_scale` on 5558 (1.0 → 1.3 → 1.0); read back 1.0 on both devices
  it could have reached.
- **No processes left running.** `ps | grep -iE
  "GradleDaemon|KotlinCompileDaemon|typeprobe"` is empty; the one gradle
  daemon this probe started was stopped with `gradle --stop`
  ("1 Daemon stopped") and the list is empty after.
- **Emulators untouched.** The four AVDs were already running at 20 days
  uptime before this probe and still are, same pids (1856/1859/1862/63625).
  Not started by this probe, not stopped by it.
- **Disk.** The scratch gradle project (60 MB with its build output) is
  deleted; session scratchpad went 95 MB → 36 MB. This probe's surviving
  evidence measures 388 KB (JSON, PNGs, drivers, this report).
- **App data wiped.** `/data/user/0/dev.kaya.typeprobe` — where the font
  blob was written — does not exist on any of the four devices.
- **Repo untouched.** `git status --porcelain` shows only
  `docs/deferred.md` and `docs/styling-plan.md`, both modified by other
  work — the tree was already reported dirty by this session's first
  command, before this probe wrote anything.

### Evidence kept (all under `styling/`)

`sweep.json` (23 family names × platform + both Compose routes),
`detect.json` / `detect-tablet.json` (miss detectors, both AVDs),
`read-*.json` (8 render legs), `bytes-good.json`, `bytes-corrupt.json`,
`render-*.json`, and the screenshots `shot-*.png` — including the three
that share one md5 (`shot-CONTROL_nobrand.png`,
`shot-KayaNoSuchFamily-9x-full-device.png`, `shot-Roboto-full-device.png`),
which are the silent fallback in one picture.
