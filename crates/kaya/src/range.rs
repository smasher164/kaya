//! The range's one clamp (docs/range-plan.md §3 rule 2): every arm's commit
//! path, whatever moved the thumb, calls this and writes the answer back.

/// Where a moved thumb may rest: on the step's lattice from the minimum,
/// inside `min..=max`, and at least `gap` from the other thumb. Thumbs stop;
/// they never cross or push.
pub fn clamp_thumb(min: f64, max: f64, step: f64, gap: f64, low: bool, other: f64, raw: f64) -> f64 {
    let raw = if raw.is_nan() { if low { min } else { max } } else { raw };
    let mut v = raw;
    if step > 0.0 {
        v = min + ((raw - min) / step).round() * step;
    }
    v = v.clamp(min, max);
    if low { v.min(other - gap) } else { v.max(other + gap) }
}

#[cfg(test)]
mod tests {
    use super::clamp_thumb;

    #[test]
    fn a_thumb_snaps_to_the_step_and_stays_in_the_range() {
        assert_eq!(clamp_thumb(0.0, 10.0, 0.5, 1.0, true, 8.0, 3.2), 3.0);
        assert_eq!(clamp_thumb(0.0, 10.0, 0.5, 1.0, true, 8.0, -4.0), 0.0);
        assert_eq!(clamp_thumb(0.0, 10.0, 0.5, 1.0, false, 2.0, 12.0), 10.0);
        assert_eq!(clamp_thumb(0.0, 10.0, 0.0, 0.0, true, 8.0, 3.21), 3.21);
    }

    /// docs/range-plan.md §5: `set_value range#0 low 9.5` stops at 7.
    #[test]
    fn a_thumb_stops_at_the_gap_and_never_crosses() {
        assert_eq!(clamp_thumb(0.0, 10.0, 0.5, 1.0, true, 8.0, 9.5), 7.0);
        assert_eq!(clamp_thumb(0.0, 10.0, 0.5, 1.0, false, 2.0, 1.0), 3.0);
        assert_eq!(clamp_thumb(0.0, 10.0, 0.0, 0.0, true, 5.0, 6.0), 5.0);
        assert_eq!(clamp_thumb(0.0, 10.0, 0.0, 0.0, false, 5.0, 4.0), 5.0);
    }

    #[test]
    fn a_nan_rests_the_thumb_at_its_own_end() {
        assert_eq!(clamp_thumb(0.0, 10.0, 0.5, 1.0, true, 8.0, f64::NAN), 0.0);
        assert_eq!(clamp_thumb(0.0, 10.0, 0.5, 1.0, false, 2.0, f64::NAN), 10.0);
    }
}
