//! The rich rows scene (tools/scenes/richrows.steps): a rich textarea per
//! stamped ROW whose document is a FIELD of the row (docs/rich-text-plan.md
//! §19). The app writes a copy's document by patching its row, and a copy's
//! own act folds into the row the app reads back.

use kaya::PathKey;

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Note {
    title: String,
    body: kaya::Document,
}

#[derive(Clone)]
enum Msg {
    Acted(kaya::Path),
    Patch,
    Read,
    /// An undo or redo moved the row back: the app reads ITS OWN mirror of
    /// row b, which is the fold a restored Blob field lands in.
    Restored,
}

/// The core's spelling of runs (`expect_runs`), so the row's field and the
/// core's mirror are compared as one string.
fn spell(runs: &[kaya::Run]) -> String {
    runs.iter()
        .map(|run| {
            if run.is_flag() {
                format!("{}:{} {}", run.range.start, run.range.end, run.name)
            } else {
                format!("{}:{} {}={}", run.range.start, run.range.end, run.name, run.value)
            }
        })
        .collect::<Vec<_>>()
        .join("|")
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (notes, last, view) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW)
            .title("richrows")
            .menu("Edit", |m| {
                m.item("Undo").role(kaya::MenuRole::Undo).id();
                m.item("Redo").role(kaya::MenuRole::Redo).id();
            })
            .id();
        let notes = tx.collection::<Note>();
        let last = tx.signal("");
        let view = tx.signal("");
        let root = tx
            .column(|tx| {
                tx.label(last);
                tx.label(view);
                tx.row(|tx| {
                    let patch = tx.button("patch b").id();
                    msgs.on_click(patch, Msg::Patch);
                    let read = tx.button("read a").id();
                    msgs.on_click(read, Msg::Read);
                });
                for mut row in notes.rows(tx) {
                    row.column(|t| {
                        t.label(Note::title());
                        let body = t.textarea_rich_bound(Note::body());
                        t.a11y_id(body, "body");
                        msgs.on_edit_node(body, |path, _| Msg::Acted(path));
                        msgs.on_format_node(body, |path, _| Msg::Acted(path));
                    });
                }
            })
            .id();
        tx.mount(root);
        tx.insert(
            &notes,
            "a",
            Note {
                title: "a".to_owned(),
                body: kaya::Document::new("Héllo world").mark(0..6, "bold", true),
            },
        );
        tx.insert(
            &notes,
            "b",
            Note {
                title: "b".to_owned(),
                body: kaya::Document::new("Second note").mark(7..11, "link", "https://kaya.dev"),
            },
        );
        (notes, last, view)
    });

    msgs.on_undone(kaya::DEFAULT_WINDOW, |_, _| Msg::Restored);
    msgs.on_redone(kaya::DEFAULT_WINDOW, |_, _| Msg::Restored);

    let row = |tx: &kaya::Tx<'_>, key: &str| -> Note {
        notes
            .get(tx, key)
            .unwrap_or_else(|| panic!("richrows: no row {key:?}"))
    };
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            // The row's field already carries the copy's act when this
            // fires: the app reads the row, never the widget.
            Msg::Acted(path) => ctx.apply(|tx| {
                let key = path.key::<String>(0);
                let note = row(tx, &key);
                let shown = format!("{key}: {}", spell(&note.body.runs));
                tx.write(last, shown);
            }),
            Msg::Patch => ctx.apply(|tx| {
                tx.undoable("patch b");
                notes.patch(tx, "b").body(kaya::Document::new("Patched").mark(0..7, "italic", true));
            }),
            Msg::Read => ctx.apply(|tx| {
                let note = row(tx, "a");
                let shown = format!("{} | {}", note.body.text, spell(&note.body.runs));
                tx.write(view, shown);
            }),
            Msg::Restored => ctx.apply(|tx| {
                let note = row(tx, "b");
                let shown = format!("{} | {}", note.body.text, spell(&note.body.runs));
                tx.write(view, shown);
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
