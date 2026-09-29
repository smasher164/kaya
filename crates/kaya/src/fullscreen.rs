//! The fullscreen door's bookkeeping (docs/fullscreen-plan.md §1-§3), one
//! rule for the two Rust backends; the SwiftUI arm carries its own copy,
//! driven by tools/checks/swiftui-fullscreen.swift.

/// A transition in flight, whose, and toward which state.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Flight {
    Kaya(bool),
    User(bool),
}

/// One window's fullscreen state as kaya tracks it.
#[derive(Debug, Default)]
pub(crate) struct Door {
    /// The app's value; a reported user change moves it.
    pub(crate) want: bool,
    pub(crate) flight: Option<Flight>,
    /// The app wrote while the user's transition was in flight: its write wins.
    app_wrote: bool,
}

/// What a settled transition asks of the backend: the occurrence to emit,
/// and the request that puts the app's value back.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Settled {
    pub(crate) report: Option<bool>,
    pub(crate) request: Option<bool>,
}

/// The dress key (§2), in the core's canonical shortcut spelling.
pub(crate) const DRESS_KEY: &str = "f11";

/// Whether the dress may take its key: an app shortcut on it wins (§2).
pub(crate) fn dress_key_free<'a>(shortcuts: impl IntoIterator<Item = &'a str>) -> bool {
    !shortcuts.into_iter().any(|s| s == DRESS_KEY)
}

/// The fullscreen header bar on GTK (docs/fullscreen-plan.md §9), GNOME Web's
/// rule; WinUI's fullscreen presenter draws no title bar at all.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) mod bar {
    /// The pointer within this many pixels of the top edge reveals the bar.
    pub(crate) const REVEAL_EDGE_PX: f64 = 5.0;
    /// A window entering fullscreen hides the bar this long after.
    pub(crate) const HIDE_DELAY_MS: u64 = 300;

    /// What the bar does after one input.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub(crate) enum Bar {
        Show,
        Hide,
        HideLater,
    }

    /// `pointer_y` is the last pointer position in the window, None when the
    /// last input was a touch; `held` is the focus inside the bar, which an
    /// open popover or menu from it holds. `now` hides at once (an input),
    /// else after the delay (the entry into fullscreen).
    pub(crate) fn after(pointer_y: Option<f64>, bar_height: f64, held: bool, now: bool) -> Bar {
        if pointer_y.is_some_and(|y| y <= bar_height.max(REVEAL_EDGE_PX)) || held {
            Bar::Show
        } else if now {
            Bar::Hide
        } else {
            Bar::HideLater
        }
    }
}

impl Door {
    /// The app wrote the prop while the toolkit reads `now`. A write during a
    /// transition is held: the user's is overridden when it settles, kaya's
    /// own is reconciled.
    pub(crate) fn app_writes(&mut self, on: bool, now: bool) -> Option<bool> {
        self.want = on;
        match self.flight {
            Some(Flight::User(_)) => {
                self.app_wrote = true;
                None
            }
            Some(Flight::Kaya(_)) => None,
            None if now != on => {
                self.flight = Some(Flight::Kaya(on));
                Some(on)
            }
            None => None,
        }
    }

    /// The user's door (the dress key) while the toolkit reads `now`.
    pub(crate) fn user_door(&mut self, now: bool) -> Option<bool> {
        if self.flight.is_some() {
            return None;
        }
        self.flight = Some(Flight::User(!now));
        Some(!now)
    }

    /// The toolkit reports `now`. A transition kaya started never reports; a
    /// user's (or one through a door kaya never saw open) reports unless the
    /// app overrode it before it settled.
    pub(crate) fn settled(&mut self, now: bool) -> Settled {
        let flight = self.flight.take();
        let app_wrote = std::mem::take(&mut self.app_wrote);
        let report = match flight {
            Some(Flight::Kaya(_)) => None,
            _ if app_wrote => (self.want == now).then_some(now),
            _ if now != self.want => {
                self.want = now;
                Some(now)
            }
            _ => None,
        };
        let request = (now != self.want).then(|| {
            self.flight = Some(Flight::Kaya(self.want));
            self.want
        });
        Settled { report, request }
    }

    /// Whether the window's frame is not the one to remember (§3): filling
    /// the screen, or on the way into or out of it.
    pub(crate) fn fills_screen(&self, now: bool) -> bool {
        now || self.flight.is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::bar::{Bar, after as bar_after};
    use super::{Door, Flight, Settled, dress_key_free};

    #[test]
    fn the_bar_follows_the_top_edge_and_the_focus() {
        // Hidden (height 0): the edge's own 5px reveal it, the sixth does not.
        assert_eq!(bar_after(Some(0.0), 0.0, false, true), Bar::Show);
        assert_eq!(bar_after(Some(5.0), 0.0, false, true), Bar::Show);
        assert_eq!(bar_after(Some(6.0), 0.0, false, true), Bar::Hide);
        // Revealed (47px): anywhere over the bar keeps it, below hides at once.
        assert_eq!(bar_after(Some(40.0), 47.0, false, true), Bar::Show);
        assert_eq!(bar_after(Some(48.0), 47.0, false, true), Bar::Hide);
        // Focus inside the bar (an open menu) keeps it wherever the pointer is.
        assert_eq!(bar_after(Some(500.0), 47.0, true, true), Bar::Show);
        // A touch never reveals by position.
        assert_eq!(bar_after(None, 47.0, false, true), Bar::Hide);
        // Entering fullscreen waits before hiding.
        assert_eq!(bar_after(Some(500.0), 47.0, false, false), Bar::HideLater);
        assert_eq!(bar_after(None, 47.0, false, false), Bar::HideLater);
    }

    fn settled(report: Option<bool>, request: Option<bool>) -> Settled {
        Settled { report, request }
    }

    #[test]
    fn the_apps_own_write_never_echoes() {
        let mut door = Door::default();
        assert_eq!(door.app_writes(true, false), Some(true));
        assert!(door.fills_screen(false));
        assert_eq!(door.settled(true), settled(None, None));
        assert!(door.fills_screen(true));
        // Already there: no request at all.
        assert_eq!(door.app_writes(true, true), None);
        assert_eq!(door.flight, None);
    }

    #[test]
    fn a_write_during_kayas_transition_is_held_and_reconciled() {
        let mut door = Door::default();
        assert_eq!(door.app_writes(true, false), Some(true));
        assert_eq!(door.app_writes(false, false), None);
        assert_eq!(door.settled(true), settled(None, Some(false)));
        assert_eq!(door.flight, Some(Flight::Kaya(false)));
        assert_eq!(door.settled(false), settled(None, None));
    }

    #[test]
    fn the_users_door_reports_and_moves_the_apps_copy() {
        let mut door = Door::default();
        assert_eq!(door.user_door(false), Some(true));
        // A second press while the first is in flight asks for nothing.
        assert_eq!(door.user_door(false), None);
        assert_eq!(door.settled(true), settled(Some(true), None));
        assert!(door.want);
        assert_eq!(door.user_door(true), Some(false));
        assert_eq!(door.settled(false), settled(Some(false), None));
        assert!(!door.want);
    }

    #[test]
    fn the_apps_write_wins_over_the_users_transition() {
        let mut door = Door::default();
        assert_eq!(door.user_door(false), Some(true));
        assert_eq!(door.app_writes(false, false), None);
        // Overridden: not reported, and the app's value goes back on.
        assert_eq!(door.settled(true), settled(None, Some(false)));
        assert_eq!(door.settled(false), settled(None, None));
        assert!(!door.want);
    }

    #[test]
    fn an_app_write_that_agrees_with_the_user_is_no_override() {
        let mut door = Door::default();
        assert_eq!(door.user_door(false), Some(true));
        assert_eq!(door.app_writes(true, false), None);
        assert_eq!(door.settled(true), settled(Some(true), None));
    }

    #[test]
    fn a_door_kaya_never_saw_open_still_reports() {
        let mut door = Door::default();
        assert_eq!(door.settled(true), settled(Some(true), None));
        // The same state again is no change.
        assert_eq!(door.settled(true), settled(None, None));
    }

    #[test]
    fn an_app_shortcut_on_the_dress_key_wins() {
        assert!(dress_key_free(["primary+f11", "f10", "shift+f11"]));
        assert!(!dress_key_free(["primary+s", "f11"]));
        assert!(dress_key_free(std::iter::empty()));
    }
}
