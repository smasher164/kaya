"""The number field scene (tools/scenes/numberfield.steps;
docs/number-field-plan.md §5)."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Line:
    name: str
    qty: float


app = kaya.App()
commits = 0


def spelled(v):
    """The harness's own value spelling (crates/kaya/src/harness.rs)."""
    return f"{v:.6f}".rstrip("0").rstrip(".")


def on_committed(_value):
    global commits
    commits += 1
    commit_text.set(f"commits: {commits}")


def on_row_qty(line, value):
    row_text.set(f"row {line.key}: {spelled(value)}")


def on_forty():
    # Must NOT come back as a commit.
    amount_value.set(40.0)


with app.window():
    commit_text = kaya.signal("commits: 0")
    row_text = kaya.signal("row: none")
    amount_value = kaya.signal(0.0)
    lines = kaya.collection(Line)
    with kaya.column():
        kaya.label(bind=commit_text).a11y_id("commits")
        kaya.label(bind=row_text).a11y_id("row")
        kaya.number_field(
            value=amount_value, min=0.0, max=100.0, step=0.5,
            on_commit=on_committed,
        ).a11y_id("amount").a11y_label("Amount")
        kaya.entry().a11y_id("note")
        kaya.button("forty", on_click=on_forty).a11y_id("forty")
        for line in lines:
            kaya.label(bind=line.name)
            kaya.number_field(value=line.qty, min=0.0,
                              on_commit=on_row_qty).a11y_id("qty")
    lines.insert("a", Line(name="a", qty=1.0))
    lines.insert("b", Line(name="b", qty=2.0))

sys.exit(app.run())
