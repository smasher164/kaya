//! The restored shape (tools/scenes/restoredocs.steps,
//! docs/restoration-plan.md SR9): each document's title and text live in its
//! own session scope, and act two recreates the documents the last launch
//! left, takes each scope back, and selects the active one.

use kaya::WindowId;

#[derive(Clone)]
enum Msg {
    Typed(WindowId, String),
    Recall(WindowId, kaya::SignalId),
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::<Msg>::new();
    let primary = kaya::restored_windows().into_iter().find(|w| w.id == kaya::DEFAULT_WINDOW);
    let (documents, active) = match &primary {
        Some(w) => (w.documents.clone(), w.active_document),
        None => {
            let first = [(WindowId(10), "a"), (WindowId(11), "b"), (WindowId(12), "c")];
            for (id, title) in first {
                kaya::document_session(id).set_string("title", title);
            }
            (first.iter().map(|(id, _)| *id).collect(), None)
        }
    };
    let fields = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("restoredocs").size(640.0, 420.0);
        let mut fields = Vec::new();
        for id in &documents {
            let scope = kaya::document_session(*id);
            let title = scope.get_string("title", "untitled");
            tx.add_document(*id).title(title.as_str()).restore(*id);
            let (root, (field, recall, caption)) = tx
                .column(|tx| {
                    let caption = tx.signal(format!("{title} body"));
                    tx.label(caption).a11y_id(format!("caption-{title}"));
                    let field = tx.entry().a11y_id(format!("body-{title}")).id();
                    let recall = tx.button("recall").a11y_id(format!("recall-{title}")).id();
                    (field, recall, caption)
                })
                .into_parts();
            tx.set_text(field, &scope.get_string("body", ""));
            tx.mount_in(*id, root);
            fields.push((*id, field, recall, caption));
        }
        if let Some(active) = active {
            tx.select_document(active);
        }
        fields
    });
    for (id, field, recall, caption) in &fields {
        let (id, caption) = (*id, *caption);
        msgs.on_change(*field, move |text| Msg::Typed(id, text));
        msgs.on_click(*recall, Msg::Recall(id, caption));
    }
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Typed(id, text) => kaya::document_session(id).set_string("body", &text),
            Msg::Recall(id, caption) => {
                let title = kaya::document_session(id).get_string("title", "untitled");
                ctx.apply(|tx| tx.write(caption, format!("{title} body")));
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
