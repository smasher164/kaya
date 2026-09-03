// The grow conformance scene (tools/scenes/grow.steps). EVERY CHILD IS A
// GROWER, or the split is no longer weight/Σweight.

import * as kaya from "kaya-gui";

const app = new kaya.App();

app.window(() => {
  const probe = kaya.signal("grow probe");
  const one = kaya.signal("one");

  kaya.column(() => {
    kaya.label({ bind: probe, grow: 1 }); // label#0
    kaya.textarea({ grow: 2 }); // textarea#0
    kaya.row({ grow: 1, spacing: 12 }, () => {
      kaya.label({ bind: one, grow: 1 }); // label#1
      kaya.button("three", { grow: 3 });
    });
  });
});

app.run();
