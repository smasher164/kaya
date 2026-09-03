// The radio conformance scene (tools/scenes/radio.steps).

import * as kaya from "kaya-gui";

const OPTIONS = ["Small", "Medium", "Large"];

const app = new kaya.App();

function onSelect(index: number): void {
  size.set(`size: ${OPTIONS[index]}`);
}

let size!: kaya.Signal<string>;

app.window({ title: "radio" }, () => {
  size = kaya.signal("size: Small");
  kaya.column(() => {
    kaya.radio(OPTIONS, { selected: 0, onSelect });
    kaya.label({ bind: size });
  });
});

app.run();
