"""Tier-1 negative and bookkeeping checks: the mirror-read guard trips
in recording positions, mirrors track writes, derived signals recompute
and batch, and removing a parent entry purges descendant instance
mirrors. Runs against the real bindings; the core is never entered
(records queue, the process exits)."""

import struct
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
        with kaya.column(grow=2, spacing=12, align="center", inset=6):
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
        # And as the F64 the prop is typed as, out of the int written
        # here: an inset arriving as an I64 is refused by the root for
        # its TYPE, which is a true complaint about the wrong mistake
        # (the window inset's lesson, one level down).
        check(
            "column inset= reaches the records",
            _prop_write(kaya.wire.PROP_INSET, kaya.wire.VALUE_F64)
            and not _prop_write(kaya.wire.PROP_INSET, kaya.wire.VALUE_I64),
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
            # The per-row CAPTION. Python was the one binding that could
            # not spell it at all — `text=` runs the UTF-8 wall, which
            # raises on a FieldRef, and there is no widget-level bind to
            # fall to — while five bindings had it as sugar and two at
            # their zone's floor (docs/deferred.md, "the template
            # button's caption is not uniform").
            ("button", lambda: kaya.button(bind=el.title), kaya.wire.PROP_TEXT, 0),
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
            ("inset", lambda: kaya.column(inset=el.pct), kaya.wire.PROP_INSET),
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

    # AND THE ZONE WALL UNDER `button(bind=)`. A bound caption is a
    # TEMPLATE-zone constructor in all eight and exists in no live zone
    # (docs/tpl-props-plan.md F5, re-verified 2026-08-17). The other
    # seven refuse it live by having no such overload; Python's ambient
    # transaction gives one function to both zones, so the refusal is a
    # zone check and this is the only place it can be watched.
    sig_live = kaya.signal("live")
    before_live = len(kaya._tx)
    try:
        kaya.button(bind=sig_live)
        check("button(bind=) refuses a LIVE-zone caption source", False)
    except TypeError as exc:
        check(
            "button(bind=) refuses a LIVE-zone caption source",
            "template-only" in str(exc),
        )
    _rewind(before_live)

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


def _const_num_prop(fn, prop, value_type):
    """(target id, value) for one constant NUMERIC prop write, or None if
    that prop reached the wire any other way.

    The two above answer a string and a signal id; the styling props are
    numbers, and the TARGET is half of what they have to answer — a role
    or an inset that reached the wire naming a live widget id styles
    nothing a For will ever stamp, and raises nowhere."""
    before = len(kaya._tx)
    try:
        fn()
    except Exception as exc:  # a finding, not a crash (_elem_bind)
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
        if int.from_bytes(rec[24:28], "little") != value_type:
            return None
        body = rec[32:32 + int.from_bytes(rec[28:32], "little")]
        value = (int.from_bytes(body, "little")
                 if value_type == kaya.wire.VALUE_I64
                 else struct.unpack("<d", body)[0])
        return int.from_bytes(rec[8:16], "little"), value
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

            # THE STYLING PROPS IN THE TEMPLATE ZONE: a stamped copy can
            # say what it MEANS (`role`) and how far its prototype holds
            # its children off its edge (`inset`). Python spelled both
            # before the slice asked for them — and by two DIFFERENT
            # lines, which is why they are checked apart rather than as
            # one "the props are there":
            #
            #   role  — `_Handle.role`, the base `Widget` and `Node`
            #           share, exactly as the a11y trio above.
            #   inset — the `inset=` argument every container constructor
            #           already takes, written onto whatever
            #           `_alloc_widget_or_node` handed back. Inside a For
            #           that is a Node, so the KWARG IS THIS ZONE'S
            #           SPELLING, and `Widget.inset` (the dynamic setter)
            #           stays live-only on purpose: a blueprint is
            #           declared, never mutated.
            #
            # BOTH CLAUSES READ THE TARGET ID, which is the half no
            # `hasattr` reader can reach. A prop that reaches the wire
            # naming a WIDGET id styles something no For will ever stamp
            # — the copies keep the prototype's default and nothing
            # anywhere raises, which is the `spacing=` failure shape one
            # zone over.
            head5 = kaya.label(bind=row5.title)
            check(
                "a template node's role reaches the wire, on the NODE's id",
                _const_num_prop(lambda: head5.role(kaya.Role.HEADING),
                                kaya.wire.PROP_ROLE, kaya.wire.VALUE_I64)
                == (head5.id, kaya.wire.ROLE_HEADING),
            )
            check(
                "and the string spelling is the same prop here too",
                _const_num_prop(lambda: head5.role("destructive"),
                                kaya.wire.PROP_ROLE, kaya.wire.VALUE_I64)
                == (head5.id, kaya.wire.ROLE_DESTRUCTIVE),
            )
            # CONST-ONLY, and for `accepts`'s reason rather than for a
            # missing wire encoder — `tx_bind_role_element` is generated
            # and sitting right there. What a copy MEANS is a fact about
            # the prototype, so no binding offers a per-row role, and the
            # refusal has to NAME what it got: without it `_role_value`'s
            # int arm is reached by anything with an `__index__` and the
            # row's number becomes a role nobody wrote.
            for what, source in (("a field", row5.title),
                                 ("the element", row5),
                                 ("a Signal", name5)):
                before_role = len(kaya._tx)
                try:
                    kaya.label().role(source)
                    ok = False
                except Exception as exc:
                    ok = (isinstance(exc, TypeError)
                          and type(source).__name__ in str(exc))
                _rewind(before_role)
                check(f"a template node's role refuses {what}", ok)

            # THE CONTAINER KWARG, from inside the For — the `inset=`
            # half. The int is written on purpose: an inset arriving as
            # an I64 is refused by the root for its TYPE, a true
            # complaint about the wrong mistake (the window inset's
            # lesson, two levels up).
            before_ins = len(kaya._tx)
            with kaya.row(inset=8) as bar5:
                pass
            queued_ins = kaya._tx[before_ins:]
            _rewind(before_ins)
            check(
                "a container declared inside a For is a Node",
                isinstance(bar5, kaya.Node),
            )
            ins5 = [
                r for r in queued_ins
                if _rec_kind(r) == kaya.wire.TX_SET_PROPERTY
                and int.from_bytes(r[16:20], "little") == kaya.wire.PROP_INSET
            ]
            check("and its inset= reaches the records exactly once",
                  len(ins5) == 1)
            # NOT `if ins5:` — behind that guard a dropped record makes
            # the clause below VANISH instead of going red (the
            # harness-feature failure shape this file already learned
            # twice, at brand_accent and at brand_typeface).
            got_ins = (
                (int.from_bytes(ins5[0][8:16], "little"),
                 int.from_bytes(ins5[0][20:24], "little"),
                 int.from_bytes(ins5[0][24:28], "little"),
                 struct.unpack("<d", ins5[0][32:40])[0])
                if len(ins5) == 1 else (None, None, None, None))
            check(
                "naming the NODE's id, as a constant F64 and not an I64",
                got_ins == (bar5.id, kaya.wire.SOURCE_CONST,
                            kaya.wire.VALUE_F64, 8.0),
            )
            # AND THE DYNAMIC SETTER STAYS LIVE-ONLY, said out loud so
            # the asymmetry is a decision and not an oversight: `Widget`
            # adds the momentary verbs and the after-the-build prop
            # setters over `_Handle`, and a template is declared once and
            # never mutated. Moving `inset` down to the base would give a
            # blueprint a write with no moment to happen in.
            check("and the dynamic setter is not on a template node",
                  not hasattr(bar5, "inset") and hasattr(live5, "inset"))

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

# THE STYLING TIER (docs/styling-plan.md slice 1): the brand accent, the
# role and the window inset, each checked where this file can see —
# WHAT REACHED THE WIRE, and what the binding refuses before anything
# does. It cannot see the core: no transaction is ever applied here, so
# the pairings (role vs kind, a non-negative inset, the set-once wall)
# are the ROOT's and are probed against a running core instead.
#
# THE EMISSION HALF IS THE `spacing=` LESSON one prop over: a styling
# argument that is accepted and dropped changes nothing on screen and
# raises nothing, and neither a screenshot nor an accessibility read can
# tell "the platform ignored the role" from "the role never left the
# guest".
app_style = kaya.App()
with app_style.window(title="styling", width=480.0, height=360.0, inset=0.0):
    window_records = list(kaya._tx)

    def _window_prop(prop, value_type, records=None):
        return any(
            _rec_kind(r) == kaya.wire.TX_SET_WINDOW_PROP
            and int.from_bytes(r[16:20], "little") == prop
            and int.from_bytes(r[20:24], "little") == kaya.wire.SOURCE_CONST
            and int.from_bytes(r[24:28], "little") == value_type
            for r in (window_records if records is None else records)
        )

    check("window inset= reaches the records",
          _window_prop(kaya.wire.WPROP_INSET, kaya.wire.VALUE_F64))
    # AS AN F64 AND NOT AN I64, and the int is WRITTEN here rather than
    # assumed: the window prop is typed, so `inset=0` reaching the core
    # as an I64 would be refused for its TYPE — a true complaint about
    # the wrong mistake. (The live spelling of the same construct, which
    # is what a handler uses.)
    before_int = len(kaya._tx)
    app_style.window(inset=0)
    int_records = list(kaya._tx[before_int:])
    _rewind(before_int)
    check("and an int inset reaches it as the F64 the prop is typed as",
          _window_prop(kaya.wire.WPROP_INSET, kaya.wire.VALUE_F64, int_records)
          and not _window_prop(kaya.wire.WPROP_INSET, kaya.wire.VALUE_I64,
                               int_records))

    before = len(kaya._tx)
    kaya.brand_accent(0x3584E4)
    brand = [r for r in kaya._tx[before:]
             if _rec_kind(r) == kaya.wire.TX_SET_BRAND_ACCENT]
    check("brand_accent reaches the records", len(brand) == 1)
    # NOT `if brand:` — the typeface clauses below learned this under a
    # watched perturbation: behind the guard, a missing record makes the
    # two field clauses VANISH instead of going red (the harness-feature
    # failure shape, 194 -> 172). A missing record answers the sentinel
    # and both clauses fail.
    seed, mask, light, dark = (
        tuple(int.from_bytes(brand[0][8 + 4 * i:12 + 4 * i], "little")
              for i in range(4))
        if len(brand) == 1 else (None, None, None, None))
    check("the seed rides as one packed sRGB word", seed == 0x3584E4)
    check("and an unstated appearance sets no mask bit",
          (mask, light, dark) == (0, 0, 0))
    _rewind(before)

    # THE MASK IS THE ONE THING THIS CALL CAN GET SILENTLY WRONG: swap
    # bit 0 and bit 1 and a brand book's dark variant paints the light
    # appearance, with nothing raised anywhere. The convention is the
    # CORE's (crates/kaya/src/wire.rs decodes bit 0 = light, bit 1 =
    # dark), and it is pinned here so an edit cannot quietly reverse it.
    for what, call, want_mask, want_light, want_dark in (
        ("dark", lambda: kaya.brand_accent(0x3584E4, dark=0x62A0EA),
         2, 0, 0x62A0EA),
        ("light", lambda: kaya.brand_accent(0x3584E4, light=0xE62D42),
         1, 0xE62D42, 0),
        ("both", lambda: kaya.brand_accent(0x3584E4, light=0xE62D42,
                                           dark=0x62A0EA),
         3, 0xE62D42, 0x62A0EA),
    ):
        before = len(kaya._tx)
        call()
        rec = [r for r in kaya._tx[before:]
               if _rec_kind(r) == kaya.wire.TX_SET_BRAND_ACCENT][0]
        got = tuple(int.from_bytes(rec[8 + 4 * i:12 + 4 * i], "little")
                    for i in range(1, 4))
        check(f"a {what} override rides its own mask bit and slot",
              got == (want_mask, want_light, want_dark))
        _rewind(before)

    for what, value in (("a str", "#3584E4"), ("a bool", True),
                        ("a float", 1.0)):
        before = len(kaya._tx)
        try:
            kaya.brand_accent(value)
            ok = False
        except TypeError as exc:
            ok = "packed sRGB" in str(exc)
        except Exception:
            ok = False
        _rewind(before)
        check(f"brand_accent refuses {what}", ok)

    # THE BINDING REFUSES THE u32 DOMAIN ONLY — its spelling of what the
    # other bindings' parameter type refuses at compile time. The 24-bit
    # rule is deliberately NOT the binding's: for one fan-out this file's
    # was the only 0xRRGGBB wall in eight languages (invariant 1), so
    # that refusal now lives in the ROOT's SetBrandAccent arm
    # (crates/kaya/src/scene.rs, an_alpha_carrying_seed_dies), and the
    # binding's job is to deliver the word untouched for the root to
    # judge.
    for what, kwargs in (("a negative seed", {"seed": -1}),
                         ("a seed beyond u32", {"seed": 0x1_0000_0000})):
        before = len(kaya._tx)
        try:
            kaya.brand_accent(**kwargs)
            ok = False
        except ValueError as exc:
            ok = "does not fit the wire's u32" in str(exc)
        except Exception:
            ok = False
        _rewind(before)
        check(f"brand_accent refuses {what}", ok)

    before = len(kaya._tx)
    kaya.brand_accent(0xFF3584E4)
    argb = [r for r in kaya._tx[before:]
            if _rec_kind(r) == kaya.wire.TX_SET_BRAND_ACCENT]
    check("an in-u32 ARGB word passes through for the ROOT's wall to refuse",
          len(argb) == 1
          and int.from_bytes(argb[0][8:12], "little") == 0xFF3584E4)
    _rewind(before)

    # THE BRAND TYPEFACE (docs/styling-plan.md Slice 2b), the accent's
    # twin one slot over — and the half that cannot be seen any other
    # way. Every platform's font API renders SOMETHING for a family it
    # does not have, so a per-platform row that never left this guest is
    # indistinguishable, on every observation kaya owns, from a lowering
    # that applied: `expect_typeface` reads a RESOLVED family, and a
    # dropped row reads as the default the platform would have used.
    # That is the `spacing=` lesson with a font on it.

    # THE CLASS IS HAND-WRITTEN AND THE CONSTANTS ARE GENERATED, so the
    # first clause is the census that holds them together — the
    # kaya.Symbol shape one vocabulary over. Add a platform to
    # crates/kaya/src/spec.rs, regenerate, and this goes red until
    # kaya.Platform grows the name, instead of leaving Python the one
    # binding that cannot address the new backend (invariant 2).
    generated_platforms = {
        name[len("PLATFORM_"):].lower(): value
        for name, value in vars(kaya.wire).items()
        if name.startswith("PLATFORM_") and isinstance(value, int)
    }
    authored_platforms = {
        name.lower(): value
        for name, value in vars(kaya.Platform).items()
        if name.isupper()
    }
    check("kaya.Platform is exactly the generated vocabulary, name for name",
          authored_platforms == generated_platforms
          and len(authored_platforms) == 5)
    check("and the platform name spelling is derived from it, not typed twice",
          kaya._PLATFORM_NAMES == generated_platforms)
    check("and the tag->name table is that one reversed",
          kaya._PLATFORM_NAME_OF
          == {v: k for k, v in generated_platforms.items()})

    def _typeface(rec):
        """The TX_SET_BRAND_TYPEFACE record, field by field:
        8 header, u32 mask, u32 reserved, the family value, a counted
        value list (tag, family, tag, family, ...), then the font slot.
        Answers (mask, family, pairs, font_value_kind)."""
        def one(off):
            kind = int.from_bytes(rec[off:off + 4], "little")
            length = int.from_bytes(rec[off + 4:off + 8], "little")
            body = rec[off + 8:off + 8 + length]
            nxt = off + 8 + (length + 7) // 8 * 8
            if kind == kaya.wire.VALUE_I64:
                return kind, int.from_bytes(body, "little"), nxt
            if kind == kaya.wire.VALUE_STR:
                return kind, body.decode(), nxt
            return kind, body, nxt
        mask = int.from_bytes(rec[8:12], "little")
        _k, family, off = one(16)
        count = int.from_bytes(rec[off:off + 4], "little")
        off += 8
        flat = []
        for _ in range(count):
            _k, v, off = one(off)
            flat.append(v)
        font_kind, _v, _off = one(off)
        return mask, family, list(zip(flat[::2], flat[1::2])), font_kind

    def _typeface_records(records):
        return [r for r in records
                if _rec_kind(r) == kaya.wire.TX_SET_BRAND_TYPEFACE]

    before = len(kaya._tx)
    kaya.brand_typeface("Georgia")
    typefaces = _typeface_records(kaya._tx[before:])
    check("brand_typeface reaches the records", len(typefaces) == 1)
    # NOT `if typefaces:`, and the difference was measured rather than
    # reasoned: under a perturbation that queued the record and dropped
    # it on the floor, the two clauses below VANISHED instead of going
    # red — the harness-feature failure shape exactly (22 tests that
    # silently disappeared, 194 -> 172, rather than failing). A missing
    # record now answers the sentinel and both clauses fail.
    mask, family, pairs, font_kind = (
        _typeface(typefaces[0]) if len(typefaces) == 1
        else (None, None, None, None))
    # THE MASK AND THE SLOT ARE THE PAIR THIS CALL CAN GET SILENTLY
    # WRONG, exactly as the accent's appearance bits are: the convention
    # is the CORE's (crates/kaya/src/wire.rs writes bit 0 for a font blob
    # and an EMPTY STR in the slot when there is none), and a binding
    # that set the bit without the blob would send every backend to
    # register nothing.
    check("with the family as a Str, no rows, and bit 0 clear",
          (mask, family, pairs) == (0, "Georgia", []))
    check("and the font slot written anyway, as the empty Str",
          font_kind == kaya.wire.VALUE_STR)
    _rewind(before)

    # THE ROWS RIDE IN DECLARATION ORDER AND BOTH SPELLINGS RESOLVE, in
    # one clause because they fail together: a lowering picks the FIRST
    # row it matches, so an order this binding reshuffles is a family
    # silently swapped between two platforms.
    before = len(kaya._tx)
    kaya.brand_typeface("Georgia",
                        {kaya.Platform.LINUX: "DejaVu Serif",
                         "windows": "Constantia",
                         kaya.Platform.ANDROID: "Noto Serif"},
                        font=b"\x00\x01\x00\x00sfnt-ish")
    rows = _typeface_records(kaya._tx[before:])
    check("per-platform rows reach the wire in declaration order",
          len(rows) == 1
          and _typeface(rows[0])[2] == [
              (kaya.wire.PLATFORM_LINUX, "DejaVu Serif"),
              (kaya.wire.PLATFORM_WINDOWS, "Constantia"),
              (kaya.wire.PLATFORM_ANDROID, "Noto Serif")])
    check("and font= sets bit 0 with a Blob in the slot",
          len(rows) == 1
          and _typeface(rows[0])[0] == 1
          and _typeface(rows[0])[3] == kaya.wire.VALUE_BLOB)
    _rewind(before)

    # THE CLOSED SET AND THE TWO TYPES, said out loud where the other
    # seven bindings have `Platform`, `&str` and `Option<&[u8]>`. The
    # bool key is the coercion that would otherwise pass: `{True: ...}`
    # reads as platform 1, mac, out of a key that meant nothing.
    for what, kwargs, kind, fragment in (
        ("an unknown platform name",
         {"family": "Georgia", "platforms": {"bsd": "Charter"}},
         ValueError, "is not a platform"),
        ("a platform tag outside the vocabulary",
         {"family": "Georgia", "platforms": {6: "Charter"}},
         ValueError, "is not a platform"),
        ("a bool platform key",
         {"family": "Georgia", "platforms": {True: "Charter"}},
         TypeError, "not bool"),
        ("platforms= that is not a mapping",
         {"family": "Georgia", "platforms": [("linux", "Charter")]},
         TypeError, "takes a mapping"),
        ("a family that is not a str", {"family": b"Georgia"},
         TypeError, "takes a family NAME as str"),
        ("a family that is not a str on a ROW",
         {"family": "Georgia", "platforms": {"linux": 12}},
         TypeError, "takes a family NAME as str"),
        ("font= that is not bytes",
         {"family": "Georgia", "font": "/fonts/kaya.ttf"},
         TypeError, "takes a font FILE's bytes"),
    ):
        before_bad = len(kaya._tx)
        try:
            kaya.brand_typeface(**kwargs)
            ok = False
        except Exception as exc:
            ok = isinstance(exc, kind) and fragment in str(exc)
        _rewind(before_bad)
        check(f"brand_typeface refuses {what}", ok)

    # A refusal NAMES the vocabulary: with no enum to read it off, "not a
    # platform" leaves the reader's next question unanswered.
    try:
        kaya.brand_typeface("Georgia", {"bsd": "Charter"})
        named = False
    except ValueError as exc:
        named = all(f"'{n}'" in str(exc) for n in sorted(kaya._PLATFORM_NAMES))
    check("and the platform refusal lists the whole vocabulary", named)

    # WHAT IS DELIBERATELY NOT REFUSED HERE, pinned so a later edit
    # cannot quietly add it: an empty family, an empty family on a row
    # and one platform named twice are all the ROOT's, in one sentence
    # every language reads (crates/kaya/src/scene.rs). The accent's
    # 24-bit rule is why — this file's copy of a root wall was once the
    # only wall in eight (invariant 1).
    before = len(kaya._tx)
    passed_through = 0
    for kwargs in ({"family": ""},
                   {"family": "Georgia", "platforms": {"linux": ""}},
                   {"family": "Georgia",
                    "platforms": {kaya.Platform.LINUX: "A", "linux": "B"}}):
        try:
            kaya.brand_typeface(**kwargs)
            passed_through += 1
        except Exception:
            pass
    check("an empty family, an empty row and a duplicated platform all "
          "pass through for the ROOT to refuse", passed_through == 3)
    _rewind(before)

    with kaya.column():
        before = len(kaya._tx)
        kaya.label(text="Sections").role(kaya.Role.HEADING)
        role_records = [
            r for r in kaya._tx[before:]
            if _rec_kind(r) == kaya.wire.TX_SET_PROPERTY
            and int.from_bytes(r[16:20], "little") == kaya.wire.PROP_ROLE
        ]
        check("role() reaches the records", len(role_records) == 1)
        if role_records:
            r = role_records[0]
            check("as a constant I64 carrying the role's own value",
                  int.from_bytes(r[20:24], "little") == kaya.wire.SOURCE_CONST
                  and int.from_bytes(r[24:28], "little") == kaya.wire.VALUE_I64
                  and int.from_bytes(r[32:40], "little") == kaya.wire.ROLE_HEADING)
        # THE NAME SPELLING IS THE SAME PROP, not a second surface (the
        # `align="center"` precedent).
        before_name = len(kaya._tx)
        kaya.button("Delete").role("destructive")
        named = [r for r in kaya._tx[before_name:]
                 if _rec_kind(r) == kaya.wire.TX_SET_PROPERTY
                 and int.from_bytes(r[16:20], "little") == kaya.wire.PROP_ROLE]
        check("the string spelling writes the same prop",
              len(named) == 1
              and int.from_bytes(named[0][32:40], "little")
              == kaya.wire.ROLE_DESTRUCTIVE)
        _rewind(before)

        # THE CLOSED SET, said out loud where the other bindings have an
        # enum: a name outside it, a number outside it, and the three
        # source shapes that would otherwise coerce — `role(True)` reads
        # as 1, the destructive role, out of a value that meant nothing.
        role_signal = kaya.signal("heading")
        for what, value, kind, fragment in (
            ("an unknown name", "shouty", ValueError, "must be one of"),
            ("a number outside the vocabulary", 4, ValueError, "is not a role"),
            ("a bool", True, TypeError, "not bool"),
            ("a Signal", role_signal, TypeError, "not Signal"),
            ("a float", 3.0, TypeError, "not float"),
        ):
            before_bad = len(kaya._tx)
            try:
                kaya.button("Delete").role(value)
                ok = False
            except Exception as exc:
                ok = isinstance(exc, kind) and fragment in str(exc)
            _rewind(before_bad)
            check(f"role refuses {what}", ok)

    # THE SEMANTIC ICON VOCABULARY (docs/styling-plan.md D6). Same two
    # halves as the role above: what reached the wire, and what the
    # binding refuses before anything does. The PAIRINGS stay the
    # root's — a symbol on a separator, a signal-bound one — and are
    # probed against a running core, never here.

    # THE CLASS IS HAND-WRITTEN AND THE CONSTANTS ARE GENERATED, so the
    # first clause is the census that holds them together. Add a concept
    # to crates/kaya/src/spec.rs, regenerate, and this goes red until
    # kaya.Symbol grows the name — without it Python is silently the one
    # binding that cannot say the new word, which is exactly how
    # `list_detail` shipped unsayable here (invariant 2).
    generated = {
        name[len("SYMBOL_"):].lower(): value
        for name, value in vars(kaya.wire).items()
        if name.startswith("SYMBOL_") and isinstance(value, int)
    }
    authored = {
        name.lower(): value
        for name, value in vars(kaya.Symbol).items()
        if name.isupper()
    }
    check("kaya.Symbol is exactly the generated vocabulary, name for name",
          authored == generated and len(authored) == 20)
    check("and the name spelling is derived from it, not typed twice",
          kaya._SYMBOL_NAMES == generated)

    def _menu_symbols(records):
        """The symbol values that reached the wire as menu props."""
        return [
            int.from_bytes(r[32:40], "little")
            for r in records
            if _rec_kind(r) == kaya.wire.TX_SET_MENU_PROP
            and int.from_bytes(r[16:20], "little") == kaya.wire.MPROP_SYMBOL
            and int.from_bytes(r[20:24], "little") == kaya.wire.SOURCE_CONST
            and int.from_bytes(r[24:28], "little") == kaya.wire.VALUE_I64
        ]

    # EVERY CONSTRUCTOR THAT TAKES `icon=` TAKES `symbol=` AND EMITS IT.
    # A census and not one spot check: the failure this catches is the
    # fan-out that grows `item` and forgets `option`, which no scene can
    # see (the scene asserts the items it names) and which leaves one
    # kind of menu entry unable to carry an icon at all.
    with app_style.menu("File") as bar_menu:
        surfaces = [
            ("kaya.item", lambda: kaya.item("Save", symbol=kaya.Symbol.DONE)),
            ("kaya.toggle", lambda: kaya.toggle("Details",
                                                symbol=kaya.Symbol.DONE)),
            ("kaya.menu", lambda: kaya.menu("Sub", symbol=kaya.Symbol.DONE)),
            ("kaya.radio_group", lambda: kaya.radio_group(
                "Sort", symbol=kaya.Symbol.DONE)),
            ("MenuItem.symbol", lambda: bar_menu.symbol(kaya.Symbol.DONE)),
        ]
        for what, call in surfaces:
            before_s = len(kaya._tx)
            try:
                call()
                got = _menu_symbols(kaya._tx[before_s:])
            except Exception as exc:
                print(f"       (raised {type(exc).__name__}: {exc})")
                got = []
            _rewind(before_s)
            check(f"{what} takes symbol= and it reaches the wire",
                  got == [kaya.wire.SYMBOL_DONE])
        # kaya.option only declares inside a radio group.
        with kaya.radio_group("Sort") as _group:
            before_s = len(kaya._tx)
            kaya.option("Name", symbol=kaya.Symbol.DONE)
            got = _menu_symbols(kaya._tx[before_s:])
            _rewind(before_s)
            check("kaya.option takes symbol= and it reaches the wire",
                  got == [kaya.wire.SYMBOL_DONE])
    before_s = len(kaya._tx)
    with app_style.radio_group("Bar", symbol=kaya.Symbol.DONE):
        pass
    got = _menu_symbols(kaya._tx[before_s:])
    _rewind(before_s)
    check("app.radio_group takes symbol= and it reaches the wire",
          got == [kaya.wire.SYMBOL_DONE])
    before_s = len(kaya._tx)
    with app_style.menu("Bar2", symbol=kaya.Symbol.DONE):
        pass
    got = _menu_symbols(kaya._tx[before_s:])
    _rewind(before_s)
    check("app.menu takes symbol= and it reaches the wire",
          got == [kaya.wire.SYMBOL_DONE])

    # THE NAME SPELLING IS THE SAME PROP, not a second surface (the
    # `align="center"` / `role("heading")` precedent).
    with app_style.menu("File2"):
        before_s = len(kaya._tx)
        kaya.item("Copy", symbol="copy")
        got = _menu_symbols(kaya._tx[before_s:])
        _rewind(before_s)
        check("the name spelling writes the same menu prop and value",
              got == [kaya.wire.SYMBOL_COPY])

    # The SECTION half of the same prop — a different wire slot
    # (SPROP_SYMBOL), so the menu clauses above say nothing about it.
    before_s = len(kaya._tx)
    with app_style.add_section(4242, title="Feed", symbol=kaya.Symbol.HOME):
        with kaya.column():
            kaya.label("feed")
    section_symbols = [
        int.from_bytes(r[32:40], "little")
        for r in kaya._tx[before_s:]
        if _rec_kind(r) == kaya.wire.TX_SET_SECTION_PROP
        and int.from_bytes(r[16:20], "little") == kaya.wire.SPROP_SYMBOL
        and int.from_bytes(r[20:24], "little") == kaya.wire.SOURCE_CONST
        and int.from_bytes(r[24:28], "little") == kaya.wire.VALUE_I64
    ]
    _rewind(before_s)
    check("add_section takes symbol= and it reaches the wire",
          section_symbols == [kaya.wire.SYMBOL_HOME])

    # THE CLOSED SET, said out loud where the other bindings have an
    # enum. A bool is excluded before int (which it subclasses):
    # `symbol(True)` would otherwise read as 1, the `add` glyph, out of
    # a value that meant nothing.
    symbol_signal = kaya.signal(5)
    with app_style.menu("File3"):
        bad_item = kaya.item("Save")
        for what, value, kind, fragment in (
            ("an unknown name", "save", ValueError, "must be one of"),
            ("a number past the vocabulary", 21, ValueError,
             "is not a symbol"),
            ("zero", 0, ValueError, "is not a symbol"),
            ("a bool", True, TypeError, "not bool"),
            ("a Signal", symbol_signal, TypeError, "not Signal"),
            ("a float", 15.0, TypeError, "not float"),
        ):
            before_bad = len(kaya._tx)
            try:
                bad_item.symbol(value)
                ok = False
            except Exception as exc:
                ok = isinstance(exc, kind) and fragment in str(exc)
            _rewind(before_bad)
            check(f"symbol refuses {what}", ok)
        # AND THE REFUSAL NAMES THE VOCABULARY: "not a symbol" alone
        # leaves the reader's next question ("then what may I say?")
        # unanswered, and there is no enum here to read it off.
        try:
            bad_item.symbol("save")
            named = False
        except ValueError as exc:
            named = all(f"'{n}'" in str(exc)
                        for n in sorted(kaya._SYMBOL_NAMES))
        check("and the refusal lists the whole vocabulary", named)

    # The section spelling refuses AT THE add_section CALL, not at the
    # `with`: the scope records nothing until it is entered, so a raise
    # from __enter__ would point at the block instead of at the word.
    before_bad = len(kaya._tx)
    try:
        app_style.add_section(4243, title="Nope", symbol="save")
        ok = False
    except ValueError as exc:
        ok = "must be one of" in str(exc)
    _rewind(before_bad)
    check("add_section refuses a bad symbol at the call, not at the with", ok)

sys.exit(1 if failures else 0)

