//! The select conformance scene: the control owns its selection and
//! reports each change as a 0-based index — the slider contract with
//! an index. The contract is tools/scenes/select.steps.

const OPTIONS: [&str; 3] = ["Red", "Green", "Blue"];

#[derive(Clone)]
enum Msg {
    Picked(usize),
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let picked = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("select");
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
