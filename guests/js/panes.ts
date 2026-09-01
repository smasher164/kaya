// The panes conformance scene, JS port — a THREE-pane ceiling as
// assertions (docs/multicolumn-plan.md D1/D5).
//
// Nothing here is panes-specific except `panes: 3`, asked for ONCE — the
// stack is the ordinary navigation stack, and how many of the three fit is
// the platform's re-decision at every width. See guests/rust/panes.rs and
// tools/scenes/panes.steps.

import * as kaya from "kaya-gui";

const app = new kaya.App();

const CONTENT = 7;
const DETAIL = 8;

function openDetail(): void {
  app.pushEntry(DETAIL, { title: "detail" }, () => {
    const caption = kaya.signal("detail pane");
    kaya.column(() => {
      kaya.label({ bind: caption }).a11yId("detail"); // label#last
    });
  });
}

function openContent(): void {
  app.pushEntry(CONTENT, { title: "content" }, () => {
    const caption = kaya.signal("content pane");
    kaya.column(() => {
      kaya.label({ bind: caption }).a11yId("content"); // label#1
      kaya.button("open detail", { onClick: openDetail }); // button#1
    });
  });
}

app.window({ title: "panes", panes: 3 }, () => {
  const caption = kaya.signal("root pane");
  kaya.column(() => {
    // Authored ids so the REAL-TREE read can address these:
    // `expect_ax label#N` reads the platform's own tree, where the
    // model reads above pass for an arm that ran and drew nothing.
    kaya.label({ bind: caption }).a11yId("root"); // label#0
    kaya.button("open content", { onClick: openContent }); // button#0
  });
});

app.run();
