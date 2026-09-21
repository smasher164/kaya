pub(crate) fn app(ctx: kaya::AppCtx) {
    use kaya::AlertChoice;

    #[derive(Clone, Copy)]
    enum Msg {
        AskDelete,
        AskEject,
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

    let tasks = ctx.tasks();
    while let Some(msg) = tasks.next(&msgs) {
        match msg {
            Msg::AskDelete => tasks.spawn(async move |app| {
                let choice = app
                    .show_alert()
                    .title("delete item?")
                    .message("this cannot be undone")
                    .action("Delete")
                    .action("Archive")
                    .cancel("Keep")
                    .await;
                app.apply(|tx| {
                    tx.write(
                        status,
                        match choice {
                            AlertChoice::Action(0) => "deleted",
                            AlertChoice::Action(1) => "archived",
                            AlertChoice::Action(_) => unreachable!("the cap is 2"),
                            AlertChoice::Cancel => "kept",
                        },
                    );
                });
            }),
            Msg::AskEject => tasks.spawn(async move |app| {
                let choice = app
                    .show_alert()
                    .title("eject disk?")
                    .message("it is still mounted")
                    .action("Eject")
                    .cancel("Hold")
                    .await;
                app.apply(|tx| {
                    tx.write(
                        status,
                        match choice {
                            AlertChoice::Action(_) => "ejected",
                            AlertChoice::Cancel => "held",
                        },
                    );
                });
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
