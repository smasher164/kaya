// The search scene (tools/scenes/search.steps): a search field filtering a
// list on every keystroke, the app owning the filter (docs/search-plan.md
// S9) — the visible set is a diff of removes and inserts by key.
//     KAYA_SELFTEST=search node guests/js/search.ts

import * as kaya from "kaya-gui";

const Item = kaya.record({ name: String }, "Item");

const ITEMS = ["apple", "banana", "cherry", "mango"];

const app = new kaya.App();

let visible: string[] = [...ITEMS];

function onQuery(text: string): void {
  const query = text.toLowerCase();
  const wanted = ITEMS.filter((name) => name.includes(query));
  // A DIFF, never clear-and-refill: only the rows whose membership changed
  // move (docs/search-plan.md S9).
  for (const name of visible) if (!wanted.includes(name)) items.remove(name);
  for (const name of wanted) if (!visible.includes(name)) items.insert(name, Item({ name }));
  // Insertion order is arrival order, so a row coming back lands last;
  // walking the wanted keys to the end in order puts the list back in ITEMS
  // order.
  for (const name of wanted) items.moveToEnd(name);
  count.set(query === "" ? `${ITEMS.length} items` : `${wanted.length} of ${ITEMS.length} match`);
  visible = wanted;
}

let items!: kaya.Collection<kaya.Fields<typeof Item.schema>, kaya.Row<typeof Item.schema>>;
let count!: kaya.Signal<string>;

app.window(() => {
  items = kaya.collection(Item);
  count = kaya.signal(`${ITEMS.length} items`);

  kaya.column(() => {
    kaya.search({ placeholder: "Search", onChange: onQuery }).a11yId("find").a11yLabel("Find items");
    kaya.label({ bind: count }).a11yId("count");
    // The For IS the list: expect_order reads its label children.
    for (const item of items.rows({ a11yId: "list" })) {
      kaya.label({ bind: item.name });
    }
  });

  for (const name of ITEMS) items.insert(name, Item({ name }));
});

app.run();
