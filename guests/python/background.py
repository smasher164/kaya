"""The background conformance scene, Python port — work off the app
thread, posted back (docs/background-work-plan.md).

THE SHAPE IS DELIBERATE: a wrong implementation must DEADLOCK rather
than disagree. The worker parks until a CLICK releases it, and only a
live app thread can process a click, so a binding that let background
work occupy the app thread cannot even deliver its own release.

The accumulators need no lock: everything that touches them runs on the
app thread, inside a posted transaction.
"""

import sys
import threading

import kaya

app = kaya.App()

released = threading.Event()
posted = []
nested = []


def start():
    def worker():
        # Parks until the scene clicks release; work on the app thread
        # would leave that click unprocessed and deadlock the scene.
        released.wait()
        # Three posts, in order: the accumulator makes this a test of
        # ORDER, not of which one ran last.
        for step in ("1", "2", "3"):
            def land(step=step):
                posted.append(step)
                status.set("".join(posted))

            app.post(land)

    threading.Thread(target=worker, name="background-worker", daemon=True).start()
    status.set("working")


def ping():
    # Proof the app thread still serves input while the worker is parked.
    alive.set("alive")


def release():
    released.set()


def nest():
    # A post from INSIDE a handler QUEUES for after; it never nests. The
    # handler appends a, posts a closure appending b, appends c — so it
    # commits "ac" and the posted closure then commits "acb". Nesting
    # can only ever produce "abc".
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
        # Authored so the closing AX read can address it by identifier;
        # an index read passes for an arm that ran and drew nothing.
        kaya.label(bind=detail).a11y_id("nested")  # label#2
        kaya.button("start", on_click=start)  # button#0
        kaya.button("ping", on_click=ping)  # button#1
        kaya.button("release", on_click=release)  # button#2
        kaya.button("nest", on_click=nest)  # button#3


sys.exit(app.run())
