//! The nav conformance scene: the serial navigation grammar as
//! assertions (DESIGN.md, Navigation). Two pushes from two buttons —
//! detail (plain: the user's back affordance pops natively and
//! entry_popped reports post-fact) and settings (intercept_back
//! armed: back emits back_requested, nothing pops, and the guest
//! confirms with pop_entry — the close-veto class transplanted to
//! POP). The covered root is RETAINED: the status label takes writes
//! while covered and reads back after every pop. A programmatic
//! pop_entry does not echo entry_popped (its caller already knows) —
//! the settings round's status stays "back requested", which pins
//! exactly that.

pub(crate) fn app(ctx: kaya::AppCtx) {
    use kaya::WindowId;

    #[derive(Clone, Copy)]
    enum Msg {
        OpenDetail,
        OpenSettings,
        Popped(WindowId),
        BackAsked(WindowId),
    }

    const DETAIL: WindowId = WindowId(7);
    const SETTINGS: WindowId = WindowId(8);

    let msgs = kaya::Messages::<Msg>::new();
    let status = ctx.apply(|tx| {
        tx.window_title("nav");
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

    msgs.on_entry_popped(Msg::Popped);
    msgs.on_back_requested(Msg::BackAsked);

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::OpenDetail => ctx.apply(|tx| {
                let entry = tx.push_entry(DETAIL).title("detail").id();
                let pane = tx
                    .column(|tx| {
                        let caption = tx.signal("detail pane");
                        tx.label(caption);
                    })
                    .id();
                tx.mount_in(entry, pane);
                // The covered root keeps taking writes — retention,
                // observable after the pop.
                tx.write(status, "pushed detail");
            }),
            Msg::OpenSettings => ctx.apply(|tx| {
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
            }),
            Msg::Popped(entry) => ctx.apply(|tx| {
                tx.write(
                    status,
                    if entry == DETAIL {
                        "popped detail"
                    } else {
                        "popped settings"
                    },
                );
            }),
            Msg::BackAsked(_) => ctx.apply(|tx| {
                // The veto class: nothing has popped; the guest
                // agrees and confirms. No entry_popped will echo —
                // this write is the round's final status.
                tx.write(status, "back requested");
                tx.pop_entry();
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
