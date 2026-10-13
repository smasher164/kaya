//! The network images scene over HTTP (tools/scenes/netimage_http.steps;
//! docs/network-images-plan.md §5, N12): kaya's row-image helper fetching
//! from the lane's media server with the app's own client. Twelve rows share
//! three covers, the album case; four rows fail or wait in the ways a real
//! catalogue does.

use std::io::Read;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use kaya::{Fit, ImagePhase};

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Track {
    title: String,
    art_url: String,
    art: Vec<u8>,
    phase: ImagePhase,
}

#[derive(Clone)]
enum Msg {}

const COVERS: [&str; 3] = ["covers/cover-600.jpg", "covers/cover-320.jpg", "covers/cover-1000.jpg"];

fn fetch(url: &str) -> Result<Vec<u8>, String> {
    let mut body = ureq::get(url).call().map_err(|e| e.to_string())?.into_body();
    let mut bytes = Vec::new();
    body.as_reader().read_to_end(&mut bytes).map_err(|e| e.to_string())?;
    Ok(bytes)
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let base = std::env::var("KAYA_MEDIA_URL").unwrap_or_else(|_| {
        panic!(
            "kaya: the netimage_http scene reads KAYA_MEDIA_URL, the local server the lane starts \
             (tools/lib/media_server.py)"
        )
    });
    let msgs = kaya::Messages::<Msg>::new();
    let failures = Arc::new(AtomicUsize::new(0));
    let (tracks, art_node, errors) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("netimage_http").size(640.0, 560.0);
        let errors = tx.signal("errors: 0");
        let tracks = tx.collection::<Track>();
        let mut node = None;
        let root = tx
            .row(|tx| {
                tx.label(errors).a11y_id("errors");
                let rows = tracks.rows(tx).columns(&["Art", "Title"], kaya::Sort::none());
                let id = rows.id();
                for mut row in rows {
                    row.row(|t| {
                        let image = t.image(Track::art());
                        t.fit(image, Fit::Cover);
                        t.max_width(image, 20.0);
                        t.max_height(image, 20.0);
                        t.phase(image, Track::phase());
                        t.a11y_id(image, "art");
                        node = Some(image);
                        t.label(Track::title());
                    });
                }
                tx.grow(id, 1.0);
            })
            .id();
        tx.mount(root);
        let special = [
            ("missing", "status/404/"),
            ("broken", "status/500/"),
            ("junk", "covers/README.md"),
            ("slow", "trickle/covers/cover-600.jpg"),
        ];
        for (key, path) in special {
            let track = Track { title: key.into(), art_url: format!("{base}/{path}"), art: Vec::new(), phase: ImagePhase::Loading };
            tx.insert(&tracks, key, track);
        }
        for i in 0..12 {
            let key = format!("a{i:02}");
            let track = Track {
                title: format!("Track {i}"),
                art_url: format!("{base}/{}", COVERS[i % 3]),
                art: Vec::new(),
                phase: ImagePhase::Loading,
            };
            tx.insert(&tracks, key.as_str(), track);
        }
        (tracks, node.expect("the table declared its art"), errors)
    });

    let art = kaya::RowImages::new(&ctx, &tracks, Track::art_url(), Track::art(), Track::phase(), fetch);
    art.on_error(move |tx, _, _| {
        let n = failures.fetch_add(1, Ordering::SeqCst) + 1;
        tx.write(errors, format!("errors: {n}"));
    });
    art.attach(&msgs, art_node);

    while let Some(msg) = msgs.next(&ctx) {
        match msg {}
    }
}

fn main() {
    kaya::run(app)
}
