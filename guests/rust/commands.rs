//! The standard-commands scene: a chord on every leaf kind (a checkable
//! command, one option of a group, a plain command) and the `settings`
//! role, which macOS relocates into the application menu while the model
//! keeps the item where it was declared. The byte-frozen contract is
//! tools/scenes/commands.steps.

/// The app's event vocabulary: the occurrence-side eliminator.
#[derive(Clone)]
enum Msg {
    Details(bool),
    Sorted(usize),
    Settings,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (status, details, sort) = ctx.apply(|tx| {
        let status = tx.signal("ready");
        let details = tx.signal(false);
        let sort = tx.signal(0.0);

        // The settings command: a punctuation chord it declares itself,
        // plus the role that tells macOS where users look for it. An
        // ordinary command sits beside it so the menu that declared it
        // is not left empty once the platform moves it.
        let settings = tx
            .window(kaya::DEFAULT_WINDOW)
            .title("commands")
            .menu("File", |m| {
                let _reload = m.item("Reload").id();
                m.item("Settings…")
                    .role(kaya::MenuRole::Settings)
                    .shortcut("primary+comma")
                    .id()
            })
            .out;
        msgs.on_menu_item(settings, Msg::Settings);

        // A checkable command carrying its own key — the "Show Sidebar"
        // shape every desktop app wants — and, nested beside it, a group
        // whose options each answer their own chord (the view-mode
        // pattern). Option order IS the index vocabulary: Name = 0,
        // Date = 1.
        let (details_item, sort_group) = tx
            .window(kaya::DEFAULT_WINDOW)
            .menu("View", |m| {
                let details_item = m
                    .toggle("Details")
                    .checked(details)
                    .shortcut("primary+backslash")
                    .id();
                let sort_group = m
                    .radio_group("Sort", |o| {
                        o.option("Name").shortcut("primary+1");
                        o.option("Date").shortcut("primary+2");
                    })
                    .value(sort)
                    .id();
                (details_item, sort_group)
            })
            .out;
        msgs.on_menu_toggle(details_item, Msg::Details);
        msgs.on_menu_select(sort_group, Msg::Sorted);

        let root = tx
            .column(|c| {
                c.label(status);
            })
            .id();
        tx.mount(root);
        (status, details, sort)
    });
    let _ = (details, sort);

    let mut settings_count = 0usize;
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            // The native control owns user state; this scene proves the
            // occurrence, so the bound signals stay where they were (the
            // menus-scene stance).
            Msg::Details(on) => ctx.apply(|tx| {
                tx.write(status, if on { "details on" } else { "details off" });
            }),
            Msg::Sorted(index) => ctx.apply(|tx| {
                tx.write(status, if index == 1 { "sorted date" } else { "sorted name" });
            }),
            // Fires twice on purpose: once by the chord, once by
            // activating the item at its DECLARED path — which on macOS
            // lives in the application menu by then.
            Msg::Settings => {
                settings_count += 1;
                let text = format!("settings {settings_count}");
                ctx.apply(|tx| {
                    tx.write(status, text);
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
