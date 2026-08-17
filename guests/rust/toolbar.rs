//! The toolbar conformance scene: the `primary` bit as real window
//! chrome (docs/chrome-plan.md C2). The app declares ONE catalog and
//! marks two actions primary; every host promotes the same first two in
//! catalog preorder — the desktop's toolbar, the phones' top bar — and
//! the rest of the catalog stays reachable where that host keeps it.
//!
//! There is no toolbar vocabulary to spell here, and that is the point:
//! this guest is the menus guest with a promotion bit and no new call.
//! The byte-frozen contract is tools/scenes/toolbar.steps.

/// The app's event vocabulary: the occurrence-side eliminator.
#[derive(Clone)]
enum Msg {
    ToggleSave,
    Save,
    Find,
    Export,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (status, can_save) = ctx.apply(|tx| {
        let status = tx.signal("ready");
        // The one signal the enablement round-trip turns on. The app
        // writes it against the MENU ITEM and says nothing about any
        // button: the promoted button is that same item, so it follows
        // or the lowering kept a copy.
        let can_save = tx.signal(true);

        // CATALOG PREORDER DECIDES PROMOTION — top-level groupings in
        // menubar-append order, then each node's children in append
        // order, depth-first. Save is the first primary and Find the
        // second, so every host's promoted set is [Save, Find] however
        // large its own k is.
        let save = tx
            .window(kaya::DEFAULT_WINDOW)
            .title("toolbar")
            .menu("File", |m| {
                let save = m
                    .item("Save")
                    // `done` is the checkmark idiom: the vocabulary has
                    // no save-specific glyph, and neither does Apple's
                    // own catalog (docs/styling-plan.md D6).
                    .symbol(kaya::Symbol::Done)
                    .primary(true)
                    .enabled(can_save)
                    .shortcut("primary+s")
                    .id();
                let export = m.item("Export").symbol(kaya::Symbol::Forward).id();
                msgs.on_menu_item(export, Msg::Export);
                save
            })
            .out;
        msgs.on_menu_item(save, Msg::Save);

        let find = tx
            .window(kaya::DEFAULT_WINDOW)
            .menu("Edit", |m| {
                let find = m.item("Find").symbol(kaya::Symbol::Search).primary(true).id();
                // The remainder: everything below is catalog, not
                // chrome, on every platform — which is what makes the
                // bare expect_toolbar's second half a real question.
                m.item("Replace").symbol(kaya::Symbol::Edit).id();
                find
            })
            .out;
        msgs.on_menu_item(find, Msg::Find);

        tx.window(kaya::DEFAULT_WINDOW)
            .menu("View", |m| {
                m.item("Refresh").symbol(kaya::Symbol::Refresh).id();
                m.item("Info").symbol(kaya::Symbol::Info).id();
            })
            .id();

        let root = tx
            .column(|tx| {
                tx.label(status); // label#0
                let toggle = tx.button("toggle save").id(); // button#0
                msgs.on_click(toggle, Msg::ToggleSave);
            })
            .id();
        tx.mount(root);
        (status, can_save)
    });

    let mut save_enabled = true;
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::ToggleSave => {
                save_enabled = !save_enabled;
                ctx.apply(|tx| {
                    tx.write(can_save, save_enabled);
                });
            }
            Msg::Save => ctx.apply(|tx| {
                tx.write(status, "saved");
            }),
            Msg::Find => ctx.apply(|tx| {
                tx.write(status, "found");
            }),
            Msg::Export => ctx.apply(|tx| {
                tx.write(status, "exported");
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
