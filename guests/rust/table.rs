//! The table scene (tools/scenes/table.steps): a header click is a REQUEST,
//! and the platform sorts nothing.

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Item {
    name: String,
    size: String,
}

#[derive(Clone)]
enum Msg {
    Sort(u32),
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (items, table) = ctx.apply(|tx| {
        let items = tx.collection::<Item>();
        // The root is a row: the For's container is the only column.
        let mut table = kaya::WidgetId(0);
        let root = tx.row(|tx| {
            let rows = items
                .rows(tx)
                .columns(&["Name", "Size"], kaya::Sort::none())
                .on_sort(&msgs, Msg::Sort);
            table = rows.id();
            for mut row in rows {
                // One cell per declared column: the core holds the arity.
                row.row(|t| {
                    t.label(Item::name());
                    t.label(Item::size());
                });
            }
            // Grown on purpose: ungrown, a table hugs its rows.
            tx.grow(table, 1.0);
        })
        .id();
        tx.mount(root);
        for (key, name, size) in
            [("b", "banana", "30"), ("a", "apple", "10"), ("c", "cherry", "20")]
        {
            tx.insert(
                &items,
                key,
                Item { name: name.to_string(), size: size.to_string() },
            );
        }
        (items, table)
    });

    // The guest's sort policy; the platform never has one.
    let mut sorted: Option<(u32, bool)> = None;
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Sort(column) => {
                let descending = match sorted {
                    Some((current, desc)) if current == column => !desc,
                    _ => false,
                };
                sorted = Some((column, descending));
                ctx.apply(|tx| {
                    let mut entries = tx.items(&items);
                    entries.sort_by(|a, b| {
                        let (ka, kb) = if column == 0 {
                            (&a.1.name, &b.1.name)
                        } else {
                            (&a.1.size, &b.1.size)
                        };
                        if descending { kb.cmp(ka) } else { ka.cmp(kb) }
                    });
                    // Each key to the end, in the target order.
                    for (key, _) in &entries {
                        tx.move_to_end(&items, key.clone());
                    }
                    let indicator = if descending {
                        kaya::Sort::desc(column)
                    } else {
                        kaya::Sort::asc(column)
                    };
                    tx.columns(table, &["Name", "Size"], indicator);
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
