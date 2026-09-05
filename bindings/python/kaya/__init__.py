"""kaya's idiomatic surface for Python: the structural core plus the
tier-1 sugar (DESIGN.md, "the shape of an app").
"""

import dataclasses
import datetime
import io
import operator
import sys
import threading
import traceback
import types

from . import runtime
from . import wire

# The wire-representable field types; any other field type is guest-only.
# bool before int — bool IS an int in Python. A date and a time ride the
# I64 tag in packed decimal (docs/datetime-plan.md D2/D10).
_WIRE_TYPES = [(bool, wire.VALUE_BOOL), (int, wire.VALUE_I64),
               (float, wire.VALUE_F64), (str, wire.VALUE_STR),
               (bytes, wire.VALUE_BLOB), (datetime.date, wire.VALUE_I64),
               (datetime.time, wire.VALUE_I64)]


def _wire_tag(py_type):
    for ty, tag in _WIRE_TYPES:
        if py_type is ty:
            return tag
    return None


def _encode_blob_field(value):
    """A blob field's wire value; handles are single-submit, so every
    mutation carrying a blob field re-registers."""
    return wire.BlobHandle(runtime.register_blob(value))


def _date_parts(what, value):
    """A civil date's components. `datetime.datetime` is refused though it
    IS a `datetime.date`: a picker holds no instant, and dropping the time
    silently is the zone-conversion bug genre (docs/datetime-plan.md §0)."""
    if isinstance(value, datetime.datetime) or not isinstance(value, datetime.date):
        raise TypeError(
            f"kaya: {what} is a datetime.date (year, month, day), not "
            f"{type(value).__name__} — a picker carries civil components, "
            "never an instant"
        )
    return value.year, value.month, value.day


def _time_parts(what, value):
    """A civil time's hour and minute; seconds are not a picker value (D3)."""
    if not isinstance(value, datetime.time):
        raise TypeError(
            f"kaya: {what} is a datetime.time (hour, minute), not "
            f"{type(value).__name__}"
        )
    return value.hour, value.minute


def _encode_date_field(value):
    return wire.pack_date(*_date_parts("a Date field", value))


def _encode_time_field(value):
    return wire.pack_time(*_time_parts("a Time field", value))


def _decode_date_field(packed):
    return datetime.date(*wire.unpack_date(packed))


def _decode_time_field(packed):
    return datetime.time(*wire.unpack_time(packed))


def _identity(value):
    return value


# Per-FIELD-TYPE codecs: the tag alone cannot tell a Date field from an
# int one (both are I64 on the wire).
_FIELD_ENCODERS = {bytes: _encode_blob_field, datetime.date: _encode_date_field,
                   datetime.time: _encode_time_field}
_FIELD_DECODERS = {datetime.date: _decode_date_field,
                   datetime.time: _decode_time_field}


def _wire_scalar(value):
    """A signal's value on the wire: a date or a time packs, everything
    else travels as itself."""
    if isinstance(value, datetime.datetime):
        raise TypeError(
            "kaya: a signal carries a civil date or time, not a "
            "datetime.datetime — a picker holds no instant "
            "(docs/datetime-plan.md §0)"
        )
    if isinstance(value, datetime.date):
        return wire.pack_date(value.year, value.month, value.day)
    if isinstance(value, datetime.time):
        return wire.pack_time(value.hour, value.minute)
    return value


def _text_value(what, text):
    """The UTF-8 wall: text properties are str, never bytes — image
    bytes have their own channel."""
    if not isinstance(text, str):
        raise TypeError(
            f"kaya: {what} takes str, not {type(text).__name__} — encoded "
            "image bytes belong on kaya.image(source=...)"
        )
    return text


def _text_range(what, span):
    """One text range, normalized to the (start, stop) pair the wire
    carries — `range(start, stop)` or a plain pair.

    A `slice` is REFUSED rather than reinterpreted: a None endpoint means
    the text's own end, which this call cannot resolve. NEGATIVE OFFSETS
    ARE REFUSED BY NAME, because `str.find` answers -1 and kaya has no
    end-relative offset. Every other malformed range is the core's.
    """
    if isinstance(span, range):
        if span.step != 1:
            raise ValueError(
                f"kaya: {what} takes a contiguous range — {span!r} counts in "
                f"steps of {span.step}"
            )
        start, stop = span.start, span.stop
    elif isinstance(span, (tuple, list)) and len(span) == 2:
        start, stop = span
    else:
        raise TypeError(
            f"kaya: {what} takes a text range — range(start, stop), or a "
            f"(start, stop) pair of UTF-8 byte offsets — not {span!r}"
        )
    for name, offset in (("start", start), ("stop", stop)):
        if isinstance(offset, bool) or not isinstance(offset, int):
            raise TypeError(
                f"kaya: {what}: a range's {name} is a UTF-8 byte offset (int), "
                f"not {type(offset).__name__}"
            )
        if offset < 0:
            raise ValueError(
                f"kaya: {what}: a range's {name} is {offset} — offsets count "
                "from the start of the text and kaya has no end-relative "
                "spelling (str.find answers -1 for no match; test for it)"
            )
    return start, stop

_app = None  # the process's App: one core per process, so one of these
_tx = None  # the ambient transaction's record list, when one is open
# None until the dispatch loop starts, which is why module-scope
# declaration on the main thread still works.
_app_thread = None


def _require_app_thread():
    """The Python spelling of a rule the other bindings get from types.

    `_tx` is a module GLOBAL, not thread-local, so a transaction opened
    on a background thread would stamp its records into the app thread's
    open one — silently, and interleaved (tools/check-tx-liveness.py).
    """
    if _app_thread is not None and threading.get_ident() != _app_thread:
        raise RuntimeError(
            "kaya: a transaction belongs to the app thread — this is "
            f"thread {threading.get_ident()}, the app thread is "
            f"{_app_thread}. To mutate from a background thread use "
            "app.post(fn), which runs fn as a transaction over there."
        )
_parents = []  # the container stack; None marks a template body's floor
_menu_scopes = []  # open menu scopes: creators seat under the top
_for_stack = []  # depth indices of enclosing Fors, for element levels
# Tracers whose template scope is still open; a break leaves one behind,
# caught at transaction exit.
_open_traces = []
_for_collections = []  # the enclosing Fors' collections, for mirror parentage
_tpl_depth = 0  # 0 = live zone; >0 = declaring a blueprint
# Each canvas's declared viewbox, so a redraw in a LATER transaction does
# not have to repeat it (docs/canvas-plan.md §2.2).
_canvas_viewboxes = {}
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
    handler that raises abandons its records and the mirrors both."""
    # Keyed by id(): signals overload __eq__ into derived signals, so an
    # object-keyed dict would truth-test one on a hash collision.
    if _journal is not None and id(obj) not in _journal:
        _journal[id(obj)] = restore


def _journal_instances(coll):
    """_journal_once for the one restore whose SNAPSHOT costs O(model).

    THE SNAPSHOT IS TAKEN INSIDE THE `not in` TEST, never before it:
    built eagerly every mutation is O(entries) (docs/deferred.md, "the
    Python binding's insert is quadratic"; the scaling clause in
    bindings/python/kaya_app_checks.py fails if it comes back).
    """
    if _journal is None or id(coll) in _journal:
        return
    old = {path: dict(entries) for path, entries in coll._instances.items()}

    def restore():
        coll._instances.clear()
        coll._instances.update(old)

    _journal[id(coll)] = restore


def _guard_tracer_escape():
    """Element tracers are record-time blueprints; one captured into a
    handler names the template, not any stamped copy's data."""
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


def _no_truth_value(what):
    """A template body runs ONCE, so a branch taken on the row's data
    freezes one row's answer into every copy.

    ON THE ELEMENT AS WELL AS ITS FIELDS, because the constant arms
    COERCE: an object with no `__bool__` is true, so
    `progress(indeterminate=el)` wrote a spinning bar on every row with
    nothing raised.
    """
    raise RuntimeError(
        f"kaya: {what} has no truth value — bind it "
        "(checkbox(checked=el.field)) or, for per-constructor branches, "
        "declare a sum and its case arms; handlers read the model "
        "(get()/items()), never the tracer"
    )


class Signal:
    def __init__(self, id, initial=None):
        self.id = id
        self._mirror = initial
        self._dependents = []

    def set(self, value):
        old = self._mirror
        _journal_once(self, lambda: setattr(self, "_mirror", old))
        _records().append(wire.tx_write_signal(self.id, _wire_scalar(value)))
        self._mirror = value
        for derived in self._dependents:
            derived._recompute()

    # No read method, deliberately: signals are a render pipe, not a
    # state bus. The mirror feeds derivations and skips no-op writes.

    def _derive(self, compute):
        derived = _Derived(_app._next("signal"), self, compute)
        _app._signals[derived.id] = derived
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

    # `count == 0` is `count.eq(0)`, so == no longer answers identity —
    # which is why signals keep identity hashing.
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
        # Python cannot overload statement branching, so an `if` on a
        # signal cannot trace to a template.
        raise RuntimeError(
            "kaya: a signal has no truth value at record time — branch "
            "with `with kaya.when(sig):` (build the condition with "
            "sig.eq(...) / sig == ...); handlers fold occurrences into "
            "your own state, never widget reads"
        )


class _Derived(Signal):
    """Binding-maintained: recomputed when the source is written, the
    write batched into the same transaction."""

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
    mutation of the live-zone instance, batched into the same
    transaction."""

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


def _prop_source(what, handle, value, const, signal, element):
    """One prop write from whichever source the guest handed over: a
    constant, a Signal, or the enclosing For's element.

    THE SOURCE ARMS COME FIRST AND THE CONSTANT ARM LAST, because the
    constant arm COERCES: `str(row.title)` succeeds and writes the repr
    onto every stamped copy.
    """
    if isinstance(value, Signal):
        return signal(handle.id, value.id)
    if isinstance(value, FieldRef):
        return element(handle.id, value._level(), value._index)
    if isinstance(value, Element):
        # A scalar collection's element IS the value: level, field 0.
        return element(handle.id, value._level())
    if isinstance(value, _CaseElement):
        raise TypeError(
            f"kaya: {what} takes a str, a Signal or one of the row's "
            f"fields (row.title), not {type(value).__name__} — inside a "
            "case arm project the field: .a11y_label(note.text)"
        )
    return const(handle.id, str(value))


class _Handle:
    """What carries props: a live widget, or a template node.

    Python's transaction is ambient, so ONE set of constructors serves
    both zones and `_alloc_widget_or_node` decides which handle comes
    back. What differs by zone is which SOURCES are reachable, not the
    call: the enclosing For's element exists only inside a template.
    """

    def __init__(self, id):
        self.id = id

    def a11y_id(self, ident):
        """Set this widget's accessibility IDENTIFIER: a stable authored
        key automation addresses it by, and which is NEVER spoken.

        IN A TEMPLATE, TAKE IT FROM THE ROW (`row.slug`): the copies of
        one node share a node id, so a constant names N things at once.
        Returns the handle, so it chains."""
        _records().append(_prop_source(
            "a11y_id", self, ident, wire.tx_set_a11y_id,
            wire.tx_bind_a11y_id, wire.tx_bind_a11y_id_element))
        return self

    def a11y_hint(self, hint):
        """Set what ACTIVATING this widget does. Write a VERB PHRASE:
        VoiceOver speaks it as written, TalkBack prefixes "double tap
        to". Activation kinds only. Returns the handle."""
        _records().append(_prop_source(
            "a11y_hint", self, hint, wire.tx_set_a11y_hint,
            wire.tx_bind_a11y_hint, wire.tx_bind_a11y_hint_element))
        return self

    def a11y_label(self, label):
        """Set this widget's accessibility LABEL: what an assistive
        client speaks for it. Separate from `a11y_id` — an automation key
        is not a spoken name. Setting it OVERRIDES what the platform
        derives from the control's content. Returns the handle."""
        _records().append(_prop_source(
            "a11y_label", self, label, wire.tx_set_a11y_label,
            wire.tx_bind_a11y_label, wire.tx_bind_a11y_label_element))
        return self

    def accepts(self, *kinds):
        """Declare what this widget takes from a paste — the closed kinds
        by name plus any custom format ids.

        A widget that declares nothing gets the platform's own insertion
        and reports it through the ordinary change path. CONSTANT IN A
        TEMPLATE, unlike the a11y props: an accept list describes the
        PROTOTYPE, not the row. Returns the handle.
        """
        for kind in kinds:
            if isinstance(kind, (Signal, Element, _CaseElement, FieldRef)):
                # Without this the kind coerces to a repr and
                # `_accept_list` complains about a space in a format id —
                # a true sentence about the wrong problem.
                raise TypeError(
                    f"kaya: accepts takes constant kinds, not "
                    f"{type(kind).__name__} — an accept list describes "
                    "the control and not the row; rows that take "
                    "different things are different variants, one "
                    "cases.case(...) arm each"
                )
        _records().append(wire.tx_set_accepts(self.id, _accept_list(kinds)))
        return self

    def role(self, role):
        """Declare what this widget MEANS — never how it looks
        (docs/styling-plan.md D4). Plain names accepted too.

        THE VOCABULARY IS CLOSED (D5): an unknown name raises here rather
        than travelling as an integer nobody lowers. CONSTANT ONLY, like
        `accepts`. ON THE BASE, so a STAMPED copy can say what it means —
        moving it up to `Widget` leaves every stamped copy undeclarable
        with nothing raised (tools/checks/py-node-props.py). Returns the
        handle."""
        _records().append(wire.tx_set_role(self.id, _role_value(role)))
        return self

    def on_paste(self, fn):
        """Take pasted content here: fn(clip), or fn(*keys, clip) for a
        stamped copy — the copy's key path first, as on_change delivers.

        ONLY FIRES FOR A WIDGET THAT DECLARED WHAT IT `accepts`, in both
        zones, so one that registers this and declares nothing waits
        forever. Returns the handle."""
        _app._register(self, wire.OCC_PASTED, fn)
        return self

    def draggable(self, text=None, html=None, image=None, files=(),
                  custom=None, operations=None):
        """DECLARE what this widget hands over when dragged: a clip in
        the shapes `copy` takes, plus the operations it allows.

        App-updated state — re-declare when the payload changes, and
        declaring NOTHING withdraws it, which is how a same-app move
        removes its source (docs/dnd-plan.md D1, D2). On a TEMPLATE NODE
        every stamped copy is born with this payload and its own
        identity, each representation a constant or the ROW'S OWN FIELD
        (`text=row.title`, docs/dnd-plan.md §4); `draggable_at` gives one
        copy its own, constants only. Returns the handle."""
        return self._draggable((), text, html, image, files, custom,
                               operations)

    def draggable_at(self, *keys, text=None, html=None, image=None,
                     files=(), custom=None, operations=None):
        """ONE stamped copy's drag declaration (docs/dnd-plan.md §4): the
        copy's keys, outermost first, then the payload `draggable` takes.

        The per-row payload an app declares after the row's insert; it
        overrides the template's own for that copy and follows it through
        a re-stamp. Returns the handle."""
        _template_zone_only(self, "draggable_at")
        return self._draggable(keys, text, html, image, files, custom,
                               operations)

    def _draggable(self, keys, text, html, image, files, custom,
                   operations):
        reps = []
        bound = 0
        present = 0
        custom = dict(custom or {})
        files = list(files)

        def slot(what, value):
            """Append one representation, bound or constant, and say
            which it was — the slot IS its index in `reps`."""
            nonlocal bound
            ref = _drag_slot(self, keys, what, value)
            if ref is None:
                return False
            bound |= 1 << len(reps)
            reps.append(ref)
            return True

        for ident, data in custom.items():
            _accept_list([ident])  # an id with a space would not survive
            reps.append(str(ident))
            if not slot("custom bytes", data):
                reps.append(wire.BlobHandle(runtime.register_blob(data)))
        for picked in files:
            reps.append(getattr(picked, "handle", picked))
        if image is not None:
            present |= wire.CLIP_IMAGE
            if not slot("image", image):
                reps.append(wire.BlobHandle(runtime.register_blob(image)))
        if html is not None:
            present |= wire.CLIP_HTML
            if not slot("html", html):
                reps.append(str(html))
        if text is not None:
            present |= wire.CLIP_TEXT
            if not slot("text", text):
                reps.append(str(text))
        empty = present == 0 and not files and not custom
        mask = 0 if empty else _operations(
            (OP_COPY,) if operations is None else operations)
        keys = list(keys)
        _records().append(wire.tx_set_drag_source(
            self.id, present, len(files), len(custom), mask, len(keys),
            bound, [*keys, *reps]))
        return self

    def drop_target(self, *operations):
        """DECLARE that this widget receives drops, performing these
        operations; naming NONE withdraws the declaration.

        WHAT it takes is its `accepts` list, which must be declared
        first — a destination has one vocabulary, not two
        (docs/dnd-plan.md D1). On a TEMPLATE NODE every stamped copy
        receives drops with these operations, taking what the template's
        `accepts` names. Returns the handle."""
        _records().append(
            wire.tx_set_drop_target(self.id, _operations(operations), 0, []))
        return self

    def drop_target_at(self, *keys, operations=()):
        """ONE stamped copy's drop declaration, `draggable_at`'s twin;
        the copy's accept list is the template's `accepts`. Returns the
        handle."""
        _template_zone_only(self, "drop_target_at")
        keys = list(keys)
        _records().append(wire.tx_set_drop_target(
            self.id, _operations(operations), len(keys), keys))
        return self

    def on_drop(self, fn):
        """Take dropped content here: fn(dropped), with the `Dropped` of
        docs/dnd-plan.md D1, or fn(*keys, dropped) for a stamped copy —
        the copy's key path first, as on_paste delivers. ONLY FIRES FOR A
        WIDGET THAT DECLARED `drop_target` over an `accepts` list, or for
        a reorderable For's container (D8). Returns the handle."""
        _app._register(self, wire.OCC_DROPPED, fn)
        return self

    def on_drag_ended(self, fn):
        """A drag that began here has ended: fn(operation), OP_COPY,
        OP_MOVE or None for cancelled or refused — fn(*keys, operation)
        for a stamped copy, which is how a reorderable row's own end
        arrives. Returns the handle."""
        _app._register(self, wire.OCC_DRAG_ENDED, fn)
        return self

    def draw(self, *keys):
        """DECLARE the whole drawing on a canvas, replacing whatever was
        declared before: `with chart.draw() as d: ...`.

        On a template node the keys select ONE stamped copy; with none it
        declares the drawing every copy is born with
        (docs/canvas-plan.md §2.1, §3.1)."""
        return _DrawScope(self, keys)


class Widget(_Handle):
    """A live widget: exactly one thing on screen."""

    # The momentary verbs and the DYNAMIC prop setters are LIVE-ONLY: a
    # template is declared, never mutated, and its declarative spelling
    # is the constructor kwarg, which serves both zones.

    def clear(self):
        """Drop an entry's content now (the field stays authoritative)."""
        _records().append(wire.tx_widget_command(self.id, wire.COMMAND_CLEAR))

    def focus(self):
        """Give this widget the keyboard focus."""
        _records().append(wire.tx_widget_command(self.id, wire.COMMAND_FOCUS))

    # The text-range surface (docs/ranges-plan.md D1).

    def set_text(self, text):
        """Put text into a text widget programmatically — the "open a
        document into the editor" write.

        THE WIDGET IS UNCONTROLLED: this is ONE write, after which the
        user owns the text. A write that CHANGES the text also drops the
        app's declared ranges (`highlight_ranges`) and spends the field's
        native undo history. Returns the widget."""
        _records().append(wire.tx_set_text(self.id, _text_value("set_text", text)))
        return self

    def highlight_ranges(self, ranges):
        """DECLARE this textarea's decorated ranges, replacing whatever
        was declared before; an empty set is the clear.

        THE OFFSETS ARE UTF-8 BYTE OFFSETS, WHICH IS NOT WHAT `str.find`
        RETURNS — it counts scalars, so search the encoded bytes and the
        offsets are kaya's by construction. APP-OWNED AND NEVER TRACKED:
        the first edit of any kind drops the set."""
        flat = []
        for span in ranges:
            start, stop = _text_range("highlight_ranges", span)
            flat += [start, stop]
        _records().append(
            wire.tx_highlight_ranges(self.id, len(flat) // 2, flat)
        )

    def select_range(self, span):
        """Put this textarea's selection at one range (an empty range is
        a caret). Same offsets and validation as `highlight_ranges`.

        REFUSED WHILE THE USER IS COMPOSING through an input method, in
        every backend: honouring it commits the composition mid-word. The
        refusal is a no-op, not an error — composition state is on no
        kaya channel."""
        start, stop = _text_range("select_range", span)
        _records().append(wire.tx_select_range(self.id, start, stop))

    def reveal_range(self, span):
        """Scroll this textarea so a range is inside the viewport. A pure
        effect: no state moves, the selection is untouched, and undo does
        not put the scroll position back."""
        start, stop = _text_range("reveal_range", span)
        _records().append(wire.tx_reveal_range(self.id, start, stop))

    def grow(self, weight):
        """Set this widget's flex weight within its row/column: 0 is
        natural size, positive weights divide the leftover main-axis
        space."""
        _records().append(wire.tx_set_grow(self.id, float(weight)))

    def align(self, mode):
        """Set this container's cross-axis child placement (see
        kaya.Align; strings accepted). Containers only — the scene
        rejects it anywhere else; baseline is rows-only."""
        _records().append(wire.tx_set_align(self.id, _align_value(mode)))

    def axis(self, mode):
        """Set this container's arrangement direction (see kaya.Axis;
        strings accepted) — the user-driven orientation toggle
        (docs/adaptive-layout-plan.md D2). Row/column only. The widget
        stays what its constructor made it."""
        _records().append(wire.tx_set_axis(self.id, _axis_value(mode)))

    def spacing(self, gap):
        """Set this container's inter-child gap (main axis, DIP; the
        normalized default is 8). Containers only."""
        _records().append(wire.tx_set_spacing(self.id, float(gap)))

    def inset(self, pad):
        """Set this container's own padding: DIP between its bounds and
        its children, uniform on all four sides. Containers only, and a
        negative one is refused.

        THE DECLARATIVE `inset=` IS THE TEMPLATE ZONE'S SPELLING; this
        dynamic setter stays live-only, since a blueprint is declared
        once and never mutated (tools/checks/py-node-props.py)."""
        _records().append(wire.tx_set_inset(self.id, float(pad)))

    def context_menu(self):
        """The live-widget context anchor: the command vocabulary scoped
        to a NOUN. No shortcuts here — a shortcut needs a window catalog
        as its native dispatch home."""
        return _MenuScope(("widget", self.id), shortcut_ok=False)


class Node(_Handle):
    """A template node: a blueprint entry, stamped per collection entry.

    ITS OWN CLASS, NOT AN ALIAS: `App._register` reads the handle's type
    to decide which handler table a callback lands in."""

    def context_menu(self, catalog):
        """Attach a live-zone-built context catalog to this template
        node: every stamped copy shows the same catalog, and each
        activation carries that copy's key path. An item takes exactly
        ONE anchor, so a second attach raises here."""
        if catalog._attached:
            raise RuntimeError(
                "kaya: a context catalog takes exactly one anchor"
            )
        catalog._attached = True
        for root in catalog._roots:
            _records().append(wire.tx_context_attach_node(self.id, root))


class Element:
    """The element of an enclosing For: what a stamped copy's bindings
    read. For a record collection, `element.title` projects one field."""

    def __init__(self, for_index, coll):
        self._for_index = for_index
        self._coll = coll

    def _level(self):
        return len(_for_stack) - 1 - self._for_index

    def __bool__(self):
        _no_truth_value("an element")

    def __getattr__(self, name):
        if name.startswith("_"):
            raise AttributeError(name)
        _guard_tracer_escape()
        coll = object.__getattribute__(self, "_coll")
        fields = coll._fields
        if fields is None or name not in fields:
            raise AttributeError(name)
        index = fields[name]
        return FieldRef(self, index, coll._variants[0].types[index])


class _Cases:
    """The eliminator over a sum collection: one `with cases.case(Cls) as
    el:` block per constructor, in any order. The scene holds the arms to
    TOTALITY at declaration."""

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

    def __bool__(self):
        _no_truth_value("an element")

    def __getattr__(self, name):
        if name.startswith("_"):
            raise AttributeError(name)
        _guard_tracer_escape()
        coll = object.__getattribute__(self, "_coll")
        variant = object.__getattribute__(self, "_variant")
        spec = coll._variants[variant]
        fields = spec.fields
        if fields is None or name not in fields:
            raise AttributeError(name)
        index = fields[name]
        return FieldRef(self, index, spec.types[index])


class FieldRef:
    """One field of an element: index plus level, ready to bind. `_type` is
    the schema's python type, which is what tells a Date field from the
    int it shares a wire tag with."""

    def __init__(self, element, index, py_type=None):
        self._element = element
        self._index = index
        self._type = py_type

    def _level(self):
        return self._element._level()

    def __bool__(self):
        _no_truth_value("an element's field")


class _BoundCollection:
    """One instance of a collection: the table inside the copy selected
    by `path` (the empty path for a live-zone collection)."""

    def __init__(self, owner, path):
        self._owner = owner
        self._path = path

    def _mirror(self):
        owner = self._owner
        _journal_instances(owner)
        return owner._instances.setdefault(tuple(self._path), {})

    def _encode(self, value):
        """The entry's constructor index and wire fields, in that
        variant's schema order; only wire fields travel."""
        variant, spec = self._owner._variant_for(value)
        if spec.getters is None:
            return variant, [value]
        return variant, [e(g(value)) for g, e in zip(spec.getters, spec.encoders)]

    def derive(self, compute):
        """A signal the binding recomputes from this collection's entries
        after every mutation, batched into the same transaction."""
        if self._path:
            raise RuntimeError(
                "kaya: derive on the collection itself, not an instance — drop the at()"
            )
        derived = _CollectionDerived(_app._next("signal"), self, compute)
        _app._signals[derived.id] = derived
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

    def set_columns(self, *titles, sort=None):
        """Re-declare this collection instance's header bar after sorting."""
        handle = getattr(self._owner, "_for_handle", None)
        if handle is None:
            raise RuntimeError(
                "kaya: set_columns before columns() — the header bar "
                "is declared with the For, then re-declared here"
            )
        sort = sort or Sort.NONE
        _records().append(
            wire.tx_set_column_headers(
                handle, sort.sorted, sort.direction,
                len(titles), len(self._path), [*self._path, *titles],
            )
        )

    def _absorb_key(self, key):
        """An explicit key, shown to the minter on its way into the
        table: a numeric key at or above the counter carries it up.

        BOOLS ARE NOT NUMBERS HERE, because they are not numbers on the
        wire either — the isinstance order below is the encoder's.
        """
        if isinstance(key, bool) or not isinstance(key, int):
            return
        path = tuple(self._path)
        if key > self._owner._fresh.get(path, 0):
            self._owner._fresh[path] = key

    def insert(self, key, value):
        variant, fields = self._encode(value)
        # ABSORPTION, on the one path every explicit key travels, so
        # hand-chosen and minted keys share one space in either order.
        self._absorb_key(key)
        _records().append(
            wire.tx_collection_insert(self._owner._id, self._path, key,
                                      variant, fields)
        )
        self._mirror()[key] = value
        self._recompute_derived()

    def insert_fresh(self, value):
        """Insert a record under a key the binding authors, and hand the
        key back — `key = todos.insert_fresh(Todo(title=draft))`.

        ONE COUNTER PER COLLECTION INSTANCE, starting at 0; the minted
        key is an I64 and is counter+1. Mixing with explicit keys is safe
        by absorption. NO DECREMENT IS EXPRESSIBLE: the counter sits
        deliberately outside `_journal_once`, so a key spent by an
        abandoned transaction stays spent.
        """
        path = tuple(self._path)
        key = self._owner._fresh.get(path, 0) + 1
        self._owner._fresh[path] = key
        self.insert(key, value)
        return key

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
        update_field per kwarg and mutates the model instance in place.
        On a sum the entry's CURRENT CONSTRUCTOR is the witness — a kwarg
        it lacks raises here."""
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
        """Reposition an entry before another's key. Keys, never indices;
        a missing key or anchor raises at the call site, and moving an
        entry before itself is a no-op."""
        self._move(key, [anchor])

    def move_to_end(self, key):
        """Reposition an entry at the end of its collection."""
        self._move(key, [])

    def move_to_front(self, key):
        """Reposition an entry at the front."""
        keys = list(self._mirror())
        if not keys:
            raise KeyError(f"kaya: move of missing key {key!r}")
        self._move(key, [keys[0]])

    def move_after(self, key, anchor):
        """Reposition an entry directly after another's."""
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
        # the stack.
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
        """A draft scope for bulk mutation: `d[key] = value` inserts or
        updates, `del d[key]` removes, reads see the draft's own writes.
        THE SCOPE IS SYNTAX, NOT A BARRIER."""
        return _Draft(self)

    def get(self, key, default=None):
        """The entry's current value — the model's copy. Template
        position raises."""
        _guard_mirror_read("get()")
        return self._mirror().get(key, default)

    def items(self):
        """The model: what this guest wrote, in insertion order.
        Template position raises."""
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
    fields in declaration order, and precompiled accessors. cls None is
    the scalar."""

    def __init__(self, cls):
        self.cls = cls
        if cls is None:
            self.fields = None
            self.schema = [wire.VALUE_STR]
            self.types = None
            self.getters = None
            self.encoders = None
            self.decoders = None
            return
        self.fields = {}
        self.schema = []
        self.types = []
        self.getters = []
        # Blob fields register their bytes at encode time, dates and times
        # pack (docs/datetime-plan.md D10); the rest are identity.
        self.encoders = []
        self.decoders = []
        for f in dataclasses.fields(cls):
            tag = _wire_tag(f.type)
            if tag is None:
                continue
            self.fields[f.name] = len(self.schema)
            self.schema.append(tag)
            self.types.append(f.type)
            self.getters.append(operator.attrgetter(f.name))
            self.encoders.append(_FIELD_ENCODERS.get(f.type, _identity))
            self.decoders.append(_FIELD_DECODERS.get(f.type, _identity))
        if not self.schema:
            raise TypeError(f"kaya: {cls.__name__} has no wire-typed fields")


class Sort:
    """The header bar's sort indicator (docs/tables-plan.md): the
    GUEST's declaration, re-sent after it handles a sort request. The
    platform never sorts; a header click only asks."""

    __slots__ = ("sorted", "direction")

    def __init__(self, sorted, direction):
        self.sorted = sorted
        self.direction = direction

    @staticmethod
    def asc(column):
        """Ascending on `column` (0-based, in the declared order)."""
        return Sort(column, 0)

    @staticmethod
    def desc(column):
        """Descending on `column`."""
        return Sort(column, 1)


# The no-indicator bar (the wire's u32 none-sentinel).
Sort.NONE = Sort(0xFFFF_FFFF, 0)


class Collection(_BoundCollection):
    def __init__(self, id, record_type=None):
        self._id = id
        self._instances = {}
        self._children = []  # collections declared inside our template
        self._derived = []  # signals recomputed from this collection
        # Highest I64 key each INSTANCE has minted or absorbed. Not in
        # the rollback journal, on purpose — see insert_fresh.
        self._fresh = {}
        self._record_type = record_type
        # The type is the schema: a dataclass is the one-variant case, a
        # union of dataclasses the sum, in declaration order.
        if record_type is None:
            self._variants = [_Variant(None)]
        elif isinstance(record_type, types.UnionType):
            self._variants = [_Variant(cls) for cls in record_type.__args__]
        else:
            self._variants = [_Variant(record_type)]
        # A sum leaves these None so a bare `element.field` or unmatched
        # patch cannot bypass the case analysis.
        only = self._variants[0] if len(self._variants) == 1 else None
        self._fields = only.fields if only else None
        super().__init__(self, [])

    def __iter__(self):
        """In template position, `for t in todos:` traces to a For — the
        loop body runs ONCE, authoring the blueprint."""
        if not (_recording or _tpl_depth > 0):
            raise TypeError(
                "kaya: `for t in coll:` is template tracing, record time "
                "only — handlers iterate the model with items()"
            )
        if len(self._variants) > 1:
            # A for-loop body is one arm, but a sum's template is a
            # record of case arms.
            raise TypeError(
                "kaya: a sum collection's template is its case arms — "
                "use `with kaya.for_each(c) as cases:` and one "
                "`with cases.case(Cls) as el:` per constructor"
            )
        return _ForTrace(self)

    def rows(self, grow=None, align=None, a11y_id=None, reorderable=False,
             on_drop=None):
        """The configured spelling of the ordinary For loop:
        `for item in items.rows(grow=1, align="stretch"):`.

        `reorderable=True` makes every stamped row drag within this
        collection; the landing arrives at `on_drop` on the For's own
        container, with the moved row's key in the clip and the row it
        landed on as the anchor, and the app confirms with a move
        (docs/dnd-plan.md D8)."""
        trace = iter(self)
        trace._grow = grow
        trace._align = align
        trace._a11y_id = a11y_id
        trace._reorderable = reorderable
        trace._on_drop = on_drop
        return trace

    def columns(self, *titles, sort=None, on_sort=None, grow=None, a11y_id=None):
        """Declare the column header bar on this collection's For — the
        table spelling of the same loop.

        The row template's body must hold a `with kaya.row():` of exactly
        one cell per column. `on_sort` takes the 0-based column index of
        a header click, preceded by the copy keys inside a nested
        template; re-declare with set_columns() after sorting
        (docs/tables-plan.md)."""
        return _ColumnsTrace(self, list(titles), sort or Sort.NONE, on_sort, grow, a11y_id)

    def _decode(self, variant, fields, current):
        """Rebuild a model value from an undo delta's wire record.

        An entry the mirror still holds is UPDATED IN PLACE, so a
        dataclass field the wire never carried survives the undo.
        """
        spec = self._variants[variant]
        for value in fields:
            if isinstance(value, wire.BlobHandle):
                # NOT REDEEMABLE: a blob field arrives as an index into
                # a batch-local table that was thrown away.
                raise NotImplementedError(
                    "kaya: this undo step restores a collection entry with "
                    "a bytes field, and the core's undo payload cannot "
                    "carry blob bytes yet (wire.rs undo_body encodes them "
                    "as a batch-local handle with no table behind it). "
                    "Keep bytes fields out of undoable groups until that "
                    "lands."
                )
        if spec.cls is None:
            return fields[0]
        names = list(spec.fields)  # schema order == wire order
        restored = [d(v) for d, v in zip(spec.decoders, fields)]
        if isinstance(current, spec.cls):
            for name, value in zip(names, restored):
                setattr(current, name, value)
            return current
        return spec.cls(**dict(zip(names, restored)))

    def _variant_for(self, value):
        """The constructor a model value holds."""
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
        _journal_instances(self)
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
        # The add_child must land after template_end: inside the
        # blueprint it would cross zones.
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
    """The for-statement tracer: opens the For template, hands the body
    one element tracer, and closes the template when the loop asks for a
    second. THE BODY RUNS ONCE — stamping is the core's replay."""

    def __init__(self, coll):
        self._template = _Template(
            wire.tx_create_for, coll._id, is_for=True, coll=coll)
        self._grow = None
        self._align = None
        self._a11y_id = None
        self._reorderable = False
        self._on_drop = None
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
            if self._grow is not None:
                _records().append(
                    wire.tx_set_grow(self._template.handle.id, float(self._grow)))
            if self._align is not None:
                _records().append(
                    wire.tx_set_align(self._template.handle.id, _align_value(self._align)))
            if self._a11y_id is not None:
                # The copies of one For node share a node id, so a
                # constant names N containers at once (`_Handle.a11y_id`).
                self._template.handle.a11y_id(self._a11y_id)
            if self._reorderable:
                _records().append(wire.tx_set_reorderable(
                    self._template.handle.id, 1))
            if self._on_drop is not None:
                self._template.handle.on_drop(self._on_drop)
        raise StopIteration


def _alloc_widget_or_node():
    # One counter for both (DESIGN.md, Binding conventions).
    if _tpl_depth > 0:
        return Node(_app._next("widget"))
    return Widget(_app._next("widget"))


def _widget(kind):
    handle = _alloc_widget_or_node()
    _records().append(wire.tx_create_widget(handle.id, kind))
    _auto_parent(handle.id)
    return handle


def create_window(window_id):
    """Create an auxiliary window (capability-gated: a phone host
    rejects it at the root). Materializes hidden; mounting presents."""
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


def select_section(section_id, window=0):
    """Select a section programmatically: configuration, never echoes
    on_selected. The section must already be added."""
    _records().append(wire.tx_select_section(int(window), int(section_id)))


# The presentation hint's closed set, spelled for guests.
SECTIONS_AUTO = wire.SECTIONS_PRESENTATION_AUTO
SECTIONS_BAR = wire.SECTIONS_PRESENTATION_BAR
SECTIONS_SIDEBAR = wire.SECTIONS_PRESENTATION_SIDEBAR


# The alert_choice cancel sentinel. Deliberately not an index.
CANCEL = wire.ALERT_CHOICE_CANCEL


def show_alert(title="", message="", actions=(), cancel=None,
               on_result=None, window=0):
    """Request a modal alert: up to two action labels (the platform
    floor) plus the REQUIRED cancel label, the slot every
    platform-native dismissal resolves to. on_result(choice) fires
    exactly once and retires. One alert may be live per process; show
    the next from the handler."""
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


class _ColumnsTrace:
    """columns()'s wrapper over the for-statement tracer. The header
    declaration is emitted when the template CLOSES: the core validates
    the row template against the declared arity, so it must follow the
    bodies."""

    def __init__(self, coll, titles, sort, on_sort, grow=None, a11y_id=None):
        self._coll = coll
        self._titles = titles
        self._sort = sort
        self._on_sort = on_sort
        self._grow = grow
        self._a11y_id = a11y_id
        self._trace = None

    def __iter__(self):
        self._trace = iter(self._coll)
        return self

    def __next__(self):
        try:
            return next(self._trace)
        except StopIteration:
            handle = self._trace._template.handle
            self._coll._for_handle = handle.id
            # path_len 0: no key path, so the values are titles alone.
            _records().append(
                wire.tx_set_column_headers(
                    handle.id, self._sort.sorted, self._sort.direction,
                    len(self._titles), 0, self._titles,
                )
            )
            if self._on_sort is not None:
                _app._register(handle, wire.OCC_SORT_REQUESTED, self._on_sort)
            if self._grow is not None:
                _records().append(wire.tx_set_grow(handle.id, float(self._grow)))
            if self._a11y_id is not None:
                handle.a11y_id(self._a11y_id)
            raise


class PickedFile:
    """One picked file: a handle to redeem, a display name, and
    `local_path` — a RE-OPENABLE NAME, empty unless re-opening it
    actually works, which measurement puts at the three desktops and
    neither phone (DESIGN.md, File dialogs)."""

    __slots__ = ("handle", "name", "local_path")

    def __init__(self, handle, name, local_path):
        self.handle = handle
        self.name = name
        self.local_path = local_path

    def open(self, mode=wire.FILE_MODE_READ):
        """Redeem the handle: returns `(file, seekable)`.

        BLOCKS, possibly for a long time, so call it from a thread you
        chose and post the result back. `seekable` RIDES THE OPEN because
        that is the only place the answer exists — an Android provider
        may hand back a pipe.
        """
        return runtime.open_picked(self.handle, mode)

    def __repr__(self):
        return f"PickedFile(name={self.name!r}, local_path={self.local_path!r})"


def pick_files(filters=(), on_result=None, window=0):
    """Ask the platform for files. THE PICK, NOT THE OPEN — the result
    carries handles you redeem later.

    `filters` is a sequence of `(label, extensions)` pairs, ADVISORY on
    every platform, so the guest still validates what it got.
    on_result(files) fires exactly once and retires; CANCEL IS THE EMPTY
    LIST. One dialog may be live per process."""
    return _pick(True, filters, on_result, window)


def pick_file(filters=(), on_result=None, window=0):
    """The single-file spelling. The floor always returns a LIST; this
    only asks the platform for one, so the handler receives zero or one
    file."""
    return _pick(False, filters, on_result, window)


def save_file(suggested_name, filters=(), on_result=None, window=0):
    """Ask the platform WHERE TO SAVE. The picker's twin, out of the same
    one-live-dialog slot.

    `suggested_name` is not optional: a save dialog with an empty name
    box is one the platform will not let the user complete. The user
    renames it and Android may append an extension, so READ THE NAME YOU
    GOT. on_result(file) fires exactly once; CANCEL IS `None`.

    WHAT YOU GET BACK OPENS EMPTY: the handle's open CREATES, so
    FILE_MODE_WRITE yields an empty file on every platform
    (docs/save-plan.md D1)."""
    app = _app
    dialog_id = app._next("file_dialog")
    if on_result is not None:
        def one(files, _handler=on_result):
            _handler(files[0] if files else None)
        app._file_dialog_handlers[dialog_id] = one
    _records().append(wire.tx_show_save_dialog(
        int(window), dialog_id, str(suggested_name), _filters(filters)))
    return dialog_id


def _filters(filters):
    """The advisory filter encoding BOTH dialogs share: alternating
    label and space-separated extensions."""
    flat = []
    for label, exts in filters:
        if not isinstance(exts, str):
            exts = " ".join(exts)
        flat.append(str(label))
        flat.append(exts)
    return flat


def _pick(multiple, filters, on_result, window):
    app = _app
    dialog_id = app._next("file_dialog")
    if on_result is not None:
        app._file_dialog_handlers[dialog_id] = on_result
    _records().append(wire.tx_show_file_dialog(
        int(window), dialog_id, 1 if multiple else 0, _filters(filters)))
    return dialog_id


# --- The clipboard (DESIGN.md, Clipboard) --------------------------
#
# kaya DERIVES NOTHING between representations: a bad auto-derivation
# degrades every paste into a plain field silently.


class Representation:
    """One representation, arriving — the sum `copy` is the record of.

    Nested constructors rather than five module-level names, so `Image`
    cannot be mistaken for the `image()` widget.
    """

    __slots__ = ()

    class Text:
        __slots__ = ("text",)
        __match_args__ = ("text",)

        def __init__(self, text):
            self.text = text

        def __repr__(self):
            return f"Text({self.text!r})"

    class Html:
        __slots__ = ("html",)
        __match_args__ = ("html",)

        def __init__(self, html):
            self.html = html

        def __repr__(self):
            return f"Html({self.html!r})"

    class Image:
        """Encoded image bytes. WHAT COMES BACK MAY BE A RE-ENCODE — the
        hosts convert freely — so never compare the bytes it arrived
        in."""

        __slots__ = ("bytes",)
        __match_args__ = ("bytes",)

        def __init__(self, data):
            self.bytes = data

        def __repr__(self):
            return f"Image({len(self.bytes)} bytes)"

    class Files:
        """PickedFile, plural INSIDE one representation. A pasted file
        opens with the picker's own call."""

        __slots__ = ("files",)
        __match_args__ = ("files",)

        def __init__(self, files):
            self.files = files

        def __repr__(self):
            return f"Files({self.files!r})"

    class Custom:
        """An app-defined format, round-tripped verbatim."""

        __slots__ = ("id", "bytes")
        __match_args__ = ("id", "bytes")

        def __init__(self, id, data):
            self.id = id
            self.bytes = data

        def __repr__(self):
            return f"Custom({self.id!r}, {len(self.bytes)} bytes)"


def _representation(payload):
    """Turn the decoder's (clip kind, values) into the sum, or None.

    EMPTY IS THE UNIVERSAL NO: a denied iOS prompt, an unfocused reader
    on Android or Wayland, an empty clipboard and unaccepted content
    alike — the platforms do not say which.
    """
    clip, values = payload
    if clip == wire.CLIP_TEXT:
        return Representation.Text(values[0])
    if clip == wire.CLIP_HTML:
        return Representation.Html(values[0])
    if clip == wire.CLIP_IMAGE:
        return Representation.Image(values[0])
    if clip == wire.CLIP_CUSTOM:
        return Representation.Custom(values[0], values[1])
    if clip == wire.CLIP_FILES:
        # The picker's own three-per-file grouping.
        return Representation.Files([
            PickedFile(values[i], values[i + 1], values[i + 2])
            for i in range(0, len(values), 3)])
    return None


class Dropped:
    """What a drop delivered (docs/dnd-plan.md D1).

    `clip` is the `Representation` a paste already delivers; `operation`
    is OP_COPY, OP_MOVE or None; `point` is (x, y) in the destination's
    own coordinates; `anchor` and `before` are the reorder's landing row
    and side (D8).
    """
    __slots__ = ("point", "operation", "anchor", "before", "clip")
    __match_args__ = ("clip", "operation")

    def __init__(self, point, operation, anchor, before, clip):
        self.point = point
        self.operation = operation
        self.anchor = anchor
        self.before = before
        self.clip = clip

    def __repr__(self):
        return (f"Dropped(point={self.point!r}, operation={self.operation!r}, "
                f"anchor={self.anchor!r}, before={self.before!r}, "
                f"clip={self.clip!r})")


def _operation(mask):
    """The drag_op word, or None for a cancelled or refused drag."""
    if mask == wire.DRAG_OP_COPY:
        return OP_COPY
    if mask == wire.DRAG_OP_MOVE:
        return OP_MOVE
    return None


def _dropped(payload):
    """Turn the decoder's drop tuple into the sum-carrying handle."""
    operation, before, point, anchor, clip, values = payload
    return Dropped(point, _operation(operation), list(anchor), before,
                   _representation((clip, values)))


def _drag_slot(handle, keys, what, value):
    """One drag representation's source (docs/dnd-plan.md §4): the row's
    own field, packed as `level << 32 | field` for the slot it fills, or
    None for a constant the caller writes itself.

    `.draggable(text=row.title)` binds the way `label(bind=row.title)`
    does, and every stamped copy resolves it from its own record.
    """
    if isinstance(value, Signal):
        raise TypeError(
            f"kaya: a drag payload's {what} cannot be a signal — a "
            "payload is app-updated state, re-declared when it changes "
            "(docs/dnd-plan.md D1), and inside a For's body it binds a "
            "constant or the row's own field (§4)")
    if isinstance(value, FieldRef):
        level, field = value._level(), value._index
    elif isinstance(value, Element):
        level, field = value._level(), 0
    elif isinstance(value, _CaseElement):
        raise TypeError(
            f"kaya: a drag payload's {what} takes one of the row's "
            "fields (row.title), not a case element — inside a case arm "
            "project the field (docs/dnd-plan.md §4)")
    else:
        return None
    if keys:
        raise RuntimeError(
            f"kaya: draggable_at names ONE stamped copy, whose payload is "
            f"already resolved — bind {what} to the row's field in the "
            "For's body instead (docs/dnd-plan.md §4)")
    if not isinstance(handle, Node):
        raise RuntimeError(
            f"kaya: a live widget's drag payload cannot bind {what} to a "
            "row's field — a live widget is one thing on screen and has "
            "no row (docs/dnd-plan.md §4)")
    return (level << 32) | field


def _template_zone_only(handle, what):
    """A keyed drag declaration names ONE STAMPED COPY, so it takes the
    template node the copy was stamped from — a live widget is exactly
    one thing on screen and has no keys (docs/dnd-plan.md §4)."""
    if not isinstance(handle, Node):
        raise RuntimeError(
            f"kaya: {what} names ONE STAMPED COPY — it takes a template "
            "node and that copy's keys, and a live widget is one thing on "
            "screen (docs/dnd-plan.md §4)")


def _operations(operations):
    """The drag_op mask a guest's words name; empty withdraws."""
    mask = 0
    for op in operations:
        if op == OP_COPY:
            mask |= wire.DRAG_OP_COPY
        elif op == OP_MOVE:
            mask |= wire.DRAG_OP_MOVE
        else:
            raise ValueError(
                f"kaya: {op!r} is not a drag operation — copy and move are "
                "the vocabulary, and link and ask are refused "
                "(docs/dnd-plan.md D3)")
    return mask


class UndoDelta:
    """What one step put back: the CORE-AUTHORITATIVE restored state
    (docs/undo-plan.md D5). Four runs, each a list:

    - `signals` — (signal id, restored value) pairs.
    - `texts` — (widget or node id, instance path, restored text)
      triples, and THE ONLY NOTIFICATION THERE IS for that text: a
      restore never echoes, so an app folding `text_changed` into its own
      model would go stale. The path is which field: EMPTY is a live
      widget, non-empty a stamped copy.
    - `entries` — (collection id, instance path, key, state), state None
      where the restored state does not have that entry.
    - `orders` — (collection id, instance path, keys in order).

    THE COLLECTION MIRRORS ARE ALREADY RECONCILED before your handler
    runs; signals and text are not mirrored, hence those two runs.
    """

    __slots__ = ("signals", "texts", "entries", "orders")

    def __init__(self, signals, texts, entries, orders):
        self.signals = signals
        self.texts = texts
        self.entries = entries
        self.orders = orders

    def __repr__(self):
        return (f"UndoDelta(signals={self.signals!r}, texts={self.texts!r}, "
                f"entries={self.entries!r}, orders={self.orders!r})")


def _accept_list(kinds):
    """Join an accept list: the closed kinds by name plus any custom ids,
    space separated.

    Ids reach every platform's registry verbatim and carry NO SPACES,
    which is what makes the join unambiguous.
    """
    out = []
    for kind in kinds:
        kind = str(kind)
        if not kind or " " in kind:
            raise ValueError(
                f"kaya: {kind!r} is not an accept-list entry — the closed "
                "kinds are 'text', 'html', 'image' and 'files', and a "
                "custom format id reaches the platform's own registry "
                "verbatim, so it carries no spaces")
        out.append(kind)
    return " ".join(out)


def copy(text=None, html=None, image=None, files=(), custom=None):
    """Put ONE clip on the system clipboard, offered in as many
    representations as you fill in.

    `custom` takes a mapping of id to bytes; `files` takes PickedFile
    handles, so the bytes never move through kaya. The wire order is
    kaya's — descending richness — not this call's.
    """
    reps = []
    present = 0
    custom = dict(custom or {})
    files = list(files)
    for ident, data in custom.items():
        _accept_list([ident])  # an id with a space would not survive
        reps.append(str(ident))
        reps.append(wire.BlobHandle(runtime.register_blob(data)))
    for picked in files:
        reps.append(getattr(picked, "handle", picked))
    if image is not None:
        present |= wire.CLIP_IMAGE
        reps.append(wire.BlobHandle(runtime.register_blob(image)))
    if html is not None:
        present |= wire.CLIP_HTML
        reps.append(str(html))
    if text is not None:
        present |= wire.CLIP_TEXT
        reps.append(str(text))
    _records().append(wire.tx_copy(present, len(files), len(custom), reps))


def read_clipboard(accepting, on_result=None):
    """Read the clipboard OUTSIDE any paste gesture — THE PRIVILEGED ONE.

    THE PLATFORMS HAVE MADE IT EXPENSIVE: iOS 16 PROMPTS when the content
    came from another app and blocks until the user answers, Android
    returns nothing unless the app has focus, and Wayland delivers no
    offer to an unfocused client. Reach for this to detect a URL, never
    to implement Paste — that is the Paste command, and it is free.

    on_result(clip) fires exactly once with the sum or None, and retires.
    """
    app = _app
    request = app._next("clipboard")
    if on_result is not None:
        app._clipboard_handlers[request] = on_result
    _records().append(wire.tx_read_clipboard(request, _accept_list(accepting)))
    return request


# --- Menus: the command vocabulary (DESIGN.md, Menus) --------------
#
# Creators declare into the open with-scope; node-anchored handlers
# receive the stamped copy's keys FIRST.


class MenuItem:
    """A live menu item in its OWN id space, never a widget or node id.
    One command identity: exactly one parent or anchor, forever."""

    def __init__(self, id):
        self.id = id

    def label(self, value):
        """Rename the item: constant text or a bound Str signal.
        Label writes never emit anything."""
        if isinstance(value, Signal):
            _records().append(wire.tx_bind_menu_label(self.id, value.id))
        else:
            _records().append(
                wire.tx_set_menu_label(self.id, _text_value("menu label", value)))

    def enabled(self, value):
        """Whether the item is enabled (default true): a constant or a
        bound Bool signal. Disabling a grouping node disables its
        subtree."""
        if isinstance(value, Signal):
            _records().append(wire.tx_bind_menu_enabled(self.id, value.id))
        else:
            _records().append(wire.tx_set_menu_enabled(self.id, bool(value)))

    def checked(self, value):
        """A toggle's state (toggle items only — root-checked). The
        programmatic write is QUIET: no menu_toggled echo."""
        if isinstance(value, Signal):
            _records().append(wire.tx_bind_menu_checked(self.id, value.id))
        else:
            _records().append(wire.tx_set_menu_checked(self.id, bool(value)))

    def value(self, v):
        """A radio group's selected option index (radio groups only —
        root-checked). QUIET, like checked."""
        if isinstance(v, Signal):
            _records().append(wire.tx_bind_menu_value(self.id, v.id))
        else:
            _records().append(wire.tx_set_menu_value(self.id, float(v)))

    def icon(self, data):
        """The item's icon (the blob channel): used by phone promotion,
        ignored where native menu dress has no icons. Const-only."""
        _records().append(
            wire.tx_set_menu_icon(self.id, runtime.register_blob(data)))

    def symbol(self, symbol):
        """The item's SEMANTIC ICON (`kaya.Symbol`, or its name): the
        closed concept vocabulary each backend maps to its own platform's
        symbol set. No symbol on a separator. Const-only."""
        _records().append(
            wire.tx_set_menu_symbol(self.id, _symbol_value(symbol)))

    def primary(self, on):
        """The phone-bar promotion hint (actions only — root-checked).
        INERT on desktops. Const-only."""
        _records().append(wire.tx_set_menu_primary(self.id, bool(on)))

    def role(self, name):
        """Declare this action a standard command (actions only).
        PLACEMENT is each host's business. One item per role, and a role
        NEVER invents a chord. Const-only."""
        _records().append(wire.tx_set_menu_role(self.id, name))

    def shortcut(self, spelling):
        """The shortcut of any LEAF command (window-anchored only),
        canonicalized by wire.canonicalize_shortcut. It fires the SAME
        menu_activated occurrence as a click. Const-only."""
        _records().append(wire.tx_set_menu_shortcut(self.id, spelling))

    def append(self):
        """Reopen this RETAINED grouping node. The root re-validates each
        appended subtree in the item's real anchor context."""
        return _MenuScope(("item", self.id), shortcut_ok=True, value=self)


class ContextCatalog:
    """A context catalog built free of any anchor, for a template node:
    menu items are live and shared across stamped copies, so it is built
    in the LIVE zone and node.context_menu(catalog) attaches it."""

    def __init__(self):
        self._roots = []
        self._attached = False


class _MenuScope(_Scope):
    """A with-block whose creators seat under one menu anchor. on_exit
    runs after the block's children recorded, which is THE RADIO VALUE'S
    SEAT: the selected index must land AFTER the options it
    addresses."""

    def __init__(self, seat, shortcut_ok, value=None, on_exit=None):
        self._seat = seat  # ("item", id) | ("widget", id) | ("free", catalog)
        self._shortcut_ok = shortcut_ok
        self._value = value
        self._on_exit = on_exit

    def _enter(self):
        _menu_scopes.append(self)
        return self._value

    def _exit(self):
        _menu_scopes.pop()
        if self._on_exit is not None:
            self._on_exit()


def _menu_create(kind, label=None):
    """Create one menu item in its own id space; menu records are
    live-zone only (a template body records a blueprint — build the
    catalog outside and attach with node.context_menu)."""
    if _tpl_depth > 0:
        raise RuntimeError(
            "kaya: menu items are live — build the context catalog in "
            "the live zone (kaya.context_catalog) and attach it inside "
            "the template with node.context_menu(catalog)"
        )
    item = MenuItem(_app._next("menu_item"))
    _records().append(wire.tx_menu_item_create(item.id, kind))
    if label is not None:
        if isinstance(label, Signal):
            _records().append(wire.tx_bind_menu_label(item.id, label.id))
        else:
            _records().append(
                wire.tx_set_menu_label(item.id, _text_value("menu label", label)))
    return item


def _menu_seat(item):
    """Seat a just-created item under the open scope's anchor and
    return the scope (for the shortcut rule)."""
    if not _menu_scopes:
        raise RuntimeError(
            "kaya: menu items declare inside a menu scope — "
            "app.menu()/app.radio_group() for the window catalog, "
            "widget.context_menu() or kaya.context_catalog() for a "
            "context anchor"
        )
    scope = _menu_scopes[-1]
    kind, target = scope._seat
    if kind == "item":
        _records().append(wire.tx_menu_item_append(target, item.id))
    elif kind == "widget":
        _records().append(wire.tx_context_attach(target, item.id))
    else:  # free roots, collected for a later template-node attach
        target._roots.append(item.id)
    return scope


#: A NAMED VOCABULARY FOR THE CLOSED HALF. A MISTYPED BARE STRING IS
#: SILENT: it becomes a custom format id no clipboard will ever offer,
#: so Paste stays dead and the paste hook never fires.
ACCEPT_TEXT = "text"
ACCEPT_HTML = "html"
ACCEPT_IMAGE = "image"
ACCEPT_FILES = "files"

#: The drag operation vocabulary (docs/dnd-plan.md D3). Named for the
#: accept list's reason: a bare string that is not one of these two is a
#: silent no-op everywhere, so `_operations` refuses it by name.
OP_COPY = "copy"
OP_MOVE = "move"


ROLE_SETTINGS = "settings"

#: The three clipboard commands: they lower to the platform's own, act
#: on the FOCUSED widget, and work out their own enablement.
ROLE_CUT = "cut"
ROLE_COPY = "copy"
ROLE_PASTE = "paste"

#: The two history commands: the FOCUSED widget is asked FIRST, the
#: window's ledger otherwise (docs/undo-plan.md D6).
ROLE_UNDO = "undo"
ROLE_REDO = "redo"


def _menu_require_catalog(scope):
    """A chord and a role both need a window catalog as their home: the
    root rejects either on a context anchor, and this says so at the call
    site."""
    if not scope._shortcut_ok:
        raise ValueError(
            "kaya: a context item takes no shortcut — a shortcut "
            "needs a window catalog as its native dispatch home"
        )


def item(label, shortcut=None, enabled=None, icon=None, symbol=None,
         primary=None, role=None, on_activate=None):
    """An action — a leaf command firing exactly one menu_activated
    occurrence, whether from a click or its shortcut. On a template-node
    catalog the handler receives the stamped copy's keys first."""
    it = _menu_create(wire.MENU_KIND_ACTION, label)
    scope = _menu_seat(it)
    if shortcut is not None:
        _menu_require_catalog(scope)
        it.shortcut(shortcut)
    if enabled is not None:
        it.enabled(enabled)
    if icon is not None:
        it.icon(icon)
    if symbol is not None:
        it.symbol(symbol)
    if primary is not None:
        it.primary(primary)
    if role is not None:
        if not scope._shortcut_ok:
            raise ValueError(
                "kaya: a context item takes no role — a role names a "
                "standard command in the window catalog"
            )
        it.role(role)
    if on_activate is not None:
        _app._menu_handlers[(wire.OCC_MENU_ACTIVATED, it.id)] = on_activate
    return it


def toggle(label, checked=None, enabled=None, icon=None, symbol=None,
           shortcut=None, on_toggle=None):
    """A toggle — a stateful leaf: user flips emit menu_toggled (the
    handler receives the new state, template-node copies the stamped keys
    first); programmatic checked writes are quiet."""
    it = _menu_create(wire.MENU_KIND_TOGGLE, label)
    scope = _menu_seat(it)
    if shortcut is not None:
        _menu_require_catalog(scope)
        it.shortcut(shortcut)
    if checked is not None:
        it.checked(checked)
    if enabled is not None:
        it.enabled(enabled)
    if icon is not None:
        it.icon(icon)
    if symbol is not None:
        it.symbol(symbol)
    if on_toggle is not None:
        _app._menu_handlers[(wire.OCC_MENU_TOGGLED, it.id)] = on_toggle
    return it


def option(label, enabled=None, icon=None, symbol=None, shortcut=None):
    """One labeled radio option, appended in declaration order — the
    order IS the index vocabulary the group's value selects over."""
    it = _menu_create(wire.MENU_KIND_RADIO_OPTION, label)
    scope = _menu_seat(it)
    if shortcut is not None:
        _menu_require_catalog(scope)
        it.shortcut(shortcut)
    if enabled is not None:
        it.enabled(enabled)
    if icon is not None:
        it.icon(icon)
    if symbol is not None:
        it.symbol(symbol)
    return it


def separator():
    """Native grouping chrome: no label, no props, no handle kept."""
    it = _menu_create(wire.MENU_KIND_SEPARATOR)
    _menu_seat(it)


def menu(label, enabled=None, icon=None, symbol=None):
    """A NESTED menu — grouping, never navigation (one nested level is
    the cap, root-checked). Bar-level menus are `app.menu`."""
    it = _menu_create(wire.MENU_KIND_MENU, label)
    scope = _menu_seat(it)
    if enabled is not None:
        it.enabled(enabled)
    if icon is not None:
        it.icon(icon)
    if symbol is not None:
        it.symbol(symbol)
    return _MenuScope(("item", it.id), scope._shortcut_ok, value=it)


def radio_group(label, value=None, enabled=None, icon=None, symbol=None,
                on_select=None):
    """A NESTED radio group, declaring only kaya.option children.
    `value` is the selected 0-based index; programmatic writes are quiet,
    and on_select receives each USER pick's new index."""
    it = _menu_create(wire.MENU_KIND_RADIO_GROUP, label)
    scope = _menu_seat(it)
    if enabled is not None:
        it.enabled(enabled)
    if icon is not None:
        it.icon(icon)
    if symbol is not None:
        it.symbol(symbol)
    if on_select is not None:
        _app._menu_handlers[(wire.OCC_MENU_VALUE_CHANGED, it.id)] = on_select
    # value= lands at block exit, AFTER the option children: the index
    # addresses options, and the root judges its domain at the record.
    on_exit = (lambda: it.value(value)) if value is not None else None
    return _MenuScope(("item", it.id), scope._shortcut_ok, value=it,
                      on_exit=on_exit)


def context_catalog():
    """Build a context catalog UNANCHORED — free root items for a
    template-node anchor, built in the LIVE zone. Context items take no
    shortcuts."""
    catalog = ContextCatalog()
    return _MenuScope(("free", catalog), shortcut_ok=False, value=catalog)


def window_size(width, height):
    """Request the primary surface's content size (DIP). ADVISORY on
    every platform — a request, never a guarantee."""
    _records().append(wire.tx_set_window_width(0, float(width)))
    _records().append(wire.tx_set_window_height(0, float(height)))


def _accent(what, value):
    """The wire field's domain, and NOTHING SEMANTIC. A bool is excluded
    BEFORE int, which it subclasses: `True` would silently become the
    colour 0x000001.

    THE 24-BIT RULE IS DELIBERATELY NOT HERE — it dies at the ROOT's
    wall, in one sentence every language gets (invariant 1).
    """
    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError(
            f"kaya: brand accent {what} takes one packed sRGB int "
            f"(0x3584E4), not {type(value).__name__} — brand is identity, "
            "set once before the first mount, so it is never a signal"
        )
    if not 0 <= value <= 0xFFFFFFFF:
        raise ValueError(
            f"kaya: brand accent {what} is {value:#x}, which does not fit "
            "the wire's u32 — the accent is one packed sRGB hex (0x3584E4)"
        )
    return value


def brand_accent(seed, light=None, dark=None):
    """REQUEST the app's brand accent (docs/styling-plan.md D1/D2): one
    hex is the whole call, `light`/`dark` a per-appearance variant, and
    whatever an appearance does not state is filled from the seed.

    A REQUEST, UNIFORMLY: macOS applies an app accent only while the
    system accent is multicolor, so nothing here promises the pixels.

    SET ONCE, BEFORE THE FIRST MOUNT: the root refuses a second write and
    a late one.
    """
    mask = (1 if light is not None else 0) | (2 if dark is not None else 0)
    _records().append(wire.tx_set_brand_accent(
        _accent("seed", seed),
        mask,
        _accent("light", light) if light is not None else 0,
        _accent("dark", dark) if dark is not None else 0,
    ))


class Platform:
    """WHICH PLATFORM A PER-PLATFORM BRAND VALUE IS FOR (spec enum
    "platform"; docs/styling-plan.md Slice 2b), closed. Plain names
    accepted too.

    AN APP NAMES THESE, IT NEVER ASKS WHICH ONE IT IS: there is no
    `Platform.current()`, and `sys.platform` reads "linux" on Android.
    Every row travels to every backend and each picks its own.
    """

    MAC = wire.PLATFORM_MAC
    IOS = wire.PLATFORM_IOS
    LINUX = wire.PLATFORM_LINUX
    WINDOWS = wire.PLATFORM_WINDOWS
    ANDROID = wire.PLATFORM_ANDROID


class SizeClass:
    """A window's named size class (spec enum "size_class"): what
    `row(stack_when=...)` speaks in place of an author-invented width.
    COMPACT is the whole surface today — the platform's own class on iOS,
    narrower than 600 points everywhere else.
    """

    def __init__(self, tag, name):
        self._tag = tag
        self._name = name

    def __repr__(self):
        return f"kaya.{self._name}"


#: The one size class an app can name today (`stack_when=kaya.COMPACT`).
COMPACT = SizeClass(wire.SIZE_CLASS_COMPACT, "COMPACT")


#: DERIVED from the class rather than typed again: a drifted second
#: table hands a platform's family to a DIFFERENT platform, with nothing
#: raised and no lane able to see it.
_PLATFORM_NAMES = {
    name.lower(): value
    for name, value in vars(Platform).items()
    if name.isupper()
}

#: Tag -> name, derived from the table above, not typed again.
_PLATFORM_NAME_OF = {value: name for name, value in _PLATFORM_NAMES.items()}


def _platform_value(platform):
    """One platform tag, from either spelling, refused here if it is
    neither.

    WHAT STAYS THE ROOT'S, deliberately: naming one platform TWICE (two
    spellings of the same row are two dict keys) and an empty family.
    """
    if isinstance(platform, str):
        try:
            return _PLATFORM_NAMES[platform]
        except KeyError:
            raise ValueError(
                f"kaya: brand_typeface: {platform!r} is not a platform — the "
                f"vocabulary is {sorted(_PLATFORM_NAMES)}"
            ) from None
    # bool BEFORE int, which it subclasses: `{True: "Georgia"}` would
    # otherwise read as platform 1, mac.
    if isinstance(platform, bool) or not isinstance(platform, int):
        raise TypeError(
            f"kaya: brand_typeface: a per-platform key is kaya.Platform.LINUX "
            f"or its name, not {type(platform).__name__} — an app names the "
            "platforms it has a family for; it never asks which one it is"
        )
    if platform not in _PLATFORM_NAMES.values():
        raise ValueError(
            f"kaya: brand_typeface: {platform} is not a platform — the "
            f"vocabulary is {sorted(_PLATFORM_NAMES)} "
            "(kaya.Platform.MAC/IOS/LINUX/WINDOWS/ANDROID)"
        )
    return platform


class Asset:
    """One open asset: the bytes of a file the app's own BUILD shipped,
    held by the core and named the same way on five platforms
    (docs/assets-plan.md).

    TWO REDEMPTIONS: hand it to kaya (`font=`, `icon=`, `kaya.image()` —
    the bytes never enter Python), or read it yourself (`bytes()`,
    `reader()`). THERE IS NO FILE DESCRIPTOR on this surface and no call
    takes a mode. `close()` is idempotent; `with` and the finalizer both
    call it.
    """

    __slots__ = ("_handle", "_name")

    def __init__(self, handle, name):
        self._handle = handle
        self._name = name

    @property
    def name(self):
        """The name this asset was asked for — what `asset(name)` was
        given, not a path. Android has no path to hand back."""
        return self._name

    def bytes(self):
        """The asset's bytes, copied out of core memory. RAISES if the
        asset is closed rather than answering `b""`."""
        self._alive("bytes()")
        return runtime.asset_bytes(self._handle)

    def reader(self):
        """The asset as a file-like object: `io.BytesIO` over a copy of
        the bytes."""
        return io.BytesIO(self.bytes())

    def _blob(self):
        """Register the core's own bytes into the pending table and
        return the handle the next submit consumes — no copy, nothing
        through Python."""
        self._alive("a blob redemption")
        return runtime.asset_blob(self._handle)

    def close(self):
        """Release the core's handle. Idempotent, and the finalizer
        calls it too."""
        handle, self._handle = self._handle, 0
        if handle:
            runtime.asset_release(handle)

    def _alive(self, what):
        if not self._handle:
            raise RuntimeError(
                f"kaya: {what} on a closed asset ({self._name!r}) — the "
                "handle was released, and the bytes it borrowed are the "
                "core's. Read inside the `with`, or keep the bytes rather "
                "than the asset."
            )

    def __len__(self):
        self._alive("len()")
        return runtime.asset_len(self._handle)

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        self.close()
        return False

    def __del__(self):
        # Deliberately SILENT: interpreter teardown can already have
        # torn down what close() reaches, and a raising finalizer prints
        # an unraisable-exception warning.
        try:
            self.close()
        except Exception:
            pass

    def __repr__(self):
        state = "closed" if not self._handle else f"{len(self)} bytes"
        return f"Asset(name={self._name!r}, {state})"


def asset(name):
    """Open an asset — a file the app's own BUILD shipped beside it,
    named by a relative path under the asset root.

    Callable anywhere, including outside a transaction. A MISS RAISES
    WITH THE CORE'S SENTENCE AND NOTHING ADDED, so every binding's guest
    is handed the same bytes and one scene can freeze them. EACH CALL
    READS: no cache, no watch, no reload.
    """
    if not isinstance(name, str):
        raise TypeError(
            f"kaya: asset() takes a name as str ('fonts/sora-wght.ttf'), "
            f"not {type(name).__name__} — a relative path under the asset "
            "root, spelled with `/` on every platform"
        )
    handle = runtime.asset_open(name)
    if handle:
        return Asset(handle, name)
    sentence = runtime.asset_miss_sentence(name)
    raise RuntimeError(sentence or (
        # Reachable only if the two calls disagree: the open answered a
        # miss and the why-not answered that it resolves.
        f"kaya: asset({name!r}) did not open, and the core's own why-not "
        "answers that it resolves — those two facts were measured a "
        "moment apart, and this binding has nothing further to report"
    ))


def asset_miss_sentence(name):
    """Why `asset(name)` would fail — the sentence it would raise, handed
    over without raising. `""` means the name resolves.

    Line 1 (name, rule, census) is the same on every platform and is the
    line a scene freezes; line 2 names the resolved place.
    """
    if not isinstance(name, str):
        raise TypeError(
            f"kaya: asset_miss_sentence() takes a name as str "
            f"('fonts/sora-wght.ttf'), not {type(name).__name__} — a "
            "relative path under the asset root, spelled with `/` on "
            "every platform"
        )
    return runtime.asset_miss_sentence(name)


def _blob_of(source):
    """The one place a blob-taking consumer turns its argument into a
    handle: an `Asset` redeems, bytes register."""
    return source._blob() if isinstance(source, Asset) \
        else runtime.register_blob(source)


def _typeface_family(what, family):
    """The wire field's domain and NOTHING SEMANTIC.

    THE EMPTY FAMILY IS DELIBERATELY NOT REFUSED HERE — that sentence is
    the ROOT's, so every language reads the same one (invariant 1).
    """
    if not isinstance(family, str):
        raise TypeError(
            f"kaya: brand_typeface {what} takes a family NAME as str "
            f"('Georgia'), not {type(family).__name__} — a font FILE's bytes "
            "ride the font= slot, which is a different thing"
        )
    return family


def brand_typeface(family, platforms=None, font=None):
    """REQUEST the app's brand typeface (docs/styling-plan.md Slice 2b):
    one family name is the whole call, and every platform that has that
    family installed uses it.

    THE FAMILY, NEVER THE SCALE (DESIGN.md). The per-platform rows travel
    UNRESOLVED, each backend picking its own; an unnamed platform falls
    back to `family`, and a registered blob's own family wins over it.
    SET ONCE, BEFORE THE FIRST MOUNT. THE RISK IS THE SILENT FALLBACK:
    every platform's font API renders SOMETHING for a family it does not
    have, so nothing here promises the pixels.
    """
    pairs = []
    if platforms is not None:
        if not isinstance(platforms, dict):
            raise TypeError(
                f"kaya: brand_typeface platforms= takes a mapping of platform "
                f"to family — {{kaya.Platform.LINUX: 'DejaVu Serif'}} — not "
                f"{type(platforms).__name__}"
            )
        for key, value in platforms.items():
            tag = _platform_value(key)
            pairs.append(tag)
            pairs.append(_typeface_family(
                f"family for {_PLATFORM_NAME_OF.get(tag, tag)}", value))
    if font is not None and not isinstance(font, (Asset, bytes, bytearray,
                                                  memoryview)):
        raise TypeError(
            f"kaya: brand_typeface font= takes a font FILE's bytes, not "
            f"{type(font).__name__} — a family NAME is the first argument, "
            "and a font the app's BUILD shipped is kaya.asset('fonts/...')"
        )
    _records().append(wire.tx_set_brand_typeface(
        # Bit 0 says a blob rides; the slot is written either way, as an
        # empty Str when it does not (the record's shape is fixed).
        1 if font is not None else 0,
        _typeface_family("family", family),
        pairs,
        wire.BlobHandle(_blob_of(font)) if font is not None else "",
    ))


def app_identity(name, icon=None):
    """DECLARE the app's identity (docs/app-identity-plan.md): the name
    it goes by and the picture that stands for it. `icon=None` leaves
    every platform's own mark in place.

    ONE PICTURE, FIVE PLATFORMS — send a PNG, each lowering converts.
    SET ONCE, BEFORE THE FIRST MOUNT. THE BYTES ARE NEVER INSPECTED
    between here and the platform's decoder, so bytes that are not an
    image leave every platform's default in place.
    """
    if icon is not None and not isinstance(icon, (Asset, bytes, bytearray,
                                                  memoryview)):
        raise TypeError(
            f"kaya: app_identity icon= takes an image FILE's bytes, not "
            f"{type(icon).__name__} — the NAME is the first argument, and a "
            "mark the app's BUILD shipped is kaya.asset('icons/...')"
        )
    if not isinstance(name, str):
        raise TypeError(
            f"kaya: app_identity takes the app's name as str ('Aurora "
            f"Notes'), not {type(name).__name__} — an image FILE's bytes ride "
            "the icon= slot, which is a different thing"
        )
    _records().append(wire.tx_set_app_identity(
        # Bit 0 says a blob rides; the slot is written either way, as an
        # empty Str when it does not (the record's shape is fixed).
        1 if icon is not None else 0,
        name,
        wire.BlobHandle(_blob_of(icon)) if icon is not None else "",
    ))


#: The undo-group record's kind, in the two header bytes `record()`
#: frames it with — how `undoable` recognises a marker already at the
#: head without unpacking anything.
_UNDO_GROUP_TAG = wire.TX_UNDO_GROUP.to_bytes(2, "little")


def undoable(label, window=0):
    """Make THIS transaction one undoable step in `window`'s history,
    under `label` (docs/undo-plan.md D2).

    The marker goes AT THE HEAD of the batch wherever this call sits.
    THE UNDOABLE SET IS THE REACTIVE HALF (D4): signal writes and the
    five collection deltas. Pure effects (focus) ride along unrestored;
    anything else is REFUSED at apply, naming the op.
    """
    text = _text_value("undoable", label)
    if not text:
        raise ValueError(
            "kaya: an undo group needs a name — the EMPTY label is taken: "
            "it is how a typing episode identifies itself on the same "
            "occurrence, so an anonymous group would be indistinguishable "
            "from the native tier"
        )
    records = _records()
    if records and records[0][4:6] == _UNDO_GROUP_TAG:
        raise RuntimeError(
            "kaya: this transaction is already an undo group — one name "
            "per step"
        )
    records.insert(0, wire.tx_undo_group(int(window), text))


@dataclasses.dataclass(frozen=True)
class Capabilities:
    """WHAT THIS HOST CAN DO (crates/kaya/src/app.rs carries the
    canonical note). Named booleans, never the bits: the core is free to
    renumber. CAPABILITIES INFORM; WALLS REFUSE.
    """

    #: The host can materialize a surface beside the primary one. False
    #: on iOS and Android, where `create_window` aborts at the root.
    aux_windows: bool


def capabilities():
    """This host's capabilities, constant for the life of the process."""
    bits = runtime.capability_bits()
    return Capabilities(aux_windows=bool(bits & runtime.CAP_AUX_WINDOWS))


def signal(initial):
    handle = Signal(_app._next("signal"), initial)
    # By id, for the undo path: a restored value arrives as a signal id
    # and has to reach the binding's own cache (App._absorb_undo).
    _app._signals[handle.id] = handle
    _records().append(wire.tx_create_signal(handle.id, _wire_scalar(initial)))
    return handle


def collection(record_type=None):
    """Declare a collection. With no argument, a scalar (str) table —
    the one-field case. With a dataclass, a record collection: the
    dataclass IS the schema (wire-typed fields, declaration order), and
    `element.field` / `patch(key, field=...)` project it."""
    handle = Collection(_app._next("collection"), record_type)
    # THE UNDO PATH ARRIVES BY ID, not by handle, so the binding needs
    # the way back.
    _app._collections[handle._id] = handle
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
    """The align enum: a container's cross-axis child placement. Plain
    names accepted too — `align="center"`."""

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


class Axis:
    """The axis enum: a container's arrangement direction — row and
    column are one node whose constructor names the initial value
    (docs/adaptive-layout-plan.md D1). Plain names accepted too."""

    HORIZONTAL = wire.AXIS_HORIZONTAL
    VERTICAL = wire.AXIS_VERTICAL


_AXIS_NAMES = {
    "horizontal": wire.AXIS_HORIZONTAL,
    "vertical": wire.AXIS_VERTICAL,
}


def _axis_value(axis):
    if isinstance(axis, str):
        try:
            return _AXIS_NAMES[axis]
        except KeyError:
            raise ValueError(
                f"axis must be one of {sorted(_AXIS_NAMES)}, got {axis!r}"
            ) from None
    return int(axis)


def _align_value(align):
    if isinstance(align, str):
        try:
            return _ALIGN_NAMES[align]
        except KeyError:
            raise ValueError(
                f"align must be one of {sorted(_ALIGN_NAMES)}, got {align!r}"
            ) from None
    return int(align)


class Role:
    """The role enum: SEMANTIC EMPHASIS, the closed vocabulary
    (docs/styling-plan.md D4). Plain names accepted too.

    DESTRUCTIVE marks the press that destroys something; PROMINENT THE
    primary action; HEADING a text hierarchy heading (the platform's
    style AND the accessibility trait); CAPTION the footnote tier under
    the content it explains."""

    DESTRUCTIVE = wire.ROLE_DESTRUCTIVE
    PROMINENT = wire.ROLE_PROMINENT
    HEADING = wire.ROLE_HEADING
    CAPTION = wire.ROLE_CAPTION


_ROLE_NAMES = {
    "destructive": wire.ROLE_DESTRUCTIVE,
    "prominent": wire.ROLE_PROMINENT,
    "heading": wire.ROLE_HEADING,
    "caption": wire.ROLE_CAPTION,
}


def _role_value(role):
    """One role, from either spelling, refused here if it is neither.

    What stays the ROOT's is the PAIRING — whether this role fits the
    kind it was written on — which no handle here knows.
    """
    if isinstance(role, str):
        try:
            return _ROLE_NAMES[role]
        except KeyError:
            raise ValueError(
                f"kaya: role must be one of {sorted(_ROLE_NAMES)}, got "
                f"{role!r}"
            ) from None
    # bool BEFORE int, which it subclasses: `role(True)` would otherwise
    # read as 1, the destructive role.
    if isinstance(role, bool) or not isinstance(role, int):
        raise TypeError(
            f"kaya: role takes kaya.Role.HEADING or its name, not "
            f"{type(role).__name__} — a role says what a widget MEANS and "
            "is declared once, so no binding binds one to a signal"
        )
    if role not in _ROLE_NAMES.values():
        raise ValueError(
            f"kaya: {role} is not a role — the vocabulary is "
            f"{sorted(_ROLE_NAMES)} "
            "(kaya.Role.DESTRUCTIVE/PROMINENT/HEADING/CAPTION)"
        )
    return role


class Symbol:
    """THE SEMANTIC ICON VOCABULARY (spec enum "symbol";
    docs/styling-plan.md D6). An app names a CONCEPT and each backend
    draws its own platform's glyph; plain names accepted too.

    THE VALUES ARE WIRE VALUES AND ARE APPEND-ONLY. A new concept takes
    21; renumbering silently redraws every shipped app's menus.

    Where a word could go two ways: DELETE destroys (the wastebasket)
    while REMOVE takes an item out of a list; CLOSE dismisses (the ✕) and
    is not DELETE; DONE is the checkmark; MORE is the overflow ellipsis.
    BACK and FORWARD mean BACKWARD and FORWARD in READING ORDER, never
    left and right — every platform mirrors them under RTL."""

    ADD = wire.SYMBOL_ADD
    REMOVE = wire.SYMBOL_REMOVE
    DELETE = wire.SYMBOL_DELETE
    EDIT = wire.SYMBOL_EDIT
    DONE = wire.SYMBOL_DONE
    CLOSE = wire.SYMBOL_CLOSE
    SEARCH = wire.SYMBOL_SEARCH
    SETTINGS = wire.SYMBOL_SETTINGS
    REFRESH = wire.SYMBOL_REFRESH
    INFO = wire.SYMBOL_INFO
    WARNING = wire.SYMBOL_WARNING
    BACK = wire.SYMBOL_BACK
    FORWARD = wire.SYMBOL_FORWARD
    MORE = wire.SYMBOL_MORE
    COPY = wire.SYMBOL_COPY
    PASTE = wire.SYMBOL_PASTE
    STAR = wire.SYMBOL_STAR
    LOCK = wire.SYMBOL_LOCK
    PERSON = wire.SYMBOL_PERSON
    HOME = wire.SYMBOL_HOME


#: DERIVED from the class rather than typed again: a drifted second
#: table draws the wrong concept with nothing raised.
_SYMBOL_NAMES = {
    name.lower(): value
    for name, value in vars(Symbol).items()
    if name.isupper()
}


def _symbol_value(symbol):
    """One symbol, from either spelling, refused here if it is neither.
    The ROOT keeps its own wall and the PAIRING too."""
    if isinstance(symbol, str):
        try:
            return _SYMBOL_NAMES[symbol]
        except KeyError:
            raise ValueError(
                f"kaya: symbol must be one of {sorted(_SYMBOL_NAMES)}, got "
                f"{symbol!r}"
            ) from None
    # bool BEFORE int, which it subclasses: `symbol(True)` would
    # otherwise read as 1, the `add` glyph.
    if isinstance(symbol, bool) or not isinstance(symbol, int):
        raise TypeError(
            f"kaya: symbol takes kaya.Symbol.COPY or its name, not "
            f"{type(symbol).__name__} — a symbol names a CONCEPT the "
            "platform draws, and is declared once, so no binding binds "
            "one to a signal"
        )
    if symbol not in _SYMBOL_NAMES.values():
        raise ValueError(
            f"kaya: {symbol} is not a symbol — the vocabulary is "
            f"{sorted(_SYMBOL_NAMES)} (kaya.Symbol.COPY and friends)"
        )
    return symbol


def _set_align(handle, align):
    if align is None:
        return
    _records().append(wire.tx_set_align(handle.id, _align_value(align)))


def _set_spacing(handle, spacing):
    if spacing is None:
        return
    _records().append(wire.tx_set_spacing(handle.id, float(spacing)))


def _set_inset(handle, inset):
    if inset is None:
        return
    _records().append(wire.tx_set_inset(handle.id, float(inset)))


def _set_grow(handle, grow):
    # Every constructor takes `grow=`, the declarative spelling of
    # Widget.grow.
    if grow is not None:
        _records().append(wire.tx_set_grow(handle.id, float(grow)))


def scroll(grow=None):
    """A vertical scroll viewport parenting EXACTLY ONE child. Give it
    `grow` so the enclosing track CONSTRAINS it — an unconstrained
    viewport hugs its content and nothing overflows."""
    handle = _widget(wire.KIND_SCROLL)
    _set_grow(handle, grow)
    return _Container(handle)


def grid(columns, grow=None, spacing=None, inset=None):
    """A grid container laying its children out row-major into `columns`
    columns — each column at its NATURAL width, aligned across rows.
    `spacing` is the inter-cell gap on both axes; `inset` its own
    padding."""
    handle = _widget(wire.KIND_GRID)
    _records().append(wire.tx_set_columns(handle.id, float(columns)))
    _set_grow(handle, grow)
    _set_spacing(handle, spacing)
    _set_inset(handle, inset)
    return _Container(handle)


def spacer(grow=1.0):
    """A spacer: an empty grown column consuming the leftover main-axis
    space between its siblings."""
    handle = _widget(wire.KIND_COLUMN)
    _set_grow(handle, grow)
    return handle


def column(grow=None, spacing=None, align=None, inset=None):
    """A column container: parents everything declared inside it. `grow`
    is its flex weight; `spacing` its inter-child gap (main axis, DIP,
    default 8); `inset` its own padding."""
    handle = _widget(wire.KIND_COLUMN)
    _set_grow(handle, grow)
    _set_spacing(handle, spacing)
    _set_align(handle, align)
    _set_inset(handle, inset)
    return _Container(handle)


def button(text=None, bind=None, on_click=None, grow=None):
    """A button; `text` for a constant caption, `bind` for one the row
    supplies — a Signal, the enclosing For's element, or one of its
    fields (`row.title`).

    `bind` IS TEMPLATE-ONLY (docs/tpl-props-plan.md F5): one function
    serves both zones here, so it checks the ZONE instead of the type.
    """
    handle = _widget(wire.KIND_BUTTON)
    if text is not None:
        _records().append(wire.tx_set_text(handle.id, _text_value("button text", text)))
    if bind is not None:
        if _tpl_depth == 0:
            raise TypeError(
                "kaya: button bind is template-only — a live button's caption "
                "is a constant in all eight bindings (docs/tpl-props-plan.md "
                "F5). Bind inside `with kaya.for_each(c) as row:`; live, pass "
                "text=."
            )
        if isinstance(bind, Signal):
            _records().append(wire.tx_bind_text(handle.id, bind.id))
        elif isinstance(bind, Element):
            _records().append(wire.tx_bind_text_element(handle.id, bind._level()))
        elif isinstance(bind, FieldRef):
            _records().append(
                wire.tx_bind_text_element(handle.id, bind._level(), bind._index)
            )
        else:
            # Python's equivalent of not compiling: raise, rather than
            # bind nothing in silence.
            raise TypeError(
                f"kaya: button bind takes a Signal, the enclosing For's "
                f"element, or one of its fields (row.title), not "
                f"{type(bind).__name__} — inside a case arm project the "
                "field: kaya.button(bind=note.text)"
            )
    if on_click is not None:
        _app._register(handle, wire.OCC_BUTTON_CLICKED, on_click)
    _set_grow(handle, grow)
    return handle


def row(grow=None, spacing=None, align=None, inset=None, stack_when=None):
    """A row container: column turned sideways. `grow` is its flex
    weight; `spacing` its inter-child gap (main axis, DIP, default 8);
    `inset` its own padding.

    `stack_when` stacks the children vertically while the window's SIZE
    CLASS is the named one — a core-evaluated breakpoint, reverting when
    the class is left (docs/adaptive-layout-plan.md D3). The app never
    writes a width."""
    handle = _widget(wire.KIND_ROW)
    if stack_when is not None:
        if stack_when is not COMPACT:
            raise TypeError(
                f"kaya: stack_when takes a size class — kaya.COMPACT is "
                f"the only class today — not {stack_when!r}. The raw-width "
                "breakpoint (stack_below=N) is gone; kaya owns the numbers "
                "(docs/adaptive-layout-plan.md D3)"
            )
        if _tpl_depth > 0:
            raise TypeError(
                "kaya: stack_when is live-only — a breakpoint's setters "
                "name live widgets, and a template row is a blueprint "
                "stamped per entry (docs/adaptive-layout-plan.md D3)"
            )
        _records().append(
            wire.tx_create_breakpoint(
                0,
                wire.SIZE_CLASS_COMPACT,
                1,
                [handle.id, wire.PROP_AXIS, wire.AXIS_VERTICAL],
            )
        )
    _set_grow(handle, grow)
    _set_spacing(handle, spacing)
    _set_align(handle, align)
    _set_inset(handle, inset)
    return _Container(handle)


def checkbox(text=None, checked=None, on_toggle=None, grow=None):
    """A labeled on/off box. The box owns its checked bit: `on_toggle`
    receives the new state (template copies get the stamped keys first)
    and the app folds it into its own model."""
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
    """A progress bar: display-only. `value` is the determinate fraction
    (0..=1); `indeterminate=True` switches to the platform's activity
    mode and the fraction is ignored while it is on."""
    handle = _widget(wire.KIND_PROGRESS)
    if value is not None:
        if isinstance(value, Signal):
            _records().append(wire.tx_bind_value(handle.id, value.id))
        elif isinstance(value, FieldRef):
            _records().append(
                wire.tx_bind_value_element(handle.id, value._level(),
                                           value._index)
            )
        else:
            _records().append(wire.tx_set_value(handle.id, float(value)))
    if indeterminate is not None:
        _records().append(
            wire.tx_set_indeterminate(handle.id, bool(indeterminate)))
    _set_grow(handle, grow)
    return handle


def select(options, selected=0, on_select=None, grow=None):
    """A dropdown select over fixed options; each becomes a label child.
    UNCONTROLLED: the widget owns its selection and reports each USER
    pick to `on_select`; programmatic writes never echo."""
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
    """A radio group over fixed options — `select`'s contract in its
    inline presentation."""
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


def slider(value=None, min=None, max=None, step=None, tick_spacing=None,
           on_change=None, on_commit=None, grow=None):
    """A slider over a numeric range. UNCONTROLLED: the widget owns its
    position and reports each change to `on_change` and each settled
    gesture to `on_commit`, template copies getting the stamped keys
    first. `min`/`max` default to 0..1. `step` is the granularity the
    thumb rests on and `tick_spacing` the distance between drawn ticks,
    in value units (docs/slider-plan.md S1, S5); each divides the range
    evenly and the spacing is a multiple of the step."""
    handle = _widget(wire.KIND_SLIDER)
    if min is not None:
        _records().append(wire.tx_set_min(handle.id, min))
    if max is not None:
        _records().append(wire.tx_set_max(handle.id, max))
    if step is not None:
        _records().append(wire.tx_set_step(handle.id, float(step)))
    if tick_spacing is not None:
        _records().append(
            wire.tx_set_tick_spacing(handle.id, float(tick_spacing)))
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
    if on_commit is not None:
        _app._register(handle, wire.OCC_VALUE_COMMITTED, on_commit)
    _set_grow(handle, grow)
    return handle


def _picker_field(what, value, want):
    """A picker's template source, held to the field TYPE — a Date field
    and an int one share the I64 tag, so nothing below this can tell them
    apart (docs/datetime-plan.md D10)."""
    if value._type is not want:
        raise TypeError(
            f"kaya: {what} binds a {want.__name__} field, not "
            f"{getattr(value._type, '__name__', value._type)}"
        )


def date_picker(value=None, min=None, max=None, on_change=None, grow=None):
    """A date picker over civil dates — `datetime.date`, never an instant
    (docs/datetime-plan.md). UNCONTROLLED: the control owns its value and
    reports each COMMITTED pick to `on_change`, template copies getting the
    stamped keys first. `min`/`max` are the inclusive range; a pick past a
    bound lands on the bound."""
    handle = _widget(wire.KIND_DATE_PICKER)
    if min is not None:
        _records().append(
            wire.tx_set_min_date(handle.id, *_date_parts("min_date", min)))
    if max is not None:
        _records().append(
            wire.tx_set_max_date(handle.id, *_date_parts("max_date", max)))
    if value is not None:
        if isinstance(value, Signal):
            _records().append(wire.tx_bind_date(handle.id, value.id))
        elif isinstance(value, FieldRef):
            _picker_field("a date picker", value, datetime.date)
            _records().append(
                wire.tx_bind_date_element(handle.id, value._level(),
                                          value._index)
            )
        else:
            _records().append(
                wire.tx_set_date(handle.id,
                                 *_date_parts("a date picker's value", value)))
    if on_change is not None:
        _app._register(
            handle, wire.OCC_DATE_CHANGED,
            lambda *args: on_change(*args[:-1], _decode_date_field(args[-1])))
    _set_grow(handle, grow)
    return handle


def time_picker(value=None, step=None, on_change=None, grow=None):
    """A time picker over civil times — `datetime.time`, hours and minutes
    (seconds are not a picker value). `step` is the minute granularity: 1,
    5, 10, 15 or 30, and a pick snaps to it."""
    handle = _widget(wire.KIND_TIME_PICKER)
    if step is not None:
        _records().append(wire.tx_set_minute_step(handle.id, float(step)))
    if value is not None:
        if isinstance(value, Signal):
            _records().append(wire.tx_bind_time(handle.id, value.id))
        elif isinstance(value, FieldRef):
            _picker_field("a time picker", value, datetime.time)
            _records().append(
                wire.tx_bind_time_element(handle.id, value._level(),
                                          value._index)
            )
        else:
            _records().append(
                wire.tx_set_time(handle.id,
                                 *_time_parts("a time picker's value", value)))
    if on_change is not None:
        _app._register(
            handle, wire.OCC_TIME_CHANGED,
            lambda *args: on_change(*args[:-1], _decode_time_field(args[-1])))
    _set_grow(handle, grow)
    return handle


def entry(text=None, on_change=None, grow=None):
    """A single-line text field. UNCONTROLLED: the widget owns its text
    and reports each edit to `on_change`, template copies getting the
    stamped keys first. There is no read-back."""
    handle = _widget(wire.KIND_ENTRY)
    if text is not None:
        _records().append(wire.tx_set_text(handle.id, _text_value("entry text", text)))
    if on_change is not None:
        _app._register(handle, wire.OCC_TEXT_CHANGED, on_change)
    _set_grow(handle, grow)
    return handle


def textarea(text=None, on_change=None, grow=None):
    """A multi-line text editor: the entry's uncontrolled contract over
    the platform's real multi-line editor."""
    handle = _widget(wire.KIND_TEXTAREA)
    if text is not None:
        _records().append(wire.tx_set_text(handle.id, _text_value("textarea text", text)))
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
    elif bind is not None:
        # Without this arm the call binds NOTHING and says nothing — a
        # `cases.case(...)` arm hands over the refined proxy, which is
        # not an `Element`.
        raise TypeError(
            f"kaya: label bind takes a Signal, the enclosing For's element, "
            f"or one of its fields (el.title), not {type(bind).__name__} — "
            "inside a case arm project the field: kaya.label(bind=note.text)"
        )
    _set_grow(handle, grow)
    return handle


def heading(text=None, bind=None, grow=None):
    """A label wearing the heading role: the platform's heading text
    style AND the accessibility heading trait, and on a grouped screen
    the section-header seat (docs/styling-plan.md D4)."""
    return label(text=text, bind=bind, grow=grow).role("heading")


def caption(text=None, bind=None, grow=None):
    """A label wearing the caption role: the platform's footnote text
    tier, and on a grouped screen the section-footer seat."""
    return label(text=text, bind=bind, grow=grow).role("caption")


def image(source=None, grow=None):
    """An image displaying encoded bytes: the toolkit decodes natively,
    and a decode failure renders the placeholder, never a crash. `source`
    is encoded bytes, an `Asset`, a Signal, or an element field."""
    handle = _widget(wire.KIND_IMAGE)
    if source is not None:
        if isinstance(source, Signal):
            _records().append(wire.tx_bind_source(handle.id, source.id))
        elif isinstance(source, FieldRef):
            _records().append(
                wire.tx_bind_source_element(handle.id, source._level(),
                                            source._index)
            )
        elif isinstance(source, (Asset, bytes, bytearray, memoryview)):
            _records().append(
                wire.tx_set_source(handle.id, _blob_of(source))
            )
        else:
            raise TypeError(
                f"kaya: image source takes encoded bytes, an asset the "
                f"app's build shipped (kaya.asset('icons/...')), a Signal "
                f"or an element field, not {type(source).__name__} — text "
                "belongs on kaya.label"
            )
    _set_grow(handle, grow)
    return handle


# The NUMBERS come from the generated wire file, never retyped here
# (tools/check-symbol-parity.py holds the surfaces that copy by hand;
# this is not one).
_PAINTS = {
    "series": wire.PAINT_SERIES,
    "series_fill": wire.PAINT_SERIES_FILL,
    "grid": wire.PAINT_GRID,
    "axis": wire.PAINT_AXIS,
    "ground": wire.PAINT_GROUND,
}
_FILL_RULES = {
    "nonzero": wire.FILL_RULE_NONZERO,
    "even_odd": wire.FILL_RULE_EVEN_ODD,
}
_TEXT_ALIGNS = {
    "start": wire.TEXT_ALIGN_START,
    "middle": wire.TEXT_ALIGN_MIDDLE,
    "end": wire.TEXT_ALIGN_END,
}
_TEXT_BASELINES = {
    "alphabetic": wire.TEXT_BASELINE_ALPHABETIC,
    "middle": wire.TEXT_BASELINE_MIDDLE,
    "top": wire.TEXT_BASELINE_TOP,
    "bottom": wire.TEXT_BASELINE_BOTTOM,
}


def _draw_vocab(table, what, name):
    try:
        return table[name]
    except (KeyError, TypeError):
        raise ValueError(
            f"kaya: {name!r} is not a canvas {what}; the vocabulary is "
            + ", ".join(sorted(table))
        ) from None


class Draw:
    """The drawing scope's recorder: the calls read as immediate-mode
    drawing, but ONE record is submitted when the scope closes
    (docs/canvas-plan.md §2.1)."""

    def __init__(self, viewbox):
        self.viewbox = viewbox
        self._ops = []

    def _op(self, code, *operands):
        self._ops.append(code)
        self._ops.extend(operands)
        return self

    def move_to(self, x, y):
        """Start a subpath at (x, y)."""
        return self._op(wire.DRAW_OP_MOVE_TO, float(x), float(y))

    def line_to(self, x, y):
        """Extend the current subpath to (x, y)."""
        return self._op(wire.DRAW_OP_LINE_TO, float(x), float(y))

    def close(self):
        """Close the current subpath."""
        return self._op(wire.DRAW_OP_CLOSE)

    def polyline(self, points):
        """`move_to` the first point and `line_to` the rest."""
        for i, (x, y) in enumerate(points):
            if i == 0:
                self.move_to(x, y)
            else:
                self.line_to(x, y)
        return self

    def stroke(self, paint, width=1.0):
        """Stroke the built path and clear it. `width` is in
        device-independent points and does NOT carry the viewbox stretch
        (docs/canvas-plan.md §3.2)."""
        return self._op(wire.DRAW_OP_STROKE,
                        _draw_vocab(_PAINTS, "paint role", paint),
                        float(width))

    def fill(self, paint, rule="nonzero"):
        """Fill the built path and clear it."""
        return self._op(wire.DRAW_OP_FILL,
                        _draw_vocab(_PAINTS, "paint role", paint),
                        _draw_vocab(_FILL_RULES, "fill rule", rule))

    def font(self, size, asset="", weight=400):
        """Select the face for subsequent text ops. `asset` is an
        ordinary asset name; `""` is kaya's own embedded default face."""
        return self._op(wire.DRAW_OP_FONT, str(asset), float(size),
                        int(weight))

    def text(self, x, y, s, paint="axis", align="start",
             baseline="alphabetic"):
        """Draw ONE LINE with its anchor at (x, y). A line break in `s`
        is refused by the core (docs/canvas-plan.md §3.3)."""
        return self._op(wire.DRAW_OP_TEXT, float(x), float(y),
                        _draw_vocab(_PAINTS, "paint role", paint),
                        _draw_vocab(_TEXT_ALIGNS, "text align", align),
                        _draw_vocab(_TEXT_BASELINES, "text baseline",
                                    baseline),
                        str(s))


class _DrawScope:
    """`_Handle.draw`'s with-block: records through `Draw`, submits one
    `set_drawing` on exit. Nothing is emitted when the body raises."""

    def __init__(self, handle, keys):
        self._handle = handle
        self._keys = list(keys)
        self._draw = None

    def __enter__(self):
        viewbox = _canvas_viewboxes.get(self._handle.id)
        if viewbox is None:
            raise RuntimeError(
                f"kaya: draw() on widget {self._handle.id} — that is not a "
                "canvas this app declared; a drawing is a declaration "
                "against the canvas it draws on (docs/canvas-plan.md §2.1)"
            )
        self._draw = Draw(viewbox)
        return self._draw

    def __exit__(self, exc_type, exc, tb):
        if exc_type is not None:
            return False
        w, h = self._draw.viewbox
        ops = self._draw._ops
        _records().append(wire.tx_set_drawing(
            self._handle.id, w, h, len(ops), len(self._keys),
            [*self._keys, *ops],
        ))
        return False


def _size_policy(handle, fixed, on_draw, on_tick):
    """WHAT THIS CANVAS DOES WITH A TRACK THAT IS NOT ITS VIEWBOX
    (docs/canvas-plan.md §3.2.1). `scale` is spelled by declaring
    nothing. THE HANDLER IS THE DECLARATION: registering it and putting
    the policy on the wire are ONE act."""
    declared = [k for k, v in (("fixed", fixed), ("on_draw", on_draw),
                               ("on_tick", on_tick)) if v]
    if not declared:
        return
    if len(declared) > 1:
        # Simultaneous keywords have no order, so two policies is a
        # question this cannot answer.
        raise ValueError(
            "kaya: a canvas declares ONE size policy, not "
            + " and ".join(declared)
            + " (docs/canvas-plan.md §3.2.1)"
        )
    if isinstance(handle, Node):
        raise RuntimeError(
            "kaya: the size policy is a LIVE-ZONE declaration in this "
            "slice — a canvas inside a row template keeps `scale` "
            "(docs/deferred.md, the template-zone size policy entry)"
        )
    if fixed:
        policy = wire.SIZE_POLICY_FIXED
    else:
        policy = (wire.SIZE_POLICY_REDRAW if on_draw is not None
                  else wire.SIZE_POLICY_TICK)
        _app._register_draw(handle, policy, on_draw or on_tick)
    _records().append(wire.tx_set_size_policy(handle.id, policy))


def canvas(viewbox, grow=None, fixed=None, on_draw=None, on_tick=None):
    """A drawing surface. `viewbox` is the (width, height) coordinate
    system the ops are written in AND the canvas's natural size in
    points (docs/canvas-plan.md §3.2). Declare what it draws with
    `with handle.draw() as d:`.

    WHAT IT DOES WITH A TRACK THAT IS NOT ITS VIEWBOX is one of three
    declarations, and declaring NOTHING is `scale` — refitted uniformly
    into whatever track layout hands over (§3.2.1):

    - `fixed=True` refuses coercion: rastered at the viewbox and placed
      in the track without adapting to it.
    - `on_draw=fn` — `fn(d, size)` draws for the size layout assigned.
    - `on_tick=fn` — `fn(d, size, time)`, once a frame, with the frame's
      time in seconds. THE TIME IS THE PLATFORM'S: a guest reading its
      own clock re-imports the jitter the frame clocks remove.

    Both handlers run inside a transaction THE BINDING opens
    (tools/check-ambient-tx.py) and never reach the app."""
    w, h = viewbox
    handle = _widget(wire.KIND_CANVAS)
    _canvas_viewboxes[handle.id] = (float(w), float(h))
    _set_grow(handle, grow)
    _size_policy(handle, fixed, on_draw, on_tick)
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


def _window_props(window, title, width, height, veto_close, dirty,
                  panes, sections_presentation, inset):
    """The window construct's props — ONE place, so the scene scope and
    the live call cannot drift apart."""
    records = _records()
    if title is not None:
        records.append(wire.tx_set_window_title(window, str(title)))
    if veto_close is not None:
        records.append(wire.tx_set_window_veto_close(window, bool(veto_close)))
    # `dirty` is ORTHOGONAL to `veto_close`: either rides this construct
    # without the other (App.window).
    if dirty is not None:
        records.append(wire.tx_set_window_dirty(window, bool(dirty)))
    if panes is not None:
        records.append(wire.tx_set_window_panes(window, int(panes)))
    if sections_presentation is not None:
        records.append(wire.tx_set_window_sections_presentation(
            window, int(sections_presentation)))
    # float() so it lands as the F64 the prop is typed as — an I64 is
    # refused for its TYPE, a true complaint about the wrong mistake.
    if inset is not None:
        records.append(wire.tx_set_window_inset(window, float(inset)))
    if width is not None or height is not None:
        if width is None or height is None:
            raise ValueError("kaya: window width and height travel together")
        records.append(wire.tx_set_window_width(window, float(width)))
        records.append(wire.tx_set_window_height(window, float(height)))


class _LiveWindow:
    """What the window construct returns when it was called LIVE — its
    props are already in the ambient transaction.

    It exists to make the other spelling's mistake LOUD: `with
    app.window(dirty=True):` inside a handler would otherwise report
    "transactions do not nest", which is true and unhelpful.
    """

    def __enter__(self):
        raise RuntimeError(
            "kaya: the window construct's props are already in this "
            "transaction — inside a handler (or `with app.build():`) the "
            "construct is a PLAIN CALL, `app.window(dirty=True)`. The "
            "`with` form is the scene scope: it opens a transaction of "
            "its own and mounts a root, which a handler must not do."
        )

    def __exit__(self, exc_type, exc, tb):
        return False


class _TxScope:
    def __init__(self, app, mount_on_exit, title=None, width=None, height=None,
                 window=0, create=False, veto_close=None, dirty=None,
                 panes=None,
                 sections_presentation=None, inset=None, push=False,
                 intercept_back=None, on_popped=None, on_back=None,
                 section=False, on_selected=None, host_window=0,
                 symbol=None):
        # FIRST, so __del__ below can read them even if this __init__
        # raises on one of its own conversions.
        self._entered = False
        self._app = app
        self._mount = mount_on_exit
        self._title = title
        self._width = width
        self._height = height
        self._window = int(window)
        # The window a SECTION scope adds its section into — 0 for the
        # primary, an aux window's id otherwise.
        self._host_window = int(host_window)
        self._create = create
        self._veto_close = veto_close
        self._dirty = dirty
        self._panes = panes
        self._sections_presentation = sections_presentation
        self._inset = inset
        self._push = push
        self._intercept_back = intercept_back
        self._on_popped = on_popped
        self._on_back = on_back
        self._section = section
        self._on_selected = on_selected
        # Already through _symbol_value at the add_section call site.
        self._symbol = symbol

    def __del__(self):
        # A construct BUILT AND NEVER ENTERED emits nothing and says
        # nothing. Guarded because __del__ can run while the interpreter
        # is tearing stderr down.
        if self._entered:
            return
        try:
            print(
                "kaya: a window construct was built and never used — its "
                "attributes went nowhere. `app.window(...)` as a plain "
                "call is the LIVE spelling and needs a transaction "
                "already open (inside a handler, or `with app.build():`); "
                "outside one it is the SCENE scope and needs its `with`.",
                file=sys.stderr,
            )
        except Exception:
            pass

    def __enter__(self):
        global _tx, _pending_root, _recording, _journal
        self._entered = True
        _require_app_thread()
        if self._section:
            # A section's scene scope: it may open inside the ambient
            # build, and the body's root mounts INTO the section on exit.
            self._nested = _tx is not None
            if not self._nested:
                _tx = []
                _journal = {}
            self._outer = (_recording, _pending_root)
            _recording = True
            _pending_root = None
            _records().append(wire.tx_add_section(self._host_window, self._window))
            if self._title is not None:
                _records().append(
                    wire.tx_set_section_title(self._window, str(self._title)))
            if self._symbol is not None:
                _records().append(
                    wire.tx_set_section_symbol(self._window, self._symbol))
            # Per-section, NOT one-shot; a programmatic select never
            # fires it.
            if self._on_selected is not None:
                self._app._section_selected[self._window] = self._on_selected
            return self
        if self._push:
            # UNLIKE EVERY OTHER SCOPE this one NESTS inside an open
            # transaction — pushes happen from click handlers — so the
            # records join the same commit and only the root-tracking is
            # scoped.
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
            # The popped registration retires with the one pop; the back
            # one fires per request while armed.
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
        _window_props(
            self._window, self._title, self._width, self._height,
            self._veto_close, self._dirty, self._panes,
            self._sections_presentation, self._inset)
        return self

    def __exit__(self, exc_type, exc, tb):
        global _tx, _recording, _journal, _pending_root
        if self._section or self._push:
            # Submit only if this scope opened its own transaction:
            # inside a handler the ambient build owns commit and
            # rollback.
            root = _pending_root
            _recording, _pending_root = self._outer
            if exc_type is not None:
                if not self._nested:
                    _tx = None
                    _journal = None
                return False
            if root is None:
                raise RuntimeError(
                    "kaya: push_entry()/add_section() body declared no "
                    "root container")
            _tx.append(wire.tx_mount(self._window, root.id))
            if not self._nested:
                records, _tx = _tx, None
                _journal = None
                if records:
                    runtime.submit(*records)
            return False
        global _tpl_depth
        _recording = False
        records, _tx = _tx, None
        journal, _journal = _journal, None
        abandoned, _open_traces[:] = list(_open_traces), []
        # An abandoned transaction must not leave a menu scope armed for
        # the next one.
        _menu_scopes[:] = []
        if exc_type is not None or abandoned:
            # Any abort resets the zone state: the surviving app must
            # not inherit a poisoned template depth or parent stack.
            _tpl_depth = 0
            _parents[:] = []
            _for_stack[:] = []
            _for_collections[:] = []
        if exc_type is not None:
            # The records are abandoned; the mirrors abandon them too.
            for restore in journal.values():
                restore()
            return False
        if abandoned:
            # A break (or early return) left a For template open: the
            # body must run to completion — it authors the blueprint, it
            # does not iterate entries.
            for restore in journal.values():
                restore()
            raise RuntimeError(
                "kaya: a `for t in coll:` template never closed — the "
                "loop body must run to completion (no break/return); "
                "conditional rendering is kaya.when"
            )
        if self._mount and _pending_root is not None:
            # A props-only body is legal (the sections shape) — nothing
            # mounts, nothing errors.
            records.append(wire.tx_mount(self._window, _pending_root.id))
        if records:
            runtime.submit(*records)
        return False


class App:
    def __init__(self):
        global _app
        # No "node" space: template nodes draw from "widget" (DESIGN.md,
        # Binding conventions).
        self._counters = {"signal": 0, "widget": 0, "collection": 0,
                          "alert": 0, "menu_item": 0, "file_dialog": 0,
                          "clipboard": 0}
        # The wire routes by path_len, not by number, so two dicts.
        self._widget_handlers = {}
        self._alert_handlers = {}
        self._file_dialog_handlers = {}
        # One-shot, keyed by request id (the alert's grammar).
        self._clipboard_handlers = {}
        # Menu items are their own id space, so their own table.
        self._menu_handlers = {}
        # Per-entry navigation handlers, keyed by entry surface id.
        self._entry_popped = {}
        self._back_requested = {}
        self._section_selected = {}
        # Per-window lifecycle handlers, keyed by window id.
        self._close_requested = {}
        self._window_closed = {}
        # NOT one-shot: a history is walked as often as the user likes.
        self._undone = {}
        self._redone = {}
        # By core id, for the undo path: an `undone` payload names them
        # rather than handing back handles.
        self._collections = {}
        self._signals = {}
        self._node_handlers = {}
        # Its own table because these do not fold an occurrence into app
        # state: they answer the ask with a drawing the guest never sees
        # (docs/canvas-plan.md §3.2.1).
        self._draw_handlers = {}
        # THE ONLY STATE HERE TOUCHED FROM ANOTHER THREAD, and the only
        # reason App carries a lock.
        self._post_lock = threading.Lock()
        self._posted = []
        _app = self

    def _next(self, space):
        self._counters[space] += 1
        return self._counters[space]

    def _register(self, handle, kind, fn):
        if isinstance(handle, Node):
            self._node_handlers[(kind, handle.id)] = fn
        else:
            self._widget_handlers[(kind, handle.id)] = fn

    def _register_draw(self, handle, policy, fn):
        """The registration half of `canvas(on_draw=)`/`(on_tick=)`.

        THE HANDLER IS WIDENED HERE, never switched on the record kind: a
        TICK canvas is a REDRAW canvas too — the core asks it once, as a
        draw_requested, before its first frame — so the answer path must
        have ONE call shape (docs/canvas-plan.md, "WIDEN THE HANDLER AT
        REGISTRATION")."""
        if policy == wire.SIZE_POLICY_REDRAW:
            drawn = fn
            fn = lambda d, size, _time: drawn(d, size)  # noqa: E731
        self._draw_handlers[handle.id] = (handle, fn)

    def _answer_canvas(self, ident, kind, values):
        """ANSWER ONE CANVAS ASK: draw at the size the core assigned and
        submit that drawing (docs/canvas-plan.md §3.2.1). The binding
        opens the transaction (tools/check-ambient-tx.py) and the ask
        never reaches the app. The assigned size BECOMES the canvas's
        viewbox."""
        seat = self._draw_handlers.get(ident)
        if seat is None:
            return
        handle, fn = seat
        size = (float(values[0]), float(values[1]))
        # ONE CALL SHAPE either way — `_register_draw` widened an
        # on_draw handler to take the time, so nothing here reads the
        # record kind.
        time = float(values[2]) if kind == wire.OCC_TICK else 0.0

        def answer():
            _canvas_viewboxes[ident] = size
            with handle.draw() as d:
                fn(d, size, time)
        self._dispatch(answer)

    def _register_history(self, window_id, on_undone, on_redone):
        """Seat a surface's two history handlers. Per window and NOT
        one-shot: both outlive every step."""
        if on_undone is not None:
            self._undone[int(window_id)] = on_undone
        if on_redone is not None:
            self._redone[int(window_id)] = on_redone

    def create_window(self, window_id, title=None, width=None, height=None,
                      veto_close=None, dirty=None, panes=None,
                      sections_presentation=None, inset=None,
                      on_close_requested=None, on_closed=None,
                      on_undone=None, on_redone=None):
        """An auxiliary surface's scene scope: create_window plus its
        props on entry, and the single top-level container mounts INTO IT
        on exit. Capability-gated — a phone host rejects at the root.

        on_close_requested() fires per chrome close while veto_close is
        armed, and NOTHING HAS CLOSED — answer with kaya.destroy_window
        to agree. on_closed() fires when a non-veto auxiliary is
        chrome-closed and retires with it. The prop set is App.window's,
        called again with this surface's id."""
        if on_close_requested is not None:
            self._close_requested[int(window_id)] = on_close_requested
        if on_closed is not None:
            self._window_closed[int(window_id)] = on_closed
        self._register_history(window_id, on_undone, on_redone)
        return _TxScope(
            self, mount_on_exit=True, window=window_id, create=True,
            title=title, width=width, height=height, veto_close=veto_close,
            dirty=dirty, panes=panes,
            sections_presentation=sections_presentation, inset=inset)

    def window(self, title=None, width=None, height=None, veto_close=None,
               dirty=None, panes=None, sections_presentation=None,
               inset=None, on_close_requested=None, on_closed=None,
               on_undone=None, on_redone=None, window_id=0):
        """The scene scope: an ambient transaction whose single top-level
        container mounts into the default window on exit. `title` names
        the surface; `width`/`height` request content size in DIP
        (advisory); `veto_close` arms the close-veto class;
        `sections_presentation` is the ADVISORY sections hint;
        `window_id` names the surface the attributes are about.

        `panes` is the CEILING on how many of this window's stack entries
        present side by side: 1 is the serial stack, 2 and 3 are columns
        on a window wide enough, the shallowest shed first as it narrows
        (docs/multicolumn-plan.md). The stack's order is the priority
        order; the root refuses 0 and anything above 3.

        `inset` is the window's CONTENT INSET in layout units — LAYOUT,
        not appearance (docs/styling-plan.md D3), 16 by default and 0 for
        full bleed. HONORED UNCONDITIONALLY, unlike `width`/`height`; a
        platform's SAFE AREA is a separate fact and is not removed by it.

        `dirty` says this surface holds UNSAVED WORK
        (docs/dirty-plan.md D2/D4). STATE, NOT CHROME, and it ARMS
        NOTHING (D3): "unsaved changes, close anyway?" is `veto_close`
        plus `kaya.show_alert`. NOTHING INFERS IT.

        THE LIVE SPELLING IS THIS SAME CONSTRUCT, CALLED AGAIN, without
        the `with` (DESIGN.md, Binding conventions).

        on_undone(label, delta) fires each time kaya routes an undo at
        this surface, with the group's label — EMPTY for a typing episode
        kaya took back itself — and the whole restored state. Per window
        and PERSISTENT. on_redone is its twin; neither fires for a
        native-tier undo (docs/undo-plan.md A6)."""
        window_id = int(window_id)
        if on_close_requested is not None:
            self._close_requested[window_id] = on_close_requested
        if on_closed is not None:
            self._window_closed[window_id] = on_closed
        self._register_history(window_id, on_undone, on_redone)
        if _tx is not None:
            # THE LIVE FORM: a transaction is already open, so the props
            # join it and there is nothing to enter. The thread check is
            # the one `__enter__` does (see _require_app_thread).
            _require_app_thread()
            _window_props(window_id, title, width, height, veto_close,
                          dirty, panes, sections_presentation, inset)
            return _LiveWindow()
        return _TxScope(
            self, mount_on_exit=True, window=window_id,
            title=title, width=width, height=height,
            veto_close=veto_close, dirty=dirty, panes=panes,
            sections_presentation=sections_presentation, inset=inset)

    def build(self):
        """An ambient transaction without the mount — for mutations
        outside handlers."""
        return _TxScope(self, mount_on_exit=False)

    def push_entry(self, entry_id, title=None, intercept_back=None,
                   on_popped=None, on_back=None):
        """A navigation entry's scene scope (DESIGN.md, Navigation): the
        single top-level container mounts INTO IT on exit. Entry ids are
        guest-allocated in the shared surface namespace.

        on_popped() fires when the user's back affordance pops THIS entry
        natively (a programmatic kaya.pop_entry does not fire it) and
        retires with the one pop. on_back() fires per back request while
        intercept_back is armed, and NOTHING HAS POPPED — answer with
        kaya.pop_entry to agree."""
        return _TxScope(
            self, mount_on_exit=True, window=entry_id, push=True,
            title=title, intercept_back=intercept_back,
            on_popped=on_popped, on_back=on_back)

    def add_section(self, section_id, title=None, symbol=None,
                    on_selected=None, window=0):
        """A section's scene scope (DESIGN.md, Sections): the single
        top-level container mounts INTO IT on exit. The set is
        append-only and switching is SELECTION, not lifecycle.

        `symbol=` is the switcher item's SEMANTIC ICON, REFUSED HERE and
        not at the `with`: a raise from __enter__ would point at the
        block rather than at the word.

        on_selected() fires each time the USER switches to this section,
        NOT one-shot. A programmatic kaya.select_section does not fire
        it."""
        return _TxScope(
            self, mount_on_exit=True, window=section_id, section=True,
            title=title, symbol=None if symbol is None else _symbol_value(symbol),
            on_selected=on_selected, host_window=window)

    def menu(self, label, enabled=None, icon=None, symbol=None, window=0):
        """A top-level menu in `window`'s command catalog (DESIGN.md,
        Menus). Yields the retained handle, which append() reopens at any
        time; disabling the menu disables its subtree."""
        it = _menu_create(wire.MENU_KIND_MENU, label)
        _records().append(wire.tx_menubar_append(int(window), it.id))
        if enabled is not None:
            it.enabled(enabled)
        if icon is not None:
            it.icon(icon)
        if symbol is not None:
            it.symbol(symbol)
        return _MenuScope(("item", it.id), shortcut_ok=True, value=it)

    def radio_group(self, label, value=None, enabled=None, icon=None,
                    symbol=None, on_select=None, window=0):
        """A BAR-LEVEL radio group, declaring only kaya.option children.
        `value` is the selected 0-based index; programmatic writes are
        quiet, and on_select receives each USER pick's new index."""
        it = _menu_create(wire.MENU_KIND_RADIO_GROUP, label)
        _records().append(wire.tx_menubar_append(int(window), it.id))
        if enabled is not None:
            it.enabled(enabled)
        if icon is not None:
            it.icon(icon)
        if symbol is not None:
            it.symbol(symbol)
        if on_select is not None:
            self._menu_handlers[(wire.OCC_MENU_VALUE_CHANGED, it.id)] = on_select
        # value= lands at block exit, AFTER the option children: the
        # index addresses options, and the root judges its domain at
        # the record.
        on_exit = (lambda: it.value(value)) if value is not None else None
        return _MenuScope(("item", it.id), shortcut_ok=True, value=it,
                          on_exit=on_exit)

    def _dispatch(self, handler, *args):
        """One handler dispatch, INSIDE an ambient transaction. An
        exception crossing the build boundary — which rolled the mirrors
        back and dropped the records — is logged and the loop moves on;
        non-Exception aborts (KeyboardInterrupt) still propagate.

        EVERY occurrence goes through here, LIFECYCLE ones included: a
        bare call leaves `kaya.destroy_window` inside an
        on_close_requested with no ambient transaction.
        """
        try:
            with self.build():
                handler(*args)
        except Exception:
            traceback.print_exc()
            print(
                "kaya: handler raised (transaction rolled back)",
                file=sys.stderr,
            )

    def post(self, fn, *args):
        """Run fn as a transaction on the app thread, soon. THE ONE method
        safe to call from another thread.

        A posted callable runs in its OWN transaction, after whatever is
        running now, so posting from inside a handler queues for AFTER
        and never nests.
        """
        with self._post_lock:
            self._posted.append((fn, args))
        # The app thread may be parked in C waiting on the ring. Posted
        # work never enters that ring, so this is the only way it hears
        # about it.
        runtime.wake()

    def _absorb_undo(self, delta):
        """Fold an undo's payload into the collection mirrors; the
        payload is core-authoritative, so nothing here re-derives.

        BEFORE THE HANDLER AND WITHOUT ONE: an app that registered no
        on_undone still has a mirror. The `signals` run is read here as
        well as handed to the app, because the binding caches the last
        written value to skip no-op DERIVED writes and an undo moves
        signals behind that cache.

        NO DERIVED RECOMPUTE, DELIBERATELY: a derived signal's write rode
        the SAME transaction as its cause, so the core has already
        restored it, and this runs off the occurrence loop with no
        ambient transaction to write into (docs/deferred.md carries the
        retracted "a derived signal goes stale after an undo" defect and
        its one residual).
        """
        for signal_id, value in delta.signals:
            sig = self._signals.get(signal_id)
            if sig is not None:
                sig._mirror = value
        for coll_id, path, key, state in delta.entries:
            coll = self._collections.get(coll_id)
            if coll is None:
                continue
            table = coll._instances.setdefault(tuple(path), {})
            if state is None:
                table.pop(key, None)
                # The core tore the copy down, taking descendant
                # collection instances with it; the mirrors follow.
                prefix = tuple(path) + (key,)
                for child in coll._children:
                    child._purge(prefix)
                continue
            variant, fields = state
            table[key] = coll._decode(variant, fields, table.get(key))
        for coll_id, path, keys in delta.orders:
            coll = self._collections.get(coll_id)
            if coll is None:
                continue
            table = coll._instances.get(tuple(path))
            if table is None:
                continue
            # Insertion-ordered dicts have no move, so the named keys
            # are re-added in order; anything unnamed stays at the end.
            for key in list(keys) + [k for k in table if k not in keys]:
                if key in table:
                    table[key] = table.pop(key)

    def _drain_posted(self):
        """Run everything posted, each as its own transaction, in order.

        The batch is taken and the lock released BEFORE any of it runs,
        so a callable that posts again lands in the NEXT batch — holding
        the lock across the calls would starve the occurrence loop.
        """
        with self._post_lock:
            batch, self._posted = self._posted, []
        for fn, args in batch:
            self._dispatch(fn, *args)

    def _dispatch_loop(self):
        global _app_thread
        _app_thread = threading.get_ident()
        while True:
            # Draining at the TOP is what makes a wake sufficient:
            # whatever brought this thread back, it looks here first.
            self._drain_posted()
            occurrence = runtime.next_occurrence()
            if occurrence is None:
                return  # shutdown
            if occurrence is runtime.WOKEN:
                continue  # drained at the top of the next turn
            kind, ident, keys, payload = occurrence
            if kind == wire.OCC_CLOSE_REQUESTED:
                handler = self._close_requested.get(ident)
                if handler is not None:
                    self._dispatch(handler)
                continue
            if kind == wire.OCC_WINDOW_CLOSED:
                # One-shot: the window is gone.
                self._close_requested.pop(ident, None)
                handler = self._window_closed.pop(ident, None)
                if handler is not None:
                    self._dispatch(handler)
                continue
            if kind == wire.OCC_ENTRY_POPPED:
                # One-shot: the entry is gone.
                self._back_requested.pop(ident, None)
                handler = self._entry_popped.pop(ident, None)
                if handler is not None:
                    self._dispatch(handler)
                continue
            if kind == wire.OCC_SECTION_SELECTED:
                # NOT one-shot: the user can return any number of times
                # (ident is the section; the window rides as payload).
                handler = self._section_selected.get(ident)
                if handler is not None:
                    self._dispatch(handler)
                continue
            if kind == wire.OCC_BACK_REQUESTED:
                handler = self._back_requested.get(ident)
                if handler is not None:
                    self._dispatch(handler)
                continue
            if kind == wire.OCC_ALERT_RESULT:
                # One-shot: the registration retires with the result.
                handler = self._alert_handlers.pop(ident, None)
                if handler is not None:
                    # payload is the parsed u32 choice.
                    self._dispatch(handler, payload)
                continue
            if kind == wire.OCC_FILE_DIALOG_RESULT:
                # One-shot. payload is the decoder's list of (handle,
                # name, local_path) triples; EMPTY IS CANCEL.
                handler = self._file_dialog_handlers.pop(ident, None)
                if handler is not None:
                    self._dispatch(handler, [
                        PickedFile(h, n, p) for (h, n, p) in payload])
                continue
            if kind == wire.OCC_CLIPBOARD_RESULT:
                # One-shot. EMPTY IS THE UNIVERSAL NO and arrives as
                # None — denied, unfocused, absent and unaccepted alike.
                handler = self._clipboard_handlers.pop(ident, None)
                if handler is not None:
                    self._dispatch(handler, _representation(payload))
                continue
            if kind in (wire.OCC_UNDONE, wire.OCC_REDONE):
                # ident is the window whose ledger moved; NOT one-shot.
                # THE MIRRORS FOLLOW FIRST, and unconditionally: an undo
                # moved core state without a transaction, so a model read
                # after one is stale otherwise — including in an app that
                # registered no handler.
                label, signals, texts, entries, orders = payload
                delta = UndoDelta(signals, texts, entries, orders)
                self._absorb_undo(delta)
                table = self._undone if kind == wire.OCC_UNDONE else self._redone
                handler = table.get(ident)
                if handler is not None:
                    self._dispatch(handler, label, delta)
                continue
            if kind in (wire.OCC_DRAW_REQUESTED, wire.OCC_TICK):
                # ANSWERED HERE AND NEVER DISPATCHED TO THE APP. keys is
                # empty: the core asks only LIVE canvases in this slice
                # (docs/deferred.md).
                self._answer_canvas(ident, kind, payload)
                continue
            if kind in (wire.OCC_MENU_ACTIVATED, wire.OCC_MENU_TOGGLED,
                        wire.OCC_MENU_VALUE_CHANGED):
                # Their own id space, so neither widget nor node ids can
                # collide. Node-anchored context items pass the stamped
                # copy's keys first; toggles append the new state, radio
                # groups the new 0-based index.
                handler = self._menu_handlers.get((kind, ident))
                if handler is None:
                    continue
                args = list(keys)
                if kind == wire.OCC_MENU_TOGGLED:
                    args.append(payload)
                elif kind == wire.OCC_MENU_VALUE_CHANGED:
                    args.append(int(payload))
                try:
                    with self.build():
                        handler(*args)
                except Exception:
                    traceback.print_exc()
                    print(
                        "kaya: handler raised (transaction rolled back)",
                        file=sys.stderr,
                    )
                continue
            if keys:
                handler = self._node_handlers.get((kind, ident))
            else:
                handler = self._widget_handlers.get((kind, ident))
            if handler is None:
                continue
            args = list(keys)
            if kind == wire.OCC_PASTED:
                # A paste rides a click tag verbatim, so it arrives on
                # the ordinary widget/node path. Never empty: a paste
                # that delivered nothing is not an occurrence.
                args.append(_representation(payload))
            elif kind == wire.OCC_DROPPED:
                # A drop rides the same tag with four more words
                # (docs/dnd-plan.md D1).
                args.append(_dropped(payload))
            elif kind == wire.OCC_DRAG_ENDED:
                # None is a cancelled or refused drag, not an error.
                args.append(_operation(payload))
            elif payload is not None:
                args.append(payload)
            self._dispatch(handler, *args)

    def run(self):
        """Block until the app ends; returns the exit code. On the
        desktops the calling thread (the process main thread) enters the
        core and a spawned thread dispatches occurrences; on the hosted
        platforms the caller IS the app thread and dispatch happens here
        (docs/python-mobile-plan.md §D2)."""
        if runtime.HOSTED_ENTRY:
            # Exit code 0: there is no process to hand a status to
            # (docs/go-mobile-plan.md §D5).
            self._dispatch_loop()
            return 0
        app_thread = threading.Thread(target=self._dispatch_loop)
        app_thread.start()
        code = runtime.run()
        app_thread.join()
        return code
