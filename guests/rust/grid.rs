//! The grid conformance scene (tools/scenes/grid.steps): labels aligned
//! across rows, which nested rows cannot express.

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("grid");
        let root = tx
            .column(|tx| {
                tx.grid(2, |tx| {
                    let name = tx.signal("Name:");
                    tx.label(name); // label#0
                    let who = tx.signal("Ada Lovelace");
                    tx.label(who); // label#1
                    let role = tx.signal("Role:");
                    tx.label(role); // label#2
                    let what = tx.signal("Engine programmer");
                    tx.label(what); // label#3
                });
                tx.row(|tx| {
                    tx.button("left"); // button#0
                    tx.spacer();
                    tx.button("right"); // button#1
                })
                .grow(1.0);
            })
            .id();
        tx.mount(root);
    });

    while msgs.next(&ctx).is_some() {}
}

fn main() {
    kaya::run(app)
}
