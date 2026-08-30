//! The styling conformance scene (docs/styling-plan.md slice 1): brand
//! accent, role tier, window inset. The byte-frozen contract is
//! tools/scenes/styling.steps.
//!
//! `Heading` is the one role with a real-tree observable on every lane,
//! which is why the steps freeze it and not the other two. 0x3584E4 is
//! Adwaita blue, the derivation's empirical anchor (D2).

pub(crate) fn app(ctx: kaya::AppCtx) {
    #[derive(Clone)]
    enum Msg {
        Delete,
        Save,
    }

    let msgs = kaya::Messages::<Msg>::new();
    let status = ctx.apply(|tx| {
        // BEFORE THE FIRST MOUNT, per the set-once wall.
        tx.brand_accent(0x3584E4);
        tx.window(kaya::DEFAULT_WINDOW)
            .title("styling")
            .size(480.0, 360.0)
            .inset(0.0);
        let heading = tx.signal("Sections");
        let status = tx.signal("ready");
        let root = tx
            .column(|tx| {
                // expect_ax resolves a target through its AUTHORED id,
                // so everything the steps read back is identified.
                tx.heading(heading).a11y_id("title"); // label#0
                tx.label(status); // label#1
                let delete = tx
                    .button("Delete")
                    .role(kaya::Role::Destructive)
                    .a11y_id("delete")
                    .id(); // button#0
                msgs.on_click(delete, Msg::Delete);
                let save = tx
                    .button("Save")
                    .role(kaya::Role::Prominent)
                    .a11y_id("save")
                    .id(); // button#1
                msgs.on_click(save, Msg::Save);
                // Declared so every backend's caption arm runs, like the
                // two button roles: no universal AX observable, so the
                // walls are the arms' refusals plus this label's text.
                let cap = tx.signal("captioned");
                tx.caption(cap); // label#2
            })
            .id();
        tx.mount(root);
        status
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Delete => ctx.apply(|tx| tx.write(status, "deleted")),
            Msg::Save => ctx.apply(|tx| tx.write(status, "saved")),
        }
    }
}

fn main() {
    kaya::run(app)
}
