//! The sliders scene (tools/scenes/sliders.steps; docs/slider-plan.md): a
//! stepped slider with ticks bound to a signal so button#0 can write it
//! PROGRAMMATICALLY (the echo negative), a continuous one with ticks, and a
//! stamped stepped slider bound to a row's own field.

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Track {
    name: String,
    level: f64,
}

#[derive(Clone)]
enum Msg {
    Level(f64),
    Committed,
    Volume(f64),
    RowLevel(kaya::Path, f64),
    Reset,
}

fn key_word(path: &kaya::Path) -> String {
    match path.first() {
        Some(kaya::Value::Str(s)) => s.clone(),
        other => format!("{other:?}"),
    }
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let mut commits = 0u32;
    let (level_text, commit_text, volume_text, row_text, pos, level_node) = ctx.apply(|tx| {
        let level_text = tx.signal("value: 50");
        let commit_text = tx.signal("commits: 0");
        let volume_text = tx.signal("volume: 0.5");
        let row_text = tx.signal("row: none");
        let pos = tx.signal(50.0);
        let tracks = tx.collection::<Track>();
        let mut level_node = kaya::TemplateNodeId(0);
        let root = tx
            .column(|tx| {
                tx.label(level_text); // label#0
                tx.label(commit_text); // label#1
                tx.label(volume_text); // label#2
                tx.label(row_text); // label#3
                let level = tx
                    .slider_bound(0.0, 100.0, pos) // slider#0
                    .step(5.0)
                    .tick_spacing(25.0)
                    .a11y_label("Level")
                    .id();
                tx.a11y_id(level, "master");
                msgs.on_value(level, Msg::Level);
                msgs.on_commit(level, |_| Msg::Committed);
                let volume = tx
                    .slider(0.0, 1.0, 0.5) // slider#1
                    .tick_spacing(0.25)
                    .a11y_label("Volume")
                    .id();
                msgs.on_value(volume, Msg::Volume);
                let reset = tx.button("reset").id(); // button#0
                msgs.on_click(reset, Msg::Reset);
                for mut row in tracks.rows(tx) {
                    row.label(Track::name());
                    let slider = row.slider(0.0, 100.0, Track::level());
                    row.step(slider, 10.0);
                    row.a11y_id(slider, "level");
                    level_node = slider;
                }
            })
            .id();
        tx.mount(root);
        tx.insert(&tracks, "a", Track { name: "a".into(), level: 70.0 });
        tx.insert(&tracks, "b", Track { name: "b".into(), level: 20.0 });
        (level_text, commit_text, volume_text, row_text, pos, level_node)
    });
    msgs.on_commit_node(level_node, Msg::RowLevel);

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Level(v) => ctx.apply(|tx| {
                tx.write(level_text, format!("value: {v}"));
            }),
            Msg::Committed => {
                commits += 1;
                ctx.apply(|tx| {
                    tx.write(commit_text, format!("commits: {commits}"));
                })
            }
            Msg::Volume(v) => ctx.apply(|tx| {
                tx.write(volume_text, format!("volume: {v}"));
            }),
            Msg::RowLevel(path, v) => ctx.apply(|tx| {
                tx.write(row_text, format!("row {}: {v}", key_word(&path)));
            }),
            Msg::Reset => ctx.apply(|tx| {
                // Must NOT come back as a value or a commit occurrence.
                tx.write(pos, 25.0);
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
