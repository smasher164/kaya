//! The row menu scene (tools/scenes/rowmenu.steps; docs/media-player-plan.md M26).

use kaya::PathKey;

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Entry {
    title: String,
    mark: String,
}

#[derive(Clone)]
enum Msg {
    Star(kaya::Path),
    Pin(kaya::Path),
    Open(kaya::Path),
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (status, notes, files) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("rowmenu");
        let status = tx.signal("ready");
        let notes = tx.collection::<Entry>();
        let files = tx.collection::<Entry>();
        let (note_menu, (star, open_note)) = tx.context_catalog(|m| {
            let star = m.item("Star").id();
            m.separator();
            (star, m.item("Open").id())
        });
        msgs.on_menu_item_node(star, Msg::Star);
        msgs.on_menu_item_node(open_note, Msg::Open);
        let (file_menu, (pin, open_file)) = tx.context_catalog(|m| {
            let pin = m.item("Pin").id();
            m.separator();
            (pin, m.item("Open").id())
        });
        msgs.on_menu_item_node(pin, Msg::Pin);
        msgs.on_menu_item_node(open_file, Msg::Open);

        let mut note_menu = Some(note_menu);
        let mut file_menu = Some(file_menu);
        let root = tx
            .column(|tx| {
                tx.label(status);
                for mut note in notes.rows(tx) {
                    let (line, ()) = note.row(|t| {
                        t.label(Entry::title());
                    });
                    note.a11y_id(line, "note");
                    note.context_menu(line, note_menu.take().expect("the note trace yields one row"));
                    note.context_label(line, star, Entry::mark());
                }
                let table = files.rows(tx).columns(&["Name"], kaya::Sort::none());
                let id = table.id();
                for mut file in table {
                    let (line, ()) = file.row(|t| {
                        t.label(Entry::title());
                    });
                    file.a11y_id(line, "file");
                    file.context_menu(line, file_menu.take().expect("the file trace yields one row"));
                    file.context_label(line, pin, Entry::mark());
                }
                tx.grow(id, 1.0);
            })
            .id();
        tx.mount(root);
        for (key, title, mark) in [("a", "apples", "Star"), ("b", "bread", "Unstar")] {
            tx.insert(&notes, key, Entry { title: title.into(), mark: mark.into() });
        }
        for (key, title, mark) in [("x", "x.txt", "Pin"), ("y", "y.txt", "Unpin")] {
            tx.insert(&files, key, Entry { title: title.into(), mark: mark.into() });
        }
        (status, notes, files)
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Star(path) => {
                let key = path.key::<String>(0);
                ctx.apply(|tx| {
                    let on = notes.get(tx, key.clone()).is_some_and(|e| e.mark == "Star");
                    tx.update_field(&notes, key.clone(), Entry::mark(), (if on { "Unstar" } else { "Star" }).to_string());
                    tx.write(status, format!("{} {key}", if on { "starred" } else { "unstarred" }));
                });
            }
            Msg::Pin(path) => {
                let key = path.key::<String>(0);
                ctx.apply(|tx| {
                    let on = files.get(tx, key.clone()).is_some_and(|e| e.mark == "Pin");
                    tx.update_field(&files, key.clone(), Entry::mark(), (if on { "Unpin" } else { "Pin" }).to_string());
                    tx.write(status, format!("{} {key}", if on { "pinned" } else { "unpinned" }));
                });
            }
            Msg::Open(path) => {
                let key = path.key::<String>(0);
                ctx.apply(|tx| {
                    tx.write(status, format!("opened {key}"));
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
