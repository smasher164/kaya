//! The row-windowing band machine (docs/virtualization-plan.md §1–§2):
//! which rows of one For are realized, and where they sit.
//!
//! Pure state and arithmetic. Stamping and teardown are scene.rs's, the
//! ABI capi.rs's; nothing here touches a widget.

use std::collections::HashMap;
use std::ops::Range;

use crate::protocol::Key;

/// The overscan, in viewports, each side of the visible range (§1: "the
/// viewport plus one viewport of overscan each side").
const OVERSCAN: usize = 1;

/// One For site's window.
///
/// UNREPORTED IS UNBOUNDED — the default, and the plan's §1 bridge: a For
/// no backend has reported on realizes every row, which is exactly the
/// pre-windowing behavior every backend, scene and lane still has. The
/// report is what narrows the band.
#[derive(Default)]
pub(crate) struct RowWindow {
    /// The backend's last reported visible range, `(first, count)`.
    reported: Option<(usize, usize)>,
    /// The SEED: the band a windowed-capable For starts life in until the
    /// first report replaces it (docs/deferred.md, the declares-windowing
    /// entry). Not a report — it is what the backend knows before any
    /// layout, which is nothing.
    seed: Option<usize>,
    /// The realized rows in band order — what the For's container holds.
    /// scene.rs's `reconcile_window` is its only writer.
    realized: Vec<Key>,
    /// The PITCH: the first extent this site was ever told about,
    /// presumed for every unmeasured row. Never a constant — one number
    /// cannot be right on five platforms' text metrics (§2.1).
    pitch: Option<f64>,
    /// Measured extents, BY KEY: rows flow through a fixed band under
    /// sorts, so a measurement belongs to the row, not to the position.
    heights: HashMap<Key, f64>,
    /// Set by the first measurement that disagrees with the pitch, and
    /// never cleared: the corrected path is permanent for the instance's
    /// life (§2.3).
    corrected: bool,
    /// Prefix sums over measured-or-presumed heights, indexed by position
    /// in the current order. Built on demand, dropped when the order
    /// moves, maintained in place by each measurement.
    sums: Option<Fenwick>,
    /// The row the viewport is parked on, and the position that row had
    /// when the report arrived. Corrections above it move the row's
    /// position; the difference is the scroll adjustment that keeps the
    /// row still under the reader's eyes (§2.4).
    anchor: Option<(Key, f64)>,
}

impl RowWindow {
    /// Reported, as against merely seeded — the distinction the tests
    /// hold and nothing else needs.
    #[cfg(test)]
    pub(crate) fn is_reported(&self) -> bool {
        self.reported.is_some()
    }

    /// Reported OR seeded: the band is a range over the collection rather
    /// than the whole of it, so the site's realized set is exactly the
    /// band's rows and scene.rs's windowed fork applies.
    pub(crate) fn is_bounded(&self) -> bool {
        self.reported.is_some() || self.seed.is_some()
    }

    /// Start this site at `rows` instead of unbounded. A no-op once
    /// anything real has arrived — a report is a measurement and a seed
    /// is an admission of having none.
    pub(crate) fn plant_seed(&mut self, rows: usize) {
        if self.reported.is_none() {
            self.seed = Some(rows);
        }
    }

    pub(crate) fn corrected(&self) -> bool {
        self.corrected
    }

    pub(crate) fn realized(&self) -> &[Key] {
        &self.realized
    }

    pub(crate) fn set_realized(&mut self, rows: Vec<Key>) {
        self.realized = rows;
    }

    /// The band this site's rows are realized in: the visible range plus one
    /// viewport of overscan each side, clamped to the collection.
    ///
    /// A NON-EMPTY COLLECTION ALWAYS REALIZES ITS FIRST VISIBLE ROW — a band
    /// holding none can never be measured and so can never grow. THE SEED IS
    /// THE FLOOR, NOT A VIEWPORT: no overscan, and the first report replaces
    /// it outright.
    pub(crate) fn band(&self, total: usize) -> Range<usize> {
        let Some((first, count)) = self.reported else {
            return match self.seed {
                Some(rows) => 0..rows.min(total),
                None => 0..total,
            };
        };
        if total == 0 {
            return 0..0;
        }
        let first = first.min(total - 1);
        let lo = first.saturating_sub(count.saturating_mul(OVERSCAN));
        let hi = first
            .saturating_add(count.saturating_mul(1 + OVERSCAN))
            .max(first + 1)
            .min(total);
        lo..hi
    }

    /// The backend's report of what is on screen.
    pub(crate) fn report(&mut self, first: usize, count: usize) {
        self.reported = Some((first, count));
    }

    /// A run of measured extents for the rows at `first..first + keys.len()`.
    /// Returns true when this report is the one that moved the site onto
    /// the corrected path.
    pub(crate) fn measured(&mut self, first: usize, keys: &[Key], heights: &[f64]) -> bool {
        let was = self.corrected;
        for (i, (key, h)) in keys.iter().zip(heights).enumerate() {
            let h = *h;
            let pitch = *self.pitch.get_or_insert(h);
            // EXACT equality, no tolerance: a tolerance hides a per-row
            // error that accumulates over N rows, and the corrected path
            // costs arithmetic where a missed correction costs pixels.
            if h != pitch {
                self.corrected = true;
            }
            let old = self.heights.insert(key.clone(), h).unwrap_or(pitch);
            if let Some(sums) = self.sums.as_mut() {
                sums.add(first + i, h - old);
            }
        }
        !was && self.corrected
    }

    /// The top of the row at `index`, in the scroll axis's own units.
    ///
    /// EXACT PATH: multiplication, so every windowing observable is a pure
    /// function of N and pitch and is byte-deterministic on every lane
    /// (§2.2). CORRECTED PATH: a prefix sum over measured-or-presumed
    /// heights, O(log N).
    pub(crate) fn position(&mut self, order: &[Key], index: usize) -> f64 {
        let index = index.min(order.len());
        match (self.corrected, self.pitch) {
            (false, Some(pitch)) => index as f64 * pitch,
            // Nothing measured yet: the backend has no geometry to draw
            // spacers from either, and says so by reporting a height.
            (false, None) => 0.0,
            (true, _) => self.sums(order).prefix(index),
        }
    }

    /// The whole collection's extent, realized or not.
    pub(crate) fn extent(&mut self, order: &[Key]) -> f64 {
        self.position(order, order.len())
    }

    /// ONE row's height: what it measured, else the presumption, else 0
    /// before anything has been measured at all.
    ///
    /// The tier that asks AppKit's question (docs/virtualization-plan.md
    /// §4) reads it here rather than keeping a cache of its own, which
    /// would be the second estimator §2 exists to remove.
    pub(crate) fn row_extent(&self, order: &[Key], index: usize) -> f64 {
        let Some(key) = order.get(index) else {
            return 0.0;
        };
        self.heights
            .get(key)
            .copied()
            .unwrap_or_else(|| self.pitch.unwrap_or(0.0))
    }

    /// Park the viewport on the row at `first`: its identity, and the
    /// position it has right now.
    ///
    /// NOT BEFORE THERE IS GEOMETRY: until a measurement lands every
    /// position is the placeholder 0.0, and parking against it would read
    /// the first measurement as one enormous correction.
    pub(crate) fn park(&mut self, order: &[Key], first: usize) {
        if self.pitch.is_none() {
            return;
        }
        let Some(key) = order.get(first).cloned() else {
            return;
        };
        let at = self.position(order, first);
        self.anchor = Some((key, at));
    }

    /// How far the anchor row has moved since the viewport parked on it —
    /// the scroll adjustment that keeps it still. Corrections ABOVE the
    /// anchor land here; nothing here re-derives the anchor from extent.
    pub(crate) fn anchor_shift(&mut self, order: &[Key]) -> f64 {
        let Some((key, at)) = self.anchor.clone() else {
            return 0.0;
        };
        let Some(index) = order.iter().position(|k| *k == key) else {
            return 0.0;
        };
        self.position(order, index) - at
    }

    /// The order changed: the prefix sums are indexed by position, so
    /// they are no longer about this collection.
    pub(crate) fn order_moved(&mut self) {
        self.sums = None;
    }

    fn sums(&mut self, order: &[Key]) -> &mut Fenwick {
        if self.sums.as_ref().is_none_or(|t| t.len() != order.len()) {
            let pitch = self.pitch.unwrap_or(0.0);
            let heights: Vec<f64> = order
                .iter()
                .map(|k| *self.heights.get(k).unwrap_or(&pitch))
                .collect();
            self.sums = Some(Fenwick::build(&heights));
        }
        self.sums.as_mut().unwrap()
    }
}

/// A Fenwick tree over the current order's row heights: O(log N)
/// positions on the corrected path, and O(log N) to fold in one
/// measurement.
struct Fenwick {
    /// 1-based; `tree[0]` is unused.
    tree: Vec<f64>,
}

impl Fenwick {
    fn build(heights: &[f64]) -> Self {
        let n = heights.len();
        let mut tree = vec![0.0; n + 1];
        for (i, h) in heights.iter().enumerate() {
            let at = i + 1;
            tree[at] += h;
            let parent = at + (at & at.wrapping_neg());
            if parent <= n {
                tree[parent] += tree[at];
            }
        }
        Fenwick { tree }
    }

    fn len(&self) -> usize {
        self.tree.len() - 1
    }

    fn add(&mut self, index: usize, delta: f64) {
        let n = self.len();
        let mut at = index + 1;
        while at <= n {
            self.tree[at] += delta;
            at += at & at.wrapping_neg();
        }
    }

    /// The summed height of rows `[0, index)`.
    fn prefix(&self, index: usize) -> f64 {
        let mut at = index.min(self.len());
        let mut sum = 0.0;
        while at > 0 {
            sum += self.tree[at];
            at -= at & at.wrapping_neg();
        }
        sum
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn keys(n: usize) -> Vec<Key> {
        (0..n as i64).map(Key::I64).collect()
    }

    /// The bridge, at this layer: no report, no narrowing.
    #[test]
    fn an_unreported_window_bands_every_row() {
        let w = RowWindow::default();
        assert_eq!(w.band(15_000), 0..15_000);
        assert_eq!(w.band(0), 0..0);
    }

    /// THE SEED: a declared backend's site starts at the first k rows and
    /// nothing else — no overscan, clamped to the collection.
    #[test]
    fn a_seeded_window_bands_the_first_rows_only() {
        let mut w = RowWindow::default();
        w.plant_seed(128);
        assert!(w.is_bounded(), "a seed bounds the band");
        assert!(!w.is_reported(), "but it is not a report");
        assert_eq!(w.band(15_000), 0..128);
        assert_eq!(w.band(40), 0..40, "clamped to a small collection");
        assert_eq!(w.band(0), 0..0);
    }

    /// THE FIRST REPORT REPLACES THE SEED: a measurement outranks an
    /// admission of having none, whichever direction it moves the band.
    #[test]
    fn a_report_replaces_the_seed() {
        let mut w = RowWindow::default();
        w.plant_seed(128);
        w.report(400, 20);
        assert_eq!(w.band(1_000), 380..440, "the report's band, not the seed's");
        w.plant_seed(128);
        assert_eq!(w.band(1_000), 380..440, "and a later seed cannot take it back");
    }

    /// Visible ± one viewport, clamped at both ends.
    #[test]
    fn the_band_is_the_viewport_plus_one_each_side() {
        let mut w = RowWindow::default();
        w.report(100, 20);
        assert_eq!(w.band(1000), 80..140);
        w.report(5, 20);
        assert_eq!(w.band(1000), 0..45, "clamped at the top");
        w.report(980, 20);
        assert_eq!(w.band(1000), 960..1000, "clamped at the bottom");
    }

    /// A zero-height viewport still realizes the row it is parked on —
    /// a band with no rows can never be measured and never grows.
    #[test]
    fn an_empty_report_still_realizes_one_row() {
        let mut w = RowWindow::default();
        w.report(0, 0);
        assert_eq!(w.band(1000), 0..1);
        w.report(7, 0);
        assert_eq!(w.band(1000), 7..8);
        assert_eq!(w.band(0), 0..0, "but an empty collection realizes nothing");
    }

    /// Uniform reports never leave the exact path, and positions there
    /// are multiplication.
    #[test]
    fn uniform_measurements_stay_exact() {
        let order = keys(10_000);
        let mut w = RowWindow::default();
        for start in [0usize, 40, 9_000] {
            let run: Vec<Key> = order[start..start + 40].to_vec();
            assert!(!w.measured(start, &run, &vec![24.0; 40]));
        }
        assert!(!w.corrected());
        assert_eq!(w.pitch, Some(24.0));
        assert_eq!(w.position(&order, 7_000), 7_000.0 * 24.0);
        assert_eq!(w.extent(&order), 10_000.0 * 24.0);
    }

    /// One mismatch corrects, permanently, and every later uniform
    /// measurement leaves it corrected.
    #[test]
    fn one_mismatch_corrects_for_good() {
        let order = keys(100);
        let mut w = RowWindow::default();
        assert!(!w.measured(0, &order[0..4], &[20.0, 20.0, 20.0, 20.0]));
        assert!(w.measured(4, &order[4..5], &[36.0]), "the transition reports itself");
        assert!(w.corrected());
        assert!(
            !w.measured(5, &order[5..9], &[20.0; 4]),
            "already corrected: the transition happens once"
        );
        assert!(w.corrected(), "and never unwinds");
        assert_eq!(w.pitch, Some(20.0), "the pitch is still the first extent");
    }

    /// Corrected positions equal a straight left-to-right sum, at scale.
    #[test]
    fn prefix_sums_equal_a_straight_sum() {
        let order = keys(20_000);
        let mut w = RowWindow::default();
        w.measured(0, &order[0..1], &[16.0]);
        // Every fifth row is taller; the rest keep the presumption.
        let tall: Vec<usize> = (0..20_000).step_by(5).collect();
        for i in &tall {
            w.measured(*i, &order[*i..*i + 1], &[48.0]);
        }
        assert!(w.corrected());
        let straight = |upto: usize| -> f64 {
            (0..upto).map(|i| if i % 5 == 0 { 48.0 } else { 16.0 }).sum()
        };
        for index in [0usize, 1, 5, 999, 10_000, 19_999, 20_000] {
            assert_eq!(w.position(&order, index), straight(index), "at {index}");
        }
        assert_eq!(w.extent(&order), straight(20_000));
    }

    /// The tree is maintained in place by a later measurement, not only
    /// rebuilt — the same numbers whichever way the reader asks.
    #[test]
    fn a_measurement_after_a_position_query_still_counts() {
        let order = keys(50);
        let mut w = RowWindow::default();
        w.measured(0, &order[0..2], &[10.0, 30.0]);
        assert_eq!(w.position(&order, 5), 10.0 + 30.0 + 3.0 * 10.0);
        w.measured(2, &order[2..3], &[50.0]);
        assert_eq!(w.position(&order, 5), 10.0 + 30.0 + 50.0 + 2.0 * 10.0);
        assert_eq!(w.extent(&order), 10.0 + 30.0 + 50.0 + 47.0 * 10.0);
    }

    /// Corrections ABOVE the anchor move the extent and the anchor's
    /// position; the anchor itself — identity and parked offset — does
    /// not move, and the shift is what the backend adds to its scroll.
    #[test]
    fn corrections_above_the_anchor_move_the_extent_not_the_anchor() {
        let order = keys(1_000);
        let mut w = RowWindow::default();
        w.measured(500, &order[500..504], &[20.0; 4]);
        w.park(&order, 500);
        let extent_before = w.extent(&order);
        assert_eq!(w.anchor_shift(&order), 0.0);

        // Fifty rows above the anchor turn out to be twice as tall.
        for i in 100..150 {
            w.measured(i, &order[i..i + 1], &[40.0]);
        }
        assert!(w.corrected());
        assert_eq!(w.anchor.as_ref().map(|(k, _)| k), Some(&order[500]), "the anchor is the row, still");
        assert_eq!(w.extent(&order) - extent_before, 50.0 * 20.0);
        assert_eq!(
            w.anchor_shift(&order),
            50.0 * 20.0,
            "the whole correction is scroll adjustment"
        );
        assert_eq!(
            w.anchor_shift(&order),
            50.0 * 20.0,
            "and reading it does not consume it"
        );
    }

    /// The per-row read the row-height delegate asks: measured, else the
    /// presumption, and 0 only before anything has been measured.
    #[test]
    fn a_row_extent_is_measured_then_presumed() {
        let order = keys(10);
        let mut w = RowWindow::default();
        assert_eq!(w.row_extent(&order, 0), 0.0, "nothing is presumed yet");
        w.measured(0, &order[0..2], &[20.0, 44.0]);
        assert_eq!(w.row_extent(&order, 0), 20.0);
        assert_eq!(w.row_extent(&order, 1), 44.0);
        assert_eq!(w.row_extent(&order, 9), 20.0, "unmeasured rows take the pitch");
        assert_eq!(w.row_extent(&order, 10), 0.0, "and past the end is not a row");
    }

    /// A permuted order invalidates the sums: the tree is indexed by
    /// position, the cache by row.
    #[test]
    fn a_sort_moves_the_heights_with_their_rows() {
        let mut order = keys(6);
        let mut w = RowWindow::default();
        w.measured(0, &order, &[10.0, 20.0, 30.0, 10.0, 10.0, 10.0]);
        assert_eq!(w.position(&order, 3), 60.0);
        order.reverse();
        w.order_moved();
        assert_eq!(
            w.position(&order, 3),
            30.0,
            "the three shortest rows lead now"
        );
        assert_eq!(w.extent(&order), 90.0, "and the extent is the same rows");
    }
}
