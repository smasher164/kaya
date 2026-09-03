//! The panels conformance scene (tools/scenes/panels.steps). DESKTOP-ONLY:
//! phone hosts reject create_window by capability.

pub(crate) fn app(ctx: kaya::AppCtx) {
    use kaya::WindowId;

    const INSPECTOR: WindowId = WindowId(1);

    #[derive(Clone, Copy)]
    enum Msg {
        CloseAsked,
    }

    let msgs = kaya::Messages::<Msg>::new();
    let status = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("panels");
        let status = tx.signal("two panels");

        let root = tx
            .column(|tx| {
                tx.label(status); // label#0
            })
            .id();
        tx.mount(root);

        let inspector = tx
            .create_window(INSPECTOR)
            .title("inspector")
            .size(480.0, 320.0)
            .veto_close(true)
            .id();
        let aux_root = tx
            .column(|tx| {
                let caption = tx.signal("inspector pane");
                tx.label(caption); // label#1
            })
            .id();
        tx.mount_in(inspector, aux_root);

        status
    });

    msgs.on_close_requested(INSPECTOR, Msg::CloseAsked);

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::CloseAsked => ctx.apply(|tx| {
                tx.write(status, "close requested");
                tx.destroy_window(INSPECTOR);
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
