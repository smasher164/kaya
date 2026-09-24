// The formatter door and the catalog (tools/scenes/format.steps,
// docs/compliance-plan.md §6): fixed inputs through every fmt call and
// two catalog messages, asserted against what THIS platform's formatter
// writes and against the catalog's own bytes.

import * as kaya from "kaya-gui";

const app = new kaya.App();
kaya.catalog("format");
const d: kaya.CivilDate = { year: 2026, month: 9, day: 7 };
const t: kaya.CivilTime = { hour: 8, minute: 30 };

// Fourteen labels and a row: taller than the default window, which GTK
// would otherwise let the root overflow (expect_root_fills).
app.window({ title: "format", width: 540, height: 560 }, () => {
  kaya.column(() => {
    kaya.label({ bind: kaya.signal(kaya.fmt.date(d, "short")) }); // label#0
    kaya.label({ bind: kaya.signal(kaya.fmt.date(d, "medium")) }); // label#1
    kaya.label({ bind: kaya.signal(kaya.fmt.date(d, "long")) }); // label#2
    kaya.label({ bind: kaya.signal(kaya.fmt.time(t, "short")) }); // label#3
    kaya.label({ bind: kaya.signal(kaya.fmt.dateTime(d, t, "medium")) }); // label#4
    kaya.label({ bind: kaya.signal(kaya.fmt.number(1234567.891)) }); // label#5
    kaya.label({ bind: kaya.signal(kaya.fmt.percent(0.256)) }); // label#6
    kaya.label({ bind: kaya.signal(kaya.fmt.currency(1234567.89, "USD")) }); // label#7
    kaya.label({ bind: kaya.signal(kaya.tr("items", { count: 1 })) }); // label#8
    kaya.label({ bind: kaya.signal(kaya.tr("items", { count: 3 })) }); // label#9
    kaya.label({ bind: kaya.signal(kaya.tr("greeting", { name: "Ada" })) }); // label#10
    kaya.row(() => {
      // row#0
      kaya.label({ bind: kaya.signal("first") }); // label#11
      kaya.spacer();
      kaya.label({ bind: kaya.signal("last") }); // label#12
    });
    kaya.label({ bind: kaya.signal(kaya.fmt.locale().tag) }); // label#13
  });
});

app.run();
