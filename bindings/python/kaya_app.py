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
  collections;
- the collection is the model — the only copy. Every mutation is a
  patch: it edits the model and becomes the wire delta in one recorded
  operation, in order, inside the transaction, and an abandoned
  transaction rolls both back together — so reads (`for key, value in
  groups.items():`) are exactly the committed model, never stale, and
  no second bookkeeping copy exists anywhere. Bulk mutations read
  naturally as draft scopes (`with items.at("g1").change() as d:`
  `d[k] = v`, `del d[k]` — insert-or-update resolved from the model),
  Immer-style; single ops keep the method spelling. Signals have no
  read method, deliberately: they are a render pipe, not a state bus.
  Model reads in template position are a frozen-branch bug and raise
  at record time (values in handlers, signals in templates);
- derived signals: `steps.eq(1)`, `steps.fmt("step {}")` — maintained
  by the binding, recomputed at write time, batched into the same
  transaction; the core never knows. Derived signals are signals:
  bind them, hand them to `when`.

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
_for_collections = []  # the enclosing Fors' collections, for mirror parentage
_tpl_depth = 0  # 0 = live zone; >0 = declaring a blueprint
_pending_root = None  # the top-level container window() will mount
_recording = False  # inside window(): mirror reads would freeze branches
_journal = None  # per-transaction mirror undo, run if the tx is abandoned


def _records():
    if _tx is None:
        raise RuntimeError(
            "kaya: no ambient transaction — declare inside `with app.window():` "
            "or mutate inside a handler (or `with app.build():`)"
        )
    return _tx


def _journal_once(obj, restore):
    """Record how to undo obj's mirror state, once per transaction: a
    handler that raises abandons its records, and the mirrors must
    abandon the same writes — `.value()` means "what I wrote", never
    "what I almost wrote"."""
    if _journal is not None and obj not in _journal:
        _journal[obj] = restore


def _auto_parent(child_id):
    if _parents and _parents[-1] is not None:
        _records().append(wire.tx_add_child(_parents[-1], child_id))


def _guard_mirror_read(what):
    if _recording or _tpl_depth > 0:
        raise RuntimeError(
            f"kaya: {what} reads a mirror snapshot, which would freeze this "
            "branch at record time — bind the signal (or use kaya.when / "
            "kaya.for_each) in templates; read mirrors in handlers"
        )


class Signal:
    def __init__(self, id, initial=None):
        self.id = id
        self._mirror = initial
        self._dependents = []

    def set(self, value):
        old = self._mirror
        _journal_once(self, lambda: setattr(self, "_mirror", old))
        _records().append(wire.tx_write_signal(self.id, value))
        self._mirror = value
        for derived in self._dependents:
            derived._recompute()

    # No read method, deliberately: signals are a render pipe, not a
    # state bus. The value you wrote lives in your own variables or in
    # a collection mirror; computations belong in derived signals. (The
    # internal mirror below exists to feed derivations and to skip
    # no-op derived writes.)

    def _derive(self, compute):
        derived = _Derived(_app._next("signal"), self, compute)
        _records().append(wire.tx_create_signal(derived.id, derived._mirror))
        self._dependents.append(derived)
        return derived

    def eq(self, other):
        """A derived Bool signal: this value == other."""
        return self._derive(lambda v: v == other)

    def ne(self, other):
        return self._derive(lambda v: v != other)

    def lt(self, other):
        return self._derive(lambda v: v < other)

    def gt(self, other):
        return self._derive(lambda v: v > other)

    def fmt(self, template):
        """A derived Str signal: template.format(value)."""
        return self._derive(lambda v: template.format(v))


class _Derived(Signal):
    """Binding-maintained: recomputed when the source is written, the
    write batched into the same transaction. The core sees an ordinary
    signal."""

    def __init__(self, id, source, compute):
        super().__init__(id, compute(source._mirror))
        self._compute = compute
        self._source = source

    def set(self, value):
        raise RuntimeError("kaya: derived signals are written by their source")

    def _recompute(self):
        new = self._compute(self._source._mirror)
        if new != self._mirror:
            old = self._mirror
            _journal_once(self, lambda: setattr(self, "_mirror", old))
            _records().append(wire.tx_write_signal(self.id, new))
            self._mirror = new
            for derived in self._dependents:
                derived._recompute()


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
    """One instance of a collection: the table inside the copy selected
    by `path` (the empty path for a live-zone collection)."""

    def __init__(self, owner, path):
        self._owner = owner
        self._path = path

    def _mirror(self):
        owner = self._owner
        old = {path: dict(entries) for path, entries in owner._instances.items()}

        def restore():
            owner._instances.clear()
            owner._instances.update(old)

        _journal_once(owner, restore)
        return owner._instances.setdefault(tuple(self._path), {})

    def insert(self, key, value):
        _records().append(
            wire.tx_collection_insert(self._owner._id, self._path, key, value)
        )
        self._mirror()[key] = value

    def update(self, key, value):
        _records().append(
            wire.tx_collection_update(self._owner._id, self._path, key, value)
        )
        self._mirror()[key] = value

    def remove(self, key):
        _records().append(wire.tx_collection_remove(self._owner._id, self._path, key))
        self._mirror().pop(key, None)
        # The core tears down the copy, taking descendant collection
        # instances with it; the mirrors follow.
        prefix = tuple(self._path) + (key,)
        for child in self._owner._children:
            child._purge(prefix)

    def change(self):
        """A draft scope for bulk mutation: `with c.change() as d:` —
        `d[key] = value` inserts or updates (resolved from the model),
        `del d[key]` removes, reads see the draft's own writes. Each
        operation records its patch immediately, in order, into the
        ambient transaction; the scope is syntax, not a barrier."""
        return _Draft(self)

    def items(self):
        """The model: what this guest wrote, in insertion order.
        Transition code only; template position raises."""
        _guard_mirror_read("items()")
        return list(self._mirror().items())

    def keys(self):
        _guard_mirror_read("keys()")
        return list(self._mirror().keys())

    def __len__(self):
        _guard_mirror_read("len()")
        return len(self._mirror())

    def __contains__(self, key):
        _guard_mirror_read("membership")
        return key in self._mirror()


class _Draft:
    """Records natural mutations as patches; see change()."""

    def __init__(self, bound):
        self._bound = bound

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def __setitem__(self, key, value):
        if key in self._bound._mirror():
            self._bound.update(key, value)
        else:
            self._bound.insert(key, value)

    def __delitem__(self, key):
        self._bound.remove(key)

    def __getitem__(self, key):
        _guard_mirror_read("draft reads")
        return self._bound._mirror()[key]

    def __contains__(self, key):
        _guard_mirror_read("draft membership")
        return key in self._bound._mirror()


class Collection(_BoundCollection):
    def __init__(self, id):
        self._id = id
        self._instances = {}
        self._children = []  # collections declared inside our template
        super().__init__(self, [])

    def at(self, *path):
        """The instance of this (template-declared) collection inside
        the copy selected by `path` — one key per enclosing For."""
        return _BoundCollection(self, list(path))

    def _purge(self, prefix):
        old = {path: dict(entries) for path, entries in self._instances.items()}

        def restore():
            self._instances.clear()
            self._instances.update(old)

        _journal_once(self, restore)
        for path in [p for p in self._instances if p[: len(prefix)] == prefix]:
            del self._instances[path]
        for child in self._children:
            child._purge(prefix)


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
    def __init__(self, opener, target_id, is_for, coll=None):
        self._opener = opener
        self._target_id = target_id
        self._is_for = is_for
        self._coll = coll

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
            _for_collections.append(self._coll)
            return Element(_for_stack[-1])
        return None

    def _exit(self):
        global _tpl_depth
        if self._is_for:
            _for_stack.pop()
            _for_collections.pop()
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
    handle = Signal(_app._next("signal"), initial)
    _records().append(wire.tx_create_signal(handle.id, initial))
    return handle


def collection():
    handle = Collection(_app._next("collection"))
    _records().append(wire.tx_create_collection(handle._id))
    # Declared inside a For's template: entries removed from the parent
    # tear down our instances, so the mirror bookkeeping needs the edge.
    if _for_collections:
        _for_collections[-1]._children.append(handle)
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
    return _Template(wire.tx_create_for, coll._id, is_for=True, coll=coll)


def when(sig):
    """A When over a Bool signal: stamps its template on true, unstamps
    on false."""
    return _Template(wire.tx_create_when, sig.id, is_for=False)


class _TxScope:
    def __init__(self, app, mount_on_exit):
        self._app = app
        self._mount = mount_on_exit

    def __enter__(self):
        global _tx, _pending_root, _recording, _journal
        if _tx is not None:
            raise RuntimeError("kaya: transactions do not nest")
        _tx = []
        _journal = {}
        _pending_root = None
        _recording = self._mount
        return self

    def __exit__(self, exc_type, exc, tb):
        global _tx, _recording, _journal
        _recording = False
        records, _tx = _tx, None
        journal, _journal = _journal, None
        if exc_type is not None:
            # The records are abandoned; the mirrors abandon them too.
            for restore in journal.values():
                restore()
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
