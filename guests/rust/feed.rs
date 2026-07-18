//! The feed scene: sum-typed elements, end to end. One collection
//! holds two constructors — Note{text} and Todo{title, done} — the For
//! declares one case per constructor, and stamping eliminates by each
//! entry's discriminant. "promote" converts the first note into a
//! todo: an update carrying a different constructor, which the core
//! answers by restamping the same key in place. The checkbox handler
//! reaches its field through the match-refined accessor — a write on
//! the wrong constructor is unrepresentable, and a stale occurrence's
//! arm simply doesn't run.
//!
//! The backend selftest (KAYA_SELFTEST=feed) reads the note labels
//! (the For container's bare label children; todo rows nest theirs),
//! toggles the todo, promotes the first note, and watches the
//! done-count label move.

use kaya::Occurrence;

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
enum Post {
    Note { text: String },
    Todo { title: String, done: bool },
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let mut tx = ctx.begin();
    let feed = tx.collection::<Post>();
    let done_count = feed.derive(&mut tx, |items| {
        let n = items
            .iter()
            .filter(|(_, p)| matches!(p, Post::Todo { done: true, .. }))
            .count();
        format!("{n} done")
    });

    let promote = tx.button("promote");
    let status = tx.label(done_count);
    // The eliminator as a record of arms: one field per constructor,
    // so a missing arm is a missing field — totality at compile time,
    // the same way a match holds its arms. Each arm's handles come
    // back in the matching field of the out record.
    let (list, arms) = tx.for_each_sum(&feed, PostCases {
        note: |t: &mut kaya::Tpl| {
            t.label(Post::note_text());
        },
        todo: |t: &mut kaya::Tpl| {
            let c = t.checkbox(Post::todo_done());
            let title = t.label(Post::todo_title());
            t.row(&[c, title]);
            c
        },
    });
    let check = arms.todo;
    // The root is a row so the For's container stays the scene's only
    // column-kind widget (the reorder scene's lesson).
    let root = tx.row(&[promote, status, list]);
    tx.mount(root);
    tx.insert(&feed, "a", Post::Note { text: "jot one".into() });
    tx.insert(&feed, "b", Post::Todo { title: "buy milk".into(), done: false });
    tx.insert(&feed, "c", Post::Note { text: "jot two".into() });
    tx.commit();

    loop {
        match ctx.next() {
            Occurrence::ButtonClicked { id } if id == promote => {
                // The first note, promoted to a finished todo: the
                // model is asked which entry is a Note — the handler
                // never counts widgets — and the update's new
                // constructor restamps that key's copy in place.
                let mut tx = ctx.begin();
                let note = tx.items(&feed).into_iter().find_map(|(k, p)| match p {
                    Post::Note { text } => Some((k, text)),
                    _ => None,
                });
                if let Some((key, text)) = note {
                    tx.update(&feed, key, Post::Todo { title: text, done: true });
                }
                tx.commit();
            }
            Occurrence::InstanceToggled { node, path, checked } if node == check => {
                // The match arm as an accessor: Some exactly when the
                // entry still holds Todo. A stale occurrence lands in
                // the None arm and folds into nothing.
                let mut tx = ctx.begin();
                if let Some(todo) = Post::todo(&mut tx, &feed, path[0].clone()) {
                    todo.done(checked);
                }
                tx.commit();
            }
            Occurrence::Shutdown => break,
            _ => {}
        }
    }
}

fn main() {
    kaya::run(app)
}
