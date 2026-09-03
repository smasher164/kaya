//! The feed scene, sum-typed elements (tools/scenes/feed.steps).


#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
enum Post {
    Note { text: String },
    Todo { title: String, done: bool },
}

#[derive(Clone)]
enum Msg {
    Promote,
    Toggle(kaya::Path, bool),
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let feed = ctx.apply(|tx| {
        let feed = tx.collection::<Post>();
        let done_count = feed.derive(tx, |items| {
            let n = items
                .iter()
                .filter(|(_, p)| matches!(p, Post::Todo { done: true, .. }))
                .count();
            format!("{n} done")
        });

        // The root is a row: the For's container is the only column.
        let root = tx.row(|tx| {
            let promote = tx.button("promote").id();
            msgs.on_click(promote, Msg::Promote);
            tx.label(done_count);
            // One field per constructor: a missing arm is a missing field.
            tx.for_each_sum(&feed, PostCases {
                note: |t: &mut kaya::Tpl| {
                    t.label(Post::note_text());
                },
                todo: |t: &mut kaya::Tpl| {
                    t.row(|t| {
                        let c = t.checkbox(Post::todo_done());
                        msgs.on_toggle_node(c, Msg::Toggle);
                        t.label(Post::todo_title());
                    });
                },
            });
        })
        .id();
        tx.mount(root);
        tx.insert(&feed, "a", Post::Note { text: "jot one".into() });
        tx.insert(&feed, "b", Post::Todo { title: "buy milk".into(), done: false });
        tx.insert(&feed, "c", Post::Note { text: "jot two".into() });
        feed
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Promote => {
                // The MODEL says which entry is a Note; an update restamps.
                ctx.apply(|tx| {
                    let note = tx.items(&feed).into_iter().find_map(|(k, p)| match p {
                        Post::Note { text } => Some((k, text)),
                        _ => None,
                    });
                    if let Some((key, text)) = note {
                        tx.update(&feed, key, Post::Todo { title: text, done: true });
                    }
                });
            }
            Msg::Toggle(path, checked) => {
                // Some only while the entry holds Todo: a stale one folds away.
                ctx.apply(|tx| {
                    if let Some(todo) = Post::todo(tx, &feed, path[0].clone()) {
                        todo.done(checked);
                    }
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
