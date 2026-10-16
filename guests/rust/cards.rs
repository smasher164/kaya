//! The cards scene (tools/scenes/cards.steps; docs/styling-pass-plan.md Y4): a
//! grid of cards that each take a click as a whole and show the platform's
//! hover, and a library list whose rows the app selects on activation.

use kaya::{Path, PathKey, Tint};

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Playlist {
    name: String,
    selected: bool,
}

#[derive(Clone)]
enum Msg {
    Card(&'static str),
    Open(Path),
}

const CARDS: [(&str, &str); 3] = [("card1", "Daily Mix 1"), ("card2", "Daily Mix 2"), ("card3", "Discover Weekly")];
const LIBRARY: [(&str, &str); 3] = [("p1", "Liked Songs"), ("p2", "Late Night Jazz"), ("p3", "Focus")];

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (status, library) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("cards").size(520.0, 520.0);
        let status = tx.signal("opened: none");
        let library = tx.collection::<Playlist>();
        let root = tx
            .column(|tx| {
                tx.grid(3, |tx| {
                    for (id, name) in CARDS {
                        let title = tx.signal(name);
                        let line = tx.signal("Made for you");
                        tx.column(|tx| {
                            tx.label(title);
                            tx.caption(line);
                        })
                        .filled(Tint::Neutral)
                        .a11y_id(id)
                        .on_activate(&msgs, Msg::Card(name));
                    }
                })
                .spacing(12.0);
                tx.label(status).a11y_id("status");
                for mut row in library.rows(tx) {
                    let (item, _) = row.row(|t| {
                        t.label(Playlist::name());
                    });
                    row.a11y_id(item, "lib");
                    row.selected(item, Playlist::selected());
                    row.on_activate(item, &msgs, Msg::Open);
                }
            })
            .spacing(16.0)
            .id();
        tx.mount(root);
        for (key, name) in LIBRARY {
            tx.insert(&library, key, Playlist { name: name.to_owned(), selected: false });
        }
        (status, library)
    });
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Card(name) => ctx.apply(|tx| tx.write(status, format!("opened: {name}"))),
            Msg::Open(path) => {
                let picked = path.key::<String>(0);
                ctx.apply(|tx| {
                    for (key, _) in LIBRARY {
                        library.patch(tx, key).selected(key == picked);
                    }
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
