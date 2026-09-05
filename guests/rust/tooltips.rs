//! The tooltips scene (tools/scenes/tooltips.steps; docs/tooltip-plan.md):
//! help text on four kinds including a container, one widget declaring
//! both a hint and help, a help bound to a signal, and stamped labels whose
//! help is the row's own field.

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Account {
    name: String,
    note: String,
}

#[derive(Clone)]
enum Msg {
    Save,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let name_help = ctx.apply(|tx| {
        let name_help = tx.signal("Your full name as it appears on the card");
        let accounts = tx.collection::<Account>();
        let root = tx
            .column(|tx| {
                let save = tx.button("Save").help("Saves the draft to disk").id(); // button#0
                tx.a11y_id(save, "save");
                msgs.on_click(save, Msg::Save);
                let discard = tx
                    .button("Discard") // button#1
                    .help("Throws the draft away")
                    .a11y_hint("discard every change")
                    .id();
                tx.a11y_id(discard, "discard");
                let name = tx.entry().help(name_help).id(); // entry#0
                tx.a11y_id(name, "fullname");
                let volume = tx.slider(0.0, 1.0, 0.5).help("How loud the preview plays").id(); // slider#0
                tx.a11y_id(volume, "volume");
                for mut row in accounts.rows(tx) {
                    let label = row.label(Account::name());
                    row.help(label, Account::note());
                    row.a11y_id(label, Account::name());
                }
            })
            .help("The settings for this account") // column#0
            .id();
        tx.a11y_id(root, "settings");
        tx.mount(root);
        tx.insert(
            &accounts,
            "a",
            Account { name: "a".into(), note: "The first account, opened in March".into() },
        );
        tx.insert(
            &accounts,
            "b",
            Account { name: "b".into(), note: "The second account, opened in May".into() },
        );
        name_help
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Save => ctx.apply(|tx| {
                tx.write(name_help, "Your name, as saved");
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
