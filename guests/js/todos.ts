// The todos scene: IT REGISTERS NO `onUndone`, because the derive's write
// rides the add's batch.
//     KAYA_SELFTEST=todos node guests/js/todos.ts

import * as kaya from "kaya-gui";

const Todo = kaya.record({ title: String, done: Boolean }, "Todo");

const app = new kaya.App();

let draft = "";

function itemsLeftText(items: Map<kaya.Key, kaya.Fields<typeof Todo.schema>>): string {
  let n = 0;
  for (const t of items.values()) if (!t.done) n += 1;
  return n === 1 ? "1 item left" : `${n} items left`;
}

function onChange(text: string): void {
  draft = text;
}

async function onAdd(): Promise<void> {
  if (!draft) return;
  // The marker leads the batch wherever the call sits in the body.
  kaya.undoable(`add ${draft}`);
  // The binding mints the key (docs/fresh-key-plan.md).
  todos.insertFresh(Todo({ title: draft, done: false }));
  // A SECOND transaction: `clear` in an undoable group is refused, and the
  // handler's transaction commits at this await. CLEAR BEFORE FOCUS.
  await app.commit();
  field.clear();
  field.focus();
}

function onToggle(todo: kaya.RowHandle<kaya.Fields<typeof Todo.schema>>, checked: boolean): void {
  // One field's delta: the assignment IS the patch.
  todo.done = checked;
}

let field!: kaya.Widget;
let todos!: kaya.Collection<kaya.Fields<typeof Todo.schema>, kaya.Row<typeof Todo.schema>>;

app.window({ title: "todos" }, () => {
  app.menu("Edit", () => {
    kaya.item("Undo", { role: kaya.ROLE_UNDO });
    kaya.item("Redo", { role: kaya.ROLE_REDO });
  });

  todos = kaya.collection(Todo);
  const itemsLeft = todos.derive(itemsLeftText);

  kaya.column(() => {
    field = kaya.entry({ onChange });
    kaya.button("Add", { onClick: onAdd });
    kaya.label({ bind: itemsLeft });
    // The body runs ONCE, authoring the blueprint.
    for (const todo of todos) {
      kaya.row(() => {
        kaya.checkbox({ checked: todo.done, onToggle });
        kaya.label({ bind: todo.title });
      });
    }
  });
});

app.run();
