//! The number field scene (tools/scenes/numberfield.steps;
//! docs/number-field-plan.md §5): a field over 0..100 stepping by 0.5 bound
//! to a signal so button#0 can write it PROGRAMMATICALLY (the echo
//! negative), an entry for the focus to move to, and a stamped field per
//! row whose commits name the row.

use kaya::PathKey;

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Line {
    name: String,
    qty: f64,
}

#[derive(Clone)]
enum Msg {
    Committed,
    RowQty(kaya::Path, f64),
    Forty,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let mut commits = 0u32;
    let (commit_text, row_text, amount_value, qty_node) = ctx.apply(|tx| {
        let commit_text = tx.signal("commits: 0");
        let row_text = tx.signal("row: none");
        let amount_value = tx.signal(0.0);
        let lines = tx.collection::<Line>();
        let mut qty_node: Option<kaya::TemplateNodeId> = None;
        let root = tx
            .column(|tx| {
                tx.label(commit_text).a11y_id("commits");
                tx.label(row_text).a11y_id("row");
                let amount = tx
                    .number_field_bound(amount_value)
                    .min(0.0)
                    .max(100.0)
                    .step(0.5)
                    .a11y_id("amount")
                    .a11y_label("Amount")
                    .id();
                msgs.on_commit(amount, |_| Msg::Committed);
                tx.entry().a11y_id("note");
                let forty = tx.button("forty").a11y_id("forty").id();
                msgs.on_click(forty, Msg::Forty);
                for mut row in lines.rows(tx) {
                    row.label(Line::name());
                    let qty = row.number_field(Line::qty());
                    row.min(qty, 0.0);
                    row.a11y_id(qty, "qty");
                    qty_node = Some(qty);
                }
            })
            .id();
        tx.mount(root);
        tx.insert(&lines, "a", Line { name: "a".into(), qty: 1.0 });
        tx.insert(&lines, "b", Line { name: "b".into(), qty: 2.0 });
        let qty_node = qty_node.expect("lines template declared a row field");
        (commit_text, row_text, amount_value, qty_node)
    });
    msgs.on_commit_node(qty_node, Msg::RowQty);

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Committed => {
                commits += 1;
                ctx.apply(|tx| {
                    tx.write(commit_text, format!("commits: {commits}"));
                })
            }
            Msg::RowQty(path, v) => ctx.apply(|tx| {
                tx.write(row_text, format!("row {}: {v}", path.key::<String>(0)));
            }),
            Msg::Forty => ctx.apply(|tx| {
                // Must NOT come back as a commit.
                tx.write(amount_value, 40.0);
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
