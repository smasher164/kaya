// The progress conformance scene, JS port. See guests/rust/progress.rs
// and tools/scenes/progress.steps.

import * as kaya from "kaya-gui";

const app = new kaya.App();

app.window({ title: "progress" }, () => {
  kaya.column(() => {
    kaya.progress({ value: 0.25 }); // progress#0
    kaya.progress({ indeterminate: true }); // progress#1
  });
});

app.run();
