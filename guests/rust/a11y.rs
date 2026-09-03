//! The a11y conformance scene (tools/scenes/a11y.steps): EVERY WIDGET KIND
//! appears, and exactly ONE container of each kind, which is ordinal.

pub(crate) fn app(ctx: kaya::AppCtx) {
    #[derive(Clone, Copy)]
    enum Msg {
        Rename,
    }

    let msgs = kaya::Messages::<Msg>::new();
    let spoken = ctx.apply(|tx| {
        let status = tx.signal("Ready");
        let cell_name = tx.signal("Name");
        let cell_value = tx.signal("Ada");
        let feed_item = tx.signal("Item");
        let spoken_caption = tx.signal("Spoken");
        let spoken = tx.signal("Before");

        let root = tx.column(|tx| {
            // Deliberately NOT labelled: the platform speaks the caption.
            // A hint is a verb phrase; TalkBack prefixes "double tap to".
            tx.button("Save").a11y_id("save").a11y_hint("save the draft");
            tx.checkbox("Details").a11y_id("details").a11y_hint("show more detail");
            tx.button("Reset").a11y_id("reset");
            tx.label(status).a11y_id("status");
            tx.entry().a11y_id("name").a11y_label("Full name");
            tx.textarea().a11y_id("notes").a11y_label("Notes");
            tx.slider(0.0, 1.0, 0.5).a11y_id("volume").a11y_label("Volume");
            tx.progress(0.25).a11y_id("loading").a11y_label("Loading");
            let logo = tx.asset("images/a11y-logo.png");
            tx.image(&logo).a11y_id("logo").a11y_label("Logo");
            tx.select(&["Red", "Green"], 0).a11y_id("color").a11y_label("Color");
            tx.radio(&["Small", "Large"], 0).a11y_id("size").a11y_label("Size");
            // NAMING a container declares it a group, and its children must
            // stay reachable (docs/traps.md, `children: .contain`).
            tx.grid(2, |tx| {
                tx.label(cell_name);
                tx.label(cell_value);
            })
            .a11y_id("cells")
            .a11y_label("Cells");
            tx.scroll(|tx| {
                tx.label(feed_item);
            })
            .a11y_id("feed")
            .a11y_label("Feed");
            tx.row(|tx| {
                tx.button("Cancel").a11y_id("cancel");
                tx.button("OK").a11y_id("ok");
            })
            .a11y_id("actions")
            .a11y_label("Actions");
            tx.label(spoken_caption).a11y_id("spoken").a11y_label(spoken);
            let rename = tx.button("Rename").a11y_id("rename").id();
            msgs.on_click(rename, Msg::Rename);
        })
        .a11y_id("form")
        .a11y_label("Form")
        .id();
        tx.mount(root);
        spoken
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Rename => ctx.apply(|tx| {
                tx.write(spoken, "After");
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
