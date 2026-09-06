"""The adaptive conformance scene (tools/scenes/adaptive.steps): row@dash
flips by a HANDLER, row@narrow by the compact breakpoint."""

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
        # column#1: the control group, whose axis never moves.
        with kaya.column() as steady_col:
            kaya.label(bind=steady)  # label#2
        steady_col.a11y_id("steady")
        kaya.button("flip", on_click=flip)  # button#0
        # row#1: the BREAKPOINT subject; the handler never touches it.
        with kaya.row(stack_when=kaya.COMPACT) as narrow:
            one = kaya.signal("one")
            two = kaya.signal("a wider two")
            kaya.label(bind=one)  # label#3
            kaya.label(bind=two)  # label#4
        narrow.a11y_id("narrow")
        # grid@sheet: three columns regular, one compact (D6.2).
        with kaya.grid(3, columns_when=(kaya.COMPACT, 1)) as sheet:
            for text in ("c1", "c2", "c3", "c4", "c5", "c6"):
                kaya.label(bind=kaya.signal(text))  # label#5..#10
        sheet.a11y_id("sheet")

sys.exit(app.run())
