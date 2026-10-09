"""The expander scene (tools/scenes/expander.steps;
docs/expander-plan.md §5)."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Section:
    name: str
    open: bool


app = kaya.App()
heard = 0
opens = {"s01": True}


def word(open):
    return "open" if open else "closed"


def on_details(open):
    global heard
    heard += 1
    state.set(f"details: {word(open)}")
    heard_text.set(f"heard: {heard}")


def on_typed(text):
    typed.set(f"name: {text}")


def on_show(open):
    details.expanded(open)
    state.set(f"details: {word(open)}")


def on_section(sec, open):
    opens[sec.key] = open
    sec.open = open
    rows_text.set(f"sec {sec.key}: {word(open)}")


def on_rebuild():
    sections.remove("s00")
    sections.insert("s00", Section(name="Section 0", open=opens.get("s00", False)))
    rows_text.set("rebuilt s00")


with app.window(title="expander", width=520, height=860):
    state = kaya.signal("details: closed")
    heard_text = kaya.signal("heard: 0")
    typed = kaya.signal("name: -")
    rows_text = kaya.signal("rows: -")
    inside = kaya.signal("Inside the body")
    sections = kaya.collection(Section)
    with kaya.column():
        with kaya.expander("Details", summary="One field", symbol=kaya.Symbol.INFO,
                           on_toggle=on_details) as details:
            details.a11y_id("details")
            kaya.entry(placeholder="Name", on_change=on_typed).a11y_id("name")
            kaya.label(bind=inside).a11y_id("inside")
        kaya.label(bind=state).a11y_id("state")
        kaya.label(bind=heard_text).a11y_id("heard")
        kaya.label(bind=typed).a11y_id("typed")
        with kaya.row():
            kaya.button("Show", on_click=lambda: on_show(True)).a11y_id("show")
            kaya.button("Hide", on_click=lambda: on_show(False)).a11y_id("hide")
        with kaya.column() as form:
            form.a11y_id("form")
            with kaya.labeled("Sort"):
                kaya.select(["Due", "Name"]).a11y_id("sort")
            with kaya.expander("Advanced") as advanced:
                advanced.a11y_id("advanced")
                with kaya.labeled("Hide badge"):
                    kaya.checkbox("").a11y_id("badge")
                with kaya.labeled("Keep completed"):
                    kaya.checkbox("").a11y_id("keep")
        kaya.label(bind=rows_text).a11y_id("rows")
        kaya.button("Rebuild", on_click=on_rebuild).a11y_id("rebuild")
        with kaya.column():
            for sec in sections:
                with kaya.expander(sec.name, expanded=sec.open,
                                   on_toggle=on_section) as node:
                    node.a11y_id("sec")
                    kaya.label(bind=sec.name)
    for i in range(3):
        sections.insert(f"s{i:02}", Section(name=f"Section {i}", open=i == 1))

sys.exit(app.run())
