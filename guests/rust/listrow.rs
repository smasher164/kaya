//! The common list-row shapes, side by side, so a layout divergence is a
//! red leg instead of a reviewer's eye (docs/deferred.md's list-row layout
//! scene). Two rows carry the SAME chrome and differ only in how much text
//! the middle cell holds, which is the comparison the height verb makes:
//! the one-line row must not be taller than the two-line one. A WinUI row
//! shipped 14px the other way (2026-09-24).
//!
//! BOTH ROWS TAKE `Align::Baseline`, which is not decoration: the runaway
//! lives inside the baseline row's own compensation, so a row that does not
//! ask for it never reaches the code this scene exists to watch. The first
//! draft of this scene left it off, passed on Windows with the fix reverted,
//! and would have shipped as a guard that catches nothing.

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("listrow").size(420.0, 320.0);
        let one = tx.signal("Buy milk");
        let two = tx.signal("Draft chapter three");
        let when = tx.signal("Monday, Sep 7");
        let bare = tx.signal("Call the dentist");
        let root = tx
            .column(|tx| {
                // ROW A — one line in the middle cell.
                tx.row(|tx| {
                    tx.checkbox(""); // checkbox#0
                    // A COLUMN IN BOTH ROWS, so the ONE difference between
                    // them is how many lines it holds. The task row's own
                    // shape, which is the shape the defect appeared in.
                    tx.column(|tx| {
                        tx.label(one); // label#0
                    });
                    tx.spacer().grow(1.0);
                    tx.button("Details"); // button#0
                })
                .a11y_id("row_one")
                .align(kaya::Align::Baseline)
                .spacing(8.0);
                // ROW B — the same chrome, TWO lines in the middle cell.
                tx.row(|tx| {
                    tx.checkbox(""); // checkbox#1
                    tx.column(|tx| {
                        tx.label(two); // label#1
                        tx.caption(when); // label#2
                    });
                    tx.spacer().grow(1.0);
                    tx.button("Details"); // button#1
                })
                .a11y_id("row_two")
                .align(kaya::Align::Baseline)
                .spacing(8.0);
                // ROW C — a BARE label as the flex child, the shape an app
                // writes first (docs/deferred.md's bare-label entry).
                tx.row(|tx| {
                    tx.checkbox(""); // checkbox#2
                    tx.label(bare); // label#3
                    tx.spacer().grow(1.0);
                    tx.button("Details"); // button#2
                })
                .a11y_id("row_bare")
                .align(kaya::Align::Baseline)
                .spacing(8.0);
                // A GROWN ENTRY BESIDE A BUTTON: the entry takes the track
                // and the button hugs its caption.
                tx.row(|tx| {
                    tx.entry().placeholder("Name").grow(1.0).a11y_id("name");
                    tx.button("Add"); // button#3
                })
                .a11y_id("row_entry")
                .spacing(8.0);
                // A CAPTIONED CHECKBOX, directly in the COLUMN and not in a
                // row of its own, which is both the settings-list shape and
                // the only portable way to ask the question: a column's
                // CROSS axis is the width, so `expect_hugs` here means "does
                // not claim the free width" — the iPhone switch's and the
                // WinUI checkbox's own divergence. In a ROW the cross axis
                // is the height and the verb would ask something else.
                tx.checkbox("Remind me").a11y_id("remind");
            })
            .id();
        tx.mount(root);
    });

    while msgs.next(&ctx).is_some() {}
}

fn main() {
    kaya::run(app)
}
