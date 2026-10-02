//! What a typed number may contain (docs/number-field-plan.md §3 rule 5,
//! RULED 2026-10-02): one rule on five platforms, read by kaya over the
//! marks the platform's own formatter writes at the moment of parsing.

/// The zero of every Unicode `Nd` run, Unicode 17.0 (the version
/// `char::UNICODE_VERSION` names; `the_table_is_rusts_unicode` holds the
/// pair). Each run is ten consecutive code points, zero to nine.
const ZEROS: [u32; 77] = [
    0x30, 0x660, 0x6F0, 0x7C0, 0x966, 0x9E6, 0xA66, 0xAE6, 0xB66, 0xBE6, 0xC66, 0xCE6, 0xD66, 0xDE6,
    0xE50, 0xED0, 0xF20, 0x1040, 0x1090, 0x17E0, 0x1810, 0x1946, 0x19D0, 0x1A80, 0x1A90, 0x1B50,
    0x1BB0, 0x1C40, 0x1C50, 0xA620, 0xA8D0, 0xA900, 0xA9D0, 0xA9F0, 0xAA50, 0xABF0, 0xFF10, 0x104A0,
    0x10D30, 0x10D40, 0x11066, 0x110F0, 0x11136, 0x111D0, 0x112F0, 0x11450, 0x114D0, 0x11650,
    0x116C0, 0x116D0, 0x116DA, 0x11730, 0x118E0, 0x11950, 0x11BF0, 0x11C50, 0x11D50, 0x11DA0,
    0x11DE0, 0x11F50, 0x16130, 0x16A60, 0x16AC0, 0x16B50, 0x16D70, 0x1CCF0, 0x1D7CE, 0x1D7D8,
    0x1D7E2, 0x1D7EC, 0x1D7F6, 0x1E140, 0x1E2F0, 0x1E4F0, 0x1E5F1, 0x1E950, 0x1FBF0,
];

/// A decimal digit of any system, as its value.
pub(crate) fn digit(c: char) -> Option<u8> {
    let cp = c as u32;
    let at = ZEROS.partition_point(|&zero| zero <= cp);
    let zero = *ZEROS.get(at.checked_sub(1)?)?;
    (cp - zero < 10).then(|| (cp - zero) as u8)
}

const BIDI_MARKS: [char; 3] = ['\u{200E}', '\u{200F}', '\u{061C}'];

/// The space-like group marks the formatters write (Apple measured 2026-10-02:
/// U+202F for fr-FR, U+00A0 for fr-CA, sv-SE, ru-RU, pl-PL and others), which no
/// ordinary keyboard types: under one of them a plain space is that group mark.
const SPACE_GROUPS: [&str; 4] = ["\u{00A0}", "\u{202F}", "\u{2009}", "\u{2007}"];

/// The locale's marks as the platform's formatter writes them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Marks {
    pub(crate) decimal: String,
    /// Empty where the formatter groups nothing.
    pub(crate) group: String,
    /// The group nearest the decimal mark, and every group left of it.
    pub(crate) primary: usize,
    pub(crate) secondary: usize,
    /// What the formatter writes before a negative number's digits, direction
    /// marks taken out.
    pub(crate) minus: String,
}

/// The value the formatter is asked to write, grouped, at one fraction
/// digit: seven integer digits reach a secondary group.
pub(crate) const SAMPLE: f64 = -1234567.5;

impl Marks {
    /// Read off the formatter's spelling of `SAMPLE`. None when the spelling
    /// is not one: digits in runs, one decimal mark, one group mark.
    pub(crate) fn from_sample(written: &str) -> Option<Marks> {
        let text: String = written.chars().filter(|c| !BIDI_MARKS.contains(c)).collect();
        let mut runs: Vec<(String, usize)> = Vec::new();
        let mut between = String::new();
        let mut run = 0usize;
        for c in text.chars() {
            if digit(c).is_some() {
                if run == 0 {
                    runs.push((std::mem::take(&mut between), 0));
                }
                run += 1;
                runs.last_mut()?.1 = run;
            } else {
                run = 0;
                between.push(c);
            }
        }
        let (fraction_mark, fraction) = runs.pop()?;
        if fraction != 1 || fraction_mark.is_empty() || !between.is_empty() {
            return None;
        }
        let minus = runs.first()?.0.clone();
        let groups: Vec<usize> = runs.iter().map(|r| r.1).collect();
        let marks: Vec<&str> = runs.iter().skip(1).map(|r| r.0.as_str()).collect();
        if marks.iter().any(|m| *m != marks.first().copied().unwrap_or_default()) {
            return None;
        }
        let group = marks.first().copied().unwrap_or_default().to_owned();
        if group == fraction_mark || groups.iter().sum::<usize>() != 7 {
            return None;
        }
        let primary = *groups.last()?;
        let secondary = if groups.len() > 2 { groups[groups.len() - 2] } else { primary };
        Some(Marks { decimal: fraction_mark, group, primary, secondary, minus })
    }
}

/// The ruling's four clauses, over the WHOLE text: any digit system; the
/// locale's decimal mark, and "." wherever "." is neither of the locale's
/// marks; the locale's group mark only where a group falls; a leading
/// minus (the hyphen, U+2212 or the locale's own, after any direction
/// marks). Everything else is None.
pub(crate) fn read(text: &str, marks: &Marks) -> Option<f64> {
    let mut rest = text.trim_start_matches(BIDI_MARKS);
    let mut negative = false;
    for minus in ["-", "\u{2212}", marks.minus.as_str()] {
        if !minus.is_empty() && minus != marks.decimal && minus != marks.group {
            if let Some(after) = rest.strip_prefix(minus) {
                rest = after;
                negative = true;
                break;
            }
        }
    }
    let point_free = "." != marks.decimal && "." != marks.group;
    let (whole, fraction) = match rest.split_once(marks.decimal.as_str()) {
        Some(split) => (split.0, Some(split.1)),
        None if point_free => match rest.split_once('.') {
            Some(split) => (split.0, Some(split.1)),
            None => (rest, None),
        },
        None => (rest, None),
    };
    let mut ascii = String::from(if negative { "-" } else { "" });
    let fold = |s: &str, out: &mut String| -> Option<()> {
        for c in s.chars() {
            out.push(char::from(b'0' + digit(c)?));
        }
        Some(())
    };
    let typed_space;
    let whole = if SPACE_GROUPS.contains(&marks.group.as_str()) {
        typed_space = whole.replace(' ', &marks.group);
        typed_space.as_str()
    } else {
        whole
    };
    let groups: Vec<&str> =
        if marks.group.is_empty() { vec![whole] } else { whole.split(marks.group.as_str()).collect() };
    if groups.len() > 1 {
        let len = |g: &str| g.chars().count();
        let last = groups.len() - 1;
        let placed = groups.iter().enumerate().all(|(i, g)| match i {
            0 => (1..=marks.secondary).contains(&len(g)),
            i if i == last => len(g) == marks.primary,
            _ => len(g) == marks.secondary,
        });
        if !placed {
            return None;
        }
    }
    for g in &groups {
        fold(g, &mut ascii)?;
    }
    let whole_digits = ascii.len() - usize::from(negative);
    if whole_digits == 0 {
        ascii.push('0');
    }
    ascii.push('.');
    let before = ascii.len();
    if let Some(fraction) = fraction {
        fold(fraction, &mut ascii)?;
    }
    if whole_digits == 0 && ascii.len() == before {
        return None;
    }
    ascii.push('0');
    ascii.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn marks(decimal: &str, group: &str, primary: usize, secondary: usize) -> Marks {
        Marks { decimal: decimal.into(), group: group.into(), primary, secondary, minus: "-".into() }
    }

    fn en() -> Marks {
        marks(".", ",", 3, 3)
    }
    fn de() -> Marks {
        marks(",", ".", 3, 3)
    }
    /// What CLDR's ar-EG writes on the Apple, Android and Windows arms.
    fn ar() -> Marks {
        marks("\u{066B}", "\u{066C}", 3, 3)
    }

    #[test]
    fn the_table_is_rusts_unicode() {
        assert_eq!(
            char::UNICODE_VERSION,
            (17, 0, 0),
            "ZEROS is Unicode 17.0's Nd; regenerate it from that version's UnicodeData.txt"
        );
        assert!(ZEROS.windows(2).all(|w| w[0] + 10 <= w[1]), "ZEROS sorted, runs disjoint");
        let mut digits = 0;
        for cp in 0..=0x10FFFFu32 {
            let Some(c) = char::from_u32(cp) else { continue };
            if let Some(v) = digit(c) {
                assert!(c.is_numeric(), "{cp:#X}");
                assert_eq!(digit(char::from_u32(cp - u32::from(v)).unwrap()), Some(0), "{cp:#X}");
                digits += 1;
            }
        }
        assert_eq!(digits, 770);
    }

    #[test]
    fn every_digit_run_folds() {
        for zero in ZEROS {
            let text: String = (0..10).map(|i| char::from_u32(zero + i).unwrap()).collect();
            assert_eq!(read(&text, &en()), Some(123456789.0), "the run at {zero:#X}");
        }
        assert_eq!(read("٣٤", &en()), Some(34.0));
        assert_eq!(read("۳۴", &de()), Some(34.0));
        assert_eq!(read("३४", &ar()), Some(34.0));
        for not_nd in ["²", "½", "①", "Ⅻ", "٣²"] {
            assert_eq!(read(not_nd, &en()), None, "{not_nd}");
        }
    }

    #[test]
    fn the_locales_decimal_and_the_free_point() {
        assert_eq!(read("3.5", &en()), Some(3.5));
        assert_eq!(read("3,5", &de()), Some(3.5));
        assert_eq!(read("٣٫٥", &ar()), Some(3.5));
        // "." where it is neither mark.
        assert_eq!(read("3.5", &ar()), Some(3.5));
        assert_eq!(read("٣.٥", &ar()), Some(3.5));
        assert_eq!(read("٣.٥", &en()), Some(3.5));
        assert_eq!(read("3.5", &marks(",", "\u{202F}", 3, 3)), Some(3.5));
        // "." where it groups: refused, never a decimal.
        assert_eq!(read("3.5", &de()), None);
        // One decimal mark, and never both spellings.
        assert_eq!(read("1.2.3", &en()), None);
        assert_eq!(read("3.5٫5", &ar()), None);
        assert_eq!(read("3,5", &en()), None);
        assert_eq!(read(".5", &en()), Some(0.5));
        assert_eq!(read("3.", &en()), Some(3.0));
        assert_eq!(read(".", &en()), None);
        assert_eq!(read("", &en()), None);
    }

    #[test]
    fn grouping_only_where_a_group_falls() {
        assert_eq!(read("1,234", &en()), Some(1234.0));
        assert_eq!(read("1,234,567.5", &en()), Some(1234567.5));
        assert_eq!(read("1.234", &de()), Some(1234.0));
        assert_eq!(read("1.234,5", &de()), Some(1234.5));
        assert_eq!(read("١٬٢٣٤", &ar()), Some(1234.0));
        assert_eq!(read("١٬٢٣٤٫٥", &ar()), Some(1234.5));
        for misplaced in ["12,34", "1,23,4.5", ",234", "1,234,", "1234,567", "1,2345"] {
            assert_eq!(read(misplaced, &en()), None, "{misplaced}");
        }
        assert_eq!(read("1.2.3", &de()), None);
        assert_eq!(read("12.34,5", &de()), None);
        assert_eq!(read("1,234.5,6", &en()), None);
        assert_eq!(read("١٢٬٣٤", &ar()), None);
        // The locale's own sizes: hi-IN groups twos left of the first three.
        let hi = marks(".", ",", 3, 2);
        assert_eq!(read("12,34,567.5", &hi), Some(1234567.5));
        assert_eq!(read("1,234,567", &hi), None);
        // A space-like group mark takes the plain space a keyboard types, in
        // the same positions; a plain space anywhere else is refused.
        let fr = marks(",", "\u{202F}", 3, 3);
        assert_eq!(read("1 234,5", &fr), Some(1234.5));
        assert_eq!(read("1\u{202F}234,5", &fr), Some(1234.5));
        assert_eq!(read("1 234 567", &marks(",", "\u{00A0}", 3, 3)), Some(1234567.0));
        assert_eq!(read("12 34", &fr), None);
        assert_eq!(read("1 234, 5", &fr), None);
        assert_eq!(read("1 234", &en()), None);
        // A locale whose formatter groups nothing takes no group mark.
        assert_eq!(read("1,234", &marks(".", "", 3, 3)), None);
    }

    #[test]
    fn a_comma_under_ar_eg_is_refused() {
        assert_eq!(read("1,234", &ar()), None);
        assert_eq!(read("3,5", &ar()), None);
        assert_eq!(read("12,34", &ar()), None);
        assert_eq!(read("1,234.5", &ar()), None);
    }

    #[test]
    fn a_leading_minus() {
        assert_eq!(read("-3.5", &en()), Some(-3.5));
        assert_eq!(read("\u{2212}3.5", &en()), Some(-3.5));
        assert_eq!(read("\u{200F}-٣٫٥", &ar()), Some(-3.5));
        assert_eq!(read("\u{061C}-٣٫٥", &ar()), Some(-3.5));
        let own = Marks { minus: "\u{2013}".into(), ..en() };
        assert_eq!(read("\u{2013}3.5", &own), Some(-3.5));
        for refused in ["+3.5", "3.5-", "--3.5", "- 3.5", "-", " 3.5", "3.5e2"] {
            assert_eq!(read(refused, &en()), None, "{refused:?}");
        }
    }

    /// A user who chose "," for the decimal and "." for the group (Windows'
    /// Region settings, Apple's number format): the marks are what the
    /// formatter writes, so the rule follows the user, not the locale's name.
    #[test]
    fn customised_separators_are_the_users() {
        let custom = Marks::from_sample("-1.234.567,5").unwrap();
        assert_eq!(custom, de());
        assert_eq!(read("1.234", &custom), Some(1234.0));
        assert_eq!(read("3,5", &custom), Some(3.5));
        assert_eq!(read("3.5", &custom), None);
        let apostrophe = Marks::from_sample("-1'234'567.5").unwrap();
        assert_eq!(read("3.5", &apostrophe), Some(3.5));
        assert_eq!(read("1'234", &apostrophe), Some(1234.0));
        assert_eq!(read("1,234", &apostrophe), None);
    }

    #[test]
    fn the_marks_come_from_what_the_formatter_writes() {
        assert_eq!(Marks::from_sample("-1,234,567.5"), Some(en()));
        assert_eq!(Marks::from_sample("-1.234.567,5"), Some(de()));
        // ICU's ar-EG, with the Arabic letter mark before the minus.
        assert_eq!(Marks::from_sample("\u{061C}-١٬٢٣٤٬٥٦٧٫٥"), Some(ar()));
        assert_eq!(Marks::from_sample("-١٬٢٣٤٬٥٦٧٫٥"), Some(ar()));
        assert_eq!(Marks::from_sample("-12,34,567.5"), Some(marks(".", ",", 3, 2)));
        assert_eq!(Marks::from_sample("-1234567.5"), Some(marks(".", "", 7, 7)));
        assert_eq!(
            Marks::from_sample("−1\u{202F}234\u{202F}567,5"),
            Some(Marks { minus: "−".into(), ..marks(",", "\u{202F}", 3, 3) })
        );
        for broken in ["", "-1234567", "-1,234.567,5", "-1,234;567.5", "-1234567.55", "-1,234,567,5"] {
            assert_eq!(Marks::from_sample(broken), None, "{broken:?}");
        }
    }
}
