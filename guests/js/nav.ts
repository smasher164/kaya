// The nav conformance scene (tools/scenes/nav.steps): a programmatic
// popEntry does NOT echo entry_popped.

import * as kaya from "kaya-gui";

const app = new kaya.App();

const DETAIL = 7;
const SETTINGS = 8;

function poppedDetail(): void {
  status.set("popped detail");
}

function backAskedSettings(): void {
  // Nothing has popped, and no entry_popped will follow.
  status.set("back requested");
  kaya.popEntry();
}

function openDetail(): void {
  // The push NESTS in the handler's transaction: one commit.
  app.pushEntry(DETAIL, { title: "detail", onPopped: poppedDetail }, () => {
    const caption = kaya.signal("detail pane");
    kaya.column(() => {
      kaya.label({ bind: caption });
    });
  });
  status.set("pushed detail");
}

function openSettings(): void {
  app.pushEntry(SETTINGS, { title: "settings", interceptBack: true, onBack: backAskedSettings }, () => {
    const caption = kaya.signal("settings pane");
    kaya.column(() => {
      kaya.label({ bind: caption });
    });
  });
  status.set("pushed settings");
}

let status!: kaya.Signal<string>;

app.window({ title: "nav" }, () => {
  status = kaya.signal("at root");
  kaya.column(() => {
    kaya.label({ bind: status }); // label#0
    kaya.button("open detail", { onClick: openDetail }); // button#0
    kaya.button("open settings", { onClick: openSettings }); // button#1
  });
});

app.run();
