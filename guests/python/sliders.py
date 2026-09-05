"""The sliders scene (tools/scenes/sliders.steps; docs/slider-plan.md)."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Track:
    name: str
    level: float


app = kaya.App()
commits = 0


def spelled(v):
    """The harness's own slider spelling (crates/kaya/src/harness.rs)."""
    return f"{v:.6f}".rstrip("0").rstrip(".")


def on_level(value):
    level_text.set(f"value: {spelled(value)}")


def on_committed(_value):
    global commits
    commits += 1
    commit_text.set(f"commits: {commits}")


def on_volume(value):
    volume_text.set(f"volume: {spelled(value)}")


def on_row_level(key, value):
    row_text.set(f"row {key}: {spelled(value)}")


def on_reset():
    # Must NOT come back as a value or a commit occurrence.
    pos.set(25.0)


with app.window():
    level_text = kaya.signal("value: 50")
    commit_text = kaya.signal("commits: 0")
    volume_text = kaya.signal("volume: 0.5")
    row_text = kaya.signal("row: none")
    pos = kaya.signal(50.0)
    tracks = kaya.collection(Track)
    with kaya.column():
        kaya.label(bind=level_text)                             # label#0
        kaya.label(bind=commit_text)                            # label#1
        kaya.label(bind=volume_text)                            # label#2
        kaya.label(bind=row_text)                               # label#3
        kaya.slider(                                            # slider#0
            value=pos, min=0.0, max=100.0, step=5.0,
            tick_spacing=25.0, on_change=on_level,
            on_commit=on_committed,
        ).a11y_id("master").a11y_label("Level")
        kaya.slider(                                            # slider#1
            value=0.5, min=0.0, max=1.0, tick_spacing=0.25,
            on_change=on_volume,
        ).a11y_label("Volume")
        kaya.button("reset", on_click=on_reset)                 # button#0
        for track in tracks:
            kaya.label(bind=track.name)
            kaya.slider(value=track.level, min=0.0, max=100.0, step=10.0,
                        on_commit=on_row_level).a11y_id("level")
    tracks.insert("a", Track(name="a", level=70.0))
    tracks.insert("b", Track(name="b", level=20.0))

sys.exit(app.run())
