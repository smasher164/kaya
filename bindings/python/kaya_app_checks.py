"""Tier-1 negative and bookkeeping checks: the mirror-read guard trips
in recording positions, mirrors track writes, derived signals recompute
and batch, and removing a parent entry purges descendant instance
mirrors. Runs against the real bindings; the core is never entered
(records queue, the process exits)."""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import kaya_app as kaya

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

sys.exit(1 if failures else 0)
