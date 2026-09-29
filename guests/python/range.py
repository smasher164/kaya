"""The range scene (tools/scenes/range.steps; docs/range-plan.md §5)."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Clip:
    name: str
    trim_in: float
    trim_out: float


app = kaya.App()
commits = 0


def spelled(v):
    """The harness's own slider spelling (crates/kaya/src/harness.rs)."""
    return f"{v:.6f}".rstrip("0").rstrip(".")


def on_moved(low, high):
    live_text.set(f"live: {spelled(low)} {spelled(high)}")


def on_committed(low, high):
    global commits
    commits += 1
    commit_text.set(f"commits: {commits} at {spelled(low)} {spelled(high)}")


def on_volume(value):
    volume_text.set(f"volume: {spelled(value)}")


def on_clip_trim(clip, low, high):
    clip_text.set(f"clip {clip.key}: {spelled(low)} {spelled(high)}")


def on_reset():
    # Must NOT come back as a move or a commit.
    low_sig.set(1.0)


def on_late():
    # Crosses a high thumb the user moved; the core clamps it (docs/range-plan.md §3).
    low_sig.set(6.0)


with app.window():
    live_text = kaya.signal("live: 2 8")
    commit_text = kaya.signal("commits: 0")
    volume_text = kaya.signal("volume: 0.25")
    clip_text = kaya.signal("clip: none")
    low_sig = kaya.signal(2.0)
    high_sig = kaya.signal(8.0)
    clips = kaya.collection(Clip)
    with kaya.column():
        kaya.label(bind=live_text)                              # label#0
        kaya.label(bind=commit_text)                            # label#1
        kaya.label(bind=volume_text)                            # label#2
        kaya.label(bind=clip_text)                              # label#3
        kaya.range(                                             # range#0
            low_sig, high_sig, min=0.0, max=10.0, step=0.5,
            tick_spacing=1.0, min_gap=1.0, low_label="In", high_label="Out",
            on_change=on_moved, on_commit=on_committed,
        ).a11y_id("trim").a11y_label("Trim")
        kaya.range(4.0, 6.0, min=0.0, max=10.0, step=0.5,       # range#1
                   tick_spacing=1.0, min_gap=0.0).a11y_label("Tie")
        kaya.slider(5.0, min=0.0, max=10.0).a11y_label("Playhead")  # slider#0
        kaya.slider(                                            # slider#1
            0.25, min=0.0, max=1.0, step=0.25, axis=kaya.Axis.VERTICAL,
            on_change=on_volume,
        ).a11y_id("volume").a11y_label("Volume")
        kaya.button("reset", on_click=on_reset)                 # button#0
        kaya.button("late", on_click=on_late)                   # button#1
        for clip in clips:
            kaya.label(bind=clip.name)
            kaya.range(clip.trim_in, clip.trim_out, min=0.0, max=10.0,
                       step=0.5, min_gap=1.0,
                       on_commit=on_clip_trim).a11y_id("clip")
    clips.insert("a", Clip(name="a", trim_in=1.0, trim_out=4.0))
    clips.insert("b", Clip(name="b", trim_in=3.0, trim_out=7.0))

sys.exit(app.run())
