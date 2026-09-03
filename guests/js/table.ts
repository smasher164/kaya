// The table scene: a header click is a REQUEST, and the platform sorts none.
//     KAYA_SELFTEST=table node guests/js/table.ts

import * as kaya from "kaya-gui";

const Item = kaya.record({ name: String, size: String }, "Item");
type ItemFields = kaya.Fields<typeof Item.schema>;

const app = new kaya.App();

// The guest's sort policy; the platform never has one.
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
  // Each key to the end, in the target order.
  for (const [key] of entries) {
    items.moveToEnd(key);
  }
  const indicator = descending ? kaya.Sort.desc(column) : kaya.Sort.asc(column);
  items.setColumns(["Name", "Size"], { sort: indicator });
}

let items!: kaya.Collection<ItemFields, kaya.Row<typeof Item.schema>>;

app.window(() => {
  items = kaya.collection(Item);
  // The root is a row: the For's container is the only column.
  kaya.row(() => {
    // Grown on purpose: ungrown, a table hugs its rows.
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
