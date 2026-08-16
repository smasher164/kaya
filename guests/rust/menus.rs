//! The menus conformance scene: the command vocabulary (a File/View/Sort
//! menu bar, context menus on a live label and on stamped rows), the
//! uncontrolled-menu echo doctrine, and a late rename/append/promotion
//! rework. This is the canonical annotated port; the byte-frozen contract
//! is tools/scenes/menus.steps.

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Task {
    title: String,
}

/// The app's event vocabulary: the occurrence-side eliminator.
#[derive(Clone)]
enum Msg {
    EnableExport,
    Reset,
    Rework,
    Save,
    Details(bool),
    Sorted(usize),
    Rename,
    Remove(kaya::Path),
    Share,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (status, can_export, details, sort, file, share, groups, items) = ctx.apply(|tx| {
        let status = tx.signal("ready");
        let can_export = tx.signal(false);
        let details = tx.signal(false);
        let sort = tx.signal(0.0);

        // File and its Export leaf share one enablement signal: one write
        // moves both.
        let (file, share) = tx
            .window(kaya::DEFAULT_WINDOW)
            .title("menus")
            .menu("File", |m| {
                // THE SEMANTIC ICON (docs/styling-plan.md D6): a
                // CONCEPT, drawn by each platform in its own symbol
                // set. `done` is the checkmark idiom — the vocabulary
                // has no `save` on purpose (Apple's own catalog has no
                // save-specific glyph either).
                let save = m
                    .item("Save")
                    .symbol(kaya::Symbol::Done)
                    .shortcut("primary+s")
                    .id();
                msgs.on_menu_item(save, Msg::Save);
                let _export = m
                    .item("Export")
                    .enabled(can_export)
                    .symbol(kaya::Symbol::Forward)
                    .id();
                let share = m.item("Share").primary(true).id();
                msgs.on_menu_item(share, Msg::Share);
                share
            })
            .enabled(can_export)
            .into_parts();

        let details_item = tx
            .window(kaya::DEFAULT_WINDOW)
            // A toggle carries a symbol like any other leaf.
            .menu("View", |m| {
                m.toggle("Details").checked(details).symbol(kaya::Symbol::Info).id()
            })
            .out;
        msgs.on_menu_toggle(details_item, Msg::Details);

        // Option order IS the index vocabulary: Name = 0, Date = 1.
        let sort_group = tx
            .window(kaya::DEFAULT_WINDOW)
            .radio_group("Sort", |o| {
                o.option("Name");
                o.option("Date");
            })
            .value(sort)
            .id();
        msgs.on_menu_select(sort_group, Msg::Sorted);

        let groups = tx.collection::<String>();
        // Catalog built live: items are shared across stamped copies; the
        // template only attaches, and each activation carries its key path.
        let catalog =
            tx.context_catalog(|m| m.item("Remove").symbol(kaya::Symbol::Delete).id());
        msgs.on_menu_item_node(catalog.out, Msg::Remove);

        let (root, items) = tx
            .column(|tx| {
                tx.label(status); // label#0
                let enable = tx.button("enable export").id(); // button#0
                msgs.on_click(enable, Msg::EnableExport);
                let reset = tx.button("reset menu state").id(); // button#1
                msgs.on_click(reset, Msg::Reset);
                let rework = tx.button("extend menus").id(); // button#2
                msgs.on_click(rework, Msg::Rework);

                let target_text = tx.signal("rename target");
                let target = tx.label(target_text).id(); // label#1
                let rename = tx.context_menu(target, |m| {
                    m.item("Rename").symbol(kaya::Symbol::Edit).id()
                });
                msgs.on_menu_item(rename, Msg::Rename);

                // Remove's activation names BOTH keys (group, then item).
                //
                // The TRACING tier, not the for_each combinator this
                // block used to spell: `rows` is the construction sugar
                // (DESIGN.md, "the strongest of all") and the combinator
                // was the floor it left. The body's result gets out
                // through the slot idiom milestone2.rs already models —
                // each trace yields exactly one row, so the slot is
                // filled exactly once.
                // The catalog rides a slot for the same reason items
                // does: it is consumed by its one attach, the trace
                // records once, and the compiler cannot see that a
                // trace loop's body runs exactly once.
                let mut items = None;
                let mut catalog = Some(catalog);
                for mut group in groups.rows(tx) {
                    group.column(|t| {
                        let per_group = t.collection::<Task>();
                        for mut item in per_group.rows(t) {
                            let row = item.label(Task::title()); // label#2 once g2/a stamps
                            item.context_menu(
                                row,
                                catalog.take().expect("the item trace yields one row"),
                            );
                        }
                        items = Some(per_group);
                    });
                }
                items.expect("the group trace yields one row")
            })
            .into_parts();
        tx.mount(root);
        (status, can_export, details, sort, file, share, groups, items)
    });

    ctx.apply(|tx| {
        tx.insert(&groups, "g2", "Home");
        tx.insert(&items.at("g2"), "a", Task { title: "water plants".into() });
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::EnableExport => ctx.apply(|tx| {
                tx.write(can_export, true);
            }),
            Msg::Details(on) => ctx.apply(|tx| {
                tx.write(status, if on { "details on" } else { "details off" });
            }),
            Msg::Sorted(index) => ctx.apply(|tx| {
                tx.write(status, if index == 1 { "sorted date" } else { "sorted name" });
            }),
            Msg::Save => ctx.apply(|tx| {
                tx.write(status, "saved");
            }),
            Msg::Reset => ctx.apply(|tx| {
                // The folds never echo the user's pick, so details/sort still
                // hold false/0; these two prop writes are real checked/value
                // records (never coalesced) that reset the user-state mirror.
                tx.write(details, false);
                tx.write(sort, 0.0);
                tx.write(status, "ready");
            }),
            Msg::Rename => ctx.apply(|tx| {
                tx.write(status, "renamed");
            }),
            Msg::Remove(path) => {
                let [kaya::Value::Str(group), kaya::Value::Str(item)] = &path[..] else {
                    panic!("remove carries [group, item], got {path:?}");
                };
                ctx.apply(|tx| {
                    tx.remove(&items.at(path[0].clone()), path[1].clone());
                    tx.write(status, format!("removed {group}/{item}"));
                });
            }
            Msg::Rework => {
                // Append-only: rename the retained File, move the promotion
                // hint from Share to Publish, grow the bar by Tools.
                let publish = ctx.apply(|tx| {
                    tx.menu(share).primary(false);
                    let publish = tx
                        .menu(file)
                        .label("Document")
                        .append(|m| {
                            m.item("Publish").primary(true)
                                .symbol(kaya::Symbol::Copy)
                                .id()
                        });
                    tx.window(kaya::DEFAULT_WINDOW)
                        .menu("Tools", |m| {
                            m.item("Inspect").symbol(kaya::Symbol::Search).id();
                        })
                        .id();
                    publish
                });
                msgs.on_menu_item(publish, Msg::Share);
            }
            Msg::Share => ctx.apply(|tx| {
                tx.write(status, "shared");
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
