use kaya::fmt::{self, NumberFormat, TimecodeRate};
use kaya::PathKey;

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Line { qty: f64 }

#[derive(Clone)]
enum Msg { Committed(f64), Row(kaya::Path, f64), SwitchFormat }

pub(crate) fn app(ctx: kaya::AppCtx) {
    let normal = TimecodeRate::new(25, 1, false).unwrap();
    let drop = TimecodeRate::new(30000, 1001, true).unwrap();
    let msgs = kaya::Messages::new();
    let mut commits = 0;
    let mut phase = 0;
    let (status, playhead, row_status, switching, switch_value) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("Timecode").size(440.0, 500.0);
        let status = tx.signal("commits: 0");
        let row_status = tx.signal("row: none");
        let playhead = tx.signal(fmt::timecode(93087, normal).unwrap());
        let rows = tx.collection::<Line>();
        let switch_value = tx.signal(-2.0);
        let root = tx.column(|tx| {
            let caption = tx.signal("25 fps");
            tx.label(caption);
            tx.label(playhead).a11y_id("playhead");
            let field = tx.number_field(93087.0).format(NumberFormat::Timecode(normal))
                .a11y_id("position").a11y_label("Position").id();
            msgs.on_commit(field, Msg::Committed);
            tx.label(status).a11y_id("commits");
            let caption = tx.signal("29.97 drop-frame");
            tx.label(caption);
            let field = tx.number_field(1799.0).format(NumberFormat::Timecode(drop))
                .a11y_id("drop").a11y_label("Drop frame").id();
            msgs.on_commit(field, Msg::Committed);
            tx.entry().a11y_id("note");
            for mut row in rows.rows(tx) {
                let field = row.number_field(Line::qty());
                row.format(field, NumberFormat::Timecode(normal));
                row.a11y_id(field, "rowtime");
                msgs.on_commit_node(field, Msg::Row);
            }
            tx.label(row_status).a11y_id("row");
            let switching = tx.number_field_bound(switch_value).a11y_id("switching").id();
            let button = tx.button("Switch format").a11y_id("switchformat").id();
            msgs.on_click(button, Msg::SwitchFormat);
            switching
        });
        let (root, switching) = root.into_parts();
        tx.mount(root);
        tx.insert(&rows, "a", Line { qty: 25.0 });
        (status, playhead, row_status, switching, switch_value)
    });
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::SwitchFormat => {
                ctx.apply(|tx| match phase % 4 {
                    0 => { tx.number_format(switching, NumberFormat::Timecode(drop)); tx.write(switch_value, 1800.0); }
                    1 => { tx.write(switch_value, -2.0); tx.number_format(switching, NumberFormat::Number); }
                    2 => { tx.write(switch_value, 1800.0); tx.number_format(switching, NumberFormat::Timecode(drop)); }
                    _ => { tx.number_format(switching, NumberFormat::Number); tx.write(switch_value, -2.0); }
                });
                phase += 1;
            }
            Msg::Committed(frames) => {
                commits += 1;
                ctx.apply(|tx| {
                    tx.write(status, format!("commits: {commits}"));
                    tx.write(playhead, fmt::timecode(frames as i64, normal).unwrap());
                });
            }
            Msg::Row(path, frames) => ctx.apply(|tx| { tx.write(row_status, format!("row {}: {frames}", path.key::<String>(0))); }),
        }
    }
}

fn main() { kaya::run(app) }
