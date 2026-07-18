"""The feed scene: sum-typed elements, end to end. The union IS the
sum — `kaya.collection(Note | Todo)` declares one variant per member,
in the union's order — and the for_each yields the eliminator: one
`with cases.case(Cls) as el:` block per constructor (the scene holds
the arms to totality at declaration). Mutation is match-refined the
Python way: the isinstance that guards a patch is checked, not
trusted — the patch witnesses the entry's current constructor, and a
kwarg the constructor lacks raises at the call site, so a stale
occurrence folds into nothing.

The backend selftest (KAYA_SELFTEST=feed) reads the note labels,
toggles the todo, promotes the first note into a finished todo (same
key, restamped in place), and watches the done-count label move.

Build the library first (cargo build), then:
    KAYA_SELFTEST=feed python3 guests/python/feed.py
"""

import pathlib
import sys
from dataclasses import dataclass

_here = pathlib.Path(__file__).resolve().parent
for _base in [_here, *_here.parents]:
    if (_base / "bindings" / "python").is_dir():
        sys.path.insert(0, str(_base / "bindings" / "python"))
        break

import kaya_app as kaya


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
    # The first note, promoted to a finished todo: the model is asked
    # which entry is a Note — the handler never counts widgets — and
    # the update's new constructor restamps that key's copy in place.
    for key, post in feed.items():
        if isinstance(post, Note):
            feed.update(key, Todo(title=post.text, done=True))
            break


def on_toggle(key, checked):
    # The match arm as a guard: the patch below witnesses the entry's
    # current constructor, so this isinstance is checked, not trusted.
    # A stale occurrence lands in the else and folds into nothing.
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
