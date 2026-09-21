"""The sheet scene (tools/scenes/sheet.steps; docs/sheet-plan.md §6): a
sheet opened from a button and closed through the platform's cancel
path, the same sheet with the dismiss veto armed, a child sheet chained
over it, and a programmatic dismiss that echoes nothing."""

import sys

import kaya

app = kaya.App()

TASK = 11
DETAILS = 12


def on_draft(text):
    draft.set(f"draft: {text}")


def dismissed():
    status.set("dismissed")


def dismiss_asked():
    # Nothing has gone; the app keeps the sheet up and says so.
    status.set("dismiss requested")


def details_dismissed():
    status.set("details dismissed")


def open_details():
    with app.sheet(DETAILS, title="details", parent=TASK,
                   on_dismissed=details_dismissed):
        caption = kaya.signal("more about it")
        with kaya.column():
            kaya.label(bind=caption)  # the newest label
    status.set("details open")


def done():
    # Programmatic: no sheet_dismissed follows, so "done" stays.
    kaya.dismiss_sheet(TASK)
    status.set("done")


def open_task(armed):
    with app.sheet(TASK, title="new task", detent="medium",
                   intercept_dismiss=armed, on_dismissed=dismissed,
                   on_dismiss_requested=dismiss_asked if armed else None):
        caption = kaya.signal("what needs doing?")
        with kaya.column():
            kaya.label(bind=caption)  # label#1
            kaya.entry(on_change=on_draft)  # entry#0
            kaya.label(bind=draft)  # label#2
            kaya.button("details", on_click=open_details)  # button#2
            kaya.button("done", on_click=done)  # button#3
    status.set("open")
    draft.set("draft: none")


with app.window(title="sheet"):
    status = kaya.signal("closed")
    draft = kaya.signal("draft: none")
    with kaya.column():
        kaya.label(bind=status)  # label#0
        kaya.button("new task", on_click=lambda: open_task(False))  # button#0
        kaya.button("new task, armed", on_click=lambda: open_task(True))  # button#1


sys.exit(app.run())
