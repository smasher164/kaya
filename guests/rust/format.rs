//! The formatter door and the catalog (tools/scenes/format.steps,
//! docs/compliance-plan.md §6): fixed inputs through every fmt call and
//! two catalog messages, asserted against what THIS platform's formatter
//! writes and against the catalog's own bytes.

use kaya::fmt::{self, Length, NumberOptions};

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::<()>::new();
    kaya::catalog("format");
    let d = kaya::Date::new(2026, 9, 7).unwrap();
    let t = kaya::Time::new(8, 30).unwrap();
    ctx.apply(|tx| {
        // Fourteen labels and a row: taller than the default window, which
        // GTK would otherwise let the root overflow (expect_root_fills), and
        // taller than a phone at twice the text size, so the column scrolls
        // (the iOS formatbig leg under expect_no_clipping's off-screen
        // clause, docs/flex-shrink-plan.md §4).
        tx.window(kaya::DEFAULT_WINDOW).title("format").size(540.0, 560.0);
        let root = tx
            .scroll(|tx| {
                tx.column(|tx| {
                let s = tx.signal(fmt::date(d, Length::Short));
                tx.label(s); // label#0
                let s = tx.signal(fmt::date(d, Length::Medium));
                tx.label(s); // label#1
                let s = tx.signal(fmt::date(d, Length::Long));
                tx.label(s); // label#2
                let s = tx.signal(fmt::time(t, Length::Short));
                tx.label(s); // label#3
                let s = tx.signal(fmt::date_time(d, t, Length::Medium));
                tx.label(s); // label#4
                let s = tx.signal(fmt::number(1234567.891, NumberOptions::default()));
                tx.label(s); // label#5
                let s = tx.signal(fmt::percent(0.256, NumberOptions::default()));
                tx.label(s); // label#6
                let s = tx.signal(fmt::currency(1234567.89, "USD"));
                tx.label(s); // label#7
                let s = tx.signal(kaya::tr!("items", count = 1));
                tx.label(s); // label#8
                let s = tx.signal(kaya::tr!("items", count = 3));
                tx.label(s); // label#9
                let s = tx.signal(kaya::tr!("greeting", name = "Ada"));
                tx.label(s); // label#10
                tx.row(|tx| {
                    let s = tx.signal("first");
                tx.label(s); // label#11
                    tx.spacer();
                    let s = tx.signal("last");
                tx.label(s); // label#12
                }); // row#0
                let info = fmt::locale();
                let s = tx.signal(info.tag);
                tx.label(s); // label#13
                });
            })
            .id();
        tx.mount(root);
    });

    while msgs.next(&ctx).is_some() {}
}

fn main() {
    kaya::run(app)
}
