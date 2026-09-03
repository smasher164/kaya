// Signals are a render pipe, written and never read back: the counter
// itself is a guest variable.
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

function onRemove(item: kaya.RowHandle<string>): void {
  // The innermost row's handle: its path is the group it sits in.
  const group = item.path[0]!;
  item.remove();
  status.set(`removed ${group}/${item.key}, ${items.at(group).size} left`);
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
    // `if (steps)` would branch on the HANDLE, never on the value.
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
