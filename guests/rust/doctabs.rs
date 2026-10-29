//! The document-tabs scene (tools/scenes/doctabs.steps; docs/doctabs-plan.md
//! §5): three documents, one of them armed against a close, a shared region
//! beside them, the "+", and a programmatic select that echoes nothing.

pub(crate) fn app(ctx: kaya::AppCtx) {
    use kaya::{AlertChoice, WindowId};

    #[derive(Clone)]
    enum Msg {
        Selected(&'static str),
        Closed(&'static str),
        AskClose,
        Answered(AlertChoice),
        AskWindow(Vec<WindowId>),
        New,
        Moved(&'static str, u32),
        Detached(WindowId, Vec<WindowId>),
        Mark,
        GoFirst,
    }

    const A: WindowId = WindowId(10);
    const B: WindowId = WindowId(11);
    const C: WindowId = WindowId(12);
    const NOTES: WindowId = WindowId(30);

    let msgs = kaya::Messages::<Msg>::new();
    // THE ONE BUILDER every window's shared region comes from, the first
    // window's and a torn-out one's alike (docs/doctabs-plan.md §1.2).
    let notes = |tx: &mut kaya::Tx, window: WindowId, region: WindowId, status: kaya::SignalId| {
        tx.add_region_in(window, region, kaya::RegionEdge::Leading);
        let root = tx
            .column(|tx| {
                tx.label(status).a11y_id("status");
                tx.entry().a11y_id("note");
                let first = tx.button("to a").a11y_id("first").id();
                msgs.on_click(first, Msg::GoFirst);
            })
            .id();
        tx.mount_in(region, root);
    };
    let status = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("doctabs").size(640.0, 420.0).new_document(true);
        let status = tx.signal("ready");
        for (id, name) in [(A, "a"), (B, "b"), (C, "c")] {
            tx.add_document(id).title(name).tooltip(&format!("/documents/{name}")).intercept_close(id == B);
            let root = tx
                .column(|tx| {
                    let caption = tx.signal(format!("{name} body"));
                    tx.label(caption).a11y_id(format!("body-{name}"));
                    tx.entry().a11y_id(format!("field-{name}"));
                    if id == B {
                        let mark = tx.button("mark b").a11y_id("mark").id();
                        msgs.on_click(mark, Msg::Mark);
                    }
                })
                .id();
            tx.mount_in(id, root);
        }
        notes(tx, kaya::DEFAULT_WINDOW, NOTES, status);
        status
    });

    for (id, name) in [(A, "a"), (B, "b"), (C, "c")] {
        msgs.on_document_selected(id, Msg::Selected(name));
        msgs.on_document_closed(id, Msg::Closed(name));
        msgs.on_document_moved(id, move |_, index| Msg::Moved(name, index));
    }
    msgs.on_document_close_requested(B, Msg::AskClose);
    msgs.on_documents_close_requested(kaya::DEFAULT_WINDOW, Msg::AskWindow);
    msgs.on_new_document(kaya::DEFAULT_WINDOW, Msg::New);
    msgs.on_documents_detached(kaya::DEFAULT_WINDOW, Msg::Detached);

    let mut untitled = 0u64;
    let mut regions = 0u64;
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Selected(name) => ctx.apply(|tx| tx.write(status, format!("selected {name}"))),
            Msg::Closed(name) => ctx.apply(|tx| tx.write(status, format!("closed {name}"))),
            Msg::Moved(name, index) => ctx.apply(|tx| tx.write(status, format!("moved {name} to {index}"))),
            Msg::Detached(window, documents) => {
                regions += 1;
                ctx.apply(|tx| {
                    notes(tx, window, WindowId(300 + regions), status);
                    let names: Vec<&str> = documents
                        .iter()
                        .map(|d| match *d {
                            A => "a",
                            B => "b",
                            C => "c",
                            _ => "untitled",
                        })
                        .collect();
                    tx.write(status, format!("detached {}", names.join(" ")));
                });
            }
            Msg::Mark => ctx.apply(|tx| {
                tx.document(B).dirty(true);
                tx.write(status, "marked b");
            }),
            // Programmatic: no document_selected follows, so the status stays.
            Msg::GoFirst => ctx.apply(|tx| tx.select_document(A)),
            Msg::AskClose => {
                let alert = ctx.apply(|tx| {
                    tx.show_alert()
                        .title("unsaved changes")
                        .message("b has unsaved changes")
                        .action("Discard")
                        .cancel("Keep Editing")
                        .show()
                });
                msgs.on_alert(alert, Msg::Answered);
            }
            Msg::Answered(choice) => ctx.apply(|tx| match choice {
                AlertChoice::Action(_) => {
                    tx.close_document(B);
                    tx.write(status, "discarded b");
                }
                AlertChoice::Cancel => tx.write(status, "kept b"),
            }),
            Msg::AskWindow(documents) => ctx.apply(|tx| {
                tx.write(status, format!("asked about {}", documents.len()));
            }),
            Msg::New => {
                untitled += 1;
                let name = format!("untitled {untitled}");
                let id = WindowId(100 + untitled);
                ctx.apply(|tx| {
                    tx.add_document(id).title(name.as_str()).select();
                    let root = tx
                        .column(|tx| {
                            let caption = tx.signal(format!("{name} body"));
                            tx.label(caption);
                        })
                        .id();
                    tx.mount_in(id, root);
                    tx.write(status, format!("new {name}"));
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
