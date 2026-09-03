//! The nav conformance scene (tools/scenes/nav.steps): a programmatic
//! `pop_entry` does NOT echo entry_popped.

pub(crate) fn app(ctx: kaya::AppCtx) {
    use kaya::WindowId;

    #[derive(Clone, Copy)]
    enum Msg {
        OpenDetail,
        OpenSettings,
        // Distinct variants per entry: no guest inspects an id.
        PoppedDetail,
        BackAskedSettings,
    }

    const DETAIL: WindowId = WindowId(7);
    const SETTINGS: WindowId = WindowId(8);

    let msgs = kaya::Messages::<Msg>::new();
    let status = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("nav");
        let status = tx.signal("at root");
        let root = tx
            .column(|tx| {
                tx.label(status); // label#0
                let detail = tx.button("open detail").id(); // button#0
                msgs.on_click(detail, Msg::OpenDetail);
                let settings = tx.button("open settings").id(); // button#1
                msgs.on_click(settings, Msg::OpenSettings);
            })
            .id();
        tx.mount(root);
        status
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::OpenDetail => {
                let entry = ctx.apply(|tx| {
                    let entry = tx.push_entry(DETAIL).title("detail").id();
                    let pane = tx
                        .column(|tx| {
                            let caption = tx.signal("detail pane");
                            tx.label(caption);
                        })
                        .id();
                    tx.mount_in(entry, pane);
                    // The covered root keeps taking writes: retention.
                    tx.write(status, "pushed detail");
                    entry
                });
                // Rides the push, per-entry, and retires with the pop.
                msgs.on_entry_popped(entry, Msg::PoppedDetail);
            }
            Msg::OpenSettings => {
                let entry = ctx.apply(|tx| {
                    let entry = tx
                        .push_entry(SETTINGS)
                        .title("settings")
                        .intercept_back(true)
                        .id();
                    let pane = tx
                        .column(|tx| {
                            let caption = tx.signal("settings pane");
                            tx.label(caption);
                        })
                        .id();
                    tx.mount_in(entry, pane);
                    tx.write(status, "pushed settings");
                    entry
                });
                msgs.on_back_requested(entry, Msg::BackAskedSettings);
            }
            Msg::PoppedDetail => ctx.apply(|tx| {
                tx.write(status, "popped detail");
            }),
            Msg::BackAskedSettings => ctx.apply(|tx| {
                // Nothing has popped, and no entry_popped will follow.
                tx.write(status, "back requested");
                tx.pop_entry();
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
