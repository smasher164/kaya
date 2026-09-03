// The undo conformance scene (tools/scenes/undo.steps). THE AMBIENT TIER
// NAMES ITS TRANSACTION FROM INSIDE; a second scope in a handler throws.

import * as kaya from "kaya-gui";

const Todo = kaya.record({ title: String }, "Todo");

const app = new kaya.App();

// Two mirrors of widget-owned text; the payload's path tells them apart.
let draft = "";
const rowNotes = new Map<kaya.Key, string>();

/** kaya invents no name for a typing episode: the label is empty. */
function what(label: string): string {
  return label || "typing";
}

/** The app's collection mirror, in the order it holds the keys. */
function keyList(): string {
  const ks = todos.keys();
  if (ks.length === 0) return "no keys";
  return `keys ${ks.map((k) => String(k)).join(",")}`;
}

/** What is typed in the ROWS, by key, lowest first. */
function noteList(): string {
  if (rowNotes.size === 0) return "no notes";
  const sorted = [...rowNotes.entries()].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  return `notes ${sorted.map(([key, text]) => `${key}=${text}`).join(",")}`;
}

/** The empty path is the draft, a path names a row, and AN EMPTY NOTE IS
 * NO NOTE: a field restored to "" must REMOVE the key. */
function foldTexts(texts: kaya.UndoDelta["texts"]): void {
  for (const [_ident, path, text] of texts) {
    if (path.length === 0) draft = text;
    else if (!text) rowNotes.delete(path[0] as kaya.Key);
    else rowNotes.set(path[0] as kaya.Key, text);
  }
}

function onChange(text: string): void {
  draft = text;
}

/** The stamped row arrives first, as a handle, then the text. */
function onNote(row: kaya.RowHandle<unknown>, text: string): void {
  if (text) rowNotes.set(row.key, text);
  else rowNotes.delete(row.key);
  // NOT a step: the ledger banks an uncontrolled field's typing.
  notes.set(noteList());
}

function onAdd(): void {
  if (!draft) {
    status.set(`nothing to add, ${todos.size} total`);
    return;
  }
  kaya.undoable(`add ${draft}`);
  // The binding mints the key (docs/fresh-key-plan.md).
  todos.insertFresh(Todo({ title: draft }));
  status.set(`added ${draft}, ${todos.size} total`);
  keys.set(keyList());
  field.focus();
  // A SECOND transaction: `clear` inside the group is refused, and a
  // handler IS one transaction here.
  app.post(() => field.clear());
}

function onRemove(): void {
  const entries = todos.items();
  if (entries.length === 0) {
    status.set(`nothing to remove, ${todos.size} total`);
    return;
  }
  // The FIRST entry, so the restore has to come back before the rest.
  const [key, todo] = entries[0]!;
  kaya.undoable(`remove ${todo.title}`);
  todos.remove(key);
  status.set(`removed ${todo.title}, ${todos.size} total`);
  keys.set(keyList());
}

function onStar(): void {
  kaya.undoable("star");
  status.set("starred");
}

function onFocus(): void {
  field.focus();
}

/** THE DELTA IS THE ONLY NOTIFICATION for a field's text: an undo never
 * echoes. The mirror is reconciled before this runs. */
function undone(label: string, delta: kaya.UndoDelta): void {
  foldTexts(delta.texts);
  history.set(`undid ${what(label)}, ${todos.size} total`);
  keys.set(keyList());
  notes.set(noteList());
}

function redone(label: string, delta: kaya.UndoDelta): void {
  foldTexts(delta.texts);
  history.set(`redid ${what(label)}, ${todos.size} total`);
  keys.set(keyList());
  notes.set(noteList());
}

let status!: kaya.Signal<string>;
let history!: kaya.Signal<string>;
let keys!: kaya.Signal<string>;
let notes!: kaya.Signal<string>;
let field!: kaya.Widget;
let todos!: kaya.Collection<kaya.Fields<typeof Todo.schema>, kaya.Row<typeof Todo.schema>>;

app.window({ title: "undo", onUndone: undone, onRedone: redone }, () => {
  app.menu("Edit", () => {
    kaya.item("Undo", { role: kaya.ROLE_UNDO });
    kaya.item("Redo", { role: kaya.ROLE_REDO });
  });

  status = kaya.signal("no todos");
  history = kaya.signal("history empty");
  keys = kaya.signal("no keys");
  notes = kaya.signal("no notes");
  todos = kaya.collection(Todo);

  kaya.column(() => {
    kaya.label({ bind: status }).a11yId("status"); // label#0
    kaya.label({ bind: history }).a11yId("history"); // label#1
    kaya.label({ bind: keys }).a11yId("keys"); // label#2
    kaya.label({ bind: notes }).a11yId("notes"); // label#3
    field = kaya.entry({ onChange }).a11yId("draft"); // entry#0
    kaya.button("add", { onClick: onAdd }); // button#0
    kaya.button("star", { onClick: onStar }); // button#1
    // The scene's way back to the field.
    kaya.button("focus", { onClick: onFocus }); // button#2
    kaya.button("remove", { onClick: onRemove }); // button#3
    for (const todo of todos) {
      kaya.row(() => {
        kaya.label({ bind: todo.title });
        kaya.entry({ onChange: onNote });
      });
    }
  });

  // The scene types with real keystrokes: something must hold focus.
  field.focus();
});

app.run();
