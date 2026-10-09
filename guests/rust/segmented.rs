//! The segmented control scene (tools/scenes/segmented.steps;
//! docs/segmented-plan.md §5): a text control the app can reset, a symbol
//! control, and a stamped control per habit whose pick names its row.

use kaya::PathKey;

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Habit {
    name: String,
    cadence: f64,
}

#[derive(Clone)]
enum Msg {
    Period(usize),
    Reset,
    View(usize),
    Cadence(kaya::Path, f64),
}

const PERIODS: [&str; 3] = ["Day", "Week", "Month"];
const VIEWS: [(&str, kaya::Symbol); 2] = [("Info", kaya::Symbol::Info), ("Edit", kaya::Symbol::Edit)];
const CADENCES: [&str; 2] = ["Daily", "Weekly"];

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (period, period_text, heard_text, view_text, cadence_text, cadence) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("segmented");
        let period = tx.signal(0.0);
        let period_text = tx.signal("period: Day");
        let heard_text = tx.signal("heard: 0");
        let view_text = tx.signal("view: Edit");
        let cadence_text = tx.signal("cadence: -");
        let habits = tx.collection::<Habit>();
        let mut cadence = None;
        let root = tx
            .column(|tx| {
                let seg = tx.segmented_bound(&PERIODS, period).a11y_id("period").a11y_label("Period").id();
                msgs.on_select(seg, Msg::Period);
                tx.label(period_text);
                tx.label(heard_text);
                let reset = tx.button("Reset").a11y_id("reset").id();
                msgs.on_click(reset, Msg::Reset);
                let view = tx.segmented_symbols(&VIEWS, 1).a11y_id("view").a11y_label("View").id();
                msgs.on_select(view, Msg::View);
                tx.label(view_text);
                tx.label(cadence_text);
                for mut row in habits.rows(tx) {
                    row.label(Habit::name());
                    let control = row.segmented(&CADENCES, Habit::cadence());
                    row.a11y_id(control, "cadence");
                    cadence = Some(control);
                }
            })
            .id();
        tx.mount(root);
        tx.insert(&habits, "read", Habit { name: "read".into(), cadence: 1.0 });
        tx.insert(&habits, "walk", Habit { name: "walk".into(), cadence: 0.0 });
        (
            period,
            period_text,
            heard_text,
            view_text,
            cadence_text,
            cadence.expect("the habits template declared a cadence control"),
        )
    });
    msgs.on_value_node(cadence, Msg::Cadence);

    let mut heard = 0;
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Period(index) => {
                heard += 1;
                ctx.apply(|tx| {
                    tx.write(period, index as f64);
                    tx.write(period_text, format!("period: {}", PERIODS[index]));
                    tx.write(heard_text, format!("heard: {heard}"));
                })
            }
            Msg::Reset => ctx.apply(|tx| {
                tx.write(period, 0.0);
                tx.write(period_text, "period: Day");
            }),
            Msg::View(index) => ctx.apply(|tx| tx.write(view_text, format!("view: {}", VIEWS[index].0))),
            Msg::Cadence(path, index) => ctx.apply(|tx| {
                tx.write(
                    cadence_text,
                    format!("cadence {}: {}", path.key::<String>(0), CADENCES[index as usize]),
                )
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
