//! The search scene (tools/scenes/search.steps): a search field filtering a
//! list on every keystroke, the app owning the filter (docs/search-plan.md
//! S9) — the visible set is a diff of removes and inserts by key.

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Item {
    name: String,
}

#[derive(Clone)]
enum Msg {
    Query(String),
}

const ITEMS: [&str; 4] = ["apple", "banana", "cherry", "mango"];

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (items, count) = ctx.apply(|tx| {
        let items = tx.collection::<Item>();
        let count = tx.signal(format!("{} items", ITEMS.len()));
        let root = tx
            .column(|tx| {
                let find = tx.search().placeholder("Search").a11y_id("find").a11y_label("Find items").id();
                msgs.on_change(find, Msg::Query);
                tx.label(count).a11y_id("count");
                // The For IS the list: expect_order reads its label children.
                let rows = items.rows(tx);
                let list = rows.id();
                for mut row in rows {
                    row.label(Item::name());
                }
                tx.a11y_id(list, "list");
            })
            .id();
        tx.mount(root);
        for name in ITEMS {
            tx.insert(&items, name.to_string(), Item { name: name.to_string() });
        }
        (items, count)
    });

    let mut visible: Vec<&str> = ITEMS.to_vec();
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Query(query) => {
                let query = query.to_lowercase();
                let wanted: Vec<&str> =
                    ITEMS.iter().copied().filter(|name| name.contains(&query)).collect();
                ctx.apply(|tx| {
                    // A DIFF, never clear-and-refill: only the rows whose
                    // membership changed move (docs/search-plan.md S9).
                    for name in &visible {
                        if !wanted.contains(name) {
                            tx.remove(&items, name.to_string());
                        }
                    }
                    for name in &wanted {
                        if !visible.contains(name) {
                            tx.insert(&items, name.to_string(), Item { name: name.to_string() });
                        }
                    }
                    // Insertion order is arrival order, so a row coming back
                    // lands last; walking the wanted keys to the end in order
                    // puts the list back in ITEMS order.
                    for name in &wanted {
                        tx.move_to_end(&items, name.to_string());
                    }
                    let text = if query.is_empty() {
                        format!("{} items", ITEMS.len())
                    } else {
                        format!("{} of {} match", wanted.len(), ITEMS.len())
                    };
                    tx.write(count, text);
                });
                visible = wanted;
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
