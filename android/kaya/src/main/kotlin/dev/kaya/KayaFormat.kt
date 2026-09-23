package dev.kaya

import android.content.Context
import android.icu.text.DateFormat
import android.icu.text.NumberFormat
import android.icu.text.NumberingSystem
import android.icu.util.Calendar
import android.icu.util.Currency
import android.icu.util.ULocale
import java.util.Locale

/**
 * The formatter door's Android arm (docs/compliance-plan.md §2.3, the
 * Android row): `android.icu` over the process default locale, called by
 * the core over JNI from the app thread (crates/kaya/src/fmt.rs, the
 * android module). The entries that write a time take the application
 * Context, because the hour cycle is the platform's own setting and only
 * `android.text.format.DateFormat.is24HourFormat(context)` reads it —
 * `android.icu` does not (docs/measurements/compliance-probes-2026-09-21.md,
 * U10), so every time goes through the `Hm`/`hm` skeleton rather than
 * ICU's own time style.
 *
 * The harness's `{fmt:…}` template is answered by a SECOND spelling in
 * KayaCompose.kt (`kayaPlatformFormatted`, java.text), never by this
 * object (R9).
 */
object KayaFormat {
    private fun style(length: Int): Int = when (length) {
        0 -> DateFormat.SHORT
        2 -> DateFormat.LONG
        else -> DateFormat.MEDIUM
    }

    private fun locale(): ULocale = ULocale.getDefault(ULocale.Category.FORMAT)

    private fun calendar(y: Int, m: Int, d: Int, h: Int, mi: Int): Calendar =
        Calendar.getInstance(locale()).apply {
            clear()
            set(y, m - 1, d, h, mi, 0)
        }

    /**
     * The platform's own rule for the hour cycle — the user's 12/24 setting
     * when set, else the locale's default — run over the PROCESS locale:
     * `is24HourFormat(context)` falls back to the context's own locale,
     * which is the system's and not the one the knob installed, so a
     * German leg read `8:30 AM` until the fallback was given the process
     * locale (measured 2026-09-23).
     */
    @JvmStatic
    fun twentyFourHours(context: Context, locale: Locale): Boolean {
        val forced = android.content.res.Configuration(context.resources.configuration).apply {
            setLocales(android.os.LocaleList(locale))
        }
        return android.text.format.DateFormat.is24HourFormat(context.createConfigurationContext(forced))
    }

    /** The hour skeleton the platform's own setting asks for. */
    private fun hourSkeleton(context: Context, length: Int): String {
        val twentyFour = twentyFourHours(context, Locale.getDefault())
        return when (length) {
            0 -> if (twentyFour) "Hm" else "hm"
            2 -> if (twentyFour) "Hmsz" else "hmsz"
            else -> if (twentyFour) "Hms" else "hms"
        }
    }

    private fun dateSkeleton(length: Int): String = when (length) {
        0 -> "yyMd"
        2 -> "yMMMMd"
        else -> "yMMMd"
    }

    @JvmStatic
    fun date(y: Int, m: Int, d: Int, length: Int): String =
        DateFormat.getDateInstance(style(length), locale())
            .format(calendar(y, m, d, 12, 0).time)

    @JvmStatic
    fun dateWeekday(y: Int, m: Int, d: Int): String =
        DateFormat.getInstanceForSkeleton("EEEdMMM", locale())
            .format(calendar(y, m, d, 12, 0).time)

    /**
     * THE TIME FAMILY TAKES THE PLATFORM'S OWN PATTERN, not ICU's: the
     * text-format class's pattern generator writes a plain space before the
     * day period where `getInstanceForSkeleton` keeps CLDR's U+202F, and
     * the platform's own time APIs write the space (docs/traps.md, the
     * Android time byte). ICU still does the formatting, so the digits
     * and the day period are the locale's.
     */
    private fun byPlatformPattern(skeleton: String): DateFormat =
        android.icu.text.SimpleDateFormat(
            android.text.format.DateFormat.getBestDateTimePattern(Locale.getDefault(), skeleton),
            locale(),
        )

    @JvmStatic
    fun time(context: Context, h: Int, mi: Int, length: Int): String =
        byPlatformPattern(hourSkeleton(context, length)).format(calendar(2000, 1, 1, h, mi).time)

    @JvmStatic
    fun dateTime(context: Context, y: Int, m: Int, d: Int, h: Int, mi: Int, length: Int): String =
        byPlatformPattern(dateSkeleton(length) + hourSkeleton(context, length))
            .format(calendar(y, m, d, h, mi).time)

    private fun digits(f: NumberFormat, min: Int, max: Int, grouping: Boolean) {
        if (min >= 0) f.minimumFractionDigits = min
        if (max >= 0) f.maximumFractionDigits = maxOf(max, f.minimumFractionDigits)
        f.isGroupingUsed = grouping
    }

    @JvmStatic
    fun number(value: Double, min: Int, max: Int, grouping: Boolean): String =
        NumberFormat.getInstance(locale()).also { digits(it, min, max, grouping) }.format(value)

    @JvmStatic
    fun percent(value: Double, min: Int, max: Int, grouping: Boolean): String =
        NumberFormat.getPercentInstance(locale()).also { digits(it, min, max, grouping) }.format(value)

    @JvmStatic
    fun currency(value: Double, code: String): String =
        NumberFormat.getCurrencyInstance(locale()).also { it.currency = Currency.getInstance(code) }
            .format(value)

    /**
     * Who the user is, one line: `<tag> <h12|h23> <first weekday, ISO>
     * <calendar> <numbering>` — the platform's own settings, the hour
     * cycle from the platform's text-format class, the rest from ICU's
     * reading of the default locale's extensions (Android 14's `fw`,
     * `ca`, `nu`).
     */
    @JvmStatic
    fun locale(context: Context): String {
        val loc = locale()
        val cycle = if (twentyFourHours(context, Locale.getDefault())) "h23" else "h12"
        val cal = Calendar.getInstance(loc)
        // ICU counts Sunday as 1; ISO 8601 counts Monday as 1.
        val first = if (cal.firstDayOfWeek == Calendar.SUNDAY) 7 else cal.firstDayOfWeek - 1
        val numbering = NumberingSystem.getInstance(loc).name
        return "${loc.toLanguageTag()} $cycle $first ${cal.type} $numbering"
    }

    /**
     * `KAYA_LOCALE`'s install (docs/compliance-plan.md §2.2, the Android
     * row): the process default, which every ICU and java.text formatter
     * reads, set by the CORE before the app thread exists
     * (crates/kaya/src/android.rs's attach). The composition half — the
     * forced Configuration and layout direction — is KayaCompose's
     * `localeAsked`. Answers the tag the platform now reads back.
     */
    @JvmStatic
    fun installLocale(tag: String): String {
        val locale = Locale.forLanguageTag(tag)
        Locale.setDefault(locale)
        return Locale.getDefault().toLanguageTag()
    }
}
