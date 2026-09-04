"""The pickers scene (tools/scenes/pickers.steps; docs/datetime-plan.md)."""

import datetime
import sys
from dataclasses import dataclass

import kaya


@dataclass
class Task:
    name: str
    due: datetime.date


app = kaya.App()


def clock(when):
    return f"{when.hour:02d}:{when.minute:02d}"


def on_date(picked):
    date_text.set(f"date: {picked}")


def on_time(picked):
    time_text.set(f"time: {clock(picked)}")


def on_row_date(key, picked):
    row_text.set(f"row {key}: {picked}")


def on_reset():
    date_sig.set(datetime.date(2026, 3, 1))
    time_sig.set(datetime.time(9, 0))


with app.window():
    date_text = kaya.signal("date: none")
    time_text = kaya.signal("time: none")
    row_text = kaya.signal("row: none")
    date_sig = kaya.signal(datetime.date(2026, 9, 4))
    time_sig = kaya.signal(datetime.time(14, 30))
    tasks = kaya.collection(Task)
    with kaya.column():
        kaya.label(bind=date_text)                              # label#0
        kaya.label(bind=time_text)                              # label#1
        kaya.label(bind=row_text)                               # label#2
        kaya.date_picker(                                       # date_picker#0
            value=date_sig,
            min=datetime.date(2026, 1, 1),
            max=datetime.date(2026, 12, 31),
            on_change=on_date,
        ).a11y_id("when").a11y_label("Due")
        kaya.time_picker(                                       # time_picker#0
            value=time_sig, step=15, on_change=on_time,
        ).a11y_id("at").a11y_label("At")
        kaya.button("reset", on_click=on_reset)                 # button#0
        for task in tasks:
            kaya.label(bind=task.name)
            kaya.date_picker(value=task.due,
                             on_change=on_row_date).a11y_id("due")
    tasks.insert("a", Task(name="a", due=datetime.date(2026, 10, 1)))
    tasks.insert("b", Task(name="b", due=datetime.date(2026, 11, 20)))

sys.exit(app.run())
