"""The tooltips scene (tools/scenes/tooltips.steps; docs/tooltip-plan.md):
help text on four kinds including a container, one widget declaring both a
hint and help, a help bound to a signal, and stamped labels whose help is
the row's own field."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Account:
    name: str
    note: str


app = kaya.App()


def on_save():
    name_help.set("Your name, as saved")


with app.window():
    name_help = kaya.signal("Your full name as it appears on the card")
    accounts = kaya.collection(Account)
    with kaya.column() as settings:
        kaya.button("Save", on_click=on_save).help(          # button#0
            "Saves the draft to disk").a11y_id("save")
        kaya.button("Discard").help(                         # button#1
            "Throws the draft away").a11y_hint(
            "discard every change").a11y_id("discard")
        kaya.entry().help(name_help).a11y_id("fullname")     # entry#0
        kaya.slider(min=0.0, max=1.0, value=0.5).help(       # slider#0
            "How loud the preview plays").a11y_id("volume")
        for account in accounts:
            kaya.label(bind=account.name).help(
                account.note).a11y_id(account.name)
    settings.help("The settings for this account").a11y_id("settings")

    accounts.insert("a", Account(
        name="a", note="The first account, opened in March"))
    accounts.insert("b", Account(
        name="b", note="The second account, opened in May"))

sys.exit(app.run())
