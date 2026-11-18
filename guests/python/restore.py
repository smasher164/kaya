"""The restoration scene (tools/scenes/restore.steps,
docs/restoration-plan.md SR15): the draft lives in the session store and
comes back through the ordinary build; the list's scroll and the text's
caret come back on their own. See guests/rust/restore.rs."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Message:
    text: str


app = kaya.App()
session = kaya.app_session()

with app.window(title="restore"):
    messages = kaya.collection(Message)
    launch = kaya.signal(f"launch {kaya.restored()}")
    with kaya.column():
        kaya.label(bind=launch)
        kaya.entry(session.get("draft", ""), on_change=lambda text: session.set("draft", text))
        with kaya.row():
            kaya.button("jump", on_click=lambda: messages.container().scroll_to_row("m30")).a11y_id("jump")
            kaya.button("select", on_click=lambda: doc.select_range(range(4, 9))).a11y_id("select")
        doc = kaya.textarea("the quick brown fox").a11y_id("doc")
        with kaya.scroll(grow=1) as list_scroll:
            for message in messages.rows(a11y_id="messages"):
                kaya.label(bind=message.text)
        list_scroll.a11y_id("list")
    for i in range(1, 61):
        messages.insert(f"m{i}", Message(text=f"message {i}"))

sys.exit(app.run())
