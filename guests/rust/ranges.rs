//! The text-ranges conformance scene: the three primitives an editor
//! cannot write for itself — HIGHLIGHT a set of ranges, SELECT one,
//! REVEAL one — driven by a search this file writes in five lines.
//!
//! THE FIVE LINES ARE THE POINT. kaya ships no find engine, no find
//! bar and no regex dialect (docs/ranges-plan.md §3): what to decorate
//! is the app's question, and every editor answers it differently.
//! What no app can write for itself is the other half — colouring a run
//! of a native text view, moving its selection, scrolling it into view
//! — and that is exactly what the framework ships. `match_indices` is
//! the whole search here, and it is the honest amount of machinery for
//! the job.
//!
//! THE OFFSETS ARE RUST STRING INDICES. `match_indices` yields byte
//! offsets into the document, `a..a + hit.len()` is a `Range<usize>`,
//! and that is what `tx.highlight_ranges` takes — so the app hands kaya
//! the ranges it already had. The document opens with a CJK word for a
//! reason: every match therefore sits SIX BYTES further along than it
//! sits in UTF-16, which is the unit four of the five backends count.
//! A backend that forwarded kaya's byte offsets as if they were its own
//! unit would decorate six characters early, and the scene's frozen
//! offsets say so.
//!
//! WHAT EACH LEG PROVES, in the order the script runs them:
//!   * a set of three matches decorated at once, read back out of the
//!     platform's own accessibility tree;
//!   * one of them selected, likewise;
//!   * the third REVEALED — asserted `offscreen` first, so the leg
//!     cannot pass on a document that happened to fit;
//!   * a user's keystroke DROPPING the declared set (D2: ranges are
//!     app-owned and never tracked across an edit);
//!   * a `select_range` REFUSED because the user is mid-composition
//!     (D4), which is the one thing on this surface a backend is
//!     expected not to do.
//!
//! The byte-frozen contract is tools/scenes/ranges.steps.

/// The document, frozen. Three occurrences of `alpha` and nothing else
/// containing that substring; forty short lines, so the last match is
/// far below a 240x96 viewport and REVEAL has something to do.
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

/// THE WHOLE SEARCH. Literal, forward, non-overlapping — the standard
/// library's own iterator, yielding the byte offsets kaya's ranges are
/// made of. An editor that wants case folding, word boundaries or a
/// regex dialect writes those here, in the app, where its users can be
/// told what they mean.
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
                // The editor, seeded with the document the app opened.
                // The a11y id is not decoration: every range assertion
                // reads the platform's accessibility tree, and the id
                // is how a leg finds this control there.
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

    // The app's own copy of the document, which is the ONLY authority
    // on what the offsets mean. It advances on every edit, exactly as
    // an editor's buffer does.
    let mut doc = DOC.to_string();

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Edited(text) => {
                doc = text;
                // THE SEARCH RESULTS ARE STALE AND THE APP SAYS SO.
                // kaya has already dropped the decorations — a declared
                // set is bound to the text it was declared against — and
                // this is the app agreeing rather than being told: an
                // editor whose document moved has to search again before
                // it can claim anything about where the matches are.
                ctx.apply(|tx| {
                    tx.write(status, "0 matches");
                });
            }
            Msg::Find => {
                let hits = find_all(&doc, NEEDLE);
                let count = hits.len();
                ctx.apply(|tx| {
                    tx.highlight_ranges(editor, hits.clone());
                    // The second match, so a leg can tell the selection
                    // apart from "the first thing found".
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
