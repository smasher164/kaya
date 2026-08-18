//! The nav conformance scene: the serial navigation grammar as
//! assertions (DESIGN.md, Navigation). Two pushes — one plain, one
//! with intercept_back armed. The byte-frozen contract is
//! tools/scenes/nav.steps.
//!
//! A programmatic `pop_entry` does NOT echo entry_popped, which is why
//! the settings round's status stays "back requested".

pub(crate) fn app(ctx: kaya::AppCtx) {
    use kaya::WindowId;

    #[derive(Clone, Copy)]
    enum Msg {
        OpenDetail,
        OpenSettings,
        // Distinct variants per entry: the association is structural,
        // so no guest inspects an id anywhere.
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
                    // The covered root keeps taking writes: retention,
                    // observable after the pop.
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
                // The veto class: nothing has popped yet. No
                // entry_popped will follow the confirm below, so this
                // write is the round's final status.
                tx.write(status, "back requested");
                tx.pop_entry();
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
