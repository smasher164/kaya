"""The grow conformance scene, Python port — see guests/rust/grow.rs for
the full rationale. Every child of the column and of the row is a
grower, so each split is exactly weight/Σweight: 1,1,2 divide the
column 25/25/50 and the row's 1,3 divide its width 25/75. The harness
(KAYA_SELFTEST=grow) asserts both splits plus root-fills, byte-for-byte
against every other language and backend.

The `grow=` keyword is the declarative spelling; Widget.grow(weight) is
the dynamic path this scene has no reason to use.
"""

import sys

import kaya

app = kaya.App()

with app.window():
    probe = kaya.signal("grow probe")
    one = kaya.signal("one")

    with kaya.column():
        kaya.label(bind=probe, grow=1)  # label#0
        kaya.button("quarter", grow=1)
        with kaya.row(grow=2, spacing=12):
            kaya.label(bind=one, grow=1)  # label#1
            kaya.button("three", grow=3)

sys.exit(app.run())
