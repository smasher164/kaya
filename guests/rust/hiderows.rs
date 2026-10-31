//! The hidden-rows scene (tools/scenes/hiderows.steps; docs/hidden-plan.md).

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Note {
    title: String,
    unmatched: bool,
}

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct File {
    name: String,
    size: String,
    unmatched: bool,
}

#[derive(Clone)]
enum Msg {
    FindNotes(String),
    FindFiles(String),
    HideTwo(bool),
}

const NOTES: [&str; 3] = ["alpha", "beta", "gamma"];

fn file_name(i: usize) -> String {
    format!("file {i:03}")
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (notes, files, two) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("hiderows");
        let notes = tx.collection::<Note>();
        let files = tx.collection::<File>();
        let two = tx.signal(false);
        let root = tx
            .column(|tx| {
                let find = tx.search().placeholder("Find notes").a11y_id("find_notes").id();
                msgs.on_change(find, Msg::FindNotes);
                let list = notes.rows(tx);
                let list_id = list.id();
                for mut note in list {
                    let (line, ()) = note.row(|t| {
                        t.label(Note::title());
                        let field = t.entry();
                        t.a11y_id(field, "note");
                    });
                    note.hidden(line, Note::unmatched());
                }
                tx.a11y_id(list_id, "notes");
                tx.grid(2, |tx| {
                    let (one, second, three) = (tx.signal("one"), tx.signal("two"), tx.signal("three"));
                    tx.label(one);
                    tx.label(second).hidden(two);
                    tx.label(three);
                })
                .a11y_id("tiles");
                let hide = tx.checkbox("Hide two").a11y_id("hide_two").id();
                msgs.on_toggle(hide, Msg::HideTwo);
                let find = tx.search().placeholder("Find files").a11y_id("find_files").id();
                msgs.on_change(find, Msg::FindFiles);
                let table = files.rows(tx).columns(&["Name", "Size"], kaya::Sort::none());
                let table_id = table.id();
                for mut file in table {
                    let (line, ()) = file.row(|t| {
                        t.label(File::name());
                        t.label(File::size());
                    });
                    file.hidden(line, File::unmatched());
                }
                tx.a11y_id(table_id, "files");
                tx.grow(table_id, 1.0);
            })
            .id();
        tx.mount(root);
        for title in NOTES {
            tx.insert(&notes, title, Note { title: title.into(), unmatched: false });
        }
        for i in 0..300 {
            tx.insert(&files, file_name(i), File { name: file_name(i), size: format!("{i} KB"), unmatched: false });
        }
        (notes, files, two)
    });

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::FindNotes(query) => ctx.apply(|tx| {
                for title in NOTES {
                    tx.update_field(&notes, title, Note::unmatched(), !title.contains(query.as_str()));
                }
            }),
            Msg::FindFiles(query) => ctx.apply(|tx| {
                for i in 0..300 {
                    tx.update_field(&files, file_name(i), File::unmatched(), !file_name(i).contains(query.as_str()));
                }
            }),
            Msg::HideTwo(on) => ctx.apply(|tx| tx.write(two, on)),
        }
    }
}

fn main() {
    kaya::run(app)
}
