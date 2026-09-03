// The split scene, driven by TWO scripts (tools/scenes/split.steps and
// listdetail.steps): the presentation is asked for ONCE and never again.

import * as kaya from "kaya-gui";

const app = new kaya.App();

const DETAIL = 7;

function poppedDetail(): void {
  // Retention: the base root took this write while the detail was up.
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
    // Authored ids: an index read passes for an empty arm.
    kaya.label({ bind: status }).a11yId("list"); // label#0
    kaya.button("open detail", { onClick: openDetail }); // button#0
  });
});

app.run();
