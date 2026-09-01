// The split conformance scene, JS port — adaptive panes as
// assertions (DESIGN.md; docs/multicolumn-plan.md).
//
// The guest asks for the presentation ONCE — `panes: 2` on the window —
// and does nothing adaptive after that; the platform re-decides as the
// size class changes, and there is no prop for WHICH entries present. The
// stack is the ordinary navigation stack: nothing here is split-specific
// except that one prop.
//
// TWO scripts drive this ONE app: `split` resizes and names the
// presentation on each side, `listdetail` asserts the bare invariant at
// whatever width its host gives. See guests/rust/split.rs,
// tools/scenes/split.steps and tools/scenes/listdetail.steps.

import * as kaya from "kaya-gui";

const app = new kaya.App();

const DETAIL = 7;

function poppedDetail(): void {
  // Retention: the base root took this write while the detail was up,
  // on a regular window where it was VISIBLE the whole time.
  status.set("popped detail");
}

function openDetail(): void {
  app.pushEntry(DETAIL, { title: "detail", onPopped: poppedDetail }, () => {
    const caption = kaya.signal("detail pane");
    kaya.column(() => {
      kaya.label({ bind: caption }).a11yId("detail");
    });
  });
}

let status!: kaya.Signal<string>;

app.window({ title: "split", panes: 2 }, () => {
  status = kaya.signal("list pane");
  kaya.column(() => {
    // Authored ids so the REAL-TREE read can address these:
    // `expect label#N` reads kaya's own model and passes whether or
    // not anything reached the screen — the gap that let a
    // non-rendering split arm look green.
    kaya.label({ bind: status }).a11yId("list"); // label#0
    kaya.button("open detail", { onClick: openDetail }); // button#0
  });
});

app.run();
