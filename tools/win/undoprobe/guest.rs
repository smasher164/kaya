//! THROWAWAY guest for the WinUI undo probe (docs/undo-plan.md §0,
//! probe plan P3-win / P4 / P5). Not a scene, not a conformance
//! surface, and deliberately outside guests/rust: it exists only to
//! stand up a real kaya window containing
//!
//!   * one Entry (the TextBox whose native undo stack is the subject),
//!   * one menu item Edit>Undo carrying the chord `primary+z` (Ctrl+Z),
//!     built through the ordinary menu API so the catalog, the
//!     KeyboardAccelerator and `core.menu_shortcuts` all exist exactly
//!     as they would in a shipped app.
//!
//! Everything the app observes is printed with a PROBEGUEST prefix, so
//! the measurement can tell an occurrence the app saw from a native
//! state the backend read.

#[derive(Clone)]
enum Msg {
    Undo,
    Changed(String),
    Note(String),
    Clicked,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    ctx.apply(|tx| {
        let undo = tx
            .window(kaya::DEFAULT_WINDOW)
            .title("undoprobe")
            .menu("Edit", |m| m.item("Undo").shortcut("primary+z").id())
            .out;
        msgs.on_menu_item(undo, Msg::Undo);

        let (root, ()) = tx
            .column(|tx| {
                let field = tx.entry().id();
                msgs.on_change(field, Msg::Changed);
                // A focusable NON-text widget: the control for P5 —
                // whether a kaya accelerator fires at all in this app
                // when the focus is not inside a text control.
                let button = tx.button("elsewhere").id();
                msgs.on_click(button, Msg::Clicked);
                // The multi-line sibling (also a TextBox): D7 applies at
                // every text site, so the same questions are asked of it.
                let notes = tx.textarea().id();
                msgs.on_change(notes, Msg::Note);
                // (An app-declared context menu on a text widget was
                // tried here and is REFUSED at the root:
                // scene.rs:1435 — "context_attach rejected on Textarea
                // — the editable text controls keep their native edit
                // menus (dress)". The guest dies on the scene that
                // tries it, so the native Undo affordance measured
                // below cannot be displaced by an app menu.)
            })
            .into_parts();
        tx.mount(root);
    });
    println!("PROBEGUEST ready");

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            // The chord's or the chrome's activation of Edit>Undo. Which
            // route delivered it is decided by the backend probe, which
            // prints what it did to core.menu_shortcuts first.
            Msg::Undo => println!("PROBEGUEST menu_activated Edit>Undo"),
            // The uncontrolled contract: every edit the FIELD owns
            // reports here — including, if the platform behaves as
            // docs/undo-plan.md §0 claims, a native undo.
            Msg::Changed(text) => println!("PROBEGUEST text_changed {text:?}"),
            Msg::Note(text) => println!("PROBEGUEST textarea_changed {text:?}"),
            Msg::Clicked => println!("PROBEGUEST button_clicked"),
        }
    }
}

fn main() {
    kaya::run(app)
}
