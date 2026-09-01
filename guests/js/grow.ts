// The grow conformance scene, JS port — see guests/rust/grow.rs for
// the full rationale. Every child of the column and of the row is a
// grower, so each split is exactly weight/Σweight: 1,2,1 divide the
// column 25/50/25 and the row's 1,3 divide its width 25/75. The harness
// (KAYA_SELFTEST=grow) asserts both splits, root-fills, and that the
// textarea TAKES the track its weight earned, byte-for-byte against every
// other language and backend.

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
