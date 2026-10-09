//! The toast scene (tools/scenes/toast.steps; docs/toast-plan.md §5).

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Item {
    title: String,
}

#[derive(Clone)]
enum Msg {
    Show,
    First,
    Second,
    Delete,
    Hold,
    Dismiss,
    Answer(String, kaya::ToastOutcome),
    Undone(String),
}

fn outcome(o: kaya::ToastOutcome) -> &'static str {
    match o {
        kaya::ToastOutcome::Action => "action",
        kaya::ToastOutcome::Closed => "closed",
    }
}

fn toast(tx: &mut kaya::Tx<'_>, text: &str, action: Option<&str>) -> kaya::ToastId {
    let mut request = tx.show_toast(text);
    if let Some(label) = action {
        request = request.action(label);
    }
    request.show()
}

fn titles(tx: &kaya::Tx<'_>, items: &kaya::Collection<Item>) -> String {
    let all: Vec<String> = tx.items(items).into_iter().map(|(_, item)| item.title).collect();
    if all.is_empty() { "empty".to_string() } else { all.join(", ") }
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (last, count, undone, rows, items) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW)
            .title("toast")
            .menu("Edit", |m| {
                m.item("Undo").role(kaya::MenuRole::Undo).id();
                m.item("Redo").role(kaya::MenuRole::Redo).id();
            })
            .id();
        let last = tx.signal("no answer yet");
        let count = tx.signal("answers 0");
        let undone = tx.signal("nothing undone");
        let rows = tx.signal("Milk, Eggs, Bread");
        let items = tx.collection::<Item>();
        let root = tx
            .column(|tx| {
                tx.label(last); // label#0
                tx.label(count); // label#1
                tx.label(undone); // label#2
                tx.label(rows); // label#3
                let show = tx.button("show").id(); // button#0
                msgs.on_click(show, Msg::Show);
                let first = tx.button("first").id(); // button#1
                msgs.on_click(first, Msg::First);
                let second = tx.button("second").id(); // button#2
                msgs.on_click(second, Msg::Second);
                let delete = tx.button("delete").id(); // button#3
                msgs.on_click(delete, Msg::Delete);
                let hold = tx.button("hold").id(); // button#4
                msgs.on_click(hold, Msg::Hold);
                let dismiss = tx.button("dismiss").id(); // button#5
                msgs.on_click(dismiss, Msg::Dismiss);
                for mut row in items.rows(tx) {
                    row.row(|t| {
                        t.label(Item::title());
                    });
                }
            })
            .id();
        tx.mount(root);
        for title in ["Milk", "Eggs", "Bread"] {
            tx.insert(&items, title, Item { title: title.to_string() });
        }
        (last, count, undone, rows, items)
    });

    msgs.on_undone(kaya::DEFAULT_WINDOW, |label, _| Msg::Undone(label));

    let mut answers = 0;
    let mut undos = 0;
    let mut held = None;
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Show => {
                let id = ctx.apply(|tx| toast(tx, "Saved", None));
                msgs.on_toast(id, |o| Msg::Answer("Saved".into(), o));
            }
            Msg::First => {
                let id = ctx.apply(|tx| toast(tx, "First", Some("Open")));
                msgs.on_toast(id, |o| Msg::Answer("First".into(), o));
            }
            Msg::Second => {
                let id = ctx.apply(|tx| toast(tx, "Second", Some("Open")));
                msgs.on_toast(id, |o| Msg::Answer("Second".into(), o));
            }
            Msg::Delete => {
                let deleted = ctx.apply(|tx| {
                    let (key, item) = tx.items(&items).first().cloned()?;
                    tx.undoable(format!("delete {}", item.title));
                    tx.remove(&items, key);
                    let list = titles(tx, &items);
                    tx.write(rows, list);
                    let text = format!("Deleted {}", item.title);
                    let id = tx.show_toast(&text).action("Undo").undo().show();
                    Some((id, text))
                });
                if let Some((id, text)) = deleted {
                    msgs.on_toast(id, move |o| Msg::Answer(text.clone(), o));
                }
            }
            Msg::Hold => {
                let id = ctx.apply(|tx| tx.show_toast("Working").long().show());
                msgs.on_toast(id, |o| Msg::Answer("Working".into(), o));
                held = Some(id);
            }
            Msg::Dismiss => {
                if let Some(id) = held.take() {
                    ctx.apply(|tx| tx.dismiss_toast(id));
                }
            }
            Msg::Answer(text, o) => {
                answers += 1;
                ctx.apply(|tx| {
                    tx.write(count, format!("answers {answers}"));
                    tx.write(last, format!("{text}: {}", outcome(o)));
                });
            }
            Msg::Undone(label) => {
                undos += 1;
                ctx.apply(|tx| {
                    tx.write(undone, format!("undone {undos}: {label}"));
                    let list = titles(tx, &items);
                    tx.write(rows, list);
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
