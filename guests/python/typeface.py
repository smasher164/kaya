"""The typeface conformance scene (tools/scenes/typeface.steps): the FAMILY
swaps and the scene names NO SIZE anywhere."""

import sys

import kaya

app = kaya.App()


draft = ""


def on_change(text):
    global draft
    draft = text


def on_go():
    status.set(f"clicked {draft}")


with app.window(title="typeface", width=480.0, height=360.0):
    # BEFORE THE FIRST MOUNT: the scope mounts on exit.
    with kaya.asset("fonts/sora-wght.ttf") as font:
        kaya.brand_typeface("Sora", font=font)
    heading = kaya.signal("typeface")
    status = kaya.signal("ready")
    with kaya.column():
        # A heading OVERRIDES the root font: a root-only lowering shows here.
        kaya.label(bind=heading).role(kaya.Role.HEADING).a11y_id("title")  # label#0
        kaya.label(bind=status)  # label#1
        # Two DIFFERENT routes: one alone cannot see a half-applied swap.
        kaya.entry(on_change=on_change)  # entry#0
        kaya.textarea()  # textarea#0
        kaya.button("Go", on_click=on_go)  # button#0

sys.exit(app.run())
