"""The restored shape (tools/scenes/restoredocs.steps,
docs/restoration-plan.md SR9): each document's title and text live in its
own session scope, and act two recreates the documents the last launch
left, takes each scope back, and selects the active one."""

import sys

import kaya

app = kaya.App()

primary = next((w for w in kaya.restored_windows() if w.id == 0), None)
if primary is None:
    documents = [10, 11, 12]
    for did, title in zip(documents, ("a", "b", "c")):
        kaya.document_session(did).set("title", title)
    active = None
else:
    documents = primary.documents
    active = primary.active_document


def typed(did: int):
    return lambda text: kaya.document_session(did).set("body", text)


def recall(did: int, caption):
    return lambda: caption.set(kaya.document_session(did).get("title", "untitled") + " body")


with app.window(title="restoredocs", width=640, height=420):
    pass

for did in documents:
    scope = kaya.document_session(did)
    title = scope.get("title", "untitled")
    with app.add_document(did, title=title, restore=did):
        caption = kaya.signal(f"{title} body")
        with kaya.column():
            kaya.label(bind=caption).a11y_id(f"caption-{title}")
            kaya.entry(scope.get("body", ""), on_change=typed(did)).a11y_id(f"body-{title}")
            kaya.button("recall", on_click=recall(did, caption)).a11y_id(f"recall-{title}")

with app.build():
    if active is not None:
        kaya.select_document(active)

sys.exit(app.run())
