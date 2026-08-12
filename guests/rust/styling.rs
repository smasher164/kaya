//! The styling conformance scene (docs/styling-plan.md, slice 1): the
//! brand accent, the role tier, and the window inset, together because
//! they are one design — brand slots fill each platform's token system,
//! roles say what a widget MEANS, and the inset is the one layout knob
//! the pass admitted (D3).
//!
//! What each piece demonstrates:
//!   - `brand_accent(0x3584E4)` — Adwaita blue, the derivation's
//!     empirical anchor: one hex is the whole call, the core derives
//!     fills and foregrounds, and a platform may let its user override
//!     the result (D2).
//!   - `.role(Heading)` on the title label — the platform's heading
//!     text style AND the assistive heading trait, which is the one
//!     role the steps freeze from the real tree on every lane.
//!   - `.role(Destructive)` / `.role(Prominent)` on the two buttons —
//!     the platform's own emphasis chrome, and (the scene's point) NO
//!     change to what pressing them does.
//!   - `.inset(0.0)` — full bleed, the editor's own need, honored
//!     unconditionally because the inset is kaya's padding (D3).
//!
//! The byte-frozen contract is tools/scenes/styling.steps.

pub(crate) fn app(ctx: kaya::AppCtx) {
    #[derive(Clone)]
    enum Msg {
        Delete,
        Save,
    }

    let msgs = kaya::Messages::<Msg>::new();
    let status = ctx.apply(|tx| {
        // BEFORE THE FIRST MOUNT, per the set-once wall: brand is
        // identity, not state.
        tx.brand_accent(0x3584E4);
        tx.window(kaya::DEFAULT_WINDOW)
            .title("styling")
            .size(480.0, 360.0)
            .inset(0.0);
        let heading = tx.signal("Sections");
        let status = tx.signal("ready");
        let root = tx
            .column(|tx| {
                // expect_ax resolves a target through its AUTHORED
                // id into the real tree, so everything the steps read
                // back is identified (the a11y scene's discipline).
                tx.label(heading).role(kaya::Role::Heading).a11y_id("title"); // label#0
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
