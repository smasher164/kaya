//! The clean-quit scene (tools/scenes/auxquit.steps): the first launch opens
//! an aux window and the second opens none, so a window the system brings
//! back is one the app never created.

pub(crate) fn app(ctx: kaya::AppCtx) {
    let prefs = kaya::prefs();
    let first = !prefs.get_bool("auxquit.opened", false);
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("auxquit");
        let note = tx.signal(if first { "first launch" } else { "second launch" });
        let root = tx.column(|tx| {
            tx.label(note); // label#0
        });
        let root = root.id();
        tx.mount(root);
        if first {
            let inspector = tx.create_window(kaya::WindowId(1)).title("inspector").size(480.0, 320.0).id();
            let pane = tx.column(|tx| {
                let caption = tx.signal("inspector pane");
                tx.label(caption); // label#1
            });
            let pane = pane.id();
            tx.mount_in(inspector, pane);
        }
    });
    if first {
        prefs.set_bool("auxquit.opened", true);
    }
    while msgs.next(&ctx).is_some() {}
}

fn main() {
    kaya::run(app)
}
