//! The formatter door (docs/compliance-plan.md §2.3): dates, times, numbers,
//! percentages and money written the way the user's platform writes them,
//! with the user's own settings, by the platform's own formatter. Pure
//! functions, any thread, no transaction. One arm per platform; a platform
//! with no arm yet refuses through the depth stub.

use crate::protocol::{Date, Time};

/// How much of a date or time to write. `Short` is the numeric form,
/// `Medium` the abbreviated words, `Long` the full words; each maps onto
/// the platform's own named style where it has one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Length {
    Short,
    Medium,
    Long,
}

impl Length {
    /// The C floor's spelling: 0, 1, 2.
    pub(crate) fn from_code(code: i64) -> Option<Length> {
        match code {
            0 => Some(Length::Short),
            1 => Some(Length::Medium),
            2 => Some(Length::Long),
            _ => None,
        }
    }
}

/// What a number formatter may be told. `None` leaves the platform's own
/// default for the locale.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NumberOptions {
    pub min_fraction_digits: Option<u8>,
    pub max_fraction_digits: Option<u8>,
    pub grouping: bool,
}

impl Default for NumberOptions {
    fn default() -> Self {
        NumberOptions { min_fraction_digits: None, max_fraction_digits: None, grouping: true }
    }
}

/// The platform's hour cycle, the setting a user flips most.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HourCycle {
    /// 1–12 with a day period.
    H12,
    /// 0–23.
    H23,
}

/// Which way the layout runs, decided by the locale's script.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction {
    Ltr,
    Rtl,
}

/// Who the user is, as the platform reports it (docs/compliance-plan.md
/// §1.2 step 1): the BCP-47 tag and the four settings beside it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LocaleInfo {
    /// BCP-47, `en-US` never `en_US`.
    pub tag: String,
    pub hour_cycle: HourCycle,
    /// 1 is Monday, 7 is Sunday (ISO 8601's numbering).
    pub first_weekday: u8,
    /// CLDR's calendar name: `gregorian`, `japanese`, `buddhist`, …
    pub calendar: String,
    /// CLDR's numbering system: `latn`, `arab`, …
    pub numbering: String,
}

/// The date, in the process locale.
pub fn date(d: Date, length: Length) -> String {
    platform::date(d, length)
}

/// The date with its weekday and no year — a task list's idiom (`Mon, Sep 7`
/// in en-US): the platform orders the `EEE d MMM` fields for the locale.
pub fn date_weekday(d: Date) -> String {
    platform::date_weekday(d)
}

/// The time, in the process locale and the user's hour cycle.
pub fn time(t: Time, length: Length) -> String {
    platform::time(t, length)
}

/// The date and the time together, one length for both.
pub fn date_time(d: Date, t: Time, length: Length) -> String {
    platform::date_time(d, t, length)
}

/// A number with the locale's separators.
pub fn number(value: f64, options: NumberOptions) -> String {
    platform::number(value, options)
}

/// A fraction as the locale's percentage: 0.256 is `26%` in en-US.
pub fn percent(value: f64, options: NumberOptions) -> String {
    platform::percent(value, options)
}

/// An amount in the currency named by its ISO 4217 code (`USD`, `EUR`),
/// with the locale's symbol placement and the currency's own fraction
/// digits (a yen has none).
pub fn currency(value: f64, code: &str) -> String {
    platform::currency(value, code)
}

/// The process locale and its settings, asked of the platform each time
/// so a setting flipped while the app runs is seen.
pub fn locale() -> LocaleInfo {
    platform::locale()
}

/// The layout direction the locale asks for.
pub fn direction() -> Direction {
    direction_of(&locale().tag)
}

/// The text scale the platform reported (docs/compliance-plan.md §2.1):
/// 1.0 until a backend reports one, which the desktops without a text
/// size never do.
pub fn text_scale() -> f64 {
    f64::from_bits(TEXT_SCALE.load(std::sync::atomic::Ordering::Relaxed))
}

static TEXT_SCALE: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(0x3FF0_0000_0000_0000); // 1.0

/// The backend's report, latched (`kaya_text_scale` in the C API).
pub(crate) fn report_text_scale(factor: f64) {
    TEXT_SCALE.store(factor.to_bits(), std::sync::atomic::Ordering::Relaxed);
}

/// RTL from the tag alone: an explicit script subtag decides, else the
/// language's default script (CLDR `scriptMetadata`'s rtl scripts and
/// `likelySubtags`, the handful of languages that carry one).
pub(crate) fn direction_of(tag: &str) -> Direction {
    const RTL_SCRIPTS: &[&str] =
        &["arab", "hebr", "thaa", "syrc", "nkoo", "adlm", "samr", "mand", "rohg", "yezi"];
    const RTL_LANGUAGES: &[&str] =
        &["ar", "he", "iw", "fa", "ur", "ps", "sd", "ug", "yi", "dv", "ckb", "ks", "syr", "nqo", "ff-adlm"];
    let mut parts = tag.split(['-', '_']).map(|p| p.to_ascii_lowercase());
    let language = parts.next().unwrap_or_default();
    if let Some(second) = parts.next() {
        if second.len() == 4 {
            return if RTL_SCRIPTS.contains(&second.as_str()) { Direction::Rtl } else { Direction::Ltr };
        }
    }
    if RTL_LANGUAGES.contains(&language.as_str()) {
        Direction::Rtl
    } else {
        Direction::Ltr
    }
}

/// `KAYA_LOCALE=<bcp47>`, the harness's per-process locale, installed
/// through the platform's own per-process route BEFORE the app thread
/// exists (lib.rs's `run`), so a guest that formats first formats right
/// and the toolkit's every read agrees (docs/compliance-plan.md §2.2).
/// UNSET INSTALLS NOTHING; a malformed tag dies here naming the shape.
pub(crate) fn install_locale_knob() {
    let Ok(tag) = std::env::var("KAYA_LOCALE") else { return };
    let ok = !tag.is_empty() && tag.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-');
    assert!(ok, "kaya: KAYA_LOCALE={tag:?} is not a BCP-47 tag such as ar-EG");
    platform::install_locale(&tag, direction_of(&tag));
}

/// A Date and a Time as the platform's own instant, local time zone.
#[cfg(any(target_os = "macos", target_os = "ios"))]
mod platform {
    use super::{Date, Direction, HourCycle, Length, LocaleInfo, NumberOptions, Time};
    use std::ffi::{c_char, c_void, CStr};

    type CFTypeRef = *const c_void;
    type CFStringRef = *const c_void;
    type CFLocaleRef = *const c_void;
    type CFCalendarRef = *const c_void;
    type CFDateFormatterRef = *const c_void;
    type CFNumberFormatterRef = *const c_void;
    type CFAbsoluteTime = f64;
    const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;
    const K_CF_NUMBER_DOUBLE_TYPE: isize = 13;
    const K_CF_NUMBER_S32_TYPE: isize = 3;

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        static kCFAllocatorDefault: *const c_void;
        static kCFLocaleIdentifier: CFStringRef;
        static kCFNumberFormatterCurrencyCode: CFStringRef;
        static kCFNumberFormatterMinFractionDigits: CFStringRef;
        static kCFNumberFormatterMaxFractionDigits: CFStringRef;
        static kCFNumberFormatterUseGroupingSeparator: CFStringRef;
        static kCFBooleanTrue: CFTypeRef;
        static kCFBooleanFalse: CFTypeRef;
        fn CFRelease(cf: CFTypeRef);
        fn CFLocaleCopyCurrent() -> CFLocaleRef;
        fn CFLocaleGetValue(locale: CFLocaleRef, key: CFStringRef) -> CFTypeRef;
        fn CFLocaleCreateCanonicalLanguageIdentifierFromString(
            alloc: *const c_void,
            id: CFStringRef,
        ) -> CFStringRef;
        fn CFCalendarCopyCurrent() -> CFCalendarRef;
        fn CFCalendarGetIdentifier(cal: CFCalendarRef) -> CFStringRef;
        fn CFCalendarGetFirstWeekday(cal: CFCalendarRef) -> isize;
        fn CFCalendarComposeAbsoluteTime(
            cal: CFCalendarRef,
            at: *mut CFAbsoluteTime,
            desc: *const c_char,
            ...
        ) -> bool;
        fn CFDateFormatterCreate(
            alloc: *const c_void,
            locale: CFLocaleRef,
            date_style: isize,
            time_style: isize,
        ) -> CFDateFormatterRef;
        fn CFDateFormatterCreateStringWithAbsoluteTime(
            alloc: *const c_void,
            f: CFDateFormatterRef,
            at: CFAbsoluteTime,
        ) -> CFStringRef;
        fn CFDateFormatterSetFormat(f: CFDateFormatterRef, format: CFStringRef);
        fn CFDateFormatterCreateDateFormatFromTemplate(
            alloc: *const c_void,
            template: CFStringRef,
            options: u64,
            locale: CFLocaleRef,
        ) -> CFStringRef;
        fn CFNumberFormatterCreate(
            alloc: *const c_void,
            locale: CFLocaleRef,
            style: isize,
        ) -> CFNumberFormatterRef;
        fn CFNumberFormatterSetProperty(f: CFNumberFormatterRef, key: CFStringRef, value: CFTypeRef);
        fn CFNumberFormatterCreateStringWithValue(
            alloc: *const c_void,
            f: CFNumberFormatterRef,
            ty: isize,
            ptr: *const c_void,
        ) -> CFStringRef;
        fn CFNumberCreate(alloc: *const c_void, ty: isize, ptr: *const c_void) -> CFTypeRef;
        fn CFStringCreateWithCString(
            alloc: *const c_void,
            s: *const c_char,
            encoding: u32,
        ) -> CFStringRef;
        fn CFStringGetCString(s: CFStringRef, buf: *mut c_char, cap: isize, encoding: u32) -> bool;
        fn CFStringGetLength(s: CFStringRef) -> isize;
    }

    struct Owned(CFTypeRef);
    impl Drop for Owned {
        fn drop(&mut self) {
            if !self.0.is_null() {
                unsafe { CFRelease(self.0) }
            }
        }
    }

    fn cfstr(s: &str) -> Owned {
        let c = std::ffi::CString::new(s).expect("no NUL in a formatter argument");
        Owned(unsafe { CFStringCreateWithCString(kCFAllocatorDefault, c.as_ptr(), K_CF_STRING_ENCODING_UTF8) })
    }

    /// Read a CFString out; a null answers an empty string, which the
    /// callers turn into a refusal naming what they asked for.
    fn read(s: CFStringRef) -> String {
        if s.is_null() {
            return String::new();
        }
        let cap = unsafe { CFStringGetLength(s) } * 4 + 1;
        let mut buf = vec![0 as c_char; cap as usize];
        let ok = unsafe { CFStringGetCString(s, buf.as_mut_ptr(), cap, K_CF_STRING_ENCODING_UTF8) };
        if !ok {
            return String::new();
        }
        unsafe { CStr::from_ptr(buf.as_ptr()) }.to_string_lossy().into_owned()
    }

    fn current_locale() -> Owned {
        Owned(unsafe { CFLocaleCopyCurrent() })
    }

    /// The platform's own instant for a local date and time.
    fn instant(d: Date, t: Option<Time>) -> CFAbsoluteTime {
        let cal = Owned(unsafe { CFCalendarCopyCurrent() });
        let mut at: CFAbsoluteTime = 0.0;
        let (h, m) = t.map_or((12, 0), |t| (t.hour as i32, t.minute as i32));
        let ok = unsafe {
            CFCalendarComposeAbsoluteTime(
                cal.0,
                &mut at,
                c"yMdHms".as_ptr(),
                d.year as i32,
                d.month as i32,
                d.day as i32,
                h,
                m,
                0i32,
            )
        };
        assert!(ok, "kaya: the platform calendar refused {d:?} {t:?}");
        at
    }

    fn style(length: Length) -> isize {
        match length {
            Length::Short => 1,
            Length::Medium => 2,
            Length::Long => 3,
        }
    }

    fn with_styles(date_style: isize, time_style: isize, at: CFAbsoluteTime) -> String {
        let locale = current_locale();
        let f = Owned(unsafe { CFDateFormatterCreate(kCFAllocatorDefault, locale.0, date_style, time_style) });
        let s = Owned(unsafe { CFDateFormatterCreateStringWithAbsoluteTime(kCFAllocatorDefault, f.0, at) });
        read(s.0)
    }

    pub(super) fn date(d: Date, length: Length) -> String {
        with_styles(style(length), 0, instant(d, None))
    }

    pub(super) fn time(t: Time, length: Length) -> String {
        with_styles(0, style(length), instant(Date { year: 2000, month: 1, day: 1 }, Some(t)))
    }

    pub(super) fn date_weekday(d: Date) -> String {
        let locale = current_locale();
        let template = cfstr("EEEdMMM");
        let pattern = Owned(unsafe {
            CFDateFormatterCreateDateFormatFromTemplate(kCFAllocatorDefault, template.0, 0, locale.0)
        });
        let f = Owned(unsafe { CFDateFormatterCreate(kCFAllocatorDefault, locale.0, 0, 0) });
        unsafe { CFDateFormatterSetFormat(f.0, pattern.0) };
        let s = Owned(unsafe {
            CFDateFormatterCreateStringWithAbsoluteTime(kCFAllocatorDefault, f.0, instant(d, None))
        });
        read(s.0)
    }

    pub(super) fn date_time(d: Date, t: Time, length: Length) -> String {
        with_styles(style(length), style(length), instant(d, Some(t)))
    }

    fn number_with(style: isize, value: f64, options: NumberOptions, currency: Option<&str>) -> String {
        let locale = current_locale();
        let f = Owned(unsafe { CFNumberFormatterCreate(kCFAllocatorDefault, locale.0, style) });
        unsafe {
            if let Some(code) = currency {
                let code = cfstr(code);
                CFNumberFormatterSetProperty(f.0, kCFNumberFormatterCurrencyCode, code.0);
            }
            if let Some(min) = options.min_fraction_digits {
                let n = min as i32;
                let v = Owned(CFNumberCreate(kCFAllocatorDefault, K_CF_NUMBER_S32_TYPE, &n as *const i32 as *const c_void));
                CFNumberFormatterSetProperty(f.0, kCFNumberFormatterMinFractionDigits, v.0);
            }
            if let Some(max) = options.max_fraction_digits {
                let n = max as i32;
                let v = Owned(CFNumberCreate(kCFAllocatorDefault, K_CF_NUMBER_S32_TYPE, &n as *const i32 as *const c_void));
                CFNumberFormatterSetProperty(f.0, kCFNumberFormatterMaxFractionDigits, v.0);
            }
            CFNumberFormatterSetProperty(
                f.0,
                kCFNumberFormatterUseGroupingSeparator,
                if options.grouping { kCFBooleanTrue } else { kCFBooleanFalse },
            );
        }
        let s = Owned(unsafe {
            CFNumberFormatterCreateStringWithValue(
                kCFAllocatorDefault,
                f.0,
                K_CF_NUMBER_DOUBLE_TYPE,
                &value as *const f64 as *const c_void,
            )
        });
        read(s.0)
    }

    pub(super) fn number(value: f64, options: NumberOptions) -> String {
        number_with(1, value, options, None)
    }

    pub(super) fn percent(value: f64, options: NumberOptions) -> String {
        number_with(3, value, options, None)
    }

    pub(super) fn currency(value: f64, code: &str) -> String {
        // The currency's own fraction digits: the formatter knows them
        // once the code is set, so no digits are forced here.
        number_with(2, value, NumberOptions::default(), Some(code))
    }

    pub(super) fn locale() -> LocaleInfo {
        let locale = current_locale();
        let raw = read(unsafe { CFLocaleGetValue(locale.0, kCFLocaleIdentifier) });
        let canonical = Owned(unsafe {
            let id = cfstr(&raw);
            CFLocaleCreateCanonicalLanguageIdentifierFromString(kCFAllocatorDefault, id.0)
        });
        let mut tag = read(canonical.0);
        if tag.is_empty() {
            tag = raw.replace('_', "-");
        }
        // The hour cycle the platform picks for this user: the `j` skeleton
        // resolves to `h a` or `HH` under the locale AND the 24-hour setting.
        let pattern = Owned(unsafe {
            let template = cfstr("j");
            CFDateFormatterCreateDateFormatFromTemplate(kCFAllocatorDefault, template.0, 0, locale.0)
        });
        let hour_cycle = if read(pattern.0).contains('H') || read(pattern.0).contains('k') {
            HourCycle::H23
        } else {
            HourCycle::H12
        };
        let cal = Owned(unsafe { CFCalendarCopyCurrent() });
        // CF counts Sunday as 1; ISO counts Monday as 1.
        let cf_first = unsafe { CFCalendarGetFirstWeekday(cal.0) } as u8;
        let first_weekday = if cf_first <= 1 { 7 } else { cf_first - 1 };
        let calendar = read(unsafe { CFCalendarGetIdentifier(cal.0) });
        // The numbering system is what a zero comes out as.
        let zero = number(0.0, NumberOptions::default());
        let numbering = match zero.chars().next() {
            Some('٠') => "arab",
            Some('۰') => "arabext",
            Some('०') => "deva",
            Some('๐') => "thai",
            _ => "latn",
        }
        .to_owned();
        LocaleInfo { tag, hour_cycle, first_weekday, calendar, numbering }
    }

    /// Apple's own route: the ARGUMENT domain of the standard defaults,
    /// what `-AppleLanguages` on a command line sets — volatile, nothing
    /// written to the app's plist (a plain `set` was measured persisting;
    /// docs/measurements/compliance-probes-2026-09-21.md U4). The two
    /// direction defaults are Apple's RTL test knob, set when the tag's
    /// script runs right to left.
    pub(super) fn install_locale(tag: &str, direction: Direction) {
        use objc2::runtime::AnyObject;
        use objc2_foundation::{NSArgumentDomain, NSArray, NSDictionary, NSNumber, NSString, NSUserDefaults};
        let languages = NSArray::from_slice(&[&*NSString::from_str(tag)]);
        let locale = NSString::from_str(&tag.replace('-', "_"));
        let yes = NSNumber::new_bool(true);
        let k_languages = NSString::from_str("AppleLanguages");
        let k_locale = NSString::from_str("AppleLocale");
        let k_text = NSString::from_str("AppleTextDirection");
        let k_force = NSString::from_str("NSForceRightToLeftWritingDirection");
        let mut keys: Vec<&NSString> = vec![&k_languages, &k_locale];
        let mut objects: Vec<&AnyObject> = vec![&languages, &locale];
        if direction == Direction::Rtl {
            keys.push(&k_text);
            keys.push(&k_force);
            objects.push(&yes);
            objects.push(&yes);
        }
        let domain: objc2::rc::Retained<NSDictionary<NSString, AnyObject>> =
            NSDictionary::from_slices(&keys, &objects);
        unsafe {
            NSUserDefaults::standardUserDefaults().setVolatileDomain_forName(&domain, NSArgumentDomain);
        }
    }
}

#[cfg(not(any(target_os = "macos", target_os = "ios")))]
mod platform {
    use super::{Date, Length, LocaleInfo, NumberOptions, Time};

    // The three arms still owed (docs/compliance-plan.md §8 step 3: gtk,
    // winui, android). The stub tools/check-stubs.py reads is the
    // backend's own, in its Stage impl; this is the door's floor under it.
    fn refuse() -> ! {
        panic!(
            "kaya: the formatter has no arm on this platform yet — it is a depth \
             slice (docs/compliance-plan.md §8 step 3)"
        )
    }

    pub(super) fn date(_: Date, _: Length) -> String {
        refuse()
    }
    pub(super) fn time(_: Time, _: Length) -> String {
        refuse()
    }
    pub(super) fn date_weekday(_: Date) -> String {
        refuse()
    }
    pub(super) fn date_time(_: Date, _: Time, _: Length) -> String {
        refuse()
    }
    pub(super) fn number(_: f64, _: NumberOptions) -> String {
        refuse()
    }
    pub(super) fn percent(_: f64, _: NumberOptions) -> String {
        refuse()
    }
    pub(super) fn currency(_: f64, _: &str) -> String {
        refuse()
    }
    pub(super) fn locale() -> LocaleInfo {
        refuse()
    }
    pub(super) fn install_locale(_: &str, _: super::Direction) {
        refuse()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn direction_follows_the_script_then_the_language() {
        assert_eq!(direction_of("ar-EG"), Direction::Rtl);
        assert_eq!(direction_of("he_IL"), Direction::Rtl);
        assert_eq!(direction_of("fa"), Direction::Rtl);
        assert_eq!(direction_of("en-US"), Direction::Ltr);
        assert_eq!(direction_of("de"), Direction::Ltr);
        // A script subtag beats the language's default.
        assert_eq!(direction_of("ar-Latn-DZ"), Direction::Ltr);
        assert_eq!(direction_of("pa-Arab-PK"), Direction::Rtl);
        assert_eq!(direction_of(""), Direction::Ltr);
    }

    #[test]
    fn text_scale_is_one_until_reported() {
        assert_eq!(text_scale(), 1.0);
        report_text_scale(2.35);
        assert!((text_scale() - 2.35).abs() < 1e-9);
        report_text_scale(1.0);
    }

    #[test]
    fn length_codes_are_the_floor_s_three() {
        assert_eq!(Length::from_code(0), Some(Length::Short));
        assert_eq!(Length::from_code(2), Some(Length::Long));
        assert_eq!(Length::from_code(3), None);
    }

    /// The Apple arm against this Mac's own locale: the shapes the probe
    /// measured (docs/measurements/compliance-probes-2026-09-21.md U9),
    /// held loosely enough for any host locale and tightly enough that a
    /// formatter that answered nothing is red.
    #[cfg(target_os = "macos")]
    #[test]
    fn the_apple_arm_answers_every_call() {
        let d = Date::new(2026, 9, 7).unwrap();
        let t = Time::new(8, 30).unwrap();
        let short = date(d, Length::Short);
        let medium = date(d, Length::Medium);
        let long = date(d, Length::Long);
        assert!(!short.is_empty() && !medium.is_empty() && !long.is_empty(), "{short} {medium} {long}");
        assert!(long.len() >= medium.len(), "{long} vs {medium}");
        assert!(long.contains("2026"), "{long}");
        let weekday = date_weekday(d);
        assert!(weekday.contains('7') && !weekday.contains("2026"), "{weekday}");
        let clock = time(t, Length::Short);
        assert!(clock.contains("30"), "{clock}");
        assert!(date_time(d, t, Length::Medium).contains("30"));
        let n = number(1234567.891, NumberOptions::default());
        assert!(n.contains("567"), "{n}");
        let bare = number(1234567.0, NumberOptions { grouping: false, max_fraction_digits: Some(0), ..Default::default() });
        assert!(bare.contains("1234567"), "{bare}");
        let p = percent(0.256, NumberOptions::default());
        assert!(p.contains("26"), "{p}");
        let c = currency(1234567.89, "USD");
        assert!(c.contains("567"), "{c}");
        let y = currency(1234567.0, "JPY");
        assert!(!y.contains(".00") && !y.contains(",00"), "a yen carries no fraction: {y}");
        let info = locale();
        assert!(info.tag.contains('-') || info.tag.len() == 2, "{info:?}");
        assert!((1..=7).contains(&info.first_weekday), "{info:?}");
        assert!(!info.calendar.is_empty() && !info.numbering.is_empty(), "{info:?}");
    }
}
