// The scroll conformance scene (tools/scenes/scroll.steps). The viewport
// GROWS: unconstrained it hugs its content and nothing overflows.

import * as kaya from "kaya-gui";

const app = new kaya.App();

function bottomClicked(): void {
  status.set("bottom clicked");
}

function lastCardClicked(): void {
  status.set("last card clicked");
}

const { status } = app.window({ title: "scroll" }, () => {
  const status = kaya.signal("at top");
  kaya.column(() => {
    kaya.label({ bind: status }); // label#0
    kaya.scroll({ grow: 1 }, (rows) => {
      rows.a11yId("rows");
      kaya.column(() => {
        for (let i = 1; i < 30; i++) {
          kaya.label({ bind: kaya.signal(`row ${i}`) });
        }
        kaya.button("bottom", { onClick: bottomClicked }); // button#0
      });
    });
    // A strip wider than the window, scrolled sideways
    // (docs/hscroll-plan.md), addressed as scroll@strip.
    kaya.scroll({ axis: kaya.Axis.HORIZONTAL }, (strip) => {
      strip.a11yId("strip");
      kaya.row(() => {
        for (let i = 1; i < 20; i++) {
          kaya.label({ bind: kaya.signal(`card ${i}`) });
        }
        kaya.button("last card", { onClick: lastCardClicked }).a11yId("last");
      });
    });
  });
  return { status };
});

app.run();
