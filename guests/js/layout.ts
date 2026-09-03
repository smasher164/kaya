// The layout scene (tools/scenes/layout.steps). It asserts NO geometry:
// container targets are ordinal, and that differs per language.

import * as kaya from "kaya-gui";

const app = new kaya.App();

app.window(() => {
  const probe = kaya.signal("Layout probe");
  const tail = kaya.signal("tail");
  const mixed = kaya.signal("mixed");
  const nested = kaya.signal("nested");
  const deep = kaya.signal("deep");

  kaya.column(() => {
    kaya.label({ bind: probe }); // label#0

    kaya.row(() => {
      kaya.button("A");
      kaya.button("longer");
      kaya.label({ bind: tail }); // label#1
    });

    kaya.row(() => {
      kaya.checkbox("check");
      kaya.label({ bind: mixed }); // label#2
      kaya.slider({ value: 0.5, min: 0, max: 1, grow: 1 });
    });

    kaya.row(() => {
      kaya.slider({ value: 0.25, min: 0, max: 1, grow: 1 });
      kaya.slider({ value: 0.75, min: 0, max: 1, grow: 3 });
    });

    kaya.column(() => {
      kaya.label({ bind: nested }); // label#3
      kaya.row(() => {
        kaya.label({ bind: deep }); // label#4
        kaya.button("x");
      });
    });
  });
});

app.run();
