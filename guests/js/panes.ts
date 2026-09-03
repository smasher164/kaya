// The panes scene (tools/scenes/panes.steps): nothing here is
// panes-specific except `panes: 3`, asked for ONCE.

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
    // Authored ids: an index read passes for an empty arm.
    kaya.label({ bind: caption }).a11yId("root"); // label#0
    kaya.button("open content", { onClick: openContent }); // button#0
  });
});

app.run();
