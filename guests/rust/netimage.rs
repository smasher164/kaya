//! The network images affordance scene (tools/scenes/netimage.steps;
//! docs/network-images-plan.md §5). No HTTP: each "download" is a job a worker
//! thread holds until a click releases it, background.steps' principle, so a
//! write made from the wrong thread or a result landing on the wrong row is a
//! wrong reading rather than a lucky one.

use std::collections::HashSet;
use std::sync::mpsc;

use kaya::{Fit, ImagePhase, PathKey};

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Track {
    title: String,
    art_url: String,
    art: Vec<u8>,
    phase: ImagePhase,
}

#[derive(Clone)]
enum Msg {
    Release,
    Refresh,
    Junk,
    Fail,
    Needed(kaya::Path),
    Released(kaya::Path),
    Rows,
    Delete,
    Retarget,
}

const ROWS: usize = 300;

enum Job {
    Live(Option<Vec<u8>>),
    Row(String, String, Vec<u8>),
}

fn cover(covers: &[Vec<u8>; 3], i: usize) -> Vec<u8> {
    covers[i % 3].clone()
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let covers: [Vec<u8>; 3] = ctx.apply(|tx| {
        ["covers/cover-600.jpg", "covers/cover-320.jpg", "covers/cover-1000.jpg"].map(|name| tx.asset(name).bytes().to_vec())
    });
    let (art, phase, band, released, again, tracks, art_node) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("netimage").size(820.0, 640.0);
        let art = tx.signal(Vec::<u8>::new());
        let phase = tx.signal(ImagePhase::Loading);
        let band = tx.signal("band: -");
        let released = tx.signal("released: none");
        let again = tx.signal("again: none");
        let tracks = tx.collection::<Track>();
        let mut node = None;
        let root = tx
            .column(|tx| {
                tx.column(|tx| {
                    tx.image(art)
                        .max_width(96.0)
                        .max_height(96.0)
                        .fit(Fit::Cover)
                        .phase(phase)
                        .a11y_id("cover")
                        .a11y_label("Cover");
                    for pair in [[("release", Msg::Release), ("refresh", Msg::Refresh)], [("junk", Msg::Junk), ("fail", Msg::Fail)]] {
                        tx.row(|tx| {
                            for (name, msg) in pair {
                                let b = tx.button(name).a11y_id(name).id();
                                msgs.on_click(b, msg);
                            }
                        });
                    }
                    tx.row(|tx| {
                        for (name, msg) in [("rows", Msg::Rows), ("delete", Msg::Delete), ("retarget", Msg::Retarget)] {
                            let b = tx.button(name).a11y_id(name).id();
                            msgs.on_click(b, msg);
                        }
                    });
                    tx.label(band).a11y_id("band");
                    tx.label(released).a11y_id("released");
                    tx.label(again).a11y_id("again");
                });
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
                tx.a11y_id(id, "tracks");
                tx.grow(id, 1.0);
            })
            .id();
        tx.mount(root);
        for i in 0..ROWS {
            let key = format!("t{i:03}");
            tx.insert(
                &tracks,
                key.as_str(),
                Track { title: format!("Track {i}"), art_url: format!("u/{i}"), art: Vec::new(), phase: ImagePhase::Loading },
            );
        }
        (art, phase, band, released, again, tracks, node.expect("the table declared its art"))
    });
    msgs.on_needed_node(art_node, Msg::Needed);
    msgs.on_released_node(art_node, Msg::Released);

    let (jobs, inbox) = mpsc::channel::<Vec<Job>>();
    let poster = ctx.poster();
    let rows = tracks.clone();
    std::thread::Builder::new()
        .name("netimage-worker".into())
        .spawn(move || {
            while let Ok(batch) = inbox.recv() {
                for job in batch {
                    match job {
                        Job::Live(Some(bytes)) => poster.post(move |tx| {
                            tx.write(art, bytes);
                            tx.write(phase, ImagePhase::Shown);
                        }),
                        Job::Live(None) => poster.post(move |tx| tx.write(phase, ImagePhase::Failed)),
                        Job::Row(key, url, bytes) => {
                            let rows = rows.clone();
                            poster.post(move |tx| {
                                rows.patch_if(tx, key.as_str(), Track::art_url(), url).art(bytes).phase(ImagePhase::Shown);
                            });
                        }
                    }
                }
            }
        })
        .expect("failed to spawn the netimage worker");

    let mut live = Some(Job::Live(Some(covers[0].clone())));
    let mut pending: Vec<Job> = Vec::new();
    let mut needed: HashSet<String> = HashSet::new();
    let mut ever: HashSet<String> = HashSet::new();
    let mut twice: Option<String> = None;
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Release => {
                if let Some(job) = live.take() {
                    let _ = jobs.send(vec![job]);
                }
            }
            Msg::Refresh => {
                live = Some(Job::Live(Some(covers[1].clone())));
                ctx.apply(|tx| tx.write(phase, ImagePhase::Loading));
            }
            Msg::Junk => ctx.apply(|tx| {
                tx.write(art, b"not an image".to_vec());
                tx.write(phase, ImagePhase::Shown);
            }),
            Msg::Fail => {
                live = Some(Job::Live(None));
                ctx.apply(|tx| {
                    tx.write(art, Vec::<u8>::new());
                    tx.write(phase, ImagePhase::Loading);
                });
            }
            Msg::Needed(path) => {
                let key = path.key::<String>(0);
                if !needed.insert(key.clone()) {
                    twice.get_or_insert(key.clone());
                }
                ever.insert(key.clone());
                let i: usize = key[1..].parse().expect("a track key is t and a number");
                pending.push(Job::Row(key, format!("u/{i}"), cover(&covers, i)));
                let seen = ever.len();
                let twice = twice.clone();
                ctx.apply(|tx| {
                    tx.write(band, if seen < ROWS { "band: partial".to_owned() } else { format!("band: {seen}") });
                    tx.write(again, format!("again: {}", twice.as_deref().unwrap_or("none")));
                });
            }
            Msg::Released(path) => {
                let key = path.key::<String>(0);
                needed.remove(&key);
                pending.retain(|job| !matches!(job, Job::Row(k, ..) if *k == key));
                ctx.apply(|tx| tx.write(released, "released: some"));
            }
            Msg::Rows => {
                needed.clear();
                let _ = jobs.send(std::mem::take(&mut pending));
            }
            Msg::Delete => ctx.apply(|tx| tx.remove(&tracks, "t299")),
            Msg::Retarget => {
                pending.insert(0, Job::Row("t298".into(), "u/298b".into(), covers[2].clone()));
                ctx.apply(|tx| {
                    tracks.patch(tx, "t298").art_url("u/298b");
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
