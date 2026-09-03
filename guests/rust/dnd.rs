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
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::<Msg>::new();
    let scene = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("dnd");
        let items = tx.collection::<Item>();
        let drop_status = tx.signal("no drop yet");
        let drag_status = tx.signal("no drag yet");
        let source_text = tx.signal("hello");
        let text_target = tx.signal("text target");
        let note_target = tx.signal("note target");
        let files_target = tx.signal("files target");
        let mut list = kaya::WidgetId(0);
        let mut source = kaya::WidgetId(0);
        let mut text_id = kaya::WidgetId(0);
        let mut note_id = kaya::WidgetId(0);
        let root = tx
            .row(|tx| {
                let rows = items.rows(tx); // column#0
                list = rows.id();
                for mut row in rows {
                    let label = row.label(Item::title());
                    row.a11y_id(label, "row");
                }
                tx.reorderable(list, true);
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
                    tx.label(files_target)
                        .accepts(&[kaya::Accepts::Files])
                        .drop_target(&[kaya::Op::Copy]); // label#3
                    tx.label(drop_status); // label#4
                    tx.label(drag_status); // label#5
                });
            })
            .id();
        tx.mount(root);
        for key in ["a", "b", "c"] {
            tx.insert(&items, key, Item { title: key.to_string() });
        }
        (items, list, source, text_id, note_id, source_text, text_target, note_target, drop_status, drag_status)
    });
    let (items, list, source, text_id, note_id, source_text, text_target, note_target, drop_status, drag_status) =
        scene;

    msgs.on_drop(text_id, |d| Msg::Dropped(1, d));
    msgs.on_drop(note_id, |d| Msg::Dropped(2, d));
    msgs.on_drag_ended(source, Msg::DragEnded);
    msgs.on_drop(list, Msg::Reorder);

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Dropped(which, d) => ctx.apply(|tx| {
                let op = match d.operation {
                    Some(kaya::Op::Copy) => "copy",
                    Some(kaya::Op::Move) => "move",
                    None => "none",
                };
                let (name, target) = if which == 1 {
                    ("text target", text_target)
                } else {
                    ("note target", note_target)
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
                    other => tx.write(drop_status, format!("{name} got {other:?} ({op})")),
                }
                // A same-app MOVE removes its original in the same batch (D2).
                if d.operation == Some(kaya::Op::Move) {
                    tx.write(source_text, "moved out");
                    tx.draggable(source).declare();
                }
            }),
            Msg::DragEnded(op) => ctx.apply(|tx| {
                let word = match op {
                    Some(kaya::Op::Copy) => "copy",
                    Some(kaya::Op::Move) => "move",
                    None => "none",
                };
                tx.write(drag_status, format!("drag ended {word}"));
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
