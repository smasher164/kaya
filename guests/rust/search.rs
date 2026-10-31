//! The search scene (tools/scenes/search.steps): a search field filtering a
//! list on every keystroke, the app owning the predicate (docs/search-plan.md
//! S9) and each row hiding in place (docs/hidden-plan.md).

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Item {
    name: String,
    unmatched: bool,
}

#[derive(Clone)]
enum Msg {
    Query(String),
}

const ITEMS: [&str; 4] = ["apple", "banana", "cherry", "mango"];

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (items, count) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("search");
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
                    let name = row.label(Item::name());
                    row.hidden(name, Item::unmatched());
                }
                tx.a11y_id(list, "list");
            })
            .id();
        tx.mount(root);
        for name in ITEMS {
            tx.insert(&items, name.to_string(), Item { name: name.to_string(), unmatched: false });
        }
        (items, count)
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Query(query) => {
                let query = query.to_lowercase();
                let wanted = ITEMS.iter().filter(|name| name.contains(&query)).count();
                ctx.apply(|tx| {
                    for name in ITEMS {
                        tx.update_field(&items, name.to_string(), Item::unmatched(), !name.contains(&query));
                    }
                    let text = if query.is_empty() {
                        format!("{} items", ITEMS.len())
                    } else {
                        format!("{wanted} of {} match", ITEMS.len())
                    };
                    tx.write(count, text);
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
