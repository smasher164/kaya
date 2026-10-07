"""The secure field scene (tools/scenes/secure.steps;
docs/secure-entry-plan.md §5): a password field whose text the app
receives whole and answers only as a length and a match, a clear button,
and a stamped field per account whose edits name the row."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Account:
    name: str


PASSWORD = "Zq7vKeXw9pLm"

app = kaya.App()


def status(text):
    n = len(text)
    if n == 0:
        return "empty"
    if text == PASSWORD:
        return f"{n} characters, match"
    return f"{n} characters, no match"


def on_typed(text):
    status_text.set(status(text))


def on_submitted(text):
    sent_text.set(f"sent: {status(text)}")


def on_clear():
    password.clear()


def on_pin(account, text):
    pin_text.set(f"pin {account.key}: {len(text)}")


with app.window():
    status_text = kaya.signal("empty")
    sent_text = kaya.signal("sent: -")
    pin_text = kaya.signal("pin: -")
    accounts = kaya.collection(Account)
    with kaya.column():
        password = (kaya.secure_field(placeholder="Password",
                                      on_change=on_typed,
                                      on_submit=on_submitted)
                    .a11y_id("password").a11y_label("Password"))
        kaya.label(bind=status_text).a11y_id("status")
        kaya.label(bind=sent_text).a11y_id("sent")
        kaya.button("Clear", on_click=on_clear).a11y_id("clear")
        kaya.label(bind=pin_text).a11y_id("pin_status")
        for account in accounts:
            kaya.label(bind=account.name)
            kaya.secure_field(on_change=on_pin).a11y_id("pin")
    accounts.insert("a", Account(name="a"))
    accounts.insert("b", Account(name="b"))

sys.exit(app.run())
