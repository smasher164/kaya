import sys
from dataclasses import dataclass

import kaya


@dataclass
class Line:
    qty: float


normal = kaya.TimecodeRate(25)
drop = kaya.TimecodeRate(30000, 1001, True)
app = kaya.App()
commits = 0
phase = 0


def on_committed(value):
    global commits
    commits += 1
    status.set(f"commits: {commits}")
    playhead.set(kaya.fmt.timecode(int(value), normal))


def on_row(line, value):
    row_status.set(f"row {line.key}: {value:g}")


def switch_format():
    global phase
    if phase == 0:
        switching.number_format(kaya.NumberFormat.timecode(drop))
        switch_value.set(1800.0)
    elif phase == 1:
        switch_value.set(-2.0)
        switching.number_format(kaya.NumberFormat.number())
    elif phase == 2:
        switch_value.set(1800.0)
        switching.number_format(kaya.NumberFormat.timecode(drop))
    else:
        switching.number_format(kaya.NumberFormat.number())
        switch_value.set(-2.0)
    phase = (phase + 1) % 4


with app.window(title="Timecode", width=440, height=500):
    status = kaya.signal("commits: 0")
    row_status = kaya.signal("row: none")
    playhead = kaya.signal(kaya.fmt.timecode(93087, normal))
    rows = kaya.collection(Line)
    switch_value = kaya.signal(-2.0)
    with kaya.column():
        kaya.label("25 fps")
        kaya.label(bind=playhead).a11y_id("playhead")
        kaya.number_field(93087.0, format=kaya.NumberFormat.timecode(normal),
                          on_commit=on_committed).a11y_id("position").a11y_label("Position")
        kaya.label(bind=status).a11y_id("commits")
        kaya.label("29.97 drop-frame")
        kaya.number_field(1799.0, format=kaya.NumberFormat.timecode(drop),
                          on_commit=on_committed).a11y_id("drop").a11y_label("Drop frame")
        kaya.entry().a11y_id("note")
        for line in rows:
            kaya.number_field(line.qty, format=kaya.NumberFormat.timecode(normal),
                              on_commit=on_row).a11y_id("rowtime")
        kaya.label(bind=row_status).a11y_id("row")
        switching = kaya.number_field(switch_value).a11y_id("switching")
        kaya.button("Switch format", on_click=switch_format).a11y_id("switchformat")
    rows.insert("a", Line(25.0))

sys.exit(app.run())
