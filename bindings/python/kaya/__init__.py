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

import dataclasses
import operator
import sys
import threading
import traceback
import types

from . import runtime
from . import wire

# The wire-representable field types; a dataclass field of any other
# type (a handler, say) is guest-only: it lives in the model and never
# reaches the wire. bool before int — bool is an int in Python.
_WIRE_TYPES = [(bool, wire.VALUE_BOOL), (int, wire.VALUE_I64),
               (float, wire.VALUE_F64), (str, wire.VALUE_STR),
               (bytes, wire.VALUE_BLOB)]


def _wire_tag(py_type):
    for ty, tag in _WIRE_TYPES:
        if py_type is ty:
            return tag
    return None


def _encode_blob_field(value):
    """A blob field's wire value: register the bytes now, at encode
    time — handles are single-submit, so every mutation that carries a
    blob field re-registers (one copy into core memory per write; the
    model keeps the guest's own bytes)."""
    return wire.BlobHandle(runtime.register_blob(value))


def _text_value(what, text):
    """The UTF-8 wall: text properties are str, never bytes — image
    bytes have their own channel."""
    if not isinstance(text, str):
        raise TypeError(
            f"kaya: {what} takes str, not {type(text).__name__} — encoded "
            "image bytes belong on kaya.image(source=...)"
        )
    return text

_app = None  # the process's App: one core per process, so one of these
_tx = None  # the ambient transaction's record list, when one is open
_parents = []  # the container stack; None marks a template body's floor
_for_stack = []  # depth indices of enclosing Fors, for element levels
# for-statement tracers whose template scope is still open; a break
# leaves one behind, caught at transaction exit.
_open_traces = []
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
    # Keyed by id(): signals overload __eq__ into derived signals (the
    # tracing tier), so an object-keyed dict would truth-test one on a
    # hash collision.
    if _journal is not None and id(obj) not in _journal:
        _journal[id(obj)] = restore


def _guard_tracer_escape():
    """Element tracers are record-time blueprints; one captured into a
    handler is a stale reference to the template, not to any stamped
    copy's data."""
    if not (_recording or _tpl_depth > 0):
        raise RuntimeError(
            "kaya: element tracers exist at record time only — a handler "
            "receives the stamped copy's keys and reads the model "
            "(get()/items()), never the tracer"
        )


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

    def le(self, other):
        return self._derive(lambda v: v <= other)

    def ge(self, other):
        return self._derive(lambda v: v >= other)

    def fmt(self, template):
        """A derived Str signal: template.format(value)."""
        return self._derive(lambda v: template.format(v))

    # The tracing tier: comparison operators are the method vocabulary
    # in operator clothes — `count == 0` is `count.eq(0)`, a derived
    # Bool signal. The documented sharp edge (the SQLAlchemy/pandas
    # trade-off): == no longer answers identity, so signals keep
    # identity hashing and membership tests will truth-test a derived —
    # which raises, pointing here.
    __hash__ = object.__hash__

    def __eq__(self, other):
        return self.eq(other)

    def __ne__(self, other):
        return self.ne(other)

    def __lt__(self, other):
        return self.lt(other)

    def __gt__(self, other):
        return self.gt(other)

    def __le__(self, other):
        return self.le(other)

    def __ge__(self, other):
        return self.ge(other)

    def __bool__(self):
        # The lax.cond wall: Python cannot overload statement
        # branching, so an `if` on a signal cannot trace to a template.
        raise RuntimeError(
            "kaya: a signal has no truth value at record time — branch "
            "with `with kaya.when(sig):` (build the condition with "
            "sig.eq(...) / sig == ...); handlers fold occurrences into "
            "your own state, never widget reads"
        )


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


class _CollectionDerived(Signal):
    """Binding-maintained from a collection: recomputed after every
    mutation of the live-zone instance, the write batched into the same
    transaction. The core sees an ordinary signal."""

    def __init__(self, id, coll, compute):
        super().__init__(id, compute(dict(coll._mirror())))
        self._coll = coll
        self._compute = compute

    def set(self, value):
        raise RuntimeError("kaya: derived signals are written by their source")

    def _recompute(self):
        new = self._compute(dict(self._coll._mirror()))
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

    # One-shot commands: momentary verbs into widget-owned state,
    # riding the open transaction like any write — the insert and the
    # clear beside it commit together or not at all. Fire-and-forget:
    # no mirror state, nothing to journal; the widget answers through
    # its normal occurrence path (a clear arrives back as
    # text_changed("") and the app's draft fold empties itself).
    # Commands live on Widget only — a Node is a blueprint, and a
    # blueprint has nothing to clear (the type-level arm of the scene's
    # own template rejection).

    def clear(self):
        """Drop an entry's content now (the field stays authoritative)."""
        _records().append(wire.tx_widget_command(self.id, wire.COMMAND_CLEAR))

    def focus(self):
        """Give this widget the keyboard focus."""
        _records().append(wire.tx_widget_command(self.id, wire.COMMAND_FOCUS))

    def grow(self, weight):
        """Set this widget's flex weight within its row/column: 0 is
        natural size, positive weights divide the container's leftover
        main-axis space in proportion. The declarative spelling is the
        `grow=` argument at construction; this is the dynamic path —
        collapsing a pane is `grow(0)` and back."""
        _records().append(wire.tx_set_grow(self.id, float(weight)))

    def align(self, mode):
        """Set this container's cross-axis child placement (see
        kaya.Align; strings accepted). Containers only — the scene
        rejects it anywhere else; baseline is rows-only."""
        _records().append(wire.tx_set_align(self.id, _align_value(mode)))

    def spacing(self, gap):
        """Set this container's inter-child gap (main axis, DIP; the
        normalized default is 8). Containers only — the scene rejects
        it anywhere else. The declarative spelling is the `spacing=`
        argument at construction; this is the dynamic path."""
        _records().append(wire.tx_set_spacing(self.id, float(gap)))


class Node:
    """A template node: a blueprint entry, stamped per collection entry.
    Never on screen by itself; clicks on its copies arrive with the
    copy's key path."""

    def __init__(self, id):
        self.id = id


class Element:
    """The element of an enclosing For: what a stamped copy's bindings
    read. Yielded by `with kaya.for_each(c) as element:`. For a record
    collection, `element.title` projects one field — a FieldRef the
    widget constructors accept wherever a binding goes."""

    def __init__(self, for_index, coll):
        self._for_index = for_index
        self._coll = coll

    def _level(self):
        return len(_for_stack) - 1 - self._for_index

    def __getattr__(self, name):
        if name.startswith("_"):
            raise AttributeError(name)
        _guard_tracer_escape()
        fields = object.__getattribute__(self, "_coll")._fields
        if fields is None or name not in fields:
            raise AttributeError(name)
        return FieldRef(self, fields[name])


class _Cases:
    """The eliminator over a sum collection, yielded by its for_each:
    one `with cases.case(Cls) as el:` block per constructor of the
    union, in any order. The scene holds the arms to totality at
    declaration — a missing constructor is a startup error naming it,
    and an empty block is the explicit way to render one as nothing."""

    def __init__(self, for_index, coll):
        self._for_index = for_index
        self._coll = coll

    def case(self, cls):
        for variant, spec in enumerate(self._coll._variants):
            if spec.cls is cls:
                return _CaseScope(self._for_index, self._coll, variant)
        raise TypeError(
            f"kaya: {cls.__name__} is not a constructor of this collection's union"
        )


class _CaseScope:
    def __init__(self, for_index, coll, variant):
        self._for_index = for_index
        self._coll = coll
        self._variant = variant

    def __enter__(self):
        _records().append(wire.tx_variant_case(self._variant))
        return _CaseElement(self._for_index, self._coll, self._variant)

    def __exit__(self, exc_type, exc, tb):
        return False


class _CaseElement:
    """The element proxy refined to one constructor: field projections
    resolve against that variant's schema."""

    def __init__(self, for_index, coll, variant):
        self._for_index = for_index
        self._coll = coll
        self._variant = variant

    def _level(self):
        return len(_for_stack) - 1 - self._for_index

    def __getattr__(self, name):
        if name.startswith("_"):
            raise AttributeError(name)
        _guard_tracer_escape()
        coll = object.__getattribute__(self, "_coll")
        variant = object.__getattribute__(self, "_variant")
        fields = coll._variants[variant].fields
        if fields is None or name not in fields:
            raise AttributeError(name)
        return FieldRef(self, fields[name])


class FieldRef:
    """One field of an element: index plus level, ready to bind."""

    def __init__(self, element, index):
        self._element = element
        self._index = index

    def _level(self):
        return self._element._level()

    def __bool__(self):
        # The lax.cond wall, element edition: a field projection is a
        # blueprint reference, not a value.
        raise RuntimeError(
            "kaya: an element's field has no truth value — bind it "
            "(checkbox(checked=el.field)) or, for per-constructor "
            "branches, declare a sum and its case arms; handlers read "
            "the model (get()/items()), never the tracer"
        )


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

    def _encode(self, value):
        """The entry's constructor index and wire fields, in that
        variant's schema order. The model keeps the value itself (a
        dataclass instance, the scalar otherwise); only wire fields
        travel."""
        variant, spec = self._owner._variant_for(value)
        if spec.getters is None:
            return variant, [value]
        return variant, [e(g(value)) for g, e in zip(spec.getters, spec.encoders)]

    def derive(self, compute):
        """A signal the binding recomputes from this collection's
        entries after every mutation, batched into the same transaction
        — `todos.derive(lambda items: ...)`; chain .eq/.fmt for further
        derivation. The callable is pure presentation: the entries dict
        in, one value out."""
        if self._path:
            raise RuntimeError(
                "kaya: derive on the collection itself, not an instance — drop the at()"
            )
        derived = _CollectionDerived(_app._next("signal"), self, compute)
        _records().append(wire.tx_create_signal(derived.id, derived._mirror))
        self._owner._derived.append(derived)
        _journal_once(
            ("derive", derived), lambda: self._owner._derived.remove(derived)
        )
        return derived

    def _recompute_derived(self):
        # Deriveds hang off root handles, so nested-instance mutations
        # cannot change their input.
        if not self._path:
            for derived in self._owner._derived:
                derived._recompute()

    def insert(self, key, value):
        variant, fields = self._encode(value)
        _records().append(
            wire.tx_collection_insert(self._owner._id, self._path, key,
                                      variant, fields)
        )
        self._mirror()[key] = value
        self._recompute_derived()

    def update(self, key, value):
        variant, fields = self._encode(value)
        _records().append(
            wire.tx_collection_update(self._owner._id, self._path, key,
                                      variant, fields)
        )
        self._mirror()[key] = value
        self._recompute_derived()

    def patch(self, key, **fields):
        """Field-level deltas: `todos.patch(k, done=True)` sends one
        update_field per kwarg and mutates the model instance in place —
        toggling `done` never resends `title`. On a sum, the entry's
        current constructor is the witness: names resolve against it,
        the wire carries its discriminant, and a kwarg the constructor
        lacks raises here — so the isinstance (or match) that guards
        the patch is the refinement, checked, not trusted."""
        entry = self._mirror()[key]
        variant, spec = self._owner._variant_for(entry)
        if spec.fields is None:
            raise TypeError("kaya: patch() needs a record collection")
        for name, value in fields.items():
            if name not in spec.fields:
                raise KeyError(
                    f"kaya: {type(entry).__name__} has no wire field {name!r}"
                )
            index = spec.fields[name]
            _records().append(
                wire.tx_collection_update_field(
                    self._owner._id, self._path, key, index,
                    variant, spec.encoders[index](value)
                )
            )
            setattr(entry, name, value)
        self._recompute_derived()

    def move_before(self, key, anchor):
        """Reposition an entry before another's key: order is collection
        data, so the model reorders and the wire carries the same
        keys-only delta. Keys, never indices. A missing key or anchor
        raises here, at the call site — the same check the scene makes;
        moving an entry before itself is a no-op, and nothing travels."""
        self._move(key, [anchor])

    def move_to_end(self, key):
        """Reposition an entry at the end of its collection."""
        self._move(key, [])

    def move_to_front(self, key):
        """Reposition an entry at the front: sugar for move_before the
        current first key, lowering to the same wire op."""
        keys = list(self._mirror())
        if not keys:
            raise KeyError(f"kaya: move of missing key {key!r}")
        self._move(key, [keys[0]])

    def move_after(self, key, anchor):
        """Reposition an entry directly after another's: sugar for
        move_before the anchor's successor (move_to_end when the anchor
        is last), lowering to the same wire op."""
        keys = list(self._mirror())
        if key not in keys:
            raise KeyError(f"kaya: move of missing key {key!r}")
        if anchor not in keys:
            raise KeyError(f"kaya: move after missing key {anchor!r}")
        if key == anchor:
            return
        at = keys.index(anchor)
        succ = keys[at + 1] if at + 1 < len(keys) else None
        if succ == key:
            return  # already directly after the anchor
        self._move(key, [] if succ is None else [succ])

    def _move(self, key, before):
        mirror = self._mirror()
        # The same checks the scene makes, made where the guest can see
        # the stack: a missing key or anchor is a guest bug, never a
        # fallback.
        if key not in mirror:
            raise KeyError(f"kaya: move of missing key {key!r}")
        if before and before[0] not in mirror:
            raise KeyError(f"kaya: move before missing key {before[0]!r}")
        if before and before[0] == key:
            return  # moving before itself: order unchanged, nothing travels
        _records().append(
            wire.tx_collection_move(self._owner._id, self._path, key, before)
        )
        value = mirror.pop(key)
        if before:
            # Insertion-ordered dicts have no insert-at; rebuild the
            # tail from the anchor on.
            anchor = before[0]
            tail = list(mirror.items())
            cut = next(i for i, (k, _) in enumerate(tail) if k == anchor)
            for k, _ in tail[cut:]:
                del mirror[k]
            mirror[key] = value
            for k, v in tail[cut:]:
                mirror[k] = v
        else:
            mirror[key] = value
        self._recompute_derived()

    def remove(self, key):
        _records().append(wire.tx_collection_remove(self._owner._id, self._path, key))
        self._mirror().pop(key, None)
        self._recompute_derived()
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

    def get(self, key, default=None):
        """The entry's current value — the model's copy, for the match
        or isinstance that precedes a sum's patch. Transition code
        only; template position raises."""
        _guard_mirror_read("get()")
        return self._mirror().get(key, default)

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


class _Variant:
    """One constructor's wire shape: the dataclass, its wire-typed
    fields in declaration order, and precompiled accessors — the
    per-insert path is a loop over getters. cls None is the scalar."""

    def __init__(self, cls):
        self.cls = cls
        if cls is None:
            self.fields = None
            self.schema = [wire.VALUE_STR]
            self.getters = None
            self.encoders = None
            return
        self.fields = {}
        self.schema = []
        self.getters = []
        # Per-field wire encoders, parallel to the schema: identity for
        # scalars; blob fields register their bytes at encode time.
        self.encoders = []
        for f in dataclasses.fields(cls):
            tag = _wire_tag(f.type)
            if tag is None:
                continue
            self.fields[f.name] = len(self.schema)
            self.schema.append(tag)
            self.getters.append(operator.attrgetter(f.name))
            self.encoders.append(
                _encode_blob_field if tag == wire.VALUE_BLOB else (lambda v: v)
            )
        if not self.schema:
            raise TypeError(f"kaya: {cls.__name__} has no wire-typed fields")


class Collection(_BoundCollection):
    def __init__(self, id, record_type=None):
        self._id = id
        self._instances = {}
        self._children = []  # collections declared inside our template
        self._derived = []  # signals recomputed from this collection
        self._record_type = record_type
        # The type is the schema: a dataclass is the one-variant case,
        # and a union of dataclasses (Note | Todo) is the sum — one
        # variant per member, in the union's declaration order.
        if record_type is None:
            self._variants = [_Variant(None)]
        elif isinstance(record_type, types.UnionType):
            self._variants = [_Variant(cls) for cls in record_type.__args__]
        else:
            self._variants = [_Variant(record_type)]
        # The record paths (element proxies, patch-by-name) read the
        # one variant; a sum leaves them None so a bare `element.field`
        # or unmatched patch cannot bypass the case analysis.
        only = self._variants[0] if len(self._variants) == 1 else None
        self._fields = only.fields if only else None
        super().__init__(self, [])

    def __iter__(self):
        """The tracing tier: in template position, `for t in todos:`
        traces to a For — the loop body runs once, authoring the
        blueprint. (Transition code iterates the model: items().)"""
        if not (_recording or _tpl_depth > 0):
            raise TypeError(
                "kaya: `for t in coll:` is template tracing, record time "
                "only — handlers iterate the model with items()"
            )
        if len(self._variants) > 1:
            # The lax.switch wall: a for-loop body is one arm, but a
            # sum's template is a record of case arms.
            raise TypeError(
                "kaya: a sum collection's template is its case arms — "
                "use `with kaya.for_each(c) as cases:` and one "
                "`with cases.case(Cls) as el:` per constructor"
            )
        return _ForTrace(self)

    def _variant_for(self, value):
        """The constructor a model value holds — the discriminant every
        write witnesses."""
        for variant, spec in enumerate(self._variants):
            if spec.cls is None or isinstance(value, spec.cls):
                return variant, spec
        raise TypeError(
            f"kaya: {type(value).__name__} is not a constructor of this "
            "collection's union"
        )

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
            if len(self._coll._variants) > 1:
                return _Cases(_for_stack[-1], self._coll)
            return Element(_for_stack[-1], self._coll)
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


class _ForTrace:
    """The for-statement tracer (DESIGN's JAX-style tier): `for t in
    todos:` opens the For template, hands the loop body one element
    tracer, and closes the template when the loop asks for a second
    element. The body runs once — it authors the blueprint; stamping is
    the core's replay, never Python iteration."""

    def __init__(self, coll):
        self._template = _Template(
            wire.tx_create_for, coll._id, is_for=True, coll=coll)
        self._state = 0

    def __iter__(self):
        return self

    def __next__(self):
        if self._state == 0:
            self._state = 1
            element = self._template._enter()
            _open_traces.append(self)
            return element
        if self._state == 1:
            self._state = 2
            # Traces close innermost-first; anything else means the
            # loop bodies interleaved template scopes.
            if not _open_traces or _open_traces[-1] is not self:
                raise RuntimeError(
                    "kaya: nested for-loops over collections must close "
                    "innermost-first"
                )
            _open_traces.pop()
            self._template._exit()
        raise StopIteration


def _alloc_widget_or_node():
    if _tpl_depth > 0:
        return Node(_app._next("node"))
    return Widget(_app._next("widget"))


def _widget(kind):
    handle = _alloc_widget_or_node()
    _records().append(wire.tx_create_widget(handle.id, kind))
    _auto_parent(handle.id)
    return handle


def create_window(window_id):
    """Create an auxiliary window (capability-gated: a phone host
    rejects it at the root). Materializes hidden; mounting presents.
    The declarative spelling is `with app.aux_window(...)`."""
    _records().append(wire.tx_create_window(int(window_id)))


def destroy_window(window_id):
    """Close and forget an auxiliary window — also the veto grammar's
    confirmation after on_close_requested."""
    _records().append(wire.tx_destroy_window(int(window_id)))


def pop_entry(window=0):
    """Pop the window's top navigation entry and forget its tree —
    also the back-veto grammar's confirmation after
    on_back_requested. Popping an empty stack is a scene error."""
    _records().append(wire.tx_pop_entry(int(window)))


# The alert_choice cancel sentinel, spelled for handlers:
# `if choice == kaya.CANCEL`. Deliberately not an index.
CANCEL = wire.ALERT_CHOICE_CANCEL


def show_alert(title="", message="", actions=(), cancel=None,
               on_result=None, window=0):
    """Request a modal alert (the request/result grammar): up to two
    action labels (the platform floor) plus the REQUIRED cancel label
    — the slot every platform-native dismissal (Esc, back, outside
    tap) resolves to; no binding invents a default label. The result
    handler rides the REQUEST (the widget-handler precedent):
    on_result(choice) fires exactly once — choice is 0 or 1 for
    actions, kaya.CANCEL for every native dismissal — and the
    registration retires with it. Ids are binding-allocated; the call
    returns the id for the floor-minded. One alert may be live per
    process — show the next from the handler."""
    actions = list(actions)
    if len(actions) > 2:
        raise ValueError(
            "an alert carries at most 2 actions (the platform floor)")
    if not cancel:
        raise ValueError(
            "the cancel slot always exists and needs a name — pass cancel=")
    action0 = actions[0] if len(actions) >= 1 else ""
    action1 = actions[1] if len(actions) == 2 else ""
    app = _app
    alert_id = app._next("alert")
    if on_result is not None:
        app._alert_handlers[alert_id] = on_result
    _records().append(wire.tx_show_alert(
        int(window), alert_id, len(actions), title, message,
        action0, action1, cancel))
    return alert_id


def window_title(title):
    """Set the primary surface's title. Uniform semantics with
    per-platform materialization: the title bar on the desktops, the
    app switcher's label on iOS, the task label on Android."""
    _records().append(wire.tx_set_window_title(0, str(title)))


def window_size(width, height):
    """Request the primary surface's content size (DIP). ADVISORY on
    every platform: honored where the window manager permits (the
    desktops), recorded only where the system owns geometry (the
    phones) — a request, never a guarantee."""
    _records().append(wire.tx_set_window_width(0, float(width)))
    _records().append(wire.tx_set_window_height(0, float(height)))


def signal(initial):
    handle = Signal(_app._next("signal"), initial)
    _records().append(wire.tx_create_signal(handle.id, initial))
    return handle


def collection(record_type=None):
    """Declare a collection. With no argument, a scalar (str) table —
    the one-field case. With a dataclass, a record collection: the
    dataclass IS the schema (wire-typed fields, declaration order), and
    `element.field` / `patch(key, field=...)` project it."""
    handle = Collection(_app._next("collection"), record_type)
    _records().append(
        wire.tx_create_collection(handle._id,
                                  [v.schema for v in handle._variants])
    )
    # Declared inside a For's template: entries removed from the parent
    # tear down our instances, so the mirror bookkeeping needs the edge.
    if _for_collections:
        _for_collections[-1]._children.append(handle)
    return handle


class Align:
    """The align enum: a container's cross-axis child placement. The
    `align=` argument (and `Widget.align`) also accepts these names as
    plain strings — `align="center"` — the Pythonic spelling."""

    START = wire.ALIGN_START
    CENTER = wire.ALIGN_CENTER
    END = wire.ALIGN_END
    STRETCH = wire.ALIGN_STRETCH
    BASELINE = wire.ALIGN_BASELINE


_ALIGN_NAMES = {
    "start": wire.ALIGN_START,
    "center": wire.ALIGN_CENTER,
    "end": wire.ALIGN_END,
    "stretch": wire.ALIGN_STRETCH,
    "baseline": wire.ALIGN_BASELINE,
}


def _align_value(align):
    if isinstance(align, str):
        try:
            return _ALIGN_NAMES[align]
        except KeyError:
            raise ValueError(
                f"align must be one of {sorted(_ALIGN_NAMES)}, got {align!r}"
            ) from None
    return int(align)


def _set_align(handle, align):
    if align is None:
        return
    _records().append(wire.tx_set_align(handle.id, _align_value(align)))


def _set_spacing(handle, spacing):
    if spacing is None:
        return
    _records().append(wire.tx_set_spacing(handle.id, float(spacing)))


def _set_grow(handle, grow):
    # The one kind-agnostic prop: every constructor takes `grow=`, the
    # declarative spelling of Widget.grow (see that docstring for the
    # contract).
    if grow is not None:
        _records().append(wire.tx_set_grow(handle.id, float(grow)))


def scroll(grow=None):
    """A vertical scroll viewport: `with kaya.scroll():` parents its
    EXACTLY ONE child (usually a column; the scene rejects a second).
    Give it `grow` so the enclosing track CONSTRAINS it — an
    unconstrained viewport hugs its content and nothing overflows."""
    handle = _widget(wire.KIND_SCROLL)
    _set_grow(handle, grow)
    return _Container(handle)


def column(grow=None, spacing=None, align=None):
    """A column container: `with kaya.column():` parents everything
    declared inside it. `grow` is its flex weight within the enclosing
    container; `spacing` its inter-child gap (main axis, DIP; the
    normalized default is 8)."""
    handle = _widget(wire.KIND_COLUMN)
    _set_grow(handle, grow)
    _set_spacing(handle, spacing)
    _set_align(handle, align)
    return _Container(handle)


def button(text=None, on_click=None, grow=None):
    handle = _widget(wire.KIND_BUTTON)
    if text is not None:
        _records().append(wire.tx_set_text(handle.id, _text_value("button text", text)))
    if on_click is not None:
        _app._register(handle, wire.OCC_BUTTON_CLICKED, on_click)
    _set_grow(handle, grow)
    return handle


def row(grow=None, spacing=None, align=None):
    """A row container: column turned sideways; `with kaya.row():`
    parents everything declared inside it. `grow` is its flex weight
    within the enclosing container; `spacing` its inter-child gap
    (main axis, DIP; the normalized default is 8)."""
    handle = _widget(wire.KIND_ROW)
    _set_grow(handle, grow)
    _set_spacing(handle, spacing)
    _set_align(handle, align)
    return _Container(handle)


def checkbox(text=None, checked=None, on_toggle=None, grow=None):
    """A labeled on/off box. The box owns its checked bit the way an
    entry owns its text: `on_toggle` receives the new state (a bool;
    template copies get the stamped keys first), and the app folds it
    into its own model. `checked` sets the state; `text` the caption."""
    handle = _widget(wire.KIND_CHECKBOX)
    if text is not None:
        _records().append(wire.tx_set_text(handle.id, _text_value("checkbox text", text)))
    if checked is not None:
        if isinstance(checked, Signal):
            _records().append(wire.tx_bind_checked(handle.id, checked.id))
        elif isinstance(checked, FieldRef):
            _records().append(
                wire.tx_bind_checked_element(handle.id, checked._level(),
                                             checked._index)
            )
        else:
            _records().append(wire.tx_set_checked(handle.id, checked))
    if on_toggle is not None:
        _app._register(handle, wire.OCC_TOGGLED, on_toggle)
    _set_grow(handle, grow)
    return handle


def progress(value=None, indeterminate=None, grow=None):
    """A progress bar: display-only, like label and image. `value` is
    the determinate fraction (0..=1; a float, a Signal, or an element
    field); `indeterminate=True` switches to the platform's activity
    mode and the fraction is ignored while it is on."""
    handle = _widget(wire.KIND_PROGRESS)
    if value is not None:
        if isinstance(value, Signal):
            _records().append(wire.tx_bind_value(handle.id, value.id))
        elif isinstance(value, FieldRef):
            _records().append(wire.tx_bind_value_element(
                handle.id, value._level, value._field))
        else:
            _records().append(wire.tx_set_value(handle.id, float(value)))
    if indeterminate is not None:
        _records().append(
            wire.tx_set_indeterminate(handle.id, bool(indeterminate)))
    _set_grow(handle, grow)
    return handle


def select(options, selected=0, on_select=None, grow=None):
    """A dropdown select over fixed options. Each option becomes a
    label child (labels only, scene-checked; append-only — options are
    the select's data, not harness-addressable labels). `selected` is
    the initial 0-based index (an int or a Signal; domain-checked at
    the root against the option count). Uncontrolled, like the slider:
    the widget owns its selection and reports each USER pick to
    `on_select` (the new 0-based index as an int; programmatic writes
    never echo)."""
    handle = _widget(wire.KIND_SELECT)
    with _Container(handle):
        for option in options:
            label(text=option)
    if isinstance(selected, Signal):
        _records().append(wire.tx_bind_value(handle.id, selected.id))
    else:
        _records().append(wire.tx_set_value(handle.id, float(selected)))
    if on_select is not None:
        _app._register(
            handle, wire.OCC_VALUE_CHANGED,
            lambda *args: on_select(*args[:-1], int(args[-1])))
    _set_grow(handle, grow)
    return handle


def radio(options, selected=0, on_select=None, grow=None):
    """A radio group over fixed options — the choice contract
    (see `select`) in its inline presentation: same option children,
    same 0-based `selected` index, same `on_select` pick handler
    (USER picks only; programmatic writes never echo)."""
    handle = _widget(wire.KIND_RADIO)
    with _Container(handle):
        for option in options:
            label(text=option)
    if isinstance(selected, Signal):
        _records().append(wire.tx_bind_value(handle.id, selected.id))
    else:
        _records().append(wire.tx_set_value(handle.id, float(selected)))
    if on_select is not None:
        _app._register(
            handle, wire.OCC_VALUE_CHANGED,
            lambda *args: on_select(*args[:-1], int(args[-1])))
    _set_grow(handle, grow)
    return handle


def slider(value=None, min=None, max=None, on_change=None, grow=None):
    """A slider over a numeric range. Uncontrolled, like the entry: the
    widget owns its position and reports each change to `on_change`
    (the new value as a float; template copies get the stamped keys
    first). `value` sets the position (a float, a Signal, or an element
    field); `min`/`max` the range, 0..1 unless set."""
    handle = _widget(wire.KIND_SLIDER)
    if min is not None:
        _records().append(wire.tx_set_min(handle.id, min))
    if max is not None:
        _records().append(wire.tx_set_max(handle.id, max))
    if value is not None:
        if isinstance(value, Signal):
            _records().append(wire.tx_bind_value(handle.id, value.id))
        elif isinstance(value, FieldRef):
            _records().append(
                wire.tx_bind_value_element(handle.id, value._level(),
                                           value._index)
            )
        else:
            _records().append(wire.tx_set_value(handle.id, value))
    if on_change is not None:
        _app._register(handle, wire.OCC_VALUE_CHANGED, on_change)
    _set_grow(handle, grow)
    return handle


def entry(text=None, on_change=None, grow=None):
    """A single-line text field. Uncontrolled, by doctrine: the widget
    owns its text and reports each edit to `on_change` (the new content
    as a str; template copies get the stamped keys first) — the app
    folds those into its own state. There is no read-back."""
    handle = _widget(wire.KIND_ENTRY)
    if text is not None:
        _records().append(wire.tx_set_text(handle.id, _text_value("entry text", text)))
    if on_change is not None:
        _app._register(handle, wire.OCC_TEXT_CHANGED, on_change)
    _set_grow(handle, grow)
    return handle


def label(text=None, bind=None, grow=None):
    """A label; `text` for a constant, `bind` for a Signal or an
    Element (the enclosing For's, levels computed)."""
    handle = _widget(wire.KIND_LABEL)
    if text is not None:
        _records().append(wire.tx_set_text(handle.id, _text_value("label text", text)))
    if isinstance(bind, Signal):
        _records().append(wire.tx_bind_text(handle.id, bind.id))
    elif isinstance(bind, Element):
        _records().append(wire.tx_bind_text_element(handle.id, bind._level()))
    elif isinstance(bind, FieldRef):
        _records().append(
            wire.tx_bind_text_element(handle.id, bind._level(), bind._index)
        )
    _set_grow(handle, grow)
    return handle


def image(source=None, grow=None):
    """An image displaying encoded bytes (PNG, JPEG, ...): the toolkit
    decodes natively, and decode failure renders the placeholder, never
    a crash. `source` is the encoded bytes — one registration copy into
    core memory; the handle is consumed by the next submit, and the
    guest's bytes are free to drop the moment the call returns — or a
    Signal, or an element field (`row.pic`) inside a template."""
    handle = _widget(wire.KIND_IMAGE)
    if source is not None:
        if isinstance(source, Signal):
            _records().append(wire.tx_bind_source(handle.id, source.id))
        elif isinstance(source, FieldRef):
            _records().append(
                wire.tx_bind_source_element(handle.id, source._level(),
                                            source._index)
            )
        elif isinstance(source, (bytes, bytearray, memoryview)):
            _records().append(
                wire.tx_set_source(handle.id, runtime.register_blob(source))
            )
        else:
            raise TypeError(
                f"kaya: image source takes encoded bytes (or a Signal or "
                f"element field), not {type(source).__name__} — text "
                "belongs on kaya.label"
            )
    _set_grow(handle, grow)
    return handle


def for_each(coll):
    """A For over `coll`: the with-block declares the template, and the
    target yields the element — `with kaya.for_each(c) as element:`."""
    # A For binds the collection itself — its template stamps per entry
    # of every instance — so handing it an at(...) handle is a bug.
    if not isinstance(coll, Collection):
        raise TypeError(
            "kaya: for_each binds the collection itself, not an instance "
            "— drop the .at(...)"
        )
    return _Template(wire.tx_create_for, coll._id, is_for=True, coll=coll)


def when(sig):
    """A When over a Bool signal: stamps its template on true, unstamps
    on false."""
    return _Template(wire.tx_create_when, sig.id, is_for=False)


class _TxScope:
    def __init__(self, app, mount_on_exit, title=None, width=None, height=None,
                 window=0, create=False, veto_close=None, push=False,
                 intercept_back=None, on_popped=None, on_back=None):
        self._app = app
        self._mount = mount_on_exit
        self._title = title
        self._width = width
        self._height = height
        self._window = int(window)
        self._create = create
        self._veto_close = veto_close
        self._push = push
        self._intercept_back = intercept_back
        self._on_popped = on_popped
        self._on_back = on_back

    def __enter__(self):
        global _tx, _pending_root, _recording, _journal
        if self._push:
            # A navigation entry's scope: push onto the primary's
            # stack, entry props, and the body's root mounts INTO the
            # entry on exit (self._window carries the entry's surface
            # id — entries share the namespace with windows). Unlike
            # every other scope this one NESTS inside an open
            # transaction: pushes happen from click handlers, which
            # already run inside the ambient build — the records join
            # the same commit, and only the root-tracking is scoped.
            self._nested = _tx is not None
            if not self._nested:
                _tx = []
                _journal = {}
            self._outer = (_recording, _pending_root)
            _recording = True
            _pending_root = None
            _records().append(wire.tx_push_entry(0, self._window))
            if self._title is not None:
                _records().append(
                    wire.tx_set_entry_title(self._window, str(self._title)))
            if self._intercept_back is not None:
                _records().append(wire.tx_set_entry_intercept_back(
                    self._window, bool(self._intercept_back)))
            # The handlers ride the push (per-entry, the alert
            # on_result precedent): the popped registration retires
            # with the one pop; the back one fires per request while
            # armed.
            if self._on_popped is not None:
                self._app._entry_popped[self._window] = self._on_popped
            if self._on_back is not None:
                self._app._back_requested[self._window] = self._on_back
            return self
        if _tx is not None:
            raise RuntimeError("kaya: transactions do not nest")
        _tx = []
        _journal = {}
        _pending_root = None
        _recording = self._mount
        if self._create:
            _records().append(wire.tx_create_window(self._window))
        if self._title is not None:
            _records().append(
                wire.tx_set_window_title(self._window, str(self._title)))
        if self._veto_close is not None:
            _records().append(
                wire.tx_set_window_veto_close(self._window, bool(self._veto_close)))
        if self._width is not None or self._height is not None:
            if self._width is None or self._height is None:
                raise ValueError("kaya: window width and height travel together")
            _records().append(
                wire.tx_set_window_width(self._window, float(self._width)))
            _records().append(
                wire.tx_set_window_height(self._window, float(self._height)))
        return self

    def __exit__(self, exc_type, exc, tb):
        global _tx, _recording, _journal, _pending_root
        if self._push:
            # Mount the scope's root into the entry, restore the outer
            # scope's root-tracking, and — when the scope opened its
            # own transaction (top-level use) — submit it. Inside a
            # handler the ambient build owns the commit (and the
            # rollback: a later exception drops these records with the
            # rest of the transaction).
            root = _pending_root
            _recording, _pending_root = self._outer
            if exc_type is not None:
                if not self._nested:
                    _tx = None
                    _journal = None
                return False
            if root is None:
                raise RuntimeError(
                    "kaya: push_entry() body declared no root container")
            _tx.append(wire.tx_mount(self._window, root.id))
            if not self._nested:
                records, _tx = _tx, None
                _journal = None
                if records:
                    runtime.submit(*records)
            return False
        _recording = False
        records, _tx = _tx, None
        journal, _journal = _journal, None
        abandoned, _open_traces[:] = list(_open_traces), []
        if exc_type is not None:
            # The records are abandoned; the mirrors abandon them too.
            for restore in journal.values():
                restore()
            return False
        if abandoned:
            # A break (or early return) left a For template open: the
            # body must run to completion — it authors the blueprint,
            # it does not iterate entries.
            raise RuntimeError(
                "kaya: a `for t in coll:` template never closed — the "
                "loop body must run to completion (no break/return); "
                "conditional rendering is kaya.when"
            )
        if self._mount:
            if _pending_root is None:
                raise RuntimeError("kaya: window() body declared no root container")
            records.append(wire.tx_mount(self._window, _pending_root.id))
        if records:
            runtime.submit(*records)
        return False


class App:
    def __init__(self):
        global _app
        self._counters = {"signal": 0, "widget": 0, "collection": 0, "node": 0,
                          "alert": 0}
        # Dispatch tables: (occurrence kind, id) per space — widget ids
        # and template-node ids collide numerically, so two dicts.
        self._widget_handlers = {}
        self._alert_handlers = {}
        # Per-entry navigation handlers, keyed by entry surface id
        # (the request-bound alert precedent).
        self._entry_popped = {}
        self._back_requested = {}
        # Per-window lifecycle handlers, keyed by window id — same
        # rule: handlers scope to the thing that creates them.
        self._close_requested = {}
        self._window_closed = {}
        self._node_handlers = {}
        _app = self

    def _next(self, space):
        self._counters[space] += 1
        return self._counters[space]

    def _register(self, handle, kind, fn):
        if isinstance(handle, Node):
            self._node_handlers[(kind, handle.id)] = fn
        else:
            self._widget_handlers[(kind, handle.id)] = fn

    def aux_window(self, window_id, title=None, width=None, height=None,
                   veto_close=None, on_close_requested=None, on_closed=None):
        """An auxiliary surface's scene scope: create_window plus its
        props on entry, and the single top-level container mounts INTO
        IT on exit. Capability-gated — a phone host rejects at the
        root (DESIGN.md, Presentation contexts).

        The handlers ride the declaration (per-window — handlers scope
        to the thing that creates them): on_close_requested() fires
        per chrome close while veto_close is armed — nothing has
        closed; answer with kaya.destroy_window to agree.
        on_closed() fires when the non-veto auxiliary is chrome-closed
        (informational; destroy_window reconciles) and retires with
        it."""
        if on_close_requested is not None:
            self._close_requested[int(window_id)] = on_close_requested
        if on_closed is not None:
            self._window_closed[int(window_id)] = on_closed
        return _TxScope(
            self, mount_on_exit=True, window=window_id, create=True,
            title=title, width=width, height=height, veto_close=veto_close)

    def window(self, title=None, width=None, height=None):
        """The scene scope: an ambient transaction whose single
        top-level container mounts into the default window on exit.
        `title` names the primary surface (title bar / switcher label
        / task label); `width`/`height` request its content size in
        DIP — advisory on every platform. Per-window targets arrive
        with the aux-window vocabulary."""
        return _TxScope(
            self, mount_on_exit=True, title=title, width=width, height=height)

    def build(self):
        """An ambient transaction without the mount — for mutations
        outside handlers."""
        return _TxScope(self, mount_on_exit=False)

    def push_entry(self, entry_id, title=None, intercept_back=None,
                   on_popped=None, on_back=None):
        """A navigation entry's scene scope (DESIGN.md, Navigation):
        push_entry onto the primary surface's stack plus the entry's
        props on entry, and the single top-level container mounts
        INTO IT on exit. Entry ids are guest-allocated in the shared
        surface namespace (the create_window discipline). The covered
        root stays alive — retained until popped.

        The handlers ride the push (per-entry, the show_alert
        on_result precedent — no id inspection anywhere): on_popped()
        fires when the user's back affordance pops THIS entry
        natively (post-fact; a programmatic kaya.pop_entry does not
        fire it — its caller already knows) and retires with the one
        pop; on_back() fires per back request while intercept_back is
        armed — nothing has popped; answer with kaya.pop_entry to
        agree."""
        return _TxScope(
            self, mount_on_exit=True, window=entry_id, push=True,
            title=title, intercept_back=intercept_back,
            on_popped=on_popped, on_back=on_back)


    def _dispatch_loop(self):
        while occurrence := runtime.next_occurrence():
            kind, ident, keys, payload = occurrence
            if kind == wire.OCC_CLOSE_REQUESTED:
                handler = self._close_requested.get(ident)
                if handler is not None:
                    try:
                        handler()
                    except Exception:
                        traceback.print_exc()
                continue
            if kind == wire.OCC_WINDOW_CLOSED:
                # One-shot: the window is gone; both registrations
                # retire with it.
                self._close_requested.pop(ident, None)
                handler = self._window_closed.pop(ident, None)
                if handler is not None:
                    try:
                        handler()
                    except Exception:
                        traceback.print_exc()
                continue
            if kind == wire.OCC_ENTRY_POPPED:
                # One-shot: the entry is gone; both registrations
                # retire with it.
                self._back_requested.pop(ident, None)
                handler = self._entry_popped.pop(ident, None)
                if handler is not None:
                    try:
                        handler()
                    except Exception:
                        traceback.print_exc()
                continue
            if kind == wire.OCC_BACK_REQUESTED:
                handler = self._back_requested.get(ident)
                if handler is not None:
                    try:
                        handler()
                    except Exception:
                        traceback.print_exc()
                continue
            if kind == wire.OCC_ALERT_RESULT:
                # One-shot: the registration retires with the result.
                handler = self._alert_handlers.pop(ident, None)
                if handler is not None:
                    try:
                        # payload is the parsed u32 choice.
                        handler(payload)
                    except Exception:
                        traceback.print_exc()
                continue
            if keys:
                handler = self._node_handlers.get((kind, ident))
            else:
                handler = self._widget_handlers.get((kind, ident))
            if handler is None:
                continue
            args = list(keys)
            if payload is not None:
                args.append(payload)
            # One handler dispatch: an exception crosses the build
            # boundary (which rolled the mirrors back and dropped the
            # records), is logged, and the loop moves to the next
            # occurrence — the uniform dispatch discipline across every
            # binding. Non-Exception aborts (KeyboardInterrupt) still
            # propagate: the fatal floor.
            try:
                with self.build():
                    handler(*args)
            except Exception:
                traceback.print_exc()
                print(
                    "kaya: handler raised (transaction rolled back)",
                    file=sys.stderr,
                )

    def run(self):
        """Enter the core on the calling thread (must be the process
        main thread), dispatching occurrences on the app thread; returns
        the exit code."""
        app_thread = threading.Thread(target=self._dispatch_loop)
        app_thread.start()
        code = runtime.run()
        app_thread.join()
        return code
