"""The formatter door and the catalog (tools/scenes/format.steps,
docs/compliance-plan.md §6): fixed inputs through every fmt call and two
catalog messages, asserted against what THIS platform's formatter writes
and against the catalog's own bytes."""

import datetime
import sys

import kaya

app = kaya.App()
kaya.catalog("format")
d = datetime.date(2026, 9, 7)
t = datetime.time(8, 30)

# Fourteen labels and a row: taller than the default window, which GTK
# would otherwise let the root overflow (expect_root_fills).
with app.window(title="format", width=540, height=560):
    with kaya.column():
        kaya.label(bind=kaya.signal(kaya.fmt.date(d, length="short")))  # label#0
        kaya.label(bind=kaya.signal(kaya.fmt.date(d, length="medium")))  # label#1
        kaya.label(bind=kaya.signal(kaya.fmt.date(d, length="long")))  # label#2
        kaya.label(bind=kaya.signal(kaya.fmt.time(t, length="short")))  # label#3
        kaya.label(bind=kaya.signal(kaya.fmt.date_time(d, t, length="medium")))  # label#4
        kaya.label(bind=kaya.signal(kaya.fmt.number(1234567.891)))  # label#5
        kaya.label(bind=kaya.signal(kaya.fmt.percent(0.256)))  # label#6
        kaya.label(bind=kaya.signal(kaya.fmt.currency(1234567.89, "USD")))  # label#7
        kaya.label(bind=kaya.signal(kaya.tr("items", count=1)))  # label#8
        kaya.label(bind=kaya.signal(kaya.tr("items", count=3)))  # label#9
        kaya.label(bind=kaya.signal(kaya.tr("greeting", name="Ada")))  # label#10
        with kaya.row():  # row#0
            kaya.label(bind=kaya.signal("first"))  # label#11
            kaya.spacer()
            kaya.label(bind=kaya.signal("last"))  # label#12
        kaya.label(bind=kaya.signal(kaya.fmt.locale().tag))  # label#13

sys.exit(app.run())
