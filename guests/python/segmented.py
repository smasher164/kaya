"""The segmented control scene (tools/scenes/segmented.steps;
docs/segmented-plan.md §5)."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Habit:
    name: str
    cadence: float


PERIODS = ["Day", "Week", "Month"]
VIEWS = [("Info", kaya.Symbol.INFO), ("Edit", kaya.Symbol.EDIT)]
CADENCES = ["Daily", "Weekly"]

app = kaya.App()
heard = 0


def on_period(index):
    global heard
    heard += 1
    period.set(float(index))
    period_text.set(f"period: {PERIODS[index]}")
    heard_text.set(f"heard: {heard}")


def on_reset():
    period.set(0.0)
    period_text.set("period: Day")


def on_view(index):
    view_text.set(f"view: {VIEWS[index][0]}")


def on_cadence(habit, index):
    cadence_text.set(f"cadence {habit.key}: {CADENCES[index]}")


with app.window(title="segmented"):
    period = kaya.signal(0.0)
    period_text = kaya.signal("period: Day")
    heard_text = kaya.signal("heard: 0")
    view_text = kaya.signal("view: Edit")
    cadence_text = kaya.signal("cadence: -")
    habits = kaya.collection(Habit)
    with kaya.column():
        kaya.segmented(PERIODS, selected=period, on_select=on_period) \
            .a11y_id("period").a11y_label("Period")
        kaya.label(bind=period_text)
        kaya.label(bind=heard_text)
        kaya.button("Reset", on_click=on_reset).a11y_id("reset")
        kaya.segmented_symbols(VIEWS, selected=1, on_select=on_view) \
            .a11y_id("view").a11y_label("View")
        kaya.label(bind=view_text)
        kaya.label(bind=cadence_text)
        for habit in habits:
            kaya.label(bind=habit.name)
            kaya.segmented(CADENCES, selected=habit.cadence,
                           on_select=on_cadence).a11y_id("cadence")
    habits.insert("read", Habit(name="read", cadence=1.0))
    habits.insert("walk", Habit(name="walk", cadence=0.0))

sys.exit(app.run())
