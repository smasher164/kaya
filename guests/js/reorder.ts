// The reorder scene: THE ROOT IS A ROW, so column#0 names one widget.
//     KAYA_SELFTEST=reorder node guests/js/reorder.ts

import * as kaya from "kaya-gui";

const Item = kaya.record({ title: String }, "Item");

const app = new kaya.App();

function onRotate(): void {
  const first = items.keys()[0]!;
  items.moveToEnd(first);
}

function onLift(): void {
  items.moveToFront(items.keys().at(-1)!);
}

let items!: kaya.Collection<kaya.Fields<typeof Item.schema>, kaya.Row<typeof Item.schema>>;

app.window(() => {
  items = kaya.collection(Item);
  kaya.row(() => {
    kaya.button("rotate", { onClick: onRotate });
    kaya.button("lift", { onClick: onLift });
    for (const item of items) {
      kaya.label({ bind: item.title });
    }
  });
  for (const key of ["a", "b", "c"]) {
    items.insert(key, Item({ title: key }));
  }
});

app.run();
