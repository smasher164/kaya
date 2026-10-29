"""The document-tabs scene (tools/scenes/doctabs.steps; docs/doctabs-plan.md
§5): three documents, one of them armed against a close, a shared region
beside them, the "+", and a programmatic select that echoes nothing."""

import sys

import kaya

app = kaya.App()

A, B, C = 10, 11, 12
NOTES = 30
NAMES = {A: "a", B: "b", C: "c"}

untitled = 0
regions = 0


def notes(window: int, region: int) -> None:
    """THE ONE BUILDER every window's shared region comes from, the first
    window's and a torn-out one's alike (docs/doctabs-plan.md §1.2)."""
    with app.add_region(region, kaya.RegionEdge.LEADING, window=window):
        with kaya.column():
            kaya.label(bind=status).a11y_id("status")
            kaya.entry().a11y_id("note")
            kaya.button("to a", on_click=lambda: kaya.select_document(A)).a11y_id("first")


def mark():
    kaya.set_document_prop(B, kaya.DocumentProp.DIRTY, True)
    status.set("marked b")


def answered(choice):
    if choice == kaya.AlertChoice.CANCEL:
        status.set("kept b")
    else:
        kaya.close_document(B)
        status.set("discarded b")


def ask_close():
    kaya.show_alert(
        title="unsaved changes", message="b has unsaved changes",
        actions=["Discard"], cancel="Keep Editing", on_result=answered)


def new_document():
    global untitled
    untitled += 1
    name = f"untitled {untitled}"
    with app.add_document(100 + untitled, title=name):
        caption = kaya.signal(f"{name} body")
        with kaya.column():
            kaya.label(bind=caption)
    kaya.select_document(100 + untitled)
    status.set(f"new {name}")


def detached(window, documents):
    global regions
    regions += 1
    notes(window, 300 + regions)
    status.set("detached " + " ".join(NAMES.get(d, "untitled") for d in documents))


with app.window(title="doctabs", width=640, height=420, new_document=True,
                on_new_document=new_document,
                on_documents_close_requested=lambda docs: status.set(f"asked about {len(docs)}"),
                on_documents_detached=detached):
    status = kaya.signal("ready")

for did, name in NAMES.items():
    with app.add_document(
            did, title=name, tooltip=f"/documents/{name}", intercept_close=did == B,
            on_selected=lambda name=name: status.set(f"selected {name}"),
            on_closed=lambda name=name: status.set(f"closed {name}"),
            on_close_requested=ask_close if did == B else None,
            on_moved=lambda _window, index, name=name: status.set(f"moved {name} to {index}")):
        caption = kaya.signal(f"{name} body")
        with kaya.column():
            kaya.label(bind=caption).a11y_id(f"body-{name}")
            kaya.entry().a11y_id(f"field-{name}")
            if did == B:
                kaya.button("mark b", on_click=mark).a11y_id("mark")

with app.build():
    notes(0, NOTES)

sys.exit(app.run())
