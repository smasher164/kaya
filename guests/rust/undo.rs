//! The undo scene: two tiers, one Edit menu, and one ledger that
//! orders them (DESIGN.md, Menus; docs/undo-plan.md D1-D6, §3).
//!
//! WHAT AN APP WRITES FOR UNDO IS ONE CALL PER STEP. `tx.undoable(...)`
//! names a transaction, and that name is the step: the core keeps the
//! inverse of what the batch did to signals and collections, and hands
//! it back through `on_undone`. There is no undo stack in this file, no
//! command objects, and no re-run of any handler — an undo is a
//! programmatic write of the state that was there before, which is why
//! it emits nothing and why the occurrence carries the whole delta.
//!
//! THE FIELD'S OWN TYPING UNDO IS THE PLATFORM'S, and this app writes
//! nothing for it at all. Both tiers arrive through the same
//! Edit>Undo item, and which one answers is kaya's routing question,
//! not the app's (D6).
//!
//! THE SCENARIO THAT MOTIVATED THE MILESTONE is the add button, which
//! is the entry scene's add: it appends a todo AND empties the field.
//! Two transactions, deliberately — the undoable group is the insert
//! and the status it wrote, and the clear that finishes the form is
//! not part of the step. Under two unordered stacks one Cmd+Z takes
//! back the CLEAR: "milk" returns to the field, the todo stays, and
//! the user is looking at a state that never existed (docs/undo-plan.md
//! §2). Here it takes back the ADD.
//!
//! It is also the design saying the same thing twice: `clear` inside a
//! group is REFUSED at apply, because it destroys widget-owned text the
//! core never held (D4). Undo restores state, and state is signals plus
//! collections.
//!
//! AND THE APP NAMES NO TODO. A todo is a title and nothing else — it
//! has no identity of its own — so the key comes from `insert_fresh`,
//! which mints one per collection instance and hands it back
//! (docs/fresh-key-plan.md). What that buys here is the whole point of
//! the minter: this file used to carry `next_key`, a counter beside the
//! collection whose safety rested on never rewinding, and an undo that
//! rewound it would have handed the same name to two todos.

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Todo {
    title: String,
}

#[derive(Clone)]
enum Msg {
    Draft(String),
    Add,
    Remove,
    Star,
    Focus,
    /// The label of the step that came back, and the text the core put
    /// back into a field, if any.
    ///
    /// THE DELTA IS THE ONLY NOTIFICATION for that text: restoring an
    /// episode is a programmatic write, and a programmatic write never
    /// echoes, so an app that folds `text_changed` into its own model —
    /// which is every app, the field being uncontrolled — would go
    /// stale on exactly this step if the payload did not carry it (D5).
    Undone(String, Option<String>),
    Redone(String, Option<String>),
}

/// What the history label says a step was. A typing episode has no
/// authored name and kaya invents none ("Undo Typing" is an Apple
/// convention, not a scene string — docs/undo-plan.md D8), so the empty
/// label is the app's to spell.
fn what(label: &str) -> &str {
    if label.is_empty() {
        "typing"
    } else {
        label
    }
}

/// The app's collection mirror, rendered: every key it holds, in the
/// order it holds them.
///
/// THIS IS THE ONLY PART OF AN UNDO A COUNT CANNOT SEE. A restored
/// entry that came back under a fresh name, or at the end instead of
/// where it was, leaves every total in this file correct — the entries
/// and orders runs of the delta are what say otherwise, and this is
/// where the scene reads them (D5).
fn key_list(tx: &kaya::Tx<'_>, todos: &kaya::Collection<Todo>) -> String {
    let keys: Vec<String> = tx
        .items(todos)
        .iter()
        // The minter's keys are I64, and the binding's own field
        // conversion is what turns one back into a number.
        .map(|(key, _)| <i64 as kaya::KayaField>::from_value(key).to_string())
        .collect();
    if keys.is_empty() {
        "no keys".to_string()
    } else {
        format!("keys {}", keys.join(","))
    }
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (status, history, keys, field, todos) = ctx.apply(|tx| {
        // THE GESTURE LAYER, one tier deeper: an app declares the two
        // items and writes nothing else. They act on the focused
        // widget, lower to the platform's own command where it has one,
        // and work out their own enablement from what is focused and
        // what the ledger holds.
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
        let todos = tx.collection::<Todo>();
        let (root, field) = tx
            .column(|tx| {
                tx.label(status).a11y_id("status"); // label#0
                tx.label(history).a11y_id("history"); // label#1
                tx.label(keys).a11y_id("keys"); // label#2
                let field = tx.entry().a11y_id("draft").id(); // entry#0
                msgs.on_change(field, Msg::Draft);
                let add = tx.button("add").id(); // button#0
                msgs.on_click(add, Msg::Add);
                let star = tx.button("star").id(); // button#1
                msgs.on_click(star, Msg::Star);
                // THE SCENE'S WAY BACK TO THE FIELD. `star` does not
                // move the cursor on its own — an app that reaches for
                // focus after every action is deciding where the user
                // is looking — so the scene says so itself, and the
                // routing question ("what is focused?") stays visible
                // in the script rather than hidden in a handler.
                let refocus = tx.button("focus").id(); // button#2
                msgs.on_click(refocus, Msg::Focus);
                let remove = tx.button("remove").id(); // button#3
                msgs.on_click(remove, Msg::Remove);
                for mut row in todos.rows(tx) {
                    row.row(|t| {
                        t.label(Todo::title());
                    });
                }
                field
            })
            .into_parts();
        // THE SCENE TYPES WITH REAL KEYSTROKES, so something has to be
        // holding focus when it does — and focus is the routing
        // question's other half.
        tx.focus(field);
        tx.mount(root);
        (status, history, keys, field, todos)
    });

    // Per window, and PERSISTENT: a history is walked as often as the
    // user likes. The binding has already reconciled its collection
    // mirror from this payload before the handler runs, which is why
    // `tx.len` below answers about the restored state.
    msgs.on_undone(kaya::DEFAULT_WINDOW, |label, delta| {
        Msg::Undone(label, delta.texts.last().map(|(_, text)| text.clone()))
    });
    msgs.on_redone(kaya::DEFAULT_WINDOW, |label, delta| {
        Msg::Redone(label, delta.texts.last().map(|(_, text)| text.clone()))
    });

    // The fold: widget-owned state arrives as occurrences; the app's
    // copy is this variable, not a widget read.
    let mut draft = String::new();
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Draft(text) => draft = text,
            Msg::Add => {
                if draft.is_empty() {
                    // NOT A STEP, so it names no group and the forward
                    // history survives it. It is also the one place
                    // this app READS ITS OWN DRAFT out loud, which is
                    // how the script proves the restored text of an
                    // undone typing episode reached it at all.
                    ctx.apply(|tx| {
                        let total = tx.len(&todos);
                        tx.write(status, format!("nothing to add, {total} total"));
                    });
                    continue;
                }
                let step = format!("add {draft}");
                ctx.apply(|tx| {
                    // ONE CALL, AND IT IS THE WHOLE UNDO SURFACE. The
                    // name is what the step is called; everything in
                    // this batch is what it did.
                    tx.undoable(step);
                    // NO KEY, AND NO COUNTER TO GET WRONG: the binding
                    // mints the name and hands it back. This app has no
                    // use for it — a todo is looked up by nothing —
                    // and an app that does (selecting the new row, say)
                    // takes it from here rather than inventing a second
                    // name for the same datum.
                    tx.insert_fresh(&todos, Todo { title: draft.clone() });
                    let total = tx.len(&todos);
                    tx.write(status, format!("added {draft}, {total} total"));
                    let list = key_list(tx, &todos);
                    tx.write(keys, list);
                    // A PURE EFFECT rides along and is simply not
                    // restored: undo restores state, not where you were
                    // looking (A2).
                    tx.focus(field);
                });
                // FINISHING THE FORM IS NOT PART OF THE STEP. Its own
                // transaction, so undoing the add does not put the
                // draft back beside a todo that is gone — and `clear`
                // inside a group would be refused anyway. The field
                // empties on screen and reports text_changed("")
                // through its normal edit path, so the fold above
                // empties the draft.
                ctx.apply(|tx| tx.clear(field));
            }
            // THE STEP WHOSE INVERSE IS AN IDENTITY, not a content. The
            // core captured the entry and the instance's order before
            // the removal, so undoing this puts the entry back under
            // the key it already had, where it already was — neither of
            // which this app has to remember.
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
            // A group at its smallest: one signal write, which is the
            // undoable set's whole vocabulary on the reactive side.
            Msg::Star => ctx.apply(|tx| {
                tx.undoable("star");
                tx.write(status, "starred");
            }),
            Msg::Focus => ctx.apply(|tx| tx.focus(field)),
            Msg::Undone(label, text) => {
                if let Some(text) = text {
                    draft = text;
                }
                ctx.apply(|tx| {
                    let total = tx.len(&todos);
                    tx.write(history, format!("undid {}, {total} total", what(&label)));
                    // ONE TRANSACTION WITH THE LABEL ABOVE, deliberately:
                    // the script reads that label first, so by the time
                    // it reads this one the app's own answer is what is
                    // on screen — not the value the core restored on its
                    // way past.
                    let list = key_list(tx, &todos);
                    tx.write(keys, list);
                });
            }
            Msg::Redone(label, text) => {
                if let Some(text) = text {
                    draft = text;
                }
                ctx.apply(|tx| {
                    let total = tx.len(&todos);
                    tx.write(history, format!("redid {}, {total} total", what(&label)));
                    let list = key_list(tx, &todos);
                    tx.write(keys, list);
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
