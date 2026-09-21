//! THROWAWAY guest for the WinUI sheet probe (docs/sheet-plan.md U1): one
//! window with a label and a button, so the backend hook has a live root
//! to present dialogs and a popup over. Nothing here is measured; the
//! probe module (tools/win/sheetprobe/probe.rs) does the asking.

#[derive(Clone)]
enum Msg {
    Clicked,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("sheetprobe");
        let (root, ()) = tx
            .column(|tx| {
                let button = tx.button("press").id();
                msgs.on_click(button, Msg::Clicked);
            })
            .into_parts();
        tx.mount(root);
    });
    println!("PROBEGUEST ready");
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Clicked => println!("PROBEGUEST clicked"),
        }
    }
}

fn main() {
    kaya::run(app)
}
