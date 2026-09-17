// The scroll conformance scene (tools/scenes/scroll.steps). The viewport
// GROWS: unconstrained it hugs its content and nothing overflows.

import * as kaya from "kaya-gui";

const app = new kaya.App();

function bottomClicked(): void {
  status.set("bottom clicked");
}

const { status } = app.window({ title: "scroll" }, () => {
  const status = kaya.signal("at top");
  kaya.column(() => {
    kaya.label({ bind: status }); // label#0
    kaya.scroll({ grow: 1 }, () => {
      // scroll#0
      kaya.column(() => {
        for (let i = 1; i < 30; i++) {
          kaya.label({ bind: kaya.signal(`row ${i}`) });
        }
        kaya.button("bottom", { onClick: bottomClicked }); // button#0
      });
    });
  });
  return { status };
});

app.run();
