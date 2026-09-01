// The panels conformance scene, JS port — the north-star
// spelling for the auxiliary-window grammar: the inspector is one
// `createWindow` scope, its veto class one handler. See
// guests/rust/panels.rs and tools/scenes/panels.steps.

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
  // Bound to the inspector at its declaration, so it can only ever mean
  // THIS window's close was vetoed.
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
