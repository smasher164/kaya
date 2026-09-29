//! The number field's rules (docs/number-field-plan.md §2, §3), one copy
//! for every arm: the root's range check, the display digits from the
//! step, the committed value rounded to them, the text through the
//! formatter door, a commit's reading of that text, and one step.

use crate::fmt::{self, NumberOptions};

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
}

impl Default for NumberRange {
    fn default() -> Self {
        NumberRange { min: -UNBOUNDED, max: UNBOUNDED, step: 1.0, value: None }
    }
}

impl NumberRange {
    /// The relations, on the complete declaration (§2): the bounds in
    /// order, the value inside them.
    pub(crate) fn check(&self, who: &str) {
        assert!(
            self.min <= self.max,
            "kaya: number field {who}: min {} is above max {}",
            self.min,
            self.max
        );
        if let Some(value) = self.value {
            assert!(
                (self.min..=self.max).contains(&value),
                "kaya: number field {who}: value {value} is outside its range {}..{}",
                self.min,
                self.max
            );
        }
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

fn settle(read: f64, committed: f64, min: f64, max: f64, step: f64) -> Commit {
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
        NumberRange { min: 0.0, max: 100.0, step: 0.5, value: Some(100.5) }.check("t");
    }

    #[test]
    #[should_panic(expected = "is above max")]
    fn the_root_refuses_crossed_bounds() {
        NumberRange { min: 5.0, max: 4.0, step: 1.0, value: None }.check("t");
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
