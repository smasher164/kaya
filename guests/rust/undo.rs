//! The undo scene: two tiers, one Edit menu, one ledger that orders
//! them. The canonical annotated port; the reasoning is
//! docs/undo-plan.md D1-D6 and the byte-frozen contract is
//! tools/scenes/undo.steps.
//!
//! Two constraints this file is shaped by: `clear` inside an undoable
//! group is REFUSED at apply (D4), so the add below is two
//! transactions; and a restored typing episode arrives only as the
//! delta's texts run (D5), never as a text_changed echo.

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Todo {
    title: String,
}

#[derive(Clone)]
enum Msg {
    Draft(String),
    /// A note typed into a ROW's field: the copy's key path and the
    /// text.
    Note(kaya::Path, String),
    Add,
    Remove,
    Star,
    Focus,
    /// The label of the step that came back, and the whole texts run of
    /// the delta — each entry names the field it restores, so the run
    /// cannot be reduced to one string.
    Undone(String, Vec<kaya::UndoText>),
    Redone(String, Vec<kaya::UndoText>),
}

/// What the history label says a step was. kaya invents no name for a
/// typing episode (docs/undo-plan.md D8), so the empty label is the
/// app's to spell.
fn what(label: &str) -> &str {
    if label.is_empty() {
        "typing"
    } else {
        label
    }
}

/// The app's collection mirror, rendered: every key it holds, in the
/// order it holds them. The only part of an undo a count cannot see —
/// a restore under a fresh name, or at the wrong position, leaves every
/// total in this file correct (D5).
fn key_list(tx: &kaya::Tx<'_>, todos: &kaya::Collection<Todo>) -> String {
    let keys: Vec<String> = tx
        .items(todos)
        .iter()
        .map(|(key, _)| <i64 as kaya::KayaField>::from_value(key).to_string())
        .collect();
    if keys.is_empty() {
        "no keys".to_string()
    } else {
        format!("keys {}", keys.join(","))
    }
}

/// The row a stamped copy's occurrence names: for a top-level For the
/// key path is one key.
fn row_key(path: &[kaya::Value]) -> i64 {
    <i64 as kaya::KayaField>::from_value(&path[0])
}

/// The app's copy of what is typed in the ROWS, rendered: every note it
/// holds, by key. The rows' fields are uncontrolled like the draft, so
/// nothing reads this back off a widget.
fn note_list(notes: &std::collections::BTreeMap<i64, String>) -> String {
    if notes.is_empty() {
        return "no notes".to_string();
    }
    let rendered: Vec<String> = notes.iter().map(|(k, v)| format!("{k}={v}")).collect();
    format!("notes {}", rendered.join(","))
}

/// One texts run, folded into the app's two mirrors of widget-owned
/// text. The empty path is the draft; a path names a row. An empty note
/// is no note: a restore to "" must REMOVE the key.
fn fold_texts(
    draft: &mut String,
    notes: &mut std::collections::BTreeMap<i64, String>,
    texts: &[kaya::UndoText],
) {
    for text in texts {
        if text.path.is_empty() {
            *draft = text.text.clone();
        } else if text.text.is_empty() {
            notes.remove(&row_key(&text.path));
        } else {
            notes.insert(row_key(&text.path), text.text.clone());
        }
    }
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (status, history, keys, notes, field, todos) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW)
            .title("undo")
            .menu("Edit", |m| {
                m.item("Undo").role(kaya::MenuRole::Undo).id();
                m.item("Redo").role(kaya::MenuRole::Redo).id();
            })
            .id();
        let status = tx.signal("no todos");
        let history = tx.signal("history empty");
        let keys = tx.signal("no keys");
        let notes = tx.signal("no notes");
        let todos = tx.collection::<Todo>();
        let (root, field) = tx
            .column(|tx| {
                tx.label(status).a11y_id("status"); // label#0
                tx.label(history).a11y_id("history"); // label#1
                tx.label(keys).a11y_id("keys"); // label#2
                tx.label(notes).a11y_id("notes"); // label#3
                let field = tx.entry().a11y_id("draft").id(); // entry#0
                msgs.on_change(field, Msg::Draft);
                let add = tx.button("add").id(); // button#0
                msgs.on_click(add, Msg::Add);
                let star = tx.button("star").id(); // button#1
                msgs.on_click(star, Msg::Star);
                // The scene's way back to the field: `star` does not
                // move the cursor, so the script asks for focus itself.
                let refocus = tx.button("focus").id(); // button#2
                msgs.on_click(refocus, Msg::Focus);
                let remove = tx.button("remove").id(); // button#3
                msgs.on_click(remove, Msg::Remove);
                for mut row in todos.rows(tx) {
                    row.row(|t| {
                        t.label(Todo::title());
                        // Unbound: `entry_bound(src)` is the constructor
                        // that seeds a copy from its own row.
                        let note = t.entry();
                        msgs.on_change_node(note, Msg::Note);
                    });
                }
                field
            })
            .into_parts();
        // The scene types with real keystrokes, so something has to be
        // holding focus when it does.
        tx.focus(field);
        tx.mount(root);
        (status, history, keys, notes, field, todos)
    });

    // Per window, and PERSISTENT: these do not retire with one answer.
    // The binding reconciles its collection mirror from the payload
    // BEFORE the handler runs, so `tx.len` below sees restored state.
    msgs.on_undone(kaya::DEFAULT_WINDOW, |label, delta| {
        Msg::Undone(label, delta.texts.clone())
    });
    msgs.on_redone(kaya::DEFAULT_WINDOW, |label, delta| {
        Msg::Redone(label, delta.texts.clone())
    });

    // Two mirrors of widget-owned text: the draft, and one note per
    // row. The payload's path is what tells them apart.
    let mut draft = String::new();
    let mut row_notes: std::collections::BTreeMap<i64, String> = std::collections::BTreeMap::new();
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Draft(text) => draft = text,
            // Folded by the same rule `fold_texts` uses for a restore,
            // so "what a note is" has one spelling and two arrival paths.
            Msg::Note(path, text) => {
                let key = row_key(&path);
                if text.is_empty() {
                    row_notes.remove(&key);
                } else {
                    row_notes.insert(key, text);
                }
                let list = note_list(&row_notes);
                ctx.apply(|tx| tx.write(notes, list));
            }
            Msg::Add => {
                if draft.is_empty() {
                    // Not a step: it names no group, so the forward
                    // history survives it.
                    ctx.apply(|tx| {
                        let total = tx.len(&todos);
                        tx.write(status, format!("nothing to add, {total} total"));
                    });
                    continue;
                }
                let step = format!("add {draft}");
                ctx.apply(|tx| {
                    // Names the step; everything in this batch is what
                    // it did.
                    tx.undoable(step);
                    tx.insert_fresh(&todos, Todo { title: draft.clone() });
                    let total = tx.len(&todos);
                    tx.write(status, format!("added {draft}, {total} total"));
                    let list = key_list(tx, &todos);
                    tx.write(keys, list);
                    tx.focus(field);
                });
                // Its OWN transaction: the clear is not part of the
                // step, and `clear` inside a group is refused anyway.
                ctx.apply(|tx| tx.clear(field));
            }
            // The step whose inverse is an identity: the core captured
            // the entry and its position, so this app remembers neither.
            Msg::Remove => ctx.apply(|tx| {
                let first = tx.items(&todos).first().cloned();
                match first {
                    None => {
                        let total = tx.len(&todos);
                        tx.write(status, format!("nothing to remove, {total} total"));
                    }
                    Some((key, todo)) => {
                        tx.undoable(format!("remove {}", todo.title));
                        tx.remove(&todos, key);
                        let total = tx.len(&todos);
                        tx.write(status, format!("removed {}, {total} total", todo.title));
                        let list = key_list(tx, &todos);
                        tx.write(keys, list);
                    }
                }
            }),
            // A group at its smallest: one signal write.
            Msg::Star => ctx.apply(|tx| {
                tx.undoable("star");
                tx.write(status, "starred");
            }),
            Msg::Focus => ctx.apply(|tx| tx.focus(field)),
            Msg::Undone(label, texts) => {
                fold_texts(&mut draft, &mut row_notes, &texts);
                let list = note_list(&row_notes);
                ctx.apply(|tx| {
                    let total = tx.len(&todos);
                    tx.write(history, format!("undid {}, {total} total", what(&label)));
                    // ONE transaction with the history label above: the
                    // script reads that label first, so these two must
                    // already hold the app's answer and not the value
                    // the core restored on its way past.
                    let keylist = key_list(tx, &todos);
                    tx.write(keys, keylist);
                    tx.write(notes, list);
                });
            }
            Msg::Redone(label, texts) => {
                fold_texts(&mut draft, &mut row_notes, &texts);
                let list = note_list(&row_notes);
                ctx.apply(|tx| {
                    let total = tx.len(&todos);
                    tx.write(history, format!("redid {}, {total} total", what(&label)));
                    let keylist = key_list(tx, &todos);
                    tx.write(keys, keylist);
                    tx.write(notes, list);
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
