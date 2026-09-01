// The reorder scene: order as collection data, end to end. Each handler
// repositions an entry BY KEY and never touches a widget, and expect_order
// reads the toolkit's actual child order back.
//
// THE ROOT IS A ROW so the For's container is the scene's only
// column-kind widget: languages disagree on whether containers are created
// before or after their children, and column#0 must name the same widget
// everywhere.
//
// Build the library first (cargo build), then:
//     KAYA_SELFTEST=reorder node guests/js/reorder.ts

import * as kaya from "kaya-gui";

const Item = kaya.record({ title: String }, "Item");

const app = new kaya.App();

function onRotate(): void {
  // The MODEL owns the order, so the handler asks it which key is
  // first; it never counts widgets.
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
