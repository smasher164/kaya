// The formatter door and the catalog (docs/compliance-plan.md §1.4, the C#
// row): pure calls over the core's kaya_fmt_*, kaya_locale, kaya_direction,
// kaya_text_scale, kaya_catalog and kaya_tr. Any thread, no transaction.

using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

/// How much of a date or time to write: the numeric form, the abbreviated
/// words, the full words.
enum Length { Short = 0, Medium = 1, Long = 2 }

/// Which way the layout runs, decided by the locale's script.
enum Direction { Ltr = 0, Rtl = 1 }

/// What a number formatter may be told; a null digit count leaves the
/// platform's default.
readonly record struct NumberOptions(int? MinFractionDigits = null, int? MaxFractionDigits = null, bool Grouping = true);

/// Who the user is, as the platform reports it: BCP-47 tag, 12 or 24, the
/// first weekday (1 Monday … 7 Sunday), CLDR's calendar and numbering names.
readonly record struct LocaleInfo(string Tag, int HourCycle, int FirstWeekday, string Calendar, string Numbering);

static partial class Kaya
{
    [StructLayout(LayoutKind.Sequential)]
    struct KayaNumberOptions
    {
        public int MinFractionDigits;
        public int MaxFractionDigits;
        [MarshalAs(UnmanagedType.I1)] public bool Grouping;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct KayaTrArg
    {
        public IntPtr Name;
        public uint Tag;
        public long I;
        public double F;
        public IntPtr S;
    }

    const uint TR_INT = 0, TR_FLOAT = 1, TR_STR = 2, TR_DATE = 3, TR_TIME = 4;

    [DllImport("kaya")]
    static extern nuint kaya_fmt_date(long packed, long length, byte[]? into, nuint cap);

    [DllImport("kaya")]
    static extern nuint kaya_fmt_date_weekday(long packed, byte[]? into, nuint cap);

    [DllImport("kaya")]
    static extern nuint kaya_fmt_time(long packed, long length, byte[]? into, nuint cap);

    [DllImport("kaya")]
    static extern nuint kaya_fmt_date_time(long date, long time, long length, byte[]? into, nuint cap);

    [DllImport("kaya")]
    static extern nuint kaya_fmt_number(double value, in KayaNumberOptions options, byte[]? into, nuint cap);

    [DllImport("kaya")]
    static extern nuint kaya_fmt_number(double value, IntPtr options, byte[]? into, nuint cap);

    [DllImport("kaya")]
    static extern nuint kaya_fmt_percent(double value, in KayaNumberOptions options, byte[]? into, nuint cap);

    [DllImport("kaya")]
    static extern nuint kaya_fmt_percent(double value, IntPtr options, byte[]? into, nuint cap);

    [DllImport("kaya")]
    static extern nuint kaya_fmt_currency(double value, byte[] code, byte[]? into, nuint cap);

    [DllImport("kaya")]
    static extern nuint kaya_locale(byte[]? into, nuint cap);

    [DllImport("kaya")]
    static extern uint kaya_direction();

    [DllImport("kaya")]
    static extern double kaya_text_scale();

    [DllImport("kaya")]
    static extern void kaya_catalog(byte[] app);

    [DllImport("kaya")]
    static extern nuint kaya_tr(byte[] key, KayaTrArg[]? args, nuint nargs, byte[]? into, nuint cap);

    static byte[] CStr(string s) => Encoding.UTF8.GetBytes(s + "\0");

    /// One string-out core call twice, the ask-size-ask shape (PrefGetString's);
    /// a 0 answer is the core's fault report and is refused by name here rather
    /// than becoming a silent "".
    static string Filled(string what, Func<byte[]?, nuint, nuint> call)
    {
        int needed = (int)call(null, 0);
        if (needed == 0)
            throw new InvalidOperationException(
                $"kaya: {what} answered nothing — the core reported a fault (see its diagnostics)");
        byte[] into = new byte[needed];
        int written = (int)call(into, (nuint)needed);
        return Encoding.UTF8.GetString(into, 0, Math.Min(written, needed));
    }

    static long Packed(DateOnly d) => KayaWire.PackDate(d.Year, d.Month, d.Day);
    static long Packed(TimeOnly t) => KayaWire.PackTime(t.Hour, t.Minute);

    static string Number(string what, Func<IntPtr, byte[]?, nuint, nuint> bare,
        Func<KayaNumberOptions, byte[]?, nuint, nuint> with, NumberOptions? o)
    {
        if (o is not { } opts)
            return Filled(what, (into, cap) => bare(IntPtr.Zero, into, cap));
        var raw = new KayaNumberOptions
        {
            MinFractionDigits = opts.MinFractionDigits ?? -1,
            MaxFractionDigits = opts.MaxFractionDigits ?? -1,
            Grouping = opts.Grouping,
        };
        return Filled(what, (into, cap) => with(raw, into, cap));
    }

    /// The formatter door: the platform's own formatter over the process
    /// locale and the user's settings.
    public static class Fmt
    {
        public static string Date(DateOnly d, Length length = Length.Medium) =>
            Filled("Fmt.Date", (into, cap) => kaya_fmt_date(Packed(d), (long)length, into, cap));

        /// The date with its weekday and no year ("Mon, Sep 7").
        public static string DateWeekday(DateOnly d) =>
            Filled("Fmt.DateWeekday", (into, cap) => kaya_fmt_date_weekday(Packed(d), into, cap));

        public static string Time(TimeOnly t, Length length = Length.Short) =>
            Filled("Fmt.Time", (into, cap) => kaya_fmt_time(Packed(t), (long)length, into, cap));

        public static string DateTime(DateOnly d, TimeOnly t, Length length = Length.Medium) =>
            Filled("Fmt.DateTime",
                (into, cap) => kaya_fmt_date_time(Packed(d), Packed(t), (long)length, into, cap));

        public static string Number(double value, NumberOptions? options = null) =>
            Kaya.Number("Fmt.Number",
                (p, into, cap) => kaya_fmt_number(value, p, into, cap),
                (o, into, cap) => kaya_fmt_number(value, in o, into, cap), options);

        /// A fraction as the locale's percentage: 0.256 is "26%".
        public static string Percent(double value, NumberOptions? options = null) =>
            Kaya.Number("Fmt.Percent",
                (p, into, cap) => kaya_fmt_percent(value, p, into, cap),
                (o, into, cap) => kaya_fmt_percent(value, in o, into, cap), options);

        /// An amount in the currency named by its ISO 4217 code.
        public static string Currency(double value, string code)
        {
            byte[] raw = CStr(code);
            return Filled("Fmt.Currency", (into, cap) => kaya_fmt_currency(value, raw, into, cap));
        }

        /// The process locale and its settings, asked of the platform each time.
        public static LocaleInfo Locale()
        {
            string line = Filled("Fmt.Locale", kaya_locale);
            string[] parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length != 5)
                throw new InvalidOperationException($"kaya: kaya_locale answered \"{line}\", not five fields");
            return new LocaleInfo(parts[0], int.Parse(parts[1]), int.Parse(parts[2]), parts[3], parts[4]);
        }

        public static Direction Direction() => kaya_direction() == 1 ? global::Direction.Rtl : global::Direction.Ltr;

        /// The text scale the platform reported, 1.0 until one does.
        public static double TextScale() => kaya_text_scale();
    }

    /// Load the app's catalog, l10n/<app>.<locale>.ftl under the asset root
    /// with the fallback chain. Once, at startup, before any Tr.
    public static void Catalog(string app) => kaya_catalog(CStr(app));

    /// The message key with its arguments filled: int, long, double, string,
    /// DateOnly or TimeOnly under the names the catalog's placeables use. A
    /// missing key or argument is the core's own panic naming it.
    public static string Tr(string key, params (string Name, object Value)[] args)
    {
        var records = new KayaTrArg[args.Length];
        var pinned = new List<GCHandle>();
        try
        {
            for (int i = 0; i < args.Length; i++)
            {
                var name = GCHandle.Alloc(CStr(args[i].Name), GCHandleType.Pinned);
                pinned.Add(name);
                var r = new KayaTrArg { Name = name.AddrOfPinnedObject() };
                switch (args[i].Value)
                {
                    case int v: r.Tag = TR_INT; r.I = v; break;
                    case long v: r.Tag = TR_INT; r.I = v; break;
                    case double v: r.Tag = TR_FLOAT; r.F = v; break;
                    case string v:
                        var s = GCHandle.Alloc(CStr(v), GCHandleType.Pinned);
                        pinned.Add(s);
                        r.Tag = TR_STR; r.S = s.AddrOfPinnedObject();
                        break;
                    case DateOnly v: r.Tag = TR_DATE; r.I = Packed(v); break;
                    case TimeOnly v: r.Tag = TR_TIME; r.I = Packed(v); break;
                    default:
                        throw new ArgumentException(
                            $"kaya: Tr(\"{key}\"): argument \"{args[i].Name}\" is a {args[i].Value?.GetType().Name ?? "null"}; " +
                            "the arguments are int, long, double, string, DateOnly and TimeOnly");
                }
                records[i] = r;
            }
            byte[] rawKey = CStr(key);
            return Filled($"Tr(\"{key}\")",
                (into, cap) => kaya_tr(rawKey, records.Length == 0 ? null : records, (nuint)records.Length, into, cap));
        }
        finally
        {
            foreach (var h in pinned) h.Free();
        }
    }
}
