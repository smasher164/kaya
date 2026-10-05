//! The number field's rules (docs/number-field-plan.md §2, §3), one copy
//! for every arm: the root's range check, the display digits from the
//! step, the committed value rounded to them, the text through the
//! formatter door, a commit's reading of that text, and one step.

use crate::fmt::{self, NumberFormat, NumberOptions};

/// An unset bound, ±2^53: the range where every integer is exact (§2).
pub(crate) const UNBOUNDED: f64 = 9_007_199_254_740_992.0;

/// The fraction digits a field displays, at most this many (§3 rule 4).
const MAX_DIGITS: usize = 6;

/// A number field's declared numbers, as the root saw them in one
/// transaction; `value` is None until a value (or its bound signal's
/// current value) arrives.
#[derive(Clone, Copy, Debug)]
pub(crate) struct NumberRange {
    pub(crate) min: f64,
    pub(crate) max: f64,
    pub(crate) step: f64,
    pub(crate) value: Option<f64>,
    pub(crate) format: NumberFormat,
    pub(crate) min_set: bool,
    pub(crate) max_set: bool,
    pub(crate) invalid_format: bool,
}

impl Default for NumberRange {
    fn default() -> Self {
        NumberRange { min: -UNBOUNDED, max: UNBOUNDED, step: 1.0, value: None, format: NumberFormat::Number, min_set: false, max_set: false, invalid_format: false }
    }
}

impl NumberRange {
    pub(crate) fn note(&mut self, prop: crate::protocol::Prop, value: &crate::protocol::Value) -> bool {
        use crate::protocol::{Prop, Value};
        match (prop, value) {
            (Prop::Format, Value::Str(text)) => {
                self.invalid_format = NumberFormat::from_wire(text).is_err();
                if let Ok(format) = NumberFormat::from_wire(text) { self.format = format; }
            },
            (Prop::Min, Value::F64(x)) => { self.min = *x; self.min_set = true; },
            (Prop::Max, Value::F64(x)) => { self.max = *x; self.max_set = true; },
            (Prop::Step, Value::F64(x)) => self.step = *x,
            (Prop::Value, Value::F64(x)) => self.value = Some(*x),
            _ => return false,
        }
        true
    }

    pub(crate) fn refusal(&self, who: &str) -> Option<String> {
        if self.invalid_format { return Some(format!("kaya: number field {who}: invalid format; expected number or timecode:n/d:ndf|df")); }
        if matches!(self.format, NumberFormat::Timecode(_)) {
            let valid = |v: f64| v.is_finite() && v.fract() == 0.0 && (0.0..=fmt::MAX_TIMECODE_FRAMES as f64).contains(&v);
            if self.step != 1.0 {
                return Some(format!("kaya: number field {who}: format timecode requires step 1, got {}", self.step));
            }
            for (name, value, set) in [("min", self.min, self.min_set), ("max", self.max, self.max_set), ("value", self.value.unwrap_or(0.0), true)] {
                if set && !valid(value) {
                    return Some(format!("kaya: number field {who}: format timecode requires {name} to be whole frames in 0..={}, got {value}", fmt::MAX_TIMECODE_FRAMES));
                }
            }
        }
        if self.min > self.max {
            return Some(format!("kaya: number field {who}: min {} is above max {}", self.min, self.max));
        }
        if let Some(value) = self.value {
            if !(self.min..=self.max).contains(&value) {
                return Some(format!("kaya: number field {who}: value {value} is outside its range {}..{}", self.min, self.max));
            }
        }
        None
    }

    pub(crate) fn check(&self, who: &str) {
        if let Some(message) = self.refusal(who) { panic!("{message}"); }
    }

}

/// As many fraction digits as the step has, capped (§3 rule 4): `1` is 0,
/// `0.25` is 2, `0.1` is 1. Read off the step's shortest decimal
/// spelling, which Rust's `Display` writes without an exponent.
pub(crate) fn digits(step: f64) -> usize {
    let spelled = format!("{step}");
    spelled.split_once('.').map_or(0, |(_, fraction)| fraction.len().min(MAX_DIGITS))
}

/// The value at the step's digits, so the text and the value agree.
pub(crate) fn rounded(value: f64, step: f64) -> f64 {
    let d = digits(step);
    format!("{value:.d$}").parse().unwrap_or(value)
}

/// The field's text (§3 rule 5): the platform's number at the step's
/// digits, grouping off.
pub(crate) fn text(value: f64, step: f64) -> String {
    let d = digits(step) as u8;
    fmt::number(
        rounded(value, step),
        NumberOptions { min_fraction_digits: Some(d), max_fraction_digits: Some(d), grouping: false },
    )
}

/// What a commit made of the text (§3 rules 1-3).
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) enum Commit {
    /// Unreadable or empty text: the field shows the committed value's
    /// text again and nothing fires.
    Revert,
    /// The text read as the committed value: nothing fires.
    Unchanged,
    /// A new committed value, clamped and rounded: value_committed fires.
    Moved(f64),
}

pub(crate) fn commit(text: &str, committed: f64, min: f64, max: f64, step: f64) -> Commit {
    let Some(read) = fmt::parse_number(text.trim()) else { return Commit::Revert };
    settle(read, committed, min, max, step)
}

/// A step (§3 rule 6): `steps` of them from the committed value, ten for
/// a page key, clamped, as a commit.
pub(crate) fn stepped(committed: f64, steps: i32, min: f64, max: f64, step: f64) -> Commit {
    settle(committed + f64::from(steps) * step, committed, min, max, step)
}

/// A value a control already read, settled as `commit` settles text: GTK's
/// spin button moves its adjustment before `value-changed` reports it, and
/// the WinUI arm's NumberBox reads through kaya's formatter itself.
pub(crate) fn settle(read: f64, committed: f64, min: f64, max: f64, step: f64) -> Commit {
    let value = rounded(read.clamp(min, max), step);
    if value == committed {
        Commit::Unchanged
    } else {
        Commit::Moved(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn digits_come_from_the_step() {
        assert_eq!(digits(1.0), 0);
        assert_eq!(digits(5.0), 0);
        assert_eq!(digits(0.5), 1);
        assert_eq!(digits(0.1), 1);
        assert_eq!(digits(0.25), 2);
        assert_eq!(digits(0.001), 3);
        assert_eq!(digits(1e-7), 6);
        assert_eq!(digits(1.0 / 3.0), 6);
    }

    #[test]
    fn the_value_is_rounded_to_the_digits() {
        assert_eq!(rounded(12.34, 0.5), 12.3);
        assert_eq!(rounded(12.36, 0.1), 12.4);
        assert_eq!(rounded(12.5, 1.0), 12.0);
        assert_eq!(rounded(13.5, 1.0), 14.0);
        assert_eq!(rounded(0.125, 0.25), 0.12);
        assert_eq!(rounded(7.0, 0.25), 7.0);
    }

    #[test]
    fn a_commit_clamps_rounds_and_fires_only_on_a_move() {
        let (min, max, step) = (0.0, 100.0, 0.5);
        assert_eq!(settle(12.5, 0.0, min, max, step), Commit::Moved(12.5));
        assert_eq!(settle(250.0, 12.5, min, max, step), Commit::Moved(100.0));
        assert_eq!(settle(250.0, 100.0, min, max, step), Commit::Unchanged);
        assert_eq!(settle(-3.0, 12.5, min, max, step), Commit::Moved(0.0));
        assert_eq!(settle(12.54, 12.5, min, max, step), Commit::Unchanged);
    }

    #[test]
    fn a_step_moves_by_the_step_and_stops_at_a_bound() {
        let (min, max, step) = (0.0, 100.0, 0.5);
        assert_eq!(stepped(100.0, 1, min, max, step), Commit::Unchanged);
        assert_eq!(stepped(100.0, -1, min, max, step), Commit::Moved(99.5));
        assert_eq!(stepped(99.5, -10, min, max, step), Commit::Moved(94.5));
        assert_eq!(stepped(0.2, -10, min, max, step), Commit::Moved(0.0));
        assert_eq!(stepped(0.1, 1, 0.0, 1.0, 0.1), Commit::Moved(0.2));
    }

    #[test]
    #[should_panic(expected = "is outside its range")]
    fn the_root_refuses_a_value_outside_the_range() {
        NumberRange { min: 0.0, max: 100.0, step: 0.5, value: Some(100.5), ..NumberRange::default() }.check("t");
    }

    #[test]
    #[should_panic(expected = "is above max")]
    fn the_root_refuses_crossed_bounds() {
        NumberRange { min: 5.0, max: 4.0, step: 1.0, value: None, ..NumberRange::default() }.check("t");
    }

    #[test]
    fn an_unset_range_is_the_exact_integers() {
        let range = NumberRange { value: Some(-UNBOUNDED), ..NumberRange::default() };
        range.check("t");
        assert_eq!(range.step, 1.0);
    }

    /// Through the door, on the host's own locale: unreadable text reverts,
    /// empty text is unreadable, and a readable one commits.
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    #[test]
    fn a_commit_reads_the_text_through_the_door() {
        let shown = text(12.5, 0.5);
        assert_eq!(commit(&shown, 0.0, 0.0, 100.0, 0.5), Commit::Moved(12.5));
        assert_eq!(commit(&format!(" {shown} "), 12.5, 0.0, 100.0, 0.5), Commit::Unchanged);
        assert_eq!(commit("abc", 12.5, 0.0, 100.0, 0.5), Commit::Revert);
        assert_eq!(commit("", 12.5, 0.0, 100.0, 0.5), Commit::Revert);
        assert_eq!(commit(&format!("{shown}abc"), 12.5, 0.0, 100.0, 0.5), Commit::Revert);
    }
}


pub(crate) fn text_for(value: f64, step: f64, format: NumberFormat) -> String {
    match format {
        NumberFormat::Number => text(value, step),
        NumberFormat::Timecode(rate) => {
            // docs/number-field-plan.md §10: intermediate apply values.
            let frames = value.clamp(0.0, fmt::MAX_TIMECODE_FRAMES as f64) as i64;
            fmt::timecode(frames, rate).expect("bounded timecode display")
        }
    }
}

pub(crate) fn parse_for(text: &str, format: NumberFormat) -> Option<f64> {
    match format {
        NumberFormat::Number => fmt::parse_number(text.trim()),
        NumberFormat::Timecode(rate) => fmt::parse_timecode(text, rate).map(|v| v as f64),
    }
}

pub(crate) fn bounds_for(min: f64, max: f64, format: NumberFormat) -> (f64, f64) {
    match format {
        NumberFormat::Number => (min, max),
        NumberFormat::Timecode(_) => (min.max(0.0), max.min(fmt::MAX_TIMECODE_FRAMES as f64)),
    }
}

pub(crate) fn commit_for(text: &str, committed: f64, min: f64, max: f64, step: f64, format: NumberFormat) -> Commit {
    let Some(read) = parse_for(text, format) else { return Commit::Revert };
    let (min, max) = bounds_for(min, max, format);
    settle(read, committed, min, max, step)
}

pub(crate) fn stepped_for(committed: f64, steps: i32, min: f64, max: f64, step: f64, format: NumberFormat) -> Commit {
    let (min, max) = bounds_for(min, max, format);
    stepped(committed, steps, min, max, step)
}

#[cfg(test)]
mod timecode_field_tests {
    use super::*;
    fn format() -> NumberFormat { NumberFormat::Timecode(fmt::TimecodeRate::new(30000, 1001, true).unwrap()) }

    #[test]
    fn timecode_commits_reverts_clamps_and_steps() {
        let f = format();
        assert_eq!(text_for(1800.0, 1.0, f), "00:01:00;02");
        assert_eq!(commit_for("00:01:00;02", 1799.0, -UNBOUNDED, UNBOUNDED, 1.0, f), Commit::Moved(1800.0));
        assert_eq!(commit_for("00:01:00;00", 1799.0, -UNBOUNDED, UNBOUNDED, 1.0, f), Commit::Revert);
        assert_eq!(commit_for("00:01:00;02", 1800.0, -UNBOUNDED, UNBOUNDED, 1.0, f), Commit::Unchanged);
        assert_eq!(commit_for("00:01:00;02", 1700.0, 1000.0, 1799.0, 1.0, f), Commit::Moved(1799.0));
        assert_eq!(stepped_for(1799.0, 1, -UNBOUNDED, UNBOUNDED, 1.0, f), Commit::Moved(1800.0));
        assert_eq!(stepped_for(1800.0, -1, -UNBOUNDED, UNBOUNDED, 1.0, f), Commit::Moved(1799.0));
        assert_eq!(stepped_for(0.0, -1, -UNBOUNDED, UNBOUNDED, 1.0, f), Commit::Unchanged);
        assert_eq!(stepped_for(fmt::MAX_TIMECODE_FRAMES as f64, 1, -UNBOUNDED, UNBOUNDED, 1.0, f), Commit::Unchanged);
        assert_eq!(stepped_for(1800.0, 10, -UNBOUNDED, UNBOUNDED, 1.0, f), Commit::Moved(1810.0));
    }

    #[test]
    fn timecode_display_survives_intermediate_apply_values() {
        let f = format();
        assert_eq!(text_for(-20.0, 1.0, f), "00:00:00;00");
        assert_eq!(text_for(UNBOUNDED, 1.0, f), text_for(fmt::MAX_TIMECODE_FRAMES as f64, 1.0, f));
        assert_eq!(text_for(0.5, 1.0, f), "00:00:00;00");
    }

    #[test]
    fn timecode_declaration_refuses_fractional_negative_and_large_values() {
        let base = NumberRange { format: format(), ..NumberRange::default() };
        base.check("t");
        for v in [-1.0, 0.5, UNBOUNDED, f64::INFINITY, f64::NAN] {
            for r in [NumberRange { value: Some(v), ..base }, NumberRange { min: v, min_set: true, ..base }, NumberRange { max: v, max_set: true, ..base }] {
                assert!(std::panic::catch_unwind(|| r.check("t")).is_err(), "{r:?}");
            }
        }
        for step in [0.5, 2.0, -1.0] {
            assert!(std::panic::catch_unwind(|| NumberRange { step, ..base }.check("t")).is_err());
        }
    }
}
