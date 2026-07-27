//! The split conformance scene: adaptive list-detail as assertions
//! (DESIGN.md, Adaptive list-detail).
//!
//! The guest asks for the presentation ONCE — `list_detail(true)` on
//! the window — and then does nothing adaptive ever again. Everything
//! after that is the platform re-deciding as the window's size class
//! changes, which is the property being gated: an app does not write
//! two layouts and pick one, and there is no prop for WHICH way it
//! presents.
//!
//! The stack is the ordinary navigation stack. `push_entry` puts the
//! detail on it exactly as the nav scene does, and `back` pops it the
//! same way; on a regular window that entry renders BESIDE the base
//! root instead of covering it. That is the whole design — list-detail
//! is a presentation of a stack kaya already owns, not a second
//! lifecycle grammar — and this guest is the demonstration, because
//! nothing here is split-specific except one prop.

/// TWO scripts drive this ONE app. `split` drives the size class with
/// real resizes and names the presentation on each side; `listdetail`
/// asserts the bare invariant at whatever width its host gives, which
/// is the only spelling a phone or tablet lane can run. Nothing here
/// distinguishes them, and that is the claim both make: the guest does
/// not change with the form factor.
///
/// Which is also why there is no second binary. A scene selects a
/// SCRIPT, never an app — so a runner points both scenes at this one
/// example and the harness reads the .steps file it was named. The one
/// assertion that could not be shared is the window title, and
/// listdetail deliberately does not make it.
pub(crate) fn app(ctx: kaya::AppCtx) {
    use kaya::WindowId;

    #[derive(Clone, Copy)]
    enum Msg {
        OpenDetail,
        PoppedDetail,
    }

    const DETAIL: WindowId = WindowId(7);

    let msgs = kaya::Messages::<Msg>::new();
    let status = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW)
            .title("split")
            // The one adaptive declaration in the whole guest.
            .list_detail(true);
        let status = tx.signal("list pane");
        let root = tx
            .column(|tx| {
                // Authored ids so the REAL-TREE read can address these:
                // `expect label#N` reads kaya's own model and passes
                // whether or not anything reached the screen, which is
                // exactly the gap that let a non-rendering split arm
                // look green.
                tx.label(status).a11y_id("list"); // label#0
                let open = tx.button("open detail").id(); // button#0
                msgs.on_click(open, Msg::OpenDetail);
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
                            tx.label(caption).a11y_id("detail");
                        })
                        .id();
                    tx.mount_in(entry, pane);
                    entry
                });
                // The popped handler rides the push, per-entry — the
                // request-bound precedent, unchanged by the split.
                msgs.on_entry_popped(entry, Msg::PoppedDetail);
            }
            // Retention is the same rule it always was: the base root
            // took this write while the detail was up, on a regular
            // window where it was VISIBLE the whole time.
            Msg::PoppedDetail => ctx.apply(|tx| {
                tx.write(status, "popped detail");
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
