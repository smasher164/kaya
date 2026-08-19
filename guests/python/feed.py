"""The feed scene: sum-typed elements, end to end. The union IS the sum
— `kaya.collection(Note | Todo)` declares one variant per member, in the
union's order — and for_each yields the eliminator, one
`with cases.case(Cls) as el:` block per constructor, held to totality at
declaration. A patch witnesses the entry's current constructor, and a
kwarg the constructor lacks raises at the call site.

Build the library first (cargo build), then:
    KAYA_SELFTEST=feed python3 guests/python/feed.py
"""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Note:
    text: str


@dataclass
class Todo:
    title: str
    done: bool


app = kaya.App()


def done_count_text(items):
    n = sum(1 for p in items.values() if isinstance(p, Todo) and p.done)
    return f"{n} done"


def on_promote():
    # The MODEL is asked which entry is a Note — never the widgets — and
    # the update's new constructor restamps that key's copy in place.
    for key, post in feed.items():
        if isinstance(post, Note):
            feed.update(key, Todo(title=post.text, done=True))
            break


def on_toggle(key, checked):
    # The match arm as a guard: a stale occurrence lands in the else and
    # folds into nothing.
    if isinstance(feed.get(key), Todo):
        feed.patch(key, done=checked)


with app.window():
    feed = kaya.collection(Note | Todo)
    done_count = feed.derive(done_count_text)
    with kaya.row():
        kaya.button("promote", on_click=on_promote)
        kaya.label(bind=done_count)
        with kaya.for_each(feed) as cases:
            with cases.case(Note) as note:
                kaya.label(bind=note.text)
            with cases.case(Todo) as todo:
                with kaya.row():
                    kaya.checkbox(checked=todo.done, on_toggle=on_toggle)
                    kaya.label(bind=todo.title)
    feed.insert("a", Note(text="jot one"))
    feed.insert("b", Todo(title="buy milk", done=False))
    feed.insert("c", Note(text="jot two"))

sys.exit(app.run())
