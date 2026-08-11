"""Tier-1 negative and bookkeeping checks: the mirror-read guard trips
in recording positions, mirrors track writes, derived signals recompute
and batch, and removing a parent entry purges descendant instance
mirrors. Runs against the real bindings; the core is never entered
(records queue, the process exits)."""

import sys
from dataclasses import dataclass

import kaya

app = kaya.App()
failures = []


def check(name, ok):
    print(("PASS " if ok else "FAIL ") + name)
    if not ok:
        failures.append(name)


with app.window():
    s = kaya.signal(1)
    derived = s.eq(2)
    try:
        s.value()
        check("signals expose no read", False)
    except AttributeError:
        check("signals expose no read", True)

    c = kaya.collection()
    try:
        kaya.for_each(c.at("g1"))
        check("for_each rejects instance handles", False)
    except TypeError:
        check("for_each rejects instance handles", True)
    child = None
    with kaya.column():
        with kaya.for_each(c) as el:
            child = kaya.collection()
            try:
                len(c)
                check("guard trips in template", False)
            except RuntimeError:
                check("guard trips in template", True)
            kaya.label(bind=el)
        # When bodies arm the same guard (_tpl_depth covers both For
        # and When — the For-only openFors gap the other bindings had).
        cond = kaya.signal(True)
        with kaya.when(cond):
            try:
                c.items()
                check("guard trips in a When body", False)
            except RuntimeError:
                check("guard trips in a When body", True)
            kaya.label("empty")

with app.build():
    s.set(2)
    check("derived recomputes on source write", derived._mirror is True)
    s.set(3)
    check("derived recomputes again", derived._mirror is False)
    try:
        derived.set(True)
        check("derived rejects direct set", False)
    except RuntimeError:
        check("derived rejects direct set", True)

    c.insert("g1", "Work")
    child.at("g1").insert("a", "one")
    child.at("g1").insert("b", "two")
    check("collection mirror iterates", c.items() == [("g1", "Work")])
    check("child instance mirror", len(child.at("g1")) == 2)
    child.at("g1").remove("a")
    check("read-your-writes after remove", len(child.at("g1")) == 1)
    c.remove("g1")
    check("parent removal purges child mirror", len(child.at("g1")) == 0)

# Moves reorder the mirror the way the core reorders the table: by
# key, before an anchor or to the end; front/after are sugar over the
# same wire op; missing keys raise the scene's own checks at the call
# site, and order-preserving calls are no-ops.
with app.build():
    c.insert("g1", "Work")
    inst = child.at("g1")
    inst.insert("a", "one")
    inst.insert("b", "two")
    inst.insert("c", "three")
    inst.move_to_end("a")
    check("move_to_end reorders mirror", inst.keys() == ["b", "c", "a"])
    inst.move_before("a", "b")
    check("move_before reorders mirror", inst.keys() == ["a", "b", "c"])
    inst.move_to_front("c")
    check("move_to_front reorders mirror", inst.keys() == ["c", "a", "b"])
    inst.move_after("c", "a")
    check("move_after reorders mirror", inst.keys() == ["a", "c", "b"])
    inst.move_after("b", "b")
    inst.move_before("a", "a")
    inst.move_to_front("a")
    check("order-preserving moves are no-ops", inst.keys() == ["a", "c", "b"])
    try:
        inst.move_to_end("missing")
        check("move of missing key raises", False)
    except KeyError:
        check("move of missing key raises", True)
    try:
        inst.move_before("a", "missing")
        check("move before missing anchor raises", False)
    except KeyError:
        check("move before missing anchor raises", True)
try:
    with app.build():
        child.at("g1").move_before("b", "a")
        raise ValueError("handler failed")
except ValueError:
    pass
with app.build():
    check("abandoned tx rolls back move", child.at("g1").keys() == ["a", "c", "b"])
    c.remove("g1")

# Draft scopes: natural mutations record patches in order, resolve
# insert-vs-update from the model, and roll back with the transaction.
with app.build():
    c.insert("g1", "Work")
    with child.at("g1").change() as d:
        d["a"] = "one"          # insert
        d["a"] = "one, edited"  # update, resolved from the model
        d["b"] = "two"
        del d["b"]
    check("draft upsert resolved", child.at("g1").items() == [("a", "one, edited")])
try:
    with app.build():
        with child.at("g1").change() as d:
            d["z"] = "doomed"
        raise ValueError("handler failed")
except ValueError:
    pass
with app.build():
    check("draft rolls back with tx", "z" not in child.at("g1"))
    c.remove("g1")

# A handler that raises abandons its transaction; the mirrors must
# abandon the same writes.
try:
    with app.build():
        s.set(99)
        c.insert("g9", "doomed")
        raise ValueError("handler failed")
except ValueError:
    pass
with app.build():
    check("abandoned tx rolls back signal mirror", s._mirror == 3)
    check("abandoned tx rolls back collection mirror", "g9" not in c)
    check("derived mirror rolled back too", derived._mirror is False)

# The tracing tier (DESIGN's JAX-style sugar): the for statement
# traces to a For, comparisons are the derive vocabulary in operator
# clothes, and everything that cannot be traced fails loud at the
# exact wall JAX named (lax.cond: statement branching has no truth
# value at record time).
from dataclasses import dataclass


@dataclass
class TracedTodo:
    title: str
    done: bool


@dataclass
class TracedNote:
    text: str


app2 = kaya.App()
escaped = []
with app2.window():
    sig = kaya.signal(1)
    eq = sig == 1
    check("operator eq mints a derived signal",
          isinstance(eq, kaya.Signal) and eq._mirror is True)
    ge = sig >= 2
    check("operator ge mints a derived signal", ge._mirror is False)
    try:
        if sig:
            pass
        check("if-on-signal raises at the lax.cond wall", False)
    except RuntimeError:
        check("if-on-signal raises at the lax.cond wall", True)

    traced = kaya.collection(TracedTodo)
    bodies = 0
    with kaya.column():
        for el in traced:
            bodies += 1
            escaped.append(el)
            kaya.checkbox(checked=el.done)
            try:
                if el.done:
                    pass
                check("if-on-field raises at the wall", False)
            except RuntimeError:
                check("if-on-field raises at the wall", True)
    check("for-trace body runs exactly once", bodies == 1)

    feed = kaya.collection(TracedNote | TracedTodo)
    try:
        for _ in feed:
            pass
        check("sum for-trace raises at the lax.switch wall", False)
    except TypeError:
        check("sum for-trace raises at the lax.switch wall", True)

with app2.build():
    sig.set(2)
    check("operator-derived recomputes", eq._mirror is False and ge._mirror is True)
    try:
        for _ in traced:
            pass
        check("model iteration is items(), loudly", False)
    except TypeError:
        check("model iteration is items(), loudly", True)
    try:
        escaped[0].done
        check("escaped tracer raises", False)
    except RuntimeError:
        check("escaped tracer raises", True)

# One-shot commands: a Widget carries clear/focus, each queueing one
# wire record into the open transaction; a Node is a blueprint and has
# neither (the type-level arm of the scene's template rejection). An
# aborted build drops its command records with everything else —
# commands carry no mirror state, so rollback is the records dying.
app_cmd = kaya.App()
with app_cmd.window():
    with kaya.column():
        cmd_field = kaya.entry()
    before = len(kaya._tx)
    cmd_field.clear()
    cmd_field.focus()
    check("commands queue one record each", len(kaya._tx) == before + 2)
    check(
        "commands ride the tx as widget_command records",
        kaya._tx[-1][4:6] == kaya.wire.TX_WIDGET_COMMAND.to_bytes(2, "little"),
    )
check("a template node has no clear", not hasattr(kaya.Node(1), "clear"))
_submitted = []
_real_submit = kaya.runtime.submit
kaya.runtime.submit = lambda records: _submitted.append(len(records))
try:
    with app_cmd.build():
        cmd_field.clear()
        raise RuntimeError("handler bug")
except RuntimeError:
    pass
finally:
    kaya.runtime.submit = _real_submit
check("an aborted build ships no commands", not _submitted)

# The blob channel at the binding boundary: image() registers its
# bytes and queues create_widget + set_property(source, blob); a bytes
# dataclass field maps to VALUE_BLOB in the collection schema and
# re-registers at every encode (handles are single-submit); template
# binds of a blob field lower to SOURCE_ELEMENT. And the type walls
# hold — str is not image data, bytes are not label text.
@dataclass
class Avatar:
    name: str
    pic: bytes


def _rec_kind(rec):
    return int.from_bytes(rec[4:6], "little")


app_img = kaya.App()
with app_img.window():
    with kaya.column():
        before = len(kaya._tx)
        kaya.image(b"\x89PNG, not really")
        queued = kaya._tx[before:]
        check(
            "image queues a create_widget",
            any(_rec_kind(r) == kaya.wire.TX_CREATE_WIDGET for r in queued),
        )
        last = queued[-1]
        check(
            "image queues a set_source",
            _rec_kind(last) == kaya.wire.TX_SET_PROPERTY
            # body: u64 widget, u32 prop, u32 source kind, value {u32 type,...}
            and int.from_bytes(last[16:20], "little") == kaya.wire.PROP_SOURCE
            and int.from_bytes(last[20:24], "little") == kaya.wire.SOURCE_CONST
            and int.from_bytes(last[24:28], "little") == kaya.wire.VALUE_BLOB,
        )
        try:
            kaya.image("gallery.png")
            check("image rejects str with a clear TypeError", False)
        except TypeError:
            check("image rejects str with a clear TypeError", True)
        try:
            kaya.label(text=b"bytes are not text")
            check("label rejects bytes text", False)
        except TypeError:
            check("label rejects bytes text", True)

        avatars = kaya.collection(Avatar)
        check(
            "bytes field maps to blob in the schema",
            avatars._variants[0].schema
            == [kaya.wire.VALUE_STR, kaya.wire.VALUE_BLOB],
        )
        with kaya.for_each(avatars) as av:
            kaya.image(source=av.pic)
        set_prop = next(
            r for r in reversed(kaya._tx)
            if _rec_kind(r) == kaya.wire.TX_SET_PROPERTY
        )
        check(
            "template blob bind lowers to bind_source_element",
            int.from_bytes(set_prop[16:20], "little") == kaya.wire.PROP_SOURCE
            and int.from_bytes(set_prop[20:24], "little")
            == kaya.wire.SOURCE_ELEMENT,
        )

with app_img.build():
    before = len(kaya._tx)
    avatars.insert("a", Avatar("ann", b"\x01\x02\x03"))
    insert_rec = kaya._tx[-1]
    check(
        "blob-field insert registers and queues one insert",
        len(kaya._tx) == before + 1
        and _rec_kind(insert_rec) == kaya.wire.TX_COLLECTION_INSERT,
    )
    check(
        "blob field encodes as a fresh handle",
        isinstance(avatars._encode(Avatar("b", b"\x04"))[1][1],
                   kaya.wire.BlobHandle),
    )
    avatars.patch("a", pic=b"\x05\x06")  # re-registers at encode time
    check(
        "blob-field patch is an update_field",
        _rec_kind(kaya._tx[-1]) == kaya.wire.TX_COLLECTION_UPDATE_FIELD,
    )
    try:
        avatars.insert("b", Avatar("bob", "not bytes"))
        check("str into a blob field raises", False)
    except TypeError:
        check("str into a blob field raises", True)

# A break abandons the For template mid-trace; the transaction exit
# refuses to ship the half-authored blueprint.
app3 = kaya.App()
try:
    with app3.window():
        broken = kaya.collection(TracedTodo)
        with kaya.column():
            for el in broken:
                kaya.label(bind=el.title)
                break
    check("break inside a for-trace raises", False)
except RuntimeError:
    check("break inside a for-trace raises", True)

# A construction-time layout prop MUST reach the record stream — the
# Swift binding shipped a containerOf that accepted spacing= and
# silently dropped it, and no geometry gate could see it (render and
# observation share the node state a wire-dropped write never
# reaches). Every binding needs this check; Python's is the pattern
# (ledger: per-binding emission checks, the bindings program).
with app.build():
    if True:
        before = len(kaya._tx)
        with kaya.column(grow=2, spacing=12, align="center"):
            kaya.label(text="x", grow=1)
        queued = kaya._tx[before:]
        def _prop_write(prop, value_type):
            return any(
                _rec_kind(r) == kaya.wire.TX_SET_PROPERTY
                and int.from_bytes(r[16:20], "little") == prop
                and int.from_bytes(r[20:24], "little") == kaya.wire.SOURCE_CONST
                and int.from_bytes(r[24:28], "little") == value_type
                for r in queued
            )
        check(
            "column grow= reaches the records",
            _prop_write(kaya.wire.PROP_GROW, kaya.wire.VALUE_F64),
        )
        check(
            "column spacing= reaches the records",
            _prop_write(kaya.wire.PROP_SPACING, kaya.wire.VALUE_F64),
        )
        check(
            "column align= reaches the records",
            _prop_write(kaya.wire.PROP_ALIGN, kaya.wire.VALUE_I64),
        )

# The generated shortcut canonicalizer (the one binding-tier parser;
# DESIGN.md, Menus): spelling is canonicalized here, POLICY (escape,
# shift-only/bare alphanumerics, the reserved floor) dies at the core
# on the canonical form. The vectors mirror kaya-bindgen's reference
# table (tools/kaya-bindgen/src/main.rs) — the shared statement of the
# algorithm every emitter transcribes.
for spelling, want in (
    ("primary+s", "primary+s"),
    ("PRIMARY+S", "primary+s"),
    ("Shift+Primary+S", "primary+shift+s"),
    ("alt+shift+f5", "shift+alt+f5"),
    ("ALT+ENTER", "alt+enter"),
    ("enter", "enter"),
    # Recognized at the binding tier, rejected by the core (policy):
    ("Escape", "escape"),
    ("shift+s", "shift+s"),
    ("primary+q", "primary+q"),
):
    check(
        f"canonicalize_shortcut accepts {spelling!r}",
        kaya.wire.canonicalize_shortcut(spelling) == want,
    )
for bad in (
    "",
    "primary + s",
    "ctrl+s",
    "cmd+s",
    "option+p",
    "primary+primary+s",
    "primary+",
    "+s",
    "primary+s+k",
    "primary",
    "primary+esc",
    "primary+f13",
):
    try:
        kaya.wire.canonicalize_shortcut(bad)
        check(f"canonicalize_shortcut rejects {bad!r}", False)
    except ValueError:
        check(f"canonicalize_shortcut rejects {bad!r}", True)

# tx_set_menu_shortcut routes through the canonicalizer — no call site
# can bypass it: a case-variant spelling packs the canonical bytes,
# and a bad one raises before any record is framed.
check(
    "tx_set_menu_shortcut canonicalizes",
    kaya.wire.tx_set_menu_shortcut(7, "SHIFT+PRIMARY+S")
    == kaya.wire.tx_set_menu_shortcut(7, "primary+shift+s"),
)
try:
    kaya.wire.tx_set_menu_shortcut(7, "ctrl+s")
    check("tx_set_menu_shortcut rejects aliases", False)
except ValueError:
    check("tx_set_menu_shortcut rejects aliases", True)

# Menu construction must REACH the record stream (the dropped-spacing
# lesson: a surface check cannot see a constructor that emits
# nothing): one bar menu, its action with shortcut + bound enablement,
# and a live-widget context anchor, each asserted by record kind and
# prop tail.
with app.build():
    enable = kaya.signal(False)
    before = len(kaya._tx)
    with app.menu("File", enabled=enable):
        kaya.item("Save", shortcut="Primary+S")
    queued = kaya._tx[before:]

    def _menu_prop(prop, source):
        return any(
            _rec_kind(r) == kaya.wire.TX_SET_MENU_PROP
            and int.from_bytes(r[16:20], "little") == prop
            and int.from_bytes(r[20:24], "little") == source
            for r in queued
        )

    check(
        "menu construction creates both items",
        sum(_rec_kind(r) == kaya.wire.TX_MENU_ITEM_CREATE for r in queued) == 2,
    )
    check(
        "app.menu reaches the window catalog",
        any(_rec_kind(r) == kaya.wire.TX_MENUBAR_APPEND for r in queued),
    )
    check(
        "kaya.item seats under the open menu",
        any(_rec_kind(r) == kaya.wire.TX_MENU_ITEM_APPEND for r in queued),
    )
    check(
        "menu label= reaches the records",
        _menu_prop(kaya.wire.MPROP_LABEL, kaya.wire.SOURCE_CONST),
    )
    check(
        "menu enabled= binds the signal",
        _menu_prop(kaya.wire.MPROP_ENABLED, kaya.wire.SOURCE_SIGNAL),
    )
    check(
        "item shortcut= reaches the records canonicalized",
        any(
            _rec_kind(r) == kaya.wire.TX_SET_MENU_PROP
            and int.from_bytes(r[16:20], "little") == kaya.wire.MPROP_SHORTCUT
            and b"primary+s" in bytes(r)
            for r in queued
        ),
    )

    # The radio value's seat: value= must land AFTER the option
    # children it addresses — the root judges the index against the
    # option count at the record, so an eager emission dies with
    # "0 options" (caught live by the first menus-python leg; the
    # block-exit emission is the fix this check pins).
    before = len(kaya._tx)
    with app.radio_group("Sort", value=1):
        kaya.option("Name")
        kaya.option("Date")
    order = [
        _rec_kind(r)
        for r in kaya._tx[before:]
        if _rec_kind(r) in (kaya.wire.TX_MENU_ITEM_CREATE, kaya.wire.TX_SET_MENU_PROP)
        and not (
            _rec_kind(r) == kaya.wire.TX_SET_MENU_PROP
            and int.from_bytes(r[16:20], "little") != kaya.wire.MPROP_VALUE
        )
    ]
    check(
        "radio_group value= lands after its options",
        order[-1] == kaya.wire.TX_SET_MENU_PROP
        and order.count(kaya.wire.TX_MENU_ITEM_CREATE) == 3,
    )

    before = len(kaya._tx)
    with kaya.column():
        anchor = kaya.label("noun")
        with anchor.context_menu():
            kaya.item("Rename")
            try:
                kaya.item("Bad", shortcut="primary+r")
                check("context items reject shortcuts at record time", False)
            except ValueError:
                check("context items reject shortcuts at record time", True)
    check(
        "widget.context_menu attaches to the anchor",
        any(_rec_kind(r) == kaya.wire.TX_CONTEXT_ATTACH for r in kaya._tx[before:]),
    )

    with kaya.context_catalog() as catalog:
        kaya.item("Remove")
    with kaya.column():
        coll = kaya.collection()
        with kaya.for_each(coll):
            try:
                kaya.item("Late")
                check("menu items are live-zone only", False)
            except RuntimeError:
                check("menu items are live-zone only", True)
            before = len(kaya._tx)
            row = kaya.label("row")
            row.context_menu(catalog)
            check(
                "node.context_menu attaches the catalog",
                any(
                    _rec_kind(r) == kaya.wire.TX_CONTEXT_ATTACH_NODE
                    for r in kaya._tx[before:]
                ),
            )
    try:
        row.context_menu(catalog)
        check("a context catalog takes exactly one anchor", False)
    except RuntimeError:
        check("a context catalog takes exactly one anchor", True)

# The rest of the menu guard layer (menus-plan §6): the
# append-at-any-time reopen, handler scoping direct vs stamped, and
# the abort dropping an appended subtree with its records. A fresh App
# keeps the module-global _app (the handler tables, the menu-item
# counter) pointed at what these blocks assert.
app_menu = kaya.App()

# Append-at-any-time: a retained grouping handle reopens in a LATER
# transaction; the reopen queues exactly the child's create + its
# append under the RETAINED parent — and never re-anchors the bar.
with app_menu.build():
    with app_menu.menu("File") as file_menu:
        kaya.item("Save", shortcut="primary+s")
with app_menu.build():
    before = len(kaya._tx)
    with file_menu.append():
        publish = kaya.item("Publish")
    queued = kaya._tx[before:]
    check(
        "reopen creates exactly the appended child",
        sum(_rec_kind(r) == kaya.wire.TX_MENU_ITEM_CREATE for r in queued) == 1,
    )
    appends = [r for r in queued if _rec_kind(r) == kaya.wire.TX_MENU_ITEM_APPEND]
    check(
        "reopen seats under the retained parent",
        len(appends) == 1
        and int.from_bytes(appends[0][8:16], "little") == file_menu.id
        and int.from_bytes(appends[0][16:24], "little") == publish.id,
    )
    check(
        "reopen does not re-anchor the bar",
        all(_rec_kind(r) != kaya.wire.TX_MENUBAR_APPEND for r in queued),
    )

# Handler scoping, direct vs stamped: on_activate rides the item into
# the MENU table (its own id space — never the widget or node tables),
# and dispatch passes a bar item's activation bare while a stamped
# context copy's activation carries the copy's keys FIRST (the keys
# ARE the noun); a toggle's payload lands after the keys.
hits = []
with app_menu.build():
    with app_menu.menu("Edit"):
        direct = kaya.item(
            "Rename", on_activate=lambda: hits.append(("direct",)))
        tog = kaya.toggle(
            "Details", on_toggle=lambda on: hits.append(("toggle", on)))
    with kaya.context_catalog():
        stamped = kaya.item(
            "Remove",
            on_activate=lambda group, key: hits.append(("stamped", group, key)))
check(
    "on_activate registers in the menu-item table only",
    (kaya.wire.OCC_MENU_ACTIVATED, direct.id) in app_menu._menu_handlers
    and (kaya.wire.OCC_MENU_ACTIVATED, direct.id) not in app_menu._widget_handlers
    and (kaya.wire.OCC_MENU_ACTIVATED, direct.id) not in app_menu._node_handlers,
)
_occs = [
    (kaya.wire.OCC_MENU_ACTIVATED, direct.id, [], None),
    (kaya.wire.OCC_MENU_ACTIVATED, stamped.id, ["g2", "a"], None),
    (kaya.wire.OCC_MENU_TOGGLED, tog.id, [], True),
]
_real_next = kaya.runtime.next_occurrence
kaya.runtime.next_occurrence = lambda: _occs.pop(0) if _occs else None
try:
    app_menu._dispatch_loop()
finally:
    kaya.runtime.next_occurrence = _real_next
check("direct activation dispatches bare", ("direct",) in hits)
check("stamped activation carries the keys first", ("stamped", "g2", "a") in hits)
check("toggle payload lands after the keys", ("toggle", True) in hits)

# Abort rollback of an aborted append: the reopened subtree's records
# die with the transaction (nothing ships), and the abort disarms any
# open menu scope — the next transaction must not inherit a seat.
_shipped = []
_real_submit2 = kaya.runtime.submit
kaya.runtime.submit = lambda *records: _shipped.append(len(records))
try:
    with app_menu.build():
        with file_menu.append():
            kaya.item("Doomed")
        raise RuntimeError("handler bug")
except RuntimeError:
    pass
finally:
    kaya.runtime.submit = _real_submit2
check("an aborted append ships nothing", not _shipped)
try:
    with app_menu.build():
        with app_menu.menu("Poisoned"):
            kaya.item("X")
            raise RuntimeError("handler bug")
except RuntimeError:
    pass
check("an abort inside a menu scope leaves none armed", not kaya._menu_scopes)
with app_menu.build():
    try:
        kaya.item("Orphan")
        check("post-abort item outside any scope raises", False)
    except RuntimeError:
        check("post-abort item outside any scope raises", True)

# ---- undo: naming a step, and the step that comes back --------------
#
# The ambient tier names its transaction from INSIDE, because a handler
# does not open one (App._dispatch does). These pin the three rules that
# spelling has to keep — head of batch, one name per step, and a name —
# plus what an `undone` occurrence does to the mirrors before any
# handler sees it (docs/undo-plan.md D2, D5).


@dataclass
class _Todo:
    title: str


app_undo = kaya.App()
_undo_shipped = []
_real_submit3 = kaya.runtime.submit
kaya.runtime.submit = lambda *records: _undo_shipped.append(records)
try:
    # THE MARKER LEADS THE BATCH wherever the call sits in the body: a
    # handler naturally builds first and knows what the step was
    # afterwards, and the core refuses a group whose marker is not at
    # index 0 — so the surface must not make that an ordering trap.
    with app_undo.build():
        undo_sig = kaya.signal("before")
        undo_sig.set("after")
        kaya.undoable("step")
    check(
        "undoable inserts the group marker at the head",
        bool(_undo_shipped) and len(_undo_shipped[0]) == 3
        and _undo_shipped[0][0][4:6] == kaya.wire.TX_UNDO_GROUP.to_bytes(
            2, "little"),
    )
    with app_undo.build():
        kaya.undoable("first")
        try:
            kaya.undoable("second")
            check("one name per step", False)
        except RuntimeError:
            check("one name per step", True)
    with app_undo.build():
        try:
            # The EMPTY label is taken: it is how a typing episode
            # identifies itself on the same occurrence.
            kaya.undoable("")
            check("a group must be named", False)
        except ValueError:
            check("a group must be named", True)

    undo_seen = []

    def _undo_note(what, label, delta):
        # READ THE MODEL FROM INSIDE THE HANDLER: what the mirror holds
        # while the app is looking is the claim, not what it holds after
        # a later step has moved it again.
        undo_seen.append((what, label, list(delta.texts), len(undo_todos),
                          undo_todos.get("t1"), undo_todos.keys()))

    with app_undo.window(
        on_undone=lambda label, delta: _undo_note("undone", label, delta),
        on_redone=lambda label, delta: _undo_note("redone", label, delta),
    ):
        undo_todos = kaya.collection(_Todo)
        with kaya.column():
            kaya.label("todos")
    with app_undo.build():
        undo_todos.insert("t1", _Todo("milk"))
        undo_todos.insert("t2", _Todo("tea"))
        undo_todos.insert("t3", _Todo("jam"))
finally:
    kaya.runtime.submit = _real_submit3
try:
    kaya.undoable("no transaction")
    check("undoable needs an ambient transaction", False)
except RuntimeError:
    check("undoable needs an ambient transaction", True)

# Five steps come back: the entry goes; it comes back (at the end, the
# way a re-inserted key lands); a delta that names nothing still reaches
# the handler; an orders run restates the whole instance order; and the
# last one lands on a window with NO handler at all.
_undo_occs = [
    (kaya.wire.OCC_UNDONE, 0, [],
     ("add milk", [(undo_sig.id, "before")], [(7, "milk")],
      [(undo_todos._id, (), "t1", None)], [])),
    (kaya.wire.OCC_REDONE, 0, [],
     ("add milk", [], [], [(undo_todos._id, (), "t1", (0, ["milk"]))], [])),
    (kaya.wire.OCC_UNDONE, 0, [], ("star", [], [], [], [])),
    # AN ORDER NOTHING ELSE PRODUCES: not the seed's and not the one the
    # re-insert above leaves, so a run that never applied cannot pass
    # this by looking like the state already there.
    (kaya.wire.OCC_UNDONE, 0, [],
     ("sort", [], [], [], [(undo_todos._id, (), ["t3", "t1", "t2"])])),
    (kaya.wire.OCC_UNDONE, 9, [],
     ("add milk", [], [], [(undo_todos._id, (), "t1", None)], [])),
]
_real_next2 = kaya.runtime.next_occurrence
_real_submit4 = kaya.runtime.submit
kaya.runtime.next_occurrence = lambda: _undo_occs.pop(0) if _undo_occs else None
kaya.runtime.submit = lambda *records: None
try:
    app_undo._dispatch_loop()
finally:
    kaya.runtime.next_occurrence = _real_next2
    kaya.runtime.submit = _real_submit4
check(
    "an undone delta reconciles the model mirror before the handler",
    undo_seen[:1] == [("undone", "add milk", [(7, "milk")], 2, None,
                       ["t2", "t3"])],
)
check(
    "a redone delta puts the entry back, rebuilt from the wire record",
    undo_seen[1:2] == [("redone", "add milk", [], 3, _Todo("milk"),
                        ["t2", "t3", "t1"])],
)
check(
    "the history handlers stay registered — a history is walked twice",
    len(undo_seen) == 4 and undo_seen[2][:2] == ("undone", "star"),
)
check(
    "an orders run restates the instance's whole key order",
    undo_seen[3][5] == ["t3", "t1", "t2"],
)
# A signal has no read-back, but the binding caches what it last wrote to
# skip no-op DERIVED writes — and an undo moves signals behind that
# cache. The payload is what puts it right.
check(
    "the signal cache follows the restored value",
    undo_sig._mirror == "before",
)
check(
    "the mirrors follow an undo nobody registered a handler for",
    len(undo_todos) == 2,
)

# ---- the window construct: one attribute set, two spellings ---------
#
# A window attribute rides the window construct and lives nowhere else
# (DESIGN.md, Binding conventions — `window_title` retired 2026-07-22),
# so Python's construct has to serve the LIVE case too. Every other
# binding hangs it off the transaction and gets that for free; Python's
# hangs off the App because it doubles as the scene scope, so the same
# call means two things and `_tx` is what decides.
#
# THIS IS A SILENT FAILURE CLASS AND THAT IS WHY IT IS CHECKED HERE.
# Watched 2026-08-06 with the live branch deleted: `app.window(dirty=
# True)` inside a handler emitted nothing, raised nothing, printed
# nothing, and the mac leg failed three `expect_dirty true` steps while
# every label assertion passed. The dirty scene catches it today; these
# checks catch it without a scene.
app_win = kaya.App()
_win_shipped = []
_real_submit5 = kaya.runtime.submit
kaya.runtime.submit = lambda *records: _win_shipped.append(list(records))
try:
    with app_win.window(title="w", dirty=True):
        with kaya.column():
            kaya.label("x")
    check(
        "the window construct carries dirty at build",
        bool(_win_shipped)
        and kaya.wire.tx_set_window_dirty(0, True) in _win_shipped[0],
    )
    # THE LIVE SPELLING SHIPS THE SAME RECORD, byte for byte, which is
    # what keeps the two spellings from drifting apart: one prop
    # emitter, reached two ways.
    with app_win.build():
        app_win.window(dirty=False)
    check(
        "the live window construct ships the same record",
        _win_shipped[1:2] == [[kaya.wire.tx_set_window_dirty(0, False)]],
    )
    # An auxiliary surface is NAMED, not assumed. Without this the live
    # form could only ever mean window 0, and a mark raised on a panel
    # would land on the primary instead — the trailing-id spelling C#
    # and OCaml already carry.
    with app_win.build():
        app_win.window(dirty=True, window_id=7)
    check(
        "the live window construct names its surface",
        _win_shipped[2:3] == [[kaya.wire.tx_set_window_dirty(7, True)]],
    )
    # And the `with` form inside an open transaction is refused IN ITS
    # OWN WORDS. "transactions do not nest" is true here and unhelpful:
    # the answer is not to move the transaction, it is that the live
    # form takes no `with` at all.
    with app_win.build():
        try:
            with app_win.window(dirty=True):
                pass
            check("the live window construct refuses a `with`", False)
        except RuntimeError as exc:
            check(
                "the live window construct refuses a `with`",
                "PLAIN CALL" in str(exc),
            )
finally:
    kaya.runtime.submit = _real_submit5

# EVERY ELEMENT-SOURCE ARM LOWERS TO SOURCE_ELEMENT, decoded from the
# bytes rather than asked about.
#
# THE DEFECT THIS EXISTS FOR (docs/sugar-pass-plan.md D3): `progress`
# spelled the FieldRef accessors `value._level, value._field` where the
# type has `._level()` and `._index` — one callsite out of five, wrong
# in both halves. So `kaya.progress(value=row.pct)` inside a for_each
# raised AttributeError, and had it got past that it would have packed a
# bound method into struct.pack. It shipped for months because no guest
# binds a progress bar to a row, and because every check kaya had asked
# whether the CONSTRUCTOR EXISTS. It does. It always did.
#
# So this check decodes the queued record and insists on the prop, the
# source kind, the level and the FIELD INDEX. A constructor that takes
# the argument and drops it, or binds the wrong field, fails here — the
# arm has to be reachable, not merely declared.
@dataclass
class Row3:
    title: str
    done: bool
    pct: float
    pic: bytes


@dataclass
class Note3:
    text: str


@dataclass
class Shot3:
    pic: bytes


def _rewind(before):
    """Drop whatever the call under test queued. A constructor emits its
    create_widget before it reaches the argument that raises, so without
    this the next clause reads the abandoned node's records as its own."""
    del kaya._tx[before:]


def _elem_bind(fn):
    """Queue one element-bound constructor; decode what reached the wire,
    or None if no element bind did.

    A RAISING ARM IS A FINDING, NOT A CRASH. The defect above raised
    rather than mis-encoding, and an uncaught AttributeError here would
    end the run at the first bad arm — no verdict on the four beside it,
    and a reader reading a traceback instead of a name. So the exception
    is caught, printed, and answered as a failed clause."""
    before = len(kaya._tx)
    try:
        fn()
    except Exception as exc:
        print(f"       (raised {type(exc).__name__}: {exc})")
        _rewind(before)
        return None
    for rec in kaya._tx[before:]:
        if _rec_kind(rec) != kaya.wire.TX_SET_PROPERTY:
            continue
        src = int.from_bytes(rec[20:24], "little")
        if src != kaya.wire.SOURCE_ELEMENT:
            continue
        return {
            "prop": int.from_bytes(rec[16:20], "little"),
            "level": int.from_bytes(rec[24:28], "little"),
            "field": int.from_bytes(rec[28:32], "little"),
        }
    return None


def _never_const_from_a_tracer(fn, prop):
    """True when handing a tracer to `prop` either raised or bound the
    element — anything but a CONSTANT.

    This is the sentence that survives the open question. Whether an
    argument grows an element arm is undecided (the source-width table
    in the survey: `slider(min=)`, `select(selected=)`, `grow=` and the
    rest are const-only today, and widening them sweeps eight bindings).
    What is decided is that a per-row source must never quietly become
    one value for every row: `progress(indeterminate=el)` wrote a
    constant True and said nothing, because an object with no
    `__bool__` is true, until the element grew the truth-value wall its
    fields already had."""
    before = len(kaya._tx)
    try:
        fn()
    except Exception:
        _rewind(before)
        return True
    queued = kaya._tx[before:]
    _rewind(before)
    return not any(
        _rec_kind(r) == kaya.wire.TX_SET_PROPERTY
        and int.from_bytes(r[16:20], "little") == prop
        and int.from_bytes(r[20:24], "little") == kaya.wire.SOURCE_CONST
        for r in queued
    )


app_src = kaya.App()
with app_src.window():
    rows3 = kaya.collection(Row3)
    groups3 = kaya.collection(Row3)
    feed3 = kaya.collection(Note3 | Shot3)
    with kaya.for_each(rows3) as el:
        for what, fn, prop, index in (
            ("label", lambda: kaya.label(bind=el.title), kaya.wire.PROP_TEXT, 0),
            ("checkbox", lambda: kaya.checkbox(checked=el.done),
             kaya.wire.PROP_CHECKED, 1),
            ("slider", lambda: kaya.slider(value=el.pct), kaya.wire.PROP_VALUE, 2),
            ("progress", lambda: kaya.progress(value=el.pct),
             kaya.wire.PROP_VALUE, 2),
            ("image", lambda: kaya.image(source=el.pic), kaya.wire.PROP_SOURCE, 3),
        ):
            got = _elem_bind(fn)
            check(
                f"{what} binds the row's own field, and binds the right one",
                got == {"prop": prop, "level": 0, "field": index},
            )

        # The const-only arms, handed the same tracer. Each of these
        # coerces — float(), int(), bool(), the UTF-8 wall — and a
        # coercion that SUCCEEDS is the silent failure this file exists
        # for. None of them may write a constant from a tracer.
        for what, fn, prop in (
            ("entry text", lambda: kaya.entry(text=el.title),
             kaya.wire.PROP_TEXT),
            ("button text", lambda: kaya.button(text=el.title),
             kaya.wire.PROP_TEXT),
            ("textarea text", lambda: kaya.textarea(text=el.title),
             kaya.wire.PROP_TEXT),
            ("checkbox text", lambda: kaya.checkbox(text=el.title),
             kaya.wire.PROP_TEXT),
            ("select index", lambda: kaya.select(["a", "b"], selected=el.pct),
             kaya.wire.PROP_VALUE),
            ("radio index", lambda: kaya.radio(["a", "b"], selected=el.pct),
             kaya.wire.PROP_VALUE),
            ("slider min", lambda: kaya.slider(min=el.pct), kaya.wire.PROP_MIN),
            ("slider max", lambda: kaya.slider(max=el.pct), kaya.wire.PROP_MAX),
            ("progress indeterminate",
             lambda: kaya.progress(indeterminate=el.done),
             kaya.wire.PROP_INDETERMINATE),
            ("progress indeterminate, the bare element",
             lambda: kaya.progress(indeterminate=el),
             kaya.wire.PROP_INDETERMINATE),
            ("grid columns", lambda: kaya.grid(el.pct), kaya.wire.PROP_COLUMNS),
            ("grow", lambda: kaya.label("x", grow=el.pct), kaya.wire.PROP_GROW),
            ("spacing", lambda: kaya.column(spacing=el.pct),
             kaya.wire.PROP_SPACING),
            ("align", lambda: kaya.column(align=el.pct), kaya.wire.PROP_ALIGN),
        ):
            check(
                f"{what} never writes a constant from a tracer",
                _never_const_from_a_tracer(fn, prop),
            )

    # THE LEVEL IS COMPUTED, NOT ASSUMED, and every clause above would
    # pass with it hard-coded to 0 — which is the other half of the
    # defect, since `value._level` (the bound method, unparenthesized)
    # is exactly what a struct.pack of a hard-coded shape would have
    # hidden. `FieldRef._level()` counts the open Fors, so the OUTER
    # element read from inside an inner For is one level up.
    with kaya.for_each(groups3) as group3:
        with kaya.for_each(rows3) as item3:
            check(
                "a field of the enclosing For's element binds one level up",
                _elem_bind(lambda: kaya.checkbox(checked=group3.done))
                == {"prop": kaya.wire.PROP_CHECKED, "level": 1, "field": 1},
            )
            check(
                "and the innermost element stays at level 0",
                _elem_bind(lambda: kaya.checkbox(checked=item3.done))
                == {"prop": kaya.wire.PROP_CHECKED, "level": 0, "field": 1},
            )

    # `bind=` is the one source argument Python cannot type, and it had
    # no floor: a value that was not a Signal, an Element or a FieldRef
    # fell out of the ladder and bound NOTHING. The reachable spelling
    # is a sum's case arm, whose refined proxy is not an `Element` — so
    # `kaya.label(bind=note)` declared a blank label and said nothing,
    # which is the failure class the seven typed bindings get from their
    # compilers.
    with kaya.for_each(feed3) as cases3:
        with cases3.case(Note3) as note3:
            check(
                "a case arm's field binds like any other element field",
                _elem_bind(lambda: kaya.label(bind=note3.text))
                == {"prop": kaya.wire.PROP_TEXT, "level": 0, "field": 0},
            )
            try:
                kaya.label(bind=note3)
                check("label(bind=) refuses a source it cannot bind", False)
            except TypeError as exc:
                # The message NAMES WHAT IT GOT: a reader who wrote
                # `bind=note` has to be told that the case element is not
                # the thing to bind, not merely that something was wrong.
                check(
                    "label(bind=) refuses a source it cannot bind",
                    type(note3).__name__ in str(exc),
                )
        with cases3.case(Shot3) as shot3:
            check(
                "a case arm's blob field binds too",
                _elem_bind(lambda: kaya.image(source=shot3.pic))
                == {"prop": kaya.wire.PROP_SOURCE, "level": 0, "field": 0},
            )

# TEMPLATE-NODE PROPS (docs/tpl-props-plan.md §1). The a11y trio,
# `accepts` and `on_paste` sit on the `_Handle` base both handle classes
# share, so the same call names a live widget and a stamped copy — which
# is the whole of what this binding had to build, the wire encoders and
# the core's template declare arm having admitted these all along.
#
# WHAT MAKES IT WORTH CHECKING RATHER THAN READING: the surface is
# `hasattr`-shaped, so a reader cannot tell a method that reaches the
# wire from one that reaches the wrong id or the wrong source. Each
# clause below decodes the queued record instead — and the paste clause
# reads the TABLE the handler landed in, because a paste handler filed
# under a widget id is one that never fires for a row.


def _const_str_prop(fn, prop):
    """The string a const prop write put on the wire, or None if that
    prop reached it any other way (or not at all)."""
    before = len(kaya._tx)
    try:
        fn()
    except Exception as exc:
        print(f"       (raised {type(exc).__name__}: {exc})")
        _rewind(before)
        return None
    queued = kaya._tx[before:]
    _rewind(before)
    for rec in queued:
        if _rec_kind(rec) != kaya.wire.TX_SET_PROPERTY:
            continue
        if int.from_bytes(rec[16:20], "little") != prop:
            continue
        if int.from_bytes(rec[20:24], "little") != kaya.wire.SOURCE_CONST:
            return None
        if int.from_bytes(rec[24:28], "little") != kaya.wire.VALUE_STR:
            return None
        n = int.from_bytes(rec[28:32], "little")
        return rec[32:32 + n].decode()
    return None


def _signal_prop(fn, prop):
    """The signal id a signal-bound prop write named, or None.

    Catches for `_elem_bind`'s reason: a missing method raises, and an
    uncaught AttributeError would end the run at the first bad arm — no
    verdict on the clauses beside it, and a reader reading a traceback
    instead of a name."""
    before = len(kaya._tx)
    try:
        fn()
    except Exception as exc:
        print(f"       (raised {type(exc).__name__}: {exc})")
        _rewind(before)
        return None
    queued = kaya._tx[before:]
    _rewind(before)
    for rec in queued:
        if _rec_kind(rec) != kaya.wire.TX_SET_PROPERTY:
            continue
        if int.from_bytes(rec[16:20], "little") != prop:
            continue
        if int.from_bytes(rec[20:24], "little") != kaya.wire.SOURCE_SIGNAL:
            return None
        return int.from_bytes(rec[24:32], "little")
    return None


app_tpl = kaya.App()
with app_tpl.window():
    rows5 = kaya.collection(Row3)
    feed5 = kaya.collection(Note3 | Shot3)
    name5 = kaya.signal("Row")
    live5 = kaya.entry()
    check(
        "the live zone still writes a constant a11y id",
        _const_str_prop(lambda: live5.a11y_id("search"), kaya.wire.PROP_A11Y_ID)
        == "search",
    )
    # AND A LIVE SIGNAL SOURCE BINDS RATHER THAN COERCING, which is the
    # one place this binding now reaches further than the other seven
    # (their live a11y setters take a string). Not an accident and not
    # free: the alternative to a total `_prop_source` is the coercion it
    # replaced, which wrote a Signal's repr onto the widget and said
    # nothing. Pinned here so the choice is visible to whoever narrows
    # or widens it.
    live_sig5 = kaya.signal("Search")
    check(
        "a live a11y label follows a Signal instead of coercing it",
        _signal_prop(lambda: live5.a11y_label(live_sig5),
                     kaya.wire.PROP_A11Y_LABEL) == live_sig5.id,
    )
    with kaya.column():
        with kaya.for_each(rows5) as row5:
            check(
                "a constructor inside a For hands back a Node",
                isinstance(kaya.entry(), kaya.Node),
            )
            # THE ROW'S OWN FIELD IS THE POINT: fourteen copies of one
            # node share one node id, so a constant label makes fourteen
            # checkboxes that all announce the same thing.
            for what, fn, prop, index in (
                ("a11y_label", lambda: kaya.entry().a11y_label(row5.title),
                 kaya.wire.PROP_A11Y_LABEL, 0),
                ("a11y_id", lambda: kaya.entry().a11y_id(row5.title),
                 kaya.wire.PROP_A11Y_ID, 0),
                ("a11y_hint", lambda: kaya.checkbox().a11y_hint(row5.title),
                 kaya.wire.PROP_A11Y_HINT, 0),
            ):
                check(
                    f"a template node's {what} binds the row's own field",
                    _elem_bind(fn) == {"prop": prop, "level": 0, "field": index},
                )
            check(
                "and a Signal source reaches the wire as a signal bind",
                _signal_prop(lambda: kaya.entry().a11y_label(name5),
                             kaya.wire.PROP_A11Y_LABEL) == name5.id,
            )
            check(
                "and a plain string is still a constant",
                _const_str_prop(lambda: kaya.entry().a11y_id("note"),
                                kaya.wire.PROP_A11Y_ID) == "note",
            )
            # THE CONST ARM COERCES, which is why the source arms come
            # first in `_prop_source`: `str(row.title)` succeeds, writes
            # "<kaya.FieldRef object at 0x...>" onto every copy, and a
            # screen reader reads it out. Same wall as the constructors'
            # const-only arguments above.
            for what, fn, prop in (
                ("a11y_id", lambda: kaya.entry().a11y_id(row5),
                 kaya.wire.PROP_A11Y_ID),
                ("a11y_label", lambda: kaya.entry().a11y_label(row5),
                 kaya.wire.PROP_A11Y_LABEL),
                ("a11y_hint", lambda: kaya.checkbox().a11y_hint(row5),
                 kaya.wire.PROP_A11Y_HINT),
            ):
                check(
                    f"{what} never writes a constant from a tracer",
                    _never_const_from_a_tracer(fn, prop),
                )

            # ACCEPTS IS CONST-ONLY AND SAYS SO. An accept list describes
            # the prototype — what this control can receive — not the
            # row; the wire could carry a per-row one, and the platform
            # registration it drives (Android's receive-content mime set)
            # makes that unassertable by any scene.
            check(
                "a template node's accepts joins the kinds it was handed",
                _const_str_prop(
                    lambda: kaya.entry().accepts(kaya.ACCEPT_TEXT,
                                                 kaya.ACCEPT_FILES),
                    kaya.wire.PROP_ACCEPTS) == "text files",
            )
            for what, source in (("a field", row5.title), ("the element", row5),
                                 ("a Signal", name5)):
                before_acc = len(kaya._tx)
                try:
                    kaya.entry().accepts(source)
                    ok = False
                except Exception as exc:
                    # A TypeError NAMING WHAT IT GOT, like label(bind=)'s
                    # floor arm — and the exception TYPE is half the
                    # clause, because without the refusal these coerce
                    # into `_accept_list`, whose ValueError quotes the
                    # repr and so happens to contain the type's name
                    # too. A true sentence about the wrong problem: it
                    # blames a space in a format id.
                    ok = (isinstance(exc, TypeError)
                          and type(source).__name__ in str(exc))
                _rewind(before_acc)
                check(f"accepts refuses {what} as a per-row source", ok)

            # THE PASTE REGISTRAR. Python needed no dispatch arm — the
            # loop branches on whether the record carried a key path, not
            # on the occurrence kind — but nothing public could put an
            # entry in the node table until `on_paste` moved to the base.
            node5 = kaya.entry()
            try:
                node5.accepts(kaya.ACCEPT_TEXT).on_paste(lambda key, clip: None)
            except Exception as exc:  # a finding, not a crash (_elem_bind)
                print(f"       (raised {type(exc).__name__}: {exc})")
            check(
                "a template node's paste handler lands in the node table",
                (kaya.wire.OCC_PASTED, node5.id) in app_tpl._node_handlers,
            )
            check(
                "and not in the widget table",
                (kaya.wire.OCC_PASTED, node5.id) not in app_tpl._widget_handlers,
            )

        with kaya.for_each(feed5) as cases5:
            with cases5.case(Note3) as note5:
                check(
                    "a case arm's field reaches a template prop",
                    _elem_bind(lambda: kaya.entry().a11y_label(note5.text))
                    == {"prop": kaya.wire.PROP_A11Y_LABEL, "level": 0,
                        "field": 0},
                )
                before5 = len(kaya._tx)
                try:
                    kaya.entry().a11y_label(note5)
                    check("a11y_label refuses the case element itself", False)
                except TypeError as exc:
                    check(
                        "a11y_label refuses the case element itself",
                        type(note5).__name__ in str(exc),
                    )
                _rewind(before5)

sys.exit(1 if failures else 0)

