//! The sections conformance scene (tools/scenes/sections.steps): a user's
//! switch emits, a programmatic select_section does not.

use kaya::WindowId;

#[derive(Clone)]
enum Msg {
    ArchiveShown,
    GoArchive,
    OpenLibrary,
}

const FEED: WindowId = WindowId(7);
const ARCHIVE: WindowId = WindowId(8);
// An AUX WINDOW, reached only by the desktop tail's click, so create_window
// never runs where the capability is absent.
const LIBRARY: WindowId = WindowId(1);
const SHELVES: WindowId = WindowId(2);
const LOANS: WindowId = WindowId(3);

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let visits_label = ctx.apply(|tx| {
        // The presentation hint is ADVISORY: no observable rides on it.
        tx.window(kaya::DEFAULT_WINDOW)
            .title("sections")
            .sections_presentation(kaya::SectionsPresentation::Bar);
        // SF Symbols are licensed to Apple platforms: no shared asset.
        let feed = tx.add_section(FEED).title("Feed").symbol(kaya::Symbol::Home).id();
        let archive = tx
            .add_section(ARCHIVE)
            .title("Archive")
            .symbol(kaya::Symbol::Star)
            .id();
        msgs.on_section_selected(archive, Msg::ArchiveShown);

        let feed_root = tx
            .column(|tx| {
                let ready = tx.signal("feed ready");
                tx.label(ready); // label#0
                let go = tx.button("to archive").id(); // button#0
                msgs.on_click(go, Msg::GoArchive);
                let open = tx.button("open library").id(); // button#1
                msgs.on_click(open, Msg::OpenLibrary);
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
            Msg::OpenLibrary => {
                ctx.apply(|tx| {
                    tx.create_window(LIBRARY)
                        .title("library")
                        .sections_presentation(kaya::SectionsPresentation::Sidebar);
                    let shelves = tx
                        .add_section_in(LIBRARY, SHELVES)
                        .title("Shelves")
                        .symbol(kaya::Symbol::Search)
                        .id();
                    let loans = tx
                        .add_section_in(LIBRARY, LOANS)
                        .title("Loans")
                        .symbol(kaya::Symbol::Lock)
                        .id();
                    let shelves_root = tx
                        .column(|tx| {
                            let l = tx.signal("shelves ready");
                            tx.label(l); // label#2
                        })
                        .id();
                    tx.mount_in(shelves, shelves_root);
                    let loans_root = tx
                        .column(|tx| {
                            let l = tx.signal("loans ready");
                            tx.label(l); // label#3
                        })
                        .id();
                    tx.mount_in(loans, loans_root);
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
