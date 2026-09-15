//! The app-owned undo scene (tools/scenes/ownundo.steps; docs/rich-text-plan.md
//! R6, §14): two rich textareas, one on the platform's own undo tier and one
//! whose app keeps its own history of Documents. Edit>Undo reaches the app
//! through the role item's own activation while the owned textarea is
//! focused, and the platform's tier while the other one is.

#[derive(Clone)]
enum Msg {
    Edited,
    Undo,
    Redo,
    FocusNative,
    FocusOwned,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (status, native, owned) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW)
            .title("ownundo")
            .menu("Edit", |m| {
                let undo = m.item("Undo").role(kaya::MenuRole::Undo).id();
                let redo = m.item("Redo").role(kaya::MenuRole::Redo).id();
                msgs.on_menu_item(undo, Msg::Undo);
                msgs.on_menu_item(redo, Msg::Redo);
            })
            .id();
        let status = tx.signal("undo 0 redo 0");
        let (root, (native, owned)) = tx
            .column(|tx| {
                tx.label(status).a11y_id("status"); // label#0
                let native = tx.textarea().rich().a11y_id("native").a11y_label("Native").id(); // textarea#0
                let owned = tx
                    .textarea()
                    .rich()
                    .own_undo()
                    .a11y_id("owned")
                    .a11y_label("Owned")
                    .id(); // textarea#1
                msgs.on_edit(owned, |_| Msg::Edited);
                tx.row(|tx| {
                    let focus_native = tx.button("focus native").id(); // button#0
                    let focus_owned = tx.button("focus owned").id(); // button#1
                    msgs.on_click(focus_native, Msg::FocusNative);
                    msgs.on_click(focus_owned, Msg::FocusOwned);
                });
                (native, owned)
            })
            .into_parts();
        tx.mount(root);
        (status, native, owned)
    });

    // THE APP'S OWN HISTORY: the document before each user edit, and the
    // documents an undo took away. The binding's mirror is the document
    // AFTER the edit it just delivered.
    let mut undo: Vec<kaya::Document> = Vec::new();
    let mut redo: Vec<kaya::Document> = Vec::new();
    let mut current = kaya::Document::new("");
    let publish = |tx: &mut kaya::Tx, undo: &[kaya::Document], redo: &[kaya::Document]| {
        tx.write(status, format!("undo {} redo {}", undo.len(), redo.len()));
        tx.can_undo(owned, !undo.is_empty());
        tx.can_redo(owned, !redo.is_empty());
    };

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Edited => {
                undo.push(std::mem::replace(&mut current, ctx.document(owned)));
                redo.clear();
                ctx.apply(|tx| publish(tx, &undo, &redo));
            }
            Msg::Undo => {
                let Some(before) = undo.pop() else { continue };
                redo.push(std::mem::replace(&mut current, before.clone()));
                ctx.apply(|tx| {
                    tx.set_document(owned, &before);
                    publish(tx, &undo, &redo);
                });
            }
            Msg::Redo => {
                let Some(after) = redo.pop() else { continue };
                undo.push(std::mem::replace(&mut current, after.clone()));
                ctx.apply(|tx| {
                    tx.set_document(owned, &after);
                    publish(tx, &undo, &redo);
                });
            }
            Msg::FocusNative => ctx.apply(|tx| tx.focus(native)),
            Msg::FocusOwned => ctx.apply(|tx| tx.focus(owned)),
        }
    }
}

fn main() {
    kaya::run(app)
}
