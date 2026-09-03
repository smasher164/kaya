// The grid conformance scene (tools/scenes/grid.steps).

import * as kaya from "kaya-gui";

const app = new kaya.App();

app.window({ title: "grid" }, () => {
  kaya.column(() => {
    kaya.grid(2, () => {
      kaya.label("Name:"); // label#0
      kaya.label("Ada Lovelace"); // label#1
      kaya.label("Role:"); // label#2
      kaya.label("Engine programmer"); // label#3
    });
    kaya.row({ grow: 1 }, () => {
      kaya.button("left"); // button#0
      kaya.spacer();
      kaya.button("right"); // button#1
    });
  });
});

app.run();
