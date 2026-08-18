//! The app-identity conformance scene (docs/app-identity-plan.md): an
//! app declares what it is called and what it looks like, and the
//! platform shows both. The byte-frozen contract is
//! tools/scenes/identity.steps.
//!
//! THE MARK IS THE VENDORED ONE (guests/assets/icons/kaya-mark.png,
//! four flat quadrants) because no platform's own default icon can land
//! on four declared colours, so a lowering that never applied can never
//! read as a pass. KAYA_ICON_FILE is how a runner that cannot see the
//! repo points at a pushed copy — the typeface scene's KAYA_FONT_FILE,
//! one asset over.
//!
//! THE SECOND WINDOW HAS NO TITLE OF ITS OWN, deliberately: that is the
//! blank an app's NAME fills on every platform, and the only place the
//! name half of this declaration is observable at runtime.

use kaya::Occurrence;

pub(crate) fn app(ctx: kaya::AppCtx) {
    // THE UNTITLED WINDOW IS DESKTOP-ONLY, on the SAME predicate the core
    // itself keys on (crates/kaya/src/scene.rs's CreateWindow arm), so the
    // two cannot drift: the phones' systems own surface geometry, so
    // KAYA_CAP_AUX_WINDOWS is unset there and `create_window` is a
    // deterministic scene error. Measured before this cfg existed: the
    // guest aborted with "this host has no auxiliary windows" after one
    // harness step, on an emulator, with the icon already declared. The
    // phone lanes drop the one step that reads it
    // (tools/android/run-emulator.sh's scene_script_drop); the NAME's
    // reader there is the package's own label.
    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    use kaya::WindowId;

    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    const UNTITLED: WindowId = WindowId(1);

    let (status, field, go) = ctx.apply(|tx| {
        // BEFORE THE FIRST MOUNT, per the declared-once wall.
        let icon_path = std::env::var("KAYA_ICON_FILE")
            .unwrap_or_else(|_| "guests/assets/icons/kaya-mark.png".into());
        let icon = std::fs::read(&icon_path).unwrap_or_else(|e| {
            panic!(
                "kaya: the identity scene needs the vendored mark at \
                 {icon_path} (set KAYA_ICON_FILE or run from the repo \
                 root): {e}"
            )
        });
        tx.app_identity("Aurora Notes", &icon);
        tx.window(kaya::DEFAULT_WINDOW).title("identity").size(480.0, 360.0);
        // ONE PROMOTED COMMAND, AND IT IS NOT ABOUT COMMANDS. Windows
        // mints its custom caption from the first promotion and from
        // nothing else (crates/kaya/src/winui/mod.rs's
        // `window_titlebars`), and a custom caption REPLACES the system
        // one — taking the system-drawn app icon with it. That is why
        // the identity has a second Windows sink at all
        // (docs/app-identity-plan.md I3), and a scene with no promotion
        // anywhere would leave that sink's arm a branch nobody has ever
        // reached. So the primary window promotes and the second window
        // does not: one run exercises both captions.
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

        // THE UNTITLED WINDOW. It declares no title at all rather than
        // an empty one: an empty string is a title an app WROTE, and the
        // rule under test is what a window with nothing written shows.
        #[cfg(not(any(target_os = "ios", target_os = "android")))]
        {
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

    // The app's copy of the field's text: never a widget read.
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
