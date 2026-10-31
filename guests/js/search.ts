// The search scene (tools/scenes/search.steps): a search field filtering a
// list on every keystroke, the app owning the predicate (docs/search-plan.md
// S9) and each row hiding in place (docs/hidden-plan.md).
//     KAYA_SELFTEST=search node guests/js/search.ts

import * as kaya from "kaya-gui";

const Item = kaya.record({ name: String, unmatched: Boolean }, "Item");

const ITEMS = ["apple", "banana", "cherry", "mango"];

const app = new kaya.App();

function onQuery(text: string): void {
  const query = text.toLowerCase();
  for (const name of ITEMS) items.patch(name, { unmatched: !name.includes(query) });
  const wanted = ITEMS.filter((name) => name.includes(query)).length;
  count.set(query === "" ? `${ITEMS.length} items` : `${wanted} of ${ITEMS.length} match`);
}

const { items, count } = app.window({ title: "search" }, () => {
  const items = kaya.collection(Item);
  const count = kaya.signal(`${ITEMS.length} items`);

  kaya.column(() => {
    kaya.search({ placeholder: "Search", onChange: onQuery }).a11yId("find").a11yLabel("Find items");
    kaya.label({ bind: count }).a11yId("count");
    // The For IS the list: expect_order reads its label children.
    for (const item of items.rows({ a11yId: "list" })) {
      kaya.label({ bind: item.name }).hidden(item.unmatched);
    }
  });

  for (const name of ITEMS) items.insert(name, Item({ name, unmatched: false }));
  return { items, count };
});

app.run();
