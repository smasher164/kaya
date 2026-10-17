//! The tracks scene (tools/scenes/tracks.steps; docs/styling-pass-plan.md Y5,
//! Y6, Y7): a playlist's table whose title cell is rounded art beside the
//! track's name over its artist, at a row height every tier honours, the
//! playing track's name in the accent, and a row the app selects on
//! activation (Y4). A three-row album table carries the reading of every row;
//! the long playlist carries the scroll.

use kaya::{Fit, Path, PathKey, Shape, Tint};

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Track {
    number: String,
    title: String,
    artist: String,
    album: String,
    art: Vec<u8>,
    tint: Tint,
    selected: bool,
}

const PLAYLIST: usize = 60;
const PLAYING: usize = 3;
const NAMES: [(&str, &str, &str); 3] = [
    ("Blue in Green", "Miles Davis", "Kind of Blue"),
    ("So What", "Miles Davis", "Kind of Blue"),
    ("Naima", "John Coltrane", "Giant Steps"),
];

fn table(
    tx: &mut kaya::Tx<'_>,
    tracks: &kaya::Collection<Track>,
    id: &str,
    row_id: &str,
    msgs: &kaya::Messages<Path>,
) -> kaya::WidgetId {
    let rows = tracks.rows(tx).columns(&["#", "Title", "Album"], kaya::Sort::none());
    let table = rows.id();
    for mut row in rows {
        let (line, _) = row.row(|t| {
            t.label(Track::number());
            t.row(|t| {
                let image = t.image(Track::art());
                t.fit(image, Fit::Cover);
                t.max_width(image, 40.0);
                t.max_height(image, 40.0);
                t.shape(image, Shape::Rounded);
                t.a11y_id(image, "art");
                t.column(|t| {
                    let title = t.label(Track::title());
                    t.tint(title, Track::tint());
                    t.a11y_id(title, "name");
                    t.caption(Track::artist());
                });
            });
            t.label(Track::album());
        });
        row.a11y_id(line, row_id);
        row.selected(line, Track::selected());
        row.on_activate(line, msgs, |path| path);
    }
    tx.a11y_id(table, id);
    table
}

fn track(i: usize, art: &[u8]) -> Track {
    let (title, artist, album) = NAMES[i % NAMES.len()];
    Track {
        number: (i + 1).to_string(),
        title: title.to_owned(),
        artist: artist.to_owned(),
        album: album.to_owned(),
        art: art.to_vec(),
        tint: if i + 1 == PLAYING { Tint::Accent } else { Tint::None },
        selected: false,
    }
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (album, playlist) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("tracks").size(720.0, 640.0);
        let art = tx.asset("covers/cover-600.jpg").bytes().to_vec();
        let album = tx.collection::<Track>();
        let playlist = tx.collection::<Track>();
        let root = tx
            .column(|tx| {
                table(tx, &album, "album", "a", &msgs);
                let long = table(tx, &playlist, "tracks", "t", &msgs);
                tx.grow(long, 1.0);
            })
            .spacing(12.0)
            .id();
        tx.mount(root);
        for i in 0..NAMES.len() {
            tx.insert(&album, format!("a{}", i + 1).as_str(), track(i, &art));
        }
        for i in 0..PLAYLIST {
            tx.insert(&playlist, format!("t{}", i + 1).as_str(), track(i, &art));
        }
        (album, playlist)
    });
    while let Some(path) = msgs.next(&ctx) {
        let picked = path.key::<String>(0);
        ctx.apply(|tx| {
            for i in 0..NAMES.len() {
                let key = format!("a{}", i + 1);
                album.patch(tx, key.as_str()).selected(key == picked);
            }
            for i in 0..PLAYLIST {
                let key = format!("t{}", i + 1);
                playlist.patch(tx, key.as_str()).selected(key == picked);
            }
        });
    }
}

fn main() {
    kaya::run(app)
}
