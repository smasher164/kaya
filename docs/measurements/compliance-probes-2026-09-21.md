# The compliance pass — probe readings (2026-09-21)

The unknowns of docs/compliance-plan.md §2.4, each measured in a throwaway
before any arm was written. Probe sources live in the session scratchpad
(`icuprobe/`); what matters is the reading.

## U6, currency in ICU4X (measured first)

`icu` 2.3.1 with `icu_experimental` 0.6.0 (0.4 fails to resolve: it wants
`icu_casemap ~2.1` against icu 2.3's `~2.3.0`). `CurrencyFormatter::
try_new_symbol(locale, CurrencyType, Default)` then `format_fixed_decimal`
over 123456.78:

| locale | USD | EUR | JPY |
|---|---|---|---|
| en-US | `$123,456.78` | `€123,456.78` | `¥123,457` |
| ar-EG | `‏١٢٣٬٤٥٦٫٧٨ US$` | `‏١٢٣٬٤٥٦٫٧٨ €` | `‏١٢٣٬٤٥٧ JP¥` |
| de-DE | `123.456,78 $` | `123.456,78 €` | `123.457 ¥` |
| ja-JP | `$123,456.78` | `€123,456.78` | `￥123,457` |

Release binary with currency alone: 368,960 bytes against a 285,936-byte
hello (`opt-level = "z"`, LTO, stripped). The date + number + plural probe
beside it: 1,195,008 bytes, 13.6s cold build.

## The date, number and plural probe (the §2.3 table)

`DateTimeFormatter` with the `YMDE` medium fieldset, `DecimalFormatter`
with defaults, `PluralRules::try_new_cardinal`, over 2026-09-07, 1234567
and 3: en-US `Mon, Sep 7, 2026` / `1,234,567` / other; ar-EG
`الاثنين، ٠٧‏/٠٩‏/٢٠٢٦` / `١٬٢٣٤٬٥٦٧` / few; de-DE `Mo., 07.09.2026` /
`1.234.567` / other; he-IL `יום ב׳, 7 בספט׳ 2026` / `1,234,567` / other;
ja-JP `2026/09/07(月)` / `1,234,567` / other.

## The lane image's locales

`kaya-linux:latest` carries `C`, `C.utf8` and `POSIX` only; the `locales`
package is not installed. U2's `ar_EG.UTF-8` needs `locales` plus
`locale-gen` in tools/linux/Dockerfile.

## U12, the Fluent resolver (measured 2026-09-23)

`fluent-bundle` 0.16 with `unic-langid`, release at `opt-level = "z"`, LTO,
stripped: 435,344 bytes against the 285,936-byte hello, so about 150 KB
for the parser, the resolver and its plural-rules table. A `tasks-due`
message with English `one`/`other` and Arabic `zero`/`one`/`two`/`few`/
`many`/`other` variants, a custom `DATETIME` function standing in for the
platform door, isolation marks off:

| count | en-US | ar-EG |
|---|---|---|
| 0 | `0 tasks due <platform:…>` | `لا مهام مستحقة <platform:…>` (zero) |
| 1 | `one task due <platform:…>` | `مهمة واحدة مستحقة …` (one) |
| 2 | `2 tasks due …` | `مهمتان مستحقتان …` (two) |
| 3 | `3 tasks due …` | `3 مهام مستحقة …` (few) |
| 11 | `11 tasks due …` | `11 مهمة مستحقة …` (many) |
| 100 | `100 tasks due …` | `100 مهمة مستحقة …` (other) |

Every variant chosen as CLDR's Arabic rules say, no resolver errors. The
`$count` inside the message is written with ASCII digits by the resolver's
own number path; the real build routes `NUMBER()` through the door so the
digits follow the locale.

## U9, CoreFoundation from Rust off the main thread (measured 2026-09-23, this Mac)

`CFDateFormatterCreate` / `CFNumberFormatterCreate` over `CFLocaleCopyCurrent()`
and `CFLocaleCreate(tag)`, called from a spawned Rust thread, for
2026-09-07 08:36 UTC (local 01:36 PDT), 1234567.891, 0.256 and 1234567.89 USD:

| locale | date short / medium / long | time short | decimal | percent | currency |
|---|---|---|---|---|---|
| en_US (current) | `9/7/26` / `Sep 7, 2026` / `September 7, 2026` | `1:36 AM` (narrow no-break space before AM) | `1,234,567.891` | `26%` | `$1,234,567.89` |
| ar_EG | `٧/٩/٢٠٢٦` / `٠٧/٠٩/٢٠٢٦` / `٧ سبتمبر، ٢٠٢٦` (with RLM marks) | `١:٣٦ ص` | `١٬٢٣٤٬٥٦٧٫٨٩١` | `٢٦٪` | `‏١٬٢٣٤٬٥٦٧٫٨٩ US$` |
| de_DE | `07.09.26` / `07.09.2026` / `7. September 2026` | `01:36` | `1.234.567,891` | `26 %` | `1.234.567,89 $` |
| he_IL | `7.9.2026` / `7 בספט׳ 2026` / `7 בספטמבר 2026` | `1:36` | `1,234,567.891` | `26%` | `‏1,234,567.89 ‏$` |

The three lengths map one to one onto `kCFDateFormatter{Short,Medium,Long}Style`;
the formatters are created and released per call with no main-thread hop.
The user-override half (24-hour time, the date-order preset) is measured on
the simulator, not this Mac, so the maintainer's own settings are untouched.

## U2, GTK per-process text scale and locale (measured 2026-09-23, the lane image)

A python-gi probe under `xvfb-run` in `kaya-linux:latest`: an
AdwApplicationWindow with a header bar, a label, a label in the brand
face, a GtkCalendar and a two-button row.

`gtk-xft-dpi` set on `Gtk.Settings.get_default()` before the first window
(98304 → 196608, factor 2.0 read back): every widget scaled — label 20 →
39px tall, brand-face label 20 → 39, calendar 243 → 381, buttons 34 → 49
(63 → 91 wide), header bar 46 → 51 (its buttons have a floor). So the
per-process route is one settings write and the read-back is the same
property.

`Gtk.Widget.set_default_direction(RTL)` before the first window: every
widget answers `rtl`, the row's first button allocates at x=467 and its
last at 399 in a 530px root (LTR: 0 and 71). Mirroring is the toolkit's.

The locale: `apt-get install locales` plus `locale-gen` for `ar_EG.UTF-8`,
`de_DE.UTF-8`, `en_US.UTF-8` (about a minute; the image carries only C
and POSIX). Under `setlocale(LC_ALL, "ar_EG.UTF-8")`, glibc writes:

| what | ar_EG | de_DE |
|---|---|---|
| `%x` (short date) | `07 سبت, 2026` (Latin digits, abbreviated month) | `07.09.2026` |
| `%c` | `07 سبت, 2026 08:30:00 ص` | `Mo 07 Sep 2026 08:30:00 UTC` |
| `%e %b %Y` (kaya's composed medium) | ` 7 سبت 2026` | ` 7 Sep 2026` |
| `%H:%M` | `08:30` | `08:30` |
| grouped integer | `1,234,567` | `1.234.567` |
| decimal | `1,234,567.891` | `1.234.567,891` |
| `strfmon` currency | `ج.م. 123,456.780` (three fraction digits, glibc's ar_EG) | `123.456,78 €` |

Two things the composition must know: `%e` pads with a space (strip it),
and glibc's ar_EG uses LATIN digits where Foundation uses Arabic-Indic —
a kaya app on GNOME will write `7 سبت 2026` and on iOS `٧ سبتمبر ٢٠٢٦`,
which is each platform's own answer and exactly why expectations are
derived per lane rather than frozen once.

## U4, Apple's defaults route for locale and direction (measured 2026-09-23, this Mac)

A SwiftUI probe (an HStack of `first`/`last` with GeometryReader frames,
a List, a DatePicker, a formatted date and number), the defaults written
BEFORE `NSApplication.shared` exists, the window photographed with
`screencapture -l`:

| route | layoutDirection | Locale.current | NSApp direction | `first` x / `last` x | date | time |
|---|---|---|---|---|---|---|
| nothing | leftToRight | en_US | ltr | 16 / 442 | `Sep 7, 2026` | `1:36 AM` |
| `AppleLanguages`, `AppleLocale`, `AppleTextDirection`, `NSForceRightToLeftWritingDirection` | rightToLeft | ar_EG | rtl | 440 / 16 | `٧ سبتمبر، ٢٠٢٦` | `١:٣٦ ص` |

The List right-aligns its rows, the DatePicker shows Arabic-Indic digits
in day/month/year order, and the whole window mirrors — all from the
four defaults, with no `.environment` modifier at all.

THE TRAP, measured on the way: `UserDefaults.standard.set(...)` for those
keys PERSISTS in the app's own plist (`defaults read rtlprobe` showed
`AppleLanguages = (ar-EG)` afterwards), so a plain run after a knobbed
run was still Arabic. The route kaya takes is the ARGUMENT DOMAIN,
`setVolatileDomain(_:forName: UserDefaults.argumentDomain)`, which is
what `-AppleLanguages (ar-EG)` on the command line sets: on a clean
domain it flips the process identically (measured: same readings as the
row above) and a plain run after it reads en_US, ltr, `Sep 7, 2026`,
with `defaults read` answering that the domain does not exist.

## U1, U7, and the iOS halves of U4 and U9 (measured 2026-09-23, iPhone 17 simulator, kaya-sim-0)

A SwiftUI probe app (an HStack of `first`/`last`, a body label, a
`lineLimit(1)` label and a wrapping label both 200pt wide holding the
same long sentence, a hosted `UITextView` with
`adjustsFontForContentSizeCategory`, a DatePicker, a formatted date and
time), installed and launched through `simctl` with `SIMCTL_CHILD_*` env,
photographed with `simctl io screenshot` and viewed.

**The category table** (`UIFont.preferredFont(.body)` per category over
`.large`'s 17pt): XS 14 (0.82), S 15, M 16, L 17 (1.0), XL 19, XXL 21,
XXXL 23 (1.35), AX1 28 (1.65), AX2 33 (1.94), **AX3 40 (2.35)**, AX4 47
(2.76), **AX5 53 (3.12)**. Apple's "larger than 200% at AX3" holds; the
200% leg is AX3 (`accessibilityExtraLarge`) and the largest is AX5.

**U1, the window trait override.** `window.traitOverrides.preferredContentSizeCategory
= .accessibilityExtraExtraExtraLarge` before the root controller: SwiftUI's
`dynamicTypeSize` read `accessibility5`, the body font 53pt, and the hosted
`UITextView`'s font 53pt after its first layout — one install moves both
worlds. The read-back is the window's `traitCollection`.

**U7, the clipping read.** With the resolved body font, the sentence needs
these heights at 200pt wide (`NSString.boundingRect`) against what SwiftUI
gave each label:

| category | needs | `lineLimit(1)` label got | wrapping label got |
|---|---|---|---|
| L | 64.3 | 20.3 (clipped) | 64.3 (fits) |
| AX1 | 169.4 | 33.7 (clipped) | 169.7 (fits) |
| AX5 | 559.2 | 63.3 (clipped) | 125.3 (CLIPPED) |

So the read is `frame height + 1 < needed height` and it catches both
shapes Apple names: the one-line truncation, and at AX5 the wrapping label
truncated by the VStack's own height with an ellipsis — the screenshot
shows `Engine progra…`, and the DatePicker's `When` label collapsed to `W…`
beside the picker, the side-by-side overlap the criteria warn about. A
scene at AX5 will need the tasks screens inside a scroll, which is what the
leg exists to find.

**U4 on iOS.** The same volatile argument-domain defaults: `layoutDirection`
rightToLeft, `Locale.current` ar_EG, `first` at x=329 and `last` at 16,
the DatePicker in Arabic-Indic digits, `٧ سبتمبر، ٢٠٢٦` and `١:٣٦ ص`.

**U9's setting flip.** `xcrun simctl spawn <udid> defaults write -g
AppleICUForce24HourTime -bool YES` then a fresh launch: the time reads
`01:36`; `defaults delete` and a plain launch: `1:36 AM`, the key gone.
On the Mac the SAME KEY in the process's argument domain (volatile)
answers `01:36` with the host's global domain untouched (measured,
`defaults read -g` says the pair does not exist afterwards), so the mac
lane's clock leg is per process and never touches the maintainer's Mac.

## U8 and U10, Compose and android.icu (measured 2026-09-23, emulator-5554, API 35)

A Compose probe app (a Row of `first`/`last` reporting their root x, a
body Text and two 200dp-wide Texts holding one long sentence, one at
`maxLines = 1`, each with `onTextLayout`; a material3 DatePicker; and
`android.icu` formatters called from a plain `Thread`), driven by
intent extras, photographed with `screencap`.

**U8, the forced density.** `LocalDensity provides Density(density, 2.0)`
plus `fontScale = 2.0` on the forced Configuration: the body Text's
rendered height went 24px → 42px (1.75×, Android 14's NON-LINEAR font
scaling applied through Compose's own Density: 16sp at scale 2.0 is 28sp,
not 32), the wrapping label went 3 → 5 lines, `first`/`last` still at
16/295. So the read-back for `expect_text_scale` is `LocalDensity.fontScale`
(the setting, 2.0), and a pixel ratio would read 1.75 and be wrong to
compare against 2.0. `hasVisualOverflow` read `true` on the `maxLines = 1`
label and `false` on the wrapping one at both scales — the clipping read
is that flag, stored per node by `onTextLayout`.

**Direction and locale.** `setLocales(ar-EG)` + `setLayoutDirection(locale)`
on the forced Configuration with `LocalLayoutDirection provides Rtl`:
`first` at x=313, `last` at 16, the configuration reading ar-EG and
direction 1.

**U10, the formatter off the UI thread.** `Locale.setDefault(ar-EG)` then
`android.icu.text.DateFormat` / `NumberFormat` on `Thread-2`:

| locale | short / medium / long | time short | decimal | percent | currency |
|---|---|---|---|---|---|
| en-US | `9/7/26` / `Sep 7, 2026` / `September 7, 2026` | `8:30 AM` | `1,234,567.891` | `26%` | `$1,234,567.89` |
| ar-EG | `٧‏/٩‏/٢٠٢٦` / `٠٧‏/٠٩‏/٢٠٢٦` / `٧ سبتمبر ٢٠٢٦` | `٨:٣٠ ص` | `١٬٢٣٤٬٥٦٧٫٨٩١` | `٢٦٪` | `‏١٬٢٣٤٬٥٦٧٫٨٩ US$` |

THE FINDING THE ARM MUST KNOW: with `settings put system time_12_24 24`,
`android.text.format.DateFormat.getTimeFormat(context)` answered `08:30`
and `is24HourFormat` true, but `android.icu.text.DateFormat.getTimeInstance
(SHORT)` and the `jm` skeleton STILL answered `8:30 AM`. Android's ICU
does not read the user's 24-hour setting; the platform's own
`android.text.format.DateFormat` does. So the Android time arm asks
`is24HourFormat(context)` and formats through the `Hm`/`hm` skeleton (or
`getTimeFormat` itself) rather than ICU's default time style. The setting
was deleted afterwards (`settings get` answers null) and a plain run read
`8:30 AM` again.

The scale-2.0 screenshot, viewed: the material3 DatePicker's own weekday
header crowds (`W T F S` overlapping) and its right-hand day numbers are
cut at the 360dp edge. That is Material's component at 200%, outside
kaya's label census, and the tasks scene's picker screens will show it;
it is Android's answer, not kaya's to fix, and the review page will show
it as such.

## The Compose arm's first run (measured 2026-09-23, emulator pool, API 35)

The door over `android.icu` and the harness's first second spelling over
`java.text`, format.steps under the everyday locale: the six other reads
agreed byte for byte and the two TIME reads did not — `label#3 reads
"8:30 AM", wanted "8:30 AM"`, the code points `8 : 3 0 U+202F A M` from
the door against `8 : 3 0 U+0020 A M` from java.text. ICU's CLDR 42+ time
patterns carry the narrow no-break space before the day period, and the
PLATFORM writes a plain space: java.text's patterns (run 1) and
`android.text.format.DateFormat.getBestDateTimePattern`'s answer handed to
ICU's own SimpleDateFormat (run 2, the same two code-point lists) both put
U+0020 there, so only ICU's `getInstanceForSkeleton` keeps U+202F;
CoreFoundation on the Apple lanes keeps it too. `DateUtils.formatDateTime`
and java.time were not measured. The door's time family took the
platform's pattern (run 3 green), and the harness's time family is
java.text over the same pattern (`getTimeFormat(context)` answered
`8:30 AM` under the Arabic knob: it reads the activity's locale). The German and Arabic legs were
green on the same run: `07.09.2026`, `1.234.567,891`, `1.234.567,89 $`;
`٠٧‏/٠٩‏/٢٠٢٦`, `٧ سبتمبر ٢٠٢٦`, `٨:٣٠ ص`, `١٬٢٣٤٬٥٦٧٫٨٩١`,
`‏١٬٢٣٤٬٥٦٧٫٨٩ US$`, direction rtl, row#0 mirrored.

## U3, U5 and U11, Windows (measured 2026-09-23, the lane's VM, an unpackaged Rust console process over the `windows` crate 0.61)

**U11, Windows.Globalization from Rust, unpackaged.** Every formatter
answers in a plain process; the language list rides each formatter's
constructor (`CreateDateTimeFormatterLanguages`, `CreateDecimalFormatter`).
Windows inserts LEFT-TO-RIGHT / RIGHT-TO-LEFT MARKS (U+200E/U+200F)
between every field of a date, which the derived expectation naturally
carries and a frozen string would not:

| language | `shortdate` | `longdate` | `month.abbreviated day year` (the order-free template) | `shorttime` |
|---|---|---|---|---|
| en-US | `9/7/2026` | `Monday, September 7, 2026` | `07-Sep-26` | `1:10 AM` |
| ar-EG | `٠٧/٠٩/٢٠٢٦` | `٠٧ سبتمبر, ٢٠٢٦` | `٠٧ سبتمبر, ٢٠٢٦` | `٠١:١٠ ص` |
| de-DE | `07.09.2026` | `Montag, 7. September 2026` | `7. Sep. 2026` | `01:10` |

Windows has no medium date style: the order-free template is Windows'
own answer for that field set and reads `07-Sep-26` in en-US, while a
fixed pattern `{month.abbreviated} {day.integer}, {year.full}` reads
`Sep 7, 2026` and is month-first in Arabic. The arm's medium is the
template (the platform orders it), and this table is the reason the
review page will show Windows' medium beside the others.

The number formatters default to NO grouping and two percent fraction
digits (`1234567.891`, `25.60%`, `$1234567.89`); the arm sets
`IsGrouped` and the fraction digits from the options record.

**The user's Region settings reach the formatter.** With `sShortDate =
yyyy-MM-dd`, `iTime = 1` and `sShortTime = HH:mm` written under
`HKCU\Control Panel\International`, a fresh process read
`GlobalizationPreferences.Clocks = [12HourClock, 24HourClock]`, the
user formatter (no language list) `2026-09-07` and `01:10` with the
patterns `{year.full}-{month.integer(2)}-{day.integer(2)}` and
`{hour.integer(2)}:{minute.integer(2)}`, AND the en-US language-list
formatters the same — the override applies when the list's language is
the user's. Restored to `M/d/yyyy`, `0`, `h:mm tt` and re-read.

**U3, the text scale from outside the process.** `reg add HKCU\Software\
Microsoft\Accessibility /v TextScaleFactor /d 200` then a fresh process:
`UISettings.TextScaleFactor` = 2. Deleted, and a fresh process reads 1
with the value gone (it was absent before the probe). So the windows
scale legs run ALONE with the value written before and deleted after
(R5), and `expect_text_scale` reads `UISettings.TextScaleFactor`.

**U5, `PrimaryLanguageOverride` unpackaged.** REFUSED: `SetPrimaryLanguageOverride`
answers `0x80073D54`, "The process has no package identity". So the WinUI
arm cannot move the process's language; the knob installs the language
by passing it to every formatter and by `Language` on each root element,
and whether the CalendarDatePicker follows `Language` is the leg's own
reading.

## The WinUI arm's first run (measured 2026-09-23, the lane's VM)

Three legs, three reds, none of them the formatter's bytes: the everyday and
German legs read the catalog's `{ $count } items` as `3.00 items` and
`3,00 Elemente`, because `DecimalFormatter`'s own default is two FORCED
fraction digits where CLDR's `#,##0.###` (ICU, CoreFoundation, glibc's
composed form) writes an integer bare — so an unstated digit count on this
arm is CLDR's, min 0 max 3 for a number and 0/0 for a percent, and the
currency keeps its own. The Arabic leg read `direction rtl` and
`locale ar-EG` and then `row#0 not mirrored: first child at x=16, last at
x=502`: under RightToLeft, XAML's `TransformToVisual` answers in a mirrored
space whose x grows leftward from the surface's right edge, so the row WAS
mirrored (its first child 16px from the right) and the read was in flow
coordinates; the mirror read turns a flow x back into a left edge
(`surface width - x - child width`) under an RTL surface. The second run
was green on all three and read `0%` for `{fmt:percent 0.256 medium}` on
both sides, since `IncrementNumberRounder` rounds the VALUE and a percent
shows the value × 100: the increment is scaled by 0.01 for a percent, and
`fmt::win_tests` pins the digits on the guest's unit phase, because the
harness on this backend answers the template through the door itself.

## U2 again, glibc's own tables (measured 2026-09-23, a C probe in the lane image with the locales generated)

| | C.UTF-8 | en_US.UTF-8 | de_DE.UTF-8 | ar_EG.UTF-8 |
|---|---|---|---|---|
| `D_FMT` | `%m/%d/%y` | `%m/%d/%Y` | `%d.%m.%Y` | `%d %b, %Y` |
| `T_FMT` | `%H:%M:%S` | `%r` | `%T` | `%Z %I:%M:%S %p` |
| `T_FMT_AMPM` | `%I:%M:%S %p` | `%I:%M:%S %p` | (empty) | `%Z %I:%M:%S %p` |
| `_NL_TIME_FIRST_WEEKDAY` | 1 (Sunday) | 1 | 2 (Monday) | 7 (Saturday) |
| decimal / thousands / grouping | `.` / none / 0 | `.` / `,` / 3 | `,` / `.` / 3 | `.` / `,` / 3 |
| `int_curr_symbol` / symbol / fraction digits | none | `USD ` / `$` / 2 | `EUR ` / `€` / 2 | `EGP ` / `ج.م.` / 3 |
| `strfmon("%n", 1234567.89)` | `1234567.89` | `$1,234,567.89` | `1.234.567,89 €` | `ج.م. 1,234,567.890` |
| `%e %b %Y` / `%a %e %b` | ` 7 Sep 2026` / `Mon  7 Sep` | same | ` 7 Sep 2026` / `Mo  7 Sep` | ` 7 سبت 2026` / `ن  7 سبت` |

The langinfo items are `D_FMT` 131113, `T_FMT` 131114, `T_FMT_AMPM` 131115,
`D_T_FMT` 131112, `_NL_TIME_FIRST_WEEKDAY` 131176 (LC_TIME's base is
2 << 16). Three limits the arm carries, stated: `strfmon` writes the
LOCALE'S OWN currency and no other, so a foreign code takes the locale's
placement around the code (`EUR1,234,567.89` in en_US); glibc knows no
named medium or long date, so those are composed in `D_FMT`'s month/day
order from the locale's own names; `%e` pads with a space and `%a %e`
doubles it, which the arm collapses. `strfmon`'s `%i` in the probe read
garbage because the probe passed one double for two conversions — a
probe bug, not glibc's.
