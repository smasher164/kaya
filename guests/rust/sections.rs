//! The sections conformance scene: two peer roots in the primary
//! window's section set — presentation context, not lifecycle. The
//! archive pane folds section_selected into a visit count, which pins
//! the echo doctrine from both sides: the user's switch emits (the
//! harness drives the real switcher), while the feed button's
//! programmatic select_section moves the selection silently. The
//! count surviving switch round trips proves retention.

use kaya::WindowId;

#[derive(Clone)]
enum Msg {
    ArchiveShown,
    GoArchive,
}

const FEED: WindowId = WindowId(7);
const ARCHIVE: WindowId = WindowId(8);

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let visits_label = ctx.apply(|tx| {
        // One construct carries the window's attributes (the
        // unification rule). The hint is ADVISORY: `bar` is each
        // desktop's horizontal spelling and the phones' physics
        // regardless — no observable rides on it.
        tx.window(kaya::DEFAULT_WINDOW)
            .title("sections")
            .sections_presentation(kaya::SectionsPresentation::Bar);
        let feed = tx.add_section(FEED).title("Feed").id();
        let archive = tx.add_section(ARCHIVE).title("Archive").id();
        msgs.on_section_selected(archive, Msg::ArchiveShown);

        let feed_root = tx
            .column(|tx| {
                let ready = tx.signal("feed ready");
                tx.label(ready); // label#0
                let go = tx.button("to archive").id(); // button#0
                msgs.on_click(go, Msg::GoArchive);
            })
            .id();
        tx.mount_in(feed, feed_root);

        let visits = tx.signal("archive: 0 visits");
        let archive_root = tx
            .column(|tx| {
                tx.label(visits); // label#1
            })
            .id();
        tx.mount_in(archive, archive_root);
        visits
    });

    let mut visits = 0u64;
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::ArchiveShown => {
                visits += 1;
                ctx.apply(|tx| {
                    tx.write(visits_label, format!("archive: {visits} visits"));
                });
            }
            Msg::GoArchive => {
                ctx.apply(|tx| {
                    tx.select_section(ARCHIVE);
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
