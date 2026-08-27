"""Tier-1 negative and bookkeeping checks against the real bindings.
The core is never entered: records queue and the process exits."""

import dataclasses
import struct
import sys
import time
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
        # and When).
        cond = kaya.signal(True)
        with kaya.when(cond):
            try:
                c.items()
                check("guard trips in a When body", False)
            except RuntimeError:
                check("guard trips in a When body", True)
            kaya.label("empty")

# ONE ID SPACE: a template node draws from the WIDGET counter, so an app
# hands out one number sequence and the core's two "already exists" walls
# can never fire on an id the binding minted (DESIGN.md, Binding
# conventions). The contiguous run is the assertion — a private node
# counter passes "all different" while restarting at 1.
with app.build():
    with kaya.column():
        live = kaya.label("live")
        with kaya.for_each(c) as el:
            node = kaya.label(bind=el)
        after = kaya.label("live")
ids = [live.id, node.id, after.id]
check("a template node never shares a number with a live widget",
      len(set(ids)) == 3)
check("widget and node ids run through one counter",
      node.id == live.id + 2 and after.id == node.id + 1)

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

# Moves reorder the mirror the way the core reorders the table: by key,
# before an anchor or to the end. Missing keys raise at the call site.
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

# The tracing tier: the for statement traces to a For, comparisons are
# the derive vocabulary in operator clothes, and statement branching has
# no truth value at record time.
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
    try:
        for _ in feed.rows(grow=1):
            pass
        check("rows preserves the sum for-trace wall", False)
    except TypeError:
        check("rows preserves the sum for-trace wall", True)

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
        for _ in traced.rows(grow=1):
            pass
        check("rows preserves the model-iteration wall", False)
    except TypeError:
        check("rows preserves the model-iteration wall", True)
    try:
        escaped[0].done
        check("escaped tracer raises", False)
    except RuntimeError:
        check("escaped tracer raises", True)

# Dynamic tables: the nested spelling is the flat spelling at one more
# level, while an instance re-declaration names its copy outermost first.
sort_calls = []
app_table = kaya.App()
with app_table.window():
    accounts = kaya.collection(TracedTodo)
    with kaya.column():
        for account in accounts:
            with kaya.column():
                sleeves = kaya.collection(TracedTodo)
                for sleeve in sleeves:
                    with kaya.column():
                        positions = kaya.collection(TracedTodo)
                        before_table = len(kaya._tx)
                        for position in positions.columns(
                            "Name", "Done",
                            on_sort=lambda *args: sort_calls.append(args),
                        ):
                            with kaya.row():
                                kaya.label(bind=position.title)
                                kaya.checkbox(checked=position.done)
                        table_records = kaya._tx[before_table:]

table_node = positions._for_handle
header_records = [
    record for record in table_records
    if int.from_bytes(record[4:6], "little") == kaya.wire.TX_SET_COLUMN_HEADERS
]
check(
    "nested columns declares a template-scoped header bar",
    header_records == [kaya.wire.tx_set_column_headers(
        table_node, kaya.Sort.NONE.sorted, kaya.Sort.NONE.direction,
        2, 0, ["Name", "Done"],
    )],
)
sort_key = (kaya.wire.OCC_SORT_REQUESTED, table_node)
check(
    "nested on_sort registers in the node table only",
    sort_key in app_table._node_handlers
    and sort_key not in app_table._widget_handlers,
)
table_occs = [
    (kaya.wire.OCC_SORT_REQUESTED, table_node,
     ["brokerage", "taxable"], 1),
]
real_next_table = kaya.runtime.next_occurrence
kaya.runtime.next_occurrence = lambda: table_occs.pop(0) if table_occs else None
try:
    app_table._dispatch_loop()
finally:
    kaya.runtime.next_occurrence = real_next_table
check(
    "nested on_sort passes copy keys outermost first, then the column",
    sort_calls == [("brokerage", "taxable", 1)],
)

with app_table.build():
    before_table = len(kaya._tx)
    positions.set_columns("Name", "Done", sort=kaya.Sort.asc(0))
    default_header = kaya._tx[before_table:] == [
        kaya.wire.tx_set_column_headers(
            table_node, 0, kaya.Sort.asc(0).direction,
            2, 0, ["Name", "Done"],
        )
    ]
check(
    "the unchanged collection spelling re-declares the template-wide header",
    default_header,
)

with app_table.build():
    before_table = len(kaya._tx)
    try:
        positions.at("brokerage", "taxable").set_columns(
            "Name", "Done", sort=kaya.Sort.desc(1),
        )
        keyed_header = kaya._tx[before_table:] == [
            kaya.wire.tx_set_column_headers(
                table_node, 1, kaya.Sort.desc(1).direction,
                2, 2, ["brokerage", "taxable", "Name", "Done"],
            )
        ]
    except AttributeError:
        keyed_header = False
check(
    "an instance re-declares its own header with keys before titles",
    keyed_header,
)

# THE ROW'S OWN FIELDS. A nested table is FOR rows that carry named
# fields: the record-schema constructor must reach the TEMPLATE zone
# (Python's is ambient, so the open-For edge is what puts it there), and
# narrowing to one stamped copy must keep the record type — an instance
# that lost it would encode the copy's entries against no schema. Six
# other bindings' twins closed 2026-08-25 (docs/deferred.md).
app_rec = kaya.App()
with app_rec.window():
    rec_accounts = kaya.collection()
    with kaya.column():
        for rec_account in rec_accounts:
            with kaya.column():
                rec_before = len(kaya._tx)
                rec_positions = kaya.collection(TracedTodo)
                rec_birth = kaya._tx[rec_before:]
                for rec_position in rec_positions:
                    with kaya.row():
                        kaya.label(bind=rec_position.title)
                        kaya.checkbox(checked=rec_position.done)
check(
    "a nested record collection is born with the RECORD schema",
    rec_birth == [kaya.wire.tx_create_collection(
        rec_positions._id, [[kaya.wire.VALUE_STR, kaya.wire.VALUE_BOOL]],
    )],
)
check(
    "a collection declared inside a For records the teardown edge that "
    "makes it the copies' rather than the live tree's",
    rec_positions in rec_accounts._children,
)
with app_rec.build():
    rec_accounts.insert("brokerage", "Brokerage")
    rec_copy = rec_positions.at("brokerage")
    rec_at_before = len(kaya._tx)
    rec_copy.insert("aapl", TracedTodo("AAPL", False))
    rec_insert = kaya._tx[rec_at_before:]
    check(
        "the typed instance insert carries the copy's key path and the "
        "record's fields",
        rec_insert == [kaya.wire.tx_collection_insert(
            rec_positions._id, ["brokerage"], "aapl", 0, ["AAPL", False],
        )],
    )
    check(
        "the copy's model holds the record itself",
        rec_copy.items() == [("aapl", TracedTodo("AAPL", False))],
    )
    check(
        "the write was addressed to a copy and does not reach the "
        "collection's own table",
        len(rec_positions) == 0,
    )

# One-shot commands: a Widget carries clear/focus, a Node is a blueprint
# and has neither. Commands carry no mirror state, so an aborted build's
# rollback is the records dying.
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

# The blob channel at the binding boundary: image() registers its bytes,
# a bytes dataclass field maps to VALUE_BLOB and re-registers at every
# encode, and template binds lower to SOURCE_ELEMENT. The type walls
# hold: str is not image data, bytes are not label text.
@dataclass
class Avatar:
    name: str
    pic: bytes


def _rec_kind(rec):
    return int.from_bytes(rec[4:6], "little")


app_rows_props = kaya.App()
with app_rows_props.window():
    growing_rows = kaya.collection()
    before = len(kaya._tx)
    for growing_row in growing_rows.rows(
        grow=1, align="stretch", a11y_id="accounts",
    ):
        kaya.label(bind=growing_row)
    rows_records = kaya._tx[before:]
    rows_for_ids = [
        int.from_bytes(rec[8:16], "little")
        for rec in rows_records
        if _rec_kind(rec) == kaya.wire.TX_CREATE_FOR
    ]
    rows_for = rows_for_ids[0] if len(rows_for_ids) == 1 else 0
    check(
        "rows(grow=) reaches its For",
        kaya.wire.tx_set_grow(rows_for, 1.0) in rows_records,
    )
    check(
        "rows(align=) reaches its For",
        kaya.wire.tx_set_align(rows_for, kaya.wire.ALIGN_STRETCH) in rows_records,
    )
    check(
        "rows(a11y_id=) reaches its For",
        kaya.wire.tx_set_a11y_id(rows_for, "accounts") in rows_records,
    )


# A NESTED For's a11y_id MAY COME FROM THE ROW. The copies of one
# template node share a node id, so a constant names N containers at
# once and the harness cannot tell them apart — which is exactly what
# tools/scenes/varied.steps needs (`expect_order column@r200`). The
# failure this watches for is the coercing arm: `str(row.key)` succeeds
# and writes a FieldRef's repr onto every copy.
app_nested_key = kaya.App()
with app_nested_key.window():

    @dataclass
    class Outer:
        key: str

    outers = kaya.collection(Outer)
    for outer in outers.rows():
        inners = kaya.collection()
        before = len(kaya._tx)
        for inner in inners.rows(a11y_id=outer.key):
            kaya.label(bind=inner)
        inner_records = kaya._tx[before:]
    inner_for_ids = [
        int.from_bytes(rec[8:16], "little")
        for rec in inner_records
        if _rec_kind(rec) == kaya.wire.TX_CREATE_FOR
    ]
    inner_for = inner_for_ids[0] if len(inner_for_ids) == 1 else 0
    check(
        "a nested rows(a11y_id=row.field) binds the element, never its repr",
        kaya.wire.tx_bind_a11y_id_element(inner_for, 0, 0) in inner_records
        and not any(
            _rec_kind(rec) == kaya.wire.TX_SET_PROPERTY
            and int.from_bytes(rec[16:20], "little") == kaya.wire.PROP_A11Y_ID
            and int.from_bytes(rec[20:24], "little") == kaya.wire.SOURCE_CONST
            for rec in inner_records
        ),
    )


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

# A construction-time layout prop MUST reach the record stream: a
# wire-dropped write is invisible to every geometry gate
# (docs/deferred.md, the Swift containerOf miss).
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
        # here: an I64 is refused by the root for its TYPE, which is a
        # true complaint about the wrong mistake.
        check(
            "column inset= reaches the records",
            _prop_write(kaya.wire.PROP_INSET, kaya.wire.VALUE_F64)
            and not _prop_write(kaya.wire.PROP_INSET, kaya.wire.VALUE_I64),
        )

# AN EMPTY A11Y LABEL PASSES THROUGH FOR THE ROOT'S WALL TO REFUSE —
# brand_accent's rule one prop over (crates/kaya/src/scene.rs,
# an_empty_a11y_label_dies_at_declare). The refusal is deliberately the
# ROOT'S and not this binding's: four backends each answered `A11yLabel
# = ""` their own way and only WinUI's aborted, so the semantics is
# settled once at the chokepoint all eight bindings reach rather than
# eight times (invariant 1, docs/deferred.md a11y-empty-label).
# WHAT THIS WATCHES FOR is the helpful binding: a Python tier that
# dropped an empty label as a no-op would leave the root nothing to
# refuse, and the divergence would be back with every gate green.
with app.build():
    if True:
        before = len(kaya._tx)
        with kaya.column():
            kaya.label("x").a11y_label("")
        queued = kaya._tx[before:]
        empty_label = [
            r for r in queued
            if _rec_kind(r) == kaya.wire.TX_SET_PROPERTY
            and int.from_bytes(r[16:20], "little") == kaya.wire.PROP_A11Y_LABEL
            and int.from_bytes(r[20:24], "little") == kaya.wire.SOURCE_CONST
            and int.from_bytes(r[24:28], "little") == kaya.wire.VALUE_STR
        ]
        check(
            "an empty a11y label reaches the records for the ROOT to refuse",
            len(empty_label) == 1
            # and it is EMPTY on the wire: the length word after the tag.
            and int.from_bytes(empty_label[0][28:32], "little") == 0,
        )

# The generated shortcut canonicalizer (DESIGN.md, Menus): spelling is
# canonicalized here, POLICY dies at the core on the canonical form. The
# vectors mirror kaya-bindgen's reference table.
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

# tx_set_menu_shortcut routes through the canonicalizer: no call site
# can bypass it.
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

# Menu construction must REACH the record stream: a surface check cannot
# see a constructor that emits nothing.
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

    # The radio value's seat: value= must land AFTER the option children
    # it addresses — the root judges the index against the option count
    # at the record, so an eager emission dies with "0 options".
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

# The rest of the menu guard layer (menus-plan §6). A fresh App keeps
# the module-global _app pointed at what these blocks assert.
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
# the MENU table (its own id space), a bar item's activation passes
# bare, and a stamped copy's carries the copy's keys FIRST.
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

# The reopened subtree's records die with an aborted transaction, and the
# abort disarms any open menu scope — the next transaction must not
# inherit a seat.
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
# does not open one (App._dispatch does). Three rules that spelling has
# to keep — head of batch, one name per step, and a name — plus what an
# `undone` occurrence does to the mirrors (docs/undo-plan.md D2, D5).


@dataclass
class _Todo:
    title: str


app_undo = kaya.App()
_undo_shipped = []
_real_submit3 = kaya.runtime.submit
kaya.runtime.submit = lambda *records: _undo_shipped.append(records)
try:
    # THE MARKER LEADS THE BATCH wherever the call sits in the body: the
    # core refuses a group whose marker is not at index 0.
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
        # while the app is looking is the claim.
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

# Five steps come back: the entry goes; it comes back at the end, the way
# a re-inserted key lands; a delta that names nothing still reaches the
# handler; an orders run restates the whole instance order; the last one
# lands on a window with NO handler at all.
_undo_occs = [
    (kaya.wire.OCC_UNDONE, 0, [],
     ("add milk", [(undo_sig.id, "before")], [(7, "milk")],
      [(undo_todos._id, (), "t1", None)], [])),
    (kaya.wire.OCC_REDONE, 0, [],
     ("add milk", [], [], [(undo_todos._id, (), "t1", (0, ["milk"]))], [])),
    (kaya.wire.OCC_UNDONE, 0, [], ("star", [], [], [], [])),
    # AN ORDER NOTHING ELSE PRODUCES, so a run that never applied cannot
    # pass by looking like the state already there.
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
# skip no-op DERIVED writes, and an undo moves signals behind that cache.
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
# (DESIGN.md, Binding conventions), so Python's construct has to serve
# the LIVE case too: it hangs off the App because that doubles as the
# scene scope, so the same call means two things and `_tx` decides.
#
# THIS IS A SILENT FAILURE CLASS AND THAT IS WHY IT IS CHECKED HERE.
# Watched 2026-08-06 with the live branch deleted: `app.window(dirty=
# True)` inside a handler emitted nothing, raised nothing, printed
# nothing, and the mac leg failed three `expect_dirty true` steps while
# every label assertion passed.
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
    # THE LIVE SPELLING SHIPS THE SAME RECORD, byte for byte: one prop
    # emitter, reached two ways.
    with app_win.build():
        app_win.window(dirty=False)
    check(
        "the live window construct ships the same record",
        _win_shipped[1:2] == [[kaya.wire.tx_set_window_dirty(0, False)]],
    )
    # An auxiliary surface is NAMED, not assumed: otherwise a mark raised
    # on a panel would land on the primary.
    with app_win.build():
        app_win.window(dirty=True, window_id=7)
    check(
        "the live window construct names its surface",
        _win_shipped[2:3] == [[kaya.wire.tx_set_window_dirty(7, True)]],
    )
    # `panes` IS AN INTEGER PROP AND PYTHON HAS NO TYPE TO CATCH IT: the
    # keyword takes whatever it is handed, and a bool would ride the same
    # `int()` as a count. Decoded from the bytes rather than asked about,
    # so the ceiling that reaches the wire is the one the guest said
    # (docs/multicolumn-plan.md).
    with app_win.build():
        app_win.window(panes=2)
    check(
        "the window construct ships the panes ceiling as an I64",
        _win_shipped[3:4] == [[kaya.wire.tx_set_window_panes(0, 2)]],
    )
    # And the `with` form inside an open transaction is refused IN ITS
    # OWN WORDS: "transactions do not nest" is true here and unhelpful.
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
# bytes rather than asked about (docs/sugar-pass-plan.md D3). Each
# clause insists on the prop, the source kind, the level and the FIELD
# INDEX: a constructor that takes the argument and drops it, or binds
# the wrong field, fails here — the arm has to be REACHABLE, not merely
# declared, which is all a `hasattr` check ever asked.
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

    A RAISING ARM IS A FINDING, NOT A CRASH: an uncaught AttributeError
    would end the run at the first bad arm, with no verdict on the ones
    beside it. So it is caught and answered as a failed clause."""
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

    Whether an argument grows an element arm is undecided; what is
    decided is that a per-row source must never quietly become ONE value
    for every row. `progress(indeterminate=el)` wrote a constant True and
    said nothing, because an object with no `__bool__` is true."""
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
            # The per-row CAPTION (docs/deferred.md, "the template
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

        # The const-only arms, handed the same tracer. Each coerces —
        # float(), int(), bool(), the UTF-8 wall — and a coercion that
        # SUCCEEDS is the silent failure this file exists for.
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
    # pass with it hard-coded to 0. `FieldRef._level()` counts the open
    # Fors, so an OUTER element read from inside an inner For is one up.
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

    # `bind=` is the one source argument Python cannot type, so it needs
    # a floor: a value that is not a Signal, an Element or a FieldRef
    # must not fall out of the ladder and bind NOTHING. The seven typed
    # bindings get this from their compilers.
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
                # The message NAMES WHAT IT GOT.
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

    # AND THE ZONE WALL UNDER `button(bind=)`: a bound caption is a
    # TEMPLATE-zone constructor in all eight (docs/tpl-props-plan.md F5).
    # The other seven refuse it live by having no such overload; Python's
    # ambient transaction gives one function to both zones, so the
    # refusal is a ZONE CHECK and this is the only place to watch it.
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
# share, so the same call names a live widget and a stamped copy.
#
# WHAT MAKES IT WORTH CHECKING RATHER THAN READING: the surface is
# `hasattr`-shaped, so a reader cannot tell a method that reaches the
# wire from one that reaches the wrong id or the wrong source. The paste
# clause reads the TABLE the handler landed in, because one filed under
# a widget id never fires for a row.


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

    Catches for `_elem_bind`'s reason: an uncaught AttributeError would
    end the run at the first bad arm."""
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

    The TARGET is half of what it has to answer: a role or an inset that
    reached the wire naming a LIVE widget id styles nothing a For will
    ever stamp, and raises nowhere."""
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
    # AND A LIVE SIGNAL SOURCE BINDS RATHER THAN COERCING — the one
    # place this binding reaches further than the other seven, whose
    # live a11y setters take a string. The alternative coercion wrote a
    # Signal's repr onto the widget and said nothing.
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
            # THE ROW'S OWN FIELD IS THE POINT: copies of one node share
            # one node id, so a constant label makes N checkboxes that
            # all announce the same thing.
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
            # first in `_prop_source`: `str(row.title)` succeeds and a
            # screen reader reads the repr out.
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

            # ACCEPTS IS CONST-ONLY AND SAYS SO: an accept list
            # describes the prototype, not the row.
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
                    # The exception TYPE is half the clause: without the
                    # refusal these coerce into `_accept_list`, whose
                    # ValueError quotes the repr and so happens to
                    # contain the type's name too — a true sentence about
                    # the wrong problem.
                    ok = (isinstance(exc, TypeError)
                          and type(source).__name__ in str(exc))
                _rewind(before_acc)
                check(f"accepts refuses {what} as a per-row source", ok)

            # THE PASTE REGISTRAR. Python needs no dispatch arm — the
            # loop branches on whether the record carried a key path, not
            # on the occurrence kind.
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

            # THE STYLING PROPS IN THE TEMPLATE ZONE, reached by two
            # DIFFERENT lines, which is why they are checked apart:
            # `role` is `_Handle.role`, shared by Widget and Node like
            # the a11y trio; `inset` is the container constructors'
            # kwarg, written onto whatever `_alloc_widget_or_node` hands
            # back — a Node inside a For, so THE KWARG IS THIS ZONE'S
            # SPELLING and `Widget.inset` stays live-only on purpose.
            #
            # BOTH CLAUSES READ THE TARGET ID: a prop that reaches the
            # wire naming a WIDGET id styles something no For will ever
            # stamp, and nothing raises.
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
            # CONST-ONLY for `accepts`'s reason, not a missing encoder.
            # The refusal has to NAME what it got: without it
            # `_role_value`'s int arm is reached by anything with an
            # `__index__` and the row's number becomes a role.
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

            # THE CONTAINER KWARG, from inside the For. The int is
            # written on purpose: an I64 is refused by the root for its
            # TYPE, a true complaint about the wrong mistake.
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
            # the clause below VANISH instead of going red.
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
            # AND THE DYNAMIC SETTER STAYS LIVE-ONLY: a template is
            # declared once and never mutated, so moving `inset` down to
            # the base would give a blueprint a write with no moment to
            # happen in.
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

# THE STYLING TIER (docs/styling-plan.md slice 1), checked where this
# file can see: WHAT REACHED THE WIRE, and what the binding refuses. It
# cannot see the core — no transaction is applied here — so the pairings
# are the ROOT's and are probed against a running core instead.
#
# A styling argument that is accepted and dropped changes nothing on
# screen and raises nothing, and neither a screenshot nor an
# accessibility read can tell that from a platform ignoring it.
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
    # AS AN F64 AND NOT AN I64, and the int is WRITTEN rather than
    # assumed: `inset=0` reaching the core as an I64 would be refused for
    # its TYPE, a true complaint about the wrong mistake.
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
    # NOT `if brand:` — watched: behind the guard, a missing record makes
    # the two field clauses VANISH instead of going red. A missing record
    # answers the sentinel and both clauses fail.
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
    # appearance. The convention is the CORE's (bit 0 = light).
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
    # rule is deliberately the ROOT's (crates/kaya/src/scene.rs,
    # an_alpha_carrying_seed_dies): a binding-local copy of a root wall
    # was once the only wall in eight (invariant 1).
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

    # THE BRAND TYPEFACE (docs/styling-plan.md Slice 2b), and the half
    # that cannot be seen any other way: every platform's font API
    # renders SOMETHING for a family it does not have, so a per-platform
    # row that never left this guest is indistinguishable from a lowering
    # that applied.

    # THE CLASS IS HAND-WRITTEN AND THE CONSTANTS ARE GENERATED, so the
    # first clause is the census holding them together: add a platform to
    # crates/kaya/src/spec.rs and this goes red until kaya.Platform grows
    # the name (invariant 2).
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
    # NOT `if typefaces:`, and the difference was MEASURED: under a
    # perturbation that queued the record and dropped it, the two clauses
    # below VANISHED instead of going red. A missing record now answers
    # the sentinel and both clauses fail.
    mask, family, pairs, font_kind = (
        _typeface(typefaces[0]) if len(typefaces) == 1
        else (None, None, None, None))
    # THE MASK AND THE SLOT ARE THE PAIR THIS CALL CAN GET SILENTLY
    # WRONG: the convention is the CORE's (bit 0 for a font blob, an
    # EMPTY STR in the slot when there is none).
    check("with the family as a Str, no rows, and bit 0 clear",
          (mask, family, pairs) == (0, "Georgia", []))
    check("and the font slot written anyway, as the empty Str",
          font_kind == kaya.wire.VALUE_STR)
    _rewind(before)

    # THE ROWS RIDE IN DECLARATION ORDER: a lowering picks the FIRST row
    # it matches, so a reshuffle silently swaps two platforms' families.
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

    # THE CLOSED SET AND THE TWO TYPES, where the other seven bindings
    # have `Platform`, `&str` and `Option<&[u8]>`. The bool key is the
    # coercion that would otherwise pass: `{True: ...}` reads as mac.
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
    # and one platform named twice are all the ROOT's (invariant 1).
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

    # THE APP IDENTITY (docs/app-identity-plan.md), the typeface's
    # failure shape one tier up: every platform draws SOMETHING where an
    # app's mark goes. The mask and the slot are the pair that goes
    # silently wrong.

    def _identity(rec):
        """The TX_SET_APP_IDENTITY record, field by field: 8 header,
        u32 mask, u32 reserved, the name value, the icon slot. Answers
        (mask, reserved, name, icon_kind, icon_len)."""
        def one(off):
            kind = int.from_bytes(rec[off:off + 4], "little")
            length = int.from_bytes(rec[off + 4:off + 8], "little")
            body = rec[off + 8:off + 8 + length]
            nxt = off + 8 + (length + 7) // 8 * 8
            return kind, length, body, nxt
        mask = int.from_bytes(rec[8:12], "little")
        reserved = int.from_bytes(rec[12:16], "little")
        _k, _n, name, off = one(16)
        icon_kind, icon_len, _b, _off = one(off)
        return mask, reserved, name.decode(), icon_kind, icon_len

    def _identity_records(records):
        return [r for r in records
                if _rec_kind(r) == kaya.wire.TX_SET_APP_IDENTITY]

    before = len(kaya._tx)
    kaya.app_identity("Aurora Notes", icon=b"\x89PNG\r\n\x1a\n not really")
    identities = _identity_records(kaya._tx[before:])
    check("app_identity reaches the records", len(identities) == 1)
    # The sentinel rather than `if identities:`, for the typeface
    # clause's measured reason: a dropped record must FAIL, not vanish.
    mask, reserved, name, icon_kind, icon_len = (
        _identity(identities[0]) if len(identities) == 1
        else (None, None, None, None, None))
    check("with the name as a Str, bit 0 set and a Blob in the icon slot",
          (mask, name, icon_kind) == (1, "Aurora Notes", kaya.wire.VALUE_BLOB))
    check("and the reserved word untouched — a guest names no platform here",
          reserved == 0)
    _rewind(before)

    # THE NAME-ONLY FORM: the icon slot is written ANYWAY, as the empty
    # Str, so the record's field count never varies with the payload.
    before = len(kaya._tx)
    kaya.app_identity("Aurora Notes")
    named_only = _identity_records(kaya._tx[before:])
    check("app_identity with no icon= still reaches the records",
          len(named_only) == 1)
    mask, _reserved, name, icon_kind, icon_len = (
        _identity(named_only[0]) if len(named_only) == 1
        else (None, None, None, None, None))
    check("with bit 0 CLEAR and the icon slot written as the empty Str",
          (mask, name, icon_kind, icon_len)
          == (0, "Aurora Notes", kaya.wire.VALUE_STR, 0))
    _rewind(before)

    # THE TWO WIRE-DOMAIN TYPES, where the other seven bindings have
    # `&str` and `Option<&[u8]>`: the path-instead-of-bytes slip would
    # otherwise reach the core as a name-shaped blob.
    for what, kwargs, fragment in (
        ("icon= that is not bytes",
         {"name": "Aurora Notes", "icon": "guests/assets/icons/kaya-mark.png"},
         "takes an image FILE's bytes"),
        ("a name that is not a str", {"name": b"Aurora Notes"},
         "takes the app's name as str"),
    ):
        before_bad = len(kaya._tx)
        try:
            kaya.app_identity(**kwargs)
            ok = False
        except Exception as exc:
            ok = isinstance(exc, TypeError) and fragment in str(exc)
        _rewind(before_bad)
        check(f"app_identity refuses {what}", ok)

    # WHAT IS DELIBERATELY NOT REFUSED HERE: an empty name and an empty
    # icon blob are both the ROOT's (invariant 1).
    before = len(kaya._tx)
    passed_through = 0
    for kwargs in ({"name": ""}, {"name": "Aurora Notes", "icon": b""}):
        try:
            kaya.app_identity(**kwargs)
            passed_through += 1
        except Exception:
            pass
    check("an empty name and an empty icon blob both pass through for the "
          "ROOT to refuse", passed_through == 2)
    # AND THE EMPTY BLOB STILL SETS THE MASK, which is what makes the
    # root's refusal reachable from Python at all.
    empty_icon = _identity_records(kaya._tx[before:])
    check("and an empty icon= still declares itself present in the mask",
          len(empty_icon) == 2
          and _identity(empty_icon[1])[0] == 1
          and _identity(empty_icon[1])[3] == kaya.wire.VALUE_BLOB)
    _rewind(before)

    # ------------------------------------------------------------------
    # ASSETS (docs/assets-plan.md). The only tier that can assert the
    # asset path's RECORD-level claim headlessly: a VALUE_BLOB in the
    # slot with the mask bit set, INDISTINGUISHABLE from bytes the app
    # read itself, which is the point — the wire learns nothing about
    # assets (A3).
    font = kaya.asset("fonts/sora-wght.ttf")
    check("asset() opens the vendored font the build shipped",
          len(font) == 111400)
    check("and bytes() is the file, not a truncation",
          font.bytes()[:4] == b"\x00\x01\x00\x00" and len(font.bytes()) == 111400)
    # THE FILE-LIKE READER IS SUGAR OVER THOSE BYTES — no descriptor
    # anywhere. A partial read proves it is a real reader.
    reader = font.reader()
    check("and reader() is a real in-memory reader over them",
          reader.read(4) == b"\x00\x01\x00\x00" and reader.tell() == 4)

    before = len(kaya._tx)
    kaya.brand_typeface("Sora", font=font)
    rows = _typeface_records(kaya._tx[before:])
    check("brand_typeface(font=<asset>) sets bit 0 with a Blob in the slot",
          len(rows) == 1
          and _typeface(rows[0])[0] == 1
          and _typeface(rows[0])[3] == kaya.wire.VALUE_BLOB)
    check("and the family is still the app's word, never the file's",
          len(rows) == 1 and _typeface(rows[0])[1] == "Sora")
    _rewind(before)

    before = len(kaya._tx)
    kaya.app_identity("Aurora Notes", icon=kaya.asset("icons/kaya-mark.png"))
    rows = _identity_records(kaya._tx[before:])
    check("app_identity(icon=<asset>) sets bit 0 with a Blob in the slot",
          len(rows) == 1
          and _identity(rows[0])[0] == 1
          and _identity(rows[0])[3] == kaya.wire.VALUE_BLOB)
    _rewind(before)

    # THE THIRD CONSUMER: an image built from an asset, whose record has
    # to be the one bytes produce — same prop, same const source, same
    # Blob — because the wire learns nothing about assets.
    before = len(kaya._tx)
    with kaya.column():
        kaya.image(kaya.asset("icons/kaya-mark.png"))
    last = kaya._tx[before:][-1]
    check("image(<asset>) queues the same set_source bytes would",
          _rec_kind(last) == kaya.wire.TX_SET_PROPERTY
          and int.from_bytes(last[16:20], "little") == kaya.wire.PROP_SOURCE
          and int.from_bytes(last[20:24], "little") == kaya.wire.SOURCE_CONST
          and int.from_bytes(last[24:28], "little") == kaya.wire.VALUE_BLOB)
    _rewind(before)

    # THE WALLS, REFUSED IN THE CORE AND NOT HERE: this binding
    # contributes no prose of its own, so the check is that the core's
    # sentence ARRIVED.
    for what, name, fragment in (
        ("a name that escapes the root", "../Cargo.toml", "climbs out of the asset root"),
        ("an absolute path", "/etc/passwd", "is an absolute path"),
        ("the empty name", "", "names nothing"),
        ("a missing asset", "fonts/nope.ttf", "no asset named"),
    ):
        try:
            kaya.asset(name)
            check(f"asset() refuses {what}", False)
        except Exception as exc:  # noqa: BLE001 - the type is the binding's idiom
            check(f"asset() refuses {what}", fragment in str(exc))
    # AND THE MISS SENTENCE CARRIES THE CENSUS: a truncating buffer would
    # drop exactly this and leave a sentence that still looked right.
    try:
        kaya.asset("fonts/nope.ttf")
        census_ok = False
    except Exception as exc:  # noqa: BLE001
        census_ok = "the package carries" in str(exc) and \
            "fonts/sora-wght.ttf" in str(exc)
    check("and the miss names what the package DOES carry", census_ok)

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
        # THE NAME SPELLING IS THE SAME PROP, not a second surface.
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

        # THE CLOSED SET, where the other bindings have an enum. The
        # coercions matter: `role(True)` would read as 1, destructive.
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
    # halves as the role above; the PAIRINGS stay the root's.

    # THE CLASS IS HAND-WRITTEN AND THE CONSTANTS ARE GENERATED, so the
    # first clause is the census holding them together: without it Python
    # is silently the one binding that cannot say a new word, which is
    # how the window prop then spelled `list_detail` (now `panes`)
    # shipped unsayable here (invariant 2).
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
    # A census, not a spot check: the fan-out that grows `item` and
    # forgets `option` is invisible to a scene, which asserts only the
    # items it names.
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

    # THE NAME SPELLING IS THE SAME PROP, not a second surface.
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

    # THE CLOSED SET, where the other bindings have an enum. A bool is
    # excluded BEFORE int, which it subclasses: `symbol(True)` would
    # otherwise read as 1, the `add` glyph.
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
        # AND THE REFUSAL NAMES THE VOCABULARY: there is no enum here to
        # read it off.
        try:
            bad_item.symbol("save")
            named = False
        except ValueError as exc:
            named = all(f"'{n}'" in str(exc)
                        for n in sorted(kaya._SYMBOL_NAMES))
        check("and the refusal lists the whole vocabulary", named)

    # The section spelling refuses AT THE add_section CALL, not at the
    # `with`: a raise from __enter__ would point at the block instead of
    # at the word.
    before_bad = len(kaya._tx)
    try:
        app_style.add_section(4243, title="Nope", symbol="save")
        ok = False
    except ValueError as exc:
        ok = "must be one of" in str(exc)
    _rewind(before_bad)
    check("add_section refuses a bad symbol at the call, not at the with", ok)

# ---- a mutation costs the same at 32,000 entries as at 2,000 --------
#
# THE ONLY GUARD AVAILABLE IS A MEASUREMENT. The defect this replaces
# was a whole-model dict copy taken per mutation for the rollback
# journal (`_journal_instances` now takes it once per transaction):
# every insert was O(entries), so N inserts cost N²/2 and the
# transactions view's 15,000 rows cost 385ms of pure bookkeeping
# (docs/deferred.md, "the Python binding's insert is quadratic").
# Python has no compiler to refuse the eager copy the way Swift's
# `private` refuses its own bypass, and no deterministic observable
# distinguishes one snapshot from N — both leave ONE restore in the
# journal. So the clause measures per-row cost at two sizes 16x apart:
# quadratic shows up as growth (measured 9.7-12.6x with the old body
# spliced back in), linear as none (measured 0.97-1.01x). The bound has
# ~3x headroom on both sides, and the numbers print on every run so a
# red says what was measured.
BULK_SMALL = 2_000
BULK_LARGE = 32_000
BULK_GROWTH = 3.0


@dataclass
class Bulk:
    a: str


def _bulk_per_row_ms(n):
    """ms per insert into a fresh collection, the transaction abandoned.

    The rows are built BEFORE the clock starts: what is being timed is
    the binding's accumulation path, not Python's f-strings."""
    class _Stop(Exception):
        pass

    took = None
    try:
        with app.build():
            table = kaya.collection(Bulk).at()
            rows = [(f"k{i:07d}", Bulk(a=f"a{i}")) for i in range(n)]
            start = time.perf_counter()
            for key, value in rows:
                table.insert(key, value)
            took = time.perf_counter() - start
            raise _Stop()
    except _Stop:
        pass
    return took * 1000 / n


bulk_small = _bulk_per_row_ms(BULK_SMALL)
bulk_large = _bulk_per_row_ms(BULK_LARGE)
bulk_growth = bulk_large / bulk_small
print(f"bulk insert: {BULK_SMALL} rows {bulk_small:.5f} ms/row, "
      f"{BULK_LARGE} rows {bulk_large:.5f} ms/row, "
      f"growth {bulk_growth:.2f}x (bound {BULK_GROWTH}x)")
check(
    "an insert costs the same at 32,000 entries as at 2,000",
    bulk_growth < BULK_GROWTH,
)

# ---- the capability query ------------------------------------------
#
# crates/kaya/src/app.rs carries the canonical note. These clauses cover
# the two halves a bit test cannot: that the surface hands out NAMED
# BOOLEANS, and that the symbol being called is really kaya_capabilities
# rather than something that resolved to a zero. No transaction and no
# window needed.
caps = kaya.capabilities()

check("capabilities() answers with a Capabilities", isinstance(caps, kaya.Capabilities))

# NAMED BOOLEANS AND NOTHING ELSE. Asking the dataclass covers bits
# nobody has invented yet.
cap_fields = dataclasses.fields(kaya.Capabilities)
check("the capability surface says something at all", len(cap_fields) > 0)
check(
    "every capability is a named boolean",
    all(f.type in ("bool", bool) and isinstance(getattr(caps, f.name), bool)
        for f in cap_fields),
)

# FROZEN: a capability a guest can assign is a lie it told itself, and
# an app that "turned one on" sails straight into the core's wall.
try:
    caps.aux_windows = not caps.aux_windows
    frozen = False
except dataclasses.FrozenInstanceError:
    frozen = True
check("capabilities cannot be rewritten by the guest", frozen)

# THE DECODE, against the word the core actually handed over.
cap_bits = kaya.runtime.capability_bits()
check(
    "aux_windows is the core's own bit",
    caps.aux_windows == bool(cap_bits & kaya.runtime.CAP_AUX_WINDOWS),
)
# The clause a bit test cannot have: a symbol that resolved to something
# other than kaya_capabilities returns 0 and agrees with itself.
check("this desktop reports auxiliary windows", caps.aux_windows is True)

sys.exit(1 if failures else 0)
