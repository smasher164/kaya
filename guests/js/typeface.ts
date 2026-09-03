// The typeface conformance scene (tools/scenes/typeface.steps): the FAMILY
// swaps and the scene names NO SIZE anywhere.

import * as kaya from "kaya-gui";

const app = new kaya.App();

let draft = "";

function onChange(text: string): void {
  draft = text;
}

function onGo(): void {
  status.set(`clicked ${draft}`);
}

let status!: kaya.Signal<string>;

app.window({ title: "typeface", width: 480, height: 360 }, () => {
  // BEFORE THE FIRST MOUNT: the scope mounts on exit.
  const font = kaya.asset("fonts/sora-wght.ttf");
  kaya.brandTypeface("Sora", { font });
  font.close();
  const heading = kaya.signal("typeface");
  status = kaya.signal("ready");
  kaya.column(() => {
    // A heading OVERRIDES the root font: a root-only lowering shows here.
    kaya.label({ bind: heading }).role(kaya.Role.HEADING).a11yId("title"); // label#0
    kaya.label({ bind: status }); // label#1
    // Two DIFFERENT routes: one alone cannot see a half-applied swap.
    kaya.entry({ onChange }); // entry#0
    kaya.textarea(); // textarea#0
    kaya.button("Go", { onClick: onGo }); // button#0
  });
});

app.run();
