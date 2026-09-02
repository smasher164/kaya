// The undo scene, JS port: two tiers, one Edit menu, and one ledger that
// orders them (DESIGN.md, Menus; docs/undo-plan.md D1-D6, §3).
//
// THE AMBIENT TIER NAMES ITS TRANSACTION FROM INSIDE, because a handler
// does not open one: the binding does (App._dispatch), and a second scope
// inside a handler throws. The marker still leads the batch wherever it
// sits in the body, exactly as `tx.undoable` does in the handle languages.
//
// `clear` inside an undoable group is REFUSED at apply (D4), which is why
// the add below finishes the form in a SECOND transaction.
//
// Canonical semantics in guests/rust/undo.rs; the byte-frozen contract in
// tools/scenes/undo.steps.

import * as kaya from "kaya-gui";

const Todo = kaya.record({ title: String }, "Todo");

const app = new kaya.App();

// The fold: widget-owned state arrives as occurrences, not a widget read.
// Two mirrors because there are two kinds of text field on screen — the
// draft and one per row — and the payload's path is what tells them apart.
let draft = "";
const rowNotes = new Map<kaya.Key, string>();

/** What the history label says a step was. A typing episode carries an
 * empty label — kaya invents none (docs/undo-plan.md D8). */
function what(label: string): string {
  return label || "typing";
}

/** The app's collection mirror, rendered: every key it holds, in the
 * order it holds them (D5). */
function keyList(): string {
  const ks = todos.keys();
  if (ks.length === 0) return "no keys";
  return `keys ${ks.map((k) => String(k)).join(",")}`;
}

/** The app's copy of what is typed in the ROWS, rendered: every note it
 * holds, by key, lowest key first. */
function noteList(): string {
  if (rowNotes.size === 0) return "no notes";
  const sorted = [...rowNotes.entries()].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  return `notes ${sorted.map(([key, text]) => `${key}=${text}`).join(",")}`;
}

/** One texts run, folded into the two mirrors. The empty path is the
 * draft; a path names a row, and for a top-level `for` over a collection
 * that path is one key.
 *
 * EVERY ENTRY COUNTS, never just the last: one step can restore the draft
 * and a row's note at once. AN EMPTY NOTE IS NO NOTE — restoring a row's
 * field to "" must REMOVE the key, which is what makes the scene's undo
 * assertion falsifiable. */
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

/** A note typed into a ROW's field: the stamped row arrives first, as a
 * handle, then the text. */
function onNote(row: kaya.RowHandle<unknown>, text: string): void {
  if (text) rowNotes.set(row.key, text);
  else rowNotes.delete(row.key);
  // NOT a step: an uncontrolled field's typing is banked by the ledger,
  // never by the app.
  notes.set(noteList());
}

function onAdd(): void {
  if (!draft) {
    status.set(`nothing to add, ${todos.size} total`);
    return;
  }
  kaya.undoable(`add ${draft}`);
  // The binding mints the key (docs/fresh-key-plan.md); this app names no
  // todo.
  todos.insertFresh(Todo({ title: draft }));
  status.set(`added ${draft}, ${todos.size} total`);
  keys.set(keyList());
  field.focus();
  // Finishing the form is a SECOND transaction: `clear` inside the group
  // would be refused, and undoing the add must not put the draft back.
  // A handler IS one transaction here, so this one is posted.
  app.post(() => field.clear());
}

function onRemove(): void {
  const entries = todos.items();
  if (entries.length === 0) {
    status.set(`nothing to remove, ${todos.size} total`);
    return;
  }
  // The collection's FIRST entry, from the model — never a widget — so
  // the restored entry has to come back BEFORE the one that stayed.
  const [key, todo] = entries[0]!;
  kaya.undoable(`remove ${todo.title}`);
  todos.remove(key);
  status.set(`removed ${todo.title}, ${todos.size} total`);
  keys.set(keyList());
}

function onStar(): void {
  // A group at its smallest: one signal write.
  kaya.undoable("star");
  status.set("starred");
}

function onFocus(): void {
  field.focus();
}

/** The label of the step that came back, and the whole restored state.
 *
 * THE DELTA IS THE ONLY NOTIFICATION for a field's text: an undo is a
 * programmatic write and never echoes, so an app that folds
 * `text_changed` goes stale on this step without it (D5).
 *
 * The binding reconciles its collection mirror from this payload before
 * this runs, so `todos.size` answers about the restored state. */
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
    // The scene's way back to the field, so the routing question ("what
    // is focused?") stays visible in the script.
    kaya.button("focus", { onClick: onFocus }); // button#2
    kaya.button("remove", { onClick: onRemove }); // button#3
    for (const todo of todos) {
      kaya.row(() => {
        kaya.label({ bind: todo.title });
        kaya.entry({ onChange: onNote });
      });
    }
  });

  // The scene types with real keystrokes, so something must hold focus.
  field.focus();
});

app.run();
