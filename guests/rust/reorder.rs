//! The reorder scene: order as collection data, end to end. Three
//! stamped rows and two buttons that never touch a widget — each
//! handler repositions an entry by key (collection_move on the wire,
//! move_child at the toolkit), and the selftest's expect_order reads
//! the toolkit's actual child order back, which no creation-ordered
//! registry could observe.
//!
//! The backend selftest (KAYA_SELFTEST=reorder) checks "a|b|c", clicks
//! rotate (first entry to the end), checks "b|c|a", clicks lift (last
//! entry before the first), and checks "a|b|c" again.

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Item {
    title: String,
}

/// The event vocabulary: two buttons, two meanings.
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
        let (root, ()) = tx.row(|tx| {
            let rotate = tx.button("rotate");
            msgs.on_click(rotate, Msg::Rotate);
            let lift = tx.button("lift");
            msgs.on_click(lift, Msg::Lift);
            for mut row in items.rows(tx) {
                row.label(Item::title());
            }
        });
        tx.mount(root);
        for key in ["a", "b", "c"] {
            tx.insert(&items, key, Item { title: key.to_string() });
        }
        items
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Rotate => {
                // First entry to the end. The model owns the order, so
                // the handler asks it which key is first — it never
                // counts widgets.
                ctx.apply(|tx| {
                    let entries = tx.items(&items);
                    let (first, _) =
                        entries.first().expect("reorder scene has entries").clone();
                    tx.move_to_end(&items, first);
                });
            }
            Msg::Lift => {
                // Last entry to the front: move_to_front is sugar for
                // move_before the current first key — the same wire
                // op, keys never indices.
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
