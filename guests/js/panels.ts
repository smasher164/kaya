// The panels conformance scene (tools/scenes/panels.steps).

import * as kaya from "kaya-gui";

const app = new kaya.App();

let status!: kaya.Signal<string>;

app.window({ title: "panels" }, () => {
  status = kaya.signal("two panels");
  kaya.column(() => {
    kaya.label({ bind: status }); // label#0
  });
});

const INSPECTOR = 1;

function closeAsked(): void {
  // Bound at the inspector's declaration: only THIS window's close.
  status.set("close requested");
  kaya.destroyWindow(INSPECTOR);
}

app.createWindow(INSPECTOR, { title: "inspector", width: 480, height: 320, vetoClose: true, onCloseRequested: closeAsked }, () => {
  const caption = kaya.signal("inspector pane");
  kaya.column(() => {
    kaya.label({ bind: caption }); // label#1
  });
});

app.run();
