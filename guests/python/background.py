"""The background conformance scene, Python port — work off the app
thread, posted back (docs/background-work-plan.md).

WHAT IT PROVES, and the reason for its odd shape: a wrong
implementation must DEADLOCK rather than disagree. The worker parks
until a CLICK releases it, and only a live app thread can process a
click — so a binding that let background work occupy the app thread
cannot reach the end of the script at all. It could not even deliver
its own release.

The parking is a plain `threading.Event`, and the worker is a plain
daemon thread. kaya supplies no waiting primitive and should not: the
point is that a guest uses its own language's concurrency and hands
back only the result.

The accumulators are the guest's own state rather than signal
read-backs — signals are write-only by doctrine (the app owns its
model). No lock is needed on them: everything that touches them runs on
the app thread, inside a posted transaction.
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
        # Parks here until the scene clicks release. Were the binding
        # running this on the app thread, that click could never be
        # processed and the whole scene would deadlock — the point.
        released.wait()
        # Three posts, in order. The accumulator makes this a test of
        # ORDER and not merely of which one ran last.
        for step in ("1", "2", "3"):
            def land(step=step):
                posted.append(step)
                status.set("".join(posted))

            app.post(land)

    threading.Thread(target=worker, name="background-worker", daemon=True).start()
    status.set("working")


def ping():
    # Proof the app thread is still serving input while the worker is
    # parked and has posted nothing.
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
        # Authored so the CLOSING read can address it: the AX read needs
        # an identifier, and an index read passes for an arm that ran
        # and drew nothing.
        kaya.label(bind=detail).a11y_id("nested")  # label#2
        kaya.button("start", on_click=start)  # button#0
        kaya.button("ping", on_click=ping)  # button#1
        kaya.button("release", on_click=release)  # button#2
        kaya.button("nest", on_click=nest)  # button#3


sys.exit(app.run())
