//! The dirty-state scene (tools/scenes/dirty.steps). `dirty` IS DECLARED,
//! never inferred: kaya does not watch your signals and guess.

pub(crate) fn app(ctx: kaya::AppCtx) {
    use kaya::AlertChoice;

    #[derive(Clone, Copy)]
    enum Msg {
        Edit,
        Save,
        CloseAsked,
        Answered(AlertChoice),
    }

    let msgs = kaya::Messages::<Msg>::new();
    let (doc, status) = ctx.apply(|tx| {
        // `dirty` and `veto_close` are orthogonal.
        tx.window(kaya::DEFAULT_WINDOW).title("dirty").veto_close(true);
        let doc = tx.signal("notes");
        let status = tx.signal("saved");
        let root = tx
            .column(|tx| {
                tx.label(doc); // label#0
                tx.label(status); // label#1
                let edit = tx.button("edit").id(); // button#0
                msgs.on_click(edit, Msg::Edit);
                let save = tx.button("save").id(); // button#1
                msgs.on_click(save, Msg::Save);
            })
            .id();
        tx.mount(root);
        (doc, status)
    });

    msgs.on_close_requested(kaya::DEFAULT_WINDOW, Msg::CloseAsked);

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Edit => ctx.apply(|tx| {
                tx.write(doc, "notes and a line");
                tx.write(status, "unsaved");
                tx.window(kaya::DEFAULT_WINDOW).dirty(true);
            }),
            Msg::Save => ctx.apply(|tx| {
                tx.write(status, "saved");
                tx.window(kaya::DEFAULT_WINDOW).dirty(false);
            }),
            Msg::CloseAsked => {
                let alert = ctx.apply(|tx| {
                    tx.show_alert()
                        .title("unsaved changes")
                        .message("the document has unsaved changes")
                        .action("Discard")
                        .cancel("Keep Editing")
                        .show()
                });
                msgs.on_alert(alert, Msg::Answered);
            }
            Msg::Answered(choice) => ctx.apply(|tx| match choice {
                // THIS ARM ABORTS IF IT EVER RUNS — docs/traps.md, "An
                // app can VETO a close but cannot AGREE to one".
                AlertChoice::Action(_) => tx.destroy_window(kaya::DEFAULT_WINDOW),
                AlertChoice::Cancel => tx.write(status, "kept editing"),
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
