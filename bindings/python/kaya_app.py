"""kaya's idiomatic surface for Python: the structural core plus the
tier-1 sugar from the design's appendix ("the shape of an app").

On top of the three structural jobs (typed handles over the id spaces,
scoped templates, occurrence dispatch), this layer adds:

- ambient transactions: `with app.window():` and every handler body run
  inside a transaction implicitly — `status.set(...)`,
  `groups.insert(...)` queue into it, and it submits atomically on
  exit. Per the binding conventions, a handler *is* a transaction; the
  surface just stops making Python spell it;
- container auto-parenting: `with kaya.column():` parents everything
  declared inside it, deleting the add_child bookkeeping. Template
  bodies reset the parent stack — their top-level widgets are the
  blueprint's roots, appended to the For's container per stamp by the
  core;
- co-located handlers: `kaya.button("step", on_click=fn)` registers at
  the declaration site. A template button's handler receives the
  stamped copy's keys as arguments (`def on_remove(group, item):`) —
  the honest residue of templates running once rather than per element;
- element proxies: `with kaya.for_each(groups) as group:` yields the
  element, and `kaya.label(bind=group)` binds it (levels are computed,
  never written by hand);
- handles with methods: `signal.set`, `collection.insert/update/remove`
  and `collection.at(*path)` for instances of template-declared
  collections.

Dispatch still runs on the app thread after it pulls from the ring; the
core never calls into the guest. The wire vocabulary underneath
(kaya_wire) is generated from kaya::spec by kaya-bindgen.
"""

import threading

import kaya
import kaya_wire as wire

_app = None  # the process's App: one core per process, so one of these
_tx = None  # the ambient transaction's record list, when one is open
_parents = []  # the container stack; None marks a template body's floor
_for_stack = []  # depth indices of enclosing Fors, for element levels
_tpl_depth = 0  # 0 = live zone; >0 = declaring a blueprint
_pending_root = None  # the top-level container window() will mount


def _records():
    if _tx is None:
        raise RuntimeError(
            "kaya: no ambient transaction — declare inside `with app.window():` "
            "or mutate inside a handler (or `with app.build():`)"
        )
    return _tx


def _auto_parent(child_id):
    if _parents and _parents[-1] is not None:
        _records().append(wire.tx_add_child(_parents[-1], child_id))


class Signal:
    def __init__(self, id):
        self.id = id

    def set(self, value):
        _records().append(wire.tx_write_signal(self.id, value))


class Widget:
    """A live widget: exactly one thing on screen."""

    def __init__(self, id):
        self.id = id


class Node:
    """A template node: a blueprint entry, stamped per collection entry.
    Never on screen by itself; clicks on its copies arrive with the
    copy's key path."""

    def __init__(self, id):
        self.id = id


class Element:
    """The element of an enclosing For: what a stamped copy's bindings
    read. Yielded by `with kaya.for_each(c) as element:`."""

    def __init__(self, for_index):
        self._for_index = for_index

    def _level(self):
        return len(_for_stack) - 1 - self._for_index


class _BoundCollection:
    def __init__(self, id, path):
        self._id = id
        self._path = path

    def insert(self, key, value):
        _records().append(wire.tx_collection_insert(self._id, self._path, key, value))

    def update(self, key, value):
        _records().append(wire.tx_collection_update(self._id, self._path, key, value))

    def remove(self, key):
        _records().append(wire.tx_collection_remove(self._id, self._path, key))


class Collection(_BoundCollection):
    def __init__(self, id):
        super().__init__(id, [])

    def at(self, *path):
        """The instance of this (template-declared) collection inside
        the copy selected by `path` — one key per enclosing For."""
        return _BoundCollection(self._id, list(path))


class _Scope:
    """Common context-manager plumbing for containers and templates."""

    def __enter__(self):
        return self._enter()

    def __exit__(self, exc_type, exc, tb):
        if exc_type is None:
            self._exit()
        return False


class _Container(_Scope):
    def __init__(self, handle):
        self.handle = handle

    def _enter(self):
        _parents.append(self.handle.id)
        return self.handle

    def _exit(self):
        global _pending_root
        _parents.pop()
        at_live_top = _tpl_depth == 0 and (not _parents or _parents[-1] is None)
        if at_live_top and not _parents:
            _pending_root = self.handle


class _Template(_Scope):
    def __init__(self, opener, target_id, is_for):
        self._opener = opener
        self._target_id = target_id
        self._is_for = is_for

    def _enter(self):
        global _tpl_depth
        self.handle = _alloc_widget_or_node()
        # The container parents into the enclosing scope, but the record
        # must land after template_end — the opener starts the blueprint
        # scope, and an add_child inside it would cross zones.
        self._parent = _parents[-1] if _parents else None
        _records().append(self._opener(self.handle.id, self._target_id))
        _tpl_depth += 1
        _parents.append(None)  # template bodies root themselves
        if self._is_for:
            _for_stack.append(len(_for_stack))
            return Element(_for_stack[-1])
        return None

    def _exit(self):
        global _tpl_depth
        if self._is_for:
            _for_stack.pop()
        _parents.pop()
        _tpl_depth -= 1
        _records().append(wire.tx_template_end())
        if self._parent is not None:
            _records().append(wire.tx_add_child(self._parent, self.handle.id))


def _alloc_widget_or_node():
    if _tpl_depth > 0:
        return Node(_app._next("node"))
    return Widget(_app._next("widget"))


def _widget(kind):
    handle = _alloc_widget_or_node()
    _records().append(wire.tx_create_widget(handle.id, kind))
    _auto_parent(handle.id)
    return handle


def signal(initial):
    handle = Signal(_app._next("signal"))
    _records().append(wire.tx_create_signal(handle.id, initial))
    return handle


def collection():
    handle = Collection(_app._next("collection"))
    _records().append(wire.tx_create_collection(handle._id))
    return handle


def column():
    """A column container: `with kaya.column():` parents everything
    declared inside it."""
    return _Container(_widget(wire.KIND_COLUMN))


def button(text=None, on_click=None):
    handle = _widget(wire.KIND_BUTTON)
    if text is not None:
        _records().append(wire.tx_set_text(handle.id, text))
    if on_click is not None:
        _app._register(handle, on_click)
    return handle


def label(text=None, bind=None):
    """A label; `text` for a constant, `bind` for a Signal or an
    Element (the enclosing For's, levels computed)."""
    handle = _widget(wire.KIND_LABEL)
    if text is not None:
        _records().append(wire.tx_set_text(handle.id, text))
    if isinstance(bind, Signal):
        _records().append(wire.tx_bind_text(handle.id, bind.id))
    elif isinstance(bind, Element):
        _records().append(wire.tx_bind_text_element(handle.id, bind._level()))
    return handle


def for_each(coll):
    """A For over `coll`: the with-block declares the template, and the
    target yields the element — `with kaya.for_each(c) as element:`."""
    return _Template(wire.tx_create_for, coll._id, is_for=True)


def when(sig):
    """A When over a Bool signal: stamps its template on true, unstamps
    on false."""
    return _Template(wire.tx_create_when, sig.id, is_for=False)


class _TxScope:
    def __init__(self, app, mount_on_exit):
        self._app = app
        self._mount = mount_on_exit

    def __enter__(self):
        global _tx, _pending_root
        if _tx is not None:
            raise RuntimeError("kaya: transactions do not nest")
        _tx = []
        _pending_root = None
        return self

    def __exit__(self, exc_type, exc, tb):
        global _tx
        records, _tx = _tx, None
        if exc_type is not None:
            return False
        if self._mount:
            if _pending_root is None:
                raise RuntimeError("kaya: window() body declared no root container")
            records.append(wire.tx_mount(0, _pending_root.id))
        if records:
            kaya.submit(*records)
        return False


class App:
    def __init__(self):
        global _app
        self._counters = {"signal": 0, "widget": 0, "collection": 0, "node": 0}
        self._widget_handlers = {}
        self._node_handlers = {}
        _app = self

    def _next(self, space):
        self._counters[space] += 1
        return self._counters[space]

    def _register(self, handle, fn):
        if isinstance(handle, Node):
            self._node_handlers[handle.id] = fn
        else:
            self._widget_handlers[handle.id] = fn

    def window(self):
        """The scene scope: an ambient transaction whose single
        top-level container mounts into the default window on exit.
        Per-window targets arrive with the window vocabulary."""
        return _TxScope(self, mount_on_exit=True)

    def build(self):
        """An ambient transaction without the mount — for mutations
        outside handlers."""
        return _TxScope(self, mount_on_exit=False)

    def _dispatch_loop(self):
        while occurrence := kaya.next_occurrence():
            ident, keys = occurrence
            if keys:
                handler = self._node_handlers.get(ident)
            else:
                handler = self._widget_handlers.get(ident)
            if handler is None:
                continue
            with self.build():
                handler(*keys)

    def run(self):
        """Enter the core on the calling thread (must be the process
        main thread), dispatching occurrences on the app thread; returns
        the exit code."""
        app_thread = threading.Thread(target=self._dispatch_loop)
        app_thread.start()
        code = kaya.run()
        app_thread.join()
        return code
