//! The radio conformance scene: a size group over three options and a
//! label folding each pick — the choice contract (see select.rs) in
//! its inline presentation.

const OPTIONS: [&str; 3] = ["Small", "Medium", "Large"];

#[derive(Clone)]
enum Msg {
    Picked(usize),
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let size = ctx.apply(|tx| {
        tx.window_title("radio");
        let size = tx.signal("size: Small");
        let root = tx
            .column(|tx| {
                let group = tx.radio(&OPTIONS, 0).id();
                msgs.on_select(group, Msg::Picked);
                tx.label(size);
            })
            .id();
        tx.mount(root);
        size
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Picked(index) => {
                ctx.apply(|tx| {
                    tx.write(size, format!("size: {}", OPTIONS[index]));
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
