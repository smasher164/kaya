//! The app-identity scene (tools/scenes/identity.steps): the mark's four
//! flat quadrants, and a second window whose blank title the NAME fills.

use kaya::Occurrence;

pub(crate) fn app(ctx: kaya::AppCtx) {
    use kaya::WindowId;

    const UNTITLED: WindowId = WindowId(1);

    let (status, field, go) = ctx.apply(|tx| {
        // BEFORE THE FIRST MOUNT, per the declared-once wall.
        let icon = tx.asset("icons/kaya-mark.png");
        tx.app_identity("Aurora Notes", &icon);
        tx.window(kaya::DEFAULT_WINDOW).title("identity").size(480.0, 360.0);
        // ONE PROMOTED COMMAND, AND NOT ABOUT COMMANDS: Windows mints its
        // custom caption from it, replacing the system-drawn icon.
        tx.window(kaya::DEFAULT_WINDOW)
            .menu("File", |m| {
                m.item("Save").symbol(kaya::Symbol::Done).primary(true).id();
            })
            .id();
        let heading = tx.signal("identity");
        let status = tx.signal("ready");
        let (root, (field, go)) = tx
            .column(|tx| {
                tx.label(heading); // label#0
                tx.label(status); // label#1
                let field = tx.entry().id(); // entry#0
                let go = tx.button("Go").id(); // button#0
                (field, go)
            })
            .into_parts();
        tx.mount(root);

        // No title at all: an empty string is a title an app WROTE. THE HOST
        // IS ASKED, NOT THE TARGET, and the phone lanes drop this step.
        if kaya::capabilities().aux_windows {
            let untitled = tx.create_window(UNTITLED).size(360.0, 240.0).id();
            let aux_root = tx
                .column(|tx| {
                    let caption = tx.signal("no title of its own");
                    tx.label(caption); // label#2
                })
                .id();
            tx.mount_in(untitled, aux_root);
        }

        (status, field, go)
    });

    let mut draft = String::new();
    loop {
        match ctx.next() {
            Occurrence::TextChanged { id, text } if id == field => draft = text,
            Occurrence::ButtonClicked { id } if id == go => {
                let text = draft.clone();
                ctx.apply(|tx| tx.write(status, format!("clicked {text}")));
            }
            _ => {}
        }
    }
}

fn main() {
    kaya::run(app)
}
