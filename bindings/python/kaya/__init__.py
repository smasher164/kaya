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
  collections. Data with no identity of its own gets its key from the
  binding: `collection.insert_fresh(value)` mints one and returns it,
  so no app spells a `next_key` global;
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


def _text_range(what, span):
    """One text range, normalized to the (start, stop) pair the wire
    carries.

    THE SPELLING IS `range(start, stop)` — Python's own half-open
    interval of ints, which is exactly what a kaya range is — and a
    plain (start, stop) pair is taken too, since an app that has just
    computed two offsets already holds the pair. A `slice` is refused
    rather than quietly reinterpreted: its endpoints are optional, and a
    None there means "the text's own end", which this call cannot
    resolve because it does not have the text.

    NEGATIVE OFFSETS ARE REFUSED HERE, BY NAME, because Python hands
    them out: `str.find` and `bytes.find` answer -1 for "not found", and
    an unchecked -1 would reach the wire as a struct.error on one record
    and as an enormous offset on another. kaya has no end-relative
    offset.

    EVERY OTHER MALFORMED RANGE IS THE CORE'S TO REFUSE — start after
    stop, past the end of the text, or splitting a character — at its
    one chokepoint, with the text in hand and the character it splits
    nameable. Eight bindings re-deriving that check would be eight
    approximations of one sentence (scratchpad/ranges-units.md §7).
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
# The thread the dispatch loop runs on, once it starts. None before
# that, which is why module-scope declaration on the main thread still
# works.
_app_thread = None


def _require_app_thread():
    """The Python spelling of a rule the other bindings get from types.

    `_tx` above is a module GLOBAL, not thread-local, so a transaction
    opened on a background thread would stamp its records into the app
    thread's open transaction — silently, and interleaved. Rust makes
    that a compile error (`Tx` is `!Send`) and Go a panic; Python has
    neither handle to check, so it checks the thread.

    Reads and writes need no guard of their own: a signal write outside
    a transaction already raises "no ambient transaction", which is
    exactly what a background thread gets.
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


def _no_truth_value(what):
    """The lax.cond wall, element edition: a tracer is a reference into
    the blueprint, not a value. A template body runs ONCE, so a branch
    taken on the row's data freezes one row's answer into every stamped
    copy.

    ON THE ELEMENT AS WELL AS ITS FIELDS, because the constant arms
    COERCE: `progress(indeterminate=el)` matched no source arm and fell
    through to `bool(el)`, and an object with no `__bool__` is true — a
    permanently spinning bar on every row, with nothing raised and
    nothing on the wire to say the binding was meant to be per-row.
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

    # THE TEXT-RANGE SURFACE (docs/ranges-plan.md D1): the three
    # primitives an editor cannot write for itself — DECORATE a set of
    # ranges, put the SELECTION at one, SCROLL one into view — plus the
    # write that opens a document into the control in the first place.
    # On the HANDLE, beside clear and focus, because that is where this
    # binding keeps every widget-addressed verb; the languages that hand
    # a guest a transaction spell the same four on it.
    #
    # kaya ships no search. What to decorate is the app's question, and
    # a find engine, a find bar and a regex dialect belong to the text
    # editor (docs/ranges-plan.md §3); what no app can write for itself
    # is colouring a run of a native text view, moving its selection and
    # scrolling it into view, which is exactly what these are.

    def set_text(self, text):
        """Put text into a text widget programmatically — the "open a
        document into the editor" write, and the dynamic spelling of
        `kaya.textarea(text=...)`.

        SUGAR OVER THE GENERIC PROP SETTER, and it earns its own name
        because the widget is UNCONTROLLED: this is ONE write, after
        which the user owns the text. The field answers with its
        ordinary `text_changed` and the app's fold takes it from there —
        the same round trip a keystroke makes.

        A write that CHANGES the text also drops whatever ranges the app
        had declared over it (a set is bound to the text it was declared
        against — see `highlight_ranges`) and spends the field's native
        undo history. Returns the widget, so it chains with the a11y
        props."""
        _records().append(wire.tx_set_text(self.id, _text_value("set_text", text)))
        return self

    def highlight_ranges(self, ranges):
        """DECLARE this textarea's decorated ranges, replacing whatever
        was declared before; an empty set is the clear.

        THE OFFSETS ARE UTF-8 BYTE OFFSETS into the widget's current
        text — kaya's unit on the wire and in all eight bindings — and
        PYTHON IS ONE OF THE FOUR LANGUAGES WHERE THAT IS NOT WHAT THE
        LANGUAGE'S OWN SEARCH RETURNS. `str.find` counts scalars:
        `"日本語 x".find("x")` is 4 where kaya's offset is 10. Search the
        UTF-8 bytes and the offsets are kaya's by construction (UTF-8 is
        self-synchronizing, so a byte-level match is always a character
        boundary — the two searches find the same occurrences):

            data, hit = doc.encode(), needle.encode()
            at = data.find(hit)
            while at >= 0:
                hits.append(range(at, at + len(hit)))
                at = data.find(hit, at + len(hit))
            editor.highlight_ranges(hits)

        APP-OWNED AND NEVER TRACKED. A declared set is bound to the text
        it was declared against: the first edit of any kind — a
        keystroke, a `set_text`, a native undo — drops it, and the app
        re-declares from the fold `text_changed` already drives. Nothing
        in kaya adjusts a range across an edit.

        An offset past the end of the text, or one that splits a
        character, fails loudly in the core rather than in a backend:
        the five platforms answer a malformed offset five different ways
        and one of them aborts the process."""
        flat = []
        for span in ranges:
            start, stop = _text_range("highlight_ranges", span)
            flat += [start, stop]
        _records().append(
            wire.tx_highlight_ranges(self.id, len(flat) // 2, flat)
        )

    def select_range(self, span):
        """Put this textarea's selection at one range (an empty range is
        a caret). Same offsets, same validation as `highlight_ranges`.

        REFUSED WHILE THE USER IS COMPOSING through an input method, in
        every backend, because honouring it commits the composition
        mid-word — measured on macOS, where the half-typed kana land in
        the document and in the app's own model. The refusal is a no-op
        and not an error: composition state is on no kaya channel, so an
        app cannot avoid the race and is not blamed for it. The
        selection is still worth asking for after the next
        `text_changed`, which is what ends a composition."""
        start, stop = _text_range("select_range", span)
        _records().append(wire.tx_select_range(self.id, start, stop))

    def reveal_range(self, span):
        """Scroll this textarea so a range is inside the viewport. A
        pure effect: it moves no state, leaves the selection alone, and
        undo does not put the scroll position back (undo restores state,
        not where you were looking). How much context lands around the
        range is the platform's own scroll-to-range behaviour."""
        start, stop = _text_range("reveal_range", span)
        _records().append(wire.tx_reveal_range(self.id, start, stop))

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

    def a11y_id(self, ident):
        """Set this widget's accessibility IDENTIFIER: a stable authored
        key that assistive tooling and UI automation address it by, and
        which is NEVER spoken. Universal — every kind carries one.

        Returns the widget, so the two props chain:
        `kaya.entry().a11y_id("name").a11y_label("Full name")`."""
        _records().append(wire.tx_set_a11y_id(self.id, str(ident)))
        return self

    def a11y_hint(self, hint):
        """Set what ACTIVATING this widget does — the platforms' hint
        (Apple defines it as the result of performing an action;
        Android carries it as the click action's label). Write a VERB
        PHRASE: VoiceOver speaks it as written, TalkBack prefixes
        "double tap to". Activation kinds only (button, checkbox,
        select, radio); the root rejects it elsewhere. Returns the
        widget, so it chains."""
        _records().append(wire.tx_set_a11y_hint(self.id, str(hint)))
        return self

    def a11y_label(self, label):
        """Set this widget's accessibility LABEL: what an assistive
        client speaks for it. Universal, and deliberately separate from
        `a11y_id` — an automation key is not a spoken name. Leave it
        unset to keep whatever the platform derives from the control's
        own content; setting it OVERRIDES that, so a button whose
        caption already reads well needs nothing here. Returns the
        widget, so the two props chain."""
        _records().append(wire.tx_set_a11y_label(self.id, str(label)))
        return self

    def accepts(self, *kinds):
        """Declare what this widget takes from a paste — the closed
        kinds by name ("text", "html", "image", "files") plus any custom
        format ids.

        ONE DECLARATION, THREE JOBS: it drives whether the Paste command
        is live while this widget is focused, it filters what can reach
        the paste hook, and on Android it IS the native registration
        (setOnReceiveContentListener takes the mime types on the view).
        Per-widget because whether Paste should be enabled is the
        INTERSECTION of what the clipboard offers and what the FOCUSED
        target takes — a search field wants plain text, a rich editor
        also wants images.

        DECLARING IS HOW AN APP OVERRIDES THE DEFAULT. A widget that
        declares nothing gets the platform's own insertion and reports
        it through the ordinary change path, which is why a plain text
        editor writes none of this and has working cut, copy and paste.
        Returns the widget, so it chains with the a11y props.
        """
        _records().append(wire.tx_set_accepts(self.id, _accept_list(kinds)))
        return self

    def on_paste(self, fn):
        """Take pasted content here: fn(clip) with the Representation
        sum, or fn(*keys, clip) for a stamped copy.

        COSTS NOTHING ON ANY PLATFORM, unlike read_clipboard: a paste is
        a user gesture, so it is its own authorisation — iOS raises no
        prompt and the focus rules are satisfied by construction. Only
        fires for a widget that declared what it `accepts`. Returns the
        widget, so it chains."""
        _app._register(self, wire.OCC_PASTED, fn)
        return self

    def context_menu(self):
        """The live-widget context anchor: `with target.context_menu():`
        declares the catalog — the same command vocabulary scoped to a
        NOUN, with the platform's own gesture (right-click, long-press).
        No shortcuts here (a shortcut needs a window catalog as its
        native dispatch home — record-time checked); the editable text
        controls (entry, textarea) reject attachment at the root."""
        return _MenuScope(("widget", self.id), shortcut_ok=False)


class Node:
    """A template node: a blueprint entry, stamped per collection entry.
    Never on screen by itself; clicks on its copies arrive with the
    copy's key path."""

    def __init__(self, id):
        self.id = id

    def context_menu(self, catalog):
        """Attach a live-zone-built context catalog
        (kaya.context_catalog) to this template node: every stamped
        copy shows the same catalog, and each activation carries that
        copy's key path — the keys ARE the noun (the on_click_node
        encoding). An item takes exactly one anchor, so a second
        attach of the same catalog raises here."""
        if catalog._attached:
            raise RuntimeError(
                "kaya: a context catalog takes exactly one anchor"
            )
        catalog._attached = True
        for root in catalog._roots:
            _records().append(wire.tx_context_attach_node(self.id, root))


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

    def __bool__(self):
        _no_truth_value("an element")

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

    def __bool__(self):
        _no_truth_value("an element")

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
        _no_truth_value("an element's field")


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

    def _absorb_key(self, key):
        """An explicit key, shown to the minter on its way into the
        table: a numeric key at or above the counter carries it up so
        the next mint clears it.

        BOOLS ARE NOT NUMBERS HERE, because they are not numbers on the
        wire either — `wire._enc.value` dispatches `bool` before `int`
        and a True key rides as VALUE_BOOL. Python's `bool` subclasses
        `int`, so the isinstance order below is the encoder's order,
        written out; anything else has no way to collide with an I64 and
        moves nothing.
        """
        if isinstance(key, bool) or not isinstance(key, int):
            return
        path = tuple(self._path)
        if key > self._owner._fresh.get(path, 0):
            self._owner._fresh[path] = key

    def insert(self, key, value):
        variant, fields = self._encode(value)
        # ABSORPTION, on the one path every explicit key travels (the
        # draft scope's `d[k] = v` lands here too): a numeric key at or
        # above the minter's counter carries it up, so hand-chosen and
        # minted keys share one space safely and in either order
        # (insert_fresh's contract).
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

        FOR DATA THAT HAS NO IDENTITY OF ITS OWN. Keys are domain
        identity and guest-chosen (DESIGN.md, the update algebra), so
        anything that already HAS a name passes it to `insert` — today
        and always. This is the other case, and it is the common one in
        a form: the app has a title and nothing else, and the
        alternative is a hand-spelled counter beside the collection,
        which in Python is a module global reached through `global` in
        every handler that adds, and whose safety rests on a
        never-rewind rule nobody wrote down.

        ONE COUNTER PER COLLECTION INSTANCE, starting at 0; the minted
        key is an I64 and is counter+1. An instance is a table — the
        live-zone collection, or one stamped copy selected by `at(...)`
        — and keys are unique within one, so that is what the counter is
        per.

        MIXING IS SAFE BY ABSORPTION: an explicit `insert` whose key is
        an int at or above the counter carries it up, so a later mint
        clears every hand-chosen numeric key already in the table. A
        string key cannot collide with an I64 at all and moves nothing.

        NO DECREMENT IS EXPRESSIBLE, and that is the whole safety
        argument. Undo and redo replay captured keys inside the core and
        never re-enter this path (`App._absorb_undo` writes the mirror
        directly), so a history walk never moves the counter; an
        abandoned transaction does not move it back either (the counter
        is deliberately outside `_journal_once` — the rollback journal
        restores the mirror, never the counter, so a key spent by an
        abandoned transaction stays spent and cannot be handed out
        twice). A fresh key is fresh forever.
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
        # The minter's counters: the highest I64 key each INSTANCE has
        # minted or absorbed, keyed by path the way `_instances` is. Not
        # in the rollback journal, on purpose — see insert_fresh.
        self._fresh = {}
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

    def _decode(self, variant, fields, current):
        """Rebuild a model value from an undo delta's wire record.

        THE MIRROR HOLDS THE APP'S OWN OBJECT — that is what makes
        `items()` the model rather than a second copy — so a restored
        entry has to be reassembled from the wire fields the core kept.
        An entry the mirror still holds is UPDATED IN PLACE, the patch()
        stance: a dataclass field the wire never carried (a handler, a
        cached thing) survives the undo instead of being dropped.
        """
        spec = self._variants[variant]
        for value in fields:
            if isinstance(value, wire.BlobHandle):
                # NOT REDEEMABLE, and loudly so: undo_body writes delta
                # values through the batch-local encoder, so a blob
                # field arrives as an index into a table that was
                # thrown away (crates/kaya/src/wire.rs). Silently
                # storing the handle would put a stranger in the app's
                # model.
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
        if isinstance(current, spec.cls):
            for name, value in zip(names, fields):
                setattr(current, name, value)
            return current
        return spec.cls(**dict(zip(names, fields)))

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
    The declarative spelling is `with app.create_window(...)`."""
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
    on_selected (the echo doctrine). The section must already be
    added."""
    _records().append(wire.tx_select_section(int(window), int(section_id)))


# The presentation hint's closed set, spelled for guests.
SECTIONS_AUTO = wire.SECTIONS_PRESENTATION_AUTO
SECTIONS_BAR = wire.SECTIONS_PRESENTATION_BAR
SECTIONS_SIDEBAR = wire.SECTIONS_PRESENTATION_SIDEBAR


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
        """Redeem the handle: returns `(file, seekable)` — an ordinary
        Python file object, and whether it supports random access.

        BLOCKS, and may block for a long time (a cloud provider can
        download the file first), so call it from a thread you chose
        and post the result back. kaya is not in the data path: the
        object returned is a real file and `read`, `mmap` and the rest
        are the ones you already know.

        `seekable` RIDES THE OPEN rather than the pick because that is
        the only place the answer exists — an Android provider may hand
        back a pipe, and nothing short of opening reveals it.
        """
        return runtime.open_picked(self.handle, mode)

    def __repr__(self):
        return f"PickedFile(name={self.name!r}, local_path={self.local_path!r})"


def pick_files(filters=(), on_result=None, window=0):
    """Ask the platform for files. THE PICK, NOT THE OPEN — the result
    carries handles you redeem later, so the name says `pick`.

    `filters` is a sequence of `(label, extensions)` pairs, advisory on
    every platform: they set a default view rather than a guarantee, so
    the guest still validates what it got. `extensions` may be a string
    or a sequence.

    on_result(files) fires exactly once with a list of PickedFile, and
    the registration retires with it — the same request/result grammar
    show_alert uses. CANCEL IS THE EMPTY LIST, faithfully: no platform
    can confirm an empty selection, so there is no sentinel to invent.

    One dialog may be live per process; show the next from the first's
    handler."""
    return _pick(True, filters, on_result, window)


def pick_file(filters=(), on_result=None, window=0):
    """The single-file spelling. The floor always returns a LIST; this
    only asks the platform for one, so the handler receives zero or one
    file."""
    return _pick(False, filters, on_result, window)


def save_file(suggested_name, filters=(), on_result=None, window=0):
    """Ask the platform WHERE TO SAVE. The picker's twin: a request that
    answers once with a capability, on the same grammar, out of the same
    one-live-dialog slot — so a save dialog and an open dialog cannot be
    up at the same time, and the next one is shown from this one's
    handler.

    `suggested_name` is the name the dialog OPENS with, and it is not
    optional: a save dialog with an empty name box is one the platform
    will not let the user complete. Every platform treats it the way it
    treats a filter — it takes it, and guarantees nothing. The user
    renames it, and Android may append an extension matching the mime
    type, so READ THE NAME YOU GOT (`file.name`) rather than the one you
    asked for.

    on_result(file) fires exactly once and the registration retires with
    it. CANCEL IS `None`, and a destination is a single PickedFile — the
    narrowing from the floor's list happens here rather than in your
    handler, because "one locator or none" is a fact of the request (no
    platform's save dialog names two destinations) and not something
    every app should re-derive from a length.

    WHAT YOU GET BACK OPENS EMPTY. A save destination may not exist yet
    — macOS, GTK and Windows answer with a name for a file nobody has
    made, and macOS does not even truncate when the user presses Replace
    — so the handle's open CREATES: opening it for FILE_MODE_WRITE
    succeeds and yields an empty file on every platform, which is the
    one behaviour to write against (docs/save-plan.md D1). Android and
    iOS hand back a document that already exists; the core absorbs the
    difference, and there is deliberately no fourth file mode asking for
    it.

    `filters` is the picker's advisory encoding, unchanged."""
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
    label and space-separated extensions. One function for the picker
    and the save request so the two cannot drift on what a filter is —
    the core keeps them together the same way (`filter_str`, wire.rs)."""
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
# A clip is not a string: every host models it as ONE item available in
# several types, with the consumer taking the richest it understands.
# So COPY TAKES A RECORD — `copy(text=..., html=...)`, where at most one
# per kind is structural rather than a duplicate check — and the two
# answers are a SUM, because you offer many and receive one.
#
# kaya DERIVES NOTHING between representations. Whether list bullets
# survive html-to-text is the app's decision, and a bad auto-derivation
# degrades every paste into a plain field silently. Files are the one
# exception, and the platforms make it: a file list also gets their own
# text rendition of the paths.


class Representation:
    """One representation, arriving — the sum `copy` is the record of.

    Nested constructors rather than five module-level names, so a match
    reads the way the wire does and `Image` cannot be mistaken for the
    `image()` widget:

        match clip:
            case None: ...                        # the universal empty
            case kaya.Representation.Text(text): ...
            case kaya.Representation.Files(files): ...
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
        hosts convert freely between image types — so compare what the
        image IS, never the bytes it arrived in."""

        __slots__ = ("bytes",)
        __match_args__ = ("bytes",)

        def __init__(self, data):
            self.bytes = data

        def __repr__(self):
            return f"Image({len(self.bytes)} bytes)"

    class Files:
        """PickedFile, plural INSIDE one representation — the same
        nesting text/uri-list and CF_HDROP already have. A pasted file
        is the picker's own capability arriving through a second door,
        so it opens with the call that already exists."""

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

    EMPTY IS THE UNIVERSAL NO, with kind 0: it covers a denied prompt on
    iOS, an unfocused reader on Android or Wayland, an empty clipboard,
    and content in no representation this read accepted. The guest is
    not told which, because the platforms deliberately do not say.
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
        # The picker's own three-per-file grouping, so a guest that
        # decodes a dialog result decodes this with the same loop.
        return Representation.Files([
            PickedFile(values[i], values[i + 1], values[i + 2])
            for i in range(0, len(values), 3)])
    return None


class UndoDelta:
    """What one step put back: the CORE-AUTHORITATIVE restored state, and
    never a replay of the ops that undid it (docs/undo-plan.md D5).

    Four runs, each a list:

    - `signals` — (signal id, restored value) pairs.
    - `texts` — (widget or node id, instance path, restored text)
      triples. THE ONLY NOTIFICATION THERE IS for that text: restoring
      a typing episode is a programmatic write, and a programmatic
      write never echoes, so an app that folds `text_changed` into its
      own model — which is every app, the field being uncontrolled —
      would go stale on exactly this step if the payload did not carry
      it.

      THE PATH IS WHICH FIELD, and it is the same identity tag every
      other occurrence already carries. EMPTY means a live widget:
      the id is the one the app holds, and there is nothing else to
      say. NON-EMPTY means a stamped copy of a template, whose identity
      is (template node, key path) because a copy has no id an app
      could hold — the very pair its own edits arrive under, since a
      template `entry`'s `on_change` is handed those keys before the
      text. A top-level `for` over a collection makes that one key, so
      `path[0]` is the row, already an int for the minter's I64 keys.

      THE RUN IS A LIST AND EVERY MEMBER COUNTS: one step can restore
      the draft and a row's note at once, so an app that reads only the
      last entry drops the other field on the floor.
    - `entries` — (collection id, instance path, key, state), with state
      None where the restored state does not have that entry at all and
      (variant, wire fields) where it does.
    - `orders` — (collection id, instance path, that instance's keys in
      order); position is the one thing per-entry statements cannot
      carry.

    THE COLLECTION MIRRORS ARE ALREADY RECONCILED from this payload
    before your handler runs, so `len(todos)` and `todos.items()` answer
    about the restored state. Signals and text are not mirrored by this
    binding (there is no read-back for either, by doctrine), which is
    why those two runs are handed to the app instead.
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
    """Join an accept list: the closed kinds by name plus any custom
    ids, space separated.

    A LIST AND NOT A MASK, because half the set is open-ended. A custom
    format that could be written and never accepted would be an escape
    hatch that only opens outward, and round-tripping an app's own data
    is the whole reason to have one. Ids reach every platform's registry
    verbatim, so they carry no spaces — which is what makes the join
    unambiguous, and what this refuses to let you break.
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

    A RECORD AND NOT A LIST: at most one per kind is structural here,
    since naming `text` twice is not something the call can express.
    `custom` is the one plural field with names — several app-defined
    formats are legitimate — and takes a mapping of id to bytes.

    `files` takes PickedFile handles: copying a file and picking one are
    the same currency, so a picked file goes straight on and the bytes
    never move through kaya. The wire order is kaya's, not this call's —
    descending richness, which is preference order on every host that
    has one.
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
    """Read the clipboard OUTSIDE any paste gesture — THE PRIVILEGED
    ONE, named for what it is rather than for pasting.

    A user's paste arrives at the widget's hook and costs nothing; this
    asks without a gesture, which the platforms have deliberately made
    expensive: iOS 16 PROMPTS when the content came from another app and
    blocks until the user answers, Android returns nothing unless the
    app has focus, and Wayland delivers no offer to an unfocused client.
    Reach for this to detect a URL or import from the clipboard, never
    to implement Paste — that is the Paste command, and it is free.

    `accepting` is the accept list; the answer carries the first match
    by descending richness, so exactly one representation is ever
    materialised. on_result(clip) fires exactly once, with the sum or
    None, and the registration retires with it — the alert's grammar.
    Returns the request id.
    """
    app = _app
    request = app._next("clipboard")
    if on_result is not None:
        app._clipboard_handlers[request] = on_result
    _records().append(wire.tx_read_clipboard(request, _accept_list(accepting)))
    return request


# --- Menus: the command vocabulary (DESIGN.md, Menus) --------------
#
# One item vocabulary, two anchors. The window bar rides the window
# construct (`with app.menu("File") as file:`); a context menu scopes
# the same verbs to a noun (`with target.context_menu():` on a live
# widget, kaya.context_catalog() + node.context_menu(catalog) for a
# template node). Creators declare into the open with-scope; handlers
# ride the declarations (on_activate=, on_toggle=, on_select=) — no
# app-global menu dispatcher exists. Node-anchored handlers receive
# the stamped copy's keys first (the keys ARE the noun).


class MenuItem:
    """A live menu item — its OWN id space (the c_menu_item counter),
    never a widget or node id. One command identity: exactly one
    parent or anchor, forever (append-only; nothing is removed in v1).
    The methods are the dynamic tier — every mutable prop, each judged
    by the root against the item's kind and anchor — plus append(),
    the reopening scope for a retained grouping node."""

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
        bound Bool signal. Enablement writes never emit anything;
        disabling a grouping node disables its subtree everywhere."""
        if isinstance(value, Signal):
            _records().append(wire.tx_bind_menu_enabled(self.id, value.id))
        else:
            _records().append(wire.tx_set_menu_enabled(self.id, bool(value)))

    def checked(self, value):
        """A toggle's state (toggle items only — root-checked): the
        Checkbox contract. The programmatic write is configuration:
        QUIET, no menu_toggled echo (the echo doctrine)."""
        if isinstance(value, Signal):
            _records().append(wire.tx_bind_menu_checked(self.id, value.id))
        else:
            _records().append(wire.tx_set_menu_checked(self.id, bool(value)))

    def value(self, v):
        """A radio group's selected option index (radio groups only —
        root-checked): the Choice contract. QUIET, like checked."""
        if isinstance(v, Signal):
            _records().append(wire.tx_bind_menu_value(self.id, v.id))
        else:
            _records().append(wire.tx_set_menu_value(self.id, float(v)))

    def icon(self, data):
        """The item's icon (the blob channel): used by phone promotion,
        ignored where native menu dress has no icons. Const-only."""
        _records().append(
            wire.tx_set_menu_icon(self.id, runtime.register_blob(data)))

    def primary(self, on):
        """The phone-bar promotion hint (actions only — root-checked).
        Flipping it recomputes the promoted set deterministically;
        INERT on desktops — not a toolbar grammar. Const-only."""
        _records().append(wire.tx_set_menu_primary(self.id, bool(on)))

    def role(self, name):
        """Declare this action a standard command (actions only —
        root-checked). The declaration is uniform; PLACEMENT is each
        host's business: macOS shows `kaya.ROLE_SETTINGS` in the
        application menu, everyone else leaves the item where it was
        declared. One item per role, and the role never invents a
        chord — spell the shortcut too if the app wants one.
        Const-only."""
        _records().append(wire.tx_set_menu_role(self.id, name))

    def shortcut(self, spelling):
        """The shortcut of any LEAF command — action, toggle, or one
        option of a group (window-anchored only — the
        root knows the retained item's anchor and judges). Canonicalized
        by the binding's one parser (wire.canonicalize_shortcut); the
        shortcut is another affordance of the same item — it fires the
        SAME menu_activated occurrence as a click. Const-only."""
        _records().append(wire.tx_set_menu_shortcut(self.id, spelling))

    def append(self):
        """Reopen this RETAINED grouping node — the append-at-any-time
        discipline: `with file.append():` declares more children
        (kaya.item/kaya.toggle/...; kaya.option for a radio group).
        The root re-validates each appended subtree in the item's real
        anchor context (depth, shortcuts, duplicates)."""
        return _MenuScope(("item", self.id), shortcut_ok=True, value=self)


class ContextCatalog:
    """A context catalog built free of any anchor
    (kaya.context_catalog) for a template node: menu items are live
    and shared across stamped copies, so the catalog is built HERE, in
    the live zone, and node.context_menu(catalog) attaches it inside
    the template. An item takes exactly one anchor — a second attach
    raises."""

    def __init__(self):
        self._roots = []
        self._attached = False


class _MenuScope(_Scope):
    """A with-block whose creators seat under one menu anchor: a
    grouping item (bar menus, submenus, radio groups, reopened
    chains), a live widget's context anchor, or a free context
    catalog. shortcut_ok carries the one anchor-dependent rule to
    record time — a shortcut needs a window catalog as its native
    dispatch home — with the root as the floor beneath. on_exit runs
    after the block's children recorded — the radio value's seat: the
    selected index must land AFTER the options it addresses (the root
    judges the index against the option count at the record)."""

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


#: The closed standard-command vocabulary (DESIGN.md, Menus). macOS
#: places this one in the application menu; every other host leaves the
#: item where the app declared it.
#: A NAMED VOCABULARY FOR THE CLOSED HALF, exactly as the menu roles
#: are. The accept list is open-ended — a custom format id is any
#: app-chosen string — so the four closed kinds cannot be a mask; but
#: they can be spelled once here instead of quoted at every call site.
#: A MISTYPED BARE STRING IS SILENT: it becomes a custom format id no
#: clipboard will ever offer, so Paste stays dead and the paste hook
#: never fires, with nothing to see anywhere. A custom id has no
#: constant by nature — the app that defines it names it.
ACCEPT_TEXT = "text"
ACCEPT_HTML = "html"
ACCEPT_IMAGE = "image"
ACCEPT_FILES = "files"


ROLE_SETTINGS = "settings"

#: The three clipboard commands. They lower to the platform's own, act
#: on the FOCUSED widget, and work out their own enablement from what
#: the clipboard offers and what that widget accepts.
#:
#: GESTURES ARE COMMANDS BECAUSE KAYA HAS NO SELECTION API: only the
#: widget knows what is selected, so an app cannot assemble the payload
#: for "copy the selected text" out of the data layer. Copy of a
#: selection is therefore necessarily a command, and Paste is its
#: mirror. `kaya.copy` and `kaya.read_clipboard` are for overriding
#: that default and for targets with no native behaviour.
ROLE_CUT = "cut"
ROLE_COPY = "copy"
ROLE_PASTE = "paste"

#: The two history commands, on the same terms. They ask the FOCUSED
#: widget first — a text field answers with its own typing history where
#: it has one — and otherwise the window's ledger answers, which is what
#: an editor user expects: mid-typing, Undo means the typing; after a
#: structural action, Undo means the action (docs/undo-plan.md D6). An
#: app that names no group still gets working text undo from these two,
#: because the first tier is the platform's.
ROLE_UNDO = "undo"
ROLE_REDO = "redo"


def _menu_require_catalog(scope):
    """A chord and a role both need a window catalog as their home: the
    root rejects either on a context anchor, and the binding says so at
    the call site (the Rust tier makes it a compile error)."""
    if not scope._shortcut_ok:
        raise ValueError(
            "kaya: a context item takes no shortcut — a shortcut "
            "needs a window catalog as its native dispatch home"
        )


def item(label, shortcut=None, enabled=None, icon=None, primary=None,
         role=None, on_activate=None):
    """An action — a leaf command firing exactly one menu_activated
    occurrence (menu click OR its shortcut: ONE occurrence, one
    dispatch path). The handler rides the declaration; on a
    template-node catalog it receives the stamped copy's keys as
    arguments (`def on_remove(group, item):`)."""
    it = _menu_create(wire.MENU_KIND_ACTION, label)
    scope = _menu_seat(it)
    if shortcut is not None:
        _menu_require_catalog(scope)
        it.shortcut(shortcut)
    if enabled is not None:
        it.enabled(enabled)
    if icon is not None:
        it.icon(icon)
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


def toggle(label, checked=None, enabled=None, icon=None, shortcut=None,
           on_toggle=None):
    """A toggle — a stateful leaf reusing the Checkbox contract: user
    flips emit menu_toggled (the handler receives the new state;
    template-node copies get the stamped keys first); programmatic
    checked writes are quiet."""
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
    if on_toggle is not None:
        _app._menu_handlers[(wire.OCC_MENU_TOGGLED, it.id)] = on_toggle
    return it


def option(label, enabled=None, icon=None, shortcut=None):
    """One labeled radio option, appended in declaration order — the
    order IS the index vocabulary the group's value selects over.
    Options carry no state of their own; selection lives on the
    group."""
    it = _menu_create(wire.MENU_KIND_RADIO_OPTION, label)
    scope = _menu_seat(it)
    if shortcut is not None:
        _menu_require_catalog(scope)
        it.shortcut(shortcut)
    if enabled is not None:
        it.enabled(enabled)
    if icon is not None:
        it.icon(icon)
    return it


def separator():
    """Native grouping chrome: no label, no props, no handle kept."""
    it = _menu_create(wire.MENU_KIND_SEPARATOR)
    _menu_seat(it)


def menu(label, enabled=None, icon=None):
    """A NESTED menu — grouping, never navigation: `with
    kaya.menu("Sub"):` inside an open menu scope (one nested grouping
    level is the cap, root-checked). Bar-level menus are `app.menu` —
    the menubar rides the window construct."""
    it = _menu_create(wire.MENU_KIND_MENU, label)
    scope = _menu_seat(it)
    if enabled is not None:
        it.enabled(enabled)
    if icon is not None:
        it.icon(icon)
    return _MenuScope(("item", it.id), scope._shortcut_ok, value=it)


def radio_group(label, value=None, enabled=None, icon=None, on_select=None):
    """A NESTED radio group — the Choice contract inline, with the
    platform's checkmark idiom: `with kaya.radio_group("Sort"):`
    declares only kaya.option children. `value` is the selected
    0-based option index (an int or a bound signal; programmatic
    writes are quiet); on_select receives each USER pick's new index.
    Bar-level groups are `app.radio_group`."""
    it = _menu_create(wire.MENU_KIND_RADIO_GROUP, label)
    scope = _menu_seat(it)
    if enabled is not None:
        it.enabled(enabled)
    if icon is not None:
        it.icon(icon)
    if on_select is not None:
        _app._menu_handlers[(wire.OCC_MENU_VALUE_CHANGED, it.id)] = on_select
    # value= lands at block exit, AFTER the option children: the index
    # addresses options, and the root judges its domain at the record.
    on_exit = (lambda: it.value(value)) if value is not None else None
    return _MenuScope(("item", it.id), scope._shortcut_ok, value=it,
                      on_exit=on_exit)


def context_catalog():
    """Build a context catalog UNANCHORED — free root items for a
    template-node anchor: `with kaya.context_catalog() as catalog:`.
    Menu items are live and shared across stamped copies, so the
    catalog is built here, in the live zone; node.context_menu(catalog)
    attaches it inside the template, and each activation carries the
    copy's key path. Context items take no shortcuts."""
    catalog = ContextCatalog()
    return _MenuScope(("free", catalog), shortcut_ok=False, value=catalog)


def window_size(width, height):
    """Request the primary surface's content size (DIP). ADVISORY on
    every platform: honored where the window manager permits (the
    desktops), recorded only where the system owns geometry (the
    phones) — a request, never a guarantee."""
    _records().append(wire.tx_set_window_width(0, float(width)))
    _records().append(wire.tx_set_window_height(0, float(height)))


#: The undo-group record's kind, in the two header bytes `record()`
#: frames it with — how `undoable` recognises a marker it already put at
#: the head, without unpacking anything.
_UNDO_GROUP_TAG = wire.TX_UNDO_GROUP.to_bytes(2, "little")


def undoable(label, window=0):
    """Make THIS transaction one undoable step in `window`'s history,
    under `label` — one call, and it is the app's whole undo surface
    (docs/undo-plan.md D2).

    The name is what the step is called; everything else in this
    transaction is what the step did. The core keeps the inverse of what
    the batch did to signals and collections and hands it back through
    the window's `on_undone`, so there is no undo stack to write, no
    command objects, and no re-run of any handler.

    THE AMBIENT TIER SPELLS IT AS A CALL, not as a keyword on
    `app.build()`, because a handler does not open its own transaction —
    the binding does (`App._dispatch`), and a second scope inside a
    handler raises. The label is usually computed in the handler
    ("add milk"), so it could not ride the declaration either. The
    marker goes AT THE HEAD of the batch wherever this call sits in the
    body: a handler naturally builds first and knows what the step was
    afterwards, and the wire's head-of-batch rule must not turn that
    into a footgun.

    THE UNDOABLE SET IS THE REACTIVE HALF (D4): signal writes and the
    five collection deltas, whose inverse the core derives from state it
    already keeps. Pure effects (focus) ride along and are simply not
    restored — undo restores state, not where you were looking (A2).
    Anything else in the same transaction — `clear`, create/destroy,
    structure, const props, commands, dialog and clipboard requests — is
    REFUSED at apply, loudly, naming the op, and the scene is left
    exactly as it was. An app that wants a widget property undoable
    binds it to a signal.
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


def signal(initial):
    handle = Signal(_app._next("signal"), initial)
    # By id, for the undo path: a restored value arrives as a signal id
    # and has to reach the binding's own cache (App._absorb_undo).
    _app._signals[handle.id] = handle
    _records().append(wire.tx_create_signal(handle.id, initial))
    return handle


def collection(record_type=None):
    """Declare a collection. With no argument, a scalar (str) table —
    the one-field case. With a dataclass, a record collection: the
    dataclass IS the schema (wire-typed fields, declaration order), and
    `element.field` / `patch(key, field=...)` project it."""
    handle = Collection(_app._next("collection"), record_type)
    # THE UNDO PATH ARRIVES BY ID, not by handle: an `undone` payload
    # names the collections it restored the way the core knows them, so
    # the binding needs the way back. Registered here because this is
    # the one place a collection is born.
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


def grid(columns, grow=None, spacing=None):
    """A grid container: `with kaya.grid(2):` parents its children,
    laying them out row-major into `columns` columns — each column
    takes its NATURAL width, aligned across rows (the thing nested
    rows cannot express). `spacing` is the inter-cell gap on both
    axes."""
    handle = _widget(wire.KIND_GRID)
    _records().append(wire.tx_set_columns(handle.id, float(columns)))
    _set_grow(handle, grow)
    _set_spacing(handle, spacing)
    return _Container(handle)


def spacer(grow=1.0):
    """A spacer: PURE SUGAR for an empty grown column — it consumes
    the leftover main-axis space between its siblings (the grow
    contract; no new vocabulary)."""
    handle = _widget(wire.KIND_COLUMN)
    _set_grow(handle, grow)
    return handle


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


def textarea(text=None, on_change=None, grow=None):
    """A multi-line text editor: the entry's uncontrolled contract
    (the widget owns its text, `on_change` receives each edit, the
    clear/focus commands apply) over the platform's real multi-line
    editor."""
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
        # The ladder needs a floor. The other seven bindings type this
        # argument, so a source they do not recognize fails to compile;
        # Python's equivalent of not compiling is raising here, and
        # without this arm the call bound NOTHING and said nothing —
        # `kaya.label(bind=el)` inside a `cases.case(...)` arm hands over
        # the refined proxy, which is not an `Element`, so it declared a
        # blank label and the row's text simply never appeared.
        raise TypeError(
            f"kaya: label bind takes a Signal, the enclosing For's element, "
            f"or one of its fields (el.title), not {type(bind).__name__} — "
            "inside a case arm project the field: kaya.label(bind=note.text)"
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


def _window_props(window, title, width, height, veto_close, dirty,
                  list_detail, sections_presentation):
    """The window construct's props, emitted into the ambient
    transaction — ONE place, so the scene scope and the live call
    cannot drift apart. The scope calls it from `__enter__` (right
    after any create_window); `App.window` calls it directly when a
    transaction is already open."""
    records = _records()
    if title is not None:
        records.append(wire.tx_set_window_title(window, str(title)))
    if veto_close is not None:
        records.append(wire.tx_set_window_veto_close(window, bool(veto_close)))
    # `dirty` sits beside `veto_close` and is ORTHOGONAL to it: either
    # rides this construct without the other. See App.window for what it
    # means and what it deliberately does not do.
    if dirty is not None:
        records.append(wire.tx_set_window_dirty(window, bool(dirty)))
    if list_detail is not None:
        records.append(wire.tx_set_window_list_detail(window, bool(list_detail)))
    if sections_presentation is not None:
        records.append(wire.tx_set_window_sections_presentation(
            window, int(sections_presentation)))
    if width is not None or height is not None:
        if width is None or height is None:
            raise ValueError("kaya: window width and height travel together")
        records.append(wire.tx_set_window_width(window, float(width)))
        records.append(wire.tx_set_window_height(window, float(height)))


class _LiveWindow:
    """What the window construct returns when it was called LIVE — its
    props are already in the ambient transaction, so there is nothing
    left to enter.

    It exists to make the other spelling's mistake loud. `with
    app.window(dirty=True):` inside a handler would otherwise reach
    `_TxScope.__enter__` and report "transactions do not nest", which is
    true and unhelpful: the answer is not to find somewhere else to put
    the transaction, it is that the live form takes no `with` at all.
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
                 list_detail=None,
                 sections_presentation=None, push=False,
                 intercept_back=None, on_popped=None, on_back=None,
                 section=False, on_selected=None):
        # FIRST, so __del__ below can read them even if this __init__
        # raises on one of its own conversions.
        self._entered = False
        self._app = app
        self._mount = mount_on_exit
        self._title = title
        self._width = width
        self._height = height
        self._window = int(window)
        self._create = create
        self._veto_close = veto_close
        self._dirty = dirty
        self._list_detail = list_detail
        self._sections_presentation = sections_presentation
        self._push = push
        self._intercept_back = intercept_back
        self._on_popped = on_popped
        self._on_back = on_back
        self._section = section
        self._on_selected = on_selected

    def __del__(self):
        # A construct that was BUILT AND NEVER ENTERED emitted nothing —
        # its props went nowhere and no error said so. That silence is
        # reachable only from the live spelling's shape: inside a
        # transaction `app.window(dirty=True)` is a real call, and
        # outside every transaction the same line is this object, which
        # nobody enters. In CPython the temporary dies on the statement
        # itself, so the complaint lands at the mistake rather than at
        # exit. Guarded because __del__ can run while the interpreter is
        # tearing stderr down, and a stream error here would print a
        # second, less useful message on top of this one.
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
            # A section's scene scope (the push_entry nesting rules:
            # it may open inside the ambient build): add_section into
            # the primary window, the section's props, and the body's
            # root mounts INTO the section on exit. Append-only —
            # sections have no destruction grammar.
            self._nested = _tx is not None
            if not self._nested:
                _tx = []
                _journal = {}
            self._outer = (_recording, _pending_root)
            _recording = True
            _pending_root = None
            _records().append(wire.tx_add_section(0, self._window))
            if self._title is not None:
                _records().append(
                    wire.tx_set_section_title(self._window, str(self._title)))
            # Per-section, NOT one-shot: the user can return any
            # number of times; a programmatic select never fires it.
            if self._on_selected is not None:
                self._app._section_selected[self._window] = self._on_selected
            return self
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
        _window_props(
            self._window, self._title, self._width, self._height,
            self._veto_close, self._dirty, self._list_detail,
            self._sections_presentation)
        return self

    def __exit__(self, exc_type, exc, tb):
        global _tx, _recording, _journal, _pending_root
        if self._section or self._push:
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
        # An abandoned transaction must not leave a menu scope armed
        # for the next one (the poisoned-zone rule the template depth
        # already follows).
        _menu_scopes[:] = []
        if exc_type is not None or abandoned:
            # Any abort (a raising body, a broken trace) resets the
            # zone state — the surviving app must not inherit a
            # poisoned template depth or parent stack (the rule every
            # binding's abort path follows; pinned by the menu
            # emission checks running after the break-trace check).
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
            # body must run to completion — it authors the blueprint,
            # it does not iterate entries.
            for restore in journal.values():
                restore()
            raise RuntimeError(
                "kaya: a `for t in coll:` template never closed — the "
                "loop body must run to completion (no break/return); "
                "conditional rendering is kaya.when"
            )
        if self._mount and _pending_root is not None:
            # A props-only body is legal (the sections shape: the
            # switcher IS the window content, the window has no root
            # of its own) — nothing mounts, nothing errors.
            records.append(wire.tx_mount(self._window, _pending_root.id))
        if records:
            runtime.submit(*records)
        return False


class App:
    def __init__(self):
        global _app
        self._counters = {"signal": 0, "widget": 0, "collection": 0, "node": 0,
                          "alert": 0, "menu_item": 0, "file_dialog": 0,
                          "clipboard": 0}
        # Dispatch tables: (occurrence kind, id) per space — widget ids
        # and template-node ids collide numerically, so two dicts.
        self._widget_handlers = {}
        self._alert_handlers = {}
        self._file_dialog_handlers = {}
        # Clipboard reads share the alert's request/result grammar and
        # so its table shape: one-shot, keyed by request id.
        self._clipboard_handlers = {}
        # Menu items are their own id space — their own table ("two
        # tables, always" — now N tables, still always), keyed by
        # (occurrence kind, item id).
        self._menu_handlers = {}
        # Per-entry navigation handlers, keyed by entry surface id
        # (the request-bound alert precedent).
        self._entry_popped = {}
        self._back_requested = {}
        self._section_selected = {}
        # Per-window lifecycle handlers, keyed by window id — same
        # rule: handlers scope to the thing that creates them.
        self._close_requested = {}
        self._window_closed = {}
        # Per-window history handlers, keyed the same way and NOT
        # one-shot: a history is walked as often as the user likes. Undo
        # in one window has never meant "revert what happened in another
        # one", so the ledger and its two handlers are per surface.
        self._undone = {}
        self._redone = {}
        # Collections and signals by their core id, for the undo path:
        # an `undone` payload names them rather than handing back
        # handles.
        self._collections = {}
        self._signals = {}
        self._node_handlers = {}
        # Work handed over by other threads, waiting to run as
        # transactions on the app thread. THE ONLY STATE HERE TOUCHED
        # FROM ANOTHER THREAD, and the only reason App carries a lock at
        # all — everything above is app-thread-only by construction.
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

    def _register_history(self, window_id, on_undone, on_redone):
        """Seat a surface's two history handlers. Per window and NOT
        one-shot (the on_section_selected stance, not the alert's): a
        history is walked as often as the user likes, so both outlive
        every step."""
        if on_undone is not None:
            self._undone[int(window_id)] = on_undone
        if on_redone is not None:
            self._redone[int(window_id)] = on_redone

    def create_window(self, window_id, title=None, width=None, height=None,
                      veto_close=None, dirty=None, list_detail=None,
                      sections_presentation=None,
                      on_close_requested=None, on_closed=None,
                      on_undone=None, on_redone=None):
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
        it. on_undone(label, delta) / on_redone(label, delta) fire each
        time kaya routes an undo at THIS surface — see App.window.

        The prop set is App.window's, `dirty` included: an auxiliary
        surface holds unsaved work as readily as the primary one. To
        raise or lower the mark LATER, call the construct again with
        this surface's id — `app.window(dirty=True, window_id=7)`."""
        if on_close_requested is not None:
            self._close_requested[int(window_id)] = on_close_requested
        if on_closed is not None:
            self._window_closed[int(window_id)] = on_closed
        self._register_history(window_id, on_undone, on_redone)
        return _TxScope(
            self, mount_on_exit=True, window=window_id, create=True,
            title=title, width=width, height=height, veto_close=veto_close,
            dirty=dirty, list_detail=list_detail,
            sections_presentation=sections_presentation)

    def window(self, title=None, width=None, height=None, veto_close=None,
               dirty=None, list_detail=None, sections_presentation=None,
               on_close_requested=None, on_closed=None,
               on_undone=None, on_redone=None, window_id=0):
        """The scene scope: an ambient transaction whose single
        top-level container mounts into the default window on exit.
        The attribute set is EXACTLY create_window's — a window's
        attributes ride its window construct, and the primary differs
        only in having no creation moment (the process owns it).
        `title` names the surface; `width`/`height` request content
        size in DIP (advisory); `veto_close` arms the close-veto
        class; `list_detail` asks this surface to present its entry
        stack as list-detail, and WHICH way it presents is the
        platform's answer (DESIGN.md, Adaptive list-detail);
        `sections_presentation` is the ADVISORY sections hint
        (kaya.SECTIONS_AUTO/BAR/SIDEBAR); `window_id` names the surface
        the attributes are about — 0, the primary, unless you say
        otherwise (the trailing-id spelling C# and OCaml already carry).

        `dirty` says this surface holds UNSAVED WORK, and each backend
        spells its own platform's affordance: the dot in the close
        button on macOS, a leading `*` in the RENDERED caption on
        Windows, a bullet beside the header-bar title on GTK, nothing on
        the phones, which have none (docs/dirty-plan.md D2/D4). STATE,
        NOT CHROME — the title you declared is left untouched, with no
        marker composed into it and no placeholder to leave room for
        (Qt's `[*]` template is the named rejection, D1). And it ARMS
        NOTHING (D3): "unsaved changes, close anyway?" is `veto_close`
        plus `kaya.show_alert`, composed by the app, because apps
        legitimately differ on what that flow should do. The two props
        are orthogonal — either rides this construct without the other.

        NOTHING INFERS IT. Writing the document's signal does not raise
        the mark and saving does not lower it: say both, in the one
        transaction the handler already is.

        THE LIVE SPELLING IS THIS SAME CONSTRUCT, CALLED AGAIN, because
        no window attribute lives as a loose function outside it
        (DESIGN.md, Binding conventions — `window_title` retired
        2026-07-22). A handler does not open its own transaction; the
        binding does (`App._dispatch`), so inside one the construct
        drops the `with` and becomes a plain call whose props join the
        transaction already running:

            with app.window(title="dirty", veto_close=True):   # the scene
                ...

            def edit():                                        # a handler
                doc.set("notes and a line")
                app.window(dirty=True)

        on_undone(label, delta) fires each time kaya routes an undo at
        this surface, with the group's label — EMPTY for a typing
        episode kaya took back itself, which the app spells however it
        likes — and the whole restored state (kaya.UndoDelta). Per
        window and PERSISTENT: a history is walked as often as the user
        likes, so it never retires. on_redone is its twin. Neither
        fires for a native-tier undo the platform's own affordance
        drove (docs/undo-plan.md A6)."""
        window_id = int(window_id)
        if on_close_requested is not None:
            self._close_requested[window_id] = on_close_requested
        if on_closed is not None:
            self._window_closed[window_id] = on_closed
        self._register_history(window_id, on_undone, on_redone)
        if _tx is not None:
            # THE LIVE FORM. A transaction is already open — this call
            # is inside a handler, or inside `with app.build():` — so
            # the props join it right here and there is nothing to
            # enter. The thread check is the one the scope form does in
            # `__enter__`: `_tx` is a module global, so a background
            # thread would otherwise stamp records into the app
            # thread's open transaction (see _require_app_thread).
            _require_app_thread()
            _window_props(window_id, title, width, height, veto_close,
                          dirty, list_detail, sections_presentation)
            return _LiveWindow()
        return _TxScope(
            self, mount_on_exit=True, window=window_id,
            title=title, width=width, height=height,
            veto_close=veto_close, dirty=dirty, list_detail=list_detail,
            sections_presentation=sections_presentation)

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

    def add_section(self, section_id, title=None, on_selected=None):
        """A section's scene scope (DESIGN.md, Sections): add_section
        into the primary window plus the section's props, and the
        single top-level container mounts INTO IT on exit. Section
        ids are guest-allocated in the shared surface namespace; the
        set is append-only (no destruction grammar), and every
        section's root is retained while covered — switching is
        SELECTION, not lifecycle.

        on_selected() rides the add (per-section): fires each time
        the USER switches to this section through the platform's
        switcher — post-fact and NOT one-shot. A programmatic
        kaya.select_section does not fire it (the echo doctrine)."""
        return _TxScope(
            self, mount_on_exit=True, window=section_id, section=True,
            title=title, on_selected=on_selected)

    def menu(self, label, enabled=None, icon=None, window=0):
        """A top-level menu in `window`'s command catalog — the
        menubar rides the window construct (DESIGN.md, Menus):
        `with app.menu("File", enabled=can_export) as file:` declares
        the children (kaya.item/kaya.toggle/nested kaya.menu/
        kaya.radio_group/kaya.separator) and yields the retained
        handle, which file.append() reopens at any time. `label` is
        constant text or a bound Str signal; `enabled` a bool or a
        bound Bool signal — disabling the menu disables its subtree
        (the inherited-disabled contract)."""
        it = _menu_create(wire.MENU_KIND_MENU, label)
        _records().append(wire.tx_menubar_append(int(window), it.id))
        if enabled is not None:
            it.enabled(enabled)
        if icon is not None:
            it.icon(icon)
        return _MenuScope(("item", it.id), shortcut_ok=True, value=it)

    def radio_group(self, label, value=None, enabled=None, icon=None,
                    on_select=None, window=0):
        """A BAR-LEVEL radio group — admissible wherever a menu
        grouping node is (it materializes as a top-level menu with the
        platform's checkmark idiom): `with app.radio_group("Sort",
        value=sort, on_select=f):` declares only kaya.option children.
        `value` is the selected 0-based index (the Choice contract:
        int or bound signal; programmatic writes are quiet), and
        on_select receives each USER pick's new index."""
        it = _menu_create(wire.MENU_KIND_RADIO_GROUP, label)
        _records().append(wire.tx_menubar_append(int(window), it.id))
        if enabled is not None:
            it.enabled(enabled)
        if icon is not None:
            it.icon(icon)
        if on_select is not None:
            self._menu_handlers[(wire.OCC_MENU_VALUE_CHANGED, it.id)] = on_select
        # value= lands at block exit, AFTER the option children: the
        # index addresses options, and the root judges its domain at
        # the record.
        on_exit = (lambda: it.value(value)) if value is not None else None
        return _MenuScope(("item", it.id), shortcut_ok=True, value=it,
                          on_exit=on_exit)

    def _dispatch(self, handler, *args):
        """One handler dispatch, INSIDE an ambient transaction. The
        rule is uniform across every binding (DESIGN.md, "a handler is
        a transaction"): the runtime opens the transaction, the handler
        body queues into it, and it commits atomically on return. An
        exception crosses the build boundary — which rolled the mirrors
        back and dropped the records — is logged, and the loop moves to
        the next occurrence. Non-Exception aborts (KeyboardInterrupt)
        still propagate: the fatal floor.

        The LIFECYCLE occurrences used to skip this and call the handler
        bare, so `kaya.destroy_window` inside an on_close_requested
        raised "no ambient transaction" and every scene opened one by
        hand. Go wrapped all of them from the start; Python was the
        outlier (fixed 2026-07-27).
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
        """Run fn as a transaction on the app thread, soon. THE ONE
        method safe to call from another thread, and the answer to "how
        does background work reach the UI".

        `with app.build():` is a transaction NOW on the calling thread;
        post is the same transaction SOON on the app thread — so a
        background thread writes ordinary blocking Python and hands back
        only the result:

            def worker():
                data = urlopen(url).read()      # blocks this thread
                app.post(lambda: content.set(data))   # back on the app thread

            threading.Thread(target=worker, daemon=True).start()

        Signals are ids and are meant to be captured; that is how the
        posted callable names what to write. A posted callable runs in
        its OWN transaction, after whatever is running now, so posting
        from inside a handler queues for after and never nests.
        """
        with self._post_lock:
            self._posted.append((fn, args))
        # The app thread may be parked in C waiting on the ring. Posted
        # work is not an occurrence and never enters that ring, so this
        # is the only way it hears about it.
        runtime.wake()

    def _absorb_undo(self, delta):
        """Fold an undo's payload into the collection mirrors.

        The rollback journal in reverse: an abandoned transaction
        restores a snapshot because nothing was shipped, while an undo
        restores a delta because everything WAS — the core already
        moved, and the mirror is what would otherwise be left behind.
        Same machinery, opposite case, and the payload is
        core-authoritative so nothing here re-derives anything.

        BEFORE THE HANDLER AND WITHOUT ONE. An app that registered no
        on_undone still has a mirror, and `len(todos)` after a routed
        undo must answer about the restored state either way.

        A signal has no read-back and no mirror the app can see, by
        doctrine — but this binding keeps the last written value to skip
        no-op DERIVED writes, and an undo moves signals behind that
        cache. So the cache follows the payload, which is why the
        `signals` run is read here as well as handed to the app: the
        core says what the value is, and a derived signal the group
        wrote is an ordinary signal in that same run. Text is neither
        mirrored nor cached, and passes straight through.

        NO DERIVED RECOMPUTE, DELIBERATELY — the absence is the design,
        not an omission. A derived signal's write rode the SAME
        transaction as the mutation that caused it
        (`Collection._recompute_derived` appends an ordinary
        `tx_write_signal` after every mutation, unconditionally), so
        when that transaction was a named step the group banked the
        derived value in both of its directions, and the core has
        already restored it — it arrives in the `signals` run above like
        any other signal. Python says the same thing structurally, since
        it has no type to say it with: recomputing appends to
        `_records()`, and there is no ambient transaction here. This
        runs straight off the occurrence loop (`_dispatch_loop`), before
        and without any handler, so a recompute would have nowhere to
        put the write.

        WHAT A RECOMPUTE HERE WOULD COST is worth spelling out, because
        the call graph invites one (docs/deferred.md carries the
        retracted "a derived signal goes stale after an undo" defect,
        inferred from exactly this method calling nothing). Agreeing
        with the banked value it writes nothing at all — `_recompute`'s
        `!=` guard sees the cache this method just moved — so it is dead
        code hiding the mechanism. Disagreeing, it raises "no ambient
        transaction" in the middle of an occurrence; and were it handed
        a transaction to write into, it would put a value the ledger
        never banked on screen, so the screen and the ledger's record of
        the step would drift apart and the next walk through the history
        would jump back. Disagreement is reachable exactly two ways: a
        compute that reads anything beyond the entries, or a derive
        declared after that step was banked (deferred.md's one
        residual). Neither is fixed by recomputing behind the core's
        back.
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
                # collection instances with it; the mirrors follow, the
                # way `remove` already makes them.
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
            # Position by the payload's list, keeping anything it does
            # not name at the end: the delta states one instance's whole
            # order, and an entry it never mentions is one this undo did
            # not touch. Insertion-ordered dicts have no move, so the
            # named keys are re-added in order and the rest follow.
            for key in list(keys) + [k for k in table if k not in keys]:
                if key in table:
                    table[key] = table.pop(key)

    def _drain_posted(self):
        """Run everything posted, each as its own transaction, in order.

        The batch is taken and the lock released BEFORE any of it runs,
        so a callable that posts again lands in the NEXT batch. Holding
        the lock across the calls would let a self-posting callable drain
        forever and starve the occurrence loop.
        """
        with self._post_lock:
            batch, self._posted = self._posted, []
        for fn, args in batch:
            self._dispatch(fn, *args)

    def _dispatch_loop(self):
        global _app_thread
        _app_thread = threading.get_ident()
        while True:
            # Posted work first, then the ring. Draining at the TOP is
            # what makes a wake sufficient: whatever brought this thread
            # back, it looks here before anywhere else.
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
                # One-shot: the window is gone; both registrations
                # retire with it.
                self._close_requested.pop(ident, None)
                handler = self._window_closed.pop(ident, None)
                if handler is not None:
                    self._dispatch(handler)
                continue
            if kind == wire.OCC_ENTRY_POPPED:
                # One-shot: the entry is gone; both registrations
                # retire with it.
                self._back_requested.pop(ident, None)
                handler = self._entry_popped.pop(ident, None)
                if handler is not None:
                    self._dispatch(handler)
                continue
            if kind == wire.OCC_SECTION_SELECTED:
                # NOT one-shot: sections never die, and the user can
                # return any number of times (ident is the section;
                # the window rides as the payload).
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
                # One-shot like the alert, and the id retires with it.
                # payload is the decoder's list of (handle, name,
                # local_path) triples; EMPTY IS CANCEL.
                handler = self._file_dialog_handlers.pop(ident, None)
                if handler is not None:
                    self._dispatch(handler, [
                        PickedFile(h, n, p) for (h, n, p) in payload])
                continue
            if kind == wire.OCC_CLIPBOARD_RESULT:
                # One-shot like the alert, and the request retires with
                # it. EMPTY IS THE UNIVERSAL NO and arrives as None —
                # denied, unfocused, absent and nothing-we-accept alike,
                # because no platform says which.
                handler = self._clipboard_handlers.pop(ident, None)
                if handler is not None:
                    self._dispatch(handler, _representation(payload))
                continue
            if kind in (wire.OCC_UNDONE, wire.OCC_REDONE):
                # ONE STEP CAME BACK. ident is the window whose ledger
                # moved, and the payload is the label plus the whole
                # restored state.
                #
                # NOT one-shot: a history is walked as often as the user
                # likes, so both registrations outlive every step (the
                # on_section_selected stance, not the alert's).
                #
                # THE MIRRORS FOLLOW FIRST, and unconditionally: an undo
                # moved core state without a transaction, so a model
                # read after one is stale otherwise — including in an
                # app that registered no handler at all.
                label, signals, texts, entries, orders = payload
                delta = UndoDelta(signals, texts, entries, orders)
                self._absorb_undo(delta)
                table = self._undone if kind == wire.OCC_UNDONE else self._redone
                handler = table.get(ident)
                if handler is not None:
                    self._dispatch(handler, label, delta)
                continue
            if kind in (wire.OCC_MENU_ACTIVATED, wire.OCC_MENU_TOGGLED,
                        wire.OCC_MENU_VALUE_CHANGED):
                # Menu occurrences key the menu-item table — their own
                # id space, so neither widget nor node ids can collide
                # with them. Node-anchored context items carry the
                # stamped copy's keys, passed first (the keys ARE the
                # noun); toggles append the new state, radio groups the
                # new 0-based index.
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
                # the ordinary widget/node path with the clip as its
                # payload — one record kind, path_len deciding, exactly
                # as a click on a stamped row is one record with a click
                # on a live widget. Never empty: a paste that delivered
                # nothing is not an occurrence.
                args.append(_representation(payload))
            elif payload is not None:
                args.append(payload)
            # One handler dispatch: an exception crosses the build
            # boundary (which rolled the mirrors back and dropped the
            # records), is logged, and the loop moves to the next
            # occurrence — the uniform dispatch discipline across every
            # binding. Non-Exception aborts (KeyboardInterrupt) still
            # propagate: the fatal floor.
            self._dispatch(handler, *args)

    def run(self):
        """Enter the core on the calling thread (must be the process
        main thread), dispatching occurrences on the app thread; returns
        the exit code."""
        app_thread = threading.Thread(target=self._dispatch_loop)
        app_thread.start()
        code = runtime.run()
        app_thread.join()
        return code
