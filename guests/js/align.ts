// The align conformance scene (tools/scenes/align.steps). The tall image
// has no baseline: its bottom sits ON the text baseline.

import * as kaya from "kaya-gui";

const TALL_PNG = new Uint8Array([
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68,
  82, 0, 0, 0, 2, 0, 0, 0, 64, 8, 2, 0, 0, 0, 191,
  68, 49, 20, 0, 0, 0, 18, 73, 68, 65, 84, 120, 156, 99, 8,
  8, 138, 2, 34, 134, 81, 106, 104, 82, 0, 67, 50, 126, 1, 49,
  1, 65, 124, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
]);

const app = new kaya.App();

app.window(() => {
  const probe = kaya.signal("align probe");
  const base = kaya.signal("base");
  const anchor = kaya.signal("anchor");
  const fit = kaya.signal("fit");

  const root = kaya.column({ align: "stretch" }, () => {
    const centered = kaya.column({ align: "center" }, () => {
      kaya.label({ bind: probe }); // label#0
      kaya.button("mid");
      kaya.row({ align: "baseline" }, () => {
        // row#0: the baseline trio
        kaya.label({ bind: base }); // label#1
        kaya.button("tick");
        kaya.image(TALL_PNG);
      });
    });
    centered.a11yId("centered");
    kaya.row(() => {
      // row#1: the stretch pair's host
      kaya.label({ bind: anchor }); // label#2
      const fitcol = kaya.column({ grow: 1, align: "stretch" }, () => {
        kaya.label({ bind: fit }); // label#3
        kaya.button("wide");
      });
      fitcol.a11yId("fitcol");
    });
  });
  root.a11yId("root");
});

app.run();
