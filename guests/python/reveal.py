"""The reveal toggle scene (tools/scenes/reveal.steps; docs/reveal-plan.md
§5): a password field with its own show/hide toggle, the app's own Show
and Hide buttons, and a stamped field each row reveals by its own field."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Account:
    name: str
    shown: bool


PASSWORD = "Rv4tNbHy2mQc"

app = kaya.App()


def status(text):
    n = len(text)
    if n == 0:
        return "empty"
    if text == PASSWORD:
        return f"{n} characters, match"
    return f"{n} characters, no match"


def shown(on):
    return "shown" if on else "hidden"


def on_typed(text):
    status_text.set(status(text))


def on_submitted(text):
    sent_text.set(f"sent: {status(text)}")


def on_toggled(on):
    heard_text.set(f"heard: {shown(on)}")


def on_show():
    password.revealed(True)


def on_hide():
    password.revealed(False)


def on_clear():
    password.clear()


def on_pin(account, text):
    pin_text.set(f"pin {account.key}: {len(text)}")


def on_pin_toggled(account, on):
    pin_text.set(f"pin {account.key}: {shown(on)}")


with app.window():
    status_text = kaya.signal("empty")
    sent_text = kaya.signal("sent: -")
    heard_text = kaya.signal("heard: -")
    pin_text = kaya.signal("pin: -")
    accounts = kaya.collection(Account)
    with kaya.column():
        password = (kaya.secure_field(placeholder="Password",
                                      content_type=kaya.ContentType.PASSWORD,
                                      revealable=True,
                                      on_change=on_typed,
                                      on_submit=on_submitted,
                                      on_toggle=on_toggled)
                    .a11y_id("password").a11y_label("Password"))
        kaya.label(bind=status_text).a11y_id("status")
        kaya.label(bind=sent_text).a11y_id("sent")
        kaya.label(bind=heard_text).a11y_id("heard")
        kaya.button("Show", on_click=on_show).a11y_id("show")
        kaya.button("Hide", on_click=on_hide).a11y_id("hide")
        kaya.button("Clear", on_click=on_clear).a11y_id("clear")
        kaya.label(bind=pin_text).a11y_id("pin_status")
        for account in accounts:
            kaya.label(bind=account.name)
            kaya.secure_field(revealed=account.shown, revealable=True,
                              on_change=on_pin, on_toggle=on_pin_toggled).a11y_id("pin")
    accounts.insert("b", Account(name="b", shown=True))

sys.exit(app.run())
