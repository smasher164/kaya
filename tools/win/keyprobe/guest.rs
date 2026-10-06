//! THROWAWAY guest for the WinUI in-process keystroke probe
//! (tools/win/keyprobe/README.md). One of each text kind the shared scenes
//! type into, each wired the way the shipped guests wire it, so the probe
//! module in kaya.dll can read what the APP saw beside what the control
//! holds:
//!
//!   labels[0]  "sent: -"        written by every `submitted` (the Return door)
//!   labels[1]  "commits: 0"     written by the number field's `on_commit`
//!   labels[2]  "changed: 0"     one count of every text_changed on any field
//!   labels[3]  "menu: none"     written when Edit>Undo (primary+z) activates
//!   entries[0] the `name` entry (TextBox) — the typing target
//!   entries[1] the `note` entry — where a posted Tab moves the focus
//!   searches[0] the `find` search field — the Escape door
//!   textareas[0] the `compose` textarea with `submits` — the Shift+Return door
//!   number_fields[0] `amount`, 0..100 by 0.5 — Return and focus-loss commits
//!
//! Every occurrence prints PROBEGUEST, so the log tells an occurrence the app
//! received from a native state the probe read.

#[derive(Clone)]
enum Msg {
    Sent(String),
    Committed(f64),
    Changed(String),
    Undo,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let mut changes = 0u32;
    let (sent, commits, changed, menu) = ctx.apply(|tx| {
        let undo = tx
            .window(kaya::DEFAULT_WINDOW)
            .title("keyprobe")
            .menu("Edit", |m| m.item("Undo").shortcut("primary+z").id())
            .value();
        msgs.on_menu_item(undo, Msg::Undo);
        let sent = tx.signal("sent: -".to_string());
        let commits = tx.signal("commits: 0".to_string());
        let changed = tx.signal("changed: 0".to_string());
        let menu = tx.signal("menu: none".to_string());
        let (root, ()) = tx
            .column(|tx| {
                tx.label(sent).a11y_id("sent");
                tx.label(commits).a11y_id("commits");
                tx.label(changed).a11y_id("changed");
                tx.label(menu).a11y_id("menu");
                let name = tx.entry().placeholder("Name").a11y_id("name").id();
                msgs.on_submit(name, Msg::Sent);
                msgs.on_change(name, Msg::Changed);
                let note = tx.entry().placeholder("Note").a11y_id("note").id();
                msgs.on_change(note, Msg::Changed);
                let find = tx.search().placeholder("Search").a11y_id("find").id();
                msgs.on_change(find, Msg::Changed);
                let compose = tx.textarea().submits().a11y_id("compose").id();
                msgs.on_submit(compose, Msg::Sent);
                msgs.on_change(compose, Msg::Changed);
                let amount = tx
                    .number_field(0.0)
                    .min(0.0)
                    .max(100.0)
                    .step(0.5)
                    .a11y_id("amount")
                    .a11y_label("Amount")
                    .id();
                msgs.on_commit(amount, Msg::Committed);
            })
            .into_parts();
        tx.mount(root);
        (sent, commits, changed, menu)
    });
    println!("PROBEGUEST ready");

    let mut committed = 0u32;
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Sent(text) => {
                println!("PROBEGUEST submitted {text:?}");
                ctx.apply(|tx| tx.write(sent, format!("sent: {text}")));
            }
            Msg::Committed(value) => {
                committed += 1;
                println!("PROBEGUEST committed {value}");
                ctx.apply(|tx| tx.write(commits, format!("commits: {committed}")));
            }
            Msg::Changed(text) => {
                changes += 1;
                println!("PROBEGUEST text_changed {text:?}");
                ctx.apply(|tx| tx.write(changed, format!("changed: {changes}")));
            }
            Msg::Undo => {
                println!("PROBEGUEST menu_activated Edit>Undo");
                ctx.apply(|tx| tx.write(menu, "menu: undo".to_string()));
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
