//! The confirm conformance scene: the modal-alert grammar as
//! assertions (DESIGN.md, Presentation contexts). The byte-frozen
//! contract is tools/scenes/confirm.steps.
//!
//! Each dialog is bound to its own handler AT SHOW TIME, so no guest
//! inspects an alert id; registrations retire with their one result.
//! Cancel is the uniform dismissal slot (Esc, back, outside tap, the
//! cancel button itself).

pub(crate) fn app(ctx: kaya::AppCtx) {
    use kaya::AlertChoice;

    #[derive(Clone, Copy)]
    enum Msg {
        AskDelete,
        AskEject,
        Deleted(AlertChoice),
        Ejected(AlertChoice),
    }

    let msgs = kaya::Messages::<Msg>::new();
    let status = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("confirm");
        let status = tx.signal("no decision");
        let root = tx
            .column(|tx| {
                tx.label(status); // label#0
                let delete = tx.button("delete").id(); // button#0
                msgs.on_click(delete, Msg::AskDelete);
                let eject = tx.button("eject").id(); // button#1
                msgs.on_click(eject, Msg::AskEject);
            })
            .id();
        tx.mount(root);
        status
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::AskDelete => {
                let alert = ctx.apply(|tx| {
                    tx.show_alert()
                        .title("delete item?")
                        .message("this cannot be undone")
                        .action("Delete")
                        .action("Archive")
                        .cancel("Keep")
                        .show()
                });
                msgs.on_alert(alert, Msg::Deleted);
            }
            Msg::AskEject => {
                let alert = ctx.apply(|tx| {
                    tx.show_alert()
                        .title("eject disk?")
                        .message("it is still mounted")
                        .action("Eject")
                        .cancel("Hold")
                        .show()
                });
                msgs.on_alert(alert, Msg::Ejected);
            }
            Msg::Deleted(choice) => ctx.apply(|tx| {
                tx.write(
                    status,
                    match choice {
                        AlertChoice::Action(0) => "deleted",
                        AlertChoice::Action(1) => "archived",
                        AlertChoice::Action(_) => unreachable!("the cap is 2"),
                        AlertChoice::Cancel => "kept",
                    },
                );
            }),
            Msg::Ejected(choice) => ctx.apply(|tx| {
                tx.write(
                    status,
                    match choice {
                        AlertChoice::Action(_) => "ejected",
                        AlertChoice::Cancel => "held",
                    },
                );
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
