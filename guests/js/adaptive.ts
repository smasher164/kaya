// The adaptive conformance scene (tools/scenes/adaptive.steps): row@dash
// flips by a HANDLER, row@narrow by the compact breakpoint.

import * as kaya from "kaya-gui";

const app = new kaya.App();

let vertical = false;
let dash!: kaya.Widget;

function flip(): void {
  vertical = !vertical;
  dash.axis(vertical ? "vertical" : "horizontal");
}

app.window({ title: "adaptive", width: 900, height: 600 }, () => {
  const alpha = kaya.signal("alpha");
  const longer = kaya.signal("a longer label");
  const steady = kaya.signal("steady");

  kaya.column(() => {
    dash = kaya.row(() => {
      // row#0: the flip subject.
      kaya.label({ bind: alpha }); // label#0
      kaya.label({ bind: longer }); // label#1
    });
    dash.a11yId("dash");
    // column#1: the control group, whose axis never moves.
    const steadyCol = kaya.column(() => {
      kaya.label({ bind: steady }); // label#2
    });
    steadyCol.a11yId("steady");
    kaya.button("flip", { onClick: flip }); // button#0
    // row#1: the BREAKPOINT subject; the handler never touches it.
    const narrow = kaya.row({ stackWhen: kaya.COMPACT }, () => {
      const one = kaya.signal("one");
      const two = kaya.signal("a wider two");
      kaya.label({ bind: one }); // label#3
      kaya.label({ bind: two }); // label#4
    });
    narrow.a11yId("narrow");
    // grid@sheet: three columns regular, one compact (D6.2).
    const sheet = kaya.grid(3, { columnsWhen: [kaya.COMPACT, 1] }, () => {
      for (const text of ["c1", "c2", "c3", "c4", "c5", "c6"]) {
        kaya.label({ bind: kaya.signal(text) }); // label#5..#10
      }
    });
    sheet.a11yId("sheet");
  });
});

app.run();
