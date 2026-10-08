//! The reveal toggle scene (tools/scenes/reveal.steps; docs/reveal-plan.md
//! §5): a password field with its own show/hide toggle, the app's own Show
//! and Hide buttons, and a stamped field each row reveals by its own field.

use kaya::PathKey;

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Account {
    name: String,
    shown: bool,
}

#[derive(Clone)]
enum Msg {
    Typed(String),
    Submitted(String),
    Toggled(bool),
    Show(bool),
    Clear,
    Pin(kaya::Path, String),
    PinToggled(kaya::Path, bool),
}

const PASSWORD: &str = "Rv4tNbHy2mQc";

fn status(text: &str) -> String {
    match text.chars().count() {
        0 => "empty".to_string(),
        n if text == PASSWORD => format!("{n} characters, match"),
        n => format!("{n} characters, no match"),
    }
}

fn shown(on: bool) -> &'static str {
    if on { "shown" } else { "hidden" }
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (status_text, sent_text, heard_text, pin_text, field, pin_node) = ctx.apply(|tx| {
        let status_text = tx.signal("empty");
        let sent_text = tx.signal("sent: -");
        let heard_text = tx.signal("heard: -");
        let pin_text = tx.signal("pin: -");
        let accounts = tx.collection::<Account>();
        let mut pin_node = None;
        let mut field = None;
        let root = tx
            .column(|tx| {
                let password = tx
                    .secure_field()
                    .placeholder("Password")
                    .content_type(kaya::ContentType::Password)
                    .revealable()
                    .a11y_id("password")
                    .a11y_label("Password")
                    .id();
                msgs.on_change(password, Msg::Typed);
                msgs.on_submit(password, Msg::Submitted);
                msgs.on_toggle(password, Msg::Toggled);
                field = Some(password);
                tx.label(status_text).a11y_id("status");
                tx.label(sent_text).a11y_id("sent");
                tx.label(heard_text).a11y_id("heard");
                let show = tx.button("Show").a11y_id("show").id();
                msgs.on_click(show, Msg::Show(true));
                let hide = tx.button("Hide").a11y_id("hide").id();
                msgs.on_click(hide, Msg::Show(false));
                let clear = tx.button("Clear").a11y_id("clear").id();
                msgs.on_click(clear, Msg::Clear);
                tx.label(pin_text).a11y_id("pin_status");
                for mut row in accounts.rows(tx) {
                    row.label(Account::name());
                    let pin = row.secure_field();
                    row.a11y_id(pin, "pin");
                    row.revealable(pin);
                    row.revealed(pin, Account::shown());
                    pin_node = Some(pin);
                }
            })
            .id();
        tx.mount(root);
        tx.insert(&accounts, "b", Account { name: "b".into(), shown: true });
        (
            status_text,
            sent_text,
            heard_text,
            pin_text,
            field.expect("the column declared the password field"),
            pin_node.expect("the accounts template declared a pin field"),
        )
    });
    msgs.on_change_node(pin_node, Msg::Pin);
    msgs.on_toggle_node(pin_node, Msg::PinToggled);

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Typed(text) => ctx.apply(|tx| tx.write(status_text, status(&text))),
            Msg::Submitted(text) => {
                ctx.apply(|tx| tx.write(sent_text, format!("sent: {}", status(&text))))
            }
            Msg::Toggled(on) => ctx.apply(|tx| tx.write(heard_text, format!("heard: {}", shown(on)))),
            Msg::Show(on) => ctx.apply(|tx| tx.revealed(field, on)),
            Msg::Clear => ctx.apply(|tx| tx.clear(field)),
            Msg::Pin(path, text) => ctx.apply(|tx| {
                tx.write(pin_text, format!("pin {}: {}", path.key::<String>(0), text.chars().count()))
            }),
            Msg::PinToggled(path, on) => ctx.apply(|tx| {
                tx.write(pin_text, format!("pin {}: {}", path.key::<String>(0), shown(on)))
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
