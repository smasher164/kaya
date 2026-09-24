"""The submit scene (tools/scenes/submit.steps): Return in an entry, a
search field and a `submits` textarea publishes `submitted` with the
field's text (docs/submit-plan.md); a plain textarea's Return is its
newline. The app writes each submit into one label."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Thread:
    title: str


app = kaya.App()


def on_sent(text):
    sent.set(f"sent: {text}")


def on_replied(thread, text):
    sent.set(f"sent: {thread.key}: {text}")


with app.window():
    threads = kaya.collection(Thread)
    sent = kaya.signal("sent: -")

    with kaya.column():
        kaya.label(bind=sent).a11y_id("sent")
        kaya.entry(placeholder="Name", on_submit=on_sent).a11y_id("name")
        kaya.search(placeholder="Search", on_submit=on_sent).a11y_id("find")
        kaya.textarea(on_submit=on_sent).a11y_id("plain")
        kaya.textarea(submits=True, on_submit=on_sent).a11y_id("compose")
        for thread in threads:
            kaya.label(bind=thread.title)
            kaya.entry(on_submit=on_replied).a11y_id("reply")

    for key, title in [("r1", "First"), ("r2", "Second")]:
        threads.insert(key, Thread(title=title))

sys.exit(app.run())
