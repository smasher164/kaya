//! The reorder conformance scene (tools/scenes/reorder.steps).

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Item {
    title: String,
}

#[derive(Clone)]
enum Msg {
    Rotate,
    Lift,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let items = ctx.apply(|tx| {
        let items = tx.collection::<Item>();
        // THE ROOT IS A ROW so the For's container is the only column:
        // construction order differs per language, column#0 may not.
        let root = tx.row(|tx| {
            let rotate = tx.button("rotate").id();
            msgs.on_click(rotate, Msg::Rotate);
            let lift = tx.button("lift").id();
            msgs.on_click(lift, Msg::Lift);
            for mut row in items.rows(tx) {
                row.label(Item::title());
            }
        })
        .id();
        tx.mount(root);
        for key in ["a", "b", "c"] {
            tx.insert(&items, key, Item { title: key.to_string() });
        }
        items
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Rotate => {
                ctx.apply(|tx| {
                    let entries = tx.items(&items);
                    let (first, _) =
                        entries.first().expect("reorder scene has entries").clone();
                    tx.move_to_end(&items, first);
                });
            }
            Msg::Lift => {
                ctx.apply(|tx| {
                    let entries = tx.items(&items);
                    let (last, _) =
                        entries.last().expect("reorder scene has entries").clone();
                    tx.move_to_front(&items, last);
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
