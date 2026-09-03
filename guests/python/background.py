"""The background scene (tools/scenes/background.steps): the worker parks
for a CLICK, so a binding that used the app thread DEADLOCKS here."""

import sys
import threading

import kaya

app = kaya.App()

released = threading.Event()
posted = []
nested = []


def start():
    def worker():
        # Parks: work on the app thread would starve the release click.
        released.wait()
        for step in ("1", "2", "3"):
            def land(step=step):
                posted.append(step)
                status.set("".join(posted))

            app.post(land)

    threading.Thread(target=worker, name="background-worker", daemon=True).start()
    status.set("working")


def ping():
    alive.set("alive")


def release():
    released.set()


def nest():
    # A post from INSIDE a handler QUEUES for after; it never nests.
    nested.append("a")

    def land():
        nested.append("b")
        detail.set("".join(nested))

    app.post(land)
    nested.append("c")
    detail.set("".join(nested))


with app.window(title="background"):
    status = kaya.signal("idle")
    alive = kaya.signal("-")
    detail = kaya.signal("-")
    with kaya.column():
        kaya.label(bind=status).a11y_id("status")  # label#0
        kaya.label(bind=alive).a11y_id("alive")  # label#1
        # Addressed by id: an index read passes for an empty arm.
        kaya.label(bind=detail).a11y_id("nested")  # label#2
        kaya.button("start", on_click=start)  # button#0
        kaya.button("ping", on_click=ping)  # button#1
        kaya.button("release", on_click=release)  # button#2
        kaya.button("nest", on_click=nest)  # button#3


sys.exit(app.run())
