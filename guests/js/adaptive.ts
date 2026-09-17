// The adaptive conformance scene (tools/scenes/adaptive.steps): row@dash
// flips by a HANDLER, row@narrow by the compact breakpoint.

import * as kaya from "kaya-gui";

const app = new kaya.App();

let vertical = false;

function flip(): void {
  vertical = !vertical;
  dash.axis(vertical ? "vertical" : "horizontal");
}

const { dash } = app.window({ title: "adaptive", width: 900, height: 600 }, () => {
  const alpha = kaya.signal("alpha");
  const longer = kaya.signal("a longer label");
  const steady = kaya.signal("steady");

  const dash = kaya.column(() => {
    const dash = kaya.row((dash) => {
      // row#0: the flip subject.
      dash.a11yId("dash");
      kaya.label({ bind: alpha }); // label#0
      kaya.label({ bind: longer }); // label#1
      return dash;
    });
    // column#1: the control group, whose axis never moves.
    kaya.column((steadyCol) => {
      steadyCol.a11yId("steady");
      kaya.label({ bind: steady }); // label#2
    });
    kaya.button("flip", { onClick: flip }); // button#0
    // row#1: the BREAKPOINT subject; the handler never touches it.
    kaya.row({ stackWhen: kaya.COMPACT }, (narrow) => {
      narrow.a11yId("narrow");
      const one = kaya.signal("one");
      const two = kaya.signal("a wider two");
      kaya.label({ bind: one }); // label#3
      kaya.label({ bind: two }); // label#4
    });
    // grid@sheet: three columns regular, one compact (D6.2).
    kaya.grid(3, { columnsWhen: [kaya.COMPACT, 1] }, (sheet) => {
      sheet.a11yId("sheet");
      for (const text of ["c1", "c2", "c3", "c4", "c5", "c6"]) {
        kaya.label({ bind: kaya.signal(text) }); // label#5..#10
      }
    });
    // grid@fit: no count, a 240-point floor, the WIDTH decides
    // (docs/layout-knobs-plan.md §3). Buttons, so label ordinals above
    // stay put.
    kaya.grid(3, (fit) => {
      fit.columnsAuto(240).a11yId("fit");
      kaya.button("f1"); // button#1
      kaya.button("f2");
      kaya.button("f3");
    });
    return dash;
  });
  return { dash };
});

app.run();
