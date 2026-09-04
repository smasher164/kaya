// The drag-and-drop scene (tools/scenes/dnd.steps; docs/dnd-plan.md D1, D8).
// The root is a ROW so column#0 is the reorderable For's container.

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Item {
    title: String,
}

#[derive(Clone)]
enum Msg {
    Dropped(u64, kaya::Dropped),
    DragEnded(Option<kaya::Op>),
    Reorder(kaya::Dropped),
    ItemDropped(kaya::Path, kaya::Dropped),
    Rename,
    NodeDragEnded(&'static str, kaya::Path, Option<kaya::Op>),
}

fn op_word(op: Option<kaya::Op>) -> &'static str {
    match op {
        Some(kaya::Op::Copy) => "copy",
        Some(kaya::Op::Move) => "move",
        None => "none",
    }
}

fn key_word(path: &kaya::Path) -> String {
    match path.first() {
        Some(kaya::Value::Str(s)) => s.clone(),
        other => format!("{other:?}"),
    }
}

/// NOT THE TEMP DIRECTORY ON THE PHONES: `$TMP` is the harness's own name
/// for the directory a picker can reach, which is Documents there
/// (guests/rust/filedialog.rs' scene_root, kayaTempDir in the interpreter).
#[cfg(target_os = "android")]
fn scene_root() -> std::path::PathBuf {
    let root = std::env::var("EXTERNAL_STORAGE").unwrap_or_else(|_| "/sdcard".into());
    std::path::PathBuf::from(root).join("Documents")
}

#[cfg(target_os = "ios")]
fn scene_root() -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_default();
    std::path::PathBuf::from(home).join("Documents")
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn scene_root() -> std::path::PathBuf {
    std::env::temp_dir()
}

/// The file the scene drops as a FOREIGN source (D6), written by the guest
/// at $TMP/kaya-dnd-$PID/dropped.txt — the same convention as the picker
/// and clipboard scenes' files.
fn dropped_file() -> std::path::PathBuf {
    scene_root().join(format!("kaya-dnd-{}", std::process::id()))
}

fn read_back(file: &kaya::PickedFile) -> String {
    use std::io::Read;
    let mut text = String::new();
    match file.open(kaya::FileMode::Read) {
        Ok(mut opened) => {
            if let Err(e) = opened.file.read_to_string(&mut text) {
                text = format!("read failed: {e}");
            }
        }
        Err(e) => text = format!("open failed: {e}"),
    }
    text
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let dir = dropped_file();
    std::fs::create_dir_all(&dir).expect("failed to make the scene's directory");
    std::fs::write(dir.join("dropped.txt"), b"dropped bytes").expect("failed to write the file");

    let msgs = kaya::Messages::<Msg>::new();
    let scene = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("dnd");
        let items = tx.collection::<Item>();
        let items2 = tx.collection::<Item>();
        let drop_status = tx.signal("no drop yet");
        let drag_status = tx.signal("no drag yet");
        let source_text = tx.signal("hello");
        let text_target = tx.signal("text target");
        let note_target = tx.signal("note target");
        let files_target = tx.signal("files target");
        let mut list = kaya::WidgetId(0);
        let mut row_label = kaya::TemplateNodeId(0);
        let mut item_label = kaya::TemplateNodeId(0);
        let mut source = kaya::WidgetId(0);
        let mut text_id = kaya::WidgetId(0);
        let mut note_id = kaya::WidgetId(0);
        let mut files_id = kaya::WidgetId(0);
        let mut rename = kaya::WidgetId(0);
        let root = tx
            .row(|tx| {
                let rows = items.rows(tx); // column#0
                list = rows.id();
                for mut row in rows {
                    let label = row.label(Item::title());
                    row.a11y_id(label, "row");
                    row_label = label;
                }
                tx.reorderable(list, true);
                tx.a11y_id(list, "rows");
                tx.column(|tx| {
                    source = tx.label(source_text).id(); // label#0
                    tx.draggable(source)
                        .text("hello")
                        .custom("dev.kaya/note", b"note!".to_vec())
                        .allow(kaya::Op::Copy)
                        .allow(kaya::Op::Move)
                        .declare();
                    text_id = tx
                        .label(text_target)
                        .accepts(&[kaya::Accepts::Text])
                        .drop_target(&[kaya::Op::Copy])
                        .id(); // label#1
                    note_id = tx
                        .label(note_target)
                        .accepts(&[kaya::Accepts::Custom("dev.kaya/note")])
                        .drop_target(&[kaya::Op::Copy, kaya::Op::Move])
                        .id(); // label#2
                    files_id = tx
                        .label(files_target)
                        .accepts(&[kaya::Accepts::Files])
                        .drop_target(&[kaya::Op::Copy])
                        .id(); // label#3
                    tx.label(drop_status); // label#4
                    tx.label(drag_status); // label#5
                });
                // THE TEMPLATE ZONE (docs/dnd-plan.md §4): every stamped
                // item is a text destination, and each declares its own
                // payload by key after its insert — column#2.
                let item_rows = items2.rows(tx);
                let items_list = item_rows.id();
                for mut row in item_rows {
                    let label = row.label(Item::title());
                    row.a11y_id(label, "item");
                    row.accepts(label, &[kaya::Accepts::Text]);
                    row.drop_target(label, &[kaya::Op::Copy]);
                    // The payload IS the row's field, resolved per copy
                    // and re-declared when it changes (§4).
                    row.draggable(label).text(Item::title()).allow(kaya::Op::Copy).declare();
                    item_label = label;
                }
                tx.a11y_id(items_list, "items");
                rename = tx.button("rename y").id(); // button#0
            })
            .id();
        tx.mount(root);
        for key in ["a", "b", "c"] {
            tx.insert(&items, key, Item { title: key.to_string() });
        }
        for key in ["x", "y"] {
            tx.insert(&items2, key, Item { title: key.to_string() });
        }
        (items, items2, list, source, text_id, note_id, files_id, rename, source_text, text_target, note_target, files_target, drop_status, drag_status, row_label, item_label)
    });
    let (items, items2, list, source, text_id, note_id, files_id, rename, source_text, text_target, note_target, files_target, drop_status, drag_status, row_label, item_label) =
        scene;

    msgs.on_drop(text_id, |d| Msg::Dropped(1, d));
    msgs.on_drop(note_id, |d| Msg::Dropped(2, d));
    msgs.on_drop(files_id, |d| Msg::Dropped(3, d));
    msgs.on_drag_ended(source, Msg::DragEnded);
    msgs.on_drop(list, Msg::Reorder);
    msgs.on_drop_node(item_label, Msg::ItemDropped);
    msgs.on_click(rename, Msg::Rename);
    msgs.on_drag_ended_node(item_label, |path, op| Msg::NodeDragEnded("item", path, op));
    msgs.on_drag_ended_node(row_label, |path, op| Msg::NodeDragEnded("row", path, op));

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Dropped(which, d) => ctx.apply(|tx| {
                let op = op_word(d.operation);
                let (name, target) = match which {
                    1 => ("text target", text_target),
                    2 => ("note target", note_target),
                    _ => ("files target", files_target),
                };
                match &d.clip {
                    kaya::Representation::Text(s) => {
                        tx.write(drop_status, format!("{name} got text {s} ({op})"));
                        tx.write(target, s.clone());
                    }
                    kaya::Representation::Custom { id, bytes } => {
                        tx.write(
                            drop_status,
                            format!("{name} got {id} {} bytes ({op})", bytes.0.len()),
                        );
                    }
                    kaya::Representation::Files(files) => {
                        // A dropped file IS a picked file (D6): read it back
                        // through the same table the picker fills.
                        let said: Vec<String> = files
                            .iter()
                            .map(|f| format!("{} {}", f.name, read_back(f)))
                            .collect();
                        tx.write(drop_status, format!("{name} got {} ({op})", said.join(", ")));
                    }
                    other => tx.write(drop_status, format!("{name} got {other:?} ({op})")),
                }
                // A same-app MOVE removes its original in the same batch (D2).
                if d.operation == Some(kaya::Op::Move) {
                    tx.write(source_text, "moved out");
                    tx.draggable(source).declare();
                }
            }),
            Msg::DragEnded(op) => ctx.apply(|tx| {
                tx.write(drag_status, format!("drag ended {}", op_word(op)));
            }),
            Msg::ItemDropped(path, d) => ctx.apply(|tx| {
                let op = op_word(d.operation);
                let key = key_word(&path);
                match &d.clip {
                    kaya::Representation::Text(s) => {
                        tx.write(drop_status, format!("item {key} got text {s} ({op})"));
                    }
                    other => tx.write(drop_status, format!("item {key} got {other:?} ({op})")),
                }
            }),
            Msg::Rename => ctx.apply(|tx| {
                // The bound payload follows the row's record (§4).
                tx.update(&items2, "y", Item { title: "yy".to_string() });
            }),
            Msg::NodeDragEnded(what, path, op) => ctx.apply(|tx| {
                tx.write(drag_status, format!("{what} {} drag ended {}", key_word(&path), op_word(op)));
            }),
            Msg::Reorder(d) => ctx.apply(|tx| {
                // The moved row's key rides as the kaya-private custom
                // representation; the anchor is the row it landed on (D8).
                let kaya::Representation::Custom { bytes, .. } = &d.clip else { return };
                let moved = String::from_utf8_lossy(&bytes.0).to_string();
                let Some(kaya::Value::Str(anchor)) = d.anchor.first().cloned() else { return };
                if d.before {
                    tx.move_before(&items, moved, anchor);
                } else {
                    tx.move_after(&items, moved, anchor);
                }
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
