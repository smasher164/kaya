// The styling conformance scene (tools/scenes/styling.steps): brand accent,
// role tier, window inset. `Role.HEADING` is the one role a lane can read.

import * as kaya from "kaya-gui";

const app = new kaya.App();

let status!: kaya.Signal<string>;

function onDelete(): void {
  status.set("deleted");
}

function onSave(): void {
  status.set("saved");
}

app.window({ title: "styling", width: 480, height: 360, inset: 0 }, () => {
  // BEFORE THE FIRST MOUNT: the scope mounts on exit.
  kaya.brandAccent(0x3584e4);
  const heading = kaya.signal("Sections");
  status = kaya.signal("ready");
  kaya.column(() => {
    // expect_ax resolves a target through its AUTHORED id.
    kaya.heading({ bind: heading }).a11yId("title"); // label#0
    kaya.label({ bind: status }); // label#1
    kaya.button("Delete", { onClick: onDelete }).role(kaya.Role.DESTRUCTIVE).a11yId("delete"); // button#0
    kaya.button("Save", { onClick: onSave }).role(kaya.Role.PROMINENT).a11yId("save"); // button#1
    // Declared so every backend's caption arm runs: no AX observable.
    kaya.caption("captioned"); // label#2
  });
});

app.run();
