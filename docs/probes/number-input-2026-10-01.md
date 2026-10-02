# Typed numbers in other toolkits (2026-10-01)

Research only; nothing built. Question: how does kaya's proposed rule for
TYPED numbers (docs/number-field-plan.md §3, and the open half of the
docs/deferred.md entry "the glibc arm of the formatter door") compare with
what other toolkits let a user type into a number entry?

The proposed rule: a number field accepts ASCII digits and the locale's own
digits, the locale's own separators, and also "." as the decimal point
wherever "." has no other meaning in that locale (accepted under ar-EG;
refused under de-DE, where "." groups).

## 1. The cases

| id | locale | typed | means | proposed rule |
|---|---|---|---|---|
| A | ar-EG | `3.5` / `34` | ASCII digits, "." decimal | accept 3.5 / 34 |
| B | ar-EG | `٣٫٥` / `٣٤` | Arabic-Indic digits, U+066B decimal | accept |
| C | en-US | `٣٤` / `٣.٥` | Arabic-Indic digits outside an Arabic locale | accept (the rule says "ASCII and the locale's own"; en-US's own are ASCII, so strictly REFUSE — see §4) |
| D | de-DE | `3,5` | locale decimal | accept 3.5 |
| E | de-DE | `3.5` | "." where "." groups | refuse |
| F | ar-EG | `3.5` | "." where U+066B is the decimal | accept (the rule's leniency) |
| G | any | `1,234.5` (en-US), `1.234,5` (de-DE), `١٬٢٣٤` (ar-EG) | typed grouping | accept the locale's own grouping (the rule says "the locale's own separators") |

"Accept" below means the field commits the intended value; "refuse" means
the text is rejected (reverted, flagged invalid, or the keystroke dropped);
"converts" means a value is committed that is not what the user meant.

## 2. Comparison table

Columns are the §1 cases, each with one representative text:
A = ar-EG `34`, B = ar-EG `٣٫٥`, C = en-US `٣٤`, D = de-DE `3,5`,
E = de-DE `3.5`, F = ar-EG `3.5`, G = the locale's own grouping typed
(de-DE `1.234,5`). "acc" accepts the intended value, "ref" refuses (at the
keystroke where marked "key"), "conv → x" commits x, "?" was not
established. Sources are the per-toolkit notes in §3 (each cell's
line reference is there); M = measured in this pass.

| toolkit | A | B | C | D | E | F | G |
|---|---|---|---|---|---|---|---|
| kaya, proposed | acc | acc | ref (rule as worded) | acc | ref | acc | acc? (rule says "own separators"; plan §3.5 parses ungrouped) |
| GTK GtkSpinButton, default (M) | acc | ref (Arabic-Indic integers only: `٣٤` acc) | acc (integer only) | acc | acc as 3.5 | acc | ref |
| GTK GtkSpinButton, `numeric` | acc | ref key | ref key | acc | ref key | acc | ref key |
| WinUI NumberBox (`ParseDouble`) | ? | acc | ? | acc | ref | ? | acc (grouping read whatever `IsGrouped` says) |
| Android EditText `numberDecimal` (no `imeHintLocales`) | acc | ref key | ref key | ref key (`,` dropped) | acc as 3.5 (app parse) | acc | ref key |
| Android EditText with `imeHintLocales` | ref key (ASCII digits dropped) | acc | ref key | acc | ref key | ref key | ref key |
| Compose `KeyboardType.Decimal` + `toDoubleOrNull` | acc | ref | ref | ref | acc as 3.5 | acc | ref |
| Apple `NumberFormatter` (M) | acc | acc | acc | acc | ref | ref | acc |
| SwiftUI `TextField(value:format:)` (M, its parse) | acc | acc | acc | acc | conv → 3 | conv → 3 | acc |
| Qt `QDoubleSpinBox` / `QLocale::toDouble` | acc | acc | ref | acc | ref (range < 1000) / conv → 35 (range ≥ 1000) | ref | acc |
| Flutter `TextField` + `double.parse` | acc | ref | ref | ref | acc as 3.5 | acc | ref |
| Flutter + intl `NumberFormat.parse` | ref | acc | ref | acc | conv → 35 (group dropped) | ref | acc |
| Chromium `<input type=number>` | acc | acc | ref key | acc | acc as 3.5 | acc | ref (bad input) |
| Firefox `<input type=number>` | acc | acc | acc | acc | acc as 3.5 | acc | ref unless `dom.forms.number.grouping` |
| Avalonia `NumericUpDown` (.NET parse) | acc | ref | ref | acc | conv → 35 | ref (ICU-mode culture, decimal `٫`; not run) | acc |
| .NET MAUI `Entry` `Keyboard.Numeric` (Android) | acc | ref key | ref key | acc | ref key | ref key | ref key |

Notes on cells:
- Flutter + intl, case E: intl maps `GROUP_SEP` through `handleSpace`
  (number_parser_base.dart line 82) and so drops the de-DE `.`; read from
  the source, not run. Its ar_EG symbols are `DECIMAL_SEP '٫'`,
  `GROUP_SEP '٬'`, `ZERO_DIGIT '٠'`
  ([number_symbols_data.dart](https://github.com/dart-lang/i18n/blob/main/pkgs/intl/lib/number_symbols_data.dart)
  lines 102-107), which is why A and F are refused.
- Apple under ar-EG also reads `3,5` as 3.5 and, lenient, `1.234` as 1234:
  ICU's equivalence classes (§3), not the locale's own two characters.
- Android with `imeHintLocales`: the digit and separator sets come from
  android.icu's ar-EG symbols, `٠-٩` and `٫`; not run on the emulator.

## 3. Notes per toolkit

### GTK 4 GtkSpinButton

Source: gtk main, [gtk/gtkspinbutton.c](https://gitlab.gnome.org/GNOME/gtk/-/blob/main/gtk/gtkspinbutton.c)
and glib main, [glib/gstrfuncs.c](https://gitlab.gnome.org/GNOME/glib/-/blob/main/glib/gstrfuncs.c).
Measured in the linux lane image (`kaya-linux:latest`, glibc 2.41) with a
verbatim copy of `gtk_spin_button_default_input` over the real `g_strtod`:
docs/probes/number-input-2026-10-01/gtk-spin-input.c.

- `gtk_spin_button_default_input` calls `g_strtod(text, &err)`; if anything
  is left over it falls back to a loop that accepts an optional `-` and then
  ONLY `g_unichar_isdigit` characters, summed as an INTEGER. So any Unicode
  decimal digit set is read, but only as a whole number: `٣٤` → 34 under
  every locale, `٣٫٥` → error, `3٫5` → error.
- `g_strtod` runs the C library's `strtod` (locale's `LC_NUMERIC`) AND
  `g_ascii_strtod` (always "."), and keeps whichever consumed MORE text.
  So "." is always a decimal point, in every locale, and the locale's own
  decimal is accepted too.
- Grouping is never read: `strtod` without the `'` flag does not take
  `thousands_sep`, so `1,234` (en-US) and `1.234,5` (de-DE) are errors.
- Under de-DE `1.234` is read by the ASCII half as 1.234, not 1234: a
  German user typing a grouped thousand gets a value a thousand times too
  small, with no error. Measured.
- The optional `numeric` mode (`gtk_spin_button_set_numeric`) filters
  keystrokes BYTE BY BYTE: `-`/`+`, the single byte `*localeconv()->decimal_point`,
  and `0x30..0x39`. Every non-ASCII digit is dropped at the keystroke, and
  under de-DE "." is dropped too.

Measured results (default mode, not numeric):

| typed | en_US | de_DE | ar_EG |
|---|---|---|---|
| `3.5` | 3.5 | **3.5** | 3.5 |
| `3,5` | error | 3.5 | error |
| `1.234` | 1.234 | **1.234** (meant 1234) | 1.234 |
| `1,234` | error | 1.234 | error |
| `1.234,5` / `1,234.5` | error / error | error / error | error / error |
| `٣٤` | 34 | 34 | 34 |
| `٣٫٥` | error | error | error |
| `١٬٢٣٤` | error | error | error |

glibc's ar_EG has decimal_point "." and thousands_sep "," (also printed by
the probe), so A and F are the same case on Linux.

### Apple: NumberFormatter and SwiftUI TextField(value:format:)

Measured on this Mac (macOS 26, Foundation's ICU), probe
docs/probes/number-input-2026-10-01/apple-parse.swift: `NumberFormatter`
(`.decimal`, `isLenient` false and true, `number(from:)`) and
`Double(_:format: .number.locale(l))`, which is the
`FloatingPointFormatStyle` parse strategy that `TextField(value:format:)`
uses ([TextField(_:value:format:prompt:)](https://developer.apple.com/documentation/swiftui/textfield/init(_:value:format:prompt:)-3fh51),
[ParseableFormatStyle](https://developer.apple.com/documentation/foundation/parseableformatstyle)).

| typed | en_US NF | en_US FS | de_DE NF | de_DE FS | ar_EG NF strict / lenient | ar_EG FS |
|---|---|---|---|---|---|---|
| `3.5` | 3.5 | 3.5 | nil | **3** | nil / nil | **3** |
| `3,5` | nil | **3** | 3.5 | 3.5 | **3.5** / **3.5** | **3.5** |
| `1.234` | 1.234 | 1.234 | 1234 | 1234 | nil / 1234 | 1234 |
| `1,234` | 1234 | 1234 | 1.234 | 1.234 | 1.234 / 1.234 | 1.234 |
| `1.234,5` | nil | **1.234** | 1234.5 | 1234.5 | nil / 1234.5 | 1234.5 |
| `1,234.5` | 1234.5 | 1234.5 | nil | **1.234** | nil / nil | **1.234** |
| `٣٤` | 34 | 34 | 34 | 34 | 34 / 34 | 34 |
| `٣٫٥` | nil | **3** | 3.5 | 3.5 | 3.5 / 3.5 | 3.5 |
| `١٬٢٣٤` | nil (lenient 1234) | 1234 | nil (lenient 1234) | 1234 | 1234 / 1234 | 1234 |
| `٣.٥` | 3.5 | 3.5 | nil | **3** | nil / nil | **3** |

(NF = NumberFormatter non-lenient unless noted; en_US and de_DE gave the
same answers lenient and strict except `١٬٢٣٤`.)

- ICU reads ANY Unicode decimal digit set in every locale (`٣٤` is 34
  under en_US and de_DE), so case C is accepted.
- The decimal separator is matched by ICU's EQUIVALENCE CLASS, not by the
  one character: ar_EG's `٫` is in the comma class, so `3,5` is 3.5 under
  ar_EG, while `3.5` is refused there (case F refused). See ICU's
  [static_unicode_sets.cpp](https://github.com/unicode-org/icu/blob/main/icu4c/source/common/static_unicode_sets.cpp)
  (the COMMA and PERIOD sets are loaded from CLDR root's `parse` lenient
  data, lines 90-97; `DIGITS` is `[:digit:]`, line 205, which is why any
  digit set parses; `٬` is in OTHER_GROUPING_SEPARATORS, line 175) and
  [numparse_decimal.cpp](https://github.com/unicode-org/icu/blob/main/icu4c/source/i18n/numparse_decimal.cpp).
- Grouping is accepted wherever it is the locale's own (`1.234,5` under
  de_DE, `1,234.5` under en_US).
- `NumberFormatter.number(from:)` must consume the whole string, so a
  wrong separator is refused (nil). The `FormatStyle` parse used by
  `TextField(value:format:)` instead stops at the first character it cannot
  use and returns the PREFIX: `3.5` under de_DE commits 3, `1,234.5` under
  de_DE commits 1.234. This is the one Apple path that converts silently.

### WinUI NumberBox

Source: microsoft-ui-xaml main,
[controls/dev/NumberBox/NumberBox.cpp](https://github.com/microsoft/microsoft-ui-xaml/blob/main/controls/dev/NumberBox/NumberBox.cpp)
and [NumberBoxParser.cpp](https://github.com/microsoft/microsoft-ui-xaml/blob/main/controls/dev/NumberBox/NumberBoxParser.cpp).

- The default `NumberFormatter` is `GetRegionalSettingsAwareDecimalFormatter()`
  (NumberBox.cpp lines 80-115, "largely copied from Calculator"): a
  `DecimalFormatter` over the user's default locale name and home region,
  `FractionDigits(0)`.
- `ValidateInput()` (lines 478-520) trims the text, then calls
  `ParseDouble(text)` (or, with `AcceptsExpression`, `NumberBoxParser::Compute`,
  which cuts each operand with the regex `^-?([^-+/*\(\)\^\s]+)` and still
  hands it to `ParseDouble`). A null answer under `InvalidInputOverwritten`
  puts the text back to the value. No keystroke filtering at all; the
  check is at commit.
- `DecimalFormatter.ParseDouble` is documented only as "Attempts to parse a
  string representation of a Double number ... otherwise null"
  ([ParseDouble](https://learn.microsoft.com/en-us/uwp/api/windows.globalization.numberformatting.decimalformatter.parsedouble));
  `NumeralSystem` is "the numbering system that is used to format and parse"
  ([NumeralSystem](https://learn.microsoft.com/en-us/uwp/api/windows.globalization.numberformatting.decimalformatter.numeralsystem)).
- kaya's own measurement on the windows lane's VM (docs/number-field-plan.md
  §4.4, 2026-09-28; fmt.rs win_tests): the locale's decimal is read and the
  other locale's refused (de-DE `12,5` read, `12.5` refused; en-US the
  reverse; ar-EG `٣٫٥` read), and grouping is READ WHATEVER `IsGrouped` SAYS
  (`1,234.5` under en-US). So stock NumberBox accepts typed grouping (G).
- NOT MEASURED in this pass (no VM per the charge): whether `ParseDouble`
  under ar-EG reads ASCII digits (A), whether en-US reads Arabic-Indic
  digits (C), and whether ar-EG reads `3.5` (F). The docs do not say. The
  cells are marked "?" in §2.

### Android EditText numberDecimal (DigitsKeyListener)

Source: AOSP frameworks/base (GitHub mirror, main):
[DigitsKeyListener.java](https://github.com/aosp-mirror/platform_frameworks_base/blob/main/core/java/android/text/method/DigitsKeyListener.java),
[NumberKeyListener.java](https://github.com/aosp-mirror/platform_frameworks_base/blob/main/core/java/android/text/method/NumberKeyListener.java),
[TextView.java](https://github.com/aosp-mirror/platform_frameworks_base/blob/main/core/java/android/widget/TextView.java).

- `android:inputType="numberDecimal"` makes TextView install
  `DigitsKeyListener.getInstance(locale, signed, decimal)` with
  `locale = getCustomLocaleForKeyListenerOrNull()` (TextView lines
  ~7915-7951), which is NULL unless the app targets O+ AND set
  `imeHintLocales`. The ordinary EditText therefore takes `setToCompat()`:
  the accepted set is `0-9` and `.` (COMPATIBILITY_CHARACTERS, lines 79-83)
  IN EVERY LOCALE. Under de-DE the `,` key is dropped at the keystroke, and
  every Arabic-Indic digit is dropped under ar-EG and en-US. This is a
  keystroke filter, not a parse: the app then parses the text itself.
- With `imeHintLocales` set, `NumberKeyListener.addDigits` adds the locale's
  `getDigitStrings()` ONLY (lines 151-163: Arabic-Indic under ar-EG, ASCII
  under de-DE), and the decimal set becomes the locale's single
  `getDecimalSeparatorString()` (DigitsKeyListener lines 193-202). ASCII
  digits are then dropped under ar-EG, and `.` is dropped under ar-EG and
  de-DE.
- Grouping is never in the accepted set, and `filter()` admits at most one
  decimal-point character (lines 339-405), so typed grouping is refused in
  both modes.

### Compose TextField with KeyboardType.Decimal

Source: androidx main,
[KeyboardType.kt](https://github.com/androidx/androidx/blob/androidx-main/compose/ui/ui-text/src/commonMain/kotlin/androidx/compose/ui/text/input/KeyboardType.kt).

- `KeyboardType` is a hint to the IME: "this input type is honored by
  keyboard and shows corresponding keyboard but this is not guaranteed";
  `Decimal` "Displays a numeric keypad containing a decimal point key (`.`
  or `,` depending on locale)". Compose installs no key listener, so ANY
  character reaches the field; what is accepted is whatever the app's parse
  accepts.
- The common app parse is Kotlin's `String.toDoubleOrNull()`, i.e. Java's
  `Double.parseDouble` grammar (ASCII digits, `.` only, no grouping:
  [Double.valueOf(String)](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/lang/Double.html#valueOf(java.lang.String))).
  Under de-DE the keyboard Compose asked for offers `,`, which that parse
  then refuses. An app that parses with `NumberFormat.getInstance(locale)`
  gets ICU's behaviour (the Apple column, through android.icu), and
  `NumberFormat.parse(String)` takes the longest PREFIX
  ([NumberFormat.parse](https://developer.android.com/reference/android/icu/text/NumberFormat#parse(java.lang.String))),
  the same prefix trap as SwiftUI's FormatStyle.

### Qt QDoubleSpinBox / QLocale::toDouble

Source: qtbase dev,
[src/corelib/text/qlocale.cpp](https://github.com/qt/qtbase/blob/dev/src/corelib/text/qlocale.cpp),
[src/corelib/text/qlocale_p.h](https://github.com/qt/qtbase/blob/dev/src/corelib/text/qlocale_p.h),
[src/widgets/widgets/qspinbox.cpp](https://github.com/qt/qtbase/blob/dev/src/widgets/widgets/qspinbox.cpp).
Read, not run.

- Digits: `NumericData::digitValue` (qlocale_p.h lines 420-439) reads the
  locale's own ten digits counted from its zero, and then FALLS THROUGH TO
  ASCII `0-9` when the locale's zero is one code unit ("Accepting ASCII with
  zeroLen != 1 would mess up code that assumes consistent digit width", so
  only multi-unit digit sets lose ASCII). So under ar-EG (CLDR zero `٠`)
  both `٣٤` and `34` read; under en-US and de-DE (zero `0`) only ASCII
  reads, and `٣٤` is refused.
- Separators: `NumericTokenizer::nextToken` (qlocale.cpp ~4505-4595) maps
  ONLY the locale's own `decimal` to `.` and its own `group` to `,`
  (plus U+2212, the ALM/LRM/RLM marks, and a plain space where the group is
  a no-break space). So under ar-EG `3.5` is refused (case F refused), and
  under de-DE `3.5` is a group separator in the wrong place.
- Typed grouping: accepted by `toDouble` when the group sizes fit
  (`1.234,5` de-DE, `1,234.5` en-US) unless `QLocale::RejectGroupSeparator`.
- QDoubleSpinBox (`validateAndInterpret`, qspinbox.cpp lines 1230-1360) runs
  on every keystroke as a QValidator: Invalid text is not entered at all.
  When `locale.toDouble` fails and the range reaches ±1000, it DELETES every
  group separator and parses again (`copy2.remove(group)`), so under de-DE
  `3.5` is read as 35 in a spin box whose maximum is 1000 or more. With the
  default range (0 to 99.99) the same text is Invalid. This is the
  converts case for Qt.

### Flutter (TextField + double.parse, or intl's NumberFormat.parse)

Sources: [double.parse](https://api.dart.dev/stable/dart-core/double/parse.html),
flutter master
[packages/flutter/lib/src/services/text_formatter.dart](https://github.com/flutter/flutter/blob/master/packages/flutter/lib/src/services/text_formatter.dart),
dart-lang/i18n main
[pkgs/intl/lib/src/intl/number_parser_base.dart](https://github.com/dart-lang/i18n/blob/main/pkgs/intl/lib/src/intl/number_parser_base.dart).

- Flutter has no number field. The usual shape is a `TextField` with
  `keyboardType: TextInputType.numberWithOptions(decimal: true)` (an IME
  hint, no filter), often `FilteringTextInputFormatter.digitsOnly`, which is
  `allow(RegExp(r'[0-9]'))` (text_formatter.dart line 430: ASCII only, no
  separator at all), and a parse with `double.parse`/`tryParse`.
- `double.parse` takes an optional sign and "digits optionally followed by
  a decimal point": ASCII digits and `.` in every locale, no grouping, no
  locale statement. So de-DE `3,5` is refused and de-DE `3.5` is read as
  3.5; Arabic-Indic digits are refused everywhere.
- An app that parses with intl's `NumberFormat.parse` gets: the locale's
  `DECIMAL_SEP` mapped to `.` and `GROUP_SEP` dropped (lines 79-95), and
  digits read ONLY from the locale's own zero (`asDigit`, lines 115-125,
  `charCode - _localeZero`). So under a locale whose zero is `٠`, ASCII
  digits are refused, and under en-US Arabic-Indic digits are refused.

### The web: `<input type="number">`

Sources: the HTML standard's
[number state](https://html.spec.whatwg.org/multipage/input.html#number-state-(type=number))
(the VALUE is a "valid floating-point number": ASCII digits and `.`; the
user agent may show and accept a localized form);
Chromium main
[number_input_type.cc](https://github.com/chromium/chromium/blob/main/third_party/blink/renderer/core/html/forms/number_input_type.cc)
and [platform_locale.cc](https://github.com/chromium/chromium/blob/main/third_party/blink/renderer/platform/text/platform_locale.cc);
Firefox
[NumericInputTypes.cpp](https://github.com/mozilla/gecko-dev/blob/master/dom/html/input/NumericInputTypes.cpp)
and [ICUUtils.cpp](https://searchfox.org/mozilla-central/source/intl/unicharutil/util/ICUUtils.cpp).
Read, not run.

- CHROMIUM filters keystrokes: `FilterBeforeTextInserted` keeps
  `0123456789.Ee-+` plus the locale's `acceptable_number_characters_`,
  which is the locale's ten digits and decimal separator and signs, and
  explicitly NOT its group separator ("We don't accept group separators",
  platform_locale.cc ~line 284). Under en-US an Arabic-Indic digit is
  dropped at the keystroke; under ar-EG both digit sets and both `.` and
  `٫` can be typed; under de-DE both `.` and `,` can be typed.
- Chromium's `ConvertFromLocalizedNumber` (platform_locale.cc 389-431) maps
  the locale's digits and decimal to ASCII, but when it meets ANY character
  that is not one of the locale's symbols, it returns the input UNCHANGED,
  and the unchanged text is then sanitized as a plain valid floating-point
  number. So `3.5` reads 3.5 in EVERY locale (de-DE and ar-EG included),
  ASCII `34` reads under ar-EG, a locale group separator makes the whole
  conversion give up (`1.234,5` under de-DE is bad input) and, under de-DE,
  `1.234` falls back to the ASCII reading 1.234 (meant 1234), GTK's misread.
  Mixed text such as `٣.٥` under ar-EG is bad input.
- FIREFOX does not filter keystrokes. `NumberInputType::ConvertStringToNumber`
  first tries the HTML parse (`StringToDecimal`: ASCII and `.`), and only if
  that fails parses with ICU in the element's language chain, requiring the
  WHOLE string to be consumed (`parsed.second == value.Length()`), grouping
  allowed only under the `dom.forms.number.grouping` pref. So like Chromium
  `.` is a decimal in every locale (de-DE `1.234` is 1.234), and the locale
  form is read through ICU (any digit set, the locale's decimal class: the
  Apple column).

### .NET: Avalonia NumericUpDown and .NET MAUI

Sources: Avalonia master
[src/Avalonia.Controls/NumericUpDown/NumericUpDown.cs](https://github.com/AvaloniaUI/Avalonia/blob/master/src/Avalonia.Controls/NumericUpDown/NumericUpDown.cs);
dotnet/runtime main
[src/libraries/Common/src/System/Number.Parsing.Common.cs](https://github.com/dotnet/runtime/blob/main/src/libraries/Common/src/System/Number.Parsing.Common.cs);
dotnet/maui main
[src/Core/src/Platform/Android/LocalizedDigitsKeyListener.cs](https://github.com/dotnet/maui/blob/main/src/Core/src/Platform/Android/LocalizedDigitsKeyListener.cs).
Read, not run.

- Avalonia's `ConvertTextToValueCore` (NumericUpDown.cs ~1155-1205) is
  `decimal.TryParse(text, ParsingNumberStyle, NumberFormat)` with
  `ParsingNumberStyle` defaulting to `NumberStyles.Any` (line 90) and
  `NumberFormat` to `NumberFormatInfo.CurrentInfo` (line 54). Failure throws
  and the control keeps its value; nothing is filtered at the keystroke.
- .NET's number parser reads ASCII digits ONLY (`IsDigit(uint ch) =>
  (ch - '0') <= 9`, Number.Parsing.Common.cs line 347), whatever the
  culture's `NativeDigits`: Arabic-Indic digits are refused in every
  culture, ar-EG included.
- Decimal: the culture's `NumberDecimalSeparator` (or, with a currency
  style such as `Any`, the currency one too: lines 47-55, 164). Grouping
  under `AllowThousands` (part of `Any`) accepts the group separator
  ANYWHERE after the first digit with no placement check (line 169). So
  under de-DE `3.5` is read as 35 and `1.2.3` as 123: the converts case.
- .NET MAUI has no numeric up-down; `Entry` with `Keyboard.Numeric` on
  Android swaps in `LocalizedDigitsKeyListener`, which accepts ASCII `0-9`,
  an optional `-` and the CURRENT CULTURE's single decimal separator in
  place of `.` (lines 30-45, ~95-105). The parse is the app's own (usually
  `double.Parse` with the culture, i.e. the rules above).

## 4. How the proposed rule compares

No surveyed toolkit has exactly the proposed rule; there is no common
answer to copy. The toolkits fall into three families:

1. ASCII and `.` always, the locale's form as well: GTK (`g_strtod`
   tries both), Chromium and Firefox (the HTML parse first or as the
   fallback), and the plain-parse apps (Compose + `toDoubleOrNull`, Flutter
   + `double.parse`, Android's compat key listener), which have no locale
   form at all.
2. The locale's form only, read by ICU or a CLDR copy: Apple, WinUI's
   `DecimalFormatter`, Android with `imeHintLocales`, Qt, Flutter + intl,
   .NET. Within it the digit sets differ: ICU reads ANY Unicode digit set
   in any locale (Apple; Firefox's second pass), Qt reads the locale's own
   digits plus ASCII, intl and hinted Android read the locale's own only,
   .NET reads ASCII only.
3. Keystroke filters with a fixed set (Android compat, GTK `numeric`,
   MAUI), which decide by character before any parse.

Against them:

- DIGITS (A, B, C). "ASCII plus the locale's own" is exactly Qt's rule
  (`digitValue` falling through to ASCII) and Chromium's (its filter keeps
  `0-9` plus the locale's digits). It is stricter than ICU (Apple, Firefox),
  which also reads `٣٤` under en-US; and more lenient than .NET (ASCII
  only), intl and hinted Android (locale only). Nobody surveyed refuses
  ASCII under ar-EG except intl and hinted Android, and both are cases
  where the app opted into the locale's digit set.
- `.` UNDER ar-EG (F). Split. Accepted by GTK, Chromium, Firefox, Android
  compat, Flutter's `double.parse`; refused by Apple/ICU, Qt, intl, .NET,
  MAUI and hinted Android. But every toolkit that accepts it does so
  because it accepts `.` in EVERY locale, de-DE included. None accepts
  `.` conditionally on the locale not using it ("wherever `.` has no other
  meaning"). The proposed rule is the only one in the survey that makes
  that distinction; it is more lenient than the ICU family under ar-EG and
  stricter than the always-`.` family under de-DE.
- `.` UNDER de-DE (E). The proposed refusal matches Apple, WinUI, Qt in its
  default range, MAUI and hinted Android. All the others commit a
  number: GTK, Chromium, Firefox and the Compose/Flutter plain parses commit 3.5,
  while Avalonia, Qt with a range of 1000 or more, and intl drop the `.` as
  grouping and commit 35, and SwiftUI's `TextField(value:format:)` commits
  the prefix, 3. Toolkits disagree about what `3.5` means under de-DE, so
  refusing it is the only answer that cannot commit the wrong number.
- GROUPING (G). Split again: ICU (Apple), WinUI and Qt accept the
  locale's own grouping; GTK, the web and every keystroke filter refuse it.
  The rule's wording ("the locale's own separators") would accept it, while
  number-field-plan §3 rule 5 parses ungrouped; that difference is unruled.

Where leniency would misread a number:

1. Accepting `.` as a decimal in a locale where `.` groups (de-DE): GTK,
   Chromium and Firefox all read de-DE `1.234` as 1.234 when the user
   meant 1234 (GTK measured). The proposed rule refuses it; this is the
   case the "no other meaning" clause exists for.
2. Accepting a group separator anywhere: .NET's parser (and so Avalonia)
   and Qt's spin box retry read de-DE `3.5` as 35.
3. Committing a parsed prefix: SwiftUI's FormatStyle parse (measured) and
   ICU's `NumberFormat.parse(String)` stop at the first character they
   cannot use (`3.5` → 3 under de-DE). kaya's door already demands the
   whole text on the Apple arm (fmt.rs `parse_in`'s range check) and on
   Android (`kayaWholeNumber` in KayaFormat.kt).
4. ICU's EQUIVALENCE CLASSES under ar-EG, which is the one misread the
   proposed rule could inherit from the platforms kaya parses with: ICU
   puts `٫` in the comma class, so Apple reads ar-EG `3,5` as 3.5 and
   would read `1,234` as 1.234 (measured; docs/probes/arabic-digits-2026-10-01.md
   §3 also has `3,5` READ on the Apple arm). An Egyptian user typing Latin
   convention `1,234` means 1234. If the rule is "the locale's own
   separators", `,` is not one of them under ar-EG, so the rule must be
   enforced by kaya over the platform parse (as the WinUI arm already
   filters characters before `ParseDouble`), not left to ICU. And with `.`
   accepted as ar-EG's decimal, a text containing both `,` and `.` under
   ar-EG must be refused, never read with `,` as a group, or the
   ICU-lenient reading (`1.234` → 1234, Apple lenient, measured) would sit
   beside kaya's `.`-as-decimal reading of the same text on the other arms.

Not settled by this pass:

- WinUI cases A, C and F (`ParseDouble`'s digit sets and `.` under ar-EG)
  need the windows VM; the docs do not say.
- Case C under the proposed rule: as worded it refuses `٣٤` under en-US,
  which Apple, Firefox and GTK accept; whether "the locale's own digits"
  should be "any decimal digit set" is a ruling.
- Grouping (G), wording versus plan §3 rule 5.
- Android's and intl's ar-EG behaviour is read from source, not run.

## Cleanup

Only `docker run --rm` probes were started (`docker ps` empty after);
the Foundation probe ran as its own short process. No VM, emulator or
simulator was touched.

## Measurements, 2026-10-02

Typing into each platform's own number entry under ar-EG, de-DE and en-US,
for the three options the maintainer is choosing between: (A) each
platform's own parsing exactly; (B) one kaya rule enforced over the
platform parse; (C) the platform's own parsing, with kaya refusing only
inputs where a misread is possible or the platforms disagree. Filled in
platform by platform as measured.


### Windows: `DecimalFormatter.ParseDouble` (measured)

The windows lane's VM (Windows 11 arm64, user format en-US, home region US),
probe docs/probes/number-input-2026-10-01/windows/parse-double.ps1: a
`DecimalFormatter` per language built the way NumberBox's default is
(`[lang]`, the home region, `NumberRounder` null, `IntegerDigits` 1,
`FractionDigits` 0), each text through `ParseDouble`. `IsGrouped` true and
false gave identical answers for every text, and a default-constructed
formatter (the user's settings, en-US) answered as the en-US column.

| typed | en-US | de-DE | ar-EG |
|---|---|---|---|
| `34` | 34 | 34 | 34 |
| `3.5` | 3.5 | null | 3.5 |
| `3,5` | null | 3.5 | null |
| `٣٤` | 34 | 34 | 34 |
| `٣٫٥` | 3.5 | 3.5 | 3.5 |
| `٣.٥` / `٣,٥` / `3٫5` (mixed) | null | null | null |
| `1,234.5` | 1234.5 | null | 1234.5 |
| `1.234,5` | null | 1234.5 | null |
| `1.234` | 1.234 | 1234 | 1.234 |
| `1,234` | 1234 | **1.234** | 1234 |
| `12,34` / `1,23,4.5` / `1.2.3` / `12.34,5` (misplaced) | null | `12,34` → 12.34, others null | null |
| `١٬٢٣٤` | 1234 | null | 1234 |
| `١٬٢٣٤٫٥` | 1234.5 | null | 1234.5 |
| `١٢٬٣٤` (misplaced) | null | null | null |
| `-3.5` | -3.5 | null | -3.5 |
| `-3,5` | null | -3.5 | null |
| `-٣٫٥` | -3.5 | -3.5 | -3.5 |
| `−3.5` (U+2212), ALM or RLM before `-` | null | null | null |
| ` 3.5 `, `+3.5`, `3.5e2` | null | null | null |

What ar-EG's formatter WRITES is `-١٢٣٤٫٥` (grouped `-١٬٢٣٤٫٥`): a plain
hyphen-minus with no direction mark.

- Under ar-EG, `ParseDouble` reads BOTH conventions whole: the Arabic one
  (`٣٫٥`, `١٬٢٣٤`) and the en-US one (`3.5`, `1,234` → 1234). So case F
  (`3.5`) is ACCEPTED on Windows, and `1,234` under ar-EG means 1234 here
  while Apple's ICU reads it as 1.234 (§3, measured): the two platforms
  disagree on the same text in the same locale.
- Arabic-Indic digits are read in every locale (case C accepted). The
  Arabic separators come with them under en-US and ar-EG (`١٬٢٣٤` → 1234),
  not under de-DE, where only an ungrouped `٣٫٥` reads.
- Grouping is placement-checked: `12,34` and `1,23,4.5` are refused under
  en-US, and a group separator after the decimal is refused.
- Under de-DE `1,234` is 1.234 (the locale's decimal), and `1.234` is 1234.
  Neither is refused; which one the user meant is the locale's reading.

### Windows: typed into a NumberBox (measured)

Typed on the VM's console session through schtasks `/it`, never over ssh.
The build is kaya's numberfield guest from a scratch worktree with
docs/probes/number-input-2026-10-01/windows/probe-build.diff applied: the
`type` verb sends a non-ASCII character as a `KEYEVENTF_UNICODE` key event
(how a touch keyboard or an IME delivers one), and
`KAYA_PROBE_STOCK_NUMBERBOX` skips kaya's `SetNumberFormatter`, which
leaves the NumberBox with its OWN default formatter (`GetRegionalSettingsAwareDecimalFormatter`,
the user's format). The scene (windows/nfprobe.steps) types each text
between alternating sentinel commits and presses Return; the record is
NumberBox's `ValueChanged` value in the verb trace (windows/analyze.py).
The field is the scene's 0..100 field, so a read above 100 shows as 100
and a negative one as 0: "acc" below means a value was committed. For the
stock box the user format was switched with `Set-Culture` (§ restoring
below); kaya's door ran under `KAYA_LOCALE`.

Stock NumberBox (the platform's own entry):

| typed | en-US | de-DE | ar-EG |
|---|---|---|---|
| `34` | 34 | 34 | 34 |
| `3.5` | 3.5 | refused | 3.5 |
| `3,5` | refused | 3.5 | refused |
| `٣٤` | 34 | 34 | 34 |
| `٣٫٥` | 3.5 | 3.5 | 3.5 |
| `1.234` | 1.234 | ≥100 (1234) | 1.234 |
| `1,234` | ≥100 (1234) | **1.234** | ≥100 (1234) |
| `1,234.5` | ≥100 | refused | ≥100 |
| `1.234,5` | refused | ≥100 | refused |
| `١٬٢٣٤` | ≥100 | refused | ≥100 |
| `12,34` | refused | 12.34 | refused |
| `1.2.3` | refused | refused | refused |
| `-3.5` | acc (negative) | refused | acc (negative) |
| `-3,5` | refused | acc (negative) | refused |
| `-٣٫٥` | acc (negative) | acc (negative) | acc (negative) |
| `٣.٥` | refused | refused | refused |

Every cell equals `ParseDouble` above: NumberBox filters no keystroke, and
the typed text is what its formatter parses on Return. Windows' own ar-EG
user format (what `Set-Culture ar-EG` writes) is `sDecimal` "." and
`sThousand` "," with Arabic-Indic native digits, while the formatter
writes `٫`; the stock ar-EG box reads both.

kaya's numberfield guest (the door: `fmt::parse_number` after the arm's
character filter, docs/number-field-plan.md §4.4):

| typed | en-US | de-DE | ar-EG |
|---|---|---|---|
| `34` | 34 | 34 | 34 |
| `3.5` | 3.5 | refused | **refused** |
| `3,5` | refused | 3.5 | refused |
| `٣٤` | 34 | 34 | 34 |
| `٣٫٥` | **refused** | **refused** | 3.5 |
| `1.234` | 1.234 | refused | refused |
| `1,234` | refused | 1.234 | refused |
| `1,234.5` / `1.234,5` / `١٬٢٣٤` | refused | refused | refused |
| `12,34` | refused | 12.34 | refused |
| `1.2.3` | refused | refused | refused |
| `-3.5` | acc | refused | refused |
| `-3,5` | refused | acc | refused |
| `-٣٫٥` | refused | refused | acc |
| `٣.٥` | refused | refused | refused |

So kaya's Windows arm today is STRICTER than the stock box: it refuses
all typed grouping, `3.5` under ar-EG and `٣٫٥` outside ar-EG, each of
which the stock box accepts. Its digit set is any digit (`٣٤` reads in
every locale) because the filter admits digits and `ParseDouble` reads
them.

### Windows: customised separators (measured)

The test user's format set to en-US with `sDecimal` "," and `sThousand`
"." (Region settings' "Additional settings", written to the registry),
then restored: the International key was exported before
(`reg export`), re-imported after, and the subkey `Set-Culture` had added
(U+1F30E U+1F30F U+1F30D, holding `Calendar = Gregorian`) deleted; the
key's listing before and after is identical (44 lines).

- The platform follows the customisation: a default-constructed
  `DecimalFormatter` AND one built with `["en-US"]` explicitly write
  `-1234,5` and read `3,5` → 3.5, `1.234` → 1234, `3.5` → null. The stock
  NumberBox answers exactly the stock de-DE column above.
- kaya's door follows it too, with no `KAYA_LOCALE`: the guest wrote `7,0`,
  read `3,5` and `12,34`, and refused `3.5` and `1.234`. It is still the
  stricter set (grouping refused, `٣٫٥` refused).
- So on Windows "the locale" is not a fixed table: the same en-US user can
  mean `,` as the decimal, and a rule written per locale name (option B)
  would contradict the user's own setting unless it is read from the
  formatter rather than from the locale's name.

Nothing left on the VM: no probe process before or after (`tasklist`),
the `kaya_nfprobe` task deleted, C:\kaya\nfprobe and the probe exe
removed.

### Android (measured)

The android lane's emulators (API 35, Gboard), nothing rebooted or
reset, no setting changed. Two instruments:

1. A hand-built probe app (docs/probes/number-input-2026-10-01/android/:
   Probe.java, AndroidManifest.xml, build.sh; targetSdk 35), installed on
   the pool tablet and uninstalled after (its package list before and after
   identical). Two stock `EditText`s with `numberDecimal|numberSigned`: one
   plain ("compat"), one with `setImeHintLocales(locale)` ("hinted", which
   installs the locale-aware `DigitsKeyListener`). Each text goes in twice:
   through the field's own `InputConnection.commitText` (the route an IME
   such as Gboard uses) and as key events from the virtual key map (ASCII
   only). The two routes agreed for every ASCII text except `1.2.3`
   (below). Beside them, android.icu `NumberFormat.parse` over the same text.
2. kaya's numberfield guest (the rusthost app the lane installed,
   2026-10-01) under `KAYA_LOCALE`, driven by its own harness: ASCII texts
   by `type` (key events through the activity), the others by `set_text`
   (the Compose field has no key listener, so a committed text reaches the
   parse unchanged either way), then `press return`
   (docs/probes/number-input-2026-10-01/android/mkscript.py and runkaya.py,
   which read the case list the Windows probe wrote).

What the stock EditText keeps of the typed text (the field's text after
the IME commits it; "" = every character dropped):

| typed | compat (any locale) | hinted en-US | hinted de-DE | hinted ar-EG |
|---|---|---|---|---|
| `34` | 34 | 34 | 34 | "" |
| `3.5` | 3.5 | 3.5 | **35** | "" |
| `3,5` | **35** | **35** | 3,5 | "" |
| `٣٤` | "" | "" | "" | ٣٤ |
| `٣٫٥` | "" | "" | "" | ٣٫٥ |
| `1.234` | 1.234 | 1.234 | 1234 | "" |
| `1,234` | 1234 | 1234 | 1,234 | "" |
| `1,234.5` | 1234.5 | 1234.5 | **1,2345** | "" |
| `1.234,5` | **1.2345** | **1.2345** | 1234,5 | "" |
| `١٬٢٣٤` | "" | "" | "" | ١٢٣٤ |
| `12,34` | 1234 | 1234 | 12,34 | "" |
| `1.2.3` | 12.3 (IME) / 1.23 (keys) | same | 123 | "" |
| `-3.5` | -3.5 | -3.5 | **-35** | - |
| `-3,5` | **-35** | **-35** | -3,5 | - |
| `-٣٫٥` | - | - | - | -٣٫٥ |
| `٣.٥` | . | . | "" | **٣٥** |

- The stock EditText does not refuse a text: it DROPS each character its
  listener does not accept and keeps the rest, so a separator the field
  does not take silently merges the digits around it. `3,5` typed into a
  plain numberDecimal field under de-DE becomes 35; with the hint locale,
  `3.5` becomes 35. Typed key by key, the dropped key simply does nothing,
  so the user sees it only by looking.
- The hinted field under ar-EG drops every ASCII digit, and "." and ",";
  it keeps only Arabic-Indic digits and `٫` (and drops `٬`).
- Gboard (pictures not kept): for the plain field, and for kaya's Compose
  field under ar-EG with `٧٫٠` on screen, the pad is ASCII `0-9`, `-`,
  space, `,` and `.` in every locale. For a hinted field Gboard abandons
  the number pad and shows the hint locale's full letter keyboard (a QWERTY letter
  keyboard labelled DE·EN for de-DE; the Arabic letters for ar-EG, with
  Arabic-Indic digits on the top row's long-press). So a user of kaya's
  Android field under ar-EG can TYPE only ASCII digits and `,`/`.` from
  the pad the field asks for.

android.icu `NumberFormat.parse` over the whole text (kaya's door: grouping
off; "lenient" = the default instance, grouping on):

| typed | en-US kaya / lenient | de-DE kaya / lenient | ar-EG kaya / lenient |
|---|---|---|---|
| `3.5` | 3.5 / 3.5 | null / null | null / null |
| `3,5` | null / null | 3.5 / 3.5 | **3.5 / 3.5** |
| `٣٤` | 34 / 34 | 34 / 34 | 34 / 34 |
| `٣٫٥` | null / null | **3.5 / 3.5** | 3.5 / 3.5 |
| `٣.٥` | **3.5 / 3.5** | null / null | null / null |
| `1.234` | 1.234 / 1.234 | null / 1234 | null / 1234 |
| `1,234` | null / 1234 | 1.234 / 1.234 | **1.234 / 1.234** |
| `1,234.5` | null / 1234.5 | null / null | null / null |
| `1.234,5` | null / null | null / 1234.5 | null / 1234.5 |
| `١٬٢٣٤` | null / 1234 | null / 1234 | null / 1234 |
| `12,34` | null / 1234 | 12.34 / 12.34 | 12.34 / 12.34 |
| `-3.5` / `-3,5` / `-٣٫٥` | -3.5 / null / null | null / -3.5 / -3.5 | null / -3.5 / -3.5 |

(The lenient instance accepts `12,34` under en-US as 1234: ICU's lenient
grouping does not check positions. `NumberFormat.parse(String)` without a
position commits the PREFIX: `3.5` → 3 under de-DE and ar-EG.)

kaya's numberfield guest committed exactly the "kaya" half of each cell
(0..100 field; a refused text left the sentinel): en-US read `34`, `3.5`,
`٣٤`, `1.234` (→ 1.2 at the step's digits), `٣.٥` and `-3.5` and refused
the rest; de-DE and ar-EG gave IDENTICAL answers to each other, reading
`34`, `3,5`, `٣٤`, `٣٫٥`, `1,234` (as 1.234), `12,34` (as 12.34),
`-3,5` and `-٣٫٥`, and refusing `3.5`, `1.234`, all grouping and `٣.٥`.

- Under ar-EG, ICU (and so kaya's Android door) treats `,` as the
  decimal, because `٫` is in ICU's comma class: an Egyptian typing on the
  ASCII pad gets `3,5` → 3.5 and `1,234` → 1.234, and `3.5` reverts. The
  Windows stock box under ar-EG reads the same `1,234` as 1234 and `3.5`
  as 3.5. Same text, same locale, two platforms, two values.
- Under en-US, `٣.٥` (Arabic-Indic digits, Latin point) reads 3.5 on
  Android and Apple (ICU) and is refused on Windows; `٣٫٥` is refused on
  Android and read on Windows.
- Android exposes no user setting for the decimal or group separator
  (Android 14's regional preferences cover temperature, calendar, first
  day and numbering system; read from Android's documentation, not
  measured), so §4's customisation has no Android column.

### Apple: customised separators (measured on the mac, process-local)

The host's own settings were only read (`defaults read -g`: `AppleLocale`
en_US, no `AppleICUNumberSymbols`), never written. The probe
(docs/probes/number-input-2026-10-01/apple/custom-separators.swift) is run
with the customisation in its own ARGUMENT domain, `-AppleLocale <id>
-AppleICUNumberSymbols '{0 = <decimal>; 1 = <group>; 10 = …; 17 = …;}'`,
which is the key Apple's Number format setting has written to the global
domain (that macOS 26's Settings writes this same key was not checked,
since the host's settings are off limits). It asks three readers: a
default `NumberFormatter` (the current locale), Swift's
`Double(_:format: .number)` (the `FormatStyle` parse that
`TextField(value:format:)` uses), and kaya's own parse, a line-for-line
copy of fmt.rs `parse_in` over `CFLocaleCopyCurrent()`.

| typed | en_US NF / FS / kaya | en_US, decimal "," group "." NF / FS / kaya | de_DE, decimal "." group "'" NF / FS / kaya |
|---|---|---|---|
| `3.5` | 3.5 / 3.5 / 3.5 | nil / **3.5** / nil | 3.5 / **3** / 3.5 |
| `3,5` | nil / **3** / nil | 3.5 / **3** / 3.5 | nil / **3.5** / nil |
| `1.234` | 1.234 / 1.234 / 1.234 | 1234 / **1.234** / nil | 1.234 / **1234** / 1.234 |
| `1,234` | 1234 / 1234 / nil | 1.234 / **1234** / 1.234 | nil / **1.234** / nil |
| `1,234.5` | 1234.5 / 1234.5 / nil | nil / **1234.5** / nil | nil / **1.234** / nil |
| `12,34` | nil / **1234** / nil | 12.34 / **1234** / 12.34 | nil / **12.34** / nil |
| `٣٫٥` | nil / **3** / nil | 3.5 / **3** / 3.5 | nil / **3.5** / nil |

- `NumberFormatter` and the CoreFoundation formatter follow the
  customisation (they write `1.234,5` and `12,5`), and so kaya's Apple
  door follows it today when `KAYA_LOCALE` is unset. (With `KAYA_LOCALE`
  set, fmt.rs replaces the whole argument domain with the knob's locale,
  so the customisation is dropped.)
- Swift's `FormatStyle` parse IGNORES it: it parses with the base
  locale's symbols (en_US's `.`, de_DE's `,`) whatever the user chose, and
  still takes the prefix. A SwiftUI `TextField(value:format: .number)`
  under a customised format therefore reads `1.234` as 1.234 for a user
  whose decimal is "," (what that style WRITES under the customisation was
  not measured). Also measured: under plain en_US it reads `12,34` as 1234 (no
  grouping-position check).

### iOS simulator (measured)

One lane simulator (kaya-sim-0, iPhone, iOS 26), nothing erased or
rebooted. kaya's numberfield Swift guest run by tools/ios/run-sim.py from a
scratch worktree (docs/probes/number-input-2026-10-01/ios/runner.diff: one
simulator, the picker admission skipped since it can erase a device, a
longer leg ceiling, and a hook for launch arguments), with the two
numberfield scenes replaced by ios/probe-en.steps, probe-de.steps and
probe-ar.steps. Every text is TYPED by the lane's XCUITest driver
(`typeText`, real key events through the simulator's keyboard), then
Return; each case sits between sentinel commits and asserts the value the
field then holds, so a leg that PASSES has confirmed every cell below.
The field is the scene's `.decimalPad` field (0..100, step 0.5).

kaya's Apple door (CFNumberFormatter over the whole text, grouping off):

| typed | en-US | de-DE, ar-EG and customised en-US (identical) |
|---|---|---|
| `34` | 34 | 34 |
| `3.5` | 3.5 | refused |
| `3,5` | refused | 3.5 |
| `٣٤` | 34 | 34 |
| `٣٫٥` | refused | 3.5 |
| `٣.٥` | 3.5 | refused |
| `1.234` | 1.234 (→ 1.2) | refused |
| `1,234` | refused | 1.234 (→ 1.2) |
| `1,234.5` / `1.234,5` / `١٬٢٣٤` / `1.2.3` | refused | refused |
| `12,34` | refused | 12.34 (→ 12.3) |
| `-3.5` | acc (negative) | refused |
| `-3,5` / `-٣٫٥` | refused | acc (negative) |

All four legs PASSED with these as their assertions (en-US, de-DE, and a
second run with the second leg under ar-EG and the first, with no
`KAYA_LOCALE`, launched with `-AppleICUNumberSymbols '{0 = ","; 1 = ".";
…}'`, the customisation in the app's own argument domain; ~80s each).
ar-EG answered exactly as de-DE, through ICU's comma class: `3,5` and
`٣٫٥` read 3.5, `1,234` reads 1.234, and `3.5` reverts. This is the mac
Foundation table of §3 with grouping off, case for case.

Customised separators on iOS: the guest launched with the customisation
drew its value as `8,0` and read every text as the de-DE column, so kaya's
Apple door follows a user's custom number format today (when
`KAYA_LOCALE` is unset; the knob replaces the argument domain).

What the keyboard offers (pictures taken mid-leg, viewed, not kept): the
`.decimalPad` has ASCII digits in all three locales and ONE separator key:
`,` under de-DE, `,` under the customised en-US (so the pad follows the
custom format), and under ar-EG a key drawn as a centred dot, not `٫`;
which character that key inserts was not measured. The pad has no minus.
Under ar-EG, then, the phone user's pad offers ASCII digits and (as drawn)
`.`, and kaya's iOS door refuses `3.5`. The `3.5` rows under de-DE and the
`1,234.5` rows are reachable only from a hardware keyboard or a paste
(XCTest synthesizes the key, so the driver reaches them).

### The three options, filled

What each option commits, per platform, for the cases typed above.
"Meant" is what the user most plausibly meant; where the text itself is
ambiguous the row says so. **MISREAD** marks a cell where the field
commits a number the user did not mean, with no refusal. Sources: Windows,
Android and iOS from this section; macOS from §3 and the custom probe
above; the iOS column is that same Foundation table, since the iOS legs
measured kaya's grouping-off door and it matched the mac's answers
wherever grouping does not enter. Linux is GtkSpinButton's default from
§3 (glibc, measured in the lane image), except en-US `٣.٥` and `12,34`,
which follow from its mechanism and were not run. "ref" = the text reverts. Minus rows are left out: every
platform and every option read `-3.5` in en-US, and the only minus
divergence is the locale's own (de-DE `-3.5` refused where `3.5` is).

**A. Each platform's own parsing, exactly** (Windows: the stock
NumberBox; Android: android.icu `NumberFormat` over the whole text, the
default lenient instance; Apple: `NumberFormatter`, whole text; Linux:
GtkSpinButton's default `g_strtod` input):

| case (locale, typed, meant) | Windows | Android | iOS | macOS | Linux |
|---|---|---|---|---|---|
| ar-EG `34` (34) | 34 | 34 | 34 | 34 | 34 |
| ar-EG `٣٫٥` (3.5) | 3.5 | 3.5 | 3.5 | 3.5 | ref |
| en-US `٣٤` (34) | 34 | 34 | 34 | 34 | 34 |
| en-US `٣.٥` (3.5) | ref | 3.5 | 3.5 | 3.5 | ref |
| de-DE `3,5` (3.5) | 3.5 | 3.5 | 3.5 | 3.5 | 3.5 |
| de-DE `3.5` (3.5, Latin habit) | ref | ref | ref | ref | 3.5 |
| ar-EG `3.5` (3.5) | 3.5 | ref | ref | ref | 3.5 |
| ar-EG `3,5` (ambiguous: 3.5 or 35) | ref | 3.5 | 3.5 | 3.5 | ref |
| de-DE `1.234` (1234) | 1234 | 1234 | 1234 | 1234 | **MISREAD 1.234** |
| en-US `1,234` (1234) | 1234 | 1234 | 1234 | 1234 | ref |
| ar-EG `1,234` (1234, Latin convention) | 1234 | **MISREAD 1.234** | **MISREAD 1.234** | **MISREAD 1.234** | ref |
| en-US `12,34` (misplaced group) | ref | **MISREAD 1234** | ref | ref | ref |
| de-DE `1.234,5` (1234.5) | 1234.5 | 1234.5 | 1234.5 | 1234.5 | ref |
| en-US user who chose decimal `,`, `1.234` (1234) | 1234 | n/a (no such setting) | 1234 | 1234 | not measured |

Under A the same text in the same locale commits different numbers on
different platforms (ar-EG `1,234`: 1234 on Windows, 1.234 on the ICU
platforms; de-DE `1.234`: 1234 everywhere but Linux), and Android's
default instance does not check where a group separator sits.

**B. One kaya rule** (any digit system; the locale's decimal mark, and
"." where "." has no other meaning; the locale's grouping only in correct
positions; enforced by kaya over the platform parse). The answer is the
same on all five by construction:

| case | all five |
|---|---|
| ar-EG `34` / `٣٫٥` | 34 / 3.5 |
| en-US `٣٤` / `٣.٥` | 34 / 3.5 |
| de-DE `3,5` / `3.5` | 3.5 / ref (`.` is de-DE's group, misplaced) |
| ar-EG `3.5` / `3,5` | 3.5 / ref (`,` is neither ar-EG mark) |
| de-DE `1.234` | 1234 |
| en-US `1,234` / `12,34` | 1234 / ref |
| ar-EG `1,234` | ref |
| de-DE `1.234,5` | 1234.5 |
| en-US user who chose decimal `,`: `1.234` | 1234 if "the locale's marks" are read from the platform's formatter (which follows the user on Windows and Apple, measured); **MISREAD 1.234** if read from the locale's name |

No MISREAD cell under B as long as the marks come from the platform's
own formatter. Its costs, measured: Windows' stock box and Linux accept
ar-EG `3.5` today and B keeps that, while the ICU platforms' own parsers
(and kaya's Android and Apple arms today) refuse it; ar-EG `3,5`, which
three platforms read as 3.5, reverts; and on the phones B can only refuse
what the keyboard offers: Android's pad offers ASCII digits, `,` and `.`
in every locale (so under ar-EG `,` reverts and `.` reads), and iOS's
offers one separator key per locale.

**C. The platform's own parsing, kaya refusing only where a misread is
possible or the platforms disagree** (A's cells, with a cell refused when
another platform commits a different value for the same text in the same
locale, or when the text is one of the measured misread shapes: `.`
where it groups, a group separator in a wrong place, `,` under ar-EG):

| case | Windows | Android | iOS | macOS | Linux |
|---|---|---|---|---|---|
| ar-EG `34` | 34 | 34 | 34 | 34 | 34 |
| ar-EG `٣٫٥` | 3.5 | 3.5 | 3.5 | 3.5 | ref |
| en-US `٣٤` | 34 | 34 | 34 | 34 | 34 |
| en-US `٣.٥` | ref | 3.5 | 3.5 | 3.5 | ref |
| de-DE `3,5` | 3.5 | 3.5 | 3.5 | 3.5 | 3.5 |
| de-DE `3.5` | ref | ref | ref | ref | ref (Linux would read 3.5) |
| ar-EG `3.5` | 3.5 | ref | ref | ref | 3.5 |
| ar-EG `3,5` | ref | ref | ref | ref | ref |
| de-DE `1.234` | ref (platforms disagree) | ref | ref | ref | ref |
| en-US `1,234` | 1234 | 1234 | 1234 | 1234 | ref |
| ar-EG `1,234` | ref (platforms disagree) | ref | ref | ref | ref |
| en-US `12,34` | ref | ref | ref | ref | ref |
| de-DE `1.234,5` | 1234.5 | 1234.5 | 1234.5 | 1234.5 | ref |

No MISREAD cell under C either, but it is not one behaviour: the same
text still commits on some platforms and reverts on others (ar-EG `3.5`,
ar-EG `٣٫٥`, en-US `٣.٥`, en-US `1,234`), and "the platforms disagree" is
only decidable if kaya carries every other platform's answers, which is a
kaya rule written as a table of exceptions. It also refuses de-DE
`1.234`, which every platform but Linux reads correctly, because Linux
does not.

kaya today, for comparison (the four arms as measured above and §3 for
glibc): Windows refuses all grouping, ar-EG `3.5` and `٣٫٥` outside ar-EG;
Android and Apple refuse grouping and read ar-EG `1,234` as **1.234** and
ar-EG `3,5` as 3.5 (the one MISREAD the current arms carry, through ICU's
comma class); Linux reads only ASCII digits and glibc's two separators.

### Not settled by these measurements

- Which character the iOS `.decimalPad`'s separator key inserts under
  ar-EG (drawn as a centred dot): if it is `.`, kaya's iOS door refuses
  the only separator the user's pad offers.
- Whether macOS 26's own Number format setting writes
  `AppleICUNumberSymbols` (the probe used the argument domain, and the
  host's settings were not touched).
- Real keyboards: the Windows typing used `KEYEVENTF_UNICODE` (an IME's
  route); what Windows' Arabic keyboard layout types for the digit row
  was not measured.
- What "meant" is for ar-EG `3,5` and de-DE `3.5` is a judgement about
  users, not a measurement.

### Cleanup, 2026-10-02

Windows: the International key restored and its listing identical to
before (44 lines), `kaya_nfprobe` deleted, no probe process in
`tasklist`, C:\kaya\nfprobe and the probe exe removed. Android: the
probe package uninstalled (package list identical), no kaya or probe
process on the four pool devices, locales and IME unchanged. iOS: the
pool still booted, the runner reported "xcui drivers stopped (2); runner
processes left: none", and the two probe-built apps uninstalled from
kaya-sim-0 (the lane installs its own on every run).
