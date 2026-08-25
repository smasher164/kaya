//! The windowed scene's guest (docs/virtualization-plan.md §6.3): 400
//! uniform rows in a grown table — enough to overflow every tier's
//! band — with the guest writing no windowing code at all. The
//! COMPILED guest is the point: ledger/varied are Python and cannot
//! reach the mobile lanes, so this one carries expect_window and
//! scroll_to_row to all five. The byte-frozen contract is
//! tools/scenes/windowed.steps.

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Item {
    name: String,
    size: String,
}

#[derive(Clone)]
enum Msg {}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::<Msg>::new();
    ctx.apply(|tx| {
        let items = tx.collection::<Item>();
        let root = tx.row(|tx| {
            let rows = items.rows(tx).columns(&["Name", "Size"], kaya::Sort::none());
            let table = rows.id();
            for mut row in rows {
                row.row(|t| {
                    t.label(Item::name());
                    t.label(Item::size());
                });
            }
            tx.grow(table, 1.0);
        })
        .id();
        tx.mount(root);
        for i in 0..400 {
            let key = format!("r{i:03}");
            tx.insert(
                &items,
                key.as_str(),
                Item { name: format!("row {i}"), size: format!("{}", i * 3) },
            );
        }
    });

    // No handlers: the harness drives the window; the guest only holds
    // the scene open.
    while let Some(msg) = msgs.next(&ctx) {
        match msg {}
    }
}

fn main() {
    kaya::run(app);
}
