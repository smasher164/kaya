//! The cards scene (tools/scenes/cards.steps; docs/styling-pass-plan.md Y4): a
//! grid of cards that each take a click as a whole and show the platform's
//! hover, a library list whose rows the app selects on activation and whose
//! play buttons take their symbol from the row, and a card the app adds to the
//! built grid (docs/media-player-plan.md M16).

use kaya::{Path, PathKey, Symbol, Tint};

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Playlist {
    name: String,
    selected: bool,
    symbol: Symbol,
}

#[derive(Clone)]
enum Msg {
    Card(&'static str),
    Open(Path),
    Play(Path),
    More,
}

const CARDS: [(&str, &str); 3] = [("card1", "Daily Mix 1"), ("card2", "Daily Mix 2"), ("card3", "Discover Weekly")];
// The third card is taller, so the row's cards take its height (M16 (1)).
const TALL: &str = "card3";
// Cut at two lines with the platform's ellipsis (M16 (2)).
const BLURB: &str = "Fresh picks every Monday, from the artists you play the most and the ones they listen to";
const LIBRARY: [(&str, &str); 3] = [("p1", "Liked Songs"), ("p2", "Late Night Jazz"), ("p3", "Focus")];

fn card(tx: &mut kaya::Tx<'_>, msgs: &kaya::Messages<Msg>, id: &str, name: &'static str) -> kaya::WidgetId {
    let title = tx.signal(name);
    let line = tx.signal("Made for you");
    let blurb = tx.signal(BLURB);
    tx.column(|tx| {
        tx.label(title);
        tx.caption(line);
        if id == TALL {
            tx.caption(blurb).max_lines(2).a11y_id("blurb");
        }
    })
    .filled(Tint::Neutral)
    .a11y_id(id)
    .on_activate(msgs, Msg::Card(name))
    .id()
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (status, library, grid) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("cards").size(520.0, 520.0);
        let status = tx.signal("opened: none");
        let library = tx.collection::<Playlist>();
        // A section hidden by a When and an empty For take no space (M16 (3)).
        let hidden = tx.signal(false);
        let empty = tx.collection::<Playlist>();
        let mut grid = None;
        let root = tx
            .column(|tx| {
                grid = Some(
                    tx.grid(1, |tx| {
                        for (id, name) in CARDS {
                            card(tx, &msgs, id, name);
                        }
                    })
                    .spacing(12.0)
                    .columns_auto(140.0)
                    .a11y_id("cards")
                    .id(),
                );
                let more = tx.button("More").a11y_id("more").id();
                msgs.on_click(more, Msg::More);
                tx.label(status).a11y_id("status");
                tx.when(hidden, |t| {
                    t.label("never shown");
                });
                for mut row in empty.rows(tx) {
                    row.row(|t| {
                        t.label(Playlist::name());
                    });
                }
                let end = tx.signal("end");
                tx.label(end).a11y_id("end");
                for mut row in library.rows(tx) {
                    let (_, (item, play)) = row.row(|t| {
                        let (item, _) = t.row(|t| {
                            t.label(Playlist::name());
                        });
                        let play = t.button("Play");
                        t.symbol(play, Playlist::symbol());
                        t.a11y_id(play, "go");
                        (item, play)
                    });
                    row.a11y_id(item, "lib");
                    row.selected(item, Playlist::selected());
                    row.on_activate(item, &msgs, Msg::Open);
                    msgs.on_click_node(play, Msg::Play);
                }
            })
            .spacing(16.0)
            .id();
        tx.mount(root);
        for (key, name) in LIBRARY {
            tx.insert(&library, key, Playlist { name: name.to_owned(), selected: false, symbol: Symbol::Play });
        }
        (status, library, grid.expect("the grid"))
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
            Msg::Play(path) => {
                let played = path.key::<String>(0);
                ctx.apply(|tx| {
                    for (key, _) in LIBRARY {
                        library.patch(tx, key).symbol(if key == played { Symbol::Pause } else { Symbol::Play });
                    }
                });
            }
            Msg::More => ctx.apply(|tx| {
                tx.within(grid, |tx| card(tx, &msgs, "card4", "Release Radar"));
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
