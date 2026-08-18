"""The stall conformance scene, Python port — an app thread that stops
taking its occurrences is REPORTED (DESIGN.md, Threading model and
protocol).

THIS IS THE ONE GUEST THAT MISUSES KAYA ON PURPOSE, in every language:
`block` sleeps on the app thread and the scene asserts that kaya
NOTICES. The class is not hypothetical — see docs/deferred.md on the
Haskell release that used a blocking `putMVar`.

WHY THE SECOND CLICK MATTERS: the consumer cursor advances BEFORE a
record reaches the guest, so a handler blocking on an empty queue is
indistinguishable from an idle app. `ping` is what makes work PENDING
while the app thread is gone, and that is what the watchdog sees.

`wedge` never returns, which is the shape a real deadlock has — every
assertion above would also pass for a merely SLOW handler. The leg still
reports its verdict, because the harness runs on its own thread and asks
the MAIN thread to exit.

See guests/rust/stall.rs and tools/scenes/stall.steps.
"""

import sys
import time

import kaya

app = kaya.App()

# Comfortably past the watchdog's one-second threshold, and short enough
# that the leg is not paying for it.
BLOCK_SECONDS = 2.5

# A day, never a literal park (docs/traps.md, "The stall scene wedges
# for a DAY").
WEDGE_SECONDS = 86400


def block():
    # DELIBERATELY WRONG, and the only place in this repo that is. Real
    # work goes on its own thread with the result posted through
    # app.post.
    time.sleep(BLOCK_SECONDS)


def wedge():
    time.sleep(WEDGE_SECONDS)


def ping():
    status.set("pinged")


with app.window(title="stall"):
    status = kaya.signal("ready")
    with kaya.column():
        kaya.label(bind=status).a11y_id("status")  # label#0
        kaya.button("block", on_click=block)  # button#0
        kaya.button("ping", on_click=ping)  # button#1
        kaya.button("wedge", on_click=wedge)  # button#2

sys.exit(app.run())
