// The window conformance scene, JS port — see guests/rust/window.rs
// and tools/scenes/window.steps. The north-star spelling from DESIGN.md's
// appendix, live: the surface's props ride the window() scope itself.

import * as kaya from "kaya-gui";

const app = new kaya.App();

app.window({ title: "window probe", width: 640, height: 400 }, () => {
  const probe = kaya.signal("window probe");
  kaya.column(() => {
    kaya.label({ bind: probe }); // label#0
  });
});

app.run();
