//! The text-ranges scene (tools/scenes/ranges.steps). THE OFFSETS ARE UTF-8
//! BYTE OFFSETS; the CJK first line is what makes a UTF-16 reader fail.

/// Frozen: three occurrences of `alpha`, and the last match must sit far
/// below the viewport.
const DOC: &str = "line 00: 日本語 preface
line 01: gamma kappa
line 02: alpha beta gamma
line 03: epsilon theta
line 04: zeta nu
line 05: eta zeta
line 06: theta lambda
line 07: iota delta
line 08: kappa iota
line 09: alpha eta theta
line 10: mu eta
line 11: nu mu
line 12: beta epsilon
line 13: gamma kappa
line 14: delta gamma
line 15: epsilon theta
line 16: zeta nu
line 17: eta zeta
line 18: theta lambda
line 19: iota delta
line 20: kappa iota
line 21: lambda beta
line 22: mu eta
line 23: nu mu
line 24: beta epsilon
line 25: gamma kappa
line 26: delta gamma
line 27: epsilon theta
line 28: zeta nu
line 29: eta zeta
line 30: theta lambda
line 31: iota delta
line 32: kappa iota
line 33: lambda beta
line 34: mu eta
line 35: nu mu
line 36: beta epsilon
line 37: alpha iota kappa
line 38: delta gamma
line 39: the last line";

const NEEDLE: &str = "alpha";

/// kaya ships no find engine: what to decorate is the app's question.
fn find_all(doc: &str, needle: &str) -> Vec<std::ops::Range<usize>> {
    doc.match_indices(needle)
        .map(|(at, hit)| at..at + hit.len())
        .collect()
}

#[derive(Clone)]
enum Msg {
    Edited(String),
    Find,
    RevealLast,
    FocusEditor,
    SelectFirst,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (status, editor) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("ranges");
        let status = tx.signal("0 matches");
        let (root, editor) = tx
            .column(|tx| {
                // Every range assertion finds this control by its id.
                let editor = tx.textarea().a11y_id("doc").a11y_label("Document").id();
                tx.set_text(editor, DOC);
                msgs.on_change(editor, Msg::Edited);
                tx.label(status);
                tx.row(|tx| {
                    let find = tx.button("find").id();
                    msgs.on_click(find, Msg::Find);
                    let reveal = tx.button("reveal last").id();
                    msgs.on_click(reveal, Msg::RevealLast);
                    let focus = tx.button("focus editor").id();
                    msgs.on_click(focus, Msg::FocusEditor);
                    let select = tx.button("select first").id();
                    msgs.on_click(select, Msg::SelectFirst);
                });
                editor
            })
            .into_parts();
        tx.mount(root);
        (status, editor)
    });

    // The ONLY authority on what the offsets mean.
    let mut doc = DOC.to_string();

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Edited(text) => {
                doc = text;
                // kaya has ALREADY dropped the decorations on this edit.
                ctx.apply(|tx| {
                    tx.write(status, "0 matches");
                });
            }
            Msg::Find => {
                let hits = find_all(&doc, NEEDLE);
                let count = hits.len();
                ctx.apply(|tx| {
                    tx.highlight_ranges(editor, hits.clone());
                    // The SECOND match, so a leg can tell it from the first.
                    if let Some(one) = hits.get(1) {
                        tx.select_range(editor, one.clone());
                    }
                    tx.write(status, format!("{count} matches"));
                });
            }
            Msg::RevealLast => {
                if let Some(last) = find_all(&doc, NEEDLE).last().cloned() {
                    ctx.apply(|tx| {
                        tx.reveal_range(editor, last);
                    });
                }
            }
            Msg::FocusEditor => {
                ctx.apply(|tx| {
                    tx.focus(editor);
                });
            }
            Msg::SelectFirst => {
                if let Some(first) = find_all(&doc, NEEDLE).first().cloned() {
                    ctx.apply(|tx| {
                        tx.select_range(editor, first);
                    });
                }
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
