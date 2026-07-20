"""The layout scene, Python port — the native-default observation
vehicle; see guests/rust/layout.rs for the axes it stresses. The two
label expects (KAYA_SELFTEST=layout) only prove the tree built; the
scene asserts no geometry — it has two columns and three rows, and
container targets index by creation order, which legitimately differs
per language. The grow contract is asserted in the grow scene instead.
"""

import sys

import kaya

app = kaya.App()

with app.window():
    probe = kaya.signal("Layout probe")
    tail = kaya.signal("tail")
    mixed = kaya.signal("mixed")
    nested = kaya.signal("nested")
    deep = kaya.signal("deep")

    with kaya.column():
        kaya.label(bind=probe)  # label#0

        # Main-axis free space: three unequal children with leftover
        # room.
        with kaya.row():
            kaya.button("A")
            kaya.button("longer")
            kaya.label(bind=tail)  # label#1

        # Cross-axis alignment: three different intrinsic heights, one
        # grower filling the leftover row width.
        with kaya.row():
            kaya.checkbox("check")
            kaya.label(bind=mixed)  # label#2
            kaya.slider(value=0.5, min=0.0, max=1.0, grow=1)

        # Proportional grow: two growers of unequal weight in one row.
        with kaya.row():
            kaya.slider(value=0.25, min=0.0, max=1.0, grow=1)
            kaya.slider(value=0.75, min=0.0, max=1.0, grow=3)

        # Nesting: a column inside the root column, a row inside that.
        with kaya.column():
            kaya.label(bind=nested)  # label#3
            with kaya.row():
                kaya.label(bind=deep)  # label#4
                kaya.button("x")

sys.exit(app.run())
