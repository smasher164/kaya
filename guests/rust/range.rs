//! The range scene (tools/scenes/range.steps; docs/range-plan.md §5): a trim
//! range bound to two signals so button#0 can write it PROGRAMMATICALLY (the
//! echo negative), a playhead slider, a vertical fader, and a stamped range
//! per clip bound to the row's own fields.

use kaya::PathKey;

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Clip {
    name: String,
    trim_in: f64,
    trim_out: f64,
}

#[derive(Clone)]
enum Msg {
    Moved(f64, f64),
    Committed(f64, f64),
    Volume(f64),
    ClipTrim(kaya::Path, f64, f64),
    Reset,
    Late,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let mut commits = 0u32;
    let (live_text, commit_text, volume_text, clip_text, low_sig, trim_node) = ctx.apply(|tx| {
        let live_text = tx.signal("live: 2 8");
        let commit_text = tx.signal("commits: 0");
        let volume_text = tx.signal("volume: 0.25");
        let clip_text = tx.signal("clip: none");
        let low_sig = tx.signal(2.0);
        let high_sig = tx.signal(8.0);
        let clips = tx.collection::<Clip>();
        let mut trim_node: Option<kaya::TemplateNodeId> = None;
        let root = tx
            .column(|tx| {
                tx.label(live_text); // label#0
                tx.label(commit_text); // label#1
                tx.label(volume_text); // label#2
                tx.label(clip_text); // label#3
                let trim = tx
                    .range_bound(0.0, 10.0, low_sig, high_sig) // range#0
                    .step(0.5)
                    .tick_spacing(1.0)
                    .min_gap(1.0)
                    .a11y_label("Trim")
                    .low_label("In")
                    .high_label("Out")
                    .id();
                tx.a11y_id(trim, "trim");
                msgs.on_range(trim, Msg::Moved);
                msgs.on_range_commit(trim, Msg::Committed);
                tx.range(0.0, 10.0, 4.0, 6.0) // range#1
                    .step(0.5)
                    .tick_spacing(1.0)
                    .min_gap(0.0)
                    .a11y_label("Tie");
                tx.slider(0.0, 10.0, 5.0).a11y_label("Playhead"); // slider#0
                let volume = tx
                    .slider(0.0, 1.0, 0.25) // slider#1
                    .step(0.25)
                    .axis(kaya::Axis::Vertical)
                    .a11y_label("Volume")
                    .id();
                tx.a11y_id(volume, "volume");
                msgs.on_value(volume, Msg::Volume);
                let reset = tx.button("reset").id(); // button#0
                msgs.on_click(reset, Msg::Reset);
                let late = tx.button("late").id(); // button#1
                msgs.on_click(late, Msg::Late);
                for mut row in clips.rows(tx) {
                    row.label(Clip::name());
                    let trim = row.range(0.0, 10.0, Clip::trim_in(), Clip::trim_out());
                    row.step(trim, 0.5);
                    row.min_gap(trim, 1.0);
                    row.a11y_id(trim, "clip");
                    trim_node = Some(trim);
                }
            })
            .id();
        tx.mount(root);
        tx.insert(&clips, "a", Clip { name: "a".into(), trim_in: 1.0, trim_out: 4.0 });
        tx.insert(&clips, "b", Clip { name: "b".into(), trim_in: 3.0, trim_out: 7.0 });
        let trim_node = trim_node.expect("clips template declared a row range");
        (live_text, commit_text, volume_text, clip_text, low_sig, trim_node)
    });
    msgs.on_range_commit_node(trim_node, Msg::ClipTrim);

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Moved(low, high) => ctx.apply(|tx| {
                tx.write(live_text, format!("live: {low} {high}"));
            }),
            Msg::Committed(low, high) => {
                commits += 1;
                ctx.apply(|tx| {
                    tx.write(commit_text, format!("commits: {commits} at {low} {high}"));
                })
            }
            Msg::Volume(v) => ctx.apply(|tx| {
                tx.write(volume_text, format!("volume: {v}"));
            }),
            Msg::ClipTrim(path, low, high) => ctx.apply(|tx| {
                tx.write(clip_text, format!("clip {}: {low} {high}", path.key::<String>(0)));
            }),
            Msg::Reset => ctx.apply(|tx| {
                // Must NOT come back as a move or a commit.
                tx.write(low_sig, 1.0);
            }),
            Msg::Late => ctx.apply(|tx| {
                // Crosses a high thumb the user moved; the core clamps it (docs/range-plan.md §3).
                tx.write(low_sig, 6.0);
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
