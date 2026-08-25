//! Which children each container holds, in order — and which containers
//! that order has left stale.
//!
//! A Grid places by attached Row/Column index rather than by child order
//! (docs/traps.md), so `reindex` in the parent module re-stamps the whole
//! set after any structural change: it clears the container's
//! RowDefinitions, rebuilds one per child and writes `Grid::SetRow` on
//! every sibling. Run once per append that is N^2/2 WinRT round trips —
//! 77s for a 10,000-row table, and why this platform's choke sat at
//! 12,000 rows (docs/deferred.md "WinUI's child append is quadratic";
//! docs/measurements/choke-windows-2026-08-24.txt). So a change MARKS its
//! container here and the re-stamp happens once at the batch boundary.
//!
//! THE PRIVATE FIELDS ARE THE GUARD. The order used to be a bare
//! `HashMap` on `CoreState`, and every arm that pushed to it also had to
//! remember the rebuild; here there is no way to reach the vector at all
//! except through a method that marks. `winui::tests`'
//! `the_deferred_rebuild_places_every_child_where_the_eager_one_did`
//! is what watches the methods themselves keep that promise.

use crate::protocol::WidgetId;
use std::collections::{HashMap, HashSet, VecDeque};

#[derive(Default)]
pub(super) struct ChildOrder {
    order: HashMap<WidgetId, Vec<WidgetId>>,
    /// Which container each child sits in. `Destroy` and the `grow` prop
    /// both need to name a child's parent, and the scan they used to do
    /// over every container was the same N^2 one surface over.
    of: HashMap<WidgetId, WidgetId>,
    /// Containers due a re-stamp, in first-marked order.
    due: VecDeque<WidgetId>,
    marked: HashSet<WidgetId>,
}

impl ChildOrder {
    pub(super) fn children(&self, parent: WidgetId) -> &[WidgetId] {
        self.order.get(&parent).map_or(&[], Vec::as_slice)
    }

    pub(super) fn parent_of(&self, child: WidgetId) -> Option<WidgetId> {
        self.of.get(&child).copied()
    }

    /// A change that leaves the ORDER alone and still needs the re-stamp:
    /// a child's `grow` weight (which is the track's size), a container's
    /// align mode, and a table declaring the two head tracks its rows
    /// shift down past.
    pub(super) fn mark(&mut self, container: WidgetId) {
        if self.marked.insert(container) {
            self.due.push_back(container);
        }
    }

    pub(super) fn append(&mut self, parent: WidgetId, child: WidgetId) {
        self.order.entry(parent).or_default().push(child);
        self.of.insert(child, parent);
        self.mark(parent);
    }

    /// Move `child` within `parent`, in front of `before` or to the end.
    /// Panics on an anchor that is not a sibling, which is what the
    /// MoveChild arm did before this type existed.
    pub(super) fn place(&mut self, parent: WidgetId, child: WidgetId, before: Option<WidgetId>) {
        let order = self.order.entry(parent).or_default();
        order.retain(|&id| id != child);
        match before {
            Some(anchor) => {
                let at = order
                    .iter()
                    .position(|&id| id == anchor)
                    .expect("kaya: move_child anchor not among siblings");
                order.insert(at, child);
            }
            None => order.push(child),
        }
        self.of.insert(child, parent);
        self.mark(parent);
    }

    /// Take a child out of whatever container holds it, answering which
    /// one that was. `None` when nothing holds it — an option label, or a
    /// child whose container was destroyed first.
    pub(super) fn detach(&mut self, child: WidgetId) -> Option<WidgetId> {
        let parent = self.of.remove(&child)?;
        let order = self.order.get_mut(&parent)?;
        let before = order.len();
        order.retain(|&id| id != child);
        if order.len() == before {
            return None;
        }
        self.mark(parent);
        Some(parent)
    }

    /// A container is gone: its order goes with it, and the children it
    /// held stop naming it.
    pub(super) fn forget(&mut self, container: WidgetId) {
        self.marked.remove(&container);
        self.due.retain(|&due| due != container);
        for child in self.order.remove(&container).unwrap_or_default() {
            if self.of.get(&child) == Some(&container) {
                self.of.remove(&child);
            }
        }
    }

    /// The next container awaiting its re-stamp. A container whose
    /// re-stamp FAILS stays taken — the ones behind it keep their marks,
    /// so the next flush finishes the batch rather than losing it.
    pub(super) fn next_due(&mut self) -> Option<WidgetId> {
        let container = self.due.pop_front()?;
        self.marked.remove(&container);
        Some(container)
    }
}

/// Which Grid track a container's `index`-th child occupies. `head` is
/// what the container owns in front of its children — 2 for a declared
/// table (the header row and the rule under it), 0 otherwise.
pub(super) fn track_of(index: usize, head: i32) -> i32 {
    index as i32 + head
}
