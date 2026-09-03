// The field owns its text and the app never reads back from the widget.
//     KAYA_SELFTEST=entry node guests/js/entry.ts

import * as kaya from "kaya-gui";

const app = new kaya.App();

let draft = "";

function onChange(text: string): void {
  draft = text;
}

function onAdd(): void {
  if (!draft) {
    status.set(`nothing to add, ${todos.size} total`);
    return;
  }
  // The binding mints the key (docs/fresh-key-plan.md).
  todos.insertFresh(draft);
  status.set(`added ${draft}, ${todos.size} total`);
  // Atomic with the insert; the field's text_changed("") empties draft.
  field.clear();
  field.focus();
}

let status!: kaya.Signal<string>;
let todos!: kaya.Collection<string, kaya.Element>;
let field!: kaya.Widget;

app.window(() => {
  status = kaya.signal("no todos");
  todos = kaya.collection();

  kaya.column(() => {
    field = kaya.entry({ onChange });
    kaya.button("add", { onClick: onAdd });
    kaya.label({ bind: status });
    for (const todo of todos) {
      kaya.label({ bind: todo });
    }
  });
});

app.run();
