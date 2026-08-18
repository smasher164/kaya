//! The reorder scene: order as collection data, end to end. Each
//! handler repositions an entry BY KEY and never touches a widget;
//! expect_order reads the toolkit's actual child order back. The
//! byte-frozen contract is tools/scenes/reorder.steps.

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
        // The root is a row so the For's container is the scene's only
        // column-kind widget: statement-shaped construction is
        // parent-first, expression trees are children-first, and
        // column#0 must name the same widget in every language.
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
                // The MODEL owns the order, so the handler asks it which
                // key is first; it never counts widgets.
                ctx.apply(|tx| {
                    let entries = tx.items(&items);
                    let (first, _) =
                        entries.first().expect("reorder scene has entries").clone();
                    tx.move_to_end(&items, first);
                });
            }
            Msg::Lift => {
                // Keys, never indices.
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
