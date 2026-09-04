//! The pickers scene (tools/scenes/pickers.steps; docs/datetime-plan.md):
//! two live pickers bound to signals so button#0 can write them
//! PROGRAMMATICALLY (the echo negative), and a stamped date picker bound
//! to a row's own Date field.

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Task {
    name: String,
    due: kaya::Date,
}

#[derive(Clone)]
enum Msg {
    Date(kaya::Date),
    Time(kaya::Time),
    RowDate(kaya::Path, kaya::Date),
    Reset,
}

fn key_word(path: &kaya::Path) -> String {
    match path.first() {
        Some(kaya::Value::Str(s)) => s.clone(),
        other => format!("{other:?}"),
    }
}

fn date(year: i32, month: u8, day: u8) -> kaya::Date {
    kaya::Date::new(year, month, day).unwrap()
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (date_text, time_text, row_text, date_sig, time_sig, due_node) = ctx.apply(|tx| {
        let date_text = tx.signal("date: none");
        let time_text = tx.signal("time: none");
        let row_text = tx.signal("row: none");
        let date_sig = tx.signal(date(2026, 9, 4));
        let time_sig = tx.signal(kaya::Time::new(14, 30).unwrap());
        let tasks = tx.collection::<Task>();
        let mut due_node = kaya::TemplateNodeId(0);
        let root = tx
            .column(|tx| {
                tx.label(date_text); // label#0
                tx.label(time_text); // label#1
                tx.label(row_text); // label#2
                let due = tx
                    .date_picker_bound(date_sig) // date_picker#0
                    .min_date(date(2026, 1, 1))
                    .max_date(date(2026, 12, 31))
                    .a11y_label("Due")
                    .id();
                tx.a11y_id(due, "when");
                msgs.on_date(due, Msg::Date);
                let at = tx
                    .time_picker_bound(time_sig) // time_picker#0
                    .minute_step(15)
                    .a11y_label("At")
                    .id();
                tx.a11y_id(at, "at");
                msgs.on_time(at, Msg::Time);
                let reset = tx.button("reset").id(); // button#0
                msgs.on_click(reset, Msg::Reset);
                for mut row in tasks.rows(tx) {
                    row.label(Task::name());
                    let picker = row.date_picker(Task::due());
                    row.a11y_id(picker, "due");
                    due_node = picker;
                }
            })
            .id();
        tx.mount(root);
        tx.insert(&tasks, "a", Task { name: "a".into(), due: date(2026, 10, 1) });
        tx.insert(&tasks, "b", Task { name: "b".into(), due: date(2026, 11, 20) });
        (date_text, time_text, row_text, date_sig, time_sig, due_node)
    });
    msgs.on_date_node(due_node, Msg::RowDate);

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Date(picked) => ctx.apply(|tx| {
                tx.write(date_text, format!("date: {picked}"));
            }),
            Msg::Time(picked) => ctx.apply(|tx| {
                tx.write(time_text, format!("time: {picked}"));
            }),
            Msg::RowDate(path, picked) => ctx.apply(|tx| {
                tx.write(row_text, format!("row {}: {picked}", key_word(&path)));
            }),
            Msg::Reset => ctx.apply(|tx| {
                // Must NOT come back as Date/Time occurrences.
                tx.write(date_sig, date(2026, 3, 1));
                tx.write(time_sig, kaya::Time::new(9, 0).unwrap());
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
