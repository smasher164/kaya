// The align conformance scene (tools/scenes/align.steps). The tall image
// has no baseline: its bottom sits ON the text baseline.

import * as kaya from "kaya-gui";

// A 100x20 PNG: exact pixel widths, so row@wrapped breaks onto two lines
// in every lane's window (docs/layout-knobs-plan.md §2).
const WIDE_PNG = new Uint8Array([
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68,
  82, 0, 0, 0, 100, 0, 0, 0, 20, 8, 2, 0, 0, 0, 244,
  162, 15, 194, 0, 0, 0, 56, 73, 68, 65, 84, 120, 218, 237, 208,
  1, 13, 0, 0, 8, 3, 160, 7, 177, 164, 109, 141, 99, 133, 7,
  96, 35, 1, 153, 61, 74, 81, 32, 75, 150, 44, 89, 178, 100, 41,
  144, 37, 75, 150, 44, 89, 178, 20, 200, 146, 37, 75, 150, 44, 89,
  10, 122, 15, 34, 121, 229, 167, 65, 55, 75, 87, 0, 0, 0, 0,
  73, 69, 78, 68, 174, 66, 96, 130,
]);

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
  const plain = kaya.signal("plain probe");

  const root = kaya.column({ align: "stretch" }, () => {
    const centered = kaya.column({ align: "center" }, () => {
      kaya.label({ bind: probe }); // label#0
      kaya.button("mid");
      const baseline = kaya.row({ align: "baseline" }, () => {
        // the baseline trio
        kaya.label({ bind: base }); // label#1
        kaya.button("tick");
        kaya.image(TALL_PNG);
      });
      baseline.a11yId("baseline");
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
    // row@plain: NO align, so the core's centre default is what the scene
    // reads
    const plainRow = kaya.row(() => {
      kaya.label({ bind: plain }).a11yId("plainlabel"); // label#4
      kaya.image(TALL_PNG);
    });
    plainRow.a11yId("plain");
    // column@knobs: NO align; fill opts one child out of its default and
    // one in
    const knobs = kaya.column(() => {
      kaya.textarea().fill(false).a11yId("optout");
      kaya.button("fills").fill(true).a11yId("fills");
      // row@wrapped: six exact-width images flow onto two lines
      const wrapped = kaya.row(() => {
        for (let i = 0; i < 6; i++) kaya.image(WIDE_PNG);
      });
      wrapped.wrap(true).a11yId("wrapped");
    });
    knobs.a11yId("knobs");
  });
  root.a11yId("root");
});

app.run();
