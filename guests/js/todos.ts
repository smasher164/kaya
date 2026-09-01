// The todos scene: records and field projection, end to end. The
// collection's elements are records; the record type IS the schema
// (wire-typed fields in declaration order), the template binds each field
// to its own widget, and toggling a row sends one field's delta —
// `patch(key, {done})` never resends the title. The items-left label is a
// derived signal recomputed from the collection after every mutation.
//
// THE DERIVED LABEL COMES BACK FROM AN UNDO WITH NOBODY RESTORING IT,
// which is why this file registers no `onUndone`: the derive's write
// lands in the add's own batch, so the core banks it in both directions.
//
// Build the library first (cargo build), then:
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

function onAdd(): void {
  if (!draft) return;
  // The ambient tier names the step from INSIDE the handler — the
  // binding opened this transaction, not the app — and the marker still
  // leads the batch wherever the call sits in the body.
  kaya.undoable(`add ${draft}`);
  // The binding mints the key (docs/fresh-key-plan.md); the toggle
  // handler below receives that same minted key.
  todos.insertFresh(Todo({ title: draft, done: false }));
  // Finishing the form is a SECOND transaction: `clear` inside an
  // undoable group is refused at apply (docs/undo-plan.md D4), and
  // undoing the add must not put "buy milk" back beside a todo that is
  // gone. A handler IS one transaction here, so this one is posted.
  app.post(finishForm);
}

function finishForm(): void {
  // The add's second transaction, on the app thread. CLEAR BEFORE
  // FOCUS, so focus is the last word.
  field.clear();
  field.focus();
}

function onToggle(key: kaya.Key, checked: boolean): void {
  // One field's delta: the title never travels; the derived signal
  // updates itself.
  todos.patch(key, { done: checked });
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
    // The for statement IS the For: the body runs ONCE, authoring the
    // blueprint; stamping is the core's replay.
    for (const todo of todos) {
      kaya.row(() => {
        kaya.checkbox({ checked: todo.done, onToggle });
        kaya.label({ bind: todo.title });
      });
    }
  });
});

app.run();
