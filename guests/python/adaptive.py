"""The adaptive conformance scene, Python port — see
guests/rust/adaptive.rs for the full rationale. row@dash flips by a
HANDLER (D2's user-driven toggle); row@narrow carries the ONE-KEYWORD
breakpoint (D3): `stack_below=520` stacks it vertically while the
window is narrower than 520 logical points and reverts crossing back.
The harness (KAYA_SELFTEST=adaptive) reads the RENDERED axis both
sides of the threshold, byte-for-byte against every other language.
"""

import sys

import kaya

app = kaya.App()

state = {"vertical": False}
handles = {}


def flip():
    state["vertical"] = not state["vertical"]
    handles["dash"].axis("vertical" if state["vertical"] else "horizontal")


with app.window(title="adaptive", width=900, height=600):
    alpha = kaya.signal("alpha")
    longer = kaya.signal("a longer label")
    steady = kaya.signal("steady")

    with kaya.column():
        with kaya.row() as dash:  # row#0: the flip subject.
            kaya.label(bind=alpha)  # label#0
            kaya.label(bind=longer)  # label#1
        dash.a11y_id("dash")
        handles["dash"] = dash
        # column#1: the control group — its axis answers the creation
        # kind's own and never moves.
        with kaya.column() as steady_col:
            kaya.label(bind=steady)  # label#2
        steady_col.a11y_id("steady")
        kaya.button("flip", on_click=flip)  # button#0
        # row#1: the BREAKPOINT subject (D3) — the handler never
        # touches it.
        with kaya.row(stack_below=520) as narrow:
            one = kaya.signal("one")
            two = kaya.signal("a wider two")
            kaya.label(bind=one)  # label#3
            kaya.label(bind=two)  # label#4
        narrow.a11y_id("narrow")

sys.exit(app.run())
