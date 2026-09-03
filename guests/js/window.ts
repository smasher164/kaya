// The window conformance scene (tools/scenes/window.steps).

import * as kaya from "kaya-gui";

const app = new kaya.App();

app.window({ title: "window probe", width: 640, height: 400 }, () => {
  const probe = kaya.signal("window probe");
  kaya.column(() => {
    kaya.label({ bind: probe }); // label#0
  });
});

app.run();
