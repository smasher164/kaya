//! The content type scene (tools/scenes/autofill.steps;
//! docs/autofill-plan.md §5): a sign-in form, a sign-up form, a code field
//! and a phone field, each saying what it holds; a button that turns the
//! sign-in name into an email address and back; and a stamped code field.

use kaya::ContentType;

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Account {
    name: String,
}

#[derive(Clone)]
enum Msg {
    Switch,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (user, mode) = ctx.apply(|tx| {
        let mode = tx.signal("sign in with a username");
        let accounts = tx.collection::<Account>();
        let mut user = None;
        let root = tx
            .column(|tx| {
                let name = tx
                    .entry()
                    .placeholder("Username")
                    .content_type(ContentType::Username)
                    .a11y_id("user")
                    .id();
                user = Some(name);
                tx.secure_field()
                    .placeholder("Password")
                    .content_type(ContentType::Password)
                    .a11y_id("password");
                tx.label(mode).a11y_id("mode");
                let switch = tx.button("Use email").a11y_id("switch").id();
                msgs.on_click(switch, Msg::Switch);
                tx.entry().placeholder("Email").content_type(ContentType::Email).a11y_id("email");
                tx.secure_field()
                    .placeholder("New password")
                    .content_type(ContentType::NewPassword)
                    .a11y_id("new");
                tx.entry()
                    .placeholder("Code")
                    .content_type(ContentType::OneTimeCode)
                    .a11y_id("code");
                tx.entry().placeholder("Phone").content_type(ContentType::Phone).a11y_id("phone");
                tx.entry().placeholder("Note").a11y_id("note");
                for mut row in accounts.rows(tx) {
                    row.label(Account::name());
                    let pin = row.secure_field();
                    row.content_type(pin, ContentType::OneTimeCode);
                    row.a11y_id(pin, "pin");
                }
            })
            .id();
        tx.mount(root);
        tx.insert(&accounts, "a", Account { name: "a".into() });
        (user.expect("the column declared the username field"), mode)
    });

    let mut email = false;
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Switch => {
                email = !email;
                ctx.apply(|tx| {
                    if email {
                        tx.content_type(user, ContentType::Email);
                        tx.write(mode, "sign in with an email address");
                    } else {
                        tx.content_type(user, ContentType::Username);
                        tx.write(mode, "sign in with a username");
                    }
                })
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
