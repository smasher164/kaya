//! The standard-commands scene (tools/scenes/commands.steps): macOS moves
//! the `settings` role but the item stays addressable where declared.

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

        // Keeps the menu non-empty once macOS MOVES Settings away.
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

        // Option order IS the index.
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
            Msg::Details(on) => ctx.apply(|tx| {
                tx.write(status, if on { "details on" } else { "details off" });
            }),
            Msg::Sorted(index) => ctx.apply(|tx| {
                tx.write(status, if index == 1 { "sorted date" } else { "sorted name" });
            }),
            // Fires twice on purpose: the chord, then the item.
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
