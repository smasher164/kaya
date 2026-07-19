"""Tier-1 negative and bookkeeping checks: the mirror-read guard trips
in recording positions, mirrors track writes, derived signals recompute
and batch, and removing a parent entry purges descendant instance
mirrors. Runs against the real bindings; the core is never entered
(records queue, the process exits)."""

import sys

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

sys.exit(1 if failures else 0)
