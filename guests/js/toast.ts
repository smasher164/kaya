// The toast scene (tools/scenes/toast.steps; docs/toast-plan.md §5).

import * as kaya from "kaya-gui";

const Item = kaya.record({ title: String }, "Item");

const app = new kaya.App();
let answers = 0;
let undos = 0;
let held: number | null = null;

function titles(): string {
  const all = items.items().map(([, item]) => item.title);
  return all.length === 0 ? "empty" : all.join(", ");
}

function answer(text: string, outcome: kaya.ToastOutcome): void {
  answers += 1;
  count.set(`answers ${answers}`);
  last.set(`${text}: ${outcome}`);
}

function toast(text: string, action?: string): void {
  kaya.showToast({ text, ...(action === undefined ? {} : { action }), onResult: (o) => answer(text, o) });
}

function onDelete(): void {
  const first = items.items()[0];
  if (first === undefined) return;
  const [key, item] = first;
  kaya.undoable(`delete ${item.title}`);
  items.remove(key);
  rows.set(titles());
  const text = `Deleted ${item.title}`;
  kaya.showToast({ text, action: "Undo", undo: true, onResult: (o) => answer(text, o) });
}

function onHold(): void {
  held = kaya.showToast({ text: "Working", duration: "long", onResult: (o) => answer("Working", o) });
}

function onDismiss(): void {
  if (held === null) return;
  kaya.dismissToast(held);
  held = null;
}

function undone(label: string): void {
  undos += 1;
  undoneText.set(`undone ${undos}: ${label}`);
  rows.set(titles());
}

const { last, count, undoneText, rows, items } = app.window({ title: "toast", onUndone: undone }, () => {
  app.menu("Edit", () => {
    kaya.item("Undo", { role: "undo" });
    kaya.item("Redo", { role: "redo" });
  });
  const last = kaya.signal("no answer yet");
  const count = kaya.signal("answers 0");
  const undoneText = kaya.signal("nothing undone");
  const rows = kaya.signal("Milk, Eggs, Bread");
  const items = kaya.collection(Item);
  kaya.column(() => {
    kaya.label({ bind: last }); // label#0
    kaya.label({ bind: count }); // label#1
    kaya.label({ bind: undoneText }); // label#2
    kaya.label({ bind: rows }); // label#3
    kaya.button("show", { onClick: () => toast("Saved") }); // button#0
    kaya.button("first", { onClick: () => toast("First", "Open") }); // button#1
    kaya.button("second", { onClick: () => toast("Second", "Open") }); // button#2
    kaya.button("delete", { onClick: onDelete }); // button#3
    kaya.button("hold", { onClick: onHold }); // button#4
    kaya.button("dismiss", { onClick: onDismiss }); // button#5
    for (const item of items) {
      kaya.row(() => {
        kaya.label({ bind: item.title });
      });
    }
  });
  for (const title of ["Milk", "Eggs", "Bread"]) items.insert(title, Item({ title }));
  return { last, count, undoneText, rows, items };
});

app.run();
