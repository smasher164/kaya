"""The toast scene (tools/scenes/toast.steps; docs/toast-plan.md §5)."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Item:
    title: str


app = kaya.App()
answers = 0
undos = 0
held = None


def titles():
    names = [item.title for _key, item in items.items()]
    return ", ".join(names) if names else "empty"


def answered(text):
    def on_result(outcome):
        global answers
        answers += 1
        count.set(f"answers {answers}")
        word = "action" if outcome == kaya.ToastOutcome.ACTION else "closed"
        last.set(f"{text}: {word}")
    return on_result


def on_show():
    kaya.show_toast("Saved", on_result=answered("Saved"))


def on_first():
    kaya.show_toast("First", action="Open", on_result=answered("First"))


def on_second():
    kaya.show_toast("Second", action="Open", on_result=answered("Second"))


def on_delete():
    entries = items.items()
    if not entries:
        return
    key, item = entries[0]
    kaya.undoable(f"delete {item.title}")
    items.remove(key)
    rows.set(titles())
    text = f"Deleted {item.title}"
    kaya.show_toast(text, action="Undo", undo=True, on_result=answered(text))


def on_hold():
    global held
    held = kaya.show_toast("Working", duration=kaya.ToastDuration.LONG,
                           on_result=answered("Working"))


def on_dismiss():
    global held
    if held is not None:
        kaya.dismiss_toast(held)
        held = None


def on_undone(label, _delta):
    global undos
    undos += 1
    undone.set(f"undone {undos}: {label}")
    rows.set(titles())


with app.window(title="toast", on_undone=on_undone):
    with app.menu("Edit"):
        kaya.item("Undo", role=kaya.MenuRole.UNDO)
        kaya.item("Redo", role=kaya.MenuRole.REDO)

    last = kaya.signal("no answer yet")
    count = kaya.signal("answers 0")
    undone = kaya.signal("nothing undone")
    rows = kaya.signal("Milk, Eggs, Bread")
    items = kaya.collection(Item)

    with kaya.column():
        kaya.label(bind=last)                        # label#0
        kaya.label(bind=count)                       # label#1
        kaya.label(bind=undone)                      # label#2
        kaya.label(bind=rows)                        # label#3
        kaya.button("show", on_click=on_show)        # button#0
        kaya.button("first", on_click=on_first)      # button#1
        kaya.button("second", on_click=on_second)    # button#2
        kaya.button("delete", on_click=on_delete)    # button#3
        kaya.button("hold", on_click=on_hold)        # button#4
        kaya.button("dismiss", on_click=on_dismiss)  # button#5
        for item in items:
            with kaya.row():
                kaya.label(bind=item.title)

    for title in ("Milk", "Eggs", "Bread"):
        items.insert(title, Item(title=title))

sys.exit(app.run())
