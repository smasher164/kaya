// The select conformance scene (tools/scenes/select.steps).

import * as kaya from "kaya-gui";

const OPTIONS = ["Red", "Green", "Blue"];

const app = new kaya.App();

function onSelect(index: number): void {
  picked.set(`picked: ${OPTIONS[index]}`);
}

let picked!: kaya.Signal<string>;

app.window({ title: "select" }, () => {
  picked = kaya.signal("picked: Red");
  kaya.column(() => {
    kaya.select(OPTIONS, { selected: 0, onSelect });
    kaya.label({ bind: picked });
  });
});

app.run();
