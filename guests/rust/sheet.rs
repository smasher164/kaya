//! The sheet scene (tools/scenes/sheet.steps; docs/sheet-plan.md §6): a
//! sheet opened from a button and closed through the platform's cancel
//! path, the same sheet with the dismiss veto armed, a child sheet chained
//! over it, and a programmatic dismiss that echoes nothing.

pub(crate) fn app(ctx: kaya::AppCtx) {
    use kaya::WindowId;

    #[derive(Clone)]
    enum Msg {
        Open,
        OpenArmed,
        Draft(String),
        OpenDetails,
        Done,
        Dismissed,
        DismissAsked,
        DetailsDismissed,
    }

    const TASK: WindowId = WindowId(11);
    const DETAILS: WindowId = WindowId(12);

    let msgs = kaya::Messages::<Msg>::new();
    let (status, draft) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("sheet");
        let status = tx.signal("closed");
        let draft = tx.signal("draft: none");
        let root = tx
            .column(|tx| {
                tx.label(status); // label#0
                let open = tx.button("new task").id(); // button#0
                msgs.on_click(open, Msg::Open);
                let armed = tx.button("new task, armed").id(); // button#1
                msgs.on_click(armed, Msg::OpenArmed);
            })
            .id();
        tx.mount(root);
        (status, draft)
    });

    // The sheet's body: a caption, a field the app reads as it changes, a
    // button that chains a child sheet, and one that finishes.
    let open_task = |tx: &mut kaya::Tx, armed: bool| {
        let sheet = tx
            .present_sheet(TASK)
            .title("new task")
            .detent(kaya::Detent::Medium)
            .intercept_dismiss(armed)
            .id();
        let body = tx
            .column(|tx| {
                let caption = tx.signal("what needs doing?");
                tx.label(caption); // label#1
                let field = tx.entry().id(); // entry#0
                msgs.on_change(field, Msg::Draft);
                tx.label(draft); // label#2
                let details = tx.button("details").id(); // button#2
                msgs.on_click(details, Msg::OpenDetails);
                let done = tx.button("done").id(); // button#3
                msgs.on_click(done, Msg::Done);
            })
            .id();
        tx.mount_in(sheet, body);
        tx.write(status, "open");
        tx.write(draft, "draft: none");
        sheet
    };

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Open => {
                let sheet = ctx.apply(|tx| open_task(tx, false));
                // Rides the present, per sheet, and retires with it.
                msgs.on_sheet_dismissed(sheet, Msg::Dismissed);
            }
            Msg::OpenArmed => {
                let sheet = ctx.apply(|tx| open_task(tx, true));
                msgs.on_sheet_dismissed(sheet, Msg::Dismissed);
                msgs.on_dismiss_requested(sheet, Msg::DismissAsked);
            }
            Msg::Draft(text) => ctx.apply(|tx| {
                tx.write(draft, format!("draft: {text}"));
            }),
            Msg::OpenDetails => {
                let child = ctx.apply(|tx| {
                    let child = tx.present_sheet_over(TASK, DETAILS).title("details").id();
                    let body = tx
                        .column(|tx| {
                            let caption = tx.signal("more about it");
                            tx.label(caption); // label#3
                        })
                        .id();
                    tx.mount_in(child, body);
                    tx.write(status, "details open");
                    child
                });
                msgs.on_sheet_dismissed(child, Msg::DetailsDismissed);
            }
            Msg::Done => ctx.apply(|tx| {
                // Programmatic: no sheet_dismissed follows, so "done" stays.
                tx.dismiss_sheet(TASK);
                tx.write(status, "done");
            }),
            Msg::Dismissed => ctx.apply(|tx| {
                tx.write(status, "dismissed");
            }),
            Msg::DismissAsked => ctx.apply(|tx| {
                // Nothing has gone; the app keeps the sheet up and says so.
                tx.write(status, "dismiss requested");
            }),
            Msg::DetailsDismissed => ctx.apply(|tx| {
                tx.write(status, "details dismissed");
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
