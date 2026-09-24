# The compliance pass — the design pass (2026-09-21, rulings 2026-09-23)

> Three obligations every store and the EU now put on an app, none of
> which kaya has proven: text that scales to the size a low-vision user
> asks for, a layout that mirrors under a right-to-left language, and
> dates and numbers written the way the user's locale writes them. The
> roadmap item (docs/tasks-plan.md S5, the ledger's compliance line) is
> mostly PROOF — kaya already spells `start`/`end` and draws with the
> platforms' own text styles — plus the design decision the maintainer
> took on 2026-09-23 after two days of back and forth: kaya OWNS
> LOCALIZATION, the catalog and the formatting API both, and the values
> are formatted by the PLATFORM'S OWN FORMATTER, not a bundled ICU. This
> document says what each obligation means in kaya's terms, how each
> platform is driven and read, what the protocol adds, and the rulings.
> Written against 4af019b3; the §2 unknowns are measured before any arm.

## §1 THE RULE, FROM ZERO

### 1.1 What is owed, and by whom

- **Larger text.** Apple's Accessibility Nutrition Labels (App Store
  Connect, "Larger Text"): an app may claim support when "users can
  enlarge text to at least 200% or the maximum font size for the system"
  and "body text in the primary iPhone, iPad, and Mac views should
  increase in size without affecting readability through overlapping
  layouts or severe truncation"; iOS Dynamic Type "reaches sizes larger
  than 200% at AX3 size, and allows body text sizes over 300% at AX5".
  The overview page says in one line: "This label isn't supported on
  Mac." WCAG 1.4.4 (resize text to 200%) reaches native apps through the
  European Accessibility Act, in force since June 2025. Android's largest
  font scale is 2.0, Windows' text-size slider goes to 225%, GNOME's
  text-scaling factor is unbounded.
- **Right-to-left.** Microsoft Store policy 10.7: "the experience
  provided by a product must be reasonably similar in all languages that
  it supports"; the EAA's perceivability rules; chat and reader apps are
  where a mirrored layout bites first. All four toolkits mirror
  automatically under an RTL locale when the app spells its layout as
  leading and trailing; kaya's protocol has only `start`, `center`, `end`
  (the `align` enum) and `start`, `middle`, `end` (the canvas
  `text_align` enum, SVG's own words), and a census of the nine bindings'
  public surfaces on 2026-09-21 found no `left` or `right` identifier
  anywhere.
- **Locale formatting and the words themselves.** Policy 10.7 again:
  an app that claims a language must be that language. Today the task
  manager spells `Mon 7 Sep` out of two English arrays and every one of
  its words is an English literal in guests/rust/tasks.rs. The date and
  time PICKERS are the platforms' own controls and already display in
  the platform's locale.

The nutrition label and the store listing are the app's to file. What
kaya owes is that an app written in kaya passes the criteria without
doing anything unusual, and a proof of that on every lane.

### 1.2 The three pieces, and who owns each (ruled 2026-09-23)

One label, `3 tasks due Mon, Sep 7`, on a phone set to Arabic:

1. **Who the user is.** The platform tells kaya the locale and the
   settings beside it (24-hour time, first weekday, calendar, numbering
   system); the locale decides the layout direction. Always the
   platform's, reported to the core at startup.
2. **Which words.** The app asks the CATALOG for `tasks-due` with
   `count = 3` and `date = …`; the resolver picks the Arabic variant for
   3 (Arabic has six plural forms) and leaves two holes. This is
   localization proper. KAYA OWNS IT: one catalog format for all nine
   languages, resolved in the core, because not every guest language
   has a catalog system of its own and an app should be translated
   once. The format is Fluent (Mozilla's message syntax: plurals and
   selectors in the file, a written specification, a mature pure-Rust
   resolver).
3. **Fill the holes.** The number and the date become text in the
   user's locale with the user's settings. THE PLATFORM'S FORMATTER
   DOES IT, called by the core: Foundation on Apple, Android's ICU over
   JNI, glibc through GLib on Linux, Windows.Globalization on Windows.
   The same formatter is what an app calls directly through `fmt` when
   it wants a value outside any message.

Then the label draws the string, mirrored and at the user's text size,
because the platform does that for a layout spelled start/end. The
guest language enters nowhere: every binding reaches the catalog and
the formatter through the C API into the core, so OCaml gets what Swift
gets and there are no carve-outs.

### 1.3 Why the platform formats, and why not a bundled ICU

The maintainer weighed both on 2026-09-23. Bundled ICU4X (measured: +0.9
MB with date, number and plural data for every locale, +0.37 MB more
with currency through `icu_experimental` 0.6; 13.6s cold build;
docs/measurements/compliance-probes-2026-09-21.md) gives one
implementation and byte-identical output on five lanes, and can take the
four common settings as locale preferences. Against it: the data moves
only with kaya releases and no system channel updates it (there is no
ICU4X data in any package manager; the platform's ICU C library is
private on Apple and version-suffixed on Linux); it cannot honor
Windows' free-form custom patterns or Apple's date-order and
number-format presets; and a kaya app could write a date one character
differently from the Settings app beside it until kaya's data catches
up. The platform formatter honors every user setting, drifts nowhere,
carries no data, and matches how every platform toolkit behaves; its
cost is four arms with four style vocabularies, one composed style on
GTK (§2.3), and test expectations derived per lane rather than frozen
once (§4). RULED: the platform formats. If the four arms prove
burdensome the door to ICU4X stays open, and this section records what
it would buy.

### 1.4 What is spelling, per language

The catalog lookup and the formatters are PURE FUNCTIONS: a value in, a
string out, on any thread, in no transaction. Each binding spells them in
its own idiom over one core implementation.

| language | the lookup | the date, medium, in the process locale |
|---|---|---|
| Rust | `kaya::tr!("tasks-due", count = 3, date = d)` | `kaya::fmt::date(d, Length::Medium)` |
| Python | `kaya.tr("tasks-due", count=3, date=d)` | `kaya.fmt.date(d, length="medium")` |
| Go | `kaya.Tr("tasks-due", kaya.Args{"count": 3, "date": d})` | `kaya.FormatDate(d, kaya.Medium)` |
| C# | `Kaya.Tr("tasks-due", ("count", 3), ("date", d))` | `Kaya.Fmt.Date(d, Length.Medium)` |
| Java | `Kaya.tr("tasks-due", Map.of("count", 3, "date", d))` | `Kaya.fmt().date(d, Length.MEDIUM)` |
| Swift | `Kaya.tr("tasks-due", ["count": 3, "date": d])` | `Kaya.fmt.date(d, .medium)` |
| OCaml | `Kaya.tr "tasks-due" [ "count", `Int 3; "date", `Date d ]` | `Kaya.Fmt.date ~length:`Medium d` |
| Haskell | `tr "tasks-due" [("count", arg 3), ("date", arg d)]` | `fmtDate Medium d` |
| JS | `kaya.tr("tasks-due", { count: 3, date: d })` | `kaya.fmt.date(d, "medium")` |
| C | `kaya_tr(...)` and `kaya_fmt_date(&d, KAYA_FMT_MEDIUM, buf, cap)`, the explicit buffer shape |

BUILT 2026-09-23 in all nine plus the floor (tools/check-sugar-surface.py's
door census holds the twelve parts), with three spellings that are not the
table's, each for a reason the census records: Go answers `Direction()` as a
`LayoutDirection` type, Swift's records are `KayaNumberSpec` and `KayaArg`
(the C header holds `KayaNumberOptions` and `KayaTrArg`), and Java's and
Swift's statics live on `KayaApp` (`KayaApp.fmt().date(…)`,
`KayaApp.fmt.date(…)`, `KayaApp.tr`, `KayaApp.catalog`) beside their other
process-wide calls. OCaml's string argument is `` `Text `` rather than
`` `Str ``, the wire's own constructor.

### 1.5 The whole thing, and what is deliberately not in it

IN: a text-scale knob and its two read-backs on every lane; a locale
knob that decides direction the way the OS does, its read-backs, and
the platform pickers following it; the four settings reported beside
the locale; the formatter door (six calls, two queries) in all nine
bindings and the C floor; the catalog (Fluent files on the asset root,
the resolver in the core, the lookup in all nine, a key-coverage gate);
the task manager translated into Arabic and formatting through kaya;
the legs per lane (largest text, the RTL locale, formatting under three
locales, one OS-setting flip); a gate refusing `left`/`right` spellings
anywhere in a binding surface; and a review page of the tasks app at
200% and in Arabic on every lane.

OUT, each with its reason:

- **An app-facing locale override** (an in-app language switcher). No
  archetype in the corpus asks for it; iOS and Android 13 give users a
  per-app language in Settings that reaches kaya's process as the
  platform's preferred locale with nothing to build. Named here so it is
  a slice and not a surprise.
- **Canvas text following the text scale.** A canvas is the app's own
  drawing, rasterized by the core in logical units; a chart's axis labels
  are not the body text Apple's criterion names. The text-scale factor is
  reported to the core beside the presentation, so an app that wants to
  scale its drawing can read it.
- **macOS text scale.** Apple: "This label isn't supported on Mac" —
  macOS has no Dynamic Type (docs/styling-plan.md D6, per Apple DTS). The
  mac lane runs the clipping read at 1.0, which still holds the layout
  to no truncation, and asserts no scale.
- **Machine formats.** An exported CSV or an invoice is not a UI string;
  an app writes those with a fixed format (ISO 8601, the language's own
  formatting), never through the locale door, and the fmt docs say so.
- **Formatting beyond the six.** Relative dates ("yesterday"), list
  joining, units and compact numbers exist on some platforms and not
  others; the door stays at what all four answer natively or nearly so.
  A message that needs one spells it in the catalog.

## §2 THE MECHANISM PER PLATFORM, AND THE UNKNOWNS

### 2.1 Text scale, per process

| platform | the install | the read-back | scale the lane uses |
|---|---|---|---|
| iOS | the window's `traitOverrides.preferredContentSizeCategory` (iOS 17+), which every SwiftUI text style and every UIKit `adjustsFontForContentSizeCategory` view below it reads | `window.traitCollection.preferredContentSizeCategory`, mapped to its factor (Apple's body-size table: `.large` 17pt is 1.0, AX5 53pt is 3.1) | the category that is 200% (U1 measures which), and AX5 |
| Android | `LocalDensity provides Density(density, fontScale)` and `fontScale` in the forced `Configuration`, beside the night bits (KayaAppearance's shape; BUILT 2026-09-23 as `KayaCompliance`, the knob read at mount and the toolkit's factor reported through `KayaPresent.textScaleReport`) | `LocalDensity.current.fontScale` at the root, and `resources.configuration.fontScale` | 2.0, Android 14's largest |
| GTK | `GtkSettings::default().set_gtk_xft_dpi(96 * 1024 * scale)` before the first window — the very value GNOME's text-scaling-factor writes into Xft/DPI | `settings.gtk_xft_dpi() / 1024 / 96` | 2.0 |
| WinUI | none exists per process: `UISettings.TextScaleFactor` is the user's system setting (1.0–2.25) and XAML applies it by itself. **U3** decides the lane's route (BUILT 2026-09-23: the knob is REFUSED on this platform naming R5, and the presentation report latches the setting for the core) | `UISettings.TextScaleFactor` | 2.0 if U3 allows |
| macOS | none; §1.5 | none; the leg asserts no scale | 1.0 |

The knob is `KAYA_TEXT_SCALE=<factor>`, refused outside 1.0..=3.1 with a
sentence naming the range, one asked function per backend dominating
every install (tools/check-appearance.py's clause shape; the gate grows
a text-scale clause), and `expect_text_scale <factor>` reads the toolkit.

### 2.2 Locale, direction and the four settings, per process

The LOCALE decides the direction, as it does on every OS: `ar`, `he`,
`fa`, `ur` mirror, and the core answers the direction from the locale's
script (a small table in the core; the RTL scripts are Arab, Hebr, Thaa,
Syrc, Nkoo, Adlm and a handful more, CLDR's `scriptMetadata`). One knob,
`KAYA_LOCALE=<bcp47>`. Beside the locale, the backend reports four
settings, each read from the platform's own API:

| setting | Apple | Android | Windows | GNOME |
|---|---|---|---|---|
| 24-hour time | `Locale.current.hourCycle` | `DateFormat.is24HourFormat` | `GlobalizationPreferences.Clocks` / `LOCALE_STIMEFORMAT` | `org.gnome.desktop.interface clock-format` |
| first weekday | `Locale.current.firstDayOfWeek` | the `fw` extension on the default locale (Android 14) | `LOCALE_IFIRSTDAYOFWEEK` | `LC_TIME`'s `first_weekday` |
| calendar | `Locale.current.calendar` | the `ca` extension | `LOCALE_ICALENDARTYPE` | Gregorian |
| numbering system | `Locale.current.numberingSystem` | the `nu` extension (Android 14) | digit substitution | `LC_NUMERIC` |

Under the platform formatter these are honored by the formatter itself
without kaya passing them; they are reported so `kaya::locale()` can
answer them to an app and so the harness can read them back. Under the
knob, the backend installs the locale into the platform (the table
below) and the settings follow the platform's own defaults for it.

| platform | locale into the platform (pickers, formatter) | direction | read-backs |
|---|---|---|---|
| macOS, iOS | `UserDefaults` `AppleLanguages`/`AppleLocale` written before the app object exists, which is Apple's own per-process route (Xcode's scheme sets exactly these) plus `.environment(\.locale)` on every root | `AppleTextDirection` and `NSForceRightToLeftWritingDirection` defaults, Apple's own RTL test knob, plus `.environment(\.layoutDirection)` on every root | `NSApp.userInterfaceLayoutDirection` / `window.effectiveUserInterfaceLayoutDirection`; `Locale.current.identifier` |
| Android | `setLocales` on the forced `Configuration`, and `Locale.setDefault` for the formatter (BUILT 2026-09-23: the core calls `KayaFormat.installLocale` over JNI at attach, before the app thread, and `KayaCompose.mount` dies if the platform then reads any other tag) | `LocalLayoutDirection provides Rtl` beside it, and `setLayoutDirection(locale)` on the configuration | the root composition's `LocalLayoutDirection`; the root composition's `LocalConfiguration.locales[0]` |
| GTK | `setlocale(LC_ALL, "ar_EG.UTF-8")` and `LANGUAGE` before GTK init — needs the locale GENERATED in the lane image (`locales` + `locale-gen`; the image has only C and POSIX today), U2 | `gtk4::Widget::set_default_direction(Rtl)` before the first window | `root.direction()`; `setlocale(LC_ALL, NULL)` |
| WinUI | `ApplicationLanguages.PrimaryLanguageOverride` before the first element (U5: an unpackaged app) and `Language` on each root (BUILT 2026-09-23: the override is refused unpackaged, so the knob is a language list per formatter and the window ground's own `Language`, which defaults to en-US whatever the user's is and so is written from the process locale on every ground) | `FlowDirection.RightToLeft` on each window's root element (BUILT: the ground's, from the core's reading of the tag's script) | the ground's `FlowDirection`; the ground's `Language` |

### 2.3 The formatter, per platform

Six calls — `date`, `time`, `date_time`, `number`, `percent`,
`currency` — with `Length` `short | medium | long` for the date and time
ones and a small options record for the numbers (`minimum_fraction_digits`,
`maximum_fraction_digits`, `grouping`). Each is implemented in the core
crate under a `cfg(target_os)` arm, the way the backends are, calling
the platform from Rust in the app's own process with no hop to the UI
thread:

| platform | the API, from Rust | notes |
|---|---|---|
| macOS, iOS | CoreFoundation's `CFDateFormatter` and `CFNumberFormatter` over `CFLocaleCopyCurrent()` — C APIs, thread-safe to create per call, and they honor the user's Language & Region overrides exactly as Foundation does (U9 measures the iOS 16 date-order preset and 24-hour time) | `kCFDateFormatterMediumStyle` etc. map the three lengths one to one |
| Android | `android.icu.text.DateFormat` / `NumberFormat` through JNI on the JavaVM the android backend already holds (BUILT 2026-09-23: android/kaya/src/main/kotlin/dev/kaya/KayaFormat.kt, called by fmt.rs's android module through `android::format_call`) | the three lengths map to `SHORT`/`MEDIUM`/`LONG` for the date; EVERY TIME goes through the `Hm`/`hm` skeleton family under `is24HourFormat(context)`, since ICU alone ignores the user's setting (U10), the pattern taken from the platform's own `getBestDateTimePattern` rather than ICU's skeleton instance, since the platform writes a plain space before the day period where ICU writes U+202F (docs/traps.md, the Android time byte), and the date-time joins the date skeleton (`yyMd`/`yMMMd`/`yMMMMd`) to it; the weekday date is the `EEEdMMM` skeleton. The harness's `{fmt:…}` is a second spelling: java.text for the date, the numbers and the time family over the platform's own pattern, in the composition's own locale |
| Linux | glibc straight off `libc`: `strftime` under `LC_TIME`, `localeconv` under `LC_NUMERIC`/`LC_MONETARY`, `strfmon` for the locale's own currency, `nl_langinfo` for `D_FMT`/`T_FMT`/the first weekday; the hour cycle is GNOME's `clock-format` when its schema is installed, else `T_FMT` (BUILT 2026-09-23) | glibc has `D_FMT` (short) and NO medium or long style, so kaya COMPOSES medium (`%e %b %Y`), long (`%e %B %Y`) and the weekday date (`%a %e %b`) in `D_FMT`'s month/day order from the locale's own names; that composition is kaya's own rule and `fmt::tests::the_glibc_arm_composes_in_the_locales_order` holds it to frozen bytes in the lane image (tools/check-gtk.py). `strfmon` writes only the locale's own currency; another code takes the locale's placement around the code. Percent is the number plus `%` |
| Windows | `Windows.Globalization.DateTimeFormatting.DateTimeFormatter` with the `shortdate`/`longdate` templates and `NumberFormatting.DecimalFormatter`/`PercentFormatter`/`CurrencyFormatter`, through the `windows` crate (BUILT 2026-09-23, fmt.rs's windows module: a language list per formatter under the knob, the user's own formatters otherwise, the instant through a Gregorian 24-hour `Calendar` in the local zone) | medium is the order-free template `month.abbreviated day year`, which Windows orders itself (`07-Sep-26` in en-US, U11's table); the weekday date is `dayofweek.abbreviated day month.abbreviated`; the time family is `shorttime`, `hour minute second`, `longtime`, and a date-time joins the two templates; grouping and the minimum fraction digits are formatter options, the maximum an `IncrementNumberRounder`, and the currency is grouped (the platform's default is not) |

The two queries: `locale()` (the BCP-47 tag plus the four settings) and
`direction()`.

### 2.4 The catalog

- **Files.** `l10n/<app>.<locale>.ftl` under the asset root, one flat
  family as every family is (tools/check-assets.py's convention), which
  every lane already stages as a unit and verifies by hash. A locale file per language the app ships; the
  app declares its DEFAULT locale in guests/assets/identity.toml beside
  its name and mark.
- **Resolution.** The core loads the catalog for the process locale with
  a fallback chain (`ar-EG` → `ar` → the declared default), resolves a
  message with fluent-bundle (plural rules from Fluent's own small CLDR
  table, `intl_pluralrules`, tens of kilobytes — the one piece of locale
  data kaya carries), and formats `NUMBER()` and `DATETIME()` arguments
  through §2.3's door. A missing message PANICS naming the key and the
  locale; a missing argument likewise. The resolved string is an
  ordinary label text; the platform never sees a catalog.
- **The gate.** a `check-l10n` gate beside the others in tools/: every key a guest names in a `tr`
  call exists in every `.ftl` the app ships, every `.ftl` parses, and
  every message's arguments agree across locales; watched negatives for
  a missing key, a missing locale file and a variant with an argument
  the default lacks.
- **The task manager** is the forcing app: its words move into
  `en.ftl`, an `ar.ftl` is written beside it, and the tasksrtl leg then
  shows a TRANSLATED mirrored app rather than an English one.

### 2.5 The unknowns, measured before any arm

- **U1, iOS: the trait override's reach.** Does
  `window.traitOverrides.preferredContentSizeCategory` move every
  SwiftUI text style AND the UIKit views the interpreter hosts (the rich
  `UITextView`, the search field), and which category is Apple's 200%.
  A throwaway SwiftUI app in the simulator.
- **U2, GTK: `gtk-xft-dpi` per process, and the locale.** Does setting
  it before the first window scale every label, the brand typeface
  included, the `GtkCalendar` and the header bar, on x11 and wayland;
  and `ar_EG.UTF-8` generated in the image with `g_date_time_format`
  answering Arabic. In the container.
- **U3, Windows: the text scale from outside the process.** Set
  `HKCU\Software\Microsoft\Accessibility\TextScaleFactor` to 200 on the
  lane's VM and start a fresh process: does `UISettings.TextScaleFactor`
  read 2.0 and does a TextBlock grow? If yes, the windows scale legs run
  ALONE (the lane's `EXCLUSIVE` set) with the setting written before and
  restored after. If no, WinUI is the platform whose text scale kaya
  cannot drive from a lane, the leg asserts the read-back at 1.0 and
  says so. The undo probe's shape (tools/win/undoprobe), on the VM.
- **U4, Apple: the defaults route.** `AppleLanguages`,
  `AppleTextDirection` and `NSForceRightToLeftWritingDirection` written
  to `UserDefaults.standard` before the app object starts: does SwiftUI's
  root `layoutDirection` flip, do `List` and the split view mirror, does
  a `DatePicker` show Arabic. Mac and simulator.
- **U5, WinUI: `PrimaryLanguageOverride` unpackaged.** Does it move a
  `CalendarDatePicker`'s month names and `FlowDirection` in kaya's
  unpackaged process, or does only the per-element `Language` property
  reach it. On the VM.
- ~~**U6, currency in ICU4X.**~~ MEASURED 2026-09-21, §1.3 and the
  measurements file; moot under the ruling but kept as the record of
  what a bundled ICU would cost.
- **U7, SwiftUI: the clipping read.** SwiftUI's `Text` exposes no
  truncation state. The interpreter already records every node's frame
  (the `frame` verb's census); the read is the label's resolved font's
  `boundingRect` for its text at the recorded width against the recorded
  height. Measured against a label forced into one line and one allowed
  to wrap.
- **U8, Compose: the forced density.** Providing `LocalDensity` with
  `fontScale = 2.0` at the root: does every `sp` move (Material 3's
  typography, kaya's own labels, the `DatePicker`), does API 34's
  non-linear font scaling apply through Compose's `Density`, and does
  `hasVisualOverflow` read true on a label kaya forces into one line.
- **U9, Apple: CoreFoundation from Rust.** `CFDateFormatterCreate` over
  `CFLocaleCopyCurrent()` from a Rust thread that is not the main
  thread: medium date, short time, decimal, percent and currency in
  en-US and ar-EG; then flip 24-hour time and the iOS 16 date-order
  preset in Settings and read the change. Simulator and this Mac.
- **U10, Android: `android.icu` over JNI from the core.** The same six
  from the app thread through the backend's JavaVM, the 24-hour setting
  flipped with `settings put system time_12_24 24`.
- **U11, Windows: `Windows.Globalization` from Rust, unpackaged.** The
  six through the `windows` crate in a plain process on the VM, and the
  user's custom short-date pattern (`HKCU\Control Panel\International`)
  reaching the `shortdate` template.
- **U12, the Fluent resolver.** `fluent-bundle` in the core over an
  `.ftl` with a six-form Arabic plural, arguments formatted through the
  door: the resolved bytes, the crate's size and its plural table's.

## §3 THE PROTOCOL

Nothing moves on the wire between app and backend: text scale, direction,
locale and the settings are PLATFORM facts, not scene properties, and the
lookup and the formatters are pure. The spec hash does not move. The C
API gains:

- `kaya_text_scale_report(factor)`, a backend-to-core report beside
  `kaya_presentation`, latched like it. THE LOCALE NEEDS NO REPORT: the
  door asks the platform's own locale on every call, and the knob is
  installed BY THE CORE at the top of `run`, before the app thread
  exists, through the platform's per-process route (the argument
  domain on Apple) — measured 2026-09-23 when the interpreter-side
  install lost the race to a guest formatting at startup. The
  interpreter keeps a wall: with the knob set, its own locale must
  already be the knob's.
- `kaya_fmt_date`, `kaya_fmt_time`, `kaya_fmt_date_time`,
  `kaya_fmt_number`, `kaya_fmt_percent`, `kaya_fmt_currency`, and the
  queries `kaya_locale` (tag and settings) and `kaya_direction` (0 ltr,
  1 rtl), each writing into a caller buffer and answering the length,
  the header's existing shape for strings.
- `kaya_tr(key, args, nargs, buf, cap)` with an argument record (name,
  tag, value: int, float, string, date, time), and `kaya_catalog_load`
  called by the runtime at startup from the asset root.

The formatter is one module, `fmt.rs` beside `canvas.rs` in the core
crate, with one `cfg(target_os)` arm per platform; the catalog is `l10n.rs`
beside it over `fluent-bundle` pinned in Cargo.lock.

## §4 THE HARNESS

Verbs, all three harnesses, both interpreters (check-verbs' rows), and one template:

- `expect_text_scale <factor>` — the toolkit's factor within 0.01 (§2.1's
  read-back column), never the knob.
- `expect_no_clipping` — every label in the live census is allocated at
  least what its text needs at its width: GTK measures against the
  allocation, Compose reads `TextLayoutResult.hasVisualOverflow` stored
  per node by `onTextLayout`, WinUI reads `IsTextTrimmed` and the
  `ActualHeight` against `DesiredSize`, SwiftUI U7. The failure sentence
  names the first clipped label's text and both sizes.
- `expect_direction ltr|rtl` — the toolkit's resolved direction at the
  root (§2.2's column).
- `expect_mirrored row#N` — the row's first child sits at the trailing
  edge: its frame's x exceeds its last child's. Geometry, toolkit-free.
- `expect_locale <bcp47>` — the PLATFORM's own locale read back (the
  §2.2 column), never the knob and never the core's latch.
- `{fmt:<kind> <value> <length>}` INSIDE an `expect` or `expect_ax`
  string — `expect label@caption[t3] "{fmt:date_weekday 2026-09-07}, Thesis"`
  — expands to what THIS PLATFORM'S formatter, asked independently by
  the harness, writes for the same input, so a composed label holds one
  script on five lanes (a separate verb could not see a date inside a
  sentence; ruled while building, 2026-09-23). The kinds are the six
  plus `date_weekday`, the task list's idiom (`Mon, Sep 7`), which the
  door gained for it. On the two interpreters the
  harness calls Foundation / `java.text` itself, not the core's door; on
  GTK and WinUI, where the harness is the Rust backend, the verb calls the
  platform API through a second, deliberately plain spelling (the
  platform's short style, its long style) and the ONE composed style,
  GTK's medium and WinUI's, is held instead by a unit test of the
  composition rule against frozen bytes in the lane image. No expected
  strings are stored anywhere else: an OS data update moves the
  expectation with it.
- `expect_script label#N <script>` — the label's letters are in the
  named script (Arab, Hebr, Latn), the check that cannot be satisfied by
  a knob that failed to reach the platform, since then both the label
  and the template's answer would be wrong together.

The knobs, `KAYA_TEXT_SCALE` and `KAYA_LOCALE`, with the lanes'
`leg_env` carrying them the way `KAYA_APPEARANCE` rides today. The
windows scale legs join `EXCLUSIVE` if U3 says the setting is the
machine's. ONE OS-SETTING LEG PER LANE flips 24-hour time through the
platform's own knob (a simulator default on Apple, `settings put` on
Android, the registry on Windows, `LC_TIME` in the container) and
asserts the time label moving from `8:30 AM` to `08:30`: the measured
proof that the door honors the user, which is the whole reason the
platform formats.

## §5 THE BINDINGS

Two surfaces in nine bindings plus the C floor (§1.4): `fmt` (six calls,
two queries) and `tr`, each a thin call into the C API, each with a
negative in its own checks file (a length name the enum lacks refused by
name; a missing key's panic sentence). check-sugar-surface gains an
`l10n` census: the nine parts in all nine bindings, read out of each
binding's own file, with the fake-stem negatives the sheet census has.

THE DIRECTION GATE: a check-sugar-surface clause reading every binding's
public surface and the C header for an identifier containing `left` or
`right` (word-bounded, so `leftover` and `items_left` in guest code are
untouched and the OCaml comment that says "never left and right" is
prose), planted negative in each. Green today by measurement.

## §6 THE SCENES, AND THE APP

- **The task manager localizes through kaya.** Its words move to the
  catalog's `en.ftl` for tasks with `ar.ftl` beside it; `Mon 7 Sep`
  becomes a `DATETIME($due)` argument, `2 in inbox` a message with a
  `$count` and its plural forms. The frozen strings in
  tools/scenes/tasks.steps stay English for the everyday leg (the `en`
  catalog's bytes, identical on five lanes) and the date lines carry
  `{fmt:…}` templates.
- **`tasksbig`** — the tasks scene's own script under
  `KAYA_TEXT_SCALE=2.0` (AX5 as a second iOS leg), with
  `expect_text_scale` at the top and `expect_no_clipping` after every
  screen the script visits — the lane's `MODS` append them. The mac leg
  runs it at 1.0 (§1.5). BUILT 2026-09-24 as two scenes rather than one
  with appends, since three lanes have no MODS: `tasksbig.steps` is the
  tasks screens under the knob with `expect_no_clipping` after each (no
  scale number, no notification act, relaunch or drag), and
  `formatbig.steps` holds the scale's own read-back, `expect_text_scale 2`,
  which the iOS lane drops for its nearest category's own ratio (1.94,
  accessibilityLarge). Both are OFF on the mac by declaration
  (tools/lib/lanes/mac.py's OFF_SCENES, read by check-steps), since the
  knob is refused there (R4), and the everyday tasks and tasksrtl scripts
  hold `expect_no_clipping` at 1.0 on every lane, the mac included. On
  windows the two legs run alone with the user's TextScaleFactor written
  before and deleted after (R5, tools/lib/lanes/win.py's TEXT_SCALE_LEGS).
- **`tasksrtl`** — the same script under `KAYA_LOCALE=ar-EG`, its word
  expectations swapped to the `ar` catalog's bytes (identical on five
  lanes), with `expect_locale`, `expect_direction rtl`,
  `expect_mirrored row@task[t1]`, `expect_script` on the date labels and
  `{fmt:…}` templates in their expectations. BUILT 2026-09-23 as the tasks
  script's screens WITHOUT its notification acts, its relaunch and its
  drag: those drive platform doors keyed by scene name on every lane
  (notify_tap, the COM activator, the portal) and the tasks legs already
  hold them; the counts ride `{fmt:number N medium}` since a count's digits
  are the platform's own under ar-EG (Arabic-Indic on four lanes, Latin on
  glibc).
- **`format.steps`**, one guest per language: the six formatters and
  `tr` over fixed inputs, asserted through `{fmt:…}` templates and
  `expect_script` under the everyday locale, then `de-DE` and `ar-EG`
  through the knob, on every lane, in all nine languages — the proof
  that nine spellings are one implementation on each platform.
- **`clock24-*`** — the OS-setting leg (§4).
- **The review page**: the tasks app at 200% and in Arabic on every
  lane, each capture viewed before it is published.

## §7 RULINGS (the maintainer, 2026-09-23)

- **R1 — the platform formats; kaya owns the catalog.** §1.2, §1.3.
  ICU4X stays out, the door open and its cost on the record.
- **R2 — the surface** is six formatters, two queries and the lookup;
  no per-call locale argument (the process locale is the only one an
  app has a reason to format for; a per-call locale is the in-app
  language switcher's slice). No plural-category call: plurals are the
  catalog's, where every catalog system keeps them.
- **R3 — one knob decides the direction.** `KAYA_LOCALE=ar-EG` mirrors,
  as the OS does; there is no `KAYA_DIRECTION`.
- **R4 — macOS states nothing about text scale** (§1.5); its legs hold
  the clipping read at 1.0.
- **R5 — Windows text scale on the lane** follows U3.
- **R6 — canvas text does not follow the text scale** (§1.5); the factor
  is reported to the core so an app can.
- **R7 — the task manager localizes through kaya** and is translated
  into Arabic as the forcing app.
- **R8 — the catalog format is Fluent**, resolved in the core; the
  platform never sees a catalog.
- **R9 — test expectations for formatted values are derived from the
  platform** (the `{fmt:…}` template), never stored, with the two composed
  styles held by unit tests and the knob's reach held by
  `expect_locale` and `expect_script`.

## §8 THE ORDER OF WORK

1. Probes U1–U5 and U7–U12, each a throwaway with its reading in
   docs/measurements/compliance-probes-2026-09-21.md; R5 follows U3.
2. Depth on the mac and iOS: `fmt.rs` with the Apple arm; `l10n.rs` over
   fluent-bundle with unit tests over an Arabic six-form message; the
   reports and queries in the C API; the Rust `fmt` and `tr!` sugar; the
   six verbs and the template in the Rust harness and the SwiftUI interpreter; the knobs
   in the SwiftUI arm; `format.steps` with its Rust guest under three
   locales on the mac and iOS; check-verbs, check-appearance and
   check-l10n rows; depth stubs on GTK, WinUI and Compose so check-stubs
   holds the fan-out open. THE TASK MANAGER'S CONVERSION WAITS FOR
   BREADTH (moved while building, 2026-09-23): its dates and counts
   through `fmt` and `tr` put `{fmt:…}` templates into tools/scenes/tasks.steps,
   which every lane runs, and a lane whose formatter is still a stub
   would go red on a scene it ran green yesterday. It lands with the
   three arms.
3. Breadth: the three formatter arms and their probes' findings, the
   task manager's catalog in `en` and `ar` and its dates through `fmt`,
   the eight bindings' `fmt` and `tr` and their `format.steps` guests,
   check-sugar-surface's census and direction gate, the three backend
   arms for scale and direction, the `tasksbig`, `tasksrtl`, `format` and
   `clock24` legs on every lane, the linux image's generated locales.
4. The matrix, then the review page with the tasks app at 200% and in
   Arabic on every lane, each capture viewed before it is published.
