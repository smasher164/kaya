// The milestone-2 scene from JavaScript, on the tier-1 surface: ambient
// transactions, container auto-parenting, co-located click handlers,
// element proxies, handles with methods, and derived signals — the extras
// banner's When binds `steps.eq(1)`, recomputed by the binding at write
// time and batched into the same transaction. The counter itself is a
// guest variable: signals are a render pipe, written and never read back.
//
// Build the library first (cargo build), then:
//     KAYA_SELFTEST=1 node guests/js/milestone2.ts

import * as kaya from "kaya-gui";

const app = new kaya.App();

let stepCount = 0;

function onStep(): void {
  stepCount += 1;
  const n = stepCount;
  steps.set(n);
  if (n === 1) {
    groups.insert("g1", "Work");
    items.at("g1").change((todo) => {
      todo.set("a", "send report");
      todo.set("b", "buy milk");
    });
  } else if (n === 2) {
    groups.insert("g2", "Home");
    items.at("g2").insert("a", "water plants");
    groups.update("g1", "Office");
  }
  status.set(`step ${n}`);
}

function onRemove(group: kaya.Key, itemKey: kaya.Key): void {
  const todos = items.at(group);
  todos.remove(itemKey);
  status.set(`removed ${group}/${itemKey}, ${todos.size} left`);
}

let steps!: kaya.Signal<number>;
let status!: kaya.Signal<string>;
let groups!: kaya.Collection<string, kaya.Element>;
let items!: kaya.Collection<string, kaya.Element>;

app.window(() => {
  steps = kaya.signal(0);
  status = kaya.signal("step 0");
  groups = kaya.collection();

  kaya.column(() => {
    kaya.button("step", { onClick: onStep });
    kaya.label({ bind: status });
    // `steps.eq(1)` is a derived Bool signal. A plain `if (steps)` would
    // take the branch on the HANDLE, never on the value: the branch must
    // be traced, not taken, which is kaya.when.
    kaya.when(steps.eq(1), () => {
      kaya.label("extras on");
    });
    for (const group of groups) {
      kaya.column(() => {
        kaya.label({ bind: group });
        items = kaya.collection();
        for (const item of items) {
          kaya.column(() => {
            kaya.label({ bind: item });
            kaya.button("remove", { onClick: onRemove });
          });
        }
      });
    }
  });
});

app.run();
