# ar-EG digits on the glibc arm — measurement notes (2026-10-01, tree 2b3cb0c5)

VERDICT: STOP, a ruling. The Linux platform's own data (glibc, which GTK, GLib
and GNOME read) names ASCII digits and a full stop for ar_EG. Nothing in the
repo was changed.

## 1. glibc in the lane image (kaya-linux:latest, Debian GLIBC 2.41-12+deb13u4)
Probe: docs/probes/arabic-digits-2026-10-01/probe.c, run in the image with setlocale(LC_ALL, "ar_EG.UTF-8").
- localeconv: decimal_point ".", thousands_sep ",", grouping 3; mon "." ","; EGP; ج.م.
- printf: %f 3.500000; %'.3f 1,234,567.891; %I.1f 3.5 (ASCII); %'Id 1,234,567; %I.1f -3.5
- nl_langinfo RADIXCHAR ".", THOUSEP ","; ALT_DIGITS empty
- strftime %x "07 سبت, 2026"; %Od %Om %Ey "07 09 26" (ASCII, no alt digits)
- strfmon %n "ج.م. 1,234,567.890"
- Source /usr/share/i18n/locales/ar_EG: LC_CTYPE is `copy "i18n"` with NO
  `outdigit` and no to_inpunct/to_outpunct maps; LC_NUMERIC "." "," 3.
  The locales that DO define `outdigit` in this glibc: bn_BD fa_IR gu_IN hi_IN
  kn_IN ml_IN mnw_MM my_MM or_IN pa_IN ps_AF shn_MM ta_IN te_IN — no Arabic
  locale at all. fa_IR shows the mechanism exists (outdigit U+06F0.., to_inpunct
  mapping "." to U+066B), so ar_EG's absence is the data, not a missing feature.
- History (gh api bminor/glibc commits on localedata/locales/ar_EG, 2000-2024):
  no commit ever added digits; the last change is the 2024 UTF-8 revert.
  Prior art: Khaled Hosny on arabeyes developer list, 2007-07-14
  (https://www.mail-archive.com/developer@arabeyes.org/msg03477.html):
  "Egypt ... uses Arabic-Indic digits, the locale definition should reflect
  this, which it doesn't currently." Never acted on upstream.
- GNOME/GTK: GtkSpinButton's own output is printf ("%0.*f"), GLib's
  g_date_time_format %O uses the locale's outdigits (none for ar_EG), so GTK
  and GNOME under ar_EG write ASCII. No GNOME app (calculator, clocks) is in
  the image to photograph; this is read from the data they consume.

## 2. ICU on the same image (libicu76 76.1-4, present as a dependency; docs/probes/arabic-digits-2026-10-01/icu.c)
- unum DECIMAL ar_EG / ar-EG: 3.5 -> ٣٫٥; -40 -> U+061C-٤٠ (ALM before the minus);
  1234.25 -> ١٢٣٤٫٢٥; grouped 1234567.891 -> ١٬٢٣٤٬٥٦٧٫٨٩١. de_DE 3,5; en_US 3.5.
- parse (grouping off, whole text): ar_EG reads ٣٫٥, 3٫5, ٣,٥, 3,5, -٤٠, −٤٠,
  ALM-٤٠, -40, ١٢٣٤٫٢٥, ۳٫۵; STOPS at "." (3.5 -> 3 at 1/3, 1234.25 -> 1234 at 4/7).
  de_DE reads ٣٫٥ and ٣,٥ as 3.5; en_US refuses both.

## 3. Apple (this Mac, CFNumberFormatter, docs/probes/arabic-digits-2026-10-01/cf.c)
- ar-EG writes ٣٫٥, ALM-٤٠, ١٬٢٣٤٬٥٦٧٫٨٩١ (identical to ICU above).
- parse, whole range required (the arm's rule): ar-EG READS ٣٫٥, 3٫5, 3,5, ٣,٥,
  -40, -٤٠, ALM-٤٠, ١٢٣٤٫٢٥; REFUSES 3.5, ٣.٥, 1234.25 (the full stop).
  de-DE READS ٣٫٥ and 3٫5 as 3.5 (٫ is treated as a comma-decimal equivalent).
  en-US reads ٣.٥ as 3.5 and refuses ٣٫٥.
  So Apple's rule is: any decimal digit set, the locale's separator (with ٫ and
  , lenient-equivalent). It is NOT "ASCII or native, same separator".

## 4. Other arms (from the tree, not re-measured here)
- Windows: fmt.rs win_tests freeze ar-EG 3.5 -> ٣٫٥ (VM, 2026-09-28,
  number-field-plan §4.4); parse_in admits only numeric chars plus those the
  formatter writes for -1.5.
- Android: KayaFormat.kt parseNumber over android.icu (same ICU behaviour as §2
  expected; not measured on the emulator in this pass).
- glibc arm (kaya's own): writes 3.5, reads ASCII digits and "." only.

## 5. The ruling to ask
The door's Linux row is glibc by design (compliance-plan §1.3/§2.3: the
platform formats, never a bundled ICU). glibc says ASCII + "." for ar_EG, and
so does every GTK/GNOME surface that reads it. Options:
 (a) keep glibc: the divergence is the platform's, recorded as a carve-out
     (Linux ar-EG writes ASCII), and only the PARSE is made uniform;
 (b) the Linux arm writes CLDR's ar-EG (Arabic-Indic, ٫, ٬) — through the ICU
     already in the image (a new runtime dependency on libicu for the Linux arm,
     which the §1.3 ruling did not take) or a kaya-held digit table (kaya's own
     locale data, which §1.3 also declined);
 (c) the Linux arm maps glibc's ASCII through a kaya digit rule only where the
     tag's CLDR numbering is `arab` (kaya's own data again).
Parse uniformity is a second, separable question: the platforms do NOT agree
today (Apple and ICU read any digit set but only the locale's separator, so a
Latin-keyboard "3.5" under ar-EG is refused on Apple/Android; the glibc arm
refuses Arabic-Indic). A uniform kaya rule ("either digit set, the locale's
separator, plus the ASCII full stop under a locale whose separator is ٫"?) is
itself a ruling.

## Cleanup
Only `docker run --rm` probes were started; none left (docker ps empty, see
final check). No VM, emulator or simulator was touched.
