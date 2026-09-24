//! The flex row's shrink (docs/flex-shrink-plan.md §2), one arithmetic for
//! the two Rust backends; the two interpreters carry copies held by the
//! flexshrink scene. CSS flexbox's own: a fixed cell shrinks in proportion
//! to its basis (its natural size), never below its minimum (a label's
//! longest word), and a cell that would go below its minimum is frozen
//! there with the rest redistributed among the others.

/// The fixed cells' extents in a row with `room` for them (the main extent
/// less the gaps): natural while they fit, else shrunk as above. Growers
/// are not among these; they divide what is left.
pub(crate) fn shrink(naturals: &[f64], minimums: &[f64], room: f64) -> Vec<f64> {
    let mut extents: Vec<f64> = naturals.to_vec();
    if naturals.iter().sum::<f64>() <= room {
        return extents;
    }
    let mut frozen = vec![false; naturals.len()];
    loop {
        let excess: f64 = extents.iter().sum::<f64>() - room;
        if excess <= 0.0 {
            return extents;
        }
        let basis: f64 = naturals
            .iter()
            .zip(&frozen)
            .filter(|(_, f)| !**f)
            .map(|(n, _)| *n)
            .sum();
        if basis <= 0.0 {
            return extents;
        }
        let mut froze = false;
        for i in 0..naturals.len() {
            if frozen[i] {
                continue;
            }
            let want = extents[i] - excess * naturals[i] / basis;
            if want < minimums[i] {
                extents[i] = minimums[i];
                frozen[i] = true;
                froze = true;
            }
        }
        if froze {
            continue;
        }
        for i in 0..naturals.len() {
            if !frozen[i] {
                extents[i] -= excess * naturals[i] / basis;
            }
        }
        return extents;
    }
}

#[cfg(test)]
mod tests {
    use super::shrink;

    fn round(v: Vec<f64>) -> Vec<i64> {
        v.into_iter().map(|x| x.round() as i64).collect()
    }

    #[test]
    fn fitting_cells_are_untouched() {
        assert_eq!(round(shrink(&[100.0, 200.0], &[40.0, 60.0], 400.0)), vec![100, 200]);
    }

    #[test]
    fn the_excess_comes_out_in_proportion_to_the_basis() {
        // 60 over 240: a third from the 100 (80), two thirds from the 200 (160).
        assert_eq!(round(shrink(&[100.0, 200.0], &[40.0, 60.0], 240.0)), vec![80, 160]);
    }

    #[test]
    fn a_cell_at_its_minimum_is_frozen_and_the_rest_redistributed() {
        // 100 over 200: proportionally 67/133, but the first floors at 80,
        // so the second takes the remainder (120) alone.
        assert_eq!(round(shrink(&[100.0, 200.0], &[80.0, 60.0], 200.0)), vec![80, 120]);
    }

    #[test]
    fn past_every_minimum_the_row_overflows() {
        assert_eq!(round(shrink(&[100.0, 200.0], &[40.0, 60.0], 50.0)), vec![40, 60]);
    }

    #[test]
    fn a_cell_with_no_slack_keeps_its_width() {
        // A button (minimum = natural) is frozen at once; the label takes
        // the whole cut.
        assert_eq!(round(shrink(&[100.0, 66.0], &[40.0, 66.0], 120.0)), vec![54, 66]);
    }
}
