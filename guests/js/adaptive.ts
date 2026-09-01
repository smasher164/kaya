// The adaptive conformance scene, JS port — see guests/rust/adaptive.rs
// for the full rationale. row@dash flips by a HANDLER (D2's user-driven
// toggle); row@narrow carries the ONE-KEYWORD breakpoint (D3, size
// classes ruled 2026-08-31): `stackWhen: kaya.COMPACT` stacks it
// vertically while the window's size class is compact (below 600 points
// on every desktop) and reverts on leaving the class. The harness
// (KAYA_SELFTEST=adaptive) reads the RENDERED axis both sides of the
// threshold, byte-for-byte against every other language.

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
    // column#1: the control group — its axis answers the creation
    // kind's own and never moves.
    const steadyCol = kaya.column(() => {
      kaya.label({ bind: steady }); // label#2
    });
    steadyCol.a11yId("steady");
    kaya.button("flip", { onClick: flip }); // button#0
    // row#1: the BREAKPOINT subject (D3) — the handler never
    // touches it.
    const narrow = kaya.row({ stackWhen: kaya.COMPACT }, () => {
      const one = kaya.signal("one");
      const two = kaya.signal("a wider two");
      kaya.label({ bind: one }); // label#3
      kaya.label({ bind: two }); // label#4
    });
    narrow.a11yId("narrow");
  });
});

app.run();
