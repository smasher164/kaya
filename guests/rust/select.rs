//! The select conformance scene: a dropdown over three colors and a
//! label folding each pick — the control owns its selection and
//! reports each change as an occurrence (the new 0-based index); the
//! app answers by writing the paired signal, the slider contract with
//! an index.

const OPTIONS: [&str; 3] = ["Red", "Green", "Blue"];

#[derive(Clone)]
enum Msg {
    Picked(usize),
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let picked = ctx.apply(|tx| {
        tx.window_title("select");
        let picked = tx.signal("picked: Red");
        let root = tx
            .column(|tx| {
                let color = tx.select(&OPTIONS, 0).id();
                msgs.on_select(color, Msg::Picked);
                tx.label(picked);
            })
            .id();
        tx.mount(root);
        picked
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Picked(index) => {
                ctx.apply(|tx| {
                    tx.write(picked, format!("picked: {}", OPTIONS[index]));
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
