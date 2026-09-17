"""kaya's idiomatic surface for Python: the structural core plus the
tier-1 sugar (DESIGN.md, "the shape of an app").
"""

from __future__ import annotations

import dataclasses
import datetime
import enum
import io
import operator
import pathlib
import sys
import threading
import traceback
import types
from collections.abc import Callable, Iterator, Mapping, Sequence
from typing import (IO, Any, Generic, Literal, NoReturn, TypeVar, cast,
                    overload)

from . import runtime
from . import wire

#: A collection's element type: the dataclass a record collection was
#: declared with, or `str` for a scalar one.
T = TypeVar("T")
#: A signal's value.
V = TypeVar("V")
#: A derived value: what a `compute` answers.
R = TypeVar("R")
#: A prop setter's own handle, so a chain keeps the zone's type.
H = TypeVar("H", bound="_Handle")


class KayaError(Exception):
    """Base for every kaya-specific failure. Mixed into the builtin the
    call site already raises (state -> RuntimeError, a wrong argument
    type -> TypeError, a bad-but-right-typed value -> ValueError, a
    missing field or collection key -> KeyError), so every existing
    `except RuntimeError`/`TypeError`/`ValueError`/`KeyError` keeps
    working unchanged, and `except kaya.KayaError` catches all of them."""


class KayaStateError(KayaError, RuntimeError):
    """No ambient transaction, the wrong thread, a transaction already
    closed — a state failure."""


class KayaTypeError(KayaError, TypeError):
    """The wrong Python type for an argument."""


class KayaValueError(KayaError, ValueError):
    """A right-typed but out-of-domain value: an unknown role or
    symbol, a range a widget refuses."""


class KayaKeyError(KayaError, KeyError):
    """A missing record field or collection key."""


# The wire-representable field types; any other field type is guest-only.
# bool before int — bool IS an int in Python. A date and a time ride the
# I64 tag in packed decimal (docs/datetime-plan.md D2/D10).
_WIRE_TYPES: list[tuple[type, int]] = [
               (bool, wire.VALUE_BOOL), (int, wire.VALUE_I64),
               (float, wire.VALUE_F64), (str, wire.VALUE_STR),
               (bytes, wire.VALUE_BLOB), (datetime.date, wire.VALUE_I64),
               (datetime.time, wire.VALUE_I64)]


def _wire_tag(py_type: object) -> int | None:
    for ty, tag in _WIRE_TYPES:
        if py_type is ty:
            return tag
    return None


def _encode_blob_field(value: bytes) -> wire.BlobHandle:
    """A blob field's wire value; handles are single-submit, so every
    mutation carrying a blob field re-registers."""
    return wire.BlobHandle(runtime.register_blob(value))


def _date_parts(what: str, value: object) -> tuple[int, int, int]:
    """A civil date's components. `datetime.datetime` is refused though it
    IS a `datetime.date`: a picker holds no instant, and dropping the time
    silently is the zone-conversion bug genre (docs/datetime-plan.md §0)."""
    if isinstance(value, datetime.datetime) or not isinstance(value, datetime.date):
        raise KayaTypeError(
            f"kaya: {what} is a datetime.date (year, month, day), not "
            f"{type(value).__name__} — a picker carries civil components, "
            "never an instant"
        )
    return value.year, value.month, value.day


def _time_parts(what: str, value: object) -> tuple[int, int]:
    """A civil time's hour and minute; seconds are not a picker value (D3)."""
    if not isinstance(value, datetime.time):
        raise KayaTypeError(
            f"kaya: {what} is a datetime.time (hour, minute), not "
            f"{type(value).__name__}"
        )
    return value.hour, value.minute


def _encode_date_field(value: datetime.date) -> int:
    return wire.pack_date(*_date_parts("a Date field", value))


def _encode_time_field(value: datetime.time) -> int:
    return wire.pack_time(*_time_parts("a Time field", value))


def _decode_date_field(packed: int) -> datetime.date:
    return datetime.date(*wire.unpack_date(packed))


def _decode_time_field(packed: int) -> datetime.time:
    return datetime.time(*wire.unpack_time(packed))


def _identity(value: Any) -> Any:
    return value


# Per-FIELD-TYPE codecs: the tag alone cannot tell a Date field from an
# int one (both are I64 on the wire).
_FIELD_ENCODERS: dict[Any, Callable[[Any], Any]] = {
    bytes: _encode_blob_field, datetime.date: _encode_date_field,
    datetime.time: _encode_time_field}
_FIELD_DECODERS: dict[Any, Callable[[Any], Any]] = {
    datetime.date: _decode_date_field,
    datetime.time: _decode_time_field}


def _wire_scalar(value: Any) -> Any:
    """A signal's value on the wire: a date or a time packs, everything
    else travels as itself."""
    if isinstance(value, datetime.datetime):
        raise KayaTypeError(
            "kaya: a signal carries a civil date or time, not a "
            "datetime.datetime — a picker holds no instant "
            "(docs/datetime-plan.md §0)"
        )
    if isinstance(value, datetime.date):
        return wire.pack_date(value.year, value.month, value.day)
    if isinstance(value, datetime.time):
        return wire.pack_time(value.hour, value.minute)
    return value


def _text_value(what: str, text: object) -> str:
    """The UTF-8 wall: text properties are str, never bytes — image
    bytes have their own channel."""
    if not isinstance(text, str):
        raise KayaTypeError(
            f"kaya: {what} takes str, not {type(text).__name__} — encoded "
            "image bytes belong on kaya.image(source=...)"
        )
    return text


def _text_range(what: str, span: object) -> tuple[int, int]:
    """One text range, normalized to the (start, stop) pair the wire
    carries — `range(start, stop)` or a plain pair.

    A `slice` is REFUSED rather than reinterpreted: a None endpoint means
    the text's own end, which this call cannot resolve. NEGATIVE OFFSETS
    ARE REFUSED BY NAME, because `str.find` answers -1 and kaya has no
    end-relative offset. Every other malformed range is the core's.
    """
    if isinstance(span, range):
        if span.step != 1:
            raise KayaValueError(
                f"kaya: {what} takes a contiguous range — {span!r} counts in "
                f"steps of {span.step}"
            )
        start, stop = span.start, span.stop
    elif isinstance(span, (tuple, list)) and len(span) == 2:
        start, stop = span
    else:
        raise KayaTypeError(
            f"kaya: {what} takes a text range — range(start, stop), or a "
            f"(start, stop) pair of UTF-8 byte offsets — not {span!r}"
        )
    for name, offset in (("start", start), ("stop", stop)):
        if isinstance(offset, bool) or not isinstance(offset, int):
            raise KayaTypeError(
                f"kaya: {what}: a range's {name} is a UTF-8 byte offset (int), "
                f"not {type(offset).__name__}"
            )
        if offset < 0:
            raise KayaValueError(
                f"kaya: {what}: a range's {name} is {offset} — offsets count "
                "from the start of the text and kaya has no end-relative "
                "spelling (str.find answers -1 for no match; test for it)"
            )
    return start, stop

# `cast` rather than `App | None`: there is one App per process and every
# call below runs inside it, so an Optional here would be 60-odd
# unreachable None checks in the binding's own body.
_app = cast("App", None)  # the process's App: one core per process
_tx: "list[bytes] | None" = None  # the ambient transaction's records
# None until the dispatch loop starts, which is why module-scope
# declaration on the main thread still works.
_app_thread: "int | None" = None


def _require_app_thread() -> None:
    """The Python spelling of a rule the other bindings get from types.

    `_tx` is a module GLOBAL, not thread-local, so a transaction opened
    on a background thread would stamp its records into the app thread's
    open one — silently, and interleaved (tools/check-tx-liveness.py).
    """
    if _app_thread is not None and threading.get_ident() != _app_thread:
        raise KayaStateError(
            "kaya: a transaction belongs to the app thread — this is "
            f"thread {threading.get_ident()}, the app thread is "
            f"{_app_thread}. To mutate from a background thread use "
            "app.post(fn), which runs fn as a transaction over there."
        )
#: the container stack; None marks a template body's floor
_parents: "list[int | None]" = []
#: open menu scopes: creators seat under the top
_menu_scopes: "list[_MenuScope[Any]]" = []
_for_stack: "list[int]" = []  # depth indices of enclosing Fors, for levels
# Tracers whose template scope is still open; a break leaves one behind,
# caught at transaction exit.
_open_traces: "list[_ForTrace[Any]]" = []
_for_collections: "list[Collection[Any]]" = []  # for mirror parentage
_tpl_depth = 0  # 0 = live zone; >0 = declaring a blueprint
# Each canvas's declared viewbox, so a redraw in a LATER transaction does
# not have to repeat it (docs/canvas-plan.md §2.2).
_canvas_viewboxes: "dict[int, tuple[float, float]]" = {}
_pending_root: "_Handle | None" = None  # the container window() will mount
_recording = False  # inside window(): mirror reads would freeze branches
#: per-transaction mirror undo, run if the tx is abandoned
_journal: "dict[int, Callable[[], None]] | None" = None


def _ship(records: Sequence[bytes]) -> None:
    """Submit one transaction, the pending link-route declarations ahead
    of it, in declaration order (docs/app-links-plan.md §4; Rust's
    PENDING_ROUTES drained head-first by Tx::commit is the shape)."""
    pending, _app._pending_records = _app._pending_records, []
    records = pending + list(records)
    if records:
        runtime.submit(*records)


def _records() -> list[bytes]:
    if _tx is None:
        raise KayaStateError(
            "kaya: no ambient transaction — declare inside `with app.window():` "
            "or mutate inside a handler (or `with app.build():`)"
        )
    return _tx


def _journal_once(obj: object, restore: Callable[[], None]) -> None:
    """Record how to undo obj's mirror state, once per transaction: a
    handler that raises abandons its records and the mirrors both."""
    # Keyed by id(): signals overload __eq__ into derived signals, so an
    # object-keyed dict would truth-test one on a hash collision.
    if _journal is not None and id(obj) not in _journal:
        _journal[id(obj)] = restore


def _journal_instances(coll: Collection[Any]) -> None:
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


def _guard_tracer_escape() -> None:
    """Element tracers are record-time blueprints; one captured into a
    handler names the template, not any stamped copy's data."""
    if not (_recording or _tpl_depth > 0):
        raise KayaStateError(
            "kaya: element tracers exist at record time only — a handler "
            "receives the stamped copy's row and reads the model "
            "(row.title, get()/items()), never the tracer"
        )


def _row_owner(what: str) -> Collection[Any]:
    """The collection a stamped registration's Row handle reads: the
    innermost For open right now (DESIGN.md, Binding conventions)."""
    if not _for_collections:
        raise KayaStateError(
            f"kaya: {what} registers inside a For — its handler receives "
            "that For's row (`todo.done = checked`), and a template node "
            "with no enclosing For is stamped by no collection, so no "
            "occurrence ever reaches it"
        )
    return _for_collections[-1]


def _auto_parent(child_id: int) -> None:
    if _parents and _parents[-1] is not None:
        _records().append(wire.tx_add_child(_parents[-1], child_id))


def _guard_mirror_read(what: str) -> None:
    if _recording or _tpl_depth > 0:
        raise KayaStateError(
            f"kaya: {what} reads a mirror snapshot, which would freeze this "
            "branch at record time — bind the signal (or use kaya.when / "
            "kaya.for_each) in templates; read mirrors in handlers"
        )


def _no_truth_value(what: str) -> NoReturn:
    """A template body runs ONCE, so a branch taken on the row's data
    freezes one row's answer into every copy.

    ON THE ELEMENT AS WELL AS ITS FIELDS, because the constant arms
    COERCE: an object with no `__bool__` is true, so
    `progress(indeterminate=el)` wrote a spinning bar on every row with
    nothing raised.
    """
    raise KayaStateError(
        f"kaya: {what} has no truth value — bind it "
        "(checkbox(checked=el.field)) or, for per-constructor branches, "
        "declare a sum and its case arms; handlers read the model "
        "(get()/items()), never the tracer"
    )


class Signal(Generic[V]):
    """One scalar the core renders from: the app writes it, the platform
    draws it, and there is no read back (DESIGN.md, "the shape of an
    app"). `.eq(...)` and friends answer a DERIVED signal this binding
    recomputes; `==` is the same call in operator spelling."""

    def __init__(self, id: int, initial: Any = None) -> None:
        self.id = id
        self._mirror: Any = initial
        self._dependents: list[_Derived[Any]] = []

    def set(self, value: V) -> None:
        old = self._mirror
        _journal_once(self, lambda: setattr(self, "_mirror", old))
        _records().append(wire.tx_write_signal(self.id, _wire_scalar(value)))
        self._mirror = value
        for derived in self._dependents:
            derived._recompute()

    # No read method, deliberately: signals are a render pipe, not a
    # state bus. The mirror feeds derivations and skips no-op writes.

    def _derive(self, compute: Callable[[Any], R]) -> Signal[R]:
        derived = _Derived(_app._next("signal"), self, compute)
        _app._signals[derived.id] = derived
        _records().append(wire.tx_create_signal(derived.id, derived._mirror))
        self._dependents.append(derived)
        return derived

    def eq(self, other: object) -> Signal[bool]:
        """A derived Bool signal: this value == other."""
        return self._derive(lambda v: v == other)

    def ne(self, other: object) -> Signal[bool]:
        return self._derive(lambda v: v != other)

    def lt(self, other: Any) -> Signal[bool]:
        return self._derive(lambda v: v < other)

    def gt(self, other: Any) -> Signal[bool]:
        return self._derive(lambda v: v > other)

    def le(self, other: Any) -> Signal[bool]:
        return self._derive(lambda v: v <= other)

    def ge(self, other: Any) -> Signal[bool]:
        return self._derive(lambda v: v >= other)

    def fmt(self, template: str) -> Signal[str]:
        """A derived Str signal: template.format(value)."""
        return self._derive(lambda v: template.format(v))

    # `count == 0` is `count.eq(0)`, so == no longer answers identity —
    # which is why signals keep identity hashing.
    __hash__: Callable[[object], int] = object.__hash__

    # `-> Any`, not `-> Signal[bool]`: object.__eq__ answers bool and an
    # override may not widen it. `.eq(...)` is the spelling that keeps the
    # type; `==` is the sugar, and it is where Python's own surface runs out.
    def __eq__(self, other: object) -> Any:
        return self.eq(other)

    def __ne__(self, other: object) -> Any:
        return self.ne(other)

    def __lt__(self, other: Any) -> Signal[bool]:
        return self.lt(other)

    def __gt__(self, other: Any) -> Signal[bool]:
        return self.gt(other)

    def __le__(self, other: Any) -> Signal[bool]:
        return self.le(other)

    def __ge__(self, other: Any) -> Signal[bool]:
        return self.ge(other)

    def __bool__(self) -> NoReturn:
        # Python cannot overload statement branching, so an `if` on a
        # signal cannot trace to a template.
        raise KayaStateError(
            "kaya: a signal has no truth value at record time — branch "
            "with `with kaya.when(sig):` (build the condition with "
            "sig.eq(...) / sig == ...); handlers fold occurrences into "
            "your own state, never widget reads"
        )


class _Derived(Signal[V]):
    """Binding-maintained: recomputed when the source is written, the
    write batched into the same transaction."""

    def __init__(self, id: int, source: Signal[Any],
                 compute: Callable[[Any], V]) -> None:
        super().__init__(id, compute(source._mirror))
        self._compute: Callable[[Any], Any] = compute
        self._source = source

    def set(self, value: V) -> NoReturn:
        raise KayaStateError("kaya: derived signals are written by their source")

    def _recompute(self) -> None:
        new = self._compute(self._source._mirror)
        if new != self._mirror:
            old = self._mirror
            _journal_once(self, lambda: setattr(self, "_mirror", old))
            _records().append(wire.tx_write_signal(self.id, new))
            self._mirror = new
            for derived in self._dependents:
                derived._recompute()


class _CollectionDerived(Signal[V]):
    """Binding-maintained from a collection: recomputed after every
    mutation of the live-zone instance, batched into the same
    transaction."""

    def __init__(self, id: int, coll: _BoundCollection[Any],
                 compute: Callable[[Any], V]) -> None:
        super().__init__(id, compute(dict(coll._mirror())))
        self._coll = coll
        self._compute: Callable[[Any], Any] = compute

    def set(self, value: V) -> NoReturn:
        raise KayaStateError("kaya: derived signals are written by their source")

    def _recompute(self) -> None:
        new = self._compute(dict(self._coll._mirror()))
        if new != self._mirror:
            old = self._mirror
            _journal_once(self, lambda: setattr(self, "_mirror", old))
            _records().append(wire.tx_write_signal(self.id, new))
            self._mirror = new
            for derived in self._dependents:
                derived._recompute()


def _prop_source(what: str, handle: _Handle, value: Any,
                 const: Callable[..., bytes], signal: Callable[..., bytes],
                 element: Callable[..., bytes]) -> bytes:
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
        raise KayaTypeError(
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

    def __init__(self, id: int) -> None:
        self.id = id

    def a11y_id(self: H, ident: TextSource) -> H:
        """Set this widget's accessibility IDENTIFIER: a stable authored
        key automation addresses it by, and which is NEVER spoken.

        IN A TEMPLATE, TAKE IT FROM THE ROW (`row.slug`): the copies of
        one node share a node id, so a constant names N things at once.
        Returns the handle, so it chains."""
        _records().append(_prop_source(
            "a11y_id", self, ident, wire.tx_set_a11y_id,
            wire.tx_bind_a11y_id, wire.tx_bind_a11y_id_element))
        return self

    def a11y_hint(self: H, hint: TextSource) -> H:
        """Set what ACTIVATING this widget does. Write a VERB PHRASE:
        VoiceOver speaks it as written, TalkBack prefixes "double tap
        to". Activation kinds only. Returns the handle."""
        _records().append(_prop_source(
            "a11y_hint", self, hint, wire.tx_set_a11y_hint,
            wire.tx_bind_a11y_hint, wire.tx_bind_a11y_hint_element))
        return self

    def a11y_label(self: H, label: TextSource) -> H:
        """Set this widget's accessibility LABEL: what an assistive
        client speaks for it. Separate from `a11y_id` — an automation key
        is not a spoken name. Setting it OVERRIDES what the platform
        derives from the control's content. Returns the handle."""
        _records().append(_prop_source(
            "a11y_label", self, label, wire.tx_set_a11y_label,
            wire.tx_bind_a11y_label, wire.tx_bind_a11y_label_element))
        return self

    def help(self: H, text: TextSource) -> H:
        """Set this widget's HELP TEXT: one short sentence saying what it
        is or does. The platform decides the surface — a tooltip on the
        desktops, nothing visible on the iPhone — and hands it to the
        assistive reader (docs/tooltip-plan.md T1/T2). Distinct from
        `a11y_hint`, which says what ACTIVATION does and wins the hint
        slot where both are authored. Returns the handle."""
        _records().append(_prop_source(
            "help", self, text, wire.tx_set_help,
            wire.tx_bind_help, wire.tx_bind_help_element))
        return self

    def placeholder(self: H, text: TextSource) -> H:
        """Set the PROMPT this field shows while its text is empty
        (docs/search-plan.md S3): the platform's own placeholder, never
        part of the text and never emitted. Entry, textarea and search
        only, checked at the root. Returns the handle."""
        _records().append(_prop_source(
            "placeholder", self, text, wire.tx_set_placeholder,
            wire.tx_bind_placeholder, wire.tx_bind_placeholder_element))
        return self

    def href(self: H, url: TextSource) -> H:
        """Set the DESTINATION a `role="link"` label opens
        (docs/tasks-s2-plan.md T3): the platform's own opener takes it and
        nothing is emitted. Returns the handle."""
        _records().append(_prop_source(
            "href", self, url, wire.tx_set_href,
            wire.tx_bind_href, wire.tx_bind_href_element))
        return self

    def fill(self: H, on: bool) -> H:
        """Whether this widget spans its container's cross axis — a
        column's width, a row's height — whatever the container's
        `align` (docs/layout-knobs-plan.md §1). Unset, the kind's own
        default holds. Returns the handle."""
        _records().append(wire.tx_set_fill(self.id, bool(on)))
        return self

    def rich(self: H, on: bool = True) -> H:
        """This textarea carries ATTRIBUTE RUNS (docs/rich-text-plan.md
        R1): `set_document`, `apply_edit`, `format`, and the `on_edit`
        and `on_format` deltas. Off, none of that exists and the widget
        is the plain uncontrolled field. Returns the handle."""
        _records().append(wire.tx_set_rich(self.id, bool(on)))
        return self

    def own_undo(self: H, on: bool = True) -> H:
        """The app owns this rich textarea's undo (docs/rich-text-plan.md
        R6, §14): the native stack is off, and Edit>Undo/Redo reach the
        app through the role item's own `on_activate` while `can_undo` /
        `can_redo` say whether they are enabled. Returns the handle."""
        _records().append(wire.tx_set_own_undo(self.id, bool(on)))
        return self

    def columns_auto(self: H, min_width: float) -> H:
        """THE GRID THAT FITS (docs/layout-knobs-plan.md §3): as many
        columns as fit this grid's width at `min_width` DIP each, sharing
        the extra. An explicit `columns_when` still wins while its class
        holds. Returns the handle."""
        _records().append(wire.tx_set_columns(self.id, 0.0))
        _records().append(wire.tx_set_min_column_width(self.id, float(min_width)))
        return self

    def wrap(self: H, on: bool) -> H:
        """A ROW THAT FLOWS (docs/layout-knobs-plan.md §2): children keep
        their natural size and move onto the next line when the row runs
        out of width, leading-aligned, the row's `spacing` on both axes.
        No child of a wrapping row may grow. Returns the handle."""
        _records().append(wire.tx_set_wrap(self.id, bool(on)))
        return self

    def accepts(self: H, *kinds: str) -> H:
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
                raise KayaTypeError(
                    f"kaya: accepts takes constant kinds, not "
                    f"{type(kind).__name__} — an accept list describes "
                    "the control and not the row; rows that take "
                    "different things are different variants, one "
                    "cases.case(...) arm each"
                )
        _records().append(wire.tx_set_accepts(self.id, _accept_list(kinds)))
        return self

    def role(self: H, role: Role | str) -> H:
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

    def on_paste(self: H, fn: Handler) -> H:
        """Take pasted content here: fn(clip), or fn(row, clip) for a
        stamped copy — the copy's `Row` first, as on_change delivers.

        ONLY FIRES FOR A WIDGET THAT DECLARED WHAT IT `accepts`, in both
        zones, so one that registers this and declares nothing waits
        forever. Returns the handle."""
        _app._register(self, wire.OCC_PASTED, fn)
        return self

    def draggable(self: H, *, text: TextSource | None = None,
                  html: TextSource | None = None,
                  image: bytes | Source | None = None,
                  files: Sequence[PickedFile] = (),
                  custom: Mapping[str, bytes] | None = None,
                  operations: Sequence[str] | None = None) -> H:
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

    def draggable_at(self: H, *keys: Key, text: TextSource | None = None,
                     html: TextSource | None = None,
                     image: bytes | Source | None = None,
                     files: Sequence[PickedFile] = (),
                     custom: Mapping[str, bytes] | None = None,
                     operations: Sequence[str] | None = None) -> H:
        """ONE stamped copy's drag declaration (docs/dnd-plan.md §4): the
        copy's keys, outermost first, then the payload `draggable` takes.

        The per-row payload an app declares after the row's insert; it
        overrides the template's own for that copy and follows it through
        a re-stamp. Returns the handle."""
        _template_zone_only(self, "draggable_at")
        return self._draggable(keys, text, html, image, files, custom,
                               operations)

    def _draggable(self: H, keys: Sequence[Key], text: TextSource | None,
                   html: TextSource | None, image: bytes | Source | None,
                   files: Sequence[PickedFile],
                   custom: Mapping[str, bytes] | None,
                   operations: Sequence[str] | None) -> H:
        reps: list[Any] = []
        bound = 0
        present = 0
        custom = dict(custom or {})
        files = list(files)

        def slot(what: str, value: Any) -> bool:
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
                reps.append(wire.BlobHandle(
                    runtime.register_blob(cast("bytes", image))))
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

    def drop_target(self: H, *operations: str) -> H:
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

    def drop_target_at(self: H, *keys: Key, operations: Sequence[str] = ()) -> H:
        """ONE stamped copy's drop declaration, `draggable_at`'s twin;
        the copy's accept list is the template's `accepts`. Returns the
        handle."""
        _template_zone_only(self, "drop_target_at")
        path = list(keys)
        _records().append(wire.tx_set_drop_target(
            self.id, _operations(operations), len(path), path))
        return self

    def on_drop(self: H, fn: Handler) -> H:
        """Take dropped content here: fn(dropped), with the `Dropped` of
        docs/dnd-plan.md D1, or fn(row, dropped) for a stamped copy —
        the copy's `Row` first, as on_paste delivers. ONLY FIRES FOR A
        WIDGET THAT DECLARED `drop_target` over an `accepts` list, or for
        a reorderable For's container (D8). Returns the handle."""
        _app._register(self, wire.OCC_DROPPED, fn)
        return self

    def on_drag_ended(self: H, fn: Handler) -> H:
        """A drag that began here has ended: fn(operation), OP_COPY,
        OP_MOVE or None for cancelled or refused — fn(row, operation)
        for a stamped copy, which is how a reorderable row's own end
        arrives. Returns the handle."""
        _app._register(self, wire.OCC_DRAG_ENDED, fn)
        return self

    def draw(self, *keys: Key) -> _DrawScope:
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

    def clear(self) -> None:
        """Drop an entry's content now (the field stays authoritative)."""
        _records().append(wire.tx_widget_command(self.id, wire.COMMAND_CLEAR))

    def focus(self) -> None:
        """Give this widget the keyboard focus."""
        _records().append(wire.tx_widget_command(self.id, wire.COMMAND_FOCUS))

    # The text-range surface (docs/ranges-plan.md D1).

    def set_text(self, text: str) -> Widget:
        """Put text into a text widget programmatically — the "open a
        document into the editor" write.

        THE WIDGET IS UNCONTROLLED: this is ONE write, after which the
        user owns the text. A write that CHANGES the text also drops the
        app's declared ranges (`highlight_ranges`) and spends the field's
        native undo history. Returns the widget."""
        _records().append(wire.tx_set_text(self.id, _text_value("set_text", text)))
        return self

    def highlight_ranges(self, ranges: Sequence[Span]) -> None:
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

    def select_range(self, span: Span) -> None:
        """Put this textarea's selection at one range (an empty range is
        a caret). Same offsets and validation as `highlight_ranges`.

        REFUSED WHILE THE USER IS COMPOSING through an input method, in
        every backend: honouring it commits the composition mid-word. The
        refusal is a no-op, not an error — composition state is on no
        kaya channel."""
        start, stop = _text_range("select_range", span)
        _records().append(wire.tx_select_range(self.id, start, stop))

    def reveal_range(self, span: Span) -> None:
        """Scroll this textarea so a range is inside the viewport. A pure
        effect: no state moves, the selection is untouched, and undo does
        not put the scroll position back."""
        start, stop = _text_range("reveal_range", span)
        _records().append(wire.tx_reveal_range(self.id, start, stop))

    # The rich document surface (docs/rich-text-plan.md R1); `rich()`
    # declares the widget and is on _Handle, since a template declares it
    # too.

    def set_document(self, document: Document) -> Widget:
        """Replace this `rich` textarea's WHOLE document — text and runs
        in one write.

        A CONFIGURATION WRITE: it echoes nothing and, like `set_text`, it
        spends the field's native undo history (docs/undo-plan.md D7).
        The app's own Document is seeded from it, so a `document()` read
        after this answers what was written. Returns the widget."""
        _app._seed_document(self.id, document)
        _records().append(wire.tx_set_rich_text(
            self.id, len(document.runs), _flat_runs(document.runs),
            document.text))
        return self

    def apply_edit(self, edit: Edit) -> Widget:
        """One edit into this `rich` textarea — the app's own or a
        collaborator's: replace `start..end` with the edit's text and its
        runs, the selection kept by R5's rule.

        Echoes nothing, never resets undo, and is HELD rather than refused
        while an input method is composing. THE APP'S DOCUMENT TAKES IT AS
        IT IS SENT, while the widget and the core's mirror take it when the
        composition ends (docs/rich-text-plan.md §7). Returns the widget."""
        _app._absorb_edit(self.id, edit.range.start, edit.range.stop, edit.inserted,
                          edit.runs)
        _records().append(wire.tx_apply_edit(
            self.id, edit.range.start, edit.range.stop, len(edit.runs),
            _flat_runs(edit.runs), edit.inserted))
        return self

    def format(self, name: str, value: bool | str = True) -> Widget:
        """Format this `rich` textarea's CURRENT SELECTION through the
        widget's own act — what a toolbar button sends.

        Over a collapsed selection the attribute is armed for the next
        keystroke instead and nothing is answered until it. The widget
        reports the range it formatted to `on_format`, which is how the
        document moves. Returns the widget."""
        if isinstance(value, bool):
            value = _flag_wire(value)
        _records().append(wire.tx_format_text(
            self.id, 0, 0, 0, 0,
            [str(name), _text_value("format value", value)]))
        return self

    def unformat(self, name: str) -> Widget:
        """Take an attribute off this textarea's current selection.
        Returns the widget."""
        _records().append(wire.tx_format_text(self.id, 1, 0, 0, 0,
                                              [str(name), ""]))
        return self

    # The named acts (docs/rich-text-plan.md §18): each is `format` with
    # its name, over this widget's own selection; removal stays
    # `unformat` and the block kinds stay `set_block`.

    def bold(self) -> Widget:
        """Bold this textarea's current selection — `format("bold")` under
        its own name, what a toolbar button sends. Returns the widget."""
        return self.format("bold")

    def italic(self) -> Widget:
        """Italicize the current selection. Returns the widget."""
        return self.format("italic")

    def underline(self) -> Widget:
        """Underline the current selection. Returns the widget."""
        return self.format("underline")

    def strike(self) -> Widget:
        """Strike the current selection through. Returns the widget."""
        return self.format("strike")

    def code(self) -> Widget:
        """Make the current selection monospaced code. Returns the
        widget."""
        return self.format("code")

    def link(self, url: str) -> Widget:
        """Make the current selection a link to `url`. Returns the
        widget."""
        return self.format("link", url)

    def format_range(self, span: Span, name: str,
                     value: bool | str = True) -> Widget:
        """One attribute over a BYTE RANGE of this document, the selection
        left exactly where the user put it (docs/rich-text-plan.md §17).

        A DOCUMENT WRITE like `apply_edit` rather than a toolbar act: the
        widget echoes nothing and `on_format` hears nothing, so the app's
        own Document takes it HERE, as it is sent. A rich LABEL takes it
        too. A `block` act covers the range's whole paragraphs, and `block`
        with `body` removes. Returns the widget."""
        start, stop = _text_range("format_range", span)
        if isinstance(value, bool):
            value = _flag_wire(value)
        name, value = str(name), _text_value("format value", value)
        start, stop = _app._ranged_act_bounds(self.id, start, stop, name)
        removed = name == "block" and value == "body"
        _app._absorb_format(self.id, start, stop, name,
                            None if removed else value)
        _records().append(wire.tx_format_text(
            self.id, 1 if removed else 0, 1, start, stop,
            [name, "" if removed else value]))
        return self

    def unformat_range(self, span: Span, name: str) -> Widget:
        """`format_range`'s removal: take an attribute off a byte range,
        the selection untouched. Returns the widget."""
        start, stop = _text_range("unformat_range", span)
        name = str(name)
        start, stop = _app._ranged_act_bounds(self.id, start, stop, name)
        _app._absorb_format(self.id, start, stop, name, None)
        _records().append(wire.tx_format_text(self.id, 1, 1, start, stop,
                                              [name, ""]))
        return self

    def set_block(self, kind: str) -> Widget:
        """Make the selection's whole paragraphs `kind` (kaya.Block;
        plain names accepted). `body` clears. Returns the widget."""
        return self.format("block", _block_value(kind))

    def can_undo(self, on: bool) -> Widget:
        """Whether this `own_undo` textarea's app has something to undo —
        what Edit>Undo's enablement reads while it is focused
        (docs/rich-text-plan.md R6, §14). Returns the widget."""
        _records().append(wire.tx_set_can_undo(self.id, bool(on)))
        return self

    def can_redo(self, on: bool) -> Widget:
        """Redo's twin. Returns the widget."""
        _records().append(wire.tx_set_can_redo(self.id, bool(on)))
        return self

    def document(self) -> Document:
        """This `rich` textarea's document, as this binding has folded it
        from the deltas (docs/rich-text-plan.md R1) — a copy, so writing
        to it moves nothing. Empty until the first write or edit."""
        return _app._document(self.id)

    def grow(self, weight: float) -> None:
        """Set this widget's flex weight within its row/column: 0 is
        natural size, positive weights divide the leftover main-axis
        space."""
        _records().append(wire.tx_set_grow(self.id, float(weight)))

    def align(self, mode: Align | str) -> None:
        """Set this container's cross-axis child placement (see
        kaya.Align; strings accepted). Containers only — the scene
        rejects it anywhere else; baseline is rows-only."""
        _records().append(wire.tx_set_align(self.id, _align_value(mode)))

    def axis(self, mode: Axis | str) -> None:
        """Set this container's arrangement direction (see kaya.Axis;
        strings accepted) — the user-driven orientation toggle
        (docs/adaptive-layout-plan.md D2). Row/column only. The widget
        stays what its constructor made it."""
        _records().append(wire.tx_set_axis(self.id, _axis_value(mode)))

    def spacing(self, gap: float) -> None:
        """Set this container's inter-child gap (main axis, DIP; the
        normalized default is 8). Containers only."""
        _records().append(wire.tx_set_spacing(self.id, float(gap)))

    def inset(self, pad: float) -> None:
        """Set this container's own padding: DIP between its bounds and
        its children, uniform on all four sides. Containers only, and a
        negative one is refused.

        THE DECLARATIVE `inset=` IS THE TEMPLATE ZONE'S SPELLING; this
        dynamic setter stays live-only, since a blueprint is declared
        once and never mutated (tools/checks/py-node-props.py)."""
        _records().append(wire.tx_set_inset(self.id, float(pad)))

    def context_menu(self,
                     catalog: ContextCatalog | None = None) -> _MenuScope[None]:
        """The live-widget context anchor: the command vocabulary scoped
        to a NOUN. No shortcuts here — a shortcut needs a window catalog
        as its native dispatch home.

        `catalog` is the TEMPLATE NODE's spelling and is refused here: one
        constructor serves both zones in this binding, so the two anchors
        share a signature and the zone is what tells them apart
        (tools/py-typecheck.py; bindings/python/kaya_app_checks.py holds
        the refusal)."""
        if catalog is not None:
            raise KayaStateError(
                "kaya: a live widget's context anchor takes no catalog — "
                "the catalog is the TEMPLATE node's spelling "
                "(node.context_menu(catalog)), where the live-built items "
                "are shared by every stamped copy; live, this with-block "
                "IS the anchor"
            )
        return _MenuScope(("widget", self.id), shortcut_ok=False)


class Node(_Handle):
    """A template node: a blueprint entry, stamped per collection entry.

    ITS OWN CLASS, NOT AN ALIAS: `App._register` reads the handle's type
    to decide which handler table a callback lands in."""

    def context_menu(self, catalog: ContextCatalog) -> None:
        """Attach a live-zone-built context catalog to this template
        node: every stamped copy shows the same catalog, and each
        activation carries that copy's key path. An item takes exactly
        ONE anchor, so a second attach raises here."""
        if catalog._attached:
            raise KayaStateError(
                "kaya: a context catalog takes exactly one anchor"
            )
        catalog._attached = True
        # Its items were built live; the attach is where they learn whose
        # row their activation carries.
        catalog._owner = _row_owner("a context catalog on a template node")
        for root in catalog._roots:
            _records().append(wire.tx_context_attach_node(self.id, root))


class Element(Generic[T]):
    """The element of an enclosing For: what a stamped copy's bindings
    read. For a record collection, `element.title` projects one field.

    A guest never NAMES this type: `for todo in todos:` hands out the
    RECORD (DESIGN.md, Binding conventions), so `todo.title` reads as the
    field's own type and every prop takes that type beside a FieldRef."""

    def __init__(self, for_index: int, coll: Collection[Any]) -> None:
        self._for_index = for_index
        self._coll = coll

    def _level(self) -> int:
        return len(_for_stack) - 1 - self._for_index

    def __bool__(self) -> NoReturn:
        _no_truth_value("an element")

    def __getattr__(self, name: str) -> FieldRef[Any]:
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

    def __init__(self, for_index: int, coll: Collection[Any]) -> None:
        self._for_index = for_index
        self._coll = coll

    def case(self, cls: type[R]) -> _CaseScope[R]:
        for variant, spec in enumerate(self._coll._variants):
            if spec.cls is cls:
                return _CaseScope(self._for_index, self._coll, variant)
        raise KayaTypeError(
            f"kaya: {cls.__name__} is not a constructor of this collection's union"
        )


class _CaseScope(Generic[T]):
    def __init__(self, for_index: int, coll: Collection[Any],
                 variant: int) -> None:
        self._for_index = for_index
        self._coll = coll
        self._variant = variant

    def __enter__(self) -> T:
        _records().append(wire.tx_variant_case(self._variant))
        # The refined proxy, typed as the CONSTRUCTOR it refines — Element's
        # own ORM convention, one arm down.
        return cast("T", _CaseElement(self._for_index, self._coll,
                                      self._variant))

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> Literal[False]:
        return False


class _CaseElement:
    """The element proxy refined to one constructor: field projections
    resolve against that variant's schema."""

    def __init__(self, for_index: int, coll: Collection[Any],
                 variant: int) -> None:
        self._for_index = for_index
        self._coll = coll
        self._variant = variant

    def _level(self) -> int:
        return len(_for_stack) - 1 - self._for_index

    def __bool__(self) -> NoReturn:
        _no_truth_value("an element")

    def __getattr__(self, name: str) -> FieldRef[Any]:
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


class FieldRef(Generic[T]):
    """One field of an element: index plus level, ready to bind. `_type` is
    the schema's python type, which is what tells a Date field from the
    int it shares a wire tag with."""

    def __init__(self, element: Element[Any] | _CaseElement, index: int,
                 py_type: Any = None) -> None:
        self._element = element
        self._index = index
        self._type = py_type

    def _level(self) -> int:
        return self._element._level()

    def __bool__(self) -> NoReturn:
        _no_truth_value("an element's field")


#: A collection key: the wire's scalar, as a guest spells it.
Key = int | str | float

#: Where a prop's value comes from other than a constant: a signal, the
#: enclosing For's element, or one of its fields. A FIELD READS AS ITS OWN
#: TYPE — `for todo in todos:` hands out the record (DESIGN.md, Binding
#: conventions) — so every prop below takes the field's value type as well.
Source = Signal[Any] | FieldRef[Any] | Element[Any]
TextSource = str | Source
FlagSource = bool | Source
NumberSource = float | Source

#: One text range, in UTF-8 BYTE offsets: `range(start, stop)` or the pair.
Span = range | tuple[int, int]

#: A handler registered on a widget OR on a template node: a stamped copy's
#: `Row` arrives FIRST (DESIGN.md, Binding conventions), so the arity is the
#: ZONE's and one spelling spans both.
Handler = Callable[..., object]


class _BoundCollection(Generic[T]):
    """One instance of a collection: the table inside the copy selected
    by `path` (the empty path for a live-zone collection)."""

    def __init__(self, owner: Collection[T], path: list[Key]) -> None:
        self._owner = owner
        self._path = path

    def _mirror(self) -> dict[Key, T]:
        owner = self._owner
        _journal_instances(owner)
        return owner._instances.setdefault(tuple(self._path), {})

    def _encode(self, value: T) -> tuple[int, list[Any]]:
        """The entry's constructor index and wire fields, in that
        variant's schema order; only wire fields travel."""
        variant, spec = self._owner._variant_for(value)
        if spec.getters is None:
            return variant, [value]
        return variant, [e(g(value)) for g, e in zip(spec.getters, spec.encoders)]

    def derive(self, compute: Callable[[dict[Key, T]], R]) -> Signal[R]:
        """A signal the binding recomputes from this collection's entries
        after every mutation, batched into the same transaction."""
        if self._path:
            raise KayaStateError(
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

    def _recompute_derived(self) -> None:
        # Deriveds hang off root handles, so nested-instance mutations
        # cannot change their input.
        if not self._path:
            for derived in self._owner._derived:
                derived._recompute()

    def set_columns(self, *titles: str, sort: Sort | None = None) -> None:
        """Re-declare this collection instance's header bar after sorting."""
        handle = getattr(self._owner, "_for_handle", None)
        if handle is None:
            raise KayaStateError(
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

    def _absorb_key(self, key: Key) -> None:
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

    def insert(self, key: Key, value: T) -> None:
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

    def insert_fresh(self, value: T) -> int:
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

    def update(self, key: Key, value: T) -> None:
        variant, fields = self._encode(value)
        _records().append(
            wire.tx_collection_update(self._owner._id, self._path, key,
                                      variant, fields)
        )
        self._mirror()[key] = value
        self._recompute_derived()

    def patch(self, key: Key, **fields: Any) -> None:
        """Field-level deltas: `todos.patch(k, done=True)` sends one
        update_field per kwarg and mutates the model instance in place.
        On a sum the entry's CURRENT CONSTRUCTOR is the witness — a kwarg
        it lacks raises here."""
        entry = self._mirror()[key]
        variant, spec = self._owner._variant_for(entry)
        if spec.fields is None:
            raise KayaTypeError("kaya: patch() needs a record collection")
        for name, value in fields.items():
            if name not in spec.fields:
                raise KayaKeyError(
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

    def move_before(self, key: Key, anchor: Key) -> None:
        """Reposition an entry before another's key. Keys, never indices;
        a missing key or anchor raises at the call site, and moving an
        entry before itself is a no-op."""
        self._move(key, [anchor])

    def move_to_end(self, key: Key) -> None:
        """Reposition an entry at the end of its collection."""
        self._move(key, [])

    def move_to_front(self, key: Key) -> None:
        """Reposition an entry at the front."""
        keys = list(self._mirror())
        if not keys:
            raise KayaKeyError(f"kaya: move of missing key {key!r}")
        self._move(key, [keys[0]])

    def move_after(self, key: Key, anchor: Key) -> None:
        """Reposition an entry directly after another's."""
        keys = list(self._mirror())
        if key not in keys:
            raise KayaKeyError(f"kaya: move of missing key {key!r}")
        if anchor not in keys:
            raise KayaKeyError(f"kaya: move after missing key {anchor!r}")
        if key == anchor:
            return
        at = keys.index(anchor)
        succ = keys[at + 1] if at + 1 < len(keys) else None
        if succ == key:
            return  # already directly after the anchor
        self._move(key, [] if succ is None else [succ])

    def _move(self, key: Key, before: list[Key]) -> None:
        mirror = self._mirror()
        # The same checks the scene makes, made where the guest can see
        # the stack.
        if key not in mirror:
            raise KayaKeyError(f"kaya: move of missing key {key!r}")
        if before and before[0] not in mirror:
            raise KayaKeyError(f"kaya: move before missing key {before[0]!r}")
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

    def remove(self, key: Key) -> None:
        _records().append(wire.tx_collection_remove(self._owner._id, self._path, key))
        self._mirror().pop(key, None)
        self._recompute_derived()
        # The core tears down the copy, taking descendant collection
        # instances with it; the mirrors follow.
        prefix = tuple(self._path) + (key,)
        for child in self._owner._children:
            child._purge(prefix)

    def change(self) -> _Draft[T]:
        """A draft scope for bulk mutation: `d[key] = value` inserts or
        updates, `del d[key]` removes, reads see the draft's own writes.
        THE SCOPE IS SYNTAX, NOT A BARRIER."""
        return _Draft(self)

    @overload
    def get(self, key: Key) -> T | None: ...

    @overload
    def get(self, key: Key, default: R) -> T | R: ...

    def get(self, key: Key, default: Any = None) -> Any:
        """The entry's current value — the model's copy. Template
        position raises."""
        _guard_mirror_read("get()")
        return self._mirror().get(key, default)

    def items(self) -> list[tuple[Key, T]]:
        """The model: what this guest wrote, in insertion order.
        Template position raises."""
        _guard_mirror_read("items()")
        return list(self._mirror().items())

    def keys(self) -> list[Key]:
        _guard_mirror_read("keys()")
        return list(self._mirror().keys())

    def __len__(self) -> int:
        _guard_mirror_read("len()")
        return len(self._mirror())

    def __contains__(self, key: object) -> bool:
        _guard_mirror_read("membership")
        return key in self._mirror()


class _Draft(Generic[T]):
    """Records natural mutations as patches; see change()."""

    def __init__(self, bound: _BoundCollection[T]) -> None:
        self._bound = bound

    def __enter__(self) -> _Draft[T]:
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> Literal[False]:
        return False

    def __setitem__(self, key: Key, value: T) -> None:
        if key in self._bound._mirror():
            self._bound.update(key, value)
        else:
            self._bound.insert(key, value)

    def __delitem__(self, key: Key) -> None:
        self._bound.remove(key)

    def __getitem__(self, key: Key) -> T:
        _guard_mirror_read("draft reads")
        return self._bound._mirror()[key]

    def __contains__(self, key: object) -> bool:
        _guard_mirror_read("draft membership")
        return key in self._bound._mirror()


class _Variant:
    """One constructor's wire shape: the dataclass, its wire-typed
    fields in declaration order, and precompiled accessors. cls None is
    the scalar."""

    def __init__(self, cls: type | None) -> None:
        self.cls = cls
        # `cls`, `fields` and `getters` are None TOGETHER and are the
        # scalar test every reader below makes; the codec lists are simply
        # empty there, so no reader has to prove they are present.
        self.fields: dict[str, int] | None = None
        self.schema: list[int] = [wire.VALUE_STR]
        # Whatever the dataclass field's annotation evaluated to: a type
        # here, a string under a guest's own `from __future__ import
        # annotations` — `_wire_tag` compares it by identity either way.
        self.types: list[Any] = []
        self.getters: list[Callable[[Any], Any]] | None = None
        # Blob fields register their bytes at encode time, dates and times
        # pack (docs/datetime-plan.md D10); the rest are identity.
        self.encoders: list[Callable[[Any], Any]] = []
        self.decoders: list[Callable[[Any], Any]] = []
        if cls is None:
            return
        self.fields = {}
        self.schema = []
        self.getters = []
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
            raise KayaTypeError(f"kaya: {cls.__name__} has no wire-typed fields")


class Sort:
    """The header bar's sort indicator (docs/tables-plan.md): the
    GUEST's declaration, re-sent after it handles a sort request. The
    platform never sorts; a header click only asks."""

    __slots__ = ("sorted", "direction")

    #: The no-indicator bar, assigned below the class (the wire's u32
    #: none-sentinel); declared here so the name is part of the surface.
    NONE: Sort

    def __init__(self, sorted: int, direction: int) -> None:
        self.sorted: int = sorted
        self.direction: int = direction

    @staticmethod
    def asc(column: int) -> Sort:
        """Ascending on `column` (0-based, in the declared order)."""
        return Sort(column, 0)

    @staticmethod
    def desc(column: int) -> Sort:
        """Descending on `column`."""
        return Sort(column, 1)


# The no-indicator bar (the wire's u32 none-sentinel).
Sort.NONE = Sort(0xFFFF_FFFF, 0)


class Collection(_BoundCollection[T]):
    """A keyed table of records the core stamps a template over: the
    declaration handle, and the live-zone instance of itself. `at(...)`
    names one instance inside a stamped copy."""

    #: The For node a columns() trace closed over, set there and read by
    #: set_columns through getattr — declared, never assigned here, so its
    #: ABSENCE is still what "columns() has not run" means.
    _for_handle: int

    def __init__(self, id: int,
                 record_type: type[T] | types.UnionType | None = None) -> None:
        self._id = id
        self._instances: dict[tuple[Key, ...], dict[Key, T]] = {}
        #: collections declared inside our template
        self._children: list[Collection[Any]] = []
        #: the signals this collection recomputes after every mutation
        self._derived: list[_CollectionDerived[Any]] = []
        # Highest I64 key each INSTANCE has minted or absorbed. Not in
        # the rollback journal, on purpose — see insert_fresh.
        self._fresh: dict[tuple[Key, ...], int] = {}
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

    def __iter__(self) -> Iterator[T]:
        """In template position, `for t in todos:` traces to a For — the
        loop body runs ONCE, authoring the blueprint."""
        if not (_recording or _tpl_depth > 0):
            raise KayaTypeError(
                "kaya: `for t in coll:` is template tracing, record time "
                "only — handlers iterate the model with items()"
            )
        if len(self._variants) > 1:
            # A for-loop body is one arm, but a sum's template is a
            # record of case arms.
            raise KayaTypeError(
                "kaya: a sum collection's template is its case arms — "
                "use `with kaya.for_each(c) as cases:` and one "
                "`with cases.case(Cls) as el:` per constructor"
            )
        return _ForTrace(self)

    def rows(self, *, grow: float | None = None,
             align: Align | str | None = None,
             a11y_id: TextSource | None = None, reorderable: bool = False,
             on_drop: Handler | None = None) -> Iterator[T]:
        """The configured spelling of the ordinary For loop:
        `for item in items.rows(grow=1, align="stretch"):`.

        `reorderable=True` makes every stamped row drag within this
        collection; the landing arrives at `on_drop` on the For's own
        container, with the moved row's key in the clip and the row it
        landed on as the anchor, and the app confirms with a move
        (docs/dnd-plan.md D8)."""
        trace = cast("_ForTrace[T]", iter(self))
        trace._grow = grow
        trace._align = align
        trace._a11y_id = a11y_id
        trace._reorderable = reorderable
        trace._on_drop = on_drop
        return trace

    def columns(self, *titles: str, sort: Sort | None = None,
                on_sort: Handler | None = None, grow: float | None = None,
                a11y_id: TextSource | None = None) -> Iterator[T]:
        """Declare the column header bar on this collection's For — the
        table spelling of the same loop.

        The row template's body must hold a `with kaya.row():` of exactly
        one cell per column. `on_sort` takes the 0-based column index of
        a header click, preceded by the ENCLOSING For's `Row` inside a
        nested template; re-declare with set_columns() after sorting
        (docs/tables-plan.md)."""
        return _ColumnsTrace(self, list(titles), sort or Sort.NONE, on_sort, grow, a11y_id)

    def _decode(self, variant: int, fields: Sequence[Any], current: Any) -> Any:
        """Rebuild a model value from an undo delta's wire record.

        An entry the mirror still holds is UPDATED IN PLACE, so a
        dataclass field the wire never carried survives the undo.
        """
        spec = self._variants[variant]
        if spec.cls is None:
            return fields[0]
        names = list(cast("dict[str, int]", spec.fields))  # schema order
        restored = [d(v) for d, v in zip(spec.decoders, fields)]
        if isinstance(current, spec.cls):
            for name, value in zip(names, restored):
                setattr(current, name, value)
            return current
        return spec.cls(**dict(zip(names, restored)))

    def _variant_for(self, value: Any) -> tuple[int, _Variant]:
        """The constructor a model value holds."""
        for variant, spec in enumerate(self._variants):
            if spec.cls is None or isinstance(value, spec.cls):
                return variant, spec
        raise KayaTypeError(
            f"kaya: {type(value).__name__} is not a constructor of this "
            "collection's union"
        )

    def at(self, *path: Key) -> _BoundCollection[T]:
        """The instance of this (template-declared) collection inside
        the copy selected by `path` — one key per enclosing For."""
        return _BoundCollection(self, list(path))

    def _purge(self, prefix: tuple[Key, ...]) -> None:
        _journal_instances(self)
        for path in [p for p in self._instances if p[: len(prefix)] == prefix]:
            del self._instances[path]
        for child in self._children:
            child._purge(prefix)


#: The handle's own surface. A RECORD FIELD OF THE SAME NAME WINS, as
#: JS's proxy does (docs/js-plan.md §4 rule 3).
_ROW_VALUES = ("key", "path", "exists", "fields")
_ROW_VERBS = ("remove", "update", "patch", "move_before", "move_after",
              "move_to_end", "move_to_front")


class Row(Generic[T]):
    """THE ROW A STAMPED HANDLER IS ABOUT (DESIGN.md, Binding
    conventions; docs/js-plan.md §4 rule 3, the JS twin).

    Fields read the model's copy and ASSIGN AS A PATCH —
    `todo.done = checked` sends exactly what `todos.patch(key,
    done=checked)` sends, and a scalar collection's row carries `value`,
    whose assignment is the update. A misspelled field is refused BY NAME
    on read and on assignment, because a plain attribute would patch
    nothing. `isinstance(row, Todo)` narrows a sum's row; a row that has
    left its collection reads None for every field, says `exists` False
    and matches no variant. Beside the fields: `key`, `path` (the
    enclosing keys, outermost first), `exists`, `fields` (the wire field
    names in schema order), `remove()`, `update(value)`,
    `patch(**fields)` and the four moves.
    """

    __slots__ = ("_owner", "_bound", "_key", "_path", "_spec")

    def __init__(self, owner: Collection[T], keys: Sequence[Key]) -> None:
        bound = owner.at(*keys[:-1])
        entry = bound._mirror().get(keys[-1])
        if entry is None:
            # A stale occurrence: only a one-variant collection can still
            # say what shape the row had.
            spec = owner._variants[0] if len(owner._variants) == 1 else None
        else:
            spec = owner._variant_for(entry)[1]
        object.__setattr__(self, "_owner", owner)
        object.__setattr__(self, "_bound", bound)
        object.__setattr__(self, "_key", keys[-1])
        object.__setattr__(self, "_path", tuple(keys[:-1]))
        object.__setattr__(self, "_spec", spec)

    @property
    def __class__(self) -> type:  # pyright: ignore[reportIncompatibleMethodOverride]
        # What `isinstance` reads once `type()` has failed — the variant
        # the entry IS, so a row that has left matches none. Python's type
        # system has no per-instance class, so the override is asserted
        # here and nowhere else.
        entry = self._entry()
        if entry is None:
            return Row
        spec = self._owner._variant_for(entry)[1]
        return Row if spec.cls is None else spec.cls

    def _entry(self) -> T | None:
        return self._bound._mirror().get(self._key)

    def _spec_now(self) -> _Variant | None:
        entry = self._entry()
        if entry is None:
            return self._spec
        return self._owner._variant_for(entry)[1]

    def _field_names(self) -> tuple[str, ...]:
        spec = self._spec_now()
        if spec is None:
            return ()
        return ("value",) if spec.fields is None else tuple(spec.fields)

    def _named(self) -> str:
        spec = self._spec_now()
        if spec is None:
            return "a row that has left its collection"
        return "a scalar row" if spec.cls is None else spec.cls.__name__

    def _no_field(self, name: str) -> str:
        names = self._field_names()
        return (
            f"kaya: {self._named()} has no field {name!r} — the fields are "
            f"{', '.join(names) if names else 'none'}; a row handle patches "
            "fields and moves or removes its row, nothing else"
        )

    def _remove(self) -> None:
        self._bound.remove(self._key)

    def _update(self, value: T) -> None:
        self._bound.update(self._key, value)

    def _patch(self, **fields: Any) -> None:
        self._bound.patch(self._key, **fields)

    def _move_before(self, anchor: Key) -> None:
        self._bound.move_before(self._key, anchor)

    def _move_after(self, anchor: Key) -> None:
        self._bound.move_after(self._key, anchor)

    def _move_to_end(self) -> None:
        self._bound.move_to_end(self._key)

    def _move_to_front(self) -> None:
        self._bound.move_to_front(self._key)

    def __getattr__(self, name: str) -> Any:
        if name in self._field_names():
            entry = self._entry()
            if entry is None:
                return None
            spec = cast("_Variant", self._spec_now())
            return entry if spec.fields is None else getattr(entry, name)
        if name in _ROW_VERBS:
            return getattr(self, "_" + name)
        if name == "key":
            return self._key
        if name == "path":
            return self._path
        if name == "exists":
            return self._entry() is not None
        if name == "fields":
            return self._field_names()
        if name.startswith("_"):
            raise AttributeError(name)
        raise KayaKeyError(self._no_field(name))

    def __setattr__(self, name: str, value: Any) -> None:
        if name in self._field_names():
            spec = cast("_Variant", self._spec_now())
            if spec.fields is None:
                self._bound.update(self._key, value)
            else:
                self._bound.patch(self._key, **{name: value})
            return
        raise KayaKeyError(self._no_field(name))

    def __dir__(self) -> list[str]:
        return sorted({*self._field_names(), *_ROW_VALUES, *_ROW_VERBS})

    def __repr__(self) -> str:
        entry = self._entry()
        return f"Row({self._key!r}) {entry!r}" if entry is not None else (
            f"Row({self._key!r}) <gone>")


class _Scope(Generic[T]):
    """Common context-manager plumbing for containers and templates.

    `T` is what the `with` block's target receives."""

    def _enter(self) -> T:
        """What the block opens with; every subclass answers it."""
        raise NotImplementedError

    def _exit(self) -> None:
        """What closing the block records; every subclass answers it."""
        raise NotImplementedError

    def __enter__(self) -> T:
        return self._enter()

    def __exit__(self, exc_type: Any, exc: Any,
                 tb: Any) -> Literal[False]:
        if exc_type is None:
            self._exit()
        return False


class _Container(_Scope["Widget"]):
    """A container's with-block: everything declared inside parents to it."""

    def __init__(self, handle: Widget) -> None:
        self.handle: Widget = handle

    def _enter(self) -> Widget:
        _parents.append(self.handle.id)
        return self.handle

    def _exit(self) -> None:
        global _pending_root
        _parents.pop()
        at_live_top = _tpl_depth == 0 and (not _parents or _parents[-1] is None)
        if at_live_top and not _parents:
            _pending_root = self.handle


class _Labeled(_Container):
    """A labelled row's with-block: the label first, then the body."""

    def __init__(self, handle: Widget, text: TextSource) -> None:
        super().__init__(handle)
        self._label = text

    def _enter(self) -> Widget:
        handle = super()._enter()
        if isinstance(self._label, str):
            label(text=self._label)
        else:
            label(bind=self._label)
        return handle


class _Template(_Scope[T]):
    """A For or When template's with-block: the body authors the
    blueprint ONCE and the core stamps it."""

    #: The For/When node itself, minted when the block opens.
    handle: Widget

    def __init__(self, opener: Callable[[int, int], bytes], target_id: int,
                 is_for: bool, coll: Collection[Any] | None = None) -> None:
        self._opener = opener
        self._target_id = target_id
        self._is_for = is_for
        # `when()` passes none; only the For arm below reads it.
        self._coll = cast("Collection[Any]", coll)

    def _enter(self) -> T:
        global _tpl_depth
        self.handle = cast("Widget", _alloc_widget_or_node())
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
                return cast("T", _Cases(_for_stack[-1], self._coll))
            # The ORM convention: the tracer stands in for the record.
            return cast("T", Element(_for_stack[-1], self._coll))
        return cast("T", None)

    def _exit(self) -> None:
        global _tpl_depth
        if self._is_for:
            _for_stack.pop()
            _for_collections.pop()
        _parents.pop()
        _tpl_depth -= 1
        _records().append(wire.tx_template_end())
        if self._parent is not None:
            _records().append(wire.tx_add_child(self._parent, self.handle.id))


class _ForTrace(Generic[T]):
    """The for-statement tracer: opens the For template, hands the body
    one element tracer, and closes the template when the loop asks for a
    second. THE BODY RUNS ONCE — stamping is the core's replay."""

    def __init__(self, coll: Collection[T]) -> None:
        self._template: _Template[T] = _Template(
            wire.tx_create_for, coll._id, is_for=True, coll=coll)
        self._grow: float | None = None
        self._align: Align | str | None = None
        self._a11y_id: TextSource | None = None
        self._reorderable = False
        self._on_drop: Handler | None = None
        self._state = 0

    def __iter__(self) -> _ForTrace[T]:
        return self

    def __next__(self) -> T:
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
                raise KayaStateError(
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
    #
    # DELIBERATELY UNANNOTATED, and the `return Node(...)` below is
    # LITERAL: tools/checks/py-node-props.py reads this statement to prove
    # the two zones are told apart here and nowhere else. Its callers cast
    # to the LIVE handle, which is the type a guest holds — one
    # constructor serves both zones in this binding
    # (tools/py-typecheck.py).
    if _tpl_depth > 0:
        return Node(_app._next("widget"))
    return Widget(_app._next("widget"))


def _widget(kind: int) -> Widget:
    handle = cast("Widget", _alloc_widget_or_node())
    _records().append(wire.tx_create_widget(handle.id, kind))
    _auto_parent(handle.id)
    return handle


def create_window(window_id: int) -> None:
    """Create an auxiliary window (capability-gated: a phone host
    rejects it at the root). Materializes hidden; mounting presents."""
    _records().append(wire.tx_create_window(int(window_id)))


def destroy_window(window_id: int) -> None:
    """Close and forget an auxiliary window — also the veto grammar's
    confirmation after on_close_requested."""
    _records().append(wire.tx_destroy_window(int(window_id)))


def pop_entry(window: int = 0) -> None:
    """Pop the window's top navigation entry and forget its tree —
    also the back-veto grammar's confirmation after
    on_back_requested. Popping an empty stack is a scene error."""
    _records().append(wire.tx_pop_entry(int(window)))


def select_section(section_id: int, *, window: int = 0) -> None:
    """Select a section programmatically: configuration, never echoes
    on_selected. The section must already be added."""
    _records().append(wire.tx_select_section(int(window), int(section_id)))


def _vocab_missing(cls: Any, value: Any, what: str, hint: str) -> Any:
    """Every closed vocabulary's `_missing_`, once: a plain name is
    accepted, anything else is refused NAMING the vocabulary."""
    if isinstance(value, str):
        try:
            return cls[value.upper()]
        except KeyError:
            raise KayaValueError(
                f"kaya: {what} must be one of "
                f"{sorted(m.name.lower() for m in cls)}, got {value!r}"
            ) from None
    raise KayaValueError(
        f"kaya: {value} is not {what} — the vocabulary is "
        f"{sorted(m.name.lower() for m in cls)} ({hint})"
    )


class SectionsPresentation(enum.IntEnum):
    """A window's ADVISORY sections hint. Plain names accepted too —
    `sections_presentation="bar"`."""

    AUTO = wire.SECTIONS_PRESENTATION_AUTO
    BAR = wire.SECTIONS_PRESENTATION_BAR
    SIDEBAR = wire.SECTIONS_PRESENTATION_SIDEBAR

    @classmethod
    def _missing_(cls, value: object) -> Any:
        return _vocab_missing(cls, value, "a sections presentation",
                              "kaya.SectionsPresentation.BAR")


class Appearance(enum.IntEnum):
    """The app's OWN light/dark choice, applied process-wide from the
    default window (docs/tasks-s2b-plan.md R1-R3). Plain names accepted
    too — `appearance="dark"`."""

    SYSTEM = wire.APPEARANCE_SYSTEM
    LIGHT = wire.APPEARANCE_LIGHT
    DARK = wire.APPEARANCE_DARK

    @classmethod
    def _missing_(cls, value: object) -> Any:
        return _vocab_missing(cls, value, "an appearance",
                              "kaya.Appearance.DARK")


class AlertChoice(enum.IntEnum):
    """An alert's three outcomes: the action the user pressed, by its
    slot, or CANCEL — every platform-native dismissal. Deliberately not a
    bare index."""

    ACTION0 = wire.ALERT_CHOICE_ACTION0
    ACTION1 = wire.ALERT_CHOICE_ACTION1
    CANCEL = wire.ALERT_CHOICE_CANCEL

    @classmethod
    def _missing_(cls, value: object) -> Any:
        return _vocab_missing(cls, value, "an alert choice",
                              "kaya.AlertChoice.CANCEL")


class NotificationOutcome(enum.IntEnum):
    """A notification's two outcomes (docs/tasks-s3-plan.md N1).
    Dismissal is not one of them: two platforms never report it."""

    ACTIVATED = wire.NOTIFICATION_OUTCOME_ACTIVATED
    REFUSED = wire.NOTIFICATION_OUTCOME_REFUSED

    @classmethod
    def _missing_(cls, value: object) -> Any:
        return _vocab_missing(cls, value, "a notification outcome",
                              "kaya.NotificationOutcome.ACTIVATED")


def show_alert(title: str = "", *, message: str = "",
               actions: Sequence[str] = (), cancel: str | None = None,
               on_result: Callable[[AlertChoice], object] | None = None,
               window: int = 0) -> int:
    """Request a modal alert: up to two action labels (the platform
    floor) plus the REQUIRED cancel label, the slot every
    platform-native dismissal resolves to. on_result(choice) fires
    exactly once and retires. One alert may be live per process; show
    the next from the handler."""
    actions = list(actions)
    if len(actions) > 2:
        raise KayaValueError(
            "an alert carries at most 2 actions (the platform floor)")
    if not cancel:
        raise KayaValueError(
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


def show_notification(notification: int, *, title: str = "", body: str = "",
                      at: int = 0,
                      on_result: Callable[[NotificationOutcome], object] | None = None
                      ) -> int:
    """Post a local notification (docs/tasks-s3-plan.md N1, N2): the
    alert's grammar without a window — the platform shows it outside
    the app. on_result(outcome) fires exactly once and retires, with
    NOTIFICATION_ACTIVATED when the user opened it and
    NOTIFICATION_REFUSED when the platform would not post it. `at` is a
    UNIX time in seconds handed to the OS scheduler where one exists;
    0 posts now. Ids are the GUEST's, and many may be live at once."""
    if not title:
        raise KayaValueError(
            "a notification needs a title — pass title=")
    notification = int(notification)
    app = _app
    if on_result is not None:
        app._notification_handlers[notification] = on_result
    _records().append(
        wire.tx_show_notification(notification, int(at), title, body))
    return notification


def cancel_notification(notification: int) -> None:
    """Withdraw a pending or delivered notification (a reminder that was
    cleared). No answer follows; an unknown id is ignored."""
    _records().append(wire.tx_cancel_notification(int(notification)))


def on_notification_activation(
        f: Callable[[int, NotificationOutcome], object]) -> None:
    """Register the PROCESS-LEVEL notification handler
    (docs/tasks-s9-plan.md R1): f(notification, outcome) receives every
    result whose id has no one-shot handler bound at the show — which is
    the whole of a process the platform RELAUNCHED for a tap, since it
    never called show. It does not retire, and a one-shot handler for
    the same id still wins. Needs no transaction; call it beside the
    scene declaration."""
    _app._notification_activation = f


def link(pattern: str, f: Callable[[dict[str, str]], object]) -> None:
    """Declare a link ROUTE and the handler that answers it
    (docs/app-links-plan.md §4): `kaya.link("task/{key}", f)` matches
    `<scheme>://task/t1` and calls `f({"key": "t1"})`. Segments split on
    `/`, `{name}` captures one segment, a literal segment matches
    itself; the query's pairs join the params and a capture wins a name
    clash.

    PROCESS-LEVEL, `on_notification_activation`'s shape: it does not
    retire and it needs no transaction — declared before the first one
    the record waits and rides the head of it, declared inside a handler
    it rides that handler's. A URL that arrives before the app thread
    exists is delivered first, and one no route matched is announced by
    the core and reaches nothing here.

    NOTHING HERE READS THE PATTERN. The core is the one parser and the
    one author of every refusal — an empty pattern, an empty segment, a
    malformed one, a duplicate — and it faults at apply with the whole
    sentence, where every other declaration refusal in kaya lands
    (tools/check-sugar-surface.py refuses a reason spelled here). The
    one check below is the one a dynamic language cannot avoid."""
    if not isinstance(pattern, str):
        raise KayaTypeError(
            f"kaya: link() takes a route pattern as str ('task/{{key}}'), "
            f"not {type(pattern).__name__}")
    app = _app
    route = app._next("link_route")
    app._link_handlers[route] = f
    app._pending_records.append(wire.tx_declare_link_route(route, pattern))


class _ColumnsTrace(Generic[T]):
    """columns()'s wrapper over the for-statement tracer. The header
    declaration is emitted when the template CLOSES: the core validates
    the row template against the declared arity, so it must follow the
    bodies."""

    def __init__(self, coll: Collection[T], titles: list[str], sort: Sort,
                 on_sort: Handler | None, grow: float | None = None,
                 a11y_id: TextSource | None = None) -> None:
        self._coll = coll
        self._titles = titles
        self._sort = sort
        self._on_sort = on_sort
        self._grow = grow
        self._a11y_id = a11y_id
        # Set by __iter__, which the for-statement always runs first.
        self._trace = cast("_ForTrace[T]", None)

    def __iter__(self) -> _ColumnsTrace[T]:
        self._trace = cast("_ForTrace[T]", iter(self._coll))
        return self

    def __next__(self) -> T:
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


class FileMode(enum.IntEnum):
    """A picked file's open mode. Plain names accepted too —
    `picked.open("write")`."""

    READ = wire.FILE_MODE_READ
    WRITE = wire.FILE_MODE_WRITE
    READ_WRITE = wire.FILE_MODE_READ_WRITE

    @classmethod
    def _missing_(cls, value: object) -> Any:
        if isinstance(value, str):
            try:
                return cls[value.upper()]
            except KeyError:
                raise KayaValueError(
                    f"kaya: file mode must be one of "
                    f"{sorted(m.name.lower() for m in cls)}, got {value!r}"
                ) from None
        raise KayaValueError(
            f"kaya: {value} is not a file mode — the vocabulary is "
            f"{sorted(m.name.lower() for m in cls)} "
            "(kaya.FileMode.READ/WRITE/READ_WRITE)"
        )


def _file_mode_value(mode: FileMode | str | int) -> FileMode:
    # bool BEFORE int, which it subclasses.
    if isinstance(mode, bool) or not isinstance(mode, (str, int)):
        raise KayaTypeError(
            f"kaya: file mode takes kaya.FileMode.READ or its name, not "
            f"{type(mode).__name__}"
        )
    return FileMode(mode)


class PickedFile:
    """One picked file: a handle to redeem, a display name, and
    `local_path` — a RE-OPENABLE NAME, `None` unless re-opening it
    actually works, which measurement puts at the three desktops and
    neither phone (DESIGN.md, File dialogs)."""

    __slots__ = ("handle", "name", "local_path")

    def __init__(self, handle: int, name: str, local_path: str | None) -> None:
        self.handle: int = handle
        self.name: str = name
        self.local_path: pathlib.Path | None = (
            pathlib.Path(local_path) if local_path else None)

    def open(self, mode: FileMode | str | int = FileMode.READ
             ) -> tuple[IO[bytes], bool]:
        """Redeem the handle: returns `(file, seekable)`.

        BLOCKS, possibly for a long time, so call it from a thread you
        chose and post the result back. `seekable` RIDES THE OPEN because
        that is the only place the answer exists — an Android provider
        may hand back a pipe.
        """
        return runtime.open_picked(self.handle, _file_mode_value(mode))

    def __repr__(self) -> str:
        return f"PickedFile(name={self.name!r}, local_path={self.local_path!r})"


def pick_files(*, filters: Sequence[tuple[str, str | Sequence[str]]] = (),
               on_result: Callable[[list[PickedFile]], object] | None = None,
               window: int = 0) -> int:
    """Ask the platform for files. THE PICK, NOT THE OPEN — the result
    carries handles you redeem later.

    `filters` is a sequence of `(label, extensions)` pairs, ADVISORY on
    every platform, so the guest still validates what it got.
    on_result(files) fires exactly once and retires; CANCEL IS THE EMPTY
    LIST. One dialog may be live per process."""
    return _pick(True, filters, on_result, window)


def pick_file(*, filters: Sequence[tuple[str, str | Sequence[str]]] = (),
              on_result: Callable[[list[PickedFile]], object] | None = None,
              window: int = 0) -> int:
    """The single-file spelling. The floor always returns a LIST; this
    only asks the platform for one, so the handler receives zero or one
    file."""
    return _pick(False, filters, on_result, window)


def save_file(suggested_name: str,
              *, filters: Sequence[tuple[str, str | Sequence[str]]] = (),
              on_result: Callable[[PickedFile | None], object] | None = None,
              window: int = 0) -> int:
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
        def one(files: list[PickedFile],
                _handler: Callable[[PickedFile | None], object] = on_result
                ) -> None:
            _handler(files[0] if files else None)
        app._file_dialog_handlers[dialog_id] = one
    _records().append(wire.tx_show_save_dialog(
        int(window), dialog_id, str(suggested_name), _filters(filters)))
    return dialog_id


def _filters(filters: Sequence[tuple[str, str | Sequence[str]]]) -> list[str]:
    """The advisory filter encoding BOTH dialogs share: alternating
    label and space-separated extensions."""
    flat = []
    for label, exts in filters:
        if not isinstance(exts, str):
            exts = " ".join(exts)
        flat.append(str(label))
        flat.append(exts)
    return flat


def _pick(multiple: bool,
          filters: Sequence[tuple[str, str | Sequence[str]]],
          on_result: Callable[[list[PickedFile]], object] | None,
          window: int) -> int:
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
        """Plain text."""

        __slots__ = ("text",)
        __match_args__ = ("text",)

        def __init__(self, text: str) -> None:
            self.text: str = text

        def __repr__(self) -> str:
            return f"Text({self.text!r})"

    class Html:
        """An HTML fragment, as the source app wrote it."""

        __slots__ = ("html",)
        __match_args__ = ("html",)

        def __init__(self, html: str) -> None:
            self.html: str = html

        def __repr__(self) -> str:
            return f"Html({self.html!r})"

    class Image:
        """Encoded image bytes. WHAT COMES BACK MAY BE A RE-ENCODE — the
        hosts convert freely — so never compare the bytes it arrived
        in."""

        __slots__ = ("bytes",)
        __match_args__ = ("bytes",)

        def __init__(self, data: bytes) -> None:
            self.bytes: bytes = data

        def __repr__(self) -> str:
            return f"Image({len(self.bytes)} bytes)"

    class Files:
        """PickedFile, plural INSIDE one representation. A pasted file
        opens with the picker's own call."""

        __slots__ = ("files",)
        __match_args__ = ("files",)

        def __init__(self, files: list[PickedFile]) -> None:
            self.files: list[PickedFile] = files

        def __repr__(self) -> str:
            return f"Files({self.files!r})"

    class Custom:
        """An app-defined format, round-tripped verbatim."""

        __slots__ = ("id", "bytes")
        __match_args__ = ("id", "bytes")

        def __init__(self, id: str, data: bytes) -> None:
            self.id: str = id
            self.bytes: bytes = data

        def __repr__(self) -> str:
            return f"Custom({self.id!r}, {len(self.bytes)} bytes)"


#: One arriving representation: the sum `copy` is the record of.
Clip = (Representation.Text | Representation.Html | Representation.Image
        | Representation.Files | Representation.Custom)


def _representation(payload: tuple[int, list[Any]]) -> Clip | None:
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

    def __init__(self, point: tuple[float, float], operation: str | None,
                 anchor: list[Key], before: bool, clip: Clip | None) -> None:
        self.point: tuple[float, float] = point
        self.operation: str | None = operation
        self.anchor: list[Key] = anchor
        self.before: bool = before
        self.clip: Clip | None = clip

    def __repr__(self) -> str:
        return (f"Dropped(point={self.point!r}, operation={self.operation!r}, "
                f"anchor={self.anchor!r}, before={self.before!r}, "
                f"clip={self.clip!r})")


def _operation(mask: int) -> str | None:
    """The drag_op word, or None for a cancelled or refused drag."""
    if mask == wire.DRAG_OP_COPY:
        return OP_COPY
    if mask == wire.DRAG_OP_MOVE:
        return OP_MOVE
    return None


def _dropped(payload: tuple[Any, ...]) -> Dropped:
    """Turn the decoder's drop tuple into the sum-carrying handle."""
    operation, before, point, anchor, clip, values = payload
    return Dropped(point, _operation(operation), list(anchor), before,
                   _representation((clip, values)))


def _drag_slot(handle: _Handle, keys: Sequence[Key], what: str,
               value: Any) -> int | None:
    """One drag representation's source (docs/dnd-plan.md §4): the row's
    own field, packed as `level << 32 | field` for the slot it fills, or
    None for a constant the caller writes itself.

    `.draggable(text=row.title)` binds the way `label(bind=row.title)`
    does, and every stamped copy resolves it from its own record.
    """
    if isinstance(value, Signal):
        raise KayaTypeError(
            f"kaya: a drag payload's {what} cannot be a signal — a "
            "payload is app-updated state, re-declared when it changes "
            "(docs/dnd-plan.md D1), and inside a For's body it binds a "
            "constant or the row's own field (§4)")
    if isinstance(value, FieldRef):
        level, field = value._level(), value._index
    elif isinstance(value, Element):
        level, field = value._level(), 0
    elif isinstance(value, _CaseElement):
        raise KayaTypeError(
            f"kaya: a drag payload's {what} takes one of the row's "
            "fields (row.title), not a case element — inside a case arm "
            "project the field (docs/dnd-plan.md §4)")
    else:
        return None
    if keys:
        raise KayaStateError(
            f"kaya: draggable_at names ONE stamped copy, whose payload is "
            f"already resolved — bind {what} to the row's field in the "
            "For's body instead (docs/dnd-plan.md §4)")
    if not isinstance(handle, Node):
        raise KayaStateError(
            f"kaya: a live widget's drag payload cannot bind {what} to a "
            "row's field — a live widget is one thing on screen and has "
            "no row (docs/dnd-plan.md §4)")
    return (level << 32) | field


def _template_zone_only(handle: _Handle, what: str) -> None:
    """A keyed drag declaration names ONE STAMPED COPY, so it takes the
    template node the copy was stamped from — a live widget is exactly
    one thing on screen and has no keys (docs/dnd-plan.md §4)."""
    if not isinstance(handle, Node):
        raise KayaStateError(
            f"kaya: {what} names ONE STAMPED COPY — it takes a template "
            "node and that copy's keys, and a live widget is one thing on "
            "screen (docs/dnd-plan.md §4)")


def _operations(operations: Sequence[str]) -> int:
    """The drag_op mask a guest's words name; empty withdraws."""
    mask = 0
    for op in operations:
        if op == OP_COPY:
            mask |= wire.DRAG_OP_COPY
        elif op == OP_MOVE:
            mask |= wire.DRAG_OP_MOVE
        else:
            raise KayaValueError(
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

    def __init__(self, signals: list[tuple[int, Any]],
                 texts: list[tuple[int, tuple[Key, ...], str]],
                 entries: list[tuple[int, tuple[Key, ...], Key,
                                     tuple[int, list[Any]] | None]],
                 orders: list[tuple[int, tuple[Key, ...], list[Key]]]) -> None:
        self.signals: list[tuple[int, Any]] = signals
        self.texts: list[tuple[int, tuple[Key, ...], str]] = texts
        self.entries: list[tuple[int, tuple[Key, ...], Key,
                                 tuple[int, list[Any]] | None]] = entries
        self.orders: list[tuple[int, tuple[Key, ...], list[Key]]] = orders

    def __repr__(self) -> str:
        return (f"UndoDelta(signals={self.signals!r}, texts={self.texts!r}, "
                f"entries={self.entries!r}, orders={self.orders!r})")


class Block:
    """One paragraph kind, carried as the `block` attribute's value
    (docs/rich-text-plan.md R3): drawn by the backend, never stored, so
    the bytes an app and a backend count are the same bytes. Plain names
    accepted too — `set_block("heading1")`."""

    BODY = "body"
    HEADING1 = "heading1"
    HEADING2 = "heading2"
    HEADING3 = "heading3"
    QUOTE = "quote"
    CODE_BLOCK = "code_block"


_BLOCK_NAMES = ("body", "heading1", "heading2", "heading3", "quote",
                "code_block")


def _block_value(kind: object) -> str:
    name = str(kind)
    if name not in _BLOCK_NAMES:
        raise KayaValueError(
            f"kaya: {kind!r} is not a block kind — one of "
            f"{list(_BLOCK_NAMES)} (docs/rich-text-plan.md R3)")
    return name


#: The wire's own spelling of a flag attribute; `_flag_wire` coerces a
#: bool to it at the boundary and `Run.is_flag` reads it back.
FLAG_VALUE = "true"


def _flag_wire(on: bool) -> str:
    return FLAG_VALUE if on else "false"


def _decoded_span(what: str, start: int, stop: int) -> range:
    """A span the CORE sent, refused BY NAME if its ends are out of
    order. No scene reaches it — the core always sends ordered spans —
    and a reversed one means the mirror and the core disagree."""
    if start > stop:
        raise KayaValueError(
            f"kaya: a {what} carries {start}..{stop}, a reversed span")
    return range(start, stop)


class Run:
    """One attribute over one span, in kaya's unit — UTF-8 BYTE offsets
    (docs/ranges-units.md §7). `range` is Python's own `range`, the type
    every write side here already takes. `value` is a URL for a link and
    a kind for a block; a flag attribute carries the wire's own string
    and is read back as `is_flag`."""

    __slots__ = ("range", "name", "value")

    def __init__(self, start: int, end: int, name: object,
                 value: object) -> None:
        self.range: range = range(int(start), int(end))
        self.name: str = str(name)
        self.value: str = str(value)

    @property
    def is_flag(self) -> bool:
        """A flag attribute, on: bold, italic, underline, strike, code."""
        return self.value == FLAG_VALUE

    def __eq__(self, other: object) -> bool:
        return (isinstance(other, Run)
                and (self.range, self.name, self.value)
                == (other.range, other.name, other.value))

    def __hash__(self) -> int:
        return hash((self.range.start, self.range.stop, self.name, self.value))

    def __repr__(self) -> str:
        return (f"Run(start={self.range.start!r}, end={self.range.stop!r}, "
                f"name={self.name!r}, value={self.value!r})")


class Document:
    """A `rich` textarea's text and runs, kept current by the binding
    from the deltas it delivers (docs/rich-text-plan.md R1).

    The marks CHAIN: `kaya.Document(text).bold(range(0, 6))`. A range is
    `range(start, stop)` or a (start, stop) pair of UTF-8 byte offsets,
    as everywhere else in this binding.
    """

    __slots__ = ("text", "runs")

    def __init__(self, text: str = "",
                 runs: Sequence[Run] | None = None) -> None:
        self.text: str = _text_value("Document text", text)
        self.runs: list[Run] = list(runs) if runs else []

    def mark(self, span: Span, name: str, value: bool | str) -> Document:
        """One attribute over one range. `value` takes a bool for a flag
        attribute, coerced to the wire's own string here at the
        boundary. Returns the document."""
        start, stop = _text_range("Document.mark", span)
        if isinstance(value, bool):
            value = _flag_wire(value)
        self.runs.append(Run(start, stop, name, value))
        return self

    def bold(self, span: Span) -> Document:
        return self.mark(span, "bold", "true")

    def italic(self, span: Span) -> Document:
        return self.mark(span, "italic", "true")

    def underline(self, span: Span) -> Document:
        return self.mark(span, "underline", "true")

    def strike(self, span: Span) -> Document:
        return self.mark(span, "strike", "true")

    def code(self, span: Span) -> Document:
        return self.mark(span, "code", "true")

    def link(self, span: Span, url: str) -> Document:
        return self.mark(span, "link", url)

    def block(self, span: Span, kind: str) -> Document:
        """A paragraph's kind; the range covers whole paragraphs or the
        core refuses it, naming the byte."""
        return self.mark(span, "block", _block_value(kind))

    def attr_at(self, byte: int, name: str) -> str | None:
        """The value `name` carries at a byte offset, or None."""
        for run in self.runs:
            if run.name == name and run.range.start <= byte < run.range.stop:
                return run.value
        return None

    def __eq__(self, other: object) -> bool:
        return (isinstance(other, Document)
                and self.text == other.text and self.runs == other.runs)

    def __repr__(self) -> str:
        return f"Document(text={self.text!r}, runs={self.runs!r})"


def _document_bytes(document: Document) -> bytes:
    """A Document's wire bytes: ONE flat value list — the text, then four
    values per run (crates/kaya/src/wire.rs, `document_blob`)."""
    values = [document.text]
    for run in document.runs:
        values += [run.range.start, run.range.stop, run.name, run.value]
    return wire._enc.values(values)


def _encode_document_field(value: object) -> wire.BlobHandle:
    """A Document field's wire value (docs/rich-text-plan.md §19): the
    blob a stamped copy's `document` prop reads, registered like any
    other blob field's bytes."""
    if not isinstance(value, Document):
        raise KayaTypeError(
            f"kaya: a Document field takes a kaya.Document, not "
            f"{type(value).__name__}")
    return wire.BlobHandle(runtime.register_blob(_document_bytes(value)))


def _decode_document_field(data: object) -> Document:
    """`_document_bytes`' inverse, for a row an undo restored: the delta
    carries the field as a blob, redeemed to bytes by the decoder
    (crates/kaya/src/wire.rs, `read_document_blob`)."""
    if not isinstance(data, (bytes, bytearray)):
        raise KayaTypeError(
            f"kaya: a restored Document field carries bytes, not "
            f"{type(data).__name__}")
    count = int.from_bytes(data[0:4], "little")
    values, at = [], 8
    for _ in range(count):
        value, at = wire.parse_value(data, at)
        values.append(value)
    if not values or not isinstance(values[0], str):
        raise KayaValueError(
            "kaya: a document blob starts with its text; this one holds "
            f"{len(values)} value(s)")
    runs = [Run(*values[i:i + 4]) for i in range(1, len(values), 4)]
    return Document(values[0], runs)


# A Document field IS a Blob field carrying `_document_bytes`' list, so
# it binds through the template zone as a String field does
# (docs/rich-text-plan.md §19). Registered here rather than in the table
# above, which is written before the class exists.
_WIRE_TYPES.append((Document, wire.VALUE_BLOB))
_FIELD_ENCODERS[Document] = _encode_document_field
_FIELD_DECODERS[Document] = _decode_document_field


class EditSource:
    """What provoked an edit the widget reports (docs/rich-text-plan.md
    §2; the review page's ruling 3, 2026-09-14)."""

    USER = "user"
    IME_COMMIT = "ime_commit"
    PASTE = "paste"
    NATIVE_UNDO = "native_undo"
    DROP = "drop"


_EDIT_SOURCES = {
    wire.EDIT_SOURCE_USER: "user",
    wire.EDIT_SOURCE_IME_COMMIT: "ime_commit",
    wire.EDIT_SOURCE_PASTE: "paste",
    wire.EDIT_SOURCE_NATIVE_UNDO: "native_undo",
    wire.EDIT_SOURCE_DROP: "drop",
}


def _edit_source(source: int) -> str:
    name = _EDIT_SOURCES.get(int(source))
    if name is None:
        raise KayaValueError(
            f"kaya: text_edited carries edit source {int(source)}, which "
            f"this build does not know")
    return name


class Edit:
    """Replace `start..end` with `inserted`, whose `runs` carry offsets
    RELATIVE to the inserted text (docs/rich-text-plan.md R1). `source`
    is what provoked an edit the widget delivered and None on one the app
    builds; `apply_edit` sends nothing of it."""

    __slots__ = ("range", "inserted", "runs", "source")

    def __init__(self, start: int, end: int, inserted: str = "",
                 runs: Sequence[Run] | None = None) -> None:
        self.range: range = range(int(start), int(end))
        self.inserted: str = _text_value("Edit text", inserted)
        self.runs: list[Run] = list(runs) if runs else []
        self.source: str | None = None

    @classmethod
    def insert(cls, at: int, text: str) -> Edit:
        return cls(at, at, text)

    @classmethod
    def delete(cls, span: Span) -> Edit:
        start, stop = _text_range("Edit.delete", span)
        return cls(start, stop, "")

    @classmethod
    def replace(cls, span: Span, text: str) -> Edit:
        start, stop = _text_range("Edit.replace", span)
        return cls(start, stop, text)

    def mark(self, span: Span, name: str, value: bool | str) -> Edit:
        """One attribute over the INSERTED text's own offsets. `value`
        takes a bool for a flag attribute, coerced to the wire's own
        string here at the boundary. Returns the edit."""
        start, stop = _text_range("Edit.mark", span)
        if isinstance(value, bool):
            value = _flag_wire(value)
        self.runs.append(Run(start, stop, name, value))
        return self

    def __eq__(self, other: object) -> bool:
        return (isinstance(other, Edit)
                and (self.range, self.inserted, self.runs, self.source)
                == (other.range, other.inserted, other.runs, other.source))

    def __repr__(self) -> str:
        return (f"Edit(start={self.range.start!r}, end={self.range.stop!r}, "
                f"inserted={self.inserted!r}, runs={self.runs!r}, "
                f"source={self.source!r})")


class Format:
    """A toolbar act over a range; `value` None is the attribute taken
    off (docs/rich-text-plan.md R1)."""

    __slots__ = ("range", "name", "value")

    def __init__(self, start: int, end: int, name: object,
                 value: object) -> None:
        self.range: range = range(int(start), int(end))
        self.name: str = str(name)
        self.value: str | None = None if value is None else str(value)

    @property
    def is_flag(self) -> bool:
        """A flag attribute, on."""
        return self.value == FLAG_VALUE

    def __eq__(self, other: object) -> bool:
        return (isinstance(other, Format)
                and (self.range, self.name, self.value)
                == (other.range, other.name, other.value))

    def __repr__(self) -> str:
        return (f"Format(start={self.range.start!r}, end={self.range.stop!r}, "
                f"name={self.name!r}, value={self.value!r})")


def _normalize_runs(runs: Sequence[Run]) -> list[Run]:
    """The core's normal form (crates/kaya/src/scene.rs, RichDoc::
    normalize), so the mirror and the core's document spell one string."""
    out = []
    for name in sorted({run.name for run in runs}):
        painted = []
        for run in [r for r in runs if r.name == name]:
            if run.range.start >= run.range.stop:
                continue
            kept = []
            for old in painted:
                if old.range.stop <= run.range.start or old.range.start >= run.range.stop:
                    kept.append(old)
                    continue
                if old.range.start < run.range.start:
                    kept.append(Run(old.range.start, run.range.start, old.name, old.value))
                if old.range.stop > run.range.stop:
                    kept.append(Run(run.range.stop, old.range.stop, old.name, old.value))
            kept.append(Run(run.range.start, run.range.stop, run.name, run.value))
            painted = kept
        painted.sort(key=lambda r: r.range.start)
        merged = []
        for run in painted:
            if merged and merged[-1].range.stop == run.range.start \
                    and merged[-1].value == run.value:
                merged[-1].range = range(merged[-1].range.start,
                                         run.range.stop)
            else:
                merged.append(Run(run.range.start, run.range.stop, run.name, run.value))
        out += merged
    out.sort(key=lambda r: (r.range.start, r.name))
    return out


def _runs_from(flat: Sequence[Any]) -> list[Run]:
    """The decoder's flat run tail, read in FOURS. A reversed span is
    refused naming the record (`_decoded_span`)."""
    out = []
    for i in range(0, len(flat), 4):
        _decoded_span("run", int(flat[i]), int(flat[i + 1]))
        out.append(Run(flat[i], flat[i + 1], flat[i + 2], flat[i + 3]))
    return out


def _flat_runs(runs: Sequence[Run]) -> list[Any]:
    """`_runs_from`'s inverse: the wire's four values per run."""
    flat = []
    for run in runs:
        flat += [run.range.start, run.range.stop, run.name, run.value]
    return flat


def _on_boundary(data: bytes, at: int) -> bool:
    """Whether a byte offset falls on a code-point boundary of `data`
    (Rust's str::is_char_boundary, in the unit the wire counts): past the
    end is not one."""
    if at > len(data):
        return False
    return at == len(data) or (data[at] & 0xC0) != 0x80


def _fold_edit(doc: Document, start: int, stop: int, inserted: str,
               runs: Sequence[Run]) -> None:
    """One edit folded into a document: runs before it keep, runs after it
    shift, a run the edit falls inside is cut, and the inserted text's own
    runs land relative to the edit (crates/kaya/src/app.rs, fold_edit)."""
    data = doc.text.encode("utf-8")
    added = inserted.encode("utf-8")
    if stop > len(data) or not _on_boundary(data, start) \
            or not _on_boundary(data, stop):
        # A mirror out of step with the core takes the edit whole
        # rather than splicing at an offset that means nothing here.
        doc.text = inserted
        doc.runs = [Run(r.range.start, r.range.stop, r.name, r.value) for r in runs]
        return
    shift = len(added) - (stop - start)
    nxt = []
    for run in doc.runs:
        if run.range.start < start:
            nxt.append(Run(run.range.start, min(run.range.stop, start), run.name,
                           run.value))
        if run.range.stop > stop:
            nxt.append(Run(max(run.range.start, stop) + shift, run.range.stop + shift,
                           run.name, run.value))
    for run in runs:
        nxt.append(Run(run.range.start + start, run.range.stop + start, run.name,
                       run.value))
    doc.text = (data[:start] + added + data[stop:]).decode("utf-8")
    doc.runs = _normalize_runs(nxt)


def _fold_format(doc: Document, start: int, stop: int, name: str,
                 value: str | None) -> None:
    """One toolbar act folded into a document: the attribute put over the
    range or taken off it, clipping THIS attribute's runs and no other
    (crates/kaya/src/app.rs, fold_format)."""
    if start >= stop:
        return
    nxt = []
    for run in doc.runs:
        if run.name != name or run.range.stop <= start or run.range.start >= stop:
            nxt.append(run)
            continue
        if run.range.start < start:
            nxt.append(Run(run.range.start, start, run.name, run.value))
        if run.range.stop > stop:
            nxt.append(Run(stop, run.range.stop, run.name, run.value))
    if value is not None:
        nxt.append(Run(start, stop, name, value))
    doc.runs = _normalize_runs(nxt)


def _accept_list(kinds: Sequence[Any]) -> str:
    """Join an accept list: the closed kinds by name plus any custom ids,
    space separated.

    Ids reach every platform's registry verbatim and carry NO SPACES,
    which is what makes the join unambiguous.
    """
    out = []
    for kind in kinds:
        kind = str(kind)
        if not kind or " " in kind:
            raise KayaValueError(
                f"kaya: {kind!r} is not an accept-list entry — the closed "
                "kinds are 'text', 'html', 'image' and 'files', and a "
                "custom format id reaches the platform's own registry "
                "verbatim, so it carries no spaces")
        out.append(kind)
    return " ".join(out)


def copy(*, text: str | None = None, html: str | None = None,
         image: bytes | None = None, files: Sequence[PickedFile] = (),
         custom: Mapping[str, bytes] | None = None) -> None:
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


def read_clipboard(accepting: Sequence[str], *,
                   on_result: Callable[[Clip | None], object] | None = None
                   ) -> int:
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
# receive the stamped copy's `Row` FIRST.


class MenuItem:
    """A live menu item in its OWN id space, never a widget or node id.
    One command identity: exactly one parent or anchor, forever."""

    def __init__(self, id: int) -> None:
        self.id = id

    def label(self, value: TextSource) -> None:
        """Rename the item: constant text or a bound Str signal.
        Label writes never emit anything."""
        if isinstance(value, Signal):
            _records().append(wire.tx_bind_menu_label(self.id, value.id))
        else:
            _records().append(
                wire.tx_set_menu_label(self.id, _text_value("menu label", value)))

    def enabled(self, value: bool | Signal[Any]) -> None:
        """Whether the item is enabled (default true): a constant or a
        bound Bool signal. Disabling a grouping node disables its
        subtree."""
        if isinstance(value, Signal):
            _records().append(wire.tx_bind_menu_enabled(self.id, value.id))
        else:
            _records().append(wire.tx_set_menu_enabled(self.id, bool(value)))

    def checked(self, value: bool | Signal[Any]) -> None:
        """A toggle's state (toggle items only — root-checked). The
        programmatic write is QUIET: no menu_toggled echo."""
        if isinstance(value, Signal):
            _records().append(wire.tx_bind_menu_checked(self.id, value.id))
        else:
            _records().append(wire.tx_set_menu_checked(self.id, bool(value)))

    def value(self, v: float | Signal[Any]) -> None:
        """A radio group's selected option index (radio groups only —
        root-checked). QUIET, like checked."""
        if isinstance(v, Signal):
            _records().append(wire.tx_bind_menu_value(self.id, v.id))
        else:
            _records().append(wire.tx_set_menu_value(self.id, float(v)))

    def icon(self, data: bytes) -> None:
        """The item's icon (the blob channel): used by phone promotion,
        ignored where native menu dress has no icons. Const-only."""
        _records().append(
            wire.tx_set_menu_icon(self.id, runtime.register_blob(data)))

    def symbol(self, symbol: Symbol | str) -> None:
        """The item's SEMANTIC ICON (`kaya.Symbol`, or its name): the
        closed concept vocabulary each backend maps to its own platform's
        symbol set. No symbol on a separator. Const-only."""
        _records().append(
            wire.tx_set_menu_symbol(self.id, _symbol_value(symbol)))

    def primary(self, on: bool) -> None:
        """The phone-bar promotion hint (actions only — root-checked).
        INERT on desktops. Const-only."""
        _records().append(wire.tx_set_menu_primary(self.id, bool(on)))

    def role(self, name: MenuRole | str) -> None:
        """Declare this action a standard command (actions only).
        PLACEMENT is each host's business. One item per role, and a role
        NEVER invents a chord. Const-only."""
        _records().append(wire.tx_set_menu_role(self.id, MenuRole(name).value))

    def shortcut(self, spelling: str) -> None:
        """The shortcut of any LEAF command (window-anchored only),
        canonicalized by wire.canonicalize_shortcut. It fires the SAME
        menu_activated occurrence as a click. Const-only."""
        _records().append(wire.tx_set_menu_shortcut(self.id, spelling))

    def append(self) -> _MenuScope[MenuItem]:
        """Reopen this RETAINED grouping node. The root re-validates each
        appended subtree in the item's real anchor context."""
        return _MenuScope(("item", self.id), shortcut_ok=True,
                          value=cast("MenuItem", self))


class ContextCatalog:
    """A context catalog built free of any anchor, for a template node:
    menu items are live and shared across stamped copies, so it is built
    in the LIVE zone and node.context_menu(catalog) attaches it."""

    def __init__(self) -> None:
        self._roots: list[int] = []
        self._attached = False
        #: the For the attach found (Row's owner)
        self._owner: Collection[Any] | None = None


class _MenuScope(_Scope[T]):
    """A with-block whose creators seat under one menu anchor. on_exit
    runs after the block's children recorded, which is THE RADIO VALUE'S
    SEAT: the selected index must land AFTER the options it
    addresses."""

    @overload
    def __init__(self: _MenuScope[None], seat: tuple[str, Any],
                 shortcut_ok: bool) -> None: ...

    @overload
    def __init__(self: _MenuScope[R], seat: tuple[str, Any],
                 shortcut_ok: bool, value: R,
                 on_exit: Callable[[], None] | None = None) -> None: ...

    def __init__(self, seat: tuple[str, Any], shortcut_ok: bool,
                 value: Any = None,
                 on_exit: Callable[[], None] | None = None) -> None:
        self._seat = seat  # ("item", id) | ("widget", id) | ("free", catalog)
        self._shortcut_ok = shortcut_ok
        self._value = value
        self._on_exit = on_exit

    def _enter(self) -> T:
        _menu_scopes.append(self)
        return self._value

    def _exit(self) -> None:
        _menu_scopes.pop()
        if self._on_exit is not None:
            self._on_exit()


def _menu_create(kind: int, label: TextSource | None = None) -> MenuItem:
    """Create one menu item in its own id space; menu records are
    live-zone only (a template body records a blueprint — build the
    catalog outside and attach with node.context_menu)."""
    if _tpl_depth > 0:
        raise KayaStateError(
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


def _menu_seat(item: MenuItem) -> _MenuScope[Any]:
    """Seat a just-created item under the open scope's anchor and
    return the scope (for the shortcut rule)."""
    if not _menu_scopes:
        raise KayaStateError(
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
        _app._item_catalogs[item.id] = target
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


class MenuRole(str, enum.Enum):
    """THE CLOSED MENU-ROLE VOCABULARY (DESIGN.md, Menus;
    crates/kaya/src/scene.rs MENU_ROLES). SETTINGS goes in the
    application menu on macOS and stays where the app declared it
    everywhere else; CUT/COPY/PASTE are the gesture layer, lowering to
    the platform's own and acting on the FOCUSED widget; UNDO/REDO ask
    the focused widget's own history before the window's ledger
    (docs/undo-plan.md D6). A str Enum, so the wire value IS the member
    and a plain name is accepted too — `role="undo"`."""

    SETTINGS = "settings"
    CUT = "cut"
    COPY = "copy"
    PASTE = "paste"
    UNDO = "undo"
    REDO = "redo"

    @classmethod
    def _missing_(cls, value: object) -> Any:
        return _vocab_missing(cls, value, "a menu role", "kaya.MenuRole.UNDO")



def _menu_require_catalog(scope: _MenuScope[Any]) -> None:
    """A chord and a role both need a window catalog as their home: the
    root rejects either on a context anchor, and this says so at the call
    site."""
    if not scope._shortcut_ok:
        raise KayaValueError(
            "kaya: a context item takes no shortcut — a shortcut "
            "needs a window catalog as its native dispatch home"
        )


def item(label: TextSource, *, shortcut: str | None = None,
         enabled: bool | Signal[Any] | None = None, icon: bytes | None = None,
         symbol: Symbol | str | None = None, primary: bool | None = None,
         role: MenuRole | str | None = None,
         on_activate: Handler | None = None) -> MenuItem:
    """An action — a leaf command firing exactly one menu_activated
    occurrence, whether from a click or its shortcut. On a template-node
    catalog the handler receives the stamped copy's `Row` first."""
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
            raise KayaValueError(
                "kaya: a context item takes no role — a role names a "
                "standard command in the window catalog"
            )
        it.role(role)
    if on_activate is not None:
        _app._menu_handlers[(wire.OCC_MENU_ACTIVATED, it.id)] = on_activate
    return it


def toggle(label: TextSource, *, checked: bool | Signal[Any] | None = None,
           enabled: bool | Signal[Any] | None = None,
           icon: bytes | None = None, symbol: Symbol | str | None = None,
           shortcut: str | None = None,
           on_toggle: Handler | None = None) -> MenuItem:
    """A toggle — a stateful leaf: user flips emit menu_toggled (the
    handler receives the new state, template-node copies their `Row`
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


def option(label: TextSource, *, enabled: bool | Signal[Any] | None = None,
           icon: bytes | None = None, symbol: Symbol | str | None = None,
           shortcut: str | None = None) -> MenuItem:
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


def separator() -> None:
    """Native grouping chrome: no label, no props, no handle kept."""
    it = _menu_create(wire.MENU_KIND_SEPARATOR)
    _menu_seat(it)


def menu(label: TextSource, *, enabled: bool | Signal[Any] | None = None,
         icon: bytes | None = None,
         symbol: Symbol | str | None = None) -> _MenuScope[MenuItem]:
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


def radio_group(label: TextSource, *, value: float | Signal[Any] | None = None,
                enabled: bool | Signal[Any] | None = None,
                icon: bytes | None = None,
                symbol: Symbol | str | None = None,
                on_select: Handler | None = None) -> _MenuScope[MenuItem]:
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


def context_catalog() -> _MenuScope[ContextCatalog]:
    """Build a context catalog UNANCHORED — free root items for a
    template-node anchor, built in the LIVE zone. Context items take no
    shortcuts."""
    catalog = ContextCatalog()
    return _MenuScope(("free", catalog), shortcut_ok=False, value=catalog)


def window_size(width: float, height: float) -> None:
    """Request the primary surface's content size (DIP). ADVISORY on
    every platform — a request, never a guarantee."""
    _records().append(wire.tx_set_window_width(0, float(width)))
    _records().append(wire.tx_set_window_height(0, float(height)))


def _accent(what: str, value: object) -> int:
    """The wire field's domain, and NOTHING SEMANTIC. A bool is excluded
    BEFORE int, which it subclasses: `True` would silently become the
    colour 0x000001.

    THE 24-BIT RULE IS DELIBERATELY NOT HERE — it dies at the ROOT's
    wall, in one sentence every language gets (invariant 1).
    """
    if isinstance(value, bool) or not isinstance(value, int):
        raise KayaTypeError(
            f"kaya: brand accent {what} takes one packed sRGB int "
            f"(0x3584E4), not {type(value).__name__} — brand is identity, "
            "set once before the first mount, so it is never a signal"
        )
    if not 0 <= value <= 0xFFFFFFFF:
        raise KayaValueError(
            f"kaya: brand accent {what} is {value:#x}, which does not fit "
            "the wire's u32 — the accent is one packed sRGB hex (0x3584E4)"
        )
    return value


def brand_accent(seed: int, *, light: int | None = None,
                 dark: int | None = None) -> None:
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


class Platform(enum.IntEnum):
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

    @classmethod
    def _missing_(cls, value: object) -> Any:
        if isinstance(value, str):
            try:
                return cls[value.upper()]
            except KeyError:
                raise KayaValueError(
                    f"kaya: brand_typeface: {value!r} is not a platform — "
                    f"the vocabulary is "
                    f"{sorted(m.name.lower() for m in cls)}"
                ) from None
        raise KayaValueError(
            f"kaya: brand_typeface: {value} is not a platform — the "
            f"vocabulary is {sorted(m.name.lower() for m in cls)} "
            "(kaya.Platform.MAC/IOS/LINUX/WINDOWS/ANDROID)"
        )


class SizeClass:
    """A window's named size class (spec enum "size_class"): what
    `row(stack_when=...)` speaks in place of an author-invented width.
    COMPACT is the whole surface today — the platform's own class on iOS,
    narrower than 600 points everywhere else.
    """

    def __init__(self, tag: int, name: str) -> None:
        self._tag = tag
        self._name = name

    def __repr__(self) -> str:
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


def _platform_value(platform: Platform | str | int) -> Platform:
    """One platform tag, from either spelling, refused here if it is
    neither.

    WHAT STAYS THE ROOT'S, deliberately: naming one platform TWICE (two
    spellings of the same row are two dict keys) and an empty family.
    """
    # bool BEFORE int, which it subclasses: `{True: "Georgia"}` would
    # otherwise read as platform 1, mac.
    if isinstance(platform, bool) or not isinstance(platform, (str, int)):
        raise KayaTypeError(
            f"kaya: brand_typeface: a per-platform key is kaya.Platform.LINUX "
            f"or its name, not {type(platform).__name__} — an app names the "
            "platforms it has a family for; it never asks which one it is"
        )
    return Platform(platform)


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

    def __init__(self, handle: int, name: str) -> None:
        self._handle = handle
        self._name = name

    @property
    def name(self) -> str:
        """The name this asset was asked for — what `asset(name)` was
        given, not a path. Android has no path to hand back."""
        return self._name

    def bytes(self) -> bytes:
        """The asset's bytes, copied out of core memory. RAISES if the
        asset is closed rather than answering `b""`."""
        self._alive("bytes()")
        return runtime.asset_bytes(self._handle)

    def reader(self) -> io.BytesIO:
        """The asset as a file-like object: `io.BytesIO` over a copy of
        the bytes."""
        return io.BytesIO(self.bytes())

    def _blob(self) -> int:
        """Register the core's own bytes into the pending table and
        return the handle the next submit consumes — no copy, nothing
        through Python."""
        self._alive("a blob redemption")
        return runtime.asset_blob(self._handle)

    def close(self) -> None:
        """Release the core's handle. Idempotent, and the finalizer
        calls it too."""
        handle, self._handle = self._handle, 0
        if handle:
            runtime.asset_release(handle)

    def _alive(self, what: str) -> None:
        if not self._handle:
            raise KayaStateError(
                f"kaya: {what} on a closed asset ({self._name!r}) — the "
                "handle was released, and the bytes it borrowed are the "
                "core's. Read inside the `with`, or keep the bytes rather "
                "than the asset."
            )

    def __len__(self) -> int:
        self._alive("len()")
        return runtime.asset_len(self._handle)

    def __enter__(self) -> Asset:
        return self

    def __exit__(self, *_exc: Any) -> Literal[False]:
        self.close()
        return False

    def __del__(self) -> None:
        # Deliberately SILENT: interpreter teardown can already have
        # torn down what close() reaches, and a raising finalizer prints
        # an unraisable-exception warning.
        try:
            self.close()
        except Exception:
            pass

    def __repr__(self) -> str:
        state = "closed" if not self._handle else f"{len(self)} bytes"
        return f"Asset(name={self._name!r}, {state})"


def asset(name: str) -> Asset:
    """Open an asset — a file the app's own BUILD shipped beside it,
    named by a relative path under the asset root.

    Callable anywhere, including outside a transaction. A MISS RAISES
    WITH THE CORE'S SENTENCE AND NOTHING ADDED, so every binding's guest
    is handed the same bytes and one scene can freeze them. EACH CALL
    READS: no cache, no watch, no reload.
    """
    if not isinstance(name, str):
        raise KayaTypeError(
            f"kaya: asset() takes a name as str ('fonts/sora-wght.ttf'), "
            f"not {type(name).__name__} — a relative path under the asset "
            "root, spelled with `/` on every platform"
        )
    handle = runtime.asset_open(name)
    if handle:
        return Asset(handle, name)
    sentence = runtime.asset_miss_sentence(name)
    raise KayaStateError(sentence or (
        # Reachable only if the two calls disagree: the open answered a
        # miss and the why-not answered that it resolves.
        f"kaya: asset({name!r}) did not open, and the core's own why-not "
        "answers that it resolves — those two facts were measured a "
        "moment apart, and this binding has nothing further to report"
    ))


def asset_miss_sentence(name: str) -> str:
    """Why `asset(name)` would fail — the sentence it would raise, handed
    over without raising. `""` means the name resolves.

    Line 1 (name, rule, census) is the same on every platform and is the
    line a scene freezes; line 2 names the resolved place.
    """
    if not isinstance(name, str):
        raise KayaTypeError(
            f"kaya: asset_miss_sentence() takes a name as str "
            f"('fonts/sora-wght.ttf'), not {type(name).__name__} — a "
            "relative path under the asset root, spelled with `/` on "
            "every platform"
        )
    return runtime.asset_miss_sentence(name)


def _blob_of(source: Asset | bytes | bytearray | memoryview) -> int:
    """The one place a blob-taking consumer turns its argument into a
    handle: an `Asset` redeems, bytes register."""
    return source._blob() if isinstance(source, Asset) \
        else runtime.register_blob(source)


def _typeface_family(what: str, family: object) -> str:
    """The wire field's domain and NOTHING SEMANTIC.

    THE EMPTY FAMILY IS DELIBERATELY NOT REFUSED HERE — that sentence is
    the ROOT's, so every language reads the same one (invariant 1).
    """
    if not isinstance(family, str):
        raise KayaTypeError(
            f"kaya: brand_typeface {what} takes a family NAME as str "
            f"('Georgia'), not {type(family).__name__} — a font FILE's bytes "
            "ride the font= slot, which is a different thing"
        )
    return family


def brand_typeface(family: str,
                   platforms: Mapping[Platform | str | int, str] | None = None,
                   *, font: Asset | bytes | bytearray | memoryview | None = None
                   ) -> None:
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
            raise KayaTypeError(
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
        raise KayaTypeError(
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


def app_identity() -> None:
    """DECLARE the app's identity (docs/app-identity-plan.md,
docs/tasks-s3-plan.md N4). NO ARGUMENTS: the name it goes by, the
picture that stands for it and the reverse-DNS id it registers under
are the asset root's own identity.toml, which the BUILD already reads,
and the core reads the same file. Set ONCE, before the first mount.

STILL AN EXPLICIT CALL, because declaring an identity is a POLICY: a
declared app is a Dock app on macOS (ruling 1), so an app that wants
the platform's own identity declares none at all.
    """
    # THE SLOTS RIDE EMPTY and the root fills them: mask 0, no name, no
    # blob. The record's shape is fixed, so the icon slot is written
    # either way, as an empty Str.
    _records().append(wire.tx_set_app_identity(0, "", ""))


#: The undo-group record's kind, in the two header bytes `record()`
#: frames it with — how `undoable` recognises a marker already at the
#: head without unpacking anything.
_UNDO_GROUP_TAG = wire.TX_UNDO_GROUP.to_bytes(2, "little")


def undoable(label: str, *, window: int = 0) -> None:
    """Make THIS transaction one undoable step in `window`'s history,
    under `label` (docs/undo-plan.md D2).

    The marker goes AT THE HEAD of the batch wherever this call sits.
    THE UNDOABLE SET IS THE REACTIVE HALF (D4): signal writes and the
    five collection deltas. Pure effects (focus) ride along unrestored;
    anything else is REFUSED at apply, naming the op.
    """
    text = _text_value("undoable", label)
    if not text:
        raise KayaValueError(
            "kaya: an undo group needs a name — the EMPTY label is taken: "
            "it is how a typing episode identifies itself on the same "
            "occurrence, so an anonymous group would be indistinguishable "
            "from the native tier"
        )
    records = _records()
    if records and records[0][4:6] == _UNDO_GROUP_TAG:
        raise KayaStateError(
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

    #: This process can post a local notification the desktop will show
    #: (docs/tasks-s3-plan.md N3). A RUNTIME bit: the host measures it.
    notifications: bool


def capabilities() -> Capabilities:
    """This host's capabilities, constant for the life of the process."""
    bits = runtime.capability_bits()
    return Capabilities(
        aux_windows=bool(bits & runtime.CAP_AUX_WINDOWS),
        notifications=bool(bits & runtime.CAP_NOTIFICATIONS))


def app_data_dir() -> pathlib.Path:
    """The app's OWN writable directory (docs/tasks-s4-plan.md P1):
    Application Support/<id> on macOS, Documents on iOS, the files
    directory on Android, $XDG_DATA_HOME/<id> on Linux,
    %LOCALAPPDATA%\\<id> on Windows. Created on first ask; None where
    the host has not handed one over yet.

    KAYA OWNS THE PLACE AND NOTHING ELSE: the app's document is the
    app's, written the standard way (sqlite3 is the recommendation).
    Settings are small and typed and belong in `prefs()`.

    REFUSES where the platform has handed no directory over — an error
    state a guest cannot plan around, so all nine bindings raise rather
    than answering an absent value (ruled 2026-09-09).
    """
    answer = runtime.app_data_dir()
    if answer is None:
        raise KayaStateError(
            "kaya: app_data_dir asked before the platform handed one "
            "over (Android before attach)")
    return pathlib.Path(answer)


def _pref_key(key: object) -> str:
    key = str(key)
    if not key:
        raise KayaValueError("kaya: a preference key must not be empty")
    return key


def _pref_write_key(key: object) -> str:
    """A guest may READ any key and WRITE any key kaya has not reserved
    (docs/tasks-s4-plan.md P4: window memory lives under `kaya.`)."""
    key = _pref_key(key)
    if key.startswith("kaya."):
        raise KayaValueError(
            f'kaya: preference key "{key}" is reserved '
            "(the kaya. prefix is kaya's own)")
    return key


class Prefs:
    """The app's preferences store (docs/tasks-s4-plan.md P2/P3): a
    small typed key-value record under the app's id, the platform's own
    where the platform has one — UserDefaults on Apple,
    SharedPreferences on Android, a key file on Linux and Windows.

    A PULL, NOT A SIGNAL: a setting is read when the app builds and
    written when the user changes it. Every get takes the default it
    answers when the key is absent OR holds another type. Writes are
    durable when they return, and the store may be used from any
    thread.
    """

    @overload
    def get(self, key: str, default: bool) -> bool: ...

    @overload
    def get(self, key: str, default: int) -> int: ...

    @overload
    def get(self, key: str, default: float) -> float: ...

    @overload
    def get(self, key: str, default: str) -> str: ...

    def get(self, key: str, default: bool | int | float | str) -> Any:
        """Read a preference, DISPATCHING ON `default`'s TYPE — bool
        before int, since bool subclasses int. Answers `default` when
        the key is absent or holds another type (§4)."""
        if isinstance(default, bool):
            value = runtime.pref_get_bool(_pref_key(key))
        elif isinstance(default, int):
            value = runtime.pref_get_i64(_pref_key(key))
        elif isinstance(default, float):
            value = runtime.pref_get_f64(_pref_key(key))
        elif isinstance(default, str):
            value = runtime.pref_get_string(_pref_key(key))
        else:
            raise KayaTypeError(
                f"kaya: a preference's default is a bool, int, float or "
                f"str, not {type(default).__name__}"
            )
        return default if value is None else value

    def set(self, key: str, value: bool | int | float | str) -> None:
        """Write a preference, dispatching on `value`'s type — bool
        before int."""
        if isinstance(value, bool):
            runtime.pref_set_bool(_pref_write_key(key), value)
        elif isinstance(value, int):
            runtime.pref_set_i64(_pref_write_key(key), value)
        elif isinstance(value, float):
            runtime.pref_set_f64(_pref_write_key(key), value)
        elif isinstance(value, str):
            runtime.pref_set_string(_pref_write_key(key), value)
        else:
            raise KayaTypeError(
                f"kaya: a preference's value is a bool, int, float or "
                f"str, not {type(value).__name__}"
            )

    def remove(self, key: str) -> None:
        runtime.pref_remove(_pref_write_key(key))


_PREFS = Prefs()


def prefs() -> Prefs:
    """The app's preferences store — one per process."""
    return _PREFS


def signal(initial: V) -> Signal[V]:
    """Declare a signal holding `initial` — the app's write channel for
    one scalar the platform draws."""
    handle: Signal[V] = Signal(_app._next("signal"), initial)
    # By id, for the undo path: a restored value arrives as a signal id
    # and has to reach the binding's own cache (App._absorb_undo).
    _app._signals[handle.id] = handle
    _records().append(wire.tx_create_signal(handle.id, _wire_scalar(initial)))
    return handle


@overload
def collection() -> Collection[str]: ...


@overload
def collection(record_type: type[T]) -> Collection[T]: ...


@overload
def collection(record_type: types.UnionType) -> Collection[Any]: ...


def collection(record_type: Any = None) -> Collection[Any]:
    """Declare a collection. With no argument, a scalar (str) table —
    the one-field case. With a dataclass, a record collection: the
    dataclass IS the schema (wire-typed fields, declaration order), and
    `element.field` / `patch(key, field=...)` project it.

    A SUM's element type is `Any`: `Note | Todo` in a value position is
    `types.UnionType`, which carries no member types, so the case arms'
    own `cases.case(Cls)` is what names a constructor there."""
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


class Align(enum.IntEnum):
    """The align enum: a container's cross-axis child placement. Plain
    names accepted too — `align="center"`."""

    START = wire.ALIGN_START
    CENTER = wire.ALIGN_CENTER
    END = wire.ALIGN_END
    STRETCH = wire.ALIGN_STRETCH
    BASELINE = wire.ALIGN_BASELINE

    @classmethod
    def _missing_(cls, value: object) -> Any:
        if isinstance(value, str):
            try:
                return cls[value.upper()]
            except KeyError:
                raise KayaValueError(
                    f"kaya: align must be one of "
                    f"{sorted(m.name.lower() for m in cls)}, got {value!r}"
                ) from None
        raise KayaValueError(
            f"kaya: {value} is not an align — the vocabulary is "
            f"{sorted(m.name.lower() for m in cls)}"
        )


class Axis(enum.IntEnum):
    """The axis enum: a container's arrangement direction — row and
    column are one node whose constructor names the initial value
    (docs/adaptive-layout-plan.md D1). Plain names accepted too."""

    HORIZONTAL = wire.AXIS_HORIZONTAL
    VERTICAL = wire.AXIS_VERTICAL

    @classmethod
    def _missing_(cls, value: object) -> Any:
        if isinstance(value, str):
            try:
                return cls[value.upper()]
            except KeyError:
                raise KayaValueError(
                    f"kaya: axis must be one of "
                    f"{sorted(m.name.lower() for m in cls)}, got {value!r}"
                ) from None
        raise KayaValueError(
            f"kaya: {value} is not an axis — the vocabulary is "
            f"{sorted(m.name.lower() for m in cls)}"
        )


def _axis_value(axis: Axis | str | int) -> Axis:
    # bool BEFORE int, which it subclasses: `axis(True)` would otherwise
    # read as 1, vertical.
    if isinstance(axis, bool) or not isinstance(axis, (str, int)):
        raise KayaTypeError(
            f"kaya: axis takes kaya.Axis.VERTICAL or its name, not "
            f"{type(axis).__name__}"
        )
    return Axis(axis)


def _align_value(align: Align | str | int) -> Align:
    # bool BEFORE int, which it subclasses: `align(True)` would otherwise
    # read as 1, center.
    if isinstance(align, bool) or not isinstance(align, (str, int)):
        raise KayaTypeError(
            f"kaya: align takes kaya.Align.CENTER or its name, not "
            f"{type(align).__name__}"
        )
    return Align(align)


class Role(enum.IntEnum):
    """The role enum: SEMANTIC EMPHASIS, the closed vocabulary
    (docs/styling-plan.md D4). Plain names accepted too.

    DESTRUCTIVE marks the press that destroys something; PROMINENT THE
    primary action; HEADING a text hierarchy heading (the platform's
    style AND the accessibility trait); CAPTION the footnote tier under
    the content it explains; PLAIN an action at low emphasis (a row's
    accessory); SWITCH a checkbox drawn as the platform's switch, for a
    setting that takes effect at once; LINK a label drawn as the
    platform's link, opening its `href` (docs/tasks-s2-plan.md T1, T3)."""

    DESTRUCTIVE = wire.ROLE_DESTRUCTIVE
    PROMINENT = wire.ROLE_PROMINENT
    HEADING = wire.ROLE_HEADING
    CAPTION = wire.ROLE_CAPTION
    PLAIN = wire.ROLE_PLAIN
    SWITCH = wire.ROLE_SWITCH
    LINK = wire.ROLE_LINK

    @classmethod
    def _missing_(cls, value: object) -> Any:
        if isinstance(value, str):
            try:
                return cls[value.upper()]
            except KeyError:
                raise KayaValueError(
                    f"kaya: role must be one of "
                    f"{sorted(m.name.lower() for m in cls)}, got {value!r}"
                ) from None
        raise KayaValueError(
            f"kaya: {value} is not a role — the vocabulary is "
            f"{sorted(m.name.lower() for m in cls)} "
            "(kaya.Role.DESTRUCTIVE/PROMINENT/HEADING/CAPTION/PLAIN/"
            "SWITCH/LINK)"
        )


def _role_value(role: Role | str | int) -> Role:
    """One role, from either spelling, refused here if it is neither.

    What stays the ROOT's is the PAIRING — whether this role fits the
    kind it was written on — which no handle here knows.
    """
    # bool BEFORE int, which it subclasses: `role(True)` would otherwise
    # read as 1, the destructive role.
    if isinstance(role, bool) or not isinstance(role, (str, int)):
        raise KayaTypeError(
            f"kaya: role takes kaya.Role.HEADING or its name, not "
            f"{type(role).__name__} — a role says what a widget MEANS and "
            "is declared once, so no binding binds one to a signal"
        )
    return Role(role)


class Symbol(enum.IntEnum):
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

    @classmethod
    def _missing_(cls, value: object) -> Any:
        if isinstance(value, str):
            try:
                return cls[value.upper()]
            except KeyError:
                raise KayaValueError(
                    f"kaya: symbol must be one of {sorted(_SYMBOL_NAMES)}, "
                    f"got {value!r}"
                ) from None
        raise KayaValueError(
            f"kaya: {value} is not a symbol — the vocabulary is "
            f"{sorted(_SYMBOL_NAMES)} (kaya.Symbol.COPY and friends)"
        )


#: DERIVED from the class rather than typed again: a drifted second
#: table draws the wrong concept with nothing raised.
_SYMBOL_NAMES = {
    name.lower(): value
    for name, value in vars(Symbol).items()
    if name.isupper()
}


def _symbol_value(symbol: Symbol | str | int) -> Symbol:
    """One symbol, from either spelling, refused here if it is neither.
    The ROOT keeps its own wall and the PAIRING too."""
    # bool BEFORE int, which it subclasses: `symbol(True)` would
    # otherwise read as 1, the `add` glyph.
    if isinstance(symbol, bool) or not isinstance(symbol, (str, int)):
        raise KayaTypeError(
            f"kaya: symbol takes kaya.Symbol.COPY or its name, not "
            f"{type(symbol).__name__} — a symbol names a CONCEPT the "
            "platform draws, and is declared once, so no binding binds "
            "one to a signal"
        )
    return Symbol(symbol)


def _set_align(handle: _Handle, align: Align | str | None) -> None:
    if align is None:
        return
    _records().append(wire.tx_set_align(handle.id, _align_value(align)))


def _set_spacing(handle: _Handle, spacing: float | None) -> None:
    if spacing is None:
        return
    _records().append(wire.tx_set_spacing(handle.id, float(spacing)))


def _set_inset(handle: _Handle, inset: float | None) -> None:
    if inset is None:
        return
    _records().append(wire.tx_set_inset(handle.id, float(inset)))


def _set_grow(handle: _Handle, grow: float | None) -> None:
    # Every constructor takes `grow=`, the declarative spelling of
    # Widget.grow.
    if grow is not None:
        _records().append(wire.tx_set_grow(handle.id, float(grow)))


def scroll(grow: float | None = None) -> _Container:
    """A vertical scroll viewport parenting EXACTLY ONE child. Give it
    `grow` so the enclosing track CONSTRAINS it — an unconstrained
    viewport hugs its content and nothing overflows."""
    handle = _widget(wire.KIND_SCROLL)
    _set_grow(handle, grow)
    return _Container(handle)


def grid(columns: float, *, grow: float | None = None,
         spacing: float | None = None, inset: float | None = None,
         columns_when: tuple[SizeClass, int] | None = None) -> _Container:
    """A grid container laying its children out row-major into `columns`
    columns — each column at its NATURAL width, aligned across rows.
    `spacing` is the inter-cell gap on both axes; `inset` its own
    padding.

    `columns_when` is a `(size class, count)` pair laying the grid out in
    that many columns while the window's SIZE CLASS is the named one — a
    core-evaluated breakpoint, reverting when the class is left
    (docs/adaptive-layout-plan.md D6.2)."""
    handle = _widget(wire.KIND_GRID)
    _records().append(wire.tx_set_columns(handle.id, float(columns)))
    if columns_when is not None:
        if (
            not isinstance(columns_when, tuple)
            or len(columns_when) != 2
            or columns_when[0] is not COMPACT
            or not isinstance(columns_when[1], int)
            or isinstance(columns_when[1], bool)
        ):
            raise KayaTypeError(
                f"kaya: columns_when takes a (size class, count) pair — "
                f"kaya.COMPACT is the only class today — not "
                f"{columns_when!r} (docs/adaptive-layout-plan.md D6.2)"
            )
        if _tpl_depth > 0:
            raise KayaTypeError(
                "kaya: columns_when is live-only — a breakpoint's setters "
                "name live widgets, and a template grid is a blueprint "
                "stamped per entry (docs/adaptive-layout-plan.md D6.2)"
            )
        _records().append(
            wire.tx_create_breakpoint(
                0,
                wire.SIZE_CLASS_COMPACT,
                1,
                [handle.id, wire.PROP_COLUMNS, float(columns_when[1])],
            )
        )
    _set_grow(handle, grow)
    _set_spacing(handle, spacing)
    _set_inset(handle, inset)
    return _Container(handle)


def labeled(label: TextSource, *, grow: float | None = None,
            spacing: float | None = None,
            inset: float | None = None) -> _Labeled:
    """A LABELLED ROW (docs/forms-plan.md): `label` names the one control
    declared inside, with an optional trailing button after it. A column
    of nothing but these renders as the platform's form.

    `label` is a str, a Signal, or — in a template — the enclosing For's
    element or one of its fields."""
    handle = _widget(wire.KIND_LABELED)
    _set_grow(handle, grow)
    _set_spacing(handle, spacing)
    _set_inset(handle, inset)
    return _Labeled(handle, label)


def spacer(grow: float = 1.0) -> Widget:
    """A spacer: an empty grown column consuming the leftover main-axis
    space between its siblings."""
    handle = _widget(wire.KIND_COLUMN)
    _set_grow(handle, grow)
    return handle


def column(*, grow: float | None = None, spacing: float | None = None,
           align: Align | str | None = None,
           inset: float | None = None) -> _Container:
    """A column container: parents everything declared inside it. `grow`
    is its flex weight; `spacing` its inter-child gap (main axis, DIP,
    default 8); `inset` its own padding."""
    handle = _widget(wire.KIND_COLUMN)
    _set_grow(handle, grow)
    _set_spacing(handle, spacing)
    _set_align(handle, align)
    _set_inset(handle, inset)
    return _Container(handle)


def button(text: str | None = None, bind: TextSource | None = None, *,
           on_click: Handler | None = None,
           grow: float | None = None) -> Widget:
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
            raise KayaTypeError(
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
            raise KayaTypeError(
                f"kaya: button bind takes a Signal, the enclosing For's "
                f"element, or one of its fields (row.title), not "
                f"{type(bind).__name__} — inside a case arm project the "
                "field: kaya.button(bind=note.text)"
            )
    if on_click is not None:
        _app._register(handle, wire.OCC_BUTTON_CLICKED, on_click)
    _set_grow(handle, grow)
    return handle


def row(*, grow: float | None = None, spacing: float | None = None,
        align: Align | str | None = None, inset: float | None = None,
        stack_when: SizeClass | None = None) -> _Container:
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
            raise KayaTypeError(
                f"kaya: stack_when takes a size class — kaya.COMPACT is "
                f"the only class today — not {stack_when!r}. The raw-width "
                "breakpoint (stack_below=N) is gone; kaya owns the numbers "
                "(docs/adaptive-layout-plan.md D3)"
            )
        if _tpl_depth > 0:
            raise KayaTypeError(
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


def checkbox(text: str | None = None, *, checked: FlagSource | None = None,
             on_toggle: Handler | None = None,
             grow: float | None = None) -> Widget:
    """A labeled on/off box. The box owns its checked bit: `on_toggle`
    receives the new state (template copies get their `Row` first, and
    `todo.done = checked` is the fold) and the app folds it into its own
    model."""
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
            _records().append(
                wire.tx_set_checked(handle.id, cast("bool", checked)))
    if on_toggle is not None:
        _app._register(handle, wire.OCC_TOGGLED, on_toggle)
    _set_grow(handle, grow)
    return handle


def progress(value: NumberSource | None = None, *,
             indeterminate: bool | None = None,
             grow: float | None = None) -> Widget:
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
            _records().append(
                wire.tx_set_value(handle.id, float(cast("float", value))))
    if indeterminate is not None:
        _records().append(
            wire.tx_set_indeterminate(handle.id, bool(indeterminate)))
    _set_grow(handle, grow)
    return handle


def select(options: Sequence[str], *, selected: float | Signal[Any] = 0,
           on_select: Handler | None = None,
           grow: float | None = None) -> Widget:
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


def radio(options: Sequence[str], *, selected: float | Signal[Any] = 0,
          on_select: Handler | None = None,
          grow: float | None = None) -> Widget:
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


def slider(value: NumberSource | None = None, *, min: float | None = None,
           max: float | None = None, step: float | None = None,
           tick_spacing: float | None = None,
           on_change: Handler | None = None, on_commit: Handler | None = None,
           grow: float | None = None) -> Widget:
    """A slider over a numeric range. UNCONTROLLED: the widget owns its
    position and reports each change to `on_change` and each settled
    gesture to `on_commit`, template copies getting their `Row`
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
            _records().append(
                wire.tx_set_value(handle.id, cast("float", value)))
    if on_change is not None:
        _app._register(handle, wire.OCC_VALUE_CHANGED, on_change)
    if on_commit is not None:
        _app._register(handle, wire.OCC_VALUE_COMMITTED, on_commit)
    _set_grow(handle, grow)
    return handle


def _picker_field(what: str, value: FieldRef[Any], want: type) -> None:
    """A picker's template source, held to the field TYPE — a Date field
    and an int one share the I64 tag, so nothing below this can tell them
    apart (docs/datetime-plan.md D10)."""
    if value._type is not want:
        raise KayaTypeError(
            f"kaya: {what} binds a {want.__name__} field, not "
            f"{getattr(value._type, '__name__', value._type)}"
        )


def date_picker(value: datetime.date | Source | None = None, *,
                min: datetime.date | None = None,
                max: datetime.date | None = None,
                on_change: Handler | None = None,
                grow: float | None = None) -> Widget:
    """A date picker over civil dates — `datetime.date`, never an instant
    (docs/datetime-plan.md). UNCONTROLLED: the control owns its value and
    reports each COMMITTED pick to `on_change`, template copies getting
    their `Row` first. `min`/`max` are the inclusive range; a pick past a
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


def time_picker(value: datetime.time | Source | None = None, *,
                step: float | None = None, on_change: Handler | None = None,
                grow: float | None = None) -> Widget:
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


def entry(text: str | None = None, *, on_change: Handler | None = None,
          grow: float | None = None,
          placeholder: TextSource | None = None) -> Widget:
    """A single-line text field. UNCONTROLLED: the widget owns its text
    and reports each edit to `on_change`, template copies getting their
    `Row` first. There is no read-back."""
    handle = _widget(wire.KIND_ENTRY)
    if text is not None:
        _records().append(wire.tx_set_text(handle.id, _text_value("entry text", text)))
    if placeholder is not None:
        handle.placeholder(placeholder)
    if on_change is not None:
        _app._register(handle, wire.OCC_TEXT_CHANGED, on_change)
    _set_grow(handle, grow)
    return handle


def _bind_document(handle: Widget, field: object) -> None:
    """A stamped copy's document, bound to a `Document` FIELD of its row
    (docs/rich-text-plan.md §19): `rich` FIRST — the core refuses
    `document` without it — then the binding, and the node is recorded so
    a copy's own edit or format act folds into the row."""
    if not isinstance(field, FieldRef):
        raise KayaTypeError(
            f"kaya: textarea document= takes a Document field of the "
            f"enclosing For's element (el.body), not "
            f"{type(field).__name__} — a LIVE textarea's document is "
            "set_document(doc), which names the widget")
    if field._type is not Document:
        raise KayaTypeError(
            "kaya: textarea document= takes a kaya.Document field; this "
            f"one is {getattr(field._type, '__name__', field._type)}")
    handle.rich(True)
    _records().append(wire.tx_bind_document_element(
        handle.id, field._level(), field._index))
    _app._document_binds[handle.id] = (field._element._coll, field._index)


def textarea(text: str | None = None, *, on_change: Handler | None = None,
             grow: float | None = None,
             placeholder: TextSource | None = None, rich: bool = False,
             own_undo: bool = False, on_edit: Handler | None = None,
             on_format: Handler | None = None,
             document: Document | FieldRef[Any] | None = None) -> Widget:
    """A multi-line text editor: the entry's uncontrolled contract over
    the platform's real multi-line editor.

    `rich=True` adds the attributed surface (docs/rich-text-plan.md R1):
    `set_document`, `apply_edit`, `format`/`unformat`/`set_block`, the
    `document()` this binding folds, and the two deltas — `on_edit(edit)`
    for every user edit, addressed, beside the whole-text `on_change`, and
    `on_format(act)` for a toolbar act over a range.

    `document=` is the TEMPLATE zone's rich spelling (§19): a Document
    field of the enclosing For's element, which makes the copy rich and
    renders that field. The app writes a copy's document by patching its
    row, and a copy's own acts fold back into the field, so `on_edit` and
    `on_format` arrive with the row's key and the row already reads
    current.

    `own_undo=True` puts the history in the app's hands
    (docs/rich-text-plan.md R6, §14)."""
    handle = _widget(wire.KIND_TEXTAREA)
    if text is not None:
        _records().append(wire.tx_set_text(handle.id, _text_value("textarea text", text)))
    if document is not None:
        _bind_document(handle, document)
    elif rich:
        handle.rich(True)
    if own_undo:
        handle.own_undo(True)
    if placeholder is not None:
        handle.placeholder(placeholder)
    if on_change is not None:
        _app._register(handle, wire.OCC_TEXT_CHANGED, on_change)
    if on_edit is not None:
        _app._register(handle, wire.OCC_TEXT_EDITED, on_edit)
    if on_format is not None:
        _app._register(handle, wire.OCC_TEXT_FORMATTED, on_format)
    _set_grow(handle, grow)
    return handle


def search(text: str | None = None, *, on_change: Handler | None = None,
           grow: float | None = None,
           placeholder: TextSource | None = None) -> Widget:
    """A search field (docs/search-plan.md): the entry's uncontrolled
    contract under the platform's search chrome, filtering on every
    keystroke. The clear affordance reaches `on_change` with ""."""
    handle = _widget(wire.KIND_SEARCH)
    if text is not None:
        _records().append(wire.tx_set_text(handle.id, _text_value("search text", text)))
    if placeholder is not None:
        handle.placeholder(placeholder)
    if on_change is not None:
        _app._register(handle, wire.OCC_TEXT_CHANGED, on_change)
    _set_grow(handle, grow)
    return handle


def label(text: str | None = None, bind: TextSource | None = None, *,
          grow: float | None = None, href: TextSource | None = None,
          rich: bool = False) -> Widget:
    """A label; `text` for a constant, `bind` for a Signal or an
    Element (the enclosing For's, levels computed). `href=` with
    `role="link"` is the destination the platform opens
    (docs/tasks-s2-plan.md T3).

    `rich=True` draws the inline vocabulary READ-ONLY
    (docs/rich-text-plan.md R8, §15): `set_document` and `apply_edit`
    are the writes, `document()` the read, a `block` run is refused,
    and a plain text write drops the runs."""
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
        raise KayaTypeError(
            f"kaya: label bind takes a Signal, the enclosing For's element, "
            f"or one of its fields (el.title), not {type(bind).__name__} — "
            "inside a case arm project the field: kaya.label(bind=note.text)"
        )
    if rich:
        handle.rich(True)
    if href is not None:
        handle.href(href)
    _set_grow(handle, grow)
    return handle


def heading(text: str | None = None, bind: TextSource | None = None, *,
            grow: float | None = None) -> Widget:
    """A label wearing the heading role: the platform's heading text
    style AND the accessibility heading trait, and on a grouped screen
    the section-header seat (docs/styling-plan.md D4)."""
    return label(text=text, bind=bind, grow=grow).role("heading")


def caption(text: str | None = None, bind: TextSource | None = None, *,
            grow: float | None = None) -> Widget:
    """A label wearing the caption role: the platform's footnote text
    tier, and on a grouped screen the section-footer seat."""
    return label(text=text, bind=bind, grow=grow).role("caption")


def image(source: bytes | bytearray | memoryview | Asset | Source | None = None,
          *, grow: float | None = None) -> Widget:
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
            raise KayaTypeError(
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


def _draw_vocab(table: Mapping[str, int], what: str, name: str) -> int:
    try:
        return table[name]
    except (KeyError, TypeError):
        raise KayaValueError(
            f"kaya: {name!r} is not a canvas {what}; the vocabulary is "
            + ", ".join(sorted(table))
        ) from None


class Draw:
    """The drawing scope's recorder: the calls read as immediate-mode
    drawing, but ONE record is submitted when the scope closes
    (docs/canvas-plan.md §2.1)."""

    def __init__(self, viewbox: tuple[float, float]) -> None:
        self.viewbox = viewbox
        self._ops: list[Any] = []

    def _op(self, code: int, *operands: Any) -> Draw:
        self._ops.append(code)
        self._ops.extend(operands)
        return self

    def move_to(self, x: float, y: float) -> Draw:
        """Start a subpath at (x, y)."""
        return self._op(wire.DRAW_OP_MOVE_TO, float(x), float(y))

    def line_to(self, x: float, y: float) -> Draw:
        """Extend the current subpath to (x, y)."""
        return self._op(wire.DRAW_OP_LINE_TO, float(x), float(y))

    def close(self) -> Draw:
        """Close the current subpath."""
        return self._op(wire.DRAW_OP_CLOSE)

    def polyline(self, points: Sequence[tuple[float, float]]) -> Draw:
        """`move_to` the first point and `line_to` the rest."""
        for i, (x, y) in enumerate(points):
            if i == 0:
                self.move_to(x, y)
            else:
                self.line_to(x, y)
        return self

    def stroke(self, paint: str, width: float = 1.0) -> Draw:
        """Stroke the built path and clear it. `width` is in
        device-independent points and does NOT carry the viewbox stretch
        (docs/canvas-plan.md §3.2)."""
        return self._op(wire.DRAW_OP_STROKE,
                        _draw_vocab(_PAINTS, "paint role", paint),
                        float(width))

    def fill(self, paint: str, rule: str = "nonzero") -> Draw:
        """Fill the built path and clear it."""
        return self._op(wire.DRAW_OP_FILL,
                        _draw_vocab(_PAINTS, "paint role", paint),
                        _draw_vocab(_FILL_RULES, "fill rule", rule))

    def font(self, size: float, asset: str = "", weight: int = 400) -> Draw:
        """Select the face for subsequent text ops. `asset` is an
        ordinary asset name; `""` is kaya's own embedded default face."""
        return self._op(wire.DRAW_OP_FONT, str(asset), float(size),
                        int(weight))

    def text(self, x: float, y: float, s: str, paint: str = "axis",
             align: str = "start", baseline: str = "alphabetic") -> Draw:
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

    def __init__(self, handle: _Handle, keys: Sequence[Key]) -> None:
        self._handle = handle
        self._keys = list(keys)
        # Set by __enter__; a scope is never used without its `with`.
        self._draw = cast("Draw", None)

    def __enter__(self) -> Draw:
        viewbox = _canvas_viewboxes.get(self._handle.id)
        if viewbox is None:
            raise KayaStateError(
                f"kaya: draw() on widget {self._handle.id} — that is not a "
                "canvas this app declared; a drawing is a declaration "
                "against the canvas it draws on (docs/canvas-plan.md §2.1)"
            )
        self._draw = Draw(viewbox)
        return self._draw

    def __exit__(self, exc_type: Any, exc: Any,
                 tb: Any) -> Literal[False]:
        if exc_type is not None:
            return False
        w, h = self._draw.viewbox
        ops = self._draw._ops
        _records().append(wire.tx_set_drawing(
            self._handle.id, w, h, len(ops), len(self._keys),
            [*self._keys, *ops],
        ))
        return False


def _size_policy(handle: Widget, fixed: bool | None,
                 on_draw: Callable[..., object] | None,
                 on_tick: Callable[..., object] | None) -> None:
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
        raise KayaValueError(
            "kaya: a canvas declares ONE size policy, not "
            + " and ".join(declared)
            + " (docs/canvas-plan.md §3.2.1)"
        )
    if isinstance(handle, Node):
        raise KayaStateError(
            "kaya: the size policy is a LIVE-ZONE declaration in this "
            "slice — a canvas inside a row template keeps `scale` "
            "(docs/deferred.md, the template-zone size policy entry)"
        )
    if fixed:
        policy = wire.SIZE_POLICY_FIXED
    else:
        policy = (wire.SIZE_POLICY_REDRAW if on_draw is not None
                  else wire.SIZE_POLICY_TICK)
        _app._register_draw(
            handle, policy, cast("Callable[..., object]", on_draw or on_tick))
    _records().append(wire.tx_set_size_policy(handle.id, policy))


def canvas(viewbox: tuple[float, float], *, grow: float | None = None,
           fixed: bool | None = None,
           on_draw: Callable[[Draw, tuple[float, float]], object] | None = None,
           on_tick: Callable[[Draw, tuple[float, float], float], object] | None = None
           ) -> Widget:
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


def for_each(coll: Collection[T]) -> _Template[T]:
    """A For over `coll`: the with-block declares the template, and the
    target yields the element — `with kaya.for_each(c) as element:`."""
    # A For binds the collection itself — its template stamps per entry
    # of every instance — so handing it an at(...) handle is a bug.
    if not isinstance(coll, Collection):
        raise KayaTypeError(
            "kaya: for_each binds the collection itself, not an instance "
            "— drop the .at(...)"
        )
    return _Template(wire.tx_create_for, coll._id, is_for=True, coll=coll)


def when(sig: Signal[Any]) -> _Template[None]:
    """A When over a Bool signal: stamps its template on true, unstamps
    on false."""
    return _Template(wire.tx_create_when, sig.id, is_for=False)


def _window_props(window: int, title: str | None, width: float | None,
                  height: float | None, veto_close: bool | None,
                  dirty: bool | None, panes: int | None,
                  sections_presentation: SectionsPresentation | str | int | None,
                  appearance: Appearance | str | int | None,
                  inset: float | None, remember_frame: bool | None) -> None:
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
    if remember_frame is not None:
        records.append(wire.tx_set_window_remember_frame(
            window, bool(remember_frame)))
    if panes is not None:
        records.append(wire.tx_set_window_panes(window, int(panes)))
    if sections_presentation is not None:
        records.append(wire.tx_set_window_sections_presentation(
            window, int(SectionsPresentation(sections_presentation))))
    if appearance is not None:
        records.append(wire.tx_set_window_appearance(
            window, int(Appearance(appearance))))
    # float() so it lands as the F64 the prop is typed as — an I64 is
    # refused for its TYPE, a true complaint about the wrong mistake.
    if inset is not None:
        records.append(wire.tx_set_window_inset(window, float(inset)))
    if width is not None or height is not None:
        if width is None or height is None:
            raise KayaValueError("kaya: window width and height travel together")
        records.append(wire.tx_set_window_width(window, float(width)))
        records.append(wire.tx_set_window_height(window, float(height)))


class _LiveWindow:
    """What the window construct returns when it was called LIVE — its
    props are already in the ambient transaction.

    It exists to make the other spelling's mistake LOUD: `with
    app.window(dirty=True):` inside a handler would otherwise report
    "transactions do not nest", which is true and unhelpful.
    """

    def __enter__(self) -> NoReturn:
        raise KayaStateError(
            "kaya: the window construct's props are already in this "
            "transaction — inside a handler (or `with app.build():`) the "
            "construct is a PLAIN CALL, `app.window(dirty=True)`. The "
            "`with` form is the scene scope: it opens a transaction of "
            "its own and mounts a root, which a handler must not do."
        )

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> Literal[False]:
        return False


class _TxScope:
    """One ambient transaction's with-block: the scene scope that mounts
    on exit, the build that does not, and the push/section nesting."""

    def __init__(self, app: App, mount_on_exit: bool, title: str | None = None,
                 width: float | None = None, height: float | None = None,
                 window: int = 0, create: bool = False,
                 veto_close: bool | None = None, dirty: bool | None = None,
                 remember_frame: bool | None = None, panes: int | None = None,
                 sections_presentation: SectionsPresentation | str | int | None = None,
                 appearance: Appearance | str | int | None = None,
                 inset: float | None = None, push: bool = False,
                 intercept_back: bool | None = None,
                 on_popped: Callable[[], object] | None = None,
                 on_back: Callable[[], object] | None = None,
                 section: bool = False,
                 on_selected: Callable[[], object] | None = None,
                 host_window: int = 0, symbol: Symbol | None = None,
                 badge: float | Signal[Any] | None = None) -> None:
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
        self._remember_frame = remember_frame
        self._panes = panes
        self._sections_presentation = sections_presentation
        self._appearance = appearance
        self._inset = inset
        self._push = push
        self._intercept_back = intercept_back
        self._on_popped = on_popped
        self._on_back = on_back
        self._section = section
        self._on_selected = on_selected
        # Already through _symbol_value at the add_section call site.
        self._symbol = symbol
        self._badge = badge

    def __del__(self) -> None:
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

    def __enter__(self) -> _TxScope:
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
            if self._badge is not None:
                if isinstance(self._badge, Signal):
                    _records().append(wire.tx_bind_section_badge(
                        self._window, self._badge.id))
                else:
                    _records().append(wire.tx_set_section_badge(
                        self._window, float(self._badge)))
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
            raise KayaStateError("kaya: transactions do not nest")
        _tx = []
        _journal = {}
        _pending_root = None
        _recording = self._mount
        if self._create:
            _records().append(wire.tx_create_window(self._window))
        _window_props(
            self._window, self._title, self._width, self._height,
            self._veto_close, self._dirty, self._panes,
            self._sections_presentation, self._appearance, self._inset,
            self._remember_frame)
        return self

    def __exit__(self, exc_type: Any, exc: Any,
                 tb: Any) -> Literal[False]:
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
                raise KayaStateError(
                    "kaya: push_entry()/add_section() body declared no "
                    "root container")
            _records().append(wire.tx_mount(self._window, root.id))
            if not self._nested:
                records, _tx = cast("list[bytes]", _tx), None
                _journal = None
                _ship(records)
            return False
        global _tpl_depth
        _recording = False
        records, _tx = cast("list[bytes]", _tx), None
        journal, _journal = cast("dict[int, Callable[[], None]]", _journal), None
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
            raise KayaStateError(
                "kaya: a `for t in coll:` template never closed — the "
                "loop body must run to completion (no break/return); "
                "conditional rendering is kaya.when"
            )
        if self._mount and _pending_root is not None:
            # A props-only body is legal (the sections shape) — nothing
            # mounts, nothing errors.
            records.append(wire.tx_mount(self._window, _pending_root.id))
        _ship(records)
        return False


class App:
    """The process's app: the scene scopes (`window`, `build`,
    `push_entry`, `add_section`), the window command catalog, and the
    occurrence loop `run()` drives."""

    def __init__(self) -> None:
        global _app
        # No "node" space: template nodes draw from "widget" (DESIGN.md,
        # Binding conventions).
        self._counters = {"signal": 0, "widget": 0, "collection": 0,
                          "alert": 0, "menu_item": 0, "file_dialog": 0,
                          "clipboard": 0, "link_route": 0}
        # The wire routes by path_len, not by number, so two dicts.
        self._widget_handlers: dict[tuple[int, int], Handler] = {}
        self._alert_handlers: dict[int, Callable[[AlertChoice], object]] = {}
        # One-shot, keyed by the GUEST's notification id (the alert's
        # grammar; many may be live at once).
        self._notification_handlers: dict[
            int, Callable[[NotificationOutcome], object]] = {}
        # NOT one-shot, and not keyed at all: the process-level handler
        # for a result whose id has none above (docs/tasks-s9-plan.md
        # R1). A relaunched process never called show.
        self._notification_activation: Callable[
            [int, NotificationOutcome], object] | None = None
        # NOT one-shot either: a route declared by link() answers every
        # URL that matches it, for the life of the process
        # (docs/app-links-plan.md §4), and the core owns the pattern
        # table — nothing is kept here but the handler.
        self._link_handlers: dict[
            int, Callable[[dict[str, str]], object]] = {}
        # link() may be called before the first transaction, so its
        # record waits here for one (_ship drains it head-first).
        self._pending_records: list[bytes] = []
        self._file_dialog_handlers: dict[
            int, Callable[[list[PickedFile]], object]] = {}
        # One-shot, keyed by request id (the alert's grammar).
        self._clipboard_handlers: dict[
            int, Callable[[Clip | None], object]] = {}
        # Menu items are their own id space, so their own table.
        self._menu_handlers: dict[tuple[int, int], Handler] = {}
        # Per-entry navigation handlers, keyed by entry surface id.
        self._entry_popped: dict[int, Callable[[], object]] = {}
        self._back_requested: dict[int, Callable[[], object]] = {}
        self._section_selected: dict[int, Callable[[], object]] = {}
        # Per-window lifecycle handlers, keyed by window id.
        self._close_requested: dict[int, Callable[[], object]] = {}
        self._window_closed: dict[int, Callable[[], object]] = {}
        # NOT one-shot: a history is walked as often as the user likes.
        self._undone: dict[int, Callable[[str, UndoDelta], object]] = {}
        self._redone: dict[int, Callable[[str, UndoDelta], object]] = {}
        # By core id, for the undo path: an `undone` payload names them
        # rather than handing back handles.
        self._collections: dict[int, Collection[Any]] = {}
        self._signals: dict[int, Signal[Any]] = {}
        self._node_handlers: dict[tuple[int, int], Handler] = {}
        # The For a stamped registration belongs to, by node id, and the
        # catalog a free context item was built in: together they name
        # the collection a Row handle reads and writes.
        self._node_owners: dict[int, Collection[Any]] = {}
        self._item_catalogs: dict[int, ContextCatalog] = {}
        # Its own table because these do not fold an occurrence into app
        # state: they answer the ask with a drawing the guest never sees
        # (docs/canvas-plan.md §3.2.1).
        self._draw_handlers: dict[
            int, tuple[Widget, Callable[..., object]]] = {}
        # The rich mirror, by LIVE widget id (docs/rich-text-plan.md R1).
        # Outside the rollback journal, as the Rust binding's is: an edge
        # the widget and the core have taken is not the app's to undo.
        self._documents: dict[int, Document] = {}
        # Template node -> (collection, field index) per bound `document`,
        # so a stamped copy's act folds into its row (§19).
        self._document_binds: dict[int, tuple[Collection[Any], int]] = {}
        # THE ONLY STATE HERE TOUCHED FROM ANOTHER THREAD, and the only
        # reason App carries a lock.
        self._post_lock = threading.Lock()
        self._posted: list[tuple[Callable[..., object], tuple[Any, ...]]] = []
        _app = self

    def _next(self, space: str) -> int:
        self._counters[space] += 1
        return self._counters[space]

    def _register(self, handle: _Handle, kind: int, fn: Handler) -> None:
        if isinstance(handle, Node):
            # THE ROW HANDLE'S OWNER: the innermost For open at
            # registration (docs/js-plan.md §4 rule 3).
            self._node_owners[handle.id] = _row_owner("a stamped handler")
            self._node_handlers[(kind, handle.id)] = fn
        else:
            self._widget_handlers[(kind, handle.id)] = fn

    def _row_args(self, ident: int, keys: Sequence[Key]) -> list[Any]:
        """The row a stamped occurrence names, as a handle."""
        if not keys:
            return []
        owner = self._node_owners.get(ident)
        if owner is None:
            catalog = self._item_catalogs.get(ident)
            owner = None if catalog is None else catalog._owner
        if owner is None:
            return list(keys)
        return [Row(owner, keys)]

    def _register_draw(self, handle: Widget, policy: int,
                       fn: Callable[..., object]) -> None:
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

    def _answer_canvas(self, ident: int, kind: int,
                       values: Sequence[Any]) -> None:
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

    def _register_history(self, window_id: int,
                          on_undone: Callable[[str, UndoDelta], object] | None,
                          on_redone: Callable[[str, UndoDelta], object] | None
                          ) -> None:
        """Seat a surface's two history handlers. Per window and NOT
        one-shot: both outlive every step."""
        if on_undone is not None:
            self._undone[int(window_id)] = on_undone
        if on_redone is not None:
            self._redone[int(window_id)] = on_redone

    def create_window(self, window_id: int, *, title: str | None = None,
                      width: float | None = None, height: float | None = None,
                      veto_close: bool | None = None,
                      dirty: bool | None = None,
                      remember_frame: bool | None = None,
                      panes: int | None = None,
                      sections_presentation: SectionsPresentation | str | int | None = None,
                      appearance: Appearance | str | int | None = None,
                      inset: float | None = None,
                      on_close_requested: Callable[[], object] | None = None,
                      on_closed: Callable[[], object] | None = None,
                      on_undone: Callable[[str, UndoDelta], object] | None = None,
                      on_redone: Callable[[str, UndoDelta], object] | None = None
                      ) -> _TxScope:
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
            dirty=dirty, remember_frame=remember_frame, panes=panes,
            sections_presentation=sections_presentation,
            appearance=appearance, inset=inset)

    def window(self, title: str | None = None, *, width: float | None = None,
               height: float | None = None, veto_close: bool | None = None,
               dirty: bool | None = None, remember_frame: bool | None = None,
               panes: int | None = None,
               sections_presentation: SectionsPresentation | str | int | None = None,
               appearance: Appearance | str | int | None = None,
               inset: float | None = None,
               on_close_requested: Callable[[], object] | None = None,
               on_closed: Callable[[], object] | None = None,
               on_undone: Callable[[str, UndoDelta], object] | None = None,
               on_redone: Callable[[str, UndoDelta], object] | None = None,
               window_id: int = 0) -> _TxScope | _LiveWindow:
        """The scene scope: an ambient transaction whose single top-level
        container mounts into the default window on exit. `title` names
        the surface; `width`/`height` request content size in DIP
        (advisory); `veto_close` arms the close-veto class;
        `sections_presentation` is the ADVISORY sections hint;
        `appearance` is the app's own light/dark choice, applied
        process-wide from the default window (kaya.APPEARANCE_SYSTEM /
        _LIGHT / _DARK, docs/tasks-s2b-plan.md R1-R3);
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

        `remember_frame` is the OPT-OUT from window memory
        (docs/tasks-s4-plan.md P4): a desktop window reopens at the
        frame the previous process left unless this is False. Inert on
        the phones, which have no window frame.

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
                          dirty, panes, sections_presentation, appearance,
                          inset, remember_frame)
            return _LiveWindow()
        return _TxScope(
            self, mount_on_exit=True, window=window_id,
            title=title, width=width, height=height,
            veto_close=veto_close, dirty=dirty,
            remember_frame=remember_frame, panes=panes,
            sections_presentation=sections_presentation,
            appearance=appearance, inset=inset)

    def build(self) -> _TxScope:
        """An ambient transaction without the mount — for mutations
        outside handlers."""
        return _TxScope(self, mount_on_exit=False)

    def push_entry(self, entry_id: int, *, title: str | None = None,
                   intercept_back: bool | None = None,
                   on_popped: Callable[[], object] | None = None,
                   on_back: Callable[[], object] | None = None) -> _TxScope:
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

    def add_section(self, section_id: int, *, title: str | None = None,
                    symbol: Symbol | str | None = None,
                    badge: float | Signal[Any] | None = None,
                    on_selected: Callable[[], object] | None = None,
                    window: int = 0) -> _TxScope:
        """A section's scene scope (DESIGN.md, Sections): the single
        top-level container mounts INTO IT on exit. The set is
        append-only and switching is SELECTION, not lifecycle.

        `symbol=` is the switcher item's SEMANTIC ICON, REFUSED HERE and
        not at the `with`: a raise from __enter__ would point at the
        block rather than at the word.

        `badge=` is the COUNT on the switcher item (docs/tasks-s2-plan.md
        T2) — a number or a Signal holding one; zero clears.

        on_selected() fires each time the USER switches to this section,
        NOT one-shot. A programmatic kaya.select_section does not fire
        it."""
        return _TxScope(
            self, mount_on_exit=True, window=section_id, section=True,
            title=title, symbol=None if symbol is None else _symbol_value(symbol),
            badge=badge, on_selected=on_selected, host_window=window)

    def menu(self, label: TextSource, *,
             enabled: bool | Signal[Any] | None = None,
             icon: bytes | None = None, symbol: Symbol | str | None = None,
             window: int = 0) -> _MenuScope[MenuItem]:
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

    def radio_group(self, label: TextSource, *,
                    value: float | Signal[Any] | None = None,
                    enabled: bool | Signal[Any] | None = None,
                    icon: bytes | None = None,
                    symbol: Symbol | str | None = None,
                    on_select: Handler | None = None,
                    window: int = 0) -> _MenuScope[MenuItem]:
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

    def _dispatch(self, handler: Callable[..., object], *args: Any) -> None:
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

    def post(self, fn: Callable[..., object], *args: Any) -> None:
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

    def _absorb_undo(self, delta: UndoDelta) -> None:
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

    # The rich mirror's three doors (docs/rich-text-plan.md R1): the
    # widget's own deltas, folded by the core's rules
    # (crates/kaya/src/app.rs, absorb_edit/absorb_format), and the seed a
    # set_document write leaves.

    def _document(self, widget: int) -> Document:
        doc = self._documents.get(widget)
        if doc is None:
            return Document()
        return Document(doc.text, [Run(r.range.start, r.range.stop, r.name, r.value)
                                   for r in doc.runs])

    def _seed_document(self, widget: int, document: Document) -> None:
        self._documents[widget] = Document(
            document.text,
            [Run(r.range.start, r.range.stop, r.name, r.value) for r in document.runs])

    def _absorb_edit(self, widget: int, start: int, stop: int, inserted: str,
                     runs: Sequence[Run]) -> None:
        _fold_edit(self._documents.setdefault(widget, Document()),
                   start, stop, inserted, runs)

    def _ranged_act_bounds(self, widget: int, start: int, stop: int,
                           name: str) -> tuple[int, int]:
        """A ranged act's range in the fold's text: a `block` covers the
        whole paragraphs it touches, as the core snaps it
        (docs/rich-text-plan.md §17)."""
        if name != "block":
            return start, stop
        doc = self._documents.get(widget)
        data = b"" if doc is None else doc.text.encode("utf-8")
        start, stop = min(start, len(data)), min(stop, len(data))
        nl = data.find(b"\n", stop)
        return data.rfind(b"\n", 0, start) + 1, len(data) if nl < 0 else nl

    def _absorb_format(self, widget: int, start: int, stop: int, name: str,
                       value: str | None) -> None:
        _fold_format(self._documents.setdefault(widget, Document()),
                     start, stop, name, value)

    def _fold_row_document(self, node: int, keys: Sequence[Key],
                           fold: Callable[[Document], None]) -> None:
        """A stamped copy's edit or format act reaches its ROW's Document
        field (docs/rich-text-plan.md §19): the node was bound to
        (collection, field) by the template textarea's `document=`, and
        the occurrence's keys name the row. A row that is gone has no
        field to fold into, and that is not a fault."""
        bind = self._document_binds.get(node)
        if bind is None:
            return
        coll, index = bind
        table = coll._instances.get(tuple(keys[:-1]))
        if table is None:
            return
        entry = table.get(keys[-1])
        if entry is None:
            return
        _, spec = coll._variant_for(entry)
        if spec.fields is None:
            return
        name = next((n for n, at in spec.fields.items() if at == index), None)
        if name is None:
            return
        doc = getattr(entry, name, None)
        if not isinstance(doc, Document):
            doc = Document()
        fold(doc)
        setattr(entry, name, doc)

    def _drain_posted(self) -> None:
        """Run everything posted, each as its own transaction, in order.

        The batch is taken and the lock released BEFORE any of it runs,
        so a callable that posts again lands in the NEXT batch — holding
        the lock across the calls would starve the occurrence loop.
        """
        with self._post_lock:
            batch, self._posted = self._posted, []
        for fn, args in batch:
            self._dispatch(fn, *args)

    def _dispatch_loop(self) -> None:
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
                    self._dispatch(handler, AlertChoice(payload))
                continue
            if kind == wire.OCC_LINK_OPENED:
                # ident is the ROUTE the core matched
                # (docs/app-links-plan.md §4), and NOT one-shot. TWO
                # DROPS WITH DISJOINT CAUSES: route 0 is a URL NO ROUTE
                # TOOK, which the core announced naming every declared
                # pattern, so it is silent here — two lines for one
                # event teaches a reader to distrust both, and this
                # slice has no registrar for a miss; a route that
                # matched and reached no handler is this binding's to
                # announce, naming its own registrar.
                # The payload is ONE FLAT RUN of Str values: the url,
                # then the params in name/value pairs (wire.py's arm).
                url = payload[0] if payload else ""
                handler = self._link_handlers.get(ident)
                if handler is not None:
                    self._dispatch(handler, dict(
                        zip(payload[1::2], payload[2::2])))
                elif ident != 0:
                    print(
                        f"kaya: link {url} matched route {ident} and "
                        "reached no handler — none is registered for it "
                        "(kaya.link)",
                        file=sys.stderr,
                    )
                continue
            if kind == wire.OCC_NOTIFICATION_RESULT:
                # THE ORDER IS THE SEMANTICS (docs/tasks-s9-plan.md R1),
                # and tools/check-sugar-surface.py reads it out of this
                # arm: the one-shot handler bound at the show first,
                # retiring with the result; else the process-level one,
                # which does not; else the drop is announced.
                # payload is the parsed u32 outcome.
                answer = NotificationOutcome(payload)
                handler = self._notification_handlers.pop(ident, None)
                if handler is not None:
                    self._dispatch(handler, answer)
                    continue
                activation = self._notification_activation
                if activation is not None:
                    self._dispatch(activation, ident, answer)
                    continue
                outcome = answer.name.lower()
                print(
                    f"kaya: notification {ident} outcome {outcome} reached "
                    "no handler — none was bound at the show and no "
                    "process-level handler is registered "
                    "(kaya.on_notification_activation)",
                    file=sys.stderr,
                )
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
            if kind in (wire.OCC_TEXT_EDITED, wire.OCC_TEXT_FORMATTED):
                # THE DOCUMENT FOLLOWS FIRST AND WITHOUT A HANDLER, as an
                # undo's mirrors do (docs/rich-text-plan.md R1): an app
                # that registered neither delta still reads a current
                # `document()`. A STAMPED copy's act folds into its ROW's
                # Document field instead, by the same rule (§19).
                if kind == wire.OCC_TEXT_EDITED:
                    source, start, stop, inserted = payload[:4]
                    runs = _runs_from(payload[4:])
                    _decoded_span("text_edited", int(start), int(stop))
                    arg = Edit(start, stop, inserted, runs)
                    arg.source = _edit_source(source)
                    if keys:
                        self._fold_row_document(
                            ident, keys,
                            lambda doc: _fold_edit(doc, start, stop,
                                                   inserted, runs))
                    else:
                        self._absorb_edit(ident, start, stop, inserted, runs)
                else:
                    removed, start, stop, name, value = payload
                    _decoded_span("text_formatted", int(start), int(stop))
                    arg = Format(start, stop, name,
                                 None if removed else value)
                    if keys:
                        self._fold_row_document(
                            ident, keys,
                            lambda doc: _fold_format(doc, start, stop, name,
                                                     cast("Format", arg).value))
                    else:
                        self._absorb_format(ident, start, stop, name,
                                            arg.value)
                table = self._node_handlers if keys else self._widget_handlers
                handler = table.get((kind, ident))
                if handler is not None:
                    self._dispatch(handler, *self._row_args(ident, keys), arg)
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
                args = self._row_args(ident, keys)
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
            args = self._row_args(ident, keys)
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

    def run(self) -> int:
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
