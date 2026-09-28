"""The fullscreen scene (tools/scenes/fullscreen.steps,
docs/fullscreen-plan.md §5). The app keeps its own copy of the state: a
toggle writes `not on`, and the user's door moves the copy through
on_fullscreen_changed."""

import sys

import kaya

app = kaya.App()
on = False
pinged = 0


def toggle():
    global on
    on = not on
    app.window(fullscreen=on)
    asked.set("asked for fullscreen" if on else "asked for a window")


def ping():
    global pinged
    pinged += 1
    pings.set(f"pings {pinged}")


def changed(now):
    global on
    on = now
    user.set("the user turned fullscreen on" if now
             else "the user turned fullscreen off")


with app.window(title="fullscreen", on_fullscreen_changed=changed):
    asked = kaya.signal("windowed")
    user = kaya.signal("no change from the user")
    pings = kaya.signal("pings 0")
    with kaya.column():
        kaya.label(bind=asked)  # label#0
        kaya.label(bind=user)  # label#1
        kaya.label(bind=pings)  # label#2
        kaya.button("toggle fullscreen", on_click=toggle)  # button#0
        kaya.button("ping", on_click=ping)  # button#1

sys.exit(app.run())
