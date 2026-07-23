//! The panels conformance scene: the auxiliary-window grammar as
//! assertions. A main window and an inspector; the inspector arms
//! veto_close, so the chrome close EMITS close_requested and closes
//! nothing — the guest answers by recording the request in the status
//! label and destroying the window (the request/confirm veto class,
//! DESIGN.md's Presentation contexts). Desktop-only: phone hosts
//! reject create_window at the root by capability.

pub(crate) fn app(ctx: kaya::AppCtx) {
    use kaya::WindowId;

    const INSPECTOR: WindowId = WindowId(1);

    // The handler binds to THE INSPECTOR at its declaration (handlers
    // scope to the thing that creates them): it can only ever mean
    // this window's close was vetoed — no id inspection anywhere.
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
