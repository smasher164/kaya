"""THE ONE GUEST THAT MISUSES KAYA ON PURPOSE (tools/scenes/stall.steps):
`block` sleeps on the app thread and `ping` makes work PENDING."""

import sys
import time

import kaya

app = kaya.App()

# Past the watchdog's one-second threshold, and no longer.
BLOCK_SECONDS = 2.5

# A day, never a literal park (docs/traps.md, "The stall scene wedges for
# a DAY").
WEDGE_SECONDS = 86400


def block():
    # DELIBERATELY WRONG, and the only place in this repo that is.
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
