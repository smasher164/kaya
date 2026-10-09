//! The expander scene (tools/scenes/expander.steps; docs/expander-plan.md §5):
//! a free expander over an entry, a form holding one, and a stamped list whose
//! rows each keep their own expanded state in their row, through a rebuild.

use std::collections::HashMap;

use kaya::PathKey;

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Section {
    name: String,
    open: bool,
}

#[derive(Clone)]
enum Msg {
    Details(bool),
    Typed(String),
    Show(bool),
    Section(kaya::Path, bool),
    Rebuild,
}

fn word(open: bool) -> &'static str {
    if open { "open" } else { "closed" }
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let mut heard = 0;
    let (state, heard_text, typed, rows_text, details, sections) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("expander").size(520.0, 860.0);
        let state = tx.signal("details: closed");
        let heard_text = tx.signal("heard: 0");
        let typed = tx.signal("name: -");
        let rows_text = tx.signal("rows: -");
        let inside = tx.signal("Inside the body");
        let sections = tx.collection::<Section>();
        let mut details = None;
        let mut section_node = None;
        let root = tx
            .column(|tx| {
                let free = tx
                    .expander("Details", |tx| {
                        let name = tx.entry().placeholder("Name").a11y_id("name").id();
                        msgs.on_change(name, Msg::Typed);
                        tx.label(inside).a11y_id("inside");
                    })
                    .summary("One field")
                    .symbol(kaya::Symbol::Info)
                    .a11y_id("details")
                    .id();
                msgs.on_toggle(free, Msg::Details);
                details = Some(free);
                tx.label(state).a11y_id("state");
                tx.label(heard_text).a11y_id("heard");
                tx.label(typed).a11y_id("typed");
                tx.row(|tx| {
                    let show = tx.button("Show").a11y_id("show").id();
                    msgs.on_click(show, Msg::Show(true));
                    let hide = tx.button("Hide").a11y_id("hide").id();
                    msgs.on_click(hide, Msg::Show(false));
                });
                tx.column(|tx| {
                    tx.labeled("Sort", |tx| {
                        tx.select(&["Due", "Name"], 0).a11y_id("sort");
                    });
                    tx.expander("Advanced", |tx| {
                        tx.labeled("Hide badge", |tx| {
                            tx.checkbox("").a11y_id("badge");
                        });
                        tx.labeled("Keep completed", |tx| {
                            tx.checkbox("").a11y_id("keep");
                        });
                    })
                    .a11y_id("advanced");
                })
                .a11y_id("form");
                tx.label(rows_text).a11y_id("rows");
                let rebuild = tx.button("Rebuild").a11y_id("rebuild").id();
                msgs.on_click(rebuild, Msg::Rebuild);
                tx.column(|tx| {
                    for mut row in sections.rows(tx) {
                        let (node, ()) = row.expander(Section::name(), Section::open(), |t| {
                            t.label(Section::name());
                        });
                        row.a11y_id(node, "sec");
                        section_node = Some(node);
                    }
                });
            })
            .id();
        tx.mount(root);
        for i in 0..3 {
            let key = format!("s{i:02}");
            tx.insert(&sections, key.as_str(), Section { name: format!("Section {i}"), open: i == 1 });
        }
        (
            state,
            heard_text,
            typed,
            rows_text,
            details.expect("the column declared the free expander"),
            (sections, section_node.expect("the list template declared an expander")),
        )
    });
    let (sections, section_node) = sections;
    msgs.on_toggle_node(section_node, Msg::Section);
    let mut opens: HashMap<String, bool> = HashMap::from([("s01".to_owned(), true)]);

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Details(open) => {
                heard += 1;
                ctx.apply(|tx| {
                    tx.write(state, format!("details: {}", word(open)));
                    tx.write(heard_text, format!("heard: {heard}"));
                })
            }
            Msg::Typed(text) => ctx.apply(|tx| tx.write(typed, format!("name: {text}"))),
            Msg::Show(open) => ctx.apply(|tx| {
                tx.expanded(details, open);
                tx.write(state, format!("details: {}", word(open)));
            }),
            Msg::Section(path, open) => {
                let key = path.key::<String>(0);
                opens.insert(key.clone(), open);
                ctx.apply(|tx| {
                    sections.patch(tx, key.as_str()).open(open);
                    tx.write(rows_text, format!("sec {key}: {}", word(open)));
                })
            }
            Msg::Rebuild => {
                let open = opens.get("s00").copied().unwrap_or(false);
                ctx.apply(|tx| {
                    tx.remove(&sections, "s00");
                    tx.insert(&sections, "s00", Section { name: "Section 0".into(), open });
                    tx.write(rows_text, "rebuilt s00");
                })
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
