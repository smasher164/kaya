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

use kaya::Occurrence;

kaya::record! {
    struct Item {
        title: String,
    }
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let mut tx = ctx.begin();
    let items = tx.collection::<Item>();
    let rotate = tx.button("rotate");
    let lift = tx.button("lift");
    let (list, ()) = tx.for_each(&items, |t| {
        t.label(Item::title());
    });
    let root = tx.column(&[rotate, lift, list]);
    tx.mount(root);
    for key in ["a", "b", "c"] {
        tx.insert(&items, key, Item { title: key.to_string() });
    }
    tx.commit();

    loop {
        match ctx.next() {
            Occurrence::ButtonClicked { id } if id == rotate => {
                // First entry to the end. The model owns the order, so
                // the handler asks it which key is first — it never
                // counts widgets.
                let mut tx = ctx.begin();
                let entries = tx.items(&items);
                let (first, _) = entries.first().expect("reorder scene has entries").clone();
                tx.move_to_end(&items, first);
                tx.commit();
            }
            Occurrence::ButtonClicked { id } if id == lift => {
                // Last entry to the front, anchored by key: keys,
                // never indices.
                let mut tx = ctx.begin();
                let entries = tx.items(&items);
                let (last, _) = entries.last().expect("reorder scene has entries").clone();
                let (first, _) = entries.first().expect("reorder scene has entries").clone();
                tx.move_before(&items, last, first);
                tx.commit();
            }
            Occurrence::Shutdown => break,
            _ => {}
        }
    }
}

fn main() {
    kaya::run(app)
}
