// The entry scene: the first widget with owned state, exercising the
// uncontrolled contract end to end. The field owns its text and reports
// each edit as a text-changed occurrence; the app folds those into
// `draft` and never reads back from the widget.
//
// Build the library first (cargo build), then:
//     KAYA_SELFTEST=entry node guests/js/entry.ts

import * as kaya from "kaya-gui";

const app = new kaya.App();

let draft = "";

function onChange(text: string): void {
  // The fold: widget-owned state arrives as occurrences; the app's
  // copy is this variable, not a widget read.
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
  // Finish the form, atomically with the insert. The field answers with
  // text_changed("") through its normal edit path, so onChange empties
  // the draft.
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
