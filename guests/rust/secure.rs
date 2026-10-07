//! The secure field scene (tools/scenes/secure.steps;
//! docs/secure-entry-plan.md §5): a password field whose text the app
//! receives whole and answers only as a length and a match, a clear button,
//! and a stamped field per account whose edits name the row.

use kaya::PathKey;

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Account {
    name: String,
}

#[derive(Clone)]
enum Msg {
    Typed(String),
    Submitted(String),
    Clear,
    Pin(kaya::Path, String),
}

const PASSWORD: &str = "Zq7vKeXw9pLm";

fn status(text: &str) -> String {
    match text.chars().count() {
        0 => "empty".to_string(),
        n if text == PASSWORD => format!("{n} characters, match"),
        n => format!("{n} characters, no match"),
    }
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (status_text, sent_text, pin_text, field, pin_node) = ctx.apply(|tx| {
        let status_text = tx.signal("empty");
        let sent_text = tx.signal("sent: -");
        let pin_text = tx.signal("pin: -");
        let accounts = tx.collection::<Account>();
        let mut pin_node = None;
        let mut field = None;
        let root = tx
            .column(|tx| {
                let password = tx
                    .secure_field()
                    .placeholder("Password")
                    .a11y_id("password")
                    .a11y_label("Password")
                    .id();
                msgs.on_change(password, Msg::Typed);
                msgs.on_submit(password, Msg::Submitted);
                field = Some(password);
                tx.label(status_text).a11y_id("status");
                tx.label(sent_text).a11y_id("sent");
                let clear = tx.button("Clear").a11y_id("clear").id();
                msgs.on_click(clear, Msg::Clear);
                tx.label(pin_text).a11y_id("pin_status");
                for mut row in accounts.rows(tx) {
                    row.label(Account::name());
                    let pin = row.secure_field();
                    row.a11y_id(pin, "pin");
                    pin_node = Some(pin);
                }
            })
            .id();
        tx.mount(root);
        tx.insert(&accounts, "a", Account { name: "a".into() });
        tx.insert(&accounts, "b", Account { name: "b".into() });
        (
            status_text,
            sent_text,
            pin_text,
            field.expect("the column declared the password field"),
            pin_node.expect("the accounts template declared a pin field"),
        )
    });
    msgs.on_change_node(pin_node, Msg::Pin);

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Typed(text) => ctx.apply(|tx| tx.write(status_text, status(&text))),
            Msg::Submitted(text) => {
                ctx.apply(|tx| tx.write(sent_text, format!("sent: {}", status(&text))))
            }
            Msg::Clear => ctx.apply(|tx| tx.clear(field)),
            Msg::Pin(path, text) => ctx.apply(|tx| {
                tx.write(
                    pin_text,
                    format!("pin {}: {}", path.key::<String>(0), text.chars().count()),
                )
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
