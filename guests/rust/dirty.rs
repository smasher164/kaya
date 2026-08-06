//! The dirty-state conformance scene: unsaved work as window chrome
//! (docs/dirty-plan.md). One boolean beside `title` and `veto_close`
//! — the app declares STATE and the backend spells its platform's own
//! affordance (the dot in the close button on macOS, a leading `*` in
//! the rendered caption on Windows, a bullet in the GTK header bar,
//! nothing on the phones, which have none).
//!
//! TWO DECLARATIONS, ON PURPOSE. An edit writes the document AND says
//! `.dirty(true)`; saving writes it back and says `.dirty(false)`.
//! kaya does not watch your signals and guess — "the document has
//! unsaved changes" is a statement only the app can make, and the
//! window prop is where it makes it.
//!
//! AND THE MARK ARMS NOTHING. The close attempt fires the veto class
//! this window already opted into, the app opens its own dialog, and
//! cancelling keeps the window with the mark still up. That flow is
//! composed here out of parts that predate this prop — which is the
//! whole reason `dirty` is presentation and nothing else.

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
        // `dirty` and `veto_close` are orthogonal — either can be set
        // without the other, on every platform. This window takes both
        // because it is an editor: it owns its close so it can ask.
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

    // The handler binds to THE WINDOW at its declaration: it can only
    // ever mean this surface's close was asked for.
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
                // Nothing has closed: the veto class says so. An editor
                // with unsaved work asks; a clean one agrees at once.
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
                // Agreeing destroys the surface, which for the PRIMARY
                // window is the process itself — so the scene answers
                // cancel and this arm stays the honest spelling of
                // "yes, close it" rather than a step. Answering a
                // dialog is not saving: the mark stays up either way.
                AlertChoice::Action(_) => tx.destroy_window(kaya::DEFAULT_WINDOW),
                AlertChoice::Cancel => tx.write(status, "kept editing"),
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
