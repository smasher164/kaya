"""The content type scene (tools/scenes/autofill.steps;
docs/autofill-plan.md §5): a sign-in form, a sign-up form, a code field
and a phone field, each saying what it holds; a button that turns the
sign-in name into an email address and back; and a stamped code field."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Account:
    name: str


app = kaya.App()
email = False


def on_switch():
    global email
    email = not email
    if email:
        user.content_type(kaya.ContentType.EMAIL)
        mode.set("sign in with an email address")
    else:
        user.content_type(kaya.ContentType.USERNAME)
        mode.set("sign in with a username")


with app.window():
    mode = kaya.signal("sign in with a username")
    accounts = kaya.collection(Account)
    with kaya.column():
        user = (kaya.entry(placeholder="Username", content_type=kaya.ContentType.USERNAME)
                .a11y_id("user"))
        kaya.secure_field(placeholder="Password",
                          content_type=kaya.ContentType.PASSWORD).a11y_id("password")
        kaya.label(bind=mode).a11y_id("mode")
        kaya.button("Use email", on_click=on_switch).a11y_id("switch")
        kaya.entry(placeholder="Email", content_type=kaya.ContentType.EMAIL).a11y_id("email")
        kaya.secure_field(placeholder="New password",
                          content_type=kaya.ContentType.NEW_PASSWORD).a11y_id("new")
        kaya.entry(placeholder="Code", content_type=kaya.ContentType.ONE_TIME_CODE).a11y_id("code")
        kaya.entry(placeholder="Phone", content_type=kaya.ContentType.PHONE).a11y_id("phone")
        kaya.entry(placeholder="Note").a11y_id("note")
        for account in accounts:
            kaya.label(bind=account.name)
            kaya.secure_field(content_type=kaya.ContentType.ONE_TIME_CODE).a11y_id("pin")
    accounts.insert("a", Account(name="a"))

sys.exit(app.run())
