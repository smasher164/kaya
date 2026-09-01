// The table scene: column headers and click-to-sort on the For
// vocabulary (docs/tables-plan.md). A header click is a REQUEST — this
// guest reorders its collection BY KEY (the reorder scene's idiom) and
// re-declares the header with the new indicator; the platform sorts
// nothing. The byte-frozen contract is tools/scenes/table.steps.
//
// Build the library first (cargo build), then:
//     KAYA_SELFTEST=table node guests/js/table.ts

import * as kaya from "kaya-gui";

const Item = kaya.record({ name: String, size: String }, "Item");
type ItemFields = kaya.Fields<typeof Item.schema>;

const app = new kaya.App();

// The guest's sort policy — the platform never has one: clicking the
// sorted column flips it, clicking another starts ascending.
let sorted: [number, boolean] | null = null;

function onSort(column: number): void {
  const current = sorted;
  const descending = current !== null && current[0] === column && !current[1];
  sorted = [column, descending];
  const entries = items.items();
  const keyOf = column === 0 ? (e: [kaya.Key, ItemFields]) => e[1].name : (e: [kaya.Key, ItemFields]) => e[1].size;
  entries.sort((a, b) => {
    const x = keyOf(a);
    const y = keyOf(b);
    const order = x < y ? -1 : x > y ? 1 : 0;
    return descending ? -order : order;
  });
  // Keys, never indices: moving each key to the end in the target
  // order leaves the collection sorted.
  for (const [key] of entries) {
    items.moveToEnd(key);
  }
  const indicator = descending ? kaya.Sort.desc(column) : kaya.Sort.asc(column);
  items.setColumns(["Name", "Size"], { sort: indicator });
}

let items!: kaya.Collection<ItemFields, kaya.Row<typeof Item.schema>>;

app.window(() => {
  items = kaya.collection(Item);
  // The root is a row so the For's container is the scene's only
  // column-kind widget (the reorder scene's rule). The table IS the
  // For, with headers on the same loop that stamps the rows.
  kaya.row(() => {
    // Grown on purpose: this scene asserts the fill-and-scroll
    // viewport, the grown half of the empty-row ruling — ungrown
    // would hug its rows (tables-plan decision 8).
    for (const item of items.columns(["Name", "Size"], { onSort, grow: 1 })) {
      kaya.row(() => {
        kaya.label({ bind: item.name });
        kaya.label({ bind: item.size });
      });
    }
  });
  for (const [key, name, size] of [
    ["b", "banana", "30"],
    ["a", "apple", "10"],
    ["c", "cherry", "20"],
  ] as const) {
    items.insert(key, Item({ name, size }));
  }
});

app.run();
