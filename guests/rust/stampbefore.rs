//! The stamped-sibling scene (tools/scenes/stampbefore.steps; docs/traps.md,
//! the positional loop).

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Bar {
    title: String,
}

#[derive(Clone)]
enum Msg {
    Select,
    Stamp,
    Unstamp,
    Focus,
    Bold,
}

const DOC: &str = "hello world, again";

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (bars, doc, status) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("stampbefore").size(420.0, 360.0);
        let bars = tx.collection::<Bar>();
        let status = tx.signal("0 stamped");
        let (root, doc) = tx
            .column(|tx| {
                for mut row in bars.rows(tx) {
                    row.row(|t| {
                        t.label(Bar::title());
                    });
                }
                let doc = tx.textarea().rich().a11y_id("doc").a11y_label("Document").id();
                tx.set_document(doc, &kaya::Document::new(DOC));
                tx.label(status).a11y_id("stamped");
                tx.row(|tx| {
                    let select = tx.button("select").id();
                    msgs.on_click(select, Msg::Select);
                    let stamp = tx.button("stamp").id();
                    msgs.on_click(stamp, Msg::Stamp);
                    let unstamp = tx.button("unstamp").id();
                    msgs.on_click(unstamp, Msg::Unstamp);
                    let focus = tx.button("focus").id();
                    msgs.on_click(focus, Msg::Focus);
                    let bold = tx.button("bold").id();
                    msgs.on_click(bold, Msg::Bold);
                });
                doc
            })
            .into_parts();
        tx.mount(root);
        (bars, doc, status)
    });

    let mut stamped: Vec<i64> = Vec::new();
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Select => {
                ctx.apply(|tx| {
                    tx.select_range(doc, 6..11);
                });
            }
            Msg::Stamp => {
                ctx.apply(|tx| {
                    let key = tx.insert_fresh(&bars, Bar { title: format!("bar {}", stamped.len() + 1) });
                    stamped.push(key);
                    tx.write(status, format!("{} stamped", stamped.len()));
                });
            }
            Msg::Focus => ctx.apply(|tx| tx.focus(doc)),
            Msg::Bold => ctx.apply(|tx| tx.format(doc, "bold", true)),
            Msg::Unstamp => {
                ctx.apply(|tx| {
                    for key in stamped.drain(..) {
                        tx.remove(&bars, key);
                    }
                    tx.write(status, "0 stamped");
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
