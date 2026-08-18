//! The toolbar conformance scene: the `primary` bit as real window
//! chrome (docs/chrome-plan.md C2). There is no toolbar vocabulary to
//! spell — this is the menus guest with a promotion bit and no new
//! call. The byte-frozen contract is tools/scenes/toolbar.steps.

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
        // Written against the MENU ITEM and never a button: the promoted
        // button IS that item, so it follows or the lowering kept a copy.
        let can_save = tx.signal(true);

        // CATALOG PREORDER DECIDES PROMOTION — groupings in menubar
        // order, then children in append order, depth-first. Save is the
        // first primary and Find the second, so every host's promoted
        // set is [Save, Find] however large its own k is.
        let save = tx
            .window(kaya::DEFAULT_WINDOW)
            .title("toolbar")
            .menu("File", |m| {
                let save = m
                    .item("Save")
                    // `done` is the checkmark idiom: the vocabulary has
                    // no save glyph (docs/styling-plan.md D6).
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
                // Not primary: catalog, not chrome, on every platform.
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
