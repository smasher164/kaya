//! The table scene: column headers and click-to-sort on the For
//! vocabulary (docs/tables-plan.md). A header click is a REQUEST —
//! this guest reorders its collection BY KEY (the reorder scene's
//! idiom) and re-declares the header with the new indicator; the
//! platform sorts nothing. The byte-frozen contract is
//! tools/scenes/table.steps.

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
        // The root is a row so the For's container is the scene's only
        // column-kind widget (the reorder scene's rule).
        let mut table = kaya::WidgetId(0);
        let root = tx.row(|tx| {
            // The table IS the For, with headers chained onto it —
            // the declaration and the click handler ride the same
            // construction that stamps the rows.
            let rows = items
                .rows(tx)
                .columns(&["Name", "Size"], kaya::Sort::none())
                .on_sort(&msgs, Msg::Sort);
            table = rows.id();
            for mut row in rows {
                // One cell per declared column, in a Row — the arity
                // the core holds this template to.
                row.row(|t| {
                    t.label(Item::name());
                    t.label(Item::size());
                });
            }
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

    // The guest's sort policy — the platform never has one: clicking
    // the sorted column flips it, clicking another starts ascending.
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
                    // Keys, never indices: moving each key to the end
                    // in the target order leaves the collection sorted.
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
